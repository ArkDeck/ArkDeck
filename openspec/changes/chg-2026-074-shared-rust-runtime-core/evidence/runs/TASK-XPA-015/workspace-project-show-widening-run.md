# `workspace.project.show` publishes why an operation is unavailable (TASK-XPA-015, M3, contract)

A contract-input change only: `workspace.project.show`'s result now admits
text in `operations[].reason` and `operations[].reasonCode`, which the
published schema had as `null` only. The Swift daemon answers exactly that
shape for any active project whose composition could not offer an operation;
no Swift or Rust source changes, and nothing yet answers it on the Rust
daemon. The 枢纽 ruled the widening a contract PR of its own (枢纽受维护者委托
裁定（2026-09-25）, S28 contract list item 1), recorded with a Swift frame
that proves the shape exists, appended to the committed corpus, and
re-deriving this one method.

Base: protected `main` `f7a3b73f7` (#2195). No stack. The checks below ran on
the same change over `f97ec67b9` (#2194); the rebase brought only #2195 (Rust
sources and documents, no contract input), and the generated inputs were
checked again after it.

| Already on `main` | This change | Still remaining (M3) |
|---|---|---|
| `workspace.project.list`, whose rows already admit text in both members (the same Swift encoder); every workspace operation on the Rust daemon | One Swift test through the handler; one corpus line; the widened schema and the regenerated baseline | The Rust projection of `show`, `list` and the preset statuses and `operation.list`'s workspace rows (PR-D, which keeps `show`'s two members `null` until this lands); `agent.status` over a workspace or input Job (S28 contract list item 2, a separate change) |

## Why

`RuntimeControlPlaneHandler.encodeRegisteredWorkspaceProject` merges the
start-up `WorkspaceProjectPublication` of an active project into both `list`
and `show`, and `WorkspaceProjectPublication.make` gives every operation the
composition cannot offer its provider's code and reason (for example
`workspace_preset_unavailable` / `workspace.presetUnavailable` when the
project has no source control). `list`'s schema already admits them;
`show`'s was derived from a single active frame whose one operation was
available, so it published both members as `null`. The Rust control layer
rewrites an answer outside its method's schema to `internalError`, so a Rust
`show` of such a project — the projection PR-D ports — would be rewritten.

## The frame

`AgentDaemonContractTests.testAShownWorkspaceProjectSaysWhyAnOperationIsUnavailable`
is the existing `show` test's composition (the production handler over a
registered, applied project and its publication) with a second operation the
publication marks unavailable, as the `list` test already does. It asserts
both operations as answered: the available one with `null` members, the
unavailable one with `workspace_preset_unavailable` and
`workspace.presetUnavailable`.

Recorded with `ARKDECK_CONTROL_FRAME_LOG`: two frames, the existing test's
(already the corpus's line, verbatim) and the new one. The new frame is
appended to `ControlFrames/workspace.project.show.jsonl`; the seven committed
lines are kept verbatim and in order (7 → 8).

## The schema

Only `workspace.project.show` is re-derived, with the generator in an
isolated copy of its inputs (`scratchpad/s28/derive_one.py`):

- the committed corpus alone reproduces `main`'s schema byte for byte, sample
  counts included;
- the final corpus, and the committed corpus with both recorded frames, give
  the same `$defs`;
- a structural check (`scratchpad/s28/covers.py`) finds exactly two
  differences, both covered: `operations[].reason` and
  `operations[].reasonCode` from `"null"` to `["null", "string"]`; run the
  other way round it reports both as narrowings;
- no request, error code or error detail changes; the sample counts move to
  8 requests, 3 results, 5 errors.

Validated with jsonschema 4.26 (validation venv): `main`'s schema admits
`main`'s 7 corpus lines and refuses the new frame; the new schema admits all
8 corpus lines and both recorded frames.

`rust/scripts/generate-contract.py --write` refreshed
`spec/baselines/swift-single-v1.json` (105 methods, 1010 recorded shapes, 1009
before); the contract identity `1d7d101e83fe…` and the generated bindings are
unchanged. No product of the machine-contract bundle digests the method
schemas (`refresh-contract-digests.py --check` passes unchanged), and
`runtime-control-plane.schema.json` names the method schema by path, so no
Swift export is regenerated.

## Local targeted checks

Logs are `/private/tmp/arkdeck-s28-d0-*.log`.

| Check | Command | Exit and result |
|---|---|---|
| Recording | `ARKDECK_CONTROL_FRAME_LOG=<fresh> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'AgentDaemonContractTests/(testAShownWorkspaceProjectSaysWhyAnOperationIsUnavailable\|testARegisteredWorkspaceProjectShowsThroughTheControlPlane)'` | 0; 2 tests, 0 failures; 2 frames (`d0-record.log`) |
| Derivation and structural check | `derive_one.py` over the committed corpus, the final corpus, and the committed corpus with both frames; `covers.py` both ways | `main`'s schema reproduced; the same `$defs` both ways; exactly the two widenings, reported as narrowings when reversed |
| jsonschema 4.26 | `main`'s and the new schema over the corpus and the frames | `main`: 7/7 admitted, the new frame refused; new: 8/8 and 2/2 admitted |
| Affected Swift classes, new schema | `ARKDECK_CONTROL_FRAME_LOG=<dir seeded with the 2 frames> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter '(ControlMethodSchemaContractTests\|AgentDaemonContractTests/(…3 workspace tests…))'` | 0; 8 tests, 0 failures (`d0-swift-validate.log`) |
| Contract manifest and vocabulary | `python3 rust/scripts/generate-contract.py --write`, then `--check`; `python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --check`; `python3 rust/scripts/refresh-contract-digests.py --check` (all again after the rebase) | 0; 105 methods, 1010 recorded shapes; 0; 0 |
| Checkout, published and candidate views | `/private/tmp/arkdeck-validation-venv/bin/python rust/scripts/check-contracts.py --output-dir /private/tmp/arkdeck-s28-d0-contract-check` (`CARGO_BUILD_JOBS=2`), in a detached worktree of the change | 0 (`d0-check-contracts.log`): the checkout's manifest verified; the published view (`main`'s inputs at `f97ec67b9`) and the candidate view (this change's) each ran `cargo clippy --workspace --all-targets -D warnings`, `cargo test --workspace` (0 failed), the process self-test, `cargo build --workspace --bins` and `check-readonly.py` (PASS); the candidate also the 12 owner checks and the facade test, all 0 |
| Format | `cargo fmt --all --check` | 0 |
| SDD | `sh scripts/check-sdd.sh` | 0; 0 errors, 0 warnings |

Not run: the App (no App source changes); devices and the installed service
(nothing here runs either).

## CI

Pending.
