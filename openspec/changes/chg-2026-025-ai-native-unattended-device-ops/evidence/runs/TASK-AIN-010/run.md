# TASK-AIN-010 implementation run

Date: 2026-07-29

Classification: host-only Swift implementation and contract/fake-port
verification. This run is not real-device, hardware, HDC, installed-tool,
network, E0, E1, or E2 execution evidence. It created no live capability,
standing authorization, usage reservation, target identity, device readback,
or external-effect result.

## Authorization, base, and scope

- TASK-AIN-010 was `ready` on the implementation base. Its dependencies
  TASK-AIN-009 and TASK-AIN-009R were `done`.
- Implementation branch:
  `agent/task-ain-010-implementation`.
- Final protected-main implementation base:
  `248eb1e5348fb2bcc90c69af5d7b17c6954a99ca`.
- Implementation commit:
  `6cc7ffb65f618b28fa23c899936cbda6a9f169cb`.
- The base advanced during implementation through TASK-HSO-001 PRs #755 and
  #756. Those commits add supervisor-observation contracts, tests, evidence,
  profiles, and status. They do not intersect TASK-AIN-010 outputs or pinned
  inputs. The implementation was rebased without conflict and all checks were
  repeated.
- Environment: macOS 26.6 (`25G72`), arm64, Xcode 26.6 (`17F113`), Apple
  Swift 6.3.3.
- All 45 readiness-pinned contract, governance, runtime, test, and
  `Package.swift` blobs were found unchanged in the final base (`45/45`).
- The implementation commit changes only the 14 source/test files permitted by
  TASK-AIN-010. This evidence file is also in its declared run directory.
  Current specs/contracts, App, CLI, `Package.swift`, tasks.md, real
  capability/authorization carriers, and concrete device executors are
  unchanged.

## Implementation result

1. Added the public closed request/result/error/blocker API and the public
   `TrustedDeviceOperationHost` actor. Its only public admission method accepts
   encoded request bytes; trusted plans, facts, grants, ports, paths, argv,
   executors, and outcome claims cannot be supplied by callers.
2. Added strict duplicate-aware JSON decoding for the AIN-009 request/result
   shapes, including Unicode-escaped duplicate rejection, closed objects,
   canonical identifiers/digests/timestamps, the 15-operation/21-profile
   registry closure, and cross-mode authorization-selector rules.
3. Implemented the trusted admission order through package-owned ports:
   registry and typed-plan resolution, maximum Core effect calculation, fresh
   fact resolution, durable claim, E0/E1/E2 authority resolution, usage
   reservation, durable `jobCreated`, exact-once permit consumption, durable
   external intent, typed dispatch, outcome, and Manifest publication.
   `planOnly` and `simulated` stop before authority, storage, or dispatch.
4. Added a non-Codable one-shot execution permit with a fileprivate
   initializer, exact request/job/session/plan/target/fact/authority binding,
   freshness checks, and lock-protected exact-once consumption. It cannot be
   reconstructed from persisted audit identity.
5. Added the closed E0/E1/E2
   `AgentExecutionAuthorityReference` runtime union while retaining the
   existing E2 `AuthorizationReference` API and historical Journal/Manifest
   behavior.
6. Added the separate durable E1 `AgentAuthorityUsageLedger` with its fixed
   file/lock/temp names, 16 MiB bound, no-follow/link/owner/mode checks,
   host-wide serialization, atomic replace and directory sync, monotonic
   ordinal/maximum-use enforcement, one-active-target rule, idempotent retry,
   and consumed-never-refunded semantics. E2 remains in the pre-existing
   ledger.
7. Added Journal and Manifest 2.2 runtime support for exact authority,
   reservation, external Step intent, external compensation, outcome, and
   confirmation correlation. Historical 1.0/2.0/2.1 readers and writers remain
   covered without migration, inference, or authority minting.
8. Added the eight closed `HumanActionRequired` mappings. Only a matching,
   unexpired trusted read-only probe receipt can resolve a blocker. Text,
   elapsed time, caller claims, identity guesses, self-approval, privilege
   escalation, helper installation, and outcome guesses cannot resolve or
   elevate authority.
