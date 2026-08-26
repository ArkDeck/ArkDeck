# ArkDeck Overview 重设计（记录优先）

> Status：draft v1.0（design input，非 normative）
> Date：2026-08-25
> Golden Journey：GJ-1 Device Observe、GJ-2 HAP Debug、GJ-5 Bounded AI Debug Loop
> 候选稿：[`overview-redesign.html`](overview-redesign.html)（日常态 / 「再来一次」确认面 / 空态）
> 行为事实源：Catalog、Runtime contracts 与 accepted specs；本文只定义产品信息架构与交互。
> 未发布的 operation 与未探测的能力在产品中必须分别显示 unavailable 与未探测，不得互相顶替。
> 与规格的关系：[`macos-ux-interaction-spec.md`](macos-ux-interaction-spec.md) §5.1 与
> `openspec/specs/desktop-ux-observability/spec.md` 是 normative 的 HOW；本文是候选稿，不替代
> 规格。两者不一致时以规格为准；§6 列出必须由维护者裁决的冲突。

## 0. 决策摘要

Overview 从「HDC 工具链诊断报告」改为「**这台设备上跑过什么、现在能做什么、怎么接着做**」。

三条骨架：

1. **调试线（thread）是「继续」的单位。** 同一条线上的运行归成一张卡，卡头是 operation
   reference、目标、binding revision、运行次数与时间跨度。**「调试线」不是 Runtime 的
   `sessionID`**——后者是每个 Job 独占的存储身份，见 §5.2。
2. **每一行都是可续的，且诚实。** `succeeded` 给「打开产物」+「再来一次」；`failed` /
   `cancelled` 只给「再来一次」；来源运行没有上报 typed inputs 时「再来一次」置灰并写明原因，
   不用默认值假装是「同样的参数」。
3. **效果分级决定「继续」的形态。** `readOnly` 直接预填；`deviceMutation` / `destructive`
   每次重新走授权闸；外部效果未知的 `destructive` 永不重放，只给恢复流程。

工具链事实（client / server / daemon version、endpoint、hash、ownership、自动调度计数）压成
底部一行；出问题时以 blocker 形式浮到记录顶部，不再常驻主视线。

需要人处理的运行**不另开横幅**：它所属的调试线卡钉在记录最上面并加 warn 边框。记录是唯一的一处，
不存在「横幅一套、列表另一套」的两份真相。

## 1. 现状诊断

当前 Overview 由 [`HDCStatusView`](../../ArkDeckApp/Features/HDC/HDCStatusView.swift) 渲染，内容为
一条四格状态带、四个 section（Server & Toolchain / Capabilities / Selected Device & Channel /
Needs Attention）与折叠的 Advanced Diagnostics。定位问题有五条：

1. **它是一份 doctor 报告，不是工作区。** 全部字段回答同一个问题——HDC 工具链是否健康。这是
   装机时问一次、坏了才问第二次的问题。
2. **展示的是宿主管道，不是用户的工作。** `clientVersion` / `daemonVersion` / `hash` /
   `ownershipBasis` / `autoSubserverDispatches` 是传输层的自证；「上一次跑了什么、产物在哪、
   下一步做什么」一条都没有。
3. **零可操作性，而它是默认落地页。** 未知 scene-storage 值 fallback 到 overview
   （[`ArkDeckApp.swift:297`](../../ArkDeckApp/App/ArkDeckApp.swift)），初值同样是 overview。
   健康时整页没有一个可点的东西；唯一可行动的 Needs Attention 位于两栏布局的右下角。
4. **有状态、没有后果。** 能力矩阵给出 `可用 / 受限 / 不可用 / 无法确认` 四档形容词，但不说明
   「所以现在不能抓 Trace」。这是「没测到 ≠ 测到的值」那族缺陷的 UI 版本。
5. **能力矩阵绑的是 `targets.first`。** 取列表首项；多设备时它描述的是一台任意设备，用户
   既看不出是哪台也选不了。**已修**：provider 现在接收显式 target，多台已接管时拒绝并报出
   候选，由 §3.1 的设备条提供选择（见
   [`OverviewCapabilityApplicationFacade.swift`](../../Packages/ArkDeckKit/Sources/ArkDeckWorkflows/OverviewCapabilityApplicationFacade.swift)）。

## 2. 重新定位

Overview 按优先级回答三个问题：

| 优先级 | 问题 | 承载 |
| --- | --- | --- |
| 1 | 跑过什么，怎么接着做 | 按调试线分组的运行记录 + 每行的续做入口 |
| 2 | 这台设备现在能做什么 | 动作卡（能力矩阵翻成后果，带效果分级） |
| 3 | 什么挡着我 | 钉在记录顶部的 warn 调试线卡 |
| — | 工具链是否健康 | 底部一行；异常时升格为 blocker |

