# Workflow, Journal, and Recovery Specification Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment@r5`
> Target: `openspec/specs/workflow-journal-recovery/spec.md`
> Baseline: `CORE-3.0.0`
> Proposed baseline: `CORE-4.0.0`

## MODIFIED Requirements

### Requirement: REQ-WF-004 Trusted Runtime facts and truthful hardware evidence

Runtime SHALL 仅从同一 Job 的 durable admission/intent/outcome、trusted target/binding/tool
facts 和已发布 Artifact metadata 推导 realHardware evidence。Agent `hostOnly`/`readOnly`
run SHALL 记录 `defaultReadOnlyPolicy`；`deviceMutation`/`destructive` SHALL 记录
`runtimeCapability`。destructive evidence reference SHALL 精确匹配首个 external intent 前由
protected-main Runtime 生成并 durable reserve 的 capability use，并关联 operation/version、
plan、target/binding、typed inputs、Artifact hashes、reservation/use ordinal 与 terminal
disposition。

Schema validation、evidence packaging、imported Manifest、caller assertion、UI confirmation、
connected USB、历史 authority 或聊天消息 SHALL NOT mint、变更、扩大或追溯提供
RuntimeCapability。新 writer SHALL NOT 写入 `standingAuthorization` 或
`evolutionCampaignConfirmation`；历史 V1-V4 evidence 保持不可变、可 decode/export，但其
authority reference SHALL NOT admit/reserve/dispatch 新 Step 或迁移成 capability。

缺失、stale、mismatched、unknown、caller-supplied 或非 durable trusted facts；effect/
capability mismatch；未匹配 intent/outcome；non-terminal/unsafe predecessor；或不可验证
Artifact hash SHALL 阻止 evidence publication。该 blocker SHALL NOT 把 Job 变为 success，
也 SHALL NOT dispatch、retry、replay 或 recover device Step。Target identity 与 raw artifacts
继续适用隐私和不可变规则。

#### Scenario: AC-WF-004-01 Agent evidence facts complete

- GIVEN Agent 完成真实 read-only、deviceMutation 或 destructive typed run，且同一 Job 有
  完整 trusted admission、fresh target/binding/tool facts、durable Step outcomes、reservation
  lineage 和 immutable Artifact metadata
- WHEN Runtime projects hardware evidence
- THEN record 包含实际 executor/effect/Step kinds、匹配的 `defaultReadOnlyPolicy` 或
  `runtimeCapability` provenance、target confirmation、plan/use correlation 和 Artifact hashes
- AND record 通过 schema 与 semantic validation，且不 mint capability

#### Scenario: AC-WF-004-02 Required evidence facts are untrusted or incomplete

- GIVEN Agent run 缺少 required trusted fact、target/binding stale 或 mismatch、capability/effect
  mismatch、intent/outcome/lineage 不完整，或 Artifact hash 不可验证
- WHEN Runtime 被请求发布 hardware evidence
- THEN Runtime 返回 `evidenceIncomplete`，schema-valid realHardware publication 为 0
- AND caller fields、historical receipt、UI/human text 或 legacy authority 不能使 run PASS 或
  authorize/replay device Step

#### Scenario: AC-WF-004-03 Legacy E2 evidence cannot substitute for Runtime admission

- GIVEN 新 destructive Agent Job 或 V5 evidence 声称 `standingAuthorization` 或
  `evolutionCampaignConfirmation`，或尝试从历史 authority/evidence 迁移 RuntimeCapability
- WHEN Runtime validates admission or projects the Job
- THEN 新 dispatch 与 V5 evidence publication 均为 0，并如实报告 legacy-authority blocker
- AND 历史 bytes 仅可 decode/export，不发生 capability minting、reservation、migration 或 replay
