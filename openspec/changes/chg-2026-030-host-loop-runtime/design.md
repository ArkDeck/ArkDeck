# CHG-2026-030 Design — host-loop runtime

> Status:draft
> Change:CHG-2026-030-host-loop-runtime@r10
> 本设计只约束本 change 的候选实现。与 Constitution、AGENTS.md、
> enforcement.md 或 CHG-2026-027 冲突时，停止并以高层规则为准。

## 1. Non-negotiable boundaries

1. protected `main` + 维护者 CODEOWNER review/merge 仍是唯一批准事实；CI、
   envelope、Issue、lease、review result 和 runtime log 均不是批准事实。
2. ordinary worker/reviewer runtime 绝不 merge、作 GitHub approval、设置
   task/change 状态，或修改 ruleset、branch protection、repository setting/
   credential。r7 无 gateway 例外；所有 GitHub 管理设置只由维护者在 Agent 不可达的
   隔离会话按 CHG-2026-033 执行，维护者凭据不得进入 Agent runtime 或 secret boundary。
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

## 1B. Exclusive creator namespace（r3）

legacy `.github/workflows/agent-pr.yml` 当前匹配全部 `agent/**` push，并在新 identity
有机会调用 create-PR 前以 `GITHUB_TOKEN` 创建 PR。为打破 HLR-002 create probe 与
HLR-003 migration 的循环依赖，TASK-HLR-002A 先把 creator ownership 按 namespace
分区：

- `refs/heads/agent/host-loop/tasks/<task-id>`：host-loop stable task branch；
- `refs/heads/agent/host-loop/leases/<task-id>`：fenced lease branch；
- `refs/heads/agent/host-loop/probes/<run-id>`：不合入的 D2/live canary；
- 其余 `refs/heads/agent/**`：继续由 legacy bootstrap 创建 PR，直至 HLR-003
  完成整体 migration。

legacy workflow 的 push filter 必须显式 include `agent/**`、exclude
`agent/host-loop/**`；TASK-HLR-002A contract test 对 YAML event filter 与全部三个
reserved family 做二值解析，禁止只靠 job 内条件或 title/body 惯例。现有
`sdd-guard.yml` 不修改，继续对全部 `agent/**` push 产生 head-SHA guard，并在新
identity 创建 PR 后由 `pull_request` event 产生 allowed-paths job。
GitHub 官方 workflow syntax 规定同一 `branches` 列表中正匹配在前、`!` 负匹配在后
即可排除，且 pattern 顺序有语义
（[workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)）；
readiness/contract test 必须固定该顺序。

reserved ref 仍由 TASK-BAP-003 的 Deploy Key + active ruleset 创建/更新/删除；PR/Issue
由 r2 integration identity 创建/更新。D2 readiness 因而必须把 identity 的 Contents
permission 钉为 read（不是 write），并以真实 merge probe 验证拒绝；ref capability
由 Deploy Key ID/ruleset ID 与正负 probe 单独证明。任何 reserved branch 上出现
legacy `github-actions[bot]` creator、同一 head 多 PR、或非 reserved branch 被意外排除，
都使 partition/identity activation fail closed。

HLR-002 D2 阶段只完成 identity/secret-storage activation 与 scheduler owner/label
reservation；receipt 明示 `workerDisabled=true`，不注册/启动尚不存在的 worker
executable。HLR-003 先以独立 source PR 交付 worker，再以分离的 D2 host evidence
注册/启用 scheduler、完成 live first-PR proof 与 legacy migration；source 未合入或
receipt/source hash 漂移时 scheduler dispatch 恒为 0。

## 1C. MECH task-token compatibility（r4）

HLR-002A candidate #412 的首次 source push 已证明 ordinary `agent/**` 的 legacy
creator 与 head guard 可达；但 evidence-only head 触发的首个真实
`pull_request/synchronize` 暴露了既有 grammar seam：`scripts/check_pr_paths.py`
的 task token 只接受 `TASK-<group>-<three digits>`，而同文件 active task-header
grammar 与仓库既有任务允许末段三位数字后的单个大写 suffix（例如
`TASK-HLR-002A`、`TASK-M1-001R`）。因此 #412 的标题不能声明真实 task，branch
fallback 又把描述性 slug 拼入 task ID，`allowed-paths` 正确地 fail closed。

