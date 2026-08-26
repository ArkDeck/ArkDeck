# ArkDeck Overview 重设计（下一步优先）

> Status：final v1.5（design input，非 normative）
> Date：2026-08-26
> Golden Journey：GJ-1 Device Observe、GJ-2 HAP Debug、GJ-5 Bounded AI Debug Loop
> 交互稿：[`overview-redesign.html`](overview-redesign.html)（日常 / 需处理 / 空态）
> 行为事实源：Catalog、Runtime contracts 与 accepted specs；本文只定义产品信息架构与交互。

## 0. 这版调整了什么

Overview 不再把「设备状态、完整工具链诊断、能力矩阵、运行记录」平铺成同等重要的卡片，而是先回答：

1. **我现在最应该做什么；**
2. **刚刚发生了什么；**
3. **只有排障时，环境细节是什么。**

v1.5 的六个结构变化：

- 顶部状态条和设备条合并，只保留当前在线设备的显式选择、授权/接管状态与一句健康摘要；
- 历史已接管但当前离线的 target 不进入设备下拉，仍只在 History 和既有运行中保留；
- 当前设备下直接显示绑定的远端构建服务器名称、SSH endpoint 与绑定状态；
- 用一张「下一步」主卡承载继续工作、严重 blocker 或第一次运行，不再让提示和记录互相重复；
- 最近运行按调试线只展示最新一次，需要时再展开此前三次；完整档案继续由 History 承载；
- accepted spec 要求的 HDC、server、能力与通道证据仍保留在 Overview，但默认折叠为「运行环境」。

## 1. 现状问题

现有 Overview 已经加入运行记录，但页面仍叠放了新旧两套中心：上半部分是工作记录，下半部分仍是完整
HDC doctor 报告。信息都正确，却产生三个体验问题：

1. **没有明确主次。** 健康、能力、设备、诊断、记录都使用相近的卡片重量，用户要自己判断下一步；
2. **常用信息出现得太晚。** 最近产物和「再次抓取」比 hash、ownership 更常用，却需要穿过大量环境事实；
3. **内容会持续变长。** 投影限制了调试线数量，但没有限制每条线展示的运行数；使用越久 Overview 越像 History。

所以这版不继续“美化更多卡片”，而是先减少默认可见的信息，再统一层级和交互。

## 2. 页面优先级

| 优先级 | 用户问题 | 页面承载 |
| --- | --- | --- |
| 1 | 我现在最该做什么 | 下一步主卡：继续、处理 blocker 或开始第一次运行 |
| 2 | 最近发生了什么 | 每条调试线的最新一次运行，可按需展开 |
| 3 | 设备与远端服务器是否选对 | 合并后的设备与服务器范围条 |
| — | 工具链和通道具体怎样 | 默认折叠的运行环境 |

页面阅读顺序固定为：

`当前设备 → 下一步 → 最近运行 → 运行环境`

## 3. 关键交互

### 3.1 场景切换

交互稿顶部的「日常 / 需处理 / 空态」只是设计评审控制，不进入产品。

- **日常**：显示最近成功的调试线，主动作是查看产物或用来源运行参数打开工作区；
- **需处理**：主卡替换为最高优先级 blocker。示例使用 destructive outcome unknown，明确禁止重放；
- **空态**：不再解释 Runtime 的所有字段，只引导从左侧工作流开始，记录和产物会自动保存。

### 3.2 设备与远端服务器作用域

Overview 使用自己的 target picker，不使用 `targets.first`，也不暗中继承其他工作区的临时选择。
当前设备下方同时显示绑定的远端构建服务器：显示名称、`username@host:port` 与「已绑定」，不另起卡片。
切换设备后同步更新设备名、target / binding 与服务器展示；真正提交时仍由对应工作区重新核对 fresh facts。

设备候选只来自 App 共享的实时 `device.candidates`：必须是当前 `Connected`、观察未过期、已经接管且带
binding revision。`target.list` 中的历史离线 target 不进入下拉。当前选择掉线后，若只剩一台在线设备则
自动切换；剩余零台或多台时回到「暂无在线设备 / 请选择」，不得继续展示离线目标的能力或服务器绑定。

这里的「远端服务器」是 Settings 中已验证的 SSH Remote Build Source；折叠诊断中的
`127.0.0.1:8710` 是本地 HDC server，两者必须使用不同标题，不得合并成一个模糊的“服务器”。

### 3.3 最近运行

Overview 以调试线为继续工作的单位，但每条线默认只显示最新一次运行：

- 成功：显示最重要的产物，并提供「查看」与「再次抓取」；
- 失败/取消：展示简短后果和可恢复动作；
- `parametersWereReported == false`：写明不能提供相同参数，不用默认值补齐；
- 需要上下文时，用户可以展开此前三次；更早的内容走 History。

这样保留“串起同一问题”的价值，同时给 Overview 一个稳定高度上限。

### 3.4 再次抓取确认面

确认面分三层：

