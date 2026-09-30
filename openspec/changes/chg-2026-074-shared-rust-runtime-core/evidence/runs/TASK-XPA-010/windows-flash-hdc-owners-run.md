# TASK-XPA-010 — the HDC-dependent Flash owners on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM4, GJ-4 (D2, destructive): software
part only. This slice follows parts A, B1, B2 and D (#2403, #2410, #2424, #2433). It ports the
Flash owners those parts left macOS-only because they compose beside a managed HDC:

- the ArkForge managed control performer;
- the Rockchip reactivation proof;
- the Loader binding coordinator;
- the executable lane install.

Branch `agent/xpa-010-windows-flash-hdc-owners-20261001`, one commit on `origin/main`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device, HDC, board or real `arkforged` was used.
- HDC is only ever the tests' in-process scripted dispatch.
- The census and ArkForge's Loader observation are the oracles' scripted stand-ins.
- Host tests are not Windows acceptance.

## What

| Crate | Item | Notes |
| --- | --- | --- |
| `arkdeck-hoststore` | `control_performer`, `rockchip_reactivation`, `loader_binding` on Windows | The macOS code. The reactivation records' root, directories and records use the host store's owner-only boundary: a private directory `HostDirectory` opens, and an owner-only single-link record it reads. |
| `arkdeck-hoststore` | `rockchip_startup` journal read on Windows | The journal is also opened with `FILE_FLAG_BACKUP_SEMANTICS`, so a directory in its place is opened as Darwin's `open` opens one and refused as no regular file. This gives Swift's `sequenceViolation` rather than an access-denied open. |
| `arkdeck-agentd` | `Host` on Windows | `with_loader_binding` and `flash.bind-current-loader` answer from the coordinator. `FlashRuntime`, `with_flash_execution` and `flash_execution` are shared with macOS. The Windows Flash admitter executes a Flash only with an installed lane, and takes its campaign. `job.run`, the background run of an agent execution, and `job.reconcile` run a Flash through `FlashRunner`/`FlashReconciler` over that lane. `rockchip_hdc_resolver` is `None` on Windows. |
| `arkdeck-agentd` | `compose_arkforge` | Composes the Loader binding coordinator as the macOS compositions do: the Application Support root, the USB census, and ArkForge's Loader observation through the lane directory. It then calls `arkforge_execution::install`, which installs nothing without a descriptor-bound HDC. The census adds `loaderBinding` at its macOS position, and the Windows process tests' census lines follow. |

The daemon stays gated. `compose_arkforge` still passes no managed-control HDC digest, so no
lane is composed and no executable lane is installed until S1's managed-HDC composition exists
behind the #2426 tuple gate. No identity or trust check was relaxed.

## Oracle comparisons (Windows)

| Oracle / test | Result |
| --- | --- |
| `loader-binding` (Swift `LoaderBindingOracleContractTests`, through the production Host and Control) | **33/33 exchanges.** Every answer is equal, and every byte of the binding, its lock and the advanced Target document is equal. The reactivation cases prove `rockchip_reactivation`. Kinds and sizes are compared; modes are not (Windows has none). The one shared-mode (0644) binding gets a Users read entry. |
| `post-flash-alias` (Swift `PostFlashAliasOracleContractTests`) | 15/15 steps: outcomes, names, sizes and bytes are equal. Owner-only is checked as the host store's private directory and owner-only document. |
| `rockchip-startup` (Swift `RockchipStartupReconcileOracleContractTests`) | 18/18 scenarios. The journal refusals (directory, malformed) are Swift's. The link case stays macOS-only, because a file symbolic link needs a privilege on Windows. |
| `arkforge_loader.rs` | 3/3. The stand-in serves ArkForge's own public named pipe for the lane directory (`arkforge-platform`'s listener) instead of `public.sock`. |
| `loader_binding_jobs.rs` | 2/2. |
| `control_performer` unit tests (Swift's managed control composition) | 8/8, over the in-process scripted executor and records. |
| The Rockchip executor's unit tests (scripted in-process HDC dispatch, #2424) | still 25/25 with the dispatcher's. |

On the test-only HDC: M1 was asked to share its in-process fake HDC. These owners' oracles need
no process-level HDC. The executor, control performer and dispatcher tests already use an
in-process scripted `HdcDispatch` (`rockchip_executor/tests.rs`). So no second fake was
written, and none of M1's was changed.

## Local targeted checks

The environment for every check:
`ARKDECK_DEV_SIGNER_THUMBPRINT=AAC23CA4D38D100996C861D9E1A68DEECD69B149` and
`CARGO_TARGET_DIR=D:/cargo-target/f1-hdc-owners`.

| Check | Result |
| --- | --- |
| `cargo fmt --all --check` | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | clean (Windows) |
| The same with `--target x86_64-unknown-linux-gnu` | clean |
| The same with `--target aarch64-apple-darwin`, `xcrun`/`ar`/`cc` stubbed (type and lint check only) | clean, after it caught one `unused_mut` on macOS |
| `cargo test --no-fail-fast -p arkdeck-hoststore -p arkdeck-rockchip-binding -p arkdeck-agentd` | all pass, 0 failed |
| The same with `TEMP`/`TMP` set to an 8.3 spelling | all pass |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`, `git diff --check` | pass, clean |

The base holds #2396's firewall gate (`wildcard_listeners_allowed`). macOS tests themselves were
not run: there is no host.

## Left out, and why

- **The Rockchip records' own mode and flag unit tests** (`rockchip_records/tests.rs`). They set
  Unix modes and `libc` flags. The records are exercised on Windows through the dispatcher, the
  executor and the Flash run oracle.
- **`readback_reconcile.rs`.** It drives the device-mutation reconcilers over the shell-script
  fake HDC, which is M1's device-lane area, not a Flash owner.
- **Installing the executable lane on the daemon, and a lane that launches.** Both need S1's
  managed HDC behind the #2426 gate. Then `compose_arkforge` passes that server's digest. After
  that, AF-W1 and phase A.
