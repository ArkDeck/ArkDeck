# TASK-XPA-018 — `agent resume --resume-token` on the client, as Swift resumes it (macOS, 2026-09-26)

TASK-XPA-018 remains in progress. Base: protected main (no stack). This PR adds no `tasks.md`
line (the coordinator's ruling of 2026-09-26). Nothing here is device evidence (POL-VERIFY-001,
POL-MODE-001). No control schema, corpus, Catalog, `openspec/contracts`, `openspec/specs` or
constitution change. Host evidence only: fake Runtimes answering Swift's recorded scripts.

## Why

A domain leaf that pauses for physical assistance (#2208, #2212) tells the person to run
`arkdeck agent resume --resume-token <token>`. Swift's CLI resumes that on the client
(`usesRuntimeExecution`: `agent resume` with a resume token and neither a selection file nor a
timeout), from the pending record the paused run wrote, through `AgentRuntimeExecutor.resume`.
The Rust CLI sent it to the Runtime instead, which holds no such record, so the command a pause
names could not continue the pause.

## What changes

- `rust/crates/arkdeck-cli/src/domain_executor.rs` ports `AgentRuntimeExecutor.resume`: the token
  held to its shape (`resume-` and a safe identifier), the pending record read and decoded whole
  (a record that is absent or does not decode is the same unknown token), the Runtime's catalog
  digest checked against the one the pause recorded, the selection the pause asks for (none, an
  adopted target, or a device candidate) checked and applied, then the paused run continued from
  where it stopped. A continuation whose request went out ends as the executor's run ends — its
  receipt, a failed run's reason, or a new pause — and the pending record is replaced or removed
  exactly as Swift does. Every refusal is Swift's `invalidResume(…)`, before anything is sent.
- `domain_leaves.rs` / `main.rs` route `agent resume --resume-token` (without `--selection-file`
  or `--timeout`) to the client, as Swift's `usesRuntimeExecution` does, and render the outcome
  through the domain handler's one renderer (`emitAgentOutcome`); `agent_executions.rs` keeps the
  token on that path.
- `tests/client_failure_mapping.rs` no longer lists `agent resume --resume-token` among the leaves
  whose connection never opened: it opens none before its pending record is read.

## Oracle and tests

- `CLIDomainExecutorOracleContractTests.testSwiftDomainExecutorResumesTheRustCLIReplays` (Swift)
  pauses a run against one scripted Runtime, then resumes it against another over the same state
  directory, and records 16 scenarios to `rust/tests/fixtures/domain-executor-resume`: a reconnect
  that completes, one that resumes into a failed Job, one refusing a selection, one that pauses
  again; an adopted-target selection that resumes, is missing, or names a target not adopted; a
  device candidate selected and adopted, missing, malformed or gone; a retried adoption; the
  catalog changed while paused; and a malformed, unknown and unprefixed token.
- `tests/domain_leaves.rs` (`every_recorded_pause_resumes_as_swift_resumes_it`) replays all 16
  through the CLI: the leaf pauses with Swift's words and details and writes the same pending
  record; `agent resume --resume-token` then sends the same frames over as many connections,
  leaves the same pending records, and ends as Swift ends — the receipt, the failed run's reason,
  the new pause, or the plain `arkdeck agent: invalidResume(…)` diagnostic with exit 1.
- `a_pending_record_that_does_not_decode_resumes_nothing`: a corrupted pending record is the
  unknown token — nothing connected, nothing replayed, the record left as it was.

The coordinator's list asked also for an expired resume: Swift's client-side pending token has no
expiry (the Human Action lifetime belongs to `human-action resume`), so there is nothing to port.

## Counts

- No change: `agent resume` was already answered; its `--resume-token` path now continues the
  pause on the client as Swift's does.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cli-lane-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --locked --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D
  warnings` — exit 0; also with `--target x86_64-pc-windows-msvc` and `--target
  x86_64-unknown-linux-gnu` — exit 0 each.
- `cargo test --locked --manifest-path rust/Cargo.toml -p arkdeck-cli` — exit 0
  (`/private/tmp/arkdeck-cli-lane-resume-final-test.log`).
- `python rust/scripts/check-readonly.py --bin-dir /private/tmp/arkdeck-cli-lane-rust-target/debug`
  (validation venv) — exit 0, `PASS`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter CLIDomainExecutorOracleContractTests`
  — exit 0 (recording the resume oracle, in the hub's Swift window, and comparing the existing
  executor oracle unchanged; `/private/tmp/arkdeck-cli-lane-swift-resume.log`).
- `sh scripts/check-sdd.sh` — exit 0.

## CI

Pending; recorded by the next slice.
