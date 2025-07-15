# git-wmf: A MessagePack-based Git Worktree Manifest Format

**Version:** 1.0.0-draft.1
**Author(s):** Cameron Garnham
**Date:** July 15, 2025

## Abstract

This document specifies `git-wmf`, a binary format for transmitting one or more Git worktrees. It provides a self-contained, verifiable, schema-first representation of a Git directory structure and its data, independent of repository metadata such as the .git directory or references like branches and tags. The format is compact for transmission, fast to parse, and supports complex states including LFS objects, symlinks, and per-blob metadata.

## Change Log

- **1.0.0-draft.1:** Initial Draft

## 1. Introduction

### 1.1. Purpose

This format addresses the need for an efficient, parsable mechanism to transmit a Git directory's state and data without requiring the original repository or its references, making it suitable for APIs, archival, and inter-system transfers. Example use cases include CI/CD pipelines transmitting build artifacts as verifiable worktrees, code review APIs providing preview snapshots, or backup systems archiving directory states with integrity checks.

### 1.2. Design Goals

The `git-wmf` format is guided by the following principles:

- **Verifiability:** Core data structures can be cryptographically verified against native Git hashes, ensuring data integrity and provenance.
- **Self-Contained:** A `git-wmf-manifest` contains all information and data necessary to reconstruct the specified worktrees, which may include all, some, or none of the underlying file content.
- **Transmission-Oriented:** The format is optimized for network transport and fast client-side parsing, rather than for random-access storage which has different design constraints.
- **Schema-First:** The structure is rigid and independent of the data it contains. Keys are static `unicode` literals, aligning with MessagePack map keys (str types), which simplifies parsing into strongly-typed languages.
- **Extensible:** The format supports future additions via optional components and allows for custom metadata, ensuring forward compatibility (see [Section 8.6: Using Custom Extension Keys]).

For interoperability, `git-wmf` complements existing Git tools like git-bundle (for full repo transfers) or git-archive (for snapshots), but focuses on worktree states without requiring packfiles or repository history.

| Feature          | git-wmf               | git-bundle      | git-archive          |
| :--------------- | :-------------------- | :-------------- | :------------------- |
| Includes History | No                    | Yes             | No                   |
| Self-Contained   | Yes (worktree state)  | Yes (full repo) | Yes (snapshot)       |
| Verifiability    | Git hashes + LFS      | Git objects     | Tar/Zip checksums    |
| Use Case         | Transmission/Archival | Repo transfer   | Single commit export |

### 1.3. How to Read This Document

This specification is structured for clarity and ease of reference:

- Start with [Section 2: Terminology and Conventions] for keywords and the Glossary as a master index.
- Understand the rules in [Section 3: Core Principles of the Manifest].
- Refer to [Section 5: Component Schemas] for normative structures, with tables and CDDL links.
- Follow [Section 7: Visual Guide to Cryptographic Verification] for validation logic.
- Use [Section 8: Implementation Guidance] for practical advice.
- Consult [Appendix B: CDDL Specification] as the machine-readable truth.

For **Generators**: Focus on [Section 3] and [Section 5]. For **Consumers**: Emphasize [Section 7] and [Section 8]. For auditors: Prioritize [Section 9: Security Considerations]. Use the Glossary for lookups—each entry links to details. References are [Section X.Y: Short Title].

## 2. Terminology and Conventions

### 2.1. Keywords

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119. Keywords are uppercase as per RFC 2119.

### 2.2. Glossary (Informative)

This table defines terms that describe important concepts, processes, or implementation patterns that are not part of the normative schema but are essential for understanding the design and intended use of the `git-wmf` format.

| Term                                | Definition                                                                                                                                                                                                                                    |
| :---------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Bi-Directional LFS Verification** | The two-part process (detailed in **[Section 7.3]**) that validates both the resolved LFS content against its OID and the reconstructed LFS pointer blob against its Git hash, establishing a complete **Chain of Trust**.                    |
| **Chain of Trust**                  | A security concept wherein the integrity of a whole system (the manifest) is guaranteed by cryptographically verifying each link, from the root trees down to the individual content blobs, as detailed in **[Section 7]**.                   |
| **Client-Side Cataloging**          | A RECOMMENDED process where a **Consumer** builds in-memory maps from manifest arrays (e.g., `trees`, `catalog`) for efficient O(1) data lookups by hash, avoiding costly linear scans (see guidance in **[Section 8.1]**).                   |
| **Cryptographic Downgrade Attack**  | A security threat where an attacker modifies data to remove a strong cryptographic guarantee (e.g., SHA-256) and force reliance on a weaker one (e.g., SHA-1). The Rule of Information Enrichment (**[Section 3.3.1]**) helps prevent this.   |
| **Deterministic Serialization**     | The property that a given set of content will always produce the exact same binary manifest byte-for-byte. This is a key benefit of the Principle of Sorted Components (**[Section 3.5]**), simplifying replication and verification.         |
| **Disconnected Set**                | The normative state where no tree in a set of roots is a descendant of another tree. This is a direct consequence of the **Principle of Minimal Roots ([Section 3.2])**, which ensures each root is a truly top-level entry point.            |
| **Information Enrichment**          | The principle (see **[Section 3.3.1]**) that a subtree may contain _more_ hash information (e.g., a child has SHA-1 and SHA-256) than its parent (e.g., parent has only SHA-256), but never less.                                             |
| **LFS Detection**                   | The process of identifying a blob's content as a valid Git LFS pointer based on its format and structure, independent of any file path or `git-mode`, as required by **[Section 3.7]**.                                                       |
| **Manifest Signing**                | An external security process to provide cryptographic proof of the manifest's origin (see notes in **[Section 9]**).                                                                                                                          |
| **Path Traversal**                  | A security vulnerability where an attacker uses path components (e.g., `../`) in data like symlink targets or filenames to access files outside the intended destination directory (see notes in **[Section 9]**).                            |
| **Reversible Name Mangling**        | A recommended strategy for handling filenames with invalid characters or case-collisions on a target filesystem, as described in **[Section 8.3]**. The name is transformed in a way that can be reversed to recover the original `git-name`. |
| **Sparse Checkout**                 | A Git feature where only a subset of a repository's worktree is populated. This is a primary use case for `git-wmf` which can be represented with multiple roots, as discussed in **[Section 8.3.2]**.                                        |
| **Stub / Stubbed Object**           | A general term for any entry pointing to content intentionally omitted from the manifest, indicated by a disposition of `"omitted"`. See implementation guidance in **[Section 8.3]**.                                                        |
| **Verifiability**                   | The core design goal that a **Consumer** can cryptographically validate that an object's content correctly matches its declared hash, as detailed in **[Section 7]**.                                                                         |

### 2.2.1 Actor Terms

This subsection defines the key roles that software implementations will fulfill when interacting with the `git-wmf` format.

| Term          | Definition                                                                                                                                                                                                                                                     |
| :------------ | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Consumer**  | Any software application or service that parses and interprets a `git-wmf-manifest`. The **Consumer** is responsible for validating the manifest's structural and cryptographic integrity before trusting and using its contents.                              |
| **Generator** | Any software application or service that creates a `git-wmf-manifest`. The **Generator** is responsible for correctly populating all required fields, sorting arrays per the specification, and ensuring the cryptographic congruence of all data it produces. |

### 2.3. Glossary (Normative)

This section defines terms that have a specific, normative meaning within this document. Each term provides a short description and a direct link to its primary, detailed definition in the specification.

### 2.3.1. Manifest Structural Components

| Term               | Primary Definition | Description                                                                           |
| :----------------- | :----------------- | :------------------------------------------------------------------------------------ |
| `git-wmf-manifest` | **[Section 4]**    | The entire, self-contained `git-wmf` payload, whose root is a MessagePack `map`.      |
| `meta`             | **[Section 5.2]**  | The REQUIRED top-level `map` containing contextual metadata about the manifest.       |
| `roots`            | **[Section 5.3]**  | The REQUIRED top-level `array` serving as entry points to the worktree(s).            |
| `trees`            | **[Section 5.4]**  | The REQUIRED top-level `array` containing the pool of all directory structures.       |
| `catalog`          | **[Section 5.5]**  | The OPTIONAL top-level `array` serving as a descriptive index for every unique blob.  |
| `blobs`            | **[Section 5.5]**  | The OPTIONAL top-level `array` containing the pool of all included blob content.      |
| `lfs`              | **[Section 5.6]**  | The OPTIONAL top-level `array` containing the pool of included, resolved LFS objects. |

### 2.3.2. Object Definitions

| Term                    | Primary Definition  | Description                                                                                |
| :---------------------- | :------------------ | :----------------------------------------------------------------------------------------- |
| `root-pointer-object`   | **[Section 5.3.1]** | An object in the `roots` array that identifies a single root tree by its hash(es).         |
| `git-tree-object`       | **[Section 5.4.1]** | An object in the `trees` array that represents a Git tree (a directory).                   |
| `entry-object`          | **[Section 5.4.2]** | An object in a `git-tree-object`'s `entries` array representing a single directory entry.  |
| `catalog-entry-object`  | **[Section 5.5.1]** | An object in the `catalog` that associates a blob's hash(es) with its `attributes`.        |
| `git-blob-object`       | **[Section 5.5.3]** | An object in the `blobs` array that pairs a blob's hash(es) with its raw `binary` content. |
| `lfs_v1-object`         | **[Section 5.6.1]** | An object in the `lfs` array that contains verification data for a specific LFS object.    |
| `commit-pointer-object` | **[Section 5.2.2]** | A `map` containing the hash(es) of a Git commit, used for reference in `meta`.             |

### 2.3.3. Core Attributes and Keys

| Term                          | Primary Definition    | Description                                                                              |
| :---------------------------- | :-------------------- | :--------------------------------------------------------------------------------------- |
| `attributes`                  | **[Section 5.5.2]**   | The REQUIRED `map` within a `catalog-entry-object` containing descriptive properties.    |
| `disposition-enum`            | **[Section 5.1.3]**   | A `unicode` enum (`"included"` or `"omitted"`) indicating content presence.              |
| `git-blob-size`               | **[Section 5.5.3]**   | A `size_string` of a blob's length, used for Git header verification.                    |
| `git-hash_sha1`               | **[Section 5.1.1]**   | A `sha1_binary` value representing the SHA-1 hash of a Git object.                       |
| `git-hash_sha256`             | **[Section 5.1.1]**   | A `sha256_binary` value representing the SHA-256 hash of a Git object.                   |
| `git-mode`                    | **[Section 5.1.2]**   | A `unicode` enum for the file type and permissions of an `entry-object`.                 |
| `git-name`                    | **[Section 5.4.2]**   | A `binary` byte sequence for the name of a tree entry; MUST NOT contain null bytes.      |
| `git-tree_...-size`           | **[Section 5.4.1]**   | A `size_string` of a tree's entry content length, used for Git header verification.      |
| `lfs_v1-oid`                  | **[Section 5.6.1]**   | A `lfs_v1_oid_hex` representing the unique object ID from an LFS pointer.                |
| `norm-blob-content-type-enum` | **[Section 5.1.4]**   | An enum within `attributes` that classifies blob content (e.g., `"normal"`, `"lfs_v1"`). |
| `norm-lfs-version-enum`       | **[Section 5.1.5.2]** | A controlled `unicode` vocabulary identifying a supported LFS pointer specification.     |
| `partition`                   | **[Section 3.5]**     | A logical division within an `array` where objects of a specific subtype are grouped.    |

### 2.3.4. Data Types and Primitives

This subsection defines the foundational data types and logical primitives from MessagePack and CDDL used to construct the manifest. It maps human-readable terms to their formal CDDL definitions.

