# TASK-AIN-BKMK-001 implementation run

Date: 2026-07-28

Classification: host-only implementation, contract validation, and product prerequisite
consumption matrix. This run is not real-device or hardware validation.

## Authorization, base, and concurrency

- Fresh D1 readiness PR #710 exact head
  `22b2d2985fbf19e296c0b6dab3fb5fa809c7297e` was approved by `lvye` and merged as
  `70739c4c483232ff6a5d094d753811114e3b9702`.
- Implementation began from protected main
  `f065ac90e69ff89c9ebb8817bfb4f9ebb1b0ed7d`; every readiness implementation pin matched
  its recorded blob before editing.
- Before final product and test runs, the branch was fast-forwarded to latest protected main
  `570fe28c2d6edbad18050cfe873246fd45f0bc40`. The intervening twelve paths were confined to
  HDC/OpenHarmony, CHG-2026-008, CHG-2026-022, and CHG-2026-042; they had zero intersection
  with this task's modified paths. The complete open-PR query returned `[]`.
- Immediately before push, #720 advanced protected main to
  `cd3f3e0a7b4c2055746a617110e94b2e1dc791c7` by changing only
  `openspec/changes/chg-2026-042-tasks-field-colon-parity/tasks.md`. The single implementation
  commit was rebased onto that OID; no product/source/test/change-local blob changed, and final
  SDD/path/diff checks were rerun.
- The final pre-push fetch then observed #721 at
  `54c3a3cfbc455b5eb0ab6710955ad994d5b57eac`. Its seven paths are confined to
  CHG-2026-042 and `scripts/host_loop/**`/`scripts/test_check_pr_paths.py`, with zero
  intersection with this task's modified paths. The same single commit was rebased again;
  the updated path-guard suite passed 50/50, and SDD/diff checks were rerun.
- Branch: `agent/chg-2026-025-ain-bkmk-001-implementation`.
- Environment: macOS 26.5.2 (`25F84`), arm64, Apple Swift 6.3.3.

## Final implementation blobs

The task implementation, tests, schema, runbook, and schema-matrix blobs before adding this
self-referential run carrier are:

