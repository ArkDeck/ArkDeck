# M0A Ready Gate

> Status：blocked  
> Reason：Core baseline/trust policy are not ratified and the guard is not yet enforced by protected Git/CI with external approval and claim-service verifiers.

- [ ] Change/Task approval subject IDs and exact hash targets are prepared; actual approvals are derived post-lock gates
- [ ] Every packet validates against `task-packet.schema.json`
- [ ] Core, platform, integration and conformance hashes are exact and current
- [ ] Base revision is immutable and dependencies are satisfied
- [ ] Every Requirement/AC mapping, path scope, resource, method and expected evidence is complete
- [ ] Every parserGolden AC has non-empty fixture refs pinned by the accepted Integration lock and Conformance suite
- [ ] No packet contains mutable owner/claim/attempt/run fields
- [ ] Every packet has minimal runtime capabilities; real-hardware verification is isolated in a controlled lab Task with claim-owner and exact plan/target authorization contracts
- [ ] Governance bootstrap and baseline ratification are complete

No Task in this change may become ready while this gate is blocked.
