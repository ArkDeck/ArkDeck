# TASK-XPA-014 — the control-action answers of a daemon without an HDC host (macOS, 2026-09-19)

TASK-XPA-014 remains in progress. Base: protected main `81957589` (#1985); no stack. Every answer
here comes from a synthetic host composition in a contract test. Nothing is device evidence
(POL-VERIFY-001, POL-MODE-001). No production Swift source and no Rust code changes.

This is a Swift-only contract slice of milestone M1. It records what the production Swift daemon
answers for `runtime.hdc.impact-preview`, `runtime.hdc.restart` and `control-action.list`, `.show`
and `.reconcile` when it composes no managed HDC server. It then publishes those answers in the
three control-action method schemas.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| The Swift daemon's no-host composition (`ArkDeckAgentDaemonMain`) and its routes (`hdcControlActionRequest`); corpora recorded over a fake impact source (the success frames) and over a handler with no control-action owner at all; `runtime.hdc.impact-preview` and `runtime.hdc.restart` schemas that already admit `operationUnavailable`; the Rust snapshot pager (`arkdeck-hoststore` `snapshot_pager.rs`, same `arkdeck.runtime-snapshot/1` document) | `ControlActionNoHostContractTests`: the five methods through the handler composed as the no-host daemon composes it, 20 frames; `control-action.list`, `.show` and `.reconcile` re-derived and widened; their corpora grow by 14 lines | The Rust routes for the five methods, answering as recorded here (the Rust control layer still answers them with the foundation's `rejected`); the Rust CLI leaves `runtime hdc impact-preview`/`restart` and `control-action list`/`show`/`reconcile`; a managed HDC server in the Rust daemon, whose answers the committed success frames cover |

## Why

`ArkDeckAgentDaemonMain` builds `hdcControlActions` and `toolSelectionActions` only when its HDC
server host started. Otherwise both are nil. It still builds the union owner
`RuntimeControlActionResourceCoordinator` over neither, backed by `<state>/control-action-snapshots`.
The isolated Rust daemon starts no HDC server, so these are the answers its routes must give.

The committed corpora do not contain them:
- `control-action.show` and `.reconcile` do not admit `resourceNotFound`.
- `control-action.list` admits neither `invalidInput` nor `invalidCursor`, and its request publishes
  `pageSize` only.
- The corpus's `operationUnavailable` list frame comes from a handler without the union owner. The
  production daemon always has one, so it answers a page instead.

The Rust control layer rewrites any answer outside its method's schema to `internalError`, so the
Rust routes need these answers published first.

## The tests

`ControlActionNoHostContractTests` composes `RuntimeControlPlaneHandler` with:
- no HDC control-action owner and no tool-selection owner;
- the union owner over `hdc: nil, tools: nil`, backed by a private `control-action-snapshots`
  directory;
- a counting process dispatcher.

Every request goes through the handler's line entry. Every refusal's details are exactly
`{"newDispatchCount": 0}`. At the end the dispatcher was never called and the engine holds no Job.

