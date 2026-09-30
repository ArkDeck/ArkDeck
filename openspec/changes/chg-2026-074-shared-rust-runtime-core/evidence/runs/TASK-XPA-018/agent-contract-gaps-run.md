# TASK-XPA-018: three agent-execution contract gaps. Local run, 2026-09-30

S1 found three places where the daemon's correct answer was replaced with `internalError` ("the
result does not conform to the current contract") because the published schema was narrower than
what Swift answered. It happens on macOS as on Windows. Like #2382, all three are schema gaps: the
schemas were derived from recorded frames, and each member had only been recorded in `agent.run`.

Checkout: branch `agent/xpa-018-agent-contract-gaps-20260930`, **stacked on #2382**
(`agent/xpa-018-nonconforming-replies-20260930` at `6fda8d79`), because both change the same
generator code. Host: Windows 11 Pro 10.0.26200 x64. This is a host-only software change.

## What Swift answered (source before removal, `32db20b1~1`)

1. **`failureCode`.** `RuntimeAgentExecutionRecord.projection` (`AgentExecutionStore.swift:136`)
   writes `failureCode` as the execution's failure code or null. The same projection is every
   agent execution answer: the daemon's `executionResultProjection` for `agent.run`,
   `agent.status`, `agent.resume` and `human-action.resume`, plus `agent.abandon` and the
   `agent.list` items.
   - `observeBudget` sets it to `orchestrationBudgetExpired` or `orchestrationClockUntrusted` when
     the execution stops at its budget.
   - Admission sets it to `admissionDenied` or `idempotencyConflict`.
   - Only `agent.run` ever recorded a string (`admissionDenied`), so the other methods published
     `null` only.
2. **`selectionSchema`.** `RuntimeAgentHumanAction.projection` (`AgentExecutionStore.swift:81`)
   writes null, or `{"type": "string", "enum": [<selection refs>]}` when the action chooses among
   candidates. Only `agent.run` recorded the object (a two-candidate enum).
   - Control-action human actions (`HDCControlActionRecord.swift:82`) always write null. So
     `control-action.*`, `runtime.hdc.*` and `runtime.tool.select` stay null-only, and a new test
     holds them to it.
3. **`agent.run` refusals.** The coordinator's `run` refuses with `orchestrationBudgetExpired` or
   `orchestrationClockUntrusted`:
   - from `AgentExecutionBudgetGuard.check` and `observeBudget`;
   - when there is no trusted time to create an execution;
   - on re-entry of an execution that stopped at its budget.

   The daemon adds `{phase: preAdmission, newDispatchCount: 0}`, and `executionId` where the
   coordinator gives it (`AgentDaemon.swift:3264-3275`). Swift's CLI mapper lists both codes among
   the agent owner's refusals (`CLIControlMethodRegistry.swift:335`). `agent.run`'s published enum
   lacked both, while `agent.resume` has them. Its published error details already allow
   `executionId`, `phase` and `newDispatchCount`.

## Generated, not hand-edited

`Packages/ArkDeckKit/Scripts/generate-control-contract.py` gains two things:

- **`AGENT_RUN_OWNER_ERROR_CODES`** = `orchestrationBudgetExpired`, `orchestrationClockUntrusted`,
  joined to `agent.run`'s codes like the other owner vocabularies.
- **`SHARED_MEMBERS`.** A member that carries one Swift type wherever a method answers it takes
  the values recorded for it in the source method as samples of it in every target method. The
  mechanism is `values_at` and `SHARED_SAMPLES`, used by `infer`. The entries:
  - `agent.run` `result.failureCode` → `failureCode` in `agent.status`, `agent.resume`,
    `agent.abandon`, `agent.list` (`items[]`) and `human-action.resume`;
  - `agent.run` `result.humanAction.selectionSchema` → the agent-owned human-action
    `selectionSchema` in `agent.status`, `agent.resume` (result and error details),
    `human-action.list` (`items[]`), `human-action.show` and `human-action.resume` (result and
    its `humanAction`).
  - The generator refuses to derive a target without its source method's recorded frames.

