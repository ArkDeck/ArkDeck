# Rust `job.submit` for the crash-signature analyzer — macOS, 2026-09-14

TASK-XPA-014 remains in progress. Base: `1733d375`, the `job.plan` slice (#1892, open), on protected
main `7dabc3c3`. This slice admits `analyzer.extract-crash-signature@1` from the isolated Rust
development composition as Swift does and gives the Rust CLI `job submit`. Rust dispatches nothing,
and nothing installed changes. Every request and Artifact is synthetic host data; nothing here is
device evidence.

## Already on main or in #1892 / this slice / still remaining

| Already on main or in #1892 | This slice | Still remaining for TASK-XPA-014 |
| --- | --- | --- |
| Rust reads the v1 Job index, records, events and Artifact routing and writes journals, the admission index and `job-record.json` (#1863, #1879, #1889, #1891); `job.plan` for the analyzer (#1892) | `job.submit` for the analyzer: idempotent admission under the default read-only policy, the admission journal and record, `arkdeck job submit`, a Swift-recorded admission oracle, a real-process harness whose last phase hands the Rust-written store to Swift, and Job read schemas that accept a thread | admission of every other operation (device facts, Runtime capabilities, imported leases, debug permits), capability mint/reserve/consume, the executor hand-off, §G.4 preflight, recovery (after the L.1 item 13 ruling), GJ-1..5 |

## Behaviour

`JobAdmitter` (`arkdeck-hoststore/src/job_admission.rs`) is Swift `RuntimeJobEngine.submitOwned` as the
target control plane calls it:

1. exactly one bounded `requestJson`, the current request, the catalog lookup (with `job.plan`'s
   materialized-operation gate) and the typed inputs;
2. the idempotency lookup before anything is materialized: a known key with the same fingerprint
   answers with its Job (refused as `idempotencyConflict` when the Job was admitted under another
   catalog digest, and as `reviewedPlanMismatch` when a reviewed plan differs from the Job's), and a
   known key with another fingerprint is `idempotencyConflict`;
3. the Job id Swift derives (`job-` and the first 32 hex digits of SHA-256 over key, newline and
   fingerprint), the materialized plan, and the reviewed plan against the fresh one;
4. the catalog's default read-only policy within Swift's `RuntimeDefaultReadOnlyPolicy` bounds (900 s,
   512 MiB), recorded as `{"kind": "defaultReadOnlyPolicy", "reference": "default-read-only-policy",
   "admittedAtUTC": …}` — no capability is read, reserved or consumed;
5. the admission row, then `jobs/<jobID>/journal.jsonl` with `jobCreated` (`execute`,
   `standardAgent`, `CORE-2.0.0`) and `queued -> preflight` (`admitted`), then `job-record.json` at the
   index's second version, each spelled as Swift writes it; a concurrent duplicate found at admission
   answers as Swift does there.

A refusal before the admission point carries `{"phase": "preAdmission", "newDispatchCount": 0}`. A
store failure, or any failure once the admission row is written, answers `internalError` with Swift's
single message and empty details, as Swift's handler does for a submit. The clock is Swift's plain
`ISO8601Timestamps` form, whole seconds in UTC. `arkdeck-agentd` routes `job.submit` in the isolated
composition, which now opens its Job store with the owner connection; the façade still forwards it and
the standalone foundation answers `rejected`.

`arkdeck job submit` builds requests as `job plan` does, prints Swift's note in human mode when it
generates the idempotency key, accepts only an `arkdeck.job-acceptance/1` that dispatched nothing,
and maps a refusal as Swift's CLI maps a mutation-capable method: a code survives only with the
zero-dispatch proof, any other reply is `outcomeUnknown`, and a failure to connect stays
`runtimeUnavailable`.

The harness found that the Rust control layer answered `internalError` ("the result does not conform
to the current contract") for `job.status` and `job.show` of every Job carrying a thread: their
schemas were derived from frames that never held one, so they published `threadId` as `null` only.
The oracle now records Swift's reads of each admitted Job, and re-deriving from them lets both methods
answer a `threadId` string (`job.show` also accepts `arkdeck.threadId` provenance); five frames joined
the corpus, and the CLI corpus replay, which pinned exactly 13 `job.show` frames, now requires at least
the 16 it replays verbatim.

Deliberate differences from Swift, all toward refusal:

- Operations other than the analyzer, a well-formed imported lease and a Runtime debug permit are
  refused with `rejected`, as in `job.plan`; an effect above `readOnly` would need a Runtime
  capability, which this Runtime does not issue (unreachable for the analyzer).
- No host-wide HDC lifecycle interlock applies: the isolated Rust composition has no HDC lifecycle
  action.
- An admitted Job stays in `preflight`, since this Runtime has no executor yet; the Rust CLI therefore
  has no `--wait`.

## Shared oracle

`rust/tests/fixtures/job-submit-analyzer/` was recorded by Swift `JobSubmitAnalyzerOracleContractTests`
in record mode (`ARKDECK_RUST_JOB_SUBMIT_RECORD`) under the `job.plan` oracle's fixed physical root and
lock, with a fixed clock; `provenance.json` lists the SHA-256 of each file.

| File | Content |
| --- | --- |
| `cases.json` | 18 requests in order over one store: an admission, duplicates (plain, with the matching and with another reviewed plan, and after later Jobs), a conflict, admissions with a reviewed plan, a caller capability and a thread-bearing client context, a fresh plan unlike its reviewed plan, and refusals for an unresolvable lease, an unknown operation, a pinned revision, a missing input, malformed and empty documents, a request over 1 MiB and an unconfigured analyzer |
| `reads.json` | Swift's `job.status` and `job.show` of each of the four admitted Jobs |
| `store/index.json` | the admission index a reader observes: layout, pragmas and every row |
| `store/jobs/<jobID>/` | each admitted Job's `journal.jsonl`, `job-record.json` and `.manifest.lock` |
| `artifacts/`, `analyzer` | the published source crash log and the pinned analyzer bytes |

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Rust admitter | `cargo test -p arkdeck-hoststore --test job_admission` | 1 passed: all 18 answers, the 8 reads, the index facts and the 12 Job files reproduced byte for byte |
| Rust planner and CLI | `cargo test -p arkdeck-hoststore --test job_plan`; `cargo test -p arkdeck-cli` | 3 passed; every CLI binary passed, `tests/job_submit.rs` 3 (request forms and the generated-key signal, acceptance check, zero-dispatch mapping) and the `job.submit` argv fixture replays |
| Swift oracles and schemas | `run-swiftpm.sh test --filter 'ControlMethodSchema\|JobSubmitAnalyzerOracleContractTests\|JobPlanAnalyzerOracleContractTests'` | 6 executed, 1 skipped (frames of this run, without a frame log), 0 failures: both oracles regenerate the committed fixtures and the committed corpus validates against the re-derived schemas |
| Real processes | `python3 rust/scripts/check-job-submit.py --swift-bin-dir <run-swiftpm debug products>` | PASS, 43 checks. The standalone Swift daemon and the Rust owner, in turn over one state root with `/usr/bin/true` as the analyzer, answer 17 requests identically (the unconfigured case needs a second engine and stays with the Rust test) and admit the same four Jobs; each CLI's flag-form submit returns the same acceptance and a Rust retry deduplicates; Rust reads each admitted Job as Swift reads its own; the index rows and every Job file agree apart from the clock. A standalone Swift daemon given the Rust-written store recovers the four Jobs in `preflight` and runs one: its journal gains one `stepIntent` and one `stepOutcome` and it ends `failed` (`executionFailed`), since `/usr/bin/true` prints nothing for the analyzer to verify. Summary `/private/tmp/xpa014-job-submit-harness-r2.json`, SHA-256 `30bafa499c0091c9279116e9c67540b2f5051d375e6192ba4e9ba9daaa41bb34` |
| Contract | `generate-contract.py --write`, then `--check` | the checkout manifest describes the re-derived `job.submit`, `job.status` and `job.show` schemas and corpus |

## Unified local gate

`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`,
with `ARKDECK_PYTHON` on the SDD venv and the planner started from a venv holding `PyYAML` and
`jsonschema`. Against merge base `7dabc3c3` the planner classified 67 changed files (both commits of
this branch) and selected the common, design-system, Swift and Rust lanes (no App build).

- r1 on `d1a4587f` ended `gate exit=1` (`/private/tmp/xpa014-job-submit-gate-20260914-r1.log`,
  SHA-256 `e6f8543ccce098ca14dc28b1f7c59e29864f27f1b69ac00d7a5be7ba6d469627`). Every lane passed but
  `check-contracts.py`'s published view, which runs this checkout's Rust tests against main's contract
  inputs: the CLI corpus replay then required at least 16 `job.show` frames while main's corpus holds
  13. The replay now requires at least the 13 main publishes, which both views satisfy.
- r2 on `41f1fa18`, `/private/tmp/xpa014-job-submit-gate-20260914-r2.log`:
  - Common checks: planner and agent-PR workflow tests, SDD (0 errors, 0 warnings, 121 acceptance
    IDs), catalog generator tests and `--check`, design-system tests.
  - Swift full lane: `full-parallel` 2,652 tests exit 0 (both oracle tests among them),
    `full-process-identity-race` 1 test exit 0, `full-viewer-scale` 5 tests exit 0.
  - Rust lane: `generate-contract.py --check`, `cargo fmt --all --check`, warnings-denied Clippy,
    workspace tests, `test_contract_checks.py` (33 tests OK), `check-contracts.py` passing both views
    with every candidate process harness and `test-macos-facade.py` (7 tests OK), `cargo deny` and
    `cargo vet` (36 fully audited).
  - Result: the log ends `gate exit=0`; SHA-256
    `c55def09efc8d849a9dda22e6d7901d92c31da25d022aeca70785e0face622ba`.

## Not run, and why

- No capability-bearing or device-bound admission, no executor hand-off and no recovery: TASK-XPA-014's
  next slices; ADR-0009 decisions 2/4 (L.1 item 13) are not ported.
- The handoff runs the Job in Swift, not in Rust; it proves only that Rust admissions are Swift-runnable.
- `check-job-submit.py` needs the SwiftPM daemon and CLI products, so it runs by hand rather than inside
  `check-contracts.py` or CI.
- No device; DAYU200 is not attached to this host.
