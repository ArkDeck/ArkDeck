# TASK-XPA-005 — WM1 slice A1: the Job planner and admitter on Windows (GJ-1 `job.plan` / `job.submit`)

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM1, GJ-1 hops `job.plan` and
`job.submit` of `observe.device@1` on Windows. Branch
`agent/xpa-005-windows-observe-device-20260930`, **stacked on #2361** (H2, the Job store owner,
`agent/xpa-005-windows-job-store-20260930` at `3885d716`) **and #2356** (E1, the Artifact read and
export owner, `agent/xpa-006-windows-artifact-export-20260930` at `03cf3384`), both still open,
with protected `main` at `97793944` (#2368) merged in. Host: the Windows 11 x64 reference host,
non-elevated, NTFS. No device was contacted, no HDC or board was used, no `hdc` was run, nothing
installed was read or written, and no system setting was changed. Host tests are not Windows
acceptance.

## Scope decisions (lead, 2026-09-30)

- The slice first asked for `observe.device@1` end to end on the Windows daemon against the fake
  HDC. That needs an HDC dispatch composed on Windows, and no Windows HDC tuple is registered:
  `evidence/xpa-002-readonly-foundation.md` ("Windows HDC registration scope") says a fixture
  executable, an unreviewed hash or a caller-supplied version cannot stand in for the missing
  registration, and #2341/#2350 keep the Windows daemon's HDC dispatch at none. The lead chose
  option A: compose the planner and admitter now, keep the HDC tuple gated until the maintainer's
  samples and the integration change arrive, and add no development bypass. Nothing in
  `openspec/integrations/**` changed.
- **A1, porting rather than carving**: every member the planner and admitter hold is ported where
  its Windows counterpart is cheap; only externally blocked members are carved, keeping the macOS
  struct shape and bytes; `JobPlanner` and `JobAdmitter` are constructed the same way on both
  hosts. Session publication stays None (H3 is porting it, stacked on #2361 + #2356); this slice
  does not touch those files.

## What

`arkdeck-hoststore`, now also built on Windows:

| Item | Windows before | Now |
| --- | --- | --- |
| `job_plan` (`JobPlanner`, `PlanRefusal`) with the debug HAP, native library and screen-sequence/capture plans | not built | built; all members present |
| `job_admission` (`JobAdmitter`, `AdmissionRefusal`, `MutationAuthority`, `runtime_now`) | not built | built; all members present |
| `device_facts` (`HdcComposition`), `device_steps`, `cleanup_debt` | not built | ported (portable code) |
| `capability_store`, `capability_policy` (`CapabilityStore`, `DeviceHolds`, …) | not built | ported: the store directory is created by the host store's owner-only `open_or_create_private` on Windows (`0700` `DirBuilder` on macOS, unchanged); every read and write already goes through `HostDirectory` |
| `catalog_review`, `job_owner::import_references`, `format_time::{utc_now, utc_timestamp, plain_utc_seconds}` | not built | ported (portable code) |
| Artifact read owner (`ArtifactReadStore`) | from #2356 | used by the planner |

Members whose owner is not built on Windows yet are **types with no value** there, so the same
field exists, is always `None`, and the same planner code runs:

| Member | Windows type | Blocked on |
| --- | --- | --- |
| `JobPlanner::imports` | `absent_import_upload.rs`: `enum ImportUploadStore {}` (+ `ImportUse`) | the Import owner's publication needs Artifact publication (A2) and the Flash archive (AF-W1) |
| `JobPlanner::workspace` | `absent_workspace_composition.rs`: `enum WorkspaceComposition {}` | the workspace provider crate and the DevEco toolchain/signing owners (XPA-011) |
| `JobPlanner::analyzer` | `absent_analyzer_composition.rs`: `trait AnalyzerComposition` with no implementation | the ArkTrace profiles pin trace_streamer, which Windows lacks (G20) |
| `JobAdmitter::authority` | `enum MutationAuthority {}` | the Session root owner (H3) and the Job owner's mutation-state continuity census |

Still `cfg(target_os = "macos")` (externally blocked), with a Windows stand-in answering what
macOS answers without the owner:

- the Flash planner and admitter (`flash_plan`, `FlashAdmitter`; the ArkForge lane, AF-W1): a
  Flash operation is `… is not materialized by the Rust Runtime yet` (`rejected`);
- the analyzer paths (`AnalyzerProfile`, `materialize`, `unmaterialized_analyzer`, the ArkTrace
  request cross-field check): `… is runtime unavailable: analyzer.profileUnavailable`
  (`runtime_availability` with no composition), and `None`;
- `workspace_plan`: a Windows `materialize_workspace` answering `provider workspace is not
  registered` (the member is always `None`);
- the authority's uses (`preauthorize`, `preauthorize_workspace`, the capability-gap repair,
  `submit_for_agent`, which also needs the runner): a Windows `preauthorize` answering `… needs a
  Runtime capability, which the Rust Runtime does not issue yet`, macOS's answer without an
  authority.

On macOS only `cfg`/`cfg_attr` attributes were added (plus comments and the `std::path` import
split); the exports are the same set. Linux builds none of these modules, as before.

`arkdeck-agentd` (Windows): `Host::planning` holds the root; `Host::planner` builds
`JobPlanner { imports: None, artifacts, analyzer: None, state_root, hdc: None, workspace: None }`
and `job_submit` `JobAdmitter { planner, jobs, now, authority: None }`, as macOS builds them;
`HostServices::job_plan`/`job_submit` map refusals as macOS does (a proven refusal carries
`{"phase": "preAdmission", "newDispatchCount": 0}`). The census reads
`arkdeck-agentd owners: targets, jobs, artifacts, workspaceProjects, planning`.

### Stacking merges

#2361 and #2356 each branched from `main` independently and conflict with each other:
`job_repository::database_identity` (H2's macOS arm now reads #2356's portable
`HostFileIdentity` from `document_metadata`), the Windows census, and the lifecycle composition
(Target store, Job store, Artifact owner, workspace projects, then planning). #2356's
`windows_artifact_owner_process.rs` still passes with the Job owner composed beside it. H3 will
meet the same conflicts.

## GJ-1 hops and tests

1. **Planner and admitter against the Swift oracle, on Windows**
   (`arkdeck-hoststore/tests/windows_observe_device_admission.rs`): the `observe.device@1`
   oracle's 11 `job.plan`/`job.submit` exchanges replayed in process with an `HdcComposition`
   over the recorded Target document and the recorded executable digest, and a dispatcher that
   fails the test if called. Every answer equals Swift's: the four plans (materialized plan
   digest `79fe36f6…`, request fingerprints, stable identity, steps; the Rust-only
   `stepSetDigestSHA256` is schema-checked and removed as `support::legacy_plan_answer` does on
   macOS), the four admissions (`job-0f77f8c5…`, `job-efd52ab9…`, `job-1721f8df…`,
   `job-8adf7b22…`, `deduplicated: false`, 0 dispatch) and the three refusals (stale binding,
   unbound request, unadopted target; codes and details, the message being Swift's wording, T2).
   A retry answers with the recorded Job. Without an HDC composition every one is refused
   `provider hdc is not registered` before admission and no Job directory is created. This is a
   host test of the planner and admitter; the daemon composes no HDC provider.
2. **Capability store on Windows**: `tests/capability_read.rs` (93 reads of the Swift oracle,
   paths labelled; symbolic links created under Developer Mode) and `tests/capability_write.rs`
   (5 tests; the M2 oracle stores rewritten byte for byte) run on Windows over owner-only
   directories, without comparing POSIX permission bits.
3. **The daemon** (`arkdeck-agentd/tests/windows_job_admission_process.rs`, the four recorded
   Swift Jobs recorded into `jobs-state` by the owner): over the pipe `job.plan` and
   `job.submit` of a fresh `observe.device@1` request are refused `invalidInput`, `provider hdc
   is not registered`, `preAdmission`, 0 dispatch; the recorded submission retried answers with
   the recorded Job (`deduplicated: true`, 0 dispatch; the Rust fingerprint finds the
   Swift-recorded `requestHash`); a changed request under that key is `idempotencyConflict`; an
   unknown operation, a capability in a plan and an empty `requestJson` are refused. The same
   after a restart; every file under `jobs-state` but the SQLite index is byte-identical;
   `job.list` unchanged. A fresh root lists nothing. With `ARKDECK_DEV_SIGNER_THUMBPRINT`,
   `arkdeck job plan|submit --request-file` against a dev-signed daemon reports the same.
   **Ran** on this host.

## Follow-ups (not in this slice)

- **HDC tuple gate**: a Job admitted and run on the Windows daemon needs the Windows HDC tuple
  registered (maintainer samples → integration change), then an HDC composition on Windows.
- **A2, the runner**: `job_run`, `device_run`, Artifact publication, `job_result`, `job_cancel`,
  `operation_availability` (it reads the runner's executes list and the analyzer and workspace
  compositions) and the Import owner's publication; Session publication stays with H3.
- The mutation authority on Windows (after H3's Session owner and the continuity census).
- The Flash lane (AF-W1) and a Windows analyzer (trace_streamer) stay carved.
- CLI coverage for `job.plan`/`job.submit` is not raised: nothing can be admitted by the daemon.

## Local checks (Windows 11 x64, `CARGO_TARGET_DIR=D:\cargo-target\s1-observe`)

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | clean |
| `cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-platform` (with `ARKDECK_DEV_SIGNER_THUMBPRINT`) | 0 | all pass, including `windows_observe_device_admission` 2/2, `capability_read` 1/1, `capability_write` 5/5, `windows_job_admission_process` 3/3, `windows_job_store_process` 3/3, `windows_artifact_owner_process` 3/3, `windows_target_owners_process` 3/3 |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |
| `git diff --check` | 0 | clean |

macOS and ubuntu cannot be built here. Every widened gate is `any(target_os = "macos", windows)`
(Linux unchanged); every Windows stand-in is `cfg(windows)`; in the macOS-built files only
attributes, comments and the import split changed, and the test ports keep the macOS statements
under `cfg(target_os = "macos")` (the capability tests' per-platform helpers are separate
functions, so no `let_and_return`/`needless_return` on macOS). CI decides.
