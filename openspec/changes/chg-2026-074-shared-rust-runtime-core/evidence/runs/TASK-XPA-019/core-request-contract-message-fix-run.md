# The rejection message that names the error code's module

Base: protected main `c3870c3d`. TASK-XPA-019 / SPK-8 remain incomplete. This fixes the main-branch
failure left by #2058, the slice that declared the v2 request contract in ArkDeckCore.

## What failed

#2058 was merged before its `swift-tests` job finished, and that job then failed (Swift CI
`35452126984`). The failing check was
`JobPlanAnalyzerOracleContractTests.testSwiftPlansTheSharedAnalyzerOracle`:
- the Swift `job.plan` answers no longer matched the shared oracle
  `rust/tests/fixtures/job-plan-analyzer/cases.json` (58133 bytes against 58136);
- so `provenance.json`'s digest of that file no longer matched either.

## Cause

In one case, an analyzer's source Artifact lease is bound to another target. Swift rejects it with
a message built by interpolating an enum case with associated values, and Swift's default
description of that case names the error code's module:

```text
analyzer source artifact Artifact lease is not resolvable: rejected(ArkDeckRuntime.RuntimeOperationErrorCode.invalidInput, "Artifact lease target/binding/identity does not match the materialized request")
```

#2058 moved `RuntimeOperationErrorCode` to ArkDeckCore, so the text now reads
`rejected(ArkDeckCore.RuntimeOperationErrorCode.invalidInput, …)`. The error `code` stays
`invalidInput`, and no encoded contract changed. The message did change, and #2058's record wrongly
said nothing observable changed. That record is corrected here.

The Rust port reproduces Swift's text byte for byte. The same format string appears in four
`arkdeck-hoststore` sources, one for each path that re-checks a lease's binding:
`job_plan.rs`, `debug_hap_plan.rs`, `device_run.rs` and `job_run.rs`.

## Fix

- `rust/tests/fixtures/job-plan-analyzer/cases.json`: the one recorded occurrence now names
  `ArkDeckCore`. The file shrinks by three bytes, to 58133, the size CI's Swift run produced.
- `provenance.json`: the recorded digest of `cases.json` is replaced by the new file's SHA-256,
  `406cd9173f59da4369dee540d905c2f2bb404e7e9628b5ab68c33d1ab8beb147`. It was
  `e9c1c382230d151024455496cc334a4445c0c6532b05f074d8d678995f6691c5`.
- The four Rust format strings now name `ArkDeckCore`, so the Rust daemon keeps answering exactly
  what the Swift daemon answers.
- The oracle and the Rust copies are edited to the new text rather than re-recorded. Only the
  module name changed, and the Swift test below checks the edited oracle byte for byte.
- `core-request-contract-run.md` is corrected: its header and Behaviour section now say which text
  changed, and its CI section records how #2058 was merged and what failed.

CHG-2026-074 r11 sets three parity tiers in `docs/design/cross-platform/rust-core-cross-platform-architecture.md`.
Under them, `message` text and Swift's debug rendering are T2, which need not match; the method
schemas pin only the code and the structure. This oracle and the four Rust strings pin the text
byte for byte anyway, which is left over from before r11. As the coordination session ruled, this
fix changes only the string and does not refactor the pinning.

## Local targeted checks

These ran on this change over `c3870c3d`. Only the checks the coordination session named ran:
the changed crate's fmt, clippy and tests, and the failing Swift test. The PR's CI is the gate.

| Check | Command | Result |
| --- | --- | --- |
| Rust, the changed crate | `cargo fmt --all --check`, `cargo test -p arkdeck-hoststore`, `cargo clippy -p arkdeck-hoststore --all-targets -- -D warnings` (in `rust/`, with this worktree's own `rust/target`) | exit 0, all three. 50 test binaries: 423 passed, 0 failed, 13 ignored. `tests/job_plan.rs` (3 passed) replays the edited oracle against the Rust planner with the edited string. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/msgfix-rust-r1.log`, SHA-256 `a702dc308c2224cc061221ce6f7b7c4f3445c084081d83f4306886e2fe6b3b20` |
| Swift, the failing test | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'JobPlanAnalyzerOracleContractTests'` | It was still waiting for the shared build lock when this was pushed, because main was failing for every PR and the fix went out first. It then passed, on the same tree as the pushed head: exit 0, `testSwiftPlansTheSharedAnalyzerOracle` passed in 0.208s, so Swift's answers match the edited oracle byte for byte. The workspace continuation slice records this, as the coordination session asked. Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-blissful-goldstine-c7d922/26822f74-e8f8-4647-9226-2234ed41e115/scratchpad/logs/msgfix-swift-r1.log`, SHA-256 `0b6ecb69075db06aa8b19fc6dd8d48ec95952a26f2474902457c6ebfa01ecceb` |

## CI

PR #2062, merged as `30a0c85f`. On head `ebc96cea` (base `c3870c3d`) every selected check passed:

| Workflow run | Jobs | Conclusion |
| --- | --- | --- |
| Swift CI `35453090738` | `plan` and the required `swift` aggregate; `rust-checks` ran its four jobs — host-independent checks, and the workspace on macos-26, ubuntu-latest and windows-latest | success |
| SDD Guard `35453090602` | the required `guard`, `ds-tokens` | success |
| Agent PR `35453090577` | `open-pr` | success |

`swift-tests`, `app-build` and `ds-interactions` were skipped: the planner selects the Swift lane from
changed paths, and this PR changed only Rust sources, `rust/tests/fixtures` and openspec records. So
CI did not run the failing test, and the local run above is the only check of the Swift side before
the merge. The coordination session filed that planner gap as its own slice under TASK-XPA-002:
a change under `rust/tests/fixtures/` should select the Swift lane, because 29 Swift test files read
those fixtures.
