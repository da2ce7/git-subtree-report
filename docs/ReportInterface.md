### **Interface Control Document (ICD): `GIT-SUBTREE-REPORT <-> CREATE-MESSAGEPACK`**

**Version:** 1.0.0.review.1
**Status:** Review

This document specifies the complete I/O contract for the `create_messagepack.pl` utility. It defines the mandatory inputs, expected outputs, and a structured error handling protocol to ensure reliable and predictable interaction between the Bash orchestrator (`git-subtree-report`) and the Perl serialization engine (`create_messagepack.pl`).

#### **I. Invocation Signature**

The Bash orchestrator MUST invoke `create_messagepack.pl` with the following signature:

```bash
/path/to/create_messagepack.pl [OPTIONS...] 3<[BASH_STATE_STREAM] <[CONTENT_STREAM]
```

---

#### **II. Input Channels**

##### **A. Primary Input: The `BASH_STATE_STREAM` (File Descriptor 3)**

This stream provides the results of the repository analysis.

*   **Channel:** Auxiliary File Descriptor 3 (`<&3`).
*   **Format:** A continuous stream of UTF-8 text records delimited by the **NULL byte (`\0`)**.
*   **Structure:** Each logical entry is a self-contained record of a single piece of information, represented by three consecutive fields: `[ArrayName]\0[Key]\0[Value]\0`.
    *   `ArrayName` (string): The canonical name of the source Bash associative array (e.g., `path_to_blob`).
    *   `Key` (string): The key within the associative array (typically a file path or blob SHA). **`Key` MUST be a non-empty string.**
    *   `Value` (string): The value associated with the key. An empty string is a valid `Value` and MUST be handled as such.
*   **Stream Integrity:** The stream consumer (`create_messagepack.pl`) MUST validate that the stream consists of a complete set of `[ArrayName]\0[Key]\0[Value]\0` triples. An End-Of-File (EOF) condition encountered in the middle of a triple is a fatal error, signaling a malformed stream (Exit Code Domain `40-59`).
*   **Generation (Informational):** The Bash orchestrator is expected to generate the `BASH_STATE_STREAM` by iterating through its associative arrays and using multiple `printf "[ArrayName]\0[Key]\0[Value]\0"` calls. This method is required to guarantee stream integrity, especially for keys or values containing special characters.
*   **Required `ArrayName`s:** To construct a valid report, `create_messagepack.pl` MUST receive at least one record for each of the following **core metadata** array names: `path_to_blob`, `path_to_size`, `path_to_mode`. It is a fatal error (Exit Code Domain `40-59`) if any of these are missing entirely from the stream. The script MUST also be prepared to handle streams that contain zero records for the following **optional feature** arrays: `lfs_details`, `symlink_details`, `submodule_details`, `classification_results`, `exclusion_results`.
    *   `path_to_blob`: `path -> blob_hash`. The mapping of a file path to its Git blob SHA.
    *   `path_to_size`: `path -> size_bytes`. The mapping of a file path to its blob size in bytes.
    *   `path_to_mode`: `path -> mode_string`. The mapping of a file path to its Git mode string (e.g., `100644`).
    *   `lfs_details`: `path -> stored_size_bytes`. Contains mappings for files identified as LFS pointers. May be empty.
    *   `symlink_details`: `path -> target_path`. Contains mappings for files identified as symbolic links. May be empty.
    *   `submodule_details`: `path -> url`. Contains mappings for files identified as submodules. May be empty.
    *   `classification_results`: `path -> comma_separated_classifications`. Results of the Bash-side safety and type analysis (e.g., `safe,binary_null`).
    *   `exclusion_results`: `path -> reason_string`. A map of all paths excluded by pattern. The value is a constant string (e.g., "Excluded by pattern"). May be empty.
*   **Example Stream Segment:**
    `path_to_blob\0src/main.c\0c8e6b3b\0path_to_size\0src/main.c\01024\0path_to_mode\0src/main.c\0100644\0classification_results\0src/main.c\0safe\0...`

##### **B. Configuration Input: Command-Line Options (`@ARGV`)**

These options provide top-level metadata and configure the encoder's behavior. All options are **mandatory**. Values MUST undergo semantic validation by the consumer.

*   `--schema-version=s`
    *   **Description:** The semantic version of the schema contract.
    *   **Example:** `--schema-version="1.0.0"`
*   `--tool-version=s`
    *   **Description:** The semantic version of the `git-subtree-report` tool.
    *   **Example:** `--tool-version="1.5.0"`
*   `--commit-hash=s`
    *   **Description:** The full 40-character commit SHA. The value MUST match the regex `^[0-9a-f]{40}$`.
    *   **Example:** `--commit-hash="c8e6b3b9f1d4a0b3e5a7f9c8d1a3b2c4e0f1d2e3"`
