# TASK-RIW-001 Runtime-owned isolated workspace evidence

- Evidence class: deterministic macOS arm64 contract and production-composition
  verification. It is not a WaterFlow device, HAP signing, deployment or Trace result.
- Protected-main base: `89660d2b8ba7158aa4f282c25236c8681d8c3867`.
- Change: `CHG-2026-061-runtime-isolated-workspace@r1`; operation
  `workspace.prepare-isolated-copy@1`.
- Production route exercised by the end-to-end contract:
  `RuntimeJobEngine → WorkspaceOperationsProvider →
  RuntimeOwnedWorkspaceDispatcher → EvolutionWorkspaceManager →
  RuntimeArtifactStore`.

## Acceptance results

- Catalog, workflow schema and generated operation table expose one path-free
  host-only preparation operation; generator tests: 43 passed with zero drift.
- A primary profile was copied under a Runtime-owned private evolution root. The
  copied full-profile revision equalled the admitted source revision, and its narrowed
  revision, opaque reference and manifest were reopened by a fresh manager without a
  rebuild.
- Preparation consumed zero mutation capabilities. A primary/shared build was refused
  without maintainer authority; the measured isolated build received exactly one
  Runtime-default build capability.
- The isolated build published exact non-empty ZIP/HAP bytes as `unsigned.hap`; the
  primary source and primary product destination remained unchanged.
- Source drift, escaping and absolute symlinks, an oversized regular file, generic
  process dispatch of the host-only action and product/readback disagreements were
  rejected by focused contracts.
- No durable result or error asserted an absolute source, workspace or product path.

## Frozen verification

- `RuntimeOwnedWorkspaceContractTests`: 2 passed, 0 failed.
- `HarnessEvolutionContractTests`: 19 passed, 0 failed.
- `WorkspaceProviderContractTests`: 19 passed, 0 failed.
- Combined closed-list/focused replay: 44 passed, 0 failed.
- Path-aware local CI selected both Swift and App lanes and exited 0:
  - plan tests: 17/17;
  - Agent PR workflow tests: 8/8;
  - SDD: 121 acceptance IDs, 0 errors, 0 warnings;
  - Catalog generator tests: 43/43, generated output unchanged;
  - SwiftPM lane tests: 10/10;
  - full Swift lane: 1,655 tests, 0 failures, 64 seconds, maximum RSS
    1,780,695,040 bytes;
  - macOS App/UI-test `build-for-testing`: succeeded.
- `git diff --check` and strict formatting of the touched Swift implementation files
  passed before this evidence was recorded.

The maintainer merge, protected-branch CI and subsequent local WaterFlow patch,
sign/import/deploy/Trace replay remain separate gates. Raw Trace bytes are neither
included nor claimed by this evidence.
