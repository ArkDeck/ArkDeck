# Scoped delta: bounded interactive trace session

This proposed additive delta does not change `capture.diagnostics@1` or declare hardware acceptance.

- `capture.diagnostic-session@1` materializes the exact begin, unique anchor write/readback, bounded host wait, dump, finish, file readback, receive and cleanup before mutation admission. Host stop may shorten only the admitted wait (1–120 seconds).
- Runtime creates a non-resumable live session owner after journaling intent. Only verified provider readiness opens host marker admission. Each marker is durably persisted before acknowledgement; its ID is idempotent and its timestamps are Runtime-generated. The admitted marker count is at most 200.
- `diagnostic.session.status` reads one exact Job. `diagnostic.session.mark` and `.stop` never create capability, change a materialized plan, replace a target or dispatch another operation. App mutations require ownership established by the existing App Job gate.
- Finalization rechecks the original binding and materialized identity. An uncertain provider result, missing live owner, state write fault or identity drift closes all further device dispatch, including the ordinary capture's trailing Trace probe. A persisted document cannot recreate its owner after restart.
- Published `markers.json` and `diagnostic-session.json` preserve host timing and coverage limits; no marker screenshot or host/device time mapping is invented. HiLog is optional and retrospective. Raw Artifact bytes remain unchanged.
- The App uses fixed bounded presets, preflights availability, Trace support and storage, pins active controls to the accepted Job, and opens its verified History products. Stale or uncertain replies disable mutation controls until a fresh read resolves them.

The full CHG-2026-071 multi-channel session, concurrent screenshot/input admission and ground-truth calibration remain separate requirements; this operation does not declare them satisfied.
