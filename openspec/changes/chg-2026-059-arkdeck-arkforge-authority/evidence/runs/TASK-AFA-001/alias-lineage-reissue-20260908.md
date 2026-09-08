# The reissued alias counter, and what it takes to finish unblocking GJ-4 — 2026-09-08

- Task: TASK-AFA-001
- Base: protected `main` `50dd15e9` (#1776).
- Measured on a helper built from `main` `6ba5a0b9`, daemon SHA-256
  `c1d313a0229d7f756db9adebd8b64b250bae5f8d0f6a6f0ad5e2b01eaad40f45`, Catalog
  digest `508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684`,
  with the DAYU200 attached in hdc-normal.

## Re-measured, not inherited

The 2026-09-08 diagnosis in
`post-flash-alias-watermark-20260908.md` was re-taken against this build rather
than carried forward:

| Read | Result |
| --- | --- |
| `flash bootloader-status` | `mode: hdcNormal`, `disposition: unbound` |
| `flash device-access` | `observationCount: 0`, `observedModes: []` |
| `flash prerequisites --target TGT-958780b2ffb7 --device-profile dayu200` | exit 1, `flash.postFlashHDCBindingConflict: stored alias revision 4 is newer than target revision 2` |
| `flash lane-preview …` | `state: deviceNotObserved`, same reason |
| `device candidates` | `TGT-958780b2ffb7`, `bindingRevision: 2`, `authorizationState: Connected`, `observationContinuity: relationProven`, `OpenHarmony-7.0.0.37` |

`ArkDeck/rockchip-post-flash-hdc-binding.json` holds `bindingRevision: 4`,
`Agentd/targets/targets.json` holds the same target at `2`. Same `targetID`,
same `stableLoaderIdentitySHA256`/`stablePhysicalIdentitySHA256`
`94a25a89c9c214dc9f8a0cf1b2cb3703a466e132a97fa015dfdbebfc65546f42`, same
connect key `150100424a544434520325874bbf4900`, same build.

`flash.full-restore@1` is *also* `unavailable` in `operation list`
(`provider_tool_unavailable`, ArkForge connected for assessment only). That is a
second, independent gate and this record does not touch it.

## The counter is not a route

`bindingRevision` on the alias record is a copy of the target store's counter.
The target store lives inside the daemon state directory; both Rockchip stores
live a level up in the Application Support root
(`ArkDeckAgentDaemonMain/main.swift`: `resolvedStateDirectory.deletingLastPathComponent()`).
Retiring the state directory — something the product itself offers — reissues
the counter from 1 and leaves the alias holding the retired store's high-water
mark. Every later Flash on that host is then refused forever.

A reissue is mechanically distinguishable from a genuinely newer route, and the
proof needs no new durable field. `RuntimeTargetRecord.bindingRevision` has
exactly two writers in the product — `DeviceBootstrap.swift:752-755`, which
adopts at `1`, and `:820-823`, reached only through `advanceBindingLineage`,
which refuses unless `previousStableIdentitySHA256 != currentStableIdentitySHA256`.
Nothing lowers one. So within a single store a `(targetID, stableIdentity)` pair
has exactly one revision, and a stored alias that still names this target, this
Loader identity, this HDC identity, this connect key and this build cannot be
describing a newer route — a newer route differs in at least one of those,
because that is what a route is. The only remaining explanation is that the
counter restarted underneath it.

Independently corroborated on this host:
`Agentd.retired-20260907T021356Z/targets/targets.json` holds `TGT-958780b2ffb7`
at revision 4 with the *same* stable identity `94a25a89…` that the live store
holds at revision 2, and the existing archive
`post-flash-superseded-20260814T080951Z.json` (revision 3) carries a *different*
Loader identity `718d93ba…` — the lineage did track identity changes while the
counter was continuous.

## Delivered here

1. `RockchipPostFlashHDCBindingStore.reconcileReissuedLineage(…)`. Under the
   store lock, and only when the stored revision is strictly ahead **and** all
   five identity facts agree with fresh target and device facts, it archives the
   superseded entry and republishes the same route at the live revision. No
   revision is invented or lowered, no target is edited, no unknown Job outcome
   is resolved, and every routing fact is carried across unchanged. Any
   disagreement returns nil and the original refusal stands.
2. `archiveSuperseded` no longer treats `EEXIST` as success. The archive name is
   derived from the establishment time alone, so two entries of different epochs
   can collide; the old branch returned success having written nothing and let
   the caller overwrite the live record, discarding the entry the archive exists
   to preserve. It now refuses unless the occupant is byte-identical. The
   reconciliation depends on this, and this host already carries one such file.
3. The admission refusal names which of the two things happened.
   `flash.postFlashHDCAliasLineageReissued` is published when the stored alias
   still names this target and Loader identity;
   `flash.postFlashHDCBindingConflict` keeps its original meaning for a real
   route disagreement. Neither branch admits anything.
4. The `publish` doc comment no longer credits the `:96-98` guard with stopping
   a stale Job from rotating a newer route. It cannot: the sole production
   caller passes `expectation.previousIdentitySHA256` to both operands, so in
   production it can only be true. The property comes from the else-branch's
   fourth conjunct, which compares the store's own value.

Tests: `testReissuedAliasLineageIsArchivedAndRepublishedAtTheLiveRevision`
(archive contents, every carried fact, idempotent repeat),
`testReissuedAliasReconciliationRefusesOnAnyIdentityDisagreement` (five negative
controls, each asserting the stored alias survives untouched),
`testSupersededArchiveRefusesToDiscardADifferentEntryOnANameCollision` (both
records survive). `testUnpublishablePostFlashAliasRefusesPlanAndSubmitBeforeCapabilityOrDeviceWork`
now asserts the correct code per conflict instead of one string for all three;
its actual property — every conflict refuses before any capability or device
work and every durable file is byte-identical afterwards — is unchanged.

## Not delivered: the entry point, and the exact revision it needs

The mechanism has no production caller yet, and deliberately so. The three
places it could be called from are each wrong as they stand:

- `RockchipRuntimeComposition.currentFacts` is the single Provider facts entry
  point and serves `flash prerequisites` and `flash lane-preview` as well as
  admission. Reconciling there would make a read write durable state.
- `flash install-binding [--rebind]` runs entirely in the CLI process against
  `rockchip-binding.json`. The alias store is daemon-owned; having the CLI write
  it would invert that ownership. It also requires an attached Loader, and this
  reconciliation must run in hdc-normal.
- `flash bind-loader` is control-plane, target-scoped and already CAS-on-revision,
  but its published contract is about the currently attached **Loader**.
  Overloading it would change what an existing leaf means.

**Recommendation: one new published leaf, `flash reconcile-alias --target <id>
--expected-binding-revision <n>`**, control-plane, no Catalog operation, no
capability, `hostOnly` in effect on the Runtime's own durable store, refusing
with the named reason above when the five-way proof does not hold, and returning
the archived and published revisions. `flash prerequisites` then names it in the
refusal so the operator has a path rather than a dead end.

Everything that leaf needs is already inside TASK-AFA-001's Allowed paths except
two files:

```text
openspec/contracts/cli-command-registry.yaml
openspec/contracts/cli-feature-coverage.json
```

That is the entire scope revision this asks for: two exact paths, for one leaf,
under the Task that already owns GJ-4 and both Rockchip stores. No Catalog
operation, no capability administration, no Core requirement and no Acceptance
scope changes with it. Until it merges, this host stays blocked on GJ-4 — but it
is now blocked with a named reason and a mechanism that is implemented, proven
and tested, rather than with a sentence describing a race that did not happen.
