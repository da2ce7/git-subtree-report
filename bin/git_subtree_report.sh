#!/usr/bin/env bash

# git_subtree_report.sh - Analyze Git repositories and subtrees without filesystem interaction
#
# Version: 1.6.0
# License: AGPLv3
# Author: Cameron Garnham <me@da2ce7.com>
# Repository: https://github.com/da2ce7/git-subtree-report
#
# Usage: git_subtree_report.sh [OPTIONS...]
#
# Options:
#   -C, --working-dir <DIR>    Change to directory before running.
#   -i, --include <PATTERN>    Only include files matching the ERE pattern.
#   -e, --exclude <PATTERN>    Exclude files matching the ERE pattern.
#   -h, --help                 Display a detailed help message and exit.
#   -o, --output-concat        Enable concatenated output of safe files.
#   -r, --ref <REF>            Specify Git reference (commit, branch, tag). Default: HEAD.
#   -s, --max-size <SIZE>      Set max file size for analysis (e.g., 1M). Default: 1M.
#   -t, --subtree <PATH>       Relative path of the subdirectory to analyze.
#       --version              Display version information and exit.
#
# Description:
#   This script provides a detailed analysis of Git repositories and subtrees, supporting
#   both standard and bare repositories. The filtering pipeline first applies the --include
#   filter (if provided), and then applies the --exclude filter to the result.
#
# Requirements:
#   - Bash 5.0 or later
#   - Git 2.20 or later
#   - Perl 5.10 or later
#   - C.UTF-8 locale must be available
#
# Example:
#   git_subtree_report.sh -C /path/to/repo -t src -i '\.(c|h)$' -e 'test/'
#
#   This analyzes the 'src' subtree, first including only files ending in .c or .h,
#   and then excluding any of those results that are in a 'test/' directory.

###########################################
#### 1. Initialization & Environment Setup
###########################################

### Strict Mode
set -Ceuo pipefail

# ==============================================================================
# --- Global State & Configuration
# ==============================================================================
# This group contains variables for the script's internal constants,
# environment-dependent settings, and runtime state. These are NOT directly
# set by user command-line flags.

# --- Script constants and required commands ---
declare -r VERSION="1.6.0"
declare -ra UNIX_COMMANDS=(git grep awk tr wc bc numfmt perl sort)
declare -ri MIN_PERL_MAJOR=5
declare -ri MIN_PERL_MINOR=10
declare -ri MIN_BASH_MAJOR=5
declare -ri MIN_GIT_MAJOR=2
declare -ri MIN_GIT_MINOR=20

# --- Environment-dependent state ---
declare -i color_enabled=0 # Set by `check_utf8_locale` based on tty

# --- Runtime state variables (populated during setup) ---
declare -i has_working_tree=0 # Is this a bare or standard repository?
declare repo_root=""          # Absolute path to the Git repository root
declare working_dir=""        # Absolute path after -C resolution
declare ref_hash=""           # The fully resolved commit SHA to be analyzed
declare subdir_rel=""         # The final, normalized relative path of the subtree

# ==============================================================================
# --- User-Configurable Options (with defaults)
# ==============================================================================
# This group contains variables that are directly set by user-provided command-
# line arguments. The parser will modify these values.

# --- Argument value holders ---
declare include_pattern_arg=""
declare exclude_pattern_arg=""
declare git_ref_arg="HEAD"
declare context_arg="."
declare subtree_arg="."
declare -i max_file_size_arg=1048576 # Default 1MiB (1MB)

# --- Argument flags ---
declare -i concatenate_flag=0        # -o / --output-concat
declare -i include_pattern_arg_set=0 # -i / --include
declare -i exclude_pattern_arg_set=0 # -e / --exclude
declare -i git_ref_arg_set=0         # -r / --ref
declare -i context_arg_set=0         # -C / --working-dir
declare -i subtree_arg_set=0         # -t / --subtree

### Centralized Error Handler
# This script employs a structured error handling system. Its heart is this
# single function, `fail_with`, which centralizes all exit conditions.
# Each error message is designed to be a three-part admonition:
# 1. [ALARM]   A clear, machine-parsable code and name (e.g., ERROR 23: E_PATH_NOT_RELATIVE).
# 2. [SITUATION] A concise, human-readable statement of what happened.
# 3. [POINTER]   Actionable advice on how to resolve the issue.
# This approach turns cryptic failures into helpful guidance.
fail_with() {
	local code="$1"
	shift
	local message=""

	# Domain 1-19: Environment & Dependencies
	case "$code" in
	2)
		message="ERROR 2 (E_BASH_VERSION): Bash version is below the minimum requirement.\n"
		message+="Situation: This script requires Bash v${MIN_BASH_MAJOR}.0 or newer, but your version is ${BASH_VERSION%%.*}.\n"
		message+="Pointer:   Please upgrade your Bash installation to continue."
		;;
	3)
		message="ERROR 3 (E_GIT_VERSION): Git version is below the minimum requirement.\n"
		message+="Situation: This script requires Git v${MIN_GIT_MAJOR}.${MIN_GIT_MINOR} or newer, but your version is %s.\n"
		message+="Pointer:   Please upgrade your Git installation to continue."
		;;
	4)
		message="ERROR 4 (E_PERL_VERSION): Perl version is below the minimum requirement.\n"
		message+="Situation: This script requires Perl v${MIN_PERL_MAJOR}.${MIN_PERL_MINOR} or newer, but your version is %s.\n"
		message+="Pointer:   Please upgrade your Perl installation to continue."
		;;
	5)
		message="ERROR 5 (E_CMD_NOT_FOUND): A required command is not in your PATH.\n"
		message+="Situation: The command '%s' is essential for the script but could not be found.\n"
		message+="Pointer:   Please install the command or ensure its location is in your system's PATH variable."
		;;
	6)
		message="ERROR 6 (E_LOCALE_FAILURE): The required C.UTF-8 locale is not available.\n"
		message+="Situation: The script requires the C.UTF-8 locale for consistent text processing, which is not present.\n"
		message+="Pointer:   Run 'locale -a' to see available locales and ensure C.UTF-8 is configured on your system."
		;;

	# Domain 20-39: Arguments & Input
	20)
		message="ERROR 20 (E_INVALID_OPTION): An invalid option was provided.\n"
		message+="Situation: The option '-%s' is not supported by this script.\n"
		message+="Pointer:   Run the script with '--help' to see a list of valid options."
		;;
	21)
		message="ERROR 21 (E_MISSING_ARG): An option is missing its required argument.\n"
		message+="Situation: The option '-%s' requires a value that was not provided.\n"
		message+="Pointer:   Please provide an argument (e.g., '-r <ref>', '-s <size>'). See '--help' for usage."
		;;
	22)
		message="ERROR 22 (E_INVALID_SIZE): Invalid size format provided to the -s option.\n"
		message+="Situation: The value '%s' is not a valid IEC size format.\n"
		message+="Pointer:   Use a format like '10M' (megabytes), '500K' (kilobytes), or raw bytes."
		;;
	23)
		message="ERROR 23 (E_PATH_NOT_RELATIVE): The path for the -t option must be relative.\n"
		message+="Situation: You provided an absolute path ('%s') which starts with '/'.\n"
		message+="Pointer:   Please provide a path relative to the repository root (e.g., 'src/component')."
		;;

	# Domain 40-124: Runtime & Logic
	40)
		message="ERROR 40 (E_INTERNAL_LOGIC): An internal logic error occurred.\n"
		message+="Situation: An unexpected state was reached in the function '%s'.\n"
		message+="Pointer:   This is likely a bug. Please report it at the script's repository with details."
		;;
	41)
		message="ERROR 41 (E_METADATA_MISMATCH): Inconsistent file metadata was detected.\n"
		message+="Situation: %s\n"
		message+="Pointer:   This indicates a problem during the Git data collection phase. Ensure the repository is not corrupt."
		;;

	# Domain 128-140: Security & High-Level State
	128)
		message="ERROR 128 (E_NOT_A_REPO): The target directory is not a Git repository.\n"
		message+="Situation: Could not find a '.git' directory at or above the path '%s'.\n"
		message+="Pointer:   Please run this script from within a Git repository or use '-C /path/to/repo' to specify one."
		;;
	129)
		message="ERROR 129 (E_INVALID_CONTEXT): This operation requires running from the repository root.\n"
		message+="Situation: Current directory is '%s' but must be the repository root '%s'.\n"
		message+="Pointer:   This is required when using a bare repository or combining '-C' with '-t'. Please 'cd' to the root and retry."
		;;
	130)
		message="ERROR 130 (E_INVALID_REF): The provided Git reference is invalid or not a commit.\n"
		message+="Situation: The reference '%s' could not be resolved to a valid commit object.\n"
		message+="Pointer:   Please use a valid tag, branch, or full commit SHA. Ensure your repository is up to date."
		;;
	131)
		message="ERROR 131 (E_SUBTREE_NOT_FOUND): The specified subtree path does not exist.\n"
		message+="Situation: The path '%s' was not found in the tree of commit '%s'.\n"
		message+="Pointer:   Use 'git ls-tree %s' to list valid paths from the root of the commit."
		;;
	132)
		message="ERROR 132 (E_SUBTREE_NOT_DIR): The specified subtree path is not a directory.\n"
		message+="Situation: The path '%s' resolved to a '%s' object, not a directory (tree).\n"
		message+="Pointer:   The -t option must point to a directory within the repository."
		;;
	134)
		message="ERROR 134 (E_GIT_FAILURE): A core Git command failed during execution.\n"
		message+="Situation: The command 'git %s' failed unexpectedly.\n"
		message+="Pointer:   Ensure your Git installation is sound and the repository is not corrupt."
		;;
	135)
		message="ERROR 135 (E_SYMLINK_IN_PATH): A symbolic link was detected in the -C path.\n"
		message+="Situation: The security check found a symlink at '%s' within the provided path argument '%s'.\n"
		message+="Pointer:   For security reasons, this is disallowed. Please provide the canonical path. Use 'readlink -f %s' to resolve it."
		;;

	141)
		message="ERROR 141 (E_PIPEFAIL): A command in a pipeline failed.\n"
		message+="Situation: Execution was terminated by a broken pipe. This often happens if the output is piped to a command (like 'head') which closes the stream early.\n"
		message+="Pointer:   This is often not a critical error. If the output seems incomplete, try running without piping to another command."
		;;

	*)
		message="FATAL ERROR 1 (%s): An unhandled error occurred.\n"
		message+="Pointer: This is a bug. Please report it."
		code=1
		;;
	esac

	# shellcheck disable=SC2059
	printf "$message\n" "$@" >&2
	exit "$code"
}

