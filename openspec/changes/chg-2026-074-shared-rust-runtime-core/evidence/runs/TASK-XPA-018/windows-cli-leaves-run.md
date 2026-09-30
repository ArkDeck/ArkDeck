# TASK-XPA-018 — Windows CLI leaves without platform code of their own, and their Windows coverage (Windows 11 x64, 2026-09-30)

TASK-XPA-018 remains in progress. Base: protected main `d0f72b03` (#2339); no stack. Slice T2 of the
Windows phase, toward exit condition 4 ("CLI coverage", `windows-phase-agent-prompt.md` §阶段 S).
Run on the maintainer's Windows 11 x64 reference host (native Windows, Git Bash). Nothing here is
device evidence (POL-VERIFY-001, POL-MODE-001); no HDC, board, elevation or system change. No control
schema, Catalog, corpus, command registry or `openspec/platforms/**` change.

## What changes

- **Import leaves that only talk to the Runtime run on every platform** (`import_resources.rs`).
  `artifact import list|inspect|abort|release` exchange frames with the Runtime and validate its
  answers; nothing in them touches the host. They were compiled only on macOS because the whole of
  `execute_import` was. The upload of a source (`artifact import hap|workspace-patch|flash-bundle|
  native-library`) is now its own `upload` function, still macOS-only: it reads the source through
  `arkdeck_platform::HostImportSource` (the macOS host store's no-follow, identity-checked reader).
  Off macOS an upload is refused `unsupportedOnPlatform` ("Import upload is not supported on this
  platform", the words it had) before any frame is sent, now with the request's
  `importRequestId` in its details as every other Import failure carries it. The macOS code is moved,
  not changed.
- **`human-action resume` answers the impact-approval challenge on every platform** (`main.rs`).
  The console read (`console_approval::read_console_challenge`) is portable (the gate inventory's
  "c-pure" row, G33); only `cfg!(target_os = "macos")` kept Windows from reaching it, and made it
  answer `humanActionRequired` instead. The Runtime alone decides whether the answer came from the
  console it challenged; the Windows daemon composes no HAR owner yet, so it never issues the
  challenge today. macOS behaviour is unchanged (the removed `challenge ||` arm was unreachable
  there).
- **Windows coverage states what the Rust CLI serves there** (`feature_coverage.rs`, regenerated
  `openspec/contracts/cli-feature-coverage.json`). Until now every Windows status was
  `notImplemented` by rule ("no ratified profile"). The status now uses §14's closed set
  (`arkdeck-cli-product-spec.md` §14) without new values:
  - `implemented`: every leaf the entry reaches answers without the Runtime (the registry's
    `connectsToRuntime: false`) and is not refused off macOS — `help`, `commands`, `completion`,
    and the refused stubs `capability draft|install|revoke`. Their argv fixtures and rendered answers
    are held on Windows by `argv_fixtures.rs` (which runs here).
  - `notImplemented`: a leaf the entry reaches is refused off macOS for a macOS host primitive
    (`MACOS_HOST_LEAVES`, validated against the registry).
  - `partial`: otherwise. The leaves parse, build their frames and render their envelopes on Windows,
    but the target rests on a Runtime owner the Windows daemon does not compose yet, or whose answer
    no Windows run has measured end to end. §14 defines `partial` as "at least one real surface is
    implemented but the target contract or required fixture is not closed; it still blocks the
    claim", which is exactly "CLI implemented, daemon owner pending on Windows". It is not
    `implemented` and does not count toward exit condition 4.
  macOS statuses, `requiredPlatforms`, classifications and every other field are unchanged. The
  macOS-only families keep no Windows status (widening `requiredPlatforms` is a §11 profile decision,
  not this slice's).
- **`docs/design/cli-machine-contracts.md`**: the sentence stating the Windows rule.

The four non-macOS Unicode fallback arms (`target_resources.rs`, `domain_leaves.rs`,
`trace_inspect.rs`, `machine_contracts.rs`) are slice S2's and are not touched.

## Windows coverage (`cli-feature-coverage.json`, 256 entries)

| | implemented | partial | notImplemented | unset (macOS-only) |
| --- | ---: | ---: | ---: | ---: |
| Before (main `d0f72b03`) | 0 | 0 | 140 | 116 |
| After | 6 | 128 | 6 | 116 |

- `implemented` (6): `help`, `commands`, `completion`, `capability.draft`, `capability.install`,
  `capability.revoke`.
- `notImplemented` (6): `artifact.import.begin|append|commit|inspection` (the upload's plumbing,
  reached through `artifact import hap`), `artifact.import.flash-bundle`,
  `artifact.import.workspace-patch`.
- `partial` (128): 92 daemon methods, 30 Catalog operations (29 fronted, 1 generic through
  `job submit`), 6 CLI leaves (`job wait`, `operation example|validate`, `workspace continuation
  run|submit`, `diagnostics export`). This includes the three methods the Windows daemon answers by
  design (`doctor`, `operation.list`, `device.observations`): no client has reached a Windows daemon
  yet (below), so none is claimed.

## Leaves left gated, and the Windows primitive each needs

| Leaves | macOS primitive | Windows primitive it would need |
| --- | --- | --- |
| `runtime service *`, `agentd *` | LaunchAgent (`launchctl`, `launchd`) | decision 11: client autostart + single instance (G16) |
| `runtime signing *`, `signing *` | Keychain (`SecItem*`), echo-off terminal entry | Credential Manager (`CredWriteW`/`CredReadW`, DPAPI), `SetConsoleMode` without echo (G13) |
| `runtime update *` | App container lifecycle, `flock` leases, `NSURLSession` | App Installer per decision 10; not a port (G14) |
| `runtime support-bundle *` | `diagnostic_bundle` publisher, `operating_system_version` | no-follow exclusive publish with an owner-only DACL, `RtlGetVersion` |
| `maintainer update-feed prepare|assemble`, `update-feed *` | `measure_unchanged_file`, owner-only `0600` create; a macOS `.dmg` release tool | `GetFileInformationByHandle` no-follow measure, owner-only DACL (G47); Windows ships through App Installer instead |
| `flash install-binding` | I/O Registry USB census | SetupAPI / CfgMgr32 device census (G37) |
| `artifact import hap|workspace-patch|flash-bundle|native-library` | `HostImportSource` (host store, no-follow read + file identity) | `CreateFileW` with `FILE_FLAG_OPEN_REPARSE_POINT`, `GetFileInformationByHandleEx(FileIdInfo)` identity (G01/G40) |
| `--socket` (any leaf) | macOS compatibility endpoint | none: `macosCompatibilityOnly` by CLI spec §11.1, not a gap |
| Ctrl-C of a waiting leaf (`Interruption`, `main.rs`) | `sigaction` latch (`StopSignal`) | `SetConsoleCtrlHandler` latch (G10); today Windows ends the process without the interrupted envelope |

## Tests

| Test | What it holds | Runs on Windows |
| --- | --- | --- |
| `import_resources.rs` `import_list_rejects_malformed_paging_and_foreign_inventory_without_retry` (ungated) | one `artifact.import.list` frame, Swift's page refusals | yes |
| `import_resources.rs` `abort_and_inspection_validate_exact_requested_owner` (moved out of the macOS upload module) | the abort and inspection frames, Swift's owner refusals | yes |
| `import_resources.rs` `release_uses_original_generation_and_refuses_foreign_or_unbounded_receipts` (receipt half ungated) | the release frame, Swift's receipt refusals | yes |
| `import_resources.rs` `an_upload_is_refused_off_macos_before_any_frame_is_sent` (new, off macOS) | the upload refusal and that no frame is sent | yes |
| `console_approval.rs` `console_read_is_bounded_exact_and_refuses_redirected_input` | adds the Windows console's CR LF line end | yes |
| `feature_coverage.rs` `windows_status_follows_what_this_cli_serves_there` (new) | the three Windows statuses on named entries; every Windows `implemented` entry is closed and implemented on macOS | yes |
| `machine_contracts.rs` `every_owned_product_is_the_published_bytes` | the regenerated coverage is the committed file; the owned digests are unchanged | yes |
| `argv_fixtures.rs` (unchanged) | every served leaf's argv fixture replays; `commands`, `help`, `completion` render alike | yes |

No end-to-end Windows run: the CLI refuses a daemon it cannot verify (XPA-AC-6), and this host has no
development signing certificate yet (`rust/scripts/windows-dev-identity.ps1` needs one). The Import
leaves' frames are held through `execute_import`'s request adapter, not a live named pipe. The
UDS fake-Runtime harness (`tests/support/mod.rs`) is Unix-only, so the process-level tests of the
daemon-fronted leaves stay macOS-only; a named-pipe fake needs a way to satisfy the Windows identity
check in tests, which this slice does not add.

## Local targeted checks (Windows 11 x64, `CARGO_TARGET_DIR=D:\cargo-target\t2-cli`)

- `cargo fmt --all --check`: pass.
- `cargo clippy --workspace --all-targets -- -D warnings`: pass.
- `cargo test -p arkdeck-cli`: pass (every binary; the macOS-gated files compile to zero tests here).
- `arkdeck maintainer contracts export --contracts-directory openspec/contracts --fixtures-directory
  Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI`: only `cli-feature-coverage.json`
  changed.
- `python rust/scripts/refresh-contract-digests.py --check`, `copy-command-registry.py --check`,
  `copy-app-capability-registry.py --check`, `generate-contract.py --check`: pass (`PYTHONUTF8=1`).
- `sh scripts/check-sdd.sh`: pass. `git diff --check`: clean.
- Not run here: the macOS build of the moved upload code and the macOS-gated tests (no macOS
  target on this host); the macOS and ubuntu Rust lanes carry them.

## CI

To be recorded; not verified.
