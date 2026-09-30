# TASK-XPA-005 — WM1: the Job reconciler and the Agent engine on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM1, GJ-1: the `job.reconcile`,
`agent.*` and `human-action.*` hops on Windows. Branch
`agent/xpa-005-windows-reconciler-agent-v2-20260930`. It is one commit on `origin/main`, made
after #2385 (the consolidated Job, Session and runner owners,
`windows-job-session-runtime-consolidated-run.md`) landed as a squash. It replaces #2388, whose
branch still carried #2385's original commits; the same slice diff is applied here.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device was contacted, no HDC or board was used, and no `hdc` was run.
- Nothing installed was read or written, and no system setting was changed.
- Host tests are not Windows acceptance.

## Scope (lead, 2026-09-30)

Port the reconciler and the non-HDC parts of the Agent engine to Windows. Prove them the same way
as the earlier slices: the recorded Swift corpora, a real daemon across a restart, and the
dev-signed CLI.

The HDC tuple stays gated until the maintainer's samples and the integration change arrive, so:

- no execution observes a Target;
- nothing is dispatched;
- no development bypass goes into the daemon.

## What

`arkdeck-hoststore`, now also built on Windows. Items are the macOS code unless the table says
otherwise:

| Item | Notes |
| --- | --- |
| `job_reconcile` (`JobReconciler`), `job_reconcile_device` | The analyzer and device-bound Jobs are reconciled. **Still macOS-only**, and refused on Windows as Jobs this Runtime does not reconcile: the workspace Jobs (signing, the workspace mutations and reads, symbolization, the sweep) and a delegated Flash's lane receipt (`flash_reconcile.rs`, `FlashReconciler`, AF-W1). The lane parameter is a per-platform alias (`Lane`), with no value on Windows. |
| `agent_execution` (`AgentExecutionStore`, `AgentEngine`) | `JobAdmitter::submit_for_agent` is now built on both hosts; without it, the `AgentAdmission` trait recursed into itself on Windows. `cutover_executions` (used only by the cutover preflight) stays macOS. |
| `human_action` (`HumanActionResources`) | Built over `absent_control_action.rs`, a `ControlActionResources` with no value on Windows. The union control-action owner (the HDC lifecycle's and the tool selection's) is not built there, so the human-action owner is the same code but pages only the executions' actions. |
| `format_time::precise_utc_millis`, `utc_precise_from_millis` | Built on Windows. |

`arkdeck-agentd` (Windows):

