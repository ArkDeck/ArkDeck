# GJ-4 Flash Recovery — current-digest ledger confirmation (2026-08-05)

This record does not add a new flash. It states, from the durable host ledger,
which catalog digest the two successful GJ-4 campaigns actually ran on, because
PRODUCT-LOOP §"状态" requires `REAL_DEVICE_PASS` to be held **on the current
catalog digest** and the campaigns predate this check by a few hours.

## What the ledger says

Both campaign attempts terminated `succeeded` with the three destructive intent
events recorded, and both jobs carry the current digest:

| Campaign | Runtime job | `catalogDigest` | State |
|---|---|---|---|
| `ECAMP-96EFFF150CEEECBFCC7AEB52` | `job-95c9cd16ce40bcffd09f88f190065ec5` | `e2f8eb6592aaeeec…2cfd0aa` | `succeeded` |
| `ECAMP-31E041BC0F6FC563BCEF7563` | `job-9e393b2c7bd9745a10e0fa6fe965ba18` | `e2f8eb6592aaeeec…2cfd0aa` | `succeeded` |

Both: `actualEffect = destructive`, `materializedBindingRevision = 2`,
`materializedPlanDigest = 88b2237082638e83…e93561`, `outcomeUnknown = false`,
attempt ordinal `1` (no retry), `disposition = succeeded`, and the same closed
step set — `enterUpdater, waitForDisconnect, waitForReconnect, probeDevice,
flashPartition, verifyRemoteState, rebootDevice, captureRemoteStdout`.

Ten `verified` readbacks per job, covering the whole PRODUCT-LOOP GJ-4 chain:

```text
verify-image-bundle / hash-images        (host, profile dayu200@2)
flash intent confirmed by campaign reservation ain019-2fb1422e…
campaign reservation verified before first mutation
enter-loader-mode → wait-loader-disconnect → wait-loader-reconnect
rebind-loader-identity
flash-partitions → verify-flash-readback
reboot-device → wait-for-hdc
rebind-and-verify-build      → artifact post-flash-facts.json
capture-post-flash-diagnostics
```

`post-flash-facts.json` (`ART-eafa6ea3ce5a211545fb861fe5b9eaf4`) carries
`catalogDigest e2f8eb65…`, `expectedBindingRevision 2`, `targetId
TGT-958780b2ffb7` and the `rebind-and-verify-build` record id, i.e. the
version-verification leg is bound to the same digest as the job.

Admission was the E2 campaign confirmation, not a standing capability:
`kind = evolutionCampaignConfirmation`, attempt `ain019-2fb1422e…`,
`consumptionFingerprintSHA256 = 88b2237082638e83…` (equal to the materialized
plan digest).

## The last leg — "restore the normal Debug Runtime"

The chain's final step is not inside the flash job. It is that the rebound
device can be driven normally again, and that is what the same-digest records
already merged show: `gj1-gj2-real-device-pass-2026-08-05.md` (observe,
capture, full HAP debug chain at binding revision 2) and, in this same
directory, `gj3-native-debug-real-device-pass-2026-08-05.md` (native library
publish, loader verification and rollback at binding revision 2). Those runs
also forced the three identity-surface fixes (#1067, #1071, #1072) that the
rebind exposed.

## Golden Journey conclusion

**GJ-4 is `REAL_DEVICE_PASS` on the current catalog digest** — two independent
campaigns, each `succeeded` on the first attempt, both recorded against
`e2f8eb6592aaeeec…2cfd0aa`, with the post-flash Debug Runtime demonstrated by
the GJ-1/GJ-2/GJ-3 passes on the same digest and binding revision.
