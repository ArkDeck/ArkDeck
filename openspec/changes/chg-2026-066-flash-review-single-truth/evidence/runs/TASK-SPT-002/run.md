# TASK-SPT-002 — 计划模型单一化（2026-08-19）

## 变更

- 删除 `RockchipRockUSBFlashProvider.swift` 整文件（667 行）：`makePlan` 的
  九步 `rk-<nonce>-wlx-*` 伪造、provider 自算 plan/stepSet 摘要、
  `RockchipFlashPlan`/`RockchipFlashPlanDocument`、零消费方的
  `assessOutcome`/recovery guide/probe verdict/prerequisite gate。幸存词汇
  （`RockchipProbeEvidence` 常量、`RockchipFlashExecutionMode`、
  `RockchipPrerequisiteObservation`）迁入 `RockchipFlashReviewTypes.swift`。
- `RuntimeJobEngine.stepSetDigest` 由 private 提升为 internal（同模块单一实现，
  facade 复用；`stepIsRequested` 本就 internal static）。
- `FlashPlanPresentationBuilder`：新增 `reviewSelectionInputs`
  （`postFlashVerification=full`，与 FlashWorkspace 提交形状一致）与
  `reviewSteps(mode:)`——目录 descriptor 经引擎同一筛选规则出步骤序列，
  同一算法出 stepSet 摘要；`presentation` 改签名（catalog 步骤 + 真摘要 +
  `planDigestSHA256: String?` 如实为 nil）；fixture 预览同源换建；
  「same canonical plan」注释按新事实重写。步骤的 argumentSummary 标注
  engine host / ArkForge lane (delegated)（来自引擎自己的委托步骤集）。
- UI：`flash.plan.digest` 行在提交前显示本地化的「提交时由 Runtime 物化」
  （新词条 `flash.plan.digest.materializedAtSubmission`，en/zh-Hans）；
  accessibility 身份零改。
- 引擎计划参数里最后一处 vendor 命令词汇 `rockusb.wl-write` 改为
  `arkforge.write-partitions`（journal 标签；无测试/读取方钉旧值。注意：
  未消费的既有 RuntimeCapability 因 exactPlanDigest 随编码变化会在新构建下
  失配拒绝——重新预约即可，属自愈）。
- 测试：provider 契约文件替换为 `RockchipFlashReviewContractTests`
  （保留 profile 钉值 + 三个 gzip/tar 读取器契约）；facade 契约测试改写为
  同源事实断言（含 stepSet 摘要与台架 job record 常量
  `c1ab01f8…5e0b12` 逐字比对——SPT-AC-4 的对拍）；Dayu 组合 helper 收敛为
  describe→forBuild→validate，全部 fail-closed 反例保留。

## 验证

- `swift test --package-path Packages/ArkDeckKit --parallel`：**1448/1448，
  0 失败，exit 0**（APIBaseline 首跑失败均为本地 `.build` 缓存引用已删文件，
  清缓存后通过——外部消费者基线不引用被删类型与改可选的字段）。
- `xcodebuild … build-for-testing`：**TEST BUILD SUCCEEDED**（含 UI 与词条）。
- SPT-AC-3 残留 grep（Sources+App）：`RockchipFlashPlan`/`wlx`/`makePlan(`/
  `assessOutcome`/`"rk-` 全零；`rockusb.wl-write` 与
  `RockchipRockUSBFlashProvider` 仅存于历史注释各一处。
- SPT-AC-4/5 由新契约测试常驻守卫；`scripts/check_sdd.py` 0 error。
