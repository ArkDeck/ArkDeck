# TASK-XPA-005 — WM1 slice H3b run record: Session removal, cleanup, export and storage on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM1, slice H3b (TASK-XPA-005/014 on
Windows): the host store's Session removal on NTFS, the Session cleanup and export owners, the
Artifact usage owner, and the Windows daemon's composition of the Session owner with
`runtime.storage.*`, `session.*` and the start's staged-Session recovery.

Base: the head of #2373 (H3, `ec92b245`), with `origin/main` `ff7f5c8c` merged in (#2356
squash-merged, #2368, #2369, #2370, #2374). Every conflict of that merge is #2356 against this
branch's own earlier merge of it; the branch side, which composes it with the Job store and
the Session pager, is kept (two places git re-applied #2356's side silently were restored: the
pager's bounded tests gate and a duplicated `rust/README.md` paragraph; the stale Windows
`require_artifact_job` stub was removed). Host: the Windows 11 x64 reference host,
non-elevated, NTFS. No device was contacted, no HDC or board was used, no operation was
submitted, nothing installed was read or written, and no system setting was changed. Host
tests and hosted CI are not Windows acceptance.

## What

1. **Session removal on NTFS** (`arkdeck-platform/src/windows/host_session_removal.rs`,
   `PreparedSessionRemoval`), after W1's `host_trace_removal.rs` (#2367): the same bounded
   capture of the year/month/Session tree as macOS (owner, single link, regular or directory,
   no reparse point followed, every file digested); each removal deletes through a handle
   opened relative to its held parent (`DELETE`, no reparse point followed) and compared with
   the capture just before, so a replacement is never removed. Session removal has no
   quarantine rename (macOS has none either). Five unit tests: only the inspected Session is
   removed and the neighbour and calendar directories stay; a junction, a second hard link or
   a file anyone may write is refused before removal; changed bytes or membership invalidate
   the prepared tree; NTFS refuses to move an ancestor away while the prepared tree is held; a
   fault after the first delete leaves an owned residual and touches nothing new.