| Method | Request | Answer |
| --- | --- | --- |
| `runtime.hdc.impact-preview` | `{}`; a well-formed intent (`action`, `actionRequestId`, `serverEndpointRef`, `expectedServerGeneration`) | `operationUnavailable` "the Runtime HDC control-action owner is unavailable" (the owner check comes before any parameter is read) |
| `runtime.hdc.restart` | `{}`; a well-formed tuple (`controlAction`, `previewId`, `previewDigest`) | the same |
| `control-action.show`, `.reconcile` | a well-formed identity | `resourceNotFound` "control action does not exist" |
| `control-action.show`, `.reconcile` | a malformed identity (`control action/1`) | `invalidInput` "an exact control-action identity is required" |
| `control-action.show` | an extra key: `executable`, which the committed corpus already refuses | the same `invalidInput` |
| `control-action.list` | `{}`; `pageSize` 1000; `kind` `hdcLifecycle`; `state` `awaitingImpactApproval`; `kind` `runtimeToolSelection` with `state` `succeeded` and `pageSize` 1 | an empty `arkdeck.cli.page/1` page: `pageKind` `snapshot`, `items` `[]`, `order` `createdAtThenControlActionId`, `hasMore` false, `nextCursor` null, a lowercase UUID `snapshotRevision` |
| `control-action.list` | `kind` `adbLifecycle`; `state` `running` | `invalidInput` "unsupported control-action discovery filter" |
| `control-action.list` | `pageSize` 0 | `invalidInput` "invalid page size" |
| `control-action.list` | `cursor` `not-a-cursor`; a page token the first snapshot never issued | `invalidCursor` "cursor is invalid, belongs to another query or its snapshot was reclaimed" |
| `control-action.list` | a 257-byte `cursor` | `invalidCursor` "invalid control-action cursor" (the handler's bound) |

The snapshot store:
- The union owner creates the directory, mode 0700, when it is composed.
- Each page answered adds exactly one file `snapshot-<snapshotRevision>.json`, mode 0600. It holds
  `schemaVersion` `arkdeck.runtime-snapshot/1`, the revision, the order, `pages` `[[]]` and one token
  `<revision>.<uuid>`. Its `queryDigest` is the SHA-256 of the canonical
  `{method, filters, order, pageSize}`, with the default `pageSize` 100 filled in.
- No refused list, and no other method, writes a file.

Nothing the investigation predicted differs. It left the bad-cursor code open, and there are two
refusals with the same code. The snapshot pager refuses a string cursor of at most 256 bytes; the
handler refuses a longer one with its own message.

## The schemas

Only `control-action.list`, `.show` and `.reconcile` are re-derived. The procedure avoids the
narrowing traps of #1925 and #1929:
- The input is each method's committed corpus lines plus its recorded frames: 13, 6 and 4 frames.
- `generate-control-contract.py --derive-method-schemas` runs on those three files only, and no
  other file changed.
- The corpora are then written as every committed line, verbatim and in order, plus one recorded
  frame per request shape, response shape, error code and message. That adds 14 lines: 10 to list,
  2 to show and 2 to reconcile. The generator's own selection had also kept every committed line,
  but re-sorted them.

| Method | Added |
| --- | --- |
| `control-action.list` | error codes `invalidCursor`, `invalidInput`; request members `cursor`, `kind`, `state`, each an optional string (the request stays closed) |
| `control-action.show` | error code `resourceNotFound` |
| `control-action.reconcile` | error code `resourceNotFound` |

Nothing else changed: no result or error-details schema, no type, and no required member. Only
`x-arkdeck-sampleCounts` also moves. The result counts of show and reconcile read 1 instead of 2,
because the input holds only the corpus's one success frame, not the original recording's two.

The structural check (a scratch script) compared every method schema with `81957589`'s. It covers
types, properties, `additionalProperties`, required members, items, `anyOf` and enums:
- 102 schemas are byte-identical, `runtime.hdc.impact-preview` and `runtime.hdc.restart` among them.
- The three changed schemas admit everything the base admitted. Their widening is exactly the table
  above, and there is no narrowing.
- Every committed line is kept in order, and every non-generic error code has a corpus frame.
- A derivation from the new corpus alone, in an isolated copy, reproduces the same `$defs` for all
  three methods.

Validated with jsonschema 4.26:
- Under `81957589`'s schemas, 11 of the 16 recorded control-action frames are refused: list 9 (the
  `kind`/`state`/`cursor` members, `invalidInput`, `invalidCursor`), show 1 and reconcile 1
  (`resourceNotFound`).
- The 4 `runtime.hdc.*` frames were valid already.
- Under the new schemas, all 20 recorded frames and all 21 corpus lines of the three methods are
  valid.

