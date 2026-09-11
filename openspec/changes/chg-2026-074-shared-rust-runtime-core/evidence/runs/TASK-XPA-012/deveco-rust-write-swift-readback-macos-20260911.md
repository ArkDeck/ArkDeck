# Rust DevEco write / native Swift readback — 2026-09-11

`BootstrapInspectionControlContractTests.testExplicitRustDevEcoRegistryIsReadBackWithoutWrites`
is an opt-in compatibility check for a completed, stopped Rust daemon run.
It accepts only the explicitly supplied `ARKDECK_DEVECO_RUST_REGISTRY_ROOT`
under `/private/tmp/` and an exact
`ARKDECK_DEVECO_RUST_TOOL_REFERENCE=toolchain:sha256:<lowercase digest>`.
Without both values the test skips; it does not synthesize registry input.

The supplied root, `.lock`, `bundles.json` and `deveco-toolchains.json` must
already exist. The check instantiates a real `BootstrapBundleRegistry(root:)`
shared owner and calls the actual `BootstrapDevEcoToolchainRegistry.inspect`
with `existingStoreOnly: true`. Native trust, source identities and sealed
resources are revalidated, and the durable index is decoded by the frozen
Swift implementation. No injected trust or manually constructed success
projection is used. The test prints the actual returned native owner value.

The test checks the expected tool reference and digest, available generation 1,
DevEco kind, and unselected state. A recursive census of registry members,
permissions and regular-file content SHA-256 values must be identical before
and after inspection. It never registers, selects, removes, creates a missing
store, writes the supplied registry, or opens the default installed registry.
Only the test harness's ordinary separate temporary engine directory is owned
and cleaned by test setup/teardown.

Invocation after the Rust daemon has stopped:

```sh
ARKDECK_DEVECO_RUST_REGISTRY_ROOT=<existing private temporary Bootstrap root> \
ARKDECK_DEVECO_RUST_TOOL_REFERENCE=<exact Rust-registered toolchain reference> \
  sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test \
  --filter BootstrapInspectionControlContractTests.testExplicitRustDevEcoRegistryIsReadBackWithoutWrites
```

## Actual native readback results

Both actual process-harness roots passed the strict Swift readback test, each
with 1 test, no skips and no failures, after the producing daemon stopped:

| Registration producer | Existing Bootstrap root | Swift result |
| --- | --- | --- |
| Release Rust CLI → Release Rust daemon | `/private/tmp/arkdeck-deveco-register-q_5muhr2/state/bootstrap` | PASS, 0.538 seconds |
| Existing Swift CLI → Release Rust daemon | `/private/tmp/arkdeck-deveco-register-h6966sja/state/bootstrap` | PASS, 0.521 seconds |

Both roots were read using expected reference
`toolchain:sha256:9cee08f1e191112cb68a24ec3aa941f8d5342482224258ee3e34cdd122855e27`.
The native Swift owner decoded Rust's durable schema without a migration or
projection shim and returned that exact reference, content digest, available
generation 1, unselected DevEco kind and all five sealed child roles. Both test
runs asserted unchanged recursive membership, permissions and content hashes.

The second root also had a separate before/after comparison covering the root
and its three files: device/inode, mode, uid/gid, link count, byte size,
mtime/ctime nanoseconds and regular-file SHA-256. All four entries were exactly
unchanged. The retained baseline is
`/private/tmp/xpa012-deveco-swift-cli-rust-readback-before.json`.

The actual unedited test logs contain the full native owner's emitted JSON:

- `/private/tmp/xpa012-deveco-rust-readback.log`, SHA-256
  `490ff00e7b145fec78eb24dc7d85bdc65d86d0fda61be40413f97c40ef9fe511`.
- `/private/tmp/xpa012-deveco-swift-cli-rust-readback.log`, SHA-256
  `d521ada469fc0a2028c2d4644c027e69294ba83962f69223a96943c1fe33b861`.

The pre-existing Swift CLI used for the second producer was
`/Users/fuhanfeng/Library/Caches/com.arkdeck.ArkDeck/SwiftPM/ArkDeckKit/build/arm64-apple-macosx/debug/arkdeck`.
The initial empty-environment compile check skipped as designed and is not
counted as either actual readback result. No schema or other product source
changed for this supplement.