2. **Session cleanup and export owners** (`session_cleanup_owner`, `session_export_owner`,
   `session_cleanup_records`, `session_cleanup_plan`, the cleanup and export censuses,
   `session_export_artifacts`, `session_export_manifest`, `SessionExportRedactor::relative_path`)
   and **`ArtifactUsage`** build on Windows. The code is the macOS code; the one Windows arm is
   an export destination's absolute rule, which is the Session root's
   (`session::absolute_root`: a local drive's `D:\…`); its physical spelling is E1's.
3. **CLI**: the Session export preview and result checks accept the Windows spelling of an
   absolute path (`session_resources::absolute`); macOS and Linux keep `/…`.
4. **Daemon**: `Authority::compose` composes the Session owner (`Authority::session_store`) and
   the Artifact usage owner over `artifacts`; the census gains `storage`
   (`targets, artifacts, jobs, storage, workspaceProjects`). The Session owner keeps its
   settings in a private `session-state` and its default Sessions root in a private `sessions`
   (the macOS isolated owner's names). A development root's owner is isolated as on macOS (the
   selected Sessions root stays inside the development root and outside the reserved owners'
   directories); on Windows the isolation boundary is the daemon's held state root, whose DACL
   may grant SYSTEM, so `isolated` checks its canonical spelling there instead of opening it as
   a private directory (macOS unchanged). The Session paths are spelled plainly (`D:\…`) even
   when the root is verbatim. The account's root keeps `session-state` and `sessions` below
   `Agentd` until the Windows App names its Sessions location (macOS: `ArkDeck/Sessions`), a
   delegated minor decision. The start removes staged Sessions a crash left
   (`recover_staged_sessions`), as on macOS.

Still macOS-only: the Artifact quota answer (`artifact.quota`), the Job runners, cancellation
and reconciliation that call the publication writer, and the Session-continuity census of a
device mutation. Admission and the runners were left to S1.

## Measurements (Windows 11 x64)

1. **Swift storage lock-wait oracle, every frame** (`hoststore/tests/windows_session_owner.rs`):
   `runtime.storage.status`, `.policy`, `.root`, `session.list`, `session.pin`,
   `session.export.preview` and the final status, each sent while the storage (or catalog)
   lock is held, answer Swift's recorded frame byte for byte once it is released, the
   Artifact domain and the export preview included (roots and destination read as the
   oracle's paths; revision, preview id and digest, device, inode and volume values as its
   labels), schema-valid.
2. **Unit tests now on NTFS**: the cleanup owner (8), export owner (4), cleanup records (6),
   cleanup and export censuses (2 + 6) run on Windows with their fixtures made owner-only by
   `test_private`. One case differs by the platform, not by the owner: Unix lets the Sessions
   root be renamed away while a cleanup applies and the cleanup refuses; NTFS refuses that
   rename while the cleanup holds handles inside the root, so the cleanup applies to the root
   it proved. The cleanup lock-order tests stay macOS-only (they compose the mutation
   authority and capability store).
3. **Real daemon across a restart** (`agentd/tests/windows_session_owner_process.rs`), over the
   recorded Swift `observe.device@1` Sessions and catalog: storage status pairs the Session
   domain (two Sessions, catalog generation 2) with the Artifact domain; `session.list` a page
   at a time, `show`, `pin`; `session.export.preview` and `apply` export the observed Session's
   Manifest into a new directory; a policy the Sessions exceed makes `session.cleanup.preview`
   reclaim the unpinned Session and keep the pinned one, and `apply` removes exactly it. After
   a restart the catalog lists the kept Session, the same cleanup tuple answers the same
   receipt and nothing is removed again. A `sessions` directory that is not owner-only refuses
   the start.
4. **Real CLI against the dev-signed daemon** (`ARKDECK_DEV_SIGNER_THUMBPRINT` from
   `HKCU\Environment`): `runtime storage status`, `session list`, `session show`,
   `session export preview` and `apply`.
5. Every earlier Windows daemon process test (Target, Job store, Artifact, workspace, client
   start, lifecycle, Trace offline) passes with the Session owner composed.

## Local targeted checks

Worktree `D:\src\ArkDeck-wt\h3-session-cleanup`, `CARGO_TARGET_DIR=D:\cargo-target\h3-session`.

| Command | Exit | Notes |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | |
| `cargo test --no-fail-fast -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-platform -p arkdeck-cli` (with `ARKDECK_DEV_SIGNER_THUMBPRINT`) | 0 | 231 test binaries ok; hoststore lib 115 + the pager's 5 bounded tests restored after the merge, platform lib 110, cli lib 65; `windows_session_owner` 1, `windows_session_owner_process` 3 |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 | |
| `git diff --check` | 0 | |

Not run here: macOS and Linux builds. The macOS side was re-read cfg by cfg: the ported unit
tests keep their mode bits and symbolic links on macOS through `test_private`, the one
root-replacement case keeps its Unix assertions under `cfg(unix)`, `isolated` keeps its macOS
boundary check, and no macOS answer changes. CI's macOS and ubuntu lanes are the verdict.

## CI

First head `3c7a8ffb` (PR #2377): run 36694381427 red on `rust-checks / Rust workspace
(windows-latest)`, step "Workspace tests" (job 109819127718). Both causes were real, not load:

1. The hosted runner's TEMP is spelled short (`C:\Users\RUNNER~1\...`). The daemon opened the
   Session store and the Artifact usage owner by `<root>\<name>` paths spelled from that root,
   which the host store's canonical-path rule refuses ("host snapshot refused"), so every
   daemon of a development root below TEMP ended its start: `windows_client_start_process`,
   `windows_lifecycle_process`, `windows_trace_offline_process` and the CLI's
   `windows_signed_runtime`. Reproduced here with TEMP set to an 8.3 spelling of the scratch
   directory. Fixed: `session-state`, `sessions` and the usage owner's `artifacts` are the
   paths `StateRoot::private_child` answers, the directories as the file system resolves the
   opened handles; the development isolation boundary is their parent in that spelling.
2. `gj1_session_commands_run_through_the_cli_against_a_dev_signed_daemon`: the CLI refused the
   export preview the daemon answered (the same preview passed over the pipe). The CLI required
   every device and inode field to fit `i64`, as macOS `dev_t`/`ino_t` do; an NTFS file
   reference carries its sequence number in the top 16 bits and may use the whole `u64` (the
   method schema only requires a string). Fixed on Windows (`session_resources::file_decimal`,
   with a unit test); macOS keeps the `i64` bound. Not reproducible on this host, whose file
   references are small: it is the only host-dependent value the CLI checks there, so this
   cause is inferred, and CI decides.

After the fixes, the four crates' tests pass here both with the normal TEMP and with the
short-name TEMP (231 test binaries each, the signed-CLI tests run, none SKIPPED); fmt and
clippy exit 0. CI of the fixed head: to be recorded, not verified.
