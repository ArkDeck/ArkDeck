# TASK-XPA-014 — the Rust planner plans the pointer gestures as Swift does: catalog patterns evaluated, the frame's freshness judged, the gesture materialized (macOS, 2026-09-15)

TASK-XPA-014 remains in progress. Base: protected main `438434ef`; no stack. This slice teaches the
Rust planner `input.tap@1`, `input.long-press@1` and `input.swipe@1`. Submitting one is still
refused, because no Runtime capability is issued yet, and nothing runs one. Every plan here is
replayed from Swift's pointer-input oracle, recorded over the shared fake HDC. None of it is device
evidence (POL-VERIFY-001, POL-MODE-001).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M2 |
| --- | --- | --- |
| The pointer-input oracle (#1958); the HDC provider's gesture spec, lowering, verdict and persisted form, replayed argv for argv (#1961); the planner for the observation and capture operations | Catalog `pattern` evaluation; the provider context's clock; the gesture step's action, lowering and journal arguments in the plan; `input.*` plans | Automatic capability issuance at submit and `admissionDenied`; consuming a use before the first mutation, dispatching the gesture, recording its outcome; evidence carried from the session readback; the result readers; the full oracle replay |

## Why

Swift plans a pointer gesture before any authorization. `job.plan` answers it, and every later
method starts from the same materialized plan: `job.submit` authorizes that plan, and `job.run`
dispatches it. The Rust planner refused all three operations before judging their inputs. Once the
refusal was lifted, their `screenEpochUtc` would still be refused as a catalog pattern this
Runtime does not evaluate. Behind that, the gesture step had no action, and the planner had no
clock to judge the frame's age against.

## What changes

- **Catalog patterns** (`catalog_pattern.rs`): Swift's `text.range(of: pattern, options:
  .regularExpression)`. It evaluates the syntax every published catalog pattern uses: literals,
  escaped punctuation, classes and ranges, groups, greedy quantifiers and the two anchors.
  - Measured against Foundation on this host: `$` does not match before a final line terminator,
    and a class of ASCII digits matches no other digit. The unit tests carry Foundation's answers.
  - A string input that does not match is `input <key> does not match its catalog pattern`. An
    array item that does not match is `input <key> contains an item outside its catalog pattern`.
    Both are Swift's words.
  - A pattern outside that syntax is still refused as unevaluated. A test checks that every catalog
    pattern is read.
- **The provider context's clock**: `HdcComposition::now`, Swift `ProviderExecutionContext.nowUTC`.
  The planner reads it once per plan. A gesture whose frame is older than 1000 ms is refused
  before authorization, as Swift refuses it.
- **The gesture step**: `device_steps::action` names a pointer gesture's typed action from the
  operation, the inputs and that clock. Swift's provider errors appear under Swift's prefix: a
  provider refusal by its detail alone, a broken bound as the spec's interpolated error. Its
  journal arguments are Swift's: the gesture and the frame it was mapped against, without the
  frame's capture time. The step lowers to the provider's `uinput` process.
- **`input.tap@1`, `input.long-press@1`, `input.swipe@1` are materialized.** `job.submit` for one
  now reaches the default read-only policy and is refused there, as before, because it needs a
  Runtime capability.
- **The run lane is unchanged**: it still dispatches no gesture.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| The pointer-input plans | `cargo test --locked -p arkdeck-hoststore --test pointer_input_plan` | All 10 `job.plan` answers are Swift's, messages included: the three gestures with Swift's plan digests; the rejected, unknown and blocked cases; and the four refusals. Nothing was dispatched |
| Catalog patterns | `cargo test --locked -p arkdeck-hoststore --lib catalog_pattern` | 4 tests pass: Foundation's answers for 24 texts; backtracking over quantifiers, classes and groups; the syntax left unevaluated; every catalog pattern read |
| Foundation's answers | A Swift program on this host (Darwin 25.6.0) printing `text.range(of: pattern, options: .regularExpression) != nil` for each probe text | The answers the unit test holds |
| The whole crate | `cargo test --locked -p arkdeck-hoststore` | 251 tests pass and 10 are ignored, in 32 suites. The observe-device, capture-diagnostics, agent-execution and agent-lifecycle replays still reproduce Swift |
| The daemon | `cargo test --locked -p arkdeck-agentd` | 10 tests pass |
| Lints | `cargo clippy --locked -p arkdeck-hoststore -p arkdeck-agentd --all-targets -- -D warnings` | Clean |
| Formatting | `cargo fmt --check -p arkdeck-hoststore -p arkdeck-agentd` | Clean |
| Union-merged records | `python3 scripts/check_union_merge.py` | `check_union_merge: ok` |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, with `ARKDECK_PYTHON` naming `.venv-sdd` and the
planner run from a virtual environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `74b3f946` | `gate exit=0`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 798 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-m2-pointer-input-plan-gate-20260915-a.log`, SHA-256 `39846abf9a64bd568842c95b1df26e73791dc9ade968e4d8997b68bae446a807` |

The amend after r1 only fills in this row.

## Not run, and why

- **Submitting, running and reading a gesture.** Issuance, consumption, dispatch and the result
  readers are the next slices.
- No device, no real HDC.
