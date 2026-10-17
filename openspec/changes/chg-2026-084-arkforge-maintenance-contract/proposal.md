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

## Proposed operations (publication requires maintainer review)

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
ArkForge PR #46 is merged at `0445530207ac5e6689e61e7b51c0edd4de7f2aec`;
all six consumer dependencies now pin that main commit. The Runtime composes the
adapter with immutable source plans, exact target observations, bounded HDC full
partition hashing, the existing Job journal, target exclusion and capability owner.
CLI and both apps use `job.plan`, pin its digest, submit once and run the retained
Job. Results include each range/hash/strength/reason and the source plan identity.

The destructive operation retains `defaultPolicyIssuance: disabled`. Enabling
its default capability issuance remains a separate explicit approval decision.
No frontend creates or edits capabilities. A refused admission has a durable
stopped record; a refused `job.plan` stays read-only and creates no record. Thus
exit 1 before submission does not imply a durable stopped record exists. Changing
that plan-only rule requires a separate decision; the clients retain plan review.

No tag, release, device write or new hardware acceptance is part of this change.

## Client usage

`arkdeck flash verify --request-file verify.json --output json` and
`arkdeck flash restore-boot-loop --request-file restore.json --output json`
accept a complete `runtime-operation-request` 1.0.0 document, with explicit
request/idempotency IDs, the exact target and binding revision, operation version
1, and requested outputs. Verify inputs are `sourceJobId` and `budgetMs`
(1000–600000). Restoration adds the Runtime-issued immutable `artifactLease` for
the original image bundle. Neither command accepts raw paths, partitions, hashes,
argv or a broad confirmation switch as operation inputs. Keep the request file to
inspect the same Job after a disconnected call; unknown execution is never replayed.

Both Flash workspaces select a source Job from the selected target's history.
Verification needs no new image; restoration uses the explicitly selected original
archive. The result shows source IDs, counts and each partition's sealed range,
expected/observed digest, verification strength and typed skip/failure reason.
