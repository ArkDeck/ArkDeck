# TASK-XPA-008 — Windows run record: the Import owner on the Windows daemon

Change: CHG-2026-074-shared-rust-runtime-core. The Import owner (`artifact.import.*`, an
Import's Artifacts, a Job's Import inputs) built on Windows and composed on the Windows daemon.

Base: protected `main` `565f8b1d` (with #2385, the Job/Session/runner composition, #2382, #2391 and #2394).
The work began on #2381's head and #2385's; once #2385 landed as a squash it was rebuilt as one
commit on `main`. Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device
was contacted, no HDC or board was used, no operation was submitted, nothing installed was read
or written, and no system setting was changed. Host tests and hosted CI are not Windows
acceptance.

## What

- **arkdeck-hoststore**: `import_upload` (with its lifecycle, publication and references) builds
  on macOS and Windows; S1's Windows placeholder (`absent_import_upload.rs`) is removed.
  `TargetStore::resolve_import_binding`, the owner's one Target read, builds on Windows too. The
  code is the macOS code. The one carve-out: a `flash-bundle` Import is refused at publication
  on Windows as a kind whose validator is not configured (`operationUnavailable`, "This Import
  kind's publication validator is not configured", the words macOS answers for such a kind),
  before anything is published, until the Flash archive reader is ported (AF-W1). Its begin and
  upload are the macOS ones.
- **arkdeck-agentd**: the Windows daemon composes the Import owner over its Artifact root's
  private `.imports-v1` right after the Artifact owner; the census gains `imports` in its macOS
  position (`jobs, capabilities, targets, artifacts, imports, storage, workspaceProjects, …`).
  `artifact.import.*` routes to it as on macOS; an Import's Artifacts are read through it; the
  Windows Job planner and runner are handed it.
- **arkdeck-cli**: `artifact import <kind>` uploads on Windows through the host store's
  `HostImportSource` (#2357); other hosts keep refusing the upload before any frame.
- **Coordination**: W1's #2382 (on `main`) widened `artifact.import.list`'s published error
  codes for the no-owner answer; with the owner composed, `list` answers its page, so the
  `artifact.import.list` block of `windows_method_conformance_process.rs` now expects the
  owner's (empty) page, schema-valid.

## Measurements (Windows 11 x64)

1. **Recorded Swift corpora on NTFS**: `hoststore/tests/import_upload.rs` (31 tests, including
   the Swift upload snapshot `import-upload-current` reopened and resumed without rewriting its
   records), `tests/import_target.rs` (5, the recorded Target stores) and the in-crate Swift
   Import refusal oracle (4: every recorded refusal answered in Swift's code, words and
   details). Fixtures are made owner-only by `tests/fixture_fs` (mode bits on macOS; the store's
   owner-only DACL on Windows, a second hard link standing for a symbolic link). The tests that
   run an analyzer script or kill a child by signal stay macOS-only.
2. **CLI upload tests** (`arkdeck-cli/tests/import_resources.rs`, 13). One case differs by
   platform: Windows holds the source open without write sharing while it is sent, so the
   "changed source" case checks the write is refused rather than detected.
3. **Real daemon across a restart** (`agentd/tests/windows_import_owner_process.rs`), over the
   recorded Swift Target store of one adopted Target: a HAP begun, appended and committed,
   published with its exact bytes, read through the Import owner; a flash bundle refused with
   nothing published; after a restart the Import listed and inspected with the same receipt,
   released, and its Artifact still readable.
4. **Real CLI against the dev-signed daemon**: `artifact import hap`, `inspect`, `list`,
   `release`.
5. Existing Windows process tests with the Import owner composed: the unknown-Import Artifact
   read now answers the owner's `resourceNotFound` ("Import does not exist", no dispatch), and
   the Trace export test's untouched-store check passes the owner's `.imports-v1` over.

## Local targeted checks

Worktree `D:\src\ArkDeck-wt\h3-import`, `CARGO_TARGET_DIR=D:\cargo-target\h3-session`,
`ARKDECK_DEV_SIGNER_THUMBPRINT` exported.

| Command | Exit | Notes |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | |
| `cargo test --no-fail-fast -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-platform -p arkdeck-cli` | 0 | normal TEMP; 248 test binaries, signed-CLI tests ran, none SKIPPED |
| the same with TEMP/TMP an 8.3 short-name path | 0 | as the hosted runner; 248 test binaries, none SKIPPED |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |
| `git diff --check` | 0 | |

The gates ran on this commit on `main` `565f8b1d` (#2389, #2391, #2392, #2393, #2394). On that
base the Windows runner is #2391's `windows_runner`, which now takes the Import owner (for
`job.run`, an agent execution's Job and `job.reconcile`, whose reconciler takes it too), and
#2394's start-up retention sweep passes the owner's `.imports-v1` over (its process test still
reclaims the four expired Artifacts).

Not run here: macOS and Linux builds. macOS answers and bytes are unchanged (the flash-bundle
arm is `cfg(target_os = "macos")` exactly as before; the tests keep their mode bits and
symbolic links on macOS through `fixture_fs`); Linux still refuses the CLI upload and builds no
Import owner. CI decides.

## CI

To be recorded; not verified here.
