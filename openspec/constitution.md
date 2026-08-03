# ArkDeck Constitution

> ID：ARK-CONSTITUTION  
> Version：1.0.0  
> Status：in baseline CORE-2.0.0（ratification 状态见 `openspec/baselines/CORE-2.0.0.yaml`）

## POL-SPEC-001 Specification is the source of truth

`openspec/specs/`、锁定 contracts 和 accepted baseline SHALL 定义产品行为。实现、任务、平台设计和代码注释 SHALL NOT 改写这些行为。

## POL-PLATFORM-001 One product, multiple platform ports

macOS、Windows、Linux 和其他未来平台 SHALL 实现同一组 Core Requirement 和 Acceptance Scenario。平台 Profile MAY 选择不同 API、UI toolkit、打包和系统集成，也 MAY 施加更严格限制；它 SHALL NOT override、relax 或重新编号 Core 规则。

平台无法满足 Safety Requirement 时，该能力 SHALL 标记为 `nonConformant` 或不发布，不能以平台特例伪造通过。

## POL-PLATFORM-002 Declared platforms have explicit revalidation debt

任何 Core MINOR/MAJOR change SHALL 在 proposal 中说明对每个 declared target platform 的影响。已处于 `verified` 的平台在新 Core baseline 下 SHALL 立即变为 `needsReverification`，直到同一新 Conformance suite 通过。尚未开始实现的平台（如当前的 Windows/Linux）记录 `deferred` 即可，不阻断批准；`deferred` SHALL 禁止该平台的新支持声明或 release，它不构成 AC 豁免。

## POL-SAFETY-001 Fail closed under uncertainty

设备身份、server ownership、通道保护、外部副作用结果、destructive step 状态或恢复结果不确定时，系统 SHALL 停止危险推进并进入明确的等待、失败或 recovery 状态。系统 SHALL NOT 从相似型号、退出码 0、endpoint 重用或缺失 outcome 推断成功。

## POL-TARGET-001 Identity before convenience

`connectKey` 只用于寻址。任何 device mutation 前，系统 SHALL 使用已确认且已持久化的 binding revision。TCP/UART 断线后 SHALL 人工确认；USB 自动重绑定 SHALL 满足 Core 不可降低的证据基线。

## POL-HDC-001 Protect shared HDC infrastructure

HDC server 是 host-wide 共享资源。ArkDeck SHALL 建模 server ownership，SHALL NOT 自动停止 external/unknown server，并 SHALL 将 server 全局事件传播到所有受影响设备和 Job。

## POL-WORKFLOW-001 Typed and auditable side effects

所有外部操作 SHALL 由封闭 typed step 表达。系统 SHALL 在副作用前 durable 写入 intent，在完成后写入 outcome。host 命令 SHALL 使用 executable + argument array，不得拼接 shell 字符串。

## POL-RECOVERY-001 Unknown outcomes are never replayed blindly

只有 `stepIntent` 而没有 `stepOutcome` 的 destructive step SHALL 标记为 `outcomeUnknown`。系统 SHALL NOT 自动重放或猜测性补偿。放弃恢复必须先持久化审计，再释放 lane 和 storage claim。

## POL-ARTIFACT-001 Raw evidence is immutable

Raw Artifact SHALL 不被原地修改。过滤、合并、符号化和格式转换 SHALL 生成可重建的 derived Artifact，并记录来源、参数、size 和 hash。

## POL-MODE-001 Execution modes cannot be confused

`execute`、`planOnly` 和 `simulated` SHALL 使用不同语义和持久化标识。Plan-only SHALL 零 device mutation/destructive dispatch；Simulated Provider SHALL 不接受真实 `connectKey` 或启动真实工具。两者 SHALL NOT 计入真实硬件支持。

## POL-STORAGE-001 Shared host resources require coordination

不同 Job 共享 HDC server 和主机卷。系统 SHALL 使用 per-volume 软额度、metadata/finalization headroom 和 writer admission；同卷在 MVP 中最多一个 heavy writer。软额度 SHALL NOT 被描述为真实磁盘块预留。

## POL-PRIVACY-001 Local-first and explicit export

设备 Artifact 和 App 诊断默认 SHALL 只保存在本地，不自动上传。导出 SHALL 由用户发起、可预览并提示敏感数据。私钥、密码和 secret SHALL NOT 写入日志、manifest 或 task evidence。

## POL-VERIFY-001 Evidence, not task completion

每个 normative Requirement SHALL 关联至少一个 Acceptance Scenario 和验证方法。Task 勾选、编译成功、fake 或 simulation SHALL NOT 单独证明规格已满足。发布需要目标平台的 conformance evidence；硬件声明需要对应设备/固件/toolchain 的真实证据。

