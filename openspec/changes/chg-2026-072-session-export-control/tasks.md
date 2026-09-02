# Tasks — CHG-2026-072

## TASK-SEP-001 — Publish generation-bound Session export preview/apply

- Status:in-progress (the status and implementation have no protected-main
  effect until a human maintainer reviews and merges the delivery PR)
- Golden Journey:GJ-1, GJ-2, GJ-3, GJ-4, GJ-5 post-run Artifact handling
- Platform:macos
- Acceptance:SEP-AC-1, SEP-AC-2, SEP-AC-3, SEP-AC-4
- Depends on:protected-main Runtime Session storage/catalog, existing anchored
  `SessionDiagnosticExporter`, protocol 2 negotiation, and bot-authored PR flow
- Production reachability:`arkdeck session export preview/apply` → daemon
  UDS/XPC allowlist → Runtime-owned Session storage/catalog → bounded external
  host destination; no device Provider or Runtime Job dispatch
- Trusted facts:catalog generation, finalized manifest and Artifact identity /
  digest / role / bytes, destination descriptor identity and volume, Runtime
  clock, durable preview state
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `docs/design/**`
  - `openspec/changes/chg-2026-072-session-export-control/**`
  - `evidence/runs/TASK-SEP-001/**`
- Forbidden paths:
  - `Catalog/**`
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/verification/**`
  - `openspec/baselines/**`
  - `openspec/integrations/**`
  - `openspec/platforms/**`
  - other change directories, `AGENTS.md`, `PRODUCT-LOOP.md`, `.github/**`
  - raw executable/argv/shell/HDC/remote path, caller privacy or capability
    facts, overwrite, device dispatch, source Session mutation, unknown replay
- Risk:medium (host filesystem publication and sensitive diagnostic disclosure;
  bounded preview, explicit opt-in, redaction, exact destination identity,
  durable applying state, atomic publication, and no-replay failure handling)
- Hardware required:no
- Decision-Grade:D1 (new published host control surface; human maintainer review
  and protected-main merge are the approval)

### Deliverables

- Runtime preview/apply owner and private durable record;
- strict protocol/XPC/CLI vocabulary and response validation;
- exact Artifact/privacy/redaction/destination projection with no source paths;
- anchored bounded export, immutable receipt, and outcome-unknown no-replay;
- parser, owner, drift, privacy, corruption, fault, and real CLI subprocess
  coverage; minimal product documentation and host evidence.
