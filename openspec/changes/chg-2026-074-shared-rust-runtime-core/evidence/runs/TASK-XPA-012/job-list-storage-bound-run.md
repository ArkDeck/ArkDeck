# TASK-XPA-012 — the Job list's own storage bound, as Swift's Job owner keeps it (macOS, 2026-09-26)

TASK-XPA-012 remains in progress. Base: protected main `e58dda2bb` (after #2243 and #2246; no
stack). This PR adds no `tasks.md` line (the coordinator's ruling of 2026-09-26). Nothing here is
device evidence (POL-VERIFY-001, POL-MODE-001). No control schema, corpus, Catalog,
`openspec/contracts`, `openspec/specs` or constitution change. The daemon crate is touched at the
hub's assignment (2026-09-26).

## What changes

Swift's Job owner adds up the canonical bytes of the history rows a `job.list` query keeps and,
past 16 MiB, refuses the query before its pager sees a row:
`operationUnavailable`, `Job snapshot exceeds its storage bound; narrow the query`
(`RuntimeJobEngine.swift` `jobListSnapshot`, 5276-5278), an `AgentExecutionControlFailure` its Job
read handler answers with `{"phase":"preAdmission","newDispatchCount":0}`. The Rust list had no
such check, so the shared pager's own bound answered, in the pager's words
(`snapshot exceeds its storage bound`). `job_owner.rs` now counts the canonical bytes of each kept
row as it streams them, stops handing rows to the pager past the bound, and refuses in Swift's
owner's words and details once the scan is complete. Rows the query leaves out, and timelines the
query does not include, do not count, as in Swift.

## Declared difference

Swift meets the rows in SQLite's unordered read of `runtime_job` and throws at whichever comes
first there: an unreadable record or the running total passing the bound. The Rust list reads the
rows in the list's order and already answers the first record refusal in creation order after a
complete scan (TASK-XPA-025); it keeps that rule and lets a record refusal outrank the bound. When
both occur, the two answers can differ; each is a refusal with zero dispatch.

## Tests

- `job_list_stream_tests.rs` `a_job_list_past_its_storage_bound_is_refused_as_swifts_owner_refuses_it`:
  eighty Jobs of about 250 KB each (timelines still inline) — the list with timelines is refused in
  Swift's owner's code, words and details, in both orders; without timelines, and for each
  forty-Job state filter with timelines walked through every page, the list answers every row; an
  unreadable record's refusal outranks the bound. No Swift recording exists (a Swift oracle would
  need over 16 MiB of Jobs); the expected answer is taken from Swift's source.
- Negative control: with the old `job_owner.rs` the test fails on the pager's words
  (`snapshot exceeds its storage bound`); code and details were already Swift's.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cli-lane-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --locked --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd
  --all-targets -- -D warnings` — exit 0; also with `--target x86_64-pc-windows-msvc` and
  `--target x86_64-unknown-linux-gnu` — exit 0 each.
- `cargo test --locked --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd` —
  exit 0 (`/private/tmp/arkdeck-cli-lane-b1-test.log`).
- `sh scripts/check-sdd.sh` — exit 0.

## CI

Pending; recorded by the next slice.
