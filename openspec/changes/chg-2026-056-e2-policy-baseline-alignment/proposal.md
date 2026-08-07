---
id: CHG-2026-056-e2-policy-baseline-alignment
revision: 6
status: proposed
class: core
core_change_level: major
owner: lvye
core_baseline: CORE-3.0.0
platforms: [macos, windows, linux]
---

# 移除独立 E2 授权层，统一为 Runtime 安全准入

> r1-r4 已分别落地 bounded campaign、Runtime Agent 规则、独立对抗评审门移除和
> DAYU200 构建事实推导。它们的维护者审批不授权本次 r5。
>
> r5（2026-08-07）响应产品闭环中的直接阻塞：每次真实 Flash 都要先创建或确认
> `standingAuthorization` / `evolutionCampaignConfirmation`，使 AI 修复—构建—UI
> 复验循环依赖一次新的安全载体和精确聊天确认。r5 请求删除独立 E2 执行等级及其
> 人工授权层；`destructive` 仍是不可降级的设备效果分类，并继续触发最严格的
> identity、typed-plan、fresh readback、reservation、journal 和 recovery 规则。
>
> r5 是 MAJOR Safety 裁决；它的提案分支只包含裁决材料，维护者合并到受保护 `main`
> 构成人类批准。r6 仍只含裁决材料；不得据此修改生产代码、Catalog、authority 实例
> 或真实设备，只有维护者 review/merge r6 后新增路径才进入已批准范围。
>
> r6（2026-08-07）不改变 r5 的任何 Safety、Catalog、Runtime 或硬件语义。实现前的
> 路径审计发现，r5 已声明的 `ArkDeckApp/manual UI driver -> Agent XPC -> Runtime`
> 生产链缺少两个 XPC 源文件，CLI surface 清理缺少其实现文件，且 dayu200 v1 profile
> 留有一处仅文本的 E2 陈述。r6 只把这四个精确文件补入 TASK-E2B-001 Allowed paths；
> 不允许借此修改 profile identity/partition mapping、扩大 XPC 方法集或新增执行面。

## Why

现行 `POL-AGENT-002` 把真实 `destructive` dispatch 绑定到两个精确 E2 authority。
这能证明一轮执行获得了特定的人类授权，但它与 Runtime 已经执行的安全校验高度耦合：
同一 plan/archive/target/binding、fresh readback、candidate pin、attempt reservation、
durable intent/outcome 和 unsafe-terminal 停止条件同时存在于 authority 与执行内核。

对 GJ-4 来说，authority 载体已成为产品循环本身的前置物。一次 UI 缺陷修复可能需要
重新构建、重新 materialize plan 和再次刷机；任一代码或计划 digest 变化都会使旧 campaign
失效，即使目标设备、归档和 typed operation 未改变。结果是 AI 自动化把大部分时间花在
重建授权上下文，而不是发现并修复产品问题。

r5 选择把“是否允许已发布操作执行”交回受保护主干 Runtime 的封闭策略：调用方只表达
typed execute intent，Runtime 根据已发布 Catalog 和自己读取的可信事实生成并消费短期
`RuntimeCapability`。调用方、candidate、repairer 和聊天文本都不能提供或扩大这个
capability。这样删除 per-campaign / per-PR 的人工许可，同时保留防止错设备、错字节、
不确定结果重放和任意命令注入的机械边界。

这是明确的风险接受，而不是无风险重构：批准后，一个能够向本地 Runtime 提交已发布
`destructive` operation 的 Agent，不再需要人类为该 plan 单独确认，即可能执行会擦除
userdata 的合法请求。维护者必须在“减少自动化阻塞”和“失去逐次人工 intent 证明”之间
作出裁决；CI 绿色或本提案作者的判断不能替代该裁决。

## Requested decision

维护者被请求批准以下不可拆分的语义：

1. 删除 E2 作为独立执行等级及 `standingAuthorization` /
   `evolutionCampaignConfirmation` 作为新 destructive dispatch authority 的资格。
2. 保留 `WorkflowEffect.destructive`，不得把 Flash、system partition replacement、erase、
   format 或其他破坏性 Step 降级为 `deviceMutation`/`readOnly`。
3. 对 `deviceMutation` 与 `destructive` 统一使用 Runtime-owned `RuntimeCapability`；
   destructive capability 由受保护主干 Runtime 在完整 plan-only materialization 后按
   Catalog 确定性生成，不由 caller、Agent、candidate 或聊天消息签发。
4. destructive capability 仍逐项 pin operation/version、stable target identity、binding
   revision、exact typed inputs、plan/archive/artifact digest、有效期和使用预算，并在每轮
   首个外部效果前 fresh readback + durable reservation。
