# A named campaign admits complete-overwrite recovery after the four-hour budget — 2026-09-09

- Task: TASK-AFA-001
- Decision: DEC-016 (`openspec/planning/open-questions.md`), taken by the
  maintainer on 2026-09-09.
- Base: protected `main` after #1818.

## What refused GJ-4

On the reference host, with the DEC-014 campaign bound and every device
prerequisite satisfied, `agent run --operation flash.full-restore@1` on
`TGT-958780b2ffb7` (r2) was refused at admission, and the protected recovery
invocation (`debug-070a56fb…`) refused the same pinned request before dispatch
with the durable reason
`non-overridable recovery blocker: completeOverwriteRecovery.sharedFourHourBudgetExpired`.

`RuntimeRecoveryService.completeOverwriteAdmission` had found the two
2026-09-07 unresolved destructive intents (`job-bf0b748e…`, `job-c9274a31…`),
confirmed the request covers every effect they could have had, found no later
successful complete flash to recognise, and then applied the automation
invocation's four-hour clock from the first unknown intent. Nothing published
can move that: `job reconcile` keeps both unknown for want of a complete-plan
receipt (`arkforged`'s own journals show the first Job never wrote and the
second wrote through `DEVICE_RESET` without a terminal), and the only
supersession the engine recognises is a later complete flash the same clock
refuses. Record: `docs/design/references/single-v1/svc-acceptance-2026-09-09-published-main.md`
§GJ-4.

## The change

- `RuntimeRecoveryService` takes `hardwareAcceptanceCampaign` (empty is
  `nil`). In `completeOverwriteAdmission`, after `historicalRecovery` and
  before the shared sixteen-epoch bound, an expired four-hour budget refuses
  as before **unless** a campaign is bound; then the recovery is admitted and
  the result carries `campaignAuthorizedBeyondBudget`. Coverage,
  `explicitCancellationPending`, torn journals, unbounded intents and
  `sharedEpochBudgetExhausted` refuse exactly as before, campaign or not.
- `ArkForgeLane` gains `hardwareAcceptanceCampaign` (default `nil`);
  `ArkForgeLaneHost` answers the campaign its authority support was composed
  with, so the only way to set it is `runtime service update
  --arkforge-campaign`, the DEC-014 window.
- `RuntimeJobEngine` passes the lane's campaign to both admission sites (the
  admission itself and the pre-mutation live re-check, which must agree) and
  writes `complete-overwrite recovery admitted after the shared four-hour
  budget under hardware acceptance campaign <name>` into the Job timeline.
  No durable shape changes: `RuntimeCompleteOverwriteRecoveryContext`, the
  epoch store and the capability lineage are untouched; the campaign is
  already sealed into the plan digest by `arkforged`.

## Verification

- `CompleteOverwriteRecoveryContractTests.testANamedHardwareAcceptanceCampaignAdmitsRecoveryAfterTheSharedFourHourBudget`:
  two days after the unknown, no campaign and an empty campaign still refuse
  `sharedFourHourBudgetExpired`; a named campaign admits a recovery context
  covering exactly the stale intent at epoch ordinal 2 with the unchanged
  covered-effect set and reports the campaign; inside the budget the campaign
  leaves no mark; under a campaign incomplete coverage and the seventeenth
  epoch refuse as before. The existing negative matrix (including the
  no-campaign expiry case) is unchanged.
- `ArkForgeFlashSessionContractTests.testTheLaneExposesItsHardwareAcceptanceCampaignOnlyWhenBound`.
- Unified gate `python3 scripts/ci/plan.py --run-local` on the branch — see
  the pull request.

## What happens next

After this merges the helper pair is rebuilt from `main`, the campaign window
is opened as runbook §5 says, and GJ-4 runs; its result is recorded under
`TASK-SVC-005`, not here.
