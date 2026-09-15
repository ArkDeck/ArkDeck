# TASK-XPA-014 — agent executions that name no target raise Swift's physical-assistance actions (macOS, 2026-09-15)

TASK-XPA-014 remains in progress. Base: protected main `1ce890dc`; no stack. That main carries the
daemon's device observation routes (#1966): an execution that names no target observes through
the Target observation owner and the sources the daemon composes there. Every request and answer here is synthetic host data
over `/bin/sh` scripts; nothing is device evidence (POL-VERIFY-001, POL-MODE-001). No Swift file
changes.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| Swift's physical-assistance oracle (#1950); the typed action records, re-running a waiting execution, budget expiry and abandonment (#1953); the Target observation owner (#1959); the daemon's device observation routes (#1966) | An execution that names no target observes the devices and raises Swift's action; `human-action.list` and `human-action.show` through the combined human-action owner; `tests/agent_human_action_raise.rs` | Adoption inside `agent.run` and `agent.resume`, the resume routes and the Job after them (A4: the oracle's other 14 exchanges); the development USB relation source and the real-daemon replay; the HAR CLI leaves |

## What changes

- **The raise** (`agent_execution.rs`; Swift `resolveTarget`, `resolveSnapshot` and `raiseAction`):
  - An operation that binds no device and names a registered `projectRef` resolves to that
    project, as Swift's does.
  - Any other execution that names no target takes one observation through the Target observation
    owner: the USB relations, `list targets -v`, then the relations again. The budget is checked
    after it, as Swift checks it, and an expiry stops the execution at its original budget.
  - No device raises `connectDevice`; several raise `selectDevice`, with one `candidate-` choice
    per observed device. One device that is not authorized and connected raises `trustDevice`
    while it waits for its trust prompt and `connectDevice` otherwise, naming that exact
    observation. One connected device whose physical identity is unproved is refused with
    `admissionDenied`, and the execution keeps orchestrating.
  - An action is minted as Swift mints it: `har-`, `resume-` and `candidate-` with lowercase
    version-4 UUIDs, created at the execution's high-water mark and expiring at its deadline. A
    waiting action that asks for exactly the same thing is kept, and at 128 actions the history is
    exhausted (`operationUnavailable`). The execution then waits (`waitingForHuman`) at its next
    generation, and the run answers its projection.
  - An observation that fails answers as Swift's daemon answers it: the reading's reason or, for
    a refusal of the observation owner, `internalError` "execution resource could not be read or
    advanced; inspect the exact owner".
- **Not ported yet: adoption inside the run.** Swift adopts a single proved and connected device
  inside `agent.run`. No oracle records that path, and adoption inside the resume is the next
  slice's, so here it is refused with `operationUnavailable` and the pre-admission proof. Under the
  daemon's `NoUsbRelations` no device is proved, so such a device is refused with
  `admissionDenied` first.
- **The human-action owner** (`human_action.rs`; Swift `RuntimeHumanActionResourceCoordinator`):
  - `human-action.show` and `human-action.list`, with the daemon's checks in its order. Every owner
    refusal carries the zero-dispatch proof, and any other failure is "human-action resource could
    not be read".
  - The list is every execution's actions, newest first and then by identity, paged in the owner's
    own directory (`human-action-snapshots`). A `controlAction` owner lists nothing: the Rust
    Runtime keeps no approvals.
- **Control and the daemon:**
  - `HostServices::human_action`, whose default keeps the foundation's refusal, and its route.
  - agentd composes the combined owner in the isolated development root. An execution observes
    through the Target observation owner's sources whenever the development HDC is composed.
  - Without the owners, the daemon answers `operationUnavailable` "AgentExecution owner is
    unavailable", as Swift's daemon does. `check-readonly.py` now expects that on macOS.

## Tests

`tests/agent_human_action_raise.rs` replays, in recorded order, the 19 exchanges of Swift's
physical-assistance oracle that need no adoption, resume or Job, over the shared fake HDC under its
lock.
- **The owners** are composed over a private root holding the oracle's Target document: the agent
  execution owner on the oracle's clock; the combined human-action owner; and the Target
  observation owner over a `ProcessDispatch` of the fake driver and the USB relations each
  exchange plugged.
- **Every answer** equals Swift's once the identities the owners mint read as the oracle's labels
  (`<har-1>` and so on) and each page's snapshot revision as `<snapshotRevision>`. That covers the
  result, or the refusal's code, message and details.
- **The fake's calls** are the oracle's four device lists (its lines 1, 11, 12 and 13): one for
  each run that observed.
- **The records** of the unproved execution, the one abandoned while it waited for trust, and the
  ambiguous one equal Swift's, with each observation's identity and generation read alike, since
  Swift's skipped resume observed twice more. The reconnecting execution still waits, at
  generation 4, where Swift went on to resume it. The Target document is untouched.

It passed on its first run.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| The replay | `cargo test -p arkdeck-hoststore --test agent_human_action_raise` | 1 passed: the 19 exchanges, the fake's four device lists, three records and the Target document |
| The agent owners | `cargo test -p arkdeck-hoststore --test agent_human_action_records --test agent_execution --test agent_lifecycle` | all pass: the waiting records (2), the agent execution oracle (1), the lifecycle oracle (1) and this replay (1) |
| Every hoststore test | `cargo test -p arkdeck-hoststore` | 247 passed and 10 ignored, none failed |
| Control and daemon | `cargo test -p arkdeck-control -p arkdeck-agentd` | 27 passed, none failed; `read_only` 15 of 15 |
| Real processes | `python3 rust/scripts/check-corpus-replay.py --fixture rust/tests/fixtures/<oracle>` for `agent-execution`, `agent-lifecycle`, `observe-device` and `capture-diagnostics` | PASS on all four (29, 25, 28 and 28 exchanges; 57, 58, 57 and 57 checks), as before: each of their runs names its target |
| Read-only host check | `rust/scripts/check-readonly.py` (from the virtual environment carrying jsonschema) | PASS: 124 control responses, 12 CLI envelopes, 115 valid requests. Without the owners, the macOS daemon answers `human-action.list` and `human-action.show` with `operationUnavailable`, as Swift's does |
| Union merge | `python3 scripts/check_union_merge.py` | ok |
| Lint | `cargo fmt --all`; `cargo clippy --workspace --all-targets -- -D warnings` for `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` | formatted; clean for all three |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, with `ARKDECK_PYTHON` naming `.venv-sdd` and the
planner run from a virtual environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `bc342c05` | `gate exit=0`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 804 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-agent-human-action-raise-gate-20260915-a.log`, SHA-256 `32b56aae63509f3e36a0dded3b6a2fe598bd69b6a48399cf1e9ddd2df460f351` |

The amend after r1 only fills in this row.

## Not run, and why

- **The oracle's other 14 exchanges:** the resume routes, adoption inside the resume, and the Job
  after it. They are the next slice's.
- **Adoption inside `agent.run`:** no oracle records it (above).
- **The real daemon:** its USB relations read none until a development source lands, so a
  real-daemon replay of this fixture waits for it.
- **A restart:** the observation owner's snapshot lives in memory, as in Swift, and restart
  semantics stay out until L.1 item 13 is decided.
- No device, no real HDC.
