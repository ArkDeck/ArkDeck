# Verification — CHG-2026-068

> Change:CHG-2026-068-lane-plan-preview@r1
> Status:planned；proposal merge 只批准 scope，不代表实现或验收通过

## Environment

- macOS 26 / Xcode 26.6 / Swift 6.3；`swift test --package-path
  Packages/ArkDeckKit --parallel` 全量 + `build-for-testing`。
- LPP-AC-3 需台架：已组合 lane 的 agentd + 曾导入过基线 bundle 的
  arkforged store + 绑定的 DAYU200（normal 模式即可——与执行前置一致）。
  CI 无 daemon 时该用例 `XCTSkip`，不计通过。

## Acceptance matrix

| AC ID | Verification method | Expected result |
| --- | --- | --- |
| LPP-AC-1 只读三调用 | fake lane 客户端记录调用序列 | 预览恰好调用 {inspectArtifact, discoverDevices, materializePlan}；零 importArtifact、零 startExecution、零 permit 相关调用；daemon store 与 journal 零新增痕迹 |
| LPP-AC-2 四态诚实映射 | 契约测试 | inspect 未命中→`bundleNotInLaneStore`；观察选择失败→`deviceNotObserved` 带原因；assessment→`planNotExecutable` 带 availability/reason/unknowns；成功→`available` 带 planID/planSHA256/公共步数/观察模式；agentd 侧 lane 未组合→typed「未配置」而非 internalError |
| LPP-AC-3 预览=执行同源（env-gated） | 真 daemon 对拍 | 同一 daemon 进程、同一 bundle 与绑定下：`preview.planSHA256` == 随后 job 物化并被 permit 锚定的 `planSHA256`；无 daemon 时 SKIP 并如实记录 |
| LPP-AC-4 UI 与全量回归 | `swift test` + build-for-testing + UI 契约 | 预览异步、评审渲染不被阻塞；既有 accessibility 身份零改；全量绿 |
| LPP-AC-5 XPC 面收口 | 契约测试 + 评审 | `flash.lanePlanPreview` 在 `AgentXPCContract` 白名单内；参数校验 fail-closed（缺 targetId/profileReference/archiveSha256 或 profile 不识别→invalidParams）；未采用目标→notFound |

## 不在本次验收内

- 首次镜像的预导入（评审前把 bundle 流进 daemon store）——代价与收益
  不成比（首刷后 CAS 留存即可预览）；若未来需要，另立 change 连带
  agentd 导入流的 lease 复用一起设计。
- daemon store 的配额/GC 策略变化（当前无 GC 调用方是预览可用性的
  前提事实，若 ArkForge 侧引入 GC，本 change 的 `bundleNotInLaneStore`
  文案已如实覆盖该情形）。
- 跨 daemon 代次/设备重插拔后的摘要等值承诺（执行物化为准，permit 锚定）。
