# TASK-RLC-001 legacy import manifest

- Audit date: 2026-07-19 (Asia/Shanghai)
- Execution base: `840e8306e0f8539072c3931384a21a80269d9027`
- Execution-base tree: `4391a42e2b7e1bde49b69c1211a707a46c356c18`
- Evidence class: headless Git-object audit, static source-surface audit, repository-fake process
  contracts, temporary-file contracts, and loopback-only platform contracts.
- Excluded evidence: real HDC, real device, GUI/XCUITest, NSOpenPanel/PowerBox, non-loopback
  network, hardware, conformance, support, and release.

This manifest treats only the three full commit OIDs approved in CHG-2026-014 as source
authority. Branch names are not authority. The deleted M1-006 branch is mentioned nowhere as an
input; GitHub's immutable PR #105 head ref is used only to prove that the fixed commit remains
retrievable.

## Object anchors

| Input | Source task | Parent/base | Tree | Current-main disposition |
| --- | --- | --- | --- | --- |
| `ae708518ce6cc8bbd5ad39943d948b2d81209f03` | CHG-2026-002 / TASK-M1-006 implementation | `0db5f22c0878d059697d32a3022fa260c83e2798` | `eb3df103b87c898edb24d3143cbd165244e9abea` | `already-in-main`; human-reviewed squash `21c2e218973c301e7ac6c43659d8918828f2c39e` has the same parent and tree |
| `0076e44dcaed45605c1cccefc093a82b246a4ef5` | CHG-2026-009 / TASK-PD-001 r2 implementation | `87a3a99241604b5140b049964e353dc1af00e525` | `373ce2f07c405ee769cbba688c5b8adbaddb11e0` | `already-in-main`; all 12 changed script blobs remain identical |
| `0db5f22c0878d059697d32a3022fa260c83e2798` | CHG-2026-009 / TASK-PD-001 blocked rerun | `b01cab60a405704ee59f9f2b11e6eba102b4fa9f` | `ff4280c2dcc262a9e9a28490dc8e86f9b85fe4b4` | `already-in-main`; both governance/evidence blobs remain identical and read-only |

`git diff --name-status` from the M1 squash to the execution base over all M1 source paths, from
the PD implementation to the execution base over `scripts/partition_decode/**`, and from the PD
blocked record to the execution base over its change directory all returned an empty diff. No
source file needed re-import or rejection in TASK-RLC-001.

## M1-006 path inventory

Hashes below are full Git blob OIDs in this repository's SHA-1 object format. Because the source
tree and human-reviewed squash tree are identical, each resulting blob is also the current-main
blob for the named path.

