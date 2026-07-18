---
id: CHG-2026-007-dayu200-flash-route-planning
revision: 1
status: proposed
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# Route-B / Integration plan-only:DAYU200 四 gap 关闭路径规划

## Why

DEC-002(first flashing protocol)保持 open,其 required evidence 是 archived
CHG-2026-003 显式化的四个 `unknown` gap:`GAP-DAYU200-PARTITION-SEMANTICS`、
`GAP-DAYU200-FLASH-ADDRESSES`、`GAP-DAYU200-FLASH-PROTOCOL`、
`GAP-DAYU200-RECOVERY-PATH`。DEC-002 的 resolution vehicle 指定为"DAYU200
Integration change / Route-B CLI plan-only 特征化",且按 backlog 规则不得并入
既有 Task。前置输入现已齐备:DEC-001 decided(DAYU200/RK3568)、M0B 首批
`observed` 真机事实已合入(EVD-M0B-DAYU200-20260718-001)。本 change 是该
vehicle 的 **plan-only 第一步**:只产出研究计划文档,零执行、零设备操作、零
Provider 代码。

## What changes

### In scope(全部 plan-only)

- 起草 `evidence/route-b-plan.md`:对四个 gap 各一节,每节固定五要素——
  1. 事实定义(该 gap 关闭时必须成立的可复查陈述);
  2. 候选事实来源(厂商文档/开源仓库/工具输出/受控真机观察)及其可信度分级;
  3. 获取方法设计(含未来受控观察的命令面草案与只读/写设备分级);
  4. 安全边界(`GAP-DAYU200-RECOVERY-PATH` 未解前禁止一切写设备操作的硬门,
     与恢复路径先行原则:RECOVERY-PATH 必须先于任何 flash 类观察关闭);
  5. evidence 形态与验收口径(何种记录、何种 schema、何种最低证据等级)。
- 计划须显式声明各 gap 的依赖序(RECOVERY-PATH 先行)与升级路径:后续每个
  执行型 change 必须单独立项、单独 approve。

### Out of scope

- 任何真机命令(含只读)、任何 flash/写设备操作、任何 Provider/CLI 实现;
- 修改 flashing spec、Provider contract、hardware matrix、integration lock;
- 解除任何 `GAP-DAYU200-*`、改变 DEC-002 状态(计划本身不构成 evidence);
- 支持/兼容性声明。

## Impacted specifications

- Core behavior:none · Core baseline update:no
- Platform Profile / Integration lock:unchanged
- hardware matrix:unchanged(plan-only)

## Platform impact and revalidation

| Declared platform | Disposition | Reason |
| --- | --- | --- |
| macOS | no revalidation trigger | 纯文档,无产品代码变更 |
| Windows | out of scope; lifecycle unchanged | no implementation or support claim |
| Linux | out of scope; lifecycle unchanged | no implementation or support claim |

## Safety, evidence and compatibility

- plan-only:本 change 不执行任何设备或工具命令;计划中的未来观察仅为设计,
  执行须另行立项并 approve;
- `GAP-DAYU200-RECOVERY-PATH` 未解前禁止写设备的硬门写入计划自身的验收口径;
- simulation/fake/plan-only 不进入 hardware 行(matrix 规则);本 change 产出
  不触碰 matrix。

## Approval

- 本 proposal PR 合入即 status:proposed;正式批准须另行 approval-only PR
  (先例 #14/#40/#55),由维护者 review/merge 构成。批准前 TASK-RB-001 保持
  blocked。