5. 自动化 invocation 保持最多 16 个串行 attempts、四小时、并发一；只有前一 attempt
   durable terminal 且完整 readback 分类为 `safeToReflash` 才可继续。unknown、unresolved、
   unsafe partial、identity drift、取消后的 intent 或预算耗尽永久停止。
6. 历史 E2 authority/evidence 只可 decode/export，不迁移成 RuntimeCapability，不可为新
   dispatch 提供许可。当前会话曾确认但未消费的 campaign 不被本 change 消费、转换或引用。

若维护者拒绝，现行 E2 规则完整保留；GJ-4 真实 Flash 仍须另一个当时有效、逐项匹配的
E2 authority。本 revision 不允许以“提案已存在”作为绕过理由。

## What changes

In scope:

- 完整替换 `POL-AGENT-002`、`REQ-FLASH-007`、`REQ-FLASH-015` 和 `REQ-WF-004`
  的 E2/confirmation 语义；交互 UI 保留 acknowledgement，headless Runtime 不依赖 UI。
- `AGENTS.md`、governance 和 verification policy 不再把 E0/E1/E2 当作授权阶梯；
  read-only 保持默认只读策略，所有真实设备 mutation/destructive 统一走
  RuntimeCapability，D0/D1/D2 决策等级不变。
- Catalog 的 `oneShotExactPlan` 不再是 destructive operation 的新写入策略；现有已发布
  `flash.dayu200@1` 与 `deploy.native-library.system@1` 改用统一 RuntimeCapability 策略。
  这是已发布 operation 的破坏性授权修改，和本 E2 Safety 变更由同一 change 承载。
- `RuntimeCapability` 允许 protected-main `runtimeDefaultPolicy` 为 destructive plan
  生成 exact、短期、受限 capability；Agent-facing API 仍无 install/revoke/admin surface。
- 新硬件 evidence schema 只为 Agent 写入 `defaultReadOnlyPolicy` 或
  `runtimeCapability`；V4 的 `standingAuthorization` / `evolutionCampaignConfirmation`
  保持历史解码，不进入新 writer 或 admission。
- UI 可以继续展示 userdata impact 和非阻塞性的确认/提示，但该 UI 文本或点击不构成
  Runtime authority，也不是 headless Agent dispatch 的前置条件。
- 实现与本次真实 DAYU200 GJ-4 UI Flash 同车；独立 UI driver 保持手工真机验证工具，
  不注册到默认 UI tests 或任何常规测试套件。
- r4 的板级 profile 与构建事实推导保持不变并继续属于 `CORE-4.0.0` candidate。

Observable behavior:

- Before: Agent 的 exact typed request、可信设备事实和完整 plan 全部一致，仍会因缺少或
  漂移 E2 authority 而 `policyBlocked`。
- After: protected-main Runtime 可从这些可信事实自动 materialize/consume
  RuntimeCapability 并 dispatch 已发布 typed destructive Step；不询问 standing/campaign、
  Git task、PR、AUTH-ID、legacy mode 或每轮聊天确认。
- Unchanged: target/plan/artifact/freshness/reservation 任一不确定时 dispatch 为 0；未知或
  unsafe 外部结果不能 retry/replay；candidate/repairer 不能接触设备、Runtime、authority
  或 raw command surface。

## Out of scope

- 不删除或降低 `destructive` effect，不新增 generic shell/HDC/RockUSB Step，不改变任一
  partition、argv、刷写顺序、Artifact lease、device profile 或 Provider transport。
- 不让 caller 自报 capability、target fact、plan digest、artifact digest 或 outcome 成为
  trusted fact；不开放 capability administration 给 Agent。
- 不在 proposal PR 运行 HDC、RockUSB、Flash、erase、format、unlock 或任何真实设备命令，
  不创建、修改、吊销、迁移或消费任何 authority/capability 实例。
- 不把 contract/fake/simulation/plan-only 或维护者批准本提案记为 `REAL_DEVICE_PASS`。
- 不自动恢复 unknown/unresolved/unsafe partial，不把 UI acknowledgement 伪装为执行授权。

## Scope

- Modified policy: `POL-AGENT-002`.
- Modified requirements: `REQ-FLASH-007`, `REQ-FLASH-015`, `REQ-WF-004`; pending r4
  `REQ-FLASH-016`/`REQ-FLASH-017` wording is synchronized to Runtime-owned admission while
  `REQ-FLASH-018` remains unchanged.
- Modified acceptance: `AC-FLASH-007-01`, `AC-FLASH-015-01`, `AC-FLASH-015-02`,
  `AC-FLASH-015-03`, `AC-WF-004-01`, `AC-WF-004-02`, `AC-WF-004-03`.