## POL-AGENT-001 Agents cannot self-approve rule changes

Agent MAY 起草 proposal、delta、ADR、design 和 tasks；Agent SHALL NOT 自行批准产品范围、Safety invariant、Acceptance Scenario、Core schema 或 baseline 变化。为修复实现而放宽测试或规格被禁止。

## POL-AGENT-002 Autonomous destructive execution requires exact E2 authority

自主 Agent MAY 对真实设备 dispatch 已发布 Catalog 所定义的 `destructive` typed Step，
当且仅当持有以下一种、且与本次 dispatch 精确一致的 E2 authority：

1. 维护者经 merged PR 预先批准的 `standingAuthorization`，逐项 pin 目标身份与 binding
   revision、firmware、transport、HDC、Provider、plan digest、Step 集合、recovery path、
   有效期与使用次数；或
2. 用户监督式交互 Agent 会话中的 `evolutionCampaignConfirmation`。Agent SHALL 在同一会话
   展示 exact plan/archive/step-set、脱敏 target/binding、userdata impact、protected-main
   base、candidate allowed paths/diff budget、build target/toolchain、validity 和 attempt
   limit，并如实取得用户确认。campaign 最多 16 个串行 attempts、四小时、并发一。

每个真实 destructive Step 前，protected-main broker SHALL 从已发布 typed plan 重新计算
plan/step set、读取 fresh target/binding facts，并校验 authority、candidate/review pins、
reservation ordinal、有效期和全部预算。任一缺失、已消费、漂移、过期、超限、非 PASS
review、无 fresh reservation、身份/拓扑不确定、`outcomeUnknown`、unresolved intent 或
unsafe partial write SHALL fail closed：新 destructive dispatch 数为 0，并持久记录 blocker
或 terminal disposition。

candidate 仅可在确认的 allowed paths/diff budget 内 build/test；repairer 不得取得 source
workspace，reviewer 只可读 immutable candidate/diff/build/test artifacts。candidate、repairer
与 reviewer 均不得取得 network、USB/HDC/RockUSB、raw shell、Runtime 或 authority
capability，且不得改变 argv、operation、partition、plan、archive、step set、target、broker
或 authorization。只有 protected-main broker 可在 fresh readback 与 durable reservation 后
dispatch。只有前一 attempt durable terminal 且完整 outcome/readback 分类为 `safeToReflash`
时，同一 invocation 才 MAY 自动继续下一轮；success、unknown、unresolved、unsafe partial、
drift、review/repairer 拒绝、取消后的 destructive intent、过期或预算耗尽均 SHALL 永久停止。

普通 CI、后台 daemon/scheduler、无有效 E2 authority 的 Agent 和 caller-supplied
authorization/context SHALL 只运行 contract/fake/simulated/plan-only。USB 连接、Task 风险标记、
事后 evidence 或未绑定 exact plan 的聊天消息都不构成 authority。Agent SHALL NOT 伪造未发生
的确认，也 SHALL NOT 自行创建、修改、批准或吊销 standing authorization；历史 one-shot
`chatConfirmation` 和 legacy execution mode 仅可 decode/export，新 admission/reservation/
dispatch 必须拒绝。真实 hardware evidence SHALL 如实记录 executor（human 或 agent）、实际
authority kind/reference、fresh target confirmation、时间、typed step 与 recovery path；
`evolutionCampaignConfirmation` SHALL NOT 记作 standing authorization，schema-valid evidence
也 SHALL NOT mint、扩大或事后追认 authority。人类亲手执行仍是有效路径。

## Governance

### 权威与冲突

冲突按 `AGENTS.md` 的权威顺序裁决。无法裁决时，受影响 task SHALL 进入 `blocked`，并创建 change proposal。

### 版本

- PATCH：拼写、链接或不改变任何 pass/fail 结果的澄清。
- MINOR：新增可选、向后兼容且不让既有合格实现变为不合格的能力。
- MAJOR：删除、放宽、收紧或改变既有 Requirement、状态机、默认安全策略、schema required field 或验收结果。

ratified/accepted spec 不得直接编辑。候选规格在 ratification 前可经审查修正；ratification 后的语义变化必须通过批准的 change delta。ID 永不复用，移除 ID 保留 tombstone。

### Baseline

每个执行任务 SHALL 明确其针对的 Core baseline 版本与所属 approved change。Baseline 升版只发生在人类批准 Core change、delta 合入 current specs 之后；批准载体是维护者对相应 PR 的 review（见 `governance/enforcement.md`）。

### 合规审查

Core change 至少审查：平台一致性、安全失败模式、数据/schema 兼容、验收可执行性、迁移/回滚影响，以及 traceability。任何未通过项都会阻止批准。
