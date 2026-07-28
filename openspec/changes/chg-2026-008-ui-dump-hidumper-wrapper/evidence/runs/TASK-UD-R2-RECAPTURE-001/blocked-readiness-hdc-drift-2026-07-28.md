# TASK-UD-R2-RECAPTURE-001 D2 readiness preflight — HDC drift

## Classification

- Date:2026-07-28.
- Audit base:r12 protected-main merge
  `d74c7af7179d89dc29c61e1e7b63d0ca4e7822ea` (PR #708).
- Draft rebase base:current main
  `c295d4a45a30ea08d7ab66440c5593d1208f222a`; the sole intervening commit
  modifies only CHG-2026-022 tasks and has no overlap with this task, tool or
  schema input.
- Method:host-only static governance/file-identity audit.
- Result:**blocked before D2 readiness**.
- Installed-HDC process, HDC server lifecycle, device discovery, device, fixture,
  Recipe, raw-read, mutation and destructive dispatch:`0 / 0 / 0 / 0 / 0 / 0 /
  0 / 0 / 0`.

## Observed drift

The r12 plan inherited the Phase A HDC identity:

- absolute path:
  `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`;
- expected version:`Ver: 3.2.0d`;
- expected SHA-256:
  `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`.

Without starting that executable, the readiness audit hashed the regular file at
the same absolute path. The observed SHA-256 was:

`05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`

This is not the approved `3.2.0d` binary. Protected-main
`openspec/integrations/openharmony/profile.md` registers the exact observed
digest as HDC `3.2.0f`; CHG-2026-026 r5 accepted the same exact mapping in
merge `0f0a79aff7ede1519b9fbc0cbdca12b5c687ef07` (PR #481). Those records are
used only to identify the binary drift. They do not establish UI Dump output
compatibility or authorize this task.

## Fail-closed conclusion

The r12 dependency says an HDC path/hash/version drift must not reuse the old
pin. Accordingly:

- no D2 readiness or named device window was drafted;
- no E1 per-device typed capability evidence was accepted;
- `TASK-UD-R2-RECAPTURE-001` remains `blocked`;
- no fixture availability, current target/firmware state, window state or
  Recipe result is claimed;
- the existing #248/#251 evidence remains immutable and is not reclassified.

r13 may replace only the recapture task's expected HDC identity with the
single exact `3.2.0f` tuple. Even after that D1 revision is merged, a separate
D2 readiness must revalidate all remaining pins, explicitly accept the
per-device typed capability evidence and named exclusive window, and preserve
zero device dispatch until its own merge. The later human run must still
execute `HP-0` through the closed harness before any fixture/device command;
any runtime version/hash mismatch stops with zero further dispatch.

## Repository checks

- The audit changed no `scripts/**`, contract, spec, integration profile,
  historical evidence or decision artifact.
- No raw, local fixture path, connect key, device serial or controlled-root
  path was read or recorded.
- This record is blocker provenance, not real-hardware acceptance, capability
  evidence, readiness, Recipe success, compatibility, support or conformance.