r4 的修复边界是让 title/body/full-token regex 复用一个与既有 task-header grammar
等价的 token definition：

```text
TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?
```

这只恢复 canonical task identity 的可表达性，不扩张路径授权：

- suffix token 仍必须唯一解析到 active `tasks.md` 的 exact header；
- malformed、lowercase、多字符 suffix、多个不一致 Task 与 token adjacency 继续拒绝；
- branch fallback 只在 title/body 无 token时使用，描述性 branch slug 不升级为 task；
- 不把 `TASK-HLR-002A` 改写/别名为 `TASK-HLR-002`，不靠人工编辑 metadata
  掩盖失败，不修改 `sdd-guard.yml` 的批准语义。

parser/tests 与 namespace filter 必须在同一 HLR-002A implementation candidate 中通过，
且真实 pull-request `allowed-paths` 绿色；但 #412 已永久 superseded，r4 后仍须独立
readiness 选择 fresh branch/head，不能修补或复用该 PR。

## 1D. Multi-level ref boundary remediation（r5 historical foundation）

HLR-002A implementation #419 已证明 workflow/parser contract，但 #421 记录的首个
post-merge reserved create 对
`refs/heads/agent/host-loop/probes/<uuid-v4>` 返回 GH013。失败 head 与 #419 merge
tree 相同，远端 ref、workflow run 与 PR 均为 0；由于 reserved head guard 缺失，该零
结果不能证明 creator isolation。

根因是 TASK-BAP-003 ruleset `agent-ref-boundary`（ID `19595282`）把 `~ALL` 作为
include，只以 `refs/heads/agent/**` 作为 exclude，并只用单层
`agent/cred-probe` 做过正向验证。GitHub ruleset 的 `fnmatch` 使用
`File::FNM_PATHNAME`，`*` 不跨 `/`；多层示例使用 `qa/**/*`。因此 r5 固定的最小
target-pattern delta 是：保留现有 `refs/heads/agent/**`，**仅追加**
`refs/heads/agent/**/*`；不更改 `~ALL`、creation/update/deletion rules、仅维护者
bypass 或 Deploy Key 的 non-bypass 身份。

该 delta 属 D2 权限配置；r5 规定 runtime/Agent 不得应用。r6 曾以 §1E gateway
建立例外，但该路径已由 r7/CHG-2026-033 supersede。CHG-2026-033
TASK-RPT-001 后来已由维护者在 Agent 不可达的隔离会话完成 ruleset 与 exact-main
branch protection 两层迁移，并以独立 evidence/done PR 闭合。下列清单保留 r5/r7
设计演进所要求的 D2 审计字段，不再构成 current execution readiness：

1. ruleset ID、完整 before JSON/hash、enforcement、include/exclude、rules 与 bypass；
2. exact after/rollback 采用 CHG-2026-033 批准的两层 topology：ordinary ruleset
   同时排除单层/多层 Agent namespace 与 exact `main`，main branch protection 独立
   强制 PR/CODEOWNER/`guard`/admin enforcement/human-only push allowlist；
3. 维护者窗口、操作者、rollback contact，以及失败时恢复完整 before JSON 的步骤；
4. current GitHub active-rule evaluation：单层 `agent/<probe>`、多层
   `agent/host-loop/probes/<uuid>`/`agent/hlr-002a-control/<uuid>` 与 exact
   `main` 不命中 ordinary-ref ruleset；`<non-agent-probe>` 与相似前缀
   `agentx/**` 仍命中；
5. Agent credential 的单层/多层 create-delete 正向、non-agent create 与基于空提交的
   direct-main update 负向；direct-main 拒绝由 branch protection 明确归因，任一
   负向意外成功都视为权限扩大事故。

上述迁移完成并 read-back exact after 后，fresh canary 不复用 #421 run ID/head。它在
执行时重新钉一个 protected-main OID，两个 empty commit 以该 OID 为共同 parent 且
tree 相同；main 在 reserved/ordinary 两次 push 之间前进、ruleset read-back 漂移或
任一 ref 预存在都停止。随后仍严格 reserved-first、ordinary-second：两者 head guard
成功；reserved legacy run/PR 均 0；ordinary legacy run/PR 恰一。事实闭合后才 close
control PR、删除两个 refs 并再次 read-back。cleanup 不改变 PASS/FAIL，D2 ruleset
receipt/live evidence 与 `ready→done` 仍是不同 PR。

