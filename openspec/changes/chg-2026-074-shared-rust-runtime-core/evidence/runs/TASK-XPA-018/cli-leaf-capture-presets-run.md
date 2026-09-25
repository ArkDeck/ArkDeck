# TASK-XPA-018 — the capture preset leaves on the Rust CLI (macOS, 2026-09-26)

TASK-XPA-018 remains in progress. Base: protected main (no stack). This PR adds no `tasks.md`
line (the coordinator's ruling of 2026-09-26). Slice C5. Nothing here is device evidence
(POL-VERIFY-001, POL-MODE-001). No control schema, corpus, Catalog, `openspec/contracts`,
`openspec/specs` or constitution change. Host evidence only: a fake Runtime answering Swift's
recorded executor runs.

## What changes

- **`arkdeck screen capture`**, **`ui-dump capture`**, **`ui-dump component-detail`**,
  **`debug logs`** and **`trace capture`** join the other domain leaves in Swift's one handler
  (`runDomainOperation`, #2208/#2212), each over the registry's `capture.diagnostics@1`. What sets
  them apart is Swift's `RuntimeCLI.capturePresetExecutionRequest`, ported in
  `rust/crates/arkdeck-cli/src/domain_leaves.rs` (`preset`): the leaf submits a fixed,
  product-owned set of inputs (`DiagnosticCapturePreset`) in place of the caller's, built from the
  few fields that preset accepts, each held to its type and range, and the identifier, category
  and HiLog component grammars (`DebugTypedValueValidator.isSafeHilogComponent`: grapheme
  clusters, each scalar in Foundation's `alphanumerics` or one of `._:-`). A refusal is
  `invalidInput` in Swift's words, before any connection. Everything else — the target, a named
  capability forwarded as its reference, the execution identity, the wait — is the caller's, as
  for any domain leaf.

## Oracle and tests

- `CLICapturePresetOracleContractTests` (Swift) calls `RuntimeCLI.capturePresetExecutionRequest`
  for 55 cases and records the inputs each preset submits, or the words of its refusal, to
  `rust/tests/fixtures/capture-presets`: each preset's accepted shape, each field's type and
  range, a field the preset does not accept, and the grammar boundaries (ASCII and Unicode).
- `tests/domain_leaves.rs` (`a_capture_preset_submits_swifts_preset_inputs`) replays every case
  through the CLI: an accepted case runs a recorded device capture whose submitted inputs are
  exactly the preset's, never the caller's; a refused case answers Swift's refusal with nothing
  sent.
- `argv_fixtures.rs` replays Swift's argv fixtures for the five leaves (zero deviations).

## Declared differences

- Off macOS, where Swift has no CLI and CoreFoundation's character table is not linked, a scalar
  of a HiLog component is alphanumeric as Rust classifies it.

## Counts

- Rust CLI leaves answered: +5, all ported.
- `cli-parity-audit.py`, registry leaves not served: category 2 (leaf missing, daemon routed) −5.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cli-lane-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --locked --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D
  warnings` — exit 0; also with `--target x86_64-pc-windows-msvc` and `--target
  x86_64-unknown-linux-gnu` — exit 0 each.
- `cargo test --locked --manifest-path rust/Cargo.toml -p arkdeck-cli` — exit 0
  (`/private/tmp/arkdeck-cli-lane-presets-final-test.log`).
- `python rust/scripts/check-readonly.py --bin-dir /private/tmp/arkdeck-cli-lane-rust-target/debug`
  (validation venv) — exit 0, `PASS`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter CLICapturePresetOracleContractTests`
  — exit 0 (recording, in the hub's Swift window; `/private/tmp/arkdeck-cli-lane-swift-presets.log`).
  The comparison run against the checked-in oracle is left to CI's Swift lane.
- `sh scripts/check-sdd.sh` — exit 0.

## CI

Pending; recorded by the next slice.
