# Tasks — CHG-2026-065

单任务垂直交付。各 Task 的 `ready` 只有在本 proposal PR 经维护者 review/merge
进入 protected `main` 后生效；合入前不得开始实现 PR。实现 PR 推 `agent/**`
分支由 CI 以 bot 身份开 PR，PR 标题/正文声明本文件的 Task ID，先跑
`scripts/check_pr_paths.py --preflight` 并直接看退出码。

## TASK-RRC-001 — 移除救援组件：构建、CI、打包与守卫反转

- Status:blocked（本 proposal merge 后 ready）
- Golden Journey:GJ-4（不改其行为；只收缩发布 tuple 与工程面）
- Platform:macos
- Requirements:proposal「目标」全部条目
- Acceptance:RRC-AC-1..4（见 verification.md）
- Depends on:本 proposal merge
- 交付内容:
  1. pbxproj：删除 `Embed Rockchip Component` 与 `Embed Rockchip Component
     Metadata` 两个 Copy Files 相位、对应 PBXBuildFile/PBXFileReference、
     `ROCKCHIP_COMPONENT_INPUT`/`ROCKCHIP_COMPONENT_METADATA_ROOT` 构建
     设置与 `RockchipComponent.entitlements` 引用；删除该 entitlements 文件。
  2. CI/脚本：删除 `.github/workflows/rockchip-component.yml`；
     `swift-ci.yml`、`scripts/ci/plan.py`、`scripts/test_agent_pr_workflow.py`
     去掉 `ROCKCHIP_COMPONENT_INPUT` 注入及其断言。
  3. 流水线与注册表：删除 `scripts/rockchip_component/**`（先把与组件无关的
     `manual_ui_flash.swift` 迁至 `scripts/manual_ui_flash/` 并更新
     `ManualUIFlashDriverContractTests` 的路径断言）与
     `openspec/integrations/rockchip/bundled-component/**`。
  4. 守卫反转：`AuthorizationSurfaceGuardContractTests` 中「pbxproj 必须含
     Embed 相位/`ROCKCHIP_COMPONENT_INPUT`」与「packaging 文档必须含
     `Maskrom rescue`」的断言改为断言**不含**相位且文档声明**已退役**；
     全源码 `rkdeveloptool` tripwire 与 `SessionManifest.swift` 豁免保持。
  5. 文档：ADR-0003 顶部横幅由「救援保留」改「组件已随 CHG-2026-065 退役」；
     `docs/release/rockchip-component-{packaging,distribution}.md` 同步
     （义务条款注明随分发停止而卸除）；`.gitignore` 删除 vendor 日志条目。
- Allowed paths:
  - `ArkDeck.xcodeproj/project.pbxproj`
  - `ArkDeckApp/RockchipComponent.entitlements`
  - `.github/workflows/rockchip-component.yml`
  - `.github/workflows/swift-ci.yml`
  - `scripts/ci/plan.py`
  - `scripts/test_agent_pr_workflow.py`
  - `scripts/rockchip_component/**`
  - `scripts/manual_ui_flash/**`
  - `openspec/integrations/rockchip/**`
  - `Packages/ArkDeckKit/Tests/**`
  - `docs/adr/0003-macos-rockchip-tool-execution.md`
  - `docs/release/rockchip-component-packaging.md`
  - `docs/release/rockchip-component-distribution.md`
  - `.gitignore`
  - `openspec/changes/chg-2026-065-retire-maskrom-rescue-component/**`

## TASK-RRC-002 — vendor 时代死代码与误导命名清理

- Status:blocked（依赖 TASK-RRC-001 合入——守卫反转先落，避免 tripwire
  语义在两个 PR 间摇摆）
- Golden Journey:GJ-4（行为不变；删除生产不可达代码与改名）
- Platform:macos
- Requirements:proposal「顺带」条目
- Acceptance:RRC-AC-5..7（见 verification.md）
- Depends on:TASK-RRC-001
- 交付内容:
  1. 删除 `RockchipFlashExecutionStaging.swift`（`wl` 时代逐分区 tar 展开，
     生产零调用）及仅存的 `RockchipFlashExecutionFaultContractTests` 引用；
     同步移除 `RuntimeJobEngine` 里为该 staging 预留的
     `RockchipFlashStagingCapacity` 容量门（arkforged 有自己的空间预检）。
  2. 删除无生产调用方的 `RockchipProductExecutePlanFactPort`
     （`RockchipAuthorizationFacts.swift`）及其 test-only 引用。
  3. 改名去误导：`RockchipFlashExecutionHost` →
     `RockchipDeviceBindingHost`（它是绑定存储 + IOKit 只读探测，不执行
     flash）；`RockchipFlashSessionReconcile` →
     `RockchipLegacyFlashJournalReconcile`（它 reconcile 的是已退役宿主的
     历史 journal；`arkdeck flash reconcile` 入口行为不变）。
  4. 全量 `swift test` 与既有 contract tests 全绿；改名逐引用更新，
     不留 typealias。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`
  - `Packages/ArkDeckKit/Tests/**`
  - `scripts/README.md`（RRC-001 删除 `scripts/rockchip_component/` 后其索引行
    的清理——RRC-001 的 base 授权未列此文件，顺延至此）
  - `openspec/changes/chg-2026-065-retire-maskrom-rescue-component/**`

## 证据留存

每个 Task 的产物（删除清单、`swift test` 摘要、Release 构建的 bundle
清点或 build-for-testing 证明）放 `evidence/runs/TASK-RRC-00x/`，
文件名带日期。