*   `--timestamp-utc=s`
    *   **Description:** The report generation timestamp. The value MUST be a valid ISO 8601 string.
    *   **Example:** `--timestamp-utc="2023-10-27T12:34:56Z"`
*   `--repository-root=s`
    *   **Description:** The absolute path to the repository root.
*   `--target-subtree=s`
    *   **Description:** The relative path of the analyzed subtree.
*   `--exclusion-pattern=s`
    *   **Description:** The ERE pattern used for exclusions. An empty string (`""`) signifies no pattern was used.
*   `--max-file-size-bytes=i`
    *   **Description:** An integer representing the file size limit for content analysis. The value MUST be a non-negative integer (>= 0).
*   `--inclusion-types=s`
    *   **Description:** A comma-separated string listing the inclusion criteria used for the final report.
    *   **Example:** `--inclusion-types="safe,lfs"`
*   `--embed-content`
    *   **Description:** A boolean flag. If present, indicates that `create_messagepack.pl` MUST expect and process the `CONTENT_STREAM` on STDIN, and subsequently include the `embedded_content` key in the final output object. If absent, the `CONTENT_STREAM` will be empty, and the `embedded_content` key MUST be omitted from the output.

##### **C. Optional Input: The `CONTENT_STREAM` (Standard Input)**

This stream provides raw file contents for embedding in the final report.

*   **Channel:** Standard Input (`STDIN`).
*   **Condition:** This stream is **only active if the `--embed-content` flag is provided**.
*   **Format:** The raw binary output of `git cat-file --batch`.
*   **Error Handling:** `create_messagepack.pl` MUST correctly parse the `git cat-file --batch` protocol.
    *   If it encounters a line matching the format `[40-char-sha] missing\n`, it MUST treat this as a fatal error, as it signifies a requested blob could not be provided by the orchestrator (Exit Code Domain `40-59`).
    *   Similarly, if the `--embed-content` flag is present but the `CONTENT_STREAM` provides an immediate End-Of-File without any data, this is a fatal contract violation (Exit Code Domain `40-59`).

---

#### **III. Output Channels**

##### **A. Primary Output: The `MESSAGEPACK_OBJECT_STREAM` (Standard Output)**

*   **Channel:** Standard Output (`STDOUT`).
*   **Format:** A single, raw binary object encoded with the **MessagePack specification**. The output stream MUST be opened in binary mode (`binmode`).
*   **Content:** The object MUST strictly conform to the schema defined in `audit_messagepack.pl`.

##### **B. Diagnostic Output: The `DIAGNOSTIC_STREAM` (Standard Error)**

This stream is for human consumption and machine diagnostics only.

*   **Channel:** Standard Error (`STDERR`).
*   **Format:** Human-readable, UTF-8 encoded text lines.
*   **Content:**
    1.  **On Success:** The stream MUST output a single line of text formatted as follows: `SUCCESS: Generated MessagePack object ([byte_count] bytes)`.
    2.  **On Failure:** MUST print a single, clear, multi-line error message prefixed with `FATAL: `. The message should describe the exact point of failure. It MUST then exit with the appropriate code from the structured exit code table below.
*   **Structured Exit Codes:** To provide granular error reporting, `create_messagepack.pl` adheres to the following exit code domains. The specific codes within these ranges will be defined during implementation.
    *   **[`0`] Success**
        *   **Condition:** The operation completed successfully. The `MESSAGEPACK_OBJECT_STREAM` is valid and complete.

    *   **[`1`] Unhandled Exception / Internal Bug**
        *   **Condition:** Reserved exclusively for an unexpected, unhandled exception within the Perl script.
        *   **Meaning:** This signals a likely programming error (a bug) in `create_messagepack.pl` itself. It is the catch-all for failures not covered by the specific domains below.

    *   **[`2-19`] Prerequisite Failures (Environment & Dependencies)**
        *   **Condition:** The script cannot run due to a missing requirement on the host system.
        *   **Example:** A required Perl module (like `Data::MessagePack`) is not installed.

    *   **[`20-39`] Invocation & Usage Errors**
        *   **Condition:** The script was called with invalid, missing, or improperly formatted command-line options (`@ARGV`).
        *   **Example:** A mandatory option like `--commit-hash` is missing; a value for an integer option is not a valid non-negative integer.

    *   **[`40-59`] Input Data & Stream Errors**
        *   **Condition:** The input data received via the streams (`BASH_STATE_STREAM` or `CONTENT_STREAM`) is malformed, incomplete, or violates the contract's expectations.
        *   **Example:** The `BASH_STATE_STREAM` is malformed and cannot be parsed; a core `ArrayName` is missing from the stream; a requested blob is reported as `missing` in the `CONTENT_STREAM`.

    *   **[`60-69`] Output & System Resource Failures**
        *   **Condition:** The script was unable to complete its output due to a system-level constraint.
        *   **Example:** A write error occurs on STDOUT (e.g., disk full); the system runs out of memory during data assembly.
