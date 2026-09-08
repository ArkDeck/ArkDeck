# Current Job failure frames — 2026-09-08

Task: `TASK-SVC-002`.

Base: `6a8a06fc2f437c790322c50871173b72a9ca80c9`.
Classification: host contract regression using fixture Provider receipts and
the production Runtime engine/control handler. This is not hardware evidence.

## Existing mismatch

An observation that receives an unregistered target row already produces a
structured `RuntimeOperationFailure`. The GJ-1 diagnostic regression reached
this existing branch and recorded a valid production `job.show` response that
the method schema rejected: `result.job.failure` only permitted `null`.

Checking every method carrying the same failure projection found another
incomplete schema, `job.reconcile`. Its existing terminal failure response also
requires a string `finishedAtUtc` and a `nextAction` without `retryAfter`; its
samples had covered only a waiting response. `job.list`, `job.run`, `job.status`
and `job.result` already described the structured failure shape. The subsequent
full recording validation found the related `job.result` refusal branch:
`resultNotReady` for `waitingForRecovery` carries a reconcile `nextAction`
without `retryAfter`, whereas its error-details schema required that poll-only
field. This third method is repaired in the same change.

The same non-null failure was also read from the published `6a8a06fc` Runtime
for existing observation Job `job-176e1924577288f076562d33b44c6e9f`, after the
reviewed helper update at `2026-09-08T01:38:35Z`. Its unmodified CLI output is
`published-6a8a-readback/after/unknown-observation-show.json`, SHA-256
`66affeee610a121e7adf93ff85615622283c9ba9b41988650b5a3d77ffb73235`, under the
local evidence directory below. The Job remains unknown. All seven existing
Job IDs and the original Flash journals/bindings were preserved. This resource
read is not a new device execution or hardware PASS.

No producer is changed to hide its failure or replace it with null. This repair
records the missing production branches and derives the three affected method
schemas and corpus files together.

## Production coverage

`RuntimeJobEngineContractTests.testProductionJobFailureFramesAgreeAcrossReadbacksAndReconcile`
uses the existing HDC Provider and engine with two bounded fixture receipts:

1. Malformed target output becomes `waitingForRecovery` with `outcomeUnknown`.
   The handler answers run/show/status/list with the same five-field failure;
   result remains `resultNotReady`. The existing read-only reconcile proves
   non-execution and returns the engine's confirmed-failure terminal response.
2. Invalid UTF-8 becomes a confirmed failed observation. A later reconcile
   preserves its original failure. Both scenarios compare show/status/list/
   result after finalization, then repeat reconcile and check that the failure,
   original step intents and dispatch count are unchanged.

The test verifies the complete closed failure object, not only a non-null
marker. The schema remains closed to its existing fields; this changes no
permission, operation, retry policy, event or recovery proof. The exact current
control vocabulary, generated Swift contract and Catalog are unchanged.

## Derivation and verification

Raw host recording and logs are under `/private/tmp/arkdeck-svc-a-20260908`.

- The new production test passed (`job-failure-focus.log`), recording actual
  handler frames into `job-failure-control-frames`.
- After the relevant recording stopped, `generate-control-contract.py
  --derive-method-schemas` consumed 35 relevant frames: the existing three-method
  corpus, the new production run, and the complete GJ-1 recorder file containing
  the failing `job.show` response. The input/provenance files are
  `job-failure-schema-input-v2.jsonl` and
  `job-failure-schema-input-provenance-v2.json`. Original recordings remain intact.
- Only `job.show`, `job.reconcile` and `job.result` schemas/corpus were
  re-derived. The other 93 methods retain their current corpus and schemas. This avoids replacing
  complete method coverage with the narrow recording's method subset.
- The final unified gate passed in `job-failure-final-unified-gate.log`: common
  checks, 83 design-system tests, 2,459 parallel Swift selections, one serialized
  process-identity test and five Viewer scale tests. The complete diff selected
  no App build lane; no production App source changes here.
- After every recording process stopped, the separate
  `ControlMethodSchemaContractTests/testFramesRecordedByThisRunValidate` passed
  over all 1,281 final frames in 167 files, with zero failures
  (`job-failure-final-post-recording-validation.log`). The local frame manifest
  is `job-failure-final-frame-manifest.json`. Independent validation also passed
  over the earlier 1,304 SVC and 2,564 GJ-1 frames. The validator's execution
  inside the parallel suite and `generator --check` are not used as complete
  output-conformance proof.
- The first unified attempt exposed the `job.result` gap above and an XCTest
  expectation stall in the unchanged
  `AgentClientDeadlineContractTests.testBlockedWritesCannotOutliveTheSameDeadline`.
  An isolated rerun failed because the fixture received no connection: encoding
  its 3 MB request could consume the 200 ms deadline before opening the socket.
  The fixture now constrains its receive buffer and uses a 32 KB request. It
  keeps the same deadline and additionally proves a partial write occurred,
  the request did not finish, and the client closed. All nine deadline tests
  passed in `job-failure-deadline-fixture.log`. No production deadline changed.
  The failed runs remain in `job-failure-unified-gate.log` and
  `job-failure-deadline-isolated.log`.

This closes the schema coverage defect for SVC-AC-01/02/05/06 at the host contract
level; it does not close the remaining published-device or App acceptance.
The final SVC baseline must use the reviewed merge commit and final schema/
corpus digests, not this candidate's base or an old hardware result.
