# TASK-XPA-015 — the pinned `xcode-select` tool shim (macOS, 2026-09-26)

TASK-XPA-015 remains in progress. The coordinator, acting for the
maintainer, ruled on 2026-09-26 that pinning an Xcode tool shim is a safety
defect of both the installed Swift Runtime and the Rust port. The ruling
asked for one change that fixes both and fails closed. Base: `main`
`3315a9cba`.

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No contract
input, Catalog, `openspec/contracts`, `openspec/specs` or constitution
changes, and no schema changes: every refusal uses a reason code that
already exists.

## What failed

On #2197's CI (run 36168390019, job 108181712900) the published contract
view failed `rust/crates/arkdeck-agentd/tests/workspace_checkpoint_process.rs:227`:
a `workspace.create-checkpoint@1` Job ended `failed`, with
`executionFailed` and a Session publication failed with
`sourceIntegrityFailed`. The same test passed in the lane's own step and in
the candidate view.

- The racy-index lead was checked first and does not hold here. On
  Apple Git-157 (git 2.54.0) the index stores nanosecond times.
  `git stash create` rewrites `.git/index` on every run, but in the test's
  sequence the bytes stay the same (0 of 20 both with and without the prior
  `git status`). A change to the index bytes between admission and run is
  refused before dispatch, and that Job's Session publishes, which is not
  the shape CI saw.
- The failure repeats locally: 4 failed Jobs in 160 rounds of the test's
  flow. All four were git checkpoints, and each failed in its step:
  `workspace.checkpointFailed: real process exit=1 stdoutBytes=0
  stderrBytes=99`. A temporary patch, since removed, captured the stderr:
  `clang: error: no such file or directory: 'stash'` and the same for
  `'create'`. The job-status shape (failure after the step intent, Session
  `sourceIntegrityFailed`) matches CI.
- `/usr/bin/git` is not git. It is Xcode's `xcode-select` tool shim, one file
  (inode 1152921500312607511 on this host) hard-linked under 78 names —
  `git`, `clang`, `cc`, `make`, `python3`, `swift`, `ld`, `strip` and more —
  signed `com.apple.dt.xcode_select.tool-shim-public`. It picks the tool it
  runs by the path the kernel reports for the process, never by `argv[0]`.
  Both runtimes launch a pinned executable from its retained inode,
  `/.vol/<device>/<inode>` (Rust `VerifiedTool::spawn_in`, Swift
  `DescriptorBoundProcessDispatcher`'s `.stableInodePath`), and there the
  kernel reports whichever of the file's names it last recorded. Once
  `/usr/bin/clang` had started by name, the shim launched from its inode ran
  clang 20 times of 20. Once `/usr/bin/make` had, the checkpoint's argument
  vector became `make -C <root> stash create`: the project's Makefile ran,
  and the step exited 0 with no output. The Runtime would have judged that
  `checkpointEmpty`, but by then the Makefile had already run.
- Either way the pinned digest covered no tool: even when the shim runs git,
  the git it runs is the one in the developer directory, whose bytes were
  never measured. Both outcomes break the rule that only the exact tool in
  the materialized plan runs.
- The failure is occasional because the launcher opens the shim by path
  again before it spawns (`revalidate`), and that often gives the name back
  to `git`. Another process must start one of the other names in between.

## The fix, in Swift and Rust alike

1. **Identification.** A shim is told by the identifier in its code signature
   (the CodeDirectory `codesign -d` prints), with the prefix
   `com.apple.dt.xcode_select.tool-shim`, in any architecture of the file.
   Neither the name nor the link count decides it: `/usr/bin/grep` is linked
   three times and is signed `com.apple.bzgrep`. Swift `XcodeToolShim` and
   Rust `arkdeck_platform::tool_shim` read the identifier the same way, from
   the file's bytes or through the retained descriptor.
2. **Resolution and pinning.** Pinning `/usr/bin/git`
   (`WorkspaceExecutableIdentity.hashing(path:)` /
   `ExecutableIdentity::hashing`) pins what a launch of that path runs.
   For a shim, that is the tool `/usr/bin/xcrun --find <name>` resolves,
   run with a cleared environment after xcrun's own identifier is checked to
   be `com.apple.xcrun`. The answer's physical path must be a regular Mach-O
   file that is not a shim. It is then pinned by the existing flow (path and
   SHA-256) and launched from its own inode. On this host that is
   `/Applications/Xcode.app/Contents/Developer/usr/bin/git`, one link,
   `com.apple.git`, and it runs git whichever name the shim last took.
   Resolutions are remembered per shim file identity and per `xcode-select`
   choice; a resolution that failed is never remembered.
3. **`DEVELOPER_DIR`.** Neither runtime passes `DEVELOPER_DIR` to a
   workspace tool. Swift's workspace child environment is the clean base,
   plus `DEVECO_SDK_HOME` when an SDK is registered; Rust's is the clean base.
   So the shim chose its tool through `xcode-select`'s choice
   (`/var/db/xcode_select_link`), and `xcrun --find` with a cleared
   environment resolves through the same choice. A different choice resolves
   again.
4. **Refusals, all before any dispatch and all with existing codes:**
   - When xcrun resolves nothing, or resolves to another shim, the shim
     itself stays pinned, and every operation of its profile is unavailable
     as `provider_tool_unavailable` (`workspace.toolchainUnavailable`). The
     tool is never swapped: a WaterFlow checkpoint does not quietly become a
     sealed archive.
   - A pinned tool whose digest has moved is `tool_identity_drift`, as
     before.
   - The dispatcher's executable resolution (Swift
     `WorkspaceActionExecutableResolver.validated`, Rust
     `generic_resolution`) refuses a pinned shim.
   - The launcher refuses any shim (Rust `VerifiedTool::open`, Swift
     `VerifiedExecutableDescriptor.open` →
     `ProcessExecutionError.executableIsToolShim`). Every identity-bound
     launch, of either launch mode, opens its executable there.

