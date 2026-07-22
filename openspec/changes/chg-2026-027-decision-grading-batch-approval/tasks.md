# CHG-2026-027 Tasks

> 三任务:BAP-001(规则正本)与 BAP-003(凭据分离,human 执行)可并行,
> BAP-002(运营载体 + 首次演练)blocked 于两者 done。本 change 首 PR 只
> proposal 五件套,零实现、零 evidence。

## TASK-BAP-001 — 决策分级与批次审批协议入正本(host-only,docs)

- Status:blocked(双前置:① CHG-2026-027 经 approval-only PR 批准;② 独立
  readiness PR——须钉 enforcement.md 与 AGENTS.md 的 base blob OID(全 OID)
  并复核与在途 change 的文本零冲突)
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

- Status:blocked(双前置:① approve;② 独立 readiness PR——须钉凭据机制
  (GitHub ruleset/deploy key/GitHub App 等,design §5)、作用面与正负双向
  验证步骤)
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
