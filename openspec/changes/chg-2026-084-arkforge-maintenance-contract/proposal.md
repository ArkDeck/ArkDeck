---
id: CHG-2026-084-arkforge-maintenance-contract
revision: 1
status: proposed
class: capability
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos, windows]
---

# ArkForge maintenance consumer contract

The existing ArkForge lane sends Hello through the shared Rust SDK. Device-access
failures previously hid HelloAck.refusal behind a generic observation failure.
The first implementation pins all ArkForge crates to the main commit that merged
PR #44, asserts protocol 1.0 and adapter contract 1.0.0, runs both upstream
consumer_contract suites, and exposes the handshake refusal to CLI and both apps.

## Proposed operations (not yet published)

- `flash.verify@1`: readOnly, confirmed device, exclusive target lane, source Job
  reference and bounded duration only. Runtime derives the sealed ranges, hashes,
  tools and identity. A separate flash-verification/v1 result exposes 0 matched,
  9 typed skip and 7 failed, target ranges/digests/strength/reason, and source IDs.
- `flash.restore-boot-loop@1`: destructive, RuntimeCapability, confirmed device,
  exclusive target lane, source Job and immutable artifactLease. The plan writes
  exactly the pinned original ramdisk, never userdata. Invalid parameters produce
  exit 2 before a record; stopped produces exit 1 with no blind retry; success is
  exit 0 only after a distinct succeeded Job plus full ramdisk hash verification.

Neither operation may call the standalone ArkForge CLI/script: its authority
namespace, records and permits are not ArkDeck's. Unknown outcomes stay unknown;
this ramdisk-only operation is not complete-overwrite recovery. Exact capability
consumption, durable intent before dispatch and fresh target checks remain required.

## Dependency and review

The user explicitly extended scope to an ArkForge-owned safe maintenance API.
The companion adapter API provides typed orchestration over trusted Runtime ports.
It needs maintainer review and merge before this main-only dependency pin can
consume it. This PR does not publish unsupported Catalog entries or enable a
candidate operation. Runtime port implementation and the result UI/CLI remain
open in tasks.md; the contract pin/handshake work is independently usable.

No tag, release, device write or new hardware acceptance is part of this change.
