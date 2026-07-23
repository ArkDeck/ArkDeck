# CHG-2026-029 Verification Plan

> Status:passed # 2026-07-23；五条 AC、六 task merge 链与当前 main 重跑结论见 proposal.md「Verification closure」；仅在维护者 review/merge 本 verification-closure PR 后生效
> Change:CHG-2026-029-agent-failure-prevention@r5
> Core baseline:CORE-2.1.0（零 Core/Product behavior 变更）
> r2 把 `AFP-HANDBOOK-001` 的验收对象由九项 ID 扩为十八项。
> r3 新增 `AFP-CORRECT-001`（TASK-AFP-004 手册 `Fact` 一手复核）；
> r4 新增 `AFP-LINK-001`（TASK-AFP-005 手册 archive 断链收口）；
> r5 新增 TASK-AFP-006，修正 AF-014 一手事实并以 addendum 取代旧 run 对该项的结论；
> `AFP-HANDBOOK-001`/`AFP-TEMPLATE-001`/`AFP-DRILL-001` 的验收内容逐字不变。

本 change 只认领五条 change-local acceptance。验证目标不是证明历史产品重新合格，
而是证明：手册可追溯且不成为 shadow spec，模板在任务开工前暴露关键问题，历史演练
能检出已发生模式同时保持环境/evidence-class 边界诚实，Fact 一手复核与 archive
链接收口均有当前 evidence。

## Acceptance matrix

| Evidence ID | Task | Method | Expected result |
| --- | --- | --- | --- |
| AFP-HANDBOOK-001 | AFP-001/006 | documentReview | `agent-failure-patterns.md` 首屏声明 non-normative/authority/conflict/privacy 边界；`AF-001`…`AF-018` ID 唯一且各含 signal、observed cases、root cause、preflight、positive+negative verification、canonical references、automation status、完整 main OID/date currency；`AF-001`…`AF-009` 含 design §3.1 登记的子面，`AF-010`…`AF-018` 与 design §3.2 的根因/案例锚点一致；AF-014 按 design §3.3 引用 capability-bound reliable-total factory/receipt 的一手 source，错误的 public-enum bypass 表述为 0；案例链接可解析且事实/推断分离；不复制 raw/sensitive evidence，不新增 normative rule/批准语义，不改 archive |
| AFP-TEMPLATE-001 | AFP-002 | documentReview | tasks/design/evidence-run 三模板按 design §4 增加短字段；既有 Requirements/Acceptance/Depends/Allowed/Forbidden/Risk/Hardware/Deliverables/Verification/Notes、failure/security 与 evidence-class 规则零删除零放宽；字段允许 `not applicable` + 理由但不自动通过；不存在自动 approval/ready/done、simulation→hardware 或手册覆盖 canonical rule 的表达 |
| AFP-DRILL-001 | AFP-003 | documentReview | readiness 钉定的六类历史案例全部映射到最早触发阶段、AF ID、模板字段、预防/验证动作与历史 evidence；至少一个环境失败反例保持 environment blocked/deviation 而非产品 failure；演练不修改历史 bytes、不重判 task/change/AC、不产生产品或硬件支持声明 |
| AFP-CORRECT-001 | AFP-004/006 | documentReview | r5 addendum 明确旧 AFP-004 run 的 AF-014 PASS 已 superseded；手册 `AF-001`…`AF-018` 的全部当前 `Fact` 行逐条给出一手出处（相对路径 + 完整 40-hex blob OID）、可检索位置与支持/不支持判定；不被支持的具体表述已改写为可支持表述或降级为 `Inference`，两种处置均有判定依据；AF-014 同时钉定 CHG-2026-021 tasks 与 TASK-TR-002R run；`Inference` 行未被误写为 `Fact`；`AF-NNN` ID 集合、taxonomy 归属、八字段契约、`Automation status` 取值域与两轴划分零变化；手册内代码符号可在仓内（手册与本 change 之外）解析；`Currency` 已更新；archive 与模板 diff 为零 |
| AFP-LINK-001 | AFP-005 | documentReview | 手册对**本 change 目录**的相对路径引用归零（`git grep` 在 `openspec/planning/**` 下命中 0），且 taxonomy 登记在 CHG-2026-029 design §3 这一事实指向以不依赖 change 目录位置的形式保留；`AF-NNN` ID 集合、taxonomy 归属与两轴划分、八字段契约与顺序、`Automation status` 取值域、首屏声明、`Fact`/`Inference` 标注与 positive/negative 方法数**零变化**；指向其他活跃 change 的 24 条链接逐字不动并在 run 中登记为已知限制；`openspec/templates/**`、`changes/archive/**` 与 chg-2026-027 目录 diff 为 0 |

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

本 change 只有在 AFP-001…AFP-006 全部经各自 implementation/evidence PR 与独立
done PR 合入、五条 change-local acceptance 有可复查 evidence、上述
negative/boundary/repository checks 全部通过后，才可起草独立 `verified` PR。
verified 不把手册提升为权威规则，不改变任何产品/platform/conformance/support
状态，也不构成未来 guard/CI 扩展授权。