## Pinned host tools

Every host-tool path either runtime names, read on this host:

| Path | Links | Signing identifier | Shim | Where |
| --- | --- | --- | --- | --- |
| `/usr/bin/git` | 78 | `com.apple.dt.xcode_select.tool-shim-public` | yes | Swift and Rust workspace profiles (source control) |
| `/usr/bin/python3` | 78 | `com.apple.dt.xcode_select.tool-shim-public` | yes | a Rust CLI test only, started by path |
| `/usr/bin/grep` | 3 | `com.apple.bzgrep` | no | workspace profiles (inspection) |
| `/usr/bin/sed` | 1 | `com.apple.sed` | no | workspace profiles (source range) |
| `/usr/bin/patch` | 1 | `com.apple.patch` | no | workspace profiles (unified diff) |
| `/usr/bin/bsdtar` | 1 | `com.apple.bsdtar` | no | workspace profiles (sealed archive) |
| `/usr/bin/xcrun` | 1 | `com.apple.xcrun` | no | the resolver; a Rust test |
| `/usr/bin/pgrep`, `/usr/bin/pkill` | 2 | `com.apple.pkill` | no | tests |
| `/usr/bin/security`, `mkfifo`, `nc`, `printenv`, `touch`, `true`, `false`, `yes` | 1 | their own | no | tests and fixtures |
| `/bin/cp`, `echo`, `kill`, `launchctl`, `ls`, `sh`, `sleep` | 1 | their own | no | tests and fixtures |

HDC, DevEco's Node and Hvigor, symbolizers and signing tools are registered
by path from their own installations, not from `/usr/bin`. Should one ever
be a shim, the launcher refuses it.

## Tests

| Test | What it holds |
| --- | --- |
| Rust `tool_shim::tests` (5) | Synthetic images: the identifier per architecture, one shim architecture makes a shim, malformed or cut bytes are nothing. On the host: `/usr/bin/git` is a shim through its bytes and its descriptor; `grep` (three links), `sed`, `patch` and `bsdtar` are not. `resolve("git")` is a non-shim `com.apple.git`, and names with a slash, a dash or a NUL are refused. `VerifiedTool::open` refuses `/usr/bin/git` and opens what it resolves to |
| Rust `workspace_profile::tests` (3 new, 1 tightened) | What is pinned for `/usr/bin/git` is what xcrun resolves, and `sed` is itself. A profile left pinning the shim offers `provider_tool_unavailable` for every operation, and a registry of shims resolves nothing. Launched from its inode after clang and then make last started by name, the pinned git leaves git's object and no mark: the Rust document equals Swift's `after.json`, and `codesign` confirms the pin is no shim. The derived-profile test now checks the pin it actually made |
| Rust `workspace_checkpoint_process` (agentd) | The production daemon's two git checkpoints now come after clang and after make have started, with a committed Makefile whose targets would leave marks. Both still succeed as git, and no mark exists |
| Swift `XcodeToolShimContractTests` (7) | The same cases for `XcodeToolShim`, `VerifiedExecutableDescriptor.open` (`executableIsToolShim`), `WorkspaceExecutableIdentity.hashing`/`measuring`, provider availability and `WorkspaceActionExecutableResolver` |
| Swift `XcodeToolShimOracleContractTests` | Records and checks what the pinned git runs (below) |

