# TASK-XPA-005/015 — `artifact.quota` and the workspace mutation census on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, slice CI2-Q. Base: #2361's head
`cc863b11` (the Job store composed on the Windows daemon). Host: the Windows 11 x64 reference
host, non-elevated, NTFS. No device was contacted, no HDC or board was used, no operation was
submitted, nothing installed was read or written, and no system setting was changed. Host tests
are not Windows acceptance.

## What

1. **`artifact.quota` on the Windows daemon.** #2377 composes the Session owner on Windows and
   left the quota out. `artifact_quota.rs` (Swift `RuntimeArtifactStore.totalBytesUsed()`
   without its cache) now builds on Windows with one walk and one set of answers:
   - the classification, the index decode and every row check are shared;
   - only the reads under them are the host's.
     - macOS keeps Swift's own system calls, verbatim, in a `host` module.
     - Windows reads through the host store (`HostDirectory`), which never follows a reparse
       point. The root's entries use `names` and `kind_and_size`, where a junction is neither a
       directory nor a regular file. The index is sized with `kind_and_size`, so empty or over
       16 MiB is "exceeds its read bound", then read with `read`. The payloads use
       `check_payload`, which maps onto Swift's three refusal classes (`Unopenable(errno)`,
       `TypeOrSize`, `DigestOrIdentity`).
   - Whether an index exists is still asked by path, following a link, as Swift's `fileExists`
     does: a dangling link is an absent index.

   The Windows daemon answers `artifact.quota` from its Artifact owner
   (`ArtifactReadStore::quota`, over the same `artifacts` root), which the control trait
   documents as the method's owner. The macOS daemon still answers it through its storage
   owner's `ArtifactUsage`, unchanged. Without an Artifact owner the Windows daemon refuses it
   as the foundation always has (`rejected`).

   One difference is stricter than Swift. On Windows a payload must be the owner-only,
   single-link file the Windows Artifact owners read, and the same `check_payload` guards
   `artifact.read` there. Swift checks only the payload's type and size, and reseals a
   non-`0400` payload.

2. **Workspace project and preset update and remove on Windows.** The Windows arm of
   `Host::workspace_project` answered `recordUnreadable` for every mutation. It now asks the Job
   owner's census, the same closure as macOS:
   - `JobStore::require_no_active_workspace_project_reference` for a project;
   - `require_no_active_workspace_preset_reference` for a preset.

   `workspace_references.rs` now builds on Windows. Only the copy sweep's
   `workspace_reference_facts`, which reads the macOS-only `workspace_sweep`, stays macOS.

   On macOS a Runtime-owned copy's reference maps to its source project through the workspace
   provider (`census_registration`). Windows composes no workspace provider and so has made no
   copy: every reference is compared as written, which is Swift `resolveRegistrationProjectRef`
   for a reference nothing maps. Without the Job owner every mutation is still refused
   (`recordUnreadable`).

The owner census (`Host::owner_census`) is unchanged: it names no new owner. The Windows
daemon still reports `jobs, targets, artifacts, workspaceProjects` in the macOS order.

## Measured

### Quota: the Swift oracle on NTFS

`arkdeck-hoststore/tests/windows_artifact_quota.rs` rebuilds on NTFS each of the 27 roots in
`rust/tests/fixtures/artifact-quota` that Swift `ArtifactQuotaOracleContractTests` recorded.
Each root is rebuilt under an owner-only Artifact root:
- a file mode is the inherited owner-only DACL;
- `0000` is a DACL with no entry;
- a link is a junction, because a file symbolic link needs a privilege the unelevated account
  lacks. A link to a file becomes a junction to the directory beside it.

Results:
- **All 27 answers equal Swift's.** Successes match byte for byte as JSON. Refusals match by
  code and store error, with `(errno N)` compared as `(errno _)`, since the numbers are the
  host's.
- Every root is left entry-for-entry and byte-for-byte as it was.
- A reopened owner answers the same, and the walk keeps no total.

