# TASK-XPA-011 — Windows Hvigor build, tests and crash symbolization (WM3 GJ-5, PR 6), 2026-10-04

- Task: TASK-XPA-011, WM3 slice GJ-5, the Hvigor layer. It is stacked on the signing layer
  (#2508, `agent/xpa-011-windows-sign-registered-20261004`), which is stacked on the mutations
  layer (#2506) and the lanes layer (#2500). Hvigor build and test presets now run on a
  Runtime-owned copy on Windows, and the daemon's `--symbolize-crash` mode, which a symbol
  preset runs, answers on Windows too.
- Host: the Windows 11 x64 reference host, non-elevated. No DevEco, SDK, device or credential was
  used: the Node launcher is a stand-in test binary.

## What changed

| Area | Change |
| --- | --- |
| `workspace_composition.rs` `lower_build` | The build product's landing joins its relative path below the copy's `X:\` root with `support::join`. Before, the landing was spelled with `/` |
| `workspace_composition.rs` `inherited_base` | A build or test child inherits these on Windows: `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`, `TMP`. These are the account's profile and temporary directories, which Node and Hvigor read where macOS reads `HOME` and `TMPDIR`. On macOS it is still `HOME` and `TMPDIR`. The composition's overlay (`DEVECO_SDK_HOME`) is added as before |
| `arkdeck-agentd` `crash_symbolizer_mode.rs`, `main.rs` | `--symbolize-crash <map> <dump>` is served on Windows. An absolute path is a drive and its root, and the report is written to standard output |

## Measurements

| Check | Result |
| --- | --- |
| `arkdeck-hoststore` `windows_workspace_hvigor` (`harness = false`; the test binary is the presets' Node, beside a pinned `hvigorw.js`) | The copy is made, then `workspace.build-openharmony@1` on the copy is planned `deviceMutation`, admitted under the Runtime's capability and run. It succeeds `verified`, publishing the landed `unsigned.hap` (ZIP header) and its `build.log`. The child saw the composition's `DEVECO_SDK_HOME` and the inherited `USERPROFILE` and `TEMP`, and no `HOME`. `workspace.run-tests@1` on the copy succeeds. A build of the person's own tree is refused `admissionDenied`. After the pinned `hvigorw.js` changed, a build of the copy is refused or fails, and nothing lands |
| `arkdeck-agentd` `crash_symbolizer_mode` (now macOS and Windows) | Every case of the Swift symbolizer oracle (`crash-symbolizer-oracle`), run through the built daemon with no environment and no stdin, answers Swift's report byte for byte, or exit 1 for a map that is not a JSON object. Each usage refusal gives Swift's line and exit 64, before anything is read. An unreadable absolute path is a read failure whose line does not name the path |

## Gates

| Check | Result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` (Windows) and the cross-check for `aarch64-apple-darwin` and `x86_64-unknown-linux-gnu` (stubbed toolchain) | exit 0 each, after a needless borrow in the landing join was dropped |
| `cargo test --no-fail-fast -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli`, `ARKDECK_DEV_SIGNER_THUMBPRINT` set | 270 `test result: ok`, 0 failed; only the two known wildcard-listener `SKIPPED` lines |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`; `git diff --check` | `check_sdd: 0 error(s), 0 warning(s)`; clean |

## Delegated minor decisions, pending the next rulings batch

1. **What a Hvigor child inherits on Windows**: `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`
   and `TMP`, beyond the clean base (`PATH`, `SystemRoot`, `WINDIR`), where macOS gives
   `HOME` and `TMPDIR`.

## Left out, and why

- **`workspace build`, `workspace test` and `workspace symbolize` through the daemon and the
  CLI.** A build or test preset resolves only from a registered DevEco toolchain. Registering
  one needs a Huawei-signed DevEco installation, which neither the hosted runners nor a clean
  host have. A symbolization reads a crash dump a device capture published, and no Windows
  device lane captures one yet. These leaves stay Windows `partial`; the lanes are measured at
  the composition level above.
