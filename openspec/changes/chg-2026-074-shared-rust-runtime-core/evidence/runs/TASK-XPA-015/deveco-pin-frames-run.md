# The DevEco owner's refusals through a preset's pin (TASK-XPA-015, M3)

This change is Swift-only. One Swift contract test drives
`workspace.preset.register/update/remove` through the pin the composition root
builds over `BootstrapDevEcoToolchainRegistry`, and records the registry's own
refusals. #2041's oracle pinned through a test owner that accepted every pin,
so the published schemas carry none of them; the Rust control layer answers
`internalError` for a code outside the published set, and the Rust daemon is
about to compose the same pin.

Base: protected `main` `28d2016c`, which carries #2064's pin oracle.

| Already on `main` | This change delivers | Still remaining (M3) |
|---|---|---|
| The seven workspace methods on the Rust owner (#2056); the DevEco pin oracle for the registry's own acquire and release (#2064) | `AgentDaemonContractTests.testWorkspacePresetPinsRecordTheDevEcoRegistryRefusals`; 13 recorded frames; re-derived schemas and corpora for the three preset mutations | Rust DevEco acquire and release and their composition into the isolated daemon; the signing credential owner; the 13 `workspace.*` operations; GJ-5 |

## What the test records

The test registers three fabricated DevEco roots in one registry, with the
injected trust `BootstrapToolRegistryContractTests` uses, and gives the
production daemon handler a `RuntimeWorkspaceProjectStore` whose
`RuntimeWorkspaceToolchainPinning` is the one `ArkDeckAgentDaemonMain` builds:
the registry's `AgentExecutionControlFailure` becomes the preset owner's
failure, code and message unchanged.

| Step | Answer |
|---|---|
| Register a build preset on a registered toolchain | the preset, pinned |
| Register on an unregistered reference | `resourceNotFound` |
| Register at generation 2 | `resourceConflict` |
| Update to an unregistered reference | `resourceNotFound` |
| Update to the second toolchain | the preset at generation 2 |
| Update to a toolchain retired meanwhile | `resourceConflict` |
| Remove the preset | removed, and its pin released |
| Register on a toolchain whose child is gone | `fileIdentityChanged` |
| Register on the second toolchain | the preset, pinned |
| Register once its reference bound is reached | `quotaExceeded` |
| Register after its content changed | `recordUnreadable` |
| Remove a preset pinned to that changed content | `recordUnreadable` |

The last step is last on purpose. A removal writes its record and then
releases, and the release verifies the same content, so it cannot complete:
the intent stays and every later request meets it. The store is only readable
again once the content is restored.

## Schema derivation

For the three methods only, the source held the committed corpus plus this
test's frames. `generate-control-contract.py --derive-method-schemas` wrote the
schemas and corpora, and `rust/scripts/generate-contract.py --write`
regenerated the manifest: 105 methods, 904 recorded shapes.

| Method | Codes added to the published set | Corpus lines |
|---|---|---|
| `workspace.preset.register` | `fileIdentityChanged`, `resourceNotFound` | 19 → 21 |
| `workspace.preset.update` | `resourceNotFound` | 12 → 13 |
| `workspace.preset.remove` | none: the release's `recordUnreadable` was already published | 11 → 11 |

A structural check found every new schema a superset of the old one: types,
properties, definitions and codes. One old register line, a `resourceConflict`
carrying `credentialRef`, was replaced by a refusal of the same code; a
successful signing registration and an `invalidInput` still evidence that
member, and it stays in the request schema.

## Local targeted checks

| Check | Exit | Result |
|---|---|---|
| `run-swiftpm.sh test --filter AgentDaemonContractTests/testWorkspacePresetPinsRecordTheDevEcoRegistryRefusals` with `ARKDECK_CONTROL_FRAME_LOG` | 0 | 1 test, 0 failures (2.2 s); the recording |
| `run-swiftpm.sh test --filter ControlMethodSchemaContractTests` and both workspace frame tests | 0 | 7 tests, 1 skipped, 0 failures |
| `python rust/scripts/generate-contract.py --check` | 0 | no difference after `--write` |
| `cargo test -p arkdeck-contract` | 0 | 44 passed |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |

## CI

The PR's `guard` and `swift` aggregate are the unified gate. The Swift lane
runs because a Swift test changed; the Rust lane runs because contract inputs
changed. Their result is added by the Rust port that stacks on this change.
