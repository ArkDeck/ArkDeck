# Spec Impact — CHG-2026-026

## Classification

本 change 是 macOS platform/product composition，不修改 Core 可观察语义。现行
`REQ-UX-001` 已要求 Flash 入口与全局 Job 状态，`REQ-FLASH-001…015` 已定义 Provider、
镜像、模式、确认、取消、postflight、恢复和执行权限边界；`REQ-DEV-001/002/003/006/008`
已定义 original target、durable binding revision、跨模式 rebind threshold、identity gate 和
mutation lane。本 change 只让 macOS App 实现这些既有要求。

r2 的 discovery executable repin、001/001A dependency correction 与一次 E1
characterization window 仍属于同一 platform/integration scope：typed `enterUpdater`、
binding/rebind threshold、effect classification 与全部 Core AC 均不变。

## No-op delta conclusion

- `openspec/specs/**`：零修改。
- `openspec/contracts/**`：零 required-field/schema 修改。
- `openspec/verification/acceptance-cases.yaml` / index：零 ID 变化。
- Core baseline：保持 `CORE-2.0.0`；若 CHG-2026-025 在本 change 实现前归档并产生新
  baseline，readiness 必须重新 pin 并复核 `REQ-FLASH-015` overlay，不得自动沿用。

## Interpretation requiring maintainer review

本 proposal 把“人类操作者在 App 内审阅 exact plan、完成强确认并点击 Start Flash”视为
交互式人类执行入口；executor 仍是 ArkDeck typed process adapter。因为现有 CLI 选择了
human handoff 而非内置 dispatch，维护者必须在批准本 change 时明确这一实现是否兼容
`REQ-FLASH-015`。若不兼容，execute task 保持 blocked 并先走 Core delta；plan-only/UI
任务不借此放宽。

`enterUpdater` 已在 locked WorkflowStep registry/schema 中定义，现有 Rockchip Provider 也
已生成 `providerOperationId=rockusb.enter-loader`、expected `0x2207:0x350a Loader` 和
120 秒 deadline。本 change 只增加具名 E1 capability evidence 与 platform adapter，不需要
新 step kind/schema。若真实 HDC→Loader binding 需要降低 Core evidence threshold，则本
change 必须保持 blocked 并另走 Core delta；不得把 BlueTool 的“唯一 Loader”规则当解释。
