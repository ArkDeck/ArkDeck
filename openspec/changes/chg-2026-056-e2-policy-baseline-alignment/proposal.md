---
id: CHG-2026-056-e2-policy-baseline-alignment
revision: 9
status: proposed
class: core
core_change_level: major
owner: lvye
core_baseline: CORE-3.0.0
platforms: [macos, windows, linux]
---

# 让 destructive Runtime 在可证明条件下自主完成 Flash 恢复

> r5 经维护者裁决移除了独立 E2/standing/campaign 人工授权层；r6 补齐实现路径，随后
> #1183 已把 Runtime-owned destructive admission 合入 protected `main`。这些批准不授权
> r7/r8/r9。
>
> r8（2026-08-08）同时收敛 GJ-4 迭代中暴露的 DAYU200 profile 身份分叉。按
> `REQ-FLASH-016`，profile 表达的是 board-scoped 约束，build/archive 是由 Artifact 派生的
> facts；因此 `dayu200@1` 与 `dayu200@2` 不应作为两个可选设备 profile 长期共存。r8 删除
> 两个 versioned profile，发布唯一无版本引用 `dayu200`，保留当前九分区约束与 seed
> archive facts，并保留该 board 已发布的 observe/debug/deploy/flash 能力合集。
>
> r9 把 singleton typed operation 从 `flash.dayu200@1` 收敛为裸引用 `flash.dayu200`，删除
> Catalog `version` 字段和 UI/CLI/Agent/Provider 中的 DAYU200 版本展示；effect、Steps、argv、
> Provider 与 RuntimeCapability 精确绑定不变。新请求中的 `dayu200@1`/`dayu200@2` profile 及
> `flash.dayu200@1` operation 均 fail closed，不提供 alias；
> 历史 evidence/journal 字节不重写，仍持有旧 profile identity 且无法精确证明兼容的未完成
> recovery 保持 blocked。Catalog generator 允许其它 profile 继续显式 version，但禁止同一 ID
> 的裸 profile 与 versioned variants 共存。
>
> r9 的 singleton source naming 同样把 operation 文件从 `flash.dayu200.v1.json` 改为
> `flash.dayu200.json`。新 Runtime operation/capability/journal writer 对该 operation 省略 version；
> 旧 versioned bytes 只可 decode/export，不能匹配新 Catalog、mint capability、reserve、恢复
> 或 dispatch。
>
> r7（2026-08-08）处理真实 GJ-4 暴露的下一层阻塞：旧或当前 Flash 只要留下一个
> `outcomeUnknown` write intent，目标 lane 就永久停止，即使后续完整 Flash 已经把同一物理
> 目标的全部相关分区写入并通过 postflight。当前语义把“禁止盲重放”扩大成“任何恢复都要
> 永久中断”，重新引入反复询问人工的自动化断点。
>
> r7/r8/r9 是新的 MAJOR Safety 与已发布 profile/operation-contract 裁决。维护者 review/merge
> 到 protected `main` 前，不迁移历史 Job、不签发 capability、不执行
> HDC/RockUSB/Flash/erase，也不以本提案绕过当前 blocker。r9 的实现可在同一产品变更中用纯
> host gate 验证，但不得据此自称已批准或产生 `REAL_DEVICE_PASS`。

## Why

r5 正确取消了逐 plan 的人类 intent 证明，但仍规定 unknown/unresolved/partial predecessor
永久阻断任何下一次 destructive dispatch。真实 UI 验证中，两个同 target 的历史
`flash-partitions` intent 保持 `outcomeUnknown`；专用 readback 无法证明原始写入结果，安全门
因此拒绝新的 UI Flash。继续让用户输入“确认”既不能证明设备字节，也不能合法越过该门。

问题的本质不是缺少授权，而是当前模型只有两个选项：证明旧 Step outcome，或者永久停止。
对于完整设备镜像 Flash，还存在第三种可机械证明的路径：不猜旧 Step 是否执行，不重发旧
Step，而是运行一个独立的 complete-overwrite recovery，覆盖旧 intent 可能影响的全部状态，
逐项确认新写入，再通过 reboot/rebind/postflight 建立一个更晚且已知的 target-state epoch。

