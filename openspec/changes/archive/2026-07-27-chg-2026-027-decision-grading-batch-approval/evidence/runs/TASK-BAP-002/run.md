# TASK-BAP-002 run — 批次运营载体(implementation 阶段)

- Date:2026-07-23;executor:agent(host-only,docs;零设备/网络副作用)。
- 阶段边界:本 run 只记录 **template + runbook implementation** 阶段;
  首次批次演练(issue、候选、merge 核验、续跑)按 readiness r2 时序在本
  PR 合入后另行执行,届时产出**独立 drill evidence PR**,本 run 不预写
  任何演练结论。

## Governance chain 与 pins 复核

- approval #317 `bc4a68b4888d5018992fb5004f5fbd7216c12419`;readiness r2
  #382 `cfab930722afe60ed5e8759ea0c91d7a178971cc`(contracts 正本)+ r3
  #386 `00bbc5a`(全 OID 见 git 账本;重钉 audit base
  `679c57f43c60a56b8957c3e075208a8037bd5d98`、chg-029 tasks.md blob
  `dc8129773d18349b7e7d5123ce2fa8beefb80b7d`、候选 2 替换为 chg-029
  verify 闭包)。
- 实现开工时(base = r3 合入后 origin/main)对 r2/r3 全部 15 项
  commit/blob authority pins 逐项 `git ls-tree` 复核 = **15/15 零漂移**;
  两个 deliverable 于 base 均不存在(纯新增)。

## 交付与契约对照

1. `openspec/templates/batch-digest.md`:
   - design §2 全字段 ✓(PR 编号/标题、grade、change/task、一句话内容、
     base/head OID、files read-back、风险影响、evidence/测试指针、独立
     exact-head review 结论/finding 指针、依赖与建议顺序、合并前置/仓外
     动作);
   - 首屏声明 ✓(issue/digest 仅导航、逐 PR review/merge、CI 绿与 digest
     均无批准语义、零 auto-merge、遇拒停链、close 仅归档);
   - 入队三门 ✓(CI 绿 / 独立会话 exact-head APPROVE 且 head 变更重审 /
     digest 完整)。
2. `openspec/governance/host-loop-runbook.md`:
   - 状态机逐字 = `advance → queue → all-blocked summary → wait/poll →
     merge-OID verify → rebase --onto → resume` ✓;
   - 覆盖清单 ✓:worktree 隔离、入队三门、producer/reviewer 会话分离
     (head 变更旧 APPROVE 不继承)、按 digest 顺序逐 PR 合并、遇拒停链、
     API/网络/merge 身份不确定即暂停、不以分支消失/elapsed time/
     `mergeable` 推断批准、零 auto-merge、零新服务/bot/credential;
   - credential-compatible polling ✓:gh 零账号不再登录/增 token;PR
     metadata 只经现有 connector/公开只读 API;最终以 Deploy Key
     `git fetch origin main` + ancestry/commit subject 核验;batch issue
     只经现有 connector 写导航内容,connector 不可用即 blocked 回 D1;
     全工具面零 approve/merge 能力。
   - 未改写 enforcement/AGENTS.md/design 或其他权威载体 ✓(纯新增两文件)。

## 检查

- `check-sdd`:0 errors / 0 warnings / 111 acceptance IDs(前后一致);
- 字节级 U+200B/U+FEFF 自检:三文件零命中;
- diff 范围 = allowed paths 内(两个 deliverable + 本 run);tasks.md 未动
  (状态翻转须待演练完成后按 evidence gate 另行 D0 PR)。

## AC 结论(candidate)

`BAP-DRILL-001`:**未达成,预期如此**——本阶段只交付运营载体;PASS 需要
首次演练(≥2 个合格 D0 项同批次按序合并 + 守望 merge-OID 检测续跑)全程
evidence,候选 1 = chg-028 verify、候选 2' = chg-029 verify(r3 钉定),
在本 PR 合入后由各自 lane 天然产出并**留在 open 队列等批次**。

## 偏差与遗留

- 批次 issue(`batch-20260723-1`)创建依赖现有 GitHub connector;本
  producer 会话当前无 connector——drill 开工时由具备 connector 的 watch
  会话执行,或按 r2 条款保持 blocked 回 D1 由维护者决定载体(不新增
  credential)。
- **节奏前提重申(r3 已明写)**:两个候选 PR 产生后必须留在 open 队列;
  再次实时秒合将第四次消耗候选,`BAP-DRILL-001` 无法 PASS。