1. 来源运行、target / binding、效果分级和 Catalog digest；
2. 来源 typed inputs 与本次预填值的逐项对照；
3. 「打开 Trace 并预填」出口。

如果 Catalog digest 已变化，参数仍可预填，但必须说明旧结论不能直接沿用。这个动作不是 Runtime replay，
也不会在 Overview 立即执行。

### 3.5 outcome unknown 恢复面

未知 destructive outcome 的主卡不提供「重试」「继续」或确认按钮，只解释：

- 原请求不会重放；
- Runtime 必须先从 durable facts 界定可能 effects；
- 只有 published complete-overwrite contract 完整覆盖时，才可能建立独立恢复；
- 身份、binding、Artifact 或工具事实漂移时保持停止。

「查看恢复证据」只去 History 查看证据，不启动恢复。

### 3.6 运行环境

`运行环境` 使用原生 disclosure，默认只显示：

`HDC 正常 · 通道已保护 · 0 个问题`

展开后保留 accepted spec 当前要求的字段：tool/path/source/version/hash/signature、server endpoint/
ownership/health、key strategy、授权、设备能力与 channel protection evidence。异常数量会出现在折叠摘要，
严重 blocker 还会升格到顶部主卡。

## 4. 视觉原则

- **一个页面只保留一个高视觉重量区域。** 主卡用于下一步，其余区域使用低边框、低阴影；
- **少用状态色。** 蓝色只表示动作，绿色表示确认成功，橙色表示需要判断，红色只用于危险或失败；
- **状态文案说后果。** 使用「只读 · 可用」「修改设备 · 未探测」「覆写设备」，不让用户先翻译 enum；
- **运行数字使用等宽或 tabular 数字。** Job ID、target、binding、时间和大小便于扫描；
- **窄窗口先降栏，不压文字。** 先把 sidebar 收进系统侧栏按钮，再将主卡动作和运行行改成纵向；
- **动效克制。** 只给可点击控件轻微按压反馈，并尊重 `prefers-reduced-motion`。

## 5. 可访问性与键盘路径

交互稿使用原生 `button`、`select`、`details/summary` 与 `dialog`：

- 所有可操作项都有可见 `:focus-visible`；
- dialog 关闭后把焦点还给来源按钮；
- 场景状态、按钮反馈和刷新结果通过 `aria-live` 传达；
- 图标只辅助识别，按钮名称不依赖图标或颜色。

## 6. 必须保持的语义

1. **未探测 ≠ 不可用。** probe failed / unrecognized 只能表达为未探测或无法确认；
2. **参数没上报就不承诺重放。** 不用默认值伪装成来源参数；
3. **继续不会降低效果等级。** `deviceMutation` / `destructive` 仍重新 materialize plan 并走准入；
4. **未知 destructive intent 永不 replay。** 只能进入满足完整证明的 distinct recovery；
5. **Overview 只预填和跳转，不提交 operation；**
6. **调试线是展示和审计标注，不携带 authority，也不改变 sessionID、存储或 Runtime identity。**

## 7. 数据与落地边界

运行、证据、产物和关联字段来自
[`RuntimeHistoryApplicationFacade`](../../Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeHistoryApplicationFacade.swift)；
能力来自 `OverviewCapabilityApplicationFacade`；效果等级来自 Catalog。

Viewer 是唯一的界面检查产品工作区；UI dump 只作为 Viewer 内部的 typed input / Artifact，
不在 Overview 或侧栏中形成独立入口。

[`RemoteBuildSourcePresentation`](../../Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RemoteBuildSource/RemoteBuildSourceApplicationFacade.swift)
已经提供服务器名称、SSH endpoint 与最后验证时间，但当前生产模型没有可供 Overview 读取的
`device target → remote source` 显式关联。实现时必须增加或读取真实绑定事实；不得用服务器列表第一项、
最近使用项或默认值推断绑定。交互稿中的两组服务器数据只是该关联的展示示例。

调试线继续使用不带权限的 `clientContext.provenance["arkdeck.threadId"]`，不能复用每个 Job 独占、
同时参与磁盘与 audit identity 的 `sessionID`。

Overview 与 History 的边界：

- Overview：最近 2–4 条调试线，每条默认 1 次、最多展开此前 3 次，强调继续和需处理；
- History：全量筛选、timeline、evidence、correlation 与 Artifact 导出。

## 8. 与规格的关系

`openspec/specs/desktop-ux-observability/spec.md` 当前要求 Overview 显示完整 HDC 与通道诊断。
v1.4 采用保守方案：字段仍在 Overview，只改成默认折叠，不修改 accepted requirement。

未来若决定把完整诊断迁到 Settings → 诊断，需要单独 behavior delta；在维护者裁决前不做该迁移。

## 9. 本稿范围

定稿后的首轮实现只调整 Overview 信息架构、显式远端服务器绑定和已有跳转/展开交互，不新增
operation、provider、integration/device profile 或 destructive safety policy。设计稿中的按钮仍只演示
跳转、预填、展开和状态反馈，不会运行真实设备操作。
