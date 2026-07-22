# CHG-2026-021 evidence summary

## TASK-TR-001

- Controlled provenance run:[`runs/TASK-TR-001/run.md`](runs/TASK-TR-001/run.md),with three
  redacted manifests and the `OPENHARMONY-TRACE-PROBES@1.0.0` hash closure.
- Evidence class:`controlledHumanCapture` + `documentReview`;the human maintainer personally ran
  the approved harness.Agent device/HDC/network/external-process dispatch = 0.
- Claimed surface:change-local `TRACE-PROV-001` candidate only.This registers hitrace help/tag/
  minimal-capture and bytrace help/tag probe families for the exact observed tuple;bytrace capture
  remains unregistered.
- Full raw trace,connect key and serial-bearing inventory stay outside the repository.This does not
  claim adapter implementation,hardware support,conformance,release or change-level verification;
  TASK-TR-001 remains `ready` until its independent status PR.

## TASK-TR-002

- Host contract run: [`runs/TASK-TR-002/run.md`](runs/TASK-TR-002/run.md)
- Evidence class:`contract` using in-memory synthetic observations;real device/HDC/network
  dispatch = 0 for the task-specific suite.
- Claimed surface:`AC-TRACE-002-01`/`003-01`/`004-01`/`005-01`/`006-01`/
  `008-01`/`009-01` only.
- This does not claim hitrace/bytrace adapter provenance,parser compatibility,real hardware
  support,or change-level verification.TASK-TR-002 remains `ready` until the separately
  reviewed status PR.
