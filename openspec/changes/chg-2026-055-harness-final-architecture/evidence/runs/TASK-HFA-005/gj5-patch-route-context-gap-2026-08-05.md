# GJ-5 — the repair leg's real blocker, measured (2026-08-05, third run)

Third current-digest run, after `gj5-current-digest-2026-08-05.md` (no decision
producer) and `gj5-local-agent-gateway-2026-08-05.md` (producer present, task
submitted without a workspace scope). This one closes the scope question and
finds what is actually in the way.

## Scope and target

- Catalog digest: `e2f8eb6592aaeeec37c63a01708db2325b38c798b0f8272228ba0fccc2cfd0aa`
- Target: `TGT-958780b2ffb7`, binding revision `2`, DAYU200 / OpenHarmony `7.0.0.36`
- Decision producer: `claude-code-cli-gateway@1`, model `sonnet`
- Task: `HTASK-9BFBEFC90953`, evolution workspace `evolution-6ec5d24fec3c5b480be2`
  (materialized from `demo-app`, base revision
  `084dddd2b8626fd7f82e05b4fea639366a44c30791d153a117b22950bc459c24`)

## Declaring the workspace scope: how to get the base revision right

`--workspace-allowed-paths` requires `--base-workspace-revision`, and the
revision is computed over **the declared paths**, not over the whole tree — so
a revision read for a different glob set is the wrong number. Two product
paths give the right one, and neither is a guess:

- `arkdeck capability draft --operation workspace.build-openharmony@1
  --inputs-file <projectRef>` reports `workspaceIdentitySHA256`,
  `workspaceRevision` and `workspaceFileScopesDigest` for that operation's
  scope;
- submitting with the wrong value is refused with both numbers in the message:
  `baseRevisionMismatch(expected: 952a688b…, actual: 084dddd2…)`.

With `084dddd2…` the submission is accepted and the evolution workspace is
materialized. The previous run's `unauthorizedScopeMissingDiagnostics` does not
recur.

## The loop then reaches the same place and stops for a different reason

```text
 1 admitted        taskAdmitted
 2 jobDispatched   baselineTargetObservation
 3 jobObserved     operationSucceeded:observe.device@1
 4 evaluation      inconclusive:collectMoreEvidence
 5 jobDispatched   collectDeclaredEvidence
 6 jobObserved     crashLedgerAwaitingDerivedAnalysis
 7 jobDispatched   analyzeCapturedCrashLedger
 8 jobObserved     operationSucceeded:analyzer.extract-crash-signature@1
 9 evaluation      inconclusive:collectMoreEvidence
10 jobDispatched   deployBaselineCrashFixture
11 jobObserved     baselineCrashFixtureDeployed
12 jobDispatched   collectDeclaredEvidence
13 jobObserved     crashLedgerAwaitingDerivedAnalysis
14 jobDispatched   analyzeCapturedCrashLedger
15 jobObserved     operationSucceeded:analyzer.extract-crash-signature@1
16 evaluation      criteriaFailed
17 humanBlocked    insufficientDiagnosticEvidence
```

Consumed: `rounds 6/24`, `modelCalls 7/32`, `e1Mutations 1/8`,
`artifactBytes 1,745,610/67,108,864`, human actions `0`. `EVAL-6BA0EC9EC735`
is a measured FAIL (`applicationLiveness: unhealthy`, watermark advanced to a
new `jscrash-com.example.waterflowdemo-…` entry after the deployment).

`insufficientDiagnosticEvidence` is **the model's own reason code**, not a
product refusal: at a `patchProposalRequired` decision the model may answer
`requestHuman`, and it did. It is not being blocked — it is declining, and the
question is whether it is right to decline.

## It is right to decline: nothing in the context can support a patch

A `proposePatch` must carry `baseWorkspaceRevision`, `patchSha256`,
`unifiedDiff`, `touchedFiles` and `expectedChangedSymbols`. A unified diff needs
exact context lines. What the model is given at that moment is:

- the goal text and typed desired state (bundle, ability, presets, declared
  crash signature),
- evaluator measurements — short scalars such as `latestCrashSignature`,
  `matchingCrashCount`, `crashLedgerWatermark`,
- artifact **descriptors**: `HarnessContextArtifact` is documented in-source as
  "identity, size, digest prefix and whether it verified. **Never content.**",
- the allowed file globs and the base revision.

So the log bytes are not in the context by deliberate design, and the source
bytes are not either. Nor can the model go and fetch them:
`DebugCrashTaskHandler.permittedOperations` is
`{observe.device, capture.diagnostics, analyzer.extract-crash-signature,
debug.hap, workspace.create-checkpoint, workspace.apply-patch,
workspace.build-openharmony, workspace.run-tests, workspace.revert-patch}` —
it contains no source-reading operation, and `offeredOperations` can only
narrow that set, never widen it. `workspace.inspect-source@1` and
`workspace.read-source-range@1` are published and currently `available`, but a
debugCrash task may not choose them; and even if it could, their output is an
artifact, whose content the same boundary keeps from the model.

That is a closed loop with no path to a patch. Adding the read-only operations
to the handler would not open it on its own — the artifact-content boundary is
the load-bearing half, and it is an intentional invariant, so widening it is a
maintainer design decision rather than a defect to be patched over.

## Status

GJ-5 stays `IMPLEMENTING`. The blocker is now located precisely and is neither
of the two previously recorded ones: not a missing decision producer, and not a
missing workspace scope or grant — the repair leg never reaches the workspace
capability, because the model is asked for a diff against files no product path
lets it read.

Two shapes would close it, and choosing between them is a design decision:
give the decision context a bounded, redaction-aware excerpt channel for the
evidence and the touched files; or let the deterministic handler carry the
repair itself for the class of crashes whose fix is derivable from the
evaluator's own measurements. Nothing here should be widened silently — the
"never content" boundary is what keeps the model's blast radius equal to its
typed proposal.