r7 请求维护者裁决这一风险变化：unknown 后允许 Runtime 再发起新的 destructive 完整覆盖，
前提是相同物理目标、可能 effect 的封闭集合、完整覆盖、immutable bytes、每项 outcome 与
最终设备状态均由 protected-main Runtime 从 trusted facts 证明。这样 AI 在所有机械可判定
路径上不再询问或中断；真正无法界定目标或覆盖的情况仍 fail closed，而且报告的是不可由
聊天确认 override 的 blocker。

## Requested decision

维护者被请求批准以下不可拆分语义：

1. 保留 r5 的 no-E2/no-standing/no-campaign/no-chat admission，以及 `destructive` effect、
   typed-only、identity、Artifact、reservation、journal、privacy 和 candidate isolation。
2. 原始 `outcomeUnknown` intent 永不 replay、永不猜测 outcome、永不因后续恢复而改写为
   succeeded/failed。
3. protected-main Runtime SHALL 从所有同 target outstanding destructive intents 的 durable
   operation/profile/plan facts 保守计算完整 `uncertainEffectSet`；无法界定即零派发。
4. exact published operation/profile 的 Provider MAY 声明 reviewed
   `completeOverwriteSupersessionSafe` contract，定义 effect universe、coverage plan、fresh
   prerequisites、逐项 verification、postflight 与不可覆盖 stop conditions。
5. 仅当 same stable physical identity/binding/topology、immutable archive/Artifact、完整 union
   coverage 与 budget 全部成立时，Runtime MAY durable 分类
   `safeToSupersedeByCompleteOverwrite`，无需 UI/chat/human decision 自动启动独立 recovery。
6. recovery 使用新的 RuntimeCapability、reservation、intent/outcomes，不复用旧 capability 或
   intent。只有全部写入及 reboot/rebind/runtime-build postflight confirmed 后才写 durable
   `SupersedingRecoveryEpoch` 并释放 target lane；旧 outcome 保持 unknown。
7. recovery 自身 unknown 时，其 possible effects 加入 union。普通 attempt 与 recovery epoch
   共用最多十六次串行、四小时、并发一的硬预算；每轮均重新读取 fresh facts 和证明 coverage。
8. 已有 immutable 后续 real Flash history 只有在 identity、严格后序、完整 coverage、逐项
   outcomes 与 postflight 全部可验证时 MAY 零 dispatch 补记 supersession relation；单纯
   `succeeded`、exit 0 或人工声称不足。
9. proof 缺失、wrong/unknown target、unbounded/incomplete effect coverage、Provider 未声明、
   drift、取消、过期或预算耗尽仍零派发。产品不得询问用户“是否强行继续”，因为确认不能
   补足 device-state proof；只报告精确、不可 override 的安全 blocker。

若维护者拒绝，r5/r6 当前语义完整保留：任何 unresolved destructive outcome 继续永久阻断
target lane，本提案不得作为自动 Flash 或历史 lane 释放的依据。

## What changes

In scope:

- 修改 `POL-RECOVERY-001` 与 `POL-AGENT-002`，把“unknown 不盲重放”与“允许独立完整覆盖
  recovery”明确拆开。
- 修改 `REQ-FLASH-013`、`REQ-FLASH-015`、`REQ-WF-004`、`REQ-JOB-001`、`REQ-JOB-006`
  及 Provider contract，增加 conservative effect union、complete-overwrite proof、distinct
  recovery epoch 与 truthful supersession evidence。
- 修改 `PRODUCT-LOOP.md` §15：`STILL_UNKNOWN`/`PARTIALLY_COMPLETED` 先自动评估 reviewed
  recovery proof；可恢复时不再请求人工决策，不可恢复时也不提供 confirmation override。
- exact DAYU200 Flash Provider/profile 增加完整覆盖 contract；不新增 operation、Provider，
  并把两个 versioned DAYU200 profiles 收敛为唯一 `dayu200`。保留当前 partition mapping、
  write-forbidden 集合、argv、工具与刷写字节。
- Job/journal/RuntimeCapability/target-lane/evidence schema 增加 recovery lineage、effect-set/
  coverage digests、`SupersedingRecoveryEpoch` 和与 ordinary success 分离的 recovery terminal。
- UI/Agent-facing `outcomeUnknownDecision` 在可机械恢复时消失；不可恢复时成为只读 blocker，
  不再呈现为用户批准问题。交互 UI 的初始 userdata acknowledgement 仍是 UX boundary。
- 对历史 durable Job 做 read-only semantic scan；只有完整 proof 可 append 新 supersession
  relation，不改写原 journal/event/evidence bytes。
