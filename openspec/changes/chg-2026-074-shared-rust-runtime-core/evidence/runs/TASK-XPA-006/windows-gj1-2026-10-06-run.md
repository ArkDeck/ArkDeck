# Windows GJ-1 actual-device run — 2026-10-06

Task: `TASK-XPA-006`, `CHG-2026-074`.

The original `gj_record` judge generated **REAL_DEVICE_PASS**, with all 88
criteria satisfied and no unsatisfied criterion, from the root operator's
actual DAYU200 Runtime captures. The maintainer resumed the previously skipped
GJ-1 window and performed the requested disconnect/reconnect in the same fixed
USB port. No fixture, simulation or manually written PASS supplied this result.

The generated, redacted record is
[gj-headless-rerun-2026-10-06-windows.json](../../../../../../docs/design/references/v1.6-goal/gj-headless-rerun-2026-10-06-windows.json).
Raw output remains local in the protected capture directory; this note includes
no board serial, connect key, machine/account name, user directory or resume
reference. The three execution IDs are `gj1-20261006`,
`gj1-20261006-capture` and `gj1-20261006-har`.

## Installed source and observed behavior

- Protected-main Runtime source: `d238a55c7b693adc7edbf6314699e920f0ee1e08`.
- Catalog: `c6e92eb252fe7653ed303a9ce34d12635bbc5f71ffb2a54fb8eb1fa3a9b99036`.
- Development RC ZIP SHA-256: `676849c7b7e711def42d8c5fa533f9ac4148beea2f3e93e7c375048b963d8c1b`.
- Runtime executable SHA-256: `0511ee0d7c799ee5608b93a66a8dfe80d11fb0d6debe97e28a47a7912abbdff4`.
- CLI executable SHA-256: `60530913142cd1f6ab81a454e4e2a6b29d7a08d4f1c3fcefee711c54e65e19d7`.
- Registered HDC: version `3.2.0g`, SHA-256 `c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e`.

The native installed-instance verifier confirmed the signed package's exact
process path, file identity, executable digest, source and fresh service
verification before running and again after the typed Runtime restart. Three
new execution IDs were proven absent before their one-time launches. Captures
were strictly serial throughout; older windows and their bytes remain intact.

| Leg | Actual Runtime result and complete readback |
| --- | --- |
| Observe | `observe.device@1`, Job `job-7534e727fc3902fbfb608d6691531993`; completed/succeeded, outcome known; three published Artifacts read whole and digest-checked |
| Capture | `capture.diagnostics@1`, Job `job-e716a2ec4f9a4c86332bddf4e876441b`; completed/succeeded; six published Artifacts read whole and digest-checked; eight missing inventory declarations retained as missing, with no invented bytes |
| Restart retention | Typed restart exit 0; both Jobs' status, show, result, evidence, complete inventories and all nine published products were read back after restart |
| Disconnected HAR | Current `device.candidates` observed no Connected board; targetless observe exited 75 with `humanActionRequired`, `waitingForHuman` and `newDispatchCount: 0` |
| Reconnect/resume | Recovered status, complete owner action list and action show supplied the matching waiting reference; it was consumed once, exit 0; Job `job-ba3c8912e033ee9c5605e0bb9e8d75fc` succeeded and its three published Artifacts were read whole and digest-checked |

The recorder confirms the same Target, binding revision and stable physical
identity across reconnect, and the HAR's `resolvedByFreshProbe` outcome. All
three actual Jobs are read-only, have known outcomes and have no outstanding
residue. The record's operation coverage names two real-device-passing
operations, `observe.device@1` and `capture.diagnostics@1`; other operations
remain unexercised in this window.

After assembly, typed Runtime stop (Raw 83) and status (Raw 84) both exited 0.
Drain was complete, no registration or daemon was removed, the socket was absent
and retained state was preserved. All 84 Raw commands were serial and retained.

## Local targeted checks

The root-only bounded wrapper `tools/gj1/journey.py --date 2026-10-06` ran
`facts`, `discover`, `observe`, `verify`, `capture`, `restart`,
`har-unplugged`, `har-replugged`, `har-resume` and `assemble`: each phase exited
0. The expected HAR receipt inside `har-unplugged` exited 75. The installed CLI
and daemon were verified on each capture; typed operation outputs, whole-product
reads and their exact argument arrays remain in the local protected journal.

`python -B -X utf8 tools/gj1-review/inspect_gj1_20261006_criteria.py` exited 0
with `satisfied: 88`, `unsatisfied: []` and `recordWritten: false`.
`journey.py ... assemble --record .../gj-headless-rerun-2026-10-06-windows.json`
then exited 0 and wrote the record through `python -m gj_record assemble`.
`python -B -X utf8 tools/gj1-review/stop_gj1_20261006.py` exited 0 after checking
the unchanged recorder criteria and all three completed executions.

After typed stop, `tools/run_check.py` ran
`C:/Program Files/Git/usr/bin/sh.exe scripts/check-sdd.sh`: exit 0, log
`D:/src/ArkDeck-wt/tools/logs/windows-gj1-delivery-sdd-20261006.log`.
The initial bare `sh` launcher was unavailable in this process environment;
the absolute Git shell above completed the actual SDD check.
`git diff --cached --check` exited 0 after all six changed files were staged;
log `D:/src/ArkDeck-wt/tools/logs/windows-gj1-delivery-diff-staged-20261006.log`.
This increment changes only evidence and current acceptance notes;
no Rust, Swift, App build, generator or HDC-probing test was run during the
device window.

## CI

The installed source was released by
[PR #2597](https://github.com/ArkDeck/ArkDeck/pull/2597), whose exact head passed
SDD Guard [37361252068](https://github.com/ArkDeck/ArkDeck/actions/runs/37361252068)
and Swift aggregate
[37361252550](https://github.com/ArkDeck/ArkDeck/actions/runs/37361252550).
Those checks validate the implementation, not this later acceptance record.

The preceding delivery documentation head's Agent PR
[37370701028](https://github.com/ArkDeck/ArkDeck/actions/runs/37370701028), SDD Guard
[37370701274](https://github.com/ArkDeck/ArkDeck/actions/runs/37370701274) and Swift
[37370701823](https://github.com/ArkDeck/ArkDeck/actions/runs/37370701823) concluded
failure because their cancelled jobs were not acquired by a hosted runner after
multiple attempts, before any job step. The successful plan and interaction
jobs remain recorded. No automatic PR was created by that failed run. This
substantive evidence commit will trigger a new normal push; its PR and CI are
**PENDING**, with no bypass or claim of green checks.

## Remaining acceptance

GJ-1's formal prerequisite is now satisfied on the recorded Catalog. The
original paired GJ-2 HAP, GJ-3 signed ARM32 library/pinned rollback fixture, and
GJ-5 board-trusted debug signing material/preset and remaining crash-probe
inputs are still missing. The earlier independent HAP smoke and host repair
do not substitute for those formal inputs. GJ-4 remains gated by AF-W1 and its
destructive HardwareCampaign. This run does not adopt a performance baseline
or change the Windows CLI census of 149 implemented, 11 partial and 2
notImplemented features.
