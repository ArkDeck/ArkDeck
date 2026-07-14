# DAYU200 Image Characterization Design

> Status：draft
> Proposal：CHG-2026-003-dayu200-image-characterization@r1
> Core baseline：CORE-1.0.0

## Purpose and boundary

This Change implements one offline research scanner and runs it against one
fixed vendor archive. It does not implement the future `arkdeck flash` parser,
publish an Integration Profile, choose a Flash Provider, prove target
compatibility or create hardware support evidence.

The implementation is `scripts/archive_characterization/scan.py` plus schemas,
small synthetic hazard fixtures and `test_scan.py`. It uses repository-pinned
CPython 3.14.6 and the Python standard library only. It never invokes a shell or
child process, never extracts a member to disk and never executes a member.

## Fixed input gate

The production entry point accepts the external archive only when the raw
`.tar.gz` file is exactly `732948803` bytes and has SHA-256
`fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280`.
The caller supplies its locator at execution time. The locator, basename and
host directory are never written to evidence or passed to classification.

Identity mismatch is a terminal scan failure, not `unknown`. Tests reach hazard
branches by calling the same scanner core with each synthetic fixture's own
test-only expected size/hash; the production CLI exposes no identity bypass.

## Streaming inventory

The scanner opens the archive read-only. Raw archive bytes and each regular
member's uncompressed logical bytes are hashed in chunks no larger than
`1048576` bytes. Inventory order is physical tar-header order. Each accepted row
contains only validated POSIX path, `kind:regular`, logical byte size and member
SHA-256. Member bytes may be read to hash them but are never decoded,
interpreted, retained, forwarded to classification or written to disk.

Path validation uses the original tar member name. Before accepting a row it:

1. rejects POSIX absolute, UNC-like and drive-prefixed names;
2. treats both `/` and `\\` as separators for traversal detection and rejects a
   `..` segment;
3. rejects backslashes, empty names/segments, `.` segments, C0/DEL characters,
   NULs and Unicode surrogate code points;
4. requires the name to equal its canonical POSIX form and be unique; and
5. accepts regular files only. Links, directories, sparse files, devices, FIFO
   and every other tar member kind are unsupported.

No classification call occurs until the whole archive has passed identity,
framing, path, type and member-stream validation.

## Fixed hazard results and precedence

Hazards are failures, never package-family results. The stable codes are:

| Code | Meaning |
| --- | --- |
| `ARC001_IDENTITY_MISMATCH` | Raw archive size or SHA-256 differs from the expected identity. |
| `ARC002_ARCHIVE_INVALID` | Gzip/tar open, header, checksum, end-marker or trailer framing is invalid or incomplete, excluding a short regular-member body covered by ARC009. |
| `ARC003_PATH_ABSOLUTE` | A POSIX, UNC-like or drive-prefixed absolute member path is present. |
| `ARC004_PATH_TRAVERSAL` | A `/`- or `\\`-separated member path contains `..`. |
| `ARC005_PATH_INVALID` | A path is empty, non-canonical, ambiguous or contains a prohibited character. |
| `ARC006_PATH_DUPLICATE` | Two physical headers resolve to the same accepted path. |
| `ARC007_LINK_UNSUPPORTED` | A symbolic or hard link is present. |
| `ARC008_MEMBER_TYPE_UNSUPPORTED` | A directory, sparse, device, FIFO or other non-regular type is present. |
| `ARC009_MEMBER_SIZE_MISMATCH` | Logical bytes read differ from the tar header's declared size. |

Production checks identity first. A framing failure observed before the first
complete member is `ARC002`; otherwise the first failing member in physical order
wins and, within that member, numeric code order wins. A framing/trailer failure
observed only after all earlier members passed is `ARC002`. A short logical read
after a complete member header is `ARC009`, not `ARC002`. Tests include one
fixture per code and a multi-hazard precedence fixture.

## Closed classification rule

Classification consumes only an immutable projection of the verified inventory:
`{path, kind, size}`. It cannot receive archive identity, archive/member hashes,
raw bytes, host locator, archive basename or marketing/model text. Member order is not a
predicate.

`imagePackageFamily` is `rockchipRawImageSet` exactly when all conditions below
are true; otherwise it is `unknown`:

1. every member is a non-empty, root-level regular file;
2. `parameter.txt` occurs exactly once;
3. `MiniLoaderAll.bin` occurs exactly once;
4. `uboot.img` occurs exactly once;
5. at least two additional members have a case-sensitive `.img` suffix; and
6. every member is one of those three anchors, another case-sensitive `.img`, or
   exactly `config.cfg`, `daily_build.log`, `manifest_tag.xml` or
   `updater_binary`.

The result records these ordered condition IDs and booleans:
`PKG-RK-ROOT-REGULAR-NONEMPTY`, `PKG-RK-PARAMETER`, `PKG-RK-MINILOADER`,
`PKG-RK-UBOOT`, `PKG-RK-EXTRA-IMAGES` and `PKG-RK-ALLOWLIST`. It records every
failed ID in that order rather than selecting an implementation-defined first
reason.

Even a matching result has `classificationScope:fixedArchiveOnly`,
`authoritative:false`, `deviceFlashProvider:unknown`,
`targetCompatibility:unknown`, `imageProfileReadiness:candidateNonExecutable`,
`executableProfile:false` and `hardwareSupportClaim:false`.

## Evidence and tests

The Task produces exactly four JSON results and one derived summary:

- `archive-identity.json`: expected/observed raw size/hash and match result, with
  no external locator;
- `member-inventory.json`: ordered accepted rows and scanner/hazard test summary;
- `package-classification.json`: condition results, package result, fixed axes and
  explicit gaps for partition semantics, flash addresses, protocol and recovery;
- `process-audit.json`: Python version, maximum read chunk, read-only archive
  access and zero extraction, child-process, network, HDC, vendor-tool,
  USB/UART/TCP and device-mutation dispatch counts; and
- `summary.md`: hashes of the four JSON results and non-authoritative follow-up
  recommendations.

JSON output is UTF-8, deterministic and schema-validated. Raw external archive
bytes and member bytes never enter the repository. Existing evidence is never
overwritten. Tests cover every hazard code, multi-hazard precedence, the positive
classification, each failed condition, zero-sized required members, member-order
invariance, archive-locator independence, classifier input shape and bounded
reads for a large synthetic member.
