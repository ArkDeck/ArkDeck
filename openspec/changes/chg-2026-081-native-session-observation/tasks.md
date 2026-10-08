# Tasks — CHG-2026-081

## TASK-NSO-001 — Produce native deployment Session observation

- Status: in-progress; this document does not approve the proposal.
- Golden Journey: GJ-3 native deployment and rollback.
- Hardware required: no for implementation; current-Catalog acceptance remains separate.
- Decision-Grade: D1 (additive published plan/Catalog delta).
- Scope: native Catalog evidence prefix, generator and generated consumers,
  existing Runtime evidence/action routing, truthful failed final-cleanup status,
  strict final/compensation cleanup-debt persistence, focused native tests and
  the implementation run note.
- Allowed paths: Catalog/**, scripts/catalog_gen/**, rust/**,
  Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogGenerated.swift,
  Packages/ArkDeckKit/Sources/ArkDeckCore/FlashReviewCatalogGenerated.swift,
  Packages/ArkDeckKit/Tests/ArkDeckCoreTests/RuntimeOperationCatalogTests.swift,
  openspec/changes/chg-2026-081-native-session-observation/** and the
  TASK-XPA-011 evidence run note.
- Derived-consumer work includes the pure
  `rust/crates/arkdeck-hoststore/examples/flash_catalog_review.rs` generator
  on Windows; its Flash presentation fields remain platform-independent.
- The current HAP software oracle retains the immutable original 63-exchange
  recipe and 108 fake calls. Its complete ten-plan capsule proves unchanged
  HAP semantics before the current owners generate fresh authority and
  publication output; historical authority seeds remain source-drift guards.
- Exclusions: accepted Core/Safety changes, new provider/action/operation,
  capability/coverage administration, historical record migration or replay,
  direct transport/device execution, hardware evidence and cleanup of the
  old unpublishable durable Job.

Deliver the scoped source increment, genuine targeted checks and normal
maintainer review. Do not mark the proposal approved or hardware verified.
