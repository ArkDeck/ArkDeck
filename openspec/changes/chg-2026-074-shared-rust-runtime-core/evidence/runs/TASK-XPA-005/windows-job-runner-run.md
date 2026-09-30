# TASK-XPA-005 — WM1 slice A2: the Job runner, cancellation, results and recovery on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM1, GJ-1: the `job.run`, `job.cancel`,
`job.result`/`job.evidence`, start-up recovery and `operation.list` hops on Windows. Branch
`agent/xpa-005-windows-job-runner-20260930`, **stacked on #2376** (A1, the planner and admitter)
and **#2373** (H3, the Session owner, publication and snapshot pages), which are stacked on
#2361 (H2, the Job store owner); the stack's heads and `main` are merged in (see the commit).
Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device was contacted, no HDC or
board was used, no `hdc` was run, nothing installed was read or written, and no system setting
was changed. Host tests are not Windows acceptance.

## Scope (lead, 2026-09-30)

Port the Job runner and `device_run`, Artifact publication, `job_result`, `job_cancel` and
`operation_availability` to Windows and compose the runner on the daemon. The HDC tuple stays
gated (maintainer samples → integration change), so no device Job runs; the proof is the
runner's restart and recovery paths, a queued Job's cancellation and `job.result` on the
recorded Swift corpora, in process and through the daemon, and `operation.list` matching the
macOS no-HDC answers. Session publication comes from H3 (#2373); its hoststore files are not
changed here.

## What

`arkdeck-hoststore`, now also built on Windows (the macOS code unless said):

| Item | Notes |
| --- | --- |
| `job_run` (`JobRunner`, `RunRefusal`, `runtime_precise_now`), `device_run` with its HAP-failure, native, screen-sequence and trace submodules | the device lane; the analyzer lane (`execute`, `dispatch`, `dispatch_arktrace`), `workspace_run.rs` and `flash_run.rs` stay `cfg(target_os = "macos")`; on Windows `executes` is the device lane, and an analyzer or workspace Job is refused before its run as one this Runtime does not execute |
| `job_cancel` (`JobCanceller`, `RunCancellation`), `job_result` (`JobResultReader`) | `job_result`'s Flash step-kind projection stays macOS (no Flash Job exists on Windows) |
| `artifact_publication`, `capture_documents` | a landed file's bytes are read by `landed_file_bytes` (the macOS read moved verbatim into it; on Windows `measure_host_file` before and after the read, no reparse point followed, same messages); `capture_documents`' Flash report and facts stay macOS |
| `mutation_execution`, `job_lineage_repair`, `job_recovery`, `job_owner::retention_census` | `consume_workspace_authority` stays macOS (workspace lane); `job_recovery` does not read a Flash recovery epoch on Windows: a Flash Job interrupted in `finalizing` is left as it is (error), never failed unproved |
| `operation_availability` | reads the analyzer facts from `analyzer_operations.rs` (moved out of `analyzer_composition.rs`, re-exported there on macOS) and the Windows stand-ins of `host_unavailable_reason`/`runtime_availability` (macOS's answers with no composition) |
| `MutationAuthority` | now the same struct on Windows (was a valueless stand-in in A1); its proof of the mutation state fails closed on Windows (`recordUnreadable`): the Job owner's continuity census is not built there |
| `ArtifactUsage`, `format_time::utc_precise_now` | exported / built on Windows |

`arkdeck-platform`: `runtime_home` on Windows, the account's profile Known Folder
(`FOLDERID_Profile`), never `USERPROFILE` — Artifact redaction's home, as `NSHomeDirectory()` on
macOS.

`arkdeck-agentd` (Windows):

- `Host`: the run slots, capability store, Session storage, claims, holds, home and the quarantine
  and staged-Session notes are composed as on macOS; `authority()` is shared (no mutation root
  on Windows, so none); `job.cancel` and `job.result`/`job.evidence` are the macOS handlers;
  `job.run` builds `JobRunner` as macOS builds it with this composition's owners (no HDC,
  analyzer, workspace or Flash); `operation.list` reports with the planner, Job and Artifact
  owners and no HDC — HDC operations `provider_not_registered` — and the analyzer provider not
  registered (none is built on Windows; the offline Trace surface, #2360, already reports it so).
- `windows_lifecycle::Authority::compose`: the capability store in `jobs-state\capabilities`;
  over a development root the Session owner (`session-state`, default root `sessions`) beside
  the Artifact usage owner. The macOS isolated owner also bounds a selected Session root to the
  development root (`SessionStore::isolated`), which needs the root opened as a private
  directory; a Windows development root need not be one, and no storage request is served on
  Windows, so only the default root is reachable. The account root composes no Session owner
  yet (its Sessions' place beside `%LOCALAPPDATA%\ArkDeck\Agentd` is open).
- `main.rs`: the start's `recover_active_jobs` and staged-Session recovery run on Windows as on
  macOS. The start's Artifact retention sweep stays macOS-only in this slice (it would reclaim
  the recorded fixtures' expired Artifacts in #2356's daemon test).
- Census: `jobs, capabilities, targets, artifacts, storage, workspaceProjects, planning` (the
  macOS order); the Windows daemon tests asserting it are updated. H2's
  `windows_job_store_process.rs` now recovers its recorded Jobs as the daemon's start does before
  it compares (the parked Job's recovery marker).

On macOS the changes are attributes, the `analyzer_operations` move (same items, same paths via
re-export), `landed_file_bytes` (the same statements, now a function both publishers call) and
`drain` moved from `workspace_run.rs` to `job_run.rs` (same body). Linux builds none of these
modules, as before.

## GJ-1 hops and tests

1. **Restart and recovery** (`arkdeck-hoststore/tests/job_recovery.rs`, the macOS test now on
   Windows too): an outstanding intent parked and marked once, a clean cancellation and an
   interrupted finalization completed, a reconcile decision's transition completed, an absent
   admission projection restored (a partial one refused unchanged), an unreadable record
   quarantined and a capability Job refused without its store — 5/5 on Windows. The one step
   that needs the reconciler stays macOS.
2. **Recorded results** (`tests/windows_job_runner.rs`): the `observe.device@1` corpus's 8
   `job.result`/`job.evidence` exchanges answer as Swift answered (T0; refusal wording T2) over
   the records, journals and Artifacts laid down as Swift left them.
3. **Queued cancellation**: an `observe.device@1` Job admitted in process (HDC composition over
   the recorded Target, a dispatcher that fails the test if called) is cancelled before it runs:
   the same three transitions and reasons and the same `operationFailure` as Swift's
   cancelled-before-run Job (`job-cancel-analyzer` oracle), its Session published
   (`catalogPublished`, the same record fields and proposal as Swift's), and a run then refused
   `resourceConflict` with the zero-dispatch proof. Without an HDC composition a queued device Job
   is refused before its run and stays queued.
4. **The daemon** (`arkdeck-agentd/tests/windows_job_runner_process.rs`): the start recovers the
   recorded Jobs (`recovered 2 active job(s); unknown outcomes parked`; the parked Job marked as
   Swift's start marks it); `job.result`/`job.evidence` as Swift answered; `job.run` of the queued
   Job refused (`rejected`, `preAdmission`, 0 dispatch), `job.cancel` closes it cancelled with its
   Session published under `sessions`, a later run `resourceConflict`; `operation.list` reports
   `observe.device@1`, `capture.diagnostics@1`, `input.tap@1` `provider_not_registered`; a restart
   reads it all back and changes no record. Through the real CLI against a dev-signed daemon
   (`ARKDECK_DEV_SIGNER_THUMBPRINT`): `job run` refused, `job cancel`, `job status` cancelled,
   `job result` of the observed Job equal to Swift's — **ran** on this host.
5. `arkdeck-hoststore` unit tests on Windows now include the runner's, canceller's, recovery's and
   device lane's own (lib: 101 passed, 2 ignored).

## Follow-ups (not in this slice)

- **HDC tuple gate**: a device Job running on Windows needs the registered Windows HDC tuple,
  then an HDC composition; nothing here dispatches.
- The Job reconciler (`job_reconcile*`), the Agent engine, the Session storage requests
  (`runtime.storage.*`) and the account root's Session owner.
- The start's Artifact retention sweep on Windows (the census is built; composing it changes
  what #2356's daemon test reads).
- The mutation authority on Windows (the continuity census), the analyzer lane (trace_streamer),
  the workspace lane (XPA-011) and the Flash lane (AF-W1).
- CLI coverage for `job.run`/`job.cancel`/`job.result` is not raised: no device Job runs.

## Local checks (Windows 11 x64, `CARGO_TARGET_DIR=D:\cargo-target\s1-runner`)

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | clean |
| `cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-platform` (with `ARKDECK_DEV_SIGNER_THUMBPRINT`) | 0 | all pass: `job_recovery` 5/5, `windows_job_runner` 3/3, `capability_read` 1/1, `capability_write` 5/5, `windows_observe_device_admission` 2/2, `windows_job_runner_process` 2/2, every other Windows daemon test |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |
| `git diff --check` | 0 | clean |

macOS and ubuntu cannot be built here; the cfg pairings were reread by hand. CI decides.
