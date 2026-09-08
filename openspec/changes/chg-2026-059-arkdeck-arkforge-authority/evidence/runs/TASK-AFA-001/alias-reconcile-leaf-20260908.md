# The reconciliation entry point — 2026-09-08

- Task: TASK-AFA-001
- Base: protected `main` `e93b686f` (#1782, which added the three paths this uses).
- Precondition: #1779 landed `reconcileReissuedLineage`, its mechanical proof and
  its tests. This is the leaf that calls it, and it is the last piece before
  GJ-4's first gate can be cleared on the reference host.

## The leaf

```text
arkdeck flash reconcile-alias --target <id> --expected-binding-revision <n>
```

Control-plane, `flash.reconcile-alias`. No Catalog operation, no capability, and
**zero device dispatch**: the only facts it uses are the durable target record
and the USB identities the host can see right now.

`ProductRockchipPostFlashAliasReconciler` gathers them itself:

1. Compare-and-swap on the caller's `--expected-binding-revision` against the
   live target, exactly as `flash bind-loader` does. A stale caller reconciles
   nothing.
2. Exactly one registered DAYU200 must be attached, and it must be in
   **hdc-normal** mode. A Loader-mode board cannot answer for the hdc-normal
   alias this store describes, and two boards make "the attached device"
   ambiguous.
3. `reconcileReissuedLineage` then requires all five identity facts to agree
   before it archives and republishes.

Every fact is Runtime-observed. None is supplied by the caller, and none can be
satisfied by handing the function a value copied out of the record it is
judging. The receipt reports the archived and published revisions and the HDC
identity digest; it never carries the raw connect key.

## One deliberate change to what #1779 merged

`reconcileReissuedLineage`'s fifth fact was `observedBuildVersion`. It is now
`observedUSBTopology`, compared against the record's own `usbTopology`.

The build version can only be read back over HDC. This leaf dispatches nothing
to the device, so the only values a caller could pass are one copied out of the
record — which makes the comparison the same empty guard documented on
`publish` — or a caller assertion, which is not a proof. The USB topology is
observed from the same IOKit probe that supplies the identity and connect key,
so it is a real fact about the attachment, and it is a *stronger* freshness
signal than a firmware string: it changes when the board moves to another port,
which is exactly a case where "the attached device is the one this alias
describes" should be re-established rather than assumed.

The record still carries `buildVersion`, unchanged, and republication preserves
it byte for byte along with every other routing fact.

## Refusal now names the way out

`flash prerequisites` previously ended at `flash.postFlashHDCAliasLineageReissued`
with an explanation and no next step. It now names the exact command, with this
target's own id and live revision substituted in, and says the board must be in
hdc-normal mode.

## Verification

`RockchipRuntimeCompositionContractTests`, 44 tests, 0 failures. New cases:

- `testReconcileAliasLeafRepublishesOnlyWithTheBoardAttachedInHDCNormal` —
  archived revision 4, published revision 2, the stored HDC identity carried
  across, and the receipt asserted not to contain the raw connect key.
- `testReconcileAliasLeafRefusesWithoutACompleteFreshProof` — six negative
  controls: nothing attached, board in Loader mode, two registered boards, a
  different board's serial, the same board at another USB topology, and a stale
  `--expected-binding-revision`. Each asserts the stored alias survives byte for
  byte.

The fixtures reach binding revision 2 through `adopt` plus
`advanceBindingLineage` and use the target id adoption mints, rather than
writing a target record directly — a hand-written record would fabricate a
lineage the store itself refuses to produce.

`CLIMachineContractTests` 22/22 after regenerating the two contract products
with `arkdeck maintainer contracts export`; the generator also produced the
`flash.reconcile-alias` argv fixture and updated the fixture index.

## Not verified here

The leaf has **not** been run against the reference host's real reissued alias.
Doing that would mean installing a helper built from an unreviewed branch and
letting it write the user's durable alias store. Real-device verification waits
until this merges and a helper is rebuilt from protected `main`; the run record
belongs to TASK-SVC-005.

GJ-4's second gate is untouched by this: `flash.full-restore@1` is separately
Catalog-`unavailable` for want of a named hardware acceptance campaign.
