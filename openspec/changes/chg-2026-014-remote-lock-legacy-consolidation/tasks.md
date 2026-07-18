# Tasks — CHG-2026-014 remote-lock legacy consolidation

> 本 change 只提供一个 implementation PR 单元。来源 Task 的完成状态不是本任务依赖，
> 但 proposal approved、source OID 固定、验证环境可用与 readiness PR 均是执行前置。

## TASK-RLC-001 — 汇入固定锁屏遗留实现并建立非阻塞 ledger

- Status:blocked(change 仍为 proposed；只有 approval-only PR 与后续独立 readiness PR
  均由维护者 review/merge 后才可转 ready)
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
