---
id: CHG-2026-007-dayu200-flash-route-planning
revision: 1
status: archived # 2026-07-21 archive PR(先例 #178/#235/#241;Route-B 收官解除暂缓:活跃面零精确路径引用;archived CHG-009 evidence 字节内 4 处路径引用属不可改写历史证据,断链接受并在 PR 记录,先例 #211);verified 于 #84。原注: 2026-07-18 verification closure(先例 #20/#48):四 PLAN-DAYU200-* AC 经 document review PASS;经本 PR 维护者 review/merge 生效
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

- Proposal 经 PR #62 合入 main(`f3961cc`,2026-07-18,status:proposed)。
- 正式批准:2026-07-18 由 approval-only PR #64 合入 main(`36df85e`)将本 change
  置为 `approved`(先例 #14/#40/#55);TASK-RB-001 经 readiness PR #65(`bc4967e`)
  转 ready。

## Verification closure(2026-07-18)

- 交付物 `evidence/route-b-plan.md` + `evidence/runs/TASK-RB-001/run.md` 经
  PR #66 合入 main(`7c68710`);TASK-RB-001 经状态 PR #67 合入 main(`c98d2b6`)
  翻转 done。四个 change-local AC(`TEST-PLAN-DAYU200-PARTITION-001`、
  `TEST-PLAN-DAYU200-ADDRESSES-001`、`TEST-PLAN-DAYU200-PROTOCOL-001`、
  `TEST-PLAN-DAYU200-RECOVERY-001`)在 run.md 以 document review 二值 PASS;
  plan-only gate 自证(#66 仅新增 markdown,零命令执行)。
- 上述 PR 的维护者 review/merge 构成 `verification.md` acceptance matrix 所
  要求的 verification confirmation。本文件的 `status: verified` 仅在包含本状态
  变更的 verification closure PR 经维护者 review 并合入 `main` 后生效;verified
  不改变计划的边界——计划不解除任何 `GAP-DAYU200-*`、不改变 DEC-002 状态、
  不构成任何后续执行型 change 的执行授权(每个执行型 change 仍须单独立项/
  approve);RECOVERY-PATH 先行硬序与只读/写设备分级规则继续对全部 Route-B
  后续步骤生效。本 change 暂不 archive:route-b-plan.md 仍是 Route-B 在途步骤
  (③演练、④第二阶段、④b)的活跃硬序依据,archive 留待 Route-B 收官后独立
  PR 裁量(先例 #21/#49)。
