# GJ-1, GJ-2 and GJ-3 — re-verified after the flash-pin work (2026-08-06)

## Why

Removing the per-build flash pins took a dozen merged changes, several of them
to code every journey runs through: `RuntimeJobEngine`'s execution contexts,
`ProviderExecutionContext` itself, the provider adapters, and — after the
target-store defect — device bootstrap. GJ-5 was re-run and recorded in
`chg-2026-055/.../gj5-real-device-pass-2026-08-05.md`. GJ-1, GJ-2 and GJ-3 had
not been, and their evidence dates from before any of it.

The catalog digest never moved, so their `REAL_DEVICE_PASS` records stayed
nominally valid throughout. That is not the same as still being true, and the
re-run of GJ-5 is what turned up a defect that would have bricked the daemon
(#1107), so this is not a formality.

- Baseline: `main@ff205ac7`
- Catalog digest: `e2f8eb6592aaeeec37c63a01708db2325b38c798b0f8272228ba0fccc2cfd0aa` (unchanged)
- Target: `TGT-958780b2ffb7`, binding revision `2`
- Device: DAYU200, OpenHarmony `7.0.0.36`, HDC `3.2.0f`

## GJ-1 Device Observe — pass

`observe.device@1` (`job-81afda15b38ca354da0ea59f58f82a75`) succeeded, tool
facts read back and published.

`capture.diagnostics@1` succeeded with the evidence preflight intact —
`confirm-evidence-target`, `read-evidence-model`, `read-evidence-firmware`,
`preflight-device-storage` all verified — and published real captures:
`hilog.txt` (`ART-a1bea9f339b0abb2bd75d90cdb3d87db`), `ui-dump.json`
(`ART-8d6190ac50ae0ebda8163b47e0d2e180`), `crash-index.txt`
(`ART-aba01e34708c2c9ac1595ef41be781fe`).

## GJ-2 HAP Debug — pass, including the teardown

`debug.hap@1` with `cleanupPolicy: uninstall` ran the whole chain and finished
`succeeded` with `outstandingResidueCount: 0`:

```
verified send-hap / install-hap → package-readback ["bundleName",
  "deployedArtifactSha256", "installed"]        → ART-519907b650af9884b7daee75aac0582c
verified start-ability → process-readback ["bundleName", "running"]
                                               → ART-ab9f9c1deb51581c41ad84b7d1a559ba
verified capture-diagnostics                   → ART-be624e8907cb8232b5dc50902079c57b
verified stop-ability ["stopped"]
verified cleanup-uninstall ["uninstalled"]
verified cleanup-remote-staging ["cleaned"]
```

The teardown legs are the part GJ-5 never exercises — it deploys with
`retain` — so they are only covered here.

## GJ-3 Native Debug — pass

The `armeabi-v7a`-bearing HAP was re-imported and installed through
`debug.hap@1` (`job-fcd23e22cad960b8132074d39d3629e9`, `succeeded`), and
`libarkdeck_gj.so` confirmed on device at
`/data/app/el1/bundle/public/com.example.scrollablecomponentstatic/libs/arm/`.

`deploy.native-library.app-owned@1` then ran the full forward chain:

```
verified verify-remote-staging ["buildId", "remoteByteCount", "remoteSha256"]
verified backup-current-version ["backupPath", "backupSha256"]
verified atomic-publish ["buildId", "fsVerityDigest", "gid", "mode",
  "publishedSha256", "targetPath", "uid"]      → ART-d522757928864865b8b77b8a85978383
verified restart-target / start-target ["processIds", "started"]
verified verify-loaded-library ["abi", "buildId", "fsVerityDigest",
  "processIds", "publishedSha256"]             → ART-dbabe642205923713c4ebde6d17fa9a2
verified cleanup-staging-and-backup ["backupRetained", "cleaned"]
```

`verify-loaded-library` is the readback that matters: it proves the running
process loaded the published library, not merely that a file landed.

## Status

GJ-1, GJ-2, GJ-3 and GJ-5 all hold on the current digest at `main@ff205ac7`.
GJ-4's pass rests on its durable campaign ledger; re-flashing to re-verify it
needs a device window and an operator confirming a destructive plan, which is
the one step in this product that is not automated by design.

## A note on the fixtures

Two things cost time and are worth writing down. The bundle the GJ-3 HAP
installs is `com.example.scrollablecomponentstatic`, not the name its NAPI
module suggests. And `arkdeck job list` sorts by job id, not by time, so "the
last row" is not the newest job — reading a run's outcome from it gives the
wrong job's state.
