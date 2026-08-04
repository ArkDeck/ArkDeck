# Tasks

## TASK-E2B-001 — Promote bounded E2 policy into the Core baseline

- Status:in-progress (`CHG-2026-056@r3` was approved by the human-reviewed merge of #1031;
  implementation remains host-only and cannot create authority instances, connect hardware, or
  dispatch)
- Golden Journey: GJ-4 (a correct E2 admission boundary is required before the real-device
  closed-loop Flash/verify journey can be claimed)
- Platform: macos, windows, linux
- Requirements: `POL-AGENT-002`, `REQ-FLASH-015`, `REQ-WF-004`
- Acceptance: `AC-FLASH-015-01`, `AC-FLASH-015-02`, `AC-FLASH-015-03`, `AC-WF-004-03`
- Depends on: maintainer review/merge approving `CHG-2026-056` (#1031); existing
  `CHG-2026-025@r15` remains the implementation provenance until archive/ratification
- Allowed paths:
  - `AGENTS.md`
  - `openspec/constitution.md`
  - `openspec/specs/flashing/spec.md`
  - `openspec/specs/workflow-journal-recovery/spec.md`
  - `openspec/contracts/provider-contracts.md`
  - `openspec/contracts/hardware-evidence.schema.json`
  - `openspec/governance/enforcement.md`
  - `openspec/governance/host-loop-runbook.md`
  - `openspec/templates/batch-digest.md`
  - `scripts/README.md`
  - `scripts/host_loop/reviewer.py`
  - `scripts/host_loop/test_reviewer_contract.py`
  - `scripts/host_loop/cursor.py`
  - `scripts/host_loop/__main__.py`
  - `scripts/host_loop/test_cursor_contract.py`
  - `scripts/host_loop/test_worker_cursor.py`
  - `scripts/host_loop/test_v3_hardening.py`
  - `scripts/host_loop/test_instance_contract.py`
  - `openspec/verification/policy.md`
  - `openspec/verification/acceptance-index.txt`
  - `openspec/verification/acceptance-cases.yaml`
  - `openspec/verification/core-conformance.yaml`
  - `openspec/verification/traceability.md`
  - `openspec/config.yaml`
  - `openspec/baselines/CORE-4.0.0.yaml`
  - `openspec/platforms/PLATFORM-PROFILES.lock.yaml`
  - `openspec/changes/chg-2026-056-e2-policy-baseline-alignment/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckHarness/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/AuthorizationUsageLedger.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/HardwareEvidenceProjector.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/AgentDaemon.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/main.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`
- Forbidden paths:
  - `Catalog/**`, all `scripts/**` other than the exact paths above, and all integration/device
    profiles
  - standing authorization or campaign confirmation instances
  - real device/HDC/RockUSB tooling, raw shell command surfaces, or hardware evidence claiming a
    dispatch
- Risk: destructive (the policy removes an E2 pre-dispatch reviewer. Implementation may change
  only the listed Runtime review/pin plumbing, historical evidence compatibility projection, and
  tests, and must perform zero external effect)
- Hardware required: no
- Decision-Grade: D1

### Deliverables

- Apply the approved deltas to current Core files without weakening the exact E2 envelope.
- Reconcile the live batch-digest template and host-loop runbook with the no-review policy: a
  complete digest must not contain an independent-AI-review field or require a separate reviewer
  session. Preserve normal maintainer PR review/merge and leave host-loop worker, transport and
  lease behavior untouched.
- Remove the unreachable host-loop reviewer module, its offline-only contract suite and the
  never-written `review_run` cursor field. Do not modify host-loop worker, transport, lease or
  GitHub route behavior.
- Remove the production adversarial-review invocation from the campaign and workspace-promotion
  paths. A changed candidate must proceed only after its existing fixed isolated build and closed
  strategy-output validation; it must not create a separate reviewer process/session or require a
  review receipt/digest. Preserve decoder-only access to historical review-bearing records where
  needed, but do not mint new review gates.
- Add `AC-FLASH-015-03` to the canonical acceptance index/cases and update the `REQ-WF-004`
  evidence authority vocabulary.
- Create `CORE-4.0.0` only in the human-reviewed archive/ratification PR; set macOS to
  `needsReverification` and Windows/Linux to `deferred`.
- Preserve all historical evidence/bytes and state explicitly that no real device run was made.

### Verification

- Source review proves every current policy/contract representation has the same two authority
  kinds, immutable-candidate/fresh-readback gate and fail-closed terminal set, without an
  adversarial-review precondition.
- Contract tests prove a changed candidate cannot enter admission before the fixed isolated
  build/strategy-output validation, then reaches the fake admission path without a reviewer
  invocation; missing, expired, consumed, drifted, unknown and unsafe campaign states retain
  destructive dispatch count 0. The positive test uses only fake/provider fixtures and verifies
  truthful authority correlation.
- Run `sh scripts/check-sdd.sh`, catalog generator unit tests/generation check, full parallel
  `swift test`, and the PR path preflight before submitting the implementation/archive PR.

### Stop conditions

- Stop if implementing the delta needs a new operation, provider, profile, raw command or a
  broader authority; each needs its own approved scope.
- Stop if any campaign attempt lacks fresh reservation/readback or is unknown/unsafe; no recovery
  or replay may be inferred.
- Stop if a requested evidence record contains raw device identity or would be used to create an
  authority instance.
