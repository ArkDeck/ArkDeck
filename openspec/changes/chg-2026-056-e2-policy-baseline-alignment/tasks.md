# Tasks

## TASK-E2B-001 — Promote bounded E2 policy into the Core baseline

- Status:blocked (awaiting human approval of this D1 Core/Safety proposal; no implementation,
  authority instance, hardware connection or dispatch is authorized by this task state)
- Golden Journey: GJ-4 (a correct E2 admission boundary is required before the real-device
  closed-loop Flash/verify journey can be claimed)
- Platform: macos, windows, linux
- Requirements: `POL-AGENT-002`, `REQ-FLASH-015`, `REQ-WF-004`
- Acceptance: `AC-FLASH-015-01`, `AC-FLASH-015-02`, `AC-FLASH-015-03`, `AC-WF-004-03`
- Depends on: maintainer review/merge approving `CHG-2026-056`; existing
  `CHG-2026-025@r15` remains the implementation provenance until archive/ratification
- Allowed paths:
  - `openspec/constitution.md`
  - `openspec/specs/flashing/spec.md`
  - `openspec/specs/workflow-journal-recovery/spec.md`
  - `openspec/contracts/provider-contracts.md`
  - `openspec/contracts/hardware-evidence.schema.json`
  - `openspec/governance/enforcement.md`
  - `openspec/verification/policy.md`
  - `openspec/verification/acceptance-index.txt`
  - `openspec/verification/acceptance-cases.yaml`
  - `openspec/verification/core-conformance.yaml`
  - `openspec/verification/traceability.md`
  - `openspec/config.yaml`
  - `openspec/baselines/CORE-4.0.0.yaml`
  - `openspec/platforms/PLATFORM-PROFILES.lock.yaml`
  - `openspec/changes/chg-2026-056-e2-policy-baseline-alignment/**`
- Forbidden paths:
  - `Catalog/**`, `Packages/**`, `scripts/**`, and all integration/device profiles
  - standing authorization or campaign confirmation instances
  - real device/HDC/RockUSB tooling, raw shell command surfaces, or hardware evidence claiming a
    dispatch
- Risk: destructive (the policy changes when an Agent may dispatch; the implementation work here
  is documentation/contract synchronization only and must perform zero external effect)
- Hardware required: no
- Decision-Grade: D1

### Deliverables

- Apply the approved deltas to current Core files without weakening the exact E2 envelope.
- Add `AC-FLASH-015-03` to the canonical acceptance index/cases and update the `REQ-WF-004`
  evidence authority vocabulary.
- Create `CORE-4.0.0` only in the human-reviewed archive/ratification PR; set macOS to
  `needsReverification` and Windows/Linux to `deferred`.
- Preserve all historical evidence/bytes and state explicitly that no real device run was made.

### Verification

- Source review proves every current policy/contract representation has the same two authority
  kinds, the same exact-pins/fresh-readback gate, and the same fail-closed terminal set.
- Negative contract tests cover missing, expired, consumed, drifted, non-PASS, unknown and unsafe
  campaign states with destructive dispatch count 0; the positive test uses only fake/provider
  fixtures and verifies truthful authority correlation.
- Run `sh scripts/check-sdd.sh`, catalog generator unit tests/generation check, full parallel
  `swift test`, and the PR path preflight before submitting the implementation/archive PR.

### Stop conditions

- Stop if implementing the delta needs a new operation, provider, profile, raw command or a
  broader authority; each needs its own approved scope.
- Stop if any campaign attempt lacks fresh reservation/readback or is unknown/unsafe; no recovery
  or replay may be inferred.
- Stop if a requested evidence record contains raw device identity or would be used to create an
  authority instance.