| Human Term / Primitive   | Definition and CDDL Mapping                                                                               | CDDL Rule                                                               |
| :----------------------- | :-------------------------------------------------------------------------------------------------------- | :---------------------------------------------------------------------- |
| `array`                  | A MessagePack `array`: an ordered, zero-indexed sequence of values. Example: The `roots` component.       | `[]`                                                                    |
| `binary`                 | An opaque sequence of bytes.                                                                              | `bstr`                                                                  |
| `boolean`                | A true/false value.                                                                                       | `bool`                                                                  |
| `enum`                   | A controlled vocabulary of allowed `unicode` values. Represented in CDDL using the choice operator (`/`). | `/`                                                                     |
| `group`                  | A CDDL construct to define a reusable collection of key-value pairs. Represented by parentheses (`()`).   | `()`                                                                    |
| `hex_string`             | A hexadecimal lowercase string (e.g., `"a1b2c3"`).                                                        | `tstr .regexp "^[0-9a-f]+$"`                                            |
| **`iso8601_utc_string`** | A UTC timestamp in ISO 8601 format, RFC 3339 (e.g., `"2025-07-15T12:00:00.123Z"`).                        | `tstr .regexp "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?Z$"` |
| `lfs_v1_oid_hex`         | A lowercase hexadecimal string of exactly 64 characters.                                                  | `tstr .regexp "^[0-9a-f]{64}$"`                                         |
| `map`                    | A MessagePack `map`: an unordered collection of key-value pairs. Represented by curly braces (`{}`).      | `{}`                                                                    |
| `mode_blob_string`       | A string enum for blob-like Git modes.                                                                    | `"100644" / "100755" / "120000"`                                        |
| `mode_commit_string`     | A string enum for Git submodule mode.                                                                     | `"160000"`                                                              |
| `mode_tree_string`       | A string enum for Git directory mode.                                                                     | `"040000"`                                                              |
| `natural_number`         | A non-negative integer.                                                                                   | `uint`                                                                  |
| `semver_string`          | A `unicode` string conforming to the **Semantic Versioning 2.0.0** (`https://semver.org`) standard.       | `semver-string`                                                         |
| `sha1_binary`            | A binary sequence of exactly 20 bytes.                                                                    | `bstr .size 20`                                                         |
| `sha256_binary`          | A binary sequence of exactly 32 bytes.                                                                    | `bstr .size 32`                                                         |
| `size_string`            | An ASCII numeric string representing a non-negative integer.                                              | `tstr .regexp "^(0\|[1-9][0-9]*)$"`                                     |
| `unicode`                | A UTF-8 encoded text string.                                                                              | `tstr`                                                                  |

## 3. Core Principles of the Manifest

### 3.1. Principle of Cryptographic Congruence

#### 3.1.1. Definition

The Principle of Cryptographic Congruence ensures that the manifest's core structures align directly with the data streams required by Git's native hashing algorithms. This enables a **Consumer** to verify the integrity of manifest data using standard Git verification logic, establishing a direct **Chain of Trust** from the manifest back to the source Git objects.

This verification is performed by constructing a byte stream according to the canonical Git object format, as defined in **[Section 7: Visual Guide to Cryptographic Verification]**, and comparing its hash against the corresponding hash provided in the manifest.

#### 3.1.2. The Cryptographic Boundary

To support this principle, all keys in the `git-wmf` schema use a prefix system to clearly delineate what is inside and outside the cryptographic chain.

| Prefix    | Role                                                                                                                                                                                                                | Example Keys                                      |
| :-------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | :------------------------------------------------ |
| `git-`    | **Cryptographic.** Part of the native Git hash chain. These fields provide the exact data (hashes, modes, names, sizes) needed to reconstruct and verify a `git-blob-object` or `git-tree-object`.                  | `git-hash_sha256`, `git-name`, `git-blob-size`    |
| `lfs_v1-` | **Cryptographic.** Part of the LFS hash chain. These fields provide the data needed for the bi-directional verification of a Git LFS object and its corresponding pointer blob.                                     | `lfs_v1-oid`, `lfs_v1-size`, `lfs_v1-content`     |
| `norm-`   | **Verifiable Metadata.** Normative data that is not part of a Git hash, but is schema-verifiable or represents a required state (e.g., content disposition). Must be trusted only after its assertions are checked. | `norm-schema_version`, `norm-disposition`         |
| `hint-`   | **Non-Verifiable Hint.** Non-normative, informational data provided for optimization or context. A **Consumer** SHOULD NOT rely on this data for security or integrity checks.                                      | `hint-generator_name`, `hint-mime`, `hint-binary` |

#### 3.1.3. Application to Core Objects

- A `git-tree-object` contains all, and only, the data needed for hash reconstruction: the pre-computed entry stream size (`git-tree_...-size`) and the sorted list of `entries`.
- A `git-blob-object` provides the raw content (`git-content`) and its pre-computed size (`git-blob-size`) necessary for blob hash verification.
- An `lfs_v1-object` contains all data needed for bi-directional verification: the resolved content (`lfs_v1-content`) to verify against its OID, and the metadata (`lfs_v1-size`, `git-blob-size`) needed to reconstruct and verify the original LFS pointer blob.

The use of pre-computed size fields (e.g., `git-blob-size`, `git-tree_sha256-size`) is a critical design feature. It allows a **Consumer** to construct the correct Git object header for verification without first measuring the content (avoiding a "two-pass" read), which enables more efficient, stream-based parsing.

### 3.2. Principle of Minimal Roots

A manifest's `roots` array defines the set of independent worktrees it contains. To be a valid, minimal set, **no tree referenced by one `root-pointer-object` may be a descendant of a tree referenced by another `git-tree-object` anywhere in the manifest.**

#### 3.2.1. Rationale

This principle ensures that the `roots` array is the smallest possible set of pointers required to define the worktree structure. It prevents redundant or conflicting top-level definitions. If this rule were violated, one root would be a subdirectory of another, making its inclusion in the `roots` array superfluous and the structure logically inconsistent.

**Note on Shared Descendants:** This principle does **not** forbid two different roots from sharing a common descendant subdirectory. Sharing common parts of a directory structure is a valid and efficient form of structural deduplication, analogous to two different file entries pointing to the same content blob, and is a key benefit of a DAG-based format.

#### 3.2.2. Validation and Examples

A **Consumer** MUST validate this property at runtime. A simple and efficient way to do this is to gather all subdirectory hashes from the entire manifest into a single set, and then verify that no hash from the `roots` array appears in that set of children.

**VALID: Roots with a Shared Descendant**
This manifest is valid. `root_A` and `root_B` are distinct, and while they share a common subdirectory (`common_dir`), neither root is a descendant of another tree.

```
Manifest Roots: {root_A_hash, root_B_hash}

  root_A_hash              root_B_hash
   /      \                  /      \
child_A  common_dir_hash   child_B  common_dir_hash
```

**INVALID: Non-Minimal (Nested) Roots**
This manifest is invalid because `root_B` is a descendant of `root_A`. The `roots` set is not minimal. A **Consumer** MUST reject this.

```
Manifest Roots: {root_A_hash, root_B_hash}  <-- INVALID

  root_A_hash
  /        \
child_A   root_B_hash  <-- Also defined as a root
```

#### 3.2.3. Pseudocode Example for Validation

The following pseudocode implements the efficient linear scan validation. It assumes `root_hashes` is a list of binary hashes extracted from the `roots` array and `all_trees` is the list of all `git-tree-object`s from the manifest.

```python
def validate_minimal_roots(root_hashes, all_trees):
    """
    Validates that the set of roots is minimal by ensuring no root is also
    a descendant tree within the manifest.
    """
    # Step 1: Create a single set of all tree hashes that are referenced
    # as entries (i.e., are subdirectories of any other tree).
    all_child_tree_hashes = set()
    for tree_object in all_trees:
        for entry in tree_object.get('entries', []):
            if entry['git-mode'] == '040000': # It's a subdirectory entry
                # Extract hash from the entry's hash-group
                child_hash = entry.get('git-hash_sha256') or entry.get('git-hash_sha1')
                if child_hash:
                    all_child_tree_hashes.add(child_hash)

    # Step 2: Verify that no root hash appears in the set of child trees.
    for root_hash in root_hashes:
        if root_hash in all_child_tree_hashes:
            raise OverlapError(
                f"Root with hash {root_hash.hex()} is also a child of another tree, "
                "violating the Principle of Minimal Roots."
            )

    # If the loop completes, the roots are valid.
    return True
```

### 3.3. Principle of Descendant Hash Consistency

This principle ensures that the cryptographic guarantees made by a parent tree are maintained throughout its entire descendant structure, creating an unbreakable **Chain of Trust**. The fundamental rule is: **A child entry MUST provide every hash algorithm guaranteed by its parent.**

Subtrees may add stronger hash information in one specific case (**Enrichment**), but they MUST NOT remove a hash guaranteed by the parent (**Downgrade**). This prevents a **Consumer** from starting a verification down a specific hash path only to find it cannot be completed.

_Note:_ This guarantee is terminated for any subtree explicitly marked as stubbed (`norm-disposition: "omitted"`), as detailed in **[Section 8.3: Handling Special Entry Types]**.

---

#### 3.3.1. VALID Transitions

The following transitions preserve or enrich the parent's cryptographic guarantees and are **VALID**.

##### **Preservation**

The child entry provides the exact same set of hash algorithms as its parent.

```
// Preservation (SHA-256)
Parent (SHA-256 only)
|
+-- Child (SHA-256 only)  // VALID


// Preservation (SHA-1)
Parent (SHA-1 only)
|
+-- Child (SHA-1 only)  // VALID


// Preservation (Dual Hash)
Parent (SHA-256 + SHA-1)
|
+-- Child (SHA-256 + SHA-1)  // VALID
```

##### **Enrichment (The Only Allowed Case)**

A parent with only a SHA-256 hash points to a child that has both SHA-256 and SHA-1 hashes. This strengthens the information in the manifest without violating the parent's guarantee.

```
Parent (SHA-256 only)
|
+-- Child (SHA-256 + SHA-1)  // VALID
```

**Rationale:** This is the only form of enrichment permitted. It allows a modern, SHA-256-first manifest to include verifiable legacy SHA-1 information where available.

---

#### 3.3.2. INVALID Transitions

Any transition not explicitly listed as VALID is **INVALID**. The following diagrams illustrate common failure cases that **Generators** MUST NOT produce and **Consumers** MUST reject.

##### **Fatal Downgrade**

The child entry is missing a hash algorithm that its parent guarantees. This breaks the parent's verification chain.

```
// Downgrade from Dual-Hash Parent
Parent (SHA-256 + SHA-1)
|
+-- Child (SHA-256 only)  // INVALID: Breaks parent's SHA-1 chain.
|
+-- Child (SHA-1 only)    // INVALID: Breaks parent's SHA-256 chain.


// Downgrade (Hash Switching) from SHA-1 Parent
Parent (SHA-1 only)
|
+-- Child (SHA-256 only)  // INVALID: Breaks parent's only SHA-1 chain.
```

##### **Disallowed Enrichment**

Enrichment starting from a SHA-1-only parent is forbidden.

```
Parent (SHA-1 only)
|
+-- Child (SHA-256 + SHA-1)  // INVALID
```

**Rationale:** This is disallowed to enforce a strict "strong-to-weak" information flow. Permitting this would allow a weak hash (SHA-1) to define a relationship to a strong one (SHA-256), which violates the security posture of the **Principle of Unambiguous References ([Section 3.6])**.

### 3.4. Principle of Universal Content Identity

The `trees` component defines structure. The `catalog` and `blobs` components define content properties. A blob's size and hashes are definitive, independent of referencing paths.

A **Generator** SHOULD include both `git-hash_sha1` and `git-hash_sha256` in a `catalog-entry-object` if known.

### **3.5. Principle of Sorted Components**

