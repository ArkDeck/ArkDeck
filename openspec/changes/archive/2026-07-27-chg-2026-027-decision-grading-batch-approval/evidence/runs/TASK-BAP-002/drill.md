# TASK-BAP-002 drill evidence — 首次批次审批演练(batch-20260723-1)

- Date:2026-07-23;记录者:watch 会话(BAP-002 producer/watch,分工见
  readiness r2)。本 PR 只提交演练 evidence,不翻 BAP-002 状态;`ready→done`
  另立独立 D0 PR。
- 队列载体:issue **#395**(`batch-20260723-1`;建前同名复查 = 0)。正文 =
  `openspec/templates/batch-digest.md` 首屏声明 + 两项 digest(全字段)。
- 演练拓扑(如实):watch 会话 orchestrate 并零候选 diff 触碰;两候选各由
  **隔离 lane-producer 子代理会话**起草;合前 review 各由**另一独立 reviewer
  子代理会话**完成——producer/reviewer/watch 三方上下文互相独立,review
  不复用 producer 结论(reviewer 报告含全部独立重跑数字)。

## 批次项与全链 OID

### 项 1:PR #393 — CHG-2026-028 verify(approved → verified)

- base `98593848defa91f73e6537bd7d151d58fcc42428` / head
  `67209ed4d415b37945658a976774f25bdb2b3f99` / merge
  `ee205537de89ab5ad0e3e81fb1f71328228c6a4e`(subject 携 `(#393)`),
  merged_at `2026-07-23T06:07:31Z`。
- 入队三门:① CI = guard ✓ + swift ✓(docs-only 快速路径);
  `allowed-paths` **skipped**(bot-PR 事件缺口,CHG-2026-030 在案,偏差 ③)。
  ② 独立 review = **APPROVE @ head,零 finding**(独立重跑:guard 0/0/111、
  `test_check_sdd` 19/19、`test_check_pr_paths` 20/20、闭包 15 个 merge OID
  祖先性 15/15、公开 API 交叉验证 canary 红/绿 run、码点扫描)。③ digest
  全字段入 #395。
- Grade = D0(verify 翻转,enforcement 列举典型项;三条件复核在 reviewer
  报告)。

### 项 2:PR #396 — TASK-AFP-005 done(ready → done)

- base `21445775cef0837fe98381a1750464bcc2a829f8` / head
  `66f096edef6f8c3524aae412bf45dd3607f6ba70` / merge
  `1b9079268db8e85bee9383f7b705d957f2a9cda3`(subject 携 `(#396)`),
  merged_at `2026-07-23T06:08:16Z`。
- 入队三门:① CI = guard ✓ + swift ✓;`allowed-paths` skipped(同上,
  偏差 ③)。② 独立 review = **APPROVE @ head,零 finding**(独立重跑:
  单 hunk diff 确认、#394 merge 树与其 head 逐字一致、二值门 0 命中/34 链接
  重现、guard 0/0/111、revision 三方 @r4 未触碰)。③ digest 全字段入 #395
  (项 2 段由维护者按 watch 提供文本更新)。
- Grade = D0(done 翻转,done recheck 全部可确定性重现)。

## 合并语义与 watch 核验(runbook `merge-OID verify`)

- 维护者按 digest 声明顺序**逐 PR review/merge**:git 账本证明
  `ee205537…`(#393)是 `1b907926…`(#396)的祖先 = 按序;merged_at 相差
  45s,同一批次场。
- watch 核验(检测时间 `2026-07-23T06:10:31Z`,Deploy Key
  `git fetch origin` 后):两 merge OID 均在 `origin/main` ancestry、subject
  携 `(#N)`;**合入树与 review 过的 exact head 树 diff = 0(两项逐字
  一致)**;chg-028 proposal 于 main 实读 `status: verified`、chg-029
  AFP-005 实读 `done`。API(merged/merge_commit_sha)与 git 账本三源一致。
- `rebase --onto`:本轮无堆叠分支依赖已合项,步骤空转(如实记录)。
- `resume`:续跑产物 = 本 evidence PR;后继 = BAP-002 done 翻转(独立 PR)。

## 偏差清单(全部如实)

1. **队列载体由维护者手建/更新**:watch 会话无 GitHub connector,r2 的
   connector 路径不可用;未回 D1 而由维护者亲手创建并按 watch 提供的
   digest 文本更新 issue——载体仍仅导航、零新 credential,维护者亲手操作
   即构成对该载体形态的接受;后续由 CHG-2026-030 HLR 面解决。
2. **候选四次失效史**(最终以 readiness r4 规则钉定收敛):r1 #378/#379 与
   r2 #384 = 实时合并节奏在入队前消耗候选;r3→r4 = chg-029 r4(#387)天然
   演化使 verify 前提失效。本轮(r4 规则下)一次成功。
3. **`allowed-paths` check 于两候选均 skipped**:`GITHUB_TOKEN` 建 PR 不触发
   `pull_request` 事件(CHG-2026-030 Why 在案);范围一致性由独立 review +
   维护者 review 兜底。
4. **near-miss(lane 协调)**:watch 曾误派重复的 AFP-005 实现 producer,
   发现原 lane 的 #394 后立即叫停,**零推送零残留**;此后流程加入"派发前
   与推送前双重防重复核查"(#396 producer 已执行)。
5. merge 检测触发 = 维护者通知 + API 轮询,终验以 git 账本为准(runbook
   条款,无单源推断)。

## AC 结论(candidate)

`BAP-DRILL-001`:候选 PASS——同批次 **2 个合格 D0 merge**(各自三门齐备、
按 digest 顺序、遇拒停链条款未触发、零 auto-merge、issue 仅导航),全程
PR/head/merge OID、检测时间、ancestry 可复查;runbook/模板与实际流程一致,
偏差 1-5 如实入档。终裁由维护者在 done/verify 流程确认。
