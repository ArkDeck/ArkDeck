# TASK-E2B-001 — the cross-mode alias carried the Loader's port (2026-09-07)

Found in a real device window while running GJ-4 on a DAYU200 against the post-SVC-001..004
Runtime. TASK-E2B-001 stays `ready`; this is a defect fix inside its existing Allowed paths, not
new scope, and it is not a GJ-4 completion claim — GJ-4 did not pass.

## What was measured

Host state: fresh Runtime state directory (the previous one was retired because its SQLite job
repository was at `user_version = 2`). Catalog digest
`508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684`, contract identity
`1054d17b598ce23003ebbdec4d42eb359b63016d6421709ba53c3f21f7c6558d`. Named hardware campaign
`svc005-single-v1-20260907` enabled, so `flash.full-restore@1` reported `available`.

`flash run` produced `job-bf0b748ef707e7e2ca80d8063959e6d1`: `waitingForRecovery`,
`outcomeUnknown` true and still true after `job reconcile`, blockers
`[artifactIntegrityFailed, recordUnreadable, resultNotReady]`, `actualStepKinds` null,
`outstandingResidueCount` 0. **No partition was written.** The daemon named the cause:

    Rockchip binding requires Runtime Loader onboarding:
      storeFailure("previous target binding lineage is missing or ambiguous")

The board was left in Loader. Both of its personalities were then read directly — the binding
document for the hdc-normal one, `ioreg -p IOUSB` for the Loader:

| personality | serial | IOKit locationID |
| --- | --- | --- |
| hdc-normal (recorded in the durable binding) | `150100424a544434520325874bbf4900` | `2097152` |
| Loader (attached at the time) | `1160102311220451` | `1179648` |

That confirms on this board what `RockchipDeviceBinding.swift:168-169` already states: a DAYU200
changes **both** its USB serial and its IOKit topology between the two personalities.

## The defect

`ProductRockchipLoaderBindingCoordinator`'s first-cross-mode-binding branch built the hdc-normal
alias as

    identitySHA256: SHA256Hex.string(of: Data(target.connectKey.utf8))   // hdc-normal — correct
    usbTopology:    identity.topology                                    // the attached Loader's port

`identity` is the Loader attached at that moment, so the alias carried the Loader's port under
`binding:hdc-normal-alias-usb-topology=`. That key becomes the post-flash hdc-normal reconnect
expectation (`DeviceProviderAdapters.swift`), so a completed restore would look for the board at a
port it only ever occupies while in Loader.

The correct value was already in hand one line away: the same evidence array records
`binding:previous-usb-topology=2097152`. The negative control below shows both written together.

## What changed

`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipBootloaderStatus.swift` only:

- the alias topology now comes from `existing.usbTopology` — the port recorded while the board was
  bound in hdc-normal — instead of from the attached Loader;
- the branch requires `existing.evidence` to contain the hdc-normal readback, so a binding that
  never saw this board in hdc-normal is refused rather than given the Loader's port. That keeps a
  Loader-only board blocked before any write instead of after the reboot, which is what
  `RockchipRuntimeComposition.swift:154-158` asks for;
- the readback marker is named once as `hdcNormalReadbackEvidence` and the two existing literal
  spellings in this file now use it, so the check and the writers cannot drift apart.

The alias identity, `confirmedHDCNormalAlias()`'s four checks, drift refusal and `--rebind` as the
person-authorized override are all unchanged. No identity comparison was weakened; one field now
reads from the observation that actually describes it.

## Verification

- `RockchipBootloaderStatusContractTests.testFirstCrossModeAliasCarriesTheHDCNormalPortNotTheAttachedLoaderPort`
  uses the two ports measured above. **Verified to be a real regression test**: with the previous
  alias source restored it fails, and the stored evidence shows the defect exactly —
  `binding:previous-usb-topology=2097152` and `binding:hdc-normal-alias-usb-topology=1179648`
  side by side.
- `RockchipBootloaderStatusContractTests.testFirstCrossModeBindRefusesWhenNoHDCNormalReadbackBacksTheBinding`
  pins the Loader-only refusal. Without the fix it does not throw and rewrites the binding from 1
  evidence entry to 11.
- All 17 cases in `RockchipBootloaderStatusContractTests` pass.

## Not fixed here, and still open

- GJ-4 itself did not run. The board is in Loader with an unresolved `outcomeUnknown` flash job;
  POL-RECOVERY-001 forbids replaying it.
- The headless runbook's GJ-4 sequence omits `flash install-binding`, which is the step whose
  absence produced the lineage error above. That file belongs to TASK-SVC-005 and is a separate PR.
- Whether this fix alone lets a restore continue from a board already in Loader is **not**
  established. It removes one wrong value; the rest of the Loader-start path was not exercised,
  because doing so needs a flash on real hardware.
