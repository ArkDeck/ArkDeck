# CHG-2026-027 Tasks

> 三任务:BAP-001(规则正本)与 BAP-003(凭据分离,human 执行)可并行,
> BAP-002(运营载体 + 首次演练)blocked 于两者 done。本 change 首 PR 只
> proposal 五件套,零实现、零 evidence。

## TASK-BAP-001 — 决策分级与批次审批协议入正本(host-only,docs)

- Status:ready(2026-07-22 本 readiness PR;前置 ① 已满足 = approval #317
  merge `bc4a68b4888d5018992fb5004f5fbd7216c12419`;状态仅在维护者
  review/merge 本 PR 后生效)
- Readiness(r1,base = main `c15814593ea3d46149e749d3a47121ea70af1cea`):
  - Governance chain:propose #315 merge
    `7a58b026646a3b1ed543cc5e941ddb1d1e02206f`;approval #317 merge
    `bc4a68b4888d5018992fb5004f5fbd7216c12419`(status:approved 生效)。
  - 待改文件 pins(实现时任一漂移即停并重做 readiness):

    ```yaml pins
    - path: openspec/governance/enforcement.md
      blob: eeea673aa62a6dbd6c0c1c873e451de90f3c01f4
    - path: AGENTS.md
      blob: 096776024275057487fcf14bf574ffe18463049c
    ```

    (pins 采用 CHG-2026-028 design §3 定稿的 fenced `pins` block 结构,
    先行实践该惯例;MECH-003 校验落地前由 review 把关。)
  - 实现边界:enforcement.md 只在"批准语义"节 ADDED"决策分级"与"批次审批
    协议"两小节 + header 版本 2.0.0→2.1.0,不触碰信任模型/CI 校验(sdd-guard)/
    真实硬件与 destructive 操作/Baseline/V1 遗留清理各节既有文本;AGENTS.md
    只在"执行规则"节追加批次协作条目(批次组织 + 判断门后零投机堆叠),
    不动权威顺序/信任与批准/Agent 禁令各节。两文件表述与 design §0 六条
    不变量逐条一致是合前 review 门。
  - 竞争面:readiness 审计时(2026-07-22,base 上)zero open PR;在途
    chg-2026-025 lane 的实现面为 Kit 文件与其 change 目录,与本任务两文件
    零交集。本批次内 BAP-003 readiness 与本 PR 同文件(tasks.md)不同段,
    后合者如冲突 update-branch 即可。
  - 基线:check-sdd 于 base = 0 errors / 0 warnings / 111 acceptance IDs;
    本任务零 Swift 面、零设备、零网络。
  - Review boundary:本 PR 只翻转 `blocked→ready` 并登记 pins/边界;实现 PR、
    `ready→done` 状态 PR 各自独立,均须维护者 review/merge。
- Objective:enforcement.md"批准语义"节 ADDED"决策分级"(D0/D1/D2 定义与
  三条件判定标准,design §1)与"批次审批协议"(队列载体/digest/按序逐 PR
  合并语义/入队门/遇拒停链,design §2)两小节,版本 2.0.0 → 2.1.0;AGENTS.md
  执行规则同步(批次协作约定 + 判断门后零投机堆叠,design §3);两文件表述
  与 design §0 六条不变量逐条一致。
- Requirements/AC:change-local `BAP-GOV-001`(见 acceptance-cases.yaml)。
- Depends on:approve。
- In scope:enforcement.md 上述两小节与版本号;AGENTS.md 执行规则节;本
  change evidence run。
- Out of scope:任何 POL-* 条款文本;信任根/权威顺序表述;guard/CI 脚本;
  digest 模板与 runbook(BAP-002);任何形式的 auto-merge。
- Allowed paths:`openspec/governance/enforcement.md`、`AGENTS.md`、本 change
  `evidence/**`、本 change `tasks.md`(仅本任务状态)。
- Risk:low(纯治理文档;语义错误的代价由 approval/readiness/实现三层 review
  兜底)。
- Hardware required:no。
- Verification:`BAP-GOV-001` documentReview;check-sdd 绿。
- Evidence gate:实现 PR 合入后 `ready→done` 独立状态 PR。

## TASK-BAP-002 — 批次运营载体与首次批次演练

- Status:blocked(四前置:① approve;② TASK-BAP-001 done;③ TASK-BAP-003
  done(无人值守吞吐扩大前凭据分离必须在位,design §5);④ 独立 readiness
  PR——须钉 digest 模板与 runbook 落点、队列载体形态、演练候选 D0 项与两会话
  (实现/review)分工)
- Objective:交付 `openspec/templates/batch-digest.md`(digest 模板:design §2
  全字段)与 `openspec/governance/host-loop-runbook.md`(守望循环 runbook:
  推进→入队→全阻塞汇总→检测合并→rebase 续跑状态机、入队三门、暂停与遇拒
  停链语义,design §4);随后执行**首次批次演练**:≥2 个真实 D0 项(来自
  在途 lane 天然产生的翻转,不为演练制造)各携独立 AI 合前 review APPROVE
  经 digest 入队 → 维护者按 digest 声明顺序逐 PR 合并 → 守望会话凭合并检测
  自动续跑,全程 evidence。