- 实现与真实 DAYU200 GJ-4 UI Flash 同车；独立 UI driver 继续不进入默认 UI tests/CI。

Observable behavior:

- Before: target lane 中任一 destructive `outcomeUnknown` 永久阻断新 Flash，并进入人工决策。
- After: 原 unknown intent 仍不重放；如果 Runtime 证明完整覆盖，则自动执行或识别一个更晚的
  recovery epoch，目标 lane 恢复为 known，AI 无需询问即可继续 GJ-4。
- Profile identity: Before 同一 board 同时暴露 `dayu200@1`/`dayu200@2`；After 新请求只接受
  `dayu200`，旧 versioned profile reference 无 alias 且零 dispatch。
- Unchanged: identity 或 effect domain 不可证明、覆盖不完整、Artifact/tool/plan 漂移、取消或
  预算耗尽时 dispatch 为 0；人类确认、UI 点击、evidence 文本不能放宽该结果。

## Out of scope

- 不允许盲 retry/replay 原始 unknown Step，不把未知 outcome 改写成 succeeded/failed。
- 不删除或降低 `destructive` effect，不新增 generic shell/HDC/RockUSB Step，不改变所保留
  的当前 DAYU200 partition mapping、write-forbidden 分区、刷写顺序或工具参数。
- 不让 caller/Agent/candidate/repairer 提供 target facts、effect set、coverage proof、
  capability、outcome 或 supersession relation。
- 不把“设备能启动”“某个后续 Job succeeded”“用户确认”或 simulation/fake/plan-only 当成
  complete-overwrite evidence。
- 不承诺 unknown physical identity、不可界定 effect 或不可覆盖硬件一定能自动恢复。
- proposal PR 不接触 Runtime stores、历史 Job、设备或用户数据，不产生 `REAL_DEVICE_PASS`。

## Scope

- Modified policies: `POL-RECOVERY-001`, `POL-AGENT-002`.
- Modified requirements: `REQ-FLASH-007`, `REQ-FLASH-013`, `REQ-FLASH-015`, `REQ-WF-004`,
  `REQ-JOB-001`, `REQ-JOB-006`.
- Modified acceptance: `AC-FLASH-007-01`, `AC-FLASH-013-01`, `AC-FLASH-015-01`,
  `AC-FLASH-015-02`, `AC-FLASH-015-03`, `AC-WF-004-01`, `AC-WF-004-02`,
  `AC-WF-004-03`, `AC-JOB-001-03`, `AC-JOB-001-05`, `AC-JOB-006-01`.
- Change-local acceptance: existing `E2R-*` plus `E2R-RECOVERY-001`,
  `E2R-RECOVERY-NEGATIVE-001`, `E2R-HISTORY-001`, `E2R-NOQUESTION-001`.
- Modified published operation/profile: `flash.dayu200@1` 收敛为无版本 `flash.dayu200`，其
  `deviceProfile` enum 与 recovery coverage 从 DAYU200 v1/v2 收敛为唯一 `dayu200`；typed
  Steps、effect、Provider 不变，partition facts 保留当前九分区集合；DAYU200 trace family
  也去除仅用于历史分代的 `-v1` 展示后缀，golden bytes 与 authority boundary 不变；旧
  rev2/chat-attestation binding 取消就地升级路径，只能作为不具备准入权的历史记录读取。
- Modified contracts: Provider contract `2.0.0 -> 3.0.0`; hardware evidence `5.0.0 -> 6.0.0`;
  versioned journal/Runtime capability and target-lane recovery records with legacy read support.
- Core baseline: `CORE-4.0.0` remains the unratified candidate over current `CORE-3.0.0`; r9 revises
  the same pending Safety candidate rather than opening a duplicate baseline/change.

## Platform impact

| Platform | Disposition after implementation | Reason |
| --- | --- | --- |
| macOS | `needsReverification` until autonomous real-device recovery + GJ-4 pass | Production Runtime and DAYU200 Provider exist here; host fixtures cannot accept the new post-unknown destructive dispatch. |
| Windows | `deferred` | Future port must preserve identical effect-set, coverage, lineage and no-question semantics. |
| Linux | `deferred` | Future port must preserve identical effect-set, coverage, lineage and no-question semantics. |

## Safety, privacy, compatibility, and rollback

