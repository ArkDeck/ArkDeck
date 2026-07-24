# CHG-2026-033 Tasks

> r1/r2 历史批准保持真实。r3 proposal #473 已登记 ref convergence、workflow
> suppression、conditional cleanup 与 residual-ref cleanup 机制。独立
> approval-only PR #474 只在维护者 review/merge 后批准 r3，并使 TASK-RPT-001
> `blocked → ready`；TASK-RPT-002 保持 `blocked`。本 PR 不创建 D2
> authorization/window，不批准 payload/probe，也没有 done 或 verified 语义。

## Cross-change stop gate

在任何 D2 readiness 前必须满足：

- 本 change current r3 仅在独立 approval-only PR #474 经维护者 review/merge 后为
  `approved`；r1/r2 approval 不授权 r3 D2；
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

- Status:ready（仅在独立 r3 approval-only PR #474 经维护者 review/merge 后生效，
  且只允许下一独立 PR 从当时最新 protected main 起草/固定 D2 readiness。
  r3 proposal #473 exact head
  `9c359396ca1cdd7355ea2c0c3d28e988335ad49b` 已由 `lvye` APPROVED 并合入
  `6153d581d7caf1bd1ed3335171318b3e92250926`；该 merge 只登记 proposal。
  #455 approval merge
  `c86f07ae6b843affaaa3f698e2f9f08a6f4c96cd` 与 CHG-2026-030 r7 #456 merge
  `c5a1a9f0f1c0a9bc0dd3d04275ac01a5738697f7` 是 r1 历史 gate；
  #474 merge 是 r3 current gate。
  本状态不批准任何 before/after/rollback payload、hash、window、operator action、
  probe-ref mutation、credential 或 GitHub control-plane write；D2 readiness 未由 `lvye`
  review/merge 前，task execution dispatch = 0。）
- Platform:macos
- Requirements/AC:change-local `RPT-BOUNDARY-001`、`RPT-MAIN-001`、
  `RPT-IDENTITY-001`、`RPT-MIGRATION-001`
- Depends on:change approval、cross-change stop gate；execution 另依赖 independent
  D2 readiness
- Applicable failure patterns:`AF-009`、`AF-016`
- Production reachability:human-isolated GitHub admin session → repository
  settings authority → branch protection/ruleset/repository setting mutation
- Trusted fact sources:human-controlled authenticated GitHub GET；public Git full
  OID；exact PR/check/review/merge metadata；移除 human credential 后的 Agent negative
  probes。executor 自报字段不能单独升级为可信事实。
