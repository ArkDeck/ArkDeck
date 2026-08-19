# Tasks — CHG-2026-066

单任务垂直交付。各 Task 的 `ready` 只有在本 proposal PR 经维护者 review/merge
进入 protected `main` 后生效；合入前不得开始实现 PR。实现 PR 推 `agent/**`
分支由 CI 以 bot 身份开 PR，标题声明 Task ID，先跑
`scripts/check_pr_paths.py --preflight` 并直接看退出码。

## TASK-SPT-001 — 分区表单一化：删除 ArkDeck 侧设备地址

- Status:blocked（本 proposal merge 后 ready）
- Golden Journey:GJ-4（行为不变；删除死数据与矛盾声明）
- Platform:macos
- Requirements:proposal 目标 1
- Acceptance:SPT-AC-1..2（见 verification.md）
- Depends on:本 proposal merge
- 交付内容:
  1. `RockchipMappedPartition` 删除 `offsetSectors` 字段、九个 FA-001 钉值、
     `RockchipFlashProfile.swift:136` 的升序自检与「consumed by the native
     typed write plan」注释；类型/文件 doc comment 改写为覆写范围声明语义，
     指明设备地址与写序权威在 arkforged（对设备自身分区表实测）。
  2. `partitionPlan` 请求输入的含义注释改写（覆写范围确认回声；admission
     照旧比对钉定名单——`DeviceProviderAdapters` 校验逻辑零改动）。
  3. 契约测试同步：`Dayu20070035RuntimePlanOnlyContractTests` 等处对
     offsetSectors 钉值的断言移除；分区名单/写序断言保留。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`
  - `Packages/ArkDeckKit/Tests/**`
  - `openspec/changes/chg-2026-066-flash-review-single-truth/**`

## TASK-SPT-002 — 计划模型单一化：评审展示只用运行时事实

- Status:blocked（依赖 TASK-SPT-001 合入——profile 形状先定，展示后改）
- Golden Journey:GJ-4（submit/execute 行为不变；评审内容换成真事实）
- Platform:macos
- Requirements:proposal 目标 2、3
- Acceptance:SPT-AC-3..6（见 verification.md）
- Depends on:TASK-SPT-001
- 交付内容:
  1. 删除 `RockchipFlashPlan`、`RockchipFlashPlanDocument`、
     `makePlan`（九步 WorkflowStep 伪造、`rk-*-wlx-*` id、
     `rockusb.wl-write`、provider 自算 plan/stepSet 摘要）、零消费方的
     `assessOutcome`/`RockchipFlashOutcomeAssessment`；
     `RockchipRockUSBFlashProvider` 类型解散，幸存小类型
     （RockchipProbe*/RockchipPrerequisite*/RockchipFlashExecutionMode/
     RockchipPostFlashVerificationLevel/RockchipFlashProviderError 按需）
     迁 `RockchipFlashReviewTypes.swift`。
  2. `RuntimeJobEngine.stepIsRequested`/`stepSetDigest` 提升 package 可见
     （单一实现，facade 复用，不写第二份）。
  3. `FlashApplicationFacade`：presentation 的步骤区改由
     `flash.dayu200` 的 Catalog descriptor 生成（kind/effect/cancellation/
     delegated 与否照 descriptor 事实）；`stepSetDigestSHA256` 用第 2 条的
     同源函数计算；plan digest 字段改为可选并如实缺席（「提交时物化」），
     job record 展示处照旧显示 engine 物化摘要；「same canonical plan」
     注释按新事实改写。fixture 预览（`preparePlan`）同源换建。
  4. `ArkDeckApp/Features/Flash/`：FlashWorkspaceView/FlashPlanDetailsView
     的步骤明细与摘要行适配新 presentation；accessibility 身份
     （`flash.execute.submit`、`flash.impact.userdata` 等）保持不变。
  5. 全量 `swift test` + `build-for-testing` 全绿；UI 契约测试
     （ManualUIFlashDriver 等）零改身份。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`
  - `ArkDeckApp/Features/Flash/**`
  - `ArkDeckApp/Resources/FlashLocalizable.xcstrings`（评审摘要行的本地化
    词条与 Flash 界面同 change 演进）
  - `Packages/ArkDeckKit/Tests/**`
  - `ArkDeckAppUITests/**`
  - `openspec/changes/chg-2026-066-flash-review-single-truth/**`

## 证据留存

每个 Task 的产物（删除清单、grep 零残留证明、stepSetDigest 与真实 job
record 的比对、`swift test`/build-for-testing 摘要）放
`evidence/runs/TASK-SPT-00x/`，文件名带日期。
