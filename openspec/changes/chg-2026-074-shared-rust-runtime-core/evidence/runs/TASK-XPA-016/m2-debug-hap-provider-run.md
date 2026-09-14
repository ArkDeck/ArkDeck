# TASK-XPA-016 — M2 run record: the debug.hap provider

Change: CHG-2026-074-shared-rust-runtime-core@r11. Milestone M2 (GJ-2/3), lane B's platform
executor: `debug.hap@1`'s device actions ported from Swift's HDC provider as one additive
module, with T1 argv parity proved by replaying the Swift oracle's recorded invocation log Job
by Job over the shared fake HDC driver. Host measurement only — not hardware, platform or
conformance evidence (POL-VERIFY-001, POL-MODE-001). No device, no HDC server, no daemon.

Base: protected main `5e3b7f7a` (#1946). Branch `agent/xpa-016-debug-hap-provider-20260914`; the
branch carries `capture_files.rs` and its test as #1949 has them (the same files, so the merge is
order-independent) because `HapAction` builds on that module's plan shapes, owned paths and
parsers. Files: `arkdeck-provider-hdc/src/debug_hap.rs` (new), `tests/debug_hap.rs` (new), the
export block in `lib.rs`, `serde_json` in `[dependencies]` (the line #1947 and #1949 add), this
record, one README section. No `arkdeck-hoststore`, `arkdeck-agentd`, `arkdeck-control`, Swift or
contract change.

## What was missing

The M1/M2 map (lane B, 2026-09-14) found no `bm`, `aa`, `uninstall` or `file send` lowering
anywhere under `rust/crates/`, while `rust/tests/fixtures/debug-hap/` already held Swift's T0
oracle of the operation (`DebugHapOracleContractTests`, 199 files: eight Jobs over the shared
fake HDC driver, their control exchanges, the products they left, and the driver's invocation
log of all 108 calls) — recorded for the Rust daemon's future replay, but with no Rust
provider to run its steps.

## What Rust now has

`arkdeck_provider_hdc::HapAction` (`debug_hap.rs`), fifteen actions:

| Action | Swift argv (after `-t <key>`) | Budget | Verdict |
| --- | --- | --- | --- |
| `SendArtifactToStaging` | `file send <host> <staged>` | 300 s | `sendFailed` on a non-zero exit, else `stagedAt` |
| `SendPackageSetToStaging` | `shell mkdir -p <dir>`; `file send <host> <dir>/<artifactID>.hap` per package | 30; 300 each | one result per package required, any non-zero `sendFailed`, else `stagedAt`/`packageCount` |
| `InstallPackage` / `InstallPackageSet` | `shell bm install -p <staged\|dir> -r` | 300 | never verified: `installFailed`, `installOutputTruncated`, `deviceUDIDUnauthorized` (`code:9568423` + "device is unauthorized"), `installRejected` (each with `outBytes=…,outHex=…,errBytes=…,errHex=…,truncated=…` over the first 512 bytes), else unknown until the readback |
| `QueryPackageReadback` | `shell bm dump -n <bundle>` | 30 | `truncated`, `invalidEncoding`, `packageNotInstalled` unless the bundle appears on its own boundaries; `bundleName`, `installed`, `deployedArtifactSha256`, and the native-library facts (`nativeLibraryPath`, `cpuAbi`, `nativeLibraryFileCount`) |
| `StartAbility` | `shell aa start -b <bundle> -a <ability>` | 60 | `startFailed` on a non-zero exit, else unknown until the process readback |
| `VerifyProcessState` | `shell pidof <bundle>` | 30 | `processNotRunning` unless every token is a live PID; `bundleName`, `running` |
| `StopAbility` | `shell aa force-stop <bundle>` (continues); `shell pidof <bundle>` | 60; 30 | `stopIneffective` when still running, unknown when ambiguous, else `stopped` |
| `UninstallPackage` | `uninstall <bundle>` (continues); `shell bm dump -n <bundle>` | 120; 30 | `uninstallIneffective` when still listed, unknown when the probe is not trustworthy, else `uninstalled` |
| `CleanupStagedPackageSet` | `shell rm -f <package>` per package (continue); `shell rmdir <dir>`; `shell ls -ld <dir>` | 30; 30; 15 | `cleanupDebt` when the directory is listed, unknown without a definite listing, else `cleaned` |
| `CleanupOwnedRemotePath` | `shell rm -f <staged>` | 15 | `cleanupDebt` on a non-zero exit |
| `ReadPackagePresence` / `ReadProcessPresence` / `ReadOwnedPathPresence` / `ReadOwnedDirectoryPresence` | `bm dump -n`, `pidof`, `ls -ld` | 30; 30; 15 | `present` true/false, or unknown with Swift's four reasons |

`for_step` is Swift's `debugHAPAction` from a step kind and the request's inputs: the staged
path minted for `send-hap` and shared by send, install and cleanup; the set form only with
`additionalHapArtifactLeases` (identity from each lease's suffix, the hash from the resolved
Artifact when one is already there); the refusals with Swift's texts. `lower` takes the
Artifacts the Job owner resolved (`ResolvedArtifact { artifact_id, sha256, path }`) and sends
nothing unless the lease's suffix names the resolved identity and the pinned hash is its digest;
`verify` takes the resolved entry digest the package readback binds to. `readback` and
`desired_presence` are Swift's `reconciliationReadback` and `desiredPresence` tables, `presence`
the three-valued reading of a probe, so a crash-resumed Job concludes a mutation without
resending it. `persisted` returns Swift's journal forms as JSON objects (the package set's
`packages` array included). The request types carry Swift's bounds (`BundleReference`,
`AbilityReference`, `StagedPackage` at `<dir>/<artifactID>.hap`, `StagedPackageSet` 2–17
distinct packages inside the directory).

