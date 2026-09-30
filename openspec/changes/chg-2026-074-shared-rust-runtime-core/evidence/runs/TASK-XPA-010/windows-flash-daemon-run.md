# TASK-XPA-010 — WM4 part D: the Windows daemon composes the ArkForge lane, up to the HDC gate

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM4, GJ-4 (D2, destructive): software
part only. This is the last of the slice's ordered PRs:

- part A (#2403): the paired lane;
- part B1 (#2410): the Flash archive reader;
- part B2 (#2424): the Flash owners;
- part D (this PR): the Windows daemon's composition.

Branch `agent/xpa-010-windows-flash-lane-d-20260930`, one commit on `origin/main`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device, HDC, board or real `arkforged` was used.
- The daemon runs over a fresh development root with every `ARKDECK_` and `OHOS_HDC_` input
  removed.
- The only bundle is a verified stand-in whose daemon never runs.
- Host tests are not Windows acceptance.

## What

`arkdeck-agentd` (Windows):

| Item | Notes |
| --- | --- |
| `arkforge_lane` on Windows | The macOS module. The lane's runtime directory `<state>\arkforge` is created with the store's private DACL when missing, best effort. |
| `windows_lifecycle::Authority::compose_arkforge` | Composes the lane as the macOS compositions do, beside the Job state. The state is the account root (macOS production's `Agentd`) or a development root's `jobs-state`. The facts' Application Support is the account root's parent or the development root. It composes: the lane from `ARKDECK_ARKFORGE_BUNDLE_PATH` (Swift's absences and retired names included); the Flash planning over it (no HDC, so no per-action record root); the Flash facts over the Windows USB census; the device access observer of the lane's directory; and the lane plan previewer when a lane exists. The start reports the lane's line on stderr, as on macOS. |
| The HDC gate | The lane's authority support binds the managed-control HDC's digest (`Lane::compose`), and no HDC is composed on Windows until its tuple is registered: CHG-2026-078 is `TBD(sample)`, and the tuple gate of #2426 admits nothing while its table is empty. So a verified bundle is refused before its `arkforged.exe` is launched: `cannot bind ArkForge authority support: the managed-control HDC digest is absent or malformed`. This is not a bypass: macOS refuses a lane with the same words when its composition has no managed HDC. No executable lane (`with_flash_execution`) is installed without an HDC, so the admitter's `executes` is false. |
| `Host` on Windows | `with_flash_planning`, `with_flash_host_facts`, `with_device_access` and `with_lane_plan_preview`. The facts port and the Flash planner and admitter run over no HDC (`flash_hdc`). `job.plan` and `job.submit` go through the Flash planner and admitter. `flash.bootloader-status`, `flash.prerequisites`, `flash.device-access` and `flash.lanePlanPreview` answer from those owners. The lane's daemon is stopped after the drain, as on macOS (`main.swift` 1624-1627). |
| The census | `flashHostFacts`, `deviceAccess` and `lanePlanPreview` sit at their macOS positions in `Host::owner_census`. The Windows daemon now reports `…, traceCache, flashHostFacts, deviceAccess`, and the Windows process tests that compare the census line were updated. |

## Tests

`arkdeck-agentd/tests/windows_flash_lane_process.rs` runs the real daemon over a development
root. That root holds the Flash plan oracle's imported bundle and Target store, laid down as
Swift's Import left them.

| Case | Proves |
| --- | --- |
| `without_a_bundle_the_start_and_a_flash_report_swifts_absence` | The start reports Swift's `NotConfigured` absence. The census holds `flashHostFacts, deviceAccess`. The oracle's canonical `job.plan` and `job.submit` are refused `invalidInput` with `flash.full-restore@1 is runtime unavailable: <absence>`, `{"phase":"preAdmission","newDispatchCount":0}`, and nothing is admitted. `flash.device-access` answers Swift's one refusal. `flash.bootloader-status` observes no board: the Windows USB census fails closed until the DAYU200 sample confirms its mapping (#2402). |
| `a_retired_lane_name_is_refused_by_name` | `ARKDECK_ARKFORGED_PATH` beside a bundle gives Swift's `RetiredConfiguration` absence, at the start and in the Flash refusal. |
| `a_verified_bundle_is_refused_before_its_daemon_starts_without_the_managed_control_hdc` | A verified bundle (`bin/arkforged.exe`, `bin/arkforge.exe`, the DAYU200 profile) is refused at the authority's HDC digest. `arkforge lane: composed` is never reported. Nothing serves the lane's pipes. Nothing was left to stop at the drain. A Flash is refused before admission with that reason and zero dispatch. |

The macOS lane tests (`arkforged_owner_stop.rs`, `flash_plan_control.rs`,
`debug_invocation_control.rs`) are unchanged.

## Local targeted checks

The environment for every check:
`ARKDECK_DEV_SIGNER_THUMBPRINT=AAC23CA4D38D100996C861D9E1A68DEECD69B149` and
`CARGO_TARGET_DIR=D:/cargo-target/f1-flash`.

| Check | Result |
| --- | --- |
| `cargo fmt --all --check` | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | clean (Windows, and with `--target x86_64-unknown-linux-gnu` as a Linux cross-check) |
| `cargo test --no-fail-fast -p arkdeck-agentd` (after `cargo build -p arkdeck-cli`) | all pass, 0 failed |
| The same with `TEMP`/`TMP` set to the 8.3 spelling `C:\Users\fuhan\AppData\Local\Temp\F1-FLA~1` | all pass |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`, `git diff --check` | pass, clean |

Not run here: macOS (no host). The macOS composition is unchanged: `compose` and
`arkforge_lane` keep their macOS bodies, and the new Windows methods are `cfg(windows)`.

## CLI coverage

No CLI leaf is added to `WINDOWS_MEASURED_LEAVES`. On Windows a Flash `job plan`/`job submit`,
`flash device-access`, `flash bootloader-status` and `flash prerequisites` now answer from their
owners, but every one of them stops at a gate that waits for the maintainer: the HDC tuple, the
USB census mapping, or AF-W1. None works end to end yet.

## Left out, and why

- **Handing the lane the managed HDC's digest.** Once the Windows managed HDC is composed behind #2426's gate (its part 3), `compose_arkforge` should name that server's SHA-256 where it passes `None` today, as the macOS compositions pass theirs. That is the one change between this composition and a lane that launches.
- **Launching and pairing `arkforged.exe` from the daemon.** The composition goes up to the HDC
  gate, and part A proved the launch itself. It needs a managed, descriptor-bound HDC, which
  waits for the Windows HDC tuple (CHG-2026-078 samples), then AF-W1 and the maintainer's
  HardwareCampaign window (phase A).
- **The executable lane and its host** (`arkforge_execution::install`, the Rockchip executor
  over the HDC resolver, the managed control performer, the Loader binding coordinator and the
  reactivation proof). All of them need that HDC.
- **The Flash invocation broker** (`debug.start`/`debug.evaluate`/`debug.status`) on Windows.
  Its attempts run through the executable lane.
