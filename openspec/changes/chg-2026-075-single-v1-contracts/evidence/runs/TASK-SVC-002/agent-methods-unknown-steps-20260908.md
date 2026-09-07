# The last two evidence surfaces that declared a shape the daemon cannot honour — 2026-09-08

Closes residual 3 of
`evidence/runs/TASK-SVC-002/job-show-unknown-steps-20260907.md` (#1763), and
with it the `actualStepKinds` family opened by #1760.

## What was left

`agent.run` and `agent.status` embed the same evidence object as `job.result`,
and their published schemas declared `evidence.actualStepKinds` as a
non-nullable array. The daemon has answered `null` there since #1760, and #1762
added the `stepKindsUnprovable` blocker on that exact path — but neither PR
could publish the shape, because publishing it requires a **recorded frame**,
and no test drove an unprovable Job through those two methods.

This PR adds no product code. It is the fixture that produces the frame, plus
the derivation that follows from it.

## The fixture

`RuntimeAgentExecutionContractTests.testAgentStatusPublishesUnknownStepsAsNullAndRefusesToCallItVerified`
seeds a terminal Flash Job whose journal is gone — a terminal Job cannot carry
an unresolved intent, so a lost journal is the reachable way for durable state
to be unable to prove the typed steps of a Job that has already ended — and an
execution record that owns it. Both `agent.status` and a re-offered `agent.run`
then answer through `executionResultProjection`, which is the code under test.

Building that record meant satisfying the store's own invariants rather than
working around them, and they are worth naming because each one is a real rule:

- `schemaVersion` is `arkdeck.runtime-agent-execution/1`, not the intent's
  `arkdeck.agent-execution-request/1`.
- `intentFingerprintSHA256` must be the fingerprint of the canonical intent.
- `deadline - createdAt` must equal the intent's `maximumWaitMilliseconds`.
- A record that owns a Job must carry the submission request, and that request
  must be byte-identical to what the coordinator would have prepared from the
  intent — including `requestID: "agent-request-<fingerprint(executionID)>"`
  and `idempotencyKey: "agent-execution-<fingerprint(executionID)>"`.

## Result

After re-recording and re-deriving, all five published surfaces that carry this
fact agree that it can be unknown:

| method | path | nullable |
| --- | --- | --- |
| `agent.run` | `result.evidence.actualStepKinds` | yes |
| `agent.status` | `result.evidence.actualStepKinds` | yes |
| `job.result` | `result.evidence.actualStepKinds` | yes |
| `job.evidence` | `result.actualStepKinds` | yes |
| `job.show` | `result.actualStepKinds` | yes |

`health.json` moved only in `x-arkdeck-sampleCounts`. 49 of the 51 corpus files
a raw re-derivation rewrites were compared by the generator's own `signature()`
fingerprint, found shape-identical, and reverted; only `agent.run.jsonl` and
`agent.status.jsonl` gained a shape.

## A limit of the recording guard, worth writing down

`ControlMethodSchemaContractTests.testFramesRecordedByThisRunValidate` is what
caught the `job.show` change in #1763: it validates every frame in the recording
directory against the committed schemas, and went red until the derivation
caught up. **It did not go red for this change**, even though the same kind of
violation was present.

The mechanism: `swift test --parallel` runs each test method in its own
process, and the recorder writes one file per process
(`control-frames-<pid>.jsonl`). The validating test therefore only sees the
frame files that already exist when **its** process runs. A frame written by a
process that starts later is never validated by it.

So a red from that test is proof of a violation, but a green is not proof of
its absence. The derivation, not the guard, is the authority on what the
published shape must be. This is the same shape of silence that let the
original defect land in #1760 and survive #1761.

## Verification

- The new test asserts `actualStepKinds` is `null`, the status is not
  `verified`, and `blockers` carries `stepKindsUnprovable`, on both
  `agent.status` and `agent.run`. The `agent.run` leg was first written inside
  an `if` and was tightened to an unconditional unwrap precisely so it could not
  pass by not running.
- Negative control: removing the blocker line #1762 added to
  `executionResultProjection` fails the test.
- Full package suite with recording active: 0 failures. Unified gate: see the PR.

## Residuals

1. `durableActualStepKinds` returns `record.actualStepKinds ?? []` for every
   non-ArkForge operation (`RuntimeJobEngine.swift:5053-5056`), so `job.evidence`
   still reports `[]` for the 2 failed `workspace.sign-openharmony-hap@1`
   records that carry a durable step intent. Deliberately deferred: since #1762
   an unprovable list also drives a non-zero CLI exit, so extending it to every
   operation would change exit codes for 11 real cancelled/failed records and
   wants its own decision. No **succeeded** non-flash record has a nil list, so
   the success path is not at risk.
2. `job.show` is a pure record projection and never calls
   `durableActualStepKinds`, so it cannot see steps the ArkForge lane ran
   (`RuntimeJobEngine.swift:5033-5042` documents this).
3. `ArkDeckApp/Features/History/RuntimeHistoryView.swift:947` still ignores
   `actualStepKindsWereReported`; `ArkDeckApp/**` is declared by no SVC Task.
4. The GJ-4 blocker — `post-flash binding changed before verified alias
   publication` — remains untouched.