- `windows_lifecycle::Authority::compose` adds two owners on both the development root and the
  account root:
  - the agent execution owner in `agent-executions`;
  - the combined human-action owner in `human-action-snapshots`.
  These are the names both macOS compositions use. The development root's Session owner already
  reserves both names (#2385).
- `Host` on Windows answers the following hops:
  - **`job.reconcile`:** the reconciler with the Session publication writer and the runner its runs
    use, with no HDC composition and no Flash lane.
  - **`agent.*`:** the execution owner over the Target, Job and Artifact owners. An execution
    admits its Job as `job.submit` does here, with no observation. An owned Job runs in the
    background through the same runner.
  - **`human-action.list|show`:** the shared handler.
- `Host::reconcile_once` holds the reconcile slot logic, now shared by both hosts: a held run
  answers its status, and a concurrent reconcile joins the one under way. macOS behaviour is
  unchanged.
- `windows_runner` is the one Windows runner composition. `job.run`, `job.reconcile` and an
  execution's owned Job all use it.

`rust/scripts/check-readonly.py`: the full matrix's daemon composes no state root, so it has no
agent owners. Without them, the `agent.*` and `human-action.*` rows now expect
`operationUnavailable` (`{"phase": "preAdmission", "newDispatchCount": 0}`) on Windows as well as
on macOS. That is the answer of the shared handler, and of Swift's daemon, without an owner.
The rows previously expected the foundation's `rejected`. That expectation turned #2388's first
head (`7568a707`) red on `Rust contract parity (windows-latest)` in the signed matrix.

## Census

`jobs, capabilities, targets, artifacts, storage, workspaceProjects, planning, agentExecutions,
humanActions, traceCache`

This is the macOS order: `agentExecutions` and `humanActions` follow `planning`. The Windows
daemon tests that assert the census are updated.

## Swift oracle comparisons

1. **`job-reconcile-analyzer`** (`arkdeck-hoststore/tests/windows_job_reconcile.rs`).
   - Swift's `secondRestart` store is laid down on NTFS: two analyzer Jobs that a signal death
     parked, the second one's source payload since removed, one Job run to success and one only
     admitted.
   - Also laid down: the Artifacts (indexes owner-only, payloads sealed) and the succeeded Job's
     Session, with the catalog at generation 1.
   - The replay runs through the Rust reconciler, composed with the Session publication writer.
   - Result: all 8 recorded `job.reconcile` cases and every recorded read
     (`job.result|evidence|show|status` of the 4 Jobs) are Swift's answers. That includes the
     parked Job published at catalog generation 2 and the removed source refused `internalError`.
   - **Allowed differences:**
     - A refusal's wording (T2).
     - The published Manifest's digest. It names `PLATFORM-WINDOWS@0.2.0`, where Swift's names
       `PLATFORM-MACOS@0.2.0`, so the test compares it against Swift's Manifest with that one
       substitution.
2. **`agent-human-action`** (`tests/windows_agent_human_action_records.rs`, a port of the macOS
   `agent_human_action_records.rs`). Swift's execution records are laid down owner-only, and each
   step answers as Swift's owner does:
   - the waiting pick-a-device execution: status, list, a re-run as a budget read, and an
     abandon that expires its action;
   - the abandoned execution re-run without a write;
   - out of time (the deadline passed, or the clock behind the record): each ends with its action
     expired, as Swift's `observeBudget` ends it.
   - The oracle's labelled identities read as valid identities of their kind.

## Process and CLI evidence

`arkdeck-agentd/tests/windows_reconcile_agent_process.rs` runs the real daemon over a development
root holding both corpora:

- **The start:** the census as above. The start recovers the store's active Jobs (`recovered 3
  active job(s); unknown outcomes parked`).
- **Agent executions:**
  - The waiting execution is re-run long after its deadline (the daemon runs on its own clock).
    It ends `budgetExpired` with its action expired and `failureCode`
    `orchestrationBudgetExpired`, at generation 4, all in its record.
  - Read as Swift answered them, compared semantically: the abandoned execution's `agent.status`,
    the `agent.list` page of abandoned executions, and the expired action's `human-action.show`.
  - 11 recorded refusals are also answered as Swift answered them: `human-action.list|show|resume`
    and `agent.resume`.
- **Reconcile:** every recorded `job.reconcile` answers as Swift's, compared without two things
  set by the daemon's own clock: the times the reconcile writes, and the digest of the Manifest
  that names them. The parked Job is closed (`executionConfirmedNotPerformed`), and its Session is
  published at catalog generation 2.
- **Restart:** a second daemon answers the same, and neither the parked Job's record nor the
  expired execution's record changes.
- **Dev-signed CLI** (`ARKDECK_DEV_SIGNER_THUMBPRINT`) — **ran** on this host:
  - `arkdeck job reconcile` closes the parked Job, with its Session at generation 2;
  - `arkdeck agent status --execution-id har-trust` equals Swift's answer;
  - `arkdeck human-action show` of the expired action equals Swift's answer.

**Contract gaps found on the way, on every host:** the current contract types an execution's
`failureCode` and a human action's `selectionSchema` as null. It also lists no
`orchestrationBudgetExpired` among `agent.run`'s error codes. As a result, the daemon answers a
conformance failure (`internalError`) for three reads:

- a pick-a-device action;
- an expired execution;
- that execution's run refusal.

The process test reads those three from the records instead. W1 widens the schemas through the
generator in #2386, using the owner's exact answers from this slice.

## Follow-ups (not in this slice)

- **Wire reads once #2386 lands:** read the expired and pick-a-device executions, their actions
  and the `orchestrationBudgetExpired` refusal over the pipe and the CLI, instead of from the
  records.
- **The retention sweep:** the start's Artifact retention sweep is still macOS-only (accepted for
  now).
- **The HDC tuple gate:**
  - An execution's Target observation, the control actions (the HDC lifecycle's impact approvals)
    and a device Job's run all need the registered Windows HDC tuple.
  - Until then, the human-action owner pages only the executions' actions.
- The workspace Jobs' reconcile (XPA-011) and a delegated Flash's reconcile (AF-W1).

## Local checks

Run on Windows 11 x64 after merging `origin/main`, with `CARGO_TARGET_DIR=D:\cargo-target\s1-reconciler`
and `ARKDECK_DEV_SIGNER_THUMBPRINT` exported:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | clean |
| `cargo test -p arkdeck-hoststore` | 0 | lib 161 passed (2 ignored); `windows_job_reconcile` 1/1; `windows_agent_human_action_records` 2/2; `job_recovery` 5/5 |
| `cargo test -p arkdeck-agentd` | 0 | `windows_reconcile_agent_process` 2/2 and every other Windows daemon test; no `SKIPPED` line |
| `cargo test -p arkdeck-control -p arkdeck-contract -p arkdeck-cli` | 0 | all pass |
| `cargo test --workspace` | 0 | all pass |
| `python rust/scripts/check-readonly.py --bin-dir <target>/debug` (with `ARKDECK_DEV_SIGNER_THUMBPRINT`) | 0 | PASS, including `windowsDevelopmentSignerMatrix` (136 control responses, 16 CLI envelopes) |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |
| `git diff --check` | 0 | clean |

macOS and Ubuntu cannot be built here, so I reread the cfg pairings by hand. CI decides.
