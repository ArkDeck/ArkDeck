# TASK-XPA-005 — WM1: the Windows agent executions read over the wire

Change: CHG-2026-074-shared-rust-runtime-core. This is a follow-up to #2391
(`windows-reconciler-agent-run.md`), now that #2389 publishes three things as Swift answers them:

- an agent execution's `failureCode`;
- an agent human action's `selectionSchema`;
- `agent.run`'s orchestration refusals.

Branch `agent/xpa-005-windows-agent-wire-reads-20260930`, one commit on `origin/main`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device was contacted, no HDC or board was used, and no `hdc` was run.
- Nothing installed was read or written.
- No system setting was changed.
- Host tests are not Windows acceptance.

## What changed

Only `arkdeck-agentd/tests/windows_reconcile_agent_process.rs` (and the README paragraph) changed.
Before, the test read three things from the execution record, because the daemon answered them as
a conformance failure. It now reads them over the pipe and compares them with the recorded Swift
answers (`rust/tests/fixtures/agent-human-action`):

- **Before any run, the pick-a-device execution:**
  - `agent.status` equals Swift's `ambiguous.run` answer;
  - its action, with `selectionSchema` `{"type": "string", "enum": [<two candidates>]}`, is the one
    item `human-action.list` answers for it;
  - `human-action.show` of that action answers the same.
- **Run again on the daemon's own clock, after its orchestration deadline:**
  - `agent.run` is refused with `orchestrationBudgetExpired` and
    `{"executionId": "har-ambiguous", "phase": "preAdmission", "newDispatchCount": 0}`;
  - `agent.status` answers Swift's execution with `state` `budgetExpired`, `failureCode`
    `orchestrationBudgetExpired`, `generation` `"4"`, and no action or next action;
  - `human-action.show` answers its action `expired`;
  - the whole `agent.list` names the four executions, the expired one with its `failureCode`.
- **After a restart:** the same reads, and a second run gets the same refusal with nothing written.
- **Dev-signed CLI** (`ARKDECK_DEV_SIGNER_THUMBPRINT`) — **ran**:
  - `arkdeck agent status --execution-id har-ambiguous` equals Swift's answer;
  - `arkdeck human-action show` of its pick-a-device action equals Swift's answer.

## Local checks

Run on Windows 11 x64 with `ARKDECK_DEV_SIGNER_THUMBPRINT` exported:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | clean |
| `cargo test -p arkdeck-agentd` | 0 | all pass, `windows_reconcile_agent_process` 2/2; no `SKIPPED` line |
| `cargo test -p arkdeck-agentd` with `TEMP`/`TMP` set to an 8.3 short path | 0 | all pass |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |
| `git diff --check` | 0 | clean |
