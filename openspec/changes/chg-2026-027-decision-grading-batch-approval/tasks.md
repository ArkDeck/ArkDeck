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

- Status:done(2026-07-23 本独立 D0 状态 PR,仅在维护者 review/merge 后
  生效。Done recheck:① deliverables 实现 #388 merge
  `21a416dbbaa88c17a71a6adf55827169d1f6b9f4`(template + runbook 在 main
  正本);② 首次批次演练完成——issue #395(batch-20260723-1)两项 D0
  按 digest 顺序合并:#393(merge
  `ee205537de89ab5ad0e3e81fb1f71328228c6a4e`)→ #396(merge
  `1b9079268db8e85bee9383f7b705d957f2a9cda3`),各自三门齐备(CI 绿/独立
  exact-head APPROVE/digest 完整),watch 三源核验树等值后自动续跑;
  ③ drill evidence #397 merge
  `0df47e85f3a84ef7b81f4ccd2fe04e4b67eb50c4`,合入版与推送分支 diff 为空,
  偏差 1-5 如实入档,`BAP-DRILL-001` 候选 PASS;evidence gate("演练
  evidence 合入后 ready→done")满足。边界:done ≠ change verified,
  chg-027 verify 须三 AC 齐备另行独立 PR。历史 readiness r2/r3/r4 全文
  保留于下)
- 历史 Status(r2/r3/r4 readiness 记录,实现与演练已完成):ready
  (2026-07-23 本独立 D1 readiness r2,同日 r3/r4 增补(见
  各增补块;r4 = drill 阶段转换与候选 2 规则化);仅在维护者 review/merge
  后生效。四前置闭合:① approval #317 merge
  `bc4a68b4888d5018992fb5004f5fbd7216c12419`;② TASK-BAP-001 done #328
  merge `d1873fb6f4b0d523f9263fcdcffe17b062840247`;③ TASK-BAP-003 execution
  evidence #375 merge `bb61726a7f47b9462296a9beae316dda88218db1` + done #376
  merge `6a6b6b7010b6563d67aa7d96e6838505e82eb25a`;④ 本 readiness 钉定
  deliverables、队列、候选 D0、两会话分工与演练门。r1 #380 曾钉
  #378/#379,但两者在 #380 合入前分别合入 main,故从未成为有效 drill 项;
  r2 fail closed 重钉天然后继。r2 merge 前 BAP-002 lane 不得开
  implementation、batch issue、候选 PR 或 drill evidence PR)