r8 的 current canary 与 evidence 分离规则见 §1G；本节末尾关于 D2 ruleset
receipt 的原有顺序只作历史设计背景。

## 1E. Scoped D2 authorization, lease and drift model（r6 historical；r7 superseded）

本节完整保留 #449/r6 与 #454 readiness 所批准机制的历史设计语境，但自 r7 合入起
不再具有 implementation、readiness、authorization 或 execution 语义。任何
`TASK-HLR-002B` source、gateway provisioning、standing authorization、privileged
credential lookup、ruleset PUT/rollback 或由该机制派生的 probe dispatch 均为 0；
不得以本节构造 current plan。

r5 把“readiness 时看到的整个 main/open-PR 集合”误当成 D2 输入，导致无关产品提交
或无关 PR 也使已批准计划失效；绝对 UTC 窗口还会在 review/merge 排队时自然过期。
r6 将安全边界改为一份 canonical sensitive-input manifest、一个 scoped lease 和一个
有限 standing authorization。三者均不能替代 protected-main 上的维护者批准。

### Sensitive-input manifest

readiness merge tree 中生成 canonical UTF-8/JSON manifest，至少固定：

- repository 与 change ID、readiness PR number/reviewed head；merge 后由 gateway
  从 GitHub metadata 绑定该 head 对应的 merge OID，merge OID 不进入预合并 manifest
  hash，避免循环引用；
- 本 change `proposal.md`、`design.md`、`tasks.md`、`verification.md` 的 exact blob；
- `.github/workflows/agent-pr.yml`、`.github/workflows/sdd-guard.yml`、
  `scripts/test_agent_pr_workflow.py`、`scripts/check_pr_paths.py`、
  `scripts/test_check_pr_paths.py` 的 exact blob；
- ruleset `19595282` 的 canonical full before、write-payload before/after/rollback
  hash、active-rule expected projection；
- 每个 exact target ref 的 expected presence/OID（通常为 absent），reserved/control
  namespace 与 probe role。

执行时 current protected main 只需满足 readiness merge 是其 ancestor，并且上述
repository paths 的 blob 与 readiness merge 相同；其他路径可以前进。gateway 对
ruleset 与 target refs 做 authenticated/read-only preflight，逐项与 manifest 比较。
main 的当前 OID 只在 direct-main negative probe 的最小原子区间内作为 target snapshot；
区间外发生且不改变 sensitive paths 的 main 前进不使 readiness 失效。任何 sensitive
blob、ruleset field 或 target ref state 漂移都停止，不能以“语义
看起来相同”解释放行。

operation/body、authorization、gateway source/identity、window 与 lease 仍须逐项校验，
但它们属于授权/执行完整性 gate，不扩张上面的 repository/external drift 集合。

### Overlapping-PR classifier

preflight 必须分页读取全部 open PR，并对每个 PR 分页读取完整 changed-files 集合。
仅以下任一成立时判为 overlap：

1. changed files 与 sensitive-input manifest 的 repository paths 相交；
2. PR 修改本 change 的 HLR-002A/002B task/evidence，或占用同一 readiness/executor
   branch；
3. PR envelope/body 中合法声明同一 D2 operation digest 或
   `repository + ruleset ID + ref namespace` lease key；
4. PR 的可验证计划会创建、修改或删除 manifest 中任一 exact target ref。

不满足这些条件的 open PR 与本 D2 正交，不阻断 readiness 或执行。API error、权限
不足、分页不完整、changed-files 截断、metadata 语法歧义或无法证明“不相交”时仍
fail closed。title 相似、PR 数量或“仓库有活动”本身均不是 overlap 证据。

### Merge-relative window

执行窗口由 GitHub 对 readiness PR 返回的可信 `merged_at` 计算为半开区间
`[merged_at + 15 minutes, merged_at + 45 minutes)`；禁止把本地 merge 观察时间、
commit author/committer time 或 readiness 文本中的绝对时间当作起点。gateway 在
acquire lease 与每个 privileged dispatch 前同时检查可信 UTC wall clock 和单调计时
连续性；时钟回拨、休眠造成边界不确定、进入窗口前或到达上界后均零 dispatch。
窗口过期只需重新 readiness/authorization，不回滚已经被 exact read-back 证明完成的
operation。

