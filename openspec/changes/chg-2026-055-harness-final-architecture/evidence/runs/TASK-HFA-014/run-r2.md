# TASK-HFA-014 r2 — the workspace that outlived its process, and the reading that never happened (2026-08-06)

## Status: `HFA-AC-24`, `HFA-AC-25` PASS (contract)

- Baseline: `main@81e1636c` plus this change
- 1344 tests, 0 failures; check-sdd 0 errors, 0 warnings
- Field case: `HTASK-C458F21E8B9C` on DAYU200 / OpenHarmony 7.0.0.37

## The run this came from

```
12:45:15  daemon starts
12:51:52  evolution workspace created → derived profile registered in that process
12:54:52  task parks: operationUnavailable:analyzer.extract-crash-signature@1
13:06:02  daemon restarted to configure the analyzer  ← new process, new registry
13:13:59  STALE_DECISION:workspaceRevisionChanged:084dddd2b862->none
13:15:45  STALE_DECISION:workspaceRevisionChanged:084dddd2b862->none
13:17:15  STALE_DECISION:workspaceRevisionChanged:084dddd2b862->none
13:18:34  causation=noSafeAction  reasonCode=insufficientEvidenceForPatch
```

The evidence was not insufficient. The workspace tree was intact throughout —
its files are still there and computing its revision directly still returns a
value. What was lost was the *registration*.

## `HFA-AC-24` — the isolated workspace outlives the process that made it

There are exactly two `.register(` call sites in the repository and both are
inside `prepareWorkspace`, which the coordinator calls only at task
submission. `EvolutionWorkspaceManager.init` creates a directory and nothing
else. So a task whose workspace was made by an earlier process holds an
`evolution-…` reference that the new process's registry cannot resolve, and
`WorkspaceHarnessRepairPort` throws `projectProfileMismatch` from then on — in
a plane whose entire purpose is surviving restarts, in the same daemon that
prints "recovered N active job(s)" at startup.

`adoptPersistedWorkspace(_:policy:)` re-registers from the stored manifest.
Deliberately not `prepareWorkspace`: preparation re-derives the *source*
revision and refuses when it has moved, which is the right question when
deciding whether to make a copy and the wrong one when deciding whether a copy
that already exists is still itself.

It refuses rather than rebuilds — the caller already holds the reference, so
pointing it at a different tree would substitute one isolated workspace for
another underneath it. Destroyed workspaces stay destroyed. And the allowed-
paths digest now has one definition shared by creation and adoption; two copies
would drift and adoption would start accepting workspaces whose scope it no
longer matches.

`HarnessTaskCoordinator.adoptPersistedEvolutionWorkspaces()` runs before
`recoverTasks()` resolves any intent, and covers every non-terminal task with a
workspace — not only those with unresolved intents, because the task in the
field case was parked waiting for a human and had none. It returns what it
could not adopt instead of throwing, and the daemon prints each one at startup:
a workspace it cannot adopt will fail every workspace decision that task makes,
and nobody should have to discover that six rounds later.

Checked by breaking it: make adoption fall back to the source tree — the
mistake the task names as its most dangerous — and
`testAPersistedEvolutionWorkspaceIsAdoptedByANewProcess` goes red on the
assertion that the adopted root is not the source root.

## `HFA-AC-25` — a reading that did not happen is not a reading that differs

`executionFacts` obtained the revision through one `try?`, so four unmet
preconditions and every thrown error became the same `nil`, and the staleness
check read that `nil` as "the workspace is at some other revision". It then
reported `workspaceRevisionChanged:084dddd2b862->none` — a claim about an
observation that was never made.

The reading is now three-valued: `notRequired`, `measured`, or `unmeasurable`
with a typed reason. Only a number that was actually read can contradict the
decision; a failed reading produces `workspaceRevisionUnmeasurable`, whose
reason code carries what failed to answer.

Checked by breaking it: route `unmeasurable` back into
`workspaceRevisionChanged(current: "none")` and
`testAnUnreadableWorkspaceRevisionIsNotReportedAsAChangedOne` goes red. And the
floor is separately held: a revision that really changed is still stale
(`testAMeasuredMatchingRevisionIsFreshAndAMeasuredDifferentOneIsNot`), because
three-valuing it must only pull "unreadable" out of "changed" and never turn
"changed" into "unchanged".

## One acceptance bullet was wrong, and is corrected rather than worked around

`HFA-AC-25` originally required that the loop "must not report
`insufficientEvidenceForPatch`". That string does not appear anywhere in the
Swift sources. It is the decision producer's own chosen reason, surfaced under
`causation: noSafeAction` — the last event of the field case. The product
cannot forbid a producer's choice of words.

What the product controls is whether what it feeds back is true, so the bullet
now constrains the staleness reason and the startup report instead. The
correction is recorded in `verification.md` next to the bullet, with what was
measured. This is making the assertion accurate, not relaxing it: the thing the
original demanded has no gate in the code to fix.

## Coverage, stated honestly

Contract only, as the task declares. The field case is not re-run here: GJ-5 on
7.0.0.37 is separate verification and must not be claimed from these tests.

What this change cannot promise: the producer, told the truth, will choose a
better reason. It will now be told that the measurement did not happen and
why, instead of being told the workspace moved. Whether the next run gets
further is a question for that run.
