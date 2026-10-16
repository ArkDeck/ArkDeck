# Tasks — CHG-2026-084

## TASK-AFM-001 — Pin the consumer and retain handshake failures

- Status: in-progress; implementation complete; PR CI and maintainer review pending.
- Hardware required: no.
- Scope: all Rust ArkForge dependency pins, upstream consumer CI, version
  assertions, refusal propagation through shared Runtime and macOS decoding,
  Rust/Swift/Windows regression coverage.

## TASK-AFM-002 — Integrate authority-owned maintenance

- Status: blocked on companion ArkForge API review/merge for a main-only pin;
  Runtime port implementation and upper-layer integration remain unimplemented.
- Hardware required: no for implementation and fake tests.
- Required work: retain an immutable source plan/receipt/binding correlation;
  implement device-exclusive source loading and bounded partition-read port;
  implement exact materialized ramdisk plan and durable one-use reservation;
  persist intent/result/stopped records; publish the proposed Catalog operations,
  generated contracts, CLI, macOS Flash workspace and Windows result surfaces.
- Safety: no standalone authority access, no arbitrary paths/argv, no capability
  administration, no replay, no historical receipt changes, no hardware claims.
