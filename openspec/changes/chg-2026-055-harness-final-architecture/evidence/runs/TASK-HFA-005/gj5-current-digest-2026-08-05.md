# GJ-5 Bounded AI Debug Loop — current-digest run and the two defects it found (2026-08-05)

> **Superseded on the status question.** GJ-5 reached `REAL_DEVICE_PASS` on
> this digest later the same day — see
> `gj5-real-device-pass-2026-08-05.md`. The status section below states
> `IMPLEMENTING`, which was true when it was written and is not now. The two
> defects and their fixes are unchanged and still current.

## Scope and target

- Baseline: `main@a672df83` plus the two fixes described below
- Catalog digest: `e2f8eb6592aaeeec37c63a01708db2325b38c798b0f8272228ba0fccc2cfd0aa`
- Target: `TGT-958780b2ffb7`, binding revision `2`
- Device: DAYU200, OpenHarmony `7.0.0.36`, HDC `3.2.0f`
- Workspace: `WaterFlowLayoutDemo` (`demo-app`), crash probe `ENABLED = true`
- Decision producer: **the built-in deterministic handler only**. No model
  gateway was configured: no Codex CLI exists on this host and the HTTPS
  vendor gateways need a vendor credential, which this run did not have and
  did not seek. `modelCalls = 0` throughout, and no decision context left the
  host.

## Status: GJ-5 stays `IMPLEMENTING` on the current digest

The r2 window (`run-r2.md`, digest `44b6728d…`) remains the only full-chain
pass. This run did not reach a passing verdict, and nothing here is claimed as
one. What it did do is take the loop as far as a producer-less composition can
go, and in doing so it found two product defects that had made the loop
unusable on a rebound device — both fixed in this change.

## Two defects, both in the same family as #1067/#1071/#1072

The GJ-4 reflash moved the device to binding revision 2 and left every
capability issued before it installed, unexpired and unrevoked.

1. **A superseded grant shadowed every usable one.** The harness names an
   installed grant in the request it submits, and it selected one by
   (operation, active, unexpired, remaining uses, effect ceiling) — nothing
   that distinguishes a grant pinned to binding revision 1 from one pinned to
   revision 2. Deterministic ordering (earliest expiry) then picked the oldest
   such grant, which after the reflash was always a revision-1 one. The engine
   refused it correctly, but an authorization refusal stops the task for a
   human: observed as `submissionRejected:authorizationTargetScopeMismatch:
   debug.hap@1`, `HTASK-335C5F300054`. The same request naming *no* grant is
   admitted, because default policy issues a correct revision-2 envelope — so
   one stale grant permanently prevented the loop from reaching its first
   mutation. The selection now also screens the pins it can decide without the
   device: `exactBindingRevision`, `exactInputs` and `inputConstraints`.
   Target identity deliberately stays with the engine.

2. **The pre-dispatch guard was stricter than the authority it screens for.**
   It required a standing maintainer-issued grant for *every* E1 operation,
   including operations whose catalog entry allows the runtime to issue its
   own bounded envelope. That requirement was never load-bearing — any
   unexpired grant naming the operation satisfied it, including the useless
   revision-1 ones — while a device with no leftover grants at all could not
   run `debug.hap@1` from the loop even though the CLI can. The guard now
   defers to the engine exactly where the catalog says the runtime may issue
   (`defaultPolicyIssuanceEnabled`), and still requires a standing grant where
   the catalog disables it — which is every `workspace.*` mutation, i.e. the
   whole of the TASK-HFA-009 flip is preserved unchanged. With guard 2 alone
   fixed the task blocked again at `authorizationRequired:debug.hap@1`
   (`HTASK-05563396E4A6`); both fixes are needed.

## What the loop then did on real hardware — `HTASK-0C50A0C49FCE`

One `arkdeck task submit`, no `task resume`, human actions `0`:

```text
1  admitted                taskAdmitted
2  jobDispatched           baselineTargetObservation
3  jobObserved             operationSucceeded:observe.device@1
4  evaluation              inconclusive:collectMoreEvidence
5  jobDispatched           collectDeclaredEvidence
6  jobObserved             crashLedgerAwaitingDerivedAnalysis
7  jobDispatched           analyzeCapturedCrashLedger
8  jobObserved             operationSucceeded:analyzer.extract-crash-signature@1
9  evaluation              inconclusive:collectMoreEvidence
10 jobDispatched           deployBaselineCrashFixture
11 jobObserved             baselineCrashFixtureDeployed
12 jobDispatched           collectDeclaredEvidence
13 jobObserved             crashLedgerAwaitingDerivedAnalysis
14 jobDispatched           analyzeCapturedCrashLedger
15 jobObserved             operationSucceeded:analyzer.extract-crash-signature@1
16 evaluation              criteriaFailed
17 humanBlocked            patchProposalRequired
```

The E1 deployment is real: `job-9b6f06bf93f1f6fe08dbfdbdc79b99e9`,
`debug.hap@1`, `succeeded`, effect `deviceMutation`, binding revision `2`,
catalog digest `e2f8eb65…`, authority
`CAP-RT-POLICY-85F3BC10842A8E83F335D…` (`kind: runtimeCapability`, consumed
before the first mutation), with `send-hap → install-hap → package-readback →
start-ability → process-readback` each verified against a readback.

The FAIL verdict is measured, not assumed — `EVAL-803B399237CF`:

```text
applicationLiveness           healthy
crashLedgerWatermark          20170806175425 → 20170806182805   (moved after the deploy)
latestCrashSignature          jscrash:com.example.waterflowdemo
latestCrashEntryName          jscrash-com.example.waterflowdemo-20010048-20170806182805
```

Budgets were enforced and none was exhausted:
`rounds 6/12`, `wallClock 59/1800 s`, `artifactBytes 1,739,383/67,108,864`,
`e1Mutations 1/8`, `modelCalls 0/8`.

## What is still missing for a pass

Exactly one thing, and it is not a product defect: **a decision producer**.
On a `fail` verdict the deterministic handler emits
`requestHuman / patchProposalRequired` by design — "without patch bytes there
is nothing safe for the built-in strategy to invent". Only a model-backed
producer supplies a `PROPOSE_PATCH`, and this host has none configured. With
one configured, the next legs (apply-patch → build → run-tests → E1 redeploy →
re-verify) additionally require a maintainer-issued workspace capability,
because `workspace.*` mutations carry `defaultPolicyIssuance: disabled`; the
two grants currently installed are scoped to other evolution workspaces and
have expired.

So the honest current-digest statement is: the loop's observe → capture →
analyze → deploy → re-capture → re-analyze → judge cycle is real-device
verified on `e2f8eb65…`, and the repair half is blocked on host configuration
and a maintainer grant, not on the runtime.

## Verification

```text
CI=true swift test --package-path Packages/ArkDeckKit
```

`1295` tests executed, `9` skipped, `0` failures. New contract coverage in
`HarnessCapabilityRevocationContractTests` (a grant pinned to another binding
revision is never named; a grant whose input constraints the request violates
is never named; an unpinned grant is still named for any revision) and a
restated `HarnessBoundsContractTests` gate (budget is always required; a
standing grant is required exactly where the catalog disables default policy
issuance, asserted against `workspace.apply-patch@1`).
