# CHG-2026-021 evidence summary

## TASK-TR-001

- Controlled provenance run:[`runs/TASK-TR-001/run.md`](runs/TASK-TR-001/run.md),with three
  redacted manifests and the `OPENHARMONY-TRACE-PROBES@1.0.0` hash closure.
- Evidence class:`controlledHumanCapture` + `documentReview`;the human maintainer personally ran
  the approved harness.Agent device/HDC/network/external-process dispatch = 0.
- Claimed surface:change-local `TRACE-PROV-001` PASS.This registers hitrace help/tag/
  minimal-capture and bytrace help/tag probe families for the exact observed tuple;bytrace capture
  remains unregistered.
- Full raw trace,connect key and serial-bearing inventory stay outside the repository.This does not
  claim adapter implementation,hardware support,conformance,release or change-level verification;
  TASK-TR-001 became `done` through independent status PR #286
  (`54cc94487b42a6918217ba0f8929c0c1f60808ff`).

## TASK-TR-002

- Host contract run: [`runs/TASK-TR-002/run.md`](runs/TASK-TR-002/run.md)
- Evidence class:`contract` using in-memory synthetic observations;real device/HDC/network
  dispatch = 0 for the task-specific suite.
- Claimed surface:`AC-TRACE-002-01`/`003-01`/`004-01`/`005-01`/`006-01`/
  `008-01`/`009-01` only.
- This does not claim hitrace/bytrace adapter provenance,parser compatibility,real hardware
  support,or change-level verification.TASK-TR-002 became `done` through independent status
  PR #271 (`c29d71705b628591711236fa9eab1e2715f446f8`).

## TASK-TR-002R

- Remediation run: [`runs/TASK-TR-002R/run.md`](runs/TASK-TR-002R/run.md)
- Evidence class:`contract` + `SessionArtifactStore` fault injection;all identities and Artifact
  bytes are synthetic;real device/HDC/network/external-process dispatch = 0.
- Claimed surface:`AC-TRACE-003-01`/`004-01`/`005-01`/`006-01`/`008-01` plus
  `TRACE-REBIND-GATE-001`/`TRACE-ATOMIC-PUBLISH-001`/
  `TRACE-PARAM-CAPABILITY-001`/`TRACE-PROGRESS-CAPABILITY-001`.
- TASK-TR-002R became `done` through independent status PR #279
  (`67f46093c3a2a2389f000e3066b1ff004b359cd9`).

## TASK-TR-003

- Parser-golden run: [`runs/TASK-TR-003/run.md`](runs/TASK-TR-003/run.md)
- Evidence class:`parserGolden`;positive bytes come only from the complete TASK-TR-001 registered
  resource closure;real device/HDC/network/external-process dispatch = 0.
- Claimed surface:`AC-TRACE-001-01`/`AC-TRACE-007-01`.hitrace is eligible only for the exact
  registered family;bytrace remains probe-only;unknown/drifted families fail closed and raw
  bytes/hash remain inspectable.
- TASK-TR-003 became `done` through independent status PR #367
  (`ccc8e5b475066c6485366528b29fefe5e3acf718`).

## Change-level verification

- Verification closure and fresh rerun results:
  [`proposal.md#verification-closure2026-07-23`](../proposal.md#verification-closure2026-07-23).
- On protected main `145d46384251e535a563aa94a142d83860f2a710`:9 canonical Core AC and
  5 change-local evidence IDs PASS;Trace targeted suites are 18/0 and 7/0;provenance harness/
  registry is 37/0 plus `TEST-TRACE-PROV-001 PASS`;storage is 60/0;Swift full suite is
  365 tests/1 existing opt-in skip/0 failures;SDD is 0/0/111.
- The candidate `verified` state and Trace macOS traceability flip become authoritative only after
  maintainer review/merge of the verification-closure PR.They do not change platform conformance
  state or establish hardware/compatibility/support/release claims.
