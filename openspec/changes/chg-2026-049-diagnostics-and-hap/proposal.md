---
id: CHG-2026-049-diagnostics-and-hap
revision: 5
status: approved # r2/r3/r4 已交付；r5 携 approved 落地：维护者 review + merge 本 PR 即批准
class: capability
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# Agent-operated diagnostics, HAP debug and the unified artifact model (MU-4)

> 产品闭环兼容说明（2026-07-30）：已发布、Catalog
> `defaultPolicyIssuance=enabled` 的 E1 operation 由 Runtime 在完整
> materialization 后自动签发并持久化 capability；不再要求人工文件、安装或
> review。下文 r2 的人工 E1 capability 描述保留为历史批准记录；E2 不变。

> r2 fresh-readiness revision（2026-07-29）：功能 scope、Acceptance、
> allowed/forbidden paths、E0/E1/E2 边界与硬件分层零变化。
> `CHG-2026-050/TASK-WSC-001` 已由维护者以 PR #789 合入
> `d13dfec6d395dd73662494f16ead9674711fe6ff`，为所有 published
> `captureRemoteStdout` step 增加 closed generated `actionRef`，并使
> diagnostics HiLog/component-tree pair 在 Catalog、generator、JSON Schema
> 与 Swift validator 间闭合。r2 记录 fresh pins、草稿迁移约束和依赖复验；
> 合入 r2 前 `TASK-DHA-001` 仍不得恢复实现。

## r5(2026-07-31):屏幕截图作为第三个文件型产物

### 真机先行,又推翻了事实表一条 `[S]`

事实表 §8 写的是 `snapshot_display [-i displayId] -f <remote.png> [-t png]`,
把 `-t png` 记成"失败后重试一次"的可选项。2026-07-31 DAYU200(OH 3.2)实测 `[R]`:

```text
shell which snapshot_display  -> /bin/snapshot_display
usage: snapshot_display [-i displayId] [-f output_file] [-w width] [-h height] [-t type] [-m]

-f <x>.png          -> error: fileName … invalid, suffix must be .jpeg     # 直接拒绝
-f <x>.jpeg         -> file type: jpeg, width: 720, height: 1280;  40,941 B
-t png -f <x>.png   -> file type: png,  width: 720, height: 1280; 449,830 B
recv 后本地魔数      -> 89 50 4E 47 0D 0A 1A 0A(真 PNG)
```

即**这台设备的默认类型是 jpeg,且文件名后缀要与类型匹配**;要 PNG 就**必须**带
`-t png`,不是可选重试。deveco 的"先不带 `-t` 再重试"正是这条规则的症状,
但照它的命令行写实现会第一次就被设备拒绝。§8 该行随实现 PR 更正。

顺带三条新事实:`-w/-h` 可改尺寸、`-m` 存在(语义未探)、stdout 会打印
`process: display 0, file type: png, width: 720, height: 1280` 这样的状态行 ——
按本表 §3 的规矩,该状态行**不作判据**,判据仍是文件。

### What(r5 交付面)

不新增 operation。截图是又一个**文件型采集产物**,与 r2 的组件树同形:

1. **`capture.diagnostics@1` 新增三个 optional 步骤**:`capture-screenshot`
   (`captureRemoteFile` / `deviceMutation`)、`receive-screenshot`
   (`receiveFile` / `readOnly`)、`cleanup-screenshot-temp`
   (`cleanupOwnedRemotePath` / `deviceMutation`),均无 actionRef(按 kind 映射)。
2. **新增输入 `uiScreenshot: boolean, default false`** 与声明产物
   `screenshot.png`(`image/png`、`privacy: sensitive`、`required: false`)。
   effect 随输入升级,未请求时计划与授权面逐字节不变 —— 与 r2/r4 同一形态。
3. **lowering 用真机确认的形式**:`shell snapshot_display -t png -f <owned>.png`。
   provider 铸的 owned path 后缀必须是 `.png` —— 该后缀在这里**不是装饰**,
   设备会按它校验。
4. **判定分两层**:设备侧 `ls -l` 判文件大小 > 0(D10 形态),host 侧由 D4 的
   `HostLandingExpectation` 实测落地大小与 SHA-256;**再加一层 PNG 魔数校验**
   (§8 自己的规矩,现已 `[R]`),魔数不符即 `.failed`,不发布。
5. **发布走 file-backed 路径**(与 `trace.htrace` 同,不是组件树那条):PNG 是二进制,
   `publishFile` 不拒绝 `image/png`,也没有可脱敏的文本。`privacy: sensitive`
   控制的是读取授权,不是脱敏 —— 这一点 r2 已经区分清楚。

