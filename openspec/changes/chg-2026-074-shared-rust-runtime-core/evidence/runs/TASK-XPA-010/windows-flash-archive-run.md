# TASK-XPA-010 — WM4 part B1: the Flash archive reader on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM4, GJ-4 (D2, destructive): software
part only. This is part B1 of the slice's ordered PRs, after part A (#2403, the paired lane).

The Flash planner reads a flash bundle's lease through the Flash archive reader
(`flash_plan.rs` → `flash_archive::summarize`/`describe`/`for_build`). So does the flash-bundle
Import validator (`import_publication.rs`). On macOS the reader decodes DEFLATE through Apple's
Compression library, which Windows does not have. This part gives Windows the decoder, then the
reader, and replays the Swift archive oracle on Windows.

Branch `agent/xpa-010-windows-flash-lane-b-20260930`, one commit on `origin/main` `86d2f2b8`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device, HDC, board or `arkforged` was used.
- Host tests are not Windows acceptance.

## What

| Crate | Item | Notes |
| --- | --- | --- |
| `arkdeck-platform` | `windows::inflate` (`RawInflate`, `InflateError`, `INFLATE_WINDOW_BYTES`) | A raw DEFLATE (RFC 1951) decoder in safe Rust, with the macOS decoder's surface. Windows ships no raw DEFLATE decoder, and a third-party crate would be a new supply-chain entry. |
| `arkdeck-hoststore` | `flash_archive` on Windows | The macOS reader, unchanged. It is marked dead code on Windows, because its two readers are not composed there yet. `sha2` becomes a macOS-and-Windows dependency. |
| `arkdeck-hoststore` | the oracle test | The label an error quotes is `<archives>/<name>` on both hosts (on macOS, the path it was before). On Windows, Swift's quoting doubles the backslashes of the directory, so both spellings are replaced by the placeholder. |

The decoder in detail:

- It is fed in any split, and resumes at the last whole unit: a block header with its code
  tables, one literal, one length/distance pair, or a run of stored bytes.
- It keeps 32 KiB of history.
- It hands its output on in windows of at most 1 MiB: each window as it fills, then what is left
  once the input is consumed.
- Input after the final block is ignored, as Swift ignores the gzip trailer.
- A malformed stream is `DecompressionFailed`. So is a stream finalized before its final block,
  as Apple's library refuses both (the macOS unit test records this).
- Code sets are judged as zlib judges them: over-subscribed sets are refused, and so are
  incomplete sets, except a literal or distance code whose longest code is one bit.

## Oracle comparisons

| Oracle | Windows result |
| --- | --- |
| `flash-archive` (Swift `FlashBundleArchiveOracleContractTests`, 41 archives: summary, build, profile and Import policy answers each) | **41/41 equal.** This includes `garbage-deflate`, `truncated-deflate`, `truncated-tar`, `trailer-trimmed`, `version-straddles-window`, `gzip-optional-fields` and `gzip-name-over-64k`. |
| `raw-deflate` (new: zlib 1.3.1 raw streams at level 1, level 9, `Z_FIXED` and `Z_RLE` of one 1.14 MB plaintext; written by `make-streams.py`) | Every stream, fed whole and in chunks of 64 KiB, 4 099 and 97 bytes, decodes to the recorded plaintext (length and SHA-256). Every stream cut in half is refused. |
| The decoder's unit tests (the macOS module's cases, plus a stored-block and a window case) | Every split of the macOS test vector decodes the same. A cut-short stream, garbage input, a wrong stored-length complement, and a distance before the output are all refused. A sink refusal ends decoding with the sink's error. 1 MiB + 3 bytes of stored output leaves in windows of at most 1 MiB. |

## Local targeted checks

The environment for every check:
`ARKDECK_DEV_SIGNER_THUMBPRINT=AAC23CA4D38D100996C861D9E1A68DEECD69B149` and
`CARGO_TARGET_DIR=D:/cargo-target/f1-flash`.

| Check | Result |
| --- | --- |
| `cargo fmt --all --check` | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | clean (Windows) |
| `cargo test -p arkdeck-platform -p arkdeck-hoststore` | all pass, 0 failed. The only `SKIPPED` line is main's by-design one (#2396): wildcard listeners run only on GitHub Actions. None comes from this change. |
| The same with `TEMP`/`TMP` set to the 8.3 spelling `C:\Users\fuhan\AppData\Local\Temp\F1-FLA~1` | all pass |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`, `git diff --check` | pass, clean |

Not run here: macOS (no host). On macOS the only code change is the oracle test's error label,
which spells the same path it did before.

## Delegated minor decisions

These are pending the next rulings batch.

1. **A decoder of our own rather than a crate.** No DEFLATE crate is in `Cargo.lock`, and adding
   one (for example `miniz_oxide`) would need a supply-chain review. The decoder is about 400
   lines of safe Rust, held to Swift's recorded answers by the archive oracle and to zlib by the
   stream fixtures.
2. **Output windows.** Apple's library decides internally where a window ends before it is full.
   This decoder hands on a partial window only when its input is consumed. The archive reader's
   answers do not depend on where a window ends: the 41 oracle cases include a version string
   that straddles a window. The oracle is the check.

## Left out, and why

- **The flash-bundle Import validator on Windows** (`import_publication.rs`, which calls
  `flash_archive::import_validation`). It belongs to the Windows Import owner (H3,
  `agent/xpa-008-windows-import-owner-20260930`, #2397). Once that lands, it is a one-line gate
  to switch on; it was coordinated with H3.
- **The Flash planner, admission, run and daemon composition.** These are parts B2, C and D of
  this slice.
