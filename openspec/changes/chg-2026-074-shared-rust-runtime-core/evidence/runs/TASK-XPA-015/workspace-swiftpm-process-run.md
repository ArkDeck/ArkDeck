# SwiftPM workspace test execution on macOS

Base: `bb3b5531c` (2026-09-26). TASK-XPA-015, M3. Host development
evidence only; no installed Runtime, device or `REAL_DEVICE_PASS`.

## Result

The production Rust daemon now runs the built-in `arkdeck-tests` preset
through its control socket against a minimal real SwiftPM package in a
Runtime-created isolated copy. A passing XCTest succeeds; a failing XCTest
fails with `workspace.testsFailed`, keeps `test-output.log`, and is not an
unknown outcome. Both Job results and their Artifact bytes survive daemon
restart. A primary project is refused before dispatch and acquires no
`.build` directory. The test uses a private temporary account home and asks
the Runtime to create its own authority; it writes no capability records.

Before the fix, the same test reached `intent run-tests`, then SwiftPM died
on signal 11. The Job correctly remained `waitingForRecovery`, with its
intent outstanding. The local crash report's faulting stack began with
`__CFCheckCFInfoPACSignature`, `CFBundleGetInfoDictionary`,
`CFBundleGetIdentifier`, and `NSUserDefaults` initialization. SwiftPM was
launched through its retained inode alias, which loses its toolchain bundle
path. The existing Swift dispatcher used the same mode.

Both dispatchers now select the existing verified canonical-path mode for
the provider-owned `swift-package` executable acting as `swift-test`.
The process starts suspended; the executable is revalidated and its first
mapping must match the retained inode before it is resumed. Resources are
checked before and after spawning. Other workspace tools keep the inode
launch path. No operation, authorization policy, capability scope or
unknown-outcome classification changes.

The Rust process regression executes both XCTest outcomes, the primary
project refusal, output retention, and restart readback. The Swift regression
starts the real SwiftPM test role through `DescriptorBoundProcessDispatcher`
and checks its help output, exercising Foundation initialization.

## Remaining boundary

These are Job and Artifact successes, not successful Session publication.
The existing Swift/Rust Session writer treats a `deviceMutation` intent as
requiring device facts. This host Job has none, so publication reports
`failed/sourceIntegrityFailed`, exactly as the existing workspace patch
process regression documents. The new test asserts that refusal explicitly.
Resolving that Session classification remains separate work; no device facts
are invented and no validation is relaxed here.

This closes the daemon execution gap for `workspace.run-tests` using the
built-in SwiftPM preset. It does not validate a DevEco/Hvigor test preset or
the full GJ-5 build, sign and device loop, and does not change the pinned
dashboard's operation counts.

## Local targeted checks

All Rust commands use `CARGO_BUILD_JOBS=2` and the worktree-specific
`CARGO_TARGET_DIR=/private/tmp/arkdeck-takeover-d79c-target`.

- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --test workspace_tests_process`:
  exit 0, one process regression covering both outcomes; log
  `/private/tmp/arkdeck-takeover-workspace-tests.log`.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings`:
  exit 0; log `/private/tmp/arkdeck-takeover-clippy.log`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter WorkspaceSwiftPMDispatchContractTests`:
  exit 0, one test; log `/private/tmp/arkdeck-takeover-swiftpm-dispatch.log`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'ProcessExecutorContractTests/testVerifiedCanonical'`:
  exit 0, five identity/mapping/resource replacement tests; log
  `/private/tmp/arkdeck-takeover-canonical-safety.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0.
- `sh scripts/check-sdd.sh`: exit 0, 121 acceptance IDs; log
  `/private/tmp/arkdeck-takeover-sdd.log`.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --no-fail-fast`:
  exit 0, 913 passed and 18 ignored by the existing suite defaults; log
  `/private/tmp/arkdeck-takeover-rust-tests.log`.
  The first crate-only run stopped because the existing CLI process test
  requires the CLI beside the daemon. `cargo build --manifest-path rust/Cargo.toml -p arkdeck-cli`
  supplied that prerequisite (exit 0; `/private/tmp/arkdeck-takeover-cli-build.log`),
  then the affected suite was rerun successfully.

The initial sandboxed process run was refused when creating the temporary
Unix socket; the process tests were rerun with controlled execution permission.
No installed LaunchAgent or ArkDeck account state was changed.

## CI

Not submitted yet. CI status is not an approval or hardware acceptance.
