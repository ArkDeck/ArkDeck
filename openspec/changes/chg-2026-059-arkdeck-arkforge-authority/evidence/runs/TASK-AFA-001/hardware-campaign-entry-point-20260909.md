# The hardware acceptance campaign has no entry point — 2026-09-09

A design record for `TASK-AFA-001`. It delivers a call chain, the architectural
constraint that decides the shape, the necessary changes and a verification
design. **No code is changed by this record and no campaign was minted.**

## What was found

GJ-4's second gate is `flash.dayu200` and `flash.full-restore@1` reading
`unavailable`:

> ArkForge is connected for assessment only (hardwareGated). Flash is
> unavailable: this configuration has no reviewed production support record or
> named hardware acceptance campaign.

The mechanism is one line — `ArkForgeLaneComposition.swift:454`:

```swift
inputs.campaign.isEmpty ? .unavailable(...) : .available
```

`inputs.campaign` is read from the `ARKDECK_ARKFORGE_CAMPAIGN` LaunchAgent
environment value (`:176`), written by
`runtime service update --arkforge-bundle <path> --arkforge-campaign <id>`.

Three facts make this gate ineffective today.

1. **The id is never resolved.** Composition only asks whether the string is
   empty, and `ArkForgeAuthoritySupport.seal` only copies it into the seal's
   `detail`. Any non-empty string opens the gate — `x` works as well as a real
   campaign identifier. The refusal text promises a "named hardware acceptance
   campaign"; nothing checks that the name names anything.
2. **The product can no longer mint one.** All 44 campaigns on the reference
   host date from 2026-08-04 to 08-07 and were written by the Evolution
   candidate plane. `EvolutionCandidates` and `evolution-campaigns` have **no
   consumer in the current sources**, and the string `ECAMP` appears nowhere in
   `Packages/ArkDeckKit/Sources`, `Catalog/`, `scripts/` or
   `openspec/contracts/`. `flash plan` and `flash preview` are retired. So there
   is no path — for an operator or an agent — to obtain a new identifier.
3. **An identifier names a bound object, not a label.** Each surviving campaign
   holds a `candidate-request.json` binding `operationReference
   flash.dayu200@1`, `deviceProfileReference dayu200@2`, an
   `archiveDigestSHA256` and a `stepSetDigestSHA256`. Reusing one asserts that
   its acceptance covers today's build and today's firmware.

Together: the only ways to open the gate today are to name a stale August
campaign or to invent a string. Both are false assertions, which is why this is
a product gap and not an operator decision.

## The constraint that decides the shape

A campaign must be bound to what it accepts, and what it accepts is the
authority seal key: `ArkForgeAuthoritySupport.Key.digestBytes()` over
`authorityNamespace`, `authorityImplementationVersion`,
`authorityImplementationSHA256`, `managedControlMappingSHA256`,
`managedControlToolSHA256`, `permitCodecSHA256`, `mechanicsMaturityKeySHA256`
and `hostPlatform`.

`mechanicsMaturityKeySHA256` is **not available on the host**. It is produced by
ArkForge in a mechanics assessment against the connected device, and the seal is
composed only afterwards, at `ArkForgeLaneHost.swift:845`:

```swift
let support = try authoritySupport.seal(
  mechanicsMaturityKeySHA256: mechanicsAssessment.mechanicsMaturityKeySHA256)
```

The first controller pass deliberately uses the fixed
`ArkForgeAuthoritySupport.pendingKeySHA256` / `hardwareGated` seal to obtain that
assessment, and refuses if ArkForge answers with an executable plan.

So the seal key **cannot be known** at `runtime service update` time, nor at lane
composition before an assessment. A campaign therefore cannot be minted by a
flag, by a derived identifier, or by any one-shot command. It requires a device
to be attached and an assessment to have run.

That rules out the three cheaper designs considered and leaves exactly one shape.

## Necessary changes

A two-phase, device-attached entry point, in the shape `session export` and
`flash reconcile-alias` already use — control-plane leaves, no Catalog
operation, no capability, no device mutation.

1. **`flash campaign preview --target <id> --device-profile <profile>`**
   Runs the existing assessment pass, composes the seal key, and returns the key
   digest, each of its eight axes, the current `hardwareGated` state, and a
   preview tuple (`previewId` + `previewDigest`). Read-only; no record written.
   This is what lets an agent see what it is about to accept instead of signing
   blind.
2. **`flash campaign accept --preview-id <id> --preview-digest <d>
   --campaign <identifier>`**
   Writes a Runtime-owned record binding `{campaignId, keySHA256, axes,
   acceptedAtUtc}`, refusing if the preview expired or the seal key moved since
   the preview. The identifier stays operator-supplied: it is the human
   assertion, and deriving it would assert review that did not happen.
3. **Lane composition resolves instead of testing emptiness.** Available only
   when a record exists for the configured identifier **and** its `keySHA256`
   equals the seal key composed for this run. Otherwise a named refusal
   distinguishing the three cases: no record, a record accepted for a different
   seal key, and no campaign configured at all.

Item 3 is the part that makes the gate real: a campaign stops applying by itself
when the authority build, control map, HDC, permit codec, mechanics or platform
moves, which is precisely what the seal's own `detail` claims today and does not
enforce.

All of it is inside this Task's Allowed paths, following the `flash
reconcile-alias` supplement: `ArkForge*.swift`, `control-protocol.json`,
`spec/control/methods/**`, `runtime-control-plane.schema.json`, the four CLI
registry files, `cli-command-registry.yaml`, `cli-feature-coverage.json` and
`Tests/ArkDeckContractTests/**`.

## Verification design

- Accepting a preview whose seal key has since moved is refused, and no record
  is written.
- A record accepted for one seal key does not authorize a lane whose composed
  key differs; the refusal names which axis moved.
- An identifier with no record never opens the lane, so today's "any non-empty
  string" behaviour becomes a named refusal — with a negative control asserting
  the current behaviour would fail the new test.
- `preview` writes nothing and dispatches nothing to the device beyond the
  assessment the lane already performs; `newDispatchCount` is asserted.
- The three refusal shapes are contract-tested through the daemon and the CLI,
  as `flash reconcile-alias` is.
- Device acceptance stays separate: none of the above claims GJ-4 passed.

## The governance question this does not settle

Whether accepting a campaign should require anything beyond an operator running
the `accept` leaf — a reviewer identity, a recorded justification, an expiry.
The design above records who accepted what and when, and makes acceptance
non-transferable across builds, which is the mechanical half. Whether that is a
sufficient assertion of "reviewed production support record" is a maintainer
decision, and this record does not presume it.

## Reference host state

`--arkforge-campaign 200260909-01` was bound at `2026-09-09T06:42:10Z` while
investigating, which moved operations from 27 available / 3 unavailable to 29 / 1
and made `flash prerequisites` pass. That identifier names no campaign record —
it demonstrates finding 1 above rather than satisfying the gate. **No flash was
run and the device was not modified.** Clearing it is one command:
`runtime service update --arkforge-bundle <path> --arkforge-campaign ""`.
