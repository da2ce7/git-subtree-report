#!/usr/bin/env bash

# git_subtree_report.sh - Analyze Git repositories and subtrees without filesystem interaction
#
# Version: 1.1.0
# License: AGPLv3
# Author: Cameron Garnham <me@da2ce7.com>
# Repository: https://github.com/da2ce7/git-subtree-report
#
# Usage: git_subtree_report.sh [options]
#
# Options:
#   -e PATTERN    Exclude files matching the given pattern (regex)
#   -r REF        Specify the Git reference to analyze (default: HEAD)
#   -C DIR        Change to the specified directory before performing operations
#   -o            Enable output concatenation of safe text files
#   -t PATH       Specify the relative path to the subtree to analyze
#   -s SIZE       Set the maximum file size for detailed analysis (e.g., 1M, 500K)
#
# Description:
#   This script provides a detailed analysis of Git repositories and subtrees, supporting
#   both standard and bare repositories. It generates a report on file types, sizes, and
#   safety for concatenation, among other metrics.
#
# Requirements:
#   - Bash 5.0 or later
#   - Git 2.20 or later
#   - Perl 5.10 or later
#   - C.UTF-8 locale must be available
#
# Example:
#   git_subtree_report.sh -C /path/to/repo -t sub/dir -e '\.log$' -s 10M
#
#   This analyzes the 'sub/dir' subtree in the repository at '/path/to/repo',
#   excluding files ending with '.log', and only performs detailed analysis on files
#   smaller than 10 megabytes.

###########################################
#### 1. Initialization & Environment Setup
###########################################

### Strict Mode
set -Ceuo pipefail

### Global Configuration
declare -ra UNIX_COMMANDS=(git grep awk tr wc bc numfmt perl sort)

# Constants set at declaration, inherently read-only with -r
declare -ri MIN_PERL_MAJOR=5
declare -ri MIN_PERL_MINOR=10
declare -ri MIN_BASH_MAJOR=5
declare -ri MIN_GIT_MAJOR=2
declare -ri MIN_GIT_MINOR=20

# Color output control
declare -i color_enabled=0 # Disabled by default, updated in check_utf8_locale

declare -i has_working_tree=0        # Repository has a working tree
declare ref_hash                     # Reference SHA
declare repo_root                    # Path to git repo root
declare subdir_rel                   # Relative path to working subtree
declare working_dir                  # Absolute path after -C resolution
declare -i exclude_pattern_arg_set=0 # -e flag state
declare -i context_arg_set=0         # -C flag state
declare -i git_ref_arg_set=0         # -r flag state
declare -i subtree_arg_set=0         # -t flag state

declare -i concatenate_flag=0 # Flag for output concatenation (-o)

declare exclude_pattern_arg=""
declare git_ref_arg="HEAD"
declare context_arg="."
declare subtree_arg="."
declare -i max_file_size_arg=1048576 # Default 1MiB (1MB)

### Argument Parsing
parse_arguments() {
	while getopts ":e:r:C:ot:s:" opt; do
		case $opt in
		e)
			exclude_pattern_arg_set=1
			exclude_pattern_arg="$OPTARG"
			;;
		r)
			git_ref_arg_set=1
			git_ref_arg="$OPTARG"
			;;
		C)
			context_arg_set=1
			context_arg="$OPTARG"
			;;
		o)
			concatenate_flag=1
			;;
		t)
			subtree_arg_set=1
			subtree_arg="$OPTARG"
			# Path validation
			if [[ "$subtree_arg" = /* ]]; then
				echo "ERROR: -t path must be relative" >&2
				exit 130
			fi
			;;
		s)
			if ! max_file_size_arg=$(numfmt --from=iec "$OPTARG"); then
				echo "ERROR: Invalid size format for -s: '$OPTARG'" >&2
				exit 1
			fi
			;;
		\?)
			echo "Invalid option: -$OPTARG" >&2
			exit 1
			;;
		:)
			echo "Option -$OPTARG requires argument" >&2
			exit 1
			;;
		esac
	done
	shift $((OPTIND - 1))

	# Warn for redundant -C .
	if ((context_arg_set)) && [[ "$context_arg" == "." ]]; then
		echo "NOTE: Using default -C . (redundant)" >&2
	fi

	# Set argument variables to read-only after parsing
	readonly exclude_pattern_arg_set git_ref_arg_set context_arg_set subtree_arg_set
	readonly concatenate_flag exclude_pattern_arg git_ref_arg context_arg subtree_arg max_file_size_arg
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
			echo "ERROR: Must operate at repo root when:" >&2
			echo " - Using bare repository" >&2
			echo " - Combining -C and -t flags" >&2
			echo "Current working dir: $working_dir" >&2
			echo "Repo root:          $repo_root" >&2
			exit 129
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
	echo "  └─ Exclusion:  ${exclude_pattern_arg:-<none>}" >&2
}

### Directory Handling
handle_directory_change() {
	echo "Initializing working context: $context_arg" >&2
	if ! cd -- "$context_arg"; then
		echo "ERROR: Failed to establish context (-C)" >&2
		exit 129
	fi
	working_dir=$(pwd -P)
	readonly working_dir # Final value assigned
}

### Repository Validation
check_git_repository() {
	if ! git rev-parse --git-dir 1>/dev/null; then
		echo "Not a git repository" >&2
		exit 129
	fi
}

determine_repo_type() {
	local worktree_status
	if ! worktree_status=$(git rev-parse --is-inside-work-tree); then
		echo "FATAL: Failed to determine repository type" >&2
		exit 1
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
		echo "Invalid repository root" >&2
		exit 129
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

		# RELATIVE PATH VALIDATION
		if [[ "$subdir_rel" == /* ]]; then
			echo "ERROR: -t path must be relative" >&2
			exit 130
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
		# Use the resolved ref_hash, not HEAD
		if ! git ls-tree --name-only "$ref_hash" "$subdir_rel" &>/dev/null; then
			echo "ERROR: Subtree path '$subdir_rel' not found in commit ${ref_hash:0:8}" >&2
			echo "HINT: Use 'git ls-tree HEAD' to see available paths" >&2
			exit 1
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
		echo "ERROR: Path '$subdir_rel' exists but is inaccessible" >&2
		exit 1
	}
	readonly tree_type # Used only here, made read-only to prevent accidental reuse

	if [[ "$tree_type" != "tree" ]]; then
		echo "ERROR: Path '$subdir_rel' is not a directory (found $tree_type)" >&2
		exit 1
	fi
}

### Commit Resolution
resolve_commit() {
	echo "Resolving commit: $git_ref_arg" >&2

	if ! ref_hash=$(git rev-parse "$git_ref_arg"); then
		if ((git_ref_arg_set)) && [[ "$git_ref_arg" != "HEAD" ]]; then
			echo "ERROR: Invalid commit reference: '$git_ref_arg'" >&2
			exit 1
		else
			echo "ERROR: Default HEAD reference is invalid" >&2
			echo "HINT: Check if repository is in valid state" >&2
			exit 1
		fi
	fi

	if ! git cat-file -e "$ref_hash^{commit}"; then
		echo "ERROR: Object $ref_hash exists but is not a commit" >&2
		exit 1
	fi

	readonly ref_hash # Final value assigned
	echo "Resolved commit: ${ref_hash:0:8}" >&2
}

### Utility Validators
check_bash_version() {
	((BASH_VERSINFO[0] >= MIN_BASH_MAJOR)) || {
		echo "Requires Bash v$MIN_BASH_MAJOR+ (current: $BASH_VERSION)" >&2
		exit 1
	}
}

check_git_version() {
	local version_str major minor
	version_str=$(git --version | awk '{gsub(/^v|,.*/,"",$3); print $3}')
	IFS='.' read -r major minor _ <<<"$version_str"
	major=${major:-0}
	minor=${minor:-0}

	if ((major < MIN_GIT_MAJOR || (major == MIN_GIT_MAJOR && minor < MIN_GIT_MINOR))); then
		echo "ERROR: Need Git $MIN_GIT_MAJOR.$MIN_GIT_MINOR+ (found $version_str)" >&2
		exit 1
	fi
}