All top-level data arrays (`roots`, `trees`, `catalog`, `blobs`, `lfs`) MUST be strictly and verifiably ordered. This principle is fundamental to the format's design, as it guarantees **Deterministic Serialization**—ensuring that a given set of content always produces a byte-for-byte identical manifest. This predictability simplifies replication and verification, and it enables efficient O(log n) lookups (e.g., via binary search) for **Consumers**, a critical feature for memory-constrained environments as detailed in **[Section 8.1.2]**.

The ordering for these top-level arrays follows a simple two-step logic: objects are first **partitioned**, then **sorted** within each partition.

- Git object arrays are partitioned by hash algorithm (`_sha256` first, then `_sha1_only`).
- The `lfs` array is partitioned by version, with newer versions first as defined in the mapping table in **[Section 5.1.5.2]**.

Within each partition, all objects MUST be sorted lexicographically by their primary identifier's raw bytes (e.g., `git-hash_sha256` or the decoded `lfs_v1-oid`). **Generators** MUST enforce this order and uniqueness. **Consumers** MUST verify it during parsing as a required conformance check (**[Section 8.7]**); an unsorted or non-unique array renders the manifest invalid.

A separate but equally important sorting rule applies to the nested `entries` array within each `git-tree-object`. To maintain cryptographic congruence with native Git, the `entries` array is not sorted by hash. Instead, it MUST be sorted lexicographically by the raw bytes of each entry's `git-name`. This critical requirement is normatively defined in the `git-tree-object` schema in **[Section 5.4.1]**.

### **3.6. Principle of Unambiguous References**

To guarantee the integrity of all object references and protect against hash collision attacks, every pointer within the manifest MUST resolve to exactly one object without ambiguity. This principle is a critical security control, especially given the inclusion of the legacy SHA-1 algorithm, as discussed in the security considerations in **[Section 9.5]**.

A `git-hash_sha1` is considered **ambiguous** if more than one distinct object in the manifest (differentiated by their `git-hash_sha256`) shares the same SHA-1 value. The central rule is:

**If a `git-hash_sha1` is ambiguous, it is forbidden to use it as the sole means of reference for an object.** Any pointer to that object MUST be resolved using its `git-hash_sha256` to provide the required precision.

While a `git-hash_sha1` may be reused, the unique pair of (`git-hash_sha256`, `git-hash_sha1`) MUST be globally unique for every object that declares both.

- A **Generator** is responsible for tracking all hashes and ensuring it never produces a manifest that violates this rule.
- A **Consumer** MUST verify this property during parsing; using a hash map with composite keys during the **Client-Side Cataloging** step (**[Section 8.1]**) is the recommended method for enforcement. If any ambiguous `git-hash_sha1` is found to be used as a sole reference, the manifest is invalid and MUST be rejected as a required conformance check (**[Section 8.7]**).

### **3.7. Principle of Verifiable LFS Classification**

To ensure the integrity of large file handling, the classification of a blob as a Git LFS pointer is a verifiable claim, not an opaque assertion. This principle establishes a complete, cryptographically verifiable link from the resolved LFS content all the way back to its entry in the directory tree.

- A **Generator** `MUST` analyze blob content. If it determines a blob is a valid LFS pointer, it `MUST` provide the complete set of corresponding objects: the `lfs_v1-object` in the `lfs` array, the pointer's `git-blob-object` in the `blobs` array, and its `catalog-entry-object`.

- A **Consumer** `MUST` treat this set of objects as a claim to be verified. The `lfs_v1-object` itself is a self-contained "verification packet." From the data within it, a Consumer can programmatically reconstruct the LFS pointer blob's content and calculate its Git hash. This calculated hash provides the cryptographic proof needed to validate the provided `catalog-entry-object`, `git-blob-object`, and its reference from an `entry-object` in a tree.

This independent verification is the core of the **Bi-Directional Verification of a v1 LFS Object** (**[Section 7.3]**) and is a important step in establishing a complete **Chain of Trust** for any LFS content.

## 4. Manifest Top-Level Structure

The root object of a `git-wmf-manifest` is a single MessagePack `map`. This map contains a set of REQUIRED and conditionally present keys that together define the manifest's metadata, directory structure, and file content.

```
git-wmf-manifest (map)
├── "meta":    {...}              (REQUIRED - Context)
├── "roots":   [...]              (REQUIRED - Worktree Entry Points)
├── "trees":   [...]              (REQUIRED - Directory Pool)
│
├── "catalog": [...] (Conditional - Blob Descriptions)
├── "blobs":   [...] (Conditional - Blob Content)
└── "lfs":     [...] (Conditional - Resolved Large File Content)
```

A conforming **Consumer** implementation MUST adhere to the following top-level rules:

- It MUST be able to parse a manifest that contains only the REQUIRED components (`meta`, `roots`, `trees`).
- It MUST validate the logical dependency rules for component presence as defined in **[Section 4.2]**. For instance, a manifest containing an `lfs` array MUST also contain `blobs`, `catalog`, `trees`, and `roots`.
- All top-level `array` components MUST be sorted and partitioned as described in the **Principle of Sorted Components ([Section 3.5])**.
- The `roots` array MUST conform to the **Principle of Minimal Roots ([Section 3.2])**.

The table below details each top-level key.

| Key       | Type          | Section | Status¹     | Description                                                                                                                      |
| :-------- | :------------ | :------ | :---------- | :------------------------------------------------------------------------------------------------------------------------------- |
| `meta`    | map           | 5.2     | REQUIRED    | Contextual metadata about the manifest itself, such as schema version and generator info.                                        |
| `roots`   | array of maps | 5.3     | REQUIRED    | An array of pointers defining the entry points into one or more worktrees. Must be empty if `trees` is empty.                    |
| `trees`   | array of maps | 5.4     | REQUIRED    | The complete, deduplicated pool of all `git-tree-object`s, which collectively define the manifest's directory structures.        |
| `catalog` | array of maps | 5.5     | CONDITIONAL | The central descriptive catalog for every unique blob referenced in the `trees`. MUST be present if `blobs` or `lfs` is present. |
| `blobs`   | array of maps | 5.5     | CONDITIONAL | The pool of included `git-blob-object`s. MUST be present if the `lfs` array is present.                                          |
| `lfs`     | array of maps | 5.6     | CONDITIONAL | The pool of included, resolved large-file objects. Its presence requires all other data arrays to be present and non-empty.      |

**Status Note:** Components marked as `CONDITIONAL` are optional at a syntactic level but their presence is governed by the logical dependency rules in **[Section 4.2]**.

### 4.1. Inter-Component Relationships

The components are designed to work together in a clear data flow, from high-level structure to specific content:

1.  The `roots` array provides the starting `git-hash` values to begin traversal.
2.  These hashes point to `git-tree-object`s within the `trees` array.
3.  Each `git-tree-object` contains `entry-object`s that point to other trees (recursively) or to blobs via their `git-hash`.
4.  Every blob hash points to a unique entry in the `catalog`, which describes the blob's properties.
5.  Finally, blob content, if included, is found in the `blobs` or `lfs` arrays.

This flow from structure to content creates a strict dependency chain. The presence of data in one component requires the presence of the upstream components needed to reference it.

### 4.2. Rules for Component Presence and Emptiness

The presence and emptiness of the top-level data arrays are governed by a strict set of logical rules. A manifest that violates these rules is invalid and MUST be rejected by a **Consumer**.

The fundamental dependency chain is:
`lfs` → `blobs` → `catalog` → `trees` → `roots`

This chain implies the following rules:

- **If the `lfs` array is not empty**, then `blobs`, `catalog`, `trees`, and `roots` MUST also be present and not empty.
- **If the `blobs` array is not empty**, then `catalog`, `trees`, and `roots` MUST also be present and not empty.
- **If the `catalog` array is not empty**, then `trees` and `roots` MUST also be present and not empty.
- **If the `trees` array is not empty**, then the `roots` array MUST also be present and not empty. This rule forbids a manifest consisting only of un-rooted ("orphaned") trees.

Conversely, emptiness propagates down the chain:

- **If the `roots` array is empty (`[]`)**, then `trees`, `catalog`, `blobs`, and `lfs` MUST also be empty. Such a manifest is valid and represents an empty worktree set, which can be used as a signal for deletion or a null state.

## 5. Component Schemas

This section provides the normative schemas for the components that constitute a `git-wmf` manifest. The definitions are specified in prose and tables for human readability. For the formal, machine-readable definition that serves as the ultimate source of truth, implementers MUST refer to the CDDL specification in [Appendix B: CDDL Specification].

### 5.1. Foundational Data Structures & Enums

To promote clarity and consistency, this section defines the primitive data structures and controlled vocabularies that are reused throughout the manifest's components.

#### 5.1.1. Hash Pointer Group

Many objects in the manifest are identified by their Git hashes. These references are encapsulated in a common structure referred to as a `hash-group`.

- **Format:** A MessagePack `map`.
- **Fields:** A `hash_sha256-group` has a REQUIRED `git-hash_sha256` (`sha256_binary`) and an OPTIONAL `git-hash_sha1` (`sha1_binary`). A `hash_sha1_only-group` has only a REQUIRED `git-hash_sha1` (`sha1_binary`).
- **Constraint:** Partitioning by hash type is used throughout the schema.
- **CDDL:** This structure corresponds to the `hash_sha256-group` and `hash_sha1_only-group` rules in [Appendix B].

#### 5.1.2. Git Mode Enum

The `git-mode` of a tree entry is represented by a controlled vocabulary of `unicode`. Future versions MAY add additional values for new Git features (e.g., via schema minor bump).

- **CDDL:** This vocabulary corresponds to the `git_mode` rule in [Appendix B].

| Enum Value | Meaning (Informative)       |
| :--------- | :-------------------------- |
| `"100644"` | Regular non-executable file |
| `"100755"` | Regular executable file     |
| `"040000"` | Directory (Tree)            |
| `"120000"` | Symbolic Link               |
| `"160000"` | Submodule (Gitlink)         |

#### 5.1.3. Disposition Enums

This enum defines whether a piece of content is included in the manifest. Note that disposition enums are context-specific (e.g., `norm-disposition` for standard blobs, `norm-lfs_v1-disposition` for LFS-resolved content, `norm-disposition` for trees).

- **CDDL:** This vocabulary corresponds to the `disposition-enum` rule in [Appendix B].

##### 5.1.3.1. Blob Content Disposition (`norm-disposition`)

| Value        | Meaning                                                      |
| :----------- | ------------------------------------------------------------ |
| `"included"` | The blob's content is present in the `blobs` component.      |
| `"omitted"`  | The blob's content is not present in the `git-wmf-manifest`. |

##### 5.1.3.2. LFS Content Disposition (`norm-lfs_v1-disposition`)

| Value        | Meaning                                                               |
| :----------- | :-------------------------------------------------------------------- |
| `"included"` | The resolved LFS content is present in the versioned `lfs` component. |
| `"omitted"`  | The resolved LFS content is not present in the `git-wmf-manifest`.    |

#### 5.1.4. Blob Content Type Enum

This enum classifies the intrinsic type of a blob's content. The `norm-blob-content-type-enum` is determined solely by content analysis and is orthogonal to the `git-mode` of any referencing tree entry (see [Section 8.3.1: Understanding git-mode vs. catalog Attributes] for handling cases like symlinks). Future versions MAY add values (e.g., for new LFS types).

- **CDDL:** This vocabulary corresponds to the `norm-blob-content-type-enum` rule in [Appendix B].

| Value (`norm-type`) | Meaning                                                       |
| :------------------ | :------------------------------------------------------------ |
| `"normal"`          | The blob contains standard file content (not an LFS pointer). |
| `"lfs_v1"`          | The blob contains an LFS pointer.                             |

#### 5.1.5. LFS Definitions

This section groups all definitions related to the handling of Git LFS.

A key principle of this design is that LFS metadata can be internally verified. A **Consumer** SHOULD parse the content of the corresponding pointer blob to confirm the LFS-specific attributes, rather than simply accepting the **Generator**'s assertions.

##### 5.1.5.1. LFS-Specific Attributes

