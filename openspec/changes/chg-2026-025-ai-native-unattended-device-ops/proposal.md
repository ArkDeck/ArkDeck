---
id: CHG-2026-025-ai-native-unattended-device-ops
revision: 3
status: approved # r1 经 #281 正式批准；r2 已合入；r3 全设备工作台扩展仅在维护者 review/merge 本修订 PR 后生效
class: core
core_change_level: major
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# AI Native 无人值守设备操作:授权从"人类亲手执行"上移为"人类批准计划"

> r3 expansion stop gate（2026-07-28）：r2 已闭合 Rockchip destructive executor 的
> host 侧实现，但最新 `main` `d42c002609177e47ef95320cb5bdc0a42f0b510e`
> 仍把 M0B、Trace 与 UI Dump 采集 harness 硬编码为 `Human-operated` /
> `controlledHumanCapture`，且产品没有覆盖 UI Dump、Trace、HiLog、HAP/SO 部署的
> Agent typed control surface。r3 只起草统一自动化边界、delta、tasks 与 verification；
> 维护者 merge 本 revision 前，新增 TASK-AIN-009—017 全部保持 blocked，任何现有
> human-only harness 不得被 Agent 直接用于真机 dispatch。

> r2 stop gate（2026-07-22）：复审发现 r1 实现只校验调用方提供的授权/context
> 字段，未证明授权来自受保护 `main`，也未从 durable journal 与实时设备自行取得
> usage/binding/prerequisite/readback；通过后仍只生成 handoff 而不由产品 executor
> dispatch。`TASK-AIN-004` 因此重新进入 `blocked`。在 r2 新增任务全部 done、独立
> readiness 再次由维护者 merge 前，现有 AUTH 载体不得用于任何真实 destructive
> dispatch。

## Why

ArkDeck 是 AI Native 项目:维护者(owner)于 2026-07-22 明确产品方向——后续刷机、
日志抓取与分析工作由 AI 无人值守自动化执行,人类角色上移为规则与计划的批准者。
现行规则(Constitution `POL-AGENT-002`、`REQ-FLASH-015`、AGENTS.md 禁令、
enforcement.md"真实硬件与 destructive 操作"节)把"人类操作者亲手执行"作为真实
硬件 destructive 操作与 realHardware evidence 的必要条件,与该方向直接冲突。

该规则在 2026-07 制定时的两个前提如今都已变化:

1. **执行风险已技术化**:CHG-2026-016(五窗口恢复演练,Loader `wlx` 重刷路径
   verified)、CHG-2026-020(RF-001 契约 + RF-002 Swift Provider/安全门/
   `arkdeck flash` CLI 真机验收)、TR-002/TR-002R(四道 fail-closed 凭据语义门,
   real-fault 注入证伪)已把"执行者是谁"与"执行是否安全"解耦——安全性由 typed
   step、binding revision、plan 精确一致性校验与恢复路径承载,不再依赖人手。
2. **人工窗口成为吞吐瓶颈**:设备窗口人工执行模型下,TR-001、chg-024 采集、
   M0B-002 等任务长期攒窗口排队;人类亲手执行的边际安全价值已低于其吞吐成本。

截至 r3 盘点，治理层已允许 Agent 执行 E0/E1/E2，但产品与一次性采集脚本仍存在
“规则允许、入口拒绝”的落差：只读采集仍要求维护者运行脚本；Trace/UI Dump 只有
plan、gate 或人工 harness，没有统一的 journal-backed production executor；HAP 安装、
应用启停和 file send 虽已在 typed step registry 中登记，却没有 Agent 可调用的闭环；
`.so` 部署甚至缺少声明目标、ABI、权限、原值快照、验证和回滚的 typed profile。该落差
使 AI 只能生成 crib 再等待人类照抄执行，不能完成“采集 → 分析 → 部署 → 重启/复验 →
证据归档”的自动调试循环。

不变的前提:威胁模型仍是"自主 Agent 可能伪造证据、静默扩权、绕过验收"。因此本
change **只移动执行权,不移动批准权**——唯一信任根(受保护 main + 维护者
CODEOWNER review,merge 即批准)与 `POL-AGENT-001`(Agent 不得自批规则)零改动。

## What changes

In scope:

- **Constitution `POL-AGENT-002` MODIFIED**(载体 `constitution-delta.md`,archive
  时合入并升版 constitution 2.0.0):自主 Agent MAY 无人值守执行含 destructive 在内
  的真实设备操作,前提是 ready 任务 + destructive 面持维护者 merged PR 预先批准的
  standing authorization + 执行门逐项校验 fail closed + evidence 如实记录 executor。
- **`specs/flashing` REQ-FLASH-015 MODIFIED**(载体 `specs/flashing/spec.md`):
  保留 AC-FLASH-015-01/02(fail-closed 面,语义收敛为"无授权/授权不匹配即阻断"),
  ADDED AC-FLASH-015-03(有效授权下的无人值守执行产生有效 realHardware evidence)。
- **`contracts/hardware-evidence.schema.json` 2.0.0 → 3.0.0**(草案
  `contracts/hardware-evidence.schema.v3-draft.json`):`operator` 字符串(仅人类)
  替换为 `executor` 对象(`kind: human|agent`;agent 必须携带 `authorizationRef`)。
- **治理文档面同步**(TASK-AIN-001):AGENTS.md 禁令、enforcement.md、
  verification/policy.md、hardware-matrix.md 序言、change 模板中"只能由人类执行"
  表述按新模型改写。
- **ArkDeckKit 执行门改造**(TASK-AIN-003):workflow authorization gate 新增
  standing-authorization 校验路径;无授权/不匹配仍 policyBlocked。
- **首次无人值守真机验收**(TASK-AIN-004):agent 无人值守执行日志采集 + pinned
  plan 刷机,产出首份 `executor.kind=agent` 的 realHardware evidence。

### r2 security-remediation additions

r2 不撤回 AI Native 产品方向，但补齐 r1 未形成的可信执行闭环：

- **TASK-AIN-005 — locked contract 对齐**：新增 change-local manifest/journal/
  authorization-usage 草案与 provider-contract delta，表达由执行宿主在可信授权解析后
  mint 的 `authorizedAgent`、逐 destructive intent 的 `authorizationRef`、actor-neutral
  confirmation 和跨 Session 原子 usage reservation；`standardAgent`/ordinary CI 无可信
  grant 时仍保持 destructive `notRun`。
- **TASK-AIN-006 — authorization provenance + trusted facts**：CLI 只提交
  `authorizationId`，不得提交授权 bytes、`approvedBy/carrier`、prior run count、binding
  revision、prerequisites 或 identity readback。执行宿主从 freshly fetched 受保护 `main`
  + GitHub merge/review metadata 解引用授权，从 durable binding/journal/usage store 与首步前
  实时 probe 取得事实；缺失、过期、不可联网且无合格缓存、任一漂移均零 dispatch。
- **TASK-AIN-007 — 产品内 typed executor**：授权通过后由 journal-backed Rockchip
  executor 自行执行固定 `ld/ppt/wlx/rd` argv，逐步 durable intent/outcome、critical safe
  boundary、semantic parser、postflight 与 recovery；不得再输出命令后交给 Agent 外部 shell。
- **TASK-AIN-004 重新阻断**：既有 r2 readiness 作为历史保留；其下一次 readiness 必须
  pin AIN-005/006/007 的 main OID、重新取得未过期 authorization，并证明执行环境中 Agent
  只能经受控执行宿主获得真实 device/tool capability。

### r3 all-device-workbench additions

r3 把同一可信宿主从“只支持 Rockchip E2”扩展为通用 Agent device-operation plane：

- **E0 默认无人值守**：设备/工具/capability 观察、HiDumper inventory 与只读 Recipe、
  HiLog host stream、hitrace/bytrace probe、owned Artifact receive 和 host 分析不再要求
  device window 或人类代跑；任务 ready 且设备已有 durable binding 即可执行。
- **E1 typed capability 后无人值守**：owned remote capture、temporary parameter
  snapshot/set/restore、采集启停、保留数据的 HAP install/replace、应用启停、端口转发、
  reboot、向 Job-owned staging path 发送文件，均由可信宿主验证 per-device capability、
  写 intent/outcome 并自动补偿；不得由 harness 或 Agent shell 绕过。uninstall、
  clear-data、downgrade、持久参数/全局 buffer 变更按 data impact 提升为 E2 或返回
  `impactApproval`，不以 E1 名义静默执行。
