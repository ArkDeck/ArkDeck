# TASK-XPA-011 — Windows Hvigor build, tests and crash symbolization (WM3 GJ-5, PR 6), 2026-10-04

- Task: TASK-XPA-011, WM3 slice GJ-5, the Hvigor layer. It is stacked on the signing layer
  (#2508, `agent/xpa-011-windows-sign-registered-20261004`), which is stacked on the mutations
  layer (#2506) and the lanes layer (#2500). Hvigor build and test presets now run on a
  Runtime-owned copy on Windows, and the daemon's `--symbolize-crash` mode, which a symbol
  preset runs, answers on Windows too.
- Host: the Windows 11 x64 reference host, non-elevated. The composition-level test uses a
  stand-in Node. The live test uses the host's DevEco Studio
  (`C:\Program Files\Huawei\DevEco Studio`, SDK API 26), read and run only. No device,
  credential or HDC was used.

## What changed

| Area | Change |
| --- | --- |
| `workspace_composition.rs` `lower_build` | The build product's landing joins its relative path below the copy's `X:\` root with `support::join`. Before, the landing was spelled with `/` |
| `workspace_composition.rs` `inherited_base` | A build or test child inherits these on Windows: `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`, `TMP`. These are the account's profile and temporary directories, which Node and Hvigor read where macOS reads `HOME` and `TMPDIR`. On macOS it is still `HOME` and `TMPDIR`. The composition's overlay (`DEVECO_SDK_HOME`) is added as before |
| `arkdeck-agentd` `crash_symbolizer_mode.rs`, `main.rs` | `--symbolize-crash <map> <dump>` is served on Windows. An absolute path is a drive and its root, and the report is written to standard output |
| `deveco_pins.rs` `resolve_in` | On Windows a registered toolchain resolves to the installation's own files, spelled `X:\…`: `tools\node\node.exe` (the registry's `node` child), `tools\hvigor\bin\hvigorw.js`, `sdk`, and each pinned child. Before, it named macOS's `tools/node/bin/node`, so no registered preset composed (`workspace.projectProfileUnavailable: …\tools\node\bin\node: Unreadable`). macOS is unchanged |
| `arkdeck-platform` `windows/tool.rs` `child_working_directory` (the tool runner's) | The rule is unchanged: the directory must equal its canonical `\\?\` form. A tool child is now given the standard `X:\…` spelling when that names exactly the same directory: a drive-letter path under 248 characters, no component ending in a dot or a space, and no DOS device name. Otherwise it keeps `\\?\`. Hvigor joins module paths to its working directory and could not find `entry` below a `\\?\` one. A managed server and a console keep `validate_working_directory`'s `\\?\` spelling. `windows_tool_dispatch`'s working-directory case now expects the standard spelling in the child |

## Measurements

| Check | Result |
| --- | --- |
| `arkdeck-hoststore` `windows_workspace_hvigor` (`harness = false`; the test binary is the presets' Node, beside a pinned `hvigorw.js`) | The copy is made, then `workspace.build-openharmony@1` on the copy is planned `deviceMutation`, admitted under the Runtime's capability and run. It succeeds `verified`, publishing the landed `unsigned.hap` (ZIP header) and its `build.log`. The child saw the composition's `DEVECO_SDK_HOME` and the inherited `USERPROFILE` and `TEMP`, and no `HOME`. `workspace.run-tests@1` on the copy succeeds. A build of the person's own tree is refused `admissionDenied`. After the pinned `hvigorw.js` changed, a build of the copy is refused or fails, and nothing lands |
| `arkdeck-agentd` `crash_symbolizer_mode` (now macOS and Windows) | Every case of the Swift symbolizer oracle (`crash-symbolizer-oracle`), run through the built daemon with no environment and no stdin, answers Swift's report byte for byte, or exit 1 for a map that is not a JSON object. Each usage refusal gives Swift's line and exit 64, before anything is read. An unreadable absolute path is a read failure whose line does not name the path |
| `arkdeck-agentd` `windows_workspace_hvigor_live_process`, run once with `ARKDECK_LIVE_DEVECO_ROOT` set (see below) | **Fails at Hvigor's `PackageHap`** with `spawn java ENOENT`. Every step before it passes through the real CLI against the dev-signed, installed-mode daemon over a fake account, holding the account's starter turn: `runtime tool register --kind deveco`, `workspace project register` of the WaterFlow demo, `workspace preset register` (`openharmony.hvigor-build@1`, `entry@default`, debug), a restart, `workspace isolate`, and `workspace build`, admitted under the Runtime's capability. Hvigor ran in the copy and finished its CMake, Ninja, resource and ArkTS compilation steps. The Job ended `failed` with its `build.log` published |
| `deveco_pins` `windows_tests`; `windows::tool::working_directory_tests` | Pass |

### The live run

These ran in order on the reference host. Each failure was fixed or isolated before the next run.

1. `workspace isolate` was refused: `workspace.projectProfileUnavailable:C:\Program Files\Huawei\DevEco Studio\tools\node\bin\node: Unreadable`. Fixed in `deveco_pins.rs`, above.
2. `workspace build` failed in 2 s. On its first run under the fake account's empty profile,
   `hvigorw.js` bootstraps its wrapper with `cmd.exe /d /c <execPath dir>\npm.cmd install pnpm`.
   Node's `execPath` is `\\?\C:\Program Files\…\node.exe` (the verified launch's spelling), and
   `cmd.exe` splits it at the space. The test now copies the account's own
   `%USERPROFILE%\.hvigor\wrapper` into the fake profile, as a person who has built with DevEco
   has it. A daemon whose account has never run Hvigor would still meet this.
3. `workspace build` failed in 35 ms: `00303149 Path not found … \\?\<HOME>\…\workspace\entry`.
   Fixed in `child_working_directory`, above.
4. `workspace build` failed at `PackageHap`: `spawn java ENOENT`. This is the current result.

A by-hand check outside the Runtime isolates the remaining gap. Node and `hvigorw.js` were run
over a clean copy of the demo with the daemon's child environment: `PATH` set to System32 only,
plus `SystemRoot`, `WINDIR`, the five inherited names and `DEVECO_SDK_HOME`. That run fails the
same way. Prepending `C:\Program Files\Huawei\DevEco Studio\jbr\bin` to `PATH` lets it finish
`assembleHap` with exit 0 and `entry-default-unsigned.hap`. Hvigor's packing step runs `java`
by name (`JavaCommandBuilder` pushes `"java"`) and reads no `JAVA_HOME`. The Runtime's child
search path is the system directory alone, and the tool runner refuses any `PATH` overlay
(`environment cannot override the search path or the loader`).

The macOS daemon's base is `PATH=/usr/bin:/bin`, so it finds `java` only through a JDK that the
host itself installed behind `/usr/bin/java`. The macOS evidence runs set `JAVA_HOME` and `PATH`
to DevEco's JBR by hand (`TASK-DHA-003` run r4). Windows has no system `java` stub.

## Gates

| Check | Result |
| --- | --- |
| `cargo fmt --all --check` | exit 0, after `cargo fmt` dropped one blank line in `windows/tool.rs` |
| `cargo clippy --workspace --all-targets -- -D warnings` (Windows) and the cross-check for `aarch64-apple-darwin` and `x86_64-unknown-linux-gnu` (stubbed toolchain) | exit 0 each |
| `cargo test --no-fail-fast -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli`, `ARKDECK_DEV_SIGNER_THUMBPRINT` set; again with `TEMP`/`TMP` on an 8.3 short path on C: | 274 `test result: ok` each, 0 failed. The only `SKIPPED` lines are the two known wildcard-listener ones. The live test runs only with `ARKDECK_LIVE_DEVECO_ROOT` set, and says so otherwise |
| The live test, once with `ARKDECK_LIVE_DEVECO_ROOT='C:\Program Files\Huawei\DevEco Studio'` | Fails at `PackageHap` (`spawn java ENOENT`), as recorded above. The account's pipe is released afterwards |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`; `git diff --check` | `check_sdd: 0 error(s), 0 warning(s)`; clean |

## Delegated minor decisions, pending the next rulings batch

1. **What a Hvigor child inherits on Windows**: `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`
   and `TMP`, beyond the clean base (`PATH`, `SystemRoot`, `WINDIR`), where macOS gives
   `HOME` and `TMPDIR`.
2. **A Windows tool child's working directory spelling** (the tool runner only): the standard `X:\…` form whenever it
   provably names the canonical `\\?\` directory (rules above). The validation that the
   directory equals its canonical form is unchanged. The image path keeps its `\\?\` spelling.

## Needs a maintainer ruling

- **The JDK on a Hvigor child's search path.** One proposal is to measure DevEco's
  `jbr\bin\java.exe` as a further child of the registered toolchain record, Authenticode-verified
  like `node.exe`. The composition would then give that toolchain's Hvigor children
  `PATH=<root>\jbr\bin;<system directory>`. That would be the only `PATH` overlay, and the
  pinned record would name it. It changes the "the search path cannot be overlaid" rule for one
  registry-pinned directory, so it is not made here. The alternative is to leave packaging to a
  host-installed JDK, as on macOS. Windows has no system `java` stub to find one, though.
- **Node's `\\?\` `execPath`.** Hvigor's wrapper bootstrap runs `cmd.exe` with the verbatim path
  unquoted. Handing the image to `CreateProcessW` in its standard spelling, under the same rules
  as the working directory, would fix that. It touches every verified launch, so it is not made
  here.

## Left out, and why

- **The `workspace build` leaf moving to Windows `implemented`.** The live build does not finish,
  so `workspace.build` stays out of `WINDOWS_MEASURED_LEAVES` and stays `partial`.
- **`workspace test`.** The demo's `test` task needs its `ohpm` devDependencies (`@ohos/hypium`).
  By hand, with `ohpm install` run and DevEco's JBR on `PATH`, the task succeeds. The Runtime runs
  no `ohpm`, though, and `ohpm` installs `oh_modules` as links, which a Runtime-owned copy
  refuses. So the live test registers no test preset. The leaf stays `partial`.
- **`workspace symbolize`.** It reads a crash dump that a device capture published, and no Windows
  device lane captures one yet. The leaf stays `partial`.
