---
id: CHG-2026-056-e2-policy-baseline-alignment
revision: 1
status: proposed
class: core
core_change_level: major
owner: lvye
core_baseline: CORE-3.0.0
platforms: [macos, windows, linux]
---

# 将有界 E2 campaign 提升为 Core 正本

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
- current workflow、provider 和 hardware-evidence contract 能表达
  `evolutionCampaignConfirmation`，并要求 evidence 如实记录 authority kind/reference、
  fresh target confirmation、attempt ordinal 和 terminal disposition。Schema validity 仍不
  mint authority，事后 evidence 仍不得追认 dispatch。
- enforcement 与 verification policy 统一到同一 E0/E1/E2 词汇和 campaign 限制。
- archive/ratification 时创建 `CORE-4.0.0`，将 macOS 标为
  `needsReverification`，Windows/Linux 标为 `deferred`；不产生支持或真机通过声明。

Observable behavior:

- Before: current Constitution/Flash contract 要求人类亲手执行真实 destructive Step，
  即使受监督用户已确认 exact campaign、broker 已完成所有 fresh checks，也必须
  `policyBlocked`。
- After: Agent 仅在 exact E2 authority 及全部 admission pins 仍一致时，才可由
  protected-main broker dispatch 已发布的 typed destructive Step；任何 authority 或事实
  缺失/漂移仍为 `policyBlocked`，外部 process/device dispatch 计数为 0。

## Out of scope

- 不增加 Operation、Provider、integration/device profile、raw-shell/HDC/RockUSB command
  surface，亦不改变任何 Catalog step、partition、argv、target binding 或 recovery action。
- 不创建、修改、批准或消费 standing authorization/campaign confirmation，不连接真实设备，
  不执行 Flash、erase、format、unlock、update 或其他 device mutation。
- 不把 fake、simulation、plan-only、CI green 或本 PR 的 review 记为 realHardware evidence；
  不提前把任一 Golden Journey 标为 `REAL_DEVICE_PASS`。
- 不允许 agent 伪造用户确认、让 candidate/repairer/reviewer 接触设备或 authority，或对
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
  or out-of-budget authority; non-terminal predecessor; absent reservation; non-PASS review;
  topology drift; unknown outcome; or unsafe partial write stops permanently with zero new
  dispatch.
- **Separation of duties.** A candidate may build and test only in its task-owned isolated
  workspace, constrained to the confirmed allowed paths and diff budget. The repairer receives
  no workspace source; the reviewer receives only immutable candidate/diff/build/test artifacts.
  None of candidate, repairer or reviewer has network, USB/HDC/RockUSB, Runtime or authority
  capability. They can only propose or assess a closed strategy; only the merged broker can
  reserve and dispatch the published typed plan. No actor can enlarge argv, operation,
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
maintainer reviews and merges it. After approval, the sole task below may synchronize the
current Core files and run the listed host-only checks. A separate human review is required for
change verification/archive and baseline ratification. No merge grants an authority instance;
each real attempt still needs its own valid standing authorization or in-session campaign
confirmation.
