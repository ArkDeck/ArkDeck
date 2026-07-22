---
id: CHG-2026-025-ai-native-unattended-device-ops
revision: 1
status: approved # r1 propose 经 #280 合入(5ed66d44…7001);本 approval-only PR 由维护者 review/merge 构成正式批准
class: core
core_change_level: major
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# AI Native 无人值守设备操作:授权从"人类亲手执行"上移为"人类批准计划"

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

Out of scope / Non-goals:

- `POL-AGENT-001`(Agent 不得自批规则/范围/授权)零改动;
- 其余全部 fail-closed 宪法条款(POL-SAFETY-001/TARGET-001/HDC-001/RECOVERY-001/
  MODE-001/ARTIFACT-001/PRIVACY-001/VERIFY-001)零改动;
- **普通 CI(GitHub Actions)权限不变**:不持 standing authorization、无设备,仍限
  contract/fake/simulated/plan-only;
- 诚实证据规则不变:simulation/fake/plan-only 永不计入真实硬件验收;
- V2 PR 链流程(propose→approval→readiness→实现→done→verify→archive)不变;
- Windows/Linux 端口(未启动,deferred)。

Observable behavior before/after:

- Before:Agent 执行凭据 + 真实 binding + destructive Step → 恒 policyBlocked,
  只能产出 plan 与人工 crib;realHardware evidence 只能由人类操作者产生。
- After:上述组合在存在逐项匹配的 standing authorization 时允许 dispatch,agent
  无人值守执行并产出有效 realHardware evidence(executor.kind=agent +
  authorizationRef);无授权或任一项不匹配时行为与 before 完全一致(fail closed)。
- 只读采集(hilog/hitrace/hidumper probe/artifact 拉取)与 host 侧分析:在
  approved change 的 ready 任务范围内即可无人值守执行,不再有"设备窗口"概念
  (执行分级 E0,见 design.md §1)。

## Scope(涉及的 Requirement/AC)

- Requirements:REQ-FLASH-015(MODIFIED);Constitution POL-AGENT-002(MODIFIED)
- Acceptance:AC-FLASH-015-01(保留)、AC-FLASH-015-02(保留)、AC-FLASH-015-03
  (ADDED;archive 时 acceptance registry 111 → 112)
- Contracts/schemas:hardware-evidence.schema.json 2.0.0 → 3.0.0
- Core baseline bump:**需要,CORE-2.1.0 → CORE-3.0.0**(MAJOR:改变既有 Safety
  Requirement 的执行边界)

## Safety, privacy, and compatibility

- Failure modes:授权缺失/过期/超次、任一 pinned 项漂移、设备身份读回不匹配、
  binding revision 不符 → 一律零 dispatch + policyBlocked + blocked-attempt 记录
  (与现行 fail-closed 语义同构);执行中 outcomeUnknown 沿用 POL-RECOVERY-001,
  不自动重放。
- Data/schema compatibility:既有 v2 evidence 记录不迁移不改写;v3 只用于新记录;
  两版 schema 并存,`schemaVersion` 判别。
- 平台影响:macOS 在 CORE-3.0.0 ratify 后按 POL-PLATFORM-002 转
  `needsReverification`;除 REQ-FLASH-015 外全部 Requirement 文本不变,重验面 =
  现行 Swift 全量基线 + TASK-AIN-003 新 contract tests + TASK-AIN-004 真机验收。
  Windows/Linux 未启动,deferred。
- Rollback/migration:revert delta 即回到人工执行模型;standing authorization 载体
  全部在 git 历史,可审计可吊销(吊销 = 维护者 merge 撤销 PR);已产出的
  executor=agent evidence 保留并如实标注其授权依据。

## Approval and flow

V2 治理:本 propose PR 合入仅登记提案。批准须独立 approval-only PR(merge 即批准
本 scope 与 delta 方向)。四任务(见 tasks.md)保持 blocked,各须独立 readiness PR
转 ready;实现期有效规格 = pinned CORE-2.1.0 + 本 change approved delta overlay,
因此 TASK-AIN-004 的无人值守真机执行在 approve + readiness 后、archive 前即为合法。
verified 翻转与 archive(合入 constitution/specs/schema、ratify CORE-3.0.0)各自
独立 PR。

## Approval

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
- 本批准不产生任务执行:四任务保持 `blocked`,各须独立 readiness PR 转
  `ready`。**本批准亦不构成任何一次具体真机执行的 standing authorization**——
  TASK-AIN-004 的授权块须由其 readiness PR 承载并逐项 pin,先例 pins 惯例
  (全 OID/全 hash)适用。delta 与 schema 于 archive PR 合入 current
  specs/contracts 并 ratify CORE-3.0.0;在此之前 current specs 原文不变,
  实现期以 approved delta overlay 为有效规格。
