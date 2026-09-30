# TASK-XPA-006 — slice E1 run record: Artifact read and export on Windows

Change: CHG-2026-074-shared-rust-runtime-core@r13. Slice E1 (GJ-1 hop "artifact read/export"),
groups G01 (the host store's export, file-export and payload-cache submodules) and G32
(Artifacts) of the TASK-XPA-004 gate inventory. Host: the Windows 11 x64 reference host
(Windows 11 Pro 10.0.26200, non-elevated, NTFS). No device was contacted, no operation was
submitted and no installed state was read or written; every daemon ran over a fresh development
root below the temporary directory. Host tests and hosted CI are not Windows acceptance.

## What

`arkdeck-platform` (Windows, `src/windows/`):

- `host_file_export.rs`: `FileExportStaging`, the single-file Artifact export. The staging file
  is created with `FILE_CREATE` and the store's protected owner-only DACL relative to the held
  export parent (`NtCreateFile`, `FILE_OPEN_REPARSE_POINT`, a reparse point refused), the
  source is copied from a sealed private payload through a held handle with its identity (file
  id, size, links, attributes, times, owner and DACL) checked before and after, the copy is
  flushed (`FlushFileBuffers`) and its digest re-read, and it is published by the POSIX rename
  (`FileRenameInformationEx`): without `REPLACE_IF_EXISTS` unless the caller asked to overwrite
  the exact owner-held single-link file it saw before copying. An error after the rename is
  `OutcomeUnknown` and never removes or replays anything. An unpublished stage is removed through
  its own handle only while its staging name still links it.
- `host_export.rs`: `ExportStaging` and `HostExportCapacity` (the Session directory export,
  macOS `host_export.rs`), with `GetDiskFreeSpaceExW`/`GetVolumeInformationByHandleW` of the
  held handle for the capacity and read-only flag; cleanup removes only entries it created,
  each through a handle whose identity was checked.
- `host_payload_verification.rs`: `PayloadVerification`, a proof bound to the parent's and the
  payload's `FileIdInfo`, size, links, attributes, write/change/creation times and owner/DACL;
  "sealed" is the Windows reading of `0400` (nobody else anything; the owner may read, not
  write).
- `host_store.rs`: `document_metadata`/`remove_document` now answer and take a
  `HostFileIdentity` (maintainer ruling 7) and `owner_only_document` is added; the export
  parent is held with add-entry rights (a directory flush needs a writable handle, SPK-5).
- `host_fs.rs`: `Stat` carries the creation time; `Access::sealed`; `volume_capacity`.
- `state.rs`: `StateRoot::private_child`, byte for byte the one #2350 (B1) adds, so the two
  merge cleanly: an owner directory created owner-only when absent and never re-permissioned.

Both OSes (ruling 7): `document_metadata`/`remove_document` are `HostFileIdentity`-typed on
macOS too, and their callers changed with them: `snapshot_pager` (size and modification time
from the identity), `bundle_list_owner` with the Bootstrap registry's `validate_index`,
`bundle_registration`, `bundle_retirement`, `tool_retirement` and `tool_list_owner` (their
document comparisons are identity equality), `job_repository` (device and inode),
`control_action_store` (size) and the Rockchip binding store's lock check
(`owner_only_document`, the same `0600` rule `owner_only` already makes).

`arkdeck-hoststore`: `artifact_read_owner` (with its payload cache), `artifact_projection`,
`artifact_resources`, `artifact_export`, `snapshot_pager`, `session_export_destination` and
`artifact_usage` (its index decoder) build on Windows; `ArtifactUsage` (usage/quota answers),
the Import owner and the Session export facts stay macOS-only. `session_export_destination::
physical` gains its Windows spelling (a local drive's absolute path, `.`/`..` resolved lexically,
upper-case drive letter; UNC, device and drive-relative paths refused) and
`ArtifactExportRequest` accepts it. The Unix-fixture unit tests of the un-gated modules are now
`cfg(all(test, target_os = "macos"))`.

`arkdeck-agentd`: the Windows daemon composes `ArtifactReadStore` over `<root>\artifacts`
(`windows_lifecycle::Authority::compose`, the development root and the account root alike) and
answers `artifact.list|inspect|read|export` through the same `artifact_resource` as macOS.
`require_artifact_job` on Windows answers "The Job owner is not configured", which the owner
maps to `operationUnavailable` / "Artifact Job owner is unavailable" before any Artifact byte,
index or snapshot page is touched; an Import owner reference is refused as on macOS without an
Import owner.

`arkdeck-cli`: `artifact export --destination` on Windows is spelled as the daemon spells it,
and the receipt's `exportedPath` is checked with the host separator.

## Why each gate came down

| Gate | Why it was macOS-only | Now |
| --- | --- | --- |
| `host_export`, `host_file_export`, `host_payload_verification` | `openat`/`mkdirat`/`renameatx_np(RENAME_EXCL)`/`F_FULLFSYNC`, `stat` fingerprints | The SPK-5 primitives of the NTFS host store (#2338) |
| `document_metadata`/`remove_document` | `std::fs::Metadata` has no stable file id on Windows | `HostFileIdentity` on both OSes (ruling 7) |
| `artifact_read_owner`, `artifact_projection`, `artifact_resources`, `artifact_export` | only the three submodules above and `document_metadata` | built on both |
| `snapshot_pager` | `document_metadata`'s type | built on both |
| `session_export_destination` | Unix path spelling | a Windows arm of `physical` |
| `artifact_usage` | its caller only (`decode_index`); `quota` walks with `std::os::unix` | the decoder on both, `quota` macOS-only |
| agentd `artifacts`, `with_artifacts`, `artifact_resource` | the hoststore owner | composed on Windows; the Job-owner proof is the Windows refusal until the Job owner is composed |

T1 notes: the identity comparisons that also compared mode, uid, gid and link count now compare
the change time instead, which every such change moves (T1-identical); the snapshot pager's
retention orders by `(seconds, nanoseconds)` of the modification time, the same order as
`SystemTime`. On Windows an Artifact whose export file name contains an NTFS-reserved character
(`\`, `:`, `*`, `?`, `"`, `<`, `>`, `|`) is refused (`invalidInput`) rather than renamed, and
`exportedPath` is `C:\dir\ART-…-name`. An export parent is refused when its owner is not the
token user (macOS: not the effective uid); like macOS it may grant others access (inherited
DACL, as a macOS `0755` user directory).

## GJ-1 hop

`arkdeck-hoststore/tests/windows_artifact_owners.rs` (4 tests) lays the macOS-recorded
Artifacts of `rust/tests/fixtures/agent-execution/artifacts/job-73b1…` (index owner-only,
payloads sealed) into a private Artifact root on NTFS and:

- lists them (every recorded row, verified, in the recorded order), inspects each (the recorded
  row) and reads each with its recorded bytes and SHA-256 (T0), warm reads reusing the proof;
  the sensitive `device-facts.json` needs the explicit opt-in (`PermissionDenied` /
  `sensitiveAccessDenied` without it); the wire answers validate against the contract, and the
  Artifact store is byte-for-byte unchanged by every read; `artifact.list` keeps its pages in
  `.imports-v1/artifact-snapshots` as on macOS;
- reproduces the Swift daemon's recorded `artifact.inspect` and `artifact.read` frames
  (`Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/`) exactly;
- refuses a same-size substituted payload, and then every read and list of the Job;
- exports `tool-facts.json` to a fresh directory: the receipt carries the recorded digest and
  240 bytes and the file holds the recorded bytes; then refuses an existing file without
  `overwrite` (`resourceConflict`, the file untouched), replaces it only with `overwrite`,
  refuses a junction in the file's place with or without `overwrite` (`resourceConflict`,
  nothing written through it), a junction as the destination directory and an upper-case
  spelling of it (`invalidInput`), the Artifact store itself, a relative, UNC or
  drive-relative destination, and `%SystemRoot%` (owned by TrustedInstaller; a directory the
  user may write but does not own cannot be made without elevation, which this slice may not
  use); a sensitive Artifact is exported only with `allowSensitive`. The Artifact store is
  unchanged throughout.

`arkdeck-platform` unit tests (`windows::host_store::{file_export,export,payload_verification}`,
13 new) prove the primitives below it: a junction or hard link in the destination's place and a
junction as the parent are refused before staging; a competitor at the destination, a changed
overwrite target, a lifted seal on the source and a tampered staging file all fail before
publication; a renamed-away staging file is not cleaned up; faults after the rename are
`OutcomeUnknown` and keep the published file; the Session directory export publishes a fresh
tree, refuses an existing destination and removes exactly what an unpublished stage created;
proofs are bound to parent, name, digest and size, a writable payload yields none, and a write,
same-bytes replacement or DACL change during a warm or cold read is refused.

Through the daemon (`arkdeck-agentd/tests/windows_artifact_owner_process.rs`, 3 tests), the real
`arkdeck-agentd.exe` over a development root holding the same recorded Job:

- over its pipe: it reports the Artifact owner composed over `<root>\artifacts`;
  `artifact.list`, `inspect`, `read` (with `allowSensitive`) and `export` are each refused
  `operationUnavailable` "Artifact Job owner is unavailable" with `{"phase": "artifactOwner",
  "newDispatchCount": 0}`; a UNC destination is refused `invalidInput` as the request is read;
  an Import reference is refused `operationUnavailable`; after the daemon's stop the Artifact
  store is byte-for-byte unchanged (no snapshot page was written) and the destination is empty;
- an existing `artifacts` directory that is not owner-only (created with the temporary
  directory's inherited DACL) refuses the start with exit 69 ("the Artifact store … is
  unusable; nothing was started"), serves nothing, and is not re-permissioned (ruling 5);
- through the real CLI, against a copy of the daemon signed with the host-trusted development
  signer (`ARKDECK_DEV_SIGNER_THUMBPRINT` from `HKCU\Environment`, signed by
  `rust/scripts/windows-dev-identity.ps1 sign`, the CLI verifying image and signer pin):
  `artifact list`, `inspect`, `read --allow-sensitive` and `export --destination <fresh dir>`
  exit 69 with the daemon's own `operationUnavailable` / "Artifact Job owner is unavailable";
  nothing is written. This ran here with the signer set (not skipped).

The full daemon round trip (`artifact list/inspect/read` returning the recorded bytes and
`artifact export` publishing through the CLI) follows once the Windows Job owner is composed
(slice H2, `agent/xpa-005-windows-job-store-20260930`, on H1 #2345): that composition gives
`require_artifact_job` its Job owner; nothing else in this path changes.

## Local targeted checks (Windows 11 x64, rustc 1.98.1)

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | clean (Windows build of every crate) |
| `cargo test -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli` (with `ARKDECK_DEV_SIGNER_THUMBPRINT` set) | 0 | all pass; new: platform 13 unit tests, hoststore `windows_artifact_owners` 4, agentd `windows_artifact_owner_process` 3, cli `windows_export_destination_…` 1 |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings (union merge ok) |
| `git diff --check` | 0 | clean |

macOS and ubuntu cannot be built on this host. Every changed macOS line was re-read against
its callers: the `Metadata`-typed comparisons became `HostFileIdentity` equality, their now
unused `MetadataExt` imports were removed and added back only in the unit-test modules that
still use them (`bundle_retirement` keeps its full stat comparison for directories in its own
test helper), and the macOS arms of every new `cfg` are the previous code. No test copies a
file without making it owner-only. CI decides macOS and Linux.

Windows CLI coverage (`openspec/contracts/cli-feature-coverage.json`) is unchanged:
`artifact.list|inspect|read|export` stay `partial` (ruling 9) until the Job owner closes the
Windows daemon path.

## CI

To be recorded, not verified.

## Open for the maintainer / next slices

1. H2 composes the Windows Job owner; `require_artifact_job` then reads it on Windows as on
   macOS, and the daemon-level test above becomes the full CLI round trip.
2. A user-writable directory owned by another principal cannot be created without elevation
   on this host, so the Windows "foreign-owned parent" refusal is proved with a system directory
   the user also cannot add to; the owner rule itself is the shared `owned(.., ExportParent)`.
3. The remaining host-store submodules (import-upload, update, trace/session removal,
   diagnostic log) and the Import owner follow with their hops (GJ-2, WM6).
