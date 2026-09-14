# TASK-XPA-014 — agent execution list and abandonment on the Rust daemon (macOS, 2026-09-14)

TASK-XPA-014 remains in progress. Base: protected main `0ae4fe45`, which carries the agent
lifecycle oracle and the control shapes these answers need (#1944); no stack. The Rust control gate
rewrites any answer outside its method's schema to `internalError`, so this slice was built and
gated stacked on that PR until it merged. Every request and answer here is synthetic host data over
`/bin/sh` scripts; nothing is device evidence (POL-VERIFY-001, POL-MODE-001). No Swift file changes.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| The Rust `agent.run`/`agent.status` and `artifact.list` (#1932), the Rust CLI's `agent run`/`agent status` (#1935), the capture leg (#1938); the lifecycle oracle and its control shapes (#1944) | `agent.list` and `agent.abandon` in `AgentExecutionStore`, a pager without a lock file, the daemon's Job projection limited to runs and status reads, the control routes, `tests/agent_lifecycle.rs`, and agent listings in `check-corpus-replay.py` | The Rust CLI's `agent list`/`agent abandon`; the runbook §2.1 HAR path (an execution without a target, `human-action.*`, `agent.resume`); `target.adopt`/`target.availability`; `runtime.hdc.*` |

## What the Rust owner does

Both methods follow the Swift daemon's `agentExecutionRequest` and `RuntimeAgentExecutionCoordinator`
(`AgentDaemon.swift`, `AgentExecutionCoordinator.swift`), in their order and with their messages.

- **`agent.list`.** The request names only `state`, `operation`, `target`, `pageSize` and `cursor`
  (else `invalidInput`). `pageSize` is an integer from 1 to 1,000, 100 by default (else
  `invalidInput`). A cursor is a string of at most 256 bytes (else `invalidCursor`, "cursor must be a
  bounded opaque string"). Each filter is a string: a published state, a bounded identity for the
  target, and 1 to 128 bytes for the operation (else `invalidInput`, "invalid execution list
  filter"). The owner then reads every record, one at a time in file-name order, as Swift's
  `forEachRecord` does: a record stored under another identity's name is `recordUnreadable`. It keeps
  those the filters select, the target filter reading the resolved target, and projects each without
  its `humanAction`. The rows are ordered newest first, then by identity (`createdAtDescExecutionIdAsc`),
  and the pager stores them and answers the first page. A cursor's page comes from its stored
  snapshot, never from a new scan. The pager's refusals are the owner's, with Swift's wording for a
  cursor and the zero-dispatch proof.
- **The pager.** `SnapshotPager::open_serialized` pages `agent-executions/snapshots/` without the
  `.snapshots.lock` the Session, bundle and tool owners' pagers keep. Swift's `RuntimeSnapshotPager`
  keeps none, and the owner's gate serializes every request as Swift's actor does, so the tree the
  oracle records has no lock file.
- **`agent.abandon`.** The request names exactly `executionId` and `expectedGeneration`. The
  generation is first a bounded identity, then a positive canonical decimal (`"02"` is
  `invalidInput`), and the execution must exist (`resourceNotFound`). An accepted submission the Job
  owner holds is `resourceConflict`, "execution already owns a Job; use explicit job cancel", and a
  recorded Job is `resourceConflict`, "execution already owns a Job"; both carry the `jobId`, since
  abandonment never cancels a Job. A changed generation is `resourceConflict` too. An execution not
  yet terminal becomes `abandoned` in one more generation; a terminal one is answered as it is,
  without a write.
- **The daemon.** `host.rs` projects the owned Job over a run's and a status read's answer only, as
  Swift's `executionMethods` does; a page and an abandonment answer as the owner wrote them.
  `arkdeck-control` routes both methods to the host's agent execution entry. A host without that
  owner still answers them with the foundation's refusal, and the macOS daemon without one answers
  `operationUnavailable`, which `check-readonly.py` now expects for all four `agent.*` methods it
  serves.

## Replays

`tests/agent_lifecycle.rs` replays the lifecycle oracle in-process on the oracle's clock, all 25
exchanges. Every answer matches at T1, and every refusal also has Swift's own message (no wording
difference is reported). A page named by a cursor is of the snapshot that minted it. The fake
received the oracle's 5 calls, the Target document is unchanged, and every file the executions and
the Job leave is Swift's byte for byte. The six page snapshots match by existence and mode, and there
is no lock file beside them: `support::walk` labels a pager snapshot as `HDCOracleHarness` does.
`tests/agent_execution.rs` still replays #1925's oracle byte for byte.

`check-corpus-replay.py` now serves the two methods and compares an agent listing as it compares an
Artifact listing. The daemon's clock orders the listing, so each page is compared by its counts, and,
once the listing ends, its items across the pages, which must stand in `createdAtDescExecutionIdAsc`
over their own times. On the real daemon the three executions are created at different times, so
the list reads `life-stale`, `life-unadopted`, `life-observe`, where the oracle's equal times read
them by identity.

On the lifecycle oracle the harness replays all 25 exchanges over the socket, with 54 checks:
- 17 answers at T1, and the six listings page by page, by their items and in their order;
- the fake's calls;
- every execution's status and the observed Job's reads, unchanged across a restart;
- the Rust CLI reading all three executions as the socket answers them, the abandoned and the
  orchestrating one included (`agent status` reads one execution and does not wait for it to
  settle);
- the observed Job's Artifacts, and a new `observe.device@1` run to its end;
- the two refused startups.

Its summary is `/private/tmp/xpa014-agent-list-harness-agent-lifecycle-r1.json` (SHA-256
`a4d5cd7cf4c5f60a68cb52f20d70e4ddeaf86d514ccf1883452a7a2d225b106f`). The agent execution, observe and
capture oracles still pass (29 exchanges and 54 checks; 28 and 57; 28 and 57), and their summaries
are byte-identical to #1938's last runs (SHA-256 `9995b3e9…`, `01e80dc1…`, `2a399881…`): the
generalized listing comparison changes nothing for `artifact.list`.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| In-process replays | `cargo test -p arkdeck-hoststore --test agent_lifecycle --test agent_execution` | 1 and 1 passed |
| Owner units | `cargo test -p arkdeck-hoststore --lib` | 146 passed, 5 ignored (the pager's own tests among them) |
| Control and daemon | `cargo test -p arkdeck-control -p arkdeck-agentd` | pass; `read_only` 15 of 15 |
| Real processes | `python3 rust/scripts/check-corpus-replay.py --fixture rust/tests/fixtures/<oracle>` for `agent-lifecycle`, `agent-execution`, `observe-device` and `capture-diagnostics` | PASS on all four (above) |
| Read-only host check | `rust/scripts/check-readonly.py` (from the virtual environment carrying jsonschema) | PASS: 124 control responses, 12 CLI envelopes, 115 valid requests |
| Lint | `cargo fmt --all`; `cargo clippy --workspace --all-targets -- -D warnings` for `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` | formatted; clean for all three |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local` (r1's merge base `7cebb912`, with #1944's commit below
this one), with `ARKDECK_PYTHON` naming `.venv-sdd` and the planner run from a virtual environment
carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `a772f25f` | `gate exit=0`: the common checks and SDD, the Swift lane (full parallel, 2,670 tests, then the serialized lanes), the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 1,995 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-agent-list-abandon-gate-20260914-r1.log`, SHA-256 `40e91dc3c655b1d263dba8d1445eb816a2b6e1056c2e6bfd54ebcb7f3eed53f1` |

The amend after r1 fills in this row. #1944 then merged as `0ae4fe45`, after #1939, #1942, #1943
and #1940, and this commit was replayed onto that main: the oracle commit below it dropped as
already upstream, and nothing conflicted. #1943 keeps a slice's record in its run record alone, so
this commit no longer adds a bullet to `tasks.md`, and its `rust/README.md` changes stay in place
in the agent section (`scripts/check_union_merge.py` passes). On the replayed head the build, both
in-process replays, the control and agentd tests (`read_only` 15 of 15) and `check-corpus-replay.py`
on the lifecycle and agent execution oracles pass again, their summaries byte-identical to r1's
(`-r2.json`). CI gates the rebased commit.

## Not run, and why

- **The Rust CLI's `agent list` and `agent abandon`.** The next slice; the CLI still refuses them.
- **An execution waiting for a person.** Its record holds a physical action, which the Rust owner
  does not read yet, so it is neither listed nor abandoned here; abandoning one expires its action
  in Swift. That is the runbook §2.1 HAR path.
- **Restart carry-over.** Nothing here resumes anything after a restart (L.1 item 13). Abandonment
  is a caller's request that only stops orchestration.
- **Snapshot bytes.** They follow a random revision and are compared by existence and mode only.
- No device, no real HDC: the fake answers what the daemon asks.
