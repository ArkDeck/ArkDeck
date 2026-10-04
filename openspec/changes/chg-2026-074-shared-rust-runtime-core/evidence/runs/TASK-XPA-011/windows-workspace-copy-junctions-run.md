# TASK-XPA-011 — A Windows workspace copy recreates in-tree junctions, and `workspace test` runs end to end (WM3 GJ-5, PR 6 layer 4), 2026-10-05

- Task: TASK-XPA-011, WM3 slice GJ-5. This is the fourth layer of the Hvigor PR (#2512), after
  `windows-workspace-hvigor-cwd-run.md`.
- Decision: the lead's of 2026-10-04 (macOS parity). A macOS Runtime copy keeps a link that
  resolves inside the source tree and rewrites an absolute one relative. On Windows, an
  in-tree junction is recreated under the same rules. Recorded as a delegated minor decision,
  pending the next rulings batch.
- Host: the Windows 11 x64 reference host, non-elevated. DevEco Studio was read and run only.
  `ohpm install` ran in the test's own project as the test's setup, from the account's `ohpm`
  cache. No device, credential or HDC was used.

## Why

`ohpm install` links a project's packages as directory junctions with absolute targets inside
the project. Examples: `oh_modules\@ohos\hypium` points into
`oh_modules\.ohpm\@ohos+hypium@1.0.21\…`, and `entry\oh_modules\libcrashprobe.so` points into
`entry\src\main\cpp\types\libcrashprobe`. A Windows copy refused every link, so a copy of an
installed project failed, and the module's unit tests, which import `@ohos/hypium`, could not
run in a copy.

## What changed

| Area | Change |
| --- | --- |
| `arkdeck-platform` `windows/junction.rs` (new) | `junction_target` reads a reparse point without following it. It answers the target of a mount-point junction as `X:\…`, answers `None` for any other reparse kind (a symbolic link, a placeholder), and refuses a junction naming a volume (`\??\Volume{…}`), UNC or device path. `create_junction` makes a new directory and sets a mount-point reparse point on it, which needs no privilege, naming a drive-letter target. A half-made link is removed |
| `workspace_isolation.rs` `Copy::link` (Windows) | A link in the source is recreated only when it is a junction to a drive-letter directory, its target is an existing directory with every link on the way resolved (`canonicalize`), and that target lies inside the canonical source root (`strip_prefix`, normal components only). It is recreated as a junction naming the copy's corresponding directory at the copy's **published** path. The copy is made in `.workspace.tmp` and renamed to `workspace`, and a junction's target is absolute. Anything else is still refused: a symbolic link, a junction out of the tree directly or through another junction, and a dangling junction |
| `copy_isolated_tree` | Takes the published root beside the destination. `prepare` passes `workspace` |
| `arkdeck-platform` `create_private_file` and `create_private_directory` (Windows) | Through `extended_length`, a drive-letter path of 248 characters or more opens in its `\\?\` form, so the copy writes past `MAX_PATH`. Below the daemon's state, the copy of `oh_modules\.ohpm\@ohos+hypium@1.0.21\oh_modules\@ohos\hypium\src\main\module\assert\…` exceeds 260 characters. The live run's first failure was `unsafeSourceEntry("assertPromiseIsRejectedWithError.js")`. Paths with `.`, `..` or empty components keep their form |
| `feature_coverage.rs`; `cli-feature-coverage.json` (exported) | `workspace.test` joins `WINDOWS_MEASURED_LEAVES`: `workspace.run-tests@1` is Windows `implemented` |
| `windows_workspace_hvigor_live_process` | It installs the project's `ohpm` dependencies (`ohpm install --all`), registers a test preset (`openharmony.hvigor-test@1`) beside the build preset, and after the build runs `workspace test` on the same copy. It asserts the junctions in the copy name directories inside the copy, and checks the coverage of both leaves |

Sweeping a copy removes its junctions without following them: the standard library's
`remove_dir_all` deletes a junction as a link. A copy's junctions name only the copy itself.

## Measurements

| Check | Result |
| --- | --- |
| `windows_workspace_hvigor_live_process` with `ARKDECK_LIVE_DEVECO_ROOT` | **Passes end to end.** `ohpm install --all` leaves the project's junctions, and `workspace isolate` copies it. `oh_modules\@ohos\hypium` and `entry\oh_modules\libcrashprobe.so` in the copy are junctions into the copy. `workspace build` succeeded in 47 s and published its HAP. `workspace test` then succeeded in the same copy, with every published Artifact `bytesVerified` and no evidence blocker. The planted commands of layer 3 still did not run. The test took 127 s in all |
| `workspace_isolation` `windows_link_tests` | An in-tree junction is recreated naming the copy's own store after the copy is renamed to its published path. A file past `MAX_PATH` is copied. A write through the copy's junction changes the copy, never the source, and removing the copy leaves the source whole. A junction out of the tree, one in-tree by name that leaves through another junction, and a dangling one are each refused `unsafeSourceEntry`. Once they are gone, the tree copies |
| `windows::junction` tests | A created junction reads back its target and resolves there. An ordinary directory is no junction. UNC, volume and relative targets are refused and leave nothing behind |
| `windows::extended_length_tests` | Only a long plain drive-letter path takes the `\\?\` form |

## Delegated minor decisions, pending the next rulings batch

1. **In-tree junctions in a Windows copy** (the lead, 2026-10-04, macOS parity): recreated
   naming the copy's corresponding directory at its published path. Symbolic links and every
   other link stay refused.
2. **Long paths in the copy**: `\\?\` for drive-letter paths of 248 characters or more in the
   platform's private file and directory creation.

## Gates

| Check | Result |
| --- | --- |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` (Windows) and the cross-check for `aarch64-apple-darwin` and `x86_64-unknown-linux-gnu` (stubbed toolchain) | exit 0 each |
| `cargo test --no-fail-fast -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli`, `ARKDECK_DEV_SIGNER_THUMBPRINT` set; again with `TEMP`/`TMP` on an 8.3 short path on C: | 275 `test result: ok` each, 0 failed. The only `SKIPPED` lines are the two known wildcard-listener ones. Without `ARKDECK_LIVE_DEVECO_ROOT` the live test says so and checks nothing |
| `maintainer contracts export` | `cli-feature-coverage.json` changes only `workspace.run-tests@1` Windows `partial` → `implemented`; `oracle.json` is not re-pinned |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh`; `git diff --check` | `check_sdd: 0 error(s), 0 warning(s)`; clean |
