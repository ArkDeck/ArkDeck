# TASK-XPA-014 — M2 Swift oracles: `debug.hap@1` and `deploy.native-library.app-owned@1` (macOS, 2026-09-14)

TASK-XPA-014 remains in progress. Base: the M1 oracle PR (`agent/xpa-014-m1-oracles-20260914`,
`a2ced1ef`, the `capture.diagnostics@1` oracle and `HDCOracleHarness`) on lane A's observe oracle
(`e14eef13`) on protected main `1a47ac67`; this slice is stacked on both and declares that in its
commit. Every request and answer here is synthetic host data over `/bin/sh` scripts; nothing is
device evidence (POL-VERIFY-001, POL-MODE-001). No Rust file changes and no production Swift
change: this is the r11 "T0 oracles for M2 recorded once in a Swift-only PR" slice for the two
operations of Golden Journeys 2 and 3, so that the Rust slices that follow change no Swift file.

## Already on main or the base / this slice / still remaining

| Already there | This slice | Still remaining for M2 |
| --- | --- | --- |
| `HDCOracleFake` and `HDCOracleHarness`; the observe.device and capture.diagnostics oracles; the Rust analyzer path, the journal/index/record writers, Session publication and the capability reads | `DebugHapOracleContractTests` with `rust/tests/fixtures/debug-hap/` and `NativeLibraryOracleContractTests` with `rust/tests/fixtures/deploy-native-library/`; the harness exposes the Artifact store to an oracle, records the store's own ledger (`artifacts/cleanup-debt.json`) and the capability store (`store/capabilities/**`), composes the provider over a code-sign helper an oracle names, and names the first differing bytes when a compare fails; `HDCObservationProviderAdapter` gains a package initializer that takes that helper | the Rust engine for both operations (lane A: capability mint/reserve/consume, the `debug.*` and native provider families, `cleanupDebt.*`), the `artifact.import.*` publication path, `debug.start/status/probe/evaluate/template.run`, input/port-forward/screen-sequence |

## What the fake had to become

The M1 fakes answered by argv alone. Both M2 operations read the device back after they change
it — `bm dump -n` after `bm install` and again after `uninstall`, `pidof` after `aa start` and
after `aa force-stop`, `sha256sum` of the target before and after the helper publishes, `ls -ld`
of a path after its removal — so the same argv must answer differently over one Job. The answers
fragment (`hdc-answers.sh`, recorded in each fixture) keeps that state in marker files beside the
driver's log: `device-installed`, `device-running`, `device-published`, and one `device-path-…`
per provider-owned remote path (created by `file send`, `mkdir -p` and `ln`, removed by `rm -f`,
`rmdir` and `mv -f`). The application state is cleared before every Job; the path markers are
each Job's own and are kept, so the residue a Job leaves is what its cleanup-debt continuation
finds. The driver and its identity are unchanged (`hdc`, SHA-256
`685bededd5e2bd7bfe87d6f576f6a86e33f3bae521a1ce32df782482facec518`). Two mechanics the fake had to
get right: `hdc shell` reports the client's status, so an absent file's `sha256sum` and `ls` are
an error line on the merged stream with exit 0 (an exit 1 there aborts the provider's sequence and
parks the Job as unknown), and `printf` must not start its format with a listing's leading dash.

## The debug.hap oracle

`DebugHapOracleContractTests.testSwiftDebugsAHapOnTheSharedFakeDevice` adopts the fake device,
publishes an entry HAP and a feature package under one input Job (`job-input-hap`, two leases,
`sourceOperation: artifact.import-hap`) and, with the runbook's GJ-2 input (§3: `installOrReplace`,
`uninstall`, `stopped`, `captureDiagnostics: true`, `diagnosticsDurationSeconds: 10`), plans
thirteen requests and runs eight Jobs in order over one store under the runtime's default policy
capability, then reads back:

| Case | Fake mode | Ends | What differs |
| --- | --- | --- | --- |
| `installed` | `normal` | `succeeded` | all fourteen steps; `install-readback.json` with the native-library facts of the `bm dump` document, `process-readback.json`, `debug-hilog.txt` (sensitive) |
| `packageSet` | `normal` | `succeeded` | `additionalHapArtifactLeases` — `mkdir -p`, two `file send` into the owned directory, one `bm install -p <dir> -r`, cleanup by `rm -f` per package, `rmdir` and `ls -ld` |
| `notInstalled` | `notInstalled` | `failed` | `bm dump` never lists the bundle (`packageNotInstalled`); the failure finalization runs `uninstall` + `bm dump` and `rm -f` as compensations |
| `startFailed` | `startFailed` | `failed` | `aa start` exits 1 (`startFailed`); the same compensations |
| `stillRunning` | `stillRunning` | `failed` | `pidof` still answers after `aa force-stop` (`stopIneffective`) |
| `stillInstalled` | `stillInstalled` | `succeeded` | the optional `cleanup-uninstall` reads the bundle still installed (`uninstallIneffective`): the step is recorded failed, the Job succeeds with `outstandingResidueCount: 1` and an `installedBundle` debt |
| `cleanupDebt` | `cleanupDebt` | `failed` | `rm -f` of the staged package exits 1 (`cleanupDebt`): the Job fails with a `remotePath` debt |
| `emptyHilog` | `emptyHilog` | `waitingForRecovery` | `hilog -x` answers nothing after the mutations: the Job parks with the package installed and the ability running |
| `staleBinding`, `unboundRequest`, `unadopted` | — | refused at plan (`invalidInput`) | as the M1 oracles |
| `unknownLease` | — | refused at plan (`invalidInput`) | `HAP Artifact lease is not resolvable` |
| `badBundleName` | — | refused at plan (`invalidInput`) | `bundleName` fails its Catalog pattern |

Then: the rerun of the installed Job (`resourceConflict`), every Job's `job.result`, `job.evidence`
and `artifact.list`, `cleanupDebt.list` (two debts), `cleanupDebt.continue` for the bundle
(`bm dump` finds it installed again by the parked Job, `uninstall` + `bm dump` are re-dispatched:
`settled`, "exact typed cleanup completed") and for the path (`ls -ld` finds it, `rm -f` is
re-dispatched: `settled`), `cleanupDebt.list` again (empty), `capability.list` and
`capability.inspect` of both automatic capabilities (`CAP-RT-POLICY-<fingerprint>-G1`: one consumed
seven times with its lineage blocked by the parked use, one consumed once by the package-set
request). Recorded (`ARKDECK_RUST_DEBUG_HAP_RECORD`, installed as `rust/tests/fixtures/debug-hap/`):
199 files — `cases.json` with the leases, the eight Job ids and 61 exchanges, the fake and its 108
calls, the Target document, the Job index, every Artifact (29 files including the input Job's two
and `cleanup-debt.json`), every Job file, the capability checkpoint, ledger and lock, the six
Sessions and the storage owner, `tree.json` and `provenance.json`.

## The native-library oracle

`NativeLibraryOracleContractTests.testSwiftDeploysANativeLibraryOnTheSharedFakeDevice` publishes
the synthetic signed arm64 ELF of `NativeLibraryTestFixture` (588 bytes, build id
`0011…3243`, `sourceOperation: artifact.import-native-library`) and, with the runbook's GJ-3 input
(§4: `restartAbility`, `hashProcessAndMaps`, `autoRollback`; `arm64-v8a` because the fixture ELF
is arm64), plans nine requests and runs five Jobs:

| Case | Fake mode | Ends | What differs |
| --- | --- | --- | --- |
| `deployed` | `normal` | `succeeded` | send (library and the bundled code-sign helper), staging readback, backup (hard link), atomic publish through the helper, restart, loader verification through `/proc/*/maps`, cleanup; `publish-report.json` and `verification-report.json` with `attestation: fsVerity` |
| `loaderFailure` | `loaderFailure` | `failed` | `grep -F` finds no map of the published library (`nativeLibraryNotLoaded`): the thirteen-command `rollback-native-library` restores the backup and restarts, then `cleanup-native-library-compensation`; `job.evidence` names `artifactIntegrityFailed` because the required `verification-report.json` was never produced |
| `targetAbsent` | `targetAbsent` | `failed` | `ls -ld` of the app-owned directory is absent (`nativeAppOwnedDirectoryMissing`, actionable: install the signed application) before any mutation |
| `unattested` | `unattested` | `succeeded` | the helper reports `ARKDECK_CODE_SIGN_ERROR stage=verify code=30 errno=61` and publishes `_UNATTESTED`: `attestation: matchesReplacedFile:none`, no `fsVerityDigest` |
| `cleanupFailure` | `cleanupFailure` | `succeeded` | `rm -f`/`rmdir` remove nothing: the optional cleanup is recorded failed and the staging path becomes a debt (`outstandingResidueCount: 1`), continued later (`ls -ld` present, the exact typed cleanup re-dispatched: `settled`) |
| `staleBinding` | — | refused at plan (`invalidInput`) | |
| `unknownLease` | — | refused at plan (`invalidInput`) | `native library Artifact lease is not resolvable` |
| `otherABI` | — | refused at plan (`invalidInput`) | `native library ABI arm64-v8a does not match expected armeabi-v7a` — the ELF is validated at materialization |
| `badLogicalName` | — | refused at plan (`invalidInput`) | `libraryLogicalName` fails its Catalog pattern |