## 3. 信息架构

三态都以 1180×760 的完整窗口绘制在 [`overview-redesign.html`](overview-redesign.html) 中。

### 3.1 日常态

自上而下四块：

1. **设备条** — 本页自己的显式 target 选择（不是 `targets.first`，也不暗中继承 sidebar 选中行，
   见 spec §5.2），加一行事实：授权与接管状态、机型、固件、传输、connect key、binding revision。
2. **开始新的一次** — 五张动作卡：抓 UI Dump、抓 Trace、调试 HAP、刷机、真机操作。每张给出
   名称、可用性、效果分级 badge 与 operation reference。未探测的写「未探测」，不写「不可用」。
3. **最近的工作** — 按调试线分组的运行记录，本页主体。线卡头右侧是「继续这条线」；每行是
   `状态 · Job ID · 操作 · 效果 · 时间 · 结果或产物 · 续做入口`。
4. **工具链一行** — 折叠行 + 「查看完整诊断 ›」。

### 3.2 「再来一次」确认面

sheet，是「方便继续」真正发生的地方，四段：

1. **核对** — 来源运行与终态、目标与 binding revision 是否与来源一致、效果分级、catalog digest
   是否一致。新运行继承来源运行的调试线。
2. **不一致时明说** — 候选稿故意画成 catalog digest 已变化的情形：参数照旧预填，但明确写出
   「这不是同一次运行的重复，结论不可直接沿用」。
3. **参数对照** — 来源运行上报的 typed inputs 与本次预填值逐项并列。
4. **出口** — 主按钮是「在 Trace 工作区打开并预填」，不是「立即执行」。Runtime history 面是
   只读的（`RuntimeHistoryApplicationProviding` 明确没有 submit / run / cancel / adopt / import），
   提交必须回到对应工作区发生。

来源运行未上报 typed inputs 时这一面不出现，对应行的「再来一次」置灰。

### 3.3 空态

不摆演示行，说清记录里将会有什么：

- **每次运行** — 操作与版本、精确目标与 binding revision、上报的 typed inputs、实际执行的步骤、
  终态与失败分类；
- **每件产物** — 名称、角色、字节数、SHA-256、隐私级别、来源运行；导出前仍需确认；
- **每条调试线** — 把同一条线上的运行串起来，之后可从其中任意一次接着做。

## 4. 必须画出的语义

以下几条是本页的存在理由，画错即画反：

1. **未探测 ≠ 不可用。** probe failed / unrecognized 是「未探测 / 无法确认」；只有 Catalog 明确
   声明 unavailable 才是「不可用」。ArkDeck 不从「没探测到」推断「没有」。
2. **参数没上报就不承诺重放。** `parametersWereReported` 为假时不得进入确认面，也不得用默认值
   补齐后声称是同一组参数。
3. **效果分级不因「继续」而降级。** 从记录里发起的续做与从工作区新发起的完全同权：
   `deviceMutation` / `destructive` 每次重新 materialize plan 并走授权闸。
4. **未知外部效果的 destructive 永不重放。** 该行不提供任何续做入口，只提供恢复流程；原 Job 的
   unknown outcome 保持不变，不得被投影成 succeeded。
5. **「继续」不等于「执行」。** Overview 只能预填并跳转，提交在工作区完成。
6. **调试线不携带任何权限。** 它是展示与审计标注，不参与准入、capability、plan
   materialization、存储布局或审计身份；伪造或改写它不能改变任何一次执行的效果。

## 5. 数据来源与落地代价

### 5.1 已有生产事实

记录所需的字段绝大多数已经存在于
[`RuntimeHistoryApplicationFacade`](../../Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeHistoryApplicationFacade.swift)：

- `RuntimeJobSummaryPresentation`：`sessionID`、`operationReference`、`targetID`、`state`、
  `waitingForHuman`、`outcomeUnknown`、`outstandingResidueCount`、`executionMode`、`actualEffect`
  与三个时间戳；
- `RuntimeJobEvidencePresentation`：`parameters`、`parametersWereReported`、`catalogDigest`、
  `bindingRevision`、`actualStepKinds`、`blockers`、`observedModel` / `observedFirmware`；
- `RuntimeArtifactPresentation`：`name`、`role`、`byteCount`、`sha256`、`privacy`、`status`、
  `sourceOperation`；
- `RuntimeJobCorrelationPresentation`：把一个 Job 与其 Artifact 清单绑在一起。

