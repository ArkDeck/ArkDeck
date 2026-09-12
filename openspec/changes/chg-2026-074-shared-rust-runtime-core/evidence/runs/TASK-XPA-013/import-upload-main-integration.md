# Import upload after the published Export integration — 2026-09-12

This candidate merges frozen Import `37cb41e6ad62a54c576670a9ba10b02b01cd4930` with published main `4e2a615e421e6174a4a50e2c8110196d77ce7007`, retaining both histories. Worktree: `/private/tmp/arkdeck-xpa013-import-upload-main-20260912`; branch: `agent/xpa013-import-upload-main-20260912`. The original Import worktree and branch were not changed while the parent ran their full gate.

## Merge decisions

Seven conflicting files were resolved by preserving both owners. Shared CLI routing, error provenance, help text and imports retain the main Export behavior and the Import bounded recovery behavior. The control unsupported-method regression excludes both configured method families. Hoststore/platform module exports retain both implementations. Task013 keeps main's already-approved Export/manifest entries and adds only the six precise Import schema paths. The manifest was regenerated from the merged checkout with `python3 rust/scripts/generate-contract.py --write`, without a baseline-revision override.

The main Export publication/read source files and CLI artifact implementation were compared directly to the merge parent and remain unchanged. The Import upload owner, platform staging implementation, CLI recovery implementation, Target binding reader and daemon composition were compared directly to frozen `37cb41e6` and remain unchanged. No files were replaced wholesale with an older candidate version, and no dependency or toolchain change was introduced by the Import diff.

The delivered scope remains begin/append/progress inspect/abort through the existing typed owner, including new uploads bound by the real TargetStore. The published Export implementation is inherited from main. HAP publication prototype `708dab9a` remains outside this PR. Commit, release, Job-reference inspection and HAP/native-library canonical-alias routes still return explicit unavailability until their complete owners are composed. Unknown commit responses are inspected once and never replayed. This phase does not activate the installed owner or complete Task013/hardware/GJ acceptance.

## Validation of this merged tree

The following batch ran with `CARGO_BUILD_JOBS=2` from the new candidate's `rust` directory and completed with exit 0 (tool session `60584`):

```sh
cargo test -p arkdeck-hoststore --test import_target --test import_upload --test artifact_read_owner
cargo test -p arkdeck-contract --test imports
cargo test -p arkdeck-cli
cargo test -p arkdeck-control --test read_only
cargo clippy --workspace --all-targets -- -D warnings
cargo build --workspace --bins
python3 scripts/check-import-upload-owner.py
cargo fmt --all --check
python3 scripts/generate-contract.py --check
```

Results: **145 passed**, comprising 24 Artifact read/export owner tests, 4 native Target integration tests, 13 Import upload tests, 5 Import contract tests, 84 CLI tests (including Export/Target/events and Import) and 15 Control tests. One explicitly ignored SIGKILL helper entry point is invoked by its parent test; all five actual upload SIGKILL windows asserted signal 9 and passed.

Workspace all-target Clippy with warnings denied, all workspace binaries, formatting and generator checks passed. Generator result: 105 methods, 599 recorded shapes, unchanged control contract identity `1d7d101e83fe...`.

The real daemon/CLI harness passed: native upload and Target fixture compatibility, new upload through the existing direct Target binding, different physical/route digests, one dropped successful append response, bounded same-request inspection/resume, restart, source identity change refusal, abort tombstones, missing Target/canonical-alias refusal, and explicit unavailable publication/reference seams. The CLI Export tests retained its one-send unknown/malformed-response behavior after the shared dispatch/error merge.

Raw log: `import-upload-main-integration-rust.log`; SHA-256 `21ea7c16a36e598abd48db226ee392c631b7de7e34db53dbf86a1b4095456adf`. Earlier native producer byte/source proofs are retained under `native-import-producer-macos-20260912` and `rust/tests/fixtures/import-target-current`; no native evidence was regenerated, fabricated or relabeled as a new Swift run in this integration.

## Remaining parent-owned final steps

The final scope declaration contains exactly six existing Import schema paths: `spec/control/methods/artifact.import.begin.json`, `.append.json`, `.abort.json`, `.inspect.json`, `.inspection.json`, and `.release.json` (each expanded to its full filename in the commit trailers). Main already authorizes `spec/baselines/swift-single-v1.json`; it is therefore omitted from new Scope-Extension declarations. Final scope preflight runs against the current main after the local merge commit.

No Swift/App build, unified full gate, push, PR creation or merge-to-main was performed by this subtask. The parent schedules the new candidate's final full gate separately; the original worktree's result must not be presented as a gate on this merged tree.
