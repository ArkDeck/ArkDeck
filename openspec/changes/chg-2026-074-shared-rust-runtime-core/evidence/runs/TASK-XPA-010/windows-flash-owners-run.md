# TASK-XPA-010 — WM4 part B2: the Flash planner, admission, run and reconcile on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM4, GJ-4 (D2, destructive): software
part only. This is the third of the slice's ordered PRs:

- part A (#2403, merged): the paired lane;
- part B1 (#2410): the Flash archive reader;
- part B2 (this PR): the Runtime's Flash owners in `arkdeck-hoststore`;
- part D (next): the Windows daemon's composition.

Branch `agent/xpa-010-windows-flash-lane-b2-20260930`, one commit on `origin/main`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device, HDC, board or real `arkforged` was used.
- The lane and the Rockchip host are the macOS tests' scripted fakes
  (`tests/support/flash_lane.rs`).
- The HDC is the executor tests' scripted dispatch.
- Host tests are not Windows acceptance.

## What

`arkdeck-hoststore`, now built on Windows. On macOS the code is unchanged but for the
refactors named in [Delegated minor decisions](#delegated-minor-decisions).

| Item | Notes |
| --- | --- |
| The Flash planner (`job_plan::flash_plan`, `FlashPlanner`, `FlashPlanning`, `RockchipFactsPort`, `rockchip_dispatch_unavailable`) | This is the planner carve-out TASK-XPA-005 left. It materializes and digests the plan as on macOS. |
| The Flash admitter (`job_admission::flash_admission`, `FlashAdmitter`) | This is the admitter carve-out. |
| The Flash run (`job_run::flash_run`, `FlashRunner`, `FlashExecution`) | Every step of the Target's mutation lane runs by StepPermit through a `FlashLane`: the lane's steps are delegated, the host's steps are the Rockchip host's (readback, rebind, postflight), and the completed plan is projected onto the catalog's steps. |
| The Flash recovery and reconcile (`job_owner::flash_recovery`, `arkforge_job_state`, `job_reconcile::flash_reconcile`, `FlashReconciler`) | The complete-overwrite recovery (DEC-016) and its epoch are handled. The delegated Flash's receipt is reconciled through the lane: the "Flash lane receipt in reconcile" carve-out, where Windows had `Lane = Infallible`, is gone. `job_recovery` reads a durable recovery epoch on Windows instead of refusing a Flash. `job_result` projects a Flash's `actualStepKinds` from its journal. |
| The Rockchip host's owners (`rockchip_action`, `rockchip_dispatcher`, `rockchip_records`, `rockchip_executor`, `rockchip_startup`, `flash_facts`, `flash_invocations`, `post_flash_alias(_store)`, `flash_alias_reconcile`, `rockchip_binding`, and the `arkdeck-rockchip-binding` store) | The Windows forms of their files are described under [the owner-only boundary](#the-owner-only-boundary-on-windows). |
| The flash-bundle Import validator (`import_publication.rs`) | It judges a bundle through the Flash archive reader, as Swift's production policy does. This is the "Flash archive reader for Import" carve-out. H3 was told. |
| `swift_hex` | Swift's `isSHA256`, shared by the ArkTrace profile and the Rockchip records. It is moved out of `arktrace_profile` unchanged. |

### The owner-only boundary on Windows

- **Records directories.** A records directory is created with `create_private_directory`. An
  existing one is accepted only as `HostDirectory::open` accepts a private directory.
- **Records files.** A record is written through `create_private_file` (no reparse point
  followed), then renamed. It is read as `HostDirectory::read_owner_only_detailed` reads an
  owner-only single-link document.
- **Directory `fsync`.** NTFS has none, so on Windows it is a no-op, as `arkforge-platform`'s
  `sync_directory` is.
- **The journal snapshot.** It is taken over the same open handle: its size and its write and
  creation times. The reparse point is opened as itself.
- **The configured `arkforged`.** It is measured as an absolute `.exe`.

## Oracle comparisons

| Oracle | Windows result |
| --- | --- |
| `flash-plan` (Swift `FlashPlanOracleContractTests`) | **23/23 exchanges equal, every plan's document digest included** (`materializedPlanDigest`/`planDigest`). The Artifact root is laid down as Swift's Import left it: owner-only directories, and the 0400 payloads sealed by the store. |
| `flash-plan` `dispatch.json` (Swift's own Rockchip dispatcher reasons) | 8/10 equal as recorded. `stateMissing` is equal but for its errno: Windows reports 3 (`ERROR_PATH_NOT_FOUND`) where Darwin reports 2 (`ENOENT`), in the same words (declared). `privatePrefix` is a `/private/tmp` spelling, which Windows paths lack, so it is not replayed there. Group-readable is `icacls /grant *S-1-5-32-545:(RX)`, and the link is a directory junction. The planner's own record-root unit test has a Windows form over drive-letter paths, with the same errno difference. |
| `flash-run` (Swift `FlashRunOracleContractTests`, 8 stories: admission, canonical, alias, failures, reconcile, recovery, recoveryAlias, cancel) | **Every story equal** (all 13 cases of `flash_run.rs`). Equal means: every answer, every lane and dispatch call the fakes record, the Job index, and every file's bytes. The tree is compared by kind (Windows has no modes). One platform difference is declared: a Session published on Windows names `PLATFORM-WINDOWS@0.2.0`. That name also changes every digest and byte count over the Manifest, and the Sessions root path in the marker (a host value). What this Runtime wrote is read back as Swift's platform wrote it (`AsSwift`) before it is compared, as `session_publication_windows_tests.rs` and `windows_job_reconcile.rs` already do. |
| `flash-archive` import policy (`flash_bundle_import.rs`) | 2/2. A bundle that fits is published with Swift's facts; every other is refused with the validator's one refusal, and nothing is published. |
| The dispatcher's and the executor's unit tests (Swift `RockchipRuntimeCompositionContractTests`) | 25/25 on Windows. These cover the rebind route's exactness: an inexact build or an inconsistent route publishes nothing, and a transition the normal readback disproves carries its diagnostic. They also cover the durable records the host writes before it dispatches. |

Fault injection with zero dispatch is covered by the `failures` and `admission` stories:

- prewarm refused or drifted;
- prepare failed, not executed or uncorrelated;
- perform failed or not executed;
- a non-canonical completion;
- a reviewed-capability mismatch, a malformed capability, a caller capability;
- the cross-mode binding unprepared, no alias, a stale revision, another Target's lease.

Each is refused as Swift refuses it, and the lane and host calls the fakes record are Swift's.

## Local targeted checks

The environment for every check:
`ARKDECK_DEV_SIGNER_THUMBPRINT=AAC23CA4D38D100996C861D9E1A68DEECD69B149` and
`CARGO_TARGET_DIR=D:/cargo-target/f1-flash`.

| Check | Result |
| --- | --- |
| `cargo fmt --all --check` | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | clean (Windows) |
| `cargo test --no-fail-fast -p arkdeck-hoststore -p arkdeck-rockchip-binding -p arkdeck-agentd` (after `cargo build -p arkdeck-cli`) | all pass, 0 failed |
| The same with `TEMP`/`TMP` set to the 8.3 spelling `C:\Users\fuhan\AppData\Local\Temp\F1-FLA~1` | all pass |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`, `git diff --check` | pass, clean |

Not run here: macOS (no host).

- The macOS lines of the ported modules are unchanged, except the two moves below and cfg
  gates.
- The macOS test files keep their macOS paths: `flash_run.rs`'s fixed `/private/tmp` root,
  `chmod` and modes.
- The device-lane test support (`debug_hap`, `hdc_oracle`, `native_library`, `reconcile`) is
  now declared macOS-only in `tests/support/mod.rs`, where only macOS tests ever used it.

## Delegated minor decisions

These are pending the next rulings batch.

1. **Two refactors, the same bytes on macOS.**
   - `swift_hex` is moved out of `arktrace_profile`.
   - `rockchip_records::read_record` reads through a per-platform `record_bytes`. The macOS body
     is the old one.
2. **Directory synchronization is a no-op on NTFS** for the Rockchip records, as for ArkForge's
   own store. The rename is durable through the file handles.
3. **The journal snapshot on Windows** compares size, write time and creation time of the same
   open handle. Std exposes no change time or file index on stable Rust. The open handle rules
   out a replaced file.
4. **The measured prewarm wait in a checkpoint seal.** The replay was flaky: 1 failure in 8
   Windows runs.
   - **Cause.** A Session publication's `checkpointSeal` is the digest of the Job record it was
     given. That record's timeline names the prewarm wait in measured milliseconds, which the
     oracle labels (`consume wait <ms> ms`). When the run measures a wait other than 0 ms, the
     sealed bytes differ from Swift's.
   - **Fix.** `AsSwift::learn_measured_waits` reads such a record's seal as Swift's, on both
     hosts. It does so only when that record measured a non-zero wait.
   - **Proof.** With a forced 400 ms prewarm, the six stories that publish fail without it and
     pass with it.

## Left out, and why

- **The daemon's composition** (the lane, the Flash planning and facts, and the device access
  observer on the Windows daemon). That is part D, next.
- **The owners that drive or observe hardware through HDC.** These are the ArkForge managed
  control performer (`control_performer`), the reactivation proof (`rockchip_reactivation`) and
  the Loader binding coordinator (`loader_binding`). They compose only beside a managed,
  descriptor-bound HDC, and the Windows HDC tuple is not registered (CHG-2026-078,
  `TBD(sample)`). Their own tests (`loader_binding_jobs.rs`, `arkforge_loader.rs`,
  `readback_reconcile.rs`, `post_flash_alias.rs`, `rockchip_startup.rs`) and the records' mode
  and flag unit tests stay macOS-only.
- **Real flashing.** It needs AF-W1 and the maintainer's HardwareCampaign window (phase A).