### Scoped D2 lease

lease key 至少为
`ArkDeck/ArkDeck + ruleset:19595282 + target-patterns(agent/**,agent/**/*)`，只序列化同一 gateway
内会读写该 ruleset/namespace 的 D2 operation；它不锁 protected main、不禁止无关
PR/merge，也不声称阻止 GitHub UI 或其他凭据的仓外写。lease 保存在 gateway 的 durable
CAS store，而不是受该 ruleset 约束的 Git ref；record 含 authorization ID、operation
digest、owner run、monotonic fence、acquired/expiry、previous record hash 与状态。

每个 authenticated ruleset/ref read 或 write 前 gateway 重读 lease 并核对 owner、
fence、expiry 与 operation digest；失配即停止。外部 actor 不受 lease 物理阻止，因此
每个 write 后仍须 immediate read-back，下一步前再做 sensitive projection 对比。
超时结果先 lookup/read-back，不盲重试。release/expiry 只解除 gateway 串行化，不把
未知 operation outcome 改成成功。

### Standing authorization and constrained gateway

standing authorization 的有效载体必须是维护者创建/修改并 review/merge 的
authorization-bearing readiness PR；该同一 merge 同时产生 readiness 状态、
authorization 与 `merged_at` 窗口起点。Agent 可提交只读 discovery 输出，但不得创建、
修改、批准或撤销 authorization carrier。authorization 至少固定：

```text
authorization-id
repository
ruleset-id
method + endpoint
before/after/rollback SHA-256
operation body SHA-256
sensitive-manifest SHA-256
target refs + expected state
lease key
gateway identity/source SHA-256
valid-from: readiness.merged_at + 15m
valid-until: readiness.merged_at + 45m
maxUses
rollback contact + revoke conditions
```

本次 ruleset remediation 的 `maxUses` 必须为 1；未来成熟操作可申请大于 1 的有限值，
但每次仍需独立 operation digest、fence、preflight/read-back receipt，且不得越过授权
列举的 targets。gateway 必须证明 authorization/readiness 的 reviewed head 就是
GitHub merge metadata 记录的 head，且该 merge OID 是 current main ancestor；授权被
后续 protected-main commit 明确撤销、过期或用尽时调用数为 0。

raw maintainer credential/App private key 只存在于 gateway 的隔离 secret storage，
worker 只能调用 `executeAuthorizedRulesetDelta(canonicalRequest)`。gateway 不暴露
generic REST/GraphQL、任意 method/URL/body、ruleset CRUD、branch protection、
review/merge 或 arbitrary ref write；route inventory 和 source scan 对这些构造数必须
为 0。gateway 按固定状态机执行：

```text
verify authorization/manifest/window
  -> classify overlapping PRs
  -> acquire scoped lease
  -> authenticated before read
  -> exact one-shot mutation
  -> immediate exact-after read-back
  -> ref/active-rule verification
  -> append immutable redacted receipt
  -> consume authorization use
  -> release lease

any ambiguity -> stop; if mutation may have occurred -> read-back;
after mismatch -> exact rollback under same fence -> read-back -> stop
```

receipt 记录 authorization/operation/manifest hash、fence、脱敏 executor/gateway
identity、GitHub response classification、before/after/rollback hash、target-ref
projection、时间和 outcome；不含 secret/raw payload/用户绝对路径，也不承载批准语义。

## 1F. Human-only ref-protection execution（r7 foundation）

CHG-2026-033 是 current ref-protection topology 与迁移流程的批准权威。本 change
只消费其结果，不复制其管理能力：

1. **Authority boundary。**ruleset、branch protection、repository setting 与
   credential 的 authenticated read/write 仅由维护者在 Agent 不可达的隔离会话执行。
   Deploy Key、GitHub App、Actions token、integration identity、worker/reviewer 与本
   change source 均无 Administration/protection/ruleset route；raw human credential
   不得进入 repository、Agent process、gateway、environment 或 Agent 可达 storage。
