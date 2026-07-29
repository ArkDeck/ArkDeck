# CHG-2026-050 Verification Plan

> Change:CHG-2026-050-diagnostics-step-contract@r1
> Status:planned
> Core baseline:CORE-2.1.0

## Environment

- protected-main checkout, macOS arm64
- Python stdlib/PyYAML catalog generator and Swift toolchain
- no device, HDC server, capability or real-hardware evidence required

## Acceptance matrix

| AC ID | Verification method | Expected result | Minimum evidence |
| --- | --- | --- | --- |
| `AC-WF-001-01` | existing workflow schema/Swift free-command negatives | executable/argv/shell/raw command remains unrepresentable and external dispatch is 0 | contract |
| `AC-WF-001-02` | Catalog actionRef generator matrix + JSON Schema/Swift parity + generated drift check | every published stdout step has an exact registered action pair; missing/unknown/misplaced or validator-incompatible pairs fail before generation/dispatch | contract |

## `AC-WF-001-02`

Positive matrix:

- the four existing `captureRemoteStdout` steps carry exact actionRef values;
- bounded HiLog and component-tree UI Dump accept their valid default and
  boundary typed inputs;
- generated `CatalogStepDescriptor` retains the exact pair byte-for-byte;
- the same constructed `WorkflowStep` passes JSON Schema and Swift validator.

Negative matrix:

- missing actionRef on a stdout step;
- unknown catalogId or actionId;
- actionRef attached to a non-stdout step;
- a registered Catalog pair removed from workflow-step schema or Swift
  validator (parity/drift failure);
- command-shaped keys or values, malformed filter tokens, invalid duration/
  budget, and caller-supplied remote path;
- generated file edited without matching Catalog source.

All negative vectors SHALL fail before provider dispatch. Tests SHALL not
substitute a fake dispatch success for construction/validation evidence.

## Negative and recovery tests

- No external effect occurs in this task; dispatch counter stays 0 for every
  invalid vector.
- Recovery semantics are unchanged. A stdout action that cannot produce a
  durable typed intent is rejected before intent append and therefore creates
  no outcome to reconcile.
- Existing journal/recovery and full Swift suites must remain green without
  weakened assertions.

## Deviations

No deviation is accepted. Adding a permissive generic catalog/action, runtime
fallback by stepID, or shell/argv escape is a failed result.

## Result gate

- [ ] `AC-WF-001-01` passed on current bytes
- [ ] `AC-WF-001-02` positive and negative matrices passed
- [ ] Catalog/JSON Schema/Swift generated parity passed
- [ ] `scripts/check-sdd.sh` and full Swift suite passed
- [ ] Simulation/fake not counted as hardware support
- [ ] Traceability updated for archive