- **Newly accepted risk:** after an unknown destructive outcome, Runtime may intentionally issue a
  distinct full-overwrite Flash without human approval. Safety rests on full effect coverage and
  final-state proof rather than a blanket no-new-dispatch rule.
- **Retained unknown honesty:** old intent/outcome bytes are immutable; supersession proves current
  target state only and is not evidence that the old Step did or did not execute.
- **Retained target/byte boundary:** stable physical identity, binding, topology, exact plan,
  immutable Artifact, Provider/tool and coverage come from trusted Runtime sources and fresh reads.
- **Bounded liveness:** ordinary and recovery epochs share sixteen serial uses/four hours/concurrency
  one. Explicit cancellation and unprovable states remain hard stops.
- **No social override:** UI/chat/human text neither authorizes recovery nor resolves missing proof.
  The Agent is not repeatedly asked for a confirmation that Runtime cannot use.
- **Compatibility:** prior journal/evidence/authority bytes remain immutable and decode/exportable.
  New writers append versioned recovery relation records; no in-place migration changes old facts.
- **Profile compatibility:** new admission accepts exactly `dayu200`; `dayu200@1`/`dayu200@2` are not
  aliases. A pending legacy Job whose exact profile cannot be reconciled remains fail-closed rather
  than being silently widened to the retained board contract.
- **Operation compatibility:** new admission accepts exactly `flash.dayu200`. Historical
  `flash.dayu200@1` request/capability/journal values remain decodable/exportable but cannot match,
  reserve, recover or dispatch the new singleton operation.
- **Privacy:** target IDs remain digested; raw archive/device artifacts remain local and immutable.
- **Rollback:** old Runtime ignores/rejects new recovery records and reverts to blocking unresolved
  target lanes. It SHALL NOT replay any old or recovery intent during downgrade.

## Approval and implementation sequence

1. #1178/#1181/#1183 remain the trust root for r5/r6 no-E2 Runtime admission and implementation.
2. r9 is a fresh policy/profile/operation revision. CI green does not approve it; human maintainer review/merge to
   protected `main` does. `status: proposed` is intentionally not self-changed by the Agent.
3. Before that merge: zero device/recovery/history mutation. Host-only implementation and contract
   tests do not constitute approval or hardware evidence.
4. After merge: publish the reviewed deltas from an `agent/**` product branch; pass all host gates
   before any real device window.
5. Real validation must first prove the existing target-lane facts, then execute the standalone UI
   Flash without chat/campaign/unknown-decision prompts, and record truthful realHardware evidence.

## r7 implementation path addendum

r7 extends `TASK-E2B-001` only for the production surfaces needed by the approved recovery branch:

- `PRODUCT-LOOP.md` for the canonical §15 recovery flow;
- `ArkDeckCore/JobStateMachine.swift` for distinct recovery/terminal semantics;
- `ArkDeckRuntime/HumanActionRequired.swift` to remove the false approval question from
  mechanically decidable recovery;
- `ArkDeckStorage/RecoveryCoordination.swift` and `RuntimeJobRepository.swift` for durable
  recovery/supersession lineage;
- `ArkDeckWorkflows/RuntimeRecoveryService.swift` for launch-time autonomous classification.

This addendum does not authorize a new operation/provider/profile, raw command, partition-map
change, caller-controlled proof or broader device access. Any such need requires another reviewed
revision before implementation.

## r9 DAYU200 singleton consolidation addendum

- Delete `dayu200.v1.json` and `dayu200.v2.json`; publish one `dayu200.json` without a profile
  `version` field.
- Retain the current seed archive/build facts, nine-partition recovery universe and write-forbidden
  facts. Preserve generic board operations that were already published across the two old entries.
- Require operation inputs, runtime defaults, Provider lookup, recovery matching, CLI/App/Harness
  composition and generated Swift Catalog to use exactly `dayu200`.
- Reject both historical versioned profile strings for all new admission paths. Do not introduce a
  compatibility alias or rewrite durable history; an incompatible pending recovery remains blocked.
- Publish the typed operation only as `flash.dayu200`, remove its Catalog `version` field, and make
  new Runtime operation/capability writers omit the optional version.
- Rename the singleton Catalog source to `flash.dayu200.json`; remove DAYU200-specific `.v1`
  Provider action labels and every UI-facing `@1` suffix.
- Keep historical versioned request/capability/journal decoding read-only. Never alias or migrate
  `flash.dayu200@1` into the new operation; it must fail closed for admission and recovery.
