# Verification Plan

> Change:CHG-2026-056-e2-policy-baseline-alignment@r2
> Baseline: `CORE-3.0.0` -> proposed `CORE-4.0.0`
> This plan does not claim a real device run.

| Requirement / acceptance | Method | Expected result | Evidence class |
| --- | --- | --- | --- |
| `POL-AGENT-002`, `AC-FLASH-015-01` | Contract/fake negative matrix: no authority, ordinary CI, generic chat text, connected USB | `policyBlocked`; destructive dispatch 0; no realHardware publication | host-only contract test |
| `POL-AGENT-002`, `AC-FLASH-015-02` | Contract/fake negative matrix: authority/target/plan/budget/review/reservation/predecessor/readback drift; unknown/unsafe outcome | terminal/blocker is durable; destructive dispatch 0; no replay | host-only fault/contract test |
| `REQ-FLASH-015`, `AC-FLASH-015-03` | Fake broker acceptance: exact authority, fresh facts, valid review and reservation | only the declared typed fake Steps run; intent/outcome and truthful authority correlation persist | simulation only, never hardware evidence |
| `REQ-WF-004`, `AC-WF-004-03` | Schema/projector fixtures for standing/campaign correlation mismatch and valid campaign provenance | invalid projection 0; valid fixture records provenance but never dispatches or mints authority | schema/contract test |
| Runtime Agent policy synchronization | `AGENTS.md` review against Constitution/Flash/Workflow deltas | published E0 needs no Git task/PR; E1/E2 each require their typed authority; `host_loop` remains incapable of Runtime dispatch | document/contract review |
| Core synchronization | `check-sdd`, catalog generator tests/check, full Swift test, path preflight | all commands exit 0; current docs/AC registries stay structurally consistent | host-only CI evidence |

## Real-hardware boundary

No verification in this change is real-hardware evidence. A future execution under the ratified
policy still requires an exact authority instance, fresh per-attempt facts and an independently
reviewable Runtime Job/Session/Artifact record. Simulation, fake success and this proposal's
merge cannot establish `REAL_DEVICE_PASS`.
