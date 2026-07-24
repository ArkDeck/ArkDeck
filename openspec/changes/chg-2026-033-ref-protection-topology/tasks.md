# CHG-2026-033 Tasks

> 本 change 当前仅为 `proposed`。所有任务均为 `blocked`；本文件没有 approval、
> readiness、authorization、done 或 verified 语义。

## Cross-change stop gate

在任何 D2 readiness 前必须满足：

- 本 change 已由独立 approval-only PR 置为 `approved`；
- CHG-2026-030 以独立 r7 revision：
  - supersede 已由 #449 合入的 r6 Agent-operated ruleset gateway；
  - 明确 #435 与全部旧 window/OID/payload/hash/UUID 永久不可执行；
  - TASK-HLR-002A 保持/恢复 `blocked`；
  - 移除 old one-pattern PUT 与 Agent-operated ruleset mutation 作为 current plan；
  - fresh HLR-002A readiness 依赖 TASK-RPT-001 done/evidence merge OID；
  - 保留 #419 source evidence 与 #421 failure evidence 的历史真实性。

该 cross-change revision 属 D1，仅修改 CHG-2026-030 governance documents，执行
GitHub control-plane/ref/probe 数为 0。

## TASK-RPT-001 — 隔离 Agent 身份并迁移 ref protection topology

- Status:blocked（前置：change approval、CHG-2026-030 r7 compatible revision
  merge、独立 D2 readiness）
- Platform:macos
- Requirements/AC:change-local `RPT-BOUNDARY-001`、`RPT-MAIN-001`、
  `RPT-IDENTITY-001`、`RPT-MIGRATION-001`
- Depends on:change approval、cross-change stop gate、independent D2 readiness
- Applicable failure patterns:`AF-009`、`AF-016`
- Production reachability:human-isolated GitHub admin session → repository
  settings authority → branch protection/ruleset/repository setting mutation
- Trusted fact sources:human-controlled authenticated GitHub GET；public Git full
  OID；exact PR/check/review/merge metadata；移除 human credential 后的 Agent negative
  probes。executor 自报字段不能单独升级为可信事实。
- Allowed paths:`openspec/changes/chg-2026-033-ref-protection-topology/d2-readiness.md`、
  本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/enforcement.md`、`openspec/specs/**`、
  `openspec/contracts/**`、`.github/**`、产品 source/tests、其他 change
- Risk:high（D2 repository permission 与 credential boundary；只允许人类仓外执行）
- Hardware required:no

### Deliverables

- 独立 D2 readiness：fresh protected main、完整 authenticated before、exact
  after/rollback payload/hash、operator/window、actor inventory 与 fresh probe names；
- human execution receipt：credential containment、repository auto-merge、main
  branch protection 与 ruleset；
- single/multi-level Agent ref 正向矩阵与 ordinary/main/agentx 负向矩阵；
- Agent/API review/merge/auto-merge/ref/admin 负向矩阵；
- 正常人类 no-bypass squash merge pilot；由后一独立 operability-evidence PR 记录。

### Verification

- `RPT-BOUNDARY-001`、`RPT-MAIN-001`、`RPT-IDENTITY-001`、
  `RPT-MIGRATION-001` 全部二值可复查；
- unexpected success、hidden actor、drift、missing field、ambiguous API、hash mismatch
  或无法 rollback，任一发生立即失败；
- execution/evidence PR 不翻状态；evidence 与 operability addendum 均合入后，才可
  以独立 D0 PR `ready → done`。

### Notes / handoff

- readiness PR 只能在 task 经独立 D1 状态 PR 成为 `ready` 后起草；
- 人类设置变更发生在 Agent 外，Agent 只可准备 secret-free payload/hash 并验证
  public/negative facts；
- 本任务不授权真实 main force/delete success path。

## TASK-RPT-002 — Supersede mechanism pointers 并重建 dependent governance

- Status:blocked
- Platform:macos
- Requirements/AC:change-local `RPT-AUDIT-001`
- Depends on:TASK-RPT-001 done、independent readiness
- Applicable failure patterns:`AF-009`、`AF-016`
- Production reachability:not applicable；只修改 governance/evidence current pointers，
  不产生 GitHub effect
- Trusted fact sources:TASK-RPT-001 merged evidence、full merge OID、protected-main
  blob 与 authenticated before/after/rollback hashes
- Allowed paths:`openspec/changes/chg-2026-027-decision-grading-batch-approval/**`、
  `openspec/changes/chg-2026-030-host-loop-runtime/**`、
  `openspec/governance/host-loop-runbook.md`、本 change `evidence/**`、
  本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:历史 evidence 文件改写/删除、`AGENTS.md`、
  `openspec/constitution.md`、`openspec/governance/enforcement.md`、
  `openspec/specs/**`、`openspec/contracts/**`、`.github/**`、产品 source/tests
- Risk:medium（错误 current pointer 可能把旧权限机制误写为仍有效）
- Hardware required:no

### Deliverables

- BAP-CRED-001 append-only supersession/revalidation：ordinary ref 拒绝来自 ruleset，
  main 拒绝来自 branch protection，身份隔离另有 actor evidence；
- CHG-2026-027 current-mechanism note，不改写历史 run；
- host-loop runbook 更新为 ruleset + branch protection 分层；
- CHG-2026-030 compatible revision/follow-up 消费新 evidence 并起草 fresh、
  canary-only HLR-002A readiness；不得复制旧 window/payload/UUID。

### Verification

- 历史 claim 在原日期保持真实；
- current claim 只指向 TASK-RPT-001 merged evidence；
- BAP-CRED-001 behavior 全矩阵重跑，不把旧 mechanism evidence 当永久证明；
- HLR-002A 在新独立 readiness merge 前保持 blocked；
- `RPT-AUDIT-001` document review、`scripts/check-sdd.sh` 与 `git diff --check` 通过。

### Notes / handoff

- 本任务只在 TASK-RPT-001 done 后进入 readiness；
- enforcement.md 与 AGENTS.md 高层不变量不变，不为描述新 topology 而修改。