The three payload refusals that carry a number (missing, a link in the payload's place, and no
read access) are the same class on NTFS. The numbers are the host's; Swift recorded 2, 62 and
13.

### Census: a recorded Swift workspace Job on NTFS

`arkdeck-hoststore/tests/windows_workspace_census.rs` uses Swift's recorded
`workspace.prepare-isolated-copy@1` Job (`agent-execution-evidence`, `job-863e…`). The Job store
owner admits it into a private `jobs-state` under its request's own fingerprint. Only what the
census reads is changed: the project and build preset it names, its state or outcome, and,
where a preset is read, its Catalog digest. Results:

| Job | project mutation | preset mutation |
| --- | --- | --- |
| running, `waitingForRecovery`, or succeeded with outcome unknown | refused: `resourceConflict`, "workspace project is referenced by an active or uncertain Job", phase `workspaceProjectOwner`, no new dispatch | refused under another Catalog (read by every closed preset input name); under this build's Catalog not refused, since `prepare-isolated-copy` has no preset input |
| succeeded; or naming another project and preset; or no Job | nothing refused | nothing refused |
| running, then persisted `succeeded` | refused, then nothing refused | same |
| admitted under another request's fingerprint | `recordUnreadable` | `recordUnreadable` |

Every answer was read from the owner and again from a store reopened after the owner closed.

### Real daemon across restarts, and the real CLI against the dev-signed daemon

`arkdeck-agentd/tests/windows_workspace_projects_process.rs`, over the pipe:
- With no Job naming it, the second project's update (generation 2, kind `arkdeck`) and its
  remove are written.
- With Swift's workspace Job admitted as running (the daemon stopped), the first project's
  update and remove and its preset's remove are refused with `resourceConflict` and no new
  dispatch. `projects.json` is unchanged, and the same holds after a restart.
- Once the Job is persisted `succeeded`, the preset and then the project are removed.
- A restart lists no project.

`arkdeck-agentd/tests/windows_artifact_owner_process.rs`: `artifact.quota` over the pipe
answers what the owner answers in process for the recorded `job-73b1…`: the 8 GiB quota, the
index's published bytes, and what remains. It answers the same after a restart, after an export
outside the root.

Through the real CLI against a copy of the daemon signed with the host-trusted development
signer (`ARKDECK_DEV_SIGNER_THUMBPRINT` from the user environment):
- `arkdeck workspace project remove` is refused with `resourceConflict` while the Job runs and
  nothing is written;
- once the Job has ended it succeeds (exit 0), and after a restart `workspace project list` is
  empty;
- `arkdeck artifact quota` prints the owner's answer.

## Local targeted checks

With `CARGO_TARGET_DIR=D:\cargo-target\ci2-quota` and `CARGO_BUILD_JOBS=4`:

| command | exit |
| --- | ---: |
| `cargo fmt --all --check` | 0 |
| `cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-platform --all-targets -- -D warnings` | 0 |
| `cargo test -p arkdeck-hoststore --test windows_artifact_quota` | 0 (2 tests) |
| `cargo test -p arkdeck-hoststore --test windows_workspace_census` | 0 (4 tests) |
| `cargo test -p arkdeck-agentd --test windows_workspace_projects_process` (dev signer set) | 0 (3 tests) |
| `cargo test -p arkdeck-agentd --test windows_artifact_owner_process` (dev signer set) | 0 (3 tests) |
| `cargo test -p arkdeck-hoststore -p arkdeck-agentd --no-fail-fast` (dev signer set) | 0 (129 tests in 131 binaries, 0 failed) |
| `sh scripts/check-sdd.sh` | 0 (0 errors, 0 warnings) |
| `git diff --check` | 0 |

The macOS arms were not compiled on this host: no Apple target is installed. The macOS
`artifact_quota.rs` reads were moved into a module unchanged, apart from the index path now
being joined inside it. The macOS census closure is the one it was, with its registration
lookup named.

## CI

To be recorded by the follow-up (PR number, run id).