- Allowed paths:通常为
  `openspec/changes/chg-2026-033-ref-protection-topology/d2-readiness.md`、
  本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）。
  #467 fail-closed 后的一次性 #459 bootstrap carrier 另允许本 change
  `proposal.md`、本 change `design.md`、本 change `verification.md`、本 change
  `acceptance-cases.yaml`，仅用于修订 Actions create+approve 组合 capability 的
  机制描述；不得修改任何其他 path。
  #472 合入后的 r3 proposal revision 另允许本 change `proposal.md`、`design.md`、
  `verification.md`、`acceptance-cases.yaml`、`tasks.md` 与
  `d2-readiness.md`，仅登记 #470 failure、作废旧 readiness 与修订 probe/recovery
  机制；不包含新 D2 pins、script 或 GitHub mutation。
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/enforcement.md`、`openspec/specs/**`、
  `openspec/contracts/**`、`.github/**`、产品 source/tests、其他 change
- Risk:high（D2 repository permission 与 credential boundary；只允许人类仓外执行）
- Hardware required:no

### Deliverables

- #467 fail-closed receipt 与 ordinary `agent-pr` transport failure evidence；
- 一次性 bootstrap recovery readiness：只授权 Actions workflow setting
  `false/read → true/read`，其他 GitHub settings/ref/PR-state mutation 为 0；
- transport 恢复后的独立 evidence PR，证明 bot-authored PR 创建恢复且仍需
  `lvye` CODEOWNER approval；
- 独立 D2 readiness：fresh protected main、完整 authenticated before、exact
  after/rollback payload/hash、operator/window、actor inventory 与 fresh probe names；
- human execution receipt：credential containment、repository auto-merge、main
  branch protection 与 ruleset；
- bounded ref convergence：Git server receipt、连续 `ls-remote` 与 authenticated
  REST 在固定预算内一致；单次 stale read 不升级为 drift；
- probe workflow isolation：positive tip commit 使用 `[skip actions]`，workflow
  blobs/events 固定，临时 probe 不创建 Actions run 或 PR；
- #470 residual ref 只在 exact after-ruleset 下由 Deploy Key 删除；失败 cleanup 在
  main exact protection 已知时先于会重新阻断 deeper ref 的 ruleset rollback；
- single/multi-level Agent ref 正向矩阵与 ordinary/main/agentx 负向矩阵；
- Agent/API review/merge/auto-merge/ref/admin 负向矩阵；
- 正常人类 no-bypass squash merge pilot；由后一独立 operability-evidence PR 记录。

### Verification

- bootstrap recovery 只证明 PR transport liveness 与 self-approval/authority
  separation，不计为任何 topology AC PASS；
- `RPT-BOUNDARY-001`、`RPT-MAIN-001`、`RPT-IDENTITY-001`、
  `RPT-MIGRATION-001` 全部二值可复查；
- unexpected success、hidden actor、drift、missing field、ambiguous API、hash mismatch
  或无法 rollback，任一发生立即失败；
- convergence timeout、Git/REST 持续矛盾、unexpected workflow/PR、residual OID
  漂移或 cleanup absence 无法证明，任一发生立即失败；
- execution/evidence PR 不翻状态；evidence 与 operability addendum 均合入后，才可
  以独立 D0 PR `ready → done`。

### Notes / handoff

- readiness PR 只能在 task 经独立 D1 状态 PR 成为 `ready` 后起草；
- #467 readiness/merge
  `9de9c63f7fe17069ad50ff0a73fc171ce6a14ec8`、两份 apply script、旧 window、
  payload/hash、nonce 与 derived refs 已 exhausted，禁止重跑；
- #470 readiness/head
  `c5cb4757065a9a3c65b5f98351e56a3236eda396`、merge
  `928d6e06b928e16874df9137950a9830aa38d8d0`、executor
  `124f9b799169fda8e3b0814442accf925f51efffdb2b7165acb7063743dd8f2c`、
  window、payload/hash 与全部 UUID 已 exhausted；#472 failure evidence merge
  `398a1e9f14ebf0debe785591f4f7517b54e16b26` 不产生 AC PASS；
- #471 已 closed/unmerged；其 head ref 保留为唯一 pinned residual：
  `refs/heads/agent/rpt001/deep/7908274d-d874-47d6-b844-c2e35ba9d2a9` /
  `2e1e5ce85266f96f54eb60d9f2547398d1c9b3e7`。r3 approval 和 fresh D2
  merge 前不得删除、移动或复用；
- 用户明确授权把 bot-authored/open PR #459 的旧 head
  `d3aeeaaa8eba79526474580208dc253c4c46d26a` 作为一次性
  `force-with-lease` expected value。该例外只恢复治理 PR transport，不授权
  ruleset/main protection mutation，也不把聊天指令当作 D2 approval；
- #459 的维护者 review/merge 同时批准 r2 mechanism revision 与 exact bootstrap
  readiness，是通道不可用条件下的显式 carrier collapse。任务状态保持 `ready`；
  topology execution 仍需 transport 恢复后的全新独立 readiness；
- 历史 D1 状态 PR 只修改本文件的 TASK-RPT-001 状态/依赖说明；未填写
  `d2-readiness.md`，不新增 evidence，不采集 authenticated control-plane JSON，
  除承载本状态变更的普通 `agent/**` branch/PR transport 外，不执行 probe ref、
  setting、credential 或其他 control-plane 操作；
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
