# The Agent execution surface called a failed Job's evidence verified — 2026-09-08

- Task: TASK-SVC-002
- Base: protected `main` `50dd15e9` (#1776).
- Found by: real DAYU200 acceptance on a helper built from `main` `6ba5a0b9`,
  daemon SHA-256 `c1d313a0229d7f756db9adebd8b64b250bae5f8d0f6a6f0ad5e2b01eaad40f45`,
  Catalog digest `508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684`.
  This record covers the repair only; the Journey results belong to TASK-SVC-005.

## The two surfaces disagreed about one Job

`deploy.native-library.app-owned@1` ran its deterministic rollback fixture on the
attached DAYU200 and failed as designed. The two published evidence surfaces then
answered differently about `job-5b91a6a9f87b23fc689aa12584469758`:

| Read | `status` | `blockers` |
| --- | --- | --- |
| `agent run` (embedded `result.evidence`) | `verified` | `[]` |
| `job evidence --job <id>` | `artifactIntegrityFailed` | `["artifactIntegrityFailed"]` |

`job.evidence` also reported `missingRequiredArtifacts: ["verification-report.json"]`.
`deploy.native-library.app-owned@1` declares that Artifact required, the load
verification never ran, and it was never published. The other three Jobs of the
same window — `job-06c4e41e2f5177afc96b6cd724b1be37`,
`job-458fadbe5a6f543ab35832a88ff7093b`, `job-a48fdb55ba96e68256b566848d39c538`,
all `succeeded` — agreed on `verified` / `[]`. Only the failure path diverged.

## Why

`AgentDaemon.executionResultProjection` derived its own blocker set. It appended
`artifactIntegrityFailed` only when the Artifact store could not be read or an
Artifact that exists failed verification, and `stepKindsUnprovable` when the
typed steps were unprovable. It never asked which *required* Artifacts are
absent. This Job's store was readable and every Artifact in it verified, so the
weaker derivation found nothing and `status` fell through to `verified`.

`RuntimeJobResourceReader.evidence` — the `job.evidence` producer — asks all of
it: descriptor availability against the record's own Catalog digest, the
intentionally-omitted set, Artifact ownership against the Job's provider,
operation, target and materialized binding, `evidenceInventory`'s integrity
flag, the missing required set, terminality, and the unprovable-steps fact.

Two derivations of one record, and the weaker one was published to the surface
an Agent reads. This is the family #1762 fixed on the Job read surface: a
result that cannot prove itself must not answer `verified`, and every gate that
reads only `blockers` let this one through.

## Repair

The derivation moves into one place, `RuntimeJobResourceReader.evidenceFacts`,
and both surfaces call it. `job.evidence` keeps its own reason ladder and its
own published shape; the Agent projection keeps its own shape too — it still
strips `parameters`, `traceProbeBefore` and `traceProbeAfter`, and still maps
its two-value `status` as `verified` when there are no blockers and `blocked`
otherwise. No key, type or vocabulary on either surface changes: `blockers` and
`status` are already open strings in the published per-method schemas, and only
the values on the failure path move. The Agent projection also stops judging a
record by this build's descriptor when the record was admitted under a different
Catalog digest, which is what the Job surface already did.

## Verification

- New `RuntimeAgentExecutionContractTests.testAgentEvidenceAgreesWithJobEvidenceWhenARequiredArtifactIsMissing`:
  a terminal `flash.full-restore@1` Job publishes `flash-report.json` and never
  publishes the required `post-flash-facts.json`, so the store is readable and
  everything in it verifies — the exact shape the weaker derivation missed. The
  assertion compares the two surfaces' `blockers` rather than copying a literal,
  so a future fact taught to one surface must be taught to the other.
- Negative control: with `AgentDaemon.swift` reverted and the rest of the change
  in place, the test fails with the agent surface publishing
  `["stepKindsUnprovable"]` against the Job surface's
  `["artifactIntegrityFailed", "stepKindsUnprovable"]`.
- `RuntimeAgentExecutionContractTests` 27/27, and
  `JobReadResourcesContractTests`, `HardwareEvidenceProjectionContractTests`,
  `AgentRuntimeExecutorContractTests`, `DeviceCandidatesContractTests`
  74 tests, 1 skipped, 0 failures.

## Not covered here

The same real-device rollback Job published no evidence that the previous
library was restored or that the target process recovered: its only Artifact is
`publish-report.json`, carrying the ghost fixture's
`publishedSha256 260a533ae2b02e23810aa5ab6ea9c1a5cf4524b19484ede66cb4dc0b7bb86d3a`.
The runbook requires the rollback leg to prove both. That is a separate gap in
`deploy.native-library.app-owned@1`'s evidence, not in this projection, and it
is recorded — unverified — for the Journey record rather than repaired here.
