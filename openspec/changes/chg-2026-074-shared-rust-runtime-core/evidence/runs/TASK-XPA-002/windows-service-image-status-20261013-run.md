# Windows service status for a packaged Runtime — 2026-10-13

## Published reproduction

After maintainer merge of #2638, clean protected main
`9fa9a36a7f71d56f6cab0d7f5998cbc2a2e2641d` produced a fresh signed xcopy RC
and MSIX. The official producer and private RC smoke exited 0. The MSIX is
73,670,067 bytes, SHA-256
`369a395a44b5524996bd8ab9e618471e42b7e0b8ebcb6ced7f1b4692cedc531e`.

The registered package then exercised the real existing-account Runtime:

| App / CLI / Runtime combination | Actual result |
| --- | --- |
| Packaged CLI and App to xcopy Runtime | Doctor, ready status and complete Job inventory passed; actual App identity/connection UIA passed 1/1 |
| Matching packaged App, CLI and Runtime | Doctor, ready status and complete Job inventory passed; actual identity and English/Chinese capture UIA passed 5/5 |
| Xcopy CLI to packaged Runtime | Doctor succeeded over authenticated transport, but service status reported `ready: false` and an unverified image with Win32 5 |
| Xcopy App to packaged Runtime | Not executed: the preceding status assertion stopped this phase |

The six executed UIA cases have zero skips. The mixed workflow exited 1 and is
not a complete mixed-installation pass. Its raw status retains the ordinary
`WindowsApps` ancestor-open refusal; successful peer authentication did not
make that independent pre-launch check usable by an unpackaged caller.

The original signed xcopy Runtime was restored. Published health, status and
full Job readback succeeded and all **57 complete Job items** were unchanged.
The test package was removed. The existing public certificate's temporary
LocalMachine TrustedPeople entry was added at 15:28:58 UTC and removed at
15:34:40 UTC under the user's standing authorization and actual UAC approval.
Both temporary TrustedPeople entries are absent; original CurrentUser Root
trust remains. Mechanical postflight fails only its workflow-success condition,
while every restoration and cleanup condition passes. The failed RC was not
promoted over the user's existing installation.

## Repair and boundaries

The authenticated client connection now retains which existing installation
pin actually vouched for its live server. Reading that pin requires the
original process to remain alive and sends zero control frames. A server-side
accepted client connection cannot supply a server image pin. Native process
and file identity, signer/package family, retained image/ancestor locks and
PID rechecks still precede a client connection's construction.

Windows service inspection uses that live proof when the pipe exists, so
`status` and `verify` can inspect an authenticated packaged Runtime from an
unpackaged client. An absent Runtime still takes the unchanged ordinary
pre-launch image check. Restart separately verifies the replacement image
**before stopping the predecessor**; a caller unable to launch the packaged
replacement refuses without stopping it. No launcher, Catalog, protocol,
RuntimeCapability, trust policy or device operation changes.

The existing signed-process regression now checks the live signer proof and
ready status, and refuses both status and verify under a wrong signer while
the original process remains healthy. The native transport regression also
checks that accepting a client does not create a server image proof. Only the
five changed source inventory pins are refreshed; fixture hashes and routes
are unchanged. Fresh published MSIX verification, including both service
reads and the final App direction, must follow maintainer review and merge.

## Incomplete independent observations

The released 24-hour soak began at 13:02:50 UTC after a full quiet-minute
preflight (1.220 busy CPUs, limit 4). It used the unchanged 86,400-second
duration, 300-second restart interval, ten jobs per cycle and 32 MiB/16-handle
growth limits. It was deliberately stopped at 15:39:47 UTC before compiling
this newly discovered repair. Last metrics retain 31 cycles, 309 terminal
jobs, one active job, zero cleanup debt, 5,087,232 bytes RSS growth and -2
handles. Its private state and raw metrics remain intact. This is an
**incomplete simulated-provider run**, not a 24-hour pass or hardware evidence;
the repaired published version needs a new full-duration run.

The independent elevated-client probe timed out waiting for desktop UAC.
Only its own launcher/server were stopped; no elevated refusal observation
was established. Second-account, elevated-client and remote-host rows remain
open, alongside the existing production distribution and external-provider
dependencies.

## Local targeted checks

Raw logs remain under `D:/temp/arkdeck-windows-acceptance-20261013` outside Git.

- Published producer and private smoke: exit 0 (`package-mixed-released.log`,
  `rc-mixed-released/rc-manifest.json`, `smoke.json`).
- Published mixed workflow: exit 1; registration/removal exit 0;
  `mixed-release-run.json`, `mixed-release-smoke/results.json` and actual TRX
  counters, `raw-mixed-release-smoke`, `raw-mixed-release-restore`,
  `mixed-release-trust/msix-trust-lifecycle.json`,
  `mixed-release-postflight.json` (exit 1 for the retained smoke failure).
- Interrupted soak: `long-soak-released/exit.json`,
  `runtime-soak-metrics.json`, `stopped-for-service-status-repair.json`.
- Official runner `clippy` for platform and its ten direct consumers,
  `--all-targets -- -D warnings`: exit 0, 63 seconds
  (`service-status-checks/clippy.log`). Fixed session cache and two jobs.
- Required `fmt --all --check`: Windows argv error 206; equivalent batched
  `rustfmt --check` passed all 356 target roots (exit 0, `fmt-batched.log`).
- Manifest validation: exit 0, 927 sources / 6,499 fixtures / 333 targets
  (`service-status-checks/manifest.log`).
- Combined `python rust/scripts/run-cargo.py test` for the same eleven `-p`
  selections with `--no-fail-fast`: exit 101 after 1,269 seconds; 1,658 passed,
  17 ignored and 34 failed across 17 targets (`service-status-checks/test.log`,
  exact arguments/exits in `checks.json`). Every failed function and its
  unchanged historical route exactly matches the published parent: six
  Agentd failures and 28 HostStore failures (`classification.json`). None is
  counted as a pass and no route or assertion was weakened.
- The changed signed-process suite passed 5/5, including ready status,
  verified live signer, wrong-signer refusal and original-process health.
  Platform passed 266 tests, including the accepted-client role refusal,
  liveness, namespace locks and thread-identity reversion. All three
  account-selection process tests passed.
- Published original-Runtime restoration, ready status and complete Job
  readback: all exit 0; all 57 complete Job items unchanged
  (`raw-service-status-test-maintenance`).
- SDD: exit 0, zero errors/warnings and 121 acceptance IDs
  (`service-status-checks/sdd.log`); `git diff --check`: exit 0.
- No contract input, Swift source or App source changed; contract generation,
  local Swift/App rebuild and the full local CI gate were not run.

## CI

The published parent #2638 passed Swift CI `38395219613`, including all three
host workspace and contract-parity lanes, and final SDD Guard `38399175832`.
It was merged by the maintainer at 12:48:32 UTC. This repair reports separate
current-head PR checks; parent success does not approve this increment.
