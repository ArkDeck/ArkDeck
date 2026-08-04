---
id: CHG-2026-056-e2-policy-baseline-alignment
revision: 3
status: proposed
class: core
core_change_level: major
owner: lvye
core_baseline: CORE-3.0.0
platforms: [macos, windows, linux]
---

# 将有界 E2 campaign 提升为 Core 正本

> r2（2026-08-03）：r1 已由维护者通过 #1014 审查并合入，但 `AGENTS.md` 仍把
> Runtime Agent 的允许路径分散在“禁令”长段、旧 ready-task 措辞与 Repo-plane
> `host_loop` 隔离说明之间。r2 增加 `agents-delta.md`：明确已发布 typed operation
> 的 Runtime Agent 是可执行主体，E0 不需要 Git Task/PR，E1/E2 分别消费 Runtime
> capability / exact E2 authority；同时保留 host_loop 的 Repo-plane 隔离。r2 不把
> 无 authority、身份不明、unknown outcome 或 raw-shell destructive dispatch 变为可执行，
> 也不在本 PR 创建 authority 或接触设备。
>
> r3（2026-08-04）：维护者取消「未合入 candidate 必须先拉起独立 AI 对抗 review，
> 才能进入设备验证/dispatch」的运行时限制。candidate 仍须在 task-owned isolation
> 内完成固定构建和封闭策略输出校验；exact E2 authority、allowed paths/diff budget、
> immutable candidate pin、fresh target/binding readback、durable reservation、typed-only
> dispatch、outcome/recovery 与所有 fail-closed 条件均不变。该修订不把任何 review
> 结论、CI 结果或 candidate 自述变成 authority，也不允许 candidate 接触设备、Runtime
> 或 authority；它只移除每次候选修改都会新建独立 review 会话的前置门，也移除
> workspace promotion 在既有 evaluation 通过后再强制创建的同类运行时会话。

## Why

`AGENTS.md` 与已获维护者批准的
`CHG-2026-025-ai-native-unattended-device-ops@r15` 已定义两个唯一的 Agent E2
authority：逐项 pin 的 merged standing authorization，或同一受监督交互会话中的
bounded evolution campaign confirmation。后者固定 exact plan/target/data impact、
protected-main base、候选修改范围、toolchain、有效期和 attempt 上限；每一轮都由
protected-main broker 重新 materialize plan、读取 target、reserve ordinal，并在不确定
时 fail closed。

当前 ratified `openspec/constitution.md` 的 `POL-AGENT-002` 与
`REQ-FLASH-015` 仍是 human-only 文本。它们会在不显式叠加 CHG-2026-025 scoped delta
的阅读或实现路径中拒绝已经发布的 campaign，且 current provider/evidence contract
无法完整表达其 provenance。这是一个安全边界冲突：既可能造成错误的零 dispatch，也会
诱导实现者以低优先级文本或代码绕过正本。

本 change 不创造新的自由裁量权。它只将已经获批并已经由 production code 实现的 bounded
E2 envelope 提升为下一 Core baseline 的单一事实源，使 Constitution、Flash workflow、
workflow evidence 和 provider contract 使用同一准入规则。

## What changes

In scope:

- `POL-AGENT-002` 从“Agent 永不执行真实 destructive workflow”替换为“只有精确 E2
  authority 才能执行”的规则。唯一有效 authority 是 merged standing authorization 和
  bounded evolution campaign confirmation；普通 CI、后台 daemon/scheduler 和无 authority
  的 Agent 继续为零 dispatch。
- `REQ-FLASH-015` 及其 Scenario 同步这一准入边界，新增有效 authority 的 Agent happy
  path，同时将缺失/漂移/过期/超限、outcomeUnknown、非 safe terminal 和 readback 不确定
  保持为零 dispatch。
- Candidate 的固定构建/策略输出校验和 immutable candidate pin 继续是 dispatch 前提；
  独立 AI adversarial review 不再是 candidate 进入设备验证、reservation 或 dispatch 的
  必要条件，也不再为每次 candidate 修改拉起一个运行时会话。正常的 PR/维护者审查不受
  此变更影响。
- workspace-backed Harness 的既有 evaluation 已通过时，直接走既有 promotion/normal PR
  路径；不再为 promotion 再调用 adversarial reviewer。此处不改变评估标准、构建、测试、
  设备验证或维护者的正常 PR review。
- current workflow、provider 和 hardware-evidence contract 能表达
  `evolutionCampaignConfirmation`，并要求 evidence 如实记录 authority kind/reference、
  fresh target confirmation、attempt ordinal 和 terminal disposition。Schema validity 仍不
  mint authority，事后 evidence 仍不得追认 dispatch。
- enforcement 与 verification policy 统一到同一 E0/E1/E2 词汇和 campaign 限制。
- `AGENTS.md` 的候选同步移除对有效 Runtime Agent 的人类代执行、Git task/PR 或
  legacy execution-mode 依赖：已发布 operation 的 E0 可按默认只读策略运行，E1/E2
  由对应 typed authority 准入。`host_loop` 保持 Repo Agent Plane，不能代替 Runtime
  dispatch；它的禁令不是 Runtime Agent 的授权规则。
