# Producer and publication boundary

Native deployment retains local ELF validation and hashing first. Its first
three device-bound steps are `confirm-evidence-target` (`probeDevice`),
`read-evidence-model` (`deviceModel`) and `read-evidence-firmware`
(`firmwareBuild`). All are required, read-only, confirmed-device bound and
included in the complete materialized plan before Runtime admission.

Only those exact existing typed steps bypass the native action dispatcher;
their existing HDC actions and bounded receipts supply the observation. The
native operation joins the existing evidence gate. The Runtime persists a
complete job-local observation before capability consumption and the first
send intent. Native preflight does not carry another session's facts.

Session composition remains strict: exact target/binding/identity, original
tool version/hash, transport/model/firmware readback, chronological admission,
plan/audit/expiry and every mutation/compensation outcome must still agree.
Known failed rollback Jobs preserve their failure while publishing their own
complete diagnostic Session. Unknown outcomes retain outstanding intents and
cannot be replayed or projected as confirmed publication.

After verified publication, a confirmed failed native final cleanup is a known
failed terminal Job. The original executed failed outcome and exact cleanup
debt survive. The completed replacement is retained; the Runtime sends no
extra rollback to turn a housekeeping failure into deployment compensation.
The existing provider lowering and cleanup continuation are unchanged. Both
the final cleanup and the existing compensation cleanup use idempotent exact
debt persistence, strict residue counts and Job persistence. Storage uncertainty
parks with the original failed device outcome and no finalized publication.

A restart retains that parked state and the original failed cleanup outcome.
The existing `job.reconcile` requires an exact persisted unknown device action,
which a known cleanup failure with uncertain host bookkeeping does not provide.
The existing cleanup continuation requires a terminal known Job and an exact
durable ledger record. This change does not invent a storage-repair operation
or a device-action retry when either prerequisite is absent.

The frozen pre-prefix native oracle recorded `sourceIntegrityFailed` and no
finalized event. Its bytes remain historical. Current tests compare every
original native transport call exactly, retain the original deployment and
rollback assertions, explicitly expect the new failed housekeeping status,
and independently require the new genuine prefix,
published Session, one finalized event and a clear unrelated Import census.
They do not erase the old failure or use it as a current publication success.
