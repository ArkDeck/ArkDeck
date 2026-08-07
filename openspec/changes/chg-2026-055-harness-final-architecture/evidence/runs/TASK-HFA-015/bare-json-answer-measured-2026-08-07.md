# The rejection this removed, measured on hardware (2026-08-07)

## Baseline

This document ships with the fix it measures, so the baseline is the commit that
carries both: `agent/gj5-proposal-quality` on top of `main@0bc7f486`. It is not a
measurement of `main` — `main` does not have the change.

Device: DAYU200, `OpenHarmony-7.0.0.34`, target `TGT-958780b2ffb7`. Run:
`HTASK-0C535C0E0B87`, terminal `succeeded`, 21 rounds, 6 E1 mutations, zero human actions.

## What the fix was for

`HTASK-7C12960C4B6E` round 7 — the one round in that task where a patch proposal was
possible — returned a complete, correct proposal and was refused as `malformedJson`,
because a sentence preceded the bare JSON object. The task then stopped for a human who
had that patch in the record.

## What changed, per round

Every producer rejection in each run, read from `model_run.rejectedResponseExcerpt` and
its outcome:

| | before (`HTASK-7C12960C4B6E`) | after (`HTASK-0C535C0E0B87`) |
|---|---|---|
| producer calls | 7 | 20 |
| rejections | 5 | 6 |
| `malformedJson` | **1, at round 7** | **0** |
| furthest round reached | 7 | 21 |

```
before   r3–r6  operationNotOffered:workspace.apply-patch@1
         r7     malformedJson                       ← the correct patch, discarded

after    r2,r4,r5,r6  operationNotOffered:…:offered=…
         r11    operationNotExpected:debug.hap@1
         r13    operationNotExpected:analyzer.extract-crash-signature@1
```

`malformedJson` does not appear. The rejections that do appear after the fix are later in
the run and of different kinds, which is what getting past a wall looks like rather than
avoiding it.

## What this does not establish

**Not that the success rate moved.** This is the fifth sample of GJ-5, and the tally is now
four passes in five attempts across two firmware builds. One run cannot separate a fix from
producer variance, and the same over-reading was already made once in this change window and
had to be withdrawn (`refusal-alternatives-measured-2026-08-06.md`).

What is supported, and all that is claimed: the single failure in that tally had a named
cause, `malformedJson` on a correct proposal; that cause did not occur in this run; and the
loop passed the point where it previously stopped.

**Not that the producer is now reliable.** Two `operationNotExpected` rejections appeared at
rounds 11 and 13. They cost rounds and did not stop the run, and nothing here investigates
them. They are recorded because a run that passes is still the place to look for the next
failure.
