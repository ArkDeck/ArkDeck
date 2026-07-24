# TASK-RKFUI-001C — HDC 3.2.0f exact repin closure

- Time: `2026-07-24T13:49:30Z`
- Executor: autonomous agent
- Base: `0f0a79aff7ede1519b9fbc0cbdca12b5c687ef07`
- Readiness: CHG-2026-026 r5 merged by
  `PR#481@0f0a79aff7ede1519b9fbc0cbdca12b5c687ef07`
- Classification: host-only registry/probe/test closure
- Result: **PASS for TASK-RKFUI-001C scoped acceptance**

## Input closure

The implementation started from the r5 merge commit above. The required pre-change blobs were:

| Input | Git blob |
| --- | --- |
| canonical loader-transition registry | `6ec79be1885348de62ad373e1607e2d4e6aa3e54` |
| Python probe | `c1bb286d8f2a5c13ccddb9128e4bcd1862e926de` |
| Python tests | `e0814df2efef7203475153f2f4f5a26dcf941e1a` |
| probe README | `14a2150cbaa1baf4b1a2e37808e17308ee222758` |
| change evidence README | `7da02aee30345527ac9b2a3cdd1f220458a9a558` |

The registry/probe blobs exactly matched the r5 readiness pins. No unexpected input drift was
observed.

## Implementation

- Appended the exact r5 authorization ref and replaced the one HDC version/hash pair with
  `Ver: 3.2.0f` /
  `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`.
- Kept the absolute executable path, pre-existing external same-UID ownership requirement,
  server lifecycle policy, window, target, RockUSB observation and operation semantics unchanged.
- Added probe-side exact closure for the complete authorization ref tuple and HDC object. This
  makes `selftest-host` fail closed if the version, hash, absolute path or server policy drifts.
- Updated FakeRunner and test configs to the new version. Added registry negative cases for the
  old version and old hash independently, plus a workflow negative proving the old reported
  version stops before usage reservation and E1.
- Updated the probe README with the single accepted r5 pin and the remaining D0/E0/per-device
  gates. The old pin is documented only as a rejected drift pair.

## Verification

| Command | Result |
| --- | --- |
| `python3 -m unittest scripts/rockchip_loader_transition_probe/test_probe.py -v` | PASS, 25 tests |
| `python3 scripts/rockchip_loader_transition_probe/probe.py selftest-host` | PASS |
| `python3 -m py_compile scripts/rockchip_loader_transition_probe/probe.py scripts/rockchip_loader_transition_probe/test_probe.py` | PASS |
| `python3 -m json.tool openspec/integrations/rockchip/loader-transition/1.0.0/registry.yaml` | PASS |
| `ARKDECK_PYTHON=/private/tmp/arkdeck-sdd-venv-rkfui001/bin/python bash scripts/check-sdd.sh` | PASS, 0 errors, 0 warnings, 111 acceptance IDs |
| `git diff --check` | PASS |
| changed-path review against `origin/main` | PASS, only TASK-RKFUI-001C allowed paths |
| changed-file credential pattern scan | PASS, no candidate secret |

The first default-Python SDD attempt did not start because that interpreter lacks `PyYAML`.
Re-running the unchanged checker with the existing task-scoped SDD environment shown above
passed. This was a host dependency selection issue, not an SDD finding.

The public GitHub open-PR query returned zero entries before commit, so no concurrent change
overlapped this task.

## Acceptance and safety conclusion

- Exact new-pin positive closure: **PASS**.
- Old version negative closure: **PASS**, fail closed before usage/E1.
- Old hash negative closure: **PASS**, registry load rejected.
- Dual-pin fallback: **absent**.
- HDC commands, including `-v`, `checkserver`, target/firmware reads and `reboot loader`: **0**.
- `rkdeveloptool` commands and USB observations: **0**.
- Binding/capability evidence, `enterUpdater` intent and usage reservation: **0**.
- E1/deviceMutation, E2/destructive, `ppt`/`wlx`/`rd` and destructive operations: **0**.
- HDC server lifecycle, privilege, helper/driver/system and host-shell mutations: **0**.
- Evidence class is host-only. This run is not real-hardware or per-device capability evidence.

## Remaining gate

TASK-RKFUI-001C remains `ready` in `tasks.md` until this implementation is maintainer-merged.
After merge, a separate D0 status-only PR may mark 001C done and restore TASK-RKFUI-001A E0
preparation. Fresh E0 must still run in a real USB-visible environment and prove zero
pre-existing RockUSB candidates before any per-device capability evidence acceptance PR; E1
remains blocked until those gates are merged.
