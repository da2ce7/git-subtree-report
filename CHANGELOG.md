# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.4.3] - 2025-07-06

### Changed

-   Refined the language and improved the clarity of all historical entries in the `CHANGELOG.md` file for better readability and historical accuracy.

## [1.4.2] - 2025-07-06

### Added

-   Desktop integration files, including AppStream metadata (`.metainfo.xml`) and a `.desktop` entry, allowing the application to be discoverable in Linux software centers and application menus.

### Changed

-   The Meson build system was updated to install the new desktop integration files to their standard system locations.

## [1.4.1] - 2025-07-05

### Fixed

-   Corrected all documentation (`man` page, `README.md`) and report output to accurately state that the `-e` exclusion filter uses Extended Regular Expressions (ERE) and not Perl-compatible regex, aligning the documentation with the actual behavior of Bash's `[[ =~ ... ]]` operator.

## [1.4.0] - 2025-07-05

### Added

-   A new, centralized error handling system (`fail_with`) that provides structured, three-part error messages: a machine-parsable error code, a description of the situation, and actionable advice on how to resolve the issue.

### Changed

-   Replaced all ad-hoc `exit` calls and `trap` commands with the new centralized system for consistent, maintainable, and user-friendly error reporting.
-   Improved `SIGPIPE` handling to provide clearer feedback when output is piped to a command like `head`.

## [1.3.0] - 2025-07-05

### Security

-   Hardened the script against potential Time-of-Check, Time-of-Use (TOCTOU) race conditions. The script now verifies that no component of the path provided via the `-C` argument is a symbolic link before changing directories, preventing malicious path swapping during execution.

## [1.2.0] - 2025-07-04

### Added

-   The report's "Exclusion Details" section now provides full transparency by listing the path and size of every file filtered by an exclusion pattern.

### Changed

-   Report statistics (e.g., file category counts) are now presented with percentages for a clearer at-a-glance analysis of repository composition.
-   Improved the clarity of report labels (e.g., "Total size (included files)") and standardized the formatting of zero-value sizes to remove ambiguity.

## [1.1.1] - 2025-04-18

### Changed

-   Overhauled the installation instructions in `README.md` to use the standard `install` command, provide platform-specific guidance for Linux and Windows, and clarify the Meson build workflow.

## [1.1.0] - 2025-04-18

### Changed

-   Refactored the core analysis engine to be "blob-centric" instead of "path-centric," significantly improving performance on repositories with duplicate file content by analyzing each unique blob only once.
-   Improved code clarity and maintainability by evolving the internal data model to distinguish between path-based properties (e.g., `path_is_symlink`) and content-based properties (e.g., `blob_is_safe`).

## [1.0.2] - 2025-04-17

### Added

-   A comprehensive `man(1)` page providing integrated, offline help, bringing the tool in line with standard UNIX command-line utilities.

### Changed

-   Updated the Meson build system to handle the installation and packaging of the new man page.

## [1.0.1] - 2025-04-17

### Added

-   A `meson.build` file to provide a standardized, dependency-aware method for installing the script and its documentation.
-   Concrete example output files (`repo_commit.txt`, `repo_commit.log`) to the repository for user reference.

### Changed

-   Updated `README.md` with instructions for the new Meson build system.

## [1.0.0] - 2025-04-17

### Added

-   Initial release of `git-subtree-report`.
-   Core functionality for Git tree parsing and file analysis without checkout.
-   Content safety validation system for null bytes, invalid UTF-8, and non-printable characters.
-   Support for submodules, symbolic links, and LFS pointers.
-   Command-line options for specifying repository, subtree, commit reference, and exclusion patterns.
-   Concatenation output mode (`-o`).
-   Comprehensive `README.md`, `LICENSE.md`, and project scaffolding.

[Unreleased]: https://github.com/da2ce7/git-subtree-report/compare/v1.4.2...HEAD
[1.4.2]: https://github.com/da2ce7/git-subtree-report/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/da2ce7/git-subtree-report/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/da2ce7/git-subtree-report/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/da2ce7/git-subtree-report/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/da2ce7/git-subtree-report/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/da2ce7/git-subtree-report/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/da2ce7/git-subtree-report/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/da2ce7/git-subtree-report/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/da2ce7/git-subtree-report/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/da2ce7/git-subtree-report/releases/tag/v1.0.0
