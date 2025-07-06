project(
    'git-subtree-report',
    version: '1.5.0',
    license: 'AGPL-3.0',
    meson_version: '>=0.56.0',
    default_options: [
        'warning_level=2',
    ]
)

major_version = meson.project_version().split('.')[0]
versioned_name = meson.project_name() + '-' + major_version

# Core program dependencies with version checks
required_programs = [
    { 'name': 'bash',   'version': '>=5.0.0'  },
    { 'name': 'git',    'version': '>=2.20.0' },
    { 'name': 'perl',   'version': '>=5.10.0' },
    { 'name': 'numfmt', 'version': '>=8.25'   }
]

foreach prog : required_programs
    find_program(
        prog['name'],
        version: prog['version'],
        required: true
    )
endforeach

# Installation paths using get_option
script_install_dir = get_option('bindir')
doc_install_dir = get_option('datadir') / 'doc' / meson.project_name()

# Install AppStream metadata for software centers
install_data(
    'data/re.da2ce7.git-subtree-report.metainfo.xml',
    install_dir: get_option('datadir') / 'metainfo'
)

# Install the .desktop file for application launchers
install_data(
    'data/re.da2ce7.git-subtree-report.desktop',
    install_dir: get_option('datadir') / 'applications'
)

# Main executable installation
install_data(
    'bin/git_subtree_report.sh',
    install_dir: script_install_dir,
    install_mode: 'rwxr-xr-x',
    rename: versioned_name
)

# Documentation installation
documentation_files = files(
    'LICENSE.md',
    'README.md'
)

install_data(
    documentation_files,
    install_dir: doc_install_dir
)

# Man Page Installation
man_page_source = 'man/man1/git-subtree-report-1.1'
man_page_basename = man_page_source.split('/')[-1] # e.g., 'git-subtree-report-1.1'
man_page_suffix = man_page_basename.split('-')[-1].split('.')[0] # Extracts '1' from '...-1.1'
assert(man_page_suffix == major_version, 'Man page filename suffix (-' + man_page_suffix + ') does not match project major version (-' + major_version + ').')

install_man(
  man_page_source,
)

# Conditionally install examples directory
examples_exist = run_command(
    'test', '-d', 'examples',
    check: false  # Explicit check handling for Meson >=0.56
).returncode() == 0

if examples_exist
    install_subdir(
        'examples',
        install_dir: doc_install_dir,
        strip_directory: false
    )
endif

# Packaging configuration using modern format
meson.add_dist_script(
    find_program('sh'),
    '-c',
    '''
    cd "@0@"
    install -Dm644 man/man1/git-subtree-report-1.1 -t "$MESON_DIST_ROOT/man/man1"
    install -Dm644 LICENSE.md README.md -t "$MESON_DIST_ROOT"
    cp -rp bin examples "$MESON_DIST_ROOT"
    '''.format(meson.current_source_dir())
)

# Explicit no-op build target for Meson compliance
build_target = custom_target(
    'noop-build',
    output: 'null',
    command: ['echo', 'No compilation required for shell script'],
    build_by_default: true
)