### 尺寸这件事要写进提案

PNG 450KB / JPEG 41KB,同一屏差 11 倍。AI 循环里每轮一张截图,这是真实的
artifact 预算问题。r5 **只交付 PNG**:魔数可校验、无损、判据便宜。JPEG 形态
(以及 `-w/-h` 缩放)留待有真实预算压力时再议,不在本 r5。

## Out of scope(r5)

- JPEG 形态与 `-w/-h` 缩放;
- `-i displayId` 多显示屏(本设备单屏,未验证多屏行为);
- `-m` 参数(语义未探,不猜);
- 截图与组件树/窗口清单的关联分析。

## r4(2026-07-31):多包应用按"一个目录、一条 install"安装

### 现状与真机事实

`debug.hap@1` 的 `hapArtifactLease` 是**标量** `artifactLease`,引擎的
`resolvedInputArtifact(jobID:)` 也只解析一条,`ProviderExecutionContext`
只带一条。于是 `send-hap` 只能推一个文件、`install-hap` 只能
`bm install -p <该文件> -r`。

2026-07-31 真机确认 `[R]`(见 `evidence/runs/TASK-DHA-001/d5-d9-window-2026-07-31.md`):
`bm install -p <目录>` 与 `bm install -p <文件> -r` **都成立**,所以单 HAP 用
现形态并没有错。缺的是**多模块应用**(entry + feature + 远端 HSP)——它们必须
send 进同一目录,由**一条** `bm install -p <dir>` 安装,逐个装单文件不是等价操作。

### 这一改比看上去便宜:两条关键先例已经在仓里

台账 D5 原先按"需要新的设备变更形态"估价,读代码后不成立:

1. **`mkdir -p <job-owned dir>` 已存在** ——
   `deploy.native-library.app-owned@1` 的 `sendNativeLibraryToStaging` 就是
   `mkdir -p` + **两次** `file send` 进同一目录(库 + 代码签名助手),都在**一个
   step 的进程序列**里。多包的"N 次 send"不需要新 step kind。
2. **目录清理已有安全形态** —— 同一族的 `cleanupNativeLibrary` 是逐个
   `rm -f <file>` 之后 `rmdir <dir>`(受 `stagingDirectoryIsJobOwned` 约束),
   **刻意不用 `rm -rf`**。

→ 因此 r4 明确禁止引入 `rm -rf`:按名逐个删已 send 的 HAP,再 `rmdir` 该
job-owned 目录。`rmdir` 在目录非空时失败,这个"删不干净就报错"正是要的性质。

### What(r4 交付面)

1. **输入面(唯一真正的契约变更)**:新增可选
   `additionalHapArtifactLeases`,元素为 artifact lease、有 maxItems 上界。
   `hapArtifactLease` 保持 required 且语义不变 = entry 包。未提供附加租约的
   请求,其计划、授权面与 argv **逐字节不变**——与 r2 的 `uiComponentTree`、
   r3 的残留同一形态:新能力一律 opt-in。
   Catalog schema 目前的字段类型只有 `artifactLease` 标量,没有数组形,
   故需在 `Catalog/schema/operation.schema.json` 增加数组型并同步生成器与
   WorkflowStep validator(词表 lockstep,先例 CHG-2026-050/053)。
2. **引擎按序解析 N 条租约**:每条都过既有 `validateArtifactBinding`
   (target identity / binding revision 一致),任一条不匹配即 fail closed、
   零 dispatch。`ProviderExecutionContext` 由一条 resolved artifact 扩展为
   有序多条;单条路径保持原字段语义。
3. **provider**:staged 目录值 mint-only(与 `HDCOwnedRemotePath` 同纪律,
   调用方不能提供设备路径);`send-hap` lower 为
   `[mkdir -p <dir>, file send ×N]` 一个序列;`install-hap` lower 为
   `bm install -p <dir> -r`;`cleanup-remote-staging` lower 为
   `[rm -f <each>, rmdir <dir>]`。
4. **判定不放宽**:安装成功仍**只**由 `package-readback` 判定(D2/DHA-HAP-001
   不变);send 的成功仍由既有 readback 判定,不看退出码。
5. **残留**:目录与其中文件的清理失败,按 r3 的 residue 记录(远端路径形态,
   无需新 residue 种类)。

### 真机状态:这一条**没有**被上次窗口证明

上次窗口只验证了"目录里放**一个** HAP 时 `bm install -p <dir>` 成功",
**没有**验证 entry + feature 一起装成一个应用(手上只有单模块 demo)。
故 r4 的真机 AC 依赖一个前置条件:**需要一套多模块签名 HAP**。在拿到之前,
该 AC 如实保持 pending-hardware,contract 面照常交付 —— 不得以"目录形已验证"
冒充"多包已验证"。