- Change-local acceptance: `E2R-CATALOG-001`, `E2R-RUNTIME-001`,
  `E2R-NEGATIVE-001`, `E2R-COMPAT-001`, `E2R-GJ4-001`.
- Modified published operations: `flash.dayu200@1`,
  `deploy.native-library.system@1` authorization policy only; operation IDs, versions, inputs,
  Steps, effect and provider remain unchanged.
- Modified contracts: Catalog authorization vocabulary/generator,
  `provider-contracts.md`, RuntimeCapability model/store and hardware evidence
  schema `4.0.0 -> 5.0.0`.
- Core baseline bump: still required. `CORE-4.0.0` remains the unratified candidate because
  current baseline is `CORE-3.0.0`; r5 replaces the pending r1-r4 E2 semantics before
  ratification rather than creating a second baseline candidate.

## Platform impact

| Platform | Disposition after implementation | Reason |
| --- | --- | --- |
| macOS | `needsReverification` until GJ-4 real-device pass | Production Runtime and DAYU200 Flash are implemented here; host-only checks cannot accept the relaxed authority boundary. |
| Windows | `deferred` | Future port must use identical Runtime-owned destructive admission and recovery semantics. |
| Linux | `deferred` | Future port must use identical Runtime-owned destructive admission and recovery semantics. |

## Safety, privacy, compatibility, and rollback

- **Removed guarantee:** a destructive Agent request no longer carries a separately reviewable
  human approval for that exact plan. This is the intended automation gain and the primary risk.
- **Retained typed boundary:** only a protected-main broker can dispatch an operation/version
  already published in Catalog. Unknown operation/Step remains destructive/unsupported; raw shell
  and caller-supplied argv remain structurally unreachable.
- **Retained identity/byte boundary:** stable identity, binding revision, exact inputs, plan,
  archive and artifact digests come from trusted Runtime materialization and fresh readback.
  Mismatch or uncertainty is a blocker, never a best-effort match.
- **Retained outcome boundary:** intent precedes effect; outcome is durable; cancellation stops at a
  safe boundary; unknown/unresolved/unsafe partial never triggers a new dispatch. A 16-attempt,
  four-hour, single-concurrency budget remains a Runtime safety budget, not a user authority.
- **Retained isolation:** candidate and repairer remain unable to reach source+device together.
  Only protected-main Runtime owns transport and capability mint/consume.
- **Evidence honesty/privacy:** V5 evidence records actual executor, `runtimeCapability` reference,
  plan/target/reservation correlation and Artifact hashes. Device identifiers stay digested and
  raw artifacts remain local/immutable. Evidence never mints capability.
- **Compatibility:** V1-V4 bytes and historical standing/campaign records remain immutable and
  decode/export-only. Active E2 records are not upgraded. New writers emit V5; new admission
  rejects legacy authority kinds.
- **Rollback:** reverting the implementation restores the exact E2 gate for new requests. Any
  RuntimeCapability issued under r5 must be rejected by the old E2 path; durable intents/outcomes
  remain available for recovery and are never replayed by rollback.

## Approval and implementation sequence

1. `CHG-2026-056@r5` adjudication was merged to protected `main` as PR #1178; that merge is the
   repository trust root for the explicit loss of per-plan human intent proof.
2. The r6 PR carries only the exact path-scope addendum below. CI green does not approve it;
   maintainer review/merge to protected `main` does.
3. Only after r6 is present on protected `main` may TASK-E2B-001 touch the added files while
   implementing the already approved r5 deltas, tests and real GJ-4 UI Flash.
4. Implementation must pass all host gates before any device window. Real Flash then uses only the
   ratified/approved Runtime path and records truthful realHardware evidence.
5. Change verification/archive and `CORE-4.0.0` ratification remain separate human decisions.

## r6 path-scope addendum

This addendum repairs only the mechanical implementation scope of the already declared production
path. It does not expand the product or safety decision:

- `Packages/ArkDeckKit/Sources/ArkDeckCore/AgentXPCContract.swift` and
  `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/AgentXPCListener.swift` are the existing App XPC
  allowlist and its enforcement point. The UI cannot reach the protected-main Runtime without a
  closed allowlist for Flash bundle import plus typed Job submit/run. Capability administration,
  target adoption, cancel, reconcile and generic mutation remain forbidden.
- `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift` owns the current
  caller-facing capability commands. Removing Agent capability administration cannot be truthful
  while that active surface remains outside the implementation scope.
- `Catalog/profiles/dayu200.v1.json` changes only the stale prose phrase "E2 capability" to the
  approved Runtime-admission wording. Its identity, operations, partitions and every other byte
  remain out of scope.

The r6 adjudication PR contains no production implementation and performs no device operation.
