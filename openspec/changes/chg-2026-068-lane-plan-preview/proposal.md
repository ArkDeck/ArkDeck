---
id: CHG-2026-068-lane-plan-preview
revision: 1
status: proposed
class: integration
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# CHG-2026-068 — Lane 计划预物化：评审屏展示 arkforged 的计划摘要

> **本文件不构成批准。** 本 proposal 经维护者 review/merge 进 protected
> `main` 后，Task 方可开始实现 PR。

## 背景

CHG-2026-066 之后，评审屏展示的每个事实都是运行时钉的那一个——目录步骤、
引擎 stepSet 摘要、诚实缺席的引擎计划摘要。还剩最后一个提交前不可见的
真事实：**lane 计划摘要**（`arkforged` 物化的 23 步设备计划的
`plan_sha256`，permit 的锚）。它今天只在 job 执行中产生。

## 可行性（2026-08-19 逐点实测）

1. **daemon API 全部现成，ArkForge 仓零改动。**
   `inspectArtifact`/`discoverDevices`/`materializePlan` 组合即预览；
   `materializePlan` 无副作用（不铸 permit、不 `startExecution`、不落
   journal job）。public socket 对 materialize 只回 assessment
   （`arkforge-ipc` `may_call` 注释明言），真计划走 controller 连接——
   而 controller 正是 agentd 持有的那条，权界不变。
2. **CAS 按内容寻址且 `artifact_id = sha256`**（`importArtifact` 响应把
   digest hex 同时写进两个字段；`inspectArtifact` 直接把 artifact_id 按
   hex digest 解析）。ArkDeck 用评审里已有的 `archiveSHA256` 即可探测，
   **预览连镜像文件都不用碰**。
3. **归档内容跨 job 留存**：`collect_garbage` 在 arkforged 生产代码中
   零调用方（quota 门仍在）；lane host 本就以「先 inspect 探测、缺了才
   import」跑（`ArkForgeLaneHost.materialize`，注释写明 731 MB 的省法）。
   所以任何刷过一次的 bundle，预览随时可用。
4. **lane 常驻**：`ArkForgeLaneComposition.composeFromEnvironment` 在
   agentd 启动时执行一次，lane host 与 daemon 生命周期随 agentd。

## 目标

评审准备后**异步**取一次 lane 预物化（不阻塞评审渲染），结果四态：

- `available`：`planID` + `planSHA256` + 公共步数 + 观察模式——用户在
  提交前就能看到 permit 将锚定的那份计划身份；
- `bundleNotInLaneStore`：该 bundle 从未进过 daemon store（首次镜像）。
  **不预导入**——为一次预览把 731 MB 流两遍（评审一遍、执行一遍语义上
  多余）不值；文案如实说明「首刷后即可预览」；
- `deviceNotObserved`：绑定目标当前不可观察（附原因）；
- `planNotExecutable`：daemon 给了 assessment（maturity 门/Profile 违例
  等），理由逐字呈现——这本身就是有价值的提交前预警。

## 诚实边界

- 预览是**预物化预览**：同一 daemon 进程、同一输入下，执行时的物化会
  复现同一摘要（env-gated 真机对拍验收 LPP-AC-3）；设备事实漂移（重插拔
  换 topology）或 daemon 换代后，**执行时物化的那份为准**——permit 锚在
  它上，UI 文案写明。
- 预览路径**只读三调用**（inspect/discover/materialize），零 import、
  零 permit、零 startExecution，由契约测试钉死（LPP-AC-1）。

## 影响面

`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/`（`ArkForgeLaneHost.
previewPlan` + facade 异步取数）、`ArkDeckAgentDaemon/`（XPC 方法
`flash.lanePlanPreview`，按 `flash.prerequisites` 模式校验/取绑定/注入
服务）、`ArkDeckCore/AgentXPCContract.swift`（方法白名单）、
`ArkDeckAgentDaemonMain/`（wiring）、`ArkDeckApp/Features/Flash/`（评审
新行 + 词条）。零 Catalog delta、零请求 schema delta、ArkForge 仓零改动。
