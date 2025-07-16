# This class acts as the application's immutable governor. Its sole responsibility
# is to parse and rigorously validate the command-line invocation. It is the
# first line of defense; an object of this class is a guarantee that the user's
# intent is well-formed, complete, and syntactically valid according to the ICD.

package GitReport::Config;

use Moo;
# We import specific, well-defined types to enforce a strict data contract on
# our attributes. This moves validation from runtime checks to declarative
# assertions, making the code safer and more self-documenting.
use Types::Standard qw(Str Bool Int ArrayRef);
use Getopt::Long qw(GetOptionsFromArray);
use Time::Util qw(check_iso8601);

# It is a best practice to define constants for exit codes. This eliminates 'magic
# numbers' from the code, replacing them with a named, explicit contract that
# improves readability and consistency.
use constant {
    EXIT_INVOCATION_ERROR => 20,
};

# -- Immutable Attribute Definitions --
# Each 'has' declaration defines a piece of the final, trusted configuration.
# The 'is => ro' (read-only) constraint is paramount, ensuring that once the
# config object is created, its state is sealed and cannot be accidentally
# modified by downstream code.

has 'schema_version',      is => 'ro', isa => Str,       required => 1;
has 'tool_version',        is => 'ro', isa => Str,       required => 1;
has 'commit_hash',         is => 'ro', isa => Str,       required => 1;
has 'timestamp_utc',       is => 'ro', isa => Str,       required => 1;
has 'repository_root',     is => 'ro', isa => Str,       required => 1;
has 'target_subtree',      is => 'ro', isa => Str,       required => 1;
has 'exclusion_pattern',   is => 'ro', isa => Str,       required => 1;
has 'max_file_size_bytes', is => 'ro', isa => Int,       required => 1;
has 'embed_content',       is => 'ro', isa => Bool,      default  => 0;

# This is the refined attribute definition based on the review. Getopt::Long's
# '=s@' specifier creates an array reference. This type constraint now
# correctly and explicitly matches that output, ensuring perfect type safety.
has 'inclusion_types',     is => 'ro', isa => ArrayRef[Str], required => 1;

# The BUILDARGS hook is a sophisticated Moo pattern. It allows us to hijack
# the object construction process to perform complex, multi-step validation
# *before* the final object is created. This ensures the constructor never
# fails; either the BUILDARGS hook returns a perfect arguments hash, or it
# throws a fatal exception.
sub BUILDARGS {
    my ($class, %args) = @_;
    my $cli_args_ref = delete $args{argv}; # Extract the raw CLI arguments.

    my %opts;
    # We parse the arguments into a temporary hash. GetOptionsFromArray is used
    # to facilitate isolated unit testing without manipulating the global @ARGV.
    # On parsing failure, we immediately throw our typed exception.
    GetOptionsFromArray(
        $cli_args_ref,
        \%opts,
        'schema-version=s',
        'tool-version=s',
        'commit-hash=s',
        'timestamp-utc=s',
        'repository-root=s',
        'target-subtree=s',
        'exclusion-pattern=s',
        'max-file-size-bytes=i',
        'inclusion-types=s@', # The '@' makes this a multi-value option.
        'embed-content',
    ) or GitReport::Exception::Invocation->throw({
        message   => 'Failed to parse command-line options. Use --help for usage.',
        exit_code => EXIT_INVOCATION_ERROR,
    });

    my %final_args;
    my @required = qw(
      schema_version tool_version commit_hash timestamp_utc
      repository_root target_subtree exclusion_pattern
      max_file_size_bytes inclusion_types
    );

    # This loop programmatically verifies the presence of all mandatory options,
    # ensuring the contract with the caller is met. It throws with a clear,
ar    # actionable error message if any option is missing.
    for my $key (@required) {
        my $cli_key = $key;
        $cli_key =~ s/_/-/g; # Convert perl_style_key to cli-style-key.

        GitReport::Exception::Invocation->throw({
            message   => "Mandatory option '--$cli_key' is missing.",
            exit_code => EXIT_INVOCATION_ERROR,
        }) unless exists $opts{$cli_key};

        $final_args{$key} = $opts{$cli_key};
    }

    # Handle the boolean flag separately.
    if ($opts{'embed-content'}) {
        $final_args{embed_content} = 1;
    }

    # Delegate fine-grained value validation to a dedicated private method.
    # This keeps the BUILDARGS hook focused on presence and parsing.
    $class->_validate_args(\%final_args);

    # The ordeal is over. We return a validated, complete, and trustworthy
    # arguments hash to the constructor, which will now create the object.
    return \%final_args;
}

# A private helper method for validating the *content* of the parsed arguments.
# This follows the Single Responsibility Principle.
sub _validate_args {
    my ($class, $args) = @_;

    # Regex validation provides cryptographic-level assurance for the SHA format.
    if ($args->{commit_hash} !~ /^[0-9a-f]{40}$/) {
        GitReport::Exception::Invocation->throw({
            message   => "Value for --commit-hash is not a valid 40-character SHA.",
            exit_code => EXIT_INVOCATION_ERROR,
        });
    }

    # Delegate date validation to a specialized, battle-tested CPAN module.
    # This is always preferable to writing a custom, likely incomplete, regex.
    if (!check_iso8601($args->{timestamp_utc})) {
        GitReport::Exception::Invocation->throw({
            message   => "Value for --timestamp-utc is not a valid ISO 8601 string.",
            exit_code => EXIT_INVOCATION_ERROR,
        });
    }

    # Simple numeric range check.
    if ($args->{max_file_size_bytes} < 0) {
        GitReport::Exception::Invocation->throw({
            message   => "Value for --max-file-size-bytes must be a non-negative integer.",
            exit_code => EXIT_INVOCATION_ERROR,
        });
    }

    return 1;
}

1;