When a blob is identified as an LFS pointer, its `catalog-entry-object` is augmented with attributes inline within the `lfs_v1-included-attributes` or `lfs_v1-omitted-attributes` (see [Section 5.5.2: The attributes Map]). The `norm-lfs_v1-size` is normative (from included LFS object); `hint-lfs_v1-size` is non-normative (from pointer when content omitted).

- **CDDL:** This structure corresponds to the `lfs_v1-included-attributes` and `lfs_v1-omitted-attributes` rules in [Appendix B].

##### 5.1.5.2. LFS Version Mapping and Sort Order

This table is the normative source of truth for all LFS versions supported by this version of the `git-wmf` specification. It defines the mapping between a short version string (used for key construction and type classification) and the formal canonical identifier used in the manifest `meta` component.

The top-level `lfs` array MUST be partitioned by version, with newer versions appearing before older ones as dictated by the `Sort Order` column (Descending: newer versions first). Within each version partition, objects MUST be sorted lexicographically by the bytes of their respective OID key (e.g., `lfs_v1-oid`).

See [Appendix C: Extending LFS Versions] for guidance on how future LFS versions will be incorporated into this specification.

| Version | Canonical Identifier (`norm-lfs-version-enum`) | Sort Order (Descending: newer versions first) | OID Key        | Hash Algo | Pointer Parse Notes (Informative)                                                                      |
| :------ | :--------------------------------------------- | :-------------------------------------------- | :------------- | :-------- | :----------------------------------------------------------------------------------------------------- |
| `"v1"`  | `"https://git-lfs.github.com/spec/v1"`         | 1                                             | `"lfs_v1-oid"` | SHA-256   | Parse OID after `"oid sha256:"` as lowercase hexadecimal, then hex-decode. Parse size after `"size "`. |

**Usage and CDDL Reference:**

- The **Version** string (e.g., `"v1"`) is used to form the `norm-type` in `attributes` (e.g., `"lfs_v1"`) and the version-specific keys in LFS objects (e.g., `lfs_v1-oid`).
- The **Canonical Identifier** string is the normative value for the `norm-lfs-version-enum` type, used within the `meta`.`norm-supported_lfs_versions` array to declare which LFS specifications the manifest generator supports.

### 5.2. The `meta` Component

The `meta` component is a MessagePack `map` for storing contextual information about the manifest.

- **CDDL:** `manifest-meta`

#### 5.2.1. Registered Meta Keys

| Key Name                       | Value Type                    | Status      | Description                                                                                                                                                                                                        |
| :----------------------------- | :---------------------------- | :---------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `norm-schema_version`          | `semver_string`               | REQUIRED    | The version of this schema (e.g., `"1.0.0-draft.1"`).                                                                                                                                                              |
| `norm-supported_lfs_versions`  | array of `unicode`            | REQUIRED    | An array of supported LFS versions from the mapping table ([Section 5.1.5.2: LFS Version Mapping and Sort Order]). **MAY** be an empty array (`[]`) if the manifest does not contain or reference any LFS content. |
| `hint-generator_name`          | `unicode`                     | RECOMMENDED | The name and version of the **Generator** software.                                                                                                                                                                |
| `hint-generation_timestamp`    | `iso8601_utc_string`          | OPTIONAL    | UTC timestamp in ISO 8601 format (e.g., `"2025-07-10T10:00:00Z"`).                                                                                                                                                 |
| `hint-source_repository_url`   | `unicode`                     | OPTIONAL    | The canonical URL of the source Git repository, if applicable.                                                                                                                                                     |
| `hint-selection_policy`        | `unicode`                     | OPTIONAL    | A human-readable description of how the content was selected.                                                                                                                                                      |
| `hint-commit_hash`             | map (`commit-pointer-object`) | OPTIONAL    | The hash(es) of a source commit relevant to the manifest content.                                                                                                                                                  |
| `hint-include_sha1_enrichment` | `boolean`                     | OPTIONAL    | True if SHA-1 hashes should be included where possible alongside preferred SHA-256.                                                                                                                                |

#### 5.2.2. Commit Pointer Object

A map conforming to the `hash-group` variants defined in [Section 5.1.1: Hash Pointer Group].

- **CDDL:** `commit-pointer-object`

### 5.3. The `roots` Component

The `roots` component is an `array` of `root-pointer-object`s defining the entry points into the manifest's trees. A **Consumer** begins traversal of the worktree structure from these pointers. The array MUST be partitioned and sorted according to the Principle of Sorted Components ([Section 3.5]).

#### 5.3.1. Root Pointer Object

A `root-pointer-object` is a map within the `roots` array that identifies a single root tree by its Git hash(es). To align with the required partitioning of the `roots` array, these objects exist in two variants.

- **CDDL:** `root-pointer_sha256-object` and `root-pointer_sha1_only-object`

##### For `root-pointer_sha256-object`:

This object MUST contain a `git-hash_sha256` and MAY contain a `git-hash_sha1`. These hashes point to a corresponding `git-tree-object` in the `trees` component.

| Key Name          | Value Type      | Status   | Description                        |
| :---------------- | :-------------- | :------- | :--------------------------------- |
| `git-hash_sha256` | `sha256_binary` | REQUIRED | The SHA-256 hash of the root tree. |
| `git-hash_sha1`   | `sha1_binary`   | OPTIONAL | The SHA-1 hash of the root tree.   |

##### For `root-pointer_sha1_only-object`:

This object MUST contain only a `git-hash_sha1`. This hash points to a corresponding `git-tree-object` in the `trees` component.

| Key Name        | Value Type    | Status   | Description                      |
| :-------------- | :------------ | :------- | :------------------------------- |
| `git-hash_sha1` | `sha1_binary` | REQUIRED | The SHA-1 hash of the root tree. |

### 5.4. The `trees` Component

The `trees` component is an `array` of all `git-tree-object`s, which collectively define the directory structure.

#### 5.4.1. Tree Object

Represents a single Git tree (a directory).

- **CDDL:** `git-tree_sha256-object` and `git-tree_sha1_only-object`

##### For `git-tree_sha256-object`:

| Key Name                  | Value Type               | Status   | Description                                                                                                                 |
| :------------------------ | :----------------------- | :------- | :-------------------------------------------------------------------------------------------------------------------------- |
| `git-hash_sha256`         | `sha256_binary`          | REQUIRED | The SHA-256 hash of the tree.                                                                                               |
| `git-hash_sha1`           | `sha1_binary`            | OPTIONAL | The SHA-1 hash of the tree.                                                                                                 |
| `git-tree_sha256-size`    | `size_string`            | REQUIRED | Precomputed `size_string` of the concatenated entry content length (using SHA-256 hashes in entries) for header congruence. |
| `git-tree_sha1_only-size` | `size_string`            | OPTIONAL | Precomputed `size_string` of the concatenated entry content length (using SHA-1 hashes in entries) for header congruence.   |
| `entries`                 | array of `entry-object`s | REQUIRED | A sorted list of entries contained within this tree.                                                                        |

The `entries` array MUST be sorted lexicographically by the raw bytes of the `git-name` key of each `entry-object`. Note that sizes differ based on hash length in entries.

##### For `git-tree_sha1_only-object`:

| Key Name                  | Value Type               | Status   | Description                                                                                                               |
| :------------------------ | :----------------------- | :------- | :------------------------------------------------------------------------------------------------------------------------ |
| `git-hash_sha1`           | `sha1_binary`            | REQUIRED | The SHA-1 hash of the tree.                                                                                               |
| `git-tree_sha1_only-size` | `size_string`            | REQUIRED | Precomputed `size_string` of the concatenated entry content length (using SHA-1 hashes in entries) for header congruence. |
| `entries`                 | array of `entry-object`s | REQUIRED | A sorted list of entries contained within this tree.                                                                      |

- **Constraint (Entries):** The `entries` array MUST be sorted lexicographically by the raw bytes of the `git-name` key of each `entry-object`. This is a **Generator** requirement not enforceable in CDDL. Note that sizes differ based on hash length in entries.

#### 5.4.2. Entry Object

Represents a single entry within a tree.

- **CDDL:** `entry-object`

The `entry-object` has three subtypes: `tree-entry`, `blob-entry`, and `commit-entry`.

##### For `tree-entry` (`git-mode: "040000"`):

| Key Name                             | Value Type                       | Status   | Description                                                                                                                                                          |
| :----------------------------------- | :------------------------------- | :------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `git-mode`                           | `mode_tree_string`               | REQUIRED | A value from the `git_mode` enum ([Section 5.1.2: Git Mode Enum]).                                                                                                   |
| `git-name`                           | `binary`                         | REQUIRED | The raw byte sequence representing the name of this entry.                                                                                                           |
| `git-hash_sha256` or `git-hash_sha1` | `sha256_binary` or `sha1_binary` | REQUIRED | The hash of the referenced tree (per common-entry-fields).                                                                                                           |
| `norm-disposition`                   | `disposition-enum`               | REQUIRED | Disposition for tree entries: `"included"` or `"omitted"`. **See [Section 8.3: Handling Special Entry Types] for guidance on handling stubbed trees (`"omitted"`)**. |

##### For `blob-entry` (`git-mode: "100644" / "100755" / "120000"`):

| Key Name                             | Value Type                       | Status   | Description                                                                                                                                                          |
| :----------------------------------- | :------------------------------- | :------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `git-mode`                           | `mode_blob_string`               | REQUIRED | A value from the `git_mode` enum ([Section 5.1.2: Git Mode Enum]).                                                                                                   |
| `git-name`                           | `binary`                         | REQUIRED | The raw byte sequence representing the name of this entry.                                                                                                           |
| `git-hash_sha256` or `git-hash_sha1` | `sha256_binary` or `sha1_binary` | REQUIRED | The hash of the referenced blob (per common-entry-fields).                                                                                                           |
| `norm-disposition`                   | `disposition-enum`               | REQUIRED | Disposition for blob entries: `"included"` or `"omitted"`. **See [Section 8.3: Handling Special Entry Types] for guidance on handling stubbed blobs (`"omitted"`)**. |

##### For `commit-entry` (`git-mode: "160000"`):

| Key Name           | Value Type           | Status   | Description                                                                                                                                |
| :----------------- | :------------------- | :------- | :----------------------------------------------------------------------------------------------------------------------------------------- |
| `git-mode`         | `mode_commit_string` | REQUIRED | A value from the `git_mode` enum ([Section 5.1.2: Git Mode Enum]).                                                                         |
| `git-name`         | `binary`             | REQUIRED | The raw byte sequence representing the name of this entry.                                                                                 |
| `git-hash_sha...`  | `..._binary`         | REQUIRED | The hash of the referenced commit (per `common-entry-fields`).                                                                             |
| `hint-disposition` | `disposition-enum`   | OPTIONAL | A non-normative assertion by the **Generator** that the submodule's content may be present elsewhere in the manifest. See rationale below. |

**Rationale for `hint-disposition`:** A `git-wmf-manifest` intentionally omits Git commit objects. A commit object is the only data structure that links a commit hash to its root tree hash. Without it, a **Consumer** cannot programmatically verify or discover which tree, if any, corresponds to a submodule's commit hash.

Therefore, `hint-disposition` is a strictly non-normative assertion from the **Generator**. A **Consumer** cannot use it to establish a verifiable link. For required **Consumer** behavior, see implementation guidance in **[Section 8.3.3: Submodules (git-mode: "160000")]**.

### 5.5. The `catalog` and `blobs` Components

This section defines the `catalog` component, which provides descriptive metadata for blobs, and the `blobs` component, which optionally contains their content. The two are tightly coupled.

#### 5.5.1. Catalog Entry Object

An object in the `catalog` array providing metadata for a single, unique blob.

- **CDDL:** `catalog-entry_sha256-object` and `catalog-entry_sha1_only-object`

##### For `catalog-entry_sha256-object`:

| Key Name          | Value Type      | Status   | Description                                 |
| :---------------- | :-------------- | :------- | ------------------------------------------- |
| `git-hash_sha256` | `sha256_binary` | REQUIRED | The SHA-256 hash of the blob.               |
| `git-hash_sha1`   | `sha1_binary`   | OPTIONAL | The SHA-1 hash of the blob.                 |
| `attributes`      | map             | REQUIRED | A map of the blob's descriptive properties. |

##### For `catalog-entry_sha1_only-object`:

| Key Name        | Value Type    | Status   | Description                                 |
| :-------------- | :------------ | :------- | :------------------------------------------ |
| `git-hash_sha1` | `sha1_binary` | REQUIRED | The SHA-1 hash of the blob.                 |
| `attributes`    | map           | REQUIRED | A map of the blob's descriptive properties. |

#### 5.5.2. The `attributes` Map

This map provides a rich description of the blob. Its precise structure depends on its `norm-type` field. **Consumers** SHOULD ignore unknown keys in the `attributes` map for forward compatibility (see [Section 8.6: Using Custom Extension Keys]).

- **CDDL:** `catalog-attributes`

The structure enforces co-occurrence constraints (e.g., "lfs_v1" requires the pointer blob to be "included"). This ensures a **Consumer** can always verify the integrity of the pointer blob against its hash and independently parse its contents to find the LFS OID, even when the resolved content is not provided. For `lfs_v1-omitted-attributes`, `norm-blob-size` is REQUIRED for pointer hash verification, while `hint-lfs_v1-size` is OPTIONAL as a non-normative hint.

For LFS entries, the pointer blob MUST always be included (`norm-disposition: "included"`) to enable verification, even if resolved content is omitted.

##### For `blob-included-attributes`:

| Key Name           | Value Type         | Status   | Description                                                      |
| :----------------- | :----------------- | :------- | :--------------------------------------------------------------- |
| `norm-type`        | `unicode`          | REQUIRED | `"normal"`                                                       |
| `norm-disposition` | `disposition-enum` | REQUIRED | `"included"`                                                     |
| `norm-blob-size`   | `natural_number`   | REQUIRED | The normative, uncompressed size of the blob's content in bytes. |
| `hint-binary`      | `boolean`          | OPTIONAL | A non-normative hint (`true` if content is likely binary).       |
| `hint-mime`        | `unicode`          | OPTIONAL | A non-normative, inferred IANA MIME type for the content.        |

##### For `blob-omitted-attributes`:

| Key Name           | Value Type         | Status   | Description                                                |
| :----------------- | :----------------- | :------- | :--------------------------------------------------------- |
| `norm-type`        | `unicode`          | REQUIRED | `"normal"`                                                 |
| `norm-disposition` | `disposition-enum` | REQUIRED | `"omitted"`                                                |
| `hint-blob-size`   | `natural_number`   | OPTIONAL | A non-normative size hint for the blob content.            |
| `hint-binary`      | `boolean`          | OPTIONAL | A non-normative hint (`true` if content is likely binary). |
| `hint-mime`        | `unicode`          | OPTIONAL | A non-normative, inferred IANA MIME type for the content.  |

##### For `lfs_v1-included-attributes`:

| Key Name                  | Value Type         | Status   | Description                                                                 |
| :------------------------ | :----------------- | :------- | :-------------------------------------------------------------------------- |
| `norm-type`               | `unicode`          | REQUIRED | `"lfs_v1"`                                                                  |
| `norm-disposition`        | `disposition-enum` | REQUIRED | `"included"` The pointer blob itself must be included                       |
| `norm-blob-size`          | `natural_number`   | REQUIRED | The normative, uncompressed size of the blob's content in bytes.            |
| `norm-lfs_v1-disposition` | `disposition-enum` | REQUIRED | `"included"`                                                                |
| `norm-lfs_v1-size`        | `natural_number`   | REQUIRED | The normative size of the resolved LFS content.                             |
| `hint-lfs_v1-binary`      | `boolean`          | OPTIONAL | A non-normative hint (`true` if the resolved LFS content is likely binary). |
| `hint-lfs_v1-mime`        | `unicode`          | OPTIONAL | A non-normative, inferred IANA MIME type for the resolved LFS content.      |

##### For `lfs_v1-omitted-attributes`:

| Key Name                  | Value Type         | Status   | Description                                                                 |
| :------------------------ | :----------------- | :------- | :-------------------------------------------------------------------------- |
| `norm-type`               | `unicode`          | REQUIRED | `"lfs_v1"`                                                                  |
| `norm-disposition`        | `disposition-enum` | REQUIRED | `"included"`                                                                |
| `norm-blob-size`          | `natural_number`   | REQUIRED | The normative, uncompressed size of the blob's content in bytes.            |
| `norm-lfs_v1-disposition` | `disposition-enum` | REQUIRED | `"omitted"`                                                                 |
| `hint-lfs_v1-size`        | `natural_number`   | OPTIONAL | A non-normative size hint for the resolved LFS content.                     |
| `hint-lfs_v1-binary`      | `boolean`          | OPTIONAL | A non-normative hint (`true` if the resolved LFS content is likely binary). |
| `hint-lfs_v1-mime`        | `unicode`          | OPTIONAL | A non-normative, inferred IANA MIME type for the resolved LFS content.      |

#### 5.5.3. Blob Object

An object in the top-level `blobs` array containing the raw content for a blob.

- **CDDL:** `git-blob_sha256-object` and `git-blob_sha1_only-object`

##### For `git-blob_sha256-object`:

| Key Name          | Value Type      | Status   | Description                                                      |
| :---------------- | :-------------- | :------- | :--------------------------------------------------------------- |
| `git-hash_sha256` | `sha256_binary` | REQUIRED | The SHA-256 hash of the blob.                                    |
| `git-hash_sha1`   | `sha1_binary`   | OPTIONAL | The SHA-1 hash of the blob.                                      |
| `git-blob-size`   | `size_string`   | REQUIRED | The `size_string` of len(`git-content`) for header verification. |
| `git-content`     | `binary`        | REQUIRED | The raw `binary` content of the blob.                            |

##### For `git-blob_sha1_only-object`:

| Key Name        | Value Type    | Status   | Description                                                      |
| :-------------- | :------------ | :------- | :--------------------------------------------------------------- |
| `git-hash_sha1` | `sha1_binary` | REQUIRED | The SHA-1 hash of the blob.                                      |
| `git-blob-size` | `size_string` | REQUIRED | The `size_string` of len(`git-content`) for header verification. |
| `git-content`   | `binary`      | REQUIRED | The raw `binary` content of the blob.                            |

### 5.6. The `lfs` Component

The `lfs` component is an OPTIONAL `array` of `lfs_v1-object`s, containing resolved large file content.

#### 5.6.1. LFS Object

An object in the `lfs` array contains a complete "verification packet" for an LFS entity. It holds the resolved content and the metadata required to verify both the content itself and the LFS pointer blob that refers to it.

- **CDDL:** `lfs_v1-object` (future versions like v2 in [Appendix C: Extending LFS Versions])

| Key Name         | Value Type       | Status   | Description                                                                                                                      |
| :--------------- | :--------------- | :------- | :------------------------------------------------------------------------------------------------------------------------------- |
| `git-blob-size`  | `size_string`    | REQUIRED | The precomputed `size_string` of the **corresponding LFS pointer blob's content length**, used to verify the pointer's Git hash. |
| `lfs_v1-oid`     | `lfs_v1_oid_hex` | REQUIRED | The SHA-256 OID of the resolved content as lowercase hexadecimal. This is the primary key for this object.                       |
| `lfs_v1-size`    | `size_string`    | REQUIRED | The size of the **resolved content**, as a base-10 ASCII string. Used for reconstructing the pointer file text.                  |
| `lfs_v1-content` | `binary`         | REQUIRED | The raw `binary` content of the resolved large file. Verified against the `lfs_v1-oid`.                                          |

#### 5.6.2. Guidance for Future Large-File Extensions

While this specification focuses on Git LFS, future minor versions MAY add support for other large-file systems (e.g., Git Annex) by extending the `norm-blob-content-type-enum`, adding new version mappings, and prepending new object types to the `lfs` array in CDDL. See [Appendix C: Extending LFS Versions] for details. In manifests with multiple LFS versions, Consumers SHOULD process partitions sequentially (newer first) and verify version in `meta` before resolution.

## 6. Data Types and Encodings

### 6.1. Hashes

`git-hash_sha1` values MUST be `sha1_binary`. `git-hash_sha256` values MUST be `sha256_binary`.

Version-specific OIDs, e.g., `lfs_v1-oid` MUST be `lfs_v1_oid_hex` (lowercase hexadecimal).

### **6.2. Strings and Binary Data**

This section defines the normative encoding rules for text and byte sequences, which correspond to the `tstr` (unicode) and `bstr` (binary) primitives in the CDDL specification (**[Appendix B]**).

All MessagePack map keys and fields specified as `tstr` (e.g., `git-mode`, `hint-generator_name`) MUST be valid, UTF-8 encoded `unicode`.

Fields specified as `bstr` represent opaque byte sequences. This includes raw file data like `git-content` and, critically, the `git-name` field within an `entry-object` (**[Section 5.4.2]**). The `git-name` has a strict constraint:

**Generators** MUST NOT generate a manifest with `git-name` containing a null byte (`0x00`). **Consumers** SHOULD reject any manifest containing an entry that violates this rule.

**Consumers** SHOULD handle `git-name` as a raw byte sequence, as it is not guaranteed to be valid `unicode`. For essential guidance on safely reconstructing filenames and mitigating path traversal vulnerabilities, refer to **[Section 8.3.5]** and **[Section 9.2]**.

### 6.3. Git Modes

The `git-mode` values MUST correspond to the `git_mode` enum defined in [Section 5.1.2: Git Mode Enum]. The equivalent descriptive names are provided for informative purposes only; the `unicode` is normative.

### 6.4. Numbers

`natural_number` for sizes like `norm-blob-size` where zero is valid, e.g., blob content; `size_string` for precomputed like `git-tree_sha256-size`. (See Glossary [Section 2.3.3: Core Attributes and Keys] for CDDL mapping.)

### 6.5. Internal Content Encoding

All content within a `git-wmf-manifest`, including the `git-content` of a `git-blob-object` and the `lfs_v1-content` of an `lfs_v1-object`, MUST be stored in its raw, uncompressed form. This contrasts with Git's internal object store, which typically uses zlib deflation.

This design choice simplifies the verification process for **Consumers**, as no decompression step is required before hashing. Compression of the entire manifest for network transport is a separate concern addressed in **[Section 8.4: Transport-Level Compression]**.

## 7. Visual Guide to Cryptographic Verification

This section provides a precise, visual schematic of the byte streams that a **Consumer** MUST construct to verify the cryptographic integrity of the manifest's core data structures. Trust in the manifest is built by successfully validating these object types.

All Git object verification relies on prepending a canonical header to the object's content before hashing. The exact header format is:

`[object_type] [space] [content_size_as_string] [null_byte]`

In the diagrams below:

- `|` denotes a concatenation boundary.
- `0x20` is a single space character (` `).
- `0x00` is a single null byte (`\0`).
- `<field_name>` refers to the raw byte value of that field from the manifest object.

---

### 7.1. Verifying a `git-blob-object`

This process validates that a blob's content is correctly represented by its Git hash.

**Schematic of Data to be Hashed:**

```
+------------------+------+-------------------+------+-----------------+
|   "blob" (unicode) | 0x20 | <git-blob-size>   | 0x00 | <git-content>   |
| (ASCII: 62 6c 6f 62) |  (SP)  |  (size_string from field)  | (NULL) | (binary from field) |
+------------------+------+-------------------+------+-----------------+
```

**Source Data (from the `git-blob-object`):**

- `git-blob-size`: The pre-computed size of `<git-content>`, encoded as a `size_string`.
- `git-content`: The raw `binary` content of the blob.

