# GJ-5 `REAL_DEVICE_PASS` on 7.0.0.37, across a daemon restart taken on purpose (2026-08-06)

## Status: `REAL_DEVICE_PASS`, and the device confirmation `run-r2.md` deliberately did not claim

`run-r2.md` closed `TASK-HFA-014` on contract evidence and said so plainly: "GJ-5 on
7.0.0.37 is separate verification and must not be claimed from these tests." This is that
verification. It also answers the one thing that document said it could not promise.

- Baseline: `main@c0c04f35` (TASK-HFA-014 merged)
- Catalog digest: `e2f8eb6592aaeeec37c63a01708db2325b38c798b0f8272228ba0fccc2cfd0aa` (unmoved)
- Device: DAYU200, `OpenHarmony-7.0.0.37`, target `TGT-958780b2ffb7`, binding revision `2`
- Task: `HTASK-2717D3B89C57`

```
status = succeeded    lifecycle = succeeded    activeJobId = None
CriteriaSatisfied = TRUE
auto-drive: HTASK-2717D3B89C57: succeeded (promotionCandidateReady)

DC-1-crash-signature-absent   5/5   observed 0        expected 0
DC-2-application-liveness     5/5   observed healthy  expected healthy
DC-3-no-new-fatal-signature   5/1   observed 0        expected 0

rounds 21/30   e1Mutations 6/8   modelCalls 20/40   wallClock 1704/9000
humanActions 0   decisionStale 0
```

One `arkdeck task submit`, no `task resume`, no human action of any kind.

## The restart was deliberate, and it is the point

At round 2, with the task non-terminal and its isolated workspace already created, the
daemon was killed and restarted. That is exactly the shape that broke the previous run
(`HTASK-C458F21E8B9C`, same firmware, 2026-08-06 morning): a restart at 13:06 left the
`evolution-…` reference unresolvable, and the loop spent three rounds reporting
`STALE_DECISION:workspaceRevisionChanged:084dddd2b862->none` before stopping.

| | before `TASK-HFA-014` | after |
|---|---|---|
| stale decisions | 3 | **0** |
| rounds reached | 6 | 21 |
| E1 mutations | 1 | 6 |
| terminal | failed | **succeeded** |

The new startup pass printed nothing, which is what a successful adoption looks like — it
reports only what it *cannot* adopt. That absence is not the evidence; the behaviour is.
The decisive exercise is the `apply-patch` decision, which necessarily carries an expected
workspace revision: before the fix that decision could not be made at all after a restart,
and here it produced `PatchApplied = TRUE`.

## What the loop actually produced

`PROMOTION-EC662F278AB0`, disposition `READY_FOR_NORMAL_PR`, 2 lines across 1 file:

```diff
--- a/entry/src/main/ets/crashprobe/CrashProbe.ets
+++ b/entry/src/main/ets/crashprobe/CrashProbe.ets
-export const ENABLED: boolean = true;
+export const ENABLED: boolean = false;
```

Base `084dddd2…`, verified workspace revision after the patch `2f1d3859…`, diff digest
`4340353577e899c7…`.

**How hard this repair was, stated honestly.** The fault is a planted switch, and the
probe's own comment names the fix: "To get the demo back to normal, set ENABLED to false".
The loop is not being credited with deep debugging here, and this journey does not test
that. What it exercised is the mechanism: locate the file from a real device crash, propose
a patch, apply it inside the isolated workspace, build, deploy to hardware, and take five
verification samples.

It is also not criteria-gaming. The criteria measure what the device reports — matching
crash count and application liveness — not what the patch says, and the patch genuinely
removes the crash.

The promotion bundle keeps its own boundary: "Promotion is never a merge claim; nothing in
it can push a branch, create a commit or merge code." It is material for a
maintainer-authored PR, not a PR.

## What this settles about `TASK-HFA-014`, and what it does not

`run-r2.md` ended: "what this change cannot promise: the producer, told the truth, will
choose a better reason." On this run the producer, no longer told that the workspace had
moved, went on to propose a patch that worked. That is one run, not a proof about
producers — but it is the outcome the change was for, observed on hardware.

Two frictions were visible throughout and are **not** defects:

- `proposalRejected:operationNotOffered:workspace.apply-patch@1`, repeatedly. The model was
  given the correct offered set (`HarnessTaskCoordinator+Decision.swift` passes
  `offered.filter { available }` into the decision context) and proposed an operation that
  was not in it, because `PatchProposalReady` was still `UNKNOWN` — a patch cannot be
  applied before it is prepared. The product refused correctly and fell back; the loop
  reached `WorkspaceReady` on its own two rounds later.
- `artifactSensitiveNotOptedIn:ui-dump.json`, in every evaluation. The host allow-list for
  this run was `crash-index.txt,hilog.txt`. Sensitive evidence not explicitly opted into
  must not inform a verdict, and this one did not: per-criterion blockers were only ever
  `insufficientSamples`, because a blocker counts against a criterion only when it names
  evidence that criterion declares.

## Golden Journeys on 7.0.0.37

| | status | reference |
|---|---|---|
| GJ-1 observation and diagnostics | `REAL_DEVICE_PASS` | re-run after the flash |
| GJ-2 `debug.hap@1` full chain | `REAL_DEVICE_PASS` | re-run after the flash |
| GJ-3 app-owned native library | `REAL_DEVICE_PASS` | `job-0ceaecb9fddb3596b564d6ff3549bc55` |
| GJ-4 flash any build | `REAL_DEVICE_PASS` | `ECAMP-8D98078469DF51F57528D278` |
| GJ-5 bounded AI debug loop | `REAL_DEVICE_PASS` | `HTASK-2717D3B89C57` |
