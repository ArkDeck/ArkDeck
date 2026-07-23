# CHG-2026-027 Tasks

> 三任务:BAP-001(规则正本)与 BAP-003(凭据分离,human 执行)可并行,
> BAP-002(运营载体 + 首次演练)blocked 于两者 done。本 change 首 PR 只
> proposal 五件套,零实现、零 evidence。

## TASK-BAP-001 — 决策分级与批次审批协议入正本(host-only,docs)

- Status:done(2026-07-22 本独立状态 PR,仅在维护者 review/merge 后生效。
  Done recheck:实现 PR #327 merge
  `42cc63123738313d253b25c9de78220e1e6814b5`,合入版与实现分支
  `git diff` 为空(逐字一致);enforcement.md 2.1.0 两小节 + AGENTS.md 批次
  协作条在 main 在案;design §0 六不变量逐条对照与检查记录见
  `evidence/runs/TASK-BAP-001/run.md`;check-sdd 于合入版 0/0/111。
  边界注记:done ≠ change verified;BAP-002 仍 blocked 于本任务 done +
  TASK-BAP-003 done 双前置,本翻转满足其一)
- Readiness(r1,base = main `c15814593ea3d46149e749d3a47121ea70af1cea`;
  历史记录,实现已于 #327 交付):
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

- Status:ready(2026-07-23 本独立 D1 readiness r1;仅在维护者 review/merge
  后生效。四前置闭合:① approval #317 merge
  `bc4a68b4888d5018992fb5004f5fbd7216c12419`;② TASK-BAP-001 done #328
  merge `d1873fb6f4b0d523f9263fcdcffe17b062840247`;③ TASK-BAP-003 execution
  evidence #375 merge `bb61726a7f47b9462296a9beae316dda88218db1` + done #376
  merge `6a6b6b7010b6563d67aa7d96e6838505e82eb25a`;④ 本 readiness 钉定
  deliverables、队列、候选 D0、两会话分工与演练门。merge 前不得开
  implementation、候选状态 PR、batch issue 或 drill evidence PR)
- Readiness(r1,base = protected main
  `21d339b97d083f1e79c1851854737d5cf0a68d8e`):
  - **Authority/input pins。**实现开工时以下 commit/blob 任一漂移即停止并
    重做 D1 readiness;完整 hash 只固定输入,不自行构成批准:

    ```yaml pins
    - artifact: TASK-BAP-002 readiness audit base
      commit: 21d339b97d083f1e79c1851854737d5cf0a68d8e
    - artifact: CHG-2026-027 approval merge
      commit: bc4a68b4888d5018992fb5004f5fbd7216c12419
    - artifact: TASK-BAP-001 done status merge
      commit: d1873fb6f4b0d523f9263fcdcffe17b062840247
    - artifact: TASK-BAP-003 done status merge
      commit: 6a6b6b7010b6563d67aa7d96e6838505e82eb25a
    - path: AGENTS.md
      blob: 3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164
    - path: openspec/governance/enforcement.md
      blob: e8ff3c130e1b8b15f8405d150ad567e774a0d82b
    - path: openspec/changes/chg-2026-027-decision-grading-batch-approval/design.md
      blob: 4655325a34d091c856ebb5eb1c11936c492c76c3
    - path: openspec/changes/chg-2026-027-decision-grading-batch-approval/verification.md
      blob: 039d6b5418d546c34c0717ba28272acb48006d86
    - path: openspec/changes/chg-2026-027-decision-grading-batch-approval/acceptance-cases.yaml
      blob: 1981dcadad0b9280f88c400ff7086356c0136a4a
    - path: openspec/changes/chg-2026-028-guard-ci-mechanization/tasks.md
      blob: 6353c97c159a65f8d8a2e269d1cbf70d4ab6e2b2
    - path: openspec/changes/chg-2026-028-guard-ci-mechanization/evidence/runs/TASK-MECH-004/run.md
      blob: dfd6c464ef88b955458c8b8b256987f75709892c
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/tasks.md
      blob: dec71a6d67f5f9a7e94ded0f00b88c9601e1eb51
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/evidence/runs/TASK-AFP-004/run.md
      blob: 4eed9d2f5ab8d79ef681a6d1473ed31b71d5242b
    ```

    两个 deliverable 在 base 均不存在:
    `openspec/templates/batch-digest.md`、
    `openspec/governance/host-loop-runbook.md`;实现 PR 新增二者,不得改写
    enforcement/AGENTS.md/design 或其他权威载体。
  - **Digest template contract。**`batch-digest.md` 必须含 design §2 全字段:
    PR 编号/标题、grade、change/task、一句话内容、风险与影响面、evidence/
    测试指针、独立 AI exact-head 合前 review 结论或 finding 指针、依赖与
    建议合并顺序、合并前置/仓外动作;模板首屏明写 issue/digest 仅导航、
    每个 PR 仍由维护者逐项 review/merge、CI 绿与 digest 均无批准语义、
    零 auto-merge。
  - **Runbook contract。**`host-loop-runbook.md` 固定
    `advance → queue → all-blocked summary → wait/poll → merge-OID verify →
    rebase --onto → resume` 状态机,并覆盖:worktree 隔离;入队三门;不同
    producer/reviewer 会话;按 digest 顺序逐 PR 合并;遇拒停止依赖链;API/
    网络/merge 身份不确定时保持暂停;不以分支消失、elapsed time 或
    `mergeable` 推断批准;零 auto-merge、零新服务/bot/credential。
  - **Credential-compatible polling。**TASK-BAP-003 后本机 `gh` 无账号,
    不得为 poll 重新登录维护者或增加 token。PR metadata 可由现有 GitHub
    connector/公开只读 API 读取,最终 merge OID 必须再以 Deploy Key
    `git fetch origin main` + ancestry/commit subject 核验。batch issue
    只允许现有 GitHub connector 创建/更新导航内容,不得执行 approve/merge。
  - **Queue carrier。**首次演练 issue 钉为 ArkDeck/ArkDeck
    `batch-20260723-1`(本 readiness audit 时同名历史 issue = 0);正文按
    新模板列两项 digest 与固定顺序,close 仅表示导航归档。若 title 冲突、
    issue 写能力不可用或需新 credential,演练保持 blocked 并回到 D1,
    不改用仓内批准文件。
  - **两个天然 D0 候选(顺序固定,不为演练制造)。**
    1. `TASK-MECH-004 ready → done`:r3 implementation #373 merge
       `0c10364addc0d5a70f093d69ecc61b8bfb075b09`;evidence closure #377
       merge `9df5642620ca07584c822d43f95d6cc5df187360`;main 中 task 仍为
       `ready`,其 run 已把 `MECH-PATH-001` evidence gate 置为 PASS。
       候选 PR 只改 CHG-2026-028 `tasks.md` 的本任务状态。
    2. `TASK-AFP-004 ready → done`:implementation/evidence #374 merge
       `21d339b97d083f1e79c1851854737d5cf0a68d8e`;main 中 task 仍为
       `ready`,run 记录 `AFP-CORRECT-001` PASS。候选 PR 只改 CHG-2026-029
       `tasks.md` 的本任务状态。

    两项改不同文件、互无依赖,但首轮 drill 仍按上述 1→2 顺序逐 PR
    review/merge。任一候选被他方提前翻转、evidence 被 supersede、pin 漂移
    或不再满足 D0 三条件时,不得临时替换/制造项目;须停下并用独立 D1
    readiness re-pin 新的天然候选。
  - **两会话与人类分工。**producer/watch 会话负责实现模板+runbook、在其
    implementation PR 合入后起草两个候选状态 PR、填 digest、poll 并以
    merge OID 自动续跑;独立 reviewer 会话不得参与上述 diff,对每个候选
    exact head 做合前 review,只写 `APPROVE` 或 finding 指针。发现修改后
    必须对新 head 重审,旧 APPROVE 不继承。维护者 `lvye` 只按 issue 声明
    顺序逐 PR review/merge;会话与 workflow 均不得代为批准或合并。
  - **演练时序与 evidence。**模板/runbook implementation PR 先独立
    review/merge;随后才创建 issue 与两个候选 D0 PR。两候选各自满足
    guard/适用 CI 绿 + 独立 exact-head APPROVE + digest 完整后才入队。
    watch 对每次合并记录 PR/head/merge OID、检测时间与 ancestry,检测失败
    即暂停;两项均确认后自动续跑为本 change 的独立 drill evidence PR,
    记录 issue、顺序、review、checks、merge OID、`rebase --onto`/续跑与
    全部偏差。该 evidence PR 不翻 BAP-002 状态;其合入后另立 D0
    `ready → done` PR。
  - **Failure semantics。**候选被拒/要求修改时按协议停止其依赖链并记
    deviation;两个候选虽独立,另一项可由维护者决定是否继续,但
    `BAP-DRILL-001` 在同批次不足两个合格 D0 merge 时不得 PASS。任何
    digest/PR 漂移、未 approved scope、判断门后投机 PR、auto-merge 或把
    issue 当批准载体均使 drill fail closed。
  - **Environment/concurrency。**readiness audit 时 GitHub open PR = 0、
    同名 batch issue = 0;host-only docs/metadata,零设备、零硬件、零
    device/network product effect。实现前须重新检查 open PR 与上述 pins;
    路径竞争或不可判定状态即暂停。
  - **Verification gate。**实现 PR 至少跑 `scripts/check-sdd.sh` 与
    `git diff --check`,并逐条对照 design §0/§2/§4;drill evidence 按
    `BAP-DRILL-001` 做 documentReview。只以 merged OID + exact-head
    review/checks 判定,不把任务勾选或 issue close 记为通过。
  - **Review boundary。**本 readiness PR 只修改本 `tasks.md` 的
    TASK-BAP-002 状态段,零 deliverable、零 issue、零候选状态 PR、零
    evidence;implementation、drill evidence 与 `ready → done` 各自独立。
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

- Status:done(2026-07-23 本独立 D0 状态 PR,仅在维护者 review/merge 后生效。
  Done recheck:human execution evidence PR #375 merge
  `bb61726a7f47b9462296a9beae316dda88218db1` 已在 main;ruleset
  `19595282` 与非 bypass Deploy Key `158088026` 在案;`agent/cred-probe`
  创建/删除成功,普通分支创建与直接更新 main 均收到 GH013 ruleset rejection;
  测试前后 main OID 均为
  `e48673fbe8c8440d7e12dbfe6aea5e94f996a4e2`;维护者凭据不可达检查 PASS。
  可复查记录见 `evidence/runs/TASK-BAP-003/run.md`;边界注记:done ≠ change
  verified,TASK-BAP-002 仅在本 PR 合入后满足其 TASK-BAP-003 done 前置)
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