## Measurement

`tests/debug_hap.rs` installs the oracle's own `hdc-answers.sh` on the shared fake driver
(`/private/tmp/arkdeck-hdc-oracle`, under its lock — the oracle was recorded at this root, as
its provenance says) and drives each of the eight Jobs as Swift's engine drove it — the three
observe-step preflight calls through `Action`, the HiLog capture through `Action`, everything
else through `HapAction` — in the oracle's mode, with the device reset between Jobs as the
recording reset it, checking every step's verdict against what let the engine continue,
compensate or park, and comparing the argv the driver logged with the oracle's
`hdc-invocations.log` segment by segment:

| Job | Mode | Steps replayed | Verdicts checked | Lines |
| --- | --- | --- | --- | --- |
| installed | normal | preflight, send, install, readback, start, pidof, hilog, stop, uninstall, cleanup | send `stagedAt`; install unknown; readback installed with the three native-library facts; start unknown; running; hilog 28 bytes; `stopped`; `uninstalled`; `cleaned` | 14 |
| packageSet | normal | the same over the staged set | `packageCount` 2; set install unknown; set cleanup `cleaned` | 19 |
| notInstalled | notInstalled | preflight, send, install, readback, then the compensation | `packageNotInstalled`; uninstall `uninstalled`; `cleaned` | 9 |
| startFailed | startFailed | …, start, then the compensation | `startFailed`; `uninstalled`; `cleaned` | 10 |
| stillRunning | stillRunning | the full flow | `stopIneffective`; `uninstalled`; `cleaned` | 14 |
| stillInstalled | stillInstalled | the full flow | `stopped`; `uninstallIneffective`; `cleaned` | 14 |
| cleanupDebt | cleanupDebt | the full flow | `uninstalled`; `cleanupDebt` | 14 |
| emptyHilog | emptyHilog | preflight, send, install, readback, start, pidof, hilog | hilog unknown "empty capture output" (the Job parks) | 9 |
| continuations | normal | the bundle debt's probe and uninstall pair, the path debt's probe and cleanup | probe present; `uninstalled`; probe present; `cleaned` | 5 |

All 108 recorded lines matched on the first run.

```
cargo test -p arkdeck-provider-hdc --lib debug_hap        6 passed
cargo test -p arkdeck-provider-hdc --test debug_hap       1 passed (8 Jobs + 2 continuations, 108/108 lines)
cargo test -p arkdeck-provider-hdc                        every suite of the crate green
cargo clippy -p arkdeck-provider-hdc --all-targets -- -D warnings   clean
cargo fmt --all --check                                   clean
```

The six unit tests port the Swift contract cases: the step mapping over one staged path or one
staged set with every refusal text; the exact argv, budgets and continue flags of every action
and the three ways a send lowers to nothing; every verdict (the install classifier with its hex
diagnostic, the readback on boundaries with the deployed digest and native-library facts, start,
process state, stop, uninstall, both cleanups, the set send); the recovery table (readback,
desired presence, effect) and the four presence reads; the persisted forms; the parsers on
their own.

## Declared differences from Swift (T1/T2)

- `lower` receives the resolved Artifacts as values; Swift reads them from
  `ProviderExecutionContext`. The guards are the same.
- `persisted` returns a JSON object rather than `Persisted` arguments, because the package set's
  `packages` is an array of objects the shared `Persisted` enum cannot carry; the journal owner
  serializes either way.
- `localizedCaseInsensitiveContains` is an ASCII-lowercase `contains`; the boundary regex is a
  scan for the bundle name with non-`[A-Za-z0-9_.]` neighbours.

## What stays with other owners

- The Job's planner and runner for `debug.hap@1` in `arkdeck-hoststore` (`device_steps::action`,
  `products`, the optional-step selection by `cleanupPolicy`/`captureDiagnostics`, the
  compensation on a failed step, the cleanup-debt ledger and its `cleanupDebt.continue` probes),
  the lease resolution (`ArtifactReadStore::lease` + `payload_matches`) that produces
  `ResolvedArtifact`, and the products (`install-readback.json`, `process-readback.json`,
  `debug-hilog.txt`) — lane A; the daemon-level replay of `rust/tests/fixtures/debug-hap`
  through `check-corpus-replay.py` follows that wiring.
