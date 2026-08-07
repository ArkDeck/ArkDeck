# The reconciliation readback needs no risky interrupt, and is already pinned (2026-08-07)

## What this corrects

Three evidence documents carry the same sentence in different words, two of them mine:

- `gj4-flash-any-build-2026-08-06.md` — "only reached when an attempt fails part-way through"
- `all-journeys-on-7-0-0-34-2026-08-06.md` — "still open", carried forward
- `main-baseline-2026-08-07.md` — "reaching it needs an interrupt *after* the first partition
  write, which risks an unbootable board"

The last one is wrong, and it is the one that turned an open item into a hardware gamble.

## What the code actually requires

`RockchipEvolutionCampaignHost.settlesUnknownLoaderTransition` runs only for an attempt whose
durable terminal says `outcomeUnknown`, and it starts by classifying the journal:

```swift
guard let kinds = try? attemptIntents.journaledStepKinds(jobID: jobID),
  Self.isLoaderTransitionOnly(kinds)
else { return false }
```

`isLoaderTransitionOnly` refuses any step whose `minimumEffect` reaches `.destructive`, and
requires at least one `enterUpdater`. So an attempt that wrote a partition **cannot reach this
readback at all** — it is classified out before the device is ever consulted. An interrupt
after the first write would have produced `unsafePartial` or one of the other branches and
exercised nothing.

The premise was inverted: the readback exists precisely for the case where *nothing*
destructive ran and the question is only whether the Loader transition happened.

## It is already pinned, in both directions

- `testUnknownLoaderTransitionSettlesSafeWhenTheBoundTargetIsReadBackRegistered` — the positive
  path, ending `[.safeToReflash, .succeeded]`, with the durable usage terminal asserted
  unchanged because the readback settles a campaign attempt and does not rewrite authority
  history.
- `testUnknownLoaderTransitionStaysSealedWithoutAnExactRegisteredReadback` — six rows, each
  removing one leg: absent readback, identity drift, unregistered mode, **a destructive
  intent**, an unrecognized step kind, and no transition intent at all. None may settle.
- `testLoaderTransitionClassificationExcludesEveryDestructiveOrUnknownKind` — the classifier
  itself, including `["enterUpdater", "flashPartition"] → false`.

The `destructive-intent` row is the one that makes the risk unnecessary, and it predates this
change window. "Pin it with a test" was already done; what was missing was reading the test
before proposing to gamble a board against it.

## What would actually reach it on hardware, and what blocks that today

A campaign attempt that (a) journals only the loader transition, no destructive step, and
(b) records a **durable terminal** with `status == outcomeUnknown`.

The interrupt tried on 2026-08-06 had the right shape for (a) and failed (b): killing the
daemon left no terminal at all, so `reconcileUnresolved` took its no-terminal branch, closed
the reservation as `outcomeUnknown` and never called the readback. That run is recorded in
`flash-continue-first-execution-2026-08-06.md`; this document is why it could not have
succeeded.

Reaching (b) needs the engine to survive and record its own unknown outcome — the child tool
failing, not the daemon dying. That was not attempted here: this session's tool sandbox
refuses to read `~/Downloads`, where the flash archives live, so `flash preview` fails at
`archiveIntegrity` with `unreadableFile` and no campaign can start. Moving one archive
somewhere readable is all it needs, and that is the operator's call, not something to work
around.

## Status, stated plainly

Contract coverage: complete, both directions, including the exclusion that makes a destructive
interrupt pointless. Production reach: still none, now with a known construction and a known
blocker rather than an open-ended risk.
