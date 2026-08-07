# The reconciliation readback has a proven construction, and a crash is not it (2026-08-07)

Supersedes the forward-looking claims in three documents in this directory. Their historical
observations stand; what they predicted about *how* the readback would first be exercised does
not. Delivered as `CHG-2026-025@r17` / `TASK-AIN-020` (#1169); the decision itself is
`docs/adr/0009-campaign-unknown-outcome-authority.md`.

## What each document claimed, and what is true now

| Document | Claim | Status |
| --- | --- | --- |
| `gj4-flash-any-build-2026-08-06.md` | "only reached when an attempt fails part-way through … if a future window has an attempt break mid-flight, those paths get their first real exercise" | **False for the readback.** A mid-flight break cannot reach it, by construction. |
| `all-journeys-on-7-0-0-34-2026-08-06.md` | "the same gap … still open" | Narrowed. Contract coverage was already complete; the *construction* is now exercised by the real engine. Device execution remains unexercised. |
| `reconciliation-readback-premise-2026-08-07.md` | "Production reach: still none … with a known construction and a known blocker" | The construction is no longer hypothetical, and the blocker it named is gone. |

## Why a mid-flight break can never reach it

Two structural reasons, both read out of the code rather than inferred from a window:

1. **Reconciliation seals its own answer in the same pass.** `reconcileUnresolved` writes its
   own `outcomeUnknown` terminal *and* calls `closeAttempt` in one call. After that
   `document.activeReservation` is nil, so the next `flash continue` returns at the first
   guard. The terminal it wrote is never re-read — and the branch that consults the readback
   only ever sees a terminal the **engine** wrote. Killing the daemon and killing the child
   tool both land here, which is why two different interrupt techniques produced the same
   result.
2. **A partition write is classified out before the device is consulted.** Unchanged, and
   already pinned by the `destructive-intent` row — this is the part
   `reconciliation-readback-premise-2026-08-07.md` got right.

So the 2026-08-06 window's failure to reach the readback was not bad luck or bad timing, and no
future mid-flight break will do better.

## What does reach it, now exercised

An **engine-written** `outcomeUnknown`: a job that survived, could not observe its own outcome,
and journaled complete intent sets. That is production-reachable without any crash —
`DescriptorBoundProcessDispatcher` raises `outcomeUnknown` whenever a child's outcome is
unobservable, as does a provider verification that returns unknown for a step with no paired
readback.

`EvolutionCampaignContractTests.testTheEngineWritesTheUnknownTerminalTheReadbackConsumes` now
builds that terminal with a **real `RuntimeJobEngine`** rather than seeding it: a campaign
reservation on `flash.dayu200@1`, the first mutating dispatch losing its child, and the engine
closing the reservation with `status: outcomeUnknown` and the intent it journaled. The
classifier then confirms that shape is the one — and the only one — that reaches the readback.
Both of the readback's conclusions are driven over it.

The named blocker is gone with it. The premise document reported that the session sandbox could
not read `~/Downloads`, so no campaign could start. This window read the pinned 7.0.0.35 archive
directly: the test ran green in 229s against it, of which most is hashing 731 MB. Device
dispatch: 0.

## What is still not exercised, stated narrowly

The readback has never run **on a device**. Reaching it there needs a real attempt whose
outcome the engine observes as unknown — a child tool dying or a provider verification going
unknown, with the daemon surviving to record it. That is a fault to inject on a live run, not
something a window can schedule, and no device window here attempted it.

What is no longer open: whether the path is reachable at all, what shape reaches it, and
whether interrupting a flash mid-flight would help. The last one is now a definite no, and the
board it would have cost is the reason this correction is worth its own document.
