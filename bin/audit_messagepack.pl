#!/usr/bin/env perl
# --- Architectural Choice: Portability. `env` ensures our script uses the user's
# configured Perl, not a system default, making it robust across diverse environments.

# audit_messagepack.pl

use v5.36;
# --- Architectural Choice: Modernity & Safety Baseline. We mandate a recent Perl
# version to guarantee a consistent, modern feature set. This implicitly enforces
# `strict` and `warnings`, establishing a non-negotiable contract for code quality.

use strict;
use warnings;
# --- Architectural Choice: Explicit Declaration. While implied by `v5.36`, we state
# these explicitly for maximum clarity. This leaves no ambiguity about our commitment
# to safe, robust code.

use autodie;
# --- Architectural Choice: Runtime Robustness. This pragma transforms silent I/O
# failures (e.g., failed `open`) into fatal exceptions. This is a deliberate
# design decision to enforce immediate, explicit error handling and eliminate a
# common class of latent bugs.

use feature 'try', 'signatures';
no warnings 'experimental::try', 'experimental::signatures';
# --- Architectural Choice: Improved Readability & Maintainability. We deliberately
# opt-in to modern syntax (`try/catch` & signatures) to produce cleaner, more
# self-documenting code, accepting a trade-off against compatibility with older,
# unmaintained Perl versions.

# --- The Framework: A curated stack of best-in-class CPAN modules.

# --  CLI Contract & User Interface --
use Getopt::Long qw(GetOptionsFromArray :config pass_through);
use Pod::Usage qw(pod2usage);
# --- Technical Choice: We use this pair to build a standard, self-documenting
# CLI compliant with user expectations. `GetOptionsFromArray` is specifically
# chosen to facilitate straightforward unit testing of the CLI parsing logic.

# --  Core Data Handling & Validation --
use Data::MessagePack;
# --- Technical Choice: The fundamental driver for our primary responsibility:
# deserializing the binary input format.
use YAML::XS qw(Load);
# --- Technical Choice: YAML is chosen for the embedded schema due to its superior
# human-readability and support for comments, making the schema itself more
# maintainable. The 'XS' version is a performance optimization.
use JSON::Schema::Modern;
# --- Technical Choice: Selected over other validators for its strictness and the
# high quality of its error reporting. Our goal is not just pass/fail, but
# providing precise, actionable diagnostics on failure.
use Time::Util qw(check_iso8601);
# For strict date format validation.

# --  Human-Centered Presentation Layer --
use Term::ANSIColor qw(:constants);
use Text::Table;
use Number::Bytes::Human qw(format_bytes);
# --- Technical Choice: This trio forms our UX stack. We've made the decision that
# clear, formatted, and human-friendly output (`--verbose`) is a core feature,
# not an afterthought.

# --  Automation & Scripting Contract --
use constant {
    EXIT_SUCCESS     => 0,
    EXIT_FAILURE     => 1,
    EXIT_USAGE_ERROR => 2
};
# --- Technical Choice: We expose our exit codes as named constants to make the
# script a reliable, well-behaved component in larger automation pipelines. This
# transforms magic numbers into a clear, machine-readable API.

# -----------------------------------------------------------------------------
# DEVELOPMENT WORKFLOW ADVISORY:
#
# This codebase is designed to be validated against the Perl::Critic static
# analyzer. Adherence to a strict set of policies ensures long-term
# maintainability and code quality.
#
# Recommended local usage:
#   $ perlcritic --profile=.perlcriticrc lib/
#
# For integration, consider using a Git pre-commit hook.
# -----------------------------------------------------------------------------

