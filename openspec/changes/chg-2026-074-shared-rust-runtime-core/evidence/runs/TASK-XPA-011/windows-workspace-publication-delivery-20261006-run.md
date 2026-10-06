# Windows workspace publication delivery — 2026-10-06

Task: `TASK-XPA-011`, `CHG-2026-074`.
Released protected main: `d238a55c7b693adc7edbf6314699e920f0ee1e08` (PR #2597).
Validated PR head: `48d2dc6a29edaa3c6dacaef6d56715c8f7addbde`.

The repair publishes closed host workspace Jobs using their complete original
consumed Runtime authority and matching durable Job, Journal, plan and pinned
tool provenance. It does not redispatch their operations, renew authority or
change their outcomes. Windows external-tool fixed PE FileVersion is read from
the retained, same-SHA executable without a version child. The Runtime's own
compiled package version requires its exact executable path, native identity and
SHA. Implementation and its original
targeted checks are recorded in
[the implementation run](windows-workspace-session-publication-20261006-run.md).
CLI coverage remains 149 implemented, 11 partial and 2 notImplemented of 162
Windows-required features, plus 101 macOS-only entries.

## Root operator results

These results are supplied by the root operator; this documentation Agent did
not read private captures or execute the Runtime/device chain. The signed d238
development RC's ZIP SHA-256 is
`676849c7b7e711def42d8c5fa533f9ac4148beea2f3e93e7c375048b963d8c1b`.
RC smoke, doctor and App UIA reported PASS.
Those are host/package results, not a formal Golden Journey or hardware PASS.

| Retained or independent work | Known result |
| --- | --- |
| Historical build `job-af3d6b42e0b281b4611f96d991dcd560` | Original succeeded Job retained; publication settled at generation 5 without operation dispatch or replacement authority |
| Historical test `job-efb76358fcbea5f41e360057ab0d074d` | Original succeeded Job retained; publication settled at generation 6 without operation dispatch or replacement authority |
| New independent host patch | Succeeded; publication generation 7; readback complete |
| New independent host build `job-a35fc6c2d40a7dd5b0b12cb74b8fa126` | Action Raw 182 exit 0, completed/succeeded; publication generation 8; whole HAP/build-log readback and fixed-input check exit 0 |
| New independent host test `job-097a4e21dd96ab44154d72d7c7220243` | Action Raw 238 exit 0, completed/succeeded; publication generation 9; whole test-log readback and fixed-input check exit 0 |
| Independent HAP smoke `job-fdfd87edaba3b7e6669d24355cde2d28` | Action Raw 277 exit 0 once; status 278 completed/succeeded; publication generation 10; three complete public products; smoke software check exit 0 |
| Repaired WaterFlow HAP signing and formal GJ-5 device loop | **BLOCKED** on board-trusted debug signing material/preset and remaining formal crash-probe inputs; the separate smoke does not replace these inputs |

The build's publication receipt Manifest SHA-256 is
`cbd9443e575b4766c7a99d4402fb39a6b846f164a1b424f4d23f46b65ea5805c`;
the test's is
`e87e94d0460a5111e30164fd962905e337d38c9c5441d035942e05445b3cc0af`.
The new repair import (Raw 115) started at `2026-10-05T20:01:18.697537Z`; its
final test Artifact read (Raw 249) finished at
`2026-10-05T20:18:06.443693Z`. The elapsed 1007.746156 seconds, exactly three host
dispatches (Raw 136/182/238) and 2,750,419 aggregate declared Job Artifact bytes
stayed within one round, 40 minutes and 512 MiB. No clock was reset.

The independent smoke used the separate signed HAP imported once at Raw 258 and
inspected at Raw 259. All eight chunks (Raw 261–268) matched its 7,987,020-byte
length and SHA-256
`e585efb1527c11b14edff214889097e021a07b57ebf6fbc4505c5f49e6089da9`.
Its publication receipt Manifest SHA-256 is
`e7db763c353c6b8d0c01b536223fb9db84a4d28a300ba5ea472811315dbc5b6d`.
Raw 285–287 read all three products whole and checked their hashes:
`debug-hilog.txt`, `install-readback.json` and `process-readback.json`.
The smoke check exited 0 with `observedTerminalState: succeeded`,
`debugSoftwareChecksSatisfied: true`, `formalAcceptance: false` and
`hardwareEvidence: false`. It supplies no UI, device-info or screenshot result.

Typed Runtime stop (Raw 288) and status (Raw 289) exited 0, reporting a complete
drain, no registration or daemon removal, no socket and preserved state. The
root's offline check confirmed all 289 current Raw entries were sequential and
nonoverlapping.

All earlier Run bytes and histories remain retained. A refused or unknown attempt
is never replayed; the new repair chain does not reset an expired original budget.
Receipt Manifest digests and complete public Artifact reads do not claim
independent whole private Manifest/Journal byte verification.

## Local targeted checks

The implementation record above preserves the exact Rust/schema/lint commands,
exits and logs for #2597. They were not rerun during the actual RC/device window.
The current pure helper checks all exited 0:

| Helper scope and command | Passed | Log |
| --- | ---: | --- |
| GJ-2 `python -X utf8 -m unittest -v test_driver test_hardening test_smoke` | 52 | `D:/src/ArkDeck-wt/tools/gj2/test-smoke-native-proof-full-utf8.log` |
| Root wrapper `python -m unittest -v test_run_remaining_smoke` | 5 | `D:/src/ArkDeck-wt/tools/gj1-review/run-remaining-inspect-hap-tests.log` |
| GJ-5 `python -X utf8 -m unittest -v test_host_repair test_host_prepare test_driver` through `tools/run_check.py` | 84 | `D:/src/ArkDeck-wt/tools/gj5/host-repair-readiness-review-fixed.log` |

Those synthetic checks establish helper guards, not actual acceptance results.

After typed Runtime stop, root ran `sh scripts/check-sdd.sh` through
`tools/run_check.py`: exit 0; log
`D:/src/ArkDeck-wt/tools/logs/windows-publication-delivery-sdd-20261006.log`.
The final staged `git diff --cached --check` exited 0; log
`D:/src/ArkDeck-wt/tools/logs/windows-publication-delivery-diff-staged-20261006.log`.
This increment changes only these delivery/census/runbook documents, so no Rust,
Swift, App or contract-generator check was rerun locally. The documentation
Agent made no Runtime/HDC calls; root alone executed the actual chain.

## CI

[PR #2597](https://github.com/ArkDeck/ArkDeck/pull/2597) was merged at
19:39:27 UTC after the exact head above completed all 16 checks with
SUCCESS/SKIPPED conclusions. SDD Guard run
[37361252068](https://github.com/ArkDeck/ArkDeck/actions/runs/37361252068) and Swift
aggregate run
[37361252550](https://github.com/ArkDeck/ArkDeck/actions/runs/37361252550)
both concluded SUCCESS. These validate the released implementation, not this
subsequent docs-only delivery increment. The first delivery head
`1525766eed991e912ad2a44ea69e270c8cf85e49` did not get an automatic PR: Agent PR
[37370701028](https://github.com/ArkDeck/ArkDeck/actions/runs/37370701028), SDD Guard
[37370701274](https://github.com/ArkDeck/ArkDeck/actions/runs/37370701274) and Swift
[37370701823](https://github.com/ArkDeck/ArkDeck/actions/runs/37370701823) failed
when hosted runners did not acquire the cancelled jobs after multiple attempts,
before any step. Plan and interaction jobs succeeded. Root is adding the actual
GJ-1 record and normally pushing that substantive increment; the new delivery
PR/head/run results remain **PENDING**.

## Remaining acceptance

GJ-1 was user-skipped/incomplete during the independent publication/smoke window
above. The maintainer subsequently resumed it: the actual 2026-10-06 run passed
all 88 unchanged recorder criteria. Its generated record and exact root results
are in [the GJ-1 run](../TASK-XPA-006/windows-gj1-2026-10-06-run.md).
Independent product execution above was completed under the earlier delegation
with the formal Scenario/recorder predicates unchanged. The
original paired formal GJ-2 HAP and GJ-3 signed ARM32 library/pinned rollback
fixture remain missing. Signing and device verification of the repaired
WaterFlow HAP remain blocked on board-trusted debug signing inputs/preset and
the remaining formal GJ-5 crash-probe inputs. The separate successful smoke and
host patch/build/test preparation do not establish its signed repro/verify loop.
No `REAL_DEVICE_PASS`, formal
Journey PASS, hardware-evidence declaration or baseline adoption is made here.
