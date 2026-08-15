# Tasks

## TASK-ATI-001 — Integrate pinned ArkTrace summary analyzer

- Status:in-progress（proposal、生产实现、测试与 evidence 作为同一个 GJ-5 垂直 PR
  开发并接受维护者 review；不得单独提交或合入本 change/readiness 文档。）
- Platform:macos
- Requirements:ATI-REQ-001, ATI-REQ-002, ATI-REQ-003, ATI-REQ-004, ATI-REQ-005
- Acceptance:ATI-AC-1, ATI-AC-2, ATI-AC-3, ATI-AC-4, ATI-AC-5, ATI-AC-6, ATI-AC-7, ATI-AC-8
- Depends on:none
- Review boundary:`CHG-2026-058-arktrace-summary-analyzer@r1` remains proposed while implementation
  proceeds in the same worktree. The task becomes a protected-main capability only when the one
  vertical implementation PR containing this change, production code, tests, and evidence is
  reviewed and merged by the ArkDeck maintainer.
- Readiness input pins:

  ```yaml pins
  - path: Catalog/operations/analyzer.summarize-trace.v1.json
    blob: bd466c1c030ce22b13ce87eea5ec6a65a2feaeeb
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AnalyzerProvider/AnalyzerProvider.swift
    blob: 482da2773a9a0c298411c67761eaf4f18bd20260
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Artifacts/RuntimeArtifactService.swift
    blob: 2e0f4c03cb9d0fddccee0d9fb187a8a339f8e7f3
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DescriptorBoundProcessDispatcher.swift
    blob: cea0f7b03e7e158c56f9c57303acae81cbb27059
  - artifact: ArkTrace/scripts/verify_phase5_cli_distribution.py
    sha256: e7a0c7a9bf9cd887a27307ecbf4c924ddf7a7b7b381f468330a4de2f6ae266b3
  ```
- Applicable failure patterns:AF-031, AF-059
- Production reachability:`ArkDeckAgentDaemonMain` → bounded default read-only host admission →
  `DescriptorBoundProcessDispatcher` identity-bound child → `RuntimeArtifactStore`
- Trusted fact sources:owner-selected exact descriptor + measured physical distribution bytes;
  Runtime Artifact lease metadata and immediate byte/hash revalidation; identity-bound process
  receipt. Caller cannot provide executable, manifest, argv, source hash or proof.
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckProcess/ArkDeckProcess.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckProcess/VerifiedRegularFileDescriptor.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AnalyzerProvider/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Artifacts/RuntimeArtifactService.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Artifacts/RuntimeArtifactStore.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DescriptorBoundProcessDispatcher.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderContract.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeRecoveryService.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AnalyzerProviderContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentDaemonContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**ArkTrace**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HostOnlyAdmissionContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ObserveDeviceSkeletonContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ProcessExecutorContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RuntimeJobEngineContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckEngineCrashFixture/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckIntegrationTests/**ArkTrace**`
  - `docs/adr/**arktrace**`
  - `evidence/runs/TASK-ATI-001/**`
  - `openspec/changes/chg-2026-058-arktrace-summary-analyzer/**`
- Forbidden paths:
  - `Catalog/operations/analyzer.summarize-trace.v1.json`
  - `Catalog/operations/analyzer.summarize-hilog.v1.json`
  - `Catalog/operations/analyzer.extract-crash-signature.v1.json`
  - `openspec/constitution.md`
  - `openspec/specs/**`
- Risk:medium
- Hardware required:no

### Deliverables

- Versioned ArkTrace distribution/profile loader with closed physical identity and contract checks.
- Action-specific multi-analyzer executable resolution with crash/hilog regression preservation.
- Availability-first bounded doctor/self-test and stable unavailable reasons.
- Exact fixed summary lowering from an immutable Artifact lease.
- Full ArkTrace JSON 1.0 envelope validation and exact derived Artifact publication.
- Cancellation/restart/upgrade/rollback/privacy/no-HDC contract coverage.
- Minimal operator documentation for descriptor install and version selection.

### Verification

- ATI-AC-1 → descriptor blob/generator lock → existing operation unchanged.
- ATI-AC-2/3 → profile/resolver fault-injection matrix → no wrong executable or pre-admission Job.
- ATI-AC-4/5 → exact argv + lease drift + route spies → one path token, zero shell/HDC/capability.
- ATI-AC-6/7 → real ArkTrace fixture envelopes + malformed/mismatched receipts + restart → exact
  bytes/provenance survive only on success.
- ATI-AC-8 → timeout/cancel/restart/upgrade/rollback tests + existing analyzer suite → fail closed,
  no regression.

### Notes / handoff

- This task and change package must not be submitted as a proposal-only, readiness-only,
  status-only, verified-only, or archive-only PR. Their review boundary is the same vertical PR as
  the GJ-5 production delivery.
- Before implementation and again before final review, revalidate every pin against the current
  protected main and the final reviewed ArkTrace distribution manifest. Drift requires an explicit
  change revision in that same PR, not silent substitution.
- Implementation evidence belongs in
  `evidence/runs/TASK-ATI-001/` and must state fake/platform/real classes honestly.
