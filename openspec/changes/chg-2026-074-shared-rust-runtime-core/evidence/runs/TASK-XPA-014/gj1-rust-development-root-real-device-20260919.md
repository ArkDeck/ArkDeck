# TASK-XPA-014 — GJ-1 on the isolated Rust daemon against the real DAYU200 (macOS, 2026-09-19)

> **Development-root real-device evidence. This is not `REAL_DEVICE_PASS`.**
>
> - **Where it ran:** an isolated development root (`ARKDECK_DEVELOPMENT_STATE_ROOT`).
> - **USB relations:** the development relation source (`ARKDECK_DEVELOPMENT_USB_RELATIONS`, #1988), a
>   caller-written file.
> - **HDC:** the registered HDC, started by the owner as its managed server (#2004).
> - **Opt-in:** `ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC=acknowledged`, added by #2023,
>   admits the relation file beside that server.
> - **Authority:** the maintainer's decision of 2026-09-19 (lvye): option A of blockers 2 and 3 in
>   `gj1-pure-rust-preflight-20260919.md` (#1994).
> - **Dashboard:** "GJ on Rust" stays **0/5** (hard rule A4: isolated-root results are not acceptance).

TASK-XPA-014 remains in progress. Recorded on protected main `f2bf0047`. The scope is the headless
runbook §0, §1 and §2, without §2.1. §2.1 is the HAR crash-resume and its restart carry-over, which
this task leaves out. Only read-only operations ran:

- `observe.device@1`;
- `capture.diagnostics@1` with `{ "durationSeconds": 5 }`: the default legs, `readOnly`.

Nothing else was done:

- no flash, deviceMutation or capability;
- no Runtime authority record written;
- no installed state directory changed.

The only change to the installed Runtime was stopping its LaunchAgent for about three minutes and
starting it again.

## Result

| Runbook §2 criterion | Observed | Holds |
| --- | --- | --- |
| `observe.device@1`: `terminalState == succeeded`, `outcomeUnknown == false`, `blockers == []` | succeeded, false, `[]` | yes |
| its 3 Artifacts all readable through `artifact read`, digest-verified | `binding-snapshot.json`, `device-facts.json` and `tool-facts.json` read in full; the SHA-256 of the bytes equals both `artifactDigest` and the listing | yes |
| `capture.diagnostics@1`: `succeeded`, `outcomeUnknown == false` | succeeded, false, `blockers == []` | yes |
| HiLog and UI Dump present, non-empty, digest-verified | `hilog.txt` 711,706 B and `ui-dump.json` 1,489 B | yes |
| capture summary `complete`, `missingRequired == []` | `complete`, `[]` | yes |
| both Jobs readable after a daemon restart | yes, after the isolated daemon's own process restart | yes, as the isolated equivalent |

On the restart row:

- the Rust CLI has no `runtime service restart`;
- the service leaves act on the installed LaunchAgent.

The §1 preflight is not clean:

- `doctor --deep --require-healthy` exits 69;
- `runtime hdc status` answers `unknown`.

Both come from the HDC identity observation timing out in the debug build (Difference 1).

**GJ-1 on Rust stays `IMPLEMENTING`.** It is neither `REAL_DEVICE_PASS` nor
`BLOCKED_BY_PRODUCT_DEFECT`. No step needed a bypass, and every GJ-1 operation ran through published
typed commands. What remains for M1 is below.

## Setup

- **Binaries.** Built from `fe0472df` in the debug profile. `fe0472df` is #2023 on main `9c58e484`,
  before #2023 was rebased. `git diff fe0472df aba996f8 -- rust/crates rust/Cargo.toml rust/Cargo.lock`
  is empty, where `aba996f8` is #2023's head. The binaries' SHA-256 values:
  - `arkdeck-agentd`: `11fca1de39121382f914d04c433e6d877ca703cd51449681690e8b58a1854ab7`;
  - `arkdeck`: `eec22e3fb26089dd908fee7a349dabd69ef0cb77122a1add7b90bb04dc2bc340`.
  The Rust CLI has no `--version`, so the CLI's build identity is recorded as its SHA-256.
- **The development HDC: the installed Runtime's registered HDC, read with the installed CLI.**
  - `runtime tool list`: kind `hdc`, `toolRef` `tool:sha256:adcf3a3c…`, executable SHA-256
    `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`, version `3.2.0f`, source
    `registeredCopy`, ad-hoc signed with no team identifier.
  - `runtime hdc status`: the path, which is the Runtime's own copy at
    `~/Library/Application Support/ArkDeck/Bootstrap/v1/tool-adcf3a3c….hdc/hdc`.
  - The daemon was given that path and ran it in place. Nothing under the installed state was
    written.
- **Managed server.** `ARKDECK_DEVELOPMENT_HDC_SERVER=managed` on the default endpoint
  `127.0.0.1:8710` (no `OHOS_HDC_SERVER_PORT`; see the window).
  - `checkserver` at startup: client and server `3.2.0f`.
  - The daemon served 6.6 s and 6.3 s after its two starts.
  - The server's child environment is the runner's minimal one (`PATH`, `LANG`, `LC_ALL`). With no
    `TMPDIR`, its pid file is not the installed server's `$TMPDIR/.HDCServer.pid`.
- **Isolated root.** `/private/tmp/xpa014-gj1-20260919/real-full-root`, mode `0700`, outside the
  installed state. The endpoint is `<root>/control.sock`. The daemon environment named exactly these
  variables:
  - `ARKDECK_DEVELOPMENT_STATE_ROOT`;
  - `ARKDECK_ENDPOINT`;
  - `ARKDECK_DEVELOPMENT_HDC_PATH`;
  - `ARKDECK_DEVELOPMENT_HDC_SERVER`;
  - `ARKDECK_DEVELOPMENT_USB_RELATIONS`;
  - `ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC`.
- **Relation file.** Caller-written, mode `0600`, one relation. Its format is
  `agentd/src/development_usb.rs`'s. It was read from IOKit (`ioreg -r -c IOUSBHostDevice -l -a`)
  the way Swift's `RockchipProductUSBProbe.systemIdentities()` and
  `TargetUSBRelation.registeredDAYU200()` read it:
  - the device: `IOUSBHostDevice` with `idVendor` 0x2207 (8711), `idProduct` 0x5000 (20480) and product
    name "HDC Device";
  - `serial` is the "USB Serial Number". It is not recorded here. Its SHA-256 begins `958780b2ffb7`,
    the Target ID;
  - `location` is the decimal `locationID`, `2097152` (0x00200000);
  - `attachmentId` is the `IORegistryEntryID`, `4295391595`.

  It was written before the probe and written again after the bootout, with the same attachment.
- **Outputs.** Every CLI stdout went to `/private/tmp/arkdeck-gj-headless-20260919-rust/{fake-full,
  real-probe,real-full}/gj1-<step>.json`, local only, as runbook §0 has it. The connect key is replaced
  by `<connect-key>` in the kept files. Artifact bytes were read in full, verified in memory and not
  kept. The driver script is in the session scratchpad and not committed.

## The window (UTC, 2026-09-19)

| Time | Step |
| --- | --- |
| 12:32:56–12:33:02 | Rehearsal against the fake HDC (next section). |
| 12:33:54 | The installed side was read with the installed CLI (below the table). |
| 12:35:31–12:35:55 | Probe on port 18710 with the installed agent still running (below the table). |
| 12:38:07 | `launchctl bootout gui/$UID/com.arkdeck.agentd` exited 0. Within 4 s the facade, the Swift daemon and its HDC server were gone and 8710 was free. Two HDC client processes of the same tool had started at the moment of the bootout and were reparented to launchd. They exited by themselves about a second later. IOKit then showed no exclusive owner on the HDC interface. |
| 12:39:23–12:40:51 | The full run, on the default endpoint (below). |
| 12:40:59 | `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.arkdeck.agentd.plist` exited 0 (the path is `launchctl print`'s `path`). The agent ran as pid 10299 with the same program. Read back below. |

**The installed side at 12:33:54.** The LaunchAgent `com.arkdeck.agentd` was running as pid 3915.
Its program was `…/Helpers/ArkDeckAgent.app/Contents/MacOS/arkdeck-facade`: the 09-10 XPA-003 r8 pair,
facade `f6c3dbf8…` and paired Swift `3b79288a…`.

- `runtime service status`: Catalog digest `508783ac…`, contract `8a662759…`.
- `runtime hdc status`: `available`, `hdc.identityObserved`, `arkDeckManaged` on `127.0.0.1:8710`.
- IOKit named the HDC server's pid as the `UsbExclusiveOwner` of the DAYU200's "HDC Interface".
- No Job was in a blocking state, and none was queued, running or finalizing. Of 61 agent executions,
  56 were completed and 5 failed.

**The probe (12:35:31–12:35:55).** The isolated daemon's managed server was on the free port
`127.0.0.1:18710` (`OHOS_HDC_SERVER_PORT=18710`), with the relations acknowledged. The server started,
with startup versions `3.2.0f`/`3.2.0f`. Both checks then found no device:

- `device candidates` answered no observations;
- the maintainer-named check `hdc -s 127.0.0.1:18710 list targets -v` answered `[Empty]`.

So two host servers cannot see the device at once. `runtime hdc status` answered `unavailable` with
`hdc.identityFamilyUnavailable`. The 3.2.0f commandless identity family is published only for
`127.0.0.1:8710`, as Swift selects it (`CommandlessIdentity::family`). The daemon stopped with exit 0.

**Why the default endpoint after the bootout.** The separate port served only to let the two servers
run side by side. Once the installed agent was stopped, `127.0.0.1:8710` was free. Only there does the
registered 3.2.0f HDC have its identity family, as it has for the installed daemon.

**The installed side after the bootstrap**, read with the installed CLI:

- `runtime hdc status`: `available`, `hdc.identityObserved`, `arkDeckManaged` on `127.0.0.1:8710`, at
  the first read, 3 s after the bootstrap;
- `runtime service status`: Catalog `508783ac…`;
- `device candidates`: the DAYU200 `Connected`, adopted as `TGT-958780b2ffb7` at binding revision 2,
  unchanged.

The installed agent was down for 2 min 52 s. No Job was submitted to the installed Runtime, and no
installed state directory, Runtime record or credential was written.

## Rehearsal against the fake HDC (runbook step 1)

The same binaries and driver ran against an isolated root with the oracle fake:

- `rust/tests/fixtures/target-adoption`'s answers of `ArkDeckFakeHDCFixture`, installed under
  `HDCOracleFake`'s lock;
- a fixture HDC, not a managed server;
- one development relation for the fake's device.

Every §1 and §2 command answered as in the real run below, with these exceptions:

- the fixture is no managed server, so `doctor --deep --require-healthy` exits 69 on its only blocker,
  `hdc.notConfigured`;
- `runtime hdc status` answers `unavailable` with `hdc.notConfigured`;
- the availability tool leg is `absent`.

The Journey itself passed on the fake:

- `TGT-3ba3f5f43b92` was adopted at revision 1;
- `gj1-fake-20260919` (`job-e395e547…`) and `-capture` (`job-53b0fb58…`) succeeded, verified;
- 3 + 6 published Artifacts were read and digest-verified;
- the capture summary was `complete`;
- both Jobs read back after a process restart;
- the fake received 15 calls.

`rust/scripts/check-corpus-replay.py --fixture rust/tests/fixtures/agent-execution` already replays the
agent runs themselves at T1 and was not changed.

## Commands and answers, compared with Swift

Swift references:

- the facade records `docs/design/references/single-v1/gj-headless-rerun-2026-09-09-xpa003.json`
  (observe and capture Jobs) and `…-2026-09-10-xpa003.json` (the GJ-1 HAR Job and its three Artifacts);
- the installed Swift daemon, read in this window;
- the Swift oracles under `rust/tests/fixtures` for the answer shapes.

The 09-09/10 raw outputs were local and are gone. So the shape of each answer is compared with the
oracle's answer to the same method. "Members" counts every member path of the result, with the items
of a list merged, and gives Rust / Swift.

| Runbook command | Rust daemon, real device | Swift | T1 |
| --- | --- | --- | --- |
| `arkdeck --version` | exit 64 `invalidOption`: no such leaf in the Rust CLI | `buildIdentity` `sha256:34b3534c…` (09-10) | CLI gap |
| `doctor --deep --require-healthy` | exit 69 `healthRequirementFailed`. Report `blocked`: 1 blocker `hdc.identityUnavailable` (from `hdc.identityObservationTimedOut`); warnings `catalog.unavailableOperations` (28 of 30) and `storage.sessionOutputOwnerUnavailable`; `checks.catalog.digest` `508783ac…` | not recorded on 09-09/10 | Differences 1 and 5 |
| `runtime service status` | exit 64 `invalidCommand`: no Rust leaf; it reads the installed LaunchAgent | read from the installed Swift above | skipped |
| `runtime hdc status` | ok. `unknown`, `hdc.identityObservationTimedOut`, ownership `unknown`. Executable `05b2bf7a…`, client `3.2.0f`, endpoint `127.0.0.1:8710` (`default`), startup `3.2.0f`/`3.2.0f`, `daemonVersion` null, `newDispatchCount` 0 | installed: `available`, `hdc.identityObserved`, `arkDeckManaged`, `daemonVersion` `0.1.0` | the answer is Swift's for a timed-out observation: `hdc-status` oracle case `13-timed-out` has the same availability, reason, ownership and members. The timeout is Difference 1. A null `daemonVersion` for the bare binary is R2's declared difference |
| `runtime tool list` | ok, 0 items | installed: 2 (hdc, deveco) | isolated root: the development HDC is named by the environment, not registered in its store |
| `operation list` | ok. 30 operations, the same references as the installed Swift. 2 available (`observe.device@1`, `capture.diagnostics@1`), 28 unavailable | installed: 28 available, 2 unavailable | the isolated composition. Neither CLI's `operation list` carries `catalogDigest`, though runbook §0 reads `result.catalogDigest` there. The digest was read from `doctor`, `agent run` and `job evidence`: `508783ac…` everywhere, equal to the installed Runtime's |
| `runtime bundle list` | ok, 0 items | — | isolated root |
| `device candidates` | ok. One observation: `Connected`, `relationProven`, not adopted, snapshot generation 1 | oracle `observe` | members 15/15 |
| `target adopt --candidate <key> --observation <obs> --observation-generation 1` | ok. `adopted`, `TGT-958780b2ffb7`, binding revision 1 | installed Target: the same ID, revision 2 | members 5/5; Difference 3 |
| `target show --target TGT-958780b2ffb7` | binding revision 1, before the runs and after them | installed: 2 | Difference 3 |
| `target availability` | Binding `ready`, revision 1, tool version `3.2.0f`. Tool `ready` (`05b2bf7a…`, `3.2.0f`/`3.2.0f`, `default`). Presence `unresolved` (`device_observation_unavailable`). Observe and capture `available` | oracle `availability`: the same presence answer, tool `ready` | members 34/34 |
| `agent run --operation observe.device@1 --target … --execution-id gj1-rust-20260919 --maximum-wait 5m` | exit 0. `completed`, Job `succeeded`, evidence `verified`, next action `readResult` | Swift's completed `agent.status` (oracle `observed.status`): the same four values | members 98/98 against Swift's completed status. Swift's oracle `agent.run` exchange recorded the accepted, still-running answer |
| `agent status --execution-id gj1-rust-20260919` | `completed` / `succeeded` | the same | 98/98 |
| `job result --job job-cfc97723145d5102291242b893f520a3` | 3 Artifacts, evidence `verified` | — | 112/112 |
| `job evidence` (observe) | `succeeded`, `outcomeUnknown` false, blockers `[]`, `readOnly`. Steps `probeHostTool`, `probeHDCServer`, `probeDevice`, `runApprovedRemoteRead`. Authority `defaultReadOnlyPolicy`. Observation `machineReadback`, model `OpenHarmony 3.2`, firmware `OpenHarmony-7.0.0.43` | 09-09 `job-57778758…`: `succeeded`, blockers `[]`, the same four step kinds | 56/56; firmware is Difference 4 |
| `artifact list --job …` (observe) | 3, all `published` | — | 34/34 |
| `artifact read` × 3 (`--allow-sensitive` for the two `sensitive` ones) | read in full and verified. `binding-snapshot.json` 510 B, `device-facts.json` 438 B, `tool-facts.json` 240 B | 09-10 HAR Job: the same names at 510, 438 and 240 B | same names, privacy and byte counts. The digests differ by construction: each embeds its `jobId`, and the binding revision is 1, not 2 |
| `runtime service verify --job …` | exit 64 `invalidCommand` | 09-09/10: served by the installed service | skipped |
| `agent run --operation capture.diagnostics@1 --target … --inputs-file gj1-capture.json --execution-id gj1-rust-20260919-capture --maximum-wait 5m` | exit 0. `completed`, `succeeded`, `verified`, `readResult` | oracle `captured.status`: the same | 98/98 against Swift's completed status |
| `job evidence` (capture) | `succeeded`, `outcomeUnknown` false, blockers `[]`, `readOnly`. Steps `probeDevice`, `runApprovedRemoteRead`, `preflightDeviceStorage`, `captureRemoteStdout`. `missingRequiredArtifacts` `[]` | 09-09 `job-cdb2c302…`: `succeeded`, blockers `[]`, the same four step kinds | 57/57 |
| `artifact list` (capture) | 14 listed: 6 `published` (`capture-summary.json`, `artifact-index.json`, `markers.json`, `capture.log`, `ui-dump.json`, `hilog.txt`) and 8 `missing` placeholders for the legs not selected | the oracle lists the same 14 with the same statuses; 09-09 verified 6 | 32/32 |
| `artifact read` × 6 | all read in full and verified. The capture summary is `complete` with `missingRequired` `[]` | 09-09 GJ-1 capture: 6 verified, `complete`, `[]` | equal |
| `runtime service restart` | exit 64 `invalidCommand` | 09-09/10: typed restart, then readback | replaced by the isolated daemon's process restart (next row) |
| isolated daemon restart, then `job show`, `job result` and `agent status` for both | SIGTERM, exit 0 with `arkdeck-agentd stopped` in 0.02 s, served again 6.3 s later. Both Jobs `succeeded`, evidence `verified`, `outcomeUnknown` false; both executions `completed`. Observe 3 Artifacts, capture 14 | 09-09/10: both Jobs read back after the restart | equal |

The maintainer-named visibility check, `hdc -s 127.0.0.1:8710 list targets -v`, ran once in the full
run. It used the registered client in the dispatcher's minimal environment, and the daemon's managed
server answered one row: `USB`, `Connected`, `localhost`.

Verified Artifacts, full run:

| Job | Artifact | Privacy | Bytes | SHA-256 |
| --- | --- | --- | --- | --- |
| `job-cfc97723145d5102291242b893f520a3` (observe; 12:40:18Z) | `binding-snapshot.json` | sensitive | 510 | `23c3d50e5cfd0c19e22cfd266ffc70ae0027b71ab4ee93057defb2df1475936f` |
| | `device-facts.json` | sensitive | 438 | `91172a6841b09b5bf14e943fe6698627c38bd056a452b63ad5dc4c66a3928e80` |
| | `tool-facts.json` | standard | 240 | `9426762c6877d1be1ba1d70ef3c86968c7d082c4797fe81d0267856e96866dbc` |
| `job-d8261896e94236553f0fb32e9b72c9a8` (capture; 12:40:28–12:40:41Z) | `capture-summary.json` | standard | 2,018 | `a29b0b48fc4ff2a5223afa91c91a1f6e8e49f1f3e15de274808f9b01e389496e` |
| | `artifact-index.json` | standard | 1,957 | `217984df96ee9d0b9fdc8ec0ab2ff624c96e111f82a7c37698a6758d887cd99d` |
| | `markers.json` | standard | 484 | `ef80f6d5b3717cf758a6c0efa722ac4cf90a229bbacb563bf2eaaf495aa50654` |
| | `capture.log` | standard | 2,029 | `3215ea431c73d92f409f163ca49fa872588f7fc3368bd95435a011b6b012bae8` |
| | `ui-dump.json` | sensitive | 1,489 | `c61da1e77a9dfeafe4a65bfe0225e6dbfb790a2ce6537404fade56b3ab6e56e2` |
| | `hilog.txt` | sensitive | 711,706 | `a6b28f3a9653326e3a7808cfe6fcd066a82178f02bafef60653c3cd31c0e11b2` |

## Differences from Swift, and their owners

1. **The HDC identity observation timed out in the debug build.**
   - **Answers affected.** `runtime.hdc.status` and deep `doctor`. The observation has a 1000 ms
     deadline, the same as Swift's `HDCSupervisorObservationProbeCatalog.timeoutMilliseconds`. The
     daemon ran as a debug build.
   - **Measurement.** Afterwards the same observation (`CommandlessIdentity::observe`, over
     `LoopbackServerLease::acquire`) was timed against the installed server on 8710. It is a read-only
     kernel scan, run 5 rounds per build:

     | Build | `VerifiedTool::open` | `acquire` | observation | outcome at 1000 ms | load |
     | --- | --- | --- | --- | --- | --- |
     | release | 13–19 ms | 45–62 ms | 55–66 ms | 5/5 observed | 28–34 |
     | debug | 345–606 ms | 660–800 ms | 986–1,098 ms | 4/5 timed out | 16–27 |

   - **Cause.** Unoptimized SHA-256 of the 6.2 MB tool, done three times per observation: `open`,
     then the two `revalidate` calls in `acquire`. The two process scans take tens of milliseconds.
   - **What it does not affect.** Dispatch: the managed server's start proof has no deadline, and the
     availability tool leg answers the startup facts.
   - **Owner.** TASK-XPA-016, lane B: `agent/xpa-016-sha2-dev-opt-20260919` (`c0bd61aa`,
     `[profile.dev.package.sha2] opt-level = 3`). Its author measured open and the two revalidations
     on a debug build falling from 930–1123 ms to 56–73 ms. That change was not run on the device.
2. **Answers that touch the registered tool are slow (T2, not compared).**
   - **Times.** `operation list` 6.45 s, `operation describe` 7.27 s and 4.00 s, `target availability`
     6.91 s, `target adopt` 4.70 s, `doctor` 5.01 s. The same reads took 0.03–0.08 s with the fake's
     four-line script.
   - **Likely cause.** The same unoptimized hashing of the development HDC, on host load of 20–33
     (a gate was running).
   - **Job times.** The Jobs themselves ran from first evidence step to finish in under 1 s (observe)
     and 13 s (capture, with its 5 s capture). The whole `agent run` took 12.2 s and 20.0 s. The 09-09
     Swift Jobs took 1 s and 8 s from creation to finish.
   - Remeasure after the change in item 1.
3. **Binding revision 1, not 2.** The isolated root adopts afresh. The Target ID is the same
   (`TGT-958780b2ffb7`), since it is derived from the identity.
4. **The firmware string changed on the device.**
   - The Jobs read back `OpenHarmony-7.0.0.43` (`machineReadback` of `const.ohos.fullname`). The task
     statement named `7.0.0.37`.
   - The installed Runtime's own `observe.device@1` evidence read `7.0.0.37` on 09-10 at 00:19Z, after
     that day's full restore, and `7.0.0.42` at 06:47Z.
   - The model is `OpenHarmony 3.2` in all three, and the Catalog digest is unchanged.
   - This is a device fact, not a Runtime difference.
5. **No `--version` and no `runtime service status|verify|restart` in the Rust CLI.** The service leaves
   act on the installed LaunchAgent, so the M5 installed service owns them; `--version` belongs to
   TASK-XPA-018. The restart readback was made on the isolated daemon's process instead.
6. **The capture Session is published after the run answers.**
   - The capture Job's Session read `unavailable` with `noCurrentPublicationRecord` in the `agent run`
     answer and in the `agent status` read at once after it. It read `published`, catalog generation 2,
     in every read after the restart.
   - The observe Session was already `published` in its run answer.
   - Swift's oracle reads `published` in its completed status. Its harness waits for the execution
     record to hold the Job's end before reading. `check-corpus-replay.py` documents that the Rust
     status says `completed` as soon as the Job is terminal, before its Session is published.
   - The 09-09/10 records keep no raw `agent run` answer. So whether Swift's answer can also precede its
     Session publication is not established here.
   - To compare on the next real run (TASK-XPA-014).
7. **The isolated composition, as expected.** 2 of 30 operations are available, and the tool and bundle
   stores are empty. The presence leg answers `unresolved`, as Swift's oracle does without an
   observation source.

## GJ record

The fields of `arkdeck.gj-headless-rerun/1` that apply. It is not a file under
`docs/design/references/`, because it is not acceptance.

```json
{
  "schemaVersion": "arkdeck.gj-headless-rerun/1",
  "date": "2026-09-19",
  "goldenJourney": "GJ-1",
  "state": "IMPLEMENTING",
  "evidenceKind": "development-root-real-device-evidence (isolated root, development USB relation source, maintainer decision 2026-09-19 option A); not REAL_DEVICE_PASS",
  "runbook": "docs/design/cli-golden-journey-headless-runbook.md §§0, 1, 2 (not 2.1)",
  "catalogDigest": "508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684",
  "protectedMainBase": "f2bf0047",
  "runtimeSourceRevision": "fe0472df (PR #2023 before its rebase; rust/crates equal to #2023 head aba996f8), debug profile",
  "runtimeExecutableSHA256": "11fca1de39121382f914d04c433e6d877ca703cd51449681690e8b58a1854ab7",
  "cliBuildIdentity": "sha256:eec22e3fb26089dd908fee7a349dabd69ef0cb77122a1add7b90bb04dc2bc340 (binary digest; the Rust CLI has no --version)",
  "hdcExecutableSHA256": "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83",
  "hdcVersion": "3.2.0f",
  "hdcEndpoint": "127.0.0.1:8710 (default), managed by the isolated owner",
  "targetID": "TGT-958780b2ffb7",
  "bindingRevisionBefore": 1,
  "bindingRevisionAfter": 1,
  "firmware": "OpenHarmony-7.0.0.43",
  "confirmationMethod": "machineReadback",
  "authority": "defaultReadOnlyPolicy",
  "jobs": [
    {
      "jobId": "job-cfc97723145d5102291242b893f520a3",
      "executionID": "gj1-rust-20260919",
      "operationReference": "observe.device@1",
      "state": "succeeded",
      "outcomeUnknown": false,
      "evidenceBlockers": [],
      "verifiedArtifactCount": 3,
      "actualStepKinds": ["probeHostTool", "probeHDCServer", "probeDevice", "runApprovedRemoteRead"],
      "startedAtUTC": "2026-09-19T12:40:18Z",
      "finishedAtUTC": "2026-09-19T12:40:18Z"
    },
    {
      "jobId": "job-d8261896e94236553f0fb32e9b72c9a8",
      "executionID": "gj1-rust-20260919-capture",
      "operationReference": "capture.diagnostics@1",
      "state": "succeeded",
      "outcomeUnknown": false,
      "evidenceBlockers": [],
      "verifiedArtifactCount": 6,
      "actualStepKinds": ["probeDevice", "runApprovedRemoteRead", "preflightDeviceStorage", "captureRemoteStdout"],
      "startedAtUTC": "2026-09-19T12:40:28Z",
      "finishedAtUTC": "2026-09-19T12:40:41Z"
    }
  ],
  "publishedArtifactsReadAndDigestVerified": 9,
  "captureCompleteness": "complete",
  "missingRequired": [],
  "humanActions": [],
  "zeroDispatchChecks": [],
  "restartReadback": "isolated daemon process restart (SIGTERM, exit 0, restart); both Jobs succeeded, verified, outcomeUnknown false; runtime service restart is not in the Rust CLI",
  "discipline": {
    "rawDeviceCommands": 0,
    "hostServerListings": 2,
    "runtimeAuthorityRecordEdits": 0,
    "unknownIntentReplays": 0,
    "bindingRebindOverrides": 0,
    "installedStateWrites": 0,
    "installedLaunchAgentStops": 1
  },
  "remaining": [
    "runbook §2.1 HAR crash-resume and the restart carry-over (design §L.1 item 13, ruled in #2016)",
    "runtime service status/verify/restart and --version on the Rust CLI",
    "runtime.hdc.status and doctor --deep within the identity observation deadline (debug build: lane B sha2 dev-opt)",
    "installed activation of the Rust daemon at M5, then REAL_DEVICE_PASS on the installed Runtime"
  ]
}
```

`hostServerListings` counts the maintainer-named visibility check: once in the probe on 18710 and once in
the full run. It is a listing answered by a host server, not a device command.

## Not run

- Runbook §2.1 (HAR crash-resume), and GJ-2 to GJ-5.
- The `runtime service` leaves, which are not in the Rust CLI.
- A second device window to remeasure with lane B's dev-profile change.
- The installed Runtime's own GJ-1. It was not needed, since its answers for this digest are recorded in
  the 09-09/10 facade records.

## Local targeted checks

This PR is documentation only, so the one targeted check is `check-sdd`:

| Command | Exit | Log SHA-256 |
| --- | --- | --- |
| `ARKDECK_PYTHON=<repo>/.venv-sdd/bin/python sh scripts/check-sdd.sh`: 0 errors, 0 warnings | 0 | `77c17376…` |

The record was also scanned for the device serial and for home-directory paths, and holds neither.

## CI

Recorded after the PR's CI reports (`guard` + `swift`).
