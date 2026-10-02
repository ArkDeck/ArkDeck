# TASK-XPA-018 — publish artifact.export's sensitive-content refusal (2026-10-01)

- **Kind:** host-only contract fix, on the Windows 11 x64 reference host. No hdc was run and the
  DAYU200 was not touched.
- **Base:** protected `main` `bdf96c09` (#2424).
- **Found by:** measuring `diagnostics export` on Windows (#2431, `windows-non-hdc-leaves-run.md`).

## The defect (every host)

`artifact.export` of a sensitive Artifact without `allowSensitive` is refused by the Artifact
owner:

- code `sensitiveAccessDenied`;
- details `{phase: artifactOwner, newDispatchCount: 0}`.

Swift's `RuntimeArtifactResourceHandler` answered the same code (#1663,
`RuntimeArtifactError.sensitiveAccessRequiresOptIn`), and its tests expected it for `artifact
export` as for `artifact read`. Only the read's refusal was ever recorded, though. So
`spec/control/methods/artifact.export.json` does not list the code, and the control layer
replaced the refusal with `internalError` "the result does not conform to the current contract".

This affects `artifact export`, `trace export` and `diagnostics export` of a sensitive Artifact
without the permission, on macOS and on Windows. Measured on Windows over the real daemon: over
the pipe the answer was that `internalError`, while the owner in process answered
`sensitiveAccessDenied`. The CLI's failure mapping already maps the code for the Artifact owner
(`OWNER_REFUSALS`), so nothing changes there.

## Generated, not hand-edited

`Packages/ArkDeckKit/Scripts/generate-control-contract.py` gains
`ARTIFACT_EXPORT_OWNER_ERROR_CODES`, joined to `artifact.export`'s codes like the other owner
vocabularies (#2370, #2382, #2389).

- It lists `sensitiveAccessDenied`, the missing code.
- It also lists `artifactIntegrityFailed` and `operationFailed`. The published schema already
  lists both (from recordings the committed corpus no longer selects), and the owner still
  answers them (`export_error`). Without them, deriving from the committed corpus would drop
  them.

Steps:

1. `generate-control-contract.py --derive-method-schemas` was run over the committed
   `ControlFrames/artifact.export.jsonl` only (6 frames).
2. The resulting diff was checked:
   - `artifact.export` gains `sensitiveAccessDenied`, and no code is removed;
   - `x-arkdeck-sampleCounts` moves to the committed corpus's counts (error 7 → 4, request
     9 → 6), the same drift as #2370, #2382 and #2389, since the Swift recorder is gone;
   - nothing else changes.
3. `generate-contract.py --write` refreshed `spec/baselines/swift-single-v1.json`.
4. `windows/scripts/generate-clientkit.py --write` refreshed `ControlContract.g.cs`.
5. The line-ending-only rewrites (the Swift protocol file, the corpus file) were restored, and
   the output is LF.
6. Every generator's `--check` passes.

## Test

`rust/crates/arkdeck-hoststore/tests/artifact_export_sensitive_refusal.rs` is new and portable;
it runs on macOS and Windows. It uses the recorded `capture.diagnostics@1` Job's Artifacts
(`capture-diagnostics-trace`):

- the sensitive Trace's export, with `allowSensitive` absent or false, is refused
  `sensitiveAccessDenied` with `{phase: artifactOwner, newDispatchCount: 0}`, and nothing is
  exported;
- the code and the details validate against `artifact.export`'s published schema;
- with the permission, the Trace is exported; the standard summary is exported without it. Both
  receipts validate and carry the recorded bytes.

Negative control: with main's `artifact.export.json` the test fails at the code's validation.

check-contracts' published view compiles this build against the merge base's contract, which
does not publish the code. There the test skips only that one validation, as `host_tests.rs`
does for the Trace cache purge's code.

## Checks

See the commit message for the local results.