check_perl_version() {
	local version_str major minor patch
	if ! version_str=$(perl -e 'print $^V' 2>/dev/null); then
		echo "ERROR: Failed to check Perl version" >&2
		exit 1
	fi

	version_str=${version_str#v}
	IFS='.' read -r major minor patch <<<"$version_str"
	major=${major:-0}
	minor=${minor:-0}
	patch=${patch:-0}

	if ((major < MIN_PERL_MAJOR)) ||
		((major == MIN_PERL_MAJOR && minor < MIN_PERL_MINOR)); then
		echo "ERROR: Perl $MIN_PERL_MAJOR.$MIN_PERL_MINOR+ required" >&2
		echo "Found version: $major.$minor.$patch" >&2
		exit 1
	fi
}

check_required_commands() {
	check_bash_version
	for cmd in "${UNIX_COMMANDS[@]}"; do
		command -v "$cmd" >/dev/null || {
			echo "Missing required command: $cmd" >&2
			exit 1
		}
	done
	check_git_version
	check_perl_version
}

check_utf8_locale() {
	if ! locale -a | grep -qiE "C\.(utf-?8|UTF-?8)"; then
		echo "C.UTF-8 locale required (available: $(locale -a | tr '\n' ' '))" >&2
		exit 1
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
	root_tree_hash=$(git -C "$repo_root" rev-parse "${ref_hash}^{tree}") || {
		echo "ERROR: Failed to resolve root tree" >&2
		exit 1
	}
	readonly root_tree_hash # Final value assigned

	if [[ "$subdir_rel" == "." ]]; then
		sub_tree_hash="$root_tree_hash"
		echo "Processing entire repository tree" >&2
	else
		local sub_tree_entry
		sub_tree_entry=$(git -C "$repo_root" ls-tree "$root_tree_hash" "$subdir_rel") || {
			echo "ERROR: Path '$subdir_rel' not found in repository" >&2
			exit 1
		}
		readonly sub_tree_entry # Used only here, locked for safety

		[[ "$(awk '{print $2}' <<<"$sub_tree_entry")" == "tree" ]] || {
			echo "ERROR: '$subdir_rel' is not a directory" >&2
			exit 1
		}
		sub_tree_hash=$(awk '{print $3}' <<<"$sub_tree_entry")

		git -C "$repo_root" cat-file -e "$sub_tree_hash^{tree}" || {
			echo "ERROR: Invalid subtree hash '$sub_tree_hash'" >&2
			exit 1
		}
	fi
	readonly sub_tree_hash # Final value assigned
}

### File Discovery & Filtering

# Path → metadata/status mappings
declare -A path_is_excluded=() # [rel_path] → 1 (filtered by exclusion pattern)
declare -A path_is_included=() # [rel_path] → 1 (passed all filters)

# Path → value mappings
declare -A path_to_blob=() # [rel_path] → blob SHA
declare -A path_to_mode=() # [rel_path] → file mode (e.g. 100644)

# Blob → value mappings
declare -A blob_to_size=()        # [blob] → raw byte count
declare -A blob_to_size_pretty=() # [blob] → human-readable size

collect_path_is_included() {
	echo -n "Collecting file metadata... " >&2

	# Step 1: Collect modes and hashes from ls-tree
	local entry
	while IFS= read -r -d '' entry; do
		IFS=' ' read -r mode type sha _ <<<"${entry%%$'\t'*}"
		if [[ "$type" == "blob" ]]; then
			local rel_path="${entry#*$'\t'}"
			path_to_blob["$rel_path"]=$sha
			path_to_mode["$rel_path"]=$mode
		fi
	done < <(git -C "$repo_root" ls-tree -r -z "$sub_tree_hash")

	local -i original_subtree_files_count=${#path_to_blob[@]}
	echo "found $original_subtree_files_count files" >&2

	# Validate that modes were captured for all blobs
	if [[ ${#path_to_mode[@]} -ne $original_subtree_files_count ]]; then
		echo "ERROR: Mismatch in file modes captured (${#path_to_mode[@]}) vs. blobs ($original_subtree_files_count)" >&2
		exit 1
	fi
	readonly -A path_to_blob path_to_mode # Fully populated

	# Step 2: Collect blob sizes using cat-file --batch-check
	echo "Calculating blob sizes..." >&2

	# Get unique SHAs from path_to_blob
	local -a unique_shas
	mapfile -t unique_shas < <(printf '%s\n' "${path_to_blob[@]}" | sort -u)
	readonly -a unique_shas # Populated and no longer modified

	# Collect sizes for each SHA
	while IFS=' ' read -r blob size type; do
		if [[ "$type" == "blob" && "$size" =~ ^[0-9]+$ ]]; then
			blob_to_size["$blob"]=$size
		else
			echo "WARNING: Could not process blob $blob (type: $type, size: $size)" >&2
		fi
	done < <(
		printf "%s\n" "${unique_shas[@]}" |
			git -C "$repo_root" cat-file --batch-check='%(objectname) %(objectsize) %(objecttype)' 2>/dev/null
	)
	readonly -A blob_to_size # Fully populated

	# Validate that sizes were captured for all unique blobs
	for sha in "${unique_shas[@]}"; do
		if [[ ! -v blob_to_size["$sha"] ]]; then
			echo "ERROR: No size found for blob $sha" >&2
			exit 1
		fi
	done

	# Step 3: Apply exclusion pattern
	echo "Applying exclusion pattern..." >&2
	if ((exclude_pattern_arg_set)); then
		for rel_path in "${!path_to_blob[@]}"; do
			local repo_rel_path="${subdir_rel%/}/${rel_path}"
			[[ "$subdir_rel" == "." ]] && repo_rel_path="$rel_path"
			if [[ "$repo_rel_path" =~ $exclude_pattern_arg ]]; then
				path_is_excluded["$rel_path"]=1
			else
				path_is_included["$rel_path"]=1
			fi
		done
		if [[ ${#path_is_included[@]} -eq 0 ]] && [[ ${#path_is_excluded[@]} -ne 0 ]]; then
			echo "All files excluded by pattern '$exclude_pattern_arg'" >&2
			exit 0
		fi
	else
		for rel_path in "${!path_to_blob[@]}"; do
			path_is_included["$rel_path"]=1
		done
	fi
	readonly -A path_is_included path_is_excluded # Fully populated

	echo "Human formatting blob sizes..." >&2
	for blob_hash in "${!blob_to_size[@]}"; do
		blob_to_size_pretty["$blob_hash"]=$(format_size "${blob_to_size[$blob_hash]}")
	done
	readonly -A blob_to_size_pretty # Fully populated

	echo "done" >&2
	echo "  ◼ Included files: ${#path_is_included[@]}" >&2
	echo "  ◼ Excluded files: ${#path_is_excluded[@]}" >&2
	echo "  ◼ Total modes captured: ${#path_to_mode[@]}" >&2
	echo "  ◼ Total unique blobs: ${#blob_to_size[@]}" >&2
}

###############################################
#### 3. Classification Pipeline & Content Analysis
###############################################

# Path → metadata/status mappings
declare -A path_is_binary=()    # [rel_path] → 1 (marked binary via .gitattributes)
declare -A path_is_submodule=() # [rel_path] → 1 (Git submodule)
declare -A path_is_symlink=()   # [rel_path] → 1 (symbolic link)
declare -A path_has_lfs=()      # [rel_path] → 1 (LFS pointer file)

# Path → value mappings
declare -A path_to_lfs_size=()        # [rel_path] → stored LFS size (bytes)
declare -A path_to_lfs_size_pretty=() # [rel_path] → formatted LFS size
declare -A path_to_submodule_url=()   # [rel_path] → submodule repository URL

# Blob status flags
declare -A blob_has_invalid_utf8=() # [blob] → 1 (invalid UTF-8 sequences)
declare -A blob_has_nonprint=()     # [blob] → 1 (non-printable chars)
declare -A blob_has_nulls=()        # [blob] → 1 (contains NUL bytes)
declare -A blob_is_candidate=()     # [blob] → 1 (eligible for analysis)
declare -A blob_is_oversize=()      # [blob] → 1 (exceeds size threshold)
declare -A blob_is_safe=()          # [blob] → 1 (safe for concatenation)

# Blob → value mappings
declare -A blob_to_nonprint_count=() # [blob] → quantity of non-printable chars
declare -A blob_to_null_count=()     # [blob] → number of NUL bytes
declare -A blob_to_symlink=()        # [blob] → resolved target path (symlinks)

### Path Normalization
normalize_path() {
	local path="$1"
	path="${path/#\//}"  # Remove leading slash
	path="${path/#.\//}" # Remove leading ./
	echo "$path" | sed -e 's#//\+#/#g' -e 's#/$##'
}

### Submodule Detection
detect_submodules() {
	echo -n "Detecting submodules... " >&2

	for rel_path in "${!path_to_mode[@]}"; do
		if [[ "${path_to_mode[$rel_path]}" == "160000" ]]; then
			if [[ -v path_to_blob["$rel_path"] ]]; then
				path_is_submodule["$rel_path"]=1
				path_to_submodule_url["$rel_path"]=$(git config -f <(
					git cat-file blob "$ref_hash:.gitmodules" 2>/dev/null || echo ""
				) --get "submodule.$rel_path.url" 2>/dev/null | head -n1)
				: "${path_to_submodule_url["$rel_path"]:="<unknown>"}"
			else
				echo "WARNING: Submodule path '$rel_path' with mode 160000 not found in path_to_blob" >&2
			fi
		fi
	done
	readonly -A path_is_submodule path_to_submodule_url # Fully populated

	echo "done (${#path_is_submodule[@]} found)" >&2
}

### Symlink Detection
detect_symlinks() {
	echo -n "Detecting symlinks... " >&2

	# Step 1: Collect symlink paths
	for rel_path in "${!path_to_mode[@]}"; do
		if [[ "${path_to_mode[$rel_path]}" == "120000" ]]; then
			if [[ -v path_to_blob["$rel_path"] ]]; then
				path_is_symlink["$rel_path"]=1
			else
				echo "WARNING: No blob hash for symlink path '$rel_path'" >&2
			fi
		fi
	done

	# Step 2: Early exit if no symlinks found
	if [[ ${#path_is_symlink[@]} -eq 0 ]]; then
		readonly -A path_is_symlink blob_to_symlink
		echo "done (0 found)" >&2
		return
	fi

	# Step 3: Get unique SHAs for symlinks
	local -a unique_shas=()
	for rel_path in "${!path_is_symlink[@]}"; do
		unique_shas+=("${path_to_blob[$rel_path]}")
	done
	mapfile -t unique_shas < <(printf "%s\n" "${unique_shas[@]}" | sort -u)
	readonly -a unique_shas

	# Step 4: Populate blob_to_symlink with blob content
	while IFS= read -r -d '' header; do
		if [[ "$header" =~ ^([0-9a-f]{40})\ blob\ ([0-9]+)$ ]]; then
			local sha="${BASH_REMATCH[1]}"
			local size="${BASH_REMATCH[2]}"
			local content
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
	echo "done (${#path_is_symlink[@]} found)" >&2
}

### Cross-Array Validation
validate_path_metadata() {
	local path="$1"
	[[ -v path_to_blob["$path"] ]] || return 1
	[[ -v path_to_mode["$path"] ]] || return 1

	if [[ -v path_has_lfs["$path"] ]]; then
		[[ -v path_to_lfs_size["$path"] ]] || return 1
	fi

	if [[ -v path_is_submodule["$path"] ]]; then
		[[ -v path_to_submodule_url["$path"] ]] || return 1
	fi

	if [[ -v path_is_symlink["$path"] ]]; then
		local blob_hash="${path_to_blob[$path]}"
		[[ -v blob_to_symlink["$blob_hash"] ]] || return 1
	fi

	return 0
}

### Attribute Processing
collect_attribute_data() {
	local path normalized_path rel_path
	[[ ${#path_is_included[@]} -eq 0 ]] && return

	local -a validated_paths=()
	for rel_path in "${!path_is_included[@]}"; do
		validate_path_metadata "$rel_path" && validated_paths+=("$rel_path")
	done
	readonly -a validated_paths # Populated and final

	echo -n "Scanning Git attributes... " >&2

	while IFS= read -d $'\0' -r line; do
		path="${line%%$'\n'*}" remaining="${line#*$'\n'}"
		normalized_path=$(normalize_path "$path")
		rel_path="${normalized_path#"${subdir_rel}/"}"

		[[ -v path_to_blob["$rel_path"] ]] || continue

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
	done < <(git -C "$repo_root" check-attr --cached --all -z -- "${validated_paths[@]}")
	readonly -A path_has_lfs path_is_binary # Fully populated

	echo "completed" >&2
	((${#path_has_lfs[@]} > 0)) && echo "  ◼ Found ${#path_has_lfs[@]} LFS pointers" >&2
	((${#path_is_binary[@]} > 0)) && echo "  ◼ Found ${#path_is_binary[@]} binary-marked files" >&2
}

### LFS Processing
capture_path_to_lfs_size() {
	((${#path_has_lfs[@]} == 0)) && return

	echo -n "Capturing LFS sizes... " >&2

	# Get unique blob hashes for LFS paths
	local -a lfs_blobs=()
	for rel_path in "${!path_has_lfs[@]}"; do
		validate_path_metadata "$rel_path" || continue
		lfs_blobs+=("${path_to_blob[$rel_path]}")
	done
	mapfile -t lfs_blobs < <(printf "%s\n" "${lfs_blobs[@]}" | sort -u)
	readonly -a lfs_blobs

	# Process LFS blob sizes
	printf "%s\n" "${lfs_blobs[@]}" |
		git -C "$repo_root" cat-file --batch |
		perl -0n -e '
            while(/^([0-9a-f]{40}) blob (\d+)\x00.*?\nsize (\d+)\n/sg) {
                print "$1 $3\n";
            }
        ' | while read -r blob stored_size; do
		# Map size back to all paths with this blob
		for rel_path in "${!path_has_lfs[@]}"; do
			if [[ "${path_to_blob[$rel_path]}" == "$blob" ]]; then
				path_to_lfs_size["$rel_path"]=$((stored_size))
			fi
		done
	done

	# Set default size of 0 for any LFS paths not processed
	for rel_path in "${!path_has_lfs[@]}"; do
		[[ -v path_to_lfs_size["$rel_path"] ]] || path_to_lfs_size["$rel_path"]=0
	done
	readonly -A path_to_lfs_size # Fully populated

	# Format LFS sizes
	for rel_path in "${!path_to_lfs_size[@]}"; do
		path_to_lfs_size_pretty["$rel_path"]=$(format_size "${path_to_lfs_size[$rel_path]}")
	done
	readonly -A path_to_lfs_size_pretty # Fully populated

	echo "done" >&2
}

### Content Analysis
analyze_content_safety() {
	local -a check_blobs=("$@")
	((${#check_blobs[@]} == 0)) && return

	echo -n "Analyzing content safety... " >&2

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

	echo "done" >&2
	echo "Processed ${#check_blobs[@]} file blobs:" >&2
	echo "  ◼ Contained null bytes:  ${#blob_has_nulls[@]}" >&2
	echo "  ◼ Contained invalid UTF8:  ${#blob_has_invalid_utf8[@]}" >&2
	echo "  ◼ Non-printable/binary:  ${#blob_has_nonprint[@]}" >&2
}

### Classification Workflow
process_files() {
	echo "Processing ${#path_is_included[@]} files:" >&2

	detect_submodules
	detect_symlinks
	collect_attribute_data
	capture_path_to_lfs_size

	for rel_path in "${!path_is_included[@]}"; do
		if ! validate_path_metadata "$rel_path"; then
			echo "WARNING: Skipping incomplete metadata for: $rel_path" >&2
			unset "path_is_included[$rel_path]"
		fi
	done

	# Step 1: Identify candidate blobs
	declare -A blob_is_candidate=()
	for rel_path in "${!path_is_included[@]}"; do
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
	readonly -A blob_is_oversize blob_is_candidate

	# Step 2: Analyze content safety for candidate blobs
	analyze_content_safety "${!blob_is_candidate[@]}"

	# Step 3: Classify blobs as concatenatable
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

	((${#blob_is_oversize[@]} > 0)) && echo "  ◼ Size exclusions: ${#blob_is_oversize[@]} blobs" >&2
	echo "  ◼ Safe text blobs: ${#blob_is_safe[@]} blobs" >&2
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
		echo "ERROR: unknown buffer: $current_buffer" >&2
		exit 1
	fi
}

buffer_reset() {
	# Stateful buffer clearance
	if [[ "$current_buffer" == "INTRODUCTION" ]]; then
		INTRODUCTION_BUFFER=""
	elif [[ "$current_buffer" == "CONCLUSION" ]]; then
		CONCLUSION_BUFFER=""
	else
		echo "ERROR: unknown buffer: $current_buffer" >&2
		exit 1
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
	buffer_append "$(printf "  %-30s %s" "$(apply_color "${label}" "${COLORS[$color]}")" "${value}")"
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
		echo "[size unavailable]"
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

collect_report_data() {
	# Aggregate metrics
	local -i total_size=0
	for rel_path in "${!path_is_included[@]}"; do
		local blob_hash="${path_to_blob[$rel_path]}"
		if [[ -v blob_to_size["$blob_hash"] ]]; then
			((total_size += blob_to_size["$blob_hash"]))
		else
			echo "WARNING: No size found for blob $blob_hash (path: $rel_path)" >&2
		fi
	done
	readonly total_size # Local and final

	# Count files with issues based on blob_hash properties
	local -i oversize_count=0 null_count=0 invalid_utf8_count=0 nonprint_count=0 concatenatable_count=0

	for rel_path in "${!path_is_included[@]}"; do
		local blob_hash="${path_to_blob[$rel_path]}"

		if [[ -v blob_is_oversize["$blob_hash"] ]]; then
			((oversize_count++))
		elif [[ -v blob_has_nulls["$blob_hash"] ]]; then
			((null_count++))
		elif [[ -v blob_has_invalid_utf8["$blob_hash"] ]]; then
			((invalid_utf8_count++))
		elif [[ -v blob_has_nonprint["$blob_hash"] ]]; then
			((nonprint_count++))
		elif [[ -v blob_is_safe["$blob_hash"] ]]; then
			((concatenatable_count++))
		fi
	done

	declare -gA report_data=(
		[file_counts_total]=${#path_is_included[@]}
		[file_counts_concatenatable]=$concatenatable_count
		[file_counts_submodules]=${#path_is_submodule[@]}
		[file_counts_symlinks]=${#path_is_symlink[@]}
		[file_counts_lfs]=${#path_has_lfs[@]}
		[file_counts_binary]=${#path_is_binary[@]}
		[file_counts_null]=$null_count
		[file_counts_invalid_utf8]=$invalid_utf8_count
		[file_counts_nonprint]=$nonprint_count
		[file_counts_oversize]=$oversize_count
		[repo_total_size]=$total_size
		[repo_lfs_size]=$(
			IFS=+
			echo "$((${path_to_lfs_size[*]}))"
		)
		[max_file_size]="$max_file_size_arg"
		[excluded_count]="${#path_is_excluded[@]}"
	)
	readonly -A report_data # Fully populated
}

validate_report_data() {
	# Metric consistency guards
	local -i error_count=0

	if [[ ! -v report_data[file_counts_total] ]]; then
		echo "ERROR: Critical field missing - total file count not tracked" >&2
		((error_count++))
	else
		if ! [[ "${report_data[file_counts_total]}" =~ ^[0-9]+$ ]]; then
			echo "ERROR: Invalid file count type (non-integer detected)" >&2
			((error_count++))
		elif ((report_data[file_counts_total] < 0)); then
			echo "ERROR: Invalid file count (negative value)" >&2
			((error_count++))
		fi
	fi

	if ((error_count > 0)); then
		echo "CRITICAL: Report validation failed with $error_count errors" >&2
		return 1
	fi
	return 0
}

### IV. Report Composition Engine
# Purpose: Structured assembly of report components

add_summary_section() {
	# Key metrics card
	add_header "GIT SUBTREE ANALYSIS REPORT"
	buffer_append "$(printf "%s %-20s: %s" "${BOX_CHARS[vertical]}" "Repository Root" "$repo_root")"
	buffer_append "$(printf "%s %-20s: %s" "${BOX_CHARS[vertical]}" "Analyzed Path" "${subdir_rel:-/}")"
	buffer_append "$(printf "%s %-20s: %s" "${BOX_CHARS[vertical]}" "Git Commit" "${ref_hash:0:8}")"
	add_divider "${BOX_CHARS[line_single]}" 80 "detail"
	buffer_append "$(printf "%s %-20s: %s" "${BOX_CHARS[vertical]}" "Exclusion Filter" "${exclude_pattern_arg:-<none>}")"
	buffer_append "$(printf "%s %-20s: %s" "${BOX_CHARS[vertical]}" "Processed Files" "${report_data[file_counts_total]}")"
}

add_file_analysis() {
	# File taxonomy breakdown
	local start_time end_time duration
	start_time=$(date +%s.%N)
	add_section "FILE COMPOSITION"

	local -r notice_categories=(
		"concatenatable:Concatenatable:${report_data[file_counts_concatenatable]}:good"
		"submodule:Submodules:${report_data[file_counts_submodules]}:warn"
		"symlink:Symlinks:${report_data[file_counts_symlinks]}:warn"
		"lfs:LFS pointers:${report_data[file_counts_lfs]}:warn"
		"git_binary:Binary files:${report_data[file_counts_binary]}:bad"
		"oversize:Oversized files:${report_data[file_counts_oversize]}:neutral"
		"null_byte:Null byte files:${report_data[file_counts_null]}:neutral"
		"invalid_utf8:Invalid UTF8 files:${report_data[file_counts_invalid_utf8]}:neutral"
		"non_printable:Non-printable files:${report_data[file_counts_nonprint]}:neutral"
	)

	local category array_name label count color
	for category in "${notice_categories[@]}"; do
		IFS=':' read -r array_name label count color <<<"$category"
		add_stat_row "${label}:" "${count}" "${color}"
		if [[ "$count" -gt 0 ]]; then
			buffer_append "$(apply_color "  » ${label}:" "${COLORS[detail]}")"
			case "$array_name" in
			submodule) add_submodule_details "${!path_is_submodule[@]}" ;;
			symlink) add_symlink_details "${!path_is_symlink[@]}" ;;
			concatenatable | git_binary | oversize | invalid_utf8) add_simple_size_details "$array_name" ;;
			lfs) add_lfs_details "${!path_has_lfs[@]}" ;;
			null_byte | non_printable) add_prefix_details "$array_name" ;;
			esac
		fi
	done

	end_time=$(date +%s.%N)
	duration=$(bc -l <<<"$end_time - $start_time")
	echo "add_file_analysis completed in $(printf "%.3f" "$duration") seconds" >&2
}

add_size_analysis() {
	# Storage visualizer
	add_section "SIZE ANALYSIS"
	add_stat_row "Total repository size:" "$(format_size "${report_data[repo_total_size]}")" "neutral"
	add_stat_row "LFS storage size:" "$(format_size "${report_data[repo_lfs_size]}")" "neutral"
	add_stat_row "Size threshold:" "$(format_size "${report_data[max_file_size]}")" "neutral"
}

add_exclusion_details() {
	# Filter coverage analysis
	((report_data[excluded_count] == 0)) && return
	add_section "EXCLUSION DETAILS"
	add_stat_row "Excluded files:" "${report_data[excluded_count]}" "neutral"
	add_stat_row "Included files:" \
		"$(format_count "${report_data[file_counts_concatenatable]}" \
			$((report_data[file_counts_concatenatable] + report_data[excluded_count])))" "neutral"
}

# Dynamic Layout Manager
add_submodule_details() {
	local files=("$@")
	local rel_path url
	while IFS= read -r rel_path; do
		if [[ ! -v path_to_blob["$rel_path"] ]]; then
			echo "ERROR: No blob hash for $rel_path" >&2
			exit 1
		fi
		url="${path_to_submodule_url[$rel_path]}"
		buffer_append "    - ${rel_path} $(apply_color "[🢒 ${url}]" "${COLORS[detail]}")"
	done < <(printf '%s\n' "${files[@]}" | sort)
}

add_symlink_details() {
	local files=("$@")
	local rel_path dest blob_hash
	while IFS= read -r rel_path; do
		if [[ ! -v path_to_blob["$rel_path"] ]]; then
			echo "ERROR: No blob hash for $rel_path" >&2
			exit 1
		fi
		blob_hash="${path_to_blob[$rel_path]}"
		dest="${blob_to_symlink[$blob_hash]}"
		buffer_append "    - ${rel_path} $(apply_color "[→ ${dest}]" "${COLORS[detail]}")"
	done < <(printf '%s\n' "${files[@]}" | sort)
}

add_simple_size_details() {
	local array_name="$1"
	local max_size_len=0 rel_path blob_hash formatted_size len padded_size prefix additional

	# Determine target array
	local target_array
	case "$array_name" in
	concatenatable) target_array="blob_is_safe" ;;
	git_binary) target_array="path_is_binary" ;;
	oversize) target_array="blob_is_oversize" ;;
	invalid_utf8) target_array="blob_has_invalid_utf8" ;;
	*)
		echo "ERROR: Unknown array_name $array_name" >&2
		exit 1
		;;
	esac

	# Collect paths associated with blobs or directly from path-based array
	declare -A target_files=()
	if [[ "$array_name" == "git_binary" ]]; then
		for rel_path in "${!path_is_binary[@]}"; do
			target_files["$rel_path"]=1
		done
	else
		for rel_path in "${!path_is_included[@]}"; do
			blob_hash="${path_to_blob[$rel_path]}"
			if [[ -v "${target_array}[$blob_hash]" ]]; then
				target_files["$rel_path"]=1
			fi
		done
	fi

	# Calculate max size length
	while IFS= read -r rel_path; do
		blob_hash="${path_to_blob[$rel_path]}"
		formatted_size="${blob_to_size_pretty[$blob_hash]}"
		len=${#formatted_size}
		((len > max_size_len)) && max_size_len=$len
	done < <(printf '%s\n' "${!target_files[@]}" | sort)

	# Generate details
	while IFS= read -r rel_path; do
		blob_hash="${path_to_blob[$rel_path]}"
		formatted_size="${blob_to_size_pretty[$blob_hash]}"
		padded_size=$(printf "%-*s" "$max_size_len" "$formatted_size")
		prefix="[$padded_size]"
		additional=$(build_additional "$array_name" "$rel_path")
		buffer_append "    - ${prefix} ${rel_path}${additional:+ $additional}"
	done < <(printf '%s\n' "${!target_files[@]}" | sort)
}

add_lfs_details() {
	local files=("$@")
	local max_pointer_len=0 max_stored_len=0 rel_path blob_hash pointer_formatted stored_formatted len_pointer len_stored padded_pointer padded_stored prefix
	while IFS= read -r rel_path; do
		if [[ ! -v path_to_blob["$rel_path"] ]]; then
			echo "ERROR: No blob hash for $rel_path" >&2
			exit 1
		fi
		blob_hash="${path_to_blob[$rel_path]}"
		pointer_formatted="${blob_to_size_pretty[$blob_hash]}"
		stored_formatted="${path_to_lfs_size_pretty[$rel_path]}"
		len_pointer=${#pointer_formatted}
		len_stored=${#stored_formatted}
		((len_pointer > max_pointer_len)) && max_pointer_len=$len_pointer
		((len_stored > max_stored_len)) && max_stored_len=$len_stored
	done < <(printf '%s\n' "${files[@]}" | sort)

	while IFS= read -r rel_path; do
		blob_hash="${path_to_blob[$rel_path]}"
		pointer_formatted="${blob_to_size_pretty[$blob_hash]}"
		stored_formatted="${path_to_lfs_size_pretty[$rel_path]}"
		padded_pointer=$(printf "%-*s" "$max_pointer_len" "$pointer_formatted")
		padded_stored=$(printf "%-*s" "$max_stored_len" "$stored_formatted")
		prefix="[pointer: $padded_pointer] [stored: $padded_stored]"
		buffer_append "    - ${prefix} ${rel_path}"
	done < <(printf '%s\n' "${files[@]}" | sort)
}

add_prefix_details() {
	local array_name="$1"
	local max_inner_size_len=0 max_inner_additional_len=0
	local rel_path blob_hash formatted_size inner_additional len_inner_size len_inner_additional count_width

	# Determine target array and label
	local label array_ref
	if [[ "$array_name" == "null_byte" ]]; then
		label="NULL"
		array_ref="blob_has_nulls"
	else
		label="NONPRINT"
		array_ref="blob_has_nonprint"
	fi

	# Collect target files
	declare -A target_files=()
	for rel_path in "${!path_is_included[@]}"; do
		blob_hash="${path_to_blob[$rel_path]}"
		[[ -v "${array_ref}[$blob_hash]" ]] && target_files["$rel_path"]=1
	done

	# Calculate max count for width
	local max_count=0
	for rel_path in "${!target_files[@]}"; do
		blob_hash="${path_to_blob[$rel_path]}"
		local count
		if [[ "$array_name" == "null_byte" ]]; then
			count=${blob_to_null_count[$blob_hash]}
		else
			count=${blob_to_nonprint_count[$blob_hash]}
		fi
		((count > max_count)) && max_count=$count
	done
	count_width=${#max_count}

	# Calculate max lengths
	while IFS= read -r rel_path; do
		blob_hash="${path_to_blob[$rel_path]}"
		formatted_size="${blob_to_size_pretty[$blob_hash]}"
		len_inner_size=${#formatted_size}
		((len_inner_size > max_inner_size_len)) && max_inner_size_len=$len_inner_size

		local count
		if [[ "$array_name" == "null_byte" ]]; then
			count=${blob_to_null_count[$blob_hash]}
		else
			count=${blob_to_nonprint_count[$blob_hash]}
		fi
		inner_additional=$(printf "%s ×%${count_width}d" "$label" "$count")
		len_inner_additional=${#inner_additional}
		((len_inner_additional > max_inner_additional_len)) && max_inner_additional_len=$len_inner_additional
	done < <(printf '%s\n' "${!target_files[@]}" | sort)

	# Generate details
	while IFS= read -r rel_path; do
		blob_hash="${path_to_blob[$rel_path]}"
		formatted_size="${blob_to_size_pretty[$blob_hash]}"
		padded_inner_size=$(printf "%-*s" "$max_inner_size_len" "$formatted_size")
		size_part="[${padded_inner_size}]"

		local count
		if [[ "$array_name" == "null_byte" ]]; then
			count=${blob_to_null_count[$blob_hash]}
		else
			count=${blob_to_nonprint_count[$blob_hash]}
		fi
		inner_additional=$(printf "%s ×%${count_width}d" "$label" "$count")
		padded_inner_additional=$(printf "%-*s" "$max_inner_additional_len" "$inner_additional")
		additional_part="[${padded_inner_additional}]"

		prefix="${size_part} ${additional_part}"
		buffer_append "    - ${prefix} ${rel_path}"
	done < <(printf '%s\n' "${!target_files[@]}" | sort)
}

build_additional() {
	# Contextual annotations
	local -r array_name="$1" rel_path="$2"
	case "$array_name" in
	git_binary) apply_color "[binary]" "${COLORS[detail]}" ;;
	*) ;;
	esac
}

### V. Output Controller
# Purpose: Final rendering pipeline orchestration

output_intro() {
	# Initial report metadata
	add_header "GIT SUBTREE CONCATENATION REPORT"
	buffer_append "$(apply_color " ▸ Repository Root: " "${COLORS[detail]}")$repo_root"
	buffer_append "$(apply_color " ▸ Target Subtree:  " "${COLORS[detail]}")${subdir_rel:-/}"
	buffer_append "$(apply_color " ▸ Commit Hash:     " "${COLORS[detail]}")${ref_hash:0:8}"
	buffer_append "$(apply_color " ▸ Exclusion Filter:" "${COLORS[detail]}")${exclude_pattern_arg:-<none>}"
	buffer_append "$(apply_color " ▸ Max File Size:   " "${COLORS[detail]}")$(numfmt --to=iec "$max_file_size_arg")"
	add_divider "${BOX_CHARS[line_single]}" 80 "detail"
}

output_concatenation_list() {
	# Concatenation preview
	((${#blob_is_safe[@]} == 0)) && return
	local count_text
	local -a sorted_paths=()
	local -i total_blobs=${#blob_is_safe[@]}
	count_text="$(apply_color "$total_blobs" "${COLORS[good]}") blobs found"

	add_section "CONCATENATION CANDIDATES"
	buffer_append "$(apply_color "  ✓ " "${COLORS[good]}")The following $count_text met all safety criteria:"
	add_divider "${BOX_CHARS[line_single]}" 80 "detail"

	# Collect all paths associated with concatenatable blobs
	declare -A concat_paths=()
	for rel_path in "${!path_is_included[@]}"; do
		blob_hash="${path_to_blob[$rel_path]}"
		if [[ -v blob_is_safe["$blob_hash"] ]]; then
			concat_paths["$rel_path"]=1
		fi
	done
	mapfile -t sorted_paths < <(printf "%s\n" "${!concat_paths[@]}" | sort -V)
	readonly -a sorted_paths

	for path in "${sorted_paths[@]}"; do
		buffer_append "  ⎔ $(apply_color "$path" "${COLORS[neutral]}")"
	done
	buffer_append "\n$(apply_color "  All files shown above will be concatenated in this order." "${COLORS[detail]}")"
	add_divider "${BOX_CHARS[line_single]}" 80 "detail"
}

output_concat() {
	# Safe file sequencer
	((${#blob_is_safe[@]} == 0)) && exit 0
	local -a sorted_paths=()

	# Collect all paths associated with concatenatable blobs
	declare -A concat_paths=()
	for rel_path in "${!path_is_included[@]}"; do
		blob_hash="${path_to_blob[$rel_path]}"
		if [[ -v blob_is_safe["$blob_hash"] ]]; then
			concat_paths["$rel_path"]=1
		fi
	done
	mapfile -t sorted_paths < <(printf '%s\n' "${!concat_paths[@]}" | sort -V)
	readonly -a sorted_paths

	for rel_path in "${sorted_paths[@]}"; do
		local blob_hash="${path_to_blob[$rel_path]}"
		if [[ -z "$blob_hash" ]]; then
			echo "ERROR: Missing blob hash for path '$rel_path'" >&2
			exit 129
		fi
		printf "\n%s\n" "╭──▶ 𝚏𝚒𝚕𝚎: ${rel_path} ◀──╮" >&1
		if ! git -C "$repo_root" cat-file blob "$blob_hash"; then
			echo "ERROR: Failed to retrieve '$rel_path' (blob: ${blob_hash:0:8})" >&2
			exit 1
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
	add_summary_section
	add_file_analysis
	add_size_analysis
	add_exclusion_details
	validate_report_data || exit 1

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
	collect_path_is_included
	process_files
	output_report

	[[ ${#blob_is_safe[@]} -eq 0 ]] &&
		echo "⚠️  Warning: No blobs passed safety checks" >&2
}

### Error and Pipe Message Formatting
trap 'echo "‼️  Critical failure at line $LINENO. Check stderr." >&2; exit 2' ERR
trap 'echo "‼️  Unexpected pipe failure" >&2; exit 141' PIPE

show_runtime_info() {
	# Resource usage stats
	echo "Processed ${#path_is_included[@]} files" >&2
	echo "Completed in ${SECONDS} seconds" >&2
}

### Final Execution Flow
{
	time main "$@"
	show_runtime_info
} && exit 0 || exit 3
