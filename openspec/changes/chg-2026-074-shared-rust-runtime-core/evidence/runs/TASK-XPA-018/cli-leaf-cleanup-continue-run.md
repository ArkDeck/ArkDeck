# TASK-XPA-018 — `recovery cleanup continue` and `cleanup-debt continue` on the Rust CLI (macOS, 2026-09-26)

TASK-XPA-018 remains in progress. Base: protected main `6c47b55e1` (#2208), with C0 (#2205) and C1 (#2208) merged;
no stack. Slice C6 of the CLI remaining-leaves lane. Nothing here is device evidence
(POL-VERIFY-001, POL-MODE-001). No Swift source or test, control schema, corpus, Catalog,
`openspec/contracts`, `openspec/specs` or constitution change. Host evidence only: a fake Runtime
answering Swift's recorded `cleanupDebt.continue` exchanges.

## What changes

- **`arkdeck recovery cleanup continue --job <id> (--remote-path <path> | --bundle <name>)`** and
  its deprecated spelling **`arkdeck cleanup-debt continue`** send one `cleanupDebt.continue` with
  `{jobId, remotePath}` or `{jobId, bundleName}` and emit the Runtime's answer, as Swift's
  `emitCleanupDebt` does for both spellings. The residue is a lookup key into the Runtime's ledger
  of recorded cleanup, never a device path the caller chooses: the Runtime re-runs only the exact
  typed action it recorded.
- The deprecated spelling says so in `meta.lifecycle` (replacement
  `arkdeck recovery cleanup continue --job <id> ...`) and, in the human rendering, on stderr.
- The Job and exactly one residue are required before any connection, refused with the
  registry's words (`requires exactly one of --remote-path, --bundle`, `requires --job <job-id>`).
  Swift's registry pass refuses the same argv before its handler's own guard, which is therefore
  unreachable in Swift too.
- `cleanupDebt.continue` is a mutation-capable method (it is not in Swift's bounded read-only
  set), so a failure after the request went out is `outcomeUnknown` (exit 75) and nothing is sent
  again; a connection that never opened is `runtimeUnavailable`; a Runtime refusal keeps its own
  code, words and details (`CLIRuntimeSession.mapped`, shared `failure_mapping`).

## Tests (`tests/read_leaves.rs`)

- `both_cleanup_spellings_continue_the_recorded_residue`: Swift's two answered exchanges
  (`ControlFrames/cleanupDebt.continue.jsonl`: a bundle and a remote path), one per spelling, each
  sending exactly the recorded parameters over one connection and printing the recorded answer;
  the deprecated spelling's lifecycle.
- `a_refused_continuation_is_the_runtimes_refusal`: the recorded `invalidParams` refusal, with the
  shared mapping's code, words, details and exit status.
- `a_lost_reply_to_a_continuation_is_an_unknown_outcome`: a Runtime that reads the request and
  closes without replying: `outcomeUnknown`, exit 75, and — checked after the CLI exited, when
  every connection it made is queued — no second connection.
- `a_continuation_needs_its_job_and_exactly_one_residue`: neither residue, both, and no Job.
- `argv_fixtures.rs` replays Swift's argv fixtures for the two newly served leaves (zero
  deviations).

Mutation check, baseline passing, each reverted after (`/private/tmp/arkdeck-cli-lane-mut-c6.py`):
`--bundle` sent as `bundle`; the residue check dropped; the Job check dropped; the leaf sent as
`cleanupDebt.list`. Each fails a named test above.

## Counts

- Rust CLI served leaves: 153/209 → 155/209.
- `cli-parity-audit.py` on this build, registry leaves not served: category 2 (leaf missing,
  daemon routed) 33 → 31, category 3 15, category 4 8.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cli-lane-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` —
  exit 0; also with `--target x86_64-pc-windows-msvc` and `--target x86_64-unknown-linux-gnu` —
  exit 0 each.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli` — exit 0
  (`/private/tmp/arkdeck-cli-lane-c6-test-all.log`).
- `python rust/scripts/check-readonly.py --bin-dir /private/tmp/arkdeck-cli-lane-rust-target/debug`
  (validation venv) — exit 0, `PASS`.
- `sh scripts/check-sdd.sh` — exit 0.

## CI

Pending; recorded by the next slice.
