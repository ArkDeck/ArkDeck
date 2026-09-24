# Validating a DAYU200 flash bundle on the Rust Runtime (TASK-XPA-017, M4-4b1)

Before this change, the Rust Import owner refused to commit a `flash-bundle`
upload, with "This Import kind's publication validator is not configured".
It therefore produced no flash Artifact lease, and without a lease neither
Flash operation can be planned.

The owner now validates a bundle as Swift's production Import policy does
(`FlashBundleImportPolicy.production`). One streaming pass reads the archive,
its partition table is parsed, and the build is judged structurally against
the DAYU200 board.

A new Swift oracle records each of those steps for 41 synthetic archives. The
Rust Runtime replays it byte for byte.

Base: protected `main` `8e65fc87` (#2156, after #2155 and M4-4a2). Routed
methods stay **101/105**, and executable operations 15/30. No contract input
changes.

| Already on `main` | This change | Still remaining (M4) |
|---|---|---|
| The Import owner's begin, append and commit for every kind; the flash bundle's binding to the Target's physical identity; the Rockchip start-up reconciliation (#2155) | Swift's gzip-tar reader, image introspection and DAYU200 board fit, ported; raw DEFLATE decoded by Apple's Compression library, as Swift decodes it; the commit validating a `flash-bundle` Import; the Swift oracle `flash-archive` | Admitting the App's flash-bundle upload at the App ingress; the two Flash operations' plan (`job.plan`), admission and `debug.start`/`debug.evaluate` (observe, stop), none of which need the upstream ArkForge client change; `flash.lanePlanPreview` and the Flash run, which do |

## The oracle

`FlashBundleArchiveOracleContractTests` reads every archive in
`rust/tests/fixtures/flash-archive/archives`. Each archive is small, and
`make-archives.py` there records how it was made. For each one the oracle
records, in `oracle/cases.json`:

- `GzipTarArchiveReader.summarize`, with the board's `derivationRequest`:
  - the archive's size and digest;
  - every regular member's name, size and digest;
  - the partition table it kept, as a size and a digest;
  - the version it scanned;
- `RockchipImageArchiveIntrospection.describe`: the declared partitions and
  every member's classification;
- `RockchipFlashProfile.forBuild`: the board carrying the build's facts;
- the policy's own answer.

A step that throws is recorded as Swift interpolates the error. No daemon,
device or engine is involved.

**41 archives.**

- **The gzip header.**
  - Readable: plain; with every optional field (extra, name, comment,
    header CRC); two concatenated members, where the second is ignored.
  - Refused: a name running past 64 KiB, method 7, a reserved flag, five
    bytes of header, an empty file, and a plain tar.
- **The DEFLATE payload.** Cut at three fifths, or garbage after the header.
  Apple's decoder refuses both as `decompressionFailed`, in Swift as here.
- **The tar records.**
  - Handled: a ustar prefix; pax extension and directory records, which are
    skipped; a symbolic link; trimmed end-of-archive blocks; a base-256 size.
  - Refused: a checksum mismatch, an octal digit that is not one (in the
    checksum field and in the size field), a size with no room for its
    alignment, a numeric overflow, an empty name, and a stream cut inside a
    member.
- **The partition table.**
  - Missing, or over the 1 MiB it may be kept at.
  - No `mtdparts`; no device prefix; an entry without parentheses; a bad
    hexadecimal field; a signed one; an empty list; not UTF-8.
  - Two CRLF tables. Swift's `split(separator: "\n")` splits on Characters,
    and `\r\n` is one Character, so a CRLF table has no line to find: Swift
    finds no `mtdparts` when `CMDLINE` is not the first line, and reads its
    last entry across the rest of the file when it is.
- **The version scan.**
  - Found across the decoder's 1 MiB output window, and after a value run
    long enough to be noise.
  - Not found: never present, or running to the end of its member.
- **The board.**
  - A table and an image set that do not fit, with all three kinds of
    violation.
  - A member name that appears twice.

The recording ran once, then was compared byte for byte without its record
variable.

## Swift, as ported

- **Raw DEFLATE** (`arkdeck_platform::RawInflate`, Swift's
  `RawDeflateDecompressor`):
  - Apple's `compression_stream` with `COMPRESSION_ZLIB`, the library Swift
    uses. Its 1 MiB windows are emitted as they fill.
  - The feed loop follows Swift's, stall rule included.
  - Nothing after the final block is decoded.
  - This adds no third-party crate.
- **The reader** (`flash_archive::summarize`, Swift
  `GzipTarArchiveReader.summarize`):
  - 1 MiB reads, with a failed read ending the input.
  - The RFC 1952 header, buffered up to 64 KiB.
  - The ustar parse:
    - the checksum;
    - octal and GNU base-256 numbers, with their overflow guards;
    - the POSIX prefix;
    - regular files only, every other record skipped as opaque content.
  - The partition table captured under its bound. A member that overran the
    bound is not kept at all.
  - Swift's streaming version scanner, restart rule and 256-byte noise bound
    included.
- **The introspection** (`describe`, `partitions`):
  - The table is parsed over Characters, as Swift's `String` does
    (extended grapheme clusters).
  - Foundation's whitespace set is used for trimming.
  - `Int64(_:radix: 16)`, sign included, reads each hexadecimal field.
- **The board** (`classification`, `conformance`, `for_build`): the DAYU200
  profile's nine mapped partitions and six write-forbidden ones, and its
  naming rule.
  - The three kinds of violation, in Swift's order.
  - `unsupportedAction` rendered as its reason.
  - The duplicate member name check.
- **The commit** (`import_publication::validate_content`, Swift
  `RuntimeImportControlHandler.validate`):
  - The registered profile must be `dayu200`.
  - The staged payload is read through the retained inode, by offset
    (`HostUploadFile::validator_reader`).
  - Any failure is Swift's one refusal: `invalidInput`, "Import content
    failed its registered format validator". The Import stays in progress
    and nothing is published.
  - A validated archive that does not match the Import's metadata is
    `artifactIntegrityFailed`.
  - A valid bundle is published with `{"kind":"flash-bundle",
    "deviceProfile":"dayu200"}`.

## Declared differences

- **Member names that are not ASCII.** Swift decides duplicate member names
  by canonical equivalence. This Runtime has no normalization tables, so it
  refuses a bundle with any member name that is not ASCII, rather than
  compare such names by their bytes and accept two names Swift would call
  one. A DAYU200 daily's seventeen names are ASCII. This is fail-closed.

**Found while recording.** A CRLF partition table, as described under the
oracle, is refused by Swift. The port keeps that behaviour.

## Verification

**Local targeted checks.** `CARGO_BUILD_JOBS=2`, `CARGO_INCREMENTAL=0`, own
target `/private/tmp/arkdeck-m4-rust-target`, logs
`/private/tmp/arkdeck-m4-flash-archive-*.log`.

| Check | Command | Result |
|---|---|---|
| Swift recording | `ARKDECK_RUST_FLASH_ARCHIVE_RECORD=… run-swiftpm.sh test --filter FlashBundleArchiveOracleContractTests` | exit 0; 41 archives (`swift-record.log`) |
| Swift verify | the same without the record variable | exit 0; byte for byte (`swift.log`) |
| Replay | `cargo test -p arkdeck-hoststore --lib flash_archive` | passed. Every archive's four answers are Swift's, on the first run after the `unsupportedAction` rendering was corrected |
| Commit | `cargo test -p arkdeck-hoststore --test flash_bundle_import` | 2 passed. Two bundles are published with Swift's facts; seven, from a plain tar to a duplicate member, are refused with the validator's refusal, stay in progress and publish nothing |
| Decoder | `cargo test -p arkdeck-platform --lib host_inflate` | 2 passed: every input split, the ignored trailer, a cut and a malformed stream, a refusing sink |
| Mutations | five, against the replay: lines split by scalars instead of Characters, an overflowing capture kept, duplicate names accepted, the header CRC field not skipped, the noise bound raised | 5/5 caught; the source restored by digest |
| fmt, clippy | `cargo fmt --all --check`; `cargo clippy -p <crate> --all-targets -- -D warnings` for `arkdeck-platform` and its direct dependents (`arkdeck-hoststore`, `arkdeck-agentd`, `arkdeck-cli`, `arkdeck-provider-arkforge`, `arkdeck-provider-workspace`, `arkdeck-provider-hdc`, `arkdeck-client`, `arkdeck-soak`) | exit 0 (`fmt.log`, `clippy.log`) |
| Crate tests | `cargo test --no-fail-fast -p <crate>` for the same nine | exit 0 each: platform 184, hoststore 575, agentd 151, cli 252, provider-arkforge 19, provider-workspace 27, provider-hdc 181, client 10, soak 4 (`test-<crate>.log`) |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv) | PASS on macOS; 135 control responses (`readonly.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0 (`sdd.log`) |

**CI.** Pending.

**#2155 (M4-4a2), recorded here.**

- *Head `1579a6d8`.* Every check passed on the first run: SDD Guard run
  36068200450, and Swift CI run 36068200812, whose `swift` aggregate and Rust
  lanes on ubuntu, macos-26 and windows passed.
- *Merged* as `43a8c2ed`.

No device, installed service, real `arkforged` or App was used, and nothing
here is device evidence. The archives are synthetic; no real DAYU200 image
was read.
