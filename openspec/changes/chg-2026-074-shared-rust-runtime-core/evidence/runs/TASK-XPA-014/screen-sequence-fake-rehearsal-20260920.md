# TASK-XPA-014 — `capture.screen-sequence@1` rehearsed over the fake HDC (macOS, 2026-09-20)

> **Fake-HDC rehearsal. No device was involved, and this is neither device evidence nor
> `REAL_DEVICE_PASS`.**

TASK-XPA-014 remains in progress. Base: protected main `486f9139e` (#2090). Documentation only: no Rust,
Swift, fixture, schema, Catalog, entitlement, `openspec/specs` or constitution change. No installed
state was written, and the installed daemon kept running throughout.

## What ran

The screen-sequence oracle's eight submissions and seven runs
(`rust/tests/fixtures/screen-sequence`), each submitted and read through the Rust CLI against a
real `arkdeck-agentd`: an isolated development root seeded with the oracle's Target document, the
scratch rehearsal HDC started as the owner's managed server, and
`ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY=acknowledged` (#2078). The fake answered each run in the
mode the oracle names, with its application state cleared first.

| Case | This daemon | Swift's recording |
| --- | --- | --- |
| `captured`, `scaled`, `gap` | `succeeded`, evidence `verified`, each publishing `frames.tar` and `sequence.json` | the same state, status, step kinds in the same order and the same two Artifacts |
| `lowStorage`, `emptyArchive` | `failed`, `artifactIntegrityFailed`, no Artifacts | the same |
| `residue` | `failed`, `artifactIntegrityFailed`, `frames.tar` published and the rest not | the same |
| `missingArchive` | `waitingForRecovery` | the same |
| `afterUnknown` | refused at submission: `admissionDenied`, phase `preAdmission`, zero dispatch, the lineage-blocked message | the same code, phase, dispatch count and message |
| Capabilities after the runs | three, each with a `deviceMutation` ceiling, consumed four, one and one times | the oracle's capability reads record the same ceilings and uses |

Every recorded answer this rehearsal replays — eight submissions, seven runs, and each Job's
result, evidence and Artifact listing — has Swift's shape and its values. The fake received 84
calls, the number the oracle's own invocation log records. The only difference is the CLI's
envelope on a refusal, as the port-forward rehearsal's record describes.

## The rig

The scratch-only rehearsal HDC of #2081, unchanged. Nothing in the fixtures changed, and the
isolated root was removed after the run.

## Not run

Any device, real HDC or installed Runtime.
