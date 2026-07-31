# TASK-HTP-007 run r1 — host-only 准入与首个 host-only operation

- Date:2026-07-31
- Executor:agent(交互式会话),host-only
- Gate:同 TASK-HTP-001 的维护者提前解冻;r2 拆分由维护者 2026-07-31 决定
- Effect:hostOnly。零 HDC dispatch、零设备命令、零 capability 消耗
- Authority:default read-only policy(E0);host-only operation 由该策略把关

## 1. 为什么需要这个任务(实测根因)

005 开工前实测:引擎准入对**每个** job 无条件解析并校验设备事实 ——
`materializeTypedPlanBeforeAuthorization` → `validateEvidenceFacts` 要求匹配 targetID、
**非空 `expectedBindingRevision`**、非空 connectKey、合法 deviceIdentity sha256、工具版本与
hash。而 catalog schema 里 operation 级 `binding: none` 是合法值,仓内 6 个 operation
却全是 `confirmedDevice`:**schema 承诺了一个准入面从未实现的形态**。workspace 面全是 host
操作,一个设备字段都没有,所以不是加法。

同类的第二处不自洽在实现中被抓到:`authorization` 的键被要求「等于 permitted 减去
hostOnly」,同时又必须非空 → **纯 hostOnly 的 operation 在契约上无法构造**。改为
「键 == permitted」(更严:host-only 也要写明由默认只读策略把关);仓内 6 个 operation 都不
permit hostOnly,行为不变,生成器与 Swift 两侧的 pin 与负例同步更新。

## 2. 交付面

**契约/词表 lockstep 八处**同步:step registry 新增 `inspectWorkspaceSource`
(hostOnly/immediate/none)、`workflow-step.schema.json` 的 kind 枚举 + typed arguments
分支、Swift `WorkflowStepKind` + metadata + 参数校验器、`operation.schema.json` 的
`provider: workspace` 与 `concurrencyKey: host-exclusive`、Core 的 `CatalogProvider` /
`CatalogConcurrencyKey`、生成器常量与 Swift 发射、引擎的 journal 参数表、以及生成器 pin 与
Swift catalog pin。catalog digest → `ad5d5a34…`,`generate.py --check` 零 drift。

**新增 catalog 文档**:`workspace.inspect-source@1`(hostOnly、`binding: none`、
`host-exclusive`、单步只读)+ host profile `workspace-host@1`(声明零 executable/argv)。

**引擎 host-only 准入**:`descriptor.binding == .none` 时不解析设备 facts、不查 target
store;请求携带 `expectedBindingRevision` 即拒;`MaterializedPlanDocument` 的身份/绑定字段
改为可选 + `encodeIfPresent`(**设备计划的字节与 plan digest 逐字节不变**);capability
draft 与 capability 查询在无设备绑定时 fail closed;host-only job 的 reconcile 不走设备
readback。

**双向 fail closed**:`validateHostOnlyDescriptor` 拒绝 host-only operation 内的
`confirmedDevice` 步骤、高于 `hostOnly` 的 step effect,以及 permitted 超过 hostOnly。

**最小 `arkdeck-workspace` provider**:只服务 `workspace.inspect-source@1`;
`resolveFacts` **抛错**(host-only 没有设备事实,不编造);调用方给 projectRef + glob,
根目录由 provider 自己解析(fileScope 禁止 `/`、`..`、前导 `-`);argv 逐 token 由 provider
构造(`-r -n --include <glob> -- <symbol> <root>`,`--` 终止选项);工具或项目未配置即
`UNAVAILABLE` 带机器可读原因。

## 3. 套件

```text
swift test --package-path Packages/ArkDeckKit          # base = main e9185fa2
Executed 877 tests, with 1 test skipped and 0 failures (0 unexpected)

catalog_gen 套件:Ran 39 tests OK;generate.py --check 零 drift
check-sdd:0 error / 0 warning / 114 acceptance IDs
```