| path | blob |
| --- | --- |
| `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift` | `98c3acc08b79384f1a24947032ddfc3b75456b3c` |
| `Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionManifest.swift` | `22e5010f47a654557f84d1514421a71a792147de` |
| `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipDeviceDiscovery.swift` | `50351ccd04596d1bcf5b71e56ed16998f93aed56` |
| `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionHost.swift` | `325e95122a6bed3355d0c45867bbc317f26af544` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipDeviceDiscoveryContractTests.swift` | `9dca5fe155dcbe697f2a0ebb813f0ee9a7850818` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipFlashExecutionContractTests.swift` | `f17f7c86e110732b003fc7ab792ae44e6e456ec4` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipProductionCompositionContractTests.swift` | `f780acccdc96142f078e4cd52aea1c58cc15183a` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/SessionArtifactStorageContractTests.swift` | `335dc5fc62a7c30c6d0e209f1539b0c78d0caff8` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipToolBookmarkContractTests.swift` | `26b4f55c24c39ce101ba2de84b2e0dad3f8d3365` |
| `contracts/manifest.schema.v2.1-draft.json` | `1fdb14da2ea8c0b45f88c3d5eef277b37e540976` |
| `evidence/host-prerequisites/installation-runbook.md` | `987596b160c33afd32c9a20737b49797f34b537c` |
| `evidence/runs/TASK-AIN-BKMK-001/schema-matrix.py` | `2ca416fba4c9cadac1be7486edc35c3cc9a29ced` |

The PR head commit and final carrier blobs remain independently recoverable from git; this run
does not attempt an impossible self-hash of its own bytes.

## Implementation

1. Added the sole product-owned installer:
   `arkdeck flash install-tool --path <absolute-rkdeveloptool-path>`. It accepts only a
   canonical, non-symlinked regular executable whose independently prepared descriptor/hash
   matches the fixed production pin. The prepared token is immediately closed; the installer
   never calls execute or launches the tool.
2. Added an ordinary-bookmark store under
   `ArkDeck.Rockchip.ToolOrdinaryBookmarkV1`. Installation performs create, ordinary
   `[.withoutUI]` self-resolution, canonical exact-target comparison, write/readback, and a
   second resolution before becoming consumable.
3. Kept `ArkDeck.Rockchip.ToolBookmark` only as a migration detector. Legacy-only, dual-key,
   missing, wrong-type, corrupt, stale, and non-canonical states fail with controlled
   `productionConfigurationUnavailable`. The old key is deleted only after the new value is
   durable and revalidated; an injected dual-key crash state remains blocked and installer rerun
   completes recovery.
4. Replaced the discovery Bool with a closed access-policy enum. E0 remains
   security-scoped and requires a successful scope start; production is typed ordinary,
   resolves without scope, and never starts or stops security-scoped access. Each profile rejects
   the other path source.
5. New authorized Rockchip Manifest 2.1 output uses
   `installedOrdinaryBookmark`. The locked validator and change-local schema accept only that
   value plus the historical `userSelectedSecurityScopedBookmark`; historical canonical bytes
   remain stable, and path/bookmark material remains forbidden.
6. Updated the installation runbook to use the product installer and document legacy/dual-key
   recovery. The retired helper-created security-scoped path is explicitly non-executable
   guidance.

## Fault, migration, and compatibility matrix

`RockchipToolBookmarkContractTests` uses an isolated `UserDefaults` suite and injected
preferences/bookmark/verifier seams. All six tests passed:

```text
TEST-AIN-BKMK-001 PASS leg=migration crash_state=dual blocked=true rerun=recovered legacy_consumed=0 spawn=0
TEST-AIN-BKMK-001 PASS leg=installer-faults verifier=blocked create=blocked roundtrip=blocked write_readback=restored spawn=0
TEST-AIN-BKMK-001 PASS leg=input-matrix absolute=closed canonical=closed symlink=closed parent_symlink=closed regular=closed executable=closed hash=closed prepared_only=true spawn=0
TEST-AIN-BKMK-001 PASS leg=isolated-defaults ordinary=true stale=false target_match=true spawn=0
TEST-AIN-BKMK-001 PASS leg=loader-faults missing=blocked wrong_type=blocked legacy=blocked dual=blocked corrupt=blocked stale=blocked path=blocked spawn=0
TEST-AIN-BKMK-001 PASS leg=typed-access e0=scoped scope_start=required production=ordinary production_scope_start=0 cross_policy=blocked
```

The locked persistence test passed both values, retained historical bytes, emitted only the new
value, and rejected unknown/forbidden fields:

```text
TEST-AIN-ROCKCHIP-PERSISTENCE-001 manifest=2.1.0 journal=2.1.0 identity=descriptor-bound path_sources=historical-scoped,new-ordinary historical_bytes=stable export=non-sensitive negatives=closed-shape mixed-version=rejected dispatch=0
```

The dependency-free schema shape matrix also passed:

```text
SCHEMA-AIN-BKMK-001 PASS draft-shape=2020-12 historical-scoped=accepted new-ordinary=accepted unknown=rejected path=forbidden bookmarkData=forbidden network=0
```

## Final product A/B matrix

Both products were rebuilt after the final protected-main fast-forward using separate SwiftPM
scratch paths, copied with basename `arkdeck`, and ad-hoc signed with distinct explicit
identities:

| build | binary SHA-256 | Identifier | CDHash |
| --- | --- | --- | --- |
| A | `7cd73f2eda178e9db992f59b99620432e4b60f60e5ac785436d14366b4b05afe` | `dev.arkdeck.implementation.a` | `171ac1b7b0b85d0956dd3ffe2b4ba6fa08dd4dc3` |
| B | `b9b7b58943ab1156f938ef4aace6586dede8630911297ca77b2d9d0f1efc9b32` | `dev.arkdeck.implementation.b` | `2788255be72363f3648b740520672aeb4bc0a229` |

The target was only opened/read for descriptor and SHA-256 validation; its hash was exactly the
fixed production value
`038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`.
No target path or bookmark bytes are recorded here.

1. Formal old, new, and quarantine-presence keys were all absent before the final matrix.
2. A ran the product installer and returned
   `pinned rkdeveloptool ordinary bookmark installed`.
3. B ran the authorized-execute CLI shape with the syntactically valid readiness ID and returned
   exactly:

   ```text
   productionConfigurationUnavailable("tool quarantine assessment is absent")
   ```

   Thus B consumed A's installed first prerequisite and stopped at the next D-1 gate, before
   authorization provenance, process-port construction, tool execution, USB, or device access.
4. The formal new key was deleted. A and B then each returned
   `pinned rkdeveloptool ordinary bookmark is not installed`, and final read-type checks confirmed
   old/new/quarantine keys were all absent.

The first precondition attempt correctly stopped without running A or B because a historical old
Data key and quarantine Boolean key were present. No value bytes were read. The maintainer then
explicitly authorized deletion of those two keys; after deletion, all three formal-key
preconditions were rechecked before the matrix.

## Verification

Every exact readiness command was rerun against final protected main:

| command/filter | result |
| --- | --- |
| `RockchipToolBookmarkContractTests` | 6 tests, 0 failures |
| `RockchipDeviceDiscoveryContractTests` | 7 tests, 0 failures |
| `RockchipProductionCompositionContractTests` | 2 tests, 0 failures |
| `RockchipFlashExecutionContractTests` | 3 tests, 0 failures |
| `RockchipFlashExecutionFaultContractTests` | 9 tests, 0 failures |
| `SessionArtifactStorageContractTests` | 60 tests, 0 failures |
| `RockchipRockUSBFlashProviderContractTests` | 15 tests, 0 failures |
| `CI=true swift test --package-path Packages/ArkDeckKit` | 466 tests, 1 skipped, 0 failures |
| `./scripts/check-sdd.sh` | 0 errors, 0 warnings, 111 acceptance IDs |
| `python3 scripts/test_check_pr_paths.py` | 50/50 passed after #721 |
| `xcrun swift-format lint --strict <nine changed Swift files>` | PASS |
| `git diff --check` | PASS |

The full result is the latest-main 460-test baseline plus six new bookmark tests. Existing
AC-FLASH-015 summaries remain:

```text
TEST-AC-FLASH-015-01 PASS destructive_dispatch=0 job=policyBlocked handoff=controlled
TEST-AC-FLASH-015-01 PASS agent=policyBlocked ci=policyBlocked planOnly=allowed dispatch=0
TEST-AC-FLASH-015-02 PASS mismatch_fields=8 stale_plan_blocked=1 real_dispatch=0 realhardware_evidence=none
```

## Effects, deviations, and conclusion

- Explicit final counters:
  `rkdeveloptool_spawn=0`, `real_device=0`, `USB=0`, `E1=0`, `E2=0`,
  `destructive=0`.
- Product A's verifier performed a descriptor/hash prepare only and immediately closed the token.
  Product B stopped before process composition. No HDC, USB probe, device identity, credential,
  network, standing-authorization provenance, or destructive command was consumed.
- Initial sandboxed Swift compilation could not write the user Clang module cache. The same
  commands were rerun through the repository-approved controlled outside-sandbox test path.
- A first optional Draft validator attempt found that the system Python lacked `jsonschema` and a
  historical `/private/tmp` dependency directory was incomplete. It performed no validation and
  made no repository/product change. The final checked-in schema matrix uses only Python stdlib;
  semantic object acceptance/rejection is independently covered by the locked Swift validator
  tests.
- No task scope or acceptance deviation remains. AIN-BKMK-001 positive cross-identity
  consumption, persistence compatibility, migration recovery, and unchanged authorization
  fail-closed legs all pass. This does not mark the change verified or make TASK-AIN-004 E2 ready.
