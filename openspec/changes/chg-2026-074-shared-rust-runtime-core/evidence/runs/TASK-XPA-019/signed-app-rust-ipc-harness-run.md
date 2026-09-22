# Real App / ClientKit / standalone Rust Mach harness

Base: protected main `73eeacc99`. This prepares the actual signed host loop;
TASK-XPA-019 and G5 are not complete.

## Path under test

`ArkDeck.app --runtime-readonly-smoke` uses the existing production ClientKit
History and HistoryFilter providers, including signature-pinned long-lived XPC,
health/contract verification, bounded requests and no replay. Factories receive
no fixture arguments. The ordinary shell/startup device refresh is not run in
this explicitly selected mode. Each stdin `refresh` emits one bounded summary
(no Job IDs, artifact bytes or device identity); no arbitrary method or transport
can be supplied. Normal App launch is unchanged.

`rust/scripts/macos-app-rust-smoke.py` defaults to read-only preflight. Execution
requires an independent logged-in macOS account/VM with no installed LaunchAgent,
no fixed Mach registration in either GUI/user domain, no launchd Runtime
environment override, a correctly signed production-sandbox App and a standalone
Rust daemon binary. It retains `com.arkdeck.agentd`, the exact App identity/team,
production Mach exception, and version/build-bound daemon signature.

On explicit `--execute`, the script packages/signs only its own copied Rust
binary in a new private output directory and registers a unique temporary
LaunchAgent label vending the unchanged fixed Mach name. The isolated Runtime
state has no configured HDC or Swift sibling. It does not install or switch an
existing Runtime. It runs the same App process through absent / connected /
disconnected / reconnected / disconnected reads, and removes only the unique
plist after this invocation's successful bootstrap. Failed bootstrap never
permits bootout. Output includes binary hashes, process records and partial
reports even if an App read fails. This is host IPC, not device acceptance.

## Run in the independent environment

Build the App using the repository's signed Release configuration and the
standalone `arkdeck-agentd` from the same commit in independent build directories.
Do not use the paired `arkdeck-facade` package or an older App without the smoke
entry point. With their absolute paths:

```sh
python3 rust/scripts/macos-app-rust-smoke.py \
  --app /absolute/path/ArkDeck.app \
  --daemon /absolute/path/arkdeck-agentd \
  --output /absolute/path/new-private-ipc-run
```

Only after preflight succeeds, run the same command with `--execute`. The output
path must not exist and cannot be in installed Runtime state. The default signing
identity is Developer ID Application: Hanfeng Fu (8AQTYW5FKR); `--sign-identity`
may select an installed identity but code verification still requires that team.
The script neither creates a VM/account nor changes global launchd settings.

## Local targeted checks

- `ARKDECK_XCODE_CACHE_ROOT=/private/tmp/arkdeck-e190-xcode ARKDECK_XCODE_JOBS=2
  sh scripts/ci/run-xcodebuild.sh`: exit 0, TEST BUILD SUCCEEDED;
  `/private/tmp/arkdeck-e190-ipc-app-build.log`.
- `PYTHONDONTWRITEBYTECODE=1 python3 rust/scripts/test-macos-app-rust-smoke.py`:
  exit 0, 4 orchestration safety tests;
  `/private/tmp/arkdeck-e190-ipc-harness-tests.log`. These mocks are not IPC evidence.
- Real built App copied under `/private/tmp/arkdeck-e190-ipc-entry-test`, signed
  ad hoc with production entitlements, launched in smoke mode: exit 0; actual
  ClientKit read reports connected/history/filter false and Job count zero;
  `/private/tmp/arkdeck-e190-ipc-entry-test.log`. This validates entry/negative
  presentation only, not positive signed Rust identity or real hardware.
- Actual read-only preflight: exit 1, `installed LaunchAgent exists; use an
  independent login/VM`; `/private/tmp/arkdeck-e190-ipc-preflight.log`. No service
  registration, bootout or installed Runtime change was attempted.

Developer ID signing identity is available on the current host. The outstanding
condition is an independent GUI login domain with the production Mach name free,
not a missing certificate. The user has been asked once for an existing
environment. Positive connection/reconnect evidence is explicitly outstanding.
No performance, device, UI presentation or REAL_DEVICE_PASS claim is made here.

## Production signed App preparation

Release build from #2115 head `fc0605ca` (subsequently merged):
`ARKDECK_XCODE_CACHE_ROOT=/private/tmp/arkdeck-e190-xcode ARKDECK_XCODE_JOBS=2 sh
scripts/ci/run-xcodebuild.sh --release`, exit 0, BUILD SUCCEEDED;
`/private/tmp/arkdeck-e190-signed-app-build.log`.

Actual `inspect_app` verification found a harness invocation defect:
`codesign -R` treats text without an `=` prefix as a filename. Both App and
isolated-daemon verification now pass the same requirement with the required
inline prefix. No identity predicate, signature or sandbox check is weakened.

Rechecking the actual signed Release App passes deep/strict signature,
team/identifier, production sandbox and exact Mach-exception validation:
`/private/tmp/arkdeck-e190-signed-app-inspection.log`, exit 0. The signer is
Developer ID Application: Hanfeng Fu (8AQTYW5FKR), version 0.1.0 build 1.
App binary SHA-256:
`522faf58e6ccadae95f6d424d882eb83c91704b5fbb66018d4dbb5b37f01e27c`.
Artifact: `/private/tmp/arkdeck-e190-xcode/DerivedData/Build/Products/Release/ArkDeck.app`.
This preparation starts no Runtime and is not positive Rust Mach acceptance.
The four harness safety tests still pass; no App rebuild was needed for this
Python argument fix. The independent login/VM condition remains outstanding.

## CI

Pending this independent PR. Required guard/swift checks and maintainer review
remain necessary. `sh scripts/check-sdd.sh` and `git diff --check` passed
(exit 0); SDD log `/private/tmp/arkdeck-e190-ipc-sdd.log`.
