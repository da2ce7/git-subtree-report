# This parser is a master of a single protocol: `git cat-file --batch`.
# It is a stateful, line-by-line reader designed for robustness. It anticipates
# and guards against every possible failure mode of the protocol, ensuring
# that no corrupt or incomplete data can enter the main application.

package GitReport::Input::ContentParser;

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
    my %content;

    my $fh = $self->handle;

    # This loop processes one blob at a time, reading a header, then content.
    while (my $header = <$fh>) {
        chomp $header;

        # First, check for the explicit failure case defined by the protocol.
        if ($header =~ /^([0-9a-f]{40})\s+missing$/) {
            GitReport::Exception::InputData->throw({
                message   => "CONTENT_STREAM reported a missing blob from git: $1",
                exit_code => EXIT_INPUT_DATA_ERROR,
            });
        }

        # Validate the success-case header format.
        if ($header !~ /^([0-9a-f]{40})\s+blob\s+(\d+)$/) {
            GitReport::Exception::InputData->throw({
                message   => "CONTENT_STREAM contained a malformed header line.",
                exit_code => EXIT_INPUT_DATA_ERROR,
            });
        }

        my ($sha, $size) = ($1, $2);
        my $buffer;
        # Read the exact number of bytes specified by the header.
        my $bytes_read = read $fh, $buffer, $size;

        # This is the most critical check. A simple `read` is not enough. We
        # MUST verify that the OS returned the number of bytes we requested.
        # A short read indicates a truncated stream and corrupted data.
        if ($bytes_read != $size) {
            GitReport::Exception::InputData->throw({
                message   => "CONTENT_STREAM was truncated. Expected $size bytes for blob $sha, but got $bytes_read.",
                exit_code => EXIT_INPUT_DATA_ERROR,
            });
        }

        # The protocol dictates a trailing newline after the content. We must
        # consume it to prevent it from being read as the next header.
        read $fh, my $newline, 1;

        $content{$sha} = $buffer;
    }

    close $fh;
    return \%content;
}

1;