9. Dispatcher uncertainty persists an unknown outcome and a structured
   recovery blocker. The host does not synthesize success, replay an
   outstanding effect, guess compensation, or resurrect a permit.

### Persistence compatibility matrix

| Stored version | Runtime meaning | Write/migration result |
| --- | --- | --- |
| Journal/Manifest 1.x | locked historical semantics | bytes and version preserved |
| 2.0.0 | standing-authorization correlation | existing semantics preserved |
| 2.1.0 | standing authorization plus Rockchip descriptor identity | existing semantics and E2 usage preserved |
| 2.2.0 | E0/E1/E2 authority union and exact external intent correlation | new authorized Agent Jobs only |

## Final implementation file identities

The run record itself is excluded because it is self-referential.

| Path | SHA-256 | Git blob |
| --- | --- | --- |
| `Packages/ArkDeckKit/Sources/ArkDeckStorage/AuthorizationUsageLedger.swift` | `f2c38a59679cb34c045aeee89129ebd34ef5dc6af7e214e84880ae50d5426724` | `e029b0505b62b7ac85cb45d1b4b693fa011e48ff` |
| `Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalEvent.swift` | `5efef1b4126bfd9f41d893ebf7830c77ed8c4ca753e80e925caad6837e235732` | `ac9f7c8e063fd6b5a6797207f30a6e477fec1fd7` |
| `Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalEventValidation.swift` | `1ceaa220741a64f07edf241551bf2ab03fc4ec33bc5c01241b5c64ca5ca69560` | `ebf3bfee93a0e97dd852d6e8a1fd36c0db4b2bab` |
| `Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalReplay.swift` | `e9da35facdec56e51d8721ce55b5c4f178055fa588839998019425ddd5b16b0a` | `7dea6267ec1da958ea958be1f3455dbb085f4ce1` |
| `Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionManifest.swift` | `551fb7c4da29af070b7b3f077fca4d5d22ea9f10fc41df65648748dee012678e` | `dd899389a55228f016a941dedefc6bcbb507ad13` |
| `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentDeviceOperations/AgentDeviceOperationModels.swift` | `260491b55e931201e05905ad8ac995b30b15bfcc2b1daca6a013d7a3ba4bb007` | `e7ea9326039b392b3ca370f7756e6f7c73e806d0` |
| `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentDeviceOperations/AgentStrictJSON.swift` | `adc9309a37677c213d76e50c378ad261be1d0bd68a416d60d148b8d1a58c6f85` | `990ac35bb5d9ec62aa828c8cb733a3c59cc34765` |
| `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentDeviceOperations/TrustedDeviceOperationHost.swift` | `a24f0b9a3554d4b15ee3af215f3c2d8a65382b2ff212ba25d7f34d56ec6e40df` | `d5509f326d53296c70ad10c3c3719fea1c5f1857` |
| `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HumanActionRequired.swift` | `e48274ac91f4770b86010877e3feb5f7a3725bb27e31162f7ad8bc419041c1c8` | `5d31f7785a20c750854215ca72354e27c54710a2` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentDeviceOperationHostContractTests.swift` | `309558a43322e4c0d444c103fc9a6423f3d24453ea1e837a35c728d444080103` | `2b91dfad25d317ac810fd054b0ec7a7c3a59309b` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AuthorizationUsageLedgerContractTests.swift` | `7bc61b491936a636a7691d28b9ff37a9923f8318ac608438f563ff4be7f931d5` | `48a5c68c547ac908e25f57acbc2a04207356c4bc` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HumanActionRequiredContractTests.swift` | `09c666eeb15abfff167e5a4d3eb293ba511bf39a3ac94954f37de4c91c4527de` | `6ed46e5cdf0e88f952427e5a941dbcd1c56149a6` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/JournalRecoveryContractTests.swift` | `ecb11f0bb7607c043f6ff4798a586c7eeac040b395ea15169206391dc5331bcd` | `69af4d4cdde61edc424cedb91e4615d2b76651dd` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/SessionArtifactStorageContractTests.swift` | `e10938f829c75f08bf7121fbba05f24732455305eeda4bd55e248f68c55fd5cd` | `210e38c1c3d57142ca459587f4fc1e889978e426` |

## Verification

### Focused host, human-boundary, usage, and persistence matrix

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter 'AgentDeviceOperationHostContractTests|HumanActionRequiredContractTests|AuthorizationUsageLedgerContractTests|JournalRecoveryContractTests.testAgentAuthorityV22|SessionArtifactStorageContractTests.testAgentAuthorityV22'

Executed 18 tests, with 0 failures (0 unexpected).
TEST-AIN-HOST-001 PASS operations=15 profiles=21 human_blockers=8 authority_kinds=3 legacy_versions=3 process_dispatch=0 device_dispatch=0 hdc_dispatch=0 network=0
TEST-AIN-HUMAN-001 PASS categories=8 resume_probes=5 prohibited_automation=9 text_resume=blocked authority_elevation=0
```

