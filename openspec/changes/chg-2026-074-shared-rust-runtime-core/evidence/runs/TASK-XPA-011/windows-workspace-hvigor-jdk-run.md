# TASK-XPA-011 — Windows Hvigor build end to end: the pinned JDK and tool image spelling (WM3 GJ-5, PR 6 layer 2), 2026-10-05

- Task: TASK-XPA-011, WM3 slice GJ-5. This is the second layer of the Hvigor PR (#2512), on
  top of `windows-workspace-hvigor-run.md`. That layer's live build stopped at Hvigor's
  `PackageHap` (`spawn java ENOENT`).
- Host: the Windows 11 x64 reference host, non-elevated. The installed DevEco Studio
  (`C:\Program Files\Huawei\DevEco Studio`, SDK API 26) was read and run only. No device,
  credential or HDC was used.
- Decisions: the lead's delegated decisions of 2026-10-04, recorded here as delegated minor
  decisions, pending the next rulings batch.

## What macOS does

The macOS Rust daemon gives a Hvigor child `PATH=/usr/bin:/bin`, plus `HOME`, `TMPDIR` and
`DEVECO_SDK_HOME`. It has no mechanism of its own for `java`. Hvigor's packaging runs `java` by
name and reads no `JAVA_HOME`. On macOS that resolves to `/usr/bin/java`, a system stub that
finds a JDK the host itself installed. Swift passed on the daemon's own `PATH`. The macOS
evidence runs set DevEco's JBR by hand (`TASK-DHA-003` run r4). No macOS run of the Rust
daemon has built a HAP end to end: `TASK-XPA-015` SPK-10 stopped on that host's x86-only
`ninja`. Windows has no system `java`, so the lead's narrow proposal is implemented instead of
a mirror.

## What changed

| Area | Change |
| --- | --- |
| `arkdeck-platform` `windows/deveco_files.rs` | A fifth Windows role, `java` = `jbr\bin\java.exe`. It is read no-follow under the same ownership and DACL rules as every role, must be a `.exe` the caller may execute, and is at most 16 MiB |
| `arkdeck-hoststore` `deveco_content.rs` | A Windows record pins the `java` child (identity and SHA-256, in the content digest) with its own Authenticode trust. Registration refuses an unsigned JDK launcher, as it refuses an unsigned `node.exe`. Every composition re-verifies the record |
| `deveco_registry.rs` | The Windows record carries five roles. A four-role record registered before this layer stays readable, so the index is not wedged |
| `deveco_pins.rs` `resolve_in` | On Windows a resolved toolchain names its `jbr\bin` as the Hvigor children's one search directory. A record without the `java` pin resolves no preset (`resourceConflict`: register it again). `java.exe` is among the verified resources the dispatch opens by pinned identity and holds while the child runs. macOS names none |
| `workspace_composition.rs`, `workspace_run.rs`, `workspace_patch.rs` | The search directory is kept by the Node launcher's path. Only the dispatch of a registered build or test preset passes it (`ToolInvocation::search_directory`). Patch, read, checkpoint and symbolize dispatches pass none, and macOS refuses one |
| `arkdeck-platform` `VerifiedTool::with_search_directory` (Windows) | The child's `PATH` is `<directory>;<system directory>`. The directory must exist and be given in the standard spelling of its canonical path, with no `;` or `"`. The caller-overlay rule is unchanged: a request still cannot name `PATH` |
| `arkdeck-platform` `windows/process.rs` `spawn_tool` | A tool-runner child is started by the standard `X:\…` spelling of its verified image's canonical path when that names exactly the same file. The rule is the working directory's. The suspended child's image is still proved against the retained file before it resumes. Managed servers, paired servers and consoles keep `\\?\`. Hvigor's first-run wrapper bootstrap runs `cmd.exe /c <execPath dir>\npm.cmd …`, and `cmd.exe` cannot run a `\\?\` path |
| `feature_coverage.rs`; `cli-feature-coverage.json` (exported) | `workspace.build` joins `WINDOWS_MEASURED_LEAVES`: `workspace.build-openharmony@1` is Windows `implemented` |
| Live test | The test copies no Hvigor wrapper into the fake profile any more. It checks the published HAP in the artifact store, and that the coverage manifest counts the leaf |

## Measurements

| Check | Result |
| --- | --- |
| `windows_workspace_hvigor_live_process`, `ARKDECK_LIVE_DEVECO_ROOT='C:\Program Files\Huawei\DevEco Studio'` | **Passes end to end.** Through the real CLI against the dev-signed installed-mode daemon over a fake account, holding the account's starter turn: `runtime tool register --kind deveco`, `workspace project register`, `workspace preset register`, a restart, `workspace isolate`, then `workspace build` succeeded in 43 s. It was admitted under the Runtime capability and published 2 verified Artifacts, `build.log` and the HAP. The HAP is a ZIP archive holding `module.json`, and its stored bytes match the result's SHA-256 and byte count. The person's tree holds no build product, and the account pipe is released afterwards. Passed on 3 runs. The first still seeded the account's Hvigor wrapper. The last two started from the fake profile's empty `.hvigor`, so Hvigor's wrapper bootstrapped itself (`npm install pnpm`, over the network) through the standard image spelling; they passed in 59 s and 43 s |
| `deveco_registry_owner` `windows_registration_tests` (fixture DevEco with a signed `java.exe`) | Five roles, `java` executable and `verified`. An unsigned `java.exe` under the DevEco publisher's launcher is refused `admissionDenied` with nothing written. A legacy four-role record reads |
| `the_installed_deveco_studio_registers` (ignored; run with `--ignored` and the live root) | Passes: the installed `jbr\bin\java.exe` verifies |
| `windows_deveco_files` | Five roles read with pinned identities; a JDK launcher the caller may not execute is refused |
| `windows_tool_dispatch` `a_tool_child_is_named_by_its_standard_image_path_and_may_lead_its_search_path` | The child's image path is the standard spelling. With a search directory, `PATH` is `<dir>;<system dir>` and every other row is the clean base. A `\\?\` spelling, a relative or missing directory, a file, a `;`-joined value and an other-case spelling are refused |
| `windows_workspace_hvigor` | The Hvigor child's `PATH` is the pinned JDK directory, then System32 |

## Not changed, and why

- **`workspace test`.** The WaterFlow demo's `test` task needs its `ohpm` devDependencies.
  Once installed by hand, it passes outside the Runtime with DevEco's JBR on `PATH`. `ohpm`
  links `oh_modules\@ohos\hypium` and `hamock` as **junctions**, with absolute targets inside
  the project. A macOS Runtime copy keeps an in-tree link and rewrites it relative
  (`workspace_isolation.rs` `link`). A Windows copy refuses every link or junction. So this is
  not parity: macOS does not refuse these links. Per the lead's instruction the copy is not
  relaxed. Recreating in-tree junctions on Windows needs its own decision, and the leaf stays
  `partial`.
- **`workspace symbolize`** stays `partial` until a Windows device lane captures a crash.
- **`JAVA_HOME`** is not set. Hvigor never reads it, and the build passes without it.

## Delegated minor decisions, pending the next rulings batch

1. **The JDK on a Hvigor child's search path** (the lead, 2026-10-04): a Windows DevEco record
   pins `jbr\bin\java.exe` (Authenticode, SHA-256, file identity). Only a registered build or
   test preset's Hvigor child gets exactly that directory ahead of the system directory. Every
   other child keeps the clean search path.
2. **A tool child's image spelling** (the lead, 2026-10-04): it is the standard `X:\…` spelling
   when that provably names the canonical file. This applies to tool-runner children only.
3. **Legacy Windows DevEco records** (four roles) stay readable and resolve no preset until
   registered again.

## Observed, not addressed

Node's child-process lookup, like `cmd.exe`, searches the child's working directory before
`PATH` for a bare `java`. Hvigor's working directory is the Runtime-owned copy, so a
`java.exe` in the project root would win over the pinned JDK. This predates the layer: it was
equally true when `java` could not be found at all. A copy only holds what the person's own tree
held. It is recorded for the rulings batch.

## Gates

| Check | Result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` (Windows) and the cross-check for `aarch64-apple-darwin` and `x86_64-unknown-linux-gnu` (stubbed toolchain) | exit 0 each |
| `cargo test --no-fail-fast -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli`, `ARKDECK_DEV_SIGNER_THUMBPRINT` set; again with `TEMP`/`TMP` on an 8.3 short path on C: | 274 `test result: ok` each, 0 failed. The only `SKIPPED` lines are the two known wildcard-listener ones. Without `ARKDECK_LIVE_DEVECO_ROOT` the live test says so and checks nothing |
| `maintainer contracts export` | `cli-feature-coverage.json` changes only `workspace.build-openharmony@1` Windows `partial` → `implemented`; `oracle.json` is not re-pinned |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`; `git diff --check` | `check_sdd: 0 error(s), 0 warning(s)`; clean |
