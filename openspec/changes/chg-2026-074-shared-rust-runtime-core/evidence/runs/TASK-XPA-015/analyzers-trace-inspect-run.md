# TASK-XPA-015 — the remaining analyzers, `trace.inspect`, and an analyzer's agent run

G5 queue slice 13, first half (M3 "no regression after Swift is deleted", A
lane). This record grows with the slice's PRs; each section names its PR, its
base and what it verified.

## 1. `agent run` of an analyzer runs its Job to the end

Base: protected `main` `333023ae4` (#2154).

### What a caller saw

The GJ-5 fake rehearsal (S23, `gj5-fake-rehearsal-2026-09-25.md`) found that
`arkdeck agent run --operation analyzer.extract-crash-signature@1 …` never
ended on the Rust daemon, while `job submit` + `job run` of the same request
ran to `succeeded`.

- The execution reached `jobOwned` and stayed there: every `agent.status`
  answered the Job `preflight` with next action `wait` / `job.running`, and
  the client read it again forever (`agent run` has no end of its own but
  `--timeout`, as in Swift's `runRuntimeExecution`).
- The Job could not be run by anyone afterwards either: its journal had
  already moved `preflight → running` (`steps-start`) while its record still
  said `preflight`, so `job.run` refused it as a journal that does not stand at
  its boundary.

### Why

Swift's `AgentExecutionCoordinator.startJob` runs the owned Job with the same
engine that admitted it. The Rust daemon's `Host::start_agent_run`, which runs
the owned Job in the background, composed its `JobRunner` with
`analyzer: None`, while the admission that accepted the Job (the planner inside
`agent_execution`) had the configured analyzer. So the run reached
`steps-start`, found no analyzer profile for the typed action and returned an
internal failure before the record was persisted.

### The fix

`start_agent_run` now takes the analyzer from the same planning composition as
the admission (`rust/crates/arkdeck-agentd/src/host.rs`). Nothing else
changes: the run, its verification, publication and the execution's
`finishJob` are the ones `job.run` already uses.

### Evidence

- New process-level test `an_agent_execution_of_the_analyzer_runs_its_job_to_the_end`
  (`rust/crates/arkdeck-agentd/tests/crash_ledger_analyzer.rs`): an isolated
  daemon whose `ARKDECK_ANALYZER_PATH` names itself, over the reconcile
  oracle's analyzer source, receives the `agent.run` the CLI sends. The test
  waits at most 60 s for the execution's durable record to leave `jobOwned`
  (the client's wait, bounded), then checks the record is `completed` with
  the Job `succeeded` and its outcome known, `job.status` agrees, the derived
  `crash-signature.json` is Swift's analysis of the source beside the source's
  identity (the existing `job.run` test's assertion, now shared), the source is
  untouched and `0400`, and a later `job.run` of the Job is refused
  `resourceConflict`.
- Before the fix (the same test on `333023ae4` + the test only): it fails
  after 61 s, "the execution never ended; its Job is "preflight"", with the
  execution record at generation 7, `jobOwned`
  (`/private/tmp/arkdeck-s25-agentrun-before2.log`).
- After the fix: 5/5 in the binary pass in 1.7 s
  (`/private/tmp/arkdeck-s25-agentrun-after2.log`).
- Mutation: putting `analyzer: None` back in `start_agent_run` is caught (the
  test fails at its 60 s bound, as above); restored by SHA-256.

### Left for the contract PR

With the Job now finishing, the first `agent.status` read of the *completed*
execution is refused by the daemon's own conformance check ("the result does
not conform to the current contract", `internalError`): the published
`agent.status` and `agent.run` result schemas were derived from device-bound
executions only, so a host-only execution's `artifacts[].bindingRevision`,
`artifacts[].stableIdentitySha256`, `evidence.artifacts[]…` and
`evidence.bindingRevision` (all `null`, as Swift answers them) do not conform.
`agent run` therefore now ends — with that refusal — instead of waiting
forever; answering `completed` needs a Swift recording of a host-only agent
execution and those two schemas widened (a contract-input change, held for the
coordinator to order against the M4 lane's `generate-contract`). The same gap
is S23's chip for the workspace operations and the input gestures.

### Checks (local, targeted)

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-1330-rust-target`, logs
`/private/tmp/arkdeck-s25-a-*.log`:

- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-agentd --all-targets -- -D warnings`:
  exit 0 (no other crate changed; nothing depends on the daemon crate).
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --no-fail-fast`:
  exit 0; the bin's 107 tests and 42 in 12 integration binaries pass
  (`crash_ledger_analyzer` 5/5). No fake HDC or daemon left running.
- `sh scripts/check-sdd.sh`: exit 0.
- Not run: `generate-contract.py --check` and `check-contracts.py` (no contract
  input changes), Swift, the App, a device.

### CI

Pending.
