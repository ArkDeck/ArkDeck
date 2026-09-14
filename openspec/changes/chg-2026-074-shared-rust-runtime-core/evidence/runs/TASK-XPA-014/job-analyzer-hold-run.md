# Oracle analyzer `hold` answer — macOS, 2026-09-14

TASK-XPA-014 remains in progress. Base: protected main `af43c172`. The change was recorded and probed
on `6cf99fb6`, after #1898 (the run oracle's budget) and #1900 (the cancellation of a running analyzer
Job) merged, then rebased without conflicts over #1906–#1912 and checked again (see "Checks"). It is
test-only — the shared oracle analyzer, the Swift oracle test, the running-cancellation replay, the
real-process harness, their README paragraphs and the four analyzer fixtures — so no production code
and nothing installed changes. Every request, source and analyzer answer is synthetic host data;
nothing here is device evidence.

## Why

`testSwiftCancelsRunningAnalyzerJobs` cancels its `drained` Job once the Job's `stepIntent` is
durable and expects the child still running, so that its process group is drained and the Job ends
`cancelled`. The child answered `sleep`, `/bin/sleep 5`, and Swift has no hook between the intent and
the child's exit: a stall of more than 5 s after the child started let it finish before the
cancellation (`job-cancel-running-analyzer-run.md`, "Not run"). The Rust replay and
`check-job-run.py`'s running cancellation wait for the same intent, and the run oracle's `timedOut`
case answered `sleep` too.

On main, a stall placed after the child started (see "Under a stall") made the Swift oracle record a
different `drained` Job, and made the harness's running Job end `failed` instead of `cancelled`. The
Rust replays passed only because a resuming Rust runner checks its pending cancellation, or its
deadline, before its output readers report the child's end — the ordering the budget note
(`job-run-oracle-budget-run.md`) names — even though the child had ended inside the stall.

## Change

- The oracle analyzer's `sleep` answer is replaced by `hold`, which answers nothing until a release
  file exists under the oracles' fixed root:
  `while [ ! -e /private/tmp/arkdeck-job-plan-oracle/release ] && kill -0 "$PPID" 2>/dev/null; do /bin/sleep 0.05; done`.
  Before a release only a cancellation or a budget ends it; it also ends once its parent is gone, so
  no hold outlives the process that ran it.
- The release path is fixed because the child cannot learn one of its caller's: Swift and Rust exec
  the analyzer through `/.vol/<dev>/<ino>`, hand it the source as another `/.vol` alias, clear its
  environment and give it `/` as its directory. A path on the source's second line would not reach
  the harness either: it copies the fixture's sources byte for byte, and their SHA-256 is in the
  Artifact index and the plan.
- `drained` and `timedOut` answer `hold`. The running-cancellation oracle and
  `tests/job_cancel_running.rs` create the release only once the `drained` run has answered: Swift
  answers `job.cancel` once the intent is durable, while it is still stopping the child, so an
  earlier release could race that stop. The run oracle never releases `timedOut`; its 2 s budget
  ends it.
- `check-job-run.py` still admits its running-cancellation Job over the `timedOut` source, now
  `hold`. It holds the oracles' lock (`/private/tmp/arkdeck-job-plan-oracle.lock`) around that
  cancellation and removes any release left behind, so no oracle or replay releases the child
  meanwhile, and it never releases the child itself. `hold` replaces `sleep` in its skipped modes.

The checked-in analyzer alone, under the oracles' lock: with no release it was still holding after
3 s; the release ended it 35 ms after it was created, with exit 0 and no output; with its parent
stopped for 6 s it kept holding (`S`); with its parent killed it was gone 24 ms later.

## Shared oracles

The four fixtures were recorded again from Swift in one run of the four tests
(`ARKDECK_RUST_JOB_RUN_RECORD=/private/tmp/xpa014-hold-run-oracle-r1`,
`ARKDECK_RUST_JOB_PUBLICATION_RECORD=/private/tmp/xpa014-hold-publication-oracle-r1`,
`ARKDECK_RUST_JOB_CANCEL_RECORD=/private/tmp/xpa014-hold-cancel-oracle-r1`,
`ARKDECK_RUST_JOB_CANCEL_RUNNING_RECORD=/private/tmp/xpa014-hold-cancel-running-oracle-r1`: 4 executed,
0 failures). The analyzer's SHA-256 went from `664e5bba…` to `16e58537…`. A switched case's source
Artifact identity is content-derived, and its lease, request and Job identity follow it (`timedOut`
`job-2be36e7a…` → `job-926fc7b6…`, `drained` `job-3a3fdbd6…` → `job-5ca4fbf1…`). With those renamed,
each of main's files compares to its new counterpart as follows
(`/private/tmp/xpa014-hold-evidence/fixture-diff-final.txt`, SHA-256 `37918be5…`):

