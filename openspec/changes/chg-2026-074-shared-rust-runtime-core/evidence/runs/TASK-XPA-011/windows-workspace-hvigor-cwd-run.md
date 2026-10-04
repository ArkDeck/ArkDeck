# TASK-XPA-011 — Windows Hvigor children never run a command from the project's directory (WM3 GJ-5, PR 6 layer 3), 2026-10-05

- Task: TASK-XPA-011, WM3 slice GJ-5. This is the third layer of the Hvigor PR (#2549, on `main`), after
  `windows-workspace-hvigor-jdk-run.md`. The lead decided on 2026-10-04 that it must not wait
  for a rulings batch: project content is untrusted, and a planted command must never run ahead
  of the pinned toolchain under the Runtime's capability.
- Host: the Windows 11 x64 reference host, non-elevated. DevEco Studio
  (`C:\Program Files\Huawei\DevEco Studio`: Node v24.14.1, libuv 1.51.0) was read and run
  only. No device, credential or HDC was used.

## The hole

Node (libuv) and `cmd.exe` resolve a bare command name in the child's working directory before
`PATH`. A Hvigor child's working directory is the Runtime-owned copy of the person's project,
and Hvigor and its wrapper run several commands by bare name:

| Run by name | Where |
| --- | --- |
| `java` | packaging (`PackageHap`), and the other Java tools of the packing step |
| `cmd.exe` | `processPlatformCmd` for `npm.cmd` (the wrapper bootstrap, `npm config get prefix`) and the ArkTS compiler's own shell runs (`es2abc`) |
| `wmic` | `getOsLanguage` (`wmic os get locale`) |

**Control run** (the flag withheld for one run of the live test): with `java.exe`, `java.com`,
`cmd.exe` and `wmic.exe` planted at the project root as copies of `whoami.exe`, the build
failed in `CompileArkTS` with `10311009 Failed to execute es2abc`. A planted image ran in
place of the system's tool.

**By hand**, with Node from DevEco and `PATH` set to `jbr\bin` then System32: in a directory
holding a planted `java.exe`, `spawnSync('java')`, `spawnSync('java', {shell: true})` and
`execSync('java …')` all ran the planted image. With `NoDefaultCurrentDirectoryInExePath=1`,
all three ran the JDK on `PATH` (`openjdk version "25.0.2"`).

## What changed

| Area | Change |
| --- | --- |
| `workspace_composition.rs` `hvigor_environment` (now public, used by the composition and its test) | A registered toolchain's Node children get `NoDefaultCurrentDirectoryInExePath=1` on Windows, beside `DEVECO_SDK_HOME`. Node (libuv `NeedCurrentDirectoryForExePathW`) and `cmd.exe` then never take a bare command from the working directory. macOS is unchanged: `execvp` searches only `PATH` (`/usr/bin:/bin`) |
| `windows_workspace_hvigor` | The Hvigor child's environment carries the flag |
| `windows_workspace_hvigor_live_process` | Before registration, these are planted at the project root, which the copy keeps and Hvigor runs in: `java.exe`, `java.com`, `cmd.exe`, `wmic.exe` (copies of `whoami.exe`, so packaging or the bootstrap would fail on them), and `java.cmd`, `java.bat`, `cmd.cmd`, `wmic.bat` (each writes a marker beside itself). The test asserts that the build succeeds and publishes its HAP, so the pinned JDK and the system's `cmd.exe` ran. It also asserts that the copy still holds the planted images and that no marker exists in the copy or the project |

## Other cwd-relative lookups, checked

| Lookup | Finding |
| --- | --- |
| `PATHEXT` tricks (`java.cmd`, `.bat`, `.com`) | `PATHEXT` is not in the child's environment, so `cmd.exe` uses its default. With the flag, no extension is tried in the working directory, and the planted scripts and `.com` never ran (live test) |
| `node_modules\.bin` | Only npm scripts prepend it to `PATH`. Hvigor runs no npm script in the project. The wrapper runs `npm install pnpm` in the account's `.hvigor\wrapper\tools\<version>`, not in the project |
| `.npmrc` in the project | `npm config get prefix` runs with the project as its working directory. Hvigor runs it only when `hvigor-config.json5` declares dependencies, and only to check that some `.npmrc` exists. The project's own registry configuration is how Hvigor installs the plugin dependencies the project declares. This is build configuration by design, so it is not closed (see below) |
| Node's own configuration (`NODE_OPTIONS`, `NODE_PATH`, `npm_config_*`) | None reaches the child: its environment is the clean base plus the named overlay. Node reads no configuration file from the working directory |
| The child's image path | It is now the standard spelling (layer 2). The search directory and the system directory are absolute |

## Not changed, and why (for the rulings batch)

A Hvigor build runs the project's own build logic: `hvigorfile.ts` in the root and in each
module, and the Hvigor plugins `hvigor/hvigor-config.json5` declares, installed from the
registry the project's `.npmrc` names. That code runs with the child's rights, on macOS as on
Windows. Closing working-directory lookups stops a planted file from silently replacing a
toolchain command. It does not make building an untrusted project safe. The build preset
(`workspace.build-openharmony@1`, `deviceMutation` on a Runtime-owned copy) executes the
project's build scripts by definition. Whether such builds need a further boundary (a
restricted token, an AppContainer, a network rule) is a design question, not this layer's.

## Delegated minor decisions, pending the next rulings batch

1. **`NoDefaultCurrentDirectoryInExePath=1` for a registered toolchain's Node children on
   Windows** (the lead, 2026-10-04).

## Measurements

| Check | Result |
| --- | --- |
| `windows_workspace_hvigor_live_process` with `ARKDECK_LIVE_DEVECO_ROOT` | Passes (`workspace build` succeeded in 38 s) with the planted images and scripts. Nothing planted ran |
| The same, with the flag withheld (control run, one run, then restored) | Fails in `CompileArkTS`: `Failed to execute es2abc` |
| `windows_workspace_hvigor` | The Hvigor child's environment carries `NoDefaultCurrentDirectoryInExePath=1` |

## Gates

| Check | Result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` (Windows) and the cross-check for `aarch64-apple-darwin` and `x86_64-unknown-linux-gnu` (stubbed toolchain) | exit 0 each |
| `cargo test --no-fail-fast -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli`, `ARKDECK_DEV_SIGNER_THUMBPRINT` set; again with `TEMP`/`TMP` on an 8.3 short path on C: | 275 `test result: ok` each, 0 failed. The only `SKIPPED` lines are the two known wildcard-listener ones. Without `ARKDECK_LIVE_DEVECO_ROOT` the live test says so and checks nothing |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`; `git diff --check` | `check_sdd: 0 error(s), 0 warning(s)`; clean |