Steps:

1. `--derive-method-schemas` was run over the committed corpora of those eight methods only (30
   frames).
2. The resulting diff was checked. Every removed line is either one of the twelve `"type": "null"`
   lines replaced by the widened member (5 `failureCode`, 7 `selectionSchema`) or an
   `x-arkdeck-sampleCounts` value. `agent.run` gains the two codes, and nothing else changes.
   - The counts move to the committed corpus's counts for five schemas. That is the same drift
     as #2370/#2382, because the Swift recorder is gone.
   - `agent.run`'s counts are unchanged.
3. `generate-contract.py --write` refreshed the baseline.
4. `generate-clientkit.py --write` refreshed the eight digests in `ControlContract.g.cs`.
5. The output was normalised to LF, and the line-ending-only rewrites (the Swift protocol file,
   the eight corpus files) were restored.
6. Both `--check`s pass.

## Tests

`rust/crates/arkdeck-contract/tests/agent_shared_members.rs` (new, portable, runs on Windows):

- `the_agent_members_admit_what_swift_answered_in_every_method`. It takes the failure code and
  the selection schema Swift recorded for `agent.run`, grafts each into every recorded answer of
  every target method at that member, and validates it against the method's published schema.
  There are ten method/member cases.
- `agent_run_publishes_its_orchestration_refusals`: both codes, with
  `{executionId, phase: preAdmission, newDispatchCount: 0}`.
- `control_action_human_actions_keep_a_null_selection_schema`: `control-action.show` and
  `runtime.tool.select` still refuse a selection schema.

- `the_rust_owner_s_captured_answers_conform` (added after S1's confirmation). It validates the
  Rust owner's exact answers S1 captured from `AgentExecutionStore` at a fixed clock, with labels
  redacted:
  - `agent.status` of an execution stopped at its deadline (`orchestrationBudgetExpired`,
    `budgetExpired`) and by an untrusted clock (`orchestrationClockUntrusted`, `clockUntrusted`);
  - the `agent.list` page listing it;
  - the waiting pick-a-device `agent.status`, whose `humanAction.selectionSchema` is
    `{"enum": [...], "type": "string"}`, and that human action as `human-action.show` answers it;
  - `agent.run`'s refusal details, with `executionId` for a stopped execution and without it for a
    new execution that has no trusted time.

  The resume owners already publish `orchestrationClockUntrusted`, which they pass through. S1
  confirmed the daemon replaced the waiting status and `human-action.show` with `internalError`
  before this change, which S1 checked through the Windows daemon.

In check-contracts' published view (merge-base schemas) the widened answers are refused, and the
tests assert only that this is the published view, as in #2370.

Negative control: with main's schemas the first two tests fail. The conformance test of #2382 does
not reach these members on Windows, because the Windows daemon composes no agent-execution owner
yet. The in-process contract test holds them instead. The Rust owner's answers are the ones S1's
reconciler/Agent-engine branch exercises.

## Local targeted checks (Windows 11 x64)

| Command | Result |
| --- | --- |
| `cargo fmt --all --check` | pass |
| `cargo clippy --workspace --all-targets -- -D warnings` | exit 0 |
| `ARKDECK_DEV_SIGNER_THUMBPRINT=<host signer> cargo test -p arkdeck-contract -p arkdeck-control -p arkdeck-cli -p arkdeck-hoststore -p arkdeck-agentd` | exit 0 |
| `generate-contract.py --check`, `generate-clientkit.py --check` | pass |
| `dotnet build windows/ArkDeck.Windows.slnx -c Release` | 0 warnings, 0 errors |
| `dotnet test` | App.Tests 37 passed; ClientKit.Tests 31 passed, 1 skipped; App.UITests 19 skipped (their own skip) |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

**macOS effect:** these answers now reach macOS clients as Swift's did, instead of `internalError`.
macOS and Linux were not built here.

## CI

To be recorded, not verified.
