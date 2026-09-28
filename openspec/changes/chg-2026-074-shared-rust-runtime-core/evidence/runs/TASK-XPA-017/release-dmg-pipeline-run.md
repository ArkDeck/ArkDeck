# TASK-XPA-017 — notarized release DMG pipeline (stage S, slice S5; macOS, 2026-09-28)

Scripts, fixture tests, CI wiring and documentation for the release candidate the maintainer builds at
the end of stage S. **Nothing was signed with Developer ID, notarized, sent to Apple, installed or run
against the installed Runtime, launchd or a device.** Signing and notarization changes need maintainer
review before merge.

Maintainer rulings applied (2026-09-28, recorded in the runbook's opening section by #2301): the release
is notarized (overriding Q11); one DMG ships App and helpers at one version; there is no Swift
transitional release and no Swift rollback build — the rollback is the installed helper that
`runtime service update` keeps in `Helpers/.rollback` plus the maintainer's `ditto` copy.

## What changed

- **Release entry** `scripts/release/build_macos_release.py`. Placed under `scripts/release/` rather than
  `Packages/ArkDeckKit/Distribution/macOS/`: the release spans the Xcode project, the Rust workspace and
  the ArkForge checkout, not the Swift package, and S6 retires the Swift package's targets. Python rather
  than shell so that every step can be driven by recording tools and its failures stay in one place. Two
  modes share the component checks, DMG assembly and mounted verification:
  - `release` (maintainer): preflight (version lockstep, clean checkout, ArkForge checkout clean and its
    `HEAD` equal to the `rust/Cargo.toml` pin, signing identity present, `notarytool history` with the
    keychain profile) before anything is built; the helper pair through `build-helpers.sh` Rust mode
    (sign, notarize, staple, spctl); ArkForge.bundle through the checkout's
    `packaging/macos/package-arkforge.sh`; the App through `xcodebuild archive` (Release) and
    `-exportArchive` with the new `scripts/release/ExportOptions.plist` (`developer-id`, manual, Team
    `8AQTYW5FKR`), then notarized, stapled and assessed by itself; the DMG (`hdiutil create` UDZO)
    signed with `--timestamp`, `notarytool submit --wait --output-format json`, `stapler staple` and
    `validate`, `spctl -a -t open --context context:primary-signature`; then mounted read-only and
    verified: entries, each item's tree equal to what was staged, strict deep verification, spctl and
    staple of the mounted App and CLI, the App's own requirement, **the exact requirement the App holds
    the daemon to** (`AgentXPCContract.serverCodeRequirement`: anchor, Team, identifier,
    `CFBundleShortVersionString` and `CFBundleVersion`), and the Team anchor of the two ArkForge
    executables.
  - `unsigned` (anyone, CI): prebuilt `--app`, `--helpers`, `--arkforge-bundle`; same checks, an
    unsigned DMG, mount and tree comparison; no codesign, xcrun, spctl or security call. The DMG and the
    output carry `UNSIGNED-STRUCTURE-CHECK-ONLY.txt`.
  - Component checks (both modes): bundle identifiers; every bundle's version pair equals the version
    source; the daemon carries no facade; ArkForge.bundle obeys the loader's rules (schema, members'
    bytes and SHA-256, no undeclared file, no link — `arkforge_bundle.rs` `reject_undeclared`) and is
    nested in neither app.
  - Output only after every step passes: `ArkDeck-<version>-<build>.dmg`, `release-receipt.json`
    (`arkdeck.macos-release-receipt/1`: source revision and cleanliness, version and build, ArkForge pin,
    built revision, manifest SHA-256 and members, DMG SHA-256/bytes/entries, App/CLI/daemon tree and
    executable SHA-256, App and DMG notary submission ids), and the two notary logs.
  - DMG layout: `ArkDeck.app`, `ArkDeckCLI.app` (Rust daemon at `Contents/Helpers/ArkDeckAgent.app`),
    `ArkForge.bundle` as its own item, `INSTALL.md` (= `docs/release/macos-install.md`).
  - Not embedding the CLI in the App: the helpers carry their own provisioning profiles and entitlements,
    so embedding them would need "Code Sign On Copy" off and an App-owned install path the sandboxed App
    cannot use; they ship beside the App as the ruling's DMG layout says.
  - ArkForge.bundle is not stapled on its own (not an `.app`, and the loader refuses the extra file a
    ticket would add); the DMG's notarization covers it. ArkForge's script notes the same.
- **`build-helpers.sh` Rust mode** no longer requires or retains `ARKDECK_ROLLBACK_HELPER`; the rollback
  notarize/staple/assess block is gone from that mode. Swift mode is unchanged (S6 deletes it).
  `LaunchAgentServiceContractTests` now counts three notarize/staple/assess steps (Swift pair, Swift
  facade rollback, Rust pair) and asserts the script no longer names `ARKDECK_ROLLBACK_HELPER`.
  `build-local-helpers.sh` (development only) is untouched.
- **Single version source** `scripts/release/release-version.json` (`0.1.0`, build `1`, unchanged) and
  `scripts/release/release_version.py` (`check`, `print`, `bump-build`, `set <version> <build>`) keeping
  the pbxproj `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` (Debug and Release), `ArkDeckApp/Info.plist`'s
  build-setting references, and both helper Info.plists (what `check-rust-helpers.py` compares) in
  lockstep. Values are limited to dot-separated numbers of at most three parts, the only form
  `serverCodeRequirement` accepts. The release version is not chosen here.