The matrix contains five host tests, three human-boundary tests, seven E1/E2
usage-ledger tests, two Journal 2.2 tests, and one Manifest 2.2 test. It covers
all three authority kinds, registry closure, malformed and injection requests,
plan/effect/fact/authority drift, exact E1 reservation identity, atomic crash
windows, permit expiry, structured blockers, unknown outcomes, external
compensation correlation, and historical-version coexistence.

### Frozen contract validators

```text
/usr/bin/python3 \
  openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-009/validate_contracts.py
TEST-AIN-OP-CONTRACT-001 PASS requests=3 results=4 operations=15 profiles=21 human_blockers=8 negatives=49 duplicates=2 core_steps=41 process_dispatch=0 device_dispatch=0 hdc_dispatch=0 network=0

/usr/bin/python3 \
  openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-009R/validate_contracts.py
TEST-AIN-CAP-CONTRACT-001 PASS e1_profiles=11 namespaces=5 authority_kinds=3 legacy_versions=3 process_dispatch=0 device_dispatch=0 hdc_dispatch=0 network=0
```

Both validators use only Python stdlib and checked-in bytes.

### Full regression and repository guards

```text
CI=true swift test --package-path Packages/ArkDeckKit
Executed 499 tests, with 1 test skipped and 0 failures (0 unexpected).

./scripts/check-sdd.sh
check_sdd: 0 error(s), 0 warning(s), 111 acceptance IDs

python3 scripts/test_check_pr_paths.py
Ran 50 tests
OK

xcrun swift-format lint --strict <all 14 changed Swift files>
git diff --check
RESULT: PASS
```

The readiness baseline was 476 tests / 1 skipped / 0 failures.
TASK-AIN-010 adds 14 tests. The final protected-main base also contains the
nine subsequently merged TASK-HSO-001 contract tests, yielding the final
499-test matrix. The single skipped test is the pre-existing manual macOS
sleep/wake observation harness.

Static source audit found no `Process`, `URLSession`, `posix_spawn`, `system`,
`popen`, `/dev/`, or `rkdeveloptool` surface in the new host or human-action
sources, and no TODO/FIXME/fatal placeholder. The task-local canonical results
record process/device/HDC/network dispatch as `0/0/0/0`.

## Acceptance, deviations, and residual risk

- `AC-WF-003-02` and `AC-WF-003-03`: **PASS** for the closed public request
  seam, trusted typed-plan/effect resolution, injection rejection, and
  structured automation-boundary output.
- `AC-DEV-009-01`: **PASS** for fresh target/fact binding, E1 capability and
  reservation correlation, mismatch rejection, and one-shot permit semantics
  under fake ports.
- `AC-JOB-002-01`, `AC-JOB-005-01`, and `AC-JOB-006-01`: **PASS** for
  durability-before-effect, typed dispatch without a shell string, exact
  authority/usage/intent/outcome persistence, and fail-closed recovery.
- Process/device/HDC/network dispatch attributable to TASK-AIN-010:
  **0/0/0/0**.
- No scope, privacy, authorization, or acceptance deviation remains.
- Production App/CLI reachability remains intentionally owned by TASK-AIN-015.
  Concrete Dump/Trace/HiLog/HAP/SO executors remain owned by TASK-AIN-011
  through TASK-AIN-014. Therefore this run does not claim product end-to-end or
  real-hardware verification.
- TASK-AIN-010 remains `ready`. A separate maintainer-reviewed status PR must
  record `ready→done`; this implementation PR does not perform that governance
  transition.