| Delta | Path | Resulting blob | Disposition / runtime role |
| --- | --- | --- | --- |
| M | `ArkDeck.xcodeproj/project.pbxproj` | `e7943096688728a22f4b940e536a32f3b8eaaf98` | `already-in-main`; build wiring only |
| M | `ArkDeck.xcodeproj/xcshareddata/xcschemes/ArkDeck.xcscheme` | `29d0fb995dd3a28ad535569a4cdc4c3964311def` | `already-in-main`; scheme wiring, XCUITest not run by this task |
| M | `ArkDeckApp/App/ArkDeckApp.swift` | `5e1f175d82d2de867b6b783ddd80ea47fee87194` | `already-in-main`; imports Core/Workflows only and receives presentation closures |
| A | `ArkDeckApp/Features/HDC/HDCStatusView.swift` | `23379eb20fafdc79998699738ca0663da0ca921f` | `already-in-main`; UI presentation/confirmation surface, no process primitive |
| A | `ArkDeckAppUITests/HDC/HDCStatusUITests.swift` | `978eaf5e5f3b86180fea1e81f43ae86a76d1e1e3` | `already-in-main`; compile/static inventory only, not executed |
| M | `Packages/ArkDeckKit/Package.swift` | `81c767410e49718192e8b4b0acb390ec22f089d3` | `already-in-main`; declared module dependencies and fake executable target |
| A | `Packages/ArkDeckKit/Sources/ArkDeckCore/JobToolchainIntent.swift` | `030415ac00bb73b1ad5d70496588b92d2de883ac` | `already-in-main`; immutable typed Job/toolchain binding |
| M | `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/ArkDeckOpenHarmony.swift` | `4d091157f32389e0c8ca179c16e71e1a9c914888` | `already-in-main`; Supervisor state, confirmation, lease invalidation; execution types are closed |
| A | `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCProduction.swift` | `00710567cf3000d20a7604b0bd8ac63f810bc7fe` | `already-in-main`; fixed registered probes and package/internal process lifecycle implementation |
| M | `Packages/ArkDeckKit/Sources/ArkDeckProcess/ArkDeckProcess.swift` | `b1d5f423c004f4ba15b15a8cf862ed2085d8bcc9` | `already-in-main`; descriptor/inode/hash-bound launch and package atomic gate |
| A | `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift` | `021fb78988242e69b90194d72a7f1a212571fdbd` | `already-in-main`; public presentation facade, private production provider |
| A | `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCServerLifecycleJournalAdapter.swift` | `25943bd1012c484198b8d41276fb09e57003f68b` | `already-in-main`; package-only durable use case/finalizer composition |
| M | `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkDeckContractTests.swift` | `0e9008f6e30efe59628e32e221924b02d75bba48` | `already-in-main`; module import-boundary contracts |
| M | `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDCServer/HDCServerFixtures.swift` | `b28fd46265955cb8c125d90f8d9ed367de1f48ef` | `already-in-main`; repository fixture only |
| A | `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCSupervisorContractTests.swift` | `fbb48ebd496ee9f2de2a43110ee72ac83dd57e25` | `already-in-main`; fake/temporary-file/loopback contracts and dispatch counters |
| M | `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ProcessExecutorContractTests.swift` | `e2ce2c8736ef06c0b0c690304da189d331a648b3` | `already-in-main`; launch substitution and atomic invalidation counters |
| A | `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/JobToolchainIntentContractTests.swift` | `111dca6ba7f3a99c1d2719a54361ce6abd86147a` | `already-in-main`; durable intent round-trip/rebinding negatives |
| A | `Packages/ArkDeckKit/Tests/ArkDeckFakeHDCFixture/main.swift` | `463b41869ccdb4e1187275db04cb7491fb03d774` | `already-in-main`; test-only child, explicitly selected by path |
| A | `openspec/changes/chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-006/run.md` | `af731ae12bdb434a129d3b5fd2b64c41ff81b24f` | `already-in-main`; immutable source-task evidence, referenced not copied |
| M | `openspec/changes/chg-2026-002-macos-m1-infrastructure/tasks.md` | `b4c8b47df56fd40944e127b344a554dfa6cbc16c` | `already-in-main`; authoritative source status, not edited by this implementation PR |

## PD-001 r2 implementation path inventory

These paths remain byte-identical to the fixed r2 implementation. They are ledger-only inputs to
TASK-RLC-001: no interactive collector or fresh PD acceptance run was executed.

