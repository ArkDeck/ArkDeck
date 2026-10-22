# Verification

> Change:CHG-2026-087-windows-acceptance-platform-fact@r1

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| WAP-AC-01 example corrected | Read `POL-PLATFORM-002` in `openspec/constitution.md` and `constitution-delta.md` | Linux is the not-started / `deferred` example. Windows is in acceptance with conformance `notStarted`, and still SHALL NOT claim support or release before `verified`. Constitution version is 2.0.1. | this PR diff |
| WAP-AC-02 conformance not advanced | Diff does not touch `PLATFORM-PROFILES.lock.yaml`, platform profiles, or conformance cases | `not_started_platforms` still lists windows and linux. Windows `conformance_status` stays `notStarted`. No release or support claim. | this PR diff |

## Local targeted checks

`sh scripts/check-sdd.sh` on this change package and the constitution edit.

## Result gate

- [ ] WAP-AC-01 and WAP-AC-02 hold on the merged text
- [ ] SDD Guard `guard` and Swift CI `swift` are green