数字随 base 变化:实现完成时的 base(#859)上是 858 例,rebase 到 #864 之后是 877 例,
两者都是 0 failure;本 PR 交付的是后者。**一次未复现的 flake 如实记下**:rebase 后第一次
全量跑出现 1 个 failure,那次输出被过滤、用例名未留存,之后 4 次全量均 0 failure;仓内含
计时构造的测试文件 8 个全是既有文件,本任务新增的 15 例全用注入时钟,故不宣布套件确定性
干净,只如实记录。

新增 `HostOnlyAdmissionContractTests` 15 例。**AC-21 的回归信号**:改动后全量套件全绿,
其中包含全部既有设备绑定准入测试;并另有三条显式回归 —— 无 facts 时设备 operation 仍以
`target facts cannot materialize` 被拒(且确实查过 facts)、请求不 pin binding revision 时
设备 operation 仍被拒、仓内除 workspace 外每个 operation 仍 `confirmedDevice` 且
`binding: none` 的 operation 恰好只有一个。

## 4. 进程级实跑(host,真实 UDS + 真实引擎 + 真 spawn)

```text
$ ARKDECK_WORKSPACE_INSPECTOR=/usr/bin/grep \
  ARKDECK_WORKSPACE_PROJECTS=demo-app=/private/tmp/ws-demo arkdeck-agentd --state-dir /tmp/adh8
workspace provider ready for demo-app

operation.list:
  observe.device@1              unavailable  ["no HDC executable configured …"]
  workspace.inspect-source@1    available    []

$ arkdeck job submit --request-file req.json --wait     # inputs: projectRef/symbol/fileScope
state: succeeded | outcomeUnknown: False
timeline: intent inspect-workspace-source > verified inspect-workspace-source
          ["fileScope","matches","projectRef","truncated"] > … > finalizing->succeeded

job.evidence: provider=workspace | effect=E0 | bindingRevision=None | blockers=[]
authority: {kind: defaultReadOnlyPolicy, reference: default-read-only-policy}
stepKinds: ["inspectWorkspaceSource"]
artifact: source-inspection.txt 95B published
  内容 = /private/tmp/ws-demo/Sources/WaterFlow.cpp:2:void WaterFlowPattern_RecoverBack() …
artifact 的 bindingSnapshot 只有 {targetID: demo-app} —— 无 bindingRevision、无设备身份
journal 中 host 路径出现次数:0
```

**实跑抓到的缺陷**:第一次跑 evidence 报
`artifactVerification: … has no published artifact metadata` —— operation 声明了必需
artifact 却没人发布它。检查产出不落盘就喂不了 evaluator(002 的「证据必须是真实字节」在
host-only 形态下的同一条)。已补:`artifactMapping` 增加
`inspect-workspace-source → source-inspection.txt`,`artifactContents` 对该名字返回
**stdout 原始字节**(不是摘要);并加测试断言发布字节与 stdout 逐字节相等、bindingSnapshot
无 revision/身份、必需 artifact 未被记为「有意省略」。

## 5. 如实登记的边界

- **artifact 内容天然含匹配到的文件路径**(它就是 inspector 的输出)。durable **journal**
  不含 host 路径(实测 0 次),而 decision context 只带 artifact 身份与摘要前缀、从不带内容
  (TASK-HTP-004 的出站断言),因此路径不会经模型面离开本机;
- **inspector 是 host 侧通用工具**(本轮用 `/usr/bin/grep`,启动时按 provider 取 hash)。
  ProjectProfile preset 与专用 inspector 属 TASK-HTP-005;
- **真机**:本任务 host-only,按定义与设备无关;GJ-5 真机收敛仍属 TASK-HTP-006;
- **005 的其余五个 operation**(applyPatch/build/runTests/symbolize/revert)不在本轮范围,
  其中 patch 写入面的 glob/回滚/零 push 断言仍归 HTP-AC-16。