能力四项来自 `OverviewCapabilityApplicationFacade`（`hidumper` / `hitrace` / `bytrace` /
RockUSB Flash）；效果分级来自 Catalog（`capture.diagnostics@1` = `readOnly`、`debug.hap@1` =
`deviceMutation`、`flash.full-restore@1` = `destructive`；Flash 身份一律走
`ArkForgeFlashOperation` 的规范策略，不硬编码别名）。这些都不需要新 operation、新 provider、
新 integration/device profile，也不改 destructive 准入策略，因此按 `AGENTS.md` 的四类清单不需要
OpenSpec change。

### 5.2 唯一前置：调试线需要一个新的、不带权限的分组键

**不能复用 `sessionID`。** 它看起来像分组键，其实是每个 Job 独占的存储身份：

- `RuntimeJobRecord.sessionID` 是计算属性 `"session-\(jobID)"`，一个 Job 一个；
- `SessionLayout` 用它当磁盘目录名：`<sessionsRoot>/<yyyy>/<MM>/<sessionID>/`，
  `createSession` 遇到已存在的目录直接拒绝；
- `SessionManifest` 与 `SessionAudit` 把 `sessionID + jobID` 当成成对身份逐条校验，
  journal 每个事件也带着它。

把它改成调用方可传、可共享，会同时撞上目录唯一性和 manifest/audit 身份两条不变量。

**正确的载体是 `clientContext.provenance`。** `RuntimeClientContext` 已经在请求文档里，
注释写明「Display/audit annotations only. The runtime never derives authority, scope or
identity from provenance entries.」，且已有长度与条数校验。五个工作区 facade 现在都已经在传
`clientContext(clientName:)`，只是没传 `provenance`——仓内目前没有任何调用方使用该字段。

因此调试线落在保留键 `arkdeck.threadId` 上：

1. `RuntimeClientContext` 增加受校验的 `threadID` 存取（闭集字符集，非法值在请求校验期
   fail closed）；
2. 无需改动任何持久化 schema——`RuntimeJobRecord` 本来就整份持久化 `request`；
3. `RuntimeJobStatus`、daemon 的 `job.status` 投影与 `RuntimeJobSummaryPresentation`
   各增加一个只读 `threadID`；
4. 五个工作区 facade 在提交时带上调试线：v1 按「同一工作区 + 同一 target」保持同一条线，
   「继续这条线 / 再来一次」沿用来源运行的那条。

这条路径不新增 operation、provider、integration/device profile，不改授权语义，也不动
`sessionID` 与存储布局。

### 5.3 与 History 页的分工

Overview 是「最近 + 需处理 + 可续」的切片，History 是全量档案（筛选、详情、timeline、evidence、
correlation、artifact 导出）。两者不做成同一张表的两个副本：Overview 只保留最近若干条调试线，
其余全部走「全部记录 ›」。

## 6. 与现有规格的冲突（待维护者裁决）

`openspec/specs/desktop-ux-observability/spec.md` 要求 Overview 显示 HDC
tool/path/source/version/hash/signature、server endpoint/ownership/health、key strategy、授权、
设备能力与 channel protection evidence 状态。本稿把其中大部分压成底部折叠行并建议移入
Settings → 诊断，与该条不一致。

Agent 不修改已 accepted 的 requirement。两条可选处置，供维护者裁决：

- **保守**：保留 Advanced Diagnostics 折叠区在 Overview 内，字段不迁移，规格不动；
- **迁移**：走 behavior delta，把工具链字段的承载页改到 Settings → 诊断，Overview 只保留一行摘要
  与异常时的 blocker。

在裁决之前，实现按「保守」执行。

## 7. 已落地与仍未做的

已落地（本稿之后的垂直 PR）：调试线分组键与 §5.2 的前置、记录与「再来一次」确认面、
显式 target 选择、以及一条每晚真跑 UI 测试的车道（`scripts/ci/run-ui-tests.sh` 与
`swift-slow-lanes.yml`）——在此之前 CI 只构建 UI 测试、从不执行它。

仍未做的：

- 不改 `openspec/specs/**` 与 `macos-ux-interaction-spec.md`；
- 不新增 operation、provider 或 integration/device profile；
- 不在页面里做 raw shell、任意重放或一键「修复」；
- 不改 `sessionID` 的语义、存储布局或 manifest/audit 身份；
- 记录里的 `outstandingResidueCount`（设备端残留）与 `executionMode`（planOnly / execute）本稿
  暂未上版面，待实际用过之后再决定放行内还是线卡头；
- 多台已接管设备时的设备条 picker 只有契约测试覆盖拒绝路径，UI 测试没有覆盖——现有 fixture
  只有一台已接管 target，加第二台会改动其他套件依赖的固定事实。