sub main(@args) {
    # -- Phase 1: User Intent & Input Marshalling --
    # Orchestrate the initial setup by delegating tasks. The goal is to
    # cleanly separate command-line parsing from input source resolution.

    # Pass by reference to allow `parse_cli_options` to modify the array
    # in-place, removing flags and leaving only positional arguments.
    my $opts_ref = {};
    parse_cli_options(\@args, $opts_ref);

    # The now-sanitized `@args` is used to determine the final input source
    # (either a file or STDIN). This decouples the two setup steps.
    my $input_src = determine_input_source(\@args);

    # -- Phase 2: Core Logic Execution with a Unified Safety Net --
    # A single try/catch block establishes a transactional boundary. Any failure
    # within this block (I/O, parsing, validation) is caught and handled
    # uniformly, ensuring application robustness.
    try {
        # Load the two primary data artifacts: the embedded schema contract
        # and the user-provided instance data.
        my $schema_data   = load_schema_from_data();
        my $instance_data = load_messagepack_instance($input_src);

        # Instantiate the validation engine and perform the core audit.
        # This is the central gatekeeper of the application's logic.
        my $validator = JSON::Schema::Modern->new;

        # We teach the validator how to recognize a strict ISO 8601 timestamp by
        # delegating the check to a specialized, battle-tested CPAN module.
        # This makes our schema's `format: "date-time"` assertion truly meaningful.
        $validator->add_format_checker('date-time', \&check_iso8601);

        # --- The Core Audit Gatekeeper ---
        # The new `format_is_assertion` option activates our custom checker.
        my ($is_valid, @errors) = $validator->validate(
            $instance_data,
            $schema_data,
            # This option tells the validator to treat 'format' keys as assertions.
            { format_is_assertion => 1 }
        );

        # Delegate all output and exit-code logic to a single, dedicated
        # subroutine. This maintains a clean separation of concerns between
        # processing and presentation.
        report_final_results($is_valid, \@errors, $instance_data, $input_src->{name}, $opts_ref);

    } catch($e) {
        # The unified safety net: gracefully handle any unexpected, fatal
        # exceptions from the core logic, providing a clear error message.
        say BOLD, RED, "FATAL ERROR: ", RESET, "An unhandled exception occurred: $e";
        exit EXIT_FAILURE;
    }
}

# --- Application Entry Point ---
# Execute the main orchestrator, passing in the command-line arguments.
main(@ARGV);


sub parse_cli_options ($args_ref, $opts_ref) {
    # Architectural Choice: Decouple from global state for testability.
    # By operating on an array reference, this function can be unit-tested
    # in isolation without manipulating the global @ARGV.
    my $is_success = GetOptionsFromArray(
        $args_ref,
        $opts_ref,
        # Define the public CLI contract: a verbose flag and a help flag.
        # The '|' character defines both long and short-form aliases.
        'verbose|v',
        'help|?',
    );

    # UX Choice: Handle --help as a primary, successful execution path.
    # This is not an error; it's a user request for documentation.
    if ($opts_ref->{help}) {
        pod2usage({
            # Exit with success, as the request was fulfilled.
            -exitval => EXIT_SUCCESS,
            # Use verbosity level 2 to render the full embedded man page.
            -verbose => 2
        });
    }

    # UX Choice: Handle parsing failures gracefully and informatively.
    unless ($is_success) {
        pod2usage({
            # Exit with a specific usage error code for automation.
            -exitval => EXIT_USAGE_ERROR,
            # Use verbosity level 0 to show only the SYNOPSIS for a quick syntax hint.
            -verbose => 0,
            # Provide a leading error message for immediate context.
            -message => "Error: Invalid command-line options specified."
        });
    }

    # An explicit return signals a clean, successful parse.
    return;
}

sub determine_input_source ($args_ref) {
    # Architectural Choice: Prioritize positional arguments first, a standard
    # CLI convention. `scalar` is a clear way to check for their existence.
    if (scalar @$args_ref) {
        my $filename = shift @$args_ref;

        # UX Choice: Handle the explicit STDIN convention where '-' is used as a filename.
        # This makes the tool behave as expected in versatile shell pipelines.
        if ($filename eq '-') {
            # Technical Detail: Set STDIN to binary mode to prevent any newline
            # translation or encoding layers from corrupting the MessagePack stream.
            binmode(STDIN);
            return { handle => \*STDIN, name => 'STDIN' };
        }
        else {
            # Technical Detail: Use the three-argument open with a raw I/O layer.
            # This is cruical for reading binary data without corruption.
            # `autodie` (from the preamble) makes this call implicitly robust.
            open my $fh, '<:raw', $filename;
            # Architectural Choice: Return a unified hash ref contract. Downstream
            # functions will operate on this structure, regardless of input source.
            return { handle => $fh, name => $filename };
        }
    }

    # UX Choice: If no filename is given, transparently handle piped input.
    # The `-t` file test operator is the canonical way to check if STDIN
    # is an interactive terminal or a data pipe.
    if (not -t \*STDIN) {
        binmode(STDIN);
        return { handle => \*STDIN, name => 'STDIN' };
    }

    # Final Guard Clause: If neither a file nor a pipe is provided, it's a
    # user error. The script must not hang waiting for input. Instead, we
    # exit gracefully with an informative usage message.
    pod2usage({
        -exitval => EXIT_USAGE_ERROR,
        -verbose => 0, # Show only a brief synopsis
        -message => "Error: No input source provided. Please specify a filename or pipe data from STDIN."
    });
}

