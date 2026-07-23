# CHG-2026-030 Design — host-loop runtime

> Status:draft；本设计只约束本 change 的候选实现。与 Constitution、AGENTS.md、
> enforcement.md 或 CHG-2026-027 冲突时，停止并以高层规则为准。

## 1. Non-negotiable boundaries

1. protected `main` + 维护者 CODEOWNER review/merge 仍是唯一批准事实；CI、
   envelope、Issue、lease、review result 和 runtime log 均不是批准事实。
2. runtime 绝不 merge、作 GitHub approval、设置 task/change 状态，或修改 branch
   protection/credentials；D2 配置也不由 runtime 创建或修改。
3. worker 与 reviewer 是不同 run ID、不同工作目录、不同 execution session。reviewer
   只读实现 head 和证据，不得提交实现或改 PR body。
4. 所有 host command 使用 executable + argv；PR title/body、branch、Issue content
   和 API 返回值只作为 data，不参与 shell 拼接。
5. 任何 GitHub state write 都先做 deterministic identity lookup，再重读目标状态；
   不确定、歧义、API timeout 或 fence mismatch 全部 fail closed。

## 1A. Integration credential containment（r2）

GitHub 的 repository permission category 不是逐 endpoint capability。官方 GitHub App
权限表把 `POST /repos/{owner}/{repo}/pulls` 与
`POST /repos/{owner}/{repo}/pulls/{pull_number}/reviews` 同列为
`Pull requests:write`，并把 ref write 与 merge endpoint 同列在
`Contents:write`。因此 r1 所写“能创建 PR/ref，但 credential 没有 review/merge API
权限”在平台上不可表达；不得以 self-approval 被拒或 runtime 当前没有调用代码伪称
permission category 不存在。

r2 使用三层闭合边界，缺一即 `blocked`：

1. **Platform minimum。**D2 readiness 钉定实际非 `GITHUB_TOKEN` identity、单仓
   installation/repository scope 与完成 PR/Issue/`agent/**` ref 所需的最小 permission
   categories；Administration、Actions、Workflows、Members、Secrets 等管理面均为
   none。identity 不得是 CODEOWNER，也不得出现在 branch protection/ruleset bypass。
2. **Typed adapter。**worker 只依赖封闭的 PR lookup/create/update、Issue
   lookup/create/update 与 `agent/**` ref read/create/CAS/delete 方法；transport 不提供
   generic REST/GraphQL method。review submit/dismiss、merge/auto-merge、branch update、
   protection/ruleset/repository admin 的 method/route 构造数恒为 0。HLR-003 用 fake
   transport、route inventory 与 source scan 同时证伪 escape hatch。
3. **Live authority probes。**维护者用实际 identity 证明 protected `main` 直接写拒绝，
   integration-authored probe PR 的 self-approval 与 merge 拒绝，admin same-value
   mutation probe 拒绝，且 identity 不是 CODEOWNER/bypass。任一请求意外成功，立即停
   scheduler、撤销 identity、保留脱敏事实并把任务维持 `blocked`；不得把 cleanup 后
   “无净变化”记成 PASS。

这里区分 endpoint coverage 与 authority：共享 write category 的潜在 coverage 是
GitHub 平台约束，不是 runtime 授权；protected-main rules + human-only CODEOWNER +
typed adapter 共同保证 automation 无批准/合并权威。独立 AI review 仍只产生仓外
`APPROVE`/`REQUEST_CHANGES`/`BLOCKED` 结果，绝不调用 GitHub review API。

## 2. PR envelope

worker 以版本化模板生成 body，而不是拼接固定 vendor 文案。task-bound PR 的必填面：

```text
PR-Type: implementation | status | verification | archive
Change: CHG-2026-030-host-loop-runtime
Task: TASK-HLR-003
Base-OID: <40-hex protected-main OID>
Head-OID: <40-hex branch OID>
Decision-Grade: D0 | D1 | D2
Depends-On: <PR number or none>
Evidence:
- <repository-relative evidence path or none with reason>
Attribution:
- producer: <configured stable host identity>
- runtime: host-loop/<version>
- run: <opaque run UUID>
```

