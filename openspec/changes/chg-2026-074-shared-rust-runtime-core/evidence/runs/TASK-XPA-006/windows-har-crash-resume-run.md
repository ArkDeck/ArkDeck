# TASK-XPA-006 — HAR crash-resume on Windows, as far as it goes without the HDC tuple

Change: CHG-2026-074-shared-rust-runtime-core. TASK-XPA-006's GJ-1 closed loop includes the headless
runbook's §2.1 "HAR crash-resume": the client process crashes before or after a human action, and
the execution is fetched again and continued by its execution ID alone. TASK-XPA-006 stays blocked
on the device and the Windows HDC tuple. This record covers what the owners prove without them.

Branch `agent/xpa-006-windows-har-crash-resume-20260930`, one commit on `origin/main`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device was contacted, no HDC or board was used, and no `hdc` was run.
- Nothing installed was read or written.
- No system setting was changed.
- Host tests are not Windows acceptance.

## What

New test `arkdeck-hoststore/tests/windows_agent_human_action_resume.rs`. It runs the adoption and
resume cases of the macOS `agent_human_action_raise.rs`, which follow Swift's physical-assistance
oracle (`rust/tests/fixtures/agent-human-action`), over the same owners laid down owner-only on
NTFS. The test bodies and their clock hooks are the macOS ones. Only the fake HDC, the roots and
the test helpers differ:

- **`connected_proved_candidate_is_adopted_once_and_owns_one_job`:**
  - A run that names no Target adopts the one connected, proved device.
  - It owns one Job. Running again, or with the owner reopened, owns the same Job without
    dispatching again.
  - The Rust runner completes the Job, and the execution reads `completed` / `succeeded`.
- **The three refused adoptions:**
  - `budget_expiring_during_identity_readback_prevents_target_commit_and_job`,
    `budget_expiring_at_target_commit_prevents_job_creation`: `orchestrationBudgetExpired`, and the
    execution is `budgetExpired` with no Target and no Job.
  - `changed_usb_identity_during_adoption_never_commits_target_or_job`: `internalError`, and the
    Target document is unchanged.
- **`crash_between_target_and_execution_commit_reopens_all_owners_and_keeps_original_budget`:**
  - A child process exits (`std::process::exit(79)`) after the Target commit and before the
    execution's own commit.
  - A new owner set, with no in-memory receipt, keeps the original `createdAt` and `deadline`.
  - It adopts nothing twice: one Job, the same Target document, no HDC call on the retry. Past the
    original deadline the retry is refused.
- **`physical_resume_keeps_original_intent_and_unique_job`:** eight scenarios (connect, trust
  and select across a daemon-restart owner, a drifted selection, expiry, clock rollback, and
  adoption expiry). In each, the action is resumed only by its durable `resumeReference` and
  `humanAction`:
  - Forged selections, Targets and action identities are refused.
  - Four concurrent resumes own exactly one Job.
  - A changed selection is `idempotencyConflict`.
  - An expired action is `humanActionExpired`, and a rolled-back clock is
    `orchestrationClockUntrusted`, both with no HDC call.
  - The action ends `resolvedByFreshProbe`, with the execution's original `createdAt`.
- **`resolved_resume_commit_gap_preserves_status_then_run_continuation`:**
  - A child exits after the resume resolved the action and before the Job was admitted.
  - A new process answers `agent.resume` as it stands (`orchestrating`, no HDC call).
  - The next run continues to one Job, or is refused past the original budget.

That is the runbook's criterion as the owners can meet it: the execution is continued from its
durable record alone. No client-side state is needed; the resume reference is re-read from the
store.

### Delegated minor decision, pending the next rulings batch

The fake HDC is the oracle's table (`hdc-answers.sh`) answered in process by mode, as #2400's
Windows raise test answers it. The owners are fed a dispatch directly, so no Windows HDC tuple is
registered or needed. The crash children get their state root from the parent (`ARKDECK_HAR_ROOT`)
instead of a pid-named path.

## Not reached, and why

- **The daemon and CLI legs of §2.1.** The Windows daemon composes no HDC before the tuple, so an
  execution that must observe a device is refused before admission over the wire. The recorded
  executions' wire reads are `windows_reconcile_agent_process.rs` (#2391, #2395).
- **The real device.** Unplugging and replugging the DAYU200 is TASK-XPA-006's `REAL_DEVICE_PASS`.

## Local checks

Run on Windows 11 x64 with `ARKDECK_DEV_SIGNER_THUMBPRINT` exported:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | clean |
| `cargo test -p arkdeck-hoststore` | 0 | all pass, `windows_agent_human_action_resume` 7 passed / 1 ignored (the crash child); no `SKIPPED` line |
| the same with `TEMP`/`TMP` set to an 8.3 short path on C: | 0 | all pass |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |
| `git diff --check` | 0 | clean |