sub load_schema_from_data () {
    # Architectural Choice: Self-Contained Application. The entire schema is
    # embedded in the script's __DATA__ block, eliminating external file
    # dependencies and simplifying distribution to a single file.

    # Technical Idiom: The "slurp". `local $/` temporarily undefines the
    # record separator, causing `<DATA>` to read the entire special filehandle
    # into a single string in one efficient operation.
    my $yaml_string = do { local $/; <DATA> };

    # Architectural Choice: Defend Internal Integrity. The embedded schema is a
    # critical asset. A failure to parse it represents a bug or corruption in
    # the script itself. This `try/catch` isolates that specific failure mode.
    try {
        # Delegate parsing to the high-performance YAML::XS engine.
        return Load($yaml_string);
    }
    catch ($e) {
        # Re-contextualize the raw parser error into a user-friendly,
        # actionable message. This clarifies that the fault lies with the tool,
        # not the user's input. The exception is then re-thrown to be caught
        # by the main application's safety net.
        die "Internal Schema Error: Failed to parse embedded YAML data. The script may be corrupt. Details: $e";
    }
}

sub load_messagepack_instance ($input_src) {
    # This subroutine's contract is to read raw bytes from the filehandle
    # provided by `determine_input_source` and deserialize them.
    # We explicitly separate I/O handling from data parsing for clearer error reporting.

    my $binary_content;

    # -- Phase 1: Robustly Read Raw Bytes from the Input Source --
    try {
        # The 'slurp' idiom reads all bytes from the provided filehandle, which
        # could be a file or STDIN, thanks to the unified $input_src contract.
        $binary_content = do { local $/; <{ $input_src->{handle} }> };

        # Resource Management: We must only close handles we explicitly opened.
        # STDIN is managed by the shell and must not be closed by this script.
        if ($input_src->{name} ne 'STDIN') {
            close $input_src->{handle};
        }
    }
    catch ($e) {
        # Error Domain 1: System-level I/O failure. The system failed to read
        # the data. `autodie` promotes these OS-level errors to exceptions.
        # We re-contextualize the error to be specific about this failure mode.
        die "I/O Error: Failed to read from input source '$input_src->{name}': $e";
    }

    # -- Phase 2: Deserialize the Binary Content --
    # Instantiate a new deserializer object for a clean parsing context.
    my $mp = Data::MessagePack->new;

    try {
        # Attempt to unpack the binary data into a native Perl data structure.
        return $mp->unpack($binary_content);
    }
    catch ($e) {
        # Error Domain 2: Data-level format failure. The data was read
        # successfully, but it does not conform to the MessagePack specification.
        # This is a user-side problem (invalid input file).
        die "Deserialization Error: Input from '$input_src->{name}' is not a valid MessagePack stream. Details: $e";
    }
}

sub report_final_results ($is_valid, $errors_ref, $instance_ref, $input_name, $opts_ref) {
    # Architectural Choice: This subroutine is the single point of exit for the
    # application, ensuring consistent output formatting and reliable exit codes.

    # --- Case 1: Validation FAILED ---
    # UX Choice: Failure output is unconditionally verbose. When the input is
    # invalid, the user must be given all available context to diagnose the issue.
    unless ($is_valid) {
        say BOLD, RED, "FAILURE: ", RESET, "Input from '", BOLD, $input_name, RESET, "' does not conform to the schema.";
        say "Validation Errors Found (@{[scalar @$errors_ref]}):";

        for my $error (@$errors_ref) {
            # Leverage the rich error objects from JSON::Schema::Modern to provide
            # precise, actionable feedback.
            my $path = $error->instance_path // 'root'; # Default to 'root' for global errors.
            my $msg  = $error->message;

            # Use color to visually distinguish the error's location from its description.
            say "  - ", BOLD, YELLOW, "Path: ", RESET, BOLD, $path, RESET;
            say "    ", BOLD, RED, "Error: ", RESET, $msg;
        }
        # Provide a machine-readable failure signal for automation.
        exit EXIT_FAILURE;
    }

    # --- Case 2: Validation SUCCEEDED ---
    # First, report the successful outcome, which is the primary contract.
    say BOLD, GREEN, "SUCCESS: ", RESET, "Input from '", BOLD, $input_name, RESET, "' conforms to the schema.";

    # UX Choice: The level of detail on success is governed by user intent.
    # The --verbose flag acts as a feature switch for deeper inspection.
    if ($opts_ref->{verbose}) {
        # Delegate the complex task of formatting to a dedicated subroutine,
        # maintaining a clean separation of concerns.
        print_human_summary($instance_ref);
    }

    # Provide a machine-readable success signal for automation.
    exit EXIT_SUCCESS;
}