- **Readiness r3 增补(2026-07-23,本 PR;维护者 merge = 接受重钉;r2 其余
  钉定全部原文有效,r3 merge 前实现仍不得开工)**:
  - 触发事实:r2(#382)合入后,独立 AFP lane 的 evidence #383(merge
    `493153f65025f177550071b5c7ac5ea7cb0b90d0`)与 done 翻转 #384(merge
    `5a51ec460409085067bc0e0dacba958d580b79c6`)在任何 batch issue 建立之前
    被实时逐 PR 合并。后果有二:① r2 authority pin
    `chg-2026-029…/tasks.md` blob `bbbda9b9f2ebefbe9b360fe2cade4e70712ed724`
    因 #384 漂移;② **drill 候选 2(AFP-003 ready→done)被消耗——连续第
    三个候选未入批次即被合并(r1 #378/#379 同型)**。按 r2"任一候选提前
    合入…不得临时替换/制造项目,须停下并用独立 D1 readiness re-pin"与
    pins 漂移条款,停止实现、起草本 r3。
  - Re-pin:audit base 前移至 protected main
    `679c57f43c60a56b8957c3e075208a8037bd5d98`(#385 后);
    `openspec/changes/chg-2026-029-agent-failure-prevention/tasks.md` blob
    重钉为 `dc8129773d18349b7e7d5123ce2fa8beefb80b7d`;r2 其余 14 项
    commit/blob pins 已于新 base 逐项复核零漂移,原文继续有效。
  - **候选 2 替换 = `CHG-2026-029 approved → verified`**(与候选 1 同构:
    四个 AFP task 已全部 done 且 evidence 在案;候选 PR 仅可置 proposal
    status `verified`、写 verification closure 并把 verification header
    `planned → passed`,零实现零 evidence 改写;若逐 AC 复核不能由已合入
    状态 + 确定性检查完全得出 PASS,则它不是 D0,演练保持 blocked)。
    顺序固定:候选 1(chg-028 verify)→ 候选 2'(chg-029 verify);由各自
    lane producer 在 template/runbook 合入且前置自然闭合后起草。
  - 队列载体(issue `batch-20260723-1`,r3 起草时以公开 search API 复查
    同名 = 0)、digest/runbook contracts、两会话与人类分工、演练时序、
    failure semantics 全部沿用 r2 原文。
  - **节奏前置(维护者动作,亦是 drill 的物理前提)**:本 r3 与随后的
    implementation PR 可即时合并;但其后两个候选 PR 产生时,**必须留在
    open 队列,等 batch issue 建立、exact-head review 完成后按 digest 顺序
    合并**——再次实时秒合将第四次消耗候选,`BAP-DRILL-001` 在"同批次
    ≥2 个合格 D0 merge"门下将永远无法 PASS。
- **Readiness r4 增补(2026-07-23,本 PR;维护者 merge = 接受;r2/r3 未被
  本块修改的条款继续有效)**:
  - 阶段事实:template/runbook implementation 已交付合入(#388 merge
    `21a416dbbaa88c17a71a6adf55827169d1f6b9f4`,与实现分支逐字一致)。
    **本 change 进入 drill-only 阶段**:r2 的 15 项 authority/input pins
    的使命是锁定实现输入,随实现合入完成使命退役;drill 阶段不再以兄弟
    lane 高频文件为 authority pin——r3 重钉的 chg-029 tasks.md blob
    `dc8129773d18349b7e7d5123ce2fa8beefb80b7d` 已再次因 #387(chg-029 r4,
    merge `d53da289b7da80a4ee2282f5dea3122ebf97325a`)漂移为
    `6211712d85bd719b7384769f8788a745d7249c21`,连续第二次证明该类 pin
    结构性易碎。
  - **候选 2′ 失效(第四次候选失效;本次成因是兄弟 lane 天然演化而非
    合并节奏)**:chg-029 r4 新增 TASK-AFP-005(blocked)并升 verification
    @r4,"四任务全 done 即 verify"前提不再成立,chg-029 verify 闭包不再是
    近期天然 D0。
  - **候选 2 改为规则钉定(维护者 merge 本 r4 = 接受该规则,取代逐次
    re-pin)**:候选 2″ = 候选 1 之后**最先天然产生且经入队三门齐备**的
    D0 状态推进 PR——必须满足 enforcement"决策分级"D0 三条件,digest 中
    逐条说明;仍**禁止为演练制造项目**;候选在入队前被合并 → 该项不计入
    drill,规则自动指向下一个天然产生者(不再逐次 D1 re-pin;这是对连续
    四次候选失效的结构性修复)。当前在途可能来源枚举(仅导航,不构成
    限定):TASK-HLR-001 ready→done、TASK-AFP-005 ready→done。
  - 候选 1 保留 = `CHG-2026-028 approved → verified`(r2 原文条款逐字
    有效);其前置(implementation 合入)已闭合,lane 现可起草;起草后
    **留在 open 队列**。
  - 队列载体与 issue 命名:沿用 r2;若演练跨日,建 issue 时按当日
    `batch-YYYYMMDD-1` 命名(建前复查同名 = 0)并在 digest 首屏注记。
    digest/runbook contracts 已成正本(#388),两会话与人类分工、演练时序、
    failure semantics 其余条款沿用 r2/r3 原文。
- Readiness(r2,base = protected main
  `cfab930722afe60ed5e8759ea0c91d7a178971cc`):
  - **Authority/input pins。**实现开工时以下 commit/blob 任一漂移即停止并
    重做 D1 readiness;完整 hash 只固定输入,不自行构成批准:

    ```yaml pins
    - artifact: TASK-BAP-002 readiness audit base
      commit: cfab930722afe60ed5e8759ea0c91d7a178971cc
    - artifact: CHG-2026-027 approval merge
      commit: bc4a68b4888d5018992fb5004f5fbd7216c12419
    - artifact: TASK-BAP-001 done status merge
      commit: d1873fb6f4b0d523f9263fcdcffe17b062840247
    - artifact: TASK-BAP-003 done status merge
      commit: 6a6b6b7010b6563d67aa7d96e6838505e82eb25a
    - artifact: TASK-BAP-002 readiness r1 merge (candidate pins invalidated)
      commit: 7d04c3dccb598a5e1a1d3b16846162353069dbf2
    - artifact: TASK-MECH-004 done status merge (r1 candidate #378, invalidated)
      commit: 5640614f427e873cf21fce2032c502822d219a30
    - artifact: TASK-AFP-004 done status merge (r1 candidate #379, invalidated)
      commit: 605bff09fdc992478203109b1e5414b207d553b3
    - artifact: TASK-AFP-003 readiness r2 merge
      commit: cfab930722afe60ed5e8759ea0c91d7a178971cc
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
    - path: openspec/changes/chg-2026-028-guard-ci-mechanization/proposal.md
      blob: 2395c2b6f4624d806c2b88cb8769a9a0a5326253
    - path: openspec/changes/chg-2026-028-guard-ci-mechanization/tasks.md
      blob: b1f756b9d71b03508f5a2008d9a0f66a0cc5ad46
    - path: openspec/changes/chg-2026-028-guard-ci-mechanization/verification.md
      blob: ea9ed46a42d9807606c1fc4291a393d34c7e38e0
    - path: openspec/changes/chg-2026-028-guard-ci-mechanization/acceptance-cases.yaml
      blob: 7fbd0708aad6bf84d6a1b88f77779bd99c3fa40d
    - path: openspec/changes/chg-2026-028-guard-ci-mechanization/evidence/runs/TASK-MECH-001/run.md
      blob: f5e51fad2f2a429748126eee27ab61df282c2f23
    - path: openspec/changes/chg-2026-028-guard-ci-mechanization/evidence/runs/TASK-MECH-002/run.md
      blob: f435c864bca7d8b2fc18f27029c3ecaa55bd85fb
    - path: openspec/changes/chg-2026-028-guard-ci-mechanization/evidence/runs/TASK-MECH-003/run.md
      blob: 9c5d9aa06320cda9e73e7613f604a9e99a0e9818
    - path: openspec/changes/chg-2026-028-guard-ci-mechanization/evidence/runs/TASK-MECH-004/run.md
      blob: dfd6c464ef88b955458c8b8b256987f75709892c
    - path: openspec/changes/chg-2026-029-agent-failure-prevention/tasks.md
      blob: bbbda9b9f2ebefbe9b360fe2cade4e70712ed724
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
  - **两个天然 D0 候选源(顺序固定,不为演练制造)。**r1 的 #378/#379
    已在本 readiness merge 前由维护者分别合入
    `5640614f427e873cf21fce2032c502822d219a30` /
    `605bff09fdc992478203109b1e5414b207d553b3`,不得追记进 drill。r2
    只选择本来就会发生的两个后继状态面:
    1. `CHG-2026-028 approved → verified`:四个 MECH task 已在 protected
       main 全部 `done`,四份 run 与四条 change-local AC 均在案。候选仅可
       把 proposal status 置 `verified`、在 proposal 写 verification closure
       并把 verification header `planned → passed`;不得追加/修改实现、
       evidence、task、required-status 或 archive。若逐 AC 复核不能由已合入
       状态 + 确定性检查完全得出 PASS,则它不是 D0,演练保持 blocked。
    2. `TASK-AFP-003 ready → done`:该 host-only historical detection drill
       已由独立 D1 readiness r2 #381 合入
       `cfab930722afe60ed5e8759ea0c91d7a178971cc` 且在 base 为 `ready`;
       其 implementation/evidence 尚未产生
       (`evidence/runs/TASK-AFP-003/` 在 base 不存在)。
       只有 AFP lane 自然完成 implementation/evidence PR、由维护者合入且
       run 闭合 `AFP-DRILL-001` 后,才可由该 lane 起草仅改本 task 状态/
       evidence 引用的 D0 候选。本 lane 不执行 AFP-003、不补 evidence、
       不代起草其状态 PR。

    两项改不同 change、互无依赖,首轮 drill 仍按上述 1→2 顺序逐 PR
    review/merge。候选 PR 只在 template/runbook implementation 合入且各自
    前置自然闭合后起草;创建时把 base/head OID 与 files read-back 写入 digest。
    任一候选提前合入/关闭、head 漂移、evidence 被 supersede 或不再满足 D0
    三条件,不得临时替换/制造项目,须停下并用独立 D1 readiness re-pin。
  - **两会话与人类分工。**CHG-2026-028 verify closure 与 AFP-003 的
    implementation/evidence/status 各由其独立 lane producer 负责;BAP-002
    producer/watch 会话只负责实现 template+runbook、读取而不修改候选、
    填 digest、poll 并以 merge OID 自动续跑。独立 reviewer 会话不得参与
    上述 diff,对每个候选 exact head 做合前 review,只写 `APPROVE` 或 finding
    指针。发现修改后必须对新 head 重审,旧 APPROVE 不继承。维护者 `lvye`
    只按 issue 声明顺序逐 PR review/merge;会话与 workflow 均不得代为批准
    或合并。
  - **演练时序与 evidence。**模板/runbook implementation PR 先独立
    review/merge;随后才创建 issue,等待上述两 lane 的天然候选,不另造项目。
    两候选各自满足
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
  - **Environment/concurrency。**初次 r1 audit 时 GitHub open PR 查询结果
    = 0、同名 batch issue = 0;其后 #378 于 `2026-07-23T03:13:43Z`、#379
    于 `2026-07-23T03:15:02Z`、本 readiness #380 于
    `2026-07-23T03:15:37Z` 依次创建。#378/#379 又分别于
    `2026-07-23T03:18:49Z`/`2026-07-23T03:19:17Z` 在 #380 合入前合并,
    因而 r1 候选失效且 drill 计数仍为 0;#380 于
    `2026-07-23T03:20:29Z` 合入。r2 首次 audit 时 open PR = 0;随后独立
    AFP lane 的 readiness r2 #381 于 `2026-07-23T03:25:37Z` 创建并在
    `2026-07-23T03:27:25Z` 合入,本 r2 重新读取其 merge/blob 后继续;
    当前 open PR 仅本 readiness r2 #382。
    该并发来自不同 task lane,不是 BAP-002 越过 D1 门的成 PR 工作。
    host-only docs/metadata,零设备、零硬件、零 device/network product
    effect。实现前须重新检查 open PR、同名 issue 与上述 pins;路径竞争或
    不可判定状态即暂停。
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

### Current mechanism note（2026-07-24；append-only）

TASK-BAP-003 的 `done` 与 2026-07-23 run 均保持原义。CHG-2026-033
TASK-RPT-001 后续以两层 topology 重新验证同一高层 AC：ordinary ref 拒绝来自
ruleset `19595282`，exact `main` 拒绝来自 branch protection，维护者凭据隔离与
actor/route containment 由其独立 authenticated evidence 证明。current pointer 与
历史/current 分界见
`evidence/runs/TASK-BAP-003/2026-07-24-ref-protection-topology-addendum.md`。
该 note 不重开、不重做或重新标记 TASK-BAP-003，也不把旧 direct-main
GH013 transcript 当作当前 main enforcement 的因果证据。
