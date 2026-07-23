# Batch digest 模板(批次审批导航载体)

> 交付:CHG-2026-027 TASK-BAP-002。字段面 = 该 change design §2 全字段;
> 语义正本 = `openspec/governance/enforcement.md`"决策分级"与"批次审批
> 协议"两节,本模板只细化格式,不得放宽任何正本条款。
> 用法:批次队列 issue(命名 `batch-YYYYMMDD-N`)正文 = 首屏声明(原样
> 携带)+ 按建议合并顺序编号的逐项 digest。

## 首屏声明(每个批次 issue 正文必须原样携带)

- 本 issue 与其中的每条 digest **仅是导航**,不承载任何批准语义;
- 队列中的**每个 PR 仍由维护者逐项对 exact head review 并单独 merge**,
  唯一批准载体 = 维护者对该 PR 的 review/merge;
- **CI 绿 ≠ 批准;digest 完整 ≠ 批准;任何等级(含 D0)不存在 auto-merge**;
- 遇拒停链:某项被拒绝或要求修改时,digest 声明依赖它的后续项本轮不合,
  被拒项回炉走正常修复;无依赖关系的其余项可继续;
- close 本 issue 仅表示导航归档,不改变任何 PR、任务或 change 状态。

## 入队三门(缺一不入队,登记于各项 digest)

1. guard 与适用 CI 全绿;
2. **独立 AI 会话**对 exact head 的合前 review = APPROVE(实现与 review
   必须是不同会话;head 变更后旧 APPROVE 失效,须对新 head 重审);
3. digest 全字段完整(含 base/head OID 与 files read-back)。

## 逐项 digest 格式

每个批次项一节,标题按建议合并顺序编号:

### 项 <N>:PR #<编号> — <标题>

| 字段 | 内容 |
| --- | --- |
| Grade | D0 / D1 / D2(enforcement"决策分级"三条件判定;拿不准按 D1) |
| Change/Task | `CHG-…` / `TASK-…`(change 级状态面写明 verify/archive 等) |
| 内容 | 一句话:本 PR 做什么 |
| Base/Head OID | 完整 40-hex 各一;创建/入队时 read-back 写入,head 漂移即重审 |
| Files read-back | `git diff --name-only base..head` 清单(与声明范围一致性由 review 把关) |
| 风险与影响面 | 简述;D0 项须能指出"结论由 main 已合入状态 + 确定性检查完全决定" |
| Evidence/测试指针 | run.md 路径、checks/run 链接、复验记录 |
| 独立 review | `APPROVE @ <head-OID>(reviewer 会话标识)` 或 finding 指针 |
| 依赖与顺序 | 依赖的前序项编号;无依赖写 `none` |
| 合并前置 | 是否需 update-branch;D2 项写明所需维护者仓外动作 |

## 与状态机的衔接

digest 由 producer/watch 会话在 `queue` 步写入;`merge-OID verify` 步的
核验结果(PR/head/merge OID、检测时间、ancestry)追加到对应项之后,作为
drill/批次 evidence 的输入。流程语义见
`openspec/governance/host-loop-runbook.md`。
