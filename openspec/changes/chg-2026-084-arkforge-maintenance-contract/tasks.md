# Tasks — CHG-2026-084

## TASK-AFM-001 — Pin the consumer and retain handshake failures

- Status: done; implemented in merged PR #2657.
- Hardware required: no.
- Scope: all Rust ArkForge dependency pins, upstream consumer CI, version
  assertions, refusal propagation through shared Runtime and macOS decoding,
  Rust/Swift/Windows regression coverage.

## TASK-AFM-002 — Integrate authority-owned maintenance

- Status: done; integration published in PR #2659, with discovery and public
  result/Session repairs published in PRs #2673 and #2676. Scoped independent
  real-device results are recorded in [the acceptance run](independent-acceptance-20261019.md).
- Hardware required: no for implementation and fake tests.
- Implemented scope: retain an immutable source plan/receipt/binding correlation;
  implement device-exclusive source loading and bounded partition-read port;
  implement exact materialized ramdisk plan and durable one-use reservation;
  persist intent/result/stopped records; publish the proposed Catalog operations,
  generated contracts, CLI, macOS Flash workspace and Windows result surfaces.
- Safety: no standalone authority access, no arbitrary paths/argv, no capability
  administration, no replay, no historical receipt changes, no hardware claims.

- Authority boundary: destructive default policy issuance stays disabled in the
  immutable revision-1 Catalog; revision 2's exact original-ramdisk policy was
  separately published in PR #2675.
  Plan-only failures do not create stopped records. No production
  support or hardware acceptance is inferred from fake checks.

## TASK-AFM-003 — Prepare the default ramdisk-restoration policy

- Status: done; focused host checks and selected platform CI passed, and the
  separately reviewed policy was published in PR #2675 as
  `f67e9919f87c9cb25d285c6317cbeb0e1b1cdf5b`.
- Hardware required: no for candidate preparation and host tests.
- Scope: enable only `flash.restore-boot-loop@1`'s existing exact-plan
  Runtime-owned capability policy; retain its source, Artifact, identity, budget,
  exclusion, durable-intent and no-replay checks. Preserve all old input schemas
  and immutable Catalog views when adding the candidate digest.
- Policy publication alone does not establish hardware acceptance or authorize a
  new nine-partition source Flash that overwrites userdata. Both scopes were
  separately authorized for [the completed independent run](independent-acceptance-20261019.md).