- **Tests** `scripts/release/test_build_macos_release.py` (18 cases): the full `release` run with
  recording `git`, `security`, `cargo`, `lipo`, `codesign`, `spctl`, `ditto`, `xcodebuild`, `xcrun`,
  `hdiutil` through the real `build-helpers.sh` and `package-rust-helpers.sh`; refusals before any build
  (ArkForge `HEAD` other than the pin, dirty ArkForge checkout, dirty source checkout, missing notary
  profile); a rejected DMG notarization, a failed DMG signature and an App from another build publish
  nothing; the unsigned mode with recording and with the **real `hdiutil`** (create, attach, compare,
  detach); an undeclared ArkForge member, a daemon with a facade, ArkForge nested in an app and an
  existing output are refused; the version tool's check, bump, set validation and drift. Every case
  asserts no temporary root leaks, no DMG stays attached, and `launchctl`/`swift` are never called.
- **CI**: Swift CI's always-run plan job runs `release_version.py check`; Rust CI's macOS workspace job
  runs the fixture tests after the helper structure check; `plan.py` selects the Rust lane for
  `scripts/release/` (test in `test_plan.py`).
- **Docs**: `docs/release/macos-install.md` (DMG layout; copy both apps; copy ArkForge.bundle out of the
  DMG with `ditto` to a stable versioned path and keep earlier ones; `runtime service update --daemon …
  --hdc … --arkforge-bundle …` for first install and upgrade; the maintainer's RC build). Runbook: the
  variable block and P3 now name the RC and the maintainer's `$ROLLBACK` copy instead of
  `$RUST_OUT/rollback`, and P3's notarization is mandatory. ADR-0002 gets a dated note that its
  `macOS 14 / arm64` support cell disagrees with deployment target 26.0 (body not rewritten; the
  maintainer decides). `rust-helper-packaging-run.md` item 2 (Q11) is marked superseded.
  `LaunchAgents/README.md` describes the Rust release without the rollback helper.

One deviation from the slice text: the request named `runtime service install|update --hdc …`. In the Rust
CLI, `runtime service install` is the typed bootstrap-registry install (`--bundle`,
`--bundle-generation`; `runtime_service_install.rs` `typed_install`), while path inputs go through
`runtime service update` (or its compatibility spelling `agentd install`), which also serves a first
install. The guide uses `update` for both and says so.

## Not done here

- No Developer ID signing, notarization or Apple upload; no real `xcodebuild archive` (not quick, and an
  unsigned archive would not exercise the export); no real ArkForge build (the local ArkForge checkout
  is not at the pin, and its packaging script needs a Developer ID identity).
- Whether `-exportArchive` re-signs the ad hoc `trace_streamer` the App's build phase signs is not
  verified without an identity; the export's strict deep verification, the App notarization and the
  mounted `spctl` would each stop the release if it does not.
- `tasks.md` XPA-017 "empty entitlements" wording: left to the 017 closing PR as planned.
- Update feed and GitHub Release: after G5, by the maintainer.

## For the maintainer (stage S exit, S7)

From a clean checkout of the chosen `main` commit, after optionally `release_version.py bump-build`
(committed), with an ArkForge checkout at the pin that has run `cargo fetch`:

```sh
ARKDECK_CLI_PROVISIONING_PROFILE=/abs/cli.provisionprofile \
ARKDECK_DAEMON_PROVISIONING_PROFILE=/abs/daemon.provisionprofile \
ARKDECK_NOTARY_KEYCHAIN_PROFILE=<profile> \
python3 scripts/release/build_macos_release.py release \
  --output /abs/arkdeck-rc-<version>-<build> --arkforge-checkout /abs/ArkForge
```

## Local targeted checks

Branch `agent/xpa-017-release-dmg-20260928` on `origin/main` `f968192e6` (#2301).

| Command | Exit | Log / result |
|---|---|---|
| `python3 scripts/release/test_build_macos_release.py` | 0 | 18 tests OK in ~31 s (real `hdiutil` case included) |
| `python3 scripts/release/release_version.py check` | 0 | `release version 0.1.0 (1) in lockstep` |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter LaunchAgentServiceContractTests` | 0 | 26 tests, 0 failures; `/private/tmp/arkdeck-lane3-work/logs/swift-launchagent.log` |
| `python3 Packages/ArkDeckKit/Distribution/macOS/test-local-rust-helpers.py` | 0 | OK |
| `python3 scripts/ci/test_plan.py` | 0 | 40 tests OK |
| `python3 scripts/test_agent_pr_workflow.py` | 0 | 15 tests OK |
| `plutil -lint scripts/release/ExportOptions.plist`; `bash -n build-helpers.sh` | 0 | OK |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings; `/private/tmp/arkdeck-lane3-work/logs/check-sdd.log` |

No Rust crate changed, so no cargo checks; no contract input changed.

## CI

Recorded by a later slice or a docs-only follow-up (the PR number and run ids are not known when this
record is committed).
