# TASK-LPP-001 — lane 计划预物化端到端（2026-08-19）

## 交付

- `ArkForgeLaneHost.previewPlan(archiveSHA256:profileID:usbTopology:)`：
  既有 `materialize()` 的只读前缀（inspect 探测→discover→观察选择→
  materializePlan），import 分支删除；`ArkForgeLanePlanPreviewOutcome`
  四态 + `previewFailed`。签名刻意不收 binding——预览只需要端口路径，
  connectKey 不进预览路径。
- agentd XPC `flash.lanePlanPreview`：按 `flash.prerequisites` 模式
  fail-closed（targetId/profileReference/64-hex archiveSha256）、
  targetStore 解析、无 previewer 时回 `laneNotComposed` 状态而非错误；
  digest 传入前统一小写。方法入 `AgentXPCContract` 只读白名单
  （其自身的"面即控制面决定"双录守卫同步更新并注明 AC-1 依据）。
- `main.swift` `ComposedLanePlanPreviewer`：以引擎 dispatch 同源的
  provider facts 取 `hdcAliasTopologyServerFactKey` 端口路径；仅当 lane
  与 DeviceProfile id 同组合存在时构建。
- facade `lanePlanPreview` + `FlashLanePlanPreviewPresentation` 六态；
  FlashWorkspace 评审 `.ready` 后异步取数（不阻塞渲染，陈旧结果按
  archive/target 双比对丢弃）；评审摘要新增「ArkForge lane 计划（预物化）」
  行，六态逐字呈现；词条 en/zh-Hans 八条入 `FlashLocalizable.xcstrings`。

## 验证

- LPP-AC-1（只读三调用）：`LanePlanPreviewContractTests`
  `testPreviewIsExactlyThreeReadOnlyCalls` 断言调用序列恰为
  {inspectArtifact, discoverDevices, materializePlan}；store miss 用例断言
  **只有一次 inspect、零 import**；lane host 构造中 performer/job client/
  authority 三个闭包为 `preconditionFailure`——预览若触碰任何执行面直接崩测。
- LPP-AC-2（四态诚实）：miss→`bundleNotInLaneStore`；端口不匹配→
  `deviceNotObserved`（含被绑端口原文）；assessment→`planNotExecutable`
  携 availability/reason/unknowns；handler 侧 `laneNotComposed`/
  `invalidParams`/`notFound` 全部有断言
  （`AgentDaemonContractTests.testLanePlanPreviewIsHonestPerStateAndFailsClosedOnParams`）。
- LPP-AC-4：`swift test` **1456/1456，0 失败，exit 0**（对 #1412 合并后 main 复验）；
  `build-for-testing` **TEST BUILD SUCCEEDED**；既有 accessibility 身份零改
  （新增行走既有 summaryRow 通道）。
- LPP-AC-5：白名单 + 双录守卫 + 参数门断言（同上测试）。
- LPP-AC-3（env-gated 同源对拍）：**本次未跑**——台架当前无常驻组合的
  agentd 会话可占用（用户在用），留待合并后一次真机核对：同 daemon 下
  评审行显示的 `planSHA256` 应等于随后 job permit 锚定值；按验收矩阵
  该用例无 daemon 即如实记录，不计通过。

## 边界复述

预览零导入（首刷前 `bundleNotInLaneStore` 是设计而非缺陷）；执行时重新
物化的摘要为准（permit 锚定）；daemon store 无 GC 调用方是可用性前提，
ArkForge 侧未来引入 GC 时该状态文案已覆盖。
