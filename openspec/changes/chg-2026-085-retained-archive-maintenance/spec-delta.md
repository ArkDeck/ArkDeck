# Scoped delta — CHG-2026-085

> Change:CHG-2026-085-retained-archive-maintenance@r1

Extends the maintenance-only restart predicate in
`spec/recovery/job-state-preflight.json`; Job state classes, cutover rules and
device admission remain unchanged.

1. Preserve the existing parked-unknown carry-over rule. Additionally, a current
   `interrupted` destructive DAYU200 Flash may carry over only when unknown remains
   true, waiting-for-human is false, residue count is zero, process progress is
   explicitly null, finish time is present, and Session publication is complete.
2. Before stopping the identity-verified Runtime, fetch a fresh
   `job.archive.preview` for each interrupted unknown in the complete paginated
   current-job snapshot. Never accept caller-supplied proof. The response must
   conform to the current schema and match Job, operation, target, Session and
   interrupted state. It must report `canArchive: true`, `mode: finishPublication`,
   no blockers, unknown true, resource release false, the original confirmation,
   a valid review digest and nonempty distinct retained hazards including both
   capability-lineage and managed-process uncertainty markers plus a device hazard.
3. This preview is produced by the existing Runtime owner: it verifies the durable
   archive decision and untorn journal, original expired recovery budget and
   materialized/capability lineage, and absence of a resident Job. Missing methods,
   failed requests, partial decisions, incomplete publication, active Jobs,
   malformed rows and incomplete or contradictory proofs refuse before stop.
4. After restart, require the same current unknown IDs and archive review digests.
   A digest covers the complete durable record and journal, so any budget, lineage,
   risk, outcome or journal change fails the maintenance proof. No provider dispatch
   or capability update is part of maintenance. Windows' stop-only uninstall uses
   the same preflight and retains the state root.
5. Archived unknown Jobs stay in the current-job census and continue to block Loader
   adoption, rebinding and conflicting Flash. Managed-process state remains unknown;
   a null progress projection does not prove that an external process exited.
   HDC configuration selection and server ownership checks remain independent.

Acceptance scenarios: completed retained archive survives a real signed daemon
restart with record/journal bytes unchanged; missing/blocked/partial proof performs
no stop; an active row or missing page blocks; pre/post digest drift fails the
restart proof; preserved unknowns still block device admission. Synthetic tests are
host verification only. Real acceptance uses protected-main typed operations.
