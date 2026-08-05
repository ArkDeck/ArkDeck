# GJ-5 Bounded AI Debug Loop — REAL_DEVICE_PASS on the current catalog digest (2026-08-05)

## Status: `REAL_DEVICE_PASS`

`HTASK-D637AF325AB3` reproduced a crash on a physical DAYU200, decided what
caused it, wrote a patch, checkpointed, applied, built, tested, deployed the
patched build to the same device, and verified the fix across five clean
captures. Twenty-one rounds, twenty-five minutes, no human input after the
submission — no grant issued mid-run, no resume, no manual step of any kind.

Confirmed by a second independent run, `HTASK-57AC733BE4E5`: same terminal
state, same round and mutation counts, the same two-line change reached
through its own decision. Details below.

This supersedes `gj5-current-digest-2026-08-05.md`, which recorded the same
journey as `IMPLEMENTING` on this digest because it had no decision producer.
The r2 window (`run-r2.md`) remains the historical pass on digest `44b6728d…`;
this is the first full-chain pass on the current one, and the first ever with
a model in the loop.

## Scope and target

- Baseline: `main@37b23c80` (includes #1086, #1087, #1088)
- Catalog digest: `e2f8eb6592aaeeec37c63a01708db2325b38c798b0f8272228ba0fccc2cfd0aa`
- Target: `TGT-958780b2ffb7`, binding revision `2`
- Device: DAYU200, OpenHarmony `7.0.0.36`, HDC `3.2.0f`
- Workspace: `WaterFlowLayoutDemo` (`demo-app`), crash probe `ENABLED = true`
- Isolated copy: `evo-e5bbb9cb6946c0c7320e4cff` / `evolution-e5bbb9cb6946c0c7320e`,
  allowed paths `entry/src/main/ets/**`,
  base revision `084dddd2b8626fd7f82e05b4fea639366a44c30791d153a117b22950bc459c24`
- Decision producer: `claude-code-cli-gateway@1`, model `sonnet`, local CLI,
  egress enabled for `demo-app` only
- Budgets: 30 rounds, 8 E1 mutations, 40 model calls, 9000s wall clock

## What the loop did

| UTC | Step |
|---|---|
| 08:21:47 | `taskAdmitted` |
| 08:22:19 | `observe.device@1` succeeded |
| 08:23:09 – 08:24:39 | first capture, crash ledger analyzed, `inconclusive` |
| 08:26:01 | `baselineCrashFixtureDeployed` (`debug.hap@1`, E1 #1) |
| 08:28:01 – 08:30:11 | capture and analysis on the armed build → **`criteriaFailed`** |
| 08:31:12 | `workspace.create-checkpoint@1` succeeded (E1 #2) |
| 08:31:19 | `workspace.apply-patch@1` succeeded (E1 #3) |
| 08:32:36 | `workspace.build-openharmony@1` succeeded (E1 #4) |
| 08:34:38 | `workspace.run-tests@1` succeeded (E1 #5) |
| 08:35:53 | `debug.hap@1` deployed the patched build (E1 #6) |
| 08:37:31 – 08:47:13 | five verification captures, each analyzed |
| 08:47:13 | **`succeeded` / `promotionCandidateReady`** |

Consumed: 21 rounds, 6 E1 mutations of 8, 20 model calls of 40, 1528s of 9000,
6086018 artifact bytes.

The five middle jobs are the first of their kind to run on this host at all.
Before this window the runtime job ledger held 168 jobs and not one
`workspace.apply-patch@1`, `workspace.build-openharmony@1` or
`workspace.run-tests@1` — the legs were unreachable by construction, which is
what #1086/#1087/#1088 fixed.

## The decision the model made

The crash is a deliberate probe the demo carries: `CrashProbe.ets` raises
SIGABRT twelve seconds after launch while `ENABLED` is true. The model read
the verified crash signature and the source, and proposed exactly that flip:

```
--- a/entry/src/main/ets/crashprobe/CrashProbe.ets
+++ b/entry/src/main/ets/crashprobe/CrashProbe.ets
@@ -19,7 +19,7 @@
-export const ENABLED: boolean = true;
+export const ENABLED: boolean = false;
```

- Attempt: `ATTEMPT-650BA685CD53041A`, candidate `candidate-02109b7708f076a8784f6428`
- Diff digest: `cd5b93a323bbc7f689ba11b59b775f5f4d34feb58482c73b1b8d90e48256071f`
- Files: `entry/src/main/ets/crashprobe/CrashProbe.ets`, 2 changed lines
- Created by: `agent`
- Reason code: `selfInflictedDebugProbeArmed` (the model's own)

## Verdict

Final evaluation at round 21, every criterion at its full sample requirement:

| Criterion | Metric | Expected | Observed | Samples | Verdict |
|---|---|---|---|---|---|
| DC-1-crash-signature-absent | `matchingCrashCount` | 0 | 0 | 5/5 | pass |
| DC-2-application-liveness | `applicationLiveness` | healthy | healthy | 5/5 | pass |
| DC-3-no-new-fatal-signature | `newFatalSignatureCount` | 0 | 0 | 5/5 | pass |

The four evaluations before it were `inconclusive:collectMoreEvidence`, and
the one at 08:30:11 was `criteriaFailed` on the armed build. The pass is
sample-backed, not vacuous: the same criteria failed on the same device
seventeen minutes earlier, and the only thing that changed between them is
the patch above.

Crash ledger watermark advanced `20170806…` across the window with
`matchingCrashCount = 0` on every verification sample.

## Second run, independently submitted

`HTASK-57AC733BE4E5`, same command, same digest, same device, nothing carried
over: a fresh isolated copy, a fresh decision, a fresh attempt id.

| | first | second |
|---|---|---|
| Task | `HTASK-D637AF325AB3` | `HTASK-57AC733BE4E5` |
| Terminal | `succeeded` / `promotionCandidateReady` | `succeeded` / `promotionCandidateReady` |
| Rounds | 21 | 21 |
| E1 mutations | 6 | 6 |
| Model calls | 20 | 20 |
| Wall clock | 1528s | 1802s |
| Attempt | `ATTEMPT-650BA685CD53041A` | `ATTEMPT-BC57967A6BA6A560` |
| Candidate | `candidate-02109b7708f076a8784f6428` | `candidate-4a23999eb4f774b2f9287be6` |
| Model reason code | `selfInflictedDebugProbeArmed` | `crashProbeArmed` |
| Criteria | 3/3 pass, 5 samples each | 3/3 pass, 5 samples each |

Both runs reached the same two-line change to the same file through
independent decisions — the reason codes differ because the model named its
own each time. The second run's patch digest is
`4340353577e899c7be659afd34f07c177a2c9d4b5bceb30a11eb2cbd4e3955ee`, the same
diff content the first proposed.

The source tree was untouched throughout: `WaterFlowLayoutDemo` still reads
`export const ENABLED: boolean = true;` and still hashes to
`084dddd2b8626fd7f82e05b4fea639366a44c30791d153a117b22950bc459c24`. Both
repairs happened in their own copies and neither reached it, which is the
isolation invariant holding under a real repair rather than in a test.

## Promotion

`disposition: READY_FOR_NORMAL_PR`. The candidate patch, its diff artifact,
its metadata artifact and the full evidence set are exported by
`arkdeck task promotion --task HTASK-D637AF325AB3`. Nothing left the isolated
copy: the promotion is a pull request a person reviews, which is the only
human step this journey has.

## Reproduce

```
arkdeck task submit \
  --target TGT-958780b2ffb7 \
  --goal "Reproduce and repair the WaterFlow demo launch crash on the adopted DAYU200" \
  --crash-signature "SIGABRT+WaterFlowCrashProbe_RecoverBack" \
  --project demo-app \
  --bundle-name com.example.waterflowdemo --ability-name EntryAbility \
  --process-name com.example.waterflowdemo \
  --baseline-hap-artifact-lease "<baseline HAP lease>" \
  --base-workspace-revision 084dddd2b8626fd7f82e05b4fea639366a44c30791d153a117b22950bc459c24 \
  --workspace-allowed-paths "entry/src/main/ets/**" \
  --build-preset waterflow-debug --test-preset waterflow-tests \
  --expected-binding-revision 2 \
  --max-rounds 30 --max-e1-mutations 8 --max-model-calls 40 --max-wall-clock-seconds 9000
```

Daemon environment: `ARKDECK_HARNESS_MODEL_PROVIDER=claude-code`,
`ARKDECK_HARNESS_MODEL_NAME=sonnet`, `ARKDECK_HARNESS_CLI_PATH=<canonical
versioned CLI directory, not a symlink>`, `ARKDECK_HARNESS_CLI_WORKDIR`,
`ARKDECK_HARNESS_CLI_TIMEOUT_SECONDS=900`,
`ARKDECK_HARNESS_EGRESS_PROJECTS=demo-app`,
`ARKDECK_HARNESS_AUTODRIVE_SECONDS=5`,
`ARKDECK_HARNESS_SENSITIVE_EVIDENCE=crash-index.txt,hilog.txt`.

Two host facts that are easy to get wrong and cost a window each:
`--build-preset`/`--test-preset` must name the profile's own preset ids
(`waterflow-debug`, `waterflow-tests`), not the handler defaults; and
`--workspace-allowed-paths` is what supplies the isolated copy, without which
the repair operations are not in the task's allow-set at all.

## Third run: what the model was actually contributing (#1091)

The first two passes hid a number worth reading. Across their 40 model calls,
**4 answers were accepted**. The loop converged because the deterministic
handler drove every round; the model was, in effect, along for the ride.

36 refusals, and 23 of them were the same shape — the model named the exact
operation the handler had chosen and left `inputs` empty, which is what the
envelope instruction tells it to do ("do not invent operation inputs or copy
context metadata into inputs"). The validator then required the proposal's
inputs to equal the handler's, and the handler's are never empty. The
instruction could not be followed. #1091 made absent inputs mean agreement.

`HTASK-95C045C0ADD9`, first run on `main@84f41bfe`:

| | runs 1–2 (pre-fix) | run 3 (post-fix) |
|---|---|---|
| Model calls | 40 | 20 |
| Accepted | 4 (10%) | **16 (80%)** |
| `operationNotExpected` | 23 | 1 |
| Rounds / E1 / wall clock | 21 / 6 / 1528s, 21 / 6 / 1802s | 21 / 6 / 1493s |
| Criteria | 3/3 pass, 5 samples | 3/3 pass, 5 samples |

The journey is unchanged — same rounds, same mutations, same verdict — which
is the point: an accepted agreement dispatches the handler's step byte for
byte. What changed is that the durable record now carries the model's own
reading of each step. The dispatch log reads
`staleDeploymentPredatesLatestPatch`, `reverifyPostPatchStaleSample`,
`insufficientVerificationSamples` where it used to read the handler's generic
`collectAdditionalSample`.

### The four remaining refusals are correct

- `operationNotOffered:workspace.apply-patch@1` ×3 — the model reaching for
  the patch before the handler has evidence to justify one. The offered set
  is the answer, and it did not include it yet.
- `operationNotExpected:analyzer.extract-crash-signature@1` ×1 — the model
  answered `requestHuman`: it suspected the device was running a stale build
  and wanted a person to confirm before verifying further. That step is one
  the handler orchestrates, so a model may not manufacture a human stop on
  it. It was overruled, the analysis ran, and verification proceeded to a
  pass — the suspicion was wrong.

Neither is a defect, and neither is worth another window. A model that
disagrees about *when* to patch is refused by the offered set; a model that
wants to stop the loop on an orchestrated step is refused by design.

## Sample-taking note

The five verification captures cost ten rounds — a capture and a derived
analysis each — and the run finished at round 21 of 30. A task with a smaller
`--max-rounds` will exhaust the budget in verification rather than in repair,
and the failure will read as `budgetExhausted(rounds)` with a correct patch
already deployed. Nothing is wrong there; it is worth knowing before reading
such a record as a repair failure.
