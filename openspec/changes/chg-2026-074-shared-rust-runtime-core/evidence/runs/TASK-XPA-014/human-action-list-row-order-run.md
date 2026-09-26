# TASK-XPA-014 — human-action.list validates its rows before its cursor, as Swift does (macOS, 2026-09-26)

TASK-XPA-014 remains in progress. Base: protected main `e58dda2bb` (after the shared pager slice, #2246; no stack).
This PR adds no `tasks.md` line (the coordinator's ruling of 2026-09-26). Nothing here is device
evidence (POL-VERIFY-001, POL-MODE-001). No control schema, corpus, Catalog, `openspec/contracts`,
`openspec/specs` or constitution change. The daemon crate is touched at the hub's assignment
(2026-09-26).

## What changes

Swift reads and validates every owner's rows for each `human-action.list` request, a cursor's too,
before its pager judges the cursor (`RuntimeHumanActionResourceCoordinator.swift:77-97`). The Rust
owner built its rows only for a first page, so with an unreadable execution record a cursor request
was refused as `invalidCursor` where Swift answers the record's refusal. `human_action.rs` now
builds and checks the rows (agent rows, control rows, the duplicate-owner check, the order) before
paging, for every request; the error mapping is unchanged.

## Tests

- `control_action_approval.rs` `a_row_refusal_outranks_a_cursor_refusal`: a foreign cursor is
  `invalidCursor` while the records are readable; once an execution record is unreadable, a first
  page and the same cursor request get the same refusal (`recordUnreadable`, pre-admission
  details). Negative control: with the old `list()` the test fails
  (`invalidCursor` where `recordUnreadable` is expected).

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cli-lane-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --locked --manifest-path rust/Cargo.toml -p arkdeck-hoststore --all-targets -- -D
  warnings` — exit 0; also with `--target x86_64-pc-windows-msvc` and `--target
  x86_64-unknown-linux-gnu` — exit 0 each.
- `cargo test --locked --manifest-path rust/Cargo.toml -p arkdeck-hoststore` — exit 0
  (`/private/tmp/arkdeck-cli-lane-b2-test.log`).
- `sh scripts/check-sdd.sh` — exit 0.

## CI

Pending; recorded by the next slice.
