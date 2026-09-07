# job.show claimed no step ran whenever the record said nothing — 2026-09-07

Closes residual 2 of
`evidence/runs/TASK-SVC-002/unprovable-steps-not-verified-20260907.md` (#1762).
`TASK-SVC-002` declares `RuntimeJobReadProjection.swift`,
`spec/control/methods/**`, `Tests/ArkDeckContractTests/**` and the change dir.

## What was wrong

`RuntimeJobReadProjection.show` publishes the durable record. Five of its
optional fields spell `?? .null` when the record is silent — `materializedPlanDigest`,
`materializedBindingRevision`, `materializedStableIdentitySha256`,
`ringCoverage`, `screenSequence`. `actualStepKinds`, in the same literal, spelled
`?? []`.

An empty list is not a value the Runtime ever stores. The only writer is the
step-intent path (`RuntimeJobEngine.swift:3902-3905`), which always appends at
least one element; there is no reset, no clear, no `= nil` anywhere. So a
published `[]` on `job.show` could only ever be that collapse, and it reads as a
positive claim that no typed step ran.

Measured against this host's durable state on 2026-09-07 — 1,897 job records
across the live and retired state directories:

```
records=1897  nil-or-absent=38  empty-array=0

    6  cancelled           flash.dayu200            1  waitingForRecovery  flash.dayu200
    6  cancelled           input.tap@1              2  waitingForRecovery  flash.full-restore@1
    6  recovered           flash.dayu200            2  cancelled           debug.hap@1
    5  failed              flash.dayu200            2  failed              workspace.sign-openharmony-hap@1
    4  failed              flash.full-restore@1     3  failed              capture.diagnostics@1
    1  recovered           flash.full-restore@1
```

Zero records hold an empty array, which confirms the mechanical premise. **Seven
of the 38 are `recovered`** — a terminal success-class state — and all seven are
Flash Jobs. Their steps ran inside the ArkForge lane and never reached the
record (the engine's own note at `RuntimeJobEngine.swift:5033-5042` describes
exactly this), so `job.show` was reporting a Job that recovered a flashed device
as having run no typed step at all.

## Change

One line, matching its five neighbours:

```swift
"actualStepKinds": record.actualStepKinds.map { .array($0.map(JSONValue.string)) } ?? .null,
```

and a re-derivation, so `spec/control/methods/job.show.json` declares the field
`anyOf` array|null. It stays `required`: the key is always present, only its
value can be null — the same shape `job.evidence.json` has carried since #1761.

The CLI validates `job.show` by exact key-set equality and never inspects this
value (`CLIJobResources.swift`, `case "show"`), so nothing downstream changes.

## Verification

- `JobReadResourcesContractTests.testJobShowSaysNothingRatherThanClaimingNoStepRan`
  — a record with no step list publishes `.null` and keeps the key; negative
  control in the same test: a record that does list its steps still publishes
  them, with an identical key set. Reverting the one line fails it.
- **The recording guard proved itself here.** The first full run after the code
  change, with `ARKDECK_CONTROL_FRAME_LOG` set, went red on
  `testFramesRecordedByThisRunValidate`:
  `control-frames-26598.jsonl:4 job.show:` — the newly emitted null did not
  validate against the still-unchanged schema. After the re-derivation the same
  recorded run is green, so every frame this run emitted was checked against
  the new schemas. That red is the feedback that was missing when this family of
  defects first landed: no test produced the shape, so nothing complained.
- 50 of the 51 corpus files a raw re-derivation rewrites were compared by the
  generator's own `signature()` fingerprint, found shape-identical, and
  reverted, as in #1761 and #1762. Only `job.show.jsonl` gained a shape.
  `health.json` moved only in `x-arkdeck-sampleCounts`.
- Full package suite (recording active): 0 failures. Unified gate: see the PR.

## Residuals

Carried forward from #1762, minus the one this closes.

1. **`job.show` still cannot see ArkForge-lane steps.** It is a pure record
   projection (`RuntimeJobResourceReader.swift:30` hands it only the record and
   status) and never calls `durableActualStepKinds`, which is the derivation
   `job.evidence` uses to recover journal-proven steps. After this change the
   two surfaces answer different questions honestly — show says "the record does
   not say", evidence says what the journal proves — but a caller reading only
   `job.show` still learns nothing about the 7 recovered Flash Jobs above.
   Either plumb the derivation into the `job.show` read path or have `job.show`
   defer to the `evidence` pointer it already publishes.
2. **`durableActualStepKinds` collapses the same way for non-ArkForge
   operations** (`RuntimeJobEngine.swift:5053-5056` returns
   `record.actualStepKinds ?? []` before the flash guard), so `job.evidence`
   still reports `[]` for the 2 failed `workspace.sign-openharmony-hap@1`
   records that carry a durable step intent. **Deliberately not fixed here.**
   Since #1762 an unprovable step list also inserts the `stepKindsUnprovable`
   blocker, which makes `RuntimeCLI.evidenceIntegrityExit` non-nil and the CLI
   exit non-zero. Extending the nil to every operation would therefore change
   exit codes for the 11 cancelled/failed non-flash records above, so it wants
   its own PR and its own decision. The scan confirms the success path is not at
   risk: **no succeeded non-flash record has a nil step list.**
3. `agent.run` and `agent.status` still declare `evidence.actualStepKinds`
   non-nullable; their behaviour is fixed but publishing the null branch needs
   an agent-execution fixture whose Job is a terminal Flash Job with no journal.
4. `ArkDeckApp/Features/History/RuntimeHistoryView.swift:947` still ignores
   `actualStepKindsWereReported`; `ArkDeckApp/**` is declared by no SVC Task.
5. The GJ-4 blocker — `post-flash binding changed before verified alias
   publication` — remains untouched.
