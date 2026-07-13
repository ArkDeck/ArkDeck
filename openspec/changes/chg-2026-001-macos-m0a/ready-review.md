# M0A Ready Gate

> Status：passed  
> Reviewed：2026-07-13 by @lvye（CODEOWNER）。Core baseline CORE-1.0.0 已 ratified，trust policy accepted，外部 trust root 与 verifier 已配置，guard 由受保护 CI 强制。

- [x] Change/Task approval subject IDs and exact hash targets are prepared; approvals are externally verified detached signatures
- [x] Every packet validates against `task-packet.schema.json`
- [x] Core, platform, integration and conformance hashes are exact and current
- [x] Base revision is immutable and dependencies are satisfied
- [x] Every Requirement/AC mapping, path scope, resource, method and expected evidence is complete
- [x] parserGolden AC fixture policy applies at claim time; no fixture-bearing AC is claimed before its fixtures are pinned
- [x] No packet contains mutable owner/claim/attempt/run fields
- [x] Every packet has minimal runtime capabilities; real-hardware verification is isolated in the controlled-lab Task (TASK-M0A-007) with claim-owner and exact plan/target authorization contracts
- [x] Governance bootstrap and baseline ratification are complete

Canonical exclusive-resource URNs use the inputs recorded in `scripts/ratify.py` (CANONICAL_RESOURCES); the claim service must reuse them verbatim.
