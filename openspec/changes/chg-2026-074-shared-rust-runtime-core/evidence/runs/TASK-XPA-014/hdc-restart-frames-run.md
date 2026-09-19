# TASK-XPA-014 — `runtime.hdc.restart` and its impact approval through the Swift daemon's handler (macOS, 2026-09-19)

TASK-XPA-014 remains in progress. Base: `5ab8079b`, the team-signature frames slice (#2037, not merged
yet) over protected main `3e95ac6d` (#2041). Both slices append to the same corpora and re-derive
schemas of the same methods, so this one is stacked on it. It was recorded first on that slice's
earlier head `25b7a4f1` and moved onto `5ab8079b` without conflict. Between the two heads the five
corpora and seven schemas read here are byte-identical, and no Swift source these tests use changed;
the final recording ran on `5ab8079b`. Every answer here comes from a synthetic host composition in
a contract test; nothing is device evidence (POL-VERIFY-001, POL-MODE-001). No production Swift or
Rust source, Catalog, entitlement, `openspec/specs` or constitution change. One Rust test changes
(below).

This is the Swift-only frames slice before C2, the Rust restart path. It records what the Swift
daemon's handler answers for `runtime.hdc.restart` once its HDC server host has started, the reads
of the impact approval a restart requests, and an unsigned tool's preview. It publishes those
answers in five method schemas.

## Already on main / this slice / still remaining

| Already on main (or below this slice) | This slice | Still remaining |
| --- | --- | --- |
| The with-host answers of `runtime.hdc.impact-preview` and `control-action.list`, `.show` and `.reconcile` (#2012); their Rust owner and routes (C1, #2017); a team-signed tool and an unknown critical Job gate (`5ab8079b`); one approval request of a fake impact source (`HDCControlActionContractTests`) | Seven Swift tests through the handler, composed as the daemon composes it: a restart's approval request, each refusal before any lifecycle dispatch, the approval read through the control-action routes and the human-action union owner, an approval that drifts and one that expires, and an unsigned tool. 30 corpus lines; five schemas widened; C1's replay extended, and its exclusion of what restart made is now exact | C2: the Rust restart path, the approval in the Rust records, and the human-action union over them. Then the console challenge, resume, the Job interlock, dispatch, the lifecycle audit and recovery. Participant rows wait for the maintainer's decision |

## Why

The Rust control layer rewrites an answer outside its method's schema to `internalError`. Three
gaps would have rewritten the answers C2 has to give:

- **`runtime.hdc.restart`** was derived from two frames: the fake source's approval request and the
  answer of a daemon without an HDC owner (`operationUnavailable`). It published none of the
  refusals Swift gives before any lifecycle dispatch: `invalidInput`, `resourceNotFound`,
  `reviewedPlanMismatch`, `admissionDenied`, `factsDrifted` (with the invalidated action in its
  details) and `orchestrationClockUntrusted`. Its preview admitted only the fake's `tool.signature:
  null`, while Swift's `HeadlessHDCStatusObserver.signature` and the Rust `NativeSignature` always
  answer an object.
- **`control-action.show`, `.reconcile` and `.list`**, and `runtime.hdc.impact-preview` sent again
  with its request identity, admitted `humanAction: null` only. No record awaiting an approval was
  ever read through them.
- **An unsigned tool.** The production inspection answers `{state: unsigned, identifier: null,
  teamIdentifier: null, …}`. Every recorded preview had an `identifier`, so each schema admitted a
  string only there.

Validated with jsonschema 4.26, the base schemas refuse 28 of the 30 lines appended here.

## The tests

**The composition.** `ControlActionWithHostContractTests` composes each daemon start as
`ArkDeckAgentDaemonMain` does once `HeadlessHDCServerHost` started (#2012). This slice adds what
`main.swift` composes beside it: the AgentExecution owner in `<state>/agent-executions` and the
human-action union owner in `<state>/human-action-snapshots`, over that owner and the control-action
union owner. The tool-selection owner and the lifecycle driver are still not composed. Nothing
resumes an approval, no console challenge is issued, and nothing is dispatched.

**Why the restart tests need a seam.** `requestRestart` (`HDCControlActionCoordinator.swift`) asks
for a ready preview. The production impact source makes a preview ready only for a healthy server,
and `HDCControlServerObserver` proves health only for the registered 3.2.0d executable (`48395ba8…`).
It observes that server's commandless identity, runs `checkserver` and expects the healthy family's
exact output, then observes the same identity again. Every other digest proves no health:
- the fixture HDC and the copies used here have no identity family at all
  (`hdc.serverIdentityUnproven`);
- the registered 3.2.0f hdc of this host proves a generation but no health
  (`hdc.serverHealthUnproven`).

On this host, then, Swift's own daemon refuses every restart with `admissionDenied`. Proving health
would run an HDC, which this slice does not do.

The restart tests therefore read the impact through `RegisteredHealthyServer`. It reads through the
production `HeadlessHDCControlImpactSource`: the executable's path, digest and native signature, the
Jobs, the Targets and the devices. Then it answers what `HDCControlServerObserver` gives a registered
healthy server: generation `100000023`, health `healthy`, version `3.2.0d`, no blocker. The tool's
client version is the one the registered digest names, `3.2.0d`, since only that executable proves
health. Ownership stays `unknown`, as the production source derives it with no launch record. The
refusals of a blocked preview, and the unsigned tool's preview, use the production source alone.

| Test | Tool; source | What it records |
| --- | --- | --- |
| `testRestartOfAReadyPreviewRequestsItsImpactApprovalOnce` | fixture HDC; seam | preview `host-restart`: `previewReady`, generation 2. Restart refusals: `{}` and an uppercase digest → `invalidInput` "restart requires one exact control-action preview tuple"; an unknown action → `resourceNotFound` "control action does not exist"; another digest, another preview id → `reviewedPlanMismatch` "restart does not name the exact immutable preview". No refusal observes or changes the action. 30 s later, the exact tuple → `awaitingImpactApproval`, generation 3, with the approval (below); one fresh observation. The same tuple again → the same answer, not observed; another digest → `reviewedPlanMismatch`; the preview's request identity again → the same action, not observed. `show`; `reconcile` (observes the same impact, unchanged); `list` whole and by `state: awaitingImpactApproval`. `human-action.show` and `.list` (owner kind `controlAction`) → the approval as the action projects it. The clock 1 s back → `orchestrationClockUntrusted` "control-action clock moved backwards", not observed |
| `testRestartIsRefusedWhenTheFreshImpactIsUnprovenOrNotTheReviewedOne` | fixture HDC; seam | two ready previews. The fresh observation fails → `factsDrifted` "fresh HDC impact could not be proven", details `{controlAction, newDispatchCount: 0}`: the action `previewDrifted`, generation 3, `hdc.impactObservationUnavailable`, its reviewed preview kept, no approval. That action again → `admissionDenied` "the control action is not eligible for impact approval". A Target adopted after the review → `factsDrifted` "fresh HDC impact differs from the reviewed preview", the action `previewDrifted` with `hdc.previewDrifted`. The fresh reading names the Target; no frame holds that reading |
| `testAnAwaitedImpactApprovalDriftsOrExpiresWithoutDispatch` | fixture HDC; seam | two approvals requested. A Target adopted, then `reconcile` of one → `previewDrifted`, generation 4, `hdc.previewDrifted`, its approval `expired`; `show` the same; `human-action.show` → `expired`; restart → `admissionDenied`. At 300 s after the other's preview, `show` → `expired`, generation 4, `controlAction.expired`, its approval `expired`; `reconcile` unchanged; `human-action.show` → `expired`; restart → `admissionDenied`; `list` → both |
| `testAnUnsignedToolIsPreviewedWithoutASigningIdentity` | the HDC oracles' unsigned shell driver (`HDCOracleFake.driver`, never run); production source | preview `host-unsigned`: `blocked`, `hdc.serverIdentityUnproven`, `tool.signature` `{unsigned, null, null, unverified, notPerformed}`; `show`, `reconcile` (unchanged), `list`. Its exact tuple → `admissionDenied` |
| `testAnUnsignedToolsRestartKeepsItsSignature` | unsigned driver; seam | a ready preview's restart → `awaitingImpactApproval` with that signature; another's, the observation failing → `factsDrifted` whose action carries it |
| `testATeamSignedToolsRestartKeepsItsTeamIdentifier` | a copy of DevEco's `fsnotifier`, as `5ab8079b` uses it (skipped without DevEco); seam | the same, with `{verified, fsnotifier, TZEA3TN37Q, …}` |

The approval a restart requests (`HDCControlActionRecord.requestingImpactApproval`):
`{schemaVersion: arkdeck.human-action/1, actionId: har-<uuid>, owner: {controlAction, <action>},
resumeReference: resume-<uuid>, category: impactApproval, reasonCode: policy.impactApprovalRequired,
minimumAction: human.reviewImpact, prohibitedAutomation: [selfApproval], createdAt: <the request>,
expiresAt: <the preview's>, status: waiting, newDispatchCount: 0, selectionSchema: null, choices: [],
binding: {controlActionId, previewId, previewDigest, generation: "3"}}`. The action's `nextAction` is
`{humanAction, resource: {humanAction, har-…}, policy.impactApprovalRequired}`. Invalidating the
action (drift, expiry, a Runtime start) sets the approval's `status` to `expired`.

Two rules held:
- **No invented request member.** Every refusal names only `controlAction`, `previewId` and
  `previewDigest`, each a string, so no parameter enters the request schema.
- **No participant row.** Every `affectedDeviceObservations`, `affectedJobIds`, `affectedTargetIds`
  and `criticalJobGate.blocking` array in the frames is empty. The adopted Targets are only in fresh
  readings no frame holds. A critical Job gate would need a current Job, which adds `affectedJobIds`
  and `blocking` rows. So the `admissionDenied` recorded is the blocked-preview one, and the Job-gate
  variant waits for the maintainer's decision on those open arrays.

All 10 tests of the class passed, none skipped, and recorded 78 frames (`control-frames-13837.jsonl`,
SHA-256 `06ea393d4fe9…`): impact-preview 22, restart 21, show 10, reconcile 10, list 11,
`human-action.show` 3, `human-action.list` 1.

## The corpora

Every committed line is kept verbatim and in order. Appended: the new tests' frames that are an
answer the corpus did not show, one each, the smallest in recording order, by #2012's `append.py`
key (request shape, outcome, response shape, error code and message, an action's state and blocker,
a page's items).

| Corpus | Lines | Appended |
| --- | --- | --- |
| `runtime.hdc.restart` | 2 → 15 | the approval of the fixture, the unsigned and the team-signed tool; `factsDrifted` of each (unproven), and the fixture's that differs; `admissionDenied`; `invalidInput` twice (`{}`, a malformed tuple); `resourceNotFound`; `reviewedPlanMismatch`; `orchestrationClockUntrusted` |
| `runtime.hdc.impact-preview` | 10 → 15 | the ready preview of the fixture, the unsigned and the team-signed tool; the unsigned tool's blocked preview; the awaiting action answered again |
| `control-action.show` | 11 → 15 | an awaiting action; one drifted and one expired with their expired approvals; the unsigned tool's blocked preview |
| `control-action.reconcile` | 10 → 14 | the same four |
| `control-action.list` | 19 → 23 | the awaiting action, whole and by state; the drifted and the expired; the unsigned tool's preview |

Not appended:
- **The existing tests' 30 frames.** By that key they add nothing.
- **The four human-action frames.** The committed `human-action.list` and `.show` corpora already
  hold the fake source's approval, so their schemas admit an action owned by a `controlAction` with
  its `binding`, in `waiting` and in `expired`. The committed corpora together with these four frames
  derive the same `$defs`, and jsonschema admits all four.

C2's replay needs to know where each drift came from. An unproven reading is a failed device list;
a differing one is a Target adopted after the review. An expiry is the clock at 300 s after the
preview.

## The schemas

Only the five methods are re-derived, with the generator in an isolated copy of its inputs (#2012's
`derive.py`):
- The committed corpora alone reproduce the base `$defs` of all five exactly, and of the two
  human-action methods.
- The final corpora give the same `$defs` as the committed corpora with all 78 recorded frames.
- The structural check (`covers.py`) finds no narrowing. Run the other way round, it reports the 16
  widenings as narrowings.

Every change is one of these:

| Method | Newly admitted |
| --- | --- |
| `runtime.hdc.restart` | error codes `admissionDenied`, `factsDrifted`, `invalidInput`, `orchestrationClockUntrusted`, `resourceNotFound`, `reviewedPlanMismatch`; `errorDetails.controlAction`, an optional member: the whole action as a refusal leaves it (every member required; `blockerReasonCode` a string, `humanAction` null, a preview with the signature object and `tool.version` a string); `result.preview.tool.signature` an object (`identifier` and `teamIdentifier` each `string` or `null`) besides `null` |
| `runtime.hdc.impact-preview`, `control-action.show`, `control-action.reconcile` | `result.humanAction` the approval object besides `null`; `result.preview.tool.signature.identifier` `null` besides a string |
| `control-action.list` | the same two members of `items[]` |

No request schema changes. `x-arkdeck-sampleCounts` are the corpus counts, as the other four carry;
restart's were `6/4/2` from an earlier recording and are now `15/4/11`. Nothing reads them.

Validated with jsonschema 4.26:
- the base schemas admit the base corpora of the five methods (52 lines) and refuse 28 of the 30
  appended lines (the two they admit are the fixture's and the team-signed tool's ready previews);
- the new schemas admit the 30 lines, all 78 recorded frames and all 82 corpus lines of the five
  methods.

`rust/scripts/generate-contract.py --write` refreshed the checkout manifest
(`spec/baselines/swift-single-v1.json`): 105 methods, 895 recorded shapes (865 before). The contract
identity `1d7d101e83fe…` is unchanged, and so are the generated bindings.

## Rust

- **`arkdeck-agentd` `control_action_host_control.rs`** is C1's replay of every with-host corpus
  line.
  - It now also replays what C1 can: the unsigned tool's blocked preview (read, reconciled, listed,
    as for the team-signed one), and the three ready previews over their recorded impacts.
  - What restart made stays unreplayed: every restart answer and refusal, and every record or page
    carrying an approval. C1 refuses such a record as unreadable.
  - The old check listed the one such line. The new one is a partition: each with-host line is
    replayed or restart's, never both. The published view's corpora predate these lines, and the new
    requests are skipped there.
- **`control_action_control.rs`** is unchanged. The 20 answered lines count as a host's (`managed`)
  and the 10 refusals as an HDC owner's; its floors hold.
- The CLI tests read each corpus's first answered and first refused line, which did not move.

## What C2 still needs

- **Restart in the Rust owner.** The route's tuple check (`invalidInput`). Then, as Swift's
  `requestRestart` does:
  - the action (`resourceNotFound`) and its age refresh (expiry, Runtime start, catalog,
    `orchestrationClockUntrusted`);
  - the exact preview (`reviewedPlanMismatch`); an awaiting action answered as it is; anything else
    not ready (`admissionDenied`);
  - a fresh reading: unproven or differing → `factsDrifted` with the invalidated action in the
    details;
  - the approval by CAS: `har-`/`resume-` identities, generation + 1, created now, expiring with the
    preview.
- **The approval in the Rust records.** Accept `awaitingImpactApproval` and an invalidated record
  carrying an expired approval; C1 refuses both as unreadable. Expire the approval on every
  invalidation, and project `nextAction` for an awaiting action. `reconcile` of an awaiting action
  reads again.
- **The human-action union.** The Rust owner (`human_action.rs`) keeps no control-action approvals,
  so a `controlAction` owner lists nothing. C2 adds the HDC owner's approvals to `human-action.list`
  and `.show`.
- **A real ready preview.** Only the registered 3.2.0d executable proves health, in Swift as in the
  Rust `ManagedServerImpact`. With this host's 3.2.0f hdc, both answer `admissionDenied` to every
  restart. An end-to-end restart needs that executable and its server.
- **Not published.** A racing request's answer (restart answers whatever the action became when its
  generation moved during the fresh read), and a Job-gate `admissionDenied` (participant rows).

## For the maintainer

- **The seam.** The ready previews, and so every approval and `factsDrifted` frame here, come from
  `RegisteredHealthyServer`: the production reading, with a registered healthy server's facts in
  place of an observation that would run an HDC. The alternative is recording against the
  registered 3.2.0d hdc and a live server.
- **The client version.** The seam answers `tool.version` `3.2.0d`, the registered digest's, beside
  the fixture's own digest and signature. Keeping the fixture's `null` would have published a
  `null` version for a ready preview, which production never gives, and restricted the refusal
  details to it, which would have rewritten a real 3.2.0d refusal.
- **`orchestrationClockUntrusted`** is now published for restart only. Recording it for the other
  four methods, whose Rust owner already gives it, would be a small follow-up.
- **Participant rows** stay undecided; the Job-gate `admissionDenied` waits for that decision.

## Local targeted checks

Logs are under the session scratchpad
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/restart-frames/logs/`
(`<logs>` below). Cargo ran with `CARGO_BUILD_JOBS=2` in this worktree's own `rust/target`. The host
was heavily loaded throughout (1-minute load 40 to 100, other sessions' builds).

| Check | Command | Exit and result | Log |
| --- | --- | --- | --- |
| Recording | `ARKDECK_CONTROL_FRAME_LOG=<fresh dir> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter ControlActionWithHostContractTests` | 0 on `5ab8079b`; 10 tests, 0 failures, none skipped; 78 frames. Earlier runs on `25b7a4f1`: r1 did not compile (the type checker gave up on one expression, split since); r2 passed before the seam answered the registered client version | `<logs>/record-3.log` |
| Derivation and structural check | `derive.py` over the final corpora and over the committed corpora with the 78 frames; `covers.py` against the base schemas | the same `$defs` both ways; `RESULT: PASS`, exactly the 16 widenings above; the human-action `$defs` unchanged | `<logs>/derive.log` |
| jsonschema 4.26 | `validate.py` (base and new schemas; appended lines, recorded frames, corpora) | as in the schemas section | `<logs>/jsonschema.log` |
| Affected Swift classes, new schemas | `ARKDECK_CONTROL_FRAME_LOG=<dir seeded with the 78 frames> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter '(ControlMethodSchemaContractTests\|ControlActionWithHostContractTests\|ControlActionNoHostContractTests\|HDCControlActionContractTests)'` | 0 on `5ab8079b`; 37 tests, 0 failures, 1 skipped (`testFacadePreservesForegroundConsoleChallengeAndRedirectedHAR`, which needs `ARKDECK_DAEMON_UNDER_TEST`); `testEveryRecordedFrameInTheCommittedCorpusValidatesAgainstItsSchema` and `testFramesRecordedByThisRunValidate` passed. jsonschema 4.26 admits all 208 frames in the log (the 78 seeded and the 130 this run recorded) | `<logs>/swift-targeted.log` |
| Contract manifest and vocabulary | `python rust/scripts/generate-contract.py --write`, then `--check` (the validation environment's Python); `python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --check` | 0; 105 methods, 895 recorded shapes; 0 | — |
| Format | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | `<logs>/fmt.log` |
| Contract, control, daemon and CLI tests | `cargo test --manifest-path rust/Cargo.toml --locked -p arkdeck-contract -p arkdeck-control -p arkdeck-agentd -p arkdeck-cli` | 0; 271 passed, 0 failed (`corpus_parity`, `control_action_host_control`, `control_action_control`, and the CLI's `hdc_control_actions`, `control_actions` and `human_action_resources` among them) | `<logs>/test-core.log` |
| Clippy | `cargo clippy --manifest-path rust/Cargo.toml --locked -p arkdeck-agentd -p arkdeck-cli --all-targets -- -D warnings` | 0 | `<logs>/clippy.log` |
| The changed Rust test over the base contract inputs (the published view) | before the corpora and schemas changed, on `25b7a4f1`, whose five corpora and schemas are `5ab8079b`'s: `cargo test ... -p arkdeck-agentd --bin arkdeck-agentd control_action` | 0; 5 passed | `<logs>/published-view-agentd.log` |
| SDD | `ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python sh scripts/check-sdd.sh` | 0; `check_sdd`: 0 errors, 0 warnings | `<logs>/check-sdd.log` |

## CI

Pending: the PR's GitHub CI is the unified gate.

## Not run, and why

- **Resume, the console challenge, the Job interlock, dispatch (`kill -r`), the lifecycle audit and
  recovery.** Out of this slice; no lifecycle driver is composed.
- **A health proof.** It would run the registered 3.2.0d hdc and its server; the seam answers its
  facts instead.
- **Participant rows.** A critical Job gate, a device or a Target in a published preview waits for
  the maintainer's decision on those open arrays.
- **`orchestrationClockUntrusted` on the other four methods.** Swift and the Rust C1 owner give it
  there too, and their schemas do not publish it. Not asked for here.
- **A device, a real HDC server, the installed Runtime; the full unified gate** (#2015: the PR's CI
  runs it).