- **HAP/SO 产品化部署**：HAP 使用现有 `installPackage` typed step；`.so` 新增封闭的
  deployment profile，固定 ABI、目标、owner/mode、旧值快照、原子发布、加载验证、进程
  重启和 rollback。写 Job-owned staging 属 E1；覆盖系统分区、无可验证 rollback 或会
  破坏 boot/runtime 的目标提升为 E2，复用 standing authorization。
- **Agent control surface**：产品提供 local、machine-readable request/status/cancel/
  reconcile/result 面，只接受 operation/profile/artifact lease/binding reference/
  authorization ID；拒绝 caller-supplied executable、argv、shell、grant bytes、
  readback、usage 或 outcome。
- **自动调试闭环**：一次 Agent Job 可组合“部署 → 启动 → Dump/Trace/HiLog →
  host 分析 → 生成 derived Artifact/下一步建议 → 复验”，但下一次 effect 仍重新走
  E0/E1/E2 admission；分析结果本身不能升级权限。
- **人工边界白名单化**：只保留系统/物理上 Agent 无法完成或治理明确要求的人类动作：
  首次设备信任弹窗/解锁、物理接线/按键/断电、OS picker/entitlement/driver/udev/group/
  Keychain/签名凭据配置、TCP/UART 或歧义 USB 的身份确认、outcomeUnknown 的风险处置、
  external/unknown HDC lifecycle、持久配置/数据丢失影响确认、D1/D2 review 与 standing
  authorization。所有 blocker 产出机器可读 `humanActionRequired` 而不是继续等待含糊的
  “人工窗口”。
- **现有 harness 迁移**：`m0b_capture`、`trace_capture`、`ud_capture` 的封闭命令、脱敏和
  golden 逻辑转入产品 executor/fixture tests；历史 `controlledHumanCapture` bytes 保持
  不改写，新 run 使用 `realHardwareE0ReadOnly`、`realHardwareE1DeviceMutation` 或
  `realHardwareE2Destructive` 如实分类。

Out of scope / Non-goals:

- `POL-AGENT-001`(Agent 不得自批规则/范围/授权)零改动;
- 其余全部 fail-closed 宪法条款(POL-SAFETY-001/TARGET-001/HDC-001/RECOVERY-001/
  MODE-001/ARTIFACT-001/PRIVACY-001/VERIFY-001)零改动;
- **普通 CI(GitHub Actions)权限不变**:不持 standing authorization、无设备,仍限
  contract/fake/simulated/plan-only;
- 诚实证据规则不变:simulation/fake/plan-only 永不计入真实硬件验收;
- V2 PR 链流程(propose→approval→readiness→实现→done→verify→archive)不变;
- Windows/Linux 端口(未启动,deferred)。
- 任意 shell/PTY、LLM 直接持有 HDC/rkdeveloptool USB capability、自动提权、自动安装
  driver/helper/系统 rule、自动处理设备信任弹窗或物理按键；
- 未经 profile 的任意远端路径写入、任意 `.so` 覆盖、自动 root/smode/remount；
- 把 Agent 分析结论、测试通过、聊天指令或“设备在线”当作 E1 capability / E2
  standing authorization；
- 自动上传 raw Dump/Trace/HiLog、扩大 MVP 到 Fault/Crash Artifact 或 System
  Diagnostic Snapshot。
- 把 ArkDeck 扩成任意 OpenHarmony 源码 build farm 或通用 shell runner；AI 可在其受控
  开发仓库/构建任务中产出 HAP/SO，ArkDeck 只消费经 hash 与 file lease 固定的 Artifact，
  负责设备部署、采集、复验和证据。

Observable behavior before/after:

- Before:Agent 执行凭据 + 真实 binding + destructive Step → 恒 policyBlocked,
  只能产出 plan 与人工 crib;realHardware evidence 只能由人类操作者产生。
- After:上述组合在存在逐项匹配的 standing authorization 时允许 dispatch,agent
  无人值守执行并产出有效 realHardware evidence(executor.kind=agent +
  authorizationRef);无授权或任一项不匹配时行为与 before 完全一致(fail closed)。
- 只读采集(hilog/hitrace/hidumper probe/artifact 拉取)与 host 侧分析:在
  approved change 的 ready 任务范围内即可无人值守执行,不再有"设备窗口"概念
  (执行分级 E0,见 design.md §1)。
- r3 Before：E0/E1 的多数真机路径仍以 human-only Python harness、人工窗口或 UI
  click 为唯一入口，HAP/SO 部署与采集分析不能组成一个 Agent Job。
