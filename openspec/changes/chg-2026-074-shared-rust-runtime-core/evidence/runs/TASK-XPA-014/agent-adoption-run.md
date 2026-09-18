# Agent Target adoption prerequisite — 2026-09-19

Scope: TASK-XPA-014, M1. Rust `agent.run` without an explicit Target now adopts
a single connected candidate whose independent USB relation is proved, through
the existing Target observation/adoption owner. It then uses the resulting exact
Target and binding revision to create the typed Job. No new control method,
capability policy, resume branch, unknown-outcome recovery or installed activation
is introduced.

The internal guarded adoption path follows Swift
`Bootstrap/TargetObservationCoordinator.swift` `adopt(beforeCommit:)`: check the
agent's original budget before adoption reads, after tool-version readback and
before the synchronous Target-store commit. The execution owner checks again
after adoption, preserves its exact budget refusal and execution identity, and
refuses a Target different from an already resolved Target. Existing public
`target.adopt` uses the same implementation with a no-op guard; its recorded
Swift oracle remains unchanged. Physical actions for disconnected, unauthorized,
ambiguous and unproved candidates retain their existing behavior.

Validation:

- `cargo check --manifest-path rust/Cargo.toml -p arkdeck-hoststore` — PASS.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore --test agent_human_action_raise --test target_adoption --test agent_execution --test agent_lifecycle`
  — PASS (8 tests total): existing Swift adoption, agent execution/lifecycle and
  HAR-raise oracle regressions plus four new adoption cases.
- After extending the successful adoption case through the real Rust JobRunner
  and SessionPublisher, `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore --test agent_human_action_raise`
  — PASS (5 tests). The fixture-backed Observe Job reaches `succeeded` and the
  agent reaches `completed`.
- `cargo fmt --manifest-path rust/Cargo.toml -p arkdeck-hoststore` and
  `git diff --check` — PASS.

New failure assertions cover deadline expiry during final identity readback
(Target bytes unchanged and no Job), deadline expiry at Target commit (no Job),
and changed USB identity during adoption (no Target or Job committed). Successful
adoption creates one Job; repeat `agent.run` and reopening the execution owner
return that exact Job without redispatch or new HDC observation. This tests
ordinary receipt readback only; it does not implement restart recovery of active
or unknown Jobs.

The initial test drafts exposed two test setup mistakes (Target document key
`targetID` and missing private Session directories); these were corrected before
the passing runs. No production refusal was relaxed. Final unified verification
is performed by the integrating parent slice before PR creation.

Evidence classification: local macOS production-owner/runner tests using the
existing fake HDC and current Swift-recorded fixtures, not real-device evidence,
not a new Swift differential recording of the no-target run, and not GJ-1
acceptance. Ordinary physical-action resume and design §L.1 item 13 recovery
remain separate work.

Commit-gap restart verification (2026-09-19): a subprocess uses the existing
injected source/budget clocks to exit immediately after Target adoption returns
and before execution.target is persisted. No production hook or durable-record
editing is used. The parent confirms exactly one Target, an `orchestrating`
execution without target/Job, then opens new Target, Artifact, Job, execution and
observation owners. Within the original budget, retry preserves the exact Target
document and original createdAt/deadline, creates one Job, and later retry returns
that Job without another dispatch start or HDC observation. After the original
deadline, retry returns `orchestrationBudgetExpired`, with zero Job and zero HDC
calls. It does not reset the budget or replay an admitted Job.

`cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore --test
agent_human_action_raise`: PASS (6 tests; 1 ignored child helper explicitly
invoked twice by the parent test). The first draft addressed Job list's `jobs`
field instead of its existing `items` contract field; corrected before passing.
This is process-exit crash simulation over the fake HDC, not physical-device or
active-Job unknown-outcome recovery evidence.

Final repository unified local check passed on 2026-09-19 with CI-pinned
Python dependencies: common checks, Rust workspace and Clippy, published and
candidate contracts, cargo deny and cargo vet. The dashboard also records
maintainer-approved merge #1972 at protected main abcb9984; coverage counts
are unchanged by that launcher-only delivery.
