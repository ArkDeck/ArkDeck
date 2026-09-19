# TASK-XPA-014 — the control-action answers of a daemon with an HDC server host (macOS, 2026-09-19)

TASK-XPA-014 remains in progress. Base: protected main `2b88705f` (#2008); no stack. The slice was
recorded on `e862d2bf` and rebased without conflict once #2008 merged, which changed no contract input. Every answer here comes
from a synthetic host composition in a contract test; nothing is device evidence (POL-VERIFY-001,
POL-MODE-001). No production Swift source, Catalog, entitlement, `openspec/specs` or constitution
change; the one Rust change is a test's classification of the corpus lines (below).

This is the Swift-only contract slice before C1 (the Rust HDC control-action owner over the isolated
daemon's managed server). It records what the production Swift daemon answers for
`runtime.hdc.impact-preview` and `control-action.list`, `.show` and `.reconcile` once its HDC server
host has started, and publishes those answers in the four method schemas.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| The success frames of a fake impact source (`HDCControlActionContractTests`, one `previewReady` action); the no-host answers and the Rust routes over the union owner with no HDC owner (#2002, #2003); the isolated daemon's managed HDC server (#2004) | `ControlActionWithHostContractTests`: the four methods through the handler composed as `ArkDeckAgentDaemonMain` composes it with a host, over the production impact source, 22 frames; the four schemas re-derived and widened; 19 corpus lines appended | C1: the Rust HDC control-action owner (`hdc-control-actions`), its impact source over the managed server and the union owner over it; then restart, the impact-approval human action, the console challenge, the Job interlock and recovery (design §L.1 item 13) |

## Why

The four schemas were derived from the fake source's frames alone, so they admit only its exact
`previewReady` shape: `blockerReasonCode` null, `preview` an object, `preview.serverGeneration`,
`serverVersion` and `tool.version` strings, `tool.signature` null, and a list's `nextCursor` null;
`runtime.hdc.impact-preview` publishes neither `invalidInput`, `resourceNotFound` nor
`idempotencyConflict`. The production impact source answers none of that shape:
`HeadlessHDCStatusObserver.signature` always returns an object, a fixture or 3.2.0f executable proves
no health, and a failed observation leaves no preview. Validated with jsonschema 4.26, the base
schemas refuse all 22 frames recorded here. The Rust control layer rewrites an answer outside its
method's schema to `internalError`, so C1 is blocked on these schemas.

## The tests

`ControlActionWithHostContractTests` composes, per daemon start, the HDC control-action owner
(`RuntimeHDCControlActionCoordinator`) in `<state>/hdc-control-actions` with
`RuntimeOperationCatalog.catalogDigest` and a fresh epoch, the union owner over it in
`<state>/control-action-snapshots`, and `RuntimeControlPlaneHandler` with both, the Target store and
the Target observation owner, as `ArkDeckAgentDaemonMain` does once `HeadlessHDCServerHost` started.
The impact source is the production `HeadlessHDCControlImpactSource` over a copy of the fixture HDC
executable (`ArkDeckFakeHDCFixture`, an unregistered digest: no commandless identity family) at the
default endpoint `127.0.0.1:8710`, with no launch record, and a fixture observation port whose device
list is empty or fails as `ProviderBootstrapObservation` reports an HDC whose `list targets -v`
printed nothing (the isolated Rust daemon's managed fake exits 23 with an empty stdout). Nothing runs
the executable. The tool-selection owner (it holds no action here) and the lifecycle driver (only an
approved restart reaches it) are not composed. The clock starts at 2026-09-19T00:00:00Z and moves
only when a test moves it. Every frame goes through the handler's line entry; every refusal carries
exactly `{"newDispatchCount": 0}`; the dispatcher is never called, no Job exists and no Target is
adopted.

| Method | Request | Answer |
| --- | --- | --- |
| `runtime.hdc.impact-preview` | `{}`; a generation spelled `0100000023` | `invalidInput` "an exact restart intent and request identity are required" |
| `runtime.hdc.impact-preview` | the endpoint reference of `127.0.0.1:8711` | `resourceNotFound` "the exact HDC endpoint reference is not configured" |
| `runtime.hdc.impact-preview` | the observation fails | a `previewDrifted` action, generation 2, `blockerReasonCode` `hdc.impactObservationUnavailable`, `preview` null, `nextAction` `reconcile` |
| `runtime.hdc.impact-preview` | the observation succeeds, no device | a `blocked` action, generation 2, `hdc.serverIdentityUnproven`; its preview has `serverGeneration`, `serverVersion` and `tool.version` null, `serverHealth` and `serverOwnership` `unknown`, `tool.trust` `unverified`, `tool.signature` the fixture's ad hoc signature object, a clear critical Job gate and empty participant sets; `previewDigest` is the SHA-256 of the canonical preview without it |
| `runtime.hdc.impact-preview` | the same request identity again | the same action, without observing again |
| `runtime.hdc.impact-preview` | the same identity with generation `100000024` | `idempotencyConflict` "the request identity belongs to a different lifecycle intent" |
| `control-action.show`, `.reconcile` | each action | the same projection; reconciling the blocked action observes again, finds the same impact and changes nothing |
| `control-action.list` | `{}`; `pageSize` 1, then its `nextCursor`; `state` `blocked` | both actions in creation-then-identity order; one per page, the first with `hasMore` true and a cursor `<revision>.<token>`, the second read from the stored snapshot; the blocked one |
| `control-action.show` after a restart (a new epoch, 60 s later) | the blocked action | `previewDrifted`, generation 3, `controlAction.runtimeRestarted`, the same preview, without observing |
| `control-action.show` 300 s after a preview of the new start | that action | `expired`, generation 3, `controlAction.expired`, the same preview |
| `control-action.reconcile`, `control-action.list` | the invalidated actions | unchanged; both listed |

An unknown field (`executablePath`) is refused the same way (`invalidInput`), asked of the owner
directly: a recorded frame would publish the invented name in the method's request schema.

Facts the tests pin that C1 must keep:

- Composing the owner makes `hdc-control-actions/records` and `hdc-control-actions/snapshots`, both
  0700. The HDC owner's own `snapshots` stays empty: the union owner pages, one snapshot per first
  page, in `control-action-snapshots`.
- Each action is one 0600 `records/action-<sha256(actionRequestId)>.json`. A refused preview persists
  nothing, but the request-identity lookup that comes before the endpoint check opens the store's
  transaction lock, so `records/.lock` exists after the wrong-endpoint refusal.

## The corpora

Every committed line is kept verbatim and in order. Appended: one recorded frame (the smallest, in
recording order) per answer the corpus did not already show — request shape, outcome, response shape,
error code and message, and for an action its state and blocker (for a page each item's, and whether
it has more). That adds 19 lines: `runtime.hdc.impact-preview` +6 (2 → 8), `control-action.show` +4
(5 → 9), `control-action.reconcile` +4 (4 → 8), `control-action.list` +5 (12 → 17).

The Rust replay of the no-host answers (`arkdeck-agentd` `control_action_control.rs`) counted the
five lines as needing a managed server. It now also counts the appended ones, and the lifecycle
refusals only an HDC control-action owner gives, instead of replaying them against the no-host owner.
Its exact counts became floors (44 lines, 19 by the owner, 10 without one, 20 with a host, 4
refusals of an HDC owner). No other test counts these corpora. The Rust CLI tests read their first
answered and first refused line, which did not move.

## The schemas

Only the four methods are re-derived, in an isolated copy of the generator's inputs (nothing else in
the checkout is written by the generator):

- Before adding anything, a derivation from the committed corpora of the four methods alone
  reproduced main's `$defs` exactly, so the corpus-collapse traps of #1925/#1929 cannot drop a code
  or shape here.
- The schemas are derived from the final corpora (committed ∪ appended). A derivation from the
  committed corpora plus all 22 recorded frames gives the same `$defs`; only `x-arkdeck-sampleCounts`
  differs between the two, and the committed schemas carry the corpus derivation's counts.
- A structural check (scratch `covers.py`: types, properties, required members,
  `additionalProperties`, items, `anyOf`, enums; it flags a narrowing when run the other way round, and
  on a planted dropped code, newly required member and newly constrained array) found no narrowing.
  Every document the base admits is admitted, every base error code is kept, and request and error
  detail schemas are byte-identical. The widening is exactly:

| Method | Newly admitted |
| --- | --- |
| `runtime.hdc.impact-preview` | error codes `idempotencyConflict`, `invalidInput`, `resourceNotFound`; `blockerReasonCode` a string; `preview` null; `preview.serverGeneration`, `preview.serverVersion` and `preview.tool.version` null; `preview.tool.signature` an object (`state`, `identifier`, `teamIdentifier` null, `platformTrust`, `executionAssessment`) |
| `control-action.show`, `control-action.reconcile` | the same result widening; no new code |
| `control-action.list` | the same widening of `items[]`; `nextCursor` a string |

Validated with jsonschema 4.26: the base schemas refuse all 22 recorded frames (impact-preview 9,
show 4, reconcile 4, list 5) and admit the 23 committed lines; the new schemas admit all 22 frames
and all 42 corpus lines of the four methods.

Still not published, because no frame here produces it (each needs its own frames first):

- **Device rows.** A non-empty `affectedDeviceObservations` or a non-null `criticalJobGate.reasonCode`
  — the arrays stay unconstrained. Recording rows would constrain those open arrays to Swift's closed
  row, which the superset rule forbids without a decision.
- **Other signatures.** A signature with a `teamIdentifier` (a Developer ID executable), or an
  unsigned executable (`identifier` null).
- **Approval states.** `awaitingImpactApproval` and a `humanAction` object, which need restart (C2).

`rust/scripts/generate-contract.py --write` refreshed the checkout manifest
(`spec/baselines/swift-single-v1.json`): 105 methods, 794 recorded shapes (775 before), contract
identity `1d7d101e83fe…` unchanged; the generated Rust bindings did not change; `--check` passes.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| This test, recording | `ARKDECK_CONTROL_FRAME_LOG=<fresh dir> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter ControlActionWithHostContractTests` | 2 tests, 0 failures; one frame file, 22 frames (impact-preview 9, list 5, show 4, reconcile 4), `control-frames-80710.jsonl`, SHA-256 `68c422798ece1fc9efeda53ef42379f83cc1f4c62e683656d978cf0402862fb8` |
| Derivation and structural check | `derive.py` (the generator over the four methods in an isolated copy), `covers.py <main's schemas> <derived>` | `RESULT: PASS`, the widening above |
| Schemas and frames, Swift | `ARKDECK_CONTROL_FRAME_LOG=<a directory seeded with the 22 frames> run-swiftpm.sh test --filter 'ControlMethodSchemaContractTests\|ControlActionWithHostContractTests\|ControlActionNoHostContractTests\|HDCControlActionContractTests'` | 29 tests, 0 failures, 1 skipped (`testFacadePreservesForegroundConsoleChallengeAndRedirectedHAR`, which needs `ARKDECK_DAEMON_UNDER_TEST`); `testFramesRecordedByThisRunValidate` validated the seeded frames and those this run recorded before it |
| Protocol vocabulary | `python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --check` | clean |
| Rust manifest | `python3 rust/scripts/generate-contract.py --write`, then `--check` | 105 methods, 794 recorded shapes |
| Rust tests over the corpora | `cargo test --locked -p arkdeck-contract -p arkdeck-control`; `-p arkdeck-agentd --bin arkdeck-agentd control_action`; `-p arkdeck-cli --test control_actions --test hdc_control_actions` | all passed (`corpus_parity` among them); agentd 4 of 4; CLI 4 and 4 |
| Format and Clippy | `cargo fmt --all --check`; `cargo clippy --workspace --all-targets --locked -- -D warnings` for the host, `--target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc` | clean |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, through the host's serialized gate queue, with
`ARKDECK_PYTHON` and the planner both from a virtual environment carrying PyYAML 6.0.3 and
jsonschema 4.26.0.

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `f4c84e13`, merge base `2b88705f`; 19:19:03–19:35:51 CST, load 11 at the start | `gate exit=0`. The planner selected the common checks, the Swift, Rust and design-system lanes (12 changed files). The common checks and SDD (`check_sdd`: 0 errors, 0 warnings); the design-system lane (83 of 83); the Swift lane: the full parallel run (2,701 tests, this slice's two among them), then the process-identity-race (1) and viewer-scale (5) lanes, each exit 0; the Rust lane: `generate-contract.py --check`, format, Clippy, the workspace tests, `test_contract_checks.py` and both contract views (published: this Rust against `2b88705f`'s contract; candidate: this checkout's), with `check-readonly.py` and the owner scripts in each. Cargo counted 2,754 passed, 0 failed and 48 ignored. Also `cargo deny --locked check` (advisories, bans, licenses, sources ok) and `cargo vet --locked --no-registry-suggestions` (36 fully audited) | `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/control-action-host-frames-gate-r1.log`, SHA-256 `08ce9dc7c30c29d1acbe199b190d6c6f520da10bed11f12f85dcf6df65667fb7` |

The amend after r1 only fills in this section and the base.

## Not run, and why

- **C1.** The Rust HDC control-action owner and its routes come next, on these schemas.
- **Restart, the impact-approval human action, the console challenge, the Job interlock and
  recovery.** They are C2, and recovery waits for design §L.1 item 13. No frame here reaches them.
- **Device rows, a critical Job gate with a reason, and other signatures.** See the schemas section.
- **A real HDC server, the 3.2.0d `checkserver` family, a device, the installed Runtime.** Nothing
  here runs an HDC executable.
