# TASK-XPA-025 — durable Journal append and complete event drain

This adds only the existing I.2 host-fixture legs: opt-in `arkdeck-soak
--measure-journal ROOT`, `bench capture --journal-samples N --journal-only`,
consumer validation, comparison identity and tests. No production writer,
pagination cap, protocol, App, CLI or device behavior changes. Existing recovery
seeds remain byte-compatible; the new fixture has its own version and the event
session identity required by the production read API.

One fresh root contains one Job and exactly 1,000 actual events. Per-event timing
brackets production JournalWriter.append through synchronous durable return;
construction/report writes are outside that interval. All attempts are emitted,
including a failed append. Bounded original stdout/stderr, complete lengths and
hashes, return code/timeout are archived before parsing, retaining valid prefixes
and malformed trailing fragments. Input event count/sequence/bytes/hash and
durability are recorded before starting the daemon.

`job.eventsDrain` includes contract handshakes, actual page requests and complete
client validation; report I/O and projection byte counting occur after timing.
It validates page contract, stable revision, every ID/position, advancing string
cursors (including the terminal page's cursor), completion and unchanged journal.
The production byte cap yields 3 pages in the actual integration. This does not
meet or replace `job.eventsPage`'s 1,000-row single-page target or its 50 ms budget.
Its gap remains explicit. No threshold is relaxed and no I.4 scenario is added.

## Local targeted checks

- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0,
  `/private/tmp/arkdeck-journal-fmt.log`.
- `CARGO_TARGET_DIR=/private/tmp/arkdeck-xpa025-journal-target CARGO_BUILD_JOBS=2
  cargo clippy --locked --manifest-path rust/Cargo.toml -p arkdeck-soak
  --all-targets -- -D warnings`: exit 0, 13.25 s,
  `/private/tmp/arkdeck-journal-clippy.log`.
- Same target/jobs, `cargo test --locked --manifest-path rust/Cargo.toml
  -p arkdeck-soak`: exit 0, 8 tests (2 library, 6 integration),
  `/private/tmp/arkdeck-journal-rust-test.log`.
- `PYTHONPATH=scripts python3 -m unittest discover -s scripts/bench -t scripts`:
  exit 0, 184 tests, 2 optional previous recovery integration tests skipped;
  `/private/tmp/arkdeck-journal-python.log`. Those two were separately passed
  on the pinned current-main release, recorded in the diagnostic run record.
- `sh scripts/check-sdd.sh` and `git diff --check`: exit 0;
  `/private/tmp/arkdeck-journal-sdd.log`. No full local unified gate.

Actual functional integration invoked `bench capture` with the pinned release
agentd and the new Debug soak, `--runtime-kind rust --journal-only
--journal-samples 1 --runs 3 --calibration-samples 10 --build-configuration debug
--allow-loaded-host`. Exit 0; each run verified 1,000 append observations and
1,000 events across 3 pages, with an unchanged 267,954-byte journal. All roots and
daemons exited. This mixed-configuration, load-waived check is **not a formal
performance capture**: baselineEligible is false, and its numeric values do not
establish product budget compliance or a new baseline.

The full advisory JSON and lossless gzip of every raw observation are archived
beside this record. `rust-journal-inputs-20260927.json` identifies exact tested
source bytes and the uncompressed raw hash; binary hashes are in the output.
The old fixed-input diagnostic attempts 1 and 2 are also retained, including
guard refusals and the first cold-start outlier. No samples were selected away.

## CI

Pending this implementation PR. The previous capture-fix PR #2274 was reviewed
and merged separately; its CI is not claimed for this new Rust fixture. Formal
quiet three-run cold/RSS and Journal baseline qualification remain incomplete.
TASK-XPA-025/G5 is not declared complete.