# --- Helper functions for argument parsing ---
display_help_and_exit() {
	# This function should contain the help text (from the script's header comments)
	echo "Usage: git-subtree-report [OPTIONS...]"
	echo "A full-featured Git repository analysis tool."
	echo ""
	echo "Options:"
	echo "  -i, --include PATTERN  Only include files that match the ERE pattern (allow-list)."
	echo "  -e, --exclude PATTERN  Exclude files from the included set that match the ERE pattern (block-list)."
	echo "  -r, --ref REF          Specify Git reference (commit, branch, tag). Default: HEAD."
	echo "  -C, --working-dir DIR  Change to directory before running."
	echo "  -t, --subtree PATH     Subtree path to analyze, relative to repo root."
	echo "  -s, --max-size SIZE    Max file size for analysis (e.g., 1M, 500K). Default: 1M."
	echo "  -o, --output-concat    Enable concatenated output of safe files."
	echo "  -h, --help             Display this help message and exit."
	echo "      --version          Display version information and exit."
	exit 0
}

display_version_and_exit() {
	echo "git-subtree-report version ${VERSION}"
	exit 0
}

# --- Refactored Argument Parsing Function ---
parse_arguments() {
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		shift # Consume the argument key now

		case "$arg" in
		# --- Help and Version ---
		-h | --help)
			display_help_and_exit
			;;
		--version)
			display_version_and_exit
			;;

		# --- Include Pattern ---
		-i | --include)
			if [[ $# -eq 0 || "$1" == -* ]]; then fail_with 21 "$arg"; fi
			include_pattern_arg="$1"
			include_pattern_arg_set=1
			shift # Consume value
			;;
		--include=*)
			include_pattern_arg="${arg#*=}"
			include_pattern_arg_set=1
			;;

		# --- Exclude Pattern ---
		-e | --exclude)
			if [[ $# -eq 0 || "$1" == -* ]]; then fail_with 21 "$arg"; fi
			exclude_pattern_arg="$1"
			exclude_pattern_arg_set=1
			shift # Consume value
			;;
		--exclude=*)
			exclude_pattern_arg="${arg#*=}"
			exclude_pattern_arg_set=1
			;;

		# --- Git Reference ---
		-r | --ref)
			if [[ $# -eq 0 || "$1" == -* ]]; then fail_with 21 "$arg"; fi
			git_ref_arg="$1"
			git_ref_arg_set=1
			shift
			;;
		--ref=*)
			git_ref_arg="${arg#*=}"
			git_ref_arg_set=1
			;;

		# --- Working Directory ---
		-C | --working-dir)
			if [[ $# -eq 0 || "$1" == -* ]]; then fail_with 21 "$arg"; fi
			context_arg="$1"
			context_arg_set=1
			shift
			;;
		--working-dir=*)
			context_arg="${arg#*=}"
			context_arg_set=1
			;;

		# --- Subtree Path ---
		-t | --subtree)
			if [[ $# -eq 0 || "$1" == -* ]]; then fail_with 21 "$arg"; fi
			subtree_arg="$1"
			if [[ "$subtree_arg" = /* ]]; then fail_with 23 "$subtree_arg"; fi
			subtree_arg_set=1
			shift
			;;
		--subtree=*)
			subtree_arg="${arg#*=}"
			if [[ "$subtree_arg" = /* ]]; then fail_with 23 "$subtree_arg"; fi
			subtree_arg_set=1
			;;

		# --- Max File Size ---
		-s | --max-size)
			if [[ $# -eq 0 || "$1" == -* ]]; then fail_with 21 "$arg"; fi
			if ! max_file_size_arg=$(numfmt --from=iec "$1"); then fail_with 22 "$1"; fi
			shift
			;;
		--max-size=*)
			local size_val="${arg#*=}"
			if ! max_file_size_arg=$(numfmt --from=iec "$size_val"); then fail_with 22 "$size_val"; fi
			;;

		# --- Concatenation Flag (Boolean) ---
		-o | --output-concat)
			concatenate_flag=1
			;;

		# --- Standard option handling ---
		--)
			# All subsequent arguments are positional (none in this script)
			break
			;;
		-*)
			# Handles unknown options like -z or --unknown-flag
			fail_with 20 "$arg"
			;;
		*)
			# Handles positional arguments. This script doesn't have any,
			# so treat them as an error.
			echo "ERROR: Unexpected positional argument '$arg'." >&2
			fail_with 20 "$arg"
			;;
		esac
	done

	# Preserve any post-parsing logic from the original script
	if ((context_arg_set)) && [[ "$context_arg" == "." ]]; then
		echo "NOTE: Using default '-C .' is redundant." >&2
	fi

	# FINALIZATION: Make variables read-only to prevent modification
	# This is a critical security and stability practice from the original script.
	readonly include_pattern_arg exclude_pattern_arg git_ref_arg context_arg subtree_arg max_file_size_arg concatenate_flag
	readonly include_pattern_arg_set exclude_pattern_arg_set git_ref_arg_set context_arg_set subtree_arg_set
}

### Core Environment Setup
setup_environment() {
	# Base system checks
	check_required_commands
	check_utf8_locale

	# Establish working context
	handle_directory_change
	check_git_repository

	# Repository characterization
	determine_repo_type
	determine_repo_root
	check_for_zero_commits

	# Critical root assertion
	if ( ! ((has_working_tree))) || ( ((context_arg_set)) && ((subtree_arg_set))); then
		if [[ "$working_dir" != "$repo_root" ]]; then
			fail_with 129 "$working_dir" "$repo_root"
		fi
	fi

	# Commit resolution
	resolve_commit

	# Subtree resolution
	determine_subtree_path
	verify_subtree_exists

	# Status diagnostics
	echo "Initialized workspace:" >&2
	echo "  ├─ Repo root:  $repo_root" >&2
	echo "  ├─ Working dir: $working_dir" >&2
	echo "  ├─ Subtree:    ./$subdir_rel" >&2
	echo "  ├─ Inclusion Filter:  '${include_pattern_arg:-<none>}'  (ERE)" >&2
	echo "  └─ Exclusion Filter:  '${exclude_pattern_arg:-<none>}'  (ERE)" >&2
}

### Security & Directory Handling
# verify_no_symlinks_in_path - Security check to prevent TOCTOU vulnerabilities.
# It traverses a path upwards from the target, ensuring no component is a symbolic link.
verify_no_symlinks_in_path() {
	local path_to_check="$1"
	local original_path="$path_to_check"
	# Canonicalize the path to be absolute for a reliable check.
	[[ "$path_to_check" != /* ]] && path_to_check="$PWD/$path_to_check"

	# This loop is a security measure. Instead of checking only the final path, it walks
	# up the tree, ensuring no component of the path is a symlink. This prevents a
	# malicious actor from swapping a directory with a symlink after a check but
	# before the script `cd`s into it.
	while [[ "$path_to_check" != "/" && "$path_to_check" != "." ]]; do
		if [ -L "$path_to_check" ]; then
			fail_with 135 "$path_to_check" "$original_path" "$original_path"
		fi
		path_to_check=$(dirname "$path_to_check")
	done
}

### Directory Handling
handle_directory_change() {
	echo "Initializing working context: $context_arg" >&2

	# Security Check: Verify the path has no symlinks before using it.
	verify_no_symlinks_in_path "$context_arg"

	if ! cd -- "$context_arg"; then
		# Use E_GIT_FAILURE as a generic for "a critical external command failed"
		fail_with 134 "cd -- \"$context_arg\""
	fi
	working_dir=$(pwd -P)
	readonly working_dir # Final value assigned
}

### Repository Validation
check_git_repository() {
	if ! git rev-parse --git-dir &>/dev/null; then
		fail_with 128 "$working_dir"
	fi
}

determine_repo_type() {
	local worktree_status
	if ! worktree_status=$(git rev-parse --is-inside-work-tree); then
		fail_with 41 "Failed to determine repository type via 'git rev-parse'."
	fi

	if [[ "$worktree_status" == "true" ]]; then
		has_working_tree=1
		echo "Work tree detected" >&2
	else
		has_working_tree=0
		echo "Bare repository detected" >&2
	fi
	readonly has_working_tree # Final value assigned
}

determine_repo_root() {
	if ((has_working_tree)); then
		repo_root=$(git rev-parse --show-toplevel)
	else
		repo_root=$(git rev-parse --absolute-git-dir)
	fi
	readonly repo_root # Final value assigned
	echo "Resolved repo root: $repo_root" >&2

	if [[ ! -d "$repo_root" ]]; then
		fail_with 41 "Resolved repository root '$repo_root' is not a valid directory."
	fi
}

check_for_zero_commits() {
	if [[ -z "$(git rev-list --all 2>/dev/null)" ]]; then
		echo "WARNING: Repository contains zero commits" >&2
		exit 0
	fi
}

### Subtree Path Resolution

determine_subtree_path() {
	if ((subtree_arg_set)); then
		# NORMALIZATION POINT FOR -t INPUT
		subdir_rel="${subtree_arg%/}" # Trim trailing slash

		# RELATIVE PATH VALIDATION executed in parse_arguments
		# Kept here as a defensive measure in case of direct function call.
		if [[ "$subdir_rel" == /* ]]; then
			fail_with 23 "$subdir_rel"
		fi

		subdir_rel=$(printf "%s" "$subdir_rel" | tr -s '/')
	else
		# Original auto-derive logic with normalization
		subdir_rel="${working_dir#"$repo_root"/}"
		subdir_rel="${subdir_rel%/}"                        # Trim trailing slash
		subdir_rel=$(printf "%s" "$subdir_rel" | tr -s '/') # Clean path
		[[ "$subdir_rel" == "$working_dir" ]] && subdir_rel="."
	fi

	readonly subdir_rel # Final normalized path
}

verify_subtree_exists() {
	if [[ "$subdir_rel" != "." ]]; then
		if ! git ls-tree --name-only "$ref_hash" "$subdir_rel" &>/dev/null; then
			fail_with 131 "$subdir_rel" "${ref_hash:0:8}" "${ref_hash:0:8}"
		fi
	fi

	local tree_path
	if [[ "$subdir_rel" == "." ]]; then
		tree_path="${ref_hash}^{tree}"
	else
		tree_path="HEAD:$subdir_rel"
	fi

	local tree_type
	tree_type=$(git cat-file -t "$tree_path") || {
		fail_with 134 "cat-file -t \"$tree_path\""
	}
	readonly tree_type # Used only here, made read-only to prevent accidental reuse

	if [[ "$tree_type" != "tree" ]]; then
		fail_with 132 "$subdir_rel" "$tree_type"
	fi
}

### Commit Resolution
resolve_commit() {
	echo "Resolving commit: $git_ref_arg" >&2

	if ! ref_hash=$(git rev-parse "$git_ref_arg"); then
		fail_with 130 "$git_ref_arg"
	fi

	if ! git cat-file -e "$ref_hash^{commit}"; then
		fail_with 130 "$ref_hash (not a commit object)"
	fi

	readonly ref_hash # Final value assigned
	echo "Resolved commit: ${ref_hash:0:8}" >&2
}

### Utility Validators
check_bash_version() {
	((BASH_VERSINFO[0] >= MIN_BASH_MAJOR)) || fail_with 2
}

check_git_version() {
	local version_str major minor
	version_str=$(git --version | awk '{gsub(/^v|,.*/,"",$3); print $3}')
	IFS='.' read -r major minor _ <<<"$version_str"
	major=${major:-0}
	minor=${minor:-0}

	if ((major < MIN_GIT_MAJOR || (major == MIN_GIT_MAJOR && minor < MIN_GIT_MINOR))); then
		fail_with 3 "$version_str"
	fi
}

check_perl_version() {
	local version_str major minor patch
	if ! version_str=$(perl -e 'print $^V' 2>/dev/null); then
		fail_with 41 "Failed to execute 'perl -e print \$^V' to check version"
	fi

	version_str=${version_str#v}
	IFS='.' read -r major minor patch <<<"$version_str"
	major=${major:-0}
	minor=${minor:-0}
	patch=${patch:-0}

	if ((major < MIN_PERL_MAJOR)) ||
		((major == MIN_PERL_MAJOR && minor < MIN_PERL_MINOR)); then
		local found_version
		found_version=$(printf "%d.%d.%d" "$major" "$minor" "$patch")
		fail_with 4 "$found_version"
	fi
}

check_required_commands() {
	check_bash_version
	for cmd in "${UNIX_COMMANDS[@]}"; do
		command -v "$cmd" >/dev/null || fail_with 5 "$cmd"
	done
	check_git_version
	check_perl_version
}

check_utf8_locale() {
	if ! locale -a | grep -qiE "C\.(utf-?8|UTF-?8)"; then
		fail_with 6
	fi
	export LC_ALL=C.UTF-8

	if [[ -t 1 ]]; then
		color_enabled=1
		readonly color_enabled # Final value assigned
		echo "Color output enabled" >&2
	else
		readonly color_enabled # Lock default value (0)
	fi
}

############################################
#### 2. Git Tree Navigation & File Inventory
############################################

### Tree Hash Resolution
declare root_tree_hash # SHA of ref_hash's tree (entire repo)
declare sub_tree_hash  # SHA of target subtree

get_tree_hashes() {
	root_tree_hash=$(git -C "$repo_root" rev-parse "${ref_hash}^{tree}") ||
		fail_with 41 "Failed to resolve root tree for commit '${ref_hash:0:8}'."

	readonly root_tree_hash # Final value assigned

	if [[ "$subdir_rel" == "." ]]; then
		sub_tree_hash="$root_tree_hash"
		echo "Processing entire repository tree" >&2
	else
		local sub_tree_entry sub_tree_type
		sub_tree_entry=$(git -C "$repo_root" ls-tree "$root_tree_hash" "$subdir_rel") ||
			fail_with 131 "$subdir_rel" "${ref_hash:0:8}" "${ref_hash:0:8}"
		readonly sub_tree_entry # Used only here, locked for safety

		sub_tree_type=$(awk '{print $2}' <<<"$sub_tree_entry")
		[[ "$sub_tree_type" == "tree" ]] ||
			fail_with 132 "$subdir_rel" "$sub_tree_type"

		sub_tree_hash=$(awk '{print $3}' <<<"$sub_tree_entry")

		git -C "$repo_root" cat-file -e "$sub_tree_hash^{tree}" ||
			fail_with 41 "Subtree object '$sub_tree_hash' for path '$subdir_rel' is invalid or not a tree."
	fi
	readonly sub_tree_hash # Final value assigned
}

### File Inventory & Filtering Pipeline

# Foundational data maps (populated once)
declare -A path_to_blob=()        # [rel_path] -> blob SHA
declare -A path_to_mode=()        # [rel_path] -> file mode (e.g. 100644)
declare -A blob_to_size=()        # [blob] -> raw byte count
declare -A blob_to_size_pretty=() # [blob] -> human-readable size

# The "Three Buckets" for categorized paths
declare -A path_is_rejected_by_include=()
declare -A path_is_rejected_by_exclude=()
declare -A path_is_selected_for_analysis=()

hydrate_file_inventory_and_filter() {
	# --- Stage 1: Hydrate Foundational Data ---
	echo -n "Collecting file metadata from subtree... " >&2
	local entry
	while IFS= read -r -d '' entry; do
		IFS=' ' read -r mode type sha _ <<<"${entry%%$'\t'*}"
		if [[ "$type" == "blob" ]]; then
			local rel_path="${entry#*$'\t'}"
			path_to_blob["$rel_path"]=$sha
			path_to_mode["$rel_path"]=$mode
		fi
	done < <(git -C "$repo_root" ls-tree -r -z "$sub_tree_hash")

	local -i initial_candidate_count=${#path_to_blob[@]}
	echo "found $initial_candidate_count files." >&2

	if [[ ${#path_to_mode[@]} -ne $initial_candidate_count ]]; then
		fail_with 41 "Mismatch in file modes captured (${#path_to_mode[@]}) vs. blobs ($initial_candidate_count)."
	fi
	readonly -A path_to_blob path_to_mode

	echo -n "Calculating blob sizes... " >&2
	local -a unique_shas
	mapfile -t unique_shas < <(printf '%s\n' "${path_to_blob[@]}" | sort -u)
	readonly -a unique_shas

	while IFS=' ' read -r blob size type; do
		if [[ "$type" == "blob" && "$size" =~ ^[0-9]+$ ]]; then
			blob_to_size["$blob"]=$size
		else
			echo "WARNING: Could not process blob $blob (type: $type, size: $size)" >&2
		fi
	done < <(printf "%s\n" "${unique_shas[@]}" | git -C "$repo_root" cat-file --batch-check='%(objectname) %(objectsize) %(objecttype)' 2>/dev/null)

	for sha in "${unique_shas[@]}"; do
		[[ -v "blob_to_size[$sha]" ]] || blob_to_size["$sha"]=0
	done
	readonly -A blob_to_size

	for blob_hash in "${!blob_to_size[@]}"; do
		blob_to_size_pretty["$blob_hash"]=$(format_size "${blob_to_size[$blob_hash]}")
	done
	readonly -A blob_to_size_pretty
	echo "done." >&2

	# --- Stage 2: Apply Name Filters ---
	echo -n "Applying name filters... " >&2
	local -a paths_after_include=()
	local rel_path full_path

	# Pass 1: Inclusion filter (allow-list)
	if ((include_pattern_arg_set)); then
		for rel_path in "${!path_to_blob[@]}"; do
			full_path="$rel_path"
			if [[ "$subdir_rel" != "." ]]; then
				full_path="${subdir_rel}/${rel_path}"
			fi

			if [[ "$full_path" =~ $include_pattern_arg ]]; then
				paths_after_include+=("$rel_path")
			else
				path_is_rejected_by_include["$rel_path"]=1
			fi
		done
	else
		# If no include filter, all initial candidates pass this stage.
		mapfile -t paths_after_include < <(printf '%s\n' "${!path_to_blob[@]}")
	fi

	# Pass 2: Exclusion filter (block-list)
	if ((exclude_pattern_arg_set)); then
		for rel_path in "${paths_after_include[@]}"; do
			full_path="$rel_path"
			if [[ "$subdir_rel" != "." ]]; then
				full_path="${subdir_rel}/${rel_path}"
			fi

			if [[ "$full_path" =~ $exclude_pattern_arg ]]; then
				path_is_rejected_by_exclude["$rel_path"]=1
			else
				path_is_selected_for_analysis["$rel_path"]=1
			fi
		done
	else
		# If no exclude filter, all paths that passed inclusion are selected.
		for rel_path in "${paths_after_include[@]}"; do
			path_is_selected_for_analysis["$rel_path"]=1
		done
	fi
	echo "done." >&2

	readonly -A path_is_rejected_by_include path_is_rejected_by_exclude path_is_selected_for_analysis

	# --- Final Sanity Check and Summary ---
	if ((${#path_is_selected_for_analysis[@]} == 0)); then
		echo "All files were filtered out. No files selected for analysis." >&2
	fi

	echo "Filtering summary:" >&2
	echo "  ◼ Initial candidates:            $initial_candidate_count" >&2
	echo "  ◼ Rejected by --include filter:  ${#path_is_rejected_by_include[@]}" >&2
	echo "  ◼ Rejected by --exclude filter:  ${#path_is_rejected_by_exclude[@]}" >&2
	echo "  ◼ Selected for analysis:         ${#path_is_selected_for_analysis[@]}" >&2
}

###############################################
#### 3. Classification Pipeline & Content Analysis
###############################################

# Path-level classifications (populated for the whole subtree)
declare -A path_is_submodule=()     # [rel_path] -> 1 (Git submodule)
declare -A path_is_symlink=()       # [rel_path] -> 1 (symbolic link)
declare -A path_to_submodule_url=() # [rel_path] -> submodule repository URL

# Path-level classifications (populated only for selected files)
declare -A path_is_binary=()          # [rel_path] -> 1 (marked binary via .gitattributes)
declare -A path_has_lfs=()            # [rel_path] -> 1 (LFS pointer file)
declare -A path_to_lfs_size=()        # [rel_path] -> stored LFS size (bytes)
declare -A path_to_lfs_size_pretty=() # [rel_path] -> formatted LFS size

# Blob-level classifications (populated only for selected blobs)
declare -A blob_has_invalid_utf8=()  # [blob] -> 1 (invalid UTF-8 sequences)
declare -A blob_has_nonprint=()      # [blob] -> 1 (non-printable chars)
declare -A blob_has_nulls=()         # [blob] -> 1 (contains NUL bytes)
declare -A blob_is_oversize=()       # [blob] -> 1 (exceeds size threshold)
declare -A blob_is_safe=()           # [blob] -> 1 (safe for concatenation)
declare -A blob_to_nonprint_count=() # [blob] -> quantity of non-printable chars
declare -A blob_to_null_count=()     # [blob] -> number of NUL bytes
declare -A blob_to_symlink=()        # [blob] -> resolved target path (symlinks)

### Path Normalization
normalize_path() {
	local path="$1"
	path="${path/#\//}"  # Remove leading slash
	path="${path/#.\//}" # Remove leading ./
	echo "$path" | sed -e 's#//\+#/#g' -e 's#/$##'
}

### Submodule Detection
detect_submodules() {
	echo -n "Detecting submodules in subtree... " >&2

	# This runs on ALL paths in the subtree to build a complete inventory.
	# The reporting stage will then determine if a submodule was included or excluded.
	for rel_path in "${!path_to_mode[@]}"; do
		if [[ "${path_to_mode[$rel_path]}" == "160000" ]]; then
			path_is_submodule["$rel_path"]=1
			path_to_submodule_url["$rel_path"]=$(git config -f <(
				git cat-file blob "$ref_hash:.gitmodules" 2>/dev/null || echo ""
			) --get "submodule.$rel_path.url" 2>/dev/null | head -n1)
			: "${path_to_submodule_url["$rel_path"]:="<unknown>"}"
		fi
	done
	readonly -A path_is_submodule path_to_submodule_url # Fully populated

	echo "done (${#path_is_submodule[@]} found)." >&2
}

### Symlink Detection
detect_symlinks() {
	echo -n "Detecting symlinks in subtree... " >&2

	# This runs on ALL paths to build a complete inventory.
	local -a symlink_paths=()
	for rel_path in "${!path_to_mode[@]}"; do
		if [[ "${path_to_mode[$rel_path]}" == "120000" ]]; then
			path_is_symlink["$rel_path"]=1
			symlink_paths+=("$rel_path")
		fi
	done

	if [[ ${#symlink_paths[@]} -eq 0 ]]; then
		readonly -A path_is_symlink blob_to_symlink
		echo "done (0 found)." >&2
		return
	fi

	local -a unique_shas=()
	for rel_path in "${symlink_paths[@]}"; do
		unique_shas+=("${path_to_blob[$rel_path]}")
	done
	mapfile -t unique_shas < <(printf "%s\n" "${unique_shas[@]}" | sort -u)

	while IFS= read -r -d '' header; do
		if [[ "$header" =~ ^([0-9a-f]{40})\ blob\ ([0-9]+)$ ]]; then
			local sha="${BASH_REMATCH[1]}" size="${BASH_REMATCH[2]}" content
			if ((size > 0)); then
				read -r -N "$size" content
				read -r -N 1 _discard
			else
				content=""
			fi
			blob_to_symlink["$sha"]="${content:-<invalid-symlink>}"
		fi
	done < <(printf "%s\0" "${unique_shas[@]}" | git -C "$repo_root" cat-file --batch --buffer -z)

	readonly -A path_is_symlink blob_to_symlink
	echo "done (${#path_is_symlink[@]} found)." >&2
}

### Attribute Processing
collect_attribute_data() {
	# This operates ONLY on the final set of files selected for analysis.
	if [[ ${#path_is_selected_for_analysis[@]} -eq 0 ]]; then
		echo "Skipping Git attributes scan: no files selected." >&2
		return
	fi

	echo -n "Scanning Git attributes for selected files... " >&2
	local path rel_path remaining

	# Use the keys of the selected files map as input for check-attr
	local -a selected_paths=("${!path_is_selected_for_analysis[@]}")

	while IFS= read -d $'\0' -r line; do
		path="${line%%$'\n'*}"
		remaining="${line#*$'\n'}"
		# The path returned by check-attr is already the relative path we need.
		rel_path=$(normalize_path "$path")

		# Ensure this path is one we are actually processing
		[[ -v path_is_selected_for_analysis["$rel_path"] ]] || continue

		while [[ "$remaining" =~ ([^:]+):\ ([^\n]+)(\n|$) ]]; do
			case "${BASH_REMATCH[1],,}" in
			filter)
				[[ "${BASH_REMATCH[2],,}" == *lfs* ]] &&
					path_has_lfs["$rel_path"]=1
				;;
			diff)
				[[ "${BASH_REMATCH[2],,}" == "binary" ]] &&
					path_is_binary["$rel_path"]=1
				;;
			esac
			remaining="${remaining#*"${BASH_REMATCH[0]}"}"
		done
	done < <(git -C "$repo_root" check-attr --cached --all -z -- "${selected_paths[@]}")
	readonly -A path_has_lfs path_is_binary # Fully populated

	echo "completed." >&2
	((${#path_has_lfs[@]} > 0)) && echo "  ◼ Found ${#path_has_lfs[@]} LFS pointers" >&2
	((${#path_is_binary[@]} > 0)) && echo "  ◼ Found ${#path_is_binary[@]} binary-marked files" >&2
}

### LFS Processing
capture_path_to_lfs_size() {
	((${#path_has_lfs[@]} == 0)) && return

	echo -n "Capturing LFS sizes... " >&2

	local -a lfs_blobs=()
	for rel_path in "${!path_has_lfs[@]}"; do
		lfs_blobs+=("${path_to_blob[$rel_path]}")
	done
	mapfile -t lfs_blobs < <(printf "%s\n" "${lfs_blobs[@]}" | sort -u)

	printf "%s\n" "${lfs_blobs[@]}" |
		git -C "$repo_root" cat-file --batch |
		perl -0n -e '
            while(/^([0-9a-f]{40}) blob (\d+)\x00.*?\nsize (\d+)\n/sg) {
                print "$1 $3\n";
            }
        ' | while read -r blob stored_size; do
		for rel_path in "${!path_has_lfs[@]}"; do
			if [[ "${path_to_blob[$rel_path]}" == "$blob" ]]; then
				path_to_lfs_size["$rel_path"]=$((stored_size))
			fi
		done
	done

	for rel_path in "${!path_has_lfs[@]}"; do
		[[ -v path_to_lfs_size["$rel_path"] ]] || path_to_lfs_size["$rel_path"]=0
	done
	readonly -A path_to_lfs_size

	for rel_path in "${!path_to_lfs_size[@]}"; do
		path_to_lfs_size_pretty["$rel_path"]=$(format_size "${path_to_lfs_size[$rel_path]}")
	done
	readonly -A path_to_lfs_size_pretty

	echo "done" >&2
}

### Content Analysis
analyze_content_safety() {
	local -a check_blobs=("$@")
	((${#check_blobs[@]} == 0)) && return

	echo -n "Analyzing content safety for candidate blobs... " >&2

	while read -r blob null_count nonprint_count is_valid_utf8; do
		if ((null_count > 0)); then
			blob_has_nulls["$blob"]=1
			blob_to_null_count["$blob"]=$null_count
		elif ((is_valid_utf8 == 0)); then
			blob_has_invalid_utf8["$blob"]=1
		elif ((nonprint_count > 0)); then
			blob_has_nonprint["$blob"]=$nonprint_count
			blob_to_nonprint_count["$blob"]=$nonprint_count
		fi
	done < <(
		printf "%s\n" "${check_blobs[@]}" |
			git -C "$repo_root" cat-file --batch |
			perl -e '
            use strict;
            use warnings;
            use Encode qw(decode FB_CROAK);

            while (1) {
                my $header = <STDIN>;
                last unless defined $header;
                next unless $header =~ /^([0-9a-f]{40}) blob (\d+)\n/;

                my ($blob, $size) = ($1, $2);
                my $content;
                my $bytes_read = read(STDIN, $content, $size);
                read(STDIN, my $newline, 1);

                my $null_count = $content =~ tr/\x00//;
                my $nonprint_count = 0;
                my $is_valid_utf8 = 1;

                eval {
                    my $decoded = decode("UTF-8", $content, FB_CROAK);
                    $nonprint_count = () = $decoded =~ /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g;
                };
                if ($@) {
                    $is_valid_utf8 = 0;
                    $nonprint_count = -1;
                }

                printf "%s %d %d %d\n", $blob, $null_count, $nonprint_count, $is_valid_utf8;
            }
        '
	)
	readonly -A blob_has_nulls blob_has_invalid_utf8 blob_has_nonprint blob_to_null_count blob_to_nonprint_count

	echo "done (${#check_blobs[@]} blobs)." >&2
}

### Classification Workflow
process_files() {
	local -i file_count=${#path_is_selected_for_analysis[@]}
	echo "Processing ${file_count} selected files:" >&2

	# Step 1: Detect special file types across the entire subtree for complete context
	detect_submodules
	detect_symlinks

	# Step 2: Collect specific attributes (LFS, etc.) only for the final set of files
	collect_attribute_data
	capture_path_to_lfs_size

	# Step 3: Identify blobs that are candidates for deep content analysis
	declare -A blob_is_candidate=()
	for rel_path in "${!path_is_selected_for_analysis[@]}"; do
		# Skip special file types that are not eligible for content analysis
		if [[ -v path_is_submodule["$rel_path"] ]] ||
			[[ -v path_is_symlink["$rel_path"] ]] ||
			[[ -v path_has_lfs["$rel_path"] ]] ||
			[[ -v path_is_binary["$rel_path"] ]]; then
			continue
		fi

		local blob_hash="${path_to_blob[$rel_path]}"
		local size="${blob_to_size[$blob_hash]}"

		if ((size > max_file_size_arg)); then
			blob_is_oversize["$blob_hash"]=1
		else
			blob_is_candidate["$blob_hash"]=1
		fi
	done
	readonly -A blob_is_oversize

	# Step 4: Analyze content safety only for the candidate blobs
	analyze_content_safety "${!blob_is_candidate[@]}"

	# Step 5: Classify blobs as safe for concatenation
	for blob_hash in "${!blob_is_candidate[@]}"; do
		if [[ -v blob_is_oversize["$blob_hash"] ]] ||
			[[ -v blob_has_nulls["$blob_hash"] ]] ||
			[[ -v blob_has_invalid_utf8["$blob_hash"] ]] ||
			[[ -v blob_has_nonprint["$blob_hash"] ]]; then
			continue
		else
			blob_is_safe["$blob_hash"]=1
		fi
	done
	readonly -A blob_is_safe

	echo "Content analysis summary:" >&2
	echo "  ◼ Blobs oversized:      ${#blob_is_oversize[@]}" >&2
	echo "  ◼ Blobs with nulls:     ${#blob_has_nulls[@]}" >&2
	echo "  ◼ Blobs with invalid UTF8: ${#blob_has_invalid_utf8[@]}" >&2
	echo "  ◼ Blobs with non-print: ${#blob_has_nonprint[@]}" >&2
	echo "  ◼ Blobs safe for concat:  ${#blob_is_safe[@]}" >&2
}

################################################
#### 4. Report Generation & Output
################################################

### I. Presentation Layer
# Purpose: Manage visual rendering mechanics for terminal environments

# Buffer Controllers
declare INTRODUCTION_BUFFER=""
declare CONCLUSION_BUFFER=""
declare current_buffer=""

buffer_append() {
	# Non-destructive write accumulator
	local append_text
	if [ $# -ge 1 ]; then
		append_text="$1"
	else
		append_text=$(tr -d '\0\r' <&0)
	fi

	if [[ "$current_buffer" == "INTRODUCTION" ]]; then
		INTRODUCTION_BUFFER+="$append_text"$'\n'
	elif [[ "$current_buffer" == "CONCLUSION" ]]; then
		CONCLUSION_BUFFER+="$append_text"$'\n'
	else
		fail_with 40 "buffer_append: unknown buffer '$current_buffer'"
	fi
}

# ANSI Orchestrator
declare -A COLORS=(
	[header]="1;36"     # Cyan
	[section]="1;34"    # Blue
	[good]="1;32"       # Green
	[warn]="1;33"       # Yellow
	[bad]="1;31"        # Red
	[neutral]="90"      # Gray
	[detail]="38;5;245" # Light gray
)
readonly -A COLORS # Theme registry, set once

apply_color() {
	# Dynamic escape sequence injector
	local text="$1" color="$2"
	((color_enabled)) && printf "\033[${color}m%s\033[0m" "$text" || printf "%s" "$text"
}

# Box-Drawing Engine
declare -A BOX_CHARS=(
	[line_double]='='
	[line_single]='-'
	[diamond]='*'
	[corner_tl]='#'
	[corner_tr]='#'
	[vertical]='|'
)
readonly -A BOX_CHARS # Glyph palette, set once

add_divider() {
	# Responsive rule generator
	local char="$1" width="${2:-80}" color="${3:-neutral}"
	buffer_append "$(apply_color "$(printf "%${width}s" | tr ' ' "$char")" "${COLORS[$color]}")"
}

add_header() {
	# Multi-width title decorator
	local title="$1" color="header"
	add_divider "${BOX_CHARS[line_double]}" 80 "$color"
	buffer_append "$(apply_color "  ${title}" "${COLORS[$color]}")"
	add_divider "${BOX_CHARS[line_double]}" 80 "$color"
}

add_section() {
	# Section title with divider
	local title="$1" color="section"
	buffer_append "\n$(apply_color " ${BOX_CHARS[diamond]} ${title}" "${COLORS[$color]}")"
	add_divider "${BOX_CHARS[line_single]}" 80 "$color"
}

add_stat_row() {
	# Formatted statistic row
	local label="$1" value="$2" color="${3:-neutral}"
	buffer_append "$(printf "  %-35s %s" "$(apply_color "${label}" "${COLORS[$color]}")" "${value}")"
}

# Tree Renderer
render_tree() {
	# Hierarchical FS visualization
	add_section "COMMIT FILE TREE STRUCTURE"

	local tree_output
	tree_output=$(
		export SUBDIR_REL="$subdir_rel"
		git -C "$repo_root" ls-tree -r -z --full-name "$root_tree_hash" |
			perl -e '
            use strict;
            use warnings;

            my %tree;
            local $/ = "\0";
            my $subdir_rel = $ENV{SUBDIR_REL} // ".";
            $subdir_rel =~ s{/$}{};

            while (<>) {
                next unless /^(\d+)\s+(\w+)\s+([0-9a-f]+)\t(.*)\z/;
                my ($mode, $type, $sha, $path) = ($1, $2, $3, $4);
                $path =~ s/\0$//;
                my $entry_type = ($type eq "tree") ? "directory" : "file";
                my @parts = split m|/|, $path;
                my $node = \%tree;

                for my $i (0 .. $#parts) {
                    my $part = $parts[$i];
                    if ($i == $#parts) {
                        $node->{$part} = {
                            type => $entry_type,
                            mode => $mode,
                            ($entry_type eq "directory" ? (children => {}) : ())
                        };
                    } else {
                        $node->{$part} //= {
                            type => "directory",
                            children => {}
                        };
                        $node = $node->{$part}{children};
                    }
                }
            }

            sub render {
                my ($node, $prefix, $current_path) = @_;
                $current_path //= "";
                my @dirs = grep { $node->{$_}{type} eq "directory" } keys %$node;
                my @files = grep { $node->{$_}{type} ne "directory" } keys %$node;
                my @sorted_dirs = sort { lc($a) cmp lc($b) } @dirs;
                my @sorted_files = sort { lc($a) cmp lc($b) } @files;
                my @entries = (@sorted_dirs, @sorted_files);

                for my $i (0 .. $#entries) {
                    my $name = $entries[$i];
                    my $current = $node->{$name};
                    my $is_last = ($i == $#entries);
                    my $branch = $is_last ? "└── " : "├── ";
                    my $display = $name;
                    my $child_path = $current_path ? "$current_path/$name" : $name;
                    my $mode = $current->{mode} // "------";

                    if ($current->{type} eq "directory") {
                        $display .= "/";
                        if ($child_path ne "." && $child_path eq $subdir_rel) {
                            $display .= " (selected subtree)";
                        }
                        print sprintf("%6s %s%s\n", $mode, $prefix, $branch . $display);
                        my $new_prefix = $prefix . ($is_last ? "    " : "│   ");
                        render($current->{children}, $new_prefix, $child_path);
                    } else {
                        print sprintf("%6s %s%s\n", $mode, $prefix, $branch . $display);
                    }
                }
            }

            my $display_root = ".";
            if ($subdir_rel eq ".") {
                $display_root .= " (selected subtree)";
            }
            print sprintf("%6s %s\n", "040000", $display_root);
            render(\%tree, "", "");
        '
	)
	readonly tree_output # Local and final

	buffer_append "$tree_output"
	add_divider "${BOX_CHARS[line_single]}" 80 "detail"
}

### II. Data Formatters & Calculators
# Purpose: Transform raw metrics into human/CLI-consumable formats

format_size() {
	# Dynamic byte scaling (B→TiB)
	local bytes="${1:-0}"
	((bytes == 0)) && {
		echo "0.0B (0 bytes)"
		return
	}
	printf "%s (%s bytes)" \
		"$(numfmt --to=iec --format="%.1f" --padding=7 "$bytes")" \
		"$(numfmt --grouping "$bytes")"
}

format_count() {
	# Percentage/ratio calculator with safe division
	local count="$1" total="$2"
	((total > 0)) && printf "%s (%.1f%%)" "$count" "$(bc <<<"scale=2; $count * 100 / $total")" || echo "$count"
}

### III. Report Data Pipeline
# Purpose: Curate and validate analysis results for output

declare -A report_data=()
collect_report_data() {
	# Aggregate metrics for the final set of selected files
	local -i total_size=0
	for rel_path in "${!path_is_selected_for_analysis[@]}"; do
		local blob_hash="${path_to_blob[$rel_path]}"
		((total_size += blob_to_size["$blob_hash"]))
	done

	local -i lfs_size=0
	for rel_path in "${!path_has_lfs[@]}"; do
		((lfs_size += path_to_lfs_size["$rel_path"]))
	done

	# Count files with issues based on blob_hash properties
	local -i oversize_count=0 null_count=0 invalid_utf8_count=0 nonprint_count=0 concatenatable_count=0
	for rel_path in "${!path_is_selected_for_analysis[@]}"; do
		local blob_hash="${path_to_blob[$rel_path]}"

		if [[ -v blob_is_oversize["$blob_hash"] ]]; then
			((oversize_count++))
		elif [[ -v blob_has_nulls["$blob_hash"] ]]; then
			((null_count++))
		elif [[ -v blob_has_invalid_utf8["$blob_hash"] ]]; then
			((invalid_utf8_count++))
		elif [[ -v blob_has_nonprint["$blob_hash"] ]]; then
			((nonprint_count++))
		elif [[ -v blob_is_safe["$blob_hash"] ]]; then # Eligible for concatenation
			# Only count as concatenatable if it's not a special file type at the path level
			if ! [[ -v path_is_symlink["$rel_path"] ||
				-v path_is_submodule["$rel_path"] ||
				-v path_has_lfs["$rel_path"] ||
				-v path_is_binary["$rel_path"] ]]; then
				((concatenatable_count++))
			fi
		fi
	done

	report_data=(
		[file_counts_initial_candidates]=${#path_to_blob[@]}
		[file_counts_rejected_by_include]=${#path_is_rejected_by_include[@]}
		[file_counts_rejected_by_exclude]=${#path_is_rejected_by_exclude[@]}
		[file_counts_selected]=${#path_is_selected_for_analysis[@]}
		[file_counts_concatenatable]=$concatenatable_count
		[file_counts_submodules]=${#path_is_submodule[@]} # From all subtree files for context
		[file_counts_symlinks]=${#path_is_symlink[@]}     # From all subtree files for context
		[file_counts_lfs]=${#path_has_lfs[@]}             # Only for selected files
		[file_counts_binary]=${#path_is_binary[@]}        # Only for selected files
		[file_counts_null]=$null_count
		[file_counts_invalid_utf8]=$invalid_utf8_count
		[file_counts_nonprint]=$nonprint_count
		[file_counts_oversize]=$oversize_count
		[repo_total_size]=$total_size
		[repo_lfs_size]=$lfs_size
		[max_file_size]="$max_file_size_arg"
	)
	readonly -A report_data # Fully populated
}

### IV. Report Composition Engine
# Purpose: Structured assembly of report components

add_list_with_size() {
	local -n path_map="$1"
	((${#path_map[@]} == 0)) && return

	local -i max_size_len=0
	local rel_path blob_hash formatted_size len
	while IFS= read -r rel_path; do
		blob_hash="${path_to_blob[$rel_path]}"
		formatted_size="${blob_to_size_pretty[$blob_hash]}"
		len=${#formatted_size}
		((len > max_size_len)) && max_size_len=$len
	done < <(printf '%s\n' "${!path_map[@]}" | sort -V)

	while IFS= read -r rel_path; do
		blob_hash="${path_to_blob[$rel_path]}"
		formatted_size="${blob_to_size_pretty[$blob_hash]}"
		buffer_append "$(printf "    - [%-*s] %s" "$max_size_len" "$formatted_size" "$rel_path")"
	done < <(printf '%s\n' "${!path_map[@]}" | sort -V)
}

add_filtering_report() {
	add_section "NAME-BASED FILTERING REPORT"

	local total="${report_data[file_counts_initial_candidates]}"
	add_stat_row "Total files in subtree:" "$total" "neutral"
	add_divider "${BOX_CHARS[line_single]}" 80 "detail"

	# Group 1: Rejected by --include
	local count="${report_data[file_counts_rejected_by_include]}"
	add_stat_row "Rejected by --include filter:" "$(format_count "$count" "$total")" "warn"
	if ((count > 0)); then
		buffer_append "$(apply_color "  » Paths not matching '${include_pattern_arg}':" "${COLORS[detail]}")"
		add_list_with_size path_is_rejected_by_include
	fi

	# Group 2: Rejected by --exclude
	count="${report_data[file_counts_rejected_by_exclude]}"
	add_stat_row "Rejected by --exclude filter:" "$(format_count "$count" "$total")" "warn"
	if ((count > 0)); then
		buffer_append "$(apply_color "  » Paths matching '${exclude_pattern_arg}':" "${COLORS[detail]}")"
		add_list_with_size path_is_rejected_by_exclude
	fi

	# Group 3: Final selected set
	count="${report_data[file_counts_selected]}"
	add_stat_row "Final set for analysis:" "$(format_count "$count" "$total")" "good"
	if ((count > 0)); then
		buffer_append "$(apply_color "  » Paths selected for content analysis:" "${COLORS[detail]}")"
		add_list_with_size path_is_selected_for_analysis
	fi
}

add_file_analysis() {
	local -i total_selected=${report_data[file_counts_selected]}
	((total_selected == 0)) && return

	add_section "CONTENT ANALYSIS REPORT (for ${total_selected} selected files)"

	local -r notice_categories=(
		"concatenatable:Concatenatable Files:${report_data[file_counts_concatenatable]}:good"
		"submodule:Submodules Found:${report_data[file_counts_submodules]}:warn"
		"symlink:Symbolic Links Found:${report_data[file_counts_symlinks]}:warn"
		"lfs:LFS Pointers:${report_data[file_counts_lfs]}:warn"
		"git_binary:Marked as Binary:${report_data[file_counts_binary]}:bad"
		"oversize:Oversized Files:${report_data[file_counts_oversize]}:neutral"
		"null_byte:Files with NULL Bytes:${report_data[file_counts_null]}:neutral"
		"invalid_utf8:Files with Invalid UTF-8:${report_data[file_counts_invalid_utf8]}:neutral"
		"non_printable:Files with Non-Printable Chars:${report_data[file_counts_nonprint]}:neutral"
	)

	local category array_name label count color
	for category in "${notice_categories[@]}"; do
		IFS=':' read -r array_name label count color <<<"$category"
		add_stat_row "${label}:" "$(format_count "$count" "$total_selected")" "${color}"
		if ((count > 0)); then
			case "$array_name" in
			concatenatable) add_details_for_safe_files ;;
			submodule) add_submodule_details ;;
			symlink) add_symlink_details ;;
			lfs) add_lfs_details ;;
			git_binary) add_git_binary_details ;;
			oversize) add_oversize_details ;;
			invalid_utf8) add_invalid_utf8_details ;;
			null_byte) add_null_byte_details ;;
			non_printable) add_nonprint_details ;;
			esac
		fi
	done
}

add_size_analysis() {
	local -i total_selected=${report_data[file_counts_selected]}
	((total_selected == 0)) && return

	add_section "SIZE ANALYSIS (for ${total_selected} selected files)"
	add_stat_row "Total size (selected files):" "$(format_size "${report_data[repo_total_size]}")" "neutral"
	add_stat_row "LFS storage size:" "$(format_size "${report_data[repo_lfs_size]}")" "neutral"
	add_stat_row "Size threshold for content analysis:" "$(format_size "${report_data[max_file_size]}")" "neutral"
}

# --- Detail Rendering Helpers ---

add_submodule_details() {
	while IFS= read -r rel_path; do
		local url="${path_to_submodule_url[$rel_path]}"
		buffer_append "    - ${rel_path} $(apply_color "[🢒 ${url}]" "${COLORS[detail]}")"
	done < <(printf '%s\n' "${!path_is_submodule[@]}" | sort -V)
}

add_symlink_details() {
	while IFS= read -r rel_path; do
		# This uses the previously "unused" blob_to_symlink variable
		local blob_hash="${path_to_blob[$rel_path]}"
		local dest="${blob_to_symlink[$blob_hash]:-<target not found>}"
		buffer_append "    - ${rel_path} $(apply_color "[→ ${dest}]" "${COLORS[detail]}")"
	done < <(printf '%s\n' "${!path_is_symlink[@]}" | sort -V)
}

add_lfs_details() {
	local max_pointer_len=0 max_stored_len=0
	local len_pointer len_stored
	while IFS= read -r rel_path; do
		len_pointer=${#blob_to_size_pretty[${path_to_blob[$rel_path]}]}
		len_stored=${#path_to_lfs_size_pretty[$rel_path]}
		((len_pointer > max_pointer_len)) && max_pointer_len=$len_pointer
		((len_stored > max_stored_len)) && max_stored_len=$len_stored
	done < <(printf '%s\n' "${!path_has_lfs[@]}")

	while IFS= read -r rel_path; do
		# This uses the previously "unused" path_to_lfs_size_pretty variable
		local pointer_formatted stored_formatted
		local padded_pointer padded_stored
		local prefix
		pointer_formatted="${blob_to_size_pretty[${path_to_blob[$rel_path]}]}"
		stored_formatted="${path_to_lfs_size_pretty[$rel_path]}"
		padded_pointer=$(printf "%-*s" "$max_pointer_len" "$pointer_formatted")
		padded_stored=$(printf "%-*s" "$max_stored_len" "$stored_formatted")
		prefix="[pointer: $padded_pointer] [stored: $padded_stored]"
		buffer_append "    - ${prefix} ${rel_path}"
	done < <(printf '%s\n' "${!path_has_lfs[@]}" | sort -V)
}

add_git_binary_details() {
	add_list_with_size path_is_binary
}

add_oversize_details() {
	declare -A target_paths
	while IFS= read -r rel_path; do
		if [[ -v "blob_is_oversize[${path_to_blob[$rel_path]}]" ]]; then
			target_paths["$rel_path"]=1
		fi
	done < <(printf '%s\n' "${!path_is_selected_for_analysis[@]}")
	add_list_with_size target_paths
}

add_invalid_utf8_details() {
	declare -A target_paths
	while IFS= read -r rel_path; do
		if [[ -v "blob_has_invalid_utf8[${path_to_blob[$rel_path]}]" ]]; then
			target_paths["$rel_path"]=1
		fi
	done < <(printf '%s\n' "${!path_is_selected_for_analysis[@]}")
	add_list_with_size target_paths
}

add_details_for_safe_files() {
	declare -A target_paths
	while IFS= read -r rel_path; do
		local blob_hash="${path_to_blob[$rel_path]}"
		if [[ -v "blob_is_safe[$blob_hash]" ]] && ! [[ -v path_is_symlink["$rel_path"] || -v path_is_submodule["$rel_path"] || -v path_has_lfs["$rel_path"] || -v path_is_binary["$rel_path"] ]]; then
			target_paths["$rel_path"]=1
		fi
	done < <(printf '%s\n' "${!path_is_selected_for_analysis[@]}")
	add_list_with_size target_paths
}

add_null_byte_details() {
	local -i max_size_len=0 max_additional_len=0 max_count=0
	declare -A target_paths

	while IFS= read -r rel_path; do
		local blob_hash="${path_to_blob[$rel_path]}"
		if [[ -v "blob_has_nulls[$blob_hash]" ]]; then
			target_paths["$rel_path"]=1
			local count=${blob_to_null_count[$blob_hash]:-0}
			((count > max_count)) && max_count=$count
		fi
	done < <(printf '%s\n' "${!path_is_selected_for_analysis[@]}")

	local count_width=${#max_count}
	local len_size
	local additional
	local len_additional

	while IFS= read -r rel_path; do
		len_size=${#blob_to_size_pretty[${path_to_blob[$rel_path]}]}
		((len_size > max_size_len)) && max_size_len=$len_size
		local count=${blob_to_null_count[${path_to_blob[$rel_path]}]}
		additional=$(printf "NULL ×%${count_width}d" "$count")
		len_additional=${#additional}
		((len_additional > max_additional_len)) && max_additional_len=$len_additional
	done < <(printf '%s\n' "${!target_paths[@]}")

	while IFS= read -r rel_path; do
		local blob_hash="${path_to_blob[$rel_path]}"
		local formatted_size count
		local padded_size padded_additional
		formatted_size="${blob_to_size_pretty[$blob_hash]}"
		count="${blob_to_null_count[$blob_hash]}"
		padded_size=$(printf "%-*s" "$max_size_len" "$formatted_size")
		additional=$(printf "NULL ×%${count_width}d" "$count")
		padded_additional=$(printf "%-*s" "$max_additional_len" "$additional")
		buffer_append "    - [${padded_size}] [${padded_additional}] ${rel_path}"
	done < <(printf '%s\n' "${!target_paths[@]}" | sort -V)
}

add_nonprint_details() {
	local -i max_size_len=0 max_additional_len=0 max_count=0
	declare -A target_paths

	while IFS= read -r rel_path; do
		local blob_hash="${path_to_blob[$rel_path]}"
		if [[ -v "blob_has_nonprint[$blob_hash]" ]]; then
			target_paths["$rel_path"]=1
			local count=${blob_to_nonprint_count[$blob_hash]:-0}
			((count > max_count)) && max_count=$count
		fi
	done < <(printf '%s\n' "${!path_is_selected_for_analysis[@]}")

	local count_width=${#max_count}
	local len_size
	local additional
	local len_additional

	while IFS= read -r rel_path; do
		len_size=${#blob_to_size_pretty[${path_to_blob[$rel_path]}]}
		((len_size > max_size_len)) && max_size_len=$len_size
		local count=${blob_to_nonprint_count[${path_to_blob[$rel_path]}]}
		additional=$(printf "NONPRINT ×%${count_width}d" "$count")
		len_additional=${#additional}
		((len_additional > max_additional_len)) && max_additional_len=$len_additional
	done < <(printf '%s\n' "${!target_paths[@]}")

	while IFS= read -r rel_path; do
		local blob_hash="${path_to_blob[$rel_path]}"
		local formatted_size count
		local padded_size padded_additional
		formatted_size="${blob_to_size_pretty[$blob_hash]}"
		count="${blob_to_nonprint_count[$blob_hash]}"
		padded_size=$(printf "%-*s" "$max_size_len" "$formatted_size")
		additional=$(printf "NONPRINT ×%${count_width}d" "$count")
		padded_additional=$(printf "%-*s" "$max_additional_len" "$additional")
		buffer_append "    - [${padded_size}] [${padded_additional}] ${rel_path}"
	done < <(printf '%s\n' "${!target_paths[@]}" | sort -V)
}

### V. Output Controller
# Purpose: Final rendering pipeline orchestration

output_intro() {
	# Initial report metadata
	add_header "GIT SUBTREE ANALYSIS REPORT"
	buffer_append "$(apply_color " ▸ Repository Root:   " "${COLORS[detail]}")$repo_root"
	buffer_append "$(apply_color " ▸ Target Subtree:    " "${COLORS[detail]}")${subdir_rel:-/}"
	local ref_display_string=""
	if ((git_ref_arg_set)); then
		ref_display_string="${ref_hash:0} (from user, ref: '${git_ref_arg}')"
	else
		ref_display_string="${ref_hash:0} (used default: HEAD)"
	fi
	buffer_append "$(apply_color " ▸ Tree Reference:       " "${COLORS[detail]}")${ref_display_string}"
	buffer_append "$(apply_color " ▸ Inclusion Filter:  " "${COLORS[detail]}")'${include_pattern_arg:-<none>}'  (ERE)"
	buffer_append "$(apply_color " ▸ Exclusion Filter:  " "${COLORS[detail]}")'${exclude_pattern_arg:-<none>}'  (ERE)"
	buffer_append "$(apply_color " ▸ Max File Size:     " "${COLORS[detail]}")$(format_size "${max_file_size_arg}")"
	add_divider "${BOX_CHARS[line_single]}" 80 "detail"
}

output_concatenation_list() {
	((report_data[file_counts_concatenatable] == 0)) && return
	local -a sorted_paths=()

	add_section "CONCATENATION CANDIDATES"
	buffer_append "$(apply_color "  ✓ " "${COLORS[good]}")The following ${report_data[file_counts_concatenatable]} files met all safety criteria:"
	add_divider "${BOX_CHARS[line_single]}" 80 "detail"

	mapfile -t sorted_paths < <(
		for rel_path in "${!path_is_selected_for_analysis[@]}"; do
			local blob_hash="${path_to_blob[$rel_path]}"
			if [[ -v blob_is_safe["$blob_hash"] ]] &&
				! [[ -v path_is_symlink["$rel_path"] ||
					-v path_is_submodule["$rel_path"] ||
					-v path_has_lfs["$rel_path"] ||
					-v path_is_binary["$rel_path"] ]]; then
				echo "$rel_path"
			fi
		done | sort -V
	)

	for path in "${sorted_paths[@]}"; do
		buffer_append "  ⎔ $(apply_color "$path" "${COLORS[neutral]}")"
	done
	buffer_append "\n$(apply_color "  All files shown above will be concatenated in this order." "${COLORS[detail]}")"
	add_divider "${BOX_CHARS[line_single]}" 80 "detail"
}

output_concat() {
	((report_data[file_counts_concatenatable] == 0)) && exit 0
	local -a sorted_paths=()

	mapfile -t sorted_paths < <(
		for rel_path in "${!path_is_selected_for_analysis[@]}"; do
			local blob_hash="${path_to_blob[$rel_path]}"
			if [[ -v blob_is_safe["$blob_hash"] ]] &&
				! [[ -v path_is_symlink["$rel_path"] ||
					-v path_is_submodule["$rel_path"] ||
					-v path_has_lfs["$rel_path"] ||
					-v path_is_binary["$rel_path"] ]]; then
				echo "$rel_path"
			fi
		done | sort -V
	)

	for rel_path in "${sorted_paths[@]}"; do
		local blob_hash="${path_to_blob[$rel_path]}"
		if [[ -z "$blob_hash" ]]; then
			fail_with 41 "Missing blob hash for file to concatenate: $rel_path"
		fi
		printf "\n%s\n" "╭──▶ 𝚏𝚒𝚕𝚎: ${rel_path} ◀──╮" >&1
		if ! git -C "$repo_root" cat-file blob "$blob_hash"; then
			fail_with 134 "cat-file blob ${blob_hash:0:8}"
		fi
		printf "\n%s\n\n" "╰──◈ 𝚎𝚗𝚍: ${rel_path} ◈──╯" >&1
	done
}

output_report() {
	# Orchestrates report generation and output
	current_buffer="INTRODUCTION"
	output_intro
	render_tree

	current_buffer="CONCLUSION"
	collect_report_data
	add_filtering_report
	add_file_analysis
	add_size_analysis

	if ((concatenate_flag)); then
		current_buffer="INTRODUCTION"
		output_concatenation_list
		current_buffer="CONCLUSION"
		echo -e "$INTRODUCTION_BUFFER"
		output_concat
	else
		echo -e "$INTRODUCTION_BUFFER"
	fi
	echo -e "$CONCLUSION_BUFFER"
}

#########################################
#### 5. Data Formatting & Execution Flow
#########################################

### Main Workflow Orchestrator
main() {
	parse_arguments "$@"
	setup_environment
	get_tree_hashes
	hydrate_file_inventory_and_filter
	process_files
	output_report

	if ((report_data[file_counts_selected] > 0 && report_data[file_counts_concatenatable] == 0)); then
		echo "⚠️  Warning: No selected files were eligible for concatenation." >&2
	fi
}

### Post-Execution Information
show_runtime_info() {
	# Resource usage stats
	echo >&2 # Add a newline for clean separation
	add_divider "${BOX_CHARS[line_single]}" 80 "detail" >&2
	echo "  Analyzed content of ${report_data[file_counts_selected]} files (from ${report_data[file_counts_initial_candidates]} total in subtree) in ${SECONDS}s." >&2
}

### Final Execution Flow
# The main function is executed within a subshell to capture its exit status.
# - If main() succeeds (exit 0), show_runtime_info runs, and the script exits cleanly.
# - If a command inside main() fails, `set -e` causes it to exit with a non-zero status.
# - If fail_with() is called, main() exits with the code specified by fail_with.
# The '||' block catches any non-zero exit code ($?).
# We specifically check for exit code 141 (SIGPIPE) to provide a helpful message.
# For all other error codes, fail_with() has already printed the error,
# so we simply propagate the original exit code.
{
	main "$@"
	show_runtime_info
} || {
	ret=$?
	if [[ $ret -eq 141 ]]; then
		fail_with 141
	else
		# fail_with has already run, so just exit with its status code.
		exit "$ret"
	fi
}

exit 0
