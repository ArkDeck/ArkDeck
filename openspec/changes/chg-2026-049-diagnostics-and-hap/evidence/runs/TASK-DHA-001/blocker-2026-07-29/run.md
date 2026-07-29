# TASK-DHA-001 blocker run — 2026-07-29

- Base protected-main OID:
  `dac5f82a41a2488c05122f0ac141ab139f147e3b`
- Evidence class:contract/static-analysis blocker
- Executor:agent
- Device dispatch:0
- Raw device artifact: none

## Work performed

1. Synced and confirmed the CHG-2026-049 proposal merge at the base OID.
2. Ran the pre-change full ArkDeckKit Swift suite successfully.
3. Implemented local, uncommitted T00/T14 scaffolding and ran focused runner,
   artifact and job-engine contract tests successfully.
4. Began T12/T13 typed plan construction and traced
   `captureRemoteStdout` from the published operation Catalog through the
   generated descriptor, workflow-step JSON Schema and Swift validator.

## Reproducible inspection

```text
rg -n -C 10 '"kind": "captureRemoteStdout"' Catalog/operations/*.json
rg -n -C 20 'catalogStdoutArguments|captureRemoteStdout' \
  openspec/contracts/workflow-step.schema.json \
  Packages/ArkDeckKit/Sources/ArkDeckCore/WorkflowStep.swift
```

Observed facts:

- `capture.diagnostics@1/capture-hilog`,
  `debug.hap@1/capture-diagnostics` and
  `flash.dayu200@1/capture-post-flash-diagnostics` declare
  `captureRemoteStdout`.
- The only schema-valid stdout catalog is `arkui-ui-dump`; the only allowed
  action IDs are UI Dump recipes.
- The Swift validator enforces the same UI-Dump-only pair.
- Catalog generation validates the step kind but carries no action identity,
  so it cannot reject this mismatch before generating Runtime descriptors.

## Result

`TASK-DHA-001` stop condition triggered. A truthful HiLog WAL intent cannot be
constructed on the pinned contracts. The implementation was not made to pass
by relabeling HiLog as UI Dump or bypassing the validator.

- `DHA-AGENT-001`:partial local implementation only; not submitted as evidence
- `DHA-ART-001`:partial local implementation only; not submitted as evidence
- `DHA-CAP-001`:blocked before provider dispatch
- `DHA-HAP-001`:blocked for its optional diagnostics leg
- `DHA-HW-001/002`:not run; hardware and host dispatch count both 0

## Follow-up

`CHG-2026-050-diagnostics-step-contract` proposes the scoped Core remediation.
The local implementation draft remains uncommitted and must not be submitted
until that change is approved, implemented and CHG-2026-049 receives fresh
readiness.
