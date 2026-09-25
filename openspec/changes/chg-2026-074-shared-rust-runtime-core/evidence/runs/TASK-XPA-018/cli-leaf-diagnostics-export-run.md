# TASK-XPA-018 — `diagnostics export` on the Rust CLI (macOS, 2026-09-26)

TASK-XPA-018 remains in progress. Base: protected main `f68e6c766` (#2209), with C0, C1, C6 and #2211 merged; no
stack. Per the coordinator's ruling of 2026-09-26, this PR adds no `tasks.md` line. The first leaf of slice C7. Nothing here is device evidence
(POL-VERIFY-001, POL-MODE-001). No Swift source or test, control schema, corpus, Catalog,
`openspec/contracts`, `openspec/specs` or constitution change. Host evidence only: a fake Runtime
answering Swift's recorded `artifact.inspect` exchange.

## What changes

- **`arkdeck diagnostics export --job <id> --artifact <id> --destination <dir> [--allow-sensitive]
  [--overwrite] [--timeout <duration>]`** is Swift's `runArtifactResource("export", command:
  "diagnostics.export", requiredSourceOperation: capture.diagnostics@1)`: `artifact.inspect` of
  the selected Artifact of the Job, the check that `capture.diagnostics@1` published it, then
  `artifact.export` to the caller's explicit destination directory, the Runtime's receipt emitted
  as given. It is `trace export` without that leaf's name, media type and privacy pins: any
  Artifact the capture published (the hilog, the screenshot, the Trace…) is exportable, and one of
  another operation is refused (`invalidInput`, exit 65) before anything is exported. Sensitive
  content still needs `--allow-sensitive`, which the Runtime owner judges; the destination is only
  ever the caller's.
- The coordinator's earlier ruling tied this leaf to Q5 (the Support Bundle writer moving to
  ClientKit) and a §12 tombstone. Swift's leaf is not the Support Bundle, so the coordinator
  withdrew that ruling (2026-09-26) and the leaf is ported as Swift has it.

## Tests (`tests/read_leaves.rs`)

- `diagnostics_export_exports_any_artifact_the_capture_published`: a hilog and a Trace of a
  diagnostics capture (Swift's recorded published Artifact, relabelled), each inspected then
  exported with exactly the recorded parameters and the receipt emitted.
- `diagnostics_export_refuses_an_artifact_of_another_operation_before_exporting_it`: an Artifact
  of `observe.device@1`: the fake Runtime answers only the inspection, so an export request would
  fail the test.
- `argv_fixtures.rs` replays Swift's argv fixtures for the newly served leaf (zero deviations).

Mutation check, baseline passing, each reverted after (`/private/tmp/arkdeck-cli-lane-mut-c7e.py`):
holding the leaf to the Trace's pins, and not checking the source operation. Each fails a named
test above.

## Counts

- Rust CLI leaves answered: 165/209 → 166/209, of which 155 → 156 ported and 10 answered by name
  (`blockedByProductDefect`, #2211).
- `cli-parity-audit.py` on this build, registry leaves not served: category 2 (leaf missing,
  daemon routed) 31 → 30, category 3 7, category 4 6.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-cli-lane-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` —
  exit 0; also with `--target x86_64-pc-windows-msvc` and `--target x86_64-unknown-linux-gnu` —
  exit 0 each.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli` — exit 0
  (`/private/tmp/arkdeck-cli-lane-c7e-test-all.log`).
- `python rust/scripts/check-readonly.py --bin-dir /private/tmp/arkdeck-cli-lane-rust-target/debug`
  (validation venv) — exit 0, `PASS`.
- `sh scripts/check-sdd.sh` — exit 0.

## CI

Pending; recorded by the next slice.
