# Current health registry producer oracle — 2026-09-11

Adding the two Bootstrap inspection methods makes the current protocol registry
contain 99 methods. The existing two successful `health` corpus frames still
contained the old 97-method list and its old contract identity. They were
therefore stale inputs for a current-registry consumer, even though their JSON
shapes still validated against the health schema.

`AgentDaemonContractTests.testHealthProducerFramesUseCurrentRegistryWithEmptyAndHDCProviders`
records both shapes again through the actual Swift
`RuntimeControlPlaneHandler.handleFrame`. It creates an empty
`DeviceProviderRegistry`, then a registry containing the existing
`HDCObservationProviderAdapter` test fixture. Each registry is supplied to the
real engine, and that registry's `registeredProviderIDs` is supplied to the
handler. The test compares the returned protocol identity, sorted method set,
Catalog digest and provider IDs with the current build's actual definitions.
It also asserts that both engines have no Jobs and the shared dispatcher count
is zero.

The HDC facts fixture is not invoked by health. Its adapter registration is
software inventory, not a claim of hardware observation, provider coverage,
execution authority or real-device acceptance. No successful JSON frame or
identity field was fabricated or edited.

## Unmodified producer recording

[`control-frames-29869.jsonl`](health-current-registry-frames-macos-20260911/control-frames-29869.jsonl)
contains exactly two successful actual producer frames, in order:
`providers: []` and `providers: ["hdc"]`. SHA-256:
`827a69a6f185c8caa42d22b839e8f6c00877db51c93f195728fd735b0b80513c`.

The committed `Fixtures/ControlFrames/health.jsonl` is a byte-for-byte copy of
that raw file. Both responses contain all 99 current methods and identity
`05a9f1ad8309a0cd23666bf00aa07eb4c04f317e882183f9aa612568faf64492`.
The two Bootstrap method names enter through the actual registry, not by
rewriting the old recorded response.

All 98 other method corpus files have the same SHA-256 before and after this
supplement: the other 96 pre-existing methods and the two newly recorded
Bootstrap methods. Thus the earlier statement that every old corpus stayed
unchanged now has exactly one explicit exception: these two health frames.
No health schema definitions, other schemas, Rust files or pins are changed
by this recording supplement.

## Focused verification

The new producer test passed: 1 test, 0 failures. Its recording command was:

```sh
ARKDECK_CONTROL_FRAME_LOG=/private/tmp/xpa012-health-current-frames \
  swift test --package-path Packages/ArkDeckKit \
  --filter AgentDaemonContractTests/testHealthProducerFramesUseCurrentRegistryWithEmptyAndHDCProviders
```

The initial sandboxed invocation could not write the normal compiler module
cache; the successful invocation used the same local Swift toolchain with
cache access. No assertion or trust check was relaxed.

The existing health client and method-schema checks use the repository wrapper:

```sh
ARKDECK_CONTROL_FRAME_LOG=/private/tmp/xpa012-health-current-frames \
  sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test \
  --filter 'AgentDaemonContractTests/testDefaultClientUsesTheOnlyCurrentHealthContract|ControlMethodSchemaContractTests'
```

This wrapper run passed all 5 tests (the existing health client plus 4 schema
tests). `generate-control-contract.py --check`, `git diff --check`, the health
schema-definition comparison, and the other 98 corpus hash comparisons also
passed.

The full Bootstrap gate and Rust candidate replay remain the integrating
task's validation; this supplement does not claim a separate full gate or
device run.