**Determinism.** The shim's name belongs to the whole host: any process that
starts one of its names moves it. The tests therefore prime the name as far
as it will go, starting the tool by name until the shim itself, launched
from its inode, runs it. The priming is never required to hold. What decides
each test is whether the pin is a shim, read by `codesign` independently of
the Runtime's own reading, and the pinned launch's outcome, which after the
fix no priming changes. A full parallel `hoststore` run first failed the
priming check that an earlier version still required. That check is now
best effort, and three full runs passed (345 of 345).

**Mutation.** With the shim identification removed (`is_tool_shim` answering
false), every shim test goes red: the three `workspace_profile` tests, the
launch test at "`/usr/bin/git` is a shim:
`com.apple.dt.xcode_select.tool-shim-public`", and the platform tests. The
negative control was seen before the fix too. Three runs of the launch test
under that mutation recorded, for the make round, `exit status: 0 "" ""`,
with marks `["ran-make-stash", "ran-make-create"]`: the Makefile's targets
ran. For the clang round they recorded clang's two errors, and in one run
make again.

**The flake.** The test's own flow, looped: 4 failed Jobs in 160 rounds
before the fix, 0 in 100 after it.

## The oracle

Swift `XcodeToolShimOracleContractTests` exercises only the product's
pinning (`WorkspaceExecutableIdentity.hashing`). The launch from the inode,
`codesign` and xcrun's answer are the test's own, so the same file records
the Runtime before and after the fix. Paths that differ between hosts are
named rather than spelled: `<xcrun --find git>` and `<root>`. Recorded with
`ARKDECK_RUST_TOOL_SHIM_RECORD=<dir> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter XcodeToolShimOracleContractTests`:

- `before.json`: recorded with the Swift sources at `main` `3315a9cba`
  and only the oracle test added. The pin is `/usr/bin/git` itself,
  `com.apple.dt.xcode_select.tool-shim-public`. Once clang had last started,
  the pinned launch ran clang: exit 1, clang's two errors, no checkpoint
  object. Once make had, it ran `make -C <root> stash create`: exit 0, no
  object, and both marks `ran-make-stash` and `ran-make-create`. Of four
  recordings, the make round ran the Makefile in all four, and the clang
  round ran clang in two and git in the other two. The fixture is the second
  recording, which shows both.
- `after.json`: recorded with this change. The pin is `<xcrun --find git>`,
  `com.apple.git`, and both rounds leave git's checkpoint object, exit 0,
  empty stderr and no mark.

The Rust port builds the same document with its own pinning and compares
it with `after.json`; they are equal. `before.json` is the defect's
evidence and is not replayed. `provenance.json` records the command, both
recordings and their digests.

## Local targeted checks

| Check | Command | Result |
| --- | --- | --- |
| Format | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 |
| Lint | `cargo clippy -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd --all-targets -- -D warnings`, natively and with `--target x86_64-pc-windows-msvc` and `x86_64-unknown-linux-gnu` | exit 0 on all three |
| Tests | `cargo test -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd --no-fail-fast` | 1,022 passed over 125 targets; the one failure was the priming check, since made best effort, and `hoststore --lib` then passed three times |
| Swift | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter '<23 classes>'`, with `ARKDECK_RUST_TOOL_SHIM_RECORD` set | The 23 test classes that pin git, open or launch identity-bound executables, resolve workspace executables or answer workspace availability (`XcodeToolShim*`, `Workspace*`, `ProcessExecutor`, `ArchitectureBoundary`, `OpenHarmonyLocalSigning`, `DeviceProvider`, `AnalyzerProvider`, `ArkTraceSummaryAnalyzer`, `ArkForgeLaneAssembly`, `EvolutionWorkspace`, `HostOnlyAdmission`, `NativeLibraryDeployment`, `RuntimeOwnedWorkspace`): 276 tests, 0 failures, 1 skipped (`ArkTraceSummaryAnalyzer`'s reviewed distribution, not provided on this host). `XcodeToolShim.swift` alone also type-checks with `-strict-memory-safety` and no warning |

`CARGO_BUILD_JOBS=2`, `CARGO_TARGET_DIR=/private/tmp/arkdeck-sleepy-allen-1abe73-rust-target`.

## Seen, not changed here

Even a successful git checkpoint's Session publication fails with
`sourceIntegrityFailed` on the Rust daemon. A checkpoint Job whose step is
refused before dispatch publishes its Session. The process test does not
check this. Whether Swift publishes these Sessions has not been recorded.

## CI

- This PR: pending.
