# TASK-RKFUI-001 signed Sandbox E0 — selection-time quarantine blocker

- Run time: 2026-07-25T01:18:40Z
- Executor: agent, with the maintainer performing the required `NSOpenPanel` selection
- Run source base: `992d4bd14664c1a7786d18b35047304966678295`
- Change/baseline: CHG-2026-026 r6 / CORE-2.0.0
- Evidence classification: signed-Sandbox host-only blocked attempt
- Task/change status change: none
- Overall result: **BLOCKED before child launch**

## Scope and readiness

The maintainer reported that the controlled DAYU200 had been physically placed in Loader. The
agent did not send HDC, reboot-loader, mode-switch, mutation, destructive, privilege, install or
system-policy commands. The signed probe was permitted to select only the registry-pinned
`rkdeveloptool` and, if every preflight gate passed, to launch only exact `["ld"]`.

Before the device window, the repository probe contract, canonical discovery registry and selected
tool matched the protected-main pins:

| Input | SHA-256 / result |
| --- | --- |
| `scripts/rockchip_e0_probe/probe.py` | `a393b389a86363dc540f238374c88806efb3d0b4590dff612f016b4daec7638d` |
| `RockchipE0ProbeApp.swift` | `2e9be843e802e0f102ded678671ac8dd7f3b7849ba5e3dcfeba229bedca888c4` |
| `Probe.entitlements` | `43cd45670fe0f8d8bf831757fedfde554aa28fe5ff7613fd0a76001a444669c4` |
| canonical RockUSB discovery registry | `2bdaed866e4818fffd345313931a2550ba5079d403f093a83dce6c882459170c` |
| selected executable | `bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923`; ad-hoc signature integrity valid; quarantine absent in the host precheck |

The App was freshly built, ad-hoc signed with Hardened Runtime, verified by `codesign`, and carried
the approved six-entitlement shape. No Developer ID signing identity was available, so this is
local platform evidence only.

## Device-window result

The first panel launch was cancelled before selection because the macOS open-panel accessibility
service did not return a usable tree. That cancelled launch emitted no envelope and dispatched no
child. A second launch presented a temporary one-entry selection directory whose sole symlink
resolved to the same fixed executable. The probe's existing canonical-URL guard accepted that
resolution, and the maintainer selected the sole `rkdeveloptool` entry.

Security-scoped bookmark creation and access succeeded. The executable hash, approved
version/source tuple and ad-hoc signature integrity still matched. However, the signed App then
observed `com.apple.quarantine` on the resolved executable and Gatekeeper rejected it. The
quarantine semantic changed from absent in the host precheck to present after selection; a
post-run host inspection attributed the new quarantine record to the Probe App. No raw quarantine
payload is committed.

The probe returned typed `toolBlocked(quarantinePresent)` and fail closed before `Process` launch:

| Gate / counter | Result |
| --- | --- |
| exact user selection + bookmark | PASS |
| fixed identity/version/source/signature | PASS |
| quarantine / Gatekeeper | BLOCKED / rejected |
| child launch attempted | false |
| exact read-only `ld` | 0 |
| USB result | not attempted |
| HDC / mode switch | 0 / 0 |
| device mutation / destructive | 0 / 0 |
| sudo/elevation/helper/driver install | 0 / 0 / 0 |
| system rule/group/ACL mutation | 0 |
| network | 0 |

Because `ld` never launched, this record does not independently observe the reported Loader mode,
does not contain real-hardware RockUSB evidence, and does not establish direct USB access.

## Verification

| Check | Result |
| --- | --- |
| `python3 -m unittest scripts/rockchip_e0_probe/test_probe.py -v` | PASS: 6 tests, 0 failures |
| `swift test --package-path Packages/ArkDeckKit --filter RockchipDeviceDiscoveryContractTests` | PASS: 7 tests, 0 failures |
| `scripts/check-sdd.sh` | PASS: 0 errors, 0 warnings, 111 acceptance IDs |
| fresh probe build | PASS: App executable `8620527d3190f0086e4d387ae603751c618e7d574952a6604f8dd8741979841b` |
| `codesign --verify --deep --strict` | PASS |
| built entitlements vs expected entitlement map | PASS |
| sanitized receipt schema/privacy review | PASS: no full path, serial, LocationID or raw quarantine payload |
| raw stdout/stderr | both empty; SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

## Conclusion and boundary

This attempt is a valid fail-closed host-only receipt, not an E0 direct-access PASS. The use of a
temporary symlink means the observation does not prove that selecting the canonical executable
path directly would reproduce the same metadata transition; it does prove that this attempt
cannot be accepted and that the formerly clean host artifact is no longer eligible.

The agent did not delete or rewrite quarantine, copy/rebuild the tool to evade assessment, add an
executable-writing entitlement, weaken Gatekeeper checks, or rerun the device window. Any change
from the approved six-entitlement boundary requires a separate scoped governance decision before
implementation. TASK-RKFUI-001 remains `ready` in this evidence-only PR, while its execute
readiness gate and TASK-RKFUI-003/004 remain blocked.
