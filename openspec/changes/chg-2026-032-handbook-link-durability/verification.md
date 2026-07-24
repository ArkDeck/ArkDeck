# CHG-2026-032 Verification Plan

> Status:passed（2026-07-23；两条 change-local acceptance 均 passed，见 proposal 的 Verification closure）
> Change:CHG-2026-032-handbook-link-durability@r1
> Core baseline:CORE-2.1.0（零 Core/Product behavior 变更）

本 change 只认领两条 change-local acceptance。验证目标不是重新评估手册的案例结论，
而是证明：指向活跃 change 的引用不再随归档失效，且事实指向与全部不动面完整保留。

## Acceptance matrix

| Evidence ID | Task | Method | Expected result |
| --- | --- | --- | --- |
| HLD-DURABLE-001 | HLD-001 | documentReview | 手册中指向活跃 change 的相对链接计数为 0；readiness 钉定的逐条清单全数处置且 run 逐条记录"原链接 → 改后文本 → 定位 OID → 取值命令"；每条改后文本含完整 40-hex OID 且在 protected `main` ancestry 中可解析；指向 `changes/archive/**` 的链接计数与内容零变化；`AF-NNN` ID 集合、taxonomy 归属与两轴划分、八字段契约与顺序、`Automation status` 取值域、`Fact`/`Inference` 标注与 positive/negative 计数零变化；归档模拟下不存在可断项；archive 与 templates diff 为零 |
| HLD-CONVENTION-001 | HLD-002 | documentReview | 手册首屏增加一条非规范引用约定，明确活跃 change 用耐久形式、已归档目标可用相对路径，且明确只约束本手册自身后续编辑；新增 normative `SHALL`/`MUST` = 0，对其他文档的强制表述 = 0，自动批准/ready/done 语义 = 0；不动面与 `HLD-DURABLE-001` 同项零变化 |

## Negative and boundary checks

- 任一改后文本失去可唯一定位的事实指向（缺 change ID、文件名或 OID）→ `HLD-DURABLE-001` fail；
- 任一 OID 不可解析或不在 protected `main` ancestry 中 → fail；
- 误改 `changes/archive/**` 类链接 → fail；
- 约定文本出现 normative `SHALL`/`MUST` 或对其他文档的强制要求 → `HLD-CONVENTION-001` fail；
- 任何 `changes/archive/**`、`openspec/templates/**`、spec/contracts、governance/AGENTS
  或产品代码 diff → 整体 fail；
- 任何 secret、真实设备标识、用户绝对路径 → 整体 fail。

## Repository checks

- `scripts/check-sdd.sh`：0 error / 0 warning / 111 canonical acceptance IDs；
- `git diff --check`；
- allowed/forbidden path audit；
- 链接与 anchor 解析审计；archive diff = 0；secret/privacy scan = 0。

## Result gate

本 change 只有在 TASK-HLD-001 与 TASK-HLD-002 各自经 implementation/evidence PR 与
独立 done PR 合入、两条 change-local acceptance 均有可复查 evidence、上述
negative/boundary/repository checks 全部通过后，才可起草独立 `verified` PR。
verified 不把手册提升为权威规则，不改变任何产品/platform/conformance/support 状态。