- archive/ratification 时创建 `CORE-4.0.0`，将 macOS 标为
  `needsReverification`，Windows/Linux 标为 `deferred`；不产生支持或真机通过声明。

Observable behavior:

- Before: current Constitution/Flash contract 要求人类亲手执行真实 destructive Step，
  即使受监督用户已确认 exact campaign、broker 已完成所有 fresh checks，也必须
  `policyBlocked`。
- After: Agent 仅在 exact E2 authority 及全部 admission pins 仍一致时，才可由
  protected-main broker dispatch 已发布的 typed destructive Step；任何 authority 或事实
  缺失/漂移仍为 `policyBlocked`，外部 process/device dispatch 计数为 0。
- After r3: 完成固定 candidate build 与封闭策略输出校验后，campaign 直接进入既有
  fresh-readback/reservation/broker 验证链；不再等待或创建独立 adversarial-review session。

## Out of scope

- 不增加 Operation、Provider、integration/device profile、raw-shell/HDC/RockUSB command
  surface，亦不改变任何 Catalog step、partition、argv、target binding 或 recovery action。
- 不创建、修改、批准或消费 standing authorization/campaign confirmation，不连接真实设备，
  不执行 Flash、erase、format、unlock、update 或其他 device mutation。
- 不把 fake、simulation、plan-only、CI green 或本 PR 的 review 记为 realHardware evidence；
  不提前把任一 Golden Journey 标为 `REAL_DEVICE_PASS`。
- 不允许 agent 伪造用户确认、让 candidate/repairer 接触设备或 authority，或对
  unknown/unsafe partial outcome 自动重放。

## Scope

- Modified policies: `POL-AGENT-002`.
- Modified requirements: `REQ-FLASH-015`, `REQ-WF-004`.
- Modified/added acceptance: `AC-FLASH-015-01`, `AC-FLASH-015-02`,
  `AC-FLASH-015-03`, `AC-WF-004-03`.
- Modified contracts: `provider-contracts.md` and
  `hardware-evidence.schema.json` (3.0.0 -> 4.0.0).
- Core baseline bump: required. `CORE-4.0.0` is the candidate because this
  changes a ratified Safety policy, execution authorization boundary, contract
  enum, and the pass/fail result of a real destructive Agent request.

## Platform impact

| Platform | Disposition after ratification | Reason |
| --- | --- | --- |
| macOS | `needsReverification` | The current Runtime campaign implementation is here; contract/fake tests do not establish hardware support. |
| Windows | `deferred` | Future port must implement the identical E2 gate and cannot claim support first. |
| Linux | `deferred` | Future port must implement the identical E2 gate and cannot claim support first. |

## Safety, privacy, compatibility, and rollback

- **Authority is exact and bounded.** A standing authorization pins target identity/binding,
  firmware, transport, HDC, Provider, plan/step set, recovery path, validity and attempt use.
  A campaign additionally pins the protected-main base, candidate paths/diff budget and
  build target/toolchain. Campaigns are hard-limited to 16 serial attempts, four hours and
  one concurrent attempt.
- **Fail closed.** Prior to every real destructive Step the broker recalculates the typed
  plan and performs fresh target/binding readback. A missing, consumed, expired, mismatched
  or out-of-budget authority; missing or drifted candidate pin; non-terminal predecessor; absent reservation;
  topology drift; unknown outcome; or unsafe partial write stops permanently with zero new
  dispatch.
- **Candidate isolation, not a runtime review session.** A candidate may build and validate its
  closed strategy only in its task-owned isolated workspace, constrained to the confirmed
  allowed paths and diff budget. The repairer receives no workspace source. Neither candidate
  nor repairer has network, USB/HDC/RockUSB, Runtime or authority capability. They can only
  propose a closed strategy; only the merged broker can reserve and dispatch the published typed
  plan. No actor can enlarge argv, operation,
  partition, plan, archive, step set, target or authority.
- **Evidence honesty and privacy.** Evidence records the real executor and authority kind;
  campaign confirmation is never represented as standing authorization. Device identifiers
  remain redacted/digested and raw artifacts stay local/immutable. Evidence records provenance
  only and can never grant E2 authority retrospectively.
- **Compatibility.** Historical one-shot `chatConfirmation` and legacy
  `normal|evolution` bytes remain decoder/export-only. New reserve/admission/dispatch through
  those surfaces fails closed. Human execution remains an allowed path.
- **Rollback.** Reverting the ratified baseline returns new requests to policyBlocked; it
  never replays an existing intent or erases the durable journal/evidence history.

## Approval and implementation sequence

This proposal is a D1 Core/Safety decision. It intentionally remains `proposed` until a human
maintainer explicitly approves the r3 policy scope; earlier r1/r2 review/merge did not authorize
removal of the independent-review admission condition. After approval, the sole task below may
synchronize the current Core files and remove the runtime review invocation while running the
listed host-only checks. A separate human review is required for change verification/archive and
baseline ratification. No merge grants an authority instance; each real attempt still needs its
own valid standing authorization or in-session campaign confirmation.
