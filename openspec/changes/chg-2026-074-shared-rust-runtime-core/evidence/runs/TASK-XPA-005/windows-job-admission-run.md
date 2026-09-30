# TASK-XPA-005 — WM1 slice: the Job planner and admitter on the Windows daemon (GJ-1 `job.plan` / `job.submit`)

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM1, GJ-1 hops `job.plan` and
`job.submit` of `observe.device@1` on the Windows daemon. Branch
`agent/xpa-005-windows-observe-device-20260930`, **stacked on #2361** (H2, the Job store owner,
`agent/xpa-005-windows-job-store-20260930` at `50ff5707`, still open), which is on protected
`main` `ca880968`. Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device was
contacted, no HDC or board was used, no `hdc` was run, nothing installed was read or written, and
no system setting was changed. Host tests are not Windows acceptance.

## Scope decision (lead, 2026-09-30)

The slice was asked to run `observe.device@1` end to end on the Windows daemon against the fake
HDC. That needs an HDC dispatch composed on Windows, and no Windows HDC tuple is registered:
`evidence/xpa-002-readonly-foundation.md` ("Windows HDC registration scope") says a fixture
executable, an unreviewed hash or a caller-supplied version cannot stand in for the missing
registration, and the earlier Windows slices (#2341, #2350) keep the Windows daemon's HDC
dispatch at none. Composing the macOS development HDC on Windows would borrow the macOS
`3.2.0d` authority or add a development bypass. The lead chose option A: compose the Job planner
and admitter on Windows over #2361's store, with Session publication left to H3 and the HDC tuple
gated until the maintainer's samples and the integration change arrive. No development bypass
was added. Nothing in `openspec/integrations/**` changed.

## What

`arkdeck-hoststore`:

| Item | Before | Now |
| --- | --- | --- |
| `job_plan` (`JobPlanner`, `PlanRefusal`) | macOS | macOS + Windows. On Windows the struct has only `state_root`; `artifacts`, `imports`, `analyzer`, `hdc`, `workspace`, the per-operation plan submodules (Flash, debug HAP, native library, screen sequence, workspace), `AnalyzerProfile`, `materialize_device`, `materialize`, `resolve_lease` and `refuse_debug_permit` stay `cfg(target_os = "macos")` |
| `job_admission` (`JobAdmitter`, `AdmissionRefusal`, `runtime_now`) | macOS | macOS + Windows. `MutationAuthority`, the `authority` field, `FlashAdmitter`, `submit_for_agent`, the capability-gap repair, `preauthorize` and `preauthorize_workspace` stay macOS |
| `catalog_review` (`selected_steps`), `job_owner::import_references`, `format_time::utc_now`/`utc_timestamp` | macOS | macOS + Windows (portable code; `flash_catalog_review` stays exported on macOS only) |

Windows arms (everything else is the macOS code):

1. `JobPlanner::materialized`: the Import holds (`import_hold`: references parsed as on macOS;
   any Import input is refused `Import input owner is unavailable`, macOS's answer without an
   Import owner), then the refusal macOS answers without the operation's provider:
   `provider hdc is not registered` / `provider workspace is not registered`
   (`materialize_device` / `materialize_workspace` with no composition) and, for an analyzer,
   `<ref> is runtime unavailable: analyzer.profileUnavailable`
   (`analyzer_composition::runtime_availability` with none). All `invalidInput`, before
   admission.
2. `JobPlanner::unmaterialized_analyzer`: `None`, as macOS with no analyzer composition.
3. `JobAdmitter::preauthorize`: the macOS answer without a capability authority
   (`<ref> needs a Runtime capability, which the Rust Runtime does not issue yet`); unreachable
   today because materialization refuses first.

On macOS the only non-attribute change is `MATERIALIZED` naming the native deployment's
reference through a local `NATIVE` constant (`"deploy.native-library.app-owned@1"`, the value of
`device_steps::NATIVE`, which is macOS-only). The public exports on macOS are the same set.
Linux compiles none of these modules, as before.

`arkdeck-agentd`:

- `Host::planning` on Windows is the state root the planner plans against
  (`Host::with_planning(state_root)`); `windows_lifecycle::Authority::compose` sets it to the
  daemon's root. The census line reads `arkdeck-agentd owners: targets, jobs, planning` (the two
  tests that assert it were updated).
