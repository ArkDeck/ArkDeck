# GJ-1 and GJ-2 — REAL_DEVICE_PASS on the current catalog digest (2026-08-05)

## Scope and target

- Baseline: `main@bf6edbe3` (includes #1071, #1072)
- Catalog digest: `e2f8eb6592aaeeec37c63a01708db2325b38c798b0f8272228ba0fccc2cfd0aa`
- Target: `TGT-958780b2ffb7`, binding revision `2`
- Device: DAYU200, OpenHarmony `7.0.0.36` (flashed by campaign
  ECAMP-96EFFF15 / re-verified by ECAMP-31E041BC the night before), HDC `3.2.0f`
- Executor: Device Runtime Agent over `arkdeck-agentd`. Manual HDC commands: `0`.

## Product corrections this run forced (all merged before the passes)

Binding revision 2 (the Loader rebind from the GJ-4 campaigns) exposed an
identity-surface family the lineage design had not reached — the same family
as #1067:

1. **#1071** — the daemon's HDC facts port published the store's
   `stablePhysicalIdentitySHA256` (the Loader/campaign identity after the
   rebind) while `confirm-evidence-target` verifies the SHA-256 of the connect
   key. From revision 2 onward every device-bound observe/debug operation
   failed `targetIdentityMismatch`: GJ-4's final leg ("restore the normal
   Debug Runtime") was structurally broken. The HDC provider now owns a single
   connect-key derivation used by both surfaces.
2. **#1072** — artifact imports still stamped lease binding snapshots with the
   store identity, so a freshly imported HAP lease could never match a
   `debug.hap` materialization. HDC-consumed leases (hap, native-library) now
   bind the connect-key derivation; the flash bundle stays on the store
   identity (its consumer is the Rockchip provider, proven end-to-end by the
   flash campaigns).

## GJ-1 Device Observe — full-scope pass

- `observe.device@1` → job `job-8e008373c21878cfe13ee13dd7564304`, `succeeded`:
  probe-host-tool, probe-hdc-server, `confirm-evidence-target` (verified with
  the connect-key identity), model + firmware evidence reads, three artifacts
  (`tool-facts.json`, `device-facts.json`, `binding-snapshot.json`).
- `capture.diagnostics@1` (durationSeconds 5) → job
  `job-9159bf746a49cdfc259a49ad63f9bd5e`, `succeeded`:
  - `hilog.txt` = **607,903 bytes** of real device log
    (`ART-c9beb1ef14c1edb9e6ac3bf21e017842`),
  - `ui-dump.json` = real WindowManagerService window inventory
    (`ART-00567ee5a8b01238cc8c3cd9d3fe8cfa`),
  - trace legs honestly `skipped: step not selected by the request inputs`.
- **Daemon restart readback**: `arkdeck-agentd` killed and restarted; both
  jobs re-queried afterwards return their full state, timeline and artifact
  references byte-for-byte. The GJ-1 chain — doctor → discovery → adopted
  durable binding → observe → bounded HiLog → UI dump → artifact store →
  post-restart query — is closed on the current digest.

## GJ-2 HAP Debug — full-scope pass

HAP: `waterflowdemo.hap`, sha256
`ee08314929e2ecb8347414e64e1afacb1d22b0c04e5a22664de8410d4b2c4ba6`
(the GJ-5 r2 window's proven build), imported for revision 2 as
`lease-v1:input-hap-TGT-958780b2ffb7-r2-ee08314929e2ecb8:ART-84fb92725b13b31118e520a52a290f62`
with the lease snapshot bound to the connect-key identity.

Four jobs, all `succeeded`, covering every leg of the PRODUCT-LOOP GJ-2 chain:

1. `job-69c8406e3ce8780282cea3f79ecf7cee` — full skeleton **with closure**:
   verify-hap-artifact → send-hap (staged at the job-owned remote path) →
   install-hap → package-readback (`bundleName`, `deployedArtifactSha256`,
   `installed`) → start-ability → process-readback (`running`) →
   capture-diagnostics (`debug-hilog.txt`) → **stop-ability (`stopped`) →
   cleanup-uninstall (`uninstalled`) → cleanup-remote-staging (`cleaned`)** →
   finalized. The closure legs the HTP-006 window deliberately left open
   (retain + keep running) are now real-device verified.
2. `gj2-run-20260805c` — install + start, `postRunAbilityState: running`,
   `cleanupPolicy: retain` (stage for in-flight capture).
3. `job-d459c84375a87f3958c2c6eff2012002` — `capture.diagnostics@1` scoped to
   the running app (`bundleName` set, `uiDump: true`,
   `traceCategories: ["ohos", "ability"]`):
   - `application-liveness.json` with `pidObserved`, `abilityState`,
     `processState` (the app-scoped liveness the HTP-006 run noted as missing),
   - `hilog.txt` = 639,108 bytes,
   - `ui-dump.json` = live window inventory,
   - **`trace.htrace` = 81,945 bytes** captured on-device and received through
     the leased artifact path (`capture-trace` → `receive-trace-artifact`,
     both verified).
4. `gj2-close-20260805c` — final closure: stop-ability → cleanup-uninstall →
   cleanup-remote-staging, leaving the device clean (bundle uninstalled,
   staging removed).

Catalog note (honest boundary): `debug.hap@1` itself carries one optional
capture step (boundedHilog). The UI-dump and trace legs of the GJ-2 chain are
expressed by `capture.diagnostics@1` against the running app — the composition
above is the product's full-chain shape on the current catalog; no catalog
change was needed.

## Status assertion

- **GJ-1: `REAL_DEVICE_PASS`** (current digest, full scope including
  post-restart readback).
- **GJ-2: `REAL_DEVICE_PASS`** (current digest, full scope including stop +
  uninstall + staging cleanup and in-flight HiLog/UI-dump/trace capture).