- Requirements/AC:change-local `BAP-DRILL-001`(见 acceptance-cases.yaml)。
- Depends on:approve、TASK-BAP-001 done、TASK-BAP-003 done。
- In scope:上述两新文件;演练的 digest、批次 issue 引用、合并 OID 清单、
  续跑记录 evidence。
- Out of scope:guard/CI 机械化;对任何在途 change 的实质改动;auto-merge。
- Allowed paths:`openspec/templates/batch-digest.md`、
  `openspec/governance/host-loop-runbook.md`、本 change `evidence/**`、本
  change `tasks.md`(仅本任务状态)。
- Risk:low-medium(演练涉及真实 lane 的真实合并;失败模式 = 回退到逐 PR
  实时模式,零持久损失)。
- Hardware required:no。
- Verification:`BAP-DRILL-001`——演练全程可复查、批次内零未 approved scope
  的实现内容、续跑由合并检测触发而非猜测;check-sdd 绿。
- Evidence gate:演练 evidence 合入后 `ready→done` 独立状态 PR。

## TASK-BAP-003 — Agent 凭据分离落实(human 执行项)

- Status:ready(2026-07-22 本 readiness PR;前置 ① 已满足 = approval #317
  merge `bc4a68b4888d5018992fb5004f5fbd7216c12419`;状态仅在维护者
  review/merge 本 PR 后生效;执行者 = 维护者,仓外窗口任意、无设备)
- Readiness(r1,base = main `c15814593ea3d46149e749d3a47121ea70af1cea`;
  维护者 merge 本 PR = 接受下述机制方案):
  - 机制钉定:**repository ruleset + 非 bypass 机器凭据**——
    (a) GitHub 仓库侧建 ruleset:target = 全部 branch ref,exclude
    `refs/heads/agent/**`;rules = restrict creations/updates/deletions;
    bypass list = 仅维护者(repo admin)。受保护 main 的既有分支保护不动,
    该 ruleset 是叠加收权。
    (b) Agent 运行环境凭据换为无 bypass 资格的机器身份:机器账号
    (collaborator write)+ fine-grained PAT,或 deploy key——择一落地,
    evidence 记实际形态与作用面(凭据值/token 永不入仓入日志)。
    (c) 维护者本人账号凭据与批准动作从 Agent 可达的进程/keychain/
    gh 配置中移除。
  - 验证步骤(全部记 evidence):正向 = 以 agent 凭据 push
    `agent/cred-probe`(成功后删分支);负向 = 同凭据 push
    `refs/heads/cred-probe-denied` 与直接 push `main` → 均须被 ruleset 拒,
    拒绝输出原样(脱敏)记录。双向齐备才算 PASS。
  - 影响面注记:`agent-pr` workflow(blob
    `2b9b03a90d70671d85da21be6a667e2f2f9c8acb`)以 github-actions bot token
    开 PR,与推送凭据无关,auto-PR 机制不受影响;收权后 agent 推送
    `.github/workflows/**` 的能力受 PAT `workflow` scope 约束,MECH-001/004
    交付形态按 CHG-2026-028 design §5 处理(agent 起草 + 维护者应用)。
  - 附带面(可同窗口顺带,不属本任务 AC):V1 三私钥删除/轮换、GitHub
    secrets `ARKDECK_TRUST_BUNDLE`/`ARKDECK_LEDGER_KEY` 清理。
  - Review boundary:本 PR 只翻转 `blocked→ready` 并登记方案;执行记录
    (evidence PR)与 `ready→done` 状态 PR 各自独立,均须维护者 review/merge。
- Objective:落实 enforcement.md 信任模型第 3 条与"V1 遗留清理"悬置项:Agent
  运行环境仅持能推送 `agent/**` 的受限凭据;维护者账号凭据与批准动作不出现
  在 Agent 可达的进程/密钥环;正向(`agent/**` 推送成功)+ 负向(非
  `agent/**` ref 推送被拒)双向验证记 evidence。执行者 = 维护者(GitHub
  设置与本机凭据配置均在仓外)。
- Requirements/AC:change-local `BAP-CRED-001`(见 acceptance-cases.yaml)。
- Depends on:approve。
- In scope:GitHub 侧配置(仓外)、Agent 环境凭据核查、evidence run(凭据值/
  token 零入仓零入日志)。
- Out of scope:V1 遗留的私钥删除/轮换与 GitHub secrets 清理(同为人类动作项,
  可同窗口顺带但不属本任务 AC);CI workflow 改动。
- Allowed paths:本 change `evidence/**`、本 change `tasks.md`(仅本任务
  状态)。
- Risk:low(收权动作;配置错误的失败模式 = agent 推送被拒,fail closed,
  即时可见)。
- Hardware required:no。
- Verification:`BAP-CRED-001` documentReview——双向证据在案、凭据值零入仓;
  check-sdd 绿。
- Evidence gate:evidence 合入后 `ready→done` 独立状态 PR。
