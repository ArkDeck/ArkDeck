# TASK-XPA-012 — the Swift oracle of the tool-selection control-action store (macOS, 2026-09-19)

TASK-XPA-012 remains in progress. Base: protected main `cb246207`; no stack. Recorded and checked on `7b5872f1`; #2025–#2036 changed nothing the test reads. This is a Swift-only
contract slice before the Rust port of `RuntimeToolSelectionControlActionStore` (the next slice):
one new contract test and the oracle it records. No production Swift source, control schema, corpus,
Catalog, entitlement, `openspec/specs` or constitution change. Nothing here is device evidence
(POL-VERIFY-001, POL-MODE-001).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining |
| --- | --- | --- |
| `runtime.tool.select` routed and answered as Swift's daemon without a tool-selection owner, and the Rust CLI leaf (#2032, `tool-select-route-run.md`); the HDC control-action owner, its store, record and impact values over the managed server (#2017) | `ToolSelectionStoreOracleContractTests`: the production Swift store's files for one selection in every state its records hold, the transitions that led there and each record's projection, checked in at `rust/tests/fixtures/tool-selection-store` | The Rust port of the store and its records over #2017's values (the human action, challenge and receipt values are new there), Rust-written records read back by Swift, `tools.json`'s selection writes, and the owner's composition (after C2 and a maintainer ruling; see `tool-select-route-run.md`) |

## What the oracle holds

The production `RuntimeToolSelectionControlActionStore` writes one record per request identity,
`action-<sha256(actionRequestId)>.json`, as RFC 8785 canonical JSON (`arkdeck.cli.canonical-json/1`,
no trailing newline), under an empty `.lock`. The test drives one request per timeline through the
record's own transitions and the store's compare-and-set replacement, with the clock fixed at
2026-09-01T00:00:00Z plus 1000 s per timeline:

| Request | State | Generation | After `begin` |
| --- | --- | --- | --- |
| `oracle-observing` | `observing` | 1 | (begin only) |
| `oracle-facts-unavailable` | `previewDrifted` | 2 | invalidated(tool.selectionFactsUnavailable) |
| `oracle-preview-ready` | `previewReady` | 2 | publishing |
| `oracle-blocked` | `blocked` | 2 | publishing(blocked) |
| `oracle-blocked-expired` | `expired` | 3 | publishing(blocked) → invalidated(controlAction.expired) |
| `oracle-preview-drifted` | `previewDrifted` | 3 | publishing → invalidated(tool.selectionPreviewDrifted) |
| `oracle-awaiting` | `awaitingImpactApproval` | 3 | publishing → requestingImpactApproval |
| `oracle-expired` | `expired` | 4 | publishing → requestingImpactApproval → invalidated(controlAction.expired) |
| `oracle-challenged` | `awaitingImpactApproval` | 4 | publishing → requestingImpactApproval → issuingInteractiveChallenge |
| `oracle-restarted` | `previewDrifted` | 5 | publishing → requestingImpactApproval → issuingInteractiveChallenge → invalidated(controlAction.runtimeRestarted) |
| `oracle-approved` | `approvalRecorded` | 5 | publishing → requestingImpactApproval → issuingInteractiveChallenge → recordingInteractiveApproval |
| `oracle-failed-before-launch` | `failed` | 7 | publishing → requestingImpactApproval → issuingInteractiveChallenge → recordingInteractiveApproval → prepared → failedBeforeLaunch(tool.lifecycleFailedBeforeLaunch) |
| `oracle-prepared` | `dispatchPrepared` | 6 | publishing → requestingImpactApproval → issuingInteractiveChallenge → recordingInteractiveApproval → prepared |
| `oracle-launched` | `outcomeUnknown` | 11 | publishing → requestingImpactApproval → issuingInteractiveChallenge → recordingInteractiveApproval → prepared → audit(impactPreview) → audit(confirmation) → audit(intent) → audit(actualCommand) → audit(launchWindowEntered) |
| `oracle-succeeded` | `succeeded` | 14 | publishing → requestingImpactApproval → issuingInteractiveChallenge → recordingInteractiveApproval → prepared → audit(impactPreview) → audit(confirmation) → audit(intent) → audit(actualCommand) → audit(launchWindowEntered) → audit(outcome) → audit(reconciliation) → settled(succeeded) |
| `oracle-failed-after-launch` | `failed` | 12 | publishing → requestingImpactApproval → issuingInteractiveChallenge → recordingInteractiveApproval → prepared → audit(impactPreview) → audit(confirmation) → audit(intent) → audit(actualCommand) → audit(launchWindowEntered) → settled(failed, tool.selectionPublishFailed) |
| `oracle-lifecycle` | `outcomeUnknown` | 13 | publishing → requestingImpactApproval → issuingInteractiveChallenge → recordingInteractiveApproval → markSelectionPrepared → lifecycle Supervisor and executor |