- `HostServices::job_plan` / `job_submit` on Windows: `JobPlanner { state_root }` and
  `JobAdmitter { planner, jobs, now: runtime_now }` over the Job store, answering refusals with
  the macOS mapping (a proven refusal carries `{"phase": "preAdmission", "newDispatchCount": 0}`).
  Flash: no `FlashPlanner`/`FlashAdmitter` (no Flash lane on Windows), so a Flash operation is
  `rejected` (`… is not materialized by the Rust Runtime yet`).

Not on Windows (T1/T2 divergences, recorded): the Flash operations (above); the ArkTrace analysis
request's closed cross-field check (`arktrace_analysis::AnalysisRequest::parse`, the analyzer's
parser, G20), so an ill-formed `analyzer.analyze-trace@1` request is refused with the analyzer's
unavailability instead of the cross-field message (same code, `invalidInput`).

## GJ-1 hops

`arkdeck-agentd/tests/windows_job_admission_process.rs`, real daemon over a fresh development
root with every `ARKDECK_`/`OHOS_HDC_` input removed, the four recorded Swift
`observe.device@1` Jobs (`rust/tests/fixtures/observe-device/store`, Catalog digest
`508783ac…`, the current one) recorded into `jobs-state` by the owner as #2361's test does:

1. Over the pipe: `job.plan` and `job.submit` of a fresh `observe.device@1` request (the
   recorded submission under a new key) are refused `invalidInput`, `provider hdc is not
   registered`, `preAdmission`, 0 dispatch. The recorded submission retried is answered
   `{"schemaVersion": "arkdeck.job-acceptance/1", "jobId": "job-0f77f8c52864d676372962eccb17389c",
   "deduplicated": true, "newDispatchCount": 0}`: the idempotency lookup with the Rust-computed
   request fingerprint finds the Swift-recorded `requestHash` and answers before anything is
   materialized. The same key with a changed request is `idempotencyConflict`. An unknown
   operation is `operationUnavailable`; a plan naming a capability is refused; an empty
   `requestJson` is refused. `job.list` lists the same four Jobs before and after.
2. Stopped by its stop request and restarted: the same answers. Every file under `jobs-state`
   but the SQLite index and its companions is byte-identical to before the first start.
3. A fresh root: plan and submit refused alike, a workspace operation refused before admission,
   `job.list` empty.
4. Real CLI against a copy of the daemon signed with the host-trusted development signer
   (`ARKDECK_DEV_SIGNER_THUMBPRINT` from `HKCU\Environment`): after a restart,
   `arkdeck job plan --request-file` and `arkdeck job submit --request-file` of the fresh request
   exit non-zero with wire code `invalidInput` and the refusal message; `arkdeck job submit` of
   the recorded request exits 0 with the recorded Job, `deduplicated: true`, 0 dispatch; the
   store's files are unchanged. **Ran** on this host.

Not in this hop: a Job admitted, run, or read back as `succeeded` on Windows. That needs the
registered Windows HDC tuple (maintainer samples → integration change), then the device facts,
device steps, runner and Artifact owners on Windows; Session publication is H3's
(stacked on #2361 + #2356), and stays out of these files.

## Windows CLI coverage

Unchanged: `job.plan` and `job.submit` are a real surface on Windows now but no operation can be
admitted, so their coverage is not raised; `cli-feature-coverage.json` is not regenerated.

## Local checks (Windows 11 x64, `CARGO_TARGET_DIR=D:\cargo-target\s1-observe`)

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | clean |
| `cargo test -p arkdeck-hoststore -p arkdeck-agentd` (with `ARKDECK_DEV_SIGNER_THUMBPRINT`) | 0 | all pass, `windows_job_admission_process` 3/3, `windows_job_store_process` 3/3, `windows_target_owners_process` 3/3 |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |
| `git diff --check` | 0 | clean |

macOS and ubuntu cannot be built here. Every widened gate is `any(target_os = "macos", windows)`
(Linux unchanged); on macOS the changed files add only `cfg` attributes, the split re-exports
name the same items, and `MATERIALIZED` spells the native reference itself. CI decides.
