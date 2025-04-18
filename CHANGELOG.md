# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2025-04-17

### Changed

-   **Core Analysis Engine:** Refactored the internal data model from being path-centric to blob-centric. This significantly improves performance on repositories with duplicate files by ensuring that each unique file content (blob) is analyzed only once.
-   **Internal State Management:** Variable names have been updated to clearly distinguish between path-based properties (e.g., `path_is_symlink`) and content-based properties (e.g., `blob_is_safe`), improving code clarity and maintainability.


## [1.0.2] - 2025-04-17

### Added

-   **Documentation:** A comprehensive `man(1)` page for `git-subtree-report`, providing integrated, offline help in the command-line environment.

### Changed

-   **Build System:** The `meson.build` file was updated to handle the installation and packaging of the new man page.


## [1.0.1] - 2025-04-17

### Added

-   **Meson Build System:**
    -   Introduced `meson.build` for standardized installation and packaging.
    -   Added programmatic dependency checks for `bash`, `git`, `perl`, and `numfmt` to ensure a stable environment.
    -   Handles installation of the main script and documentation to standard system paths (`bindir`, `datadir`).
-   **Example Outputs:**
    -   Added `repo_commit.txt` and `repo_commit.log` as concrete examples of the tool's output.

### Changed

-   **README.md:** Updated with new installation instructions for Meson and a reproducible example section.
-   **.gitignore:** Updated to ignore Meson build artifacts while explicitly including the new example log file.
-   **Project Version:** Bumped version to `1.0.1` in all relevant files.


## [1.0.0] - 2025-04-17

### Added

-   **Core Analysis Engine (`git_subtree_report.sh`):**
    -   Initial implementation for Git tree parsing and file analysis without checkout.
    -   Content safety validation system checking for null bytes, invalid UTF-8, and non-printable characters.
    -   Support for bare and standard repositories.
    -   CLI options for specifying target directory (`-C`), subtree (`-t`), Git reference (`-r`), and exclusion patterns (`-e`).
    -   Concatenation output mode (`-o`) for safe files.
-   **Documentation:**
    -   Comprehensive `README.md` with features, installation instructions, usage examples, and technical details.
    -   `LICENSE.md` file containing the GNU Affero General Public License v3.0.
    -   Example output for a repository with zero commits.
-   **Project Structure & Tooling:**
    -   Basic repository layout (`src/`, `examples/`).
    -   `.gitignore` for common OS, editor, and dependency files.
    -   `cSpell.json` for project-specific spelling dictionary.
