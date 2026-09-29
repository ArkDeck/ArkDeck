# RC readiness: nested code signing, runbook and dashboard refresh (TASK-XPA-017)

Base: protected `main` `6edb4e479` (#2307). Stage S close-out, before the maintainer's first
`build_macos_release.py release` run (prompt §4 S5/S7). No Developer ID signing, no notarization,
no contact with Apple, no installed Runtime, `launchctl`, device or credential was touched.

## 1. Nested code in the release (the #2304 known risk)

The question from #2304: the App embeds `trace_streamer`, which the "Prepare Trace Streamer" script
phase signs ad hoc (`ArkDeck.xcodeproj/project.pbxproj:568`, `codesign --force --sign - --options
runtime --entitlements TraceStreamerHelper.entitlements`), and the "Embed Trace Streamer Helper" copy
phase (`:158-170`, `dstSubfolderSpec = 6`, `Contents/MacOS`) copies it into the App. Would the
exported App carry an ad hoc nested executable that notarization rejects?

Finding: **no project change is needed.**

- The copy phase's build file already carries `ATTRIBUTES = (CodeSignOnCopy, )`
  (`project.pbxproj:70`). Xcode re-signs such a copy with the target's identity and
  `OTHER_CODE_SIGN_FLAGS`, preserving the copied code's identifier, entitlements and flags
  (`--preserve-metadata=identifier,entitlements,flags`). The Release configuration sets
  `CODE_SIGN_IDENTITY = "Developer ID Application"`, `ENABLE_HARDENED_RUNTIME = YES`,
  `OTHER_CODE_SIGN_FLAGS = "--timestamp"` and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`
  (`:779-818`), so the prepared binary's `runtime` flag and its two entitlements survive and no
  `get-task-allow` is injected.
- Observed, read-only, on the shared Release build product
  (`~/Library/Caches/com.arkdeck.ArkDeck/Xcode/Shared/DerivedData/Build/Products/Release/ArkDeck.app`,
  built 2026-09-28 11:55 by `run-xcodebuild.sh --release` from the same project settings; not built by
  this lane): `Contents/MacOS/trace_streamer` is `Identifier=com.arkdeck.desktop.trace-streamer`,
  `flags=0x10000(runtime)`, `Authority=Developer ID Application: … (8AQTYW5FKR)`, a secure
  `Timestamp=`, `TeamIdentifier=8AQTYW5FKR`, entitlements exactly `app-sandbox` and `inherit`;
  `codesign --verify --strict --deep` passes; `spctl` rejects it only as `Unnotarized Developer ID`,
  as expected before notarization.
- `-exportArchive` with `method = developer-id` re-signs the App's code with the Developer ID
  identity again; it starts from a nested signature that is already Developer ID, hardened and
  timestamped. This step itself cannot be exercised without the maintainer's identity, so the
  release entry now checks its output (below) before anything is uploaded.
- The rest of the nested code, audited statically:
  - App: the only Mach-O files are `Contents/MacOS/ArkDeck` and `Contents/MacOS/trace_streamer`
    (scan by magic of the Release product). The six SwiftPM resource bundles in `Contents/Resources`
    carry an `Info.plist` and resources only; SwiftPM products link statically; no framework, dylib,
    XPC service or `rkdeveloptool` remains (`git grep rkdeveloptool` over the project, `ArkDeckApp`
    and `Distribution` finds nothing).
  - Rust helper pair (`ArkDeckCLI.app`, `Contents/Helpers/ArkDeckAgent.app`):
    `package-rust-helpers.sh:126-129` signs the daemon bundle then the CLI bundle with
    `--options runtime` and, in the release path, `--timestamp` (`build-helpers.sh:94-96` passes
    `--timestamp` and rollback `none`); entitlements are the three keys of each `.entitlements`, no
    `get-task-allow`. The daemon's `OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable` is an
    aarch64 ELF for the device, not Mach-O; it is sealed as a resource and notarization does not
    inspect it.
  - ArkForge.bundle: `arkforge` and `arkforged` are signed by ArkForge's own packaging with
    hardened runtime and a timestamp (prompt §4 S5); the entry already checks their Team anchor.
- `codesign --verify --strict --deep` alone would **not** have stopped an ad hoc nested helper:
  a scratch copy of the Release App with `trace_streamer` replaced by the prepare phase's ad hoc
  signature and the outer bundle resealed ad hoc verifies with exit 0 ("satisfies its Designated
  Requirement"). The #2304 record's expectation that the export's strict deep verification would
  stop it was too strong; notarization would have, after an upload.

### The check added to `build_macos_release.py`

`verify_nested_code(root)` finds every Mach-O under a component by its magic (thin and fat, both byte
orders) and, for each, reads `codesign --display --verbose=4` and `--entitlements - --xml`. It fails
unless the signature is not ad hoc, has `TeamIdentifier=8AQTYW5FKR`, the `runtime` flag and a secure
`Timestamp=`, and grants no `com.apple.security.get-task-allow`; an unsigned file fails as unsigned.
It names every offending file in one refusal.

Where it runs (release mode only; the unsigned structure check still runs no `codesign`):

- right after `build-helpers.sh` (the CLI and daemon), after ArkForge's packaging, and after the
  App's export, before `notarize_app` uploads anything;
- again on the mounted DMG for `ArkDeck.app`, `ArkDeckCLI.app` and `ArkForge.bundle`.

Proof:

- Against real signatures (scratch copies; ad hoc signing only): the Release product above passes
  (`Contents/MacOS/ArkDeck`, `Contents/MacOS/trace_streamer`); the checked-in `trace_streamer`
  (linker-signed ad hoc) fails for Developer ID, Team, hardened runtime and timestamp; the prepare
  phase's output (ad hoc with `--options runtime`) fails for Developer ID, Team and timestamp; the
  resealed scratch App above fails on both executables.
- Fixture tests (`scripts/release/test_build_macos_release.py`): fixture executables now start with a
  Mach-O magic and the fixture App carries `Contents/MacOS/trace_streamer`; the recording `codesign`
  answers `--display` as the real one does. The release test asserts that both exported App
  executables are displayed before the App's upload and that all six Mach-O on the mounted DMG are
  displayed. `test_nested_code_notarization_would_reject_stops_before_the_app_upload` spoils the
  exported `trace_streamer` five ways (ad hoc, no hardened runtime, no timestamp, `get-task-allow`,
  unsigned) and requires the refusal to name it, the App never to be uploaded (only the helper pair's
  submission) and no DMG to be created.
- Mutation: with the pre-upload call removed, all five subtests fail (the App and DMG are uploaded
  before the mounted check refuses); restored.

## 2. Runbook and run records

`docs/design/cross-platform/macos-rust-cutover-runbook.md`:

- P2 and appendix B item 1: the gap is closed by #2302's `loaderTransitionsCoverTarget`; the stale
  `main.rs:716-724` pointer is now `main.rs:385-395` with `rockchip_startup.rs`.
- P7 (and appendix B item 6, the rulings note on P2): F1/F2 fixed by #2303, pointers to
  `loader.rs:38`, `authority.rs:428` and the vector test; the old `device-facts` guidance ("do not
  replace the bundle before the ruling") is replaced by "use the RC's bundle built from the pin".
- Every pointer into `rust/crates/arkdeck-cli/src/runtime_service_install.rs` re-anchored at
  `6edb4e479` by the construct it names (`install` :461-596, `cutover` :602-679,
  `refuse_unless_clear` :682-704, `block_text` :706-762, `probe` :775-850, Swift detection :837,
  `write_snapshot` :1017-1054, `replace_bundle` :1056-1091, `plist_document` :1096-1189, `receipt`
  :1193-1221, `update_request` :304-438, and the lines within them).
- Step 4 (SPK-8) is left to #2308, still open at this base.

CI results added to the run records that said "Pending" (from `gh pr view <N> --json
mergeCommit,statusCheckRollup`): #2301 run 36413866804 → `f968192e6`; #2302 run 36416346545 →
`092b45eb8`; #2303 final run 36423512334 → `e2f96a29b`; #2304 final run 36420132577 → `0aef701e5`;
#2305 run 36419884967 → `53b832780`. All green on their last heads.

## 3. Dashboard refresh (`evidence/macos-remaining.md`)

Counted at `6edb4e4792b560e1253685fd7f0cad3b4e22e362`, each script twice with identical output.

- PYCOUNT (the dashboard's block, ref updated): 105 / 105 routes (default only `trace_inspection`),
  199 parser names, 140 / 256 registered, 16 ClientKit facades and 0 in Workflows, 0 App imports,
  0 pbxproj lines, 0 / 6 Swift targets deleted, `MATERIALIZED` 28 / 30. Output SHA-256 prefix
  `8abd9d78bbc5630c`.
- `count_operations.py` from `dashboard-refresh-20260926-run.md`, with these rows appended to
  `EVIDENCE` and a third composition kind whose test marker is `arkdeck_agentd::serve_control(`:

  ```python
  SOCKET_TEST = "arkdeck_agentd::serve_control("
  FLASH_SOCKET = TESTS + "spawning/flash_socket_control.rs"
  # marker = {"isolated": ISOLATED, "production": PRODUCTION, "socket-test": SOCKET_TEST}[composition]
      ("workspace.run-tests@1", "production", TESTS + "workspace_tests_process.rs",
       "the_production_daemon_runs_tests_only_in_its_copy_and_keeps_the_result",
       "workspace.run-tests"),
      ("flash.full-restore@1", "socket-test", FLASH_SOCKET,
       "agent_run_flashes_to_completion_over_the_control_socket", "flash.full-restore@1"),
      ("flash.full-restore@1", "socket-test", FLASH_SOCKET,
       "agent_run_leaves_an_unknown_flash_outcome_unknown_over_the_control_socket",
       "flash.full-restore@1"),
      ("flash.full-restore@1", "socket-test", FLASH_SOCKET,
       "flash_run_flashes_to_completion_over_the_control_socket", "\"flash\""),
      ("flash.full-restore@1", "socket-test", FLASH_SOCKET,
       "flash_run_leaves_an_unknown_flash_outcome_unknown_over_the_control_socket", "\"flash\""),
      ("flash.dayu200", "socket-test", FLASH_SOCKET,
       "agent_run_of_the_alias_flashes_to_completion_over_the_control_socket", "flash.dayu200"),
  ```

  and one more printed line, `Supplement (either daemon composition)`. Output (SHA-256 prefix
  `643bdd3e97a7185c`): 17 / 30 isolated; 26 / 30 either daemon composition; 28 / 30 any
  composition including the socket-test Host; `MATERIALIZED` 28 / 30; `flash.full-restore@1` and
  `flash.dayu200`: `socket-test (not in MATERIALIZED)`; `workspace.build-openharmony@1` and
  `workspace.sign-openharmony-hap@1`: `-`; citations that did not verify: none.

Classification of the Flash evidence, as the dashboard now states it: the production control
transport (`serve_control`, the daemon's own serving and drain loop) and the real `arkdeck` CLI, but
a Host the test binary composes, with the Swift Flash oracle's fake ArkForge lane and Rockchip host
as its only external ports. It is neither the isolated nor the production daemon binary, so it is
counted as its own class (28 / 30), not folded into 26; the lane's IPC and production lane startup
meet it only in phase A's GJ-4.

Also updated: the M4 and M5 milestone rows, the software-gaps paragraph (closed: `agent.run` Flash
#2305, the broker's pinned Flash #2307, the preflight Loader block #2302, F1/F2 #2303, the release
entry #2304; open: SPK-8 negatives #2308, S6, the first signed `release` run), the installed-product,
Golden Journey and CLI bullets that still described pre-#2305/pre-#2272 states, the XPA-017 task row,
and a History entry.

## Local targeted checks

- `python3 scripts/release/test_build_macos_release.py`: exit 0, 19 tests (Release, Unsigned and
  Versions classes; the real-`hdiutil` case ran) — `/private/tmp/arkdeck-rc-release-tests.log`.
- The mutation above: 5 of 5 subtests fail without the pre-upload call; restored, file byte-identical.
- Real-signature probes of `verify_nested_code` and the `--deep` scratch probe (scripts in the
  session scratchpad; outputs quoted above).
- `sh scripts/check-sdd.sh`: exit 0, 0 errors, 0 warnings, 121 acceptance IDs —
  `/private/tmp/arkdeck-rc-check-sdd.log`.
- PYCOUNT and `count_operations.py` twice each at the base, outputs identical (hashes above).

Not run: `xcodebuild archive`/`-exportArchive` (an ad hoc archive is a cold Release build while
another lane holds the host's Xcode build, and would not exercise the Developer ID export; the
existing Release product and the fixture tests stand in); any Rust or Swift build or test (no Rust
or Swift source changed); `generate-contract.py --check` (no contract input changed).

## CI

Final: #2310 head `2a57e18bb`, Swift CI run 36438602989 success (the `swift` aggregate and every selected lane), SDD Guard run 36438602042 success; squash-merged as `2f75ae8e5` on 2026-09-28. Recorded by the docs-only follow-up (TASK-XPA-017).
