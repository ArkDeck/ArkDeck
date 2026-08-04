# Hardware Evidence Contract Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment`
> Target: `openspec/contracts/hardware-evidence.schema.json`
> Current version: 3.0.0
> Proposed version: 4.0.0

## MODIFIED Contract

The closed `executor.authority.kind` vocabulary adds
`evolutionCampaignConfirmation`. It is valid only when all of the following are present and
correlated with the same durable real-hardware Job:

- `reference` identifies the immutable campaign confirmation record;
- `campaignId`, `attemptId` and positive `attemptOrdinal` identify the one reserved attempt;
- `planDigest`, `targetBindingDigest`, `candidateDigest` and `brokerDigest` are present and
  match the trusted Runtime admission record; the candidate digest is emitted only after the
  fixed isolated build and closed strategy-output validation;
- target confirmation is a fresh same-attempt trusted readback, not caller-provided text;
- every actual destructive Step has a durable intent and outcome linked to that admission record.

`standingAuthorization` keeps its existing exact reference requirements. `defaultReadOnlyPolicy`
and `runtimeCapability` remain the only Agent E0/E1 authority kinds. A human executor does not
claim an Agent authority. Unknown authority kinds, missing/different correlations, raw device
identity, a campaign represented as standing authorization, or authority/effect mismatches SHALL
make the evidence invalid.

Independent adversarial review is not required to emit or validate campaign evidence and cannot
block a candidate from entering runtime verification. Validation records provenance only: no valid
or invalid evidence instance can mint, modify, consume or retroactively authorize an E2 authority.
Historical 3.0.0 evidence remains immutable and decodable; writers use 4.0.0 for a new campaign
record.
