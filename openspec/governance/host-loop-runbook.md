# Host-loop runbook(守望循环操作约定)

> 交付:CHG-2026-027 TASK-BAP-002。语义正本 =
> `openspec/governance/enforcement.md`"决策分级"与"批次审批协议"两节与
> `AGENTS.md` 批次协作条;本 runbook 只细化操作,不得放宽正本。
> 运行载体 = AI 会话(harness 侧循环),**不是产品代码、不是 CI、零新
> 服务、零新 bot、零新 credential**;runbook 改版走 PR。

## 状态机(固定顺序,不得增删跳步)

`advance → queue → all-blocked summary → wait/poll → merge-OID verify →
rebase --onto → resume`

1. **advance**:各 lane 在**各自 git worktree** 内推进 approved change 的
   ready 任务;D1/D2 判断门之后的成 PR 工作在该门合入前不得开工(唯一
   允许的预跑 = 不产生 PR 的采集/勘察);D0 机械序列可同 lane 连续推进。
2. **queue**:lane 产出 PR 且**入队三门**(guard/适用 CI 绿、独立会话
   exact-head APPROVE、digest 完整)齐备后,按
   `openspec/templates/batch-digest.md` 把 digest 写入当期批次 issue
   (`batch-YYYYMMDD-N`);未过三门的 PR 不入队、不催合。
3. **all-blocked summary**:全部 lane 都阻塞在人类门时,更新批次 issue
   汇总(项数、顺序、依赖、D2 项所需仓外动作)并通知维护者;不逐项催。
4. **wait/poll**:等待维护者按 digest 顺序逐 PR review/merge。PR metadata
   仅经**现有 GitHub connector 或公开只读 API** 读取;API 限流、网络失败、
   数据不完整 = 保持等待,不猜测、不重试轰炸、不为 poll 登录任何账号或
   新增 token。
5. **merge-OID verify**:对每个声称已合并的项,以 Deploy Key 执行
   `git fetch origin main` 后核验:merge OID 位于 `origin/main` ancestry,
   且 commit subject 携 `(#N)` 关联。**不以分支消失、elapsed time、
   `mergeable`/API 单源字段推断批准**;connector/API 与 git 账本不一致 =
   暂停并向维护者报告,不续跑。
6. **rebase --onto**:squash 合并惯例下,堆叠分支以
   `git rebase --onto origin/main <前序分支>` 剥离已合入 commit;冲突即停
   人工介入,不强推。
7. **resume**:按 digest 依赖图续跑后继工作(done 翻转、下一任务、下一
   批次项),回到 `advance`。每次续跑在 evidence/日志记录触发它的
   merge OID 与检测时间。

## 角色分离(不得复用)

- **producer/watch 会话**:实现、填 digest、poll、核验、续跑;不得 review
  自己产出的 diff,不得把实现结论充作独立 review。
- **reviewer 会话**:独立于 producer,对 exact head 做合前 review,只写
  `APPROVE @ <head-OID>` 或 finding 指针;head 变更后旧 APPROVE 不继承,
  必须对新 head 重审。
- **维护者**:按批次 issue 声明顺序逐 PR review/merge;会话与 workflow
  均不得代为 approve 或 merge。

## Failure semantics(全部 fail closed)

- **遇拒停链**:被拒项回炉走正常修复,其依赖链后续项本轮不合并;偏差记
  deviation 入 evidence。
- **候选/入队项失效**:提前合入、被 close、head 漂移、evidence 被
  supersede、不再满足 D0 三条件——一律停下,用独立 D1 readiness re-pin
  重钉,不临时替换、不为凑数制造项目。
- **不确定即暂停**:poll 失败、merge 身份不明、API 与 git 账本冲突、
  凭据异常——保持暂停并汇报,不猜测续跑。
- **协议违规即 fail**:任何 auto-merge、把 issue/digest 当批准载体、
  判断门后投机成 PR、绕过入队三门——所在批次/drill fail closed 并如实
  入档(evidence/postmortem)。

## Credential 边界(TASK-BAP-003 之后的形态)

- 本机 `gh` 零账号;Agent 写操作面 = Deploy Key 推送 `refs/heads/agent/**`
  (single/multi-level Agent namespace 由
  `refs/heads/agent/**` + `refs/heads/agent/**/*` 精确排除)。
- ruleset `agent-ref-boundary` 对除 Agent namespace 与 exact
  `refs/heads/main` 之外的 ordinary refs 继续以 creation/update/deletion
  restrictions fail closed；唯一 bypass actor 是人类 `lvye`。
- exact `main` 由独立 branch protection fail closed：必须走 PR，要求
  `@lvye` CODEOWNER approving review 与 App `15368` 的 `guard`，管理员同样受
  enforcement；push allowlist 仅 `lvye`，Deploy Key/Actions/App/integration
  均不在内，force-push、deletion 与 auto-merge 禁止。`lvye` 在 allowlist
  不等于可 direct push，仍须满足 PR/review/check。
- current topology 与正负矩阵的权威 evidence 为 CHG-2026-033
  TASK-RPT-001；CHG-2026-027 TASK-BAP-003 原 run 只保留其执行日历史，不再把
  main 拒绝归因于 current ruleset。
- 批次 issue 的创建/更新(仅导航内容)只经现有 GitHub connector;connector
  不可用或需要新 credential 时,该步保持 blocked 并回到 D1,不改用仓内
  批准文件、不新增凭据。
- 任何工具面都无 approve/merge 能力;这不是实现限制,是协议边界。