2. **Fail-closed ordering。**TASK-RPT-001 先强化并 read-back main protection，证明
   human-only push allowlist、PR、CODEOWNER review、`guard`、admin enforcement、
   force/delete/auto-merge 禁令生效，并以 Deploy Key direct-main negative probe
   明确拒绝；之后才可把 exact `main` 加入 ordinary ruleset exclusion。任一步失败即
   保持更严格状态或恢复 exact before，不得出现 main 无保护窗口。
3. **Evidence dependency。**HLR-002A 保持 `blocked`，直到 TASK-RPT-001
   evidence 与 done PR 均合入。fresh HLR-002A readiness 必须固定该 evidence merge
   OID、authenticated after projection 与全新 canary refs，只授权 creator
   control/canary；不得包含 ruleset/branch-protection/repository-setting mutation。
4. **Historical invalidation。**#435 的 OID/window/payload/hash/UUID、#449 的
   Agent-operated gateway 与 #454 的 readiness/fixtures/implementation branch 全部
   不可重放。#419 仍是真实 source/repository evidence，#421 仍是真实 live FAIL；
   两者均不能替代新 topology evidence 或 fresh canary。
5. **Negative closure。**任何 Agent-reachable admin/ruleset/protection/credential
   method，任何 non-human actor 进入 bypass/main push allowlist，任何 direct-main、
   self-approval、merge/auto-merge 或手工 merge-commit路径意外成功，均立即停链并
   触发 CHG-2026-033 rollback/incident 边界；cleanup 不把失败改成 PASS。

## 1G. Current topology consumption and creator canary（r8 historical readiness；r9 superseded）

r8 不再等待或重做 ref-protection migration。它只消费已经合入的
CHG-2026-033 TASK-RPT-001 evidence：

- execution evidence merge
  `6f874efc5c4e9fdd39bcdcc91cfcaa6a862e1961`；
- no-bypass operability merge
  `7a221d24133eefed38aa616fcda376fef33f6cf3`；
- done merge `94c23c4123712a46e7fb2f96a0509f84f5f49ba7`；
- branch-protection projection/full SHA-256
  `f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a` /
  `04f09f273fce806afaa44679c9e8257c74cce3e480fe60da27c7dcca06e85f04`；
- ruleset projection/full SHA-256
  `9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163` /
  `b172750c1c0764956725393823fa72014146d9e2ec0f1b19c48cf670964d54b5`。

HLR-002A 的 fresh live scope 只包含两个 exact Deploy Key refs：

```text
reserved: agent/host-loop/probes/8bd61cc3-d7c7-41ff-bfc8-0c62952afba3
ordinary: agent/hlr-002a-control/5a2570ed-5916-4cc8-ac84-4afa294e4b9e
```

执行从 r8 readiness PR 的 protected-main squash merge OID 开始。该 OID 必须由
PR exact reviewed head、`mergedBy=lvye`、subject `(#N)` 与 git history 共同确认，
且在首个 push 前是 current protected main。两个 canary commit 使用相同 parent 与
tree，各自一个 empty commit；subject 不得包含 Actions skip instruction，因为本
canary 正是在验证 workflow dispatch。reserved/ordinary 两次 push 之间 main、
workflow sensitive blobs、target ref 或 overlapping PR 漂移即停止。

固定顺序：

1. 重读 readiness merge、sensitive blobs、全部 open PR/files 与两个 ref absence；
2. push reserved，取得 exact-head SDD Guard push `guard=success`，并以 workflow
   path/event/branch/head 查询证明 legacy `agent-pr` run 与 PR 数均为 0；
3. 重读 main 与 reserved facts后 push ordinary，取得 exact-head SDD Guard
   `guard=success`、唯一 terminal-success `agent-pr` run 与唯一
   `github-actions[bot]` open PR；
4. 在 cleanup 前重复 run/PR 查询，固定 PR number/head/author/`merged=false`；
5. 以 Deploy Key 删除 ordinary 与 reserved refs，验证 Git server + stable
   `ls-remote` absence；ordinary PR 必须随后为 closed/unmerged。若 GitHub 未随
   head deletion 自动关闭 PR，只记录 residual cleanup，停止后续 task并请求独立
   人类 close；不得 merge、approve、启用 auto-merge 或借用维护者 credential。

