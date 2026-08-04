# Workflow, Journal, and Recovery Specification Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment`
> Target: `openspec/specs/workflow-journal-recovery/spec.md`
> Baseline: `CORE-3.0.0`
> Proposed baseline: `CORE-4.0.0`

## MODIFIED Requirements

### Requirement: REQ-WF-004 Trusted Runtime facts and truthful hardware evidence

The Runtime SHALL derive realHardware evidence only from the same Job's durable intent/outcome,
trusted target/binding/tool facts and published Artifact metadata. An Agent E0/readOnly run SHALL
record `defaultReadOnlyPolicy`; E1/deviceMutation SHALL record `runtimeCapability`; E2/destructive
SHALL record either `standingAuthorization` or `evolutionCampaignConfirmation`. Every E2 evidence
reference SHALL exactly match the authority accepted before the first destructive intent, and a
campaign reference SHALL include the durable campaign/attempt and ordinal correlation. Schema
validation, evidence packaging, an imported Manifest, caller assertion or a later chat message
SHALL NOT mint, change, expand or retrospectively supply authority.

Missing, stale, mismatched, unknown or non-durable trusted facts; authority/effect mismatch;
unmatched intent/outcome; missing immutable candidate pin; or unverifiable Artifact hash SHALL
block evidence publication. An independent adversarial review is not an evidence or dispatch
prerequisite. This blocker SHALL NOT change the underlying Job result into success and
SHALL NOT dispatch or replay a device Step. Target identity and raw artifacts retain the privacy
and immutability rules of the current baseline.

#### Scenario: AC-WF-004-01 Agent evidence facts complete

- GIVEN an Agent completes a real E0, E1 or E2 typed run and the same Job contains complete fresh
  target/binding/tool facts, admission decision, durable Step outcomes and immutable Artifact
  metadata
- WHEN Runtime projects hardware evidence
- THEN the record contains the actual executor/effect/Step kinds, the matching
  `defaultReadOnlyPolicy`, `runtimeCapability`, `standingAuthorization` or
  `evolutionCampaignConfirmation` provenance, target confirmation and Artifact hashes
- AND the record passes schema and semantic correlation validation without minting authority

#### Scenario: AC-WF-004-02 Required evidence facts are untrusted or incomplete

- GIVEN an Agent run is missing a required trusted fact, has stale or mismatched target/binding
  facts, uses an authority/effect mismatch, or has an unverifiable Artifact hash
- WHEN Runtime is asked to publish hardware evidence
- THEN Runtime returns `evidenceIncomplete` and schema-valid realHardware publication is 0
- AND caller-supplied fields, historical receipts, human text or a later chat message cannot make
  the run PASS or authorize a device Step

#### Scenario: AC-WF-004-03 Campaign evidence cannot substitute for authority

- GIVEN a destructive Agent Job claims `evolutionCampaignConfirmation`, but its evidence lacks a
  matching durable campaign/attempt reservation, authority pin, fresh target confirmation,
  intent/outcome correlation or actual artifact hash
- WHEN Runtime projects the Job into hardware evidence
- THEN evidence publication is 0 and the Job is reported with a truthful incomplete/policy
  blocker
- AND no new device dispatch, authority minting or replay occurs