sub print_human_summary ($instance_ref) {
    # Architectural Choice: A top-down information hierarchy. We present the most
    # general context first, allowing the user to progressively drill down into details.
    say "\n", BOLD, ULINE, "Detailed Summary", RESET;

    # --- Metadata Section: The "Who, When, What" of the report. ---
    # This provides immediate, non-negotiable context about the report's origin.
    my $meta = $instance_ref->{metadata};
    my $invocation = $meta->{invocation};
    say "  Generated by: ", BOLD, "git-subtree-report v$meta->{tool_version}", RESET;
    say "  Timestamp:    ", BOLD, $meta->{timestamp_utc}, RESET;
    # UX Choice: Use substr for the commit hash to provide a recognizable
    # identifier without overwhelming the user with the full 40 characters.
    say "  Commit:       ", BOLD, substr($invocation->{commit_hash}, 0, 12), RESET;
    say "  Subtree:      '", BOLD, $invocation->{target_subtree}, RESET, "'";

    # --- Aggregate Data Tables: The "At-a-Glance" Dashboard ---
    # We use Text::Table to ensure a professional, perfectly aligned presentation
    # that is robust against varying data lengths.
    my $summary = $instance_ref->{summary};
    my $counts  = $summary->{file_counts};
    my $sizes   = $summary->{size_bytes};

    # -- File Counts Table --
    my $counts_table = Text::Table->new(
        { title => 'File Counts',                          align => 'left' },
        { title => 'Value',                 width => 20, align => 'right' }
    );
    # UX Choice: Semantic use of color provides instant visual cues. Green highlights
    # the primary result, while yellow draws attention to secondary categories.
    $counts_table->load(
        [ "Total in Subtree",        $counts->{total_in_subtree} ],
        [ "Excluded by Pattern",     $counts->{excluded_by_pattern} ],
        [ "Processed for Report",    BOLD, $counts->{processed}, RESET ],
        [ "Included in Final Report",    BOLD, GREEN, $counts->{included_in_report}, RESET ],
        [ "Unmatched by Inclusions", BOLD, YELLOW, $counts->{unmatched_in_report}, RESET ],
    );
    say "\n", $counts_table;

    # -- Size Analysis Table --
    my $sizes_table = Text::Table->new(
        { title => 'Size Analysis',                        align => 'left' },
        { title => 'Value',                 width => 20, align => 'right' }
    );
    # Technical Choice: Use a dedicated module like Number::Bytes::Human to present
    # raw byte counts in a familiar, human-friendly format (e.g., "1.2 MiB").
    $sizes_table->load(
        [ "Total (Processed Files)", format_bytes($sizes->{processed_files_total}) ],
        [ "Included Files",          format_bytes($sizes->{included_files_total}) ],
        [ "LFS (Stored Remotely)",   format_bytes($sizes->{lfs_stored_total}) ],
    );
    say $sizes_table;

    # -- Special File Types Table --
    my $types_table = Text::Table->new(
        { title => 'Special File Types',                   align => 'left' },
        { title => 'Count',                 width => 20, align => 'right' }
    );
    $types_table->load(
        [ "LFS Pointers",  $counts->{lfs_pointers} ],
        [ "Symlinks",      $counts->{symlinks} ],
        [ "Submodules",    $counts->{submodules} ],
    );
    # UX Choice: Conditional output ("Signal over Noise"). We only display this
    # table if it contains meaningful, non-zero data, keeping the report uncluttered.
    say "\n", $types_table if ($counts->{lfs_pointers} || $counts->{symlinks} || $counts->{submodules});

    # --- Detailed Breakdown Section: The Granular Proof ---
    my $included_files = $instance_ref->{results}{files_included};
    my $num_included   = scalar keys %$included_files;

    # Also conditional, only show this detailed list if there are files to list.
    if ($num_included > 0) {
        say "\n", BOLD, ULINE, "Breakdown of $num_included Included File(s)", RESET;
        my $files_table = Text::Table->new(
            { title => 'File Path',           align => 'left' },
            { title => 'Size',                align => 'right' },
            { title => 'Reason for Inclusion', align => 'left' },
        );
        # Iterate over sorted keys to provide a deterministic, predictable output order.
        for my $path (sort keys %$included_files) {
            my $file_obj = $included_files->{$path};
            my $reasons  = join(", ", @{ $file_obj->{matched_inclusions} });
            # Defensive Coding: The schema allows size_bytes to be null. We handle
            # this case gracefully to prevent warnings and provide a clear 'N/A' to the user.
            my $size_str = defined $file_obj->{size_bytes} ? format_bytes($file_obj->{size_bytes}) : 'N/A';
            $files_table->add($path, $size_str, $reasons);
        }
        say $files_table;
    }
}

