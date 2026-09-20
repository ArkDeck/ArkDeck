# TASK-XPA-014 — `port-forward.create@1` and `port-forward.remove@1` rehearsed over the fake HDC (macOS, 2026-09-20)

> **Fake-HDC rehearsal. No device was involved, and this is neither device evidence nor
> `REAL_DEVICE_PASS`.**

TASK-XPA-014 remains in progress. Base: protected main `486f9139e` (#2090). Documentation only: no Rust,
Swift, fixture, schema, Catalog, entitlement, `openspec/specs` or constitution change. No installed
state was written, and the installed daemon kept running throughout.

## What ran

The port-forward oracle's nine submissions and eight runs
(`rust/tests/fixtures/port-forward`, recorded by Swift over the shared fake HDC), each submitted
and read through the Rust CLI against a real `arkdeck-agentd`: an isolated development root seeded
with the oracle's Target document, the scratch rehearsal HDC started as the owner's managed server,
and `ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY=acknowledged` (#2078), without which these device
mutations are refused before admission. The fake answered each run in the mode the oracle names,
with its application state cleared first, as the oracle's own harness sets a mode.

| Case | This daemon | Swift's recording |
| --- | --- | --- |
| `createForward`, `removeForward`, `createReverse`, `removeReverse` | `succeeded`, evidence `verified`, each publishing `port-rule-readback.json` | the same state, status, step kinds in the same order and the same Artifact |
| `createRefused`, `removeMissing`, `ruleUnlisted` | `failed`, `artifactIntegrityFailed`, no Artifacts | the same |
| `readbackUnanswered` | `waitingForRecovery`, its result `resultNotReady` | the same |
| `afterUnknown` | refused at submission: `admissionDenied`, phase `preAdmission`, zero dispatch, "automatic Runtime target lineage is blocked: lineageBlocked(…use 1 outcome outcomeUnknown)" | the same code, phase, dispatch count and message |
| Each admitted Job's capability | one per Job, effect ceiling `deviceMutation`, consumed once | the oracle's capability reads record the same ceiling and one use per Job |

Every recorded answer this rehearsal replays — nine submissions, eight runs, and each Job's result,
evidence and Artifact listing — has Swift's shape and its values. The fake received 40 calls, the
number the oracle's own invocation log records.

The one difference is the CLI's envelope: the oracle records the control-plane answer, and the CLI
adds `attentionRequired`, `controlRequestRetryable`, `details.method` and `details.wireCode` to a
refusal it prints. The code, message, phase and dispatch count are the recorded ones.

## The rig

The scratch-only rehearsal HDC of #2081: the managed-HDC fixture's source with every non-server
command `execv`'d into the oracle's own driver, so one executable serves the managed server whose
identity proof reads its launch and answers the fake device. Nothing in the fixtures changed, and
the isolated root was removed after the run.

## Not run

Any device, real HDC or installed Runtime. The real-device legs of GJ-2 and GJ-3 still wait for
the window, as their records state.
