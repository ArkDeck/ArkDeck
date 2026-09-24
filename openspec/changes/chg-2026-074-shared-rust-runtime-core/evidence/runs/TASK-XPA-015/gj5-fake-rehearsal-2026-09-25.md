# GJ-5 fake rehearsal on the isolated Rust daemon (TASK-XPA-015, macOS, 2026-09-25)

> **fake 彩排不是真机验收。** A fake HDC answered for a fake device. No DAYU200, DevEco,
> signer or Keychain item was involved. This is not device evidence and not
> `REAL_DEVICE_PASS`, and no Golden Journey count changes.

Runbook §6 (`docs/design/cli-golden-journey-headless-runbook.md`) was run end to end through
the real Rust `arkdeck` CLI against a real `arkdeck-agentd`. Both were built (debug profile)
from the tree this change pushes, rebased on protected `main` `cc5b5670` (#2151). The daemon
ran in the isolated development root `/private/tmp/xpa015-gj5`:

- `ARKDECK_DEVELOPMENT_HDC_SERVER=managed`, with the rehearsal HDC below on `127.0.0.1:18731`;
- `ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY=acknowledged`;
- `ARKDECK_ANALYZER_PATH` naming the same daemon binary, whose `--analyze-crash-ledger` mode is
  the crash-signature analyzer;
- the HDC fixtures' Target `TGT-3ba3f5f43b92` seeded at binding revision 1.

The installed service kept running and was not touched. Every root was removed after the run.

## The rehearsal HDC and device (scratch only, not committed)

- **One executable.** The server half of `rust/tests/fixtures/managed-hdc/fake-hdc.c`, plus an
  `execv` of a driver script for every device command. This keeps the managed server's identity
  proof bound to the executable the daemon started, as the GJ-2 rehearsal found. The driver
  uses absolute paths only.
- **The driver.** It merges the committed drivers' answers (debug-hap, capture-diagnostics read
  and file legs, pointer-input, debug-probe) for one stateful fake device: the probe installed,
  its process running, its Faultlogger entries, and the Runtime-owned remote paths.
- **The crash window.** The harness stands in for the probe's 12 s crash window: it ends the
  process and adds exactly one Faultlogger entry, as a crash does.
- **Every device call answered.** The device recorded 54 calls, none of them unregistered.

## Legs

| Runbook §6 leg | Through | Answer |
|---|---|---|
| Baseline (for the crash-index delta) | `agent run capture.diagnostics@1` (`crashLogs`, `bundleName`) | Crash index: 1 unrelated entry. Liveness `UNHEALTHY` (probe not yet installed) |
| `artifact import hap --target <TGT>` | CLI | Committed. `lease-v1:imp-…`, container `zip` |
| Repro: `agent run debug.hap@1` with `gj5-repro.json` (`retain`, `running`, `captureDiagnostics`, 20 s) | CLI | `succeeded`, `deviceMutation`. Eight step kinds (`probeDevice` … `captureRemoteStdout`, `cleanupOwnedRemotePath`, no stop or uninstall, as asked). `install-readback.json`, `process-readback.json` and `debug-hilog.txt` published |
| `job evidence`, `artifact list/read` | CLI | As above |
| Capture after the crash window | `agent run capture.diagnostics@1` | Liveness `UNHEALTHY` / `STOPPED` / `targetProcessNotRunning`. Crash index 2 entries, exactly one new (`cppcrash-com.example.gj5probe-20010041-20260925000012`) |
| Analyze | `job submit` + `job run` (see Defect 1) | `succeeded`. `crash-signature.json` status `answered` with both entries |
| `workspace project register/list`, `workspace preset list` | CLI; the daemon restarted to compose the project | Registered. Project list and preset list (empty) answered |
| Isolate | `job submit` + `job run` (see Defect 2) | `succeeded`. `isolated-workspace.json` names the copy `evolution-…`. Its `workspaceRevision` equals `sourceWorkspaceRevision`, which equals the revision the harness computed by the runbook's algorithm (`49acef85…`) |
| `artifact import workspace-patch --target <TGT>` | CLI | Committed |
| Patch the copy | `job submit --target <TGT>` + `job run`, the copy's projectRef and revision | `succeeded`, `outcomeUnknown` false. `applied-patch.json`: `previousWorkspaceRevision` `49acef85…` → `workspaceRevision` `0f431950…`, `touchedFiles` `entry/src/main/ets/pages/Index.ets`. The registered primary tree is unchanged |
| Negative: the same patch lease against the superseded revision | `job submit` | `invalidInput`: `typed plan preflight failed before authorization: workspace.revisionConflict:49acef858fbb!=0f4319500f93`, `newDispatchCount` 0, `phase` `preAdmission`. The complete Job set is the same six Jobs before and after |
| Build | — | **Blocked**; see "Build and sign" |
| Sign, then `artifact export` of the signed HAP and its re-import | — | **Blocked**; see "Build and sign" |
| Verify: `agent run debug.hap@1` again, then a capture | CLI | Run with the imported probe itself, not the chain's signed HAP, which cannot be produced here. `succeeded`. `install-readback.json` pins the deployed bytes to the imported HAP's SHA-256 (`3fbecb36…`). Liveness `HEALTHY` / `RUNNING` / `targetProcessRunning`. Crash index 2 entries, the same as after the repro |
| `debug.template@1` | `debug template list` + `agent run` of all four templates | All four `succeeded`, each publishing its output and report |
| `input.tap@1`, `input.long-press@1`, `input.swipe@1` | `agent run` | All three Jobs `succeeded`, but `agent run` answered `internalError` (see Defect 2) |

