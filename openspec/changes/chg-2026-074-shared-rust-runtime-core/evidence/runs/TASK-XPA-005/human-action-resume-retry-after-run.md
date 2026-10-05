# TASK-XPA-005 — `human-action.resume` admits `agent.resume`'s `nextAction`

Change: CHG-2026-074-shared-rust-runtime-core. A contract-only slice found while measuring GJ-1's
human-action loop on Windows (`windows-human-action-loop-run.md`). It is one commit on `main`,
through the generators only, as the lead asked (2026-10-05).

Host: the Windows 11 x64 reference host. No device, HDC or installed state was touched.

## Why

`agent.resume` and `human-action.resume` answer the same agent-execution projection. While the
execution's Job still runs, its `nextAction` is
`{kind: wait, owner, reasonCode: job.running, resource, retryAfter: "250ms"}`.

- `agent.resume`'s published schema admits `retryAfter`, because Swift's oracle recorded such an
  answer (`connect.resume`).
- `human-action.resume`'s did not. Swift recorded it only after the Job completed
  (`connect.againByAction`).

So resuming a still-waiting action through `human-action resume` was answered with `internalError`
("the result does not conform to the current contract") on every host. The CLI reported it as
`outcomeUnknown`. Measured through the real CLI against the signed test daemon on 2026-10-05.

## What

- **`generate-control-contract.py` `SHARED_MEMBERS`:** `agent.resume`'s recorded
  `result.nextAction` values are samples of `human-action.resume`'s `result.nextAction`. A member
  is shared whole, since the generator takes an object's keys from its samples.
- **Derived** with `--derive-method-schemas` over the committed corpora of `human-action.resume`,
  `agent.resume`, `agent.run` and `runtime.hdc.impact-preview` (the existing shared members need
  the last two). The only schema change is three lines in
  `spec/control/methods/human-action.resume.json`: `nextAction.retryAfter: {type: string}`. That
  makes it exactly `agent.resume`'s `nextAction`.
- **Restored:** the corpus files the run rewrote and the line-ending-only rewrites (the other
  method schemas, the Swift protocol file). No corpus line changes.
- **Digests:** `generate-contract.py --write` (the baseline's method-schema digests and input
  digest) and `generate-clientkit.py --write` (the schema digest in `ControlContract.g.cs`), LF.

## Proof

- `rust/crates/arkdeck-contract/tests/agent_execution_next_action.rs`:
  - `human_action_resume_publishes_agent_resume_s_next_action`: the two `nextAction` schemas are
    equal, so they cannot drift apart again;
  - `a_running_resume_conforms_as_a_human_action_resume_answer`: each recorded `agent.resume`
    answer of a running Job validates as a `human-action.resume` result;
  - negative control: with main's `human-action.resume.json` and baseline, both fail.
- `windows/ClientKit.Tests` `AgentExecutionNextActionTests.ARunningResumeDecodesAsAHumanActionResumeAnswer`:
  the C# client decodes those answers as `human-action.resume` responses.
- Swift: not run (no macOS host here). The corpus is unchanged and the schema only widens, so
  `ControlMethodSchemaContractTests` sees the same frames against a wider schema.

## Delegated minor decision, pending the next rulings batch

1. **Sibling consistency.** `human-action.resume`'s `nextAction` admits exactly `agent.resume`'s,
   since the two answer one projection. The lead decided this on 2026-10-05; no Swift oracle
   records a `human-action.resume` of a running Job.

## Gates

The commit message gives this commit's gate output.
