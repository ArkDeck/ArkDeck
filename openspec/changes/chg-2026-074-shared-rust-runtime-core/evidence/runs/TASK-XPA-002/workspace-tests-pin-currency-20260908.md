# The pin check that failed every Swift branch — 2026-09-08

- Task: TASK-XPA-002
- Base: protected `main` `abc24e1d` (#1786).

## What broke

#1778 added `cargo test --workspace` to the rust lane, because nothing else in
it compiled the checkout and a red workspace had reached `main` behind a green
lane. That was right, and it had a side effect nobody could see until a Swift
branch changed a recorded frame.

`cargo test --workspace` includes `corpus_parity`, and two of its cases assert
that every Swift contract input in the checkout is byte-identical to
`spec/baselines/swift-single-v1.json`. `generate-contract.py --write` accepts
only a commit that is already in `origin/main`, so a branch cannot move the pin
onto itself. On any branch that legitimately adds a recorded frame, those two
cases are false by construction and stay false until after the branch merges.

Measured on PR #1787 (the Session publication producer), all three rust hosts:

```text
assertion `left == right` failed: recorded shape counts: agent.resume
  left: {"errors": 4, "requests": 8, "successes": 4}
 right: {"errors": 3, "requests": 7, "successes": 4}

assertion `left == right` failed: contract input file drift:
  …/Fixtures/ControlFrames/agent.resume.jsonl
```

The `swift` aggregate then failed too, purely because `rust-checks` is one of
its `needs`: that run reported `SWIFT_RESULT: success`, `APP_RESULT: success`,
`DS_RESULT: success`, `RUST_RESULT: failure`.

## The two questions this was conflating

The lane was asking one assertion to answer two things:

1. **Does the Rust code still replay the contract?** When the checkout matches
   the pin, `cargo test --workspace` answers it. When the checkout is ahead,
   `check-contracts.py` already answers it in the isolated candidate view — it
   regenerates `control_generated.rs` against a candidate manifest and runs the
   same workspace tests there. The `candidate` input kind
   (`arkdeck.swift-candidate-inputs/1`) exists in `corpus_parity` for exactly
   this.
2. **Is the committed pin current?** That is a property of `main`, not of a
   branch, and it is what actually went wrong when #1773 drifted the corpus.
   Nothing asked it directly: `generate-contract.py --check` reads Git objects
   at the pinned commit, and `check-contracts.py` regenerates its own view, so
   neither notices a pin that has fallen behind `main`.

## What this changes

`rust/scripts/workspace-tests.py` replaces the bare `cargo test --workspace` in
both `scripts/ci/plan.py` and `.github/workflows/rust-ci.yml`:

- checkout matches the pin → run `cargo test --workspace`, propagate its exit
  code. This is `main` and every `rust/**`-only branch, so #1778's coverage is
  untouched there.
- checkout is ahead of the pin → verify every pinned file still matches
  `origin/main`, name the files this branch is ahead on, and defer their
  validation to `check-contracts.py`'s candidate run later in the same lane.
- **the pin does not match `origin/main`** → fail, naming the stale files and
  the exact `generate-contract.py --write --baseline-revision` command. This is
  the #1773 case, and it is now asked directly instead of as a side effect.
- `origin/main` unreachable → fail rather than guess; the script attempts a
  shallow fetch first.

## Verification

Exercised all three paths in a worktree at `abc24e1d`:

| Situation | Result |
| --- | --- |
| clean checkout | ran `cargo test --workspace`, exit 0 |
| one recorded frame appended | exit 0, named `…/ControlFrames/agent.resume.jsonl` as ahead of a pin current as of `origin/main` |
| one pin entry's sha256 corrupted | exit 1, named `Catalog/generated/effect-authorization-matrix.md` and printed the re-pin command |

`scripts/ci/test_plan.py` 31 tests and `scripts/test_agent_pr_workflow.py` 11
tests pass with the lane's command list and the workflow's pinned token set
updated. The workflow contract's negative mutations still reject replacing the
step with `cargo test -p arkdeck-contract` or `true`.

## What this does not do

It does not re-pin anything, and it does not remove the need to. A branch that
changes recorded frames still leaves the pin behind, and `main` still needs
`generate-contract.py --write` afterwards — the difference is that the branch is
no longer unmergeable in the meantime, and a pin that stays behind on `main` now
fails the lane by name.
