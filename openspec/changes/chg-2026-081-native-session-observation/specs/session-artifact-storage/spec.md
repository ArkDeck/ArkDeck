## MODIFIED Requirements

### Requirement: REQ-ART-004 Manifest preserves execution semantics

Manifest SHALL 至少保存 schema/app version、Job/Session ID、terminal status、executionMode、outcomeCertainty、sessionDisposition/archivedAt、original target、binding history、toolchain、Provider/fixture identity、step execution disposition、parameter state、Artifact metadata、warning/failure、recovery/abandon audit 和关联 Recovery Session。

Native deployment SHALL obtain its own verified target, model, firmware,
transport and tool observation through required read-only typed preflight
steps before its first device mutation. Those steps SHALL belong to the
complete materialized native plan. Publication SHALL retain the original
Job's binding, authority, intent/outcome and terminal semantics; a later
observation SHALL NOT be substituted for missing historical facts.

A confirmed failed final native cleanup SHALL remain an executed failed Step
and a known failed terminal Job with exact durable cleanup debt. Publication
SHALL preserve the already verified replacement and deployment products;
final housekeeping failure SHALL NOT trigger another rollback or dispatch.
The deployment/loader-verification failure rollback rule remains unchanged.
Unconfirmed Native cleanup-debt persistence SHALL block finalized publication
and any replay, retaining the original failed outcome and recovery state.

#### Scenario: Native deployment has complete original observation

- GIVEN a native Job completes its required bound preflight and known deployment
- WHEN its diagnostic Session is composed
- THEN its own observation and original authority/outcomes are verified
- AND exactly one finalized event follows the complete manifest proposal
- AND an unrelated Import owner inspection can complete its full Job census

#### Scenario: Native preflight observation is incomplete

- GIVEN model/firmware or exact target/tool/binding facts are missing or mismatched
- WHEN native deployment reaches its first device mutation
- THEN native mutation dispatch and capability consumption are zero
- AND no later Job or present observation makes the failed original Job publishable

#### Scenario: Verified native replacement has a failed final cleanup

- GIVEN native publish and loader verification succeeded under the original authority
- WHEN the final cleanup has a confirmed failed outcome
- THEN the Job closes known failed and retains that executed failed Step and exact debt
- AND the verified replacement stays in place with zero additional rollback dispatch
- AND its valid diagnostic Session is published and finalized once
- AND this housekeeping failure is not formal forward acceptance PASS

#### Scenario: Native cleanup debt cannot be made durable

- GIVEN a final or compensation cleanup has an original failed outcome
- WHEN its exact debt, residue count or Job persistence cannot be verified
- THEN the Job waits for recovery without publishing or finalizing a Session
- AND the original failed outcome remains and no cleanup/deployment intent is replayed
