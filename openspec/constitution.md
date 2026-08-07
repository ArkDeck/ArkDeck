# ArkDeck Constitution

> ID：ARK-CONSTITUTION  
> Version：2.0.0
> Status：candidate CORE-4.0.0（current ratified baseline remains CORE-3.0.0）

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

只有 `stepIntent` 而没有 confirmed `stepOutcome` 的 destructive step SHALL 标记为
`outcomeUnknown`。系统 SHALL NOT 重放该 intent、猜测其结果或把后续恢复结果追溯写成该
intent 的 outcome。

protected-main Runtime MAY 在不询问用户的情况下执行一个独立、typed 的 complete-overwrite
recovery，但仅当它从 durable operation/profile/plan facts 保守计算出所有 outstanding
intent 的完整 `uncertainEffectSet`，已发布 Provider contract 声明 exact operation/profile
支持 complete-overwrite supersession，且 fresh stable identity/binding/topology、immutable
Artifact、全覆盖映射、逐项 semantic verification 和 budget 全部可机械证明。Runtime SHALL
为该恢复生成独立 capability、reservation、intent/outcomes；只有全部写入及
reboot/rebind/postflight 成功后才可 durable 写 `SupersedingRecoveryEpoch` 并释放 target lane。
原 intent 的 `outcomeUnknown` 保持不可变。

任一 possible effect 无法界定或覆盖、stable physical identity 未知、trusted fact 漂移、
Provider 未发布安全声明、取消待处理或预算耗尽时，新的 destructive dispatch SHALL 为 0。
UI 点击、聊天确认、caller/evidence 声明不得替代缺失证明。系统 SHALL 报告不可由确认绕过
的安全 blocker，而不是请求用户批准重放。放弃恢复仍须先持久化审计，再释放 lane 和
storage claim。

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

## POL-AGENT-002 Runtime-owned admission and recovery for destructive Agent execution

仓库 SHALL NOT 再定义独立 E2 执行等级，也 SHALL NOT 要求
`standingAuthorization`、`evolutionCampaignConfirmation`、Git Task/PR、AUTH-ID、legacy
mode、UI acknowledgement 或每轮聊天确认作为真实 `destructive` dispatch 的 authority。`destructive` SHALL
继续作为不可降低的 `WorkflowEffect`，不得通过改标为 `deviceMutation`、`readOnly` 或
human execution 绕过本条。

自主 Agent MAY 请求执行已发布 Catalog 的真实 `destructive` typed operation。只有
protected-main Runtime MAY 在完整 materialize 该 operation 的 typed plan 后，从已发布
Catalog policy 与 Runtime 自己取得的 trusted facts 确定性生成、持久化和消费
`RuntimeCapability`；caller、Agent、candidate、repairer、Manifest、evidence 与聊天文本
均 SHALL NOT 创建、提供、修改或扩大该 capability。Agent-facing surface SHALL NOT 暴露
capability install/revoke/admin。

destructive RuntimeCapability SHALL pin operation/version、stable target identity、binding
revision、exact typed inputs、plan digest、archive/artifact digest、有效期、并发和使用预算。
每个真实 destructive epoch 前，Runtime SHALL 从已发布 operation 重新计算 plan/step set，
验证 Artifact lease，读取 fresh target/binding/tool facts，并 durable reserve 当前 use。任一
operation/profile/target/binding/input/plan/archive/artifact/tool/freshness/reservation 缺失、
未知或漂移 SHALL fail closed：新 destructive dispatch 为 0，并持久记录 blocker。

一个自动化 invocation 的硬上限 SHALL 为 16 个串行 destructive epochs、四小时、并发一。
普通下一 attempt 只有在前一 attempt durable terminal 且分类为 `safeToReflash` 时才 MAY
继续。存在 `outcomeUnknown`、unresolved intent 或 partial write 时，原始 intent SHALL 永不
重放；只有 `POL-RECOVERY-001` 的完整机械证明成立并 durable 分类为
`safeToSupersedeByCompleteOverwrite` 时，Runtime 才 MAY 自动启动一个独立 recovery epoch。
该 recovery 若再次 unknown，后续 epoch 必须重新覆盖所有旧与新增 uncertain effects，并
继续计入同一预算。

只有成功的 `SupersedingRecoveryEpoch` 才可使已覆盖的 uncertain intents 不再阻断 target
lane；它 SHALL NOT 修改原始 outcome 或声称原 Job succeeded。已有 durable 后续 Flash
history 仅在相同 identity、时序、完整覆盖、逐项 outcome 与 postflight 均可验证时 MAY
补记该 relation。缺失证明、identity/topology drift、不可覆盖 effect、repair rejection、
取消、过期或预算耗尽 SHALL 硬停止且零新 dispatch；用户确认不得 override。

candidate 只可在 task-owned isolation 中按已确认的 source scope build/test；repairer 不得
取得 source workspace。candidate 与 repairer 均不得取得 network、USB/HDC/RockUSB、raw
shell、Runtime 或 capability admin surface，且不得改变 executable/argv、operation、
partition、plan、archive、step set、target、coverage proof 或 broker。只有 protected-main Runtime 可拥有
真实 transport 并 dispatch。

UI MAY 展示 userdata impact、确认或警告，但该文本/点击不是 Runtime authority，且 SHALL
NOT 成为 headless Agent 执行、ordinary continuation 或 eligible complete-overwrite recovery
的前置条件。真实 hardware evidence SHALL 如实记录 executor、effect、RuntimeCapability、
fresh target confirmation、reservation/use ordinal、actual typed Steps、Artifact hashes、
uncertain-effect/coverage digests、supersession links、时间与 terminal/recovery disposition；schema-valid
evidence SHALL NOT mint、扩大或追溯提供 capability。

历史 `standingAuthorization`、`evolutionCampaignConfirmation`、one-shot
`chatConfirmation` 与 legacy execution-mode bytes SHALL 仅可 decode/export；新的 writer、
reservation、admission 或 dispatch SHALL 拒绝这些 authority kind，且 SHALL NOT 把它们
迁移为 RuntimeCapability。人类与 Agent 的真实 destructive execution 使用同一 Runtime
safety gate；human presence 不得放宽 typed-only、identity、durability、privacy 或 recovery
规则。

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
