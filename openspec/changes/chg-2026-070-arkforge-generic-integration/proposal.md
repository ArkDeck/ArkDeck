# Proposal — CHG-2026-070 ArkForge generic integration

> Status: proposed
>
> Scope approval is required before implementation. This change publishes a
> new destructive operation and moves `catalogDigest`, so it must merge after
> CHG-2026-069 and may not share a catalog generation window with it.

## Problem

ArkDeck has completed the DAYU200 execution cutover to ArkForge, but the public
and composition surfaces still describe the integration as a board-specific
Rockchip feature:

- the only public operation is the unversioned `flash.dayu200`;
- Runtime and App branch on that literal in many consumers;
- the Swift IPC codec is owned by the ArkDeck package rather than delivered as
  an ArkForge client SDK;
- LaunchAgent composition requires three independently configured values
  (`arkforged` path, digest, profile path), even though they are one reviewed
  release unit.

That shape makes the next profile or the future ArkFlash UI repeat ArkDeck's
integration work and permits configuration assembled from unrelated release
artifacts.

## Decision requested

1. Publish `flash.full-restore@1` as the canonical destructive operation.
2. Keep `flash.dayu200` for one compatibility cycle as an alias which is
   normalized to the same ArkForge adapter. The alias has no independent
   Rockchip write/readback lowering.
3. Consume an ArkForge-owned Swift package for IPC messages and the typed
   public/controller clients. ArkDeck owns authorization and product policy;
   the SDK owns framing and protocol DTOs only.
4. Configure the lane by one canonical ArkForge release-bundle path. The
   bundle manifest pins every executable and profile member; ArkDeck measures
   the manifest and each named member before spawning.

## Public contract

The canonical typed input is:

```yaml
artifactLease: required
deviceProfileRef: required, published profile reference
intent: fullRestore
verification: basic | full
```

Callers cannot submit a plan id/digest, provider, partition/address, tool,
vendor option or private action. Runtime derives all of those after target,
artifact and profile admission.

The legacy alias accepts its existing input shape for the compatibility cycle,
then converts it to the canonical input before adapter selection. Its
`partitionPlan` must exactly match the selected published profile; it never
becomes an alternative authority source.

## Release/configuration contract

One ArkForge bundle contains:

```text
ArkForge.bundle/
  Contents/MacOS/arkforge
  Contents/MacOS/arkforged
  Contents/Resources/profiles/*.yaml
  Contents/Resources/arkforge-bundle.json
```

The manifest uses relative, traversal-free member paths and records SHA-256,
byte count, role and profile id. Symlinks, undeclared members, digest drift,
duplicate roles/profile ids and non-regular files are refused. The optional
acceptance campaign remains a separate authorization input and is not embedded
as release configuration.

## Compatibility and rollback

- Existing durable jobs keep their original operation reference. History and
  recovery recognize both references; no journal rewrite occurs.
- New UI submissions use only `flash.full-restore@1`.
- Removing the new descriptor/bundle setting and restoring the previous
  generated catalog rolls back the change. The alias remains the fallback for
  one release cycle.
- `catalogDigest` movement invalidates digest-bound acceptance claims according
  to PRODUCT-LOOP §6; no existing real-device result is silently carried over.

## Out of scope

- ArkFlash UI toolkit selection;
- DAYU600 execution publication;
- removal of the `flash.dayu200` alias or legacy history decoder;
- changes to ArkForge permit/admission, recovery or native USB semantics;
- Windows packaging (tracked in ArkForge independently).