# --- Final Application Sections ---
# The __END__ directive marks the end of the executable Perl code. Everything
# that follows is accessible via the special DATA filehandle.

__END__

# =============================================================================
# SECTION: EMBEDDED DOCUMENTATION (POD)
#
# Architectural Choice: Documentation as a first-class citizen. By embedding
# the manual directly into the script using POD (Plain Old Documentation),
# we create a single, self-contained artifact. This ensures the code and its
# documentation are always in sync and can be rendered by standard tools like
# `pod2usage` and `perldoc`.
# =============================================================================

=head1 NAME

audit_messagepack.pl - Validates and inspects a git-subtree-report MessagePack file.

=head1 VERSION

# Architectural Choice: Declare a version for the auditor itself. This is
# crucial for reproducible builds and diagnosing version incompatibilities.
version 1.0.0

=head1 SYNOPSIS

# UX Choice: Provide immediate, copy-pasteable examples for the most
# common use cases. This serves as a "quick-start guide" for users.
  # Basic validation (silent on success, loud on failure)
  audit_messagepack.pl report.msgpack

  # Validate and print a human-readable summary on success
  audit_messagepack.pl --verbose report.msgpack

  # Same, but using STDIN from a pipe
  cat report.msgpack | audit_messagepack.pl --verbose

=head1 DESCRIPTION

This tool performs a strict validation of a binary MessagePack file, as generated by `git-subtree-report -m`, against the official internal schema. Its primary purpose is to serve as a reference implementation and a diagnostic tool for consumers of the machine-readable output.

# Architectural Contract: The following list explicitly defines the tool's behavior
# as a standard UNIX citizen, creating a reliable API for automation.
The script acts as a standard UNIX command-line tool:

=over 4

=item * It reads from a file specified as an argument or from STDIN if no argument is given.

=item * It exits with a status code of B<0> if the input is valid according to the schema.

=item * It exits with a status code of B<1> if the input is invalid or if a fatal error occurs.

=item * It exits with a status code of B<2> for command-line usage errors.

=back

On validation failure, it prints a detailed, colored report to STDERR pinpointing the exact location and nature of the schema violation.

=head1 OPTIONS

# UX Choice: A clear and unambiguous definition of all command-line flags.
=over 4

=item B<-v>, B<--verbose>

# The description is precise ("If and only if...") to proactively clarify that
# this option has no effect when validation fails.
If (and only if) validation is successful, print a human-readable summary of the report's contents to STDOUT in addition to the standard success message. This is useful for quick, interactive inspection of a report file.

=item B<--help>

Displays this full help message and exits successfully.

=back

=head1 ARGUMENTS

# UX Choice: Distinguish positional arguments from flagged options, following
# standard CLI conventions for clarity.
=over 4

=item B<[filename]>

Optional. The path to the MessagePack file to audit. If this argument is omitted, the script reads binary data from STDIN, allowing it to be used in shell pipelines.

=back

=head1 SCHEMA

# Architectural Choice: Explicitly declare the data contract version this tool
# validates against. This is critical for future-proofing and diagnosing
# interoperability issues if the report format ever evolves.
This tool validates against schema version B<1.0.0>. The full schema is embedded within this script. Please refer to the source code of `git-subtree-report` for the canonical schema definition.

=head1 AUTHOR

Cameron Garnham <me@da2ce7.com>

# POD requires a '=cut' directive to signal the end of the documentation block.
=cut

