# Spec Impact — CHG-2026-059

## Classification

本 change 是 integration scope：`flash.dayu200` 的 operation 契约、step 集合、
declared effect、binding requirement 与 UI 事件形状**全部不变**，变的是这条
operation 的执行归属——`rkdeveloptool` 从 ArkDeck 进程内移到 `arkforged`。

现行 `REQ-FLASH-001…015` 已定义 Provider、镜像、模式、确认、取消、postflight、
恢复与执行权限边界；`REQ-DEV-001/002/003/006/008` 已定义 original target、
durable binding revision、跨模式 rebind threshold、identity gate 与 mutation lane。
本 change 不修改其中任何一条的文本，只改变谁来满足 `REQ-FLASH` 里属于设备机制的那部分。

## No-op delta conclusion

- `openspec/specs/**`：零修改。
- `openspec/contracts/**`：零 required-field / schema 修改。
  `flash.dayu200` 的 Catalog descriptor 字节不变。
- `openspec/verification/acceptance-cases.yaml` / index：零 ID 变化。
- Core baseline：保持 `CORE-3.0.0`。

## 需要维护者判断的两处

### 1. class 归属

`RockchipProviderAction` 少两个 case，且一条 destructive 执行路径跨到了另一个进程。
本 proposal 判为 `integration`（工具链适配，不降低 Core）。若维护者认为
「destructive 执行跨进程」本身构成 capability 或 core 变化，请在 review 时重分类——
本文不替维护者定这一条。

### 2. `REQ-FLASH-015` 的执行者身份

现行解释里 executor 是 ArkDeck typed process adapter。本 change 之后，
批准者仍是 ArkDeck（签发 StepPermit），执行者是 `arkforged`。
维护者需要明确这一实现是否仍满足 `REQ-FLASH-015`：

- 若满足：本 change 按 integration 推进；
- 若不满足：execute task 保持 blocked，先走 Core delta。
  **plan-only / 只读任务不得借此放宽。**

ArkForge 侧的对应边界写在它的 `architecture.md` 3、8、9.1：
ArkDeck 保留 HDC endpoint、server ownership、connectKey、target binding 与 authority；
ArkForge 只能通过 typed `ManagedDeviceControlPort` 请求语义动作。
这条分工不是本 change 发明的，是本 change 落到代码上的。

## 不构成 delta 的既有事实

以下在本 change 之前就已成立，列出是为了 review 时不必再查：

- `flash.dayu200` 的 destructive 确认流程不变；
- userdata 被覆盖是 `flash.dayu200` 的既有语义，不是本 change 引入的；
- `enterUpdater` 已在 locked WorkflowStep registry/schema 中定义，
  本 change 不新增 step kind 或 schema。