**Example:**
For a blob containing the text `test\n`:

- `<git-content>` is the 5-byte sequence `74 65 73 74 0a`.
- `<git-blob-size>` is the 1-byte ASCII string `"5"` (`35`).
- The exact byte stream sent to the hash function is `b"blob 5\0test\n"` (hex: 62 6c 6f 62 20 35 00 74 65 73 74 0a).

**Verification:**

- `HASH(constructed_bytes)` MUST equal the `git-hash_sha1`/`git-hash_sha256` from the object.

---

### 7.2. Verifying a `git-tree-object`

This two-stage process validates a directory's structure against its Git hash.

#### Stage 1: Construct the canonical `entry_line`

For each item in the `entries` array, a single contiguous byte string called an `entry_line` is created.

**Schematic of a single `entry_line`:**

```
+--------------+------+----------------+------+----------------------------+
| <git-mode>   | 0x20 | <git-name>    | 0x00 | <binary hash of referenced object> |
| (unicode from field) |  (SP)  | (binary from field) | (NULL) |   (20 or 32 bytes from field)   |
+--------------+------+----------------+------+----------------------------+
```

#### Stage 2: Assemble the full Tree Content and Verify

All `entry_line` byte strings are concatenated sequentially, in the exact order they appear in the `entries` array. This final buffer is then prefixed with a Git `tree` header and hashed.

**Schematic of Data to be Hashed:**

```
+-----------------+------+---------------------+------+----------------------------+
|  "tree" (unicode) | 0x20 | <git-tree-size-*>   | 0x00 | entry_line_1 | entry_line_2 | ... |
| (ASCII: 74 72 65 65) |  (SP)  | (size_string from field)     | (NULL) |  (Concatenated entry lines)  |
+-----------------+------+---------------------+------+----------------------------+
```

**Source Data (from the `git-tree-object`):**

- `git-tree-size-*`: The pre-computed total byte length of all concatenated `entry_line`s, encoded as a `size_string`. The version (`-sha1` or `-sha256`) corresponds to the hash being verified.
- `entries`: The array providing `<git-mode>`, `<git-name>`, and the `<binary hash>` for each `entry_line`.

**Example:**
For a tree with one entry ("100644 file.txt\0" + 20-byte SHA1 hash):

- Entry line hex: 31 30 30 36 34 34 20 66 69 6c 65 2e 74 78 74 00 [20-byte hash]
- If size=35, stream: 74 72 65 65 20 33 35 00 [entry line]

**Verification:**

- `HASH(constructed_bytes)` MUST equal the `git-hash_sha1`/`git-hash_sha256` from the object.

---

### 7.3. Bi-Directional Verification of a `v1` LFS Object

Verifying a Git LFS entry is a two-part process that provides a complete chain of trust. It ensures the integrity of both the resolved large file content (stored in the `lfs` component) and the Git-tracked pointer blob that refers to it. A successful verification proves that the link between the Git history and the LFS store is correct.

A **Consumer** performing these steps MUST have access to the target `lfs_v1-object` from the `lfs` array, as well as its corresponding `catalog-entry-object` and `git-blob-object` (the pointer blob). If the pointer blob is omitted for an LFS entry, verification fails—enforced by the schema requiring `"included"` for `norm-disposition` in LFS attributes.

#### 7.3.1. Verifying the Resolved LFS Content against its OID

This first verification validates that the large file content matches its LFS Object ID (OID). This process is governed by the Git LFS specification.

**Schematic of Data to be Hashed:**

```
+------------------------------------+
|         <lfs_v1-content>           |
| (binary from the lfs_v1-object field) |
+------------------------------------+
```

**Source Data (from the `lfs_v1-object`):**

- `lfs_v1-content`: The raw `binary` content of the resolved large file.

**Example:**
For content "large file" (10 bytes: 6c 61 72 67 65 20 66 69 6c 65), hash with SHA-256 to match OID.

**Verification:**

1.  **Identify Algorithm:** Per the LFS Version Mapping Table ([Section 5.1.5.2: LFS Version Mapping and Sort Order]), `v1` uses the **SHA-256** algorithm.
2.  **Compute Hash:** The **Consumer** MUST calculate the `SHA-256` hash of the raw bytes from the `<lfs_v1-content>` field.
3.  **Compare:** The resulting 32-byte hash digest MUST be identical to the hex-decoded bytes from the `lfs_v1-oid` field of the same `lfs_v1-object` (since `lfs_v1-oid` is a `lfs_v1_oid_hex`).

#### 7.3.2. Verifying the LFS Pointer Blob against its Git Hash

This second, crucial verification confirms that the LFS pointer file (which is itself a Git blob) is correctly represented by its Git hash. This is achieved by programmatically reconstructing the pointer file's exact contents from the `lfs_v1-object` and then applying the standard blob verification procedure from [Section 7.1: Verifying a git-blob-object].

##### Stage 1: Reconstruct the Pointer's Content

The exact byte stream of the LFS pointer file is reconstructed. This stream is referred to as `<reconstructed_pointer_content>`. Exact bytes, no trailing newline after the size line.

**Schematic of Reconstructed Pointer Content (ASCII Art):**

```
version https://git-lfs.github.com/spec/v1<LF>
oid sha256:<hex_lfs_oid><LF>
size <lfs_v1-size>
```

Where `<LF>` is 0x0A, and there is no trailing LF after the size line.

**Source Data for Reconstruction:**

- `<hex_lfs_oid>`: The lower-case `hex_string` (all lowercase, as per Git LFS convention) from the `lfs_v1-oid` field (`lfs_v1_oid_hex`). This will result in a 64-character ASCII string.
- `<lfs_v1-size>`: The raw bytes from the `lfs_v1-size` field of the `lfs_v1-object`. This is a `size_string` representing the size of the resolved content.

**Example:**
For OID "dd0401f025a48d86243d4bd336483566b84d4ab7d1b15eb612c88ad02cee59db" and size "10":

- Content: "version https://git-lfs.github.com/spec/v1\noid sha256:dd0401f025a48d86243d4bd336483566b84d4ab7d1b15eb612c88ad02cee59db\nsize 10" (hex starts: 76 65 72 73 69 6f 6e ...)

##### Stage 2: Verify the Reconstructed Content as a Git Blob

The `<reconstructed_pointer_content>` from Stage 1 is now treated as the content of a standard Git blob and verified per [Section 7.1: Verifying a git-blob-object].

**Schematic of Data to be Hashed:**

```
+------------------+------+-----------------+------+-------------------------------+
|   "blob" (unicode)| 0x20 | <git-blob-size> | 0x00 | <reconstructed_pointer_content> |
| (ASCII: 62 6c 6f 62) |  (SP)  | (size_string from field) | (NULL) |   (Concatenated bytes from Stage 1) |
+------------------+------+-----------------+------+-------------------------------+
```

**Source Data for Hashing:**

- `<git-blob-size>`: The raw bytes from the `git-blob-size` field of the `lfs_v1-object`. This field holds the size of the **pointer file**, not the resolved content.
- `<reconstructed_pointer_content>`: The byte stream constructed in Stage 1.

**Verification:**

1.  **Fetch Target Hashes:** To find the correct Git hash(es) for the pointer blob, the **Consumer** MUST look up the `catalog-entry-object` whose `attributes` identify it as `norm-type: "lfs_v1"` and whose LFS attributes can be parsed to yield the `lfs_v1-oid` of the object being verified. The `git-hash_sha1` and/or `git-hash_sha256` from that `catalog-entry-object` are the target hashes.
2.  **Compute Hash:** The **Consumer** MUST hash the byte stream constructed in this stage's schematic using the appropriate algorithm (SHA-1 and/or SHA-256).
3.  **Compare:** The result(s) MUST be identical to the corresponding Git hash(es) fetched in the previous step.

## 8. Implementation Guidance

This section provides non-normative but strongly recommended guidance for implementers of `git-wmf`. Adhering to these practices will help ensure that **Consumers** are robust, efficient, and behave consistently.

### **8.1. Data Access Strategies**

A **Consumer's** strategy for accessing data within the manifest has significant performance implications. The following guidance describes two recommended approaches that leverage the format's normative structural rules.

#### **8.1.1. Recommended Approach: Client-Side Cataloging**

For optimal performance, a **Consumer** SHOULD implement the **Client-Side Cataloging** pattern, as defined in the glossary (**[Section 2.2]**). This involves a single, initial pass over the primary data arrays (`trees`, `catalog`, `blobs`, and `lfs`) to build in-memory lookup maps (e.g., hash tables) that provide O(1) access to objects by their hash.

To robustly enforce the uniqueness constraint from the **Principle of Unambiguous References ([Section 3.6])**, it is RECOMMENDED to index these maps using a composite key (e.g., a tuple of `sha256_binary` and `sha1_binary`) when both hashes are present. This cataloging pass is the ideal point to verify the global uniqueness of each hash pair, which is a mandatory validation step for a conforming **Consumer**.

#### **8.1.2. Alternative for Memory-Constrained Environments**

In environments where building complete in-memory hash maps is infeasible (e.g., on embedded devices or with extremely large manifests), a **Consumer** MAY instead rely directly on the manifest's structural guarantees for data access.

The **Principle of Sorted Components ([Section 3.5])** mandates that all top-level data arrays are partitioned and sorted lexicographically by their primary hash. This normative structure enables a **Consumer** to perform efficient O(log n) lookups using binary search on the arrays directly from storage or a stream, avoiding the high memory overhead of a full in-memory catalog.

To support this access pattern, **Generators** are reminded of their responsibility to produce correctly sorted arrays. It is RECOMMENDED that **Generators** use an efficient, stable sort algorithm (e.g., Timsort) during manifest creation.

### 8.2. LFS Content Resolution Workflow

To access resolved LFS content:

0. Verify that the LFS version from the pointer (parsed per [Section 7.3.2: Verifying the LFS Pointer Blob against its Git Hash]) is listed in `meta.norm-supported_lfs_versions`; if unsupported, reject or skip the LFS content and signal an error to the application.
1. From an `entry-object`, use hash to find `catalog-entry-object`.
2. If `norm-type: "lfs_v1"`, retrieve pointer from `blobs` (`norm-disposition: "included"`).
3. Parse pointer per `norm-lfs-version-enum` for OID (e.g., `lfs_v1-oid`).
4. Lookup `lfs_v1-object` in version partition.
5. Verify: hash `lfs_v1-content` per version algorithm against hex-decoded `lfs_v1-oid`.

Pseudocode:

```
def resolve_lfs(entry_hash, catalog, blobs, lfs, supported_versions):
    catalog_entry = catalog.get(entry_hash)
    if catalog_entry['attributes']['norm-type'] != 'lfs_v1':
        return None
    if catalog_entry['attributes']['norm-disposition'] != 'included':
        raise VerificationError("Pointer omitted for LFS")
    pointer_blob = blobs.get(entry_hash)
    # Parse pointer to get oid, version, size
    parsed = parse_lfs_pointer(pointer_blob['git-content'])
    if parsed['version'] not in supported_versions:
        raise UnsupportedVersionError
    lfs_obj = lfs.get(parsed['oid'])
    if not lfs_obj:
        return None  # Omitted
    # Verify bi-directionally per Section 7.3
    verify_lfs_content(lfs_obj, parsed['oid'])
    verify_pointer_reconstruction(lfs_obj, catalog_entry['git-hash_*'])
    return lfs_obj['lfs_v1-content']
```

### 8.3. Handling Special Entry Types and Reconstruction Logic

A robust **Consumer** must correctly interpret and reconstruct various special file types and states. The following guidance covers common edge cases.

#### 8.3.1. Stubbed and Omitted Entries

