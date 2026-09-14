# TASK-XPA-016 — M2 run record: the app-owned native library provider

Change: CHG-2026-074-shared-rust-runtime-core@r11. Milestone M2 (GJ-3), lane B's platform
executor: `deploy.native-library.app-owned@1`'s device actions and its host-side ELF verifier
ported from Swift's HDC provider as two additive modules, with T1 argv parity proved by
replaying the Swift oracle's recorded invocation log Job by Job over the shared fake HDC driver.
Host measurement only — not hardware, platform or conformance evidence (POL-VERIFY-001,
POL-MODE-001). No device, no HDC server, no daemon, no real code-sign helper.

Base: protected main `c1cd1ea4` (#1950). Branch `agent/xpa-016-native-library-provider-20260914`,
stacked on the debug.hap slice (#1951, which carries the capture-file legs of #1949): `NativeAction`
builds on `capture_files`' plan shapes, receipts and runner and on `debug_hap`'s `BundleReference`
and `ResolvedArtifact`. Files: `arkdeck-provider-hdc/src/native_elf.rs` (new),
`src/native_library.rs` (new), `tests/native_library.rs` (new), the export block in `lib.rs`, this
record, one README section. No `arkdeck-hoststore`, `arkdeck-agentd`, `arkdeck-control`, Swift or
contract change.

## What was missing

The M1/M2 map (lane B, 2026-09-14) found no native-library code under `rust/crates/` — no ELF
reader, no OpenHarmony code-sign block reader, no `ln`/`mv -f`/helper lowering — while
`rust/tests/fixtures/deploy-native-library/` already held Swift's T0 oracle of the operation
(`NativeLibraryOracleContractTests`, 43 files: five Jobs over the shared fake HDC driver, the
leased library's bytes, the helper's facts and recorded path, and the driver's invocation log of
all 225 calls) — recorded for the Rust daemon's future replay, but with no Rust provider to run
its steps.

## What Rust now has

`arkdeck_provider_hdc::NativeAction` (`native_library.rs`), eight mutations and eight read-only
inspections, every invocation `-t <key>`-prefixed and every action a sequence:

| Action | Swift argv (after `-t <key>`) | Budget (s) | Verdict |
| --- | --- | --- | --- |
| `SendToStaging` | `shell mkdir -p <stagingDir>`; `file send <hostLibrary> <staging>`; `file send <hostHelper> <helperRemote>`; `shell chmod 700 <helperRemote>`; `shell sha256sum <helperRemote>` | 30; 300; 60; 30; 30 | never verified: `nativeSendFailed` on a non-zero exit or a helper digest that is not the helper's, else unknown "native staging send requires remote hash readback" |
| `Backup` | `shell ls -ld <dir>`; `shell ls -l <target>`; `shell sha256sum <target>`; `shell rm -f <backup>`; `shell ln <target> <backup>`; `shell sha256sum <backup>`; `shell ls -l <backup>`; `shell ls -la <libsRoot>` (continues) | 15; 15; 30; 30; 30; 30; 15; 15 | `nativeAppOwnedDirectoryMissing` when the directory is not listed as one; `nativeBackupMismatch` with Swift's twelve-field diagnostic (the layout listing as a bounded hex prefix); else `backupSha256`, `backupPath` |
| `Publish` | `shell ls -ln <target>`; `shell <helper> verify <backup>` (continues); `shell <helper> publish <staging> <target> <rollbackStaging>`; `shell sha256sum <target>`; `shell <helper> verify <target>` (continues); `shell ls -ln <target>` | 15; 30; 60; 30; 30; 15 | `nativePublishMismatch` unless the target's bytes are the leased digest, its identity is read, and the published attestation is at least the replaced file's (`ARKDECK_CODE_SIGN_VERIFIED sha256:` / `ARKDECK_CODE_SIGN_ERROR … errno=61\|95`); `publishedSha256`, `buildId`, `targetPath`, `mode`, `uid`, `gid`, `attestation` (`fsVerity` + `fsVerityDigest`, or `matchesReplacedFile:none`) |
| `StopTarget` | `shell aa force-stop <bundle>`; `shell pidof <bundle>`; `shell sleep 2`; `shell pidof <bundle>` (all continue) | 60; 30; 5; 30 | `nativeTargetStillRunning` with the pids and the byte counts, else `stopped` |
| `StartTarget` | `shell aa start -b <bundle> -a EntryAbility`; `shell sleep 2`; `shell pidof <bundle>` (all continue) | 60; 5; 30 | `nativeTargetNotRunning`, else `processIds` |
| `Cleanup` | `shell rm -f <staging>`; `shell rm -f <helperRemote>`; `shell rmdir <stagingDir>` (job-owned only); `shell rm -f <rollbackStaging>`; `shell rm -f <backup>` (`autoRollback` only); then `shell ls -ld` of each (all continue) | 30 each; 15 each | `cleanupDebt` unless every listing is absent; `cleaned`, `backupRetained` |
| `Rollback` | `shell sha256sum <backup>`; the four stop calls; `shell rm -f <rollbackStaging>`; `shell ln <backup> <rollbackStaging>`; `shell mv -f <rollbackStaging> <target>`; `shell sha256sum <target>`; the three start calls; `shell grep -F <loaderVisible> /proc/*/maps` (all but the first continue) | 30; 60/30/5/30; 30; 60; 60; 30; 60/5/30; 30 | `nativeRollbackVerificationFailed` with the hash, process and maps facts unless the backup's bytes are back at the target and the started process maps the loader-visible path; `restoredSha256`, `processIds` |
| `Inspect(_, StagingMatchesArtifact)` | `shell sha256sum <staging>`; `shell ls -l <staging>` | 30; 15 | `nativeStagingMismatch`; `remoteSha256`, `remoteByteCount` |
| `Inspect(_, BackupMatchesTarget)` | `shell sha256sum <target>`; `shell sha256sum <backup>` | 30; 30 | `nativeBackupMismatch`; `backupSha256` |
| `Inspect(_, TargetMatchesArtifact)` | `shell sha256sum <target>`; `shell <helper> verify <backup>`; `shell <helper> verify <target>` | 30; 30; 30 | `nativeTargetHashMismatch`; the publish summary |
| `Inspect(_, TargetLoaded)` | the three above; `shell pidof <bundle>` (unless `hashOnly`); `shell grep -F <loaderVisible> /proc/*/maps` (`hashProcessAndMaps` only) | 30 each | `nativeTargetHashMismatch`, `nativeTargetNotRunning`, `nativeLibraryNotLoaded`; `loaderVerified` (`"notObserved"` when the profile does not look), `processIds`, `abi` |
| `Inspect(_, TargetStopped)` / `TargetStarted` | `shell pidof <bundle>` | 30 | `nativeTargetStillRunning` / `nativeTargetNotRunning`; `running` / `processIds` |
| `Inspect(_, CleanupComplete)` | `shell ls -ld` of each cleanup path | 15 each | `nativeCleanupIncomplete`; `cleaned` |
| `Inspect(_, RollbackRestored)` | `shell sha256sum <target>`; `shell sha256sum <backup>`; `shell pidof <bundle>`; the maps grep (`hashProcessAndMaps` only) | 30 each | `nativeTargetHashMismatch`, `nativeTargetNotRunning`; unknown "rollback bytes exist but restored loader state is unproven" when the maps do not show the library; `restoredSha256`, `processIds`, `loaderVerified` |

`for_step` is Swift's `nativeLibraryAction` by step id (`send-to-staging`, `verify-remote-staging`,
`backup-current-version`, `atomic-publish`, `restart-target`, `start-target`,
`verify-loaded-library`, `cleanup-staging-and-backup`, and the engine-synthesized
`rollback-native-library` and `cleanup-native-library-compensation`; the host-side steps map to
no device action; any other step is refused with Swift's text). `Deployment` is
`HDCAppOwnedNativeLibraryDeployment`: the provider-owned namespace derived from the bundle, the
ABI directory (`arm` for arm64 and arm32, `x86_64`) and the Job — target, loader-visible path,
job-owned staging directory under the application's `el2` data, staging, backup, rollback
staging and the helper's remote path — and, for a persisted deployment, `Deployment::new` accepts
paths only when they are exactly what it derives (the historical `arm64` directory and the legacy
sibling staging included) and refuses anything else as escaping the namespace.
`Deployment::from_inputs` is Swift's admission in its order: the required inputs, the ABI, the
profiles (`restartProcess` refused before authorization), the engine-resolved Artifact whose
identity the lease names, the library's bytes verified and matched to the resolved digest, the
helper present. `lower` takes the resolved Artifact, the library's byte count and the helper as
values and sends nothing unless they are the deployment's; `verify` reads a `FileReceipt`;
`readback` and `reconcile` are Swift's `reconciliationReadback` and its conclusion — a failed
readback concludes an idempotent mutation as not executed, never a publish ("publish state is
not safe to replay") or a rollback; `persisted` returns Swift's `nativeArguments` journal form
as a JSON object (the code-sign block's and the helper's facts only when present, the
inspection's `expectation`).

`native_elf.rs` is `NativeLibraryArtifactValidator`: `validate_elf` reads the closed ELF fields
(64 bytes minimum, 64 MiB maximum, the magic, class 1/2, little-endian only, machine 183/40/62
against its class), the expected ABI, the GNU build id from the `SHT_NOTE` sections, and the
OpenHarmony V1 code-sign block in the trailer (the 32-byte header's magic and version, one or
two 12-byte block entries, the merkle-tree info's fixed bytes) — required or optional — into
`NativeLibraryFacts`; `is_static_executable` is the helper's shape (an executable with a load
segment and no interpreter). `ValidationError` carries Swift's description strings.

## Measurement

`tests/native_library.rs` installs the oracle's own `hdc-answers.sh` on the shared fake driver
(`/private/tmp/arkdeck-hdc-oracle`, under its lock — the oracle was recorded at this root, as its
provenance says), copies the fixture's leased library to the recorded Artifact path and writes a
placeholder at the helper's recorded host path (the helper's bytes are not in the fixture; only
the path enters the argv, the fake answers its remote digest), and drives each of the five Jobs
as Swift's engine drove them — every device step through `NativeAction::for_step`, in the
oracle's mode, the device reset between Jobs as the recording reset it — checking every step's
verdict against what let the engine continue, roll back, compensate or park, and comparing the
argv the driver logged with the oracle's `hdc-invocations.log` segment by segment:

| Job | Mode | Steps replayed | Verdicts checked | Lines |
| --- | --- | --- | --- | --- |
| deployed | normal | send, staging inspection, backup, publish, stop, start, loaded inspection, cleanup | send unknown; `remoteSha256` the leased digest, `remoteByteCount` 588; `backupSha256` the replaced digest, `backupPath`; publish `mode` `-rw-------`, `uid`/`gid` 20010050, `attestation` `fsVerity` with `fsVerityDigest`; `stopped`; `processIds` 4321; `loaderVerified` true, `abi` arm64-v8a; `cleaned` | 43 |
| loaderFailure | loaderFailure | the same through the loaded inspection, then the rollback and the compensation | `nativeLibraryNotLoaded`; rollback `restoredSha256` the replaced digest, `processIds` 4321; compensation verified | 56 |
| targetAbsent | targetAbsent | send, staging inspection, backup, then the compensation | `nativeAppOwnedDirectoryMissing`; compensation `backupRetained` false | 25 |
| unattested | unattested | the full flow | publish `attestation` `matchesReplacedFile:none` and no `fsVerityDigest`; the rest as deployed | 43 |
| cleanupFailure | cleanupFailure | the full flow, then the failed cleanup's readback | `cleanupDebt`; readback `nativeCleanupIncomplete`, concluded `ConfirmedNotExecuted` | 48 |
| continuation | normal | the cleanup again over the residue | `cleaned` | 10 |

All 225 recorded lines matched on the first run.

```
cargo test -p arkdeck-provider-hdc --lib native            9 passed (3 native_elf, 6 native_library)
cargo test -p arkdeck-provider-hdc --test native_library   1 passed (5 Jobs + continuation, 225/225 lines)
cargo test -p arkdeck-provider-hdc                         every suite of the crate green (87 lib, 12 integration binaries)
cargo clippy -p arkdeck-provider-hdc --all-targets -- -D warnings   clean
cargo fmt --all --check                                    clean
```

The nine unit tests port the Swift contract cases: the fixture library validated field by field
as Swift recorded it and every refusal of the validator on the same bytes disturbed one field at
a time, the static-executable shape; the derived namespace and the persisted-path admission with
its refusals; the admission over the inputs in Swift's order of refusal; the step mapping and the
exact argv, budgets and continue flags of every mutation and inspection, with the three ways a
send lowers to nothing and the helperless refusals; the persisted forms; the parsers on their
own; and the verdicts the five Jobs do not reach (the send's two failures, the backup's failed
hard link with its diagnostic, the target still running, the target not running, a clean
cleanup, the rollback's bytes not restored, the weaker verification profiles, the unproven
rollback readback, every inspection's failure, the readback table and the three conclusions).

## Declared differences from Swift (T1/T2)

- `lower` receives the resolved Artifact, the library's byte count and the helper as values;
  Swift reads them from `ProviderExecutionContext` and the bundled resource. The guards are the
  same.
- The helper's own bytes are verified by whoever discovers it (`CodeSignHelperFacts` is the
  result; `is_static_executable` is the check) — Swift verifies the bundled resource when it
  answers availability. This slice does not discover the helper.
- `persisted` returns a JSON object rather than `Persisted` arguments (as `debug_hap` does); the
  journal owner serializes either way.
- `ValidationError` is an enum with Swift's descriptions; the admission maps it to the same
  `unsupportedAction` texts.

## What stays with other owners

- The Job's planner and runner for `deploy.native-library.app-owned@1` in `arkdeck-hoststore`
  (the step order, the synthesized `rollback-native-library` and
  `cleanup-native-library-compensation` steps on a failed publish or loader check, the
  cleanup-debt ledger and its `cleanupDebt.continue` runs), the lease resolution that produces
  `ResolvedArtifact`, the discovery of the bundled `arkdeck-code-sign-enable` helper as a
  `CodeSignHelper`, the operation's availability answer, and the products the Job leaves — lane
  A; the daemon-level replay of `rust/tests/fixtures/deploy-native-library` through
  `check-corpus-replay.py` follows that wiring.
