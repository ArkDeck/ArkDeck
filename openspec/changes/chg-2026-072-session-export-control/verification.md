# Verification — CHG-2026-072

> Change:CHG-2026-072-session-export-control@r1
> Status:planned; host verification does not approve the change or prove a
> real-device run.

| AC ID | Method | Expected result |
| --- | --- | --- |
| SEP-AC-1 closed surface | registry, parser, protocol, and XPC contract tests | only the two documented leaves and exact parameter sets reach the owner; no confirm/overwrite/raw-command field exists |
| SEP-AC-2 privacy and integrity | finalized Session fixtures with every Artifact role | raw/partial are excluded by default, explicit opt-in is digest-bound, every item carries identity/digest/bytes/privacy/redaction, and source bytes remain unchanged |
| SEP-AC-3 drift and publication | destination inode/existence, Catalog generation, Artifact digest, expiry, and injected publication failures | all pre-publication drift causes zero output; uncertainty after applying returns `outcomeUnknown` and retry publishes nothing |
| SEP-AC-4 production CLI path | real `arkdeck` subprocess against the production handler fixture | preview then exact apply creates one verified derived export, retry returns the same receipt, and Runtime Job/device dispatch counts remain zero |

Required local gates are `scripts/check-sdd.sh`, control-contract zero drift,
the relevant Swift contract set, PR path preflight, and the repository unified
local gate. Evidence is recorded under `evidence/runs/TASK-SEP-001/` without
including exported diagnostic bytes or host-private paths.