`rust/scripts/generate-contract.py --write` refreshed the checkout manifest
(`spec/baselines/swift-single-v1.json`): 105 methods, 760 recorded shapes (746 before), and
`--check` passes.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| This test, recording | `ARKDECK_CONTROL_FRAME_LOG=<fresh dir> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter ControlActionNoHostContractTests` | 2 tests, 0 failures. One frame file, 20 frames: impact-preview 2, restart 2, show 3, reconcile 2, list 11. `control-frames-8788.jsonl`, SHA-256 `85c1a44e01ea8523cbd816ff6a37fab075c08f9cc57a5fb60caffcc4bef1f2ad` |
| Derivation and structural check | `generate-control-contract.py --derive-method-schemas <the three methods' corpus + frames>`, then the scratch comparison with `81957589` | as above: `RESULT: PASS` |
| Schemas and frames, Swift | `ARKDECK_CONTROL_FRAME_LOG=<the 16 recorded control-action frames> run-swiftpm.sh test --filter 'ControlMethodSchemaContractTests\|ControlActionNoHostContractTests'` | 7 tests, 0 failures. `testFramesRecordedByThisRunValidate` checked 36 frames: the 16 seeded and the 20 this run re-recorded, since this test class runs first |
| Rust manifest | `rust/scripts/generate-contract.py --write`, then `--check` | 105 methods, 760 recorded shapes; the check passes |
| Rust contract and control tests | `cargo test --locked -p arkdeck-contract -p arkdeck-control` | 64 passed, 0 failed (`corpus_parity` 10 of 10, `read_only` 17 of 17); no Rust test changed |

## Unified local gate

The unified gate, `python scripts/ci/plan.py --repo-root . --base-revision origin/main
--head-revision HEAD --merge-base --include-worktree --run-local` (merge base `81957589`), ran with
`ARKDECK_PYTHON` and the planner both from a virtual environment carrying PyYAML 6.0.3 and
jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `c1e787c7` | `exit=1`, on one timing assertion outside this diff (below) | `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/control-action-frames-gate.log`, SHA-256 `50a0b796587b86c9fc3d0c004e7fe9715f40a76e0fa15d2e42275aa87629c354` |