proposal/approval/readiness PR 使用同一模板，但 `Task: none`，并以 `PR-Type` 和
`Change` 表达其范围；它们不能伪造 task-bound declaration。`Task: TASK-*` 必须是
独立一行，以兼容 `MECH-004` 的既有 parser。`Base-OID` 与 `Head-OID` 必须完整
40-hex；任何 body update 必须重生成整个 template，并且只在 canonical bytes 改变时
写入。Attribution 来自显式 configuration/运行事实，禁止 hard-code provider 或把
模型名称臆测为作者。

## 3. Durable coordination and fencing

### Cursor

每个 host-loop queue 使用一个命名 GitHub Issue 作导航。其 machine block 只缓存：
cursor main OID、候选 task、lease ref/OID、PR number/head、review run、最后观测时间。
启动或恢复时必须从 protected main、active `tasks.md` 和 GitHub PR metadata 重建并
校验；Issue 缺失、machine block 不可解析或与这些事实冲突时，runtime 只报告
`blocked/reconcile-required`。Issue 不是授权、批准、task 状态或唯一事实源。

### Lease

对每个 task 使用唯一 `refs/heads/agent/leases/<task-id>`。lease commit 只含 lease
record：task ID、base OID、owner run ID、monotonic fence、expiry、PR branch/name 与
previous lease OID。acquire 使用远端 `create`；renew/release/takeover 使用指明旧 remote
OID 的 compare-and-swap（例如 Git 的 exact `--force-with-lease` 语义）。因此两个 worker
不能同时得到同一 fence。

每次 lease write 后都把新 ref OID 写进 Issue cursor。每次 PR/Issue/branch 外部写前，
worker 必须重新读取 lease ref 并确认 task、owner、fence、expiry 与预期 OID；不匹配即
停止。过期 takeover 只在原 ref 的 exact OID 仍匹配且稳定 PR identity 已重查后允许。
旧 owner 不得凭本地时钟或旧 cursor 写 PR；若它的 API 写超时，先 lookup 再决定是否
重试。

PR identity 是 task 的 stable head branch + `Task:` + `Base-OID`，不是标题。create 超时
或进程崩溃后，新 owner 先按该 identity 搜索并 adopt 唯一既有 PR；0 或多于 1 个结果
均停止，不创建第二个 PR。

## 4. Worker/reviewer state machine

```text
discover -> leaseHeld -> branchPrepared -> prOpen -> checksGreen
          -> reviewRequested -> reviewRecorded -> batchQueued
          -> mergeOIDConfirmed -> leaseReleased

any uncertainty/fence mismatch/API ambiguity -> reconcileRequired (no next dispatch)
review REQUEST_CHANGES/BLOCKED              -> workerPaused
```

worker 只发现已批准且 ready 的 host-only task，校验 dependencies、allowed paths、base pin
和 D grade 后才 claim。D1/D2 gate 未确认时只写事实性阻塞记录；不得为了保持忙碌而开始
门后的实现。它不能把 CI 绿解释为 merge 许可。

reviewer loop 只接受 `prOpen`、metadata 完整、checks 已完成的候选。它调度独立 reviewer
adapter，保存 `APPROVE`、`REQUEST_CHANGES` 或 `BLOCKED` 和固定 head/base/review run
证据。这里的 `APPROVE` 仅是 CHG-2026-027 所谓独立 AI 合前 review 结论，绝不调用
GitHub approval API，也不替代维护者 review。只有该结论、checks 与 digest 都完整，
worker 才可将 PR 导航信息加入 batch Issue；任何 merge 动作仍在 runtime 外由维护者完成。
reviewer process 不接收 integration credential；worker transport 即使底层 category
覆盖 review/merge endpoint，也没有对应 typed method 或 generic escape hatch。

## 5. Recovery and migration

每轮开始先 fetch protected main，并查询所有 owned lease、stable task branches 和关联 PR。
PR closed/merged 的事实必须从 GitHub merge metadata 与 main history 中的 full merge OID
交叉确认；branch 删除、时间流逝、issue comment 或 CI 成功均不足以确认。确认后才 advance
cursor/release lease。无法确认保持暂停，并产生可复查的 reconciliation record。

新 integration identity 首次成功以完整 envelope 创建一个 task PR、且其首个
`pull_request` check 实测出现前，旧 `.github/workflows/agent-pr.yml` 不得删除。迁移
PR 必须证明同一 branch 没有双 creator；回滚先停 scheduler/worker，再恢复旧 workflow，
然后对未释放 lease/开放 PR 做只读 reconcile。