An entry marked with `norm-disposition: "omitted"` signifies content that is intentionally not included in the manifest. For a blob entry, a **Consumer** SHOULD NOT create a file placeholder (not even a zero-byte file), as this would generate content that does not match the entry's hash, violating cryptographic verifiability. Similarly, for a tree entry, a **Consumer** SHOULD NOT create an empty directory as a placeholder.

#### 8.3.2. Empty Directories versus Stubbed Trees

The manifest makes a critical distinction between a _verified empty directory_ and a _stubbed tree_. A verified empty directory is represented by a `tree-entry` that points to a `git-tree-object` whose `entries` array is empty (`[]`). This object's hash corresponds to a universally recognized Git hash:

- **SHA-1:** `4b825dc642cb6eb9a060e54bf8d69288fbee4904`
- **SHA-256:** `6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321`

In contrast, a stubbed tree (one with `norm-disposition: "omitted"`) is one whose contents are unknown, which is semantically different from being verifiably empty.

#### 8.3.3. Submodules (git-mode: "160000")

As established in the schema rationale in **[Section 5.4.2]**, a **Consumer** cannot resolve a submodule's commit hash to a tree within the manifest. Therefore, a submodule entry MUST be treated as an abstract placeholder representing an external dependency.

- **Reconstruction:** A **Consumer** SHOULD create an empty directory at the path specified by the `git-name`. An application MAY use the submodule's commit hash to orchestrate fetching the content via an external process.

- **Handling the Hint:** The optional `hint-disposition` key is a non-verifiable signal from the **Generator**. **Consumers** SHOULD NOT use this hint to attempt automatic linking or reconstruction of submodule content from within the manifest.

#### 8.3.4. Symbolic Links (git-mode: "120000")

The content of a symbolic link is a blob containing a path string. The **Generator** MUST record this path string faithfully, exactly as it exists in the source worktree. The **Consumer** is solely responsible for interpreting this path, which may be relative (e.g., `../foo/bar`), absolute (e.g., `/etc/hosts`), or invalid. **Consumers** MUST validate and sanitize symlink targets to prevent path traversal attacks before creating them on a filesystem.

#### 8.3.5. Filesystem Compatibility and Name Mangling

The `git-name` field is a raw byte sequence (`binary`) and may not be compatible with all filesystems. A **Consumer** must be prepared to handle names that are invalid on the target system, such as those containing illegal characters (e.g., `< > : " / \ | ? *` on Windows), reserved OS filenames (`CON`, `PRN`, `AUX`), or names that create collisions on case-insensitive filesystems (e.g., `file.txt` and `File.txt`).

To handle these cases while preserving the ability to round-trip data and verify its integrity against the original manifest, it is strongly recommended that **Consumers** implement a predictable and **reversible name mangling** strategy.

##### Recommended Mangling Profile based on RFC 3986

To promote interoperability for use cases like re-verification, it is **RECOMMENDED** that a **Consumer** use Percent-Encoding, as defined in RFC 3986, applied according to the following policy:

1.  **Encoding Trigger:** Encoding MAY be applied to a `git-name` if it would be invalid or cause a collision on the target filesystem.

2.  **Encoding Rules:** The goal is to produce a unique, valid filename that can be deterministically reversed.
    - **For illegal characters:** Encode only the specific illegal bytes. For example, `notes:v1.txt` becomes `notes%3av1.txt`.
    - **For reserved filenames:** It is RECOMMENDED to encode the entire name to avoid ambiguity. For example, `CON` becomes `%43%4f%4e`.
    - **For case-collisions:** Encode one or more bytes in the colliding name to create a unique value. The recommended strategy is to find the first byte that differs only by case and encode it. For example, if `file.txt` exists, a subsequent entry for `File.txt` could be reconstructed as `F%69le.txt`.

Following this recommendation allows any conforming verification tool to reliably reverse the mangling and recover the original `git-name` for hash computations.

### 8.4. Transport-Level Compression

Compress serialized manifests externally (e.g., Zstandard, DEFLATE) for transmission.

### 8.5. Error Handling

**Consumers** MUST reject the manifest if any required field or component is missing (e.g., missing `meta` or required sub-keys like `norm-schema_version`). For optional fields, absence implies default/omitted behavior.

Define standard error categories for interoperability:

- "SchemaMismatch": Unsupported version or missing required fields.
- "HashAmbiguity": Ambiguous SHA-1 without SHA-256.
- "VerificationFailed": Hash mismatch during verification.
- "OverlapError": Roots not disconnected.
- "UnsupportedVersion": Unknown LFS version.

### 8.6. Using Custom Extension Keys

The `git-wmf` schema is designed for extensibility, intentionally permitting unrecognized keys in several components (e.g., `manifest-meta`, `catalog-attributes`) via the CDDL `* tstr => any` rule. This allows **Generators** to include proprietary or application-specific metadata without requiring a revision to this specification.

To prevent key collisions between different implementers, it is STRONGLY RECOMMENDED that any custom extension keys follow a namespaced format.

The RECOMMENDED convention is **reverse domain name notation (reverse-DNS)**.

**Example:**
A **Generator** from an organization `example.com` wanting to add a proprietary build identifier to the manifest's metadata would use a key like:

```
{
    "meta": {
        "norm-schema_version": "1.0.0",
        "hint-generator_name": "BuildSystem v2.5",
        "com.example.build-id": "b-1a2b3c4d",  // Custom key using reverse-DNS
        ...
    },
    ...
}
```

This practice ensures that custom metadata from one organization will not conflict with metadata from another (e.g., `org.w3c.validation-ref`). It allows **Consumers** to safely ignore keys from namespaces they do not recognize, or to selectively target and interpret keys from known namespaces.

### 8.7. Conformance

A conforming **Consumer** MUST perform the following core validation steps to ensure a manifest is valid and secure:

1. Verify the schema version matches a supported major version (per [Section 10: Schema Versioning]).
2. Validate sorting and uniqueness in top-level arrays (per [Section 3.5: Principle of Sorted Components]).
3. Check for hash uniqueness and enforce the Rule of Unambiguous References (per [Section 3.6: Principle of Unambiguous References]).
4. Verify cryptographic integrity of all referenced objects in traversed roots/subtrees using the procedures in [Section 7: Visual Guide to Cryptographic Verification]. Verify at least one full subtree chain.
5. For manifests with LFS content, verify at least one `lfs_v1-object` bi-directionally (per [Section 7.3: Bi-Directional Verification of a v1 LFS Object]).
6. Enforce the Rule of Information Enrichment (per [Section 3.3.1: Implication: Rule of Information Enrichment]) during subtree traversal.
7. Reject manifests violating any MUST requirements.
8. Perform a runtime validation to enforce the **Principle of Minimal Roots ([Section 3.2])**, ensuring no root is a descendant of another tree.

A conforming **Generator** MUST produce manifests that pass all these validations.

Implementers are encouraged to create open-source tools (e.g., Python validator using cddl library) to test against CDDL and examples.

## 9. Security Considerations

**Generators** and **Consumers** MUST address security risks from untrusted manifests. Each of the following subsections highlights a key risk area and its corresponding CWE identifier.

### 9.1. CWE-400: Uncontrolled Resource Consumption

An attacker may provide a manifest designed to cause excessive resource usage, leading to a Denial of Service (DoS). **Consumers** MUST implement defenses such as: rejecting overly deep or wide tree nesting (uncontrolled recursion, **CWE-674**), validating content sizes against manifest declarations before allocating memory (uncontrolled memory allocation, **CWE-789**), rejecting duplicate hash pairs which could bloat lookup tables, and using parsers with configurable limits to defend against resource exhaustion from malicious MessagePack structures.

### 9.2. CWE-22: Improper Limitation of a Pathname to a Restricted Directory ('Path Traversal')

**Consumers** must treat all path-forming data from the manifest, especially `git-name` and symlink blob content, as untrusted input. Before creating any files or directories, **Consumers** SHOULD validate and sanitize symlink targets to prevent an attacker from writing files outside the intended destination directory. The guidance in **[Section 8.3.4]** and **[Section 8.3.5]** are critical security controls for mitigating this risk.

### 9.3. CWE-20: Improper Input Validation

LFS pointer blobs are a potential vector for attack if not parsed defensively. A malformed pointer could exploit vulnerabilities in a **Consumer's** parser. **Consumers** MUST validate the structure of a pointer file before trusting its contents. They MUST also verify that the resolved LFS content's hash matches its OID and reject any content associated with an unknown or unsupported LFS version declared in the pointer.

### 9.4. CWE-319: Cleartext Transmission of Sensitive Information

If transmitted over an insecure channel, the entire manifest could be intercepted and read. To ensure confidentiality and integrity, manifests SHOULD be transmitted over a secure transport layer, such as TLS. This also protects against active man-in-the-middle attacks that could alter the manifest in transit.

### 9.5. CWE-327: Use of a Broken or Risky Cryptographic Algorithm

This specification permits the use of SHA-1 for backward compatibility, but SHA-1 is considered cryptographically broken and vulnerable to collision attacks. **Consumers** and **Generators** SHOULD mitigate this risk by preferring SHA-256 for all operations. The rules in **[Section 3.6: Principle of Unambiguous References]** (requiring SHA-256 to disambiguate collisions) and **[Section 3.3: Principle of Descendant Hash Consistency]** (preventing cryptographic downgrade attacks) are mandatory controls.

### 9.6. CWE-345: Insufficient Verification of Data Authenticity

This specification does not include a built-in mechanism for verifying the origin or authorship of a manifest. A consumer has no way to know if a manifest was created by a trusted party. To mitigate this, implementers SHOULD apply an external signature (e.g., using GPG or another signing standard) to the entire serialized manifest file. **Consumers** would then be responsible for verifying this signature before parsing.

## 10. Schema Versioning

Changes to the `git-wmf` schema are tracked via `norm-schema_version` (a `semver_string` conforming to the Semantic Versioning 2.0.0 standard). Major version bumps (e.g., `2.0.0`) indicate breaking changes (e.g., required field additions). Minor bumps (e.g., `1.1.0`) add optional features. Patch bumps (e.g., `1.0.1`) fix issues without altering structure. Draft suffixes (e.g., `-draft.1`) denote pre-release iterations.

A **Consumer** parsing a manifest with a `norm-schema_version` where the major version is greater than its own supported major version **MUST** reject the entire manifest. **Consumers** SHOULD gracefully handle unknown minor or patch additions (e.g., by ignoring new optional keys) and MAY log warnings for unknown minor versions. **Consumers** SHOULD treat manifests with draft suffixes as unstable and MUST NOT use them in production environments without an explicit opt-in mechanism.

## Appendix A: Concrete Example

This appendix provides a non-trivial but simple manifest example in a human-readable JSON-like format (note that actual manifests are MessagePack binary; hashes are hex strings for readability, but would be binary in MessagePack; git-name is shown as string but is bstr: e.g., b'hello.txt').

This example includes:

- A single root tree with two entries: a normal blob ("hello.txt") and an LFS blob ("large.bin").
- Using SHA-256 with SHA-1 enrichment.
- Included content for both.

