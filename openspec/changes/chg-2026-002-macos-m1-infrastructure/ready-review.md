# M1 Ready Gate

> Status：blocked  
> Reason：Core baseline/trust policy are not ratified and the guard is not yet enforced by protected Git/CI with external approval and claim-service verifiers. TASK-M1 packets additionally depend on the M0A distribution decision record.

- [ ] Change/Task approval subject IDs and exact hash targets are prepared; actual approvals are derived post-lock gates
- [ ] Every packet validates against `task-packet.schema.json`
- [ ] Core, platform, integration and conformance hashes are exact and current
- [ ] Base revision is immutable and dependencies (including CHG-2026-001 M0A outcomes) are satisfied
- [ ] Every Requirement/AC mapping, path scope, resource, method and expected evidence is complete
- [ ] No packet requires real hardware; every packet stays `standardAgent` with minimal runtime capabilities
- [ ] No packet contains mutable owner/claim/attempt/run fields
- [ ] Governance bootstrap and baseline ratification are complete

No Task in this change may become ready while this gate is blocked.
