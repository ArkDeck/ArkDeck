# TASK-XPA-014 — a team-signed HDC tool and an unknown critical Job gate through the Swift daemon's handler (macOS, 2026-09-19)

TASK-XPA-014 remains in progress. Base: protected main `282d1bdc` (#2035); no stack. The slice was
recorded on `7b5872f1` (#2029) and rebased without conflict. The rebase changed no contract input
and no Swift source these tests use, and the Rust checks ran again after it. Every answer here comes
from a synthetic host composition in a contract test; nothing is device evidence (POL-VERIFY-001,
POL-MODE-001). No production Swift or Rust source, Catalog, entitlement, `openspec/specs` or
constitution change. Two Rust tests change (below).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining |
| --- | --- | --- |
| `runtime.hdc.status` derived from the status oracle and the registered 3.2.0f hdc (#1954); the control-action answers of a daemon with an HDC server host (#2012); the Rust with-host routes, which replay them (C1, #2017) | Three Swift tests through the handler: a team-signed tool's status and preview, and a preview whose Target inventory changed while it was read; 9 corpus lines; five schemas widened in exactly two members; C1's replay extended to the new lines | Participant rows (`affectedDeviceObservations`, `affectedJobIds`, `affectedTargetIds`, `criticalJobGate.blocking`), whose arrays stay open until the maintainer decides; restart, the impact-approval human action, the console challenge, the Job interlock and recovery (C2) |

## Why

The Rust control layer rewrites an answer outside its method's schema to `internalError`. Two
members were published as `null` only:

- **`teamIdentifier` of the HDC tool's signature.** It appears in `runtime.hdc.status` (`signature`,
  #1954) and in `runtime.hdc.impact-preview`, `control-action.show`, `.reconcile` and `.list`
  (`preview.tool.signature`, #2012).
  - Those schemas were derived from an unsigned fixture tool, a seam's `{state: testOnly}`, the
    registered 3.2.0f hdc and the fixture HDC. None carries a team.
  - Swift's `HeadlessHDCStatusObserver.signature` reports `kSecCodeInfoTeamIdentifier`, and so
    does the Rust observer's `NativeSignature`.
  - So the status of an hdc signed with a team identifier (a Developer ID), and every preview of
    it, is rewritten.
- **`preview.criticalJobGate.reasonCode`.** All of #2012's previews had a clear gate.
  - Swift's `HeadlessHDCControlImpactSource` and the Rust `ManagedServerImpact` (#2017) both leave
    the gate `unknown` with `hdc.participantInventoryUnproven` in two cases: the Jobs or Targets
    read before the device list differ from those read after it, or a device has no proved USB
    relation.
  - The isolated Rust daemon reads relations only from a development relation source it is given
    (#1988, #2023); otherwise it composes `NoUsbRelations`. There, every real device leaves the gate
    unknown, and that preview and each read of it are rewritten.

Not affected: this host's registered 3.2.0f hdc is signed ad hoc (`linker-signed`, no team). GJ-1
on the Rust daemon (#2024) read its status within the published schema, and no GJ-1 step previews an
impact.

## The tests

**The stand-in for a team-signed hdc.** No registered hdc is signed with a team identifier.
- DevEco Studio 26.0.0 (`DS-243.24978.46.36.26002`) signs the executables of its own bundle as
  "Developer ID Application: Huawei Device Co,. LTD (TZEA3TN37Q)".
- A copy of its `Contents/bin/fsnotifier` (SHA-256 `14c69a35…`) keeps that signature:
  `codesign --verify --strict --all-architectures` passes on the copy.
- The production signature inspection reads the copy as `{state: verified, identifier: fsnotifier,
  teamIdentifier: TZEA3TN37Q, platformTrust: unverified, executionAssessment: notPerformed}`.
  `TZEA3TN37Q` is what that inspection returns for the file; no seam supplies it.
- Its digest is unregistered, so it has no commandless identity family, and nothing runs it.
- A host without DevEco skips both tests that use it
  (`HDCStatusControlFramesContractTests.teamSignedExecutable`).

The three tests:

1. `HDCStatusControlFramesContractTests.testTheHandlerAnswersTheTeamIdentifierOfATeamSignedTool`.
   The production observer over the copy, observed as launched, through `RuntimeControlPlaneHandler`.
   This is the registered-tool test's composition, now shared as `launched(_:sha256:)`. The answer:
   `available`, `hdc.identityObserved`, `arkDeckManaged`, generation `100000023` and process 42.
   `clientVersion` is null, since the digest is unregistered, and the signature is exactly what the
   inspection read.
2. `ControlActionWithHostContractTests.testATeamSignedToolIsPreviewedWithItsTeamIdentifier`. #2012's
   composition over the copy instead of the fixture HDC.
   - The preview `host-team-signed` is `blocked`, `hdc.serverIdentityUnproven`, generation 2. Its
     `tool.signature` is the inspection's object.
   - `show` answers the same record. `reconcile` observes again, finds the same impact and changes
     nothing. `list` pages it alone.
3. `ControlActionWithHostContractTests.testAnInventoryChangedWhileTheImpactIsReadLeavesTheCriticalJobGateUnknown`.
   This one runs on every host.
   - The fixture HDC, with one Target adopted in the Target store. The fixture port removes the
     durable Target document while each device list is read.
   - The preview `host-inventory-changed` is `blocked`, `hdc.serverIdentityUnproven`. Its
     `criticalJobGate` is `{state: unknown, blocking: [], reasonCode:
     hdc.participantInventoryUnproven}`. Every participant array is empty: the preview names the
     Targets read after the devices, and none is left.
   - `show` answers the same record. `reconcile` runs after the document is restored, and the port
     removes it again: the same impact, nothing changed. `list` pages it alone.

Every frame goes through the handler's line entry. Nothing is dispatched and no Job exists.

A changed inventory is the only way the production source gives a reason with every participant
array empty:
- a device without a proved relation adds an `affectedDeviceObservations` row;
- a current Job adds `affectedJobIds` and `blocking` rows;
- a Target left after the read adds `affectedTargetIds`.

Recording any of those would constrain an array the schemas leave open (`{"type": "array"}`). The
superset rule forbids that without the maintainer's decision. The gate a real device without a
relation gets is the same: `unknown`, with the same reason.

All 7 tests of the two classes passed. They recorded 54 frames (`control-frames-87925.jsonl`,
SHA-256 `0718b5a940de…`): status 24, impact-preview 11, show 6, reconcile 6, list 7.

## The corpora

Every committed line is kept verbatim and in order. The 9 frames of the three new tests are
appended. Each is an answer the corpus did not show, by `append.py`'s key: request shape, outcome,
response shape, error code and message, an action's state and blocker, a page's items.

| Corpus | Lines |
| --- | --- |
| `runtime.hdc.status` | 7 → 8 |
| `runtime.hdc.impact-preview` | 8 → 10 |
| `control-action.show` | 9 → 11 |
| `control-action.reconcile` | 8 → 10 |
| `control-action.list` | 17 → 19 |

The other 45 frames are answers of the existing tests, and none is appended. Three of their list
pages order the two actions of `testImpactPreviewRecordsEveryIntentAndTheReadsPageTheRecords` the
other way round than the corpus. Both actions are created at the same instant, so their random
identities decide the order. The pages show no new member, and C1's replay selects a page by the
order of its items.

## The schemas

Only the five methods are re-derived, with the generator in an isolated copy of its inputs (#2012's
`derive.py`):
- The committed corpora alone reproduce main's `$defs` exactly, for all five.
- The final corpora give the same `$defs` as the committed corpora with all 54 recorded frames.
- A structural check (`covers.py`) finds no narrowing. Run the other way round, it reports the 9
  widenings as narrowings.
- A diff of the files shows only two kinds of change: a `"type": "null"` becoming
  `["null", "string"]`, and the sample counts.

| Method | Newly admitted |
| --- | --- |
| `runtime.hdc.status` | `signature.teamIdentifier` a string |
| `runtime.hdc.impact-preview`, `control-action.show`, `control-action.reconcile` | `preview.tool.signature.teamIdentifier` a string; `preview.criticalJobGate.reasonCode` a string |
| `control-action.list` | the same two members of `items[].preview` |

No error code, request or error detail changes.

`x-arkdeck-sampleCounts` are the corpus's counts, as #2012's four schemas carry. The counts of
`runtime.hdc.status` came from #1954's whole-suite recording (33 requests, 30 results, 3 errors);
they are now 8, 7 and 1. Nothing reads them.

Validated with jsonschema 4.26:
- main's schemas refuse all 9 new frames and admit main's 49 corpus lines;
- the new schemas admit the 9 frames, all 54 recorded frames and all 58 corpus lines of the five
  methods.

`rust/scripts/generate-contract.py --write` refreshed the checkout manifest
(`spec/baselines/swift-single-v1.json`): 105 methods, 805 recorded shapes (796 before). The contract
identity `1d7d101e83fe…` is unchanged, and so are the generated bindings.

## Rust

- **`arkdeck-agentd` `control_action_host_control.rs`** is C1's replay of every with-host corpus
  line. It now replays the new lines too.
  - For `host-team-signed` and `host-inventory-changed`: the preview over the recorded impact,
    `show`, `reconcile` over the same impact, and the page. Each compares whole; only the snapshot
    revision is set aside.
  - The published contract view's corpora predate these lines, so the replay skips a request
    identity no line shows. Its check that every with-host line was replayed stays exact.
- **`arkdeck-cli` `runtime_hdc_status.rs`**: its exact count of the corpus's answers (6) is now a
  floor. There are 7 here; the published view still has 6.
- **`control_action_control.rs`** is unchanged. The new lines count as answered by a host
  (`managed`, 20 → 28), and its floors hold.

The Rust side reads both members from the same inputs:
- A scratch probe (not committed) ran the Rust `NativeSignature` over a copy of the same
  `fsnotifier`. It read exactly the signature object of the new status and preview frames.
- `ManagedServerImpact` puts the inspector's object in `tool.signature` unchanged.
- Its unit test `inventory_that_changed_or_a_device_without_a_relation_leaves_the_gate_unknown` pins
  the unknown gate and its reason.

## Local targeted checks

Logs are under the session scratchpad
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/team-sig/logs/`
(`<logs>` below). Cargo ran with `CARGO_BUILD_JOBS=2` in this worktree's own `rust/target`.

| Check | Command | Exit and result | Log |
| --- | --- | --- | --- |
| Recording | `ARKDECK_CONTROL_FRAME_LOG=<fresh dir> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter '(HDCStatusControlFramesContractTests\|ControlActionWithHostContractTests)'` | 0 on `7b5872f1`; 7 tests, 0 failures, none skipped; 54 frames | `<logs>/record-1.log` |
| Derivation and structural check | `derive.py` over the final corpora and over the committed corpora with the 54 frames; `covers.py` against main's schemas | the same `$defs` both ways; `RESULT: PASS`, only the widening above | — |
| Affected Swift classes, new schemas | `ARKDECK_CONTROL_FRAME_LOG=<dir seeded with the 54 frames> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter '(ControlMethodSchemaContractTests\|HDCStatusControlFramesContractTests\|ControlActionWithHostContractTests\|HDCStatusOracleContractTests\|HDCLiveStatusContractTests\|ControlActionNoHostContractTests\|HDCControlActionContractTests)'` | 0 on `7b5872f1`; 41 tests, 0 failures, 1 skipped (`testFacadePreservesForegroundConsoleChallengeAndRedirectedHAR`, which needs `ARKDECK_DAEMON_UNDER_TEST`). jsonschema 4.26 admits all 110 frames the run recorded | `<logs>/swift-targeted.log` |
| Contract manifest and vocabulary | `python3 rust/scripts/generate-contract.py --write`, then `--check`; `python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --check` (both again on `282d1bdc`) | 0; 105 methods, 805 recorded shapes; 0 | — |
| Format | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 on `7b5872f1`; 0 on `282d1bdc` | `<logs>/fmt.log`, `<logs>/fmt-r3.log` |
| Contract, control and daemon tests | `cargo test --manifest-path rust/Cargo.toml --locked -p arkdeck-contract -p arkdeck-control -p arkdeck-agentd` | 0 on `7b5872f1` (109 passed); 0 on `282d1bdc`, 112 passed, 0 failed (`corpus_parity`, `control_action_host_control`, `control_action_control`, `hdc_status_control` among them) | `<logs>/test-core.log`, `<logs>/test-core-r3.log` |
| CLI tests | `cargo test --manifest-path rust/Cargo.toml --locked -p arkdeck-cli` | 0 on `7b5872f1` (153 passed); 0 on `282d1bdc`, 157 passed, 0 failed | `<logs>/test-cli.log`, `<logs>/test-cli-r3.log` |
| Clippy | `cargo clippy --manifest-path rust/Cargo.toml --locked -p arkdeck-agentd -p arkdeck-cli --all-targets -- -D warnings` | 0 on `7b5872f1`; 0 on `282d1bdc` | `<logs>/clippy.log`, `<logs>/clippy-r3.log` |
| The changed Rust tests over main's contract inputs (the published view) | on `7b5872f1`, before the corpora and schemas changed: `cargo test ... -p arkdeck-agentd --bin arkdeck-agentd control_action`; `cargo test ... -p arkdeck-cli --test runtime_hdc_status` | 0, 5 passed; 0, 3 passed | `<logs>/published-view-agentd.log`, `<logs>/published-view-cli.log` |
| SDD | `ARKDECK_PYTHON=<main checkout>/.venv-sdd/bin/python sh scripts/check-sdd.sh` | 0; `check_sdd`: 0 errors, 0 warnings | `<logs>/check-sdd.log` |

## CI

Pending: the PR's GitHub CI is the unified gate.

## Not run, and why

- **Participant rows.** A gate reason with an `affectedDeviceObservations`, `affectedJobIds`,
  `affectedTargetIds` or `blocking` row waits for the maintainer's decision on those open arrays.
- **An unsigned tool's preview** (`identifier` null) is still unpublished; no frame here produces
  one.
- **A team-signed hdc on a device, a real HDC server, the installed Runtime.** No executable is run
  here.
- **Restart, the impact-approval human action, the console challenge, the Job interlock and
  recovery.** These are C2.
- **The full unified gate.** Since #2015 the PR's CI runs it.