- r3 After：除明确列入 human-boundary registry 的配置/物理/治理动作外，所有已登记
  typed operation 均可由 Agent 经可信宿主无人值守执行、恢复和归档；无合格 binding、
  capability、profile 或 authorization 时返回精确 blocker 且 effect dispatch 为 0。

## Scope(涉及的 Requirement/AC)

- Requirements:REQ-FLASH-015(MODIFIED);Constitution POL-AGENT-002(MODIFIED);
  REQ-WF-003/REQ-DEV-009/REQ-DUMP-009/REQ-TRACE-010/REQ-DEBUG-008(ADDED)
- Acceptance:AC-FLASH-015-01(保留)、AC-FLASH-015-02(保留)、AC-FLASH-015-03
  (ADDED);r3 ADDED AC-WF-003-01/02/03、AC-DEV-009-01、
  AC-DUMP-009-01、AC-TRACE-010-01、AC-DEBUG-008-01/02/03/04
  (archive 时 acceptance registry 111 → 122)
- Contracts/schemas:hardware-evidence.schema.json 2.0.0 → 3.0.0；r2 另纳入
  manifest/journal/provider contract 的 authorized-agent delta 与新增
  authorization-usage contract；r3 新增 agent-device-operation 1.0.0 与
  human-action-required 1.0.0 contracts，并扩展 workflow step/catalog 的封闭部署面
  （版本号由 TASK-AIN-009/010 readiness 精确钉定）
- Core baseline bump:**需要,CORE-2.1.0 → CORE-3.0.0**(MAJOR:改变既有 Safety
  Requirement 的执行边界)

## Safety, privacy, and compatibility

- Failure modes:授权缺失/过期/超次、任一 pinned 项漂移、设备身份读回不匹配、
  binding revision 不符 → 一律零 dispatch + policyBlocked + blocked-attempt 记录
  (与现行 fail-closed 语义同构);执行中 outcomeUnknown 沿用 POL-RECOVERY-001,
  不自动重放。
- Data/schema compatibility:既有 v2 evidence 记录不迁移不改写;v3 只用于新记录;
  两版 schema 并存,`schemaVersion` 判别。r2 的 manifest/journal 新版本同样与 v1 历史
  并存，不原地重写；旧 schema 永远不能承载 authorized-agent destructive success。
- 平台影响:macOS 在 CORE-3.0.0 ratify 后按 POL-PLATFORM-002 转
  `needsReverification`;r2 修改 REQ-FLASH-015，r3 只新增五个 Requirement、不改写其他
  accepted Requirement。重验面 = 现行 Swift 全量基线 + TASK-AIN-003 历史回归 +
  TASK-AIN-005/006/007 新 contract/executor tests + TASK-AIN-004 真机验收 +
  TASK-AIN-009—017 的 E0/E1 control/executor/deployment/realHardware 面。
  Windows/Linux 未启动,deferred。
- Rollback/migration:revert delta 即回到人工执行模型;standing authorization 载体
  全部在 git 历史,可审计可吊销(吊销 = 维护者 merge 撤销 PR);已产出的
  executor=agent evidence 保留并如实标注其授权依据。
- r3 数据兼容：历史 human harness、golden 与 `controlledHumanCapture` provenance
  只读保留，不批量改写；新 contract 使用新 schemaVersion。Agent control plane 可整体
  feature-disable 回退到现有人类/UI 路径，但不得因回滚把已持久化 intent/outcome 或
  unresolved hazard 隐藏。
- r3 平台影响：macOS 纳入 CORE-3.0.0 `needsReverification` 的新增面包括 E0/E1
  production executor、Agent control plane、HAP/SO deployment 与真机闭环；Windows/Linux
  仍 deferred，且未来端口必须实现相同 contract/AC，不能恢复 human-only 作为 Core 豁免。

## r1 approval and flow history

以下记录描述 r1 已完成的 propose/approval 流程，不是 r2 的现行执行许可。r1 以独立
approval-only PR 批准原四任务 scope 与 delta 方向；每个任务仍须独立 readiness。r2 复审
已证明“approve + 旧 AIN-004 readiness”不足以形成可信执行闭环，因此 AIN-004 当前必须按
下方 r2 boundary 保持 blocked。verified 翻转与 archive(合入 constitution/specs/schema、
ratify CORE-3.0.0)仍各自使用独立 PR。

