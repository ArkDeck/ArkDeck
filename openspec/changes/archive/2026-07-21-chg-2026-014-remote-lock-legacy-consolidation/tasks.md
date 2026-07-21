# Tasks — CHG-2026-014 remote-lock legacy consolidation

> 本 change 只提供一个 implementation PR 单元。来源 Task 的完成状态不是本任务依赖，
> 但 proposal approved、source OID 固定、验证环境可用与 readiness PR 均是执行前置。

## TASK-RLC-001 — 汇入固定锁屏遗留实现并建立非阻塞 ledger

- Status:done（TASK-RLC-001 implementation PR #110 已由维护者合入 `main`
  `f7c334857ae5735077254ccbdf3dafac8c8ad83b`；独立 M1-006/PD-001 consolidation
  disposition PR #112 已合入 `main` `e9689e54d12d8e9baa21c7d7747c2fff9be15be4`；
  四项 RLC Test 均有同一 implementation revision 的二值 PASS evidence。本状态草案仅在
  维护者 review/merge 后生效，不构成 CHG-2026-014 `verified` 或任何来源 Task 完成）
- Completion evidence:`evidence/legacy-import-manifest.md`、
  `evidence/runs/TASK-RLC-001/run.md`。source tasks remain non-done and all unresolved gates
  remain explicit; no conformance/hardware/support/release claim。
- Readiness review（2026-07-19；不执行 TASK-RLC-001、不产生 implementation evidence）：
  - Change gate:satisfied。CHG-2026-014 已由维护者经 PR #107 批准并合入 `main`
    `4b4e0b37c82bf03ccfa1317058f06834d68273f5`；Core baseline 仍为 `CORE-2.0.0`，
    本 readiness 不修改 Requirement、AC、contract、schema、baseline 或 verification plan。
  - Source identity gate:satisfied。三个 proposal-pinned OID 均可读取；M1-006 source
    `ae708518ce6cc8bbd5ad39943d948b2d81209f03` 仍由 GitHub PR #105 的只读 head ref
    精确定位，并与已合入 squash commit
    `21c2e218973c301e7ac6c43659d8918828f2c39e` 具有相同 parent
    `0db5f22c0878d059697d32a3022fa260c83e2798`、相同 tree
    `eb3df103b87c898edb24d3143cbd165244e9abea` 和零 tree diff；PD-001 implementation
    `0076e44dcaed45605c1cccefc093a82b246a4ef5` 与 blocked record
    `0db5f22c0878d059697d32a3022fa260c83e2798` 均为当前 `main` 祖先。
  - Source-state/dependency gate:satisfied for this task only。权威 `main` 中
    `TASK-M1-006` 与 `TASK-PD-001` 均保持 `blocked`/非 `done`，其 blocker 与 AC debt
    不变；source completion 按已批准范围不是本任务依赖。M1-007/M1-008/M0B-002/
    UD-001/FA-001 的既有 dependency 未改写；其中任何未满足原依赖的任务仍不得执行，
    本 readiness 不为 consumer 铸造 authority。
  - Environment gate:satisfied。clean `main` 上可用 Swift 6.3.3、`swift-format` 6.3.0、
    Xcode 26.6（17F113）与 CPython 3.14.6；仓库 fake-HDC executable 与 server fixture
    在场。`swift test --package-path Packages/ArkDeckKit --filter
    HDCSupervisorContractTests` 在 headless shell 通过 36 tests / 0 failures；编译仅有三个
    既有 redundant-`await` warning。本机存在已安装真实 `hdc`，但它是本任务 forbidden/
    unused 输入；实现与验证必须显式绑定仓库 fake executable，发现真实 HDC、真实设备、
    GUI、非 loopback 网络或系统授权需求即 fail closed。
  - Review boundary:本 PR 只草拟 `blocked→ready` 与上述可复查审计，不导入/修改源码，
    不写 TASK-RLC-001 run/manifest，不更新来源 Task，不改变 conformance、hardware、
    support 或 release claim；实现仍须在后续独立 TASK-RLC-001 PR 闭环。
- Objective:以 proposal 固定的三个 commit OID 为输入，在不改变任何 Requirement/AC 的
  前提下，将可安全合并的 M1-006 遗留实现收敛到 main，并把 M1-006/PD-001 的交互验证债
  统一登记；完成只代表 headless fail-closed integration，不代表来源 Task 完成。
- Requirements/AC:`RLC-LEGACY-IMPORT-001`、`RLC-FAIL-CLOSED-001`、
  `RLC-NONBLOCKING-001`、`RLC-AUDIT-ROLLBACK-001`。