| Delta | Path | Resulting blob | Disposition / runtime role |
| --- | --- | --- | --- |
| M | `scripts/partition_decode/README.md` | `8e6595bdc61db64f33aab56461da8f2a13f6cab7` | `already-in-main`; documentation, read-only input |
| A | `scripts/partition_decode/broker_entry.py` | `7f7f01fb6cf1079fe4d5270704c7d90029f580e8` | `already-in-main`; same-process integer-fd entry, not run |
| M | `scripts/partition_decode/decode.py` | `517229228b71f8ceb21b5afad6a4d0d85cb62cab` | `already-in-main`; archive bytes accepted only through a pre-opened read-only regular-file fd |
| A | `scripts/partition_decode/evidence.py` | `9a4a093f85deb708421fac78868a0cde2aa1844d` | `already-in-main`; governed inventory/output publication helper, not run |
| A | `scripts/partition_decode/macos_input_broker/Broker.entitlements` | `7b82f33bb4e0f2764acac052010bf905161e9ea6` | `already-in-main`; interactive broker input, not built or run |
| A | `scripts/partition_decode/macos_input_broker/Info.plist` | `c855ed1a448730dba3befa55389d5025a8d38bce` | `already-in-main`; broker metadata, not built or run |
| A | `scripts/partition_decode/macos_input_broker/README.md` | `0a62889b8559ea11aa140daa3c16c1d5ada49d0a` | `already-in-main`; documentation, read-only input |
| A | `scripts/partition_decode/macos_input_broker/build_and_sign.zsh` | `9f6da2209d4d8b92b27624f3f74f2370a9fd868d` | `already-in-main`; fixed build script, not run |
| A | `scripts/partition_decode/macos_input_broker/collect_platform_evidence.py` | `839b53464605c27134ba8d527dd616e078b4b2fb` | `already-in-main`; interactive collector, explicitly not run |
| A | `scripts/partition_decode/macos_input_broker/main.m` | `71d183c58a82aa749807651156ed6c64204a6313` | `already-in-main`; NSOpenPanel broker, explicitly not run |
| A | `scripts/partition_decode/macos_input_broker/policy.json` | `519bfa75178a888db234535d14a5e3467852945a` | `already-in-main`; broker policy, read-only input |
| M | `scripts/partition_decode/test_decode.py` | `f88e9e7a62f41e0a8e8ba6ddd54f36a1a36b67d0` | `already-in-main`; source-task tests, not reused as fresh PD acceptance evidence |

## PD-001 blocked-record inventory

| Delta | Path | Resulting blob | Disposition |
| --- | --- | --- | --- |
| A | `openspec/changes/chg-2026-009-dayu200-partition-decode/evidence/runs/TASK-PD-001/r2-fresh-attempt-2026-07-19.md` | `6c991ab8f00803378c92a93fdc0eb37857af06c4` | `already-in-main`; immutable blocked attempt, referenced not copied or reclassified |
| M | `openspec/changes/chg-2026-009-dayu200-partition-decode/tasks.md` | `281180824c53901c0f3cca088f3c8ce4c16b2690` | `already-in-main`; authoritative blocked status, not edited by this implementation PR |

## Runtime reachability disposition

### HDC and process boundary

- A declaration scan found no `public`/`open` command, command runner, process lifecycle executor,
  lifecycle executor protocol, dispatch lease, raw server observation, durable lifecycle store, or
  lifecycle use-case type. The concrete types are `internal` or `package`; the command carrying
  arbitrary HDC arguments is module-internal.
- The App imports only `ArkDeckCore`, `ArkDeckWorkflows`, Combine, SwiftUI, and
  UniformTypeIdentifiers. A direct scan found no Process request/executor, HDC command/executor,
  Supervisor, `argv`, `posix_spawn`, or OpenHarmony/Process/Storage import in the two App HDC
  composition files.
- The public Workflows protocol carries presentation actions and a selected URL but no executable
  request, argv, lease, Supervisor, audit store, or process capability. Its normal provider is
  private; the UI fixture provider reports `lifecycleDispatchIsProductionComposed == false` and
  its dispatch method cannot reach a child.
- `FoundationProcessExecutor` remains the generic Process port previously approved by M1-002. It
  does not itself grant HDC authority, is not imported by the App, and the HDC identity-bound path
  reaches it only through the package-owned one-shot atomic launch gate and durable authorization.
- A source scan found no shell executable/API and no global `ProcessInfo.environment` write in the
  consolidated production surface. Endpoint environment is a child-request overlay.

### PD decoder boundary

- `decode.py` accepts a caller-owned integer descriptor, performs `fstat`, regular-file and
  `O_RDONLY` checks before the first read, duplicates/revalidates the descriptor, and reads archive
  bytes through `os.fdopen`; it has no archive-path fallback.
- `broker_entry.py` receives the integer fd in-process. Its path opens are limited to the governed
  inventory/output set, not archive acquisition.
- The signed NSOpenPanel broker, build script, platform collector, and PD evidence publisher were
  not executed. No old PD evidence was copied, regenerated, or reclassified.

## Dispatch and side-effect counters