**Capabilities.** Five Runtime capabilities, all `deviceMutation`, none lineage-blocked:

- the debug HAP's: two uses (repro and verify);
- the copy's patch: one use;
- each gesture's: one use.

**Shutdown.** SIGTERM stopped the daemon with exit 0. No fake HDC process was left (`pgrep`), and
no listener.

## Runbook §6 criteria, as rehearsed

- **Repro.** Liveness `UNHEALTHY` / `targetProcessNotRunning`: yes. Exactly one new crash-index
  entry: yes. `analyze crash-signature` `answered`, not `unreadable`: yes, through `job run`.
- **Repair leg.** Isolate, import and patch all `succeeded` with `outcomeUnknown` false, and the
  patch's product names `previousWorkspaceRevision` → the new revision. Build and sign did not run.
- **Verify.** The install readback pins the deployed bytes, but to the probe's digest, since
  there is no `signed.hap`. After the window, liveness `HEALTHY` and the crash-index count
  unchanged.
- **Negative.** A named refusal, and an identical Job set.
- **Discipline.**
  - The legs used published CLI surfaces only.
  - Raw device commands: 0. The fake device's state changes are the harness standing in for the
    device's own crash; they are not commands.
  - App: 0. Repository writes: 0.
  - One read-only diagnostic ran outside the legs: a raw `agent.status` control frame, to confirm
    Defect 2.
  - No HAR appeared.

## Build and sign

Neither leg can run on an isolated development root. This change adds no way around that.

- **Build.** A build needs a registered preset, and a registered preset needs a DevEco toolchain
  in the bootstrap registry.
  - `runtime tool register --kind deveco --root <stand-in>/DevEco-Studio.app/Contents` was refused
    (`fileIdentityChanged`: the DevEco source cannot be read under its required identity).
  - A complete stand-in would still meet the registry's code-signature anchor (Huawei, team
    `TZEA3TN37Q`).
  - `workspace preset register --kind build` naming an unregistered toolchain was refused
    (`resourceNotFound`: toolchain reference does not exist).
  - A build planned against the copy was refused by name (`workspace preset is not registered
    for this project`).
  - The one DevEco that would register is the maintainer's real installation. Using it would run
    a real Hvigor build, which this task forbids. On this host it cannot finish anyway: SPK-10
    found the DevEco SDK's `ninja` is x86_64 only, and the host has no Rosetta.
- **Sign.** The isolated root composes no signing credential owner, by design
  (`workspace-build-sign-run.md`): its only secret source would be the account's Data Protection
  Keychain. `workspace preset register --kind signing` was refused (`operationUnavailable`:
  signing credential reference owner is unavailable).
- **What does cover them.** The build and sign legs are exercised by the hoststore oracle replays
  and composition tests of `workspace-build-sign-run.md`, with the same stand-in Hvigor and
  signer. The proposal below would make them rehearsable on a development root.

## Defects found (none introduced by this change; all on `main`)

