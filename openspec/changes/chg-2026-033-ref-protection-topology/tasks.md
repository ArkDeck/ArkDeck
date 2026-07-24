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

- Status:done（仅在本独立 D0 状态 PR 经维护者 review/merge 后生效。r3 D2
  readiness #475 合入 `b69170f573890661dbd731eac8ed99d82e807919`；成功
  execution-evidence #476 合入
  `6f874efc5c4e9fdd39bcdcc91cfcaa6a862e1961`；独立 operability-evidence
  #477 exact head `b3ed3d6df50b77153e095d4d42caca8c077aebc9` 由 `lvye`
  APPROVED，App `15368` `guard=success`，并由 `lvye` 合入
  `7a221d24133eefed38aa616fcda376fef33f6cf3`。两份 merged evidence 共同覆盖
  settings/ref migration、完整正负矩阵、Agent/API route 隔离及正常人类
  no-bypass squash merge。本状态翻转不新增 evidence，不批准 TASK-RPT-002、
  HLR-002A readiness 或任何 payload/window/operator action，且 GitHub
  control-plane/ref/credential mutation 为 0。）
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

- Status:ready（仅在本独立 D1 readiness PR 经维护者 review/merge 后生效。
  TASK-RPT-001 done PR #478 exact head
  `54c8e0392c5bf4ef3c50f7e6086cfad680481e7d` 已由 `lvye` APPROVED，
  App `15368` `guard=success`，并由 `lvye` 合入 protected main
  `94c23c4123712a46e7fb2f96a0509f84f5f49ba7`。本状态只批准下述
  append-only current-pointer/compatible-revision 计划；不修改任何目标文档，
  不使 HLR-002A ready，不执行 canary，不修改 GitHub setting/ref/credential，
  也不批准 TASK-RPT-002 done 或 change verified。）