GitHub API/HTML 限流、workflow/run 查询不完整、0/2 ordinary run/PR、任何
reserved legacy creator、head guard 缺失、ref push/delete ambiguity 或 cleanup
前事实不全均为 FAIL。cleanup 永不把 FAIL 改成 PASS。canary 只证明 creator
partition；它不重新验证或修改 ruleset/branch protection，也不授权 HLR-002
identity/scheduler。

#480 合入后、任一 canary dispatch 前，r9 因用户要求改变 sensitive workflow
inputs 而 supersede 本节的 exact refs/pins/UUID。本节继续证明 r8 当时批准了什么，
但不再是 executable readiness；fresh canary 只能在 TASK-HLR-001A done 后重建。

## 1H. Automatic checks for `GITHUB_TOKEN`-created Agent PRs（r9 active baseline）

GitHub current semantics deliberately create approval-required
`pull_request` runs when a workflow uses its repository `GITHUB_TOKEN` to
create or update a PR. The routine Agent flow already has three exact-head
push runs before/while the PR is opened: Agent PR, SDD Guard and Swift CI.
r9 uses those existing runs instead of adding a PAT/App credential or asking
the maintainer to release duplicate PR-event runs.

### Event and check partition

1. `agent-pr.yml` remains push-only for ordered
   `agent/**` / `!agent/host-loop/**`. Its `open-pr` job must:
   - list all open same-repository PRs for the exact head branch;
   - create one bot-authored PR only when the count is zero;
   - fail closed when the count is greater than one;
   - re-read the unique PR and require numeric number, base `main`, exact
     `head.sha == github.sha`, author `github-actions[bot]` and `merged=false`;
   - expose only the validated PR number to a dependent read-only job.
2. A dependent `allowed-paths` job always runs after create-or-find. It uses
   `contents:read` + `pull-requests:read`, fetches the fixed PR endpoint into
   a temporary JSON file, parses that untrusted data inside Python, and runs
   the existing MECH-004 contract plus exact base/head diff check. It never
   interpolates PR title/body/head text into host shell or executes PR
   content as a command.
3. `sdd-guard.yml` keeps push `guard` for `main` and `agent/**`. Its
   `pull_request` event no longer includes routine bot `opened` or branch
   `synchronize`; it retains human `edited`/`reopened` revalidation so
   metadata changes cannot bypass MECH-004. The exact-head `allowed-paths`
   result for routine create/synchronize comes from step 2.
4. `swift-ci.yml` becomes push-only for `main` and `agent/**`. New branches
   with no reliable `before` continue to run the full fail-closed suite;
   later pushes use the existing path decision. Strict main protection forces
   an out-of-date branch to be updated, which produces another push run.

No new credential is introduced. `agent-pr.yml` retains job-local
`pull-requests:write` only for create; the validation job is read-only.
No workflow receives Actions, Checks, Contents write, Administration,
Workflows, review or merge permission. The repository
`can_approve_pull_request_reviews=true` legacy creator dependency remains
unchanged and does not become approval authority.

### Negative and compatibility boundary

- The first implementation PR is a live positive: before any maintainer
  workflow approval, its push head must have successful `guard`, Swift,
  `open-pr` and `allowed-paths`; there must be no `action_required`
  pull-request run whose approval is necessary to merge.
- Fixtures fail for 0/2 PR after create, non-numeric number, wrong repo/base/
  head/author, raw API shape drift, missing job dependency, write permission
  on the validation job, reintroduction of bot `opened`/routine
  `synchronize`, or removal of human `edited`/`reopened` revalidation.
- Human/non-Agent PR coverage must not be silently claimed. The current
  governance transport is same-repository `agent/**`; any future external
  contribution path requires an explicit event/approval policy and separate
  evidence. `pull_request_target` is forbidden because running or importing
  untrusted head content in base context would enlarge the trust boundary.

## 1I. Fresh automatic-check creator canary（r10 current readiness）

r10 consumes the completed TASK-HLR-001A baseline instead of replaying the
r8 plan. Its audit base is protected main
`47cec786315e79e0aad8a3209c6a7c600e6cfc60`, and its only mutable live targets
are:

```text
reserved: agent/host-loop/probes/7e9bc001-c515-4aef-b3dc-c71d7f0124ee
ordinary: agent/hlr-002a-control/4a2314d2-72c3-44f8-b579-606735e279b8
evidence: agent/task-hlr-002a-canary-evidence-r10
```

