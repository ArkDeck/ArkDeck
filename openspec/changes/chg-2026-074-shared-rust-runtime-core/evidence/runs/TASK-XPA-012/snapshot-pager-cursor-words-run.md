# TASK-XPA-012 — the shared snapshot pager's cursor refusals in Swift's words (macOS, 2026-09-26)

TASK-XPA-012 remains in progress. Base: protected main `82706393d` (after #2243; no stack). This PR adds no `tasks.md`
line (the coordinator's ruling of 2026-09-26). Nothing here is device evidence (POL-VERIFY-001,
POL-MODE-001). No control schema, corpus, Catalog, `openspec/contracts`, `openspec/specs` or
constitution change. The daemon crates are touched at the hub's assignment (2026-09-26).

## Survey

A read-only survey (2026-09-26) listed every Runtime method that pages through the Rust shared
pager (`rust/crates/arkdeck-hoststore/src/snapshot_pager.rs`), `import.list` excepted (the import
parity slice owns it): `human-action.list`, `control-action.list`, `recovery.flash-invocation.list`,
`agent.list`, `job.list`, `job.timeline`, `session.list`, `artifact.list`, `runtime.tool.list` and
`runtime.bundle.list`. For each, a cursor of the wrong shape, of another query, of a reclaimed
snapshot, and the storage bound, against Swift's recorded answer (ControlFrames) or source.

- Swift's `RuntimeSnapshotPager` refuses every such cursor with one sentence,
  `cursor is invalid, belongs to another query or its snapshot was reclaimed`
  (`RuntimeSnapshotPager.swift:112-113`), and no Swift owner rewords it; its bound messages are
  lower-case (`:75`, `:84`, `:95`). The Rust pager capitalised all four and added a comma.
- Swift's pager carries no details; each daemon handler adds its own. The Rust pager's default
  (`phase: sessionOwner`) is right for `session.list`, which passes it through; the other owners
  stamp their own. The default is unchanged.

## What changes

- `snapshot_pager.rs`: the invalid-cursor sentence and the three bound messages are Swift's.
- The four owners that rewrote the pager's cursor refusal back to Swift's sentence
  (`human_action.rs`, `agent_execution.rs`, `control_action.rs`, `flash_invocations.rs`) no longer
  need to; they keep stamping their own details.
- `job_owner.rs`, for `job.list` and `job.timeline`: a cursor that is not a bounded string is
  refused in Swift's words (`cursor must be a bounded snapshot token`,
  `RuntimeJobReadProjection.swift:36-39`), and a page size out of range, a malformed cursor and
  every refusal the pager stamps as its own carry Swift's Job read handler details
  `{"phase":"preAdmission","newDispatchCount":0}` (`RuntimeJobResourceReader.swift:84-88`). The
  rows' own refusals (an unreadable record) pass unchanged, as Swift's engine errors do.
  `job.events` keeps its own malformed-cursor words; its page-size refusal gains the same details.
- `arkdeck-control`, `runtime.tool.list` and `runtime.bundle.list`: the argument checks are
  Swift's, in its order and words — only `pageSize` and `cursor` (`<noun> list accepts only
  pageSize and cursor`), then `pageSize must be an integer`, then `cursor must be a string`
  (`AgentDaemon.swift:2829-2848`, `:2874-2893`); it was one combined sentence.

## Tests

- `snapshot_pager.rs` `a_foreign_or_reclaimed_cursor_is_refused_in_swifts_words`: a cursor of
  another query and one whose snapshot is gone, each equal (code, message, details) to Swift's
  recorded `session.list` answer (ControlFrames `session.list.jsonl`, line 1).
- `job_list_stream_tests.rs` `the_job_reads_refuse_a_cursor_as_swifts_handler_does`: `job.list`
  with an empty cursor, a page size of 0, a cursor not of the pager's shape and another query's
  cursor; `job.timeline` with an empty cursor, a cursor not of the pager's shape and a list's
  cursor — each equal to Swift's recorded answer (`job.list.jsonl` lines 3, 13, 54, 27;
  `job.timeline.jsonl` lines 12, 13, 9). Two mutations (the old Job cursor words; the old pager
  sentence) each fail it.
- `arkdeck-control` `read_only.rs`: each refusal of both registry lists in Swift's words and
  order, with the registry owner's details, including an argv that fails two checks.
- The pager's own bound tests (`snapshot_pager_tests.rs`) now expect Swift's lower-case words.

## Listed, not changed here

- `job.list` lacks Swift's owner-side storage check (`Job snapshot exceeds its storage bound;
  narrow the query`, `RuntimeJobEngine.swift:5276-5278`) — the next slice, on the Job owner.
- `human-action.list` builds its rows only for a first page, where Swift builds and validates
  them for every request (`RuntimeHumanActionResourceCoordinator.swift:77-97`), so a row refusal
  outranks a cursor refusal in Swift — a following slice.
- `job.list`'s filter refusals (`state`, `order`, `includeCurrent`, …) also lack Swift's
  pre-admission details.
- `artifact.list` shares the Job owner's snapshot directory (lane A, S37).

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cli-lane-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --locked --manifest-path rust/Cargo.toml -p arkdeck-control -p arkdeck-hoststore
  -p arkdeck-agentd --all-targets -- -D warnings` — exit 0; also with `--target
  x86_64-pc-windows-msvc` and `--target x86_64-unknown-linux-gnu` — exit 0 each.
- `cargo test --locked --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd` —
  exit 0 (`/private/tmp/arkdeck-cli-lane-pager-test.log`); `-p arkdeck-control -p arkdeck-agentd`
  — exit 0 (`/private/tmp/arkdeck-cli-lane-pager-control-test.log`).
- Rebased onto `82706393d`: `job_owner.rs` merged by hand, keeping #2243's epoch projection in
  `job.list` beside this slice's cursor checks. Replays rerun after the merge: `-p
  arkdeck-hoststore --test flash_run` (12 passed), the `job.list`/`job.timeline` corpus replays in
  the `-p arkdeck-hoststore` library tests, and `-p arkdeck-control` `read_only` — exit 0 each.
- `sh scripts/check-sdd.sh` — exit 0.

## CI

Pending; recorded by the next slice.
