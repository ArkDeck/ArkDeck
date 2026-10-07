# Verification — CHG-2026-081

> Change:CHG-2026-081-native-session-observation@r1

Status: planned. Local transport is synthetic; no hardware result is claimed.

- Native local validation and the exact three required read-only steps precede
  all native mutations in the generated Catalog and materialized plan.
- Five native scenarios retain every original native transport byte;
  each complete observation produces its own published Session and one
  finalized event, including the failed rollback scenario.
- Complete Import inspection succeeds after those finalized terminal Jobs.
- Missing firmware and mismatched target refuse before send, capability
  consumption or any native mutation.
- Final native cleanup failure retains the verified replacement and original
  failed outcome/debt, closes failed and publishes without extra rollback.
- Corrupt, unreadable or already-settled Native debt storage parks without publication,
  finalized evidence or replay, for final and compensation cleanup paths;
  reopening retains the source and the existing reconcile route refuses
  absent exact unknown-device-action proof without changing that source.
- Existing late/missing/expired admission, unknown restore and cleanup
  assertions remain in force. No historical record is repaired by this change.

Targeted Catalog/generator, affected Rust tests/clippy, formatting and SDD
checks are recorded in the implementation run note. Selected GitHub lanes
remain the unified gate; unavailable local cross-platform checks are reported.
