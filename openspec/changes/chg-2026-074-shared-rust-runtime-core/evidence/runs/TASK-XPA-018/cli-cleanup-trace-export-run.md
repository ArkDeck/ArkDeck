# TASK-XPA-018 — `recovery cleanup list`, `cleanup-debt list` and `trace export` (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This is the second slice of the Rust CLI's
batch 1 (G5 queue slice 14; the first part of b5, the read leaves). Base:
protected main `f8cef4c0` (#2170). No stack: #2171 (`job wait`) is
independent, and this slice keeps clear of its hunks. Once #2171 merged
(`a6294ec3`), the slice was rebased onto it. GitHub does not apply
`merge=union` to `tasks.md`, so a local rebase kept both bullets.

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). The Runtime
under test is the fake one the CLI tests serve recorded answers from. No
Swift source or test, control schema, corpus, Catalog, `openspec/contracts`,
`openspec/specs` or constitution change.

## What changes

- **`recovery cleanup list` and its deprecated `cleanup-debt list`.** Swift
  serves both spellings from one handler, `emitCleanupDebt`, "so the two
  spellings cannot start behaving differently". Each sends one
  `cleanupDebt.list` without parameters and prints the Runtime's answer. The
  deprecated spelling's machine answer carries `meta.lifecycle`, and its
  human rendering the warning on stderr. Both come from the registry through
  the CLI's existing lifecycle support.
- **`trace export --job <id> --artifact <id> --destination <dir>`.** Swift
  runs it as `runArtifactResource("export", …)` with four requirements. It is
  `artifact export` with a Job owner only. Before anything is exported, the
  inspected Artifact must be the one Trace a diagnostics capture publishes:
  - Its `sourceOperation` must be `capture.diagnostics@1`, else
    `invalidInput`, "selected Artifact does not belong to
    capture.diagnostics@1".
  - Its `name` must be `trace.htrace`, its `mediaType`
    `application/octet-stream` and its `privacy` `sensitive`, else
    `invalidInput`, "selected Artifact does not match the required typed
    resource".

  The export itself is the existing `artifact export`: its destination
  resolution, its one request and its receipt check.

The two Runtime methods were already served by the Rust daemon; the leaves
were the gap.

## Not in this slice

`ui-dump inspect|hit-test` and `diagnostics inspect|preview` are the rest of
b5. Each derives its answer locally from the Artifact bytes, through
ClientKit's `UIDumpOfflineInspector` (229 lines, with the CLI's derivation
around it) or `DiagnosticSessionOfflineInspector` (510 lines, with 536 lines
of CLI resources). They follow as their own slices.

## Tests

| Test | What it holds |
| --- | --- |
| `argv_fixtures.rs` | Swift's `recovery.cleanup.list.json`, `cleanup-debt.list.json` and `trace.export.json`, copied byte for byte: their 17 cases replay with no new deviation |
| `read_leaves.rs` `both_cleanup_spellings_list_the_debt_as_the_runtime_answers` | One `cleanupDebt.list` per spelling, Swift's recorded debt printed as answered; the deprecated spelling carries its lifecycle |
| `read_leaves.rs` `trace_export_exports_the_inspected_trace` | `artifact.inspect`, then one `artifact.export` with the resolved destination; the receipt printed |
| `read_leaves.rs` `trace_export_refuses_any_other_artifact_before_exporting_it` | Another capture's Artifact, another name, and a standard privacy: `invalidInput` with Swift's message, and no export request |

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-xpa018-read-fmt.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`arkdeck-xpa018-read-clippy.log`) |
| CLI tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0; 261 passed (`arkdeck-xpa018-read-test.log`) |
| Mutations | four, one at a time: the Trace requirement never called; the privacy requirement dropped; the source-operation requirement dropped; the deprecated spelling's method mapping dropped | each fails `read_leaves.rs`. Sources restored by digest, rebuilt, and rerun green (`arkdeck-xpa018-read-mutations.log`, `…-rerun.log`) |
| Audit | `cli-parity-audit.py <this build>` | 168 / 59 / 14 / 15, from main's 166 / 61 / 14 / 15; 129 of 209 leaves served (`arkdeck-xpa018-audit-read.md`). With #2171 as well: 169 / 58 / 14 / 15, 130 of 209 |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0 (`arkdeck-xpa018-read-sdd.log`) |

Not run, because no input they read changed:

- `generate-contract.py --check`: no contract input changed.
- The Swift tests: no Swift source changed.
- The other crates: `arkdeck-cli` has no dependents.

## CI

- This change: pending.
- #2170 (M4-3b, head `0de10a40`): guard run 36094721221 and swift run
  36094721456, both succeeded. Merged as `f8cef4c0`.