The readiness carrier itself is governance-only. Apart from the existing
Agent branch/PR transport needed to submit that carrier, it performs zero
target-ref, extra PR-state, setting or credential writes. After the carrier
has an exact-head `lvye` approval and protected-main squash merge, its merge
OID becomes the common parent and tree for two distinct empty commits. Both
subjects identify `TASK-HLR-002A` and contain no Actions skip instruction.

The fail-closed state machine is:

1. Re-read current main, the pinned workflow/parser/governance blobs, all open
   PR files and every remote branch. Require both target refs and the evidence
   branch to be absent and require no overlapping PR.
2. Push reserved with the Agent Deploy Key. Require exact-head push SDD Guard
   `guard=success` and Swift CI `swift=success`; query Agent PR by exact
   workflow path, `event=push`, branch and head and require zero runs. Query
   all-state PRs by exact same-repository head and require zero PRs.
3. Re-read main, pins and reserved facts. Only then push ordinary. Require
   exact-head push SDD Guard and Swift success; require exactly one successful
   Agent PR run with successful `open-pr` and `allowed-paths` jobs; require
   exactly one open, unmerged, exact-head/base-main PR authored by
   `github-actions[bot]`.
4. Before cleanup, repeat the reserved zero-run/zero-PR queries and the
   ordinary unique-run/unique-PR queries with complete pagination. Record
   request filters, full OIDs, run/job/PR IDs, conclusions and timestamps.
5. Delete ordinary and then reserved using only the Deploy Key. Confirm each
   Git receipt and stable `ls-remote` absence. The ordinary PR must be
   closed/unmerged; if deletion does not close it, record the residual and
   stop for independent human closure.

An `action_required` pull-request run is not expected or needed for this
push-based canary. Its appearance, any 0/2 ordinary creator, any reserved
creator, a missing required push job, ref push/delete ambiguity, main/input/
overlap drift, incomplete pagination or API ambiguity stops the state machine.
Cleanup preserves the observed PASS/FAIL and never repairs missing evidence.

The protection topology is consumed, not modified: ruleset `19595282`
continues to guard ordinary non-main refs while exact-main branch protection
enforces PR, human CODEOWNER review, App `15368` `guard`, administrators,
human-only push restriction and force/delete prohibitions. Any live result
inconsistent with the merged CHG-2026-033 authenticated evidence returns the
work to that change; r10 must not mutate or reinterpret protection settings.

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

对每个 task 使用唯一 `refs/heads/agent/host-loop/leases/<task-id>`。lease commit
只含 lease record：task ID、base OID、owner run ID、monotonic fence、expiry、
PR branch/name 与 previous lease OID。acquire 使用远端 `create`；renew/release/
takeover 使用指明旧 remote OID 的 compare-and-swap（例如 Git 的 exact
`--force-with-lease` 语义）。因此两个 worker 不能同时得到同一 fence。

每次 lease write 后都把新 ref OID 写进 Issue cursor。每次 PR/Issue/branch 外部写前，
worker 必须重新读取 lease ref 并确认 task、owner、fence、expiry 与预期 OID；不匹配即
停止。过期 takeover 只在原 ref 的 exact OID 仍匹配且稳定 PR identity 已重查后允许。
旧 owner 不得凭本地时钟或旧 cursor 写 PR；若它的 API 写超时，先 lookup 再决定是否
重试。

PR identity 是 `agent/host-loop/tasks/<task-id>` stable head branch + `Task:` +
`Base-OID`，不是标题。create 超时或进程崩溃后，新 owner 先按该 identity 搜索并
adopt 唯一既有 PR；0 或多于 1 个结果均停止，不创建第二个 PR。

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

新 integration identity 首次在 `agent/host-loop/tasks/**` 以完整 envelope 创建一个
task PR、且其首个 `pull_request` check 实测出现前，旧
`.github/workflows/agent-pr.yml` 对非 reserved `agent/**` 的 coverage 不得删除。迁移
PR 必须证明 reserved branch 零 legacy creator、同一 head 没有双 PR；回滚先停
scheduler/worker，再恢复 reserved namespace 的 legacy coverage，然后对未释放 lease/
开放 PR 做只读 reconcile。
