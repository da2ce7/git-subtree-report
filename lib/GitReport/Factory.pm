# This is the Master Craftsman, the complex heart of the application. Its sole
# responsibility is to take the validated, raw materials from the gateway
# components (Config and Parsers) and orchestrate their assembly into the final,
# canonical GitReport::Document. It encapsulates all the business logic of data
# transformation.

package GitReport::Factory;

use Moo;
use List::Util qw(sum);
# We bring in a type constraint to formally declare our dependencies on the
# other classes. This allows Moo to validate that the Factory is constructed
# with the correct objects, hardening the internal application contracts.
use Types::Standard qw(InstanceOf);

# -- Dependency Injection --
# The Factory does not create its dependencies; they are injected into its
# constructor. This is a critical design choice that decouples the Factory
# from the rest of the system and makes it supremely testable.

has config => (
    is       => 'ro',
    isa      => InstanceOf['GitReport::Config'],
    required => 1,
);

has state_parser => (
    is       => 'ro',
    isa      => InstanceOf['GitReport::Input::StateStreamParser'],
    required => 1,
);

# The ContentParser is optional, only required if --embed-content is used.
# The 'isa' constraint still applies if it *is* provided.
has content_parser => (
    is  => 'ro',
    isa => InstanceOf['GitReport::Input::ContentParser'],
);


# The public face of the Factory. This single method orchestrates the entire
# creation process in a clear, logical sequence.
sub create_document {
    my ($self) = @_;

    # 1. Parse Inputs: The first action is to trigger the parsers to
    #    translate the raw streams into structured Perl data.
    my $raw_state = $self->state_parser->parse();

    my $embedded_content = {};
    if ( $self->config->embed_content ) {
        $embedded_content = $self->content_parser->parse();
    }

    # 2. Build Results: The most complex step is delegated to a helper. This
    #    is where the file-by-file analysis objects are constructed.
    my $results = $self->_build_results_object($raw_state);

    # 3. Build Summary: The summary is calculated *from* the finalized results,
    #    ensuring the aggregates are always consistent with the detailed data.
    my $summary = $self->_build_summary_object( $raw_state, $results );

    # 4. Build Metadata: The metadata is constructed from the config object.
    my $metadata = $self->_build_metadata_object();

    # 5. Instantiate: The final act is to instantiate the immutable Document
    #    object, passing it the fully assembled and validated data structures.
    #    The refinement from the review is applied here: schema_version is
    #    passed as a top-level attribute.
    return GitReport::Document->new(
        {
            schema_version   => $self->config->schema_version,
            metadata         => $metadata,
            summary          => $summary,
            results          => $results,
            embedded_content => $embedded_content,
        }
    );
}

# This helper constructs the `metadata` object, a direct translation of the
# configuration state into the schema-defined structure.
sub _build_metadata_object {
    my ($self) = @_;
    my $config = $self->config;

    return {
        tool_version  => $config->tool_version,
        timestamp_utc => $config->timestamp_utc,
        embed_content => $config->embed_content,
        invocation    => {
            repository_root     => $config->repository_root,
            target_subtree      => $config->target_subtree,
            commit_hash         => $config->commit_hash,
            max_file_size_bytes => $config->max_file_size_bytes,
            exclusion_pattern   => $config->exclusion_pattern,
            inclusion_types     => $config->inclusion_types,
        },
    };
}

# This helper orchestrates the categorization of every file into one of the
# three results buckets: included, unmatched, or excluded.
sub _build_results_object {
    my ( $self, $state ) = @_;

    my %results = (
        files_included  => {},
        files_unmatched => {},
        files_excluded  => {},
    );

    my $inclusion_map = { map { $_ => 1 } @{ $self->config->inclusion_types } };

    my ( $all_paths_ref, $excluded_paths_ref ) = $self->_get_path_sets($state);

    for my $path (@$all_paths_ref) {
        next if $excluded_paths_ref->{$path};

        # Delegate the construction of the complex file object.
        my $file_obj = $self->_build_analyzed_file_object( $path, $state );
        # Determine if this file should be in the final report.
        my @matched_inclusions = $self->_get_matched_inclusions( $file_obj, $inclusion_map );

        $file_obj->{matched_inclusions} = \@matched_inclusions;

        # The core categorization logic.
        if (@matched_inclusions) {
            $results{files_included}{$path} = $file_obj;
        }
        else {
            $results{files_unmatched}{$path} = $file_obj;
        }
    }

    # Separately, build the minimal objects for the excluded files.
    for my $path ( keys %$excluded_paths_ref ) {
        $results{files_excluded}{$path} = $self->_build_excluded_file_object( $path, $state );
    }

    return \%results;
}

# This helper calculates all the aggregate statistics for the summary dashboard.
sub _build_summary_object {
    my ( $self, $state, $results ) = @_;

    my ( $all_paths_ref, $excluded_paths_ref ) = $self->_get_path_sets($state);
    my $included_files = $results->{files_included};

    my $lfs_pointers = 0;
    my $symlinks     = 0;
    my $submodules   = 0;

    for my $obj ( values %{ $included_files }, values %{ $results->{files_unmatched} } ) {
        $lfs_pointers++ if $obj->{lfs_details};
        $symlinks++     if $obj->{type} eq 'symlink';
        $submodules++   if $obj->{type} eq 'submodule';
    }

    return {
        file_counts => {
            total_in_subtree    => scalar(@$all_paths_ref),
            excluded_by_pattern => scalar( keys %$excluded_paths_ref ),
            processed           => scalar(@$all_paths_ref) - scalar( keys %$excluded_paths_ref ),
            included_in_report  => scalar( keys %$included_files ),
            unmatched_in_report => scalar( keys %{ $results->{files_unmatched} } ),
            lfs_pointers        => $lfs_pointers,
            symlinks            => $symlinks,
            submodules          => $submodules,
        },
        size_bytes => {
            processed_files_total => $self->_sum_sizes( $state, $results, [ 'files_included', 'files_unmatched' ] ),
            included_files_total  => $self->_sum_sizes( $state, $results, ['files_included'] ),
            lfs_stored_total      => $self->_sum_lfs_stored_sizes($results),
        },
    };
}

