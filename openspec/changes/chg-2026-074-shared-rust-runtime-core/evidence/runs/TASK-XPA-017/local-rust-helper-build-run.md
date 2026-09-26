# Local provisioned Rust helper build

TASK-XPA-017, M5 packaging continuation; base `bb3b5531c`, 2026-09-26.

`build-local-helpers.sh` previously always built the Swift CLI/daemon pair.
The release script already offered an explicit Rust mode, but the documented
local, non-notarized path could not prepare that pair for a cutover window.
The local script now accepts the same `ARKDECK_HELPER_RUNTIME=rust` and
`ARKDECK_ROLLBACK_HELPER` inputs. Its default remains Swift.

After the existing Developer ID availability and exact provisioning-profile
checks, Rust mode builds the arm64 debug CLI/daemon with Cargo, finds the
configured target directory through `cargo metadata`, and calls the existing
`package-rust-helpers.sh`. That script verifies the existing signed Swift
daemon/facade rollback pair, lays out the new Rust pair, signs the nested
daemon and CLI with their existing entitlements and hardened runtime, strictly
verifies them, and retains the rollback helper unchanged. The local build
passes `--timestamp=none` and publishes `LOCAL-DEVELOPMENT-BUILD.txt` alongside
the pair. Failed build, architecture, rollback or signature checks leave no
published output and clean the temporary profile/staging directories.

This does not change the release script, its mandatory notarization, any
entitlement, installed LaunchAgent, production validation or cutover decision.
Whether a local build is suitable for the acceptance window remains a
maintainer decision; it is not a distributable release.

## Verification scope

`test-local-rust-helpers.py` runs the actual local entry and shared layout
scripts with recording `cargo`, `security`, `codesign`, `lipo` and `ditto`
fixtures. It checks the successful layout, bytes and rollback; paths with
spaces and a configured Cargo target root; default Swift selection; invalid
mode, absent or symlinked rollback, wrong profile identity, unavailable
signing identity, and build/signature/architecture failures. It is invoked by
`LaunchAgentServiceContractTests` so the normal Swift lane runs it.

These are host fixture results only. No real signing identity, Keychain,
notary service, launchd or device was used. No signed acceptance artifact was
produced; no `REAL_DEVICE_PASS` or task-completion status changes.

## Local targeted checks

- `python3 Packages/ArkDeckKit/Distribution/macOS/test-local-rust-helpers.py`:
  exit 0, 11 cases; `/private/tmp/arkdeck-local-rust-helpers-test.log`.
- `bash -n Packages/ArkDeckKit/Distribution/macOS/build-local-helpers.sh`:
  exit 0.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter LaunchAgentServiceContractTests`:
  exit 0, 26 tests including the 11-case script driver;
  `/private/tmp/arkdeck-local-rust-helpers-swift.log`.
- `sh scripts/check-sdd.sh`: exit 0, 121 acceptance IDs;
  `/private/tmp/arkdeck-local-rust-helpers-sdd.log`.
- `git diff --check`: exit 0.
- Rust source and contract inputs were not changed; no Cargo crate tests or
  contract generation were needed for this slice. The existing Rust helper
  structure check remains in the selected PR lane.

## CI

Not submitted: remote push authorization is pending. Local progress continues.
