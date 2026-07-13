# ArkDeck Constitution

> ID：ARK-CONSTITUTION  
> Version：1.0.0  
> Status：review candidate  
> Ratified：pending protected human approval

## POL-SPEC-001 Specification is the source of truth

`openspec/specs/`、锁定 contracts 和 accepted baseline SHALL 定义产品行为。实现、任务、平台设计和代码注释 SHALL NOT 改写这些行为。

## POL-PLATFORM-001 One product, multiple platform ports

macOS、Windows、Linux 和其他未来平台 SHALL 实现同一组 Core Requirement 和 Acceptance Scenario。平台 Profile MAY 选择不同 API、UI toolkit、打包和系统集成，也 MAY 施加更严格限制；它 SHALL NOT override、relax 或重新编号 Core 规则。

平台无法满足 Safety Requirement 时，该能力 SHALL 标记为 `nonConformant` 或不发布，不能以平台特例伪造通过。

## POL-PLATFORM-002 Declared platforms have explicit revalidation debt

任何 Core MINOR/MAJOR change 在批准前 SHALL 对每个 declared target platform（当前为 macOS、Windows、Linux）记录 `reverifyRequired | nonConformant | deferred` 影响判定、owner 和目标里程碑；缺任一平台即阻断批准。已处于 `verified` 的平台在新 Core baseline 下 SHALL 立即变为 `needsReverification`，直到同一新 Conformance suite 通过。`deferred` 只允许 future/non-shipping platform，并 SHALL 禁止该平台的新支持声明或 release；它不构成 AC 豁免。

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

## POL-AGENT-002 Autonomous agents never execute real destructive hardware workflows

自主 Agent 和普通 CI SHALL NOT 对真实设备 dispatch Flash、erase、format、unlock、真实 update package 或其他 `destructive` Step；它们 MAY 运行 schema/contract tests、fake/simulation、plan-only，并 MAY 生成供人工审核的精确计划。真实硬件 destructive evidence 只能由明确授权的人类操作者在隔离硬件实验环境产生，使用单独的 hardware-lab Task/approval、物理目标确认、恢复路径和仓库外 evidence verifier。把 USB 设备连接到 Agent 主机、Task 标为 high risk 或用户在聊天中说“继续”均不构成该授权。

## Governance

### 权威与冲突

冲突按 `AGENTS.md` 的权威顺序裁决。无法裁决时，受影响 task SHALL 进入 `blocked`，并创建 change proposal。

### 版本

- PATCH：拼写、链接或不改变任何 pass/fail 结果的澄清。
- MINOR：新增可选、向后兼容且不让既有合格实现变为不合格的能力。
- MAJOR：删除、放宽、收紧或改变既有 Requirement、状态机、默认安全策略、schema required field 或验收结果。

ratified/accepted spec 不得直接编辑。候选规格在 ratification 前可经审查修正；ratification 后的语义变化必须通过批准的 change delta。ID 永不复用，移除 ID 保留 tombstone。

### Baseline

每个执行 Task SHALL 固定 Core baseline 版本与 approved change revision。Baseline lock 只有在人类批准 Core change、更新 current specs/contracts、完成一致性审查后才能重建。

### 合规审查

Core change 至少审查：平台一致性、安全失败模式、数据/schema 兼容、验收可执行性、迁移/回滚、macOS/Windows/Linux 影响与 revalidation disposition，以及 traceability。任何未通过项都会阻止批准。
