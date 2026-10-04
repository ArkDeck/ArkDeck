# Verification

> Change:CHG-2026-079-diagnostic-session-control@r1
> Status:planned

- DSC-AC-1: no recording before verified ring anchor; no owner means zero dispatch; closed provider arguments bind exact target and owned path.
- DSC-AC-2: stop/deadline race freezes marks once; 200-marker ceiling and same-ID idempotency; changed-ID payload conflict; timestamp comes from Runtime.
- DSC-AC-3: uncertain write/receipt, identity drift and restart never resume or dispatch new work; raw artifacts are preserved.
- DSC-AC-4: App readiness follows Runtime, rapid controls do not duplicate jobs, lost replies remain explicit, terminal results open exact History context; fixture UI is not hardware acceptance.
- DSC-AC-5: old capture lowering and contracts remain valid; Catalog generation, schemas, Swift validators and typed Control contracts agree.

- DSC-AC-6: the clock bracket surrounds only the existing anchor write; missing callbacks or uncertain persistence stop subsequent dispatch. Exact Job/anchor identity and wall/monotonic consistency are checked; malformed observations never establish calibration, readiness or restart permission. Older artifacts without observations remain readable.

Local targeted checks and CI results are recorded under `evidence/runs/TASK-DSC-001/`. Hardware execution requires the reviewed operation on protected main and is not claimed by fixture results.