## Out of scope(r4)

- 远端 HSP / 共享包的依赖解析(调用方自己决定送哪几个包);
- `installPolicy` 语义(`-r` 之外的策略不变);
- 单 HAP 路径的任何行为改变。

## r3(2026-07-31):清理没做成时,`succeeded` 不得读作"设备干净"

### 现状(实测代码,非推测)

`debug.hap@1` 的 `cleanup-uninstall` 失败后,job 仍记 `succeeded`,设备上留着
这次 job 自己装的应用,而**唯一的痕迹是一行时间线**:

- 正向路径:`recordSkippedOptionalStep` → `skipped cleanup-uninstall: failed("uninstallIneffective: … is still installed after uninstall")`;
- 补偿路径(`compensateDebugHAP`):`compensation failed cleanup-uninstall: …`。

两条路径都**不记 cleanup debt**,因为记录的门是
`step.kind == .cleanupOwnedRemotePath`,而键是 `remotePath`
(`cleanupDebtRemotePath(for:)` 只认 `.cleanupOwnedRemotePath` 与
`.cleanupNativeLibrary`)。`debug.hap@1` 也没有 summary 类 artifact,
`cleanup-uninstall` 不在 `artifactMapping` 里,所以连 `recordMissing` 都不会触发。

结果:一个 E1 job 可以留下**设备可见的残留**并对外报成功,既无持久记录、
也无操作员出路 —— 与 remote path 的残留形成不对称,后者早就有 debt 记录、
`cleanupDebt.list` 与 `cleanupDebt.continue`(CLI 入口见 #866)。

> 台账 D12 原先写的是"要动 `debug.hap@1` 的 step optional 语义"。**那个判断是错的**,
> 与 D1 同类:把症状当成了成因。真正的不对称在**债务的键**上,不在步骤的可选性上。

### What(r3 交付面)

1. **债务的身份从"远端路径"推广为"残留"**:记录可以指向 provider-owned 远端路径
   **或**一个仍然装着的 bundle。既有存储字段保持兼容(路径是其中一种残留)。
2. **记录的门改成"这一步的职责是清理"**,而不是"这个 action 带远端路径";正向与
   补偿两条路径同等对待 —— 补偿路径更重要,因为它恰好在别的事已经出错时才跑。
3. **`cleanupDebt.continue` 对 bundle 残留同样只重跑那条持久化的精确 typed action**,
   并沿用 D2 给 uninstall 的 readback:"结清"意味着 readback 说包没了,
   不是命令退出码为 0。
4. **job 的终态报告不得读作"设备干净"**:`RuntimeJobStatus` 增加该 job 的未结清
   残留计数。`succeeded` 保持原义(这次调试会话做完了要求的事),残留另行可见。
   **不新增终态**,`JobStateMachine` 的转移表保持不动。
5. **`cleanup-uninstall` 仍然是 optional**:`cleanupPolicy: keep` 必须继续把它选出去。
   变的是"跑了但失败"的待遇 —— 今天它与"根本没选中"在记录上无法区分。

### 关于 Catalog

**本 r3 很可能不需要改 `Catalog/**`。** 步骤的 optional/compensation 声明都不变,
改的是引擎与债务台账。之所以仍走 OpenSpec:它改的是一个**已发布 operation 的
失败语义**——`debug.hap@1` 报 `succeeded` 时对调用方的承诺——以及持久化的债务
台账形状,属 AGENTS.md 的安全内核面。实现任务若发现确需 Catalog 变更,按其
allowed paths 处理并在实现 PR 内如实说明。

## Out of scope(r3)

- `cleanupPolicy` 语义本身(`keep` / `uninstall` 的选择规则不变);
- 新增终态(如 `succeededWithResidue`)——需要动 `JobStateMachine` 的转移表,
  收益不抵风险;
- job 内自动重试清理——结清仍是显式操作员动作,与远端路径残留一致。

## Why

MU-1~MU-3(CHG-2026-046/047/048,均已合入;T11 门槛已由 2026-07-29 设备
窗口 attempt#2 关闭)交付了契约、daemon、job engine、bootstrap 与真实
E0 dispatch。现在 `observe.device@1` 能在真机上端到端跑通,但:

1. **产物没有归宿**:引擎只把结果写进 job timeline 与 journal,
   `observe.device@1` 声明的 `device-facts.json` 等 artifact 从未落盘,
   daemon 也没有 artifact 读取面(MU-3 已如实把该面递延本 MU);
2. **E0 采集能力未组合**:T10 交付了 HiLog/UI Dump/Trace 的 typed
   action,但没有把它们编排成一次可提交的 `capture.diagnostics@1`;
3. **E1 面完全空白**:HDC 的 mutation action(send/install/start/stop/
   uninstall/port-forward)尚未实现,`debug.hap@1` 无法执行——这是清单
   MU-4 的核心交付,也是首个需要 runtime capability 的真机面。
4. **Runtime 仍没有 Agent 执行交接**:MU-3 已证明 CLI→daemon→真设备
   的技术链路,但 `BER-HW-*` 的全部 host 命令仍由维护者亲手运行并贴回
   transcript。若继续沿用该窗口模型,新增 operation 仍会把人当作
   Runtime 调用器,与两平面治理中“AI 提交已发布 operation”的目标相悖。

## What changes(T00+T14+T12+T13 垂直交付)

- **T00 Device Runtime Agent 执行交接**:在既有 `ArkDeckAgentClient`/
  `arkdeck` JSON 面上增加一个 one-shot agent runner,封闭执行
  doctor → target list/adopt → submit/wait → artifact query。所有 host
  Runtime 调用由 Agent 执行;调用面只接受 catalog operation、target、
  typed inputs 与 capability reference,不接受 HDC executable/argv/shell,
  也不暴露 capability 创建/修改/批准。等待人类只允许三类结构化
  `humanAction`:设备屏幕首次信任、多候选目标选择、验收所需物理拔插;
  人类不代替 Agent 运行 host CLI。每次执行自动生成脱敏
  `RuntimeAgentExecutionReceipt`(executor、operation、job、target/binding、
  authority reference、humanAction 时间线与终态),不再以人工粘贴
  transcript 作为唯一运行载体。
- **T14 统一 Artifact 模型**(先落地,另两面依赖它):artifact 元数据
  (ID、session/job/step、media type、size、SHA-256、created time、
  provider、target binding snapshot、source operation/version、privacy
  class、retention deadline)、防冲突存储与发布(复用 ArkDeckStorage 既有
  原子发布/path-traversal 防护语义)、artifact ID/lease 访问面(客户端
  永不指定路径)、quota/retention/pin/GC/cleanup debt、默认 redaction
  (token/credential/host path)、manifest 记录 catalog digest 与缺失
  artifact。daemon 增 `artifact.list`/`artifact.inspect`/`artifact.read`
  (有界读)与 `artifact.export`(仅按 ID 导出到调用方指定本地目录)。
  **`observe.device@1` 的四个 artifact 随本面真正落盘**,补齐 MU-3 的
  递延项。
- **T12 `capture.diagnostics@1`**:把 T10 的诊断 action 编排为一次
  operation——preflight → bounded HiLog → UI Dump → bounded Trace →
  receive artifacts → 语义校验 → 索引 → 远端清理 → finalize manifest。
  引擎必须在授权前根据实际选中的步骤计算 effective effect:不选择远端
  trace 时为 E0/readOnly;选择 remote-file trace/cleanup 时为
  E1/deviceMutation,必须持匹配 capability,不得按 operation 的 minimum
  effect 放行。
  **部分成功必须逐 artifact 如实标注**(缺 trace 不得记为整体成功);
  cancel 时停止仍在运行的采集并在安全边界收取已完成产物;超总 byte
  budget 有序截断或失败,不耗尽磁盘;远端清理失败记 cleanup debt 供
  后续 reconcile。
- **T13 HDC E1 Action Pack + `debug.hap@1`**:新增 mutation typed
  action(send artifact to provider-owned staging、install HAP、package
  readback、start/stop ability、verify process state、uninstall、
  create/remove port forward);`debug.hap@1` 编排为 validate → install
  → **package readback**(install 成功不得只看 exit code)→ start →
  **process/ability readback**(start 成功须有可验证信号)→ capture
  diagnostics → stop → 按 cleanup policy 补偿 → finalize。E1 capability
  一次授权整个 recipe,不逐 step 弹审批;结果未知即停止后续 mutation
  并进入 reconcile。

## 硬件与授权门槛(如实分层)

contract/fake 面随实现 PR 交付并可绿。**真机面分两级,两级的 host
Runtime 命令都由 Device Runtime Agent 执行**:

- `DHA-HW-001`(E0 采集,capture.diagnostics@1):Agent 选择不创建远端
  trace 文件的只读 plan,沿用 MU-3 已验证的默认只读策略,**无需新
  capability**;
- `DHA-HW-002`(E1 调试,debug.hap@1):**首个真机 E1 mutation**,除
  硬件可用外还需维护者签发一张 **E1 RuntimeCapability**(scope 限定该
  target + `debug.hap@1`、effect ceiling deviceMutation、有期限与次数)。
  capability 文档由本 change 起草模板、由**维护者 merge 的 PR** 签发——
  Agent 不得自行创建、修改或批准;capability 生效后由 Agent 引用并执行
  整个 recipe(POL-AGENT-002 不变)。

实现 PR 内两条硬件 AC 均标 `hardware-pending`;窗口与 capability 就绪后
由 Agent 执行并以 evidence-only PR 补记。人类仅作为
`physicalAssistant` 完成设备信任、歧义选择或物理拔插;若环境没有可用的
Device Runtime Agent,AC 保持 blocked,不得退回“维护者代跑 CLI”来冒充
Agent 自动化验收。

## Out of scope

- app-owned `.so` 部署(T15/MU-5)、system `.so`(T16)、Rockchip 刷机
  迁移与 DAYU200 端到端(T17/T18/MU-6)、多轮 AI debug 决策 loop 与
  App 改造(MU-7)、
  模块目录大迁移(T23);
- T00 只交付单次 published operation 的 Agent 执行/暂停/恢复与 receipt,
  不做模型推理、自动改代码或无限循环;
- 不修改 `Catalog/` 中既有 operation 的 effect/授权语义(`debug.hap@1`
  与 `capture.diagnostics@1` 的 catalog 条目在 MU-1 已定稿,本 change
  只实现它们);
- 不修改 `openspec/specs/**`、`workflow-step-registry.yaml`;
- E2 面零改动。

## 与既有 change/task 的映射

- 吸收 chg-2026-025 blocked 任务的对应面:AIN-012(ArkUI UI Dump +
  Trace E1 executor)→ T12/T13;AIN-013(HiLog、HAP、app-lifecycle
  executor)→ T13。两任务状态本 change 不翻转,supersede 登记留待 T25。
- chg-2026-008 的 UD-* blocked 任务(受控 UI Dump 采集)→ T12 的
  UI Dump 面;其 harness 与脱敏器经验被复用,不重建。
- 复用:MU-1~MU-3 全部地基 + ArkDeckStorage 既有 artifact/session/
  manifest 原语(SessionArtifactStore、AtomicSessionManifestPublisher、
  SessionRetentionCatalog)——**不建第二套 artifact 存储**。

## Scope

- Canonical Core Requirements claimed:none
- Change-local acceptance:`DHA-AGENT-001`、`DHA-ART-001`、
  `DHA-CAP-001`、`DHA-HAP-001`(contract/fake)+ `DHA-HW-001`、
  `DHA-HW-002`(realHardware,Agent 执行后补记)
- Core baseline bump:no

## Platform impact

| Platform | Disposition | Reason |
| --- | --- | --- |
| macOS | 实现与真机验收 | Agent 执行 host Runtime;人类仅提供必要物理协助 |
| Windows / Linux | deferred / unchanged | provider/transport 边界已留 |

## Safety, privacy, and compatibility

- E1 fail-closed:缺 capability、scope 不匹配、过期/撤销/耗尽一律拒绝
  (MU-1 的 store 语义已验证);install/start 成功判定必须来自 readback,
  不得凭 exit code;结果未知即停止后续 mutation 并 reconcile。
- Agent runner 不是新命令壳:只能调用 daemon 已发布的 typed operation;
  E0 authority reference 固定为 catalog digest + default read-only policy,
  E1 只引用预先接受的 capability ID;runner 无 capability 管理入口。
- effective effect 取实际执行 plan 的最大 step effect,不得只看 catalog
  minimum;remote trace/cleanup 永远不能借 E0 默认策略 dispatch。
- artifact 隐私:HiLog/dump/trace 默认按 privacy class 标注并做基础
  redaction;原始高敏产物需显式标记与授权访问;**设备原始日志/trace/
  dump 永不入 Git**,只落 daemon 私有状态目录。
- 磁盘安全:总 byte budget 与 quota 双层约束;接近 quota 时拒绝新采集
  而非破坏既有 artifact。
- 回滚:revert 实现 PR;artifact 存储为新增独立目录结构,无既有数据
  迁移。

## Approval and flow

r1 proposal PR 合并构成初始批准；随后命中的 typed stdout blocker 已按
stop condition 中止实现。r2 proposal revision 合并构成对 fresh pins、依赖闭合
和恢复边界的 D1 readiness 批准，并使 `TASK-DHA-001` 恢复为 ready。实现 PR
仍交付代码+测试+文档+evidence(contract 面)+状态翻转
(hardware-pending)；真机窗口与 E1 capability 仍由后续独立 D2 载体处理。
