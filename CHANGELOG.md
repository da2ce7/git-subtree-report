# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
    