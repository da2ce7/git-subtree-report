# This Archaeologist class is a specialist. It knows one ancient language: the
# null-delimited BASH_STATE_STREAM from File Descriptor 3. Its purpose is to
# unearth this raw data, check it for corruption, and translate it into a
# structured Perl hash, isolating the rest of the application from the messy
# details of this custom wire format.

package GitReport::Input::StateStreamParser;

use Moo;

use constant {
    EXIT_INPUT_DATA_ERROR => 40,
};

has handle => (
    is       => 'ro',
    required => 1,
);

sub parse {
    my ($self) = @_;

    # The 'slurp' idiom is the most efficient way to read the entire stream.
    # By using a local scope for `$/`, we ensure this temporary change
    # to Perl's record separator does not affect any other part of the program.
    my $raw_content = do { local $/; <{ $self->handle }> };
    close $self->handle; # Ensure no file descriptors are leaked.

    my @elements = split /\0/, $raw_content;

    # The first integrity check: if the stream is not empty, its element
    # count MUST be a multiple of 3. This is a simple but powerful guard
    # against a truncated or malformed stream from the Bash orchestrator.
    if (@elements && @elements % 3 != 0) {
        GitReport::Exception::InputData->throw({
            message   => "BASH_STATE_STREAM is malformed: number of elements is not a multiple of 3.",
            exit_code => EXIT_INPUT_DATA_ERROR,
        });
    }

    my %state;
    # The translation loop. We confidently splice 3 elements at a time, knowing
    # the integrity check has passed.
    while (@elements) {
        my ($array_name, $key, $value) = splice(@elements, 0, 3);
        $state{$array_name}{$key} = $value;
    }

    # The second integrity check: Enforce the ICD's data contract. The stream
    # is useless without these core data mappings. This validates the *semantic*
    # content of the stream, not just its structure.
    my @required_arrays = qw(path_to_blob path_to_size path_to_mode);
    for my $req (@required_arrays) {
        unless (exists $state{$req}) {
             GitReport::Exception::InputData->throw({
                message   => "BASH_STATE_STREAM is missing mandatory array data for '$req'.",
                exit_code => EXIT_INPUT_DATA_ERROR,
            });
        }
    }

    # Return the clean, structured, and validated state hash.
    return \%state;
}

1;