# =============================================================================
# SECTION: EMBEDDED SCHEMA PAYLOAD
#
# Architectural Choice: A fully self-contained artifact. By embedding the
# schema specification directly into the script as a data payload, we eliminate
# the need for any external schema files, making the auditor a single, portable,
# and dependency-free executable.
#
# Technical Choice: YAML is used for its superior human-readability and
# support for comments, making the schema itself easier to read and maintain
# directly within this source file. This block is the authoritative source for
# the `load_schema_from_data` subroutine.
# =============================================================================

__DATA__
# -----------------------------------------------------------------------------
# GIT SUBTREE REPORT - MACHINE-READABLE OUTPUT SCHEMA
# -----------------------------------------------------------------------------
# Version: 1.0.0
# Format: YAML (JSON Schema Compatible)
#
# Description:
#   Schema for the MessagePack object generated by `git-subtree-report` with the -m flag.
#   It is the definitive contract for all consumers of the machine-readable output.
# -----------------------------------------------------------------------------

type: map
required: [schema_version, metadata, summary, results]
properties:
  schema_version:
    type: string
    required: true
    enum: ["1.0.0"]
    description: "Identifies the contract version for this output object. | PRESENCE: Required. VALUE: Must be '1.0.0' for this specification. | RELATIONSHIP: Governs the structure and interpretation of the entire object."

  metadata:
    ref: "#/definitions/MetadataObject"
    description: "A container for all metadata related to the report generation context. | PRESENCE: Required. | RELATIONSHIP: Contains the MetadataObject."

  summary:
    ref: "#/definitions/SummaryObject"
    description: "A container for aggregated statistics providing a complete dashboard view of the analysis. | PRESENCE: Required. | RELATIONSHIP: Contains the SummaryObject."

  results:
    ref: "#/definitions/ResultsObject"
    description: "A container for the detailed, file-by-file results of the analysis. | PRESENCE: Required. | RELATIONSHIP: Contains categorized maps of all processed files."

  embedded_content:
    type: map
    required: false
    additionalProperties: { type: bytes }
    description: "A map of file paths to their raw content. | PRESENCE: Optional. Only present if the -o flag is used with -m. | RELATIONSHIP: Contains content for files whose path keys appear in `results.files_included`."

