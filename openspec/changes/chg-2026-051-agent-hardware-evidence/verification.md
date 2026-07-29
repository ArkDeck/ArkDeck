# CHG-2026-051 Verification Plan

> Change:CHG-2026-051-agent-hardware-evidence@r3
> Status:planned
> Core baseline:CORE-2.1.0

## Environment

- protected-main checkout, macOS arm64, Swift toolchain；
- JSON Schema draft 2020-12 contract + deterministic local validator/vectors；
- fake/in-memory daemon target/job/provider/artifact facts，零 HDC/device dispatch；
- production Catalog/generated Swift + descriptor-bound fake HDC process fixture，验证 exact
  target-list/model/firmware 三步 preflight 与 `-t` target selection，仍零真实设备；
- Catalog schema/generator/remote-operation registry 正反例，验证
  `runApprovedRemoteRead` actionRef 的 required、exact-kind 与 generated matrix
  digest 同步；
- existing V2 evidence 作为 immutable compatibility fixture，只读不迁移。

## Acceptance matrix

| AC ID | Verification method | Expected result | Minimum evidence |
| --- | --- | --- | --- |
| `AC-WF-004-01` | Agent E0 receipt → V3 projector positive contract + JSON Schema/Swift round-trip | 同一 target/binding 的 executor、default-read-only authority、fresh machine confirmation、model/serial digest/firmware、tool/provider/transport、actual steps 与 Artifact hashes 完整且一致 | contract |
| `AC-WF-004-02` | required-fact provenance/absence/staleness/mismatch/privacy negative matrix | 任一事实不可信或不完整时返回 `evidenceIncomplete`，V3 publication count 为 0；caller 无法补写，raw serial 不可编码 | contract |
| `AC-WF-004-03` | actual effect × authority matrix + dispatch-separation instrumentation | Agent E0/E1/E2 分别只接受 default policy/runtime capability/standing authorization reference；mismatch/unknown 拒绝 evidence，schema validation 永不增加 device dispatch | contract |

## `AC-WF-004-01` positive vector

fixture 必须由 product-owned fake ports 分别产生并关联同一 job/target/binding：

- terminal Agent run：operation/version、job ID、catalog digest、start/finish；
- E0 admission decision：`defaultReadOnlyPolicy` reference；
- same-operation typed E0 preflight readback：model、serial SHA-256、firmware/build、
  binding revision、confirmation timestamp、transport；
- provider/tool receipt：provider identity、HDC version 与 binary SHA-256；
- durable step intents/outcomes：实际执行 step kinds，max effect = E0；
- immutable Artifact metadata/bytes：stable reference 与 SHA-256。

同一正例还必须走 production composition shape：target store 只提供内部
connectKey/identity/binding/tool，Catalog 的三条 required preflight 通过 descriptor-bound
fake process 分别返回 exact target、model 与 firmware；不得由 fake facts port 直接把
最终 observation 整包塞入 job。`debug.hap@1` 的首个 E1 dispatch 计数在三条 preflight
outcome durable 之前恒为 0。

fake executable 必须检查 property argv 精确为
`-t <fixture-connect-key> shell param get const.product.model|const.ohos.fullname`；
缺失/改变 `-t`、未知 property 或 default-target form 均不得产生 verified outcome。

projector 输出必须通过 V3 JSON Schema、Swift decode/encode 与 semantic parity，
且 V3 中所有 duplicated correlation fields（target identity/binding/job）一致。

## `AC-WF-004-02` negative matrix

至少覆盖：

- model、serial digest、firmware、binding revision、confirmation time/method、
  tool/provider/transport、actual step kinds 或 Artifact hash 任一缺失；
- confirmation 晚于 evidence-bearing capture 或任一 E1/E2 step、早于允许的
  freshness window、binding/identity 与 job 不同；
- caller 尝试提交 model/firmware/effect/stepKinds/authority/receipt 或
  `schemaValid=true`；合法 claim metadata 与 trusted facts 必须走不同 typed surface；
- serial 不是 64 位 lowercase SHA-256、包含 raw connectKey/serial；
- artifact missing、bytes/hash 不一致、reference 不在受控 published store；
- stale prior-run receipt、旧 target adoption 或旧 capability 被复用；
- legacy target-store record 缺少新字段时仍可读取，但在 fresh typed preflight 前
  evidence publication 为 0；
- target-list 对 durable connectKey 为 0 match / multiple match、transport/state 列未知，
  或 property lowering 未携带 exact `-t` target 时，后续 capture/E1 dispatch 为 0；
- 任一 Catalog 缺三步 required prefix、顺序漂移、generated Swift/remote action mapping
  漂移，或 generated matrix digest 漂移；
- `runApprovedRemoteRead` 缺 `actionRef`、引用 unknown remote action、引用
  step-kind 不匹配 action，或其他 step kind 非法携带 remote action reference；
- job 为 simulated/planOnly，或 effect/outcome unknown。

全部向量必须在 evidence publication 前失败；不能用空值、`unknown` 字符串、旧事实或
人工补写填充 required fields。

## `AC-WF-004-03` authority matrix

| Executor | Actual effect | Required authority | Result |
| --- | --- | --- | --- |
| agent | E0/readOnly | `defaultReadOnlyPolicy` | schema/projector accept |
| agent | E1/deviceMutation | `runtimeCapability` | 仅 reference 与 admission decision 精确一致时 accept |
| agent | E2/destructive | `standingAuthorization` | 仅记录结构；还必须由适用 approved policy 允许，schema 本身不授权 |
| agent | 任意 | missing/wrong/expired/drifted | `evidenceIncomplete`，publication 0 |
| human | 任意 | 不伪造 Agent authority | schema accept；执行合法性仍由适用 policy 判断 |

测试必须独立计数 evidence publication 与 provider/device dispatch，证明 schema
validation/projector 不能 mint capability 或触发 effect。

## Compatibility, privacy, and recovery

- V2 fixture 保持 byte-for-byte 不变并可由 legacy reader 读取；V3 writer 不自动迁移。
- legacy target-store fixture 保持可读；缺失 facts 标记 evidence-ineligible，不从
  adoption time/target ID/tool version 合成。
- unknown/missing projection 没有 device-side compensation；它只阻断 evidence
  publication，并保留原 runtime terminal state供审计。
- raw serial/connectKey、日志/dump/trace bytes、host secret/path 不进入 repo evidence。
- crash 在 evidence atomic publish 前只留下 incomplete marker；不得留下无 hash 的
  schema-valid V3 record。

## Deviations

不接受以下 deviation：放宽 required facts、允许 caller 补写 trusted facts、把 target ID
当 physical identity、让 schema validation 充当 authority、追认旧 attempt 或把
fake/simulation 计为 realHardware。

## Result gate

- [ ] `AC-WF-004-01/02/03` 全部 contract PASS
- [ ] V3 JSON Schema / Swift / semantic validator parity PASS
- [ ] production Catalog preflight / exact target / generated drift contracts PASS
- [ ] evidence publication 与 effect dispatch separation PASS
- [ ] V2 compatibility、privacy/secret scan PASS
- [ ] `scripts/check-sdd.sh` 与完整 Swift suite PASS
- [ ] implementation run evidence 可复查
- [ ] 未执行真实设备，未追认 `DHA-HW-001` attempt#2
- [ ] archive 时 traceability 与 next MAJOR baseline 精确更新