Recorded (`ARKDECK_RUST_NATIVE_LIBRARY_RECORD`, installed as
`rust/tests/fixtures/deploy-native-library/`): 43 files — 40 exchanges, the fake and its 225 calls,
14 Artifact files, every Job file, the capability store (one automatic capability consumed five
times), `tree.json` and `provenance.json`. The bundled helper (SHA-256 `86497e1a…64f5c1`,
214,016 bytes, build id `4e6f…5323`; its digest is the fake's answer to `sha256sum` of the sent
helper) lives where this build put the resource bundle, and that host path reaches the
materialized plan: the first CI run of this slice reproduced every file except the ten that
derive from `materializedPlanDigest` (the `job.plan` answers in `cases.json`, the automatic
capability's id and so the capability checkpoint and ledger, each Job record's
`consumptionFingerprintSHA256`, the index's record digests and `provenance.json`), while the
Journals, which carry typed arguments only, were equal. Labelling the path's text cannot fix a
digest, so the oracle keeps a copy of the helper at `<root>/host/arkdeck-code-sign-enable`,
verifies it as the provider verifies the bundle, and composes the provider over it through a
package initializer of `HDCObservationProviderAdapter`; a Rust replay places its helper copy at
the same path. `hdc-invocations.log` shows that path in the helper's `file send`.

Both oracles reproduce byte for byte on a second run in compare mode, in one process with the two
M1 oracles (`oracle-all-compare.log`: 4 tests, 0 failures). Every fixture path is Windows-safe and
no file names this host, its user or home directory.

## Three Swift facts the oracles pin that the maintainer should rule on

1. **No `deploy.native-library.app-owned@1` Job publishes a Session.** All five native Jobs end
   with `sessionPublication.state: failed, reasonCode: sourceIntegrityFailed`.
   `RuntimeSessionPublication.deviceContext` requires the Job record's `evidenceObservation`
   (model, firmware, transport, `machineReadback` confirmation) for any device-bound Step, and
   only the `probeDevice` and evidence-read Steps write it; the native Catalog has none. GJ-3's
   runbook criteria read `job.evidence`, not the Session, so the real-device pass never saw it.
   The Rust engine must reproduce this as recorded until the Catalog or the composer changes
   (design §L.1 candidate; not a Rust decision).
2. **A `debug.hap@1` Job that succeeds with a failed optional `cleanup-uninstall` publishes no
   Session** (`reasonCode: contractViolation`; the detail is not on the wire) while its status
   reads `succeeded` with `outstandingResidueCount: 1`, and its durable `job-record.json` still
   says `sessionPublication: null` and `outstandingResidueCount: 0`. Which composer rule refuses
   it is not verified here.
3. **The materialized plan digest of `deploy.native-library.app-owned@1` depends on where the
   application bundle is.** The bundled code-sign helper's host path is part of what the digest
   covers, so the same request plans to another digest — and to another automatic policy
   capability — after the application moves or updates. Whether that is intended (a different
   helper is a different plan) or the digest should cover the helper's identity (SHA-256, build
   id, byte count, which the deployment already carries) instead of its path is the maintainer's
   call; the Rust engine reproduces the recorded digest only with the helper at the recorded path.

## Not run, and why

- No Rust replay: the Rust engine serves neither operation yet (lane A, M2). The replays will
  seed the Artifact store from `artifacts/job-input-*/` (the inputs were published directly
  through the store because `artifact.import.*` mints random `imp-` ids; that path gets its own
  oracle with the M2 publication slice) and must place their helper copy at
  `<root>/host/arkdeck-code-sign-enable`.
- No device, no real HDC, no real code-sign helper run: the fake answers what the daemon asks;
  the attestation digests are the fake's constants.
- Not oracled: explicit standing capabilities (installed, revoked — the runbook path is the
  automatic policy), `postRunAbilityState: running` and `cleanupPolicy: retain`, the
  multi-package failure legs, `verificationProfile` below `hashProcessAndMaps`,
  `rollbackPolicy: retainBackup`, and `publishOutcomeUnknown` (a dispatcher fault, not an answer).