| Fixture | Files | Identical | Only digests changed | Anything else |
| --- | --- | --- | --- | --- |
| `job-run-analyzer` | 74 | 49 | 16: plan digests in records, the index, `reads.json`, the provenance | the analyzer; the `timedOut` source (`sleep` → `hold`, 29 → 28 bytes: payload, index row, `mode`, the parked record's `sourceByteCount`); the quota refusal's `remainingBytes: 30327` → `30328` (its Artifact index, record timeline, Journal and `job.show` read), the byte the shorter source frees |
| `job-publication-analyzer` | 107 | 97 | 9 | the analyzer |
| `job-cancel-analyzer` | 95 | 87 | 7 | the analyzer |
| `job-cancel-running-analyzer` | 90 | 75 | 11 | the analyzer; the `drained` source (`sleep` → `hold`, 29 → 28 bytes: payload, index row, `mode`) |

Every answer and state is otherwise unchanged: `drained` still ends `cancelled` with the step's
cancelled outcome, `timedOut` still parks in `waitingForRecovery` under 2 s, and `rerunParked` is
still refused.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Swift oracles, record | the four record variables above, `run-swiftpm.sh test --filter JobRunAnalyzerOracleContractTests` | 4 executed, 0 failures |
| Swift oracles, compare | the same filter in a new process | 4 executed, 0 failures |
| Rust replays | `cargo test -p arkdeck-hoststore --test job_run --test job_publication --test job_cancel --test job_cancel_running` | 4 passed |
| Rust CLI | `cargo test -p arkdeck-cli --test job_run --test job_result --test job_cancel` (they read the fixtures' cases and reads) | 3, 5 and 3 passed |
| Format | `cargo fmt --all --check` | clean |
| Real processes | `.venv-sdd/bin/python rust/scripts/check-job-run.py --swift-bin-dir <run-swiftpm debug products>` | PASS, 156 checks, 18 Sessions on each owner, 16 Jobs handed to Swift, `skippedModes: ["hold"]`; summary `/private/tmp/xpa014-hold-evidence/harness-after-r1.json`, SHA-256 `f3277be8…` |

Binaries: Swift `arkdeck-agentd` `fa8ce28f…` and `arkdeck` `282e78f7…` (run-swiftpm debug products,
copied out of the shared cache), Rust `arkdeck-agentd` `ef39d8fb…` and `arkdeck` `3eea2d6a…`.

The change was then rebased onto `af43c172` (#1906–#1912, no conflicts; #1909 is the only one touching
the same paths, with its own README section, evidence and fixture). On the rebased tree the four
replays and the three CLI tests passed again, and `check-job-run.py` passed with the rebuilt Rust
daemon (`81bb1295…`) and CLI (`15d60b57…`): 156 checks, summary
`/private/tmp/xpa014-hold-evidence/harness-rebased-r1.json`, SHA-256 `1943ece5…`.

## Under a stall

`stall_probe.py` runs a command and walks its process tree every 0.2 ms (`proc_listchildpids`).
While its trigger holds it stops one process with `SIGSTOP` for 6 s and continues it with `SIGCONT`
for 0.1 s, over and over; the analyzer, in its own process group, is never stopped. A spawn trigger
stops the process the moment a new analyzer appears and continues the analyzer itself, as its runner
would a moment later, so the analyzer runs through the stall; a `sleep` trigger stops it while a
`sleep` runs below. When a stall ends the probe records the analyzer's `ps` state (`S` still running,
`Z` exited while its parent was stopped, `gone` exited and reaped), and, in its last revision, the
analyzer's mode (its source's first line, read through the `/.vol` alias in its arguments). Main's
side used the checked-in `sleep` fixtures, main's test source and main's replay binaries; the Rust
`job_run` binary is the same on both sides, since its source did not change and it reads the fixture
at run time.