```
{
  "meta": {
    "norm-schema_version": "1.0.0-draft.1",
    "norm-supported_lfs_versions": ["https://git-lfs.github.com/spec/v1"],
    "hint-generator_name": "git-wmf-gen v1.0"
  },
  "roots": [
    {
      "git-hash_sha256": "c4d4ce6aeb9822ee3a3f4aa99f9c26616fab2aba5852bcca1d526a1f7d1eaf1a",
      "git-hash_sha1": "8215c3dd8a6aed1a3774afbbe0a994b84e0668ed"
    }
  ],
  "trees": [
  {
      "git-hash_sha256": "c4d4ce6aeb9822ee3a3f4aa99f9c26616fab2aba5852bcca1d526a1f7d1eaf1a",
      "git-hash_sha1": "8215c3dd8a6aed1a3774afbbe0a994b84e0668ed",
      "git-tree_sha256-size": "98",
      "git-tree_sha1_only-size": "74",
      "entries": [
        {
          "git-mode": "100644",
          "git-name": "hello.txt",  // as bstr: b'hello.txt'
          "git-hash_sha256": "0bd69098bd9b9cc5934a610ab65da429b525361147faa7b5b922919e9a23143d",
          "git-hash_sha1": "3b18e512dba79e4c8300dd08aeb37f8e728b8dad",
          "norm-disposition": "included"
        },
        {
          "git-mode": "100644",
          "git-name": "large.bin",  // as bstr: b'large.bin'
          "git-hash_sha256": "bb3164109965fd7111a530811c9a12a9502748cab4aed89728141c7c87134f3f",
          "git-hash_sha1": "0add9679b7c13e304bd7257a3d3c0670e2571ddc",
          "norm-disposition": "included"
        }
      ]
    }
  ],
  "catalog": [
    {
      "git-hash_sha256": "0bd69098bd9b9cc5934a610ab65da429b525361147faa7b5b922919e9a23143d",
      "git-hash_sha1": "3b18e512dba79e4c8300dd08aeb37f8e728b8dad",
      "attributes": {
        "norm-type": "normal",
        "norm-disposition": "included",
        "norm-blob-size": 12,
        "hint-binary": false,
        "hint-mime": "text/plain"
      }
    },
    {
      "git-hash_sha256": "bb3164109965fd7111a530811c9a12a9502748cab4aed89728141c7c87134f3f",
      "git-hash_sha1": "0add9679b7c13e304bd7257a3d3c0670e2571ddc",
      "attributes": {
        "norm-type": "lfs_v1",
        "norm-disposition": "included",
        "norm-blob-size": 126,
        "norm-lfs_v1-disposition": "included",
        "norm-lfs_v1-size": 10,
        "hint-lfs_v1-binary": true,
        "hint-lfs_v1-mime": "application/octet-stream"
      }
    }
  ],
  "blobs": [
    {
      "git-hash_sha256": "0bd69098bd9b9cc5934a610ab65da429b525361147faa7b5b922919e9a23143d",
      "git-hash_sha1": "3b18e512dba79e4c8300dd08aeb37f8e728b8dad",
      "git-blob-size": "12",
      "git-content": "hello world\n"  // as bstr: b'hello world\n'
    },
    {
      "git-hash_sha256": "bb3164109965fd7111a530811c9a12a9502748cab4aed89728141c7c87134f3f",
      "git-hash_sha1": "0add9679b7c13e304bd7257a3d3c0670e2571ddc",
      "git-blob-size": "126",
      "git-content": "version https://git-lfs.github.com/spec/v1\noid sha256:dd0401f025a48d86243d4bd336483566b84d4ab7d1b15eb612c88ad02cee59db\nsize 10"  // as bstr
    }
  ],
  "lfs": [
    {
      "git-blob-size": "126",
      "lfs_v1-oid": "dd0401f025a48d86243d4bd336483566b84d4ab7d1b15eb612c88ad02cee59db",
      "lfs_v1-size": "10",
      "lfs_v1-content": "large file"  // as bstr: b'large file'
    }
  ]
}
```

## Appendix B: CDDL Specification

This section provides a normative definition of the `git-wmf` format using the Concise Data Definition Language (CDDL, RFC 8610). This specification is the ultimate source of truth for the structure of a valid `git-wmf-manifest`.

```cddl
;
; git-wmf Specification v1.0.0-draft.1 in CDDL
;
; NAMING POLICY:
; 1. Prefixes: `git-` and `lfs_v1-` (cryptographic), `norm-` (verifiable), `hint-` (non-verifiable).
; 2. Hyphen (`-`): Primary word separator (kebab-case). e.g., `hint-generator-name`.
; 3. Underscore (`_`): Separates a base key from a parameter/version. e.g., `lfs_v1-oid`.
;
; uses a four-tier omission system: git-tree-object, catalog-entry-object, git-blob-object, lfs_v1-object
;
; [object_type] [space] [content_size_as_string] [null_byte]

; =========================================================================
; Primitive Types
; =========================================================================
; This section defines foundational types, including derived and constrained types from Section 2.3.3.
; Sorted alphabetically for easy reference.

binary = bstr
boolean = bool
mode_tree_string = "040000"
mode_blob_string = "100644" / "100755" / "120000"
mode_commit_string = "160000"
hex_string = tstr .regexp "^[0-9a-f]+$"
iso8601-utc-string = tstr .regexp "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?Z$"
lfs_v1_oid_hex = tstr .regexp "^[0-9a-f]{64}$"
natural_number = uint
semver-string = tstr .regexp "^(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)(?:-((?:0|[1-9]\\d*|\\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\\.(?:0|[1-9]\\d*|\\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\\+([0-9a-zA-Z-]+(?:\\.[0-9a-zA-Z-]+)*))?$"
sha1_binary = binary .size 20
sha256_binary = binary .size 32
size_string = tstr .regexp "^0|[1-9][0-9]*$"
unicode = tstr

; =========================================================================
; Enums
; =========================================================================
; Controlled vocabularies used throughout the schema.
; Sorted alphabetically by rule name.

git_mode = mode_tree_string / mode_blob_string / mode_commit_string
norm-blob-content-type-enum = "normal" / "lfs_v1"
disposition-enum = "included" / "omitted"
norm-lfs-version-enum = "https://git-lfs.github.com/spec/v1"

; =========================================================================
; Reusable Groups
; =========================================================================
; Common structures reused in multiple objects.
; Sorted alphabetically by rule name.

common-entry-fields = (
    git-name: binary,
    hash_sha256-group / hash_sha1_only-group  ; Flexible per entry (Subtree Completeness applies recursively)
)
git-tree_sha1_only-size-only = ( git-tree_sha1_only-size: size_string )
git-tree_sha256-size = ( git-tree_sha256-size: size_string, ? git-tree_sha1_only-size: size_string )
hash_sha1_only-group = ( git-hash_sha1: sha1_binary )
hash_sha256-group = ( git-hash_sha256: sha256_binary, ? git-hash_sha1: sha1_binary )

; =========================================================================
; Top-Level Manifest Structure
; =========================================================================
; The root of the git-wmf-manifest and its immediate components.

git-wmf-manifest = {
    meta:        manifest-meta,
    roots:       [ * root-pointer_sha256-object, * root-pointer_sha1_only-object ],
    trees:       [ * git-tree_sha256-object, * git-tree_sha1_only-object ],
    ? catalog:   [ * catalog-entry_sha256-object, * catalog-entry_sha1_only-object ],
    ? blobs:     [ * git-blob_sha256-object, * git-blob_sha1_only-object ],
    ? lfs:       [ * lfs_v1-object ],  ; Newer versions first; future versions (e.g., v2) would prepend here
    ; Future: ? lfs: [ * lfs_v2-object, * lfs_v1-object ]
}

manifest-meta = {
    norm-schema_version: semver-string,
    norm-supported_lfs_versions: [ * norm-lfs-version-enum ],
    ? hint-generator_name: unicode,
    ? hint-generation_timestamp: iso8601-utc-string,
    ? hint-source_repository_url: unicode,
    ? hint-selection_policy: unicode,
    ? hint-commit_hash: commit-pointer-object,
    ? hint-include_sha1_enrichment: boolean,  ; boolean for SHA-1 enrichment
    * tstr => any
}

; =========================================================================
; Core Data Objects
; =========================================================================
; Definitions for key objects like pointers, trees, entries, catalogs, blobs, and LFS.
; Grouped by logical category (e.g., pointers, trees, entries, etc.).

commit-pointer-object = hash_sha256-group / hash_sha1_only-group

; Root Pointer Variants
root-pointer_sha256-object = hash_sha256-group
root-pointer_sha1_only-object = hash_sha1_only-group
; Note: Within sha256 partition, MUST sort lex by git-hash_sha256 bytes; within sha1, by git-hash_sha1 bytes (Generator req'd)

; Tree Variants
git-tree_sha256-object = {
    hash_sha256-group,
    git-tree_sha256-size,
    entries: [ * entry-object ],  ; MUST be sorted lex by git-name bytes (Generator req'd)
}

git-tree_sha1_only-object = {
    hash_sha1_only-group,
    git-tree_sha1_only-size-only,
    entries: [ * entry-object ],  ; MUST be sorted lex by git-name bytes (Generator req'd)
}
; Note: Within partitions, MUST sort lex by primary hash bytes

; Entry Variants
entry-object = tree-entry / blob-entry / commit-entry

tree-entry = {
    git-mode: mode_tree_string,
    common-entry-fields,
    norm-disposition: disposition-enum
}

blob-entry = {
    git-mode: mode_blob_string,
    common-entry-fields,
    norm-disposition: disposition-enum
}

commit-entry = {
    git-mode: mode_commit_string,
    common-entry-fields,
    ? hint-disposition: disposition-enum
}

; Catalog Variants
catalog-entry_sha256-object = {
    hash_sha256-group,
    attributes: catalog-attributes
}

catalog-entry_sha1_only-object = {
    hash_sha1_only-group,
    attributes: catalog-attributes
}
; Note: Within partitions, MUST sort lex by primary hash bytes

; Catalog Attributes Variants
catalog-attributes = blob-included-attributes / blob-omitted-attributes / lfs_v1-included-attributes / lfs_v1-omitted-attributes

blob-included-attributes = {
    norm-type: "normal",
    norm-disposition: "included",
    norm-blob-size: natural_number,
    extra-blob-attributes,
}

blob-omitted-attributes = {
    norm-type: "normal",
    norm-disposition: "omitted",
    ? hint-blob-size: natural_number,
    extra-blob-attributes,
}

lfs_v1-included-attributes = {
    norm-type: "lfs_v1",
    norm-disposition: "included",
    norm-blob-size: natural_number,
    norm-lfs_v1-disposition: "included",
    norm-lfs_v1-size: natural_number,
    extra-lfs_v1-attributes
}

lfs_v1-omitted-attributes = {
    norm-type: "lfs_v1",
    norm-disposition: "included",
    norm-blob-size: natural_number,
    norm-lfs_v1-disposition: "omitted",
    ? hint-lfs_v1-size: natural_number,
    extra-lfs_v1-attributes
}

extra-blob-attributes = (
    ? hint-binary: boolean,
    ? hint-mime: unicode,
    * tstr => any
)

extra-lfs_v1-attributes = (
    ? hint-lfs_v1-binary: boolean,
    ? hint-lfs_v1-mime: unicode,
    * tstr => any
)

; Blob Variants
git-blob_sha256-object = {
    hash_sha256-group,
    git-blob-size: size_string,  ; Note: Precomputed ASCII string of len(git-content) (for header verification)
    git-content: binary
}

git-blob_sha1_only-object = {
    hash_sha1_only-group,
    git-blob-size: size_string,
    git-content: binary
}
; Note: Within partitions, MUST sort lex by primary hash bytes

; LFS Variants
; (version-partitioned, hypothetical v2 first)
; Future: lfs_v2-object = { ... }
lfs_v1-object = {
    git-blob-size: size_string,
    lfs_v1-oid: lfs_v1_oid_hex,
    lfs_v1-size: size_string,
    lfs_v1-content: binary,
}
; Note: Within partitions, MUST sort lex by lfs_vN-oid bytes (Generator req'd)
```

## Appendix C: Extending LFS Versions

To support a new version of LFS, this specification will require a minor schema bump (e.g., 1.1.0) and CDDL update. The process involves: adding a new row to the LFS Version Mapping Table ([Section 5.1.5.2: LFS Version Mapping and Sort Order]); defining new CDDL rules (e.g., `lfs_v2-object`); updating enums (e.g., `norm-blob-content-type-enum`); and appending to the `lfs` array partition in CDDL (newer versions first). Backward compatibility is maintained by requiring **Consumers** to ignore unknown versions via `meta.norm-supported_lfs_versions`. New versions require updating `norm-lfs-version-enum` and attributes maps.
