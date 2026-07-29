# Spec Delta

> Change:CHG-2026-051-agent-hardware-evidence
> Target capability:`openspec/specs/workflow-journal-recovery/spec.md`

## ADDED Requirements

### Requirement: REQ-WF-004 Agent real-hardware evidence uses trusted Runtime facts

当 Agent 执行的真实设备 run 被声明为 realHardware evidence 时，Runtime SHALL
从 product-owned durable target/job/step records、fresh descriptor-bound device/tool
observations、admission authority decision 与 immutable Artifact metadata 投影
hardware-evidence record。record SHALL 如实包含 executor、operation/job/catalog、
actual effect 与 step kinds、authority reference、target identity digest/binding、
model/firmware、transport/provider/toolchain、同 operation 的 typed E0 preflight
readback 所记录的 target confirmation method/time、执行时间与 Artifact
reference/hash。该 preflight MAY 是首个 device step，但 SHALL 在后续
evidence-bearing capture 与任何 E1/E2 effect 前完成。Runtime/evidence caller SHALL
NOT 提交或覆盖这些 trusted facts；
post-run evidence packaging MAY 仅补充 `evidenceId`、`acceptanceIds`、`validUntil`
与 `notes` 等不授予 execution authority 的 claim metadata，其验收归属仍 SHALL 由
approved verification plan 与维护者 review 判定。

Agent E0/readOnly、E1/deviceMutation 与 E2/destructive evidence 的 authority kind
SHALL 分别为 `defaultReadOnlyPolicy`、`runtimeCapability` 与
`standingAuthorization`，并与该 run 的 admission decision 精确关联。该映射只记录
execution authority provenance；hardware-evidence schema validation SHALL NOT mint
capability、批准 plan 或触发 device dispatch，E2 是否允许仍由当时适用的 approved
Safety policy 决定。

任一 required fact 缺失、unknown、stale、binding/identity 不一致、
authority/effect 不匹配或 Artifact bytes/hash 不可验证时，Runtime SHALL 返回结构化
`evidenceIncomplete`，SHALL NOT 发布 schema-valid realHardware record，且 SHALL NOT
使 Acceptance Scenario 进入 PASS。V2 历史 evidence SHALL 保持不可变；V3 writer
SHALL NOT 通过有损或人工补写自动迁移旧记录。

#### Scenario: AC-WF-004-01 Agent E0 evidence facts complete

- GIVEN Agent 经 published typed operation 在真实设备执行 E0/readOnly run
- AND同一 target/binding 的 fresh machine readback、admission decision、durable
  step outcomes 与 immutable Artifact metadata 完整
- WHEN Runtime 投影 hardware-evidence V3
- THEN record 包含 `executor.kind=agent` 与 `defaultReadOnlyPolicy` authority
- AND包含 model、serial digest、firmware、binding、target confirmation time、
  tool/provider/transport、actual step kinds 与 Artifact hashes
- AND该 record 通过 schema 与 semantic correlation validation

#### Scenario: AC-WF-004-02 Required evidence fact is untrusted or incomplete

- GIVEN Agent run 缺少任一 required fact，或事实 stale、binding/identity 不一致、
  Artifact hash 不可验证
- WHEN caller 请求 hardware-evidence output
- THEN Runtime 返回 `evidenceIncomplete`
- AND schema-valid realHardware publication 数为 0
- AND caller 自报字段、旧 receipt 或人工补写不能使该 run PASS

#### Scenario: AC-WF-004-03 Actual effect and authority do not match

- GIVEN Agent run 的 actual maximum effect 与 admission authority kind/reference
  不匹配、缺失、过期或 unknown
- WHEN hardware-evidence projector 校验 provenance
- THEN schema-valid realHardware publication 数为 0
- AND provider/device dispatch 数不因 schema validation 增加
- AND事后 evidence 不能补发 execution authority

## MODIFIED Requirements

None.

## REMOVED Requirements

None.

## RENAMED Requirements

None.
