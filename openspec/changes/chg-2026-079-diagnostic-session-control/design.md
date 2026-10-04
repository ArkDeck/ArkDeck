# Design

The HDC provider lowers an interactive trace into a closed sequence with a bounded host wait after its unique ring anchor is read back. Generic execution refuses this plan without a Runtime session owner, before any dispatch. The Runtime owner writes `diagnostic-control.json` in the exact Job directory and holds a process-local live handle. Only that handle can accept marks or stop; persisted state alone cannot resume recording after a crash.

An annotation is host data, not a device instruction. The session owner serializes marker admission, stop and deadline, persists before acknowledging, enforces the admitted count, and freezes data before dump. It never changes the operation request, plan, capability or raw Artifact. Duplicate IDs with the same label return the original mark; changed labels conflict. A failed or uncertain state write closes admission and does not authorize additional device effects.

Before continuing after the wait, Runtime checks the original target, binding and materialized identity again. The provider's entire trace sequence remains one WAL intent; an interrupted sequence remains unknown and is not replayed. The App's Stop is distinct from `job.cancel`: it releases only the bounded wait so the already materialized dump/finish steps can run. Disconnection does not remove the deadline. A missing live owner is visible as interrupted/finalized, never as recording.

HiLog drains after the trace window and stays optional with explicit coverage limits. Markers preserve host UTC plus monotonic offset from readiness. There is no mapping to device trace time without measured calibration. Device input and marker screenshots remain outside this session's lane and are not queued by these controls.
