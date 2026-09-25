# TASK-XPA-017 — The Rust helper pair's release packaging, default unchanged (G5 slice 20a)

Base: protected main `3315a9cba` (#2217); developed on `c3c120513` (#2216) and rebased
before the push. #2217 touches only `rust/**` and its own run record, so the Swift,
workflow and planner tests below stand; every packaging run was repeated on the rebased
tree. G5 queue slice 20a (M5 packaging): the
macOS helper release can now be built with the Rust CLI and daemon as the two
bundles' main programs, behind an explicit switch; the default still builds the
Swift pair byte for byte as before, and the cutover window (20c, with the
maintainer present) is where the default changes. No signing identity was
used, nothing was sent to Apple (no `notarytool`, `stapler` or `spctl` ran
against a real service), no keychain was touched, no real `launchctl`, installed
service, device or `~/Library/Application Support/ArkDeck` was used, and no
Catalog operation, contract input, schema, App runtime logic or completion
status changes. Host evidence only; the Golden Journey count is unchanged.

## 1. The release chain today, and who checks each product

| Step (`Packages/ArkDeckKit/Distribution/macOS/build-helpers.sh`) | Product | Checked by |
| --- | --- | --- |
| Inputs: `ARKDECK_CLI_PROVISIONING_PROFILE`, `ARKDECK_DAEMON_PROVISIONING_PROFILE`, `ARKDECK_NOTARY_KEYCHAIN_PROFILE`, `ARKDECK_CODESIGN_IDENTITY` (default `Developer ID Application: Hanfeng Fu (8AQTYW5FKR)`), `ARKDECK_HELPER_OUTPUT` | — | the script: all three required (64), profiles regular files (66), output absent (73) |
| `validate_profile` (`security cms -D`) | decoded profile plists | team `8AQTYW5FKR`; application identifier exactly `8AQTYW5FKR.com.arkdeck.cli` / `.agentd`; `keychain-access-groups` holds `8AQTYW5FKR.com.arkdeck.shared` or the team wildcard (78) |
| `swift build --arch arm64 -c release` of `arkdeck`, `arkdeck-agentd` | two Mach-Os and two SwiftPM resource bundles: `ArkDeckKit_ArkDeckWorkflows.bundle` (its only resource is `OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable`) and `ArkDeckKit_ArkDeckLaunchAgent.bundle` (the `com.arkdeck.agentd.plist` template) | the script: both bundles present (66) |
| Layout | `ArkDeckCLI.app` (`Info.plist` = `ArkDeckCLI-Info.plist`, CLI profile as `embedded.provisionprofile`, `MacOS/arkdeck`, both resource bundles) with `Contents/Helpers/ArkDeckAgent.app` (`ArkDeckAgent-Info.plist`, daemon profile, `MacOS/arkdeck-agentd`, the Workflows bundle) | — |
| `rust/scripts/package-macos-facade.sh release` | a same-release standalone Swift daemon bundle copied to `rollback/ArkDeckAgent.app` and signed; then the Rust `arkdeck-agentd` added as `Contents/MacOS/arkdeck-facade`, signed `--identifier com.arkdeck.agentd.facade` | the Rust CLI's `transport_executable` (`validate_facade_signature`) |
| Signing | daemon bundle, then CLI bundle: Developer ID, `--options runtime`, `--timestamp`, `ArkDeckAgent.entitlements` / `ArkDeckCLI.entitlements` | `codesign --verify --strict --deep` |
| Notarization | `ditto` zip → `xcrun notarytool submit --wait` → `xcrun stapler staple` → `spctl --assess --type execute`, for the CLI bundle and for the rollback bundle | Apple's notary service, Gatekeeper |
| Output | `<output>/ArkDeckCLI.app`, `<output>/rollback/ArkDeckAgent.app` | — |

`build-local-helpers.sh` is the same pair for this Mac only (debug, `--timestamp=none`,
no notarization, `LOCAL-DEVELOPMENT-BUILD.txt`). The Swift contract test
`LaunchAgentServiceContractTests.testDistributionHelpersShareOnlyTheProvisionedKeychainGroup`
pins the plists' identities, the entitlements files, and the release and local scripts'
required steps; `Packages/ArkDeckKit/LaunchAgents/README.md` states that releases come
only from `build-helpers.sh`, whose notarization has no local bypass.

Consumers of the helper pair:

- **The App embeds no helper.** `ArkDeck.xcodeproj`'s only copy phase is `Embed Trace
  Streamer Helper` (`trace_streamer`); nothing copies `ArkDeckCLI.app` or
  `ArkDeckAgent.app`. The sandboxed App reaches the installed daemon through the
  launchd Mach service `com.arkdeck.agentd` (the `mach-lookup` exception in
  `ArkDeckApp/ArkDeckApp.entitlements`) and holds the peer to
  `ArkDeckAgentXPC.serverCodeRequirement` (`ArkDeckCore/AgentXPCContract.swift:238-252`):
  `anchor apple generic and certificate leaf[subject.OU] = "8AQTYW5FKR" and (identifier
  "com.arkdeck.agentd" or identifier "com.arkdeck.agentd.facade") and
  info[CFBundleShortVersionString] = "<App's>" and info[CFBundleVersion] = "<App's>"` —
  the App's own `MARKETING_VERSION 0.1.0` and `CURRENT_PROJECT_VERSION 1`
  (`project.pbxproj:744,754,780,792`). The daemon holds the App to `anchor apple generic
  and certificate leaf[subject.OU] = "8AQTYW5FKR" and identifier "com.arkdeck.desktop"`
  (`rust/crates/arkdeck-agentd/src/app_ingress.rs:27`).
- **The Rust CLI's `runtime service update|install`** (`rust/crates/arkdeck-cli/src/
  runtime_service_install.rs`): `arkdeck_platform::validate_production_daemon_bundle`
  (`host_bundle_signature.rs:336`) requires a bounded absolute `.app`, `Info.plist`
  `CFBundleIdentifier com.arkdeck.agentd` and `CFBundleExecutable arkdeck-agentd`, an
  executable `Contents/MacOS/arkdeck-agentd`, strict static validity for every
  architecture against `anchor apple generic and certificate leaf[subject.OU] =
  "8AQTYW5FKR" and identifier "com.arkdeck.agentd"`, team `8AQTYW5FKR`, the
  entitlements `com.apple.application-identifier = 8AQTYW5FKR.com.arkdeck.agentd` and
  `keychain-access-groups ∋ 8AQTYW5FKR.com.arkdeck.shared`, the hardened runtime, and
  `Contents/embedded.provisionprofile`. A Rust daemon bundle with a facade is refused
  (`:357`). The new helper's daemon is asked `--cutover-preflight` (`probe`, `:577`:
  Swift's answers `unknown argument` exit 64, Rust's an `arkdeck.cutover-preflight/1`
  document over this home's state directory) and, when Rust, `--analyze-crash-ledger`
  on the probe listing through the Runtime's runner, no environment and the `/.vol`
  alias, byte-equal to Swift's recorded answer (`:660`). An update without `--daemon`
  installs `<CLI app>/Contents/Helpers/ArkDeckAgent.app` (`runtime_service.rs:1637`),
  and the helper it replaces is kept one generation at
  `Helpers/.rollback/ArkDeckAgent.app` (`replace_bundle`, `:863`).
- **The signing owner**: an OpenHarmony signing receipt is bound to the installed
  daemon's code identity (`trusted_daemon_fingerprint`, `keychain.rs:634`), so `update`
  refuses while a preset is installed (the coordinator's ruling 3 of 2026-09-24, Q8).

What the Rust programs read at run time:

- The Catalog is compiled in (`arkdeck-contract/src/catalog_generated.rs`), as are the
  control schemas; the Rust CLI renders the LaunchAgent plist in code (`plist_document`,
  `:898`). Neither reads `ArkDeckKit_ArkDeckLaunchAgent.bundle`.
- The Rust daemon's one bundle resource is the OpenHarmony code-sign helper, looked
  for first at `<MacOS>/../Resources/ArkDeckKit_ArkDeckWorkflows.bundle/
  OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable` — SwiftPM's flat resource-bundle
  layout (`rust/crates/arkdeck-agentd/src/code_sign_helper.rs:28-52`). Without it
  `deploy.native-library.app-owned@1` is unavailable.
- Everything else is named by the plist at install time: HDC, the analyzer (the daemon
  itself), the ArkTrace descriptor, the ArkForge bundle, the workspace pair.
- Both binaries link only system libraries (`otool -L`: CoreFoundation, Security,
  libobjc, LocalAuthentication, libsqlite3, libcompression, IOKit, libiconv,
  libSystem), so library validation under the hardened runtime needs no exception.
- `arkdeck-agentd/build.rs` embeds a `__TEXT,__info_plist` section naming
  `com.arkdeck.agentd.facade` (for the bare facade). Measured: when the binary is a
  bundle's main executable, codesign binds the bundle's own `Info.plist` instead —
  `Identifier=com.arkdeck.agentd`, `Info.plist entries=10`, and
  `info[CFBundleIdentifier] = "com.arkdeck.agentd"` is satisfied.

## 2. What this slice adds

- **`build-helpers.sh`, insertion only (+54, −0; `git diff -U0` has no removed line).**
  `ARKDECK_HELPER_RUNTIME` is `swift` by default, `rust` on request, anything else 64;
  `rust` requires `ARKDECK_ROLLBACK_HELPER` (64). After the shared input checks and
  `validate_profile`, the Rust branch builds `cargo build --locked --release --target
  aarch64-apple-darwin -p arkdeck-cli -p arkdeck-agentd --bins`, finds the target
  directory with `cargo metadata` (so `CARGO_TARGET_DIR` and cargo configuration are
  honored; `package-macos-facade.sh` assumes `rust/target`), lays out and signs through
  `package-rust-helpers.sh` with the Developer ID identity and `--timestamp`, then runs
  the Swift path's own notarize, staple and assess lines for the pair and for the
  retained Swift helper, and moves the staging root to the output. Everything after that
  block is the Swift release, unchanged. The switch lives in the one release script so
  the Rust release reuses its input checks, profile validation and cleanup verbatim,
  and the README's rule — releases only from `build-helpers.sh`, no notarization bypass —
  stays true.
- **`package-rust-helpers.sh`** (new, shared): checks the binaries (executable regular
  files, `lipo -archs` exactly `arm64`), the profiles and the code-sign helper; lays out
  `ArkDeckCLI.app` (`Info.plist`, CLI profile, `MacOS/arkdeck`) and
  `Contents/Helpers/ArkDeckAgent.app` (`Info.plist`, daemon profile,
  `MacOS/arkdeck-agentd`, the code-sign helper where the daemon looks for it), both
  executables 0700; signs the daemon bundle, then the CLI bundle, with the same
  entitlements files and `--options runtime`; verifies strictly and deeply and against
  each identifier (with the Developer ID anchor whenever an identity is named). It
  builds, validates and notarizes nothing.
- **`build-unsigned-rust-helpers.sh`** (new): the structure-only entry. The same layout
  step, signed ad hoc (`-`, `--timestamp=none`) with placeholder profiles that
  authorize nothing, the output root marked `UNSIGNED-STRUCTURE-CHECK-ONLY.txt`, and a
  stderr line saying it is not for distribution. `ARKDECK_RUST_HELPER_BINARIES` takes
  already built binaries (CI); otherwise it builds the release profile as the release
  does. It is a separate script so that no release script carries a bypass. The
  production validator refuses its output for lack of the Developer ID anchor, so it
  cannot be installed (checked, below).
- **`check-rust-helpers.py`** (new): the repeatable assertions over that output — the
  exact file tree (no facade, no link), the marker, both `Info.plist`s byte-equal to
  `Distribution/macOS` and with versions equal to the App's, the placeholder profile in
  each bundle, the code-sign helper byte-equal to the tracked resource, arm64 thin and
  0700 executables, strict deep verification, each signature's identifier, format,
  hardened runtime, bound `Info.plist` and sealed resources, `codesign -R` over the
  identifier and the App-pinned versions, the Developer ID requirement failing (exit
  3), the signed entitlements equal to the Distribution files; then, on copies re-signed
  ad hoc without entitlements (shown to be the packaged bytes once both signatures are
  removed), the daemon's `--cutover-preflight` in an empty relocated home (clear, over
  that home's state directory, nothing written) and `--analyze-crash-ledger` on the
  oracle's `runtime-service-probe` listing through its `/.vol` alias (Swift's answer
  byte for byte), and the packaged Rust CLI's `runtime service update --daemon <the
  packaged daemon bundle>` in an empty relocated home with a recording launchctl:
  exit 1 with `arkdeck-agentd helper signature does not match ArkDeck (status -67050)`
  — the path, `Info.plist` identity and executable checks passed and the only refusal is
  the anchor a real signature supplies — launchd asked nothing, nothing written.
  `--expect-rollback` also requires the retained Swift helper.
- **CI**: one step in `rust-ci.yml`'s `workspace` job, macOS only, after the workspace
  tests: the unsigned build from the `rust/target/debug` binaries those tests just built,
  then the checker. It compiles nothing; locally it took about 1.9 s (layout and ad hoc
  signing 0.35 s, checks 1.5 s), so it adds seconds to the macOS job.
  `scripts/test_agent_pr_workflow.py` (13 tests) and `scripts/ci/test_plan.py` (38) pass
  unchanged.
- **Swift contract test**: the same test now also requires `xcrun notarytool submit`,
  `xcrun stapler staple` and `spctl --assess --type execute` four times in
  `build-helpers.sh` (the pair and its rollback, in each release), the shared layout
  step in both callers, and neither the unsigned script nor the layout step to name
  `ARKDECK_NOTARY_KEYCHAIN_PROFILE`, `ARKDECK_CODESIGN_IDENTITY`, `notarytool`,
  `stapler` or `spctl`.
- **README** (`LaunchAgents/README.md`): one paragraph on the Rust release switch, the
  retained Swift helper and the unsigned structure check.

## 3. Decisions and their grounds

1. **Entitlements: the Swift helpers' three, not empty.** The Rust production
   composition composes signing over `KeychainSigningSecrets::installed`
   (`arkdeck-agentd/src/production.rs:531-552`), which reads the preset's envelope from
   the Data Protection Keychain under `8AQTYW5FKR.com.arkdeck.shared`
   (`arkdeck-provider-workspace/src/keychain_secrets.rs:20-26`); SPK-10 measured that a
   process without that group gets `-34018` (`errSecMissingEntitlement`;
   `runs/TASK-XPA-015/spk-10-run.md`), which the owner
   reports as unreadable, failing signing closed. `keychain-access-groups` is a
   restricted entitlement that needs `com.apple.application-identifier` and the team
   identifier authorized by the embedded profile. And both helper validators refuse a
   daemon bundle without the application identifier and group entitlements. So the
   Rust daemon is signed with `ArkDeckAgent.entitlements` unchanged, and no
   hardened-runtime exception. The Rust CLI keeps `ArkDeckCLI.entitlements`: it reads no
   Keychain item today, but Q8's port of `runtime signing install|migrate-deveco|remove`
   writes and removes that envelope, and the pair shares exactly one access group, which
   the Swift test pins. **This contradicts the design's "nested code with empty
   entitlements"** (tasks.md TASK-XPA-017 deliverables; `rust-core-cross-platform-
   architecture.md` lines 121 and 1022; G5 queue 20a and G5 check 6), written before the
   signing owner moved into the Rust daemon — maintainer ruling below.
2. **No facade.** The Rust daemon is the bundle's main program; the Rust CLI refuses a
   Rust daemon bundle that carries one.
3. **Rollback.** The release requires `ARKDECK_ROLLBACK_HELPER`: the current Swift
   helper, in the form the current release installs (the Swift daemon behind its Rust
   facade), checked — identity in `Info.plist`, both executables, strict deep validity
   against `…identifier "com.arkdeck.agentd"` and the facade against `…identifier
   "com.arkdeck.agentd.facade"`, with the Developer ID anchor in the release — then copied
   with `ditto` unchanged to `rollback/ArkDeckAgent.app`, re-verified, and notarized,
   stapled and assessed as its own archive, as the Swift release does its rollback. It is
   an input rather than a rebuild: the Rust release needs no SwiftPM build, and the
   rollback is the helper that was shipped. The output path is the release's existing
   `rollback/ArkDeckAgent.app`, the bundle name `runtime service update` installs and
   keeps: on a host that ran the Swift helper, `update` to the Rust one keeps the
   replaced helper at `Helpers/.rollback/ArkDeckAgent.app` (one generation, so the
   façade lasts exactly one cycle there too); the release's copy is for a host without
   one. Either rolls back with `arkdeck runtime service update --daemon <bundle>` — the
   Rust CLI recognizes a Swift daemon by its `unknown argument` answer and installs it
   through the Swift path. A rollback helper must still satisfy the App's version pin:
   an App whose `MARKETING_VERSION` moved on refuses an older daemon.
4. **arm64 only**, as the Swift release: `--target aarch64-apple-darwin` and a
   `lipo -archs` check before anything is laid out.
5. **Measured while building it**: a Mach-O signed ad hoc with these restricted
   entitlements is killed at launch (exit 137), so the unsigned output's executables are
   run from entitlement-free copies; `codesign --verify -R` needs the requirement as its
   own argument (`-R "=…"`), since `-R="=…"` hands it a leading `=`; removing the signature
   from a linker-signed and a codesign-signed copy of the same binary gives different
   bytes (the `__LINKEDIT` allocation), so the copy is compared with the packaged file,
   both codesign-signed.

## 4. Verification

### Unsigned structure runs (release profile, this commit)

- `build-unsigned-rust-helpers.sh` built `cargo build --locked --release --target
  aarch64-apple-darwin` (43 crates, 1 min 20 s cold; `arkdeck` 4.9 MB, `arkdeck-agentd`
  12 MB) and laid out the pair; `check-rust-helpers.py`: **67 checks passed, 0 failed**.
- With `ARKDECK_ROLLBACK_HELPER` naming a stand-in façade-form helper (ad hoc, a small
  arm64 program as daemon and as facade): `--expect-rollback` **72 passed, 0 failed**;
  the same flag over the first output fails with "no rollback helper was retained".
- Refusals, each exit before anything is written and with the temporary root removed:
  the Rust daemon bundle as rollback (65, no facade), a relative path (66), the CLI app
  (65, not a daemon bundle).
- `build-helpers.sh` without a signing identity: `ARKDECK_HELPER_RUNTIME=bogus` 64;
  `rust` without or with a relative `ARKDECK_ROLLBACK_HELPER` 64; default, `swift` and
  `rust`+rollback without profiles 64 with the unchanged message.

### A stubbed dry run of the release branch (no identity, no Apple service)

`PATH` put stand-ins first for `security` (prints a profile's entitlements), `xcrun`
(records; answers only `notarytool submit` and `stapler staple`), `spctl` (records) and
`codesign` (records the release's arguments, then runs the real codesign with `--sign -`,
`--timestamp=none` and the anchor clause removed, and refuses to pass on anything naming
`Developer ID`, a timestamp or an anchor). `ARKDECK_HELPER_RUNTIME=rust
build-helpers.sh` with placeholder profiles and the stand-in rollback helper exited 0 and
left `ArkDeckCLI.app` and `rollback/ArkDeckAgent.app`, no archive and no temporary
directory. Recorded, in order: both `security cms -D`; the rollback's two requirement
checks with `anchor apple generic and certificate leaf[subject.OU] = "8AQTYW5FKR" and
identifier "com.arkdeck.agentd"` / `"…agentd.facade"`; `codesign --force --sign
'Developer ID Application: Hanfeng Fu (8AQTYW5FKR)' --options runtime --timestamp
--entitlements …/ArkDeckAgent.entitlements …/Helpers/ArkDeckAgent.app`, the same with
`ArkDeckCLI.entitlements` for `ArkDeckCLI.app`; strict deep verification; the anchor
requirement checks of both bundles and the retained copy; `notarytool submit
ArkDeckCLI-notarization.zip --keychain-profile <name> --wait`, `stapler staple`,
`spctl --assess --type execute` for the pair, then the same three for
`ArkDeckAgent-rollback-notarization.zip` and the retained helper. The anchor requirement
texts compile (codesign answers 3, "not satisfied", on the ad hoc pair, and 1 for a typo'd
control); `anchor apple generic` holds for an Apple-signed `/bin/ls`.

### Mutations (a session script, not committed), each restored by checksum

15 of 15 caught. By the checker: the daemon profile not embedded; the daemon signed
with the CLI's entitlements; the daemon without the hardened runtime; the code-sign
helper outside the resource bundle; a facade in the Rust daemon bundle; the helper
version drifting from the App (`0.1.1`); executables 0755; the profiles swapped; a daemon
that answers neither one-shot mode (preflight exit 64, analyzer, and the CLI refusal all
named). Refused by the layout step's own verification before the checker ran, and caught
by the checker once that verification is removed: the daemon given the CLI's
`Info.plist`; the daemon signed as `com.arkdeck.agentd.facade`; the rollback helper not
retained. The Swift test fails when the Rust branch's rollback `stapler staple` line is
removed (count 3, not 4).

## 5. What the maintainer runs in the cutover window (not run here)

Prerequisites: the `Developer ID Application` identity of team `8AQTYW5FKR` in the
login keychain; the two Developer ID provisioning profiles (`$CLI_PROFILE`,
`$DAEMON_PROFILE`); a notarytool keychain profile stored with `xcrun notarytool
store-credentials $NOTARY_PROFILE`; network access for cargo's locked ArkForge fetch
and for notarization; a clean checkout of the commit being released.

```sh
# The current Swift helper, to keep for one cycle (skip if that release's
# output is still at hand):
ARKDECK_CLI_PROVISIONING_PROFILE="$CLI_PROFILE" \
ARKDECK_DAEMON_PROVISIONING_PROFILE="$DAEMON_PROFILE" \
ARKDECK_NOTARY_KEYCHAIN_PROFILE="$NOTARY_PROFILE" \
ARKDECK_HELPER_OUTPUT="$SWIFT_OUT" \
  bash Packages/ArkDeckKit/Distribution/macOS/build-helpers.sh

# The Rust pair:
ARKDECK_HELPER_RUNTIME=rust \
ARKDECK_ROLLBACK_HELPER="$SWIFT_OUT/ArkDeckCLI.app/Contents/Helpers/ArkDeckAgent.app" \
ARKDECK_CLI_PROVISIONING_PROFILE="$CLI_PROFILE" \
ARKDECK_DAEMON_PROVISIONING_PROFILE="$DAEMON_PROFILE" \
ARKDECK_NOTARY_KEYCHAIN_PROFILE="$NOTARY_PROFILE" \
ARKDECK_HELPER_OUTPUT="$RUST_OUT" \
  bash Packages/ArkDeckKit/Distribution/macOS/build-helpers.sh
```

Read-only acceptance of `$RUST_OUT` (`D=$RUST_OUT/ArkDeckCLI.app/Contents/Helpers/ArkDeckAgent.app`):

```sh
codesign --verify --strict --deep --verbose=2 "$RUST_OUT/ArkDeckCLI.app"
codesign -dv --verbose=4 "$D"     # Identifier=com.arkdeck.agentd, TeamIdentifier=8AQTYW5FKR,
                                  # flags …(runtime), a Timestamp, Info.plist entries=10
codesign --verify --strict -R '=anchor apple generic and certificate leaf[subject.OU] = "8AQTYW5FKR" and (identifier "com.arkdeck.agentd" or identifier "com.arkdeck.agentd.facade") and info[CFBundleShortVersionString] = "0.1.0" and info[CFBundleVersion] = "1"' "$D"
codesign -d --entitlements - --xml "$D"   # exactly ArkDeckAgent.entitlements
xcrun stapler validate "$RUST_OUT/ArkDeckCLI.app"
spctl --assess --type execute --verbose=2 "$RUST_OUT/ArkDeckCLI.app" "$RUST_OUT/rollback/ArkDeckAgent.app"
# The Rust CLI's own production acceptance, in a throwaway home whose launchd
# stand-in answers "not loaded" to print and succeeds otherwise, never the
# account's service:
H=$(cd "$(mktemp -d)" && pwd -P)
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s.log"\n[ "$1" = print ] && exit 113\nexit 0\n' \
  "$H.launchctl" > "$H.launchctl"; chmod 700 "$H.launchctl"
env -i HOME="$H" CFFIXED_USER_HOME="$H" ARKDECK_LAUNCHCTL_FOR_RELOCATED_HOME="$H.launchctl" \
  "$RUST_OUT/ArkDeckCLI.app/Contents/MacOS/arkdeck" runtime service update \
  --hdc /usr/bin/true --arktrace-descriptor none --arkforge-bundle none --json
# expected: exit 0 and a receipt with a `cutover` member (the preflight clear over
# the empty home, the analyzer answered), the helper under
# $H/Library/Application Support/ArkDeck/Helpers, and "$H.launchctl.log" holding
# only print and bootstrap; then rm -rf "$H" "$H.launchctl" "$H.launchctl.log"
```

The installed-service switch itself is 20c's, with its preflight, snapshot summary and
rollback drill.

## 6. Open items and rulings needed

1. **Entitlements (ruling).** Record the Rust daemon's minimal set as the three keys of
   `ArkDeckAgent.entitlements` (and the CLI's as `ArkDeckCLI.entitlements`), replacing
   "empty entitlements" in the TASK-XPA-017 deliverables, the architecture document and
   G5 check 6; or keep "empty" and move the signing envelope out of the Data Protection
   Keychain and drop the entitlement checks from both helper validators — a change to the
   signing and helper-trust semantics. Recommendation: the first.
2. **Q11.** This branch notarizes, as the Swift release does. If G5 is to install a
   Developer-ID-signed helper without notarization (Q11's recommendation),
   `build-local-helpers.sh` needs the same switch: its layout through
   `package-rust-helpers.sh` with `--timestamp=none` and no notarization (a small next
   slice).
3. **"Embedded in the App" / "release DMG"** (G5 queue 20a, architecture document): the
   App embeds no helper today; embedding the daemon in the App changes who installs the
   LaunchAgent, a product decision outside 20a.
4. `arkdeck-agentd/build.rs`'s facade `__info_plist` is harmless in the Rust bundle
   (measured) and can go, or name `com.arkdeck.agentd`, when the facade retires (20d).
5. A host with an installed OpenHarmony signing preset cannot take the Rust helper until
   the Rust signing owner re-records the receipt (ruling 3, Q8).

## Local targeted checks

Logs under `/private/tmp/arkdeck-s32-*.log`; target `/private/tmp/arkdeck-1330-rust-target`,
`CARGO_BUILD_JOBS=2`.

| Command | Exit | Log |
| --- | --- | --- |
| `bash -n` on `build-helpers.sh`, `package-rust-helpers.sh`, `build-unsigned-rust-helpers.sh` | 0 | — |
| `pyflakes` and `flake8 --max-line-length 110` on `check-rust-helpers.py` (3.14; also runs on the system 3.9.6) | 0, 0 | — |
| `cargo build --locked --release --target aarch64-apple-darwin -p arkdeck-agentd -p arkdeck-cli --bins` | 0 | `arkdeck-s32-release-build.log` |
| `build-unsigned-rust-helpers.sh` (the release rebuilt on the rebased tree), then `check-rust-helpers.py` | 0; 67 passed | `arkdeck-s32-unsigned-final.log` |
| the same with the stand-in rollback helper and `--expect-rollback`; `--expect-rollback` over the first output | 0, 72 passed; 1, as it must | `arkdeck-s32-unsigned-rollback-final.log` |
| the CI step's commands over debug binaries (`ARKDECK_RUST_HELPER_BINARIES`) | 0; 67 passed, about 1.9 s | `arkdeck-s32-ci-like-final.log` |
| the stubbed dry run of `ARKDECK_HELPER_RUNTIME=rust build-helpers.sh` | 0 | `arkdeck-s32-release-dryrun.log` |
| the mutation script (session scratchpad) | 0; 15/15 caught | `arkdeck-s32-mutants.log` |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter LaunchAgentServiceContractTests/testDistributionHelpersShareOnlyTheProvisionedKeychainGroup` | 0 (and 1 with the staple line removed) | `arkdeck-s32-swift-test.log`, `arkdeck-s32-swift-mutant.log` |
| `python3 scripts/test_agent_pr_workflow.py`; `python3 scripts/ci/test_plan.py` | 0 (13 tests); 0 (38 tests) | `arkdeck-s32-workflow-tests.log`, `arkdeck-s32-plan-tests.log` |
| `sh scripts/check-sdd.sh` | 0 | `arkdeck-s32-sdd.log` |

Not run: `shellcheck` (not installed on this host); `cargo fmt/clippy/test` (no Rust
source changed); `generate-contract.py --check` (no contract input changed); the Swift
default path's release build (a SwiftPM release build and a real identity; its text is
unchanged — the diff only inserts lines); any Developer ID signing, notarization,
stapling or Gatekeeper assessment against Apple; App build-for-testing (no App target
changed).

## CI

Pending; recorded by the next slice.