`oracle-lifecycle` comes from the production lifecycle Supervisor and `HDCProcessLifecycleExecutor`
launching the fake HDC fixture, as `RuntimeToolSelectionControlActionContractTests` drives it: its
eight audit rows are the ones production writes before the daemon exits for recomposition. Every
other audit payload is synthetic, because the store keeps audit payloads as opaque objects; they carry
values that exercise the canonical encoder: a key above the basic plane beside one in U+E000…U+FFFF
(JCS orders keys by UTF-16 code unit), escaped quotes, backslash, a tab and U+0001, non-ASCII text,
`</script>`, the largest exact integer, and three binary64 numbers (`0.25`, `1e-7`, `1e21`).

`projections.json` is `store.list()` projected (`arkdeck.control-action/1`), in the store's
creation-then-identity order: what `control-action.show` and `.list` answer for these records.
`cases.json` names each record's file, state, generation and the transitions that led there;
`provenance.json` pins the producer, the store's bounds and each file's SHA-256.

## How the test holds it

The records carry random identities (`UUID()` in the control action, its preview, its human action,
challenge and receipt), and the preview digest covers two of them, so a recording can never repeat
the old bytes. Without the recording variable the test therefore checks the checked-in oracle
three ways:

0. **Pinned.** Every checked-in file, and no other, has the SHA-256 `provenance.json` pinned.
1. **Read back.** A private copy of `records/` (the store opens only an owner-private directory of
   owner-private files) is listed by the production store: every record is its own canonical bytes,
   its state and generation are the recorded ones, and the projections equal `projections.json`.
2. **Played again.** The same timelines, played through a fresh production store, leave the same
   records once random identities and the preview digest over them are set aside; the lifecycle record
   is not played again.

A change to the store's format, validation or transitions therefore fails this test until the oracle
is recorded again, which the Rust port then has to follow. A negative probe showed the second check
bites on its own: with the provenance check not yet written, one synthetic audit value of
`oracle-launched` changed from 8 to 9 (still canonical, invisible to the projection) failed exactly
that record's played-again comparison and nothing else.

Found while recording: the store admits `failed` only from `dispatchPrepared`, not from
`approvalRecorded`, although `failedBeforeLaunch` accepts both; production always prepares dispatch
first. The oracle follows production.

## Recording

Recorded 2026-09-19 21:39 CST on base `7b5872f1` with
`ARKDECK_RUST_TOOL_SELECTION_STORE_RECORD=/private/tmp/arkdeck-tool-selection-store-oracle-record-213404
sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter ToolSelectionStoreOracleContractTests`
(1 test, 0 failures, 25.0 s), then copied unchanged into `rust/tests/fixtures/tool-selection-store`:
21 files — 17 records and the empty `.lock` under `records/`, `cases.json`, `projections.json` and
`provenance.json`, which pins the SHA-256 of every other file. No path, user or host name of the
recording machine appears in them; the lifecycle record names the test's fixed root
`/private/tmp/arkdeck-tool-selection-store-oracle`.

The first recording attempt failed and was discarded: its `oracle-failed-before-launch` timeline
failed straight from `approvalRecorded`, which the store refuses (`resourceConflict`, "control action
changed or update replaces immutable facts"), as noted above.

## Local targeted checks

Run 2026-09-19 on this worktree through the shared SwiftPM runner (one build lock across
worktrees); each exit code was read directly.

| Check | Command | Result |
| --- | --- | --- |
| The oracle, compare mode, beside the existing tool-selection contract tests | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'ToolSelectionStoreOracleContractTests\|RuntimeToolSelectionControlActionContractTests'` | exit 0; 6 tests, 0 failures (21:49:32) |
| Negative probe (one synthetic value of `oracle-launched` changed, before the provenance check existed) | `… test --filter ToolSelectionStoreOracleContractTests` | exit 1; one failure, `oracle-launched`'s played-again comparison; the fixture was then restored from the recording (`diff -r` clean) |
| SDD | `sh scripts/check-sdd.sh` | `check_sdd: 0 error(s), 0 warning(s)` |

No Rust source changed, so no Rust check ran; the unified local gate was not run (the PR's CI is the
gate, `AGENTS.md`, #2015).

## CI of #2032

The route slice's record could not carry its own CI: #2032 merged (squash `6d304c14`, tree identical
to its head `899e049f`) before the amendment was pushed. Its checks, all on head `899e049f`
(2026-09-19, 13:25–13:30 UTC):

| Check | Run | Result |
| --- | --- | --- |
| `guard`, `ds-tokens` | 35445726431 | pass |
| `open-pr` | 35445726473 | pass |
| `plan`; `rust-checks`: host-independent checks, Rust workspace on `ubuntu-latest`, `macos-26` and `windows-latest`; `swift` (the aggregate) | 35445726616 | pass |
| `swift-tests`, `app-build`, `ds-interactions` | 35445726616 | skipped by the plan (no Swift, App or design-system input changed) |

## CI

Recorded once this PR's CI finishes.