# This is the deepest part of the crucible, where a single file's raw state is
# transformed into its final, structured representation.
sub _build_analyzed_file_object {
    my ( $self, $path, $state ) = @_;

    # The classification data arrives as a simple, comma-separated string from
    # Bash. We must parse it into a more useful map for querying.
    my @classifications = split ',', $state->{classification_results}{$path} // '';
    my %class_map       = map { $_ => 1 } grep { $_ } @classifications;

    my $is_oversize = $class_map{oversize} // 0;

    # Per the schema, `content_analysis` is null for oversized files. This
    # ternary logic implements that rule cleanly.
    my $content_analysis = $is_oversize
      ? undef
      : {
          has_null_bytes  => $class_map{binary_null} // 0,
          null_byte_count => $state->{null_byte_counts}{$path} // 0,
          is_valid_utf8   => !$class_map{unsafe_utf8},
        };

    # Here we assemble the final object, mapping raw state keys to schema keys
    # and using the derived classification data.
    return {
        type           => $self->_get_file_type( $state, $path ),
        mode           => $state->{path_to_mode}{$path},
        blob_hash      => $state->{path_to_blob}{$path},
        size_bytes     => $state->{path_to_size}{$path},
        classification => {
            is_concatenatable => $class_map{safe} // 0,
            is_binary_by_attr => $class_map{binary_attr} // 0,
            is_oversize       => $is_oversize,
        },
        content_analysis => $content_analysis,
        symlink_target   => $state->{symlink_details}{$path},
        submodule_url    => $state->{submodule_details}{$path},
        # LFS details are also conditional and nested, per the schema.
        lfs_details => $state->{lfs_details}{$path}
        ? {
            pointer_size_bytes => $state->{path_to_size}{$path},
            stored_size_bytes  => $state->{lfs_details}{$path},
          }
        : undef,
    };
}

# A simpler builder for files that were filtered out before analysis.
sub _build_excluded_file_object {
    my ( $self, $path, $state ) = @_;
    return {
        type       => $self->_get_file_type( $state, $path ),
        mode       => $state->{path_to_mode}{$path},
        blob_hash  => $state->{path_to_blob}{$path},
        size_bytes => $state->{path_to_size}{$path},
    };
}

# Small, focused private helpers that improve readability and prevent code duplication.

sub _get_path_sets {
    my ( $self, $state ) = @_;
    my @all_paths      = sort keys %{ $state->{path_to_blob} };
    my %excluded_paths = map { $_ => 1 } keys %{ $state->{exclusion_results} // {} };
    return ( \@all_paths, \%excluded_paths );
}

sub _get_file_type {
    my ( $self, $state, $path ) = @_;
    return 'submodule' if exists $state->{submodule_details}{$path};
    return 'symlink'   if exists $state->{symlink_details}{$path};
    return 'blob';
}

sub _get_matched_inclusions {
    my ( $self, $file_obj, $inclusion_map ) = @_;
    my @matched;
    # Each line is a business rule, directly mapping a file's property to an
    # inclusion type, gated by the user's requested --include flags.
    push @matched, 'safe'        if $file_obj->{classification}{is_concatenatable} && $inclusion_map->{safe};
    push @matched, 'lfs'         if $file_obj->{lfs_details} && $inclusion_map->{lfs};
    push @matched, 'symlink'     if $file_obj->{type} eq 'symlink' && $inclusion_map->{symlink};
    push @matched, 'submodule'   if $file_obj->{type} eq 'submodule' && $inclusion_map->{submodule};
    push @matched, 'binary_attr' if $file_obj->{classification}{is_binary_by_attr} && $inclusion_map->{binary_attr};
    push @matched, 'oversize'    if $file_obj->{classification}{is_oversize} && $inclusion_map->{oversize};

    if ( my $ca = $file_obj->{content_analysis} ) {
        push @matched, 'binary_null' if $ca->{has_null_bytes} && $inclusion_map->{binary_null};
        push @matched, 'unsafe_utf8' if !$ca->{is_valid_utf8} && $inclusion_map->{unsafe_utf8};
    }
    return @matched;
}

sub _sum_sizes {
    my ( $self, $state, $results, $keys ) = @_;
    my $total = 0;
    for my $key (@$keys) {
        $total += sum map { $_->{size_bytes} // 0 } values %{ $results->{$key} };
    }
    return $total;
}

sub _sum_lfs_stored_sizes {
    my ( $self, $results ) = @_;
    my $total = 0;
    my @processed_files = ( values %{ $results->{files_included} }, values %{ $results->{files_unmatched} } );
    for my $obj (@processed_files) {
        $total += $obj->{lfs_details}{stored_size_bytes} if $obj->{lfs_details};
    }
    return $total;
}

1;