## r1 approval record

- r1 proposal 经 PR #280 合入 main(merge commit
  `5ed66d44a7414608e9ffa9b10a627a2ebec37001`,status:proposed,merged by
  维护者 @lvye,2026-07-22)。owner 方向确认:2026-07-22 维护者亲自提出
  "允许 AI 无人值守执行刷机/日志抓取/分析"并指示开出本 approval PR。
- 正式批准:2026-07-22 由本 approval-only PR(先例 #55/#89/#171/#195/#226/
  #253/#254)将本 change 置为 `approved`;批准由维护者 review/merge 本 PR 构成。
  merge 即批准:
  - **delta 方向**:Constitution POL-AGENT-002 MODIFIED(constitution-delta.md
    完整替换文本,1.0.0 → 2.0.0)、REQ-FLASH-015 MODIFIED + AC-FLASH-015-03
    ADDED(specs/flashing/spec.md delta)、hardware-evidence schema
    2.0.0 → 3.0.0(executor 对象,v3-draft);class core /
    core_change_level major,CORE-3.0.0 候选;
  - **执行模型**:执行分级 E0/E1/E2、standing authorization 载体与失效规则、
    执行门五步校验序列、evidence v3 字段面(design §1–§4);
  - **四任务 scope 与边界**:TASK-AIN-001(治理文档面同步,host-only)、
    TASK-AIN-002(schema 3.0.0 定稿,host-only)、TASK-AIN-003(Kit 执行门
    standing-authorization 路径 + real-fault contract tests)、TASK-AIN-004
    (首次无人值守真机验收,DAYU200)的 objective/allowed-paths/验证方式;
  - **不动面**:POL-AGENT-001、其余全部 POL-* 条款、普通 CI 边界、V2 PR 链、
    诚实证据规则、凭据分离(见 design §5)。
- r1 批准本身不产生任务执行:原四任务须独立 readiness PR 转 `ready`。
  **r1 批准亦不构成任何一次具体真机执行的 standing authorization**——
  TASK-AIN-004 的授权块须由其 readiness PR 承载并逐项 pin,先例 pins 惯例
  (全 OID/全 hash)适用。delta 与 schema 于 archive PR 合入 current
  specs/contracts 并 ratify CORE-3.0.0;在此之前 current specs 原文不变,
  实现期以 approved delta overlay 为有效规格。

## r2 approval boundary

- 本修订 PR 是 governance-only remediation：只修 proposal/design/tasks/verification 与
  review 记录，不修改 `Packages/**`、current specs/contracts、authorization 载体或真实
  evidence，不执行 device/HDC/network/external tool。
- 维护者 merge 本 PR 即批准新增 AIN-005/006/007 的 objective、顺序与边界，并使
  `TASK-AIN-004 ready → blocked` 生效；**不**使任何新增任务 ready，也不构成新 standing
  authorization。
- AIN-005/006/007 各自必须先有独立 readiness PR，再各用独立实现 PR 与 done PR；三者
  全部 done 后，AIN-004 仍须新的 readiness/authorization PR，旧 #296 readiness 不复用。
- r2 不允许通过放宽 plan pin、设备身份、outcomeUnknown、critical boundary、evidence
  honesty 或 ordinary-CI 边界来修复；任何无法从可信来源证明的值一律视为 unknown。

## r3 approval boundary

- r3 是 proposal revision（D1）：只修改本 change 的 proposal/design/tasks/
  verification、change-local spec delta/contract draft 与盘点记录；不修改 current
  specs/contracts、`Packages/**`、`ArkDeckApp/**` 或现有授权载体，不执行设备/HDC/tool。
- 维护者 merge r3 仅批准新增 Requirements/AC、TASK-AIN-009—017 的 scope/顺序和
  human-boundary 白名单；不使任一新增任务 ready，不创建 E1 capability evidence 或 E2
  standing authorization。
- r3 合入后依次进行 contract freeze、可信宿主通用化、各 capability executor、部署与
  闭环验收；每个任务仍走独立 readiness/实现/done PR。D1/D2 后零投机堆叠规则不变。
- 与活跃 change 的消费关系通过后续 revision 明确处理：CHG-2026-006/008/026 中已存在的
  human-only evidence task 在 r3 executor ready 前保持 blocked；不得在本 proposal PR
  越界改写其他 change 的 task status 或复用旧人工授权窗口。
