# CHG-2026-029 Verification Plan

> Status:planned
> Change:CHG-2026-029-agent-failure-prevention@r2
> Core baseline:CORE-2.1.0（零 Core/Product behavior 变更）
> r2 只把 `AFP-HANDBOOK-001` 的验收对象由九项 ID 扩为十八项；
> `AFP-TEMPLATE-001`/`AFP-DRILL-001`、negative/boundary checks 与 result gate 逐字不变。

本 change 只认领三条 change-local acceptance。验证目标不是证明历史产品重新合格，
而是证明：手册可追溯且不成为 shadow spec，模板在任务开工前暴露关键问题，历史演练
能检出已发生模式同时保持环境/evidence-class 边界诚实。

## Acceptance matrix

| Evidence ID | Task | Method | Expected result |
| --- | --- | --- | --- |
| AFP-HANDBOOK-001 | AFP-001 | documentReview | `agent-failure-patterns.md` 首屏声明 non-normative/authority/conflict/privacy 边界；`AF-001`…`AF-018` ID 唯一且各含 signal、observed cases、root cause、preflight、positive+negative verification、canonical references、automation status、完整 main OID/date currency；`AF-001`…`AF-009` 含 design §3.1 登记的子面，`AF-010`…`AF-018` 与 design §3.2 的根因/案例锚点一致；案例链接可解析且事实/推断分离；不复制 raw/sensitive evidence，不新增 normative rule/批准语义，不改 archive |
| AFP-TEMPLATE-001 | AFP-002 | documentReview | tasks/design/evidence-run 三模板按 design §4 增加短字段；既有 Requirements/Acceptance/Depends/Allowed/Forbidden/Risk/Hardware/Deliverables/Verification/Notes、failure/security 与 evidence-class 规则零删除零放宽；字段允许 `not applicable` + 理由但不自动通过；不存在自动 approval/ready/done、simulation→hardware 或手册覆盖 canonical rule 的表达 |
| AFP-DRILL-001 | AFP-003 | documentReview | readiness 钉定的六类历史案例全部映射到最早触发阶段、AF ID、模板字段、预防/验证动作与历史 evidence；至少一个环境失败反例保持 environment blocked/deviation 而非产品 failure；演练不修改历史 bytes、不重判 task/change/AC、不产生产品或硬件支持声明 |

## Negative and boundary checks

- 删除或弱化手册 non-normative/authority 声明 → `AFP-HANDBOOK-001` fail；
- observed case 无仓内路径/PR/完整 OID，或把推断写成事实 → 对应 handbook row fail；
- 模板删除既有 gate、把 `none/not applicable` 写成自动通过、或创造状态/批准语义 →
  `AFP-TEMPLATE-001` fail；
- drill 只引用 fake/contract PASS 就声称 production/hardware 可达 → `AFP-DRILL-001` fail；
- 把锁屏、module-cache、缺解释器依赖或 quarantine 等环境事件直接判产品缺陷 → drill fail；
- 任何 `changes/archive/**`、spec/contracts、governance/AGENTS 或产品代码 diff → 整体 fail；
- 任何 secret、真实设备标识、用户绝对路径、raw dump/trace 或仓库外日志复制 → 整体 fail。

## Repository checks

- `scripts/check-sdd.sh`：0 error / 0 warning / 111 canonical acceptance IDs；
- `git diff --check`；
- allowed/forbidden path audit；
- relative link/完整 40-hex Git OID audit；
- archive diff = 0；secret/privacy scan = 0。

## Result gate

本 change 只有在 AFP-001/002/003 全部经各自 implementation/evidence PR 与独立 done PR
合入、三条 change-local acceptance 有可复查 evidence、上述 negative/boundary/repository
checks 全部通过后，才可起草独立 `verified` PR。verified 不把手册提升为权威规则，
不改变任何产品/platform/conformance/support 状态，也不构成未来 guard/CI 扩展授权。
