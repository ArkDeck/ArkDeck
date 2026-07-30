# TASK-DHA-001 run r1 — MU-4 垂直交付(contract 面)

> Correction(2026-07-29):合入后深检在本记录所依据的实现中发现
> resume token 未持久化、HAP lease 未解析、跨步骤 remote path 不一致、
> 补偿未执行及 symlink/index 覆盖不足。本记录中相应的 PASS/实现描述
> 不再作为最终依据;修正、可复查命令与剩余 blocker 见 `run-r2-hardening.md`。
> 保留原文用于审计,不回写成当时并不存在的能力。

- Date:2026-07-29
- Executor:agent(实现;真机与 E1 capability 属维护者)
- Base:main `45f03dc`(#784 之后,T11 门槛已关闭)
- Evidence class:contract / fake integration
- **Hardware status:`hardware-pending`** —— `DHA-HW-001`/`DHA-HW-002`
  未主张;后者另需维护者签发的 E1 capability

## ⚠ 任务状态:blocked(维护者 2026-07-29 停手)+ 契约修正后的实现更新

维护者在实现 `capture-hilog` 的 durable intent 时命中 stop condition 并
把本任务设为 **blocked**:当时的 `captureRemoteStdout` schema/validator
只允许 `arkui-ui-dump` 系列 action,**无法如实表示 Catalog 已发布的
HiLog step**;而我先前的 journal 参数表正是用 `arkui-ui-dump` +
`nodeSummary` 顶替了 HiLog 步骤——那会让 durable journal 记下该步骤
从未执行过的 action 身份,属**伪造 evidence**,不是命名瑕疵。

契约缺口已由 **CHG-2026-050**(`TASK-WSC-001`,#787/#788/#789 已合入
main `d13dfec`)补齐:新增 `openspec/contracts/catalogs/
diagnostics-stdout.yaml`(`arkdeck-diagnostics` catalog,`boundedHilog`
与 `componentTree` 两个 action 及其参数上下界),step 增 `actionRef`,
`captureRemoteStdout` 的 validator 按 action 逐项校验参数。

**本次实现更新(按新契约)**:

- journal intent 的 action 身份**只从 catalog 的 `actionRef` 读取**;
  stdout 步骤若未声明 action,引擎**拒绝执行**而非替它编一个
  (`refusing to invent`)——这是把"不许冒充"变成结构约束;
- `boundedHilog` 的 parameters 按新契约填 duration/filters/byteBudget
  并逐项夹在上下界内;`componentTree` 填 byteBudget;
- provider 的 capture action 选择改**按 actionRef**,不再按 stepID 猜
  (改名不该悄悄改变执行内容);
- 回归测试两条:①真机路径的 journal 必须出现 `boundedHilog` /
  `arkdeck-diagnostics` 且**不得出现** `nodeSummary`;②无 actionRef 的
  stdout 步骤必须被拒。

**fresh readiness 已合入(#790,main `3da3986`)**,任务恢复 ready。其
`Saved-draft handoff` 提出两条硬要求,本 PR 逐条落实并各配测试:

1. **禁止按 `stepID` 猜 catalog/action 的 fallback**:上一版仍留有
   `case "boundedHilog", nil:` 的 nil 分支——那正是被点名禁止的猜测
   路径。现改为:无 `actionReference` 即**拒绝**(provider 与 engine
   两侧一致),不存在任何按步骤名推断的回退。
2. **构造的 `WorkflowStep` 须携带 diagnostics contract 的 exact typed
   parameters/bounds**:`boundedHilog` 填 duration/filters/byteBudget 并
   **钳制到契约上下界**,`componentTree` 只带 byteBudget。新增测试用
   越界输入(duration 99999、40 个 filter、budget 1)驱动**真实
   validator**,断言落到 600 / 16 / 1024 且步骤仍合法。

**readiness pins 复核(22 条)**:17 条逐字未动;5 条是本 PR 声明的目标
文件(RuntimeJobEngine/DeviceProviderAdapters/DeviceProviderContract/
HDCE0ActionPack/AgentDaemon);**零意外漂移**。base 为
fresh-readiness base 之后的 main `3da3986`。

`tasks.md` 的 Status 行本 PR 不触碰(readiness 已置 ready;done 翻转
待硬件面处置后另行决定)。

## 维护者 review 期的两项修订(#785 合并版 proposal)

维护者在批准 proposal 时重写了 scope,加入 **T00 Device Runtime Agent
执行交接**与 `DHA-AGENT-001`,并指出 T12 的一个**真实授权缺陷**。两项均
已落实:

1. **T00**:`ArkDeckAgentClient/AgentRuntimeExecutor` + `arkdeck agent
   run`。Agent 自己完成 health→target→submit→run→artifact 并产出
   `RuntimeAgentExecutionReceipt`(executor=agent);人只在设备信任/歧义
   选择/物理拔插三处作为 `physicalAssistant`,每处是可恢复的
   `RuntimeHumanAction`。runner 无 capability 管理面——该约束由**行为
   测试**钉死(记录实际调用的方法名),不用源码文本检查(那会被自身
   注释里的词误判,已实测)。
2. **effective effect 缺陷(维护者审出)**:引擎原先按
   `descriptor.minimumEffect` 授权,于是 `capture.diagnostics@1` 选了
   remote-file trace(deviceMutation)仍会走 E0 默认只读策略放行。改为
   按**实际选中步骤的最大 effect** 计算,授权与执行共用同一条纯选择
   规则(不可能各算各的)。配对测试:选 trace → 要 E1 且无 capability
   时零 dispatch;不选 trace → 仍 E0 免 capability。

## 交付面

- **T00 Agent runner**:见上;新增 `docs/adr/0008-agent-runtime-execution.md`。
- **T14 统一 artifact**:`Artifacts/RuntimeArtifactStore.swift` ——
  内容寻址身份(ID = 内容 SHA-256 前缀,磁盘名即 ID)、完整元数据
  (job/session/step、hash、privacy、retention、binding snapshot、
  source operation)、仅 ID/lease 访问(协议面无路径参数)、
  quota"拒新不毁旧"、GC 跳过 active/pinned、默认脱敏并留痕
  (`redactionApplied`)、cleanup debt 台账。daemon 增
  `artifact.list/inspect/read`;引擎在 verify 成功后按 catalog 声明发布
  产物——**MU-3 递延的 `observe.device@1` 四产物落盘由此补齐**。
- **T12 `capture.diagnostics@1`**:optional 步骤成为部分成功面;
  缺失产物以 `missing(reason)` 入索引并在 `capture-summary.json` 逐项
  列出;finalize 兜底补记"声明了但从未产出"的产物;上游跳过则下游跳过
  (见下方缺陷);byte budget 与 quota 双层约束。
- **T13 E1 pack + `debug.hap@1`**:新增 send/install/readback/start/
  verify/stop/uninstall/port-forward 九个 typed action(全部无路径/argv
  入参,staging 路径由 provider 铸造);**install 与 start 的 verify 永不
  返回 `.verified`**——它们把判定交给配对的 readback 步骤,readback 失败
  即整体失败;E1 capability 一次授权整个 recipe。

## 测试结果

- `swift test` 全量:**651 / 1 skipped / 0 failures**(在 main `3da3986`
  即 fresh readiness 合入后复跑;新增 37 项:
  RuntimeArtifactContractTests 12、DiagnosticsAndHAPContractTests 11、
  AgentRuntimeExecutorContractTests 6、EffectiveEffectContractTests 4、
  daemon artifact 协议面 1、action 身份与契约边界回归 3)
- `scripts/check-sdd.sh`:0 error / 0 warning / 111 AC

## 实现期抓到的真缺陷(测试驱动,已修)

**采集失败却发布了产物**:trace 采集步骤失败后,下游的
`receive-trace-artifact` 仍被执行并"成功"发布了 `trace.htrace` ——
一次失败的采集因此看起来完整。这正是本 change 要防的"部分失败被洗白
成成功"形态。修法两层:①optional 步骤链显式登记依赖,上游跳过则下游
跳过;②finalize 阶段兜底补记所有"声明了但索引里没有"的产物,**不依赖
步骤映射的完整性**(失败的往往正是上游)。下游跳过的原因如实引用上游
根因,而非复述自身条件。

另修正一条 MU-3 遗留断言:`testHDCActionMappingIsClosedAndFailClosed`
断言 `installPackage` 无注册 action;T13 实现后该失败模式**移位而非
消失**(缺 `bundleName` 输入仍被拒),已改写为断言新契约,并补一条
真正无注册 action 的 kind(`flashPartition`)保持原意图覆盖。

## Host 自测(窗口前必做,已完成)

- `arkdeck agent run --operation observe.device@1`:未配置
  `ARKDECK_HDC_PATH` 时**结构化拒绝并仍产出 receipt**
  (`executor: "agent"`、`terminalState: "adoptRefused"`、
  `authorityReference: "default-read-only-policy"`、catalog digest 在位),
  退出码 1。自测中发现首版在该路径上直接抛错、不出 receipt——与
  ADR-0008"receipt 是运行载体"相悖,已修。
- `capability list/install/revoke`、`job submit --request-file`、
  `artifact list` 均对真 daemon 实跑通过(见窗口计划 §6)。

## AC 结论

- `DHA-AGENT-001` PASS(Agent 经 typed daemon API 完成 adopt→submit→
  artifact 查询;receipt 记录 executor=agent/authority/job/binding;
  unauthorized → 可恢复 trustDevice,多候选 → selectTarget,均不猜;
  行为测试证明只调用已发布 runtime 方法、零 capability 管理;一次
  invocation 恰一个 job)
- `DHA-ART-001` PASS(元数据完整;仅 ID 访问;恶意名与畸形 jobID 均不
  落盘外;导出拒覆盖并清洗名;sensitive 需 opt-in;脱敏留痕;quota
  拒新不毁旧;GC 跳过 active/pinned;索引重开后仍在)
- `DHA-CAP-001` PASS(**effective effect**:选 trace → E1 且缺 capability
  零 dispatch,不选 trace → E0 免 capability;无 trace 请求 → trace 记
  missing 且 summary 逐项标注;trace 失败 → 降级为 missing 且 required
  产物照常发布;required 产物失败 → 整体不 succeeded)
- `DHA-HAP-001` PASS(双 readback 齐全才 succeeded;install 干净退出但
  readback 为空 → 失败且**不启动应用**;start 干净退出但无进程 → 失败;
  无 capability → 零 dispatch;跨 operation scope → 拒绝;整个 recipe
  只消耗一次 capability)
- `DHA-HW-001`/`DHA-HW-002` **未主张(hardware-pending)**

## 偏差与遗留

- `debug.hap@1` 的 `capture-diagnostics` 步骤复用 HiLog action;完整的
  "嵌套 capture.diagnostics"组合留待 T19 的 AI loop 需要时再评估。
- artifact `export` 的 daemon 方法未接线(store 层已实现并测试),CLI
  `artifact export` 随 T20 完整 CLI 一并交付;`artifact list/inspect/read`
  与 `capability list/install/revoke`、`job submit --request-file` 已随本
  change 交付并 host 自测(设备窗口需要它们)。
- retention deadline 目前只在 GC 侧消费,尚未按 operation 声明自动计算
  到期时间——T24 的可观测性/维护面统一处理。
