# Tasks — CHG-2026-073

## TASK-DTO-001 — Publish the closed Debug templates as `debug.template@1` and close the Debug namespace

- Status:in-progress (the status and implementation have no protected-main
  effect until a human maintainer reviews and merges the delivery PR)
- Golden Journey:GJ-1, GJ-2, GJ-5 admitted read-only device observation between
  steps
- Platform:macos
- Acceptance:DTO-AC-1, DTO-AC-2, DTO-AC-3, DTO-AC-4, DTO-AC-5
- Depends on:protected-main Catalog generator, `hdc` provider adapter, Runtime
  Job engine, Artifact store and the declarative CLI registry
- Production reachability:`arkdeck debug template run` → `job.submit/run` →
  Runtime admission → `debug.template@1` plan (binding confirmation, template) → HDC provider lowering →
  `DescriptorBoundProcessDispatcher` → Artifact publication → `job result`
- Trusted facts:descriptor enum, template table, binding connect key, process
  receipt, evidence preflight readback
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `Catalog/**`
  - `docs/design/**`
  - `scripts/catalog_gen/**`
  - `openspec/changes/chg-2026-073-debug-template-operation/**`
  - `evidence/runs/TASK-DTO-001/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/verification/**`
  - `openspec/baselines/**`
  - `openspec/integrations/**`
  - `openspec/platforms/**`
  - other change directories, `AGENTS.md`, `PRODUCT-LOOP.md`, `.github/**`
  - raw executable/argv/shell/HDC, caller-provided command text, new step
    kinds, new remote action registrations, device mutation
- Risk:low (read-only device commands from a closed table, admitted and
  evidenced like every other operation; the direct App method is unchanged)
- Hardware required:no
- Decision-Grade:D1 (new published operation; human maintainer review and
  protected-main merge are the approval)

### Deliverables

- `debug.template@1` descriptor, profile registration and regenerated Catalog;
- template table ownership, typed provider action, lowering, verification,
  persistence and reconciliation;
- durable step parameters and Artifact mapping, with no per-operation name in
  the execution kernel;
- `debug template list/run` CLI leaves with contract coverage;
- the shared `logs` preset and the `debug logs` CLI leaf, with the App
  facade reading the same owner;
- minimal product documentation and host evidence.