r1 selected the Swift, Rust and design-system lanes. These passed:
- the common checks and SDD, and the design-system lane;
- the Swift lane: the full parallel run (2,689 tests, this slice's two among them), then the
  process-identity-race and viewer-scale lanes, each with exit code 0;
- in the Rust lane: `generate-contract.py --check`, `cargo fmt --check`, `cargo fetch --locked` and
  Clippy with `-D warnings`.

The workspace tests then passed 678 and failed 1. They ran every test target of `arkdeck-agentd`,
`arkdeck-cli`, `arkdeck-client`, `arkdeck-contract` (`corpus_parity` among them), `arkdeck-control`
and `arkdeck-hoststore`, and `arkdeck-platform` through its last target.

The one failure is `arkdeck-platform` `verified_process::output_overflow_kills_and_reaps_the_child`,
the assertion `started.elapsed() < Duration::from_secs(2)`; the target finished in 2.16 s. It is a
wall-clock bound. The host was carrying five unified gates at once (load average 136 at the start,
about 30 at the end, on 8 cores). The test reads no contract input, and this slice changes no Rust
code.

Cargo stopped at that target. So these did not run in r1:
- the `arkdeck-provider-hdc` and `arkdeck-soak` tests;
- `test_contract_checks.py`;
- `check-contracts.py`, the published and candidate views;
- `cargo deny` and `cargo vet`.

As the coordinator asked, the gate was not rerun on the overloaded host. It schedules one serialized
rerun when the host is quiet. The amend after r1 only fills in this section.

## Not run, and why

- **The rest of the unified gate.** That is everything after the timing failure (above), until the
  serialized rerun.
- **The Rust routes.** The next slice writes them against these schemas. Until then the Rust
  control layer answers the five methods with `rejected`.
- **A daemon with a managed HDC server or a tool-selection owner.** The committed success frames of
  `HDCControlActionContractTests` stand for it. This slice changes none of them.
- **A listing with more than one page.** No action exists without an HDC host, so no page has
  `hasMore` true and a real next cursor is never minted. The list result schema keeps
  `nextCursor` null.
- **A request naming an unknown parameter.** Swift refuses it with `invalidInput`, but a recorded
  frame would publish the invented name into the request schema, so none is sent.
- No device, no HDC and no installed Runtime.

## Rebase onto protected main `2a4a3441` (2026-09-19)

Rebased from `81957589` after #1986–#1997 merged. The only conflict was the generated
`spec/baselines/swift-single-v1.json`: main's version was taken and `python3
rust/scripts/generate-contract.py --write` regenerated it from this checkout (105 methods, 762
recorded shapes, contract identity `1d7d101e83fe…` unchanged); `--check` is clean. The gate run
recorded above (exit 1, the host-load timing test only) is therefore superseded by the serialized
rerun on the rebased head below.

### Serialized reruns on the rebased head `c59f662d` (merge base `2a4a3441`)

- r2, 15:39:34–15:42:23 CST: exit 1, **invalid run**. The only failure was
  `AgentDaemonContractTests.testHilogAnalyzerRunsMultipleJobsInOneDaemonSession`, which caught
  `NSCocoaErrorDomain 513` / EPERM while removing its own `/private/tmp/arkdeck-hilog-…` daemon
  root (an `instance.json` remained). That test runs a real daemon and is untouched by this diff;
  run alone on the same head it passed (1 test, 0 failures). Log
  `…/scratchpad/logs/control-action-frames-gate-r2.log`, SHA-256
  `b61ccc091faacd7da3bdb15e45e37564d2190b51a1129825bba84fb4208a2500`.
- r3, 15:50:18–16:01:59 CST: **exit 0**. Swift, Rust and design-system lanes; SwiftPM 2693 tests
  without failure (including the two new `ControlActionNoHostContractTests`); cargo 2547 passed,
  0 failed, 48 ignored; design-system 83/83; published and candidate contract checks,
  `generate-contract.py --check`, `check-sdd`, `cargo deny` and `cargo vet` passed. Log
  `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/control-action-frames-gate-r3.log`,
  SHA-256 `cdbd1c125adefbc64bb06fbfd7ec22bbe01ba4002cbe6bd583f5c1f40ef8fa79`.

### Rebase onto protected main `521c8fad` (2026-09-19)

#1989 (workspace projects) merged with its own baseline pins, so the rebase conflicted again only in
the generated `spec/baselines/swift-single-v1.json`: main's version was taken and regenerated
(105 methods, 775 recorded shapes, contract identity unchanged; `--check` clean). The unified gate
is rerun on this head (below).

- r4 on `ac99b973` (merge base `521c8fad`), 16:16:07–16:31:08 CST: exit 1, **invalid run**. Swift (2694),
  design-system and the workspace tests passed; the only failure was
  `arkdeck-platform verified_process::output_overflow_kills_and_reaps_the_child` (a 2-second timing
  assertion outside this diff) inside `check-contracts.py`'s view rerun, while a second gate ran on the
  host. Log `…/scratchpad/logs/control-action-frames-gate-r4.log`, SHA-256
  `6025429a979a554135c14dca4cf2300a70d37d54f3c7ee1f1d0c81f3a823426c`.
- r5 on the same head, serialized, 16:40:44–16:53:47 CST: **exit 0**. SwiftPM 2694 tests without
  failure; cargo 2601 passed, 0 failed, 48 ignored; design-system 83/83; published and candidate
  contract checks, `generate-contract.py --check`, `check-sdd`, `cargo deny` and `cargo vet` passed.
  Log `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/control-action-frames-gate-r5.log`,
  SHA-256 `be3c458ed2f3516b6cafe4043235c13613f410a6588cb1cacc4a6d158e41fc09`. A trial merge with
  protected main `c49e9e93` is conflict-free (main changed no contract input since `521c8fad`).
