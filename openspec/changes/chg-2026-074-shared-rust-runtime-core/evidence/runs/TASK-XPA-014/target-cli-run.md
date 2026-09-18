# TASK-XPA-014 — the Rust CLI's `target adopt` and `target availability` (macOS, 2026-09-14)

TASK-XPA-014 remains in progress. Base: protected main `438434ef`, which carries #1957 (`9aea0419`).
The Rust client admits a Runtime answer only under the method's published schema, and the refusal
codes these leaves consume (`admissionDenied`, `factsDrifted`, `operationUnavailable`) are published
by #1957. Every answer here is one Swift's daemon recorded
over the shared fake HDC; nothing is device evidence (POL-VERIFY-001, POL-MODE-001). No Swift file
changes.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| Swift's CLI argv fixtures for both leaves; the Target adoption oracle and its control shapes (#1957); the Target observation owner (#1959); the Rust `device candidates`, `target list` and `target show` leaves | `target adopt` and `target availability` in the Rust CLI; their argv fixtures in `rust/tests/fixtures/current-cli-argv/`; `tests/target_adoption.rs` | The daemon's routes over that owner (the next slice); the daemon's `target.availability`; the HAR path's CLI leaves (`agent resume`, `human-action list/show/resume`) |

## What the leaves do

They follow Swift's `ArkDeckRuntimeCommands` (`target adopt`, `target availability`),
`CLICommandRegistry` (both leaves and `observationReferenceOptions`) and
`CLIControlFailureMapper`.
- **`target adopt --candidate <key> --observation <id> --observation-generation <n>`** sends
  `target.adopt` with `candidate`, `observationId` and `observationGeneration`.
  - The generation follows Swift's positive-integer grammar. A leading zero, zero, a sign, a word, or
    anything above `Int64.max` is `invalidOption` (64), and nothing is sent. The candidate (1 to
    1,024 bytes) and the observation (1 to 128 bytes) are checked locally as `invalidInput` (65), as
    the other Target leaves check theirs.
  - The answer must be exactly the receipt of that observation: `outcome: adopted`, a non-empty
    Target, a positive binding revision, and the request's observation and generation. Anything
    else is `outcomeUnknown` (75), "target adoption returned no matching complete receipt".
  - It is a mutation: a lost, malformed or schema-violating reply is `outcomeUnknown` and never
    replayed. A Runtime refusal keeps its code only with the pre-admission zero-dispatch proof:
    `resourceConflict` 65, `targetTrustPending` 75, `admissionDenied` 77, `factsDrifted` 77,
    `operationUnavailable` 69, `invalidInput` 65. Without the proof the outcome is unknown. This is
    the mapper `agent run` already uses.
- **`target availability --target <id>`** sends `target.availability` with `targetId`. It is one
  bounded read, emitted as the Runtime answered it once the client has admitted it under the
  method's schema. `notFound` is `resourceNotFound` (65), `invalidParams` is `invalidInput` (65),
  and a lost reply is `runtimeUnavailable` (69).

## Tests

`crates/arkdeck-cli/tests/target_adoption.rs`:
- **The argv fixtures.** Swift's `target.adopt.json` and `target.availability.json`, copied byte for
  byte into `rust/tests/fixtures/current-cli-argv/`, replay through `parse`: 7 cases each.
- **The grammar.** A leading zero, zero, a sign, `Int64.max + 1` and a word are all `invalidOption`.
- **Every recorded answer.** Each of the oracle's 11 adoptions and 3 availability reads goes through
  the actual `arkdeck` binary.
  - The three whose parameters no argv can spell (none, or a leading zero) are refused before any
    connection, with exit 64.
  - The other 11 are served by a fake Runtime. It answers health, checks that the one request carries
    the oracle's parameters, replies with Swift's recorded answer, and accepts no replay and no second
    connection.
  - Each exit code and error code is Swift's mapper's. The three adoptions and the availability
    answer come out as the Runtime answered them.
- **Unknown outcomes.** A receipt naming another observation, another generation or another outcome,
  and a closed connection, are all `outcomeUnknown` (75, not retryable). A lost availability reply
  is `runtimeUnavailable` (69).

## Checks

| Check | Command | Result |
| --- | --- | --- |
| The CLI | `cargo test -p arkdeck-cli --test target_adoption` | 4 passed: the argv fixtures (7 cases each), the grammar, all 14 recorded answers through the actual CLI, and the unknown outcomes |
| Every CLI test | `cargo test -p arkdeck-cli` | 129 passed, none failed |
| Union merge | `python3 scripts/check_union_merge.py` | ok |
| Lint | `cargo fmt --all`; `cargo clippy --workspace --all-targets -- -D warnings` for `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` | formatted; clean for all three |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, with `ARKDECK_PYTHON` naming `.venv-sdd` and the
planner run from a virtual environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `acb2968c` | `gate exit=0`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 797 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-target-cli-gate-20260915-a.log`, SHA-256 `508499eacf409cc134e3db4b833aedcb7230c33cc66d6273471d4eccd93687d4` |

The amend after r1 only fills in this row.

## Not run, and why

- **Against the daemon.** On this base the Rust daemon keeps the foundation's refusal for both
  methods. Its owner is on main (#1959), its routes are the next slice, and adoption also needs a USB
  relation source. The same answers are then replayed over the real daemon.
- **Human output.** Without `--output json`, both leaves print the answer as pretty JSON, as the
  other Rust leaves do. Swift's human text is wording (T2).
- No device, no real HDC.