1. **`agent run` of `analyzer.extract-crash-signature@1` never finishes.**
   - Cause: the agent-run worker in `arkdeck-agentd` (`Host::start_agent_run`) builds its
     `JobRunner` with `analyzer: None`. `JobRunner::execute` therefore writes the `steps-start`
     transition and then refuses as uncertain.
   - Effect on the Job: its journal stands at `running` while its record says `preflight`, so
     `job run` refuses it for good ("journal does not stand at its preflight boundary").
   - Effect on the caller: the `agent.run` long poll kept waiting well past its `--maximum-wait`
     deadline (over 10 minutes against 2 minutes).
   - Workaround here: the same leg through `job submit` + `job run`, whose runner composes the
     analyzer, succeeded.
2. **`agent run` answers `internalError` "the result does not conform to the current contract"
   for Jobs that succeeded.** This happens for the workspace operations and for the three
   gestures. The daemon's own conformance check refuses its `agent.status` answer. The published
   schema admits neither of these shapes:
   - a host-only Job's artifacts (`bindingRevision` and `stableIdentitySha256` null);
   - a gesture capability's `authority.artifactDigest` null.
3. **Projections.**
   - `operation list` reports every `workspace.*` operation `provider_not_registered`.
   - It reports `debug.template@1` `tool_identity_drift`: its reference is missing from the
     `hdc_tool_current` list.
   - `workspace project list` keeps a composed project at `runtimeRestartRequired` after the
     restart.
   - Neither blocks planning or `job run`.

Each is reported to the coordinator as its own follow-up.

## Proposal: two development seams for the build and sign legs (pending a maintainer ruling)

Both change a security boundary, so neither is implemented.

### P1: a development DevEco fixture root

- **Configuration.** `ARKDECK_DEVELOPMENT_DEVECO_FIXTURE=<absolute path>` and
  `ARKDECK_DEVELOPMENT_DEVECO_FIXTURE_ACKNOWLEDGMENT=acknowledged`.
  - Only an isolated development root reads them.
  - The standalone daemon, the facade and the production composition refuse to start when either
    is set, as they refuse the other development seams.
- **Scope.** The path must be a directory inside the development root. Registering it skips the
  Huawei code-signature check and nothing else. Every file the record pins is still measured,
  pinned by digest, re-measured at every plan and held open at dispatch.
- **Containment.** The registry record carries `trust: developmentFixture`, which an installed or
  production registry refuses to read.
- **Evidence status.** Everything built through it is development-root evidence, never
  `REAL_DEVICE_PASS`.

### P2: a development signing fixture

- **Configuration.** `ARKDECK_DEVELOPMENT_SIGNING_ROOT=<absolute path>` and
  `ARKDECK_DEVELOPMENT_SIGNING_KEYCHAIN=<absolute path>`. Only an isolated development root reads
  them; they are refused elsewhere, as in P1.
- **Signing root.** It must be inside the development root. The credential owner and its ledger
  live there, never in the account's `…/ArkDeck/Signing/OpenHarmony`.
- **Secret source.** The named file keychain (`KeychainItems::file_keychain`, the scope SPK-10's
  tests use): made for the rehearsal with `security create-keychain`, outside the user's search
  list, holding fake passwords only. The Data Protection Keychain is never read.
- **Receipt.** The product's own install path installs it into that root (a Rust
  `runtime signing install` against the development root). It is never written by hand, so the
  rehearsal manufactures no trust record.
- **Signer and acceptance.** The signer is `ArkDeckFakeHapSignerFixture`, and acceptance stays
  Q9's: argv, prompt protocol, signing identity and readbacks. Passwords still travel only through
  the pseudo-terminal, and the rehearsal scans every file it leaves for them.

### Questions for the maintainer

1. May an isolated development root register an unsigned DevEco fixture under an explicit
   acknowledgment (P1)? Or must build rehearsals wait for a device window, with a real DevEco on a
   host that can build?
2. May an isolated development root compose signing over its own preset root and a rehearsal file
   keychain (P2)?
3. If the answer to 2 is yes: is porting `runtime signing install` to the Rust CLI the
   prerequisite, or may the harness install the fixture receipt through a test-only path?

## Reproduction

The harness (`rehearse.py`, `fake-hdc-gj5.c`, `driver.sh.in`) is in the session's scratchpad and
is not committed. It builds its fake HDC with `/usr/bin/cc` and prepares fresh roots under
`/private/tmp/xpa015-gj5*`. It records every CLI call (argv, exit, answer) and every device call.
A pass takes about 40 s.

The first pass exposed Defect 1. Its evidence (the torn journal, `agent status`, a thread sample
of the daemon) was kept before the roots were rebuilt. The recorded pass is the fifth.
