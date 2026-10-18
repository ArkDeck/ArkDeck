# Tasks — CHG-2026-084

## TASK-AFM-001 — Pin the consumer and retain handshake failures

- Status: done; implemented in merged PR #2657.
- Hardware required: no.
- Scope: all Rust ArkForge dependency pins, upstream consumer CI, version
  assertions, refusal propagation through shared Runtime and macOS decoding,
  Rust/Swift/Windows regression coverage.

## TASK-AFM-002 — Integrate authority-owned maintenance

- Status: in-progress; Runtime ports, candidate Catalog, CLI and both client surfaces implemented;
  local verification and follow-up PR CI in progress; maintainer review pending.
- Hardware required: no for implementation and fake tests.
- Implemented scope: retain an immutable source plan/receipt/binding correlation;
  implement device-exclusive source loading and bounded partition-read port;
  implement exact materialized ramdisk plan and durable one-use reservation;
  persist intent/result/stopped records; publish the proposed Catalog operations,
  generated contracts, CLI, macOS Flash workspace and Windows result surfaces.
- Safety: no standalone authority access, no arbitrary paths/argv, no capability
  administration, no replay, no historical receipt changes, no hardware claims.

- Remaining authorization boundaries: destructive default policy issuance stays
  disabled in revision 1; revision 2's candidate awaits its separate approval.
  Plan-only failures do not create stopped records. No production
  support or hardware acceptance is inferred from fake checks.

## TASK-AFM-003 — Prepare the default ramdisk-restoration policy

- Status: in-progress; candidate implementation and focused host verification prepared;
  maintainer review pending.
- Hardware required: no for candidate preparation and host tests.
- Scope: propose enabling only `flash.restore-boot-loop@1`'s existing exact-plan
  Runtime-owned capability policy; retain its source, Artifact, identity, budget,
  exclusion, durable-intent and no-replay checks. Preserve all old input schemas
  and immutable Catalog views when adding the candidate digest.
- Completion of this Repo change does not establish positive hardware acceptance
  or authorize a new nine-partition source Flash that overwrites userdata.
