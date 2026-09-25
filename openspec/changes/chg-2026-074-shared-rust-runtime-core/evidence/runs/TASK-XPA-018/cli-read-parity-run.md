# TASK-XPA-018 — Job reads and device-wait names judged as Swift's CLI judges them (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This slice is the CLI parity the hub queued
after the workspace continuation. It gathers two gaps that slice found and
two fragile tests S26 found. Base: `main` `02bd0bb98`, which is #2178 (the
continuation) merged after #2180 (`trace probe`). The slice was first pushed
stacked on the continuation, whose Job read check it shares, and was replayed
onto `main` once that merged. The checks below ran on the continuation's
head `a5530b353` and again after the replay (last rows).

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). Only
`arkdeck-cli` changes: no Runtime, control schema, corpus, Catalog, Swift,
`openspec/contracts`, `openspec/specs` or constitution change.

## What changes

- **One Job read check, Swift's.** `job_resources` now holds Swift's
  `CLIJobReadValidation` for a status, a `job.show` projection and a Job's
  timeline, in its order and words. They are the functions the continuation
  slice ported, moved here. Every Job read uses them: `job status`, `job
  show`, `job run`'s answer, `job result`'s Job, each `job list` row (status,
  then timeline, then order) and the continuation. Before, the leaves had a
  check of their own.
  - A status whose next action needs a person now reads, as Swift's read
    does; its next action names the human action. The old check refused it
    as `recordUnreadable`.
  - A status that needs a reconciliation, and a failed `debug.hap` awaiting
    finalization, read as before. Swift's `validatedObservedJobStatus`
    returns normally for the latter and leaves `resultNotReady` to the waits
    that call it. This CLI's shared `observed` raises that refusal itself (for
    `job wait`), so the read check lets exactly that one through as well.
  - A status, projection or timeline that is refused is now refused in
    Swift's words, for example `Job status does not match its closed read
    schema`, `Job status carries an unreadable Session publication`, `Job
    status has no supported next action` and `unknown Job timeline
    projection`. Before, every one of them was `Runtime returned an invalid
    read-only resource`.
- **`device wait` keeps a decomposed display name.** Swift's `CLIDeviceWait`
  compares the name with its precomposed form using String `==`. That is
  canonical equivalence, so the comparison never refuses. The Runtime's
  `valid_host_text` keeps such bytes too. This CLI compared bytes and refused
  them; it now applies only the three checks that do refuse (trimmed,
  1…256 UTF-8 bytes, no control characters).
- **The two shared-deadline tests outlast the exchanges they cover**
  (`tests/read_only_resources.rs`, S26). They hold that one `--timeout`
  covers both `health` and the query. Before, a 2 s budget and replies
  1.2 s after each request left 0.8 s for everything after the deadline
  started: connecting and the Runtime's own lag. The fake Runtime now
  answers `health` 2.5 s and the query 2 s after each arrives, against a
  4 s budget:
  - the two together always outlast the budget;
  - each alone fits, so a budget per exchange would pass the query and fail
    the test;
  - `health` has 1.5 s to spare.

  As #2174 did, the fake Runtime stops when the CLI closes the connection,
  and no assertion changes.

## How reachable the read change is

The published `job.status`, `job.show` and `job.list` schemas do not admit a
human action's next-action members (`resumeReference`, `expiresAt`). This
CLI checks every answer against its method's schema before it reads it, so a
person-waiting status is still refused at that step today. The check itself
now agrees with Swift, as the continuation oracle already holds: its
`waitingForHuman` and `acceptedWaitingForHuman` cases read through it. It
will read such a status once the contract admits one. The words of the other
refusals, and the finalizing status, are reachable now; the recorded
`job.status`, `job.show` and `job.list` frames include a finalizing
`debug.hap` Job.

## Tests

| Test | What it holds |
| --- | --- |
| `job_resources::tests::a_status_whose_next_action_needs_attention_reads_as_swift_reads_it` (new) | A person-waiting status, an unknown outcome and the recorded finalizing `debug.hap` status all read; `observed` still refuses the finalizing one for the waits |
| `job_resources::tests::a_malformed_status_is_refused_in_swifts_words` (new) | An outcome that disagrees with its state, a forged publication, a false next action and a person-waiting status without the human action, each in Swift's words |
| `device_wait` unit (extended) | A decomposed display name is proved as it was published |
| `tests/workspace_continuation.rs` (unchanged) | The continuation's 87 sources and 23 resolved Jobs replay through the moved check exactly as Swift answered them |
| `tests/read_only_resources.rs` (two re-timed) | One budget for `health` and the query: a client timeout after both requests, with no snapshot emitted and no replay |

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-rp-fmt.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`arkdeck-rp-clippy.log`) |
| CLI tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0: 291 passed, none failed (`arkdeck-rp-test.log`) |
| The re-timed tests, repeated | the two `timeout_is_shared` tests, 5 times in a row (load about 2) | 5 of 5 passed, about 4.9 s each (`arkdeck-rp-repeat.log`) |
| The margin, probed | `health` answered 1 s later than its delay, 3 runs each; the test file restored by digest | old timings (2 s; 1.2 + 1.2 s): both tests fail 3 of 3. New timings: both pass 3 of 3 (`arkdeck-rp-probe2.log`). A first probe delayed the fake Runtime's `accept` by 900 ms instead: that overlaps the CLI's own start, which precedes its deadline, so both timings passed (`arkdeck-rp-probe.log`) |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv) | `PASS`, exit 0 (`arkdeck-rp-readonly.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 (`arkdeck-rp-sdd.log`) |
| After the replay onto `02bd0bb98` | fmt, clippy and `cargo test --no-fail-fast -p arkdeck-cli` again | exit 0 each: 294 passed (with `trace probe`'s three), none failed (`arkdeck-rp2-*.log`) |

Not run, because no input they read changed: `generate-contract.py --check`
and the Swift tests.

## CI

- First push (head `4ddcb108a`, stacked on #2178): `guard` (run
  `36105331115`) and `swift` (run `36105331384`) passed. `swift-tests` and
  all four Rust lanes passed.
- #2178 after its replay (head `2039e7bb9`): `guard` (run `36105283553`) and
  `swift` (run `36105283789`) passed, and so did `swift-tests` and all four
  Rust lanes. It merged as `02bd0bb98`.
- #2180, `trace probe` (head `fb79f59d4`): `guard` (run `36106060616`) and
  `swift` (run `36106060887`) passed, and so did all four Rust lanes.
  `swift-tests` was not selected. It merged as `03be6f886`.
- After this replay onto `02bd0bb98`: pending.
