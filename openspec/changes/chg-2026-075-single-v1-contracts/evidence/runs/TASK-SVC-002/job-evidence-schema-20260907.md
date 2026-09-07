# The published job.evidence schema did not describe what the daemon publishes — 2026-09-07

Closes residual 1 of
`evidence/runs/TASK-SVC-001/job-evidence-unknown-steps-20260907.md` (#1760).
Filed under `TASK-SVC-002` after the Task reached `done`, on the precedent of
#1744/#1746/#1747/#1748. `TASK-SVC-002` is the Task that declares
`spec/control/methods/**` alongside `Tests/ArkDeckContractTests/**`;
`TASK-SVC-001`, which owns the daemon that emits these frames, does not.
`TASK-XPA-001` also declares the directory but is `blocked`.

## What was wrong

`spec/control/methods/job.evidence.json` published `actualEffect`,
`actualStepKinds`, `bindingRevision` and `parameters` as non-nullable and
required. The daemon has emitted `null` for all of them whenever an evidence
read is degraded — verified against the shipped build on 2026-09-07:

```
$ arkdeck job evidence --job job-c9274a31cb5ba7c8aad61451416af4f4 --json
  "actualEffect" : null,  "actualStepKinds" : null,
  "bindingRevision" : null,  "parameters" : null,
```

The schemas are derived from frames a contract-test run records, and no test
had ever exercised a degraded evidence read, so the corpus contained only
successful frames and the derivation could only publish the success shape. The
guard was silent about it because it validates the committed corpus, and the
committed corpus did not contain the shape.

The two tests added by #1760 exercise both degraded shapes, so a re-recorded
run now carries them.

## What changed

Recorded a full contract-test run with `ARKDECK_CONTROL_FRAME_LOG` and
re-derived:

```
$ ARKDECK_CONTROL_FRAME_LOG=<dir> swift test --package-path Packages/ArkDeckKit --parallel
  2455/2455, 0 failures
$ python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --derive-method-schemas <dir>
  derived 96 method schemas from 1242 frames; corpus written
```

`spec/control/methods/job.evidence.json` — `actualEffect` and `bindingRevision`
become `["null", …]`, `actualStepKinds` and `parameters` become an `anyOf` with
a null branch. **`providerId` and `executionMode` stay non-nullable**, which is
the mechanical confirmation that #1760 removed those two violations: they are
the only two of the six the daemon no longer nulls.

`agent.status.json`, `doctor.json`, `health.json`, `job.status.json` — only
`x-arkdeck-sampleCounts` moved, describing this derivation run. No shape
changed.

`Fixtures/ControlFrames/job.evidence.jsonl` and `doctor.jsonl` — 8 → 10 frames
each; both gained the two shapes the new tests exercise.

## The 49 corpus files this change deliberately does not touch

The derivation rewrites the corpus for every method that has frames, and the
recorded identifiers (`ART-…`, `imp-<uuid>`) differ every run, so a raw
re-derivation touches 51 corpus files. Each of the other 49 was compared by the
generator's own `signature()` fingerprint — key sets with member types,
recursively — before being reverted:

```
51 corpus files changed; 2 changed shape:
   doctor.jsonl
   job.evidence.jsonl
```

The 49 reverted files are byte-different but shape-identical, and the frames
they hold are real frames a daemon answered on an earlier run. Keeping them
leaves a diff a reviewer can actually read. They will be rewritten by the next
re-derivation like any other.

## Verification

- `ControlMethodSchemaContractTests` passes with the new schemas and corpus
  (one skip: the record-and-validate test needs `ARKDECK_CONTROL_FRAME_LOG`).
- Negative control: restoring only the old `job.evidence.json` fails both
  `testEveryRecordedFrameInTheCommittedCorpusValidates` and
  `testAnUnrecordedResultFieldIsRefused`. The schema change is load-bearing,
  and the failure is proof the shipped schema did not describe the daemon.
- `ControlProtocolGenerated.swift` and `Contracts/control-protocol.json` are
  untouched: the protocol vocabulary, the 96 methods and the contract identity
  are unchanged. This is a schema-shape correction, not a protocol change.
- Full package suite and the unified gate: see the PR.

## Residuals

Unchanged from #1760, minus the one this closes:

1. `AgentRuntimeExecutor.receipt` still collapses unknown steps to `[]` in the
   persisted `RuntimeAgentExecutionReceipt`.
2. `ArkDeckApp/Features/History/RuntimeHistoryView.swift` does not yet read
   `actualStepKindsWereReported`; `ArkDeckApp/**` is declared by no SVC Task.
3. The GJ-4 blocker itself — `post-flash binding changed before verified alias
   publication` — is untouched by both PRs.
