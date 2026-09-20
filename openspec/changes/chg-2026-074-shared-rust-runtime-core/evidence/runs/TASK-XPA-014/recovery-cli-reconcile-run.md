# TASK-XPA-014 — recovery port, slice 2g: the Rust CLI's `job reconcile` leaf

Change: CHG-2026-074-shared-rust-runtime-core@r11. Part of slice 2 of the recovery port the
maintainer ruled on 2026-09-19 (design §L.1 item 13; the Ruling section of
`evidence/adr-0009-decision-package-20260914.md`). Package §1c names `job.reconcile` as the only
sanctioned exit of an unknown outcome, and §1b names the CLI's side of it: `terminalJobExit`
exits 75 with "reconcile it; the original effect is never replayed", and
`isControlRequestRetryable` never lets a caller retry into a second dispatch. The Rust CLI already
ports both (`run_exit`, `controlRequestRetryable`), but it had no leaf that reaches the exit it
names: Swift's `arkdeck job reconcile --job <id>` (`CLICommandRegistry`, `RuntimeCLI` "reconcile")
was missing. This slice ports that leaf. Host-local: no device, no daemon change.

Base: protected main `28d2016c` (#2050), whose nine-line `job.reconcile` frame corpus the tests
read. First written on `6592bcce`; each rebase met new lines in the CLI's help text (#2056's
workspace leaves, then #2065's `commands`), kept, with this leaf's line added after `job cancel`.
Since #2065 the leaf is also listed by `arkdeck commands`: that projection lists a registry entry
exactly when this parser serves its path, and `tests/argv_fixtures.rs` replays the argv fixture of
every served leaf, this one now included. Branch `agent/xpa-014-recovery-cli-reconcile-20260919`,
pushed once #2050 is on main. It does not depend on slice 2b: the leaf reaches any Runtime that
serves `job.reconcile`, the Swift daemon's today and the isolated Rust daemon's with 2b.

## Ported exactly

From Swift's CLI:
- **Argv**: the leaf takes `--job` (required) and the Runtime client options, as `job cancel`
  does (`runtimeClientOptions([jobIDOption])`): no `--timeout`, no `jsonl` output, the macOS
  `--socket` compatibility option. `rust/tests/fixtures/current-cli-argv/job.reconcile.json` is a
  byte-for-byte copy of Swift's `Fixtures/CLI/argv/job.reconcile.json`, placed where the
  contract view can include it.
- **Request and output**: `job.reconcile {jobId}` with the opaque identity as given, the Runtime's
  answer emitted as it is, exit 0 whatever the Job's state. Swift's leaf applies no
  `terminalJobExit`: a reconcile that leaves the outcome unknown answers with that status and is
  not a failed request.
- **Errors**: Swift's `CLIControlMethodRegistry` classifies `job.reconcile` as mutation-capable,
  and its answers carry no details. So `notFound` is `resourceNotFound` (65), `invalidParams`
  `invalidInput` (65), `unknownMethod` `controlMethodUnavailable` (69), `rejected` and
  `internalError` `outcomeUnknown` (75); with the pre-admission proof, `rejected` would be
  `admissionDenied`. A reply lost after the request went out is `outcomeUnknown` (75) with the
  method named and is never resent; a connect failure proves nothing was sent and stays
  `runtimeUnavailable`, as for `job cancel`.

Files: `arkdeck-cli` `lib.rs` (the route, the options, the parameter list and the mutation error
path), `job_plan.rs` (the required `--job`, and the lost-reply wording), `main.rs` (the request
branch beside `job cancel`'s and the help line), `tests/job_reconcile.rs` (new), the argv fixture
copy, `rust/README.md` (the Job cancellation section's CLI paragraph now covers both leaves), and
this record.

## Tests

`tests/job_reconcile.rs`:
- the argv fixture replays: every case's command, parameters, missing deadline, help and usage
  refusals (`invalidOption`, 64), and `--timeout` refused as for `job cancel`;
- every refusal code maps as above, the proven `rejected` included, and a lost reply is
  `outcomeUnknown` naming `job.reconcile`;
- through the actual CLI and a fake Runtime (macOS): every successful answer in Swift's
  `job.reconcile` corpus (`waitingForRecovery` with `outcomeUnknown`, `failed` with a published
  Session and with none (`unavailable`), `succeeded`, `preflight`,
  `resumeAtConfirmedSafeBoundary`) is emitted unchanged with exit 0, and the corpus's two
  refusals of a named Job (`notFound`, `internalError`) exit 65 and 75 with their wire codes
  kept in the details.

## Local targeted checks

Per `AGENTS.md` (#2015) the unified gate is the PR's CI. Locally, from `rust/`, with
`CARGO_BUILD_JOBS=2`:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --locked -p arkdeck-cli --all-targets -- -D warnings` | 0 | clean |
| the same for `--target x86_64-unknown-linux-gnu` | 0 | clean: the corpus and its reader are the macOS module's, where the fake Runtime runs, so no other host sees them unused (the first push's `ubuntu-latest` and `windows-latest` lanes did, and refused it) |
| `cargo test --locked -p arkdeck-cli` | 0 | 166 passed, 0 failed (4 new, `job_cancel` and #2065's coverage tests unchanged) |
| `sh scripts/check-sdd.sh` (repository root) | 0 | 0 errors, 0 warnings |

Log: scratchpad `logs/checks-2g-main.log`, SHA-256
`b1a185e464c5ed5229f22273441709c62e8353d035dd07b71c345e0ee06061cf`. Earlier runs: on `655c8199`
with #2050's head applied (163 passed), `checks-2g-new.log`, SHA-256
`8e3def3ef416ad70c588ffe8336d6cceaca187afaa36dcfcff53a6bbc3b65b59`; the first, on `6592bcce`
(161 passed), `checks-2g.log`, SHA-256
`f9d569dee67bea3d280cae66ec66485d5938638d9d238e108f1e53fb5f88e6b6`.

No contract input changed: the argv copy sits under `rust/tests/fixtures/`, and the corpus is read
where #2050 left it.

## CI

The PR's `guard` and `swift` aggregate (Rust lane): recorded in the next slice's record.

## Not in this slice

- An end-to-end run of the leaf against the isolated Rust daemon: slice 2b's process test drives
  `job.reconcile` over the daemon's socket, and a CLI process test follows once both are on main.
- `job wait` and `job watch`, Swift leaves that also end at a Job's terminal status; they are not
  recovery carriers.
