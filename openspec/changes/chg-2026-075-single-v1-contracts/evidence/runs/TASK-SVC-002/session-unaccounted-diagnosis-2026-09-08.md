# Naming the unaccounted Session instead of counting it — 2026-09-08

- Task: TASK-SVC-002
- Base: protected `main` `50dd15e9` (#1776).
- Measured against the installed Runtime built from `main` `6ba5a0b9`, daemon
  SHA-256 `c1d313a0229d7f756db9adebd8b64b250bae5f8d0f6a6f0ad5e2b01eaad40f45`.

## The dead end

On the installed Runtime, `session list` exits 69:

```json
{"code":"operationUnavailable","phase":"sessionOwner","newDispatchCount":0,
 "message":"Session catalog contains unaccounted content; inspect runtime storage status"}
```

Following that instruction, `runtime storage status` answers with a count:
`sessionCount: "0"`, `unaccountedSessionCount: "1"`, `measurementIncomplete: true`,
`usedBytes: "4017489603"`. It does not say which leaf, and it does not say why.
The only way to learn either was to read the Sessions directory tree by hand —
which is how the historical Session was identified in the first place: one
directory from 2026-08-02 holding `.session-identity.json` and a five-event
`journal.jsonl`, with no `manifest.json`.

`session show`, `session export preview` and the pin/unpin and cleanup paths all
refuse through the same `sessionRows` guard and the same sentence.

## What changed, and what did not

The refusal **decision** is untouched. Every operation that refused before still
refuses, the existing
`testUnaccountedContentCannotBeHiddenByAPartialSessionList` passes unmodified,
and no historical file is read differently, moved, repaired or invented.

What changed is that the scan now carries *why* it could not account for each
leaf, and the refusal says so:

```text
Session catalog contains unaccounted content: 2026/08/rockchip-session-stranded
(unreadable), not-a-year (outsideSessionLayout)
```

`SessionRetentionCatalogSnapshot` gains `unaccountedSessions: [UnaccountedSession]`
alongside the existing `unknownSessionIDs`, with a closed reason vocabulary:
`notRegistered`, `unreadable`, `duplicateIdentity`, `invalidIdentifier`,
`outsideSessionLayout`, `catalogMetadataCorrupt`. The summary in the refusal is
bounded at eight entries so a root with thousands of stray directories cannot
turn one refusal into an unbounded payload.

## A second defect found on the way

The scan's per-session loop wrapped identifier validation *and* the session
content read in one `do`/`catch`, so a correctly named directory whose content
could not be read was reported with the same outcome as a malformed name. Once
reasons became visible this surfaced immediately: the first fixture, a directory
named `rockchip-session-stranded` — a name the identifier validator accepts —
came back as `invalidIdentifier`, which would have sent an operator looking for a
typo that does not exist. The two failures now have their own `do`/`catch` and
their own reason.

## Verification

- New `SessionResourceContractTests.testUnaccountedContentIsNamedWithItsReasonInsteadOfACount`.
  Its fixture is the shape this host actually carries: a Session directory with
  its identity file and Journal and no manifest, beside content outside the
  layout. It asserts both are named with the correct reason, that the old
  "inspect runtime storage status" sentence is gone, that no manifest was
  invented, and that both remain on disk.
- `SessionResourceContractTests` 6/6, and `SessionCleanupContractTests`,
  `SessionExportContractTests`, `RuntimeStorageResourceContractTests`,
  `SessionSettingsContractTests`, `SessionArtifactStorageContractTests`
  90 tests, 0 failures.

## Still open, and not claimed here

This makes the blocked surface diagnosable. It does not publish a Session, and
`session list` on this host will still refuse — correctly — with the historical
leaf now named.

The producer remains absent: `SessionStorageTerminalFinalizer` has no production
caller (only `SessionArtifactStorageContractTests` constructs it), the
retention catalog holds `{"entries":[],"generation":0}`, and the seven Jobs this
host ran today wrote nothing under the Sessions root. Current Job → formal
Session → exact finalized export therefore cannot pass, and SVC-AC-05 and
SVC-AC-10 stay unmet. That producer is the slice already scoped and reviewed in
`session-publication-scope-review.md`; it is not delivered by this change and
this record does not claim otherwise.

The exact message the installed Runtime will print for the real 2026-08-02
directory has not been observed yet — that needs this change merged and a helper
rebuilt from protected `main`. The reason it will report is `unreadable`: the
directory carries no manifest, so `scanSession` cannot read it as a Session.
