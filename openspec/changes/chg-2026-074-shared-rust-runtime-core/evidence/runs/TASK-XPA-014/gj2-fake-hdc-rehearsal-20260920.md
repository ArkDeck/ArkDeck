# TASK-XPA-014 — GJ-2's fake-HDC rehearsal on the isolated Rust daemon (macOS, 2026-09-20)

> **Fake-HDC rehearsal. No device was involved, and this is neither device evidence nor
> `REAL_DEVICE_PASS`.** The real-device leg of GJ-2 has not run: it needs the installed LaunchAgent
> stopped for the window, which this session is not permitted to do (see "What has not run").

TASK-XPA-014 remains in progress. Base: protected main `645f21ef` (#2076). Documentation only: no
Rust, Swift, fixture, schema, Catalog, entitlement, `openspec/specs` or constitution change. No
installed state was written, and the installed daemon kept running throughout.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (TASK-XPA-014) |
| --- | --- | --- |
| The development mutation authority (#2078), acknowledged beside the managed development HDC | The rehearsal it makes possible: a `debug.hap@1` device mutation admitted, run and evidenced on a real isolated daemon over the oracle's fake HDC | GJ-2 on the real device (runbook §3), GJ-3 (runbook §4); debug.hap slice F; M5 activation |

## What ran

The debug.hap oracle's `installed` case (`rust/tests/fixtures/debug-hap`), submitted through the
Rust CLI to a real `arkdeck-agentd` over its socket, in an isolated development root seeded with

- the oracle's Target document (`targets-state/targets.json`, `TGT-3ba3f5f43b92`, revision 1), and
- the oracle's HAP inputs (`artifacts/job-input-hap`, the two stub payloads and their index),

with the daemon's environment naming exactly the isolated root, its endpoint, the rehearsal HDC,
`ARKDECK_DEVELOPMENT_HDC_SERVER=managed`, `OHOS_HDC_SERVER_PORT=18710` and
`ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY=acknowledged`. Without that acknowledgment the same run is
refused before admission, which is what #2078 changed.

| Command | Answer |
| --- | --- |
| `job submit --request-file <the oracle's request>` | exit 0, `job-5c146e0b3c72c2d2b812c1ca0a07eb70`, the identity Swift's own submission has, since it is derived from the request |
| `job run --job …` | exit 0 |
| `job result --job …` | `succeeded`, `terminal` true, `outcomeUnknown` false, `cleanup` `[]` |
| `job evidence --job …` | `deviceMutation`, `blockers` `[]`, `executionMode` `execute`, binding revision 1, Catalog digest `508783ac…`, and the ten step kinds in Swift's order: `probeDevice`, `runApprovedRemoteRead`, `sendFile`, `installPackage`, `startApplication`, `verifyRemoteState`, `captureRemoteStdout`, `stopApplication`, `uninstallPackage`, `cleanupOwnedRemotePath` |
| `artifact list --job …` | 3 published: `install-readback.json` 673 B, `process-readback.json` 476 B, `debug-hilog.txt` 28 B |
| `capability list` | one capability, effect ceiling `deviceMutation`, `consumptionCount` 1, 9 999 of 10 000 uses left, lineage not blocked |

Compared with the oracle's recorded answers to the same three methods, every result has Swift's
shape, the same terminal state, the same step kinds in the same order, the same effect and the same
authority artifact digest (`2aecbe30…`). The listing's order follows each owner's own clock, as the
corpus replay already treats it.

## The rehearsal HDC, and why it exists

No committed fake both serves the managed HDC server and answers device commands: the oracle's
driver answers device commands only, and the managed-HDC fake
(`rust/tests/fixtures/managed-hdc/fake-hdc.c`) serves the server only. The rehearsal therefore used
a scratch-only executable, built from that fixture's source with one addition: anything that is not
`-m` or `checkserver` is `execv`'d into the oracle's own driver. It is not committed, and no
fixture changed.

Two mechanical facts came out of building it, both worth keeping:

- The managed server's identity proof binds the launch to the executable the daemon started. A
  shell wrapper that `exec`s a different binary for `-m` fails with "managed HDC launch could not
  be bound to its live process identity", so the server and the device answers must come from one
  executable.
- The managed server's child environment is the runner's minimal one, so a wrapper cannot rely on
  `dirname` or any other command from a login `PATH`: an absolute path is required, and without one
  the server exits 126.

## What has not run

The real-device leg. Everything for that window is prepared and verified:

- the material is the recorded GJ-2 package, `entry-default-signed.hap`, SHA-256
  `ee08314929e2ecb8347414e64e1afacb1d22b0c04e5a22664de8410d4b2c4ba6`, the same bytes as the
  2026-08-05 run, with bundle `com.example.waterflowdemo` and ability `EntryAbility`;
- the DAYU200 is attached and answers `list targets -v` through the installed server, and its
  IOKit relation was written for the isolated owner's development relation source: the same
  attachment and location as 2026-09-19, whose serial hashes to `TGT-958780b2ffb7`;
- the driver follows the 2026-09-19 GJ-1 window: read the installed side, stop its LaunchAgent,
  serve the isolated daemon on the default endpoint, adopt, import the HAP, run `debug.hap@1`,
  read the result, evidence and Artifacts, then start the LaunchAgent again and read the installed
  side back.

The window needs `launchctl bootout gui/<uid>/com.arkdeck.agentd`, as GJ-1's did, because the
installed HDC server holds the device's HDC interface exclusively and the 3.2.0f identity family is
published only for `127.0.0.1:8710`. This session is not permitted to stop that agent, so the leg
stops here rather than being worked around. It needs the user's own approval for that one command,
after which the prepared driver runs the whole window unattended and its record follows.

## CI of #2078

The PR's CI (`guard` + `swift`) is the unified gate. #2078, head `d2f2cc0d`, merged
2026-09-20T07:38:01Z: SDD Guard run 35496845427 and Swift CI run 35496845577, both success, with
`plan`, the Rust host-independent checks and the Rust workspace on macOS 26, Ubuntu and Windows
green and the Swift, design-system and App lanes skipped by the planner.
