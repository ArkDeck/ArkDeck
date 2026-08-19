# Tasks — CHG-2026-068

单任务垂直交付。Task 的 `ready` 只有在本 proposal PR 经维护者 review/merge
进入 protected `main` 后生效；合入前不得开始实现 PR。实现 PR 推 `agent/**`
分支由 CI 以 bot 身份开 PR，标题声明 Task ID，先跑
`scripts/check_pr_paths.py --preflight` 并直接看退出码。

## TASK-LPP-001 — lane 计划预物化：只读预览端到端

- Status:done（2026-08-19;#1415 合并——预览端到端落地,契约测试钉只读三调用
  与全部状态;LPP-AC-3 的 env-gated 真机对拍**尚欠一次台架通过**,在此之前
  本 change 不归档;证据 `evidence/runs/TASK-LPP-001/run.md`）
- Golden Journey:GJ-4（不改 submit/execute 行为；评审新增只读事实）
- Platform:macos
- Requirements:proposal「目标」「诚实边界」全部条目
- Acceptance:LPP-AC-1..5（见 verification.md）
- Depends on:本 proposal merge
- 交付内容:
  1. `ArkForgeLaneHost.previewPlan(archiveSHA256:profileID:binding:)`：
     镜像既有 `materialize()` 的 inspect→discover(观察选择复用
     `ArkForgeObservationSelection`)→materializePlan 序列，**去掉 import
     分支**（inspect 未命中→`bundleNotInLaneStore`）；四态结果类型
     （available/bundleNotInLaneStore/deviceNotObserved/planNotExecutable
     含 assessment 理由）；任何失败不抛出到调用方之外、不产生持久痕迹。
  2. agentd XPC 方法 `flash.lanePlanPreview`（params:`targetId`/
     `profileReference`/`archiveSha256`）：按 `flash.prerequisites` 模式
     fail-closed 校验、`targetStore.find` 取目标、以与
     `dispatchThroughArkForge` 相同来源构造 `ArkForgeLaneDeviceBinding`、
     经注入的 previewer 调 lane；方法名入
     `ArkDeckCore/AgentXPCContract.swift` 白名单；lane 未组合时回
     「preview 不可用：lane 未配置」而非错误堆栈。
  3. facade：评审 `.ready` 后异步取预览（不阻塞渲染）；结果类型进
     presentation 侧型（独立 state，不改 `FlashExactPlanPresentation`
     已钉字段）。
  4. UI：评审摘要区新增「ArkForge lane 计划」行——available 显示
     `planSHA256`（等宽、可拷贝）+「预物化预览；执行时重新物化并由
     permit 锚定」注记；其余三态逐字呈现原因。新增 accessibility 身份
     不改动既有身份；词条 en/zh-Hans 进 `FlashLocalizable.xcstrings`。
  5. 契约测试：fake lane 客户端断言预览调用集恰为
     {inspect, discover, materializePlan}（LPP-AC-1）与四态映射
     （LPP-AC-2）；env-gated 真 daemon 对拍（LPP-AC-3，沿
     `ArkForgeLiveDaemonContractTests` 模式，无 daemon 即 XCTSkip）；
     全量 `swift test` + `build-for-testing` 全绿（LPP-AC-4）。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/AgentXPCContract.swift`
  - `ArkDeckApp/Features/Flash/**`
  - `ArkDeckApp/Resources/FlashLocalizable.xcstrings`
  - `Packages/ArkDeckKit/Tests/**`
  - `openspec/changes/chg-2026-068-lane-plan-preview/**`

## 证据留存

产物（调用集断言、四态契约、env-gated 对拍记录或 SKIP 说明、
`swift test`/build-for-testing 摘要）放 `evidence/runs/TASK-LPP-001/`，
文件名带日期。