| Stopped process | Stalled when | Main (`sleep`) | This change (`hold`) |
| --- | --- | --- | --- |
| Swift `xctest`, the run and running-cancellation oracles in compare mode | an analyzer child of `xctest` appears, and while a `sleep` runs below | 1 run: the running-cancellation oracle failed, 10 files differing — the `drained` Job's record, Journal, Manifest proposal and Session files, and `cases.json`, `reads.json`, the index and the provenance naming it; its child ended (`Z`) inside the stall | 1 run: both oracles passed; all 4 stalls of a `hold` child (2 `drained`, 2 `timedOut`) ended with it running (`S`) |
| Rust `job_cancel_running` replay | an analyzer child of the replay appears | 5 runs passed; the child ended (`Z`) in all 7 stalls, 2 of them `drained`'s | 5 runs passed; in 4 the stall caught `drained`'s `hold` child, running (`S`) when each stall ended |
| Rust `job_run` replay | a `sleep` runs below (the `timedOut` child) | 5 runs passed; the child ended (`Z`) in all 5 stalls | 5 runs passed; the `hold` child running (`S`) at the end of all 5 stalls, then timed out as recorded |
| `check-job-run.py` | a `sleep` runs below the harness | 2 runs passed: each stall came after the cancellation had reached the daemon (`gone`) | 2 runs passed, likewise |
| `check-job-run.py` | a daemon spawns the running Job's analyzer, before the harness sends `job.cancel` | 2 runs: 1 failed (`expected.runCancelled`: the running Job ended `failed`, `executionFailed`, its child having ended during the stall); 1 passed, its cancellation first | 2 runs passed, with a `hold` child running (`S`) at the end of a stall in each |

A `sleep` trigger never fired in 3 earlier runs of main's running-cancellation replay: its
cancellation lands within milliseconds of the spawn, before the child forks `sleep`, which is why
the spawn trigger was needed there. One-minute load averages were 7–79 on this 8-core host
throughout (other sessions' builds). Retained under `/private/tmp/xpa014-hold-evidence/`: the probe
(`stall_probe.py`, SHA-256 `d9f7ae7b…`), each run's summary and output under `probe/`, and their
index (`probe-index.json`, `1a1f9eb1…`).

## Unified local gate

`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`,
with `ARKDECK_PYTHON` on the SDD venv and the planner started from a scratchpad venv on Homebrew
Python 3.11 (its PyYAML 6.0) with jsonschema 4.26.0 installed from PyPI. Both runs were on
`8f402d2e`, this change before the gate result was added here, against merge base `af43c172`.

- r1 (`/private/tmp/xpa014-analyzer-hold-gate-20260914-r1.log`, SHA-256 `5aec1059…`), started after
  the driver's 20-minute wait at a one-minute load of 17: the common checks (planner and agent-PR
  workflow tests, SDD, catalog generator tests and `--check`) and the design-system tests passed; the
  full Swift lane failed in
  `RuntimeAgentExecutionContractTests.testCLIClientTimeoutAndConcurrentJobRunCannotCancelOrDuplicateTheJob`
  (`outcomeUnknown` is not `clientTimeout`, line 1176), so the Rust lane did not run. That test runs
  the real CLI with `agent run --timeout 400ms`, and the CLI bounds its whole client by that
  deadline: one that expires during the initial mutation-capable `agent.run` exchange, as a slow
  CLI start under load makes it, is reported `outcomeUnknown`, and only one that expires in the later
  wait loop is `clientTimeout`. The test touches nothing this change does, and it passed alone 3 of 3
  (0.63 s each, at one-minute loads of 31–57). It is filed separately.
- r2 (`/private/tmp/xpa014-analyzer-hold-gate-20260914-r2.log`, SHA-256 `d63702d8…`), started at once
  at a one-minute load of 17: `gate exit=0`. The planner classified 115 changed files and selected the
  common, design-system, Swift and Rust lanes (no App build). The common and design-system checks
  passed as in r1. Swift full lane: `full-parallel` 2,662 tests exit 0, `full-process-identity-race`
  1 test exit 0, `full-viewer-scale` 5 tests exit 0. Rust lane: `cargo fmt --check`, warnings-denied
  Clippy, the workspace tests, the contract-check tests, `check-contracts.py` with the macOS façade
  test, `cargo deny` (advisories, bans, licenses and sources ok) and `cargo vet` (36 fully audited)
  all passed.

## Not run, and why

- The Swift probe ran once per side: each run rebuilds the test bundle in the shared SwiftPM cache,
  and main's side needed main's test source put back first.
- The harness still skips the timeout lane: `hold` is never released there, and both daemons compose
  the 30 s production budget.
- The undrained-group and raced-completion lanes stay unexercised, as before.
- No device; DAYU200 is not attached to this host.