- Depends on:none for source-task completion；execution depends on CHG-2026-014 approved、完整 OID
  可读取、main clean、headless Swift/Xcode/Python toolchain 可用，以及独立 readiness PR。
- Allowed paths:
  - `ArkDeck.xcodeproj/project.pbxproj`
  - `ArkDeck.xcodeproj/xcshareddata/xcschemes/ArkDeck.xcscheme`
  - `ArkDeckApp/App/ArkDeckApp.swift`
  - `ArkDeckApp/Features/HDC/**`
  - `ArkDeckAppUITests/HDC/**`（只允许编译/静态隔离；本任务不运行 XCUITest）
  - `Packages/ArkDeckKit/Package.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/JobToolchainIntent.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckProcess/**`（仅遗留 atomic launch gate/import）
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCServerLifecycleJournalAdapter.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkDeckContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDCServer/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCSupervisorContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ProcessExecutorContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/JobToolchainIntentContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckFakeHDCFixture/**`
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/tasks.md`（只在独立 governance/
    status PR 追加 consolidation disposition；不得随 implementation PR 混入，不得标 done/verified）
  - `openspec/changes/chg-2026-009-dayu200-partition-decode/tasks.md`（只在独立 governance/
    status PR 追加 consolidation disposition；不得随 implementation PR 混入，不得修改
    blocker/AC 结论）
  - `openspec/changes/chg-2026-014-remote-lock-legacy-consolidation/evidence/**`
  - `openspec/changes/chg-2026-014-remote-lock-legacy-consolidation/tasks.md`（仅本任务状态）
- Read-only inputs:
  - `scripts/partition_decode/**`
  - `openspec/changes/chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-006/**`
  - `openspec/changes/chg-2026-009-dayu200-partition-decode/evidence/runs/TASK-PD-001/**`
    （2026-07-21 archive currency note:CHG-2026-009 已 verified(#175)后归档,本行与上方
    allowed-paths 行的引用现位于
    `openspec/changes/archive/2026-07-21-chg-2026-009-dayu200-partition-decode/**`;
    原文按惯例保留,ledger 所钉 blob OID 不受目录移动影响,字节以 git 历史为证）
- Forbidden paths:`openspec/constitution.md`、`openspec/specs/**`、
  `openspec/contracts/**`、`openspec/baselines/**`、`openspec/integrations/**`、
  `openspec/platforms/**`、`openspec/verification/**`、hardware matrix、其他 change/task
  evidence、任何真实设备/真实 HDC/系统授权状态。
- Risk:high（把 safety-critical HDC/process 遗留实现导入 main；必须默认 fail-closed，且
  consolidation 不能被误读为 AC 通过）
- Hardware required:no
- Required environment:锁屏 macOS headless shell；仓库声明的 Swift/Xcode/Python；仓库 fake
  fixture 与 loopback ephemeral endpoint。不得要求 GUI、Developer Mode、NSOpenPanel、
  PowerBox、真实 HDC、真实设备或网络下载。
- Deliverables:
  - `evidence/legacy-import-manifest.md`：完整 OID、逐文件 disposition/hash、未关闭 AC、
    runtime reachability、测试与 rollback；
  - 可安全进入 main 的 M1-006 遗留实现；不安全文件明确 rejected，不强求全量导入；
  - 独立 governance/status PR 中的原 M1-006/PD-001 consolidation disposition，不把来源
    Task 改为 done、不改变 blocker/AC；
  - `evidence/runs/TASK-RLC-001/run.md`：headless 命令、计数、二值 AC、偏差与风险。
- Verification:
  - `TEST-RLC-LEGACY-IMPORT-001`：完整 OID/parent/path/hash 与实际 diff 精确一致；
  - `TEST-RLC-FAIL-CLOSED-001`：真实 HDC/device/non-loopback/automatic lifecycle dispatch
    count 均为 0；未验证入口不能铸造 authority；
  - `TEST-RLC-NONBLOCKING-001`：source completion 不阻止本任务，但 source AC 与全部
    verification/release gate 保持 pending/blocked；无 consumer 被自动改依赖；
  - `TEST-RLC-AUDIT-ROLLBACK-001`：一个实现 PR 可独立 revert，旧 evidence immutable；
  - Commands:`swift format lint` 变更 Swift 文件；`swift test --package-path
    Packages/ArkDeckKit`；必要的 fake/loopback dedicated tests；`scripts/check-sdd.sh`；
    `git diff --check`；source/public/runtime reachability 静态审计。
- Evidence gate:四个 Test ID 全部 PASS 才能起草本任务 `done`；done 记录必须逐字声明
  “source tasks remain non-done and all unresolved gates remain explicit; no conformance/hardware/
  support/release claim”。
