# Shared native code-sign resource

Base: protected main `82f0971ce5f122bde47d9cd850f6df4e0b277da1`.

The Rust helper packager no longer reads a resource below the Swift Workflows
source directory. The single checked-in ELF moves to
`Packages/ArkDeckKit/Resources/OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable`.
Workflows explicitly copies that package-level directory, and its development
fallback and the Rust checkout tests read the same file. The target, its
dependencies, the C source and the installed
`ArkDeckKit_ArkDeckWorkflows.bundle/OpenHarmonyNativeCodeSign` layout stay unchanged.
The new resource path selects the Rust packaging CI lane as well as Swift.

This is a byte-for-byte move, not a rebuild: 214,016 bytes, mode `0644`, SHA-256
`86497e1a8f9b586169218df912895785c1c0f2d8bb3f87b2b700f6f86264f5c1`.
No resource symlink, second authoritative copy or additional target is introduced.
No signing, Provider, admission or device behavior changes. Installed helpers,
receipts and rollback artifacts were not accessed for modification.

## SwiftPM compatibility

The manifest declares tools version 6.3. SwiftPM's
[6.3 resource builder](https://github.com/swiftlang/swift-package-manager/blob/swift-6.3-RELEASE/Sources/PackageLoading/TargetSourcesBuilder.swift)
resolves declarations relative to the target, requires them to remain inside
the package, and includes explicitly declared resources outside its target
directory scan for tools version 6.0 or later. Keeping the Workflows target
and copied directory names retains its resource bundle and internal layout.

The local compiler reports Swift 6.4. The Swift/App CI jobs select macOS 26 and
Xcode 26.6; successful Swift CI run `36286210530`, job `108527387918`, reports
Xcode 26.6 (`17F113`) and Swift 6.3.3 (`swiftlang-6.3.3.1.3`). Thus the relevant
resource behavior is present at the declared minimum, not just the local compiler.

## Local targeted checks

Validation ran serially after the coordinating task handed over the local window.
Rust commands ran from `rust/` with
`CARGO_TARGET_DIR=/private/tmp/arkdeck-native-resource-target` and
`CARGO_BUILD_JOBS=2`; no other worktree's target was used.

- `swift run --package-path /private/tmp/arkdeck-native-code-sign-probe
  --scratch-path /private/tmp/arkdeck-native-code-sign-probe-build ResourceProbe`:
  exit 0. The dependency-free probe declares tools 6.3 and the real package,
  target and resource names. It verified the generated resource bundle,
  regular-file type, all 214,016 bytes by SHA-256 and exact `0644` mode.
  Log: `/private/tmp/arkdeck-native-resource-swift-probe.log`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter
  'NativeLibraryDeploymentContractTests/testBundledCodeSignHelperIsAValidatedStaticArm64Executable|ArchitectureBoundaryContractTests'`:
  exit 0, 18 passed. Log: `/private/tmp/arkdeck-native-resource-swift-tests.log`.
- `cargo fmt --all --check --manifest-path Cargo.toml`: exit 0.
  Log: `/private/tmp/arkdeck-native-resource-fmt.log`.
- `cargo clippy --locked --manifest-path Cargo.toml -p arkdeck-provider-hdc
  -p arkdeck-agentd -p arkdeck-hoststore -p arkdeck-soak --all-targets -- -D warnings`:
  exit 0. Log: `/private/tmp/arkdeck-native-resource-clippy.log`.
- `cargo build --locked --manifest-path Cargo.toml -p arkdeck-cli`: exit 0;
  supplies the CLI used by the process tests.
  Log: `/private/tmp/arkdeck-native-resource-cli-build.log`.
- `cargo test --locked --manifest-path Cargo.toml -p arkdeck-provider-hdc
  -p arkdeck-agentd -p arkdeck-hoststore -p arkdeck-soak --no-fail-fast`:
  exit 0, 1,097 passed, 18 existing ignored cases. Both moved-resource tests
  ran and passed. Log: `/private/tmp/arkdeck-native-resource-rust-tests.log`.
- `bash Packages/ArkDeckKit/Distribution/macOS/build-unsigned-rust-helpers.sh`
  with `ARKDECK_RUST_HELPER_BINARIES=/private/tmp/arkdeck-native-resource-target/debug`,
  `ARKDECK_UNSIGNED_HELPER_OUTPUT=/private/tmp/arkdeck-native-resource-packaged`
  and `ARKDECK_ROLLBACK_HELPER=none`: exit 0.
  Log: `/private/tmp/arkdeck-native-resource-packaging.log`.
- `python3 Packages/ArkDeckKit/Distribution/macOS/check-rust-helpers.py
  /private/tmp/arkdeck-native-resource-packaged`: exit 0, 67 checks passed.
  This verifies the resource bytes in the unchanged installed Rust layout,
  temporary bundle signatures and isolated refusal paths.
  Log: `/private/tmp/arkdeck-native-resource-package-check.log`.

- `python3 -m unittest discover -s scripts/ci -p test_plan.py`: exit 0,
  39 passed. Log: `/private/tmp/arkdeck-native-resource-planner-tests.log`.
- `bash -n Packages/ArkDeckKit/Distribution/macOS/package-rust-helpers.sh`:
  exit 0. Log: `/private/tmp/arkdeck-native-resource-shell-syntax.log`.
- `sh scripts/check-sdd.sh`: exit 0, 121 acceptance IDs, no warnings.
  Log: `/private/tmp/arkdeck-native-resource-sdd.log`.
- `git diff --check`: exit 0.

No device operation or full local unified gate ran. The packaged helpers are
ad hoc structure fixtures, not installed or distributed product artifacts.

## CI

Pending at this implementation commit; the PR and final CI results are reported
to the coordinating task. The actual Swift/App and Rust packaging jobs must
validate this change before maintainer review and merge. This does not complete
the cutover, retire a Swift target or claim hardware acceptance.