# -----------------------------------------------------------------------------
# Reusable Object Definitions
# -----------------------------------------------------------------------------
definitions:
  MetadataObject:
    type: map
    description: "Contextual information about the report generation."
    required: [tool_version, timestamp_utc, invocation]
    properties:
      tool_version: { type: string, description: "The semantic version of the `git-subtree-report` tool itself. | PRESENCE: Required. | RELATIONSHIP: Provides context for the feature set available at the time of generation." }
      timestamp_utc: { type: string, format: "date-time", description: "The UTC timestamp of when the report generation was initiated. | PRESENCE: Required. VALUE: Formatted as ISO 8601. | RELATIONSHIP: N/A." }
      invocation:
        type: map
        required: [repository_root, target_subtree, commit_hash, max_file_size_bytes, exclusion_pattern, inclusion_types]
        properties:
          repository_root: { type: string, description: "The absolute path to the Git repository root directory. | PRESENCE: Required. | RELATIONSHIP: N/A." }
          target_subtree: { type: string, description: "The relative path within the repository that was analyzed. | PRESENCE: Required. VALUE: '.' denotes the entire repository. | RELATIONSHIP: N/A." }
          commit_hash: { type: string, description: "The full 40-character SHA of the analyzed Git commit. | PRESENCE: Required. | RELATIONSHIP: N/A." }
          max_file_size_bytes: { type: integer, description: "The file size limit used for content analysis. | PRESENCE: Required. VALUE: Files larger than this are classified as 'oversize'. | RELATIONSHIP: Governs the `classification.is_oversize` flag and whether `content_analysis` is performed." }
          exclusion_pattern: { type: ["string", "null"], description: "The Extended Regular Expression (ERE) used to filter out files. | PRESENCE: Required. VALUE: `null` if no pattern was provided. | RELATIONSHIP: Rules that populate the `results.files_excluded` map." }
          inclusion_types: { type: array, items: { type: string }, description: "The list of inclusion types that governed the final report. | PRESENCE: Required. DEFAULT: Contains `['safe']` if no `--include` flags are used. | RELATIONSHIP: Determines which `AnalyzedFileObject`s populate `results.files_included` via the `matched_inclusions` field." }

  SummaryObject:
    type: map
    description: "Aggregated statistics providing a complete dashboard view of the analysis."
    required: [file_counts, size_bytes]
    properties:
      file_counts:
        type: map
        required: [total_in_subtree, excluded_by_pattern, processed, included_in_report, unmatched_in_report, lfs_pointers, symlinks, submodules]
        properties:
          total_in_subtree: { type: integer, description: "Total count of files found in the target subtree before any filtering. | PRESENCE: Required. | RELATIONSHIP: N/A." }
          excluded_by_pattern: { type: integer, description: "The number of files filtered out by `metadata.invocation.exclusion_pattern`. | PRESENCE: Required. | RELATIONSHIP: Reflects the item count of the `results.files_excluded` map." }
          processed: { type: integer, description: "The number of files that underwent analysis. | PRESENCE: Required. VALUE: `total_in_subtree` - `excluded_by_pattern`. | RELATIONSHIP: Represents the sum of items in `results.files_included` and `results.files_unmatched`." }
          included_in_report: { type: integer, description: "Final count of files that matched at least one inclusion criterion. | PRESENCE: Required. | RELATIONSHIP: Reflects the item count of the `results.files_included` map." }
          unmatched_in_report: { type: integer, description: "The number of files processed that did NOT match any inclusion criteria. | PRESENCE: Required. | RELATIONSHIP: Reflects the item count of the `results.files_unmatched` map." }
          lfs_pointers: { type: integer, description: "Total count of processed files identified as LFS pointers. | PRESENCE: Required. | RELATIONSHIP: Represents the sum of all processed files where `lfs_details` is not null." }
          symlinks: { type: integer, description: "Total count of processed files identified as symbolic links. | PRESENCE: Required. | RELATIONSHIP: Represents the sum of all processed files where `type` is 'symlink'." }
          submodules: { type: integer, description: "Total count of processed files identified as submodules. | PRESENCE: Required. | RELATIONSHIP: Represents the sum of all processed files where `type` is 'submodule'." }
      size_bytes:
        type: map
        required: [processed_files_total, included_files_total, lfs_stored_total]
        properties:
          processed_files_total: { type: integer, description: "Sum of blob sizes for all processed files. | PRESENCE: Required. | RELATIONSHIP: Sum of `size_bytes` for all objects in `results.files_included` and `results.files_unmatched`." }
          included_files_total: { type: integer, description: "Sum of blob sizes for only the files included in the final report. | PRESENCE: Required. | RELATIONSHIP: Sum of `size_bytes` for all objects in `results.files_included`." }
          lfs_stored_total: { type: integer, description: "Sum of actual file sizes for all LFS pointers found. | PRESENCE: Required. | RELATIONSHIP: Sum of `lfs_details.stored_size_bytes` across all processed files." }

  ResultsObject:
    type: map
    required: [files_included, files_unmatched, files_excluded]
    properties:
      files_included: { type: map, additionalProperties: { ref: "#/definitions/AnalyzedFileObject" }, description: "A map of path -> AnalyzedFileObject for all files that matched at least one `inclusion_type`. | PRESENCE: Required. VALUE: May be an empty map. | RELATIONSHIP: Its item count matches `summary.file_counts.included_in_report`." }
      files_unmatched: { type: map, additionalProperties: { ref: "#/definitions/AnalyzedFileObject" }, description: "A map of path -> AnalyzedFileObject for all processed files that did not match any `inclusion_type`. | PRESENCE: Required. VALUE: May be an empty map. | RELATIONSHIP: Its item count matches `summary.file_counts.unmatched_in_report`." }
      files_excluded: { type: map, additionalProperties: { ref: "#/definitions/ExcludedFileObject" }, description: "A map of path -> ExcludedFileObject for all files filtered out by the exclusion pattern. | PRESENCE: Required. VALUE: May be an empty map. | RELATIONSHIP: Its item count matches `summary.file_counts.excluded_by_pattern`." }

  ExcludedFileObject:
    type: map
    description: "A minimal record for a file excluded by pattern, before analysis is performed."
    required: [type, mode, blob_hash, size_bytes]
    properties:
      type: { type: string, enum: ["blob", "symlink", "submodule"], description: "The fundamental Git object type as reported by `ls-tree`. | PRESENCE: Required. | RELATIONSHIP: N/A." }
      mode: { type: string, description: "The file's mode string as reported by `ls-tree`. | PRESENCE: Required. | RELATIONSHIP: N/A." }
      blob_hash: { type: ["string", "null"], description: "The 40-character SHA of the blob. | PRESENCE: Required. VALUE: `null` if `type` is 'submodule'. | RELATIONSHIP: N/A." }
      size_bytes: { type: ["integer", "null"], description: "The size of the blob in bytes. | PRESENCE: Required. VALUE: `null` if `type` is 'submodule'. | RELATIONSHIP: N/A." }

  AnalyzedFileObject:
    type: map
    description: "A complete record for a file that underwent full analysis."
    required: [type, mode, blob_hash, size_bytes, classification, content_analysis, matched_inclusions]
    properties:
      type: { type: string, enum: ["blob", "symlink", "submodule"] }
      mode: { type: string }
      blob_hash: { type: ["string", "null"] }
      size_bytes: { type: ["integer", "null"] }
      classification:
        type: map
        description: "A container for high-level classifications based on attributes, type, and size. | PRESENCE: Required. | RELATIONSHIP: N/A."
        required: [is_concatenatable, is_binary_by_attr, is_oversize]
        properties:
          is_concatenatable: { type: boolean, description: "The ultimate safety check for textual content. | PRESENCE: Required. VALUE: `true` only if content is valid UTF-8, contains no null bytes, and is not designated binary. | RELATIONSHIP: Governs the 'safe' inclusion type." }
          is_binary_by_attr: { type: boolean, description: "Indicates if the file was explicitly marked as binary. | PRESENCE: Required. VALUE: Derived from `.gitattributes` analysis. | RELATIONSHIP: Governs the 'binary_attr' inclusion type." }
          is_oversize: { type: boolean, description: "Indicates if the file exceeded the size limit for deep content analysis. | PRESENCE: Required. VALUE: `true` if `size_bytes` > `metadata.invocation.max_file_size_bytes`. | RELATIONSHIP: Governs the 'oversize' inclusion type and determines if `content_analysis` is `null`." }
      content_analysis:
        type: ["map", "null"]
        description: "Results from deep inspection of file content. | PRESENCE: Required. VALUE: `null` if analysis was skipped (e.g., for oversize files). | RELATIONSHIP: Provides data for 'binary_null' and 'unsafe_utf8' inclusion types."
        required: [has_null_bytes, null_byte_count, is_valid_utf8]
        properties:
          has_null_bytes: { type: boolean, description: "Indicates if the blob contains `\\x00` characters. | PRESENCE: Required within this object. | RELATIONSHIP: Governs the 'binary_null' inclusion type." }
          null_byte_count: { type: integer, description: "A raw count of null bytes found in the blob. | PRESENCE: Required within this object. | RELATIONSHIP: N/A." }
          is_valid_utf8: { type: boolean, description: "Indicates if the blob contains valid UTF-8 byte sequences. | PRESENCE: Required within this object. | RELATIONSHIP: Governs the 'unsafe_utf8' inclusion type." }
      symlink_target: { type: string, description: "The path the symbolic link points to. | PRESENCE: Optional. Only present if `type` is 'symlink'. | RELATIONSHIP: Governs the 'symlink' inclusion type." }
      submodule_url: { type: ["string", "null"], description: "The URL of the submodule repository. | PRESENCE: Optional. Only present if `type` is 'submodule'. VALUE: `null` if the submodule has no corresponding URL in `.gitmodules`. | RELATIONSHIP: Governs the 'submodule' inclusion type." }
      lfs_details:
        type: ["map", "null"]
        description: "A container for Git LFS pointer information. | PRESENCE: Required. VALUE: `null` if the file is not an LFS pointer. | RELATIONSHIP: Governs the 'lfs' inclusion type."
        required: [pointer_size_bytes, stored_size_bytes]
        properties:
          pointer_size_bytes: { type: integer, description: "The size of the LFS pointer file itself. | PRESENCE: Required within this object. | RELATIONSHIP: This is the same value as the parent object's `size_bytes`."}
          stored_size_bytes: { type: integer, description: "The size of the actual file stored on the remote LFS server. | PRESENCE: Required within this object. | RELATIONSHIP: Contributes to `summary.size_bytes.lfs_stored_total`." }
      matched_inclusions:
        type: array
        description: "An array listing all inclusion keywords this file satisfied, providing the reason for its inclusion in the report. | PRESENCE: Required. VALUE: For objects in `results.files_unmatched`, this array MUST be empty. | RELATIONSHIP: If this array is not empty, the file appears in `results.files_included`; otherwise, it appears in `results.files_unmatched`."
        items:
          type: string
          enum: ["safe", "lfs", "symlink", "submodule", "binary_attr", "binary_null", "oversize", "unsafe_utf8"]