| Counter | TASK-RLC-001 result | Basis |
| --- | --- | --- |
| installed real HDC child dispatch | `0` | no run command invoked `hdc`; HDC contracts selected `ArkDeckFakeHDCFixture` by explicit path |
| real device dispatch | `0` | no device identity, connect key, device node, HDC target, or device API was supplied |
| non-loopback network connect/bind | `0` | tests used temporary files and an ephemeral loopback listener only; a non-loopback endpoint string was passed only to the local fake argv logger |
| automatic server lifecycle dispatch | `0` | external/unknown automatic-failure contract asserts no lifecycle audit/dispatch; all lifecycle child vectors require an explicit preview, confirmation, durable intent, and package lease |
| subserver mutation dispatch | `0` | subserver contract records only fixed `checkserver`; `spawn-sub`/`killall-sub` are absent |
| device-migration dispatch | `0` | no registered/public device-migration command or task input was reachable |
| PD interactive collector invocation | `0` | no broker/build/collector/PD evidence command was run |

Some HDC contracts intentionally launch the repository fake child after an explicit, durable
confirmation to verify audit/outcome/reconciliation. Those local fake invocations are neither
automatic nor real-HDC/device/network dispatch and are not counted as source-task platform or
hardware evidence.

## Unresolved source acceptance debt

### TASK-M1-006 remains `blocked`

The entire source-task completion gate remains authoritative and non-done, including
`AC-HDC-001-01`, `AC-HDC-001-02`, `AC-HDC-002-01`, `AC-HDC-003-01`, `AC-HDC-003-02`,
`AC-HDC-004-01`, `AC-HDC-005-01`, `AC-HDC-006-01`, `AC-HDC-007-01`, `AC-HDC-007-02`,
`AC-HDC-008-01`, `AC-HDC-009-01`, `AC-HDC-010-01`, `AC-HDC-010-02`, `AC-HDC-010-03`,
`PORT-PROCESS-001`, `PORT-FILE-ACCESS-001`, `PORT-TOOL-TRUST-001`,
`PORT-DEVICE-ACCESS-001`, and `MAC-M1-HDC-001`. Existing contract passes are not promoted to
source-task completion. The verified integration profile still lacks required production
identity/generation, selected-device authorization/binding, key-access, and subserver probe
families; the current signed Sandbox XCUITest still lacks a passing Developer Mode environment.

### TASK-PD-001 remains `blocked`

`DECODE-DAYU200-PARTITION-001`, `DECODE-DAYU200-INPUT-BOUNDARY-001`, and
`DECODE-DAYU200-RECONCILE-001` still require same-revision fresh evidence. The locked host did not
complete NSOpenPanel/PowerBox selection, and the DEFLATE sliding-history AC boundary still needs a
maintainer-approved clarification/revision. TASK-RLC-001 makes no codec decision and supplies no
PD pass result.

## Consumers and scheduling

- TASK-RLC-001 has no source-task completion dependency under the approved change.
- `TASK-M1-007` still depends on M1-006; `TASK-M1-008` still depends on M1-007.
- `TASK-M0B-002` and `TASK-UD-001` still depend on M1-006.
- `TASK-FA-001` still depends on PD-001 evidence.
- No consumer task file is modified by the TASK-RLC-001 implementation PR. A textual `ready`
  label on M1-007/M1-008 does not override their unsatisfied dependency and grants no execution
  authority.

## Verification and rollback

The exact commands and binary RLC acceptance conclusions are recorded in
`evidence/runs/TASK-RLC-001/run.md`. No Swift/product/PD source delta was required: every fixed
source blob was already in main and passed the change-local fail-closed audit.

The implementation rollback point is the clean execution base
`840e8306e0f8539072c3931384a21a80269d9027`. Reverting the eventual TASK-RLC-001 implementation
merge removes only this consolidation ledger/run and its task-status draft. It does not delete or
rewrite the independently reviewed M1/PD commits or their source evidence. That preservation is
intentional and is part of `RLC-AUDIT-ROLLBACK-001`.

No secret, private key, archive locator, device identifier, raw sensitive Artifact, or local
result-bundle path is recorded here.
