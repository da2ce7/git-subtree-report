# This class represents the final, perfected artifact. It is an immutable Data
# Transfer Object (DTO), a vessel holding the complete, validated, and structured
# report. Its purpose is to be a safe, predictable container of the data
# assembled by the Factory, ready for serialization or inspection. Once an object
# of this class exists, the data is considered canonical.

package GitReport::Document;

# The use of Moo here provides us with a concise way to declare our attributes
# and their properties, ensuring a consistent and robust object structure.
use Moo;
use Types::Standard qw(HashRef);

# As per the review, the schema_version is elevated to a first-class attribute
# of the Document itself. This makes the Document a more direct and pure
# representation of the final, top-level MessagePack object, rather than
# nesting this key within the metadata.
has 'schema_version', is => 'ro', isa => Str,     required => 1;
has 'metadata',       is => 'ro', isa => HashRef, required => 1;
has 'summary',        is => 'ro', isa => HashRef, required => 1;
has 'results',        is => 'ro', isa => HashRef, required => 1;
# Even if no content is embedded, this attribute will hold an empty hashref,
# simplifying the internal logic. The as_hash method will gate its inclusion
# in the final output.
has 'embedded_content', is => 'ro', isa => HashRef, required => 1;

# This method acts as the bridge to the outside world, specifically for the
# Serializer. It translates the internal object representation into the precise
# hash structure required for the final MessagePack output, directly matching
# the schema contract.
sub as_hash {
    my ($self) = @_;
    return {
        # The top-level attributes are directly mapped.
        schema_version => $self->schema_version,
        metadata       => $self->metadata,
        summary        => $self->summary,
        results        => $self->results,

        # This is a key piece of conditional logic that implements the schema
        # rule: the `embedded_content` key *only* appears in the final output
        # if the `--embed-content` flag was used. The ternary-like structure
        # returns an empty list `()` if the condition is false, effectively
        # causing the key-value pair to vanish from the final hash.
        (
            $self->metadata->{embed_content}
            ? ( embedded_content => $self->embedded_content )
            : ()
        ),
    };
}

1;
