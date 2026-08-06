# Measuring the refusal change, and withdrawing the reason given for it (2026-08-06)

## What this corrects

The commit that added the offer to `operationNotOffered` (#1144) justified itself like this:

> On 7.0.0.34 a bounded debug loop spent its whole no-progress budget proposing the same
> thing. […] It removes one specific way the loop burned rounds: being told what it could not
> do and never what it could.

The first sentence is not what happened, and the second is not supported by measurement. Both
are withdrawn here. The change itself stands, for a narrower reason.

## What was measured

One GJ-5 run on the merged build, `HTASK-FDAA3BFEBEF7`, against the three runs that preceded
the change. The signal is how often a round's proposal is refused as not offered.

| run | firmware | refusals | terminal |
|---|---|---|---|
| `HTASK-2717D3B89C57` | 7.0.0.37 | 5 | succeeded |
| `HTASK-7C12960C4B6E` | 7.0.0.34 | **4** | **humanRequired** |
| `HTASK-E854F29E73A6` | 7.0.0.34 | **11** | succeeded |
| `HTASK-FDAA3BFEBEF7` (after) | 7.0.0.34 | 6 | succeeded |

Six sits inside the prior range rather than below it. And the run that failed had the *fewest*
refusals of any of them, while a run that passed had the most — so refusal count was not what
ended it, and reducing refusals was never the lever it was claimed to be.

## What actually ended the failed run

Its complete event trail is seventeen entries:

```
observe.device@1 → collect → analyze → deployBaselineCrashFixture → collect → analyze
evaluation    criteriaFailed
humanBlocked  patchProposalRequired
```

Six dispatches, three evaluations, and it stopped one event after the first `criteriaFailed`.
There is no stretch of rounds being spent on repeated refusals. What happened is narrower and
different: at the single round where the criteria had failed and `workspace.apply-patch@1` was
therefore on the table, the producer did not deliver a patch proposal the gateway would accept,
and the loop blocked for a human exactly as designed.

That is a defect in what the producer proposed, not in what it was told about the offer. The
earlier reading — stated twice, in a session summary and then in a commit message — was
inference from the auto-drive log's repeated `proposalRejected` lines, without reading the
task's own event trail. The trail was available the whole time.

## What the change is still good for

Confirmed in production: the reason codes now carry the round's offer, and the offer differs
round to round.

```
operationNotOffered:workspace.apply-patch@1:offered=analyzer.extract-crash-signature@1
operationNotOffered:workspace.apply-patch@1:offered=capture.diagnostics@1
operationNotOffered:workspace.apply-patch@1:offered=debug.hap@1
```

Before, all three were the same string. A refusal that names only the refused thing tells a
reader — human or producer — nothing about what to do next, and `offered=none` remains a
materially different answer from `offered=<list>`. That is worth having on its own terms.

What is **not** claimed: that delivering it changes producer behaviour, changes the success
rate, or would have saved the run that failed. One post-change sample, inside the prior range,
supports none of that.

## The open question this leaves

GJ-5's remaining failure mode is a producer that reaches the patch round and cannot produce an
acceptable proposal. Nothing here addresses that, and this document does not pretend the
journey's success rate has moved: it stands at three passes in four attempts across two
firmware builds, with the one failure unexplained beyond "the proposal was not accepted".