- Readiness（r1；audit base = protected main
  `94c23c4123712a46e7fb2f96a0509f84f5f49ba7`）：
  - **Dependency/evidence gate:closed。**#476 execution-evidence merge
    `6f874efc5c4e9fdd39bcdcc91cfcaa6a862e1961`、#477 operability-evidence
    merge `7a221d24133eefed38aa616fcda376fef33f6cf3` 与 #478 done merge
    `94c23c4123712a46e7fb2f96a0509f84f5f49ba7` 均为 audit base ancestor。
    #477 记录正常人类 no-bypass squash merge；#478 只完成 TASK-RPT-001
    `ready→done`，未夹带 TASK-RPT-002 scope。
  - **Current topology evidence pins:closed。**成功 receipt JSON blob =
    `8eb63bf170e993785acda6345a80558fb6871b76`，文件 SHA-256 =
    `9340eae63e4b4586a07525340e1c6a4b9fe39c0a5958bda1cda55dda16df9d9f`；
    human-readable success blob =
    `6c4541d41c8a166edd201883d10190be031d0bea`；no-bypass operability blob =
    `73005c421eb3fc36a16b435873a18f6e84b97369`。receipt 内 current after
    hashes 固定为 branch-protection projection
    `f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a`、
    full `04f09f273fce806afaa44679c9e8257c74cce3e480fe60da27c7dcca06e85f04`，
    ruleset projection
    `9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163`、
    full `b172750c1c0764956725393823fa72014146d9e2ec0f1b19c48cf670964d54b5`；
    不从 public projection 推断 hidden actor。
  - **Input blob pins:closed。**implementation 只从本 readiness merge 后的最新
    protected main 新建分支；开工前以下 audit-base blobs 必须逐项重读，除
    readiness 自身预期改变的本文件外均须相等：

    ```yaml
    chg027_proposal: 47f05f5df464dd110daaffdaa00956115f807df1
    chg027_tasks: edc483423d0193104b1977d4ae25c2b27409a131
    chg027_verification: 78f95258ae6570d622636c978d244a4ac1eefa0d
    chg030_proposal: 890a40585b2898c0fd9e7d2b72f5b2a8e81b515c
    chg030_design: 7e2e20bfb884875de32cbbeb5f0399df7a137056
    chg030_tasks: 7fc3c14bb207facec9d330a8d74b23fb9aefdb58
    chg030_verification: 49f284b397006fa8626e76ec2fa51f5d9a88e307
    host_loop_runbook: 70e0bcc5b736a896f0329e24a89e273164762558
    enforcement: e8ff3c130e1b8b15f8405d150ad567e774a0d82b
    AGENTS: 3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164
    ```

  - **Historical evidence immutability:binary。**CHG-2026-027 original
    TASK-BAP-003 run blob
    `d6eaf28e188b1f5f64317ce4eacad22eae10ab10`、CHG-2026-030 #419 contract
    run blob `610fad98fe97f0618d04adafd313ebb72bdd0549` 与 #421 live failure blob
    `9fc841f46c9b62ff74eede541b00890e1c6f6dbe` 必须 byte-for-byte 不变。
    current mechanism 只通过新 addendum 与 current-status note 指向
    TASK-RPT-001 merged evidence；旧 run 在原日期的事实不删除、不改写、不
    反向标成错误。
  - **Implementation scope:closed。**后一独立 implementation/documentReview PR
    只允许：(1) 向 CHG-2026-027 proposal/tasks/verification 追加 current-mechanism
    pointer，并新增 TASK-BAP-003 append-only addendum；(2) 将 CHG-2026-030
    proposal/design/tasks/verification 作 compatible r8 follow-up，消费上述 merged
    topology evidence；(3) 把 host-loop runbook 的单层 ruleset 归因改为 ordinary
    ruleset + exact-main branch protection；(4) 在本 change TASK-RPT-002 evidence
    目录新增 documentReview。`enforcement.md` 与 `AGENTS.md` 必须零 diff。
  - **HLR-002A readiness boundary:binary。**同一 implementation PR 可作为
    CHG-2026-030 fresh canary-only readiness carrier，但只有在从届时最新 main
    重新读取所有 input blobs、公开 topology/branch/ref 状态、完整 open-PR files，
    确认无 overlap，并生成全新 reserved/ordinary refs 后，才可把 HLR-002A
    `blocked→ready`。该 readiness 只授权既有 creator-partition canary/evidence；
    ruleset、branch protection、repository setting、credential、gateway、
    standing authorization、integration identity 与 scheduler mutation 全部为 0。
    canary execution/evidence/done 仍属于 CHG-2026-030 后续独立 PR，不在
    TASK-RPT-002 implementation 中执行。
  - **Concurrency:closed for this readiness。**只读公开页面显示当前唯一 open
    PR #468，其 diff 仅为 CHG-2026-026 TASK-RKFUI-001A 三个 evidence path，与本
    task 零交集；计划分支
    `agent/task-rpt-002-mechanism-supersession` 与
    `agent/task-hlr-002a-canary-readiness` 均不存在。匿名 REST 配额 403 不被
    猜成完整 API 事实；implementation 开工前必须重做分页/公开页面 + exact diff
    交叉检查，任何不完整或 overlap 均停止。
  - **Permanent supersession:binary。**#435 的 OID/window/before/after/rollback
    payload/hash/ref/UUID/executor、#449/r6 Agent-operated gateway 与 #454
    pins/branch 均只作历史，不复制、不补跑、不改时间复用。TASK-HLR-002B 保持
    superseded `blocked` tombstone。
  - **Review/evidence boundary。**本 readiness PR 只修改本文件 TASK-RPT-002
    状态/readiness 段，GitHub control-plane/ref/probe/credential write = 0。
    implementation PR 可包含其 documentReview evidence，但不翻 TASK-RPT-002
    状态；其合入后另立独立 D0 `ready→done` PR。任一 target blob/evidence
    hash/ancestry/concurrency/topology pointer 漂移、历史 evidence diff、旧
    readiness 值复用、forbidden-path diff、secret/绝对用户路径或无法重现
    `scripts/check-sdd.sh`/`git diff --check`，立即停止并重新 readiness。
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
- Implementation/documentReview candidate:
  `evidence/runs/TASK-RPT-002/2026-07-24-document-review.md`。本
  implementation PR 不翻本任务状态；只有该 evidence 与 current-pointer/r8
  diff 经维护者 review/merge 后，才允许另立独立 D0 `ready→done` PR。
