# TASK-XPA-014 — GJ-3's fake-HDC rehearsal on the isolated Rust daemon (macOS, 2026-09-20)

> **Fake-HDC rehearsal. No device was involved, and this is neither device evidence nor
> `REAL_DEVICE_PASS`.** GJ-3's real-device leg has not run: it needs the installed LaunchAgent
> stopped for the window, which this session is not permitted to do, as GJ-2's record states.

TASK-XPA-014 remains in progress. Base: protected main `7c10f9f3c` (#2086). Documentation only: no Rust,
Swift, fixture, schema, Catalog, entitlement, `openspec/specs` or constitution change. No installed
state was written, and the installed daemon kept running throughout.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (TASK-XPA-014) |
| --- | --- | --- |
| The development mutation authority (#2078); GJ-2's fake rehearsal (#2081); the bundled code-sign helper composed and verified (#2088) | The rehearsal those make possible: `deploy.native-library.app-owned@1` deployed and rolled back on a real isolated daemon over the oracle's fake HDC | GJ-2 and GJ-3 on the real device (runbook §3, §4); debug.hap slice F; M5 activation |

## What ran

The native-library oracle's `deployed` and `loaderFailure` cases
(`rust/tests/fixtures/deploy-native-library`), submitted through the Rust CLI to a real
`arkdeck-agentd` over its socket, in an isolated development root seeded with the oracle's Target
document (`TGT-3ba3f5f43b92`, revision 1) and its library input
(`artifacts/job-input-native-library`). The daemon's environment named the isolated root, its
endpoint, the rehearsal HDC as its managed server, `ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY` and
`ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER`, the last naming the helper at the path the oracle's argv
names so that the staged bytes and their facts are the recorded ones.

| Case | This daemon | Swift's recording |
| --- | --- | --- |
| `deployed`: submit, run, result, evidence, artifact list | `succeeded`, evidence `verified`, no blockers. Step kinds `sendFile`, `runApprovedRemoteRead`, `runApprovedRemoteMutation`, `stopApplication`, `startApplication`, `verifyRemoteState`, `cleanupOwnedRemotePath`. Artifacts `verification-report.json` and `publish-report.json`, nothing missing, cleanup `[]` | the same state, status, step kinds in the same order, the same two Artifacts, and the same result and evidence shape |
| `loaderFailure`: the rollback the loader forces | `failed`, `artifactIntegrityFailed`, blockers `["artifactIntegrityFailed"]`, the same seven step kinds, `publish-report.json` published and `verification-report.json` missing | the same state, status, blockers, step kinds and Artifacts |
| `capability list` after both | one capability, effect ceiling `deviceMutation`, consumed twice, its two uses ordinal 1 and 2 in the two Jobs' evidence | the oracle's two capability reads record the same ceiling and consumption |

The fake's calls agree with the oracle's recorded stream call for call, apart from the library's
host path: the oracle read it under its own root and this owner reads it under the isolated root,
which is also why the materialized plan digest differs, as #2088's record states.

## The rig, and one mechanical fact

The rehearsal HDC is the scratch-only executable GJ-2's rehearsal built (#2081): the managed-HDC
fixture's source with every non-server command `execv`'d into the oracle's own driver. Nothing in
the fixtures changed.

Setting the fake's mode means clearing its application state first
(`device-installed`, `device-running`, `device-published`), as the oracle's own harness does
(`tests/support/hdc_oracle.rs`). A rehearsal that only writes `hdc-mode` leaves the previous case's
device state behind, and the rollback case then fails three steps earlier than Swift recorded, at
the backup rather than after the publish. That is the rig, not the runner: with the state cleared,
every answer matches.

## CI of #2088

The PR's CI (`guard` + `swift`) is the unified gate. #2088, head `67ca1402d`: SDD Guard run
35499027215 success, and Swift CI run 35499027362 success, with `plan`, the Rust host-independent checks and the
Rust workspace on macOS 26, Ubuntu and Windows green and the Swift, design-system and App lanes
skipped by the planner.

## Not run

The real device, any flash, and any write to installed state. GJ-3's real-device leg needs the same
window GJ-2's does, and the same one command this session is not permitted to run.
