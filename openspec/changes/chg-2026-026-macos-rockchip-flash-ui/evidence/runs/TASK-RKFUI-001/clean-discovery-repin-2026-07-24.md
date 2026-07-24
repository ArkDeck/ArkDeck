# TASK-RKFUI-001 clean discovery identity repin

- Run time: 2026-07-24
- Executor: autonomous agent
- Final source base: `5f34a2aa376bd3677b69ba14410f265f1a29aaf7`
- Initial readiness audit base: `73b46b684b27eda23cfbaad06c5b707bff39e2cc`;
  the intervening #443 merge changed only CHG-2026-032 governance documentation
- Change/baseline: CHG-2026-026 r2 / CORE-2.0.0
- Evidence classification: contract/fake plus signed-Sandbox host-only build
- Hardware/device dispatch: 0
- Task/change status change: none
- Overall result: **implementation remediation PASS; signed Sandbox E0 device receipt still pending**

## Readiness and scope

The four r3 implementation input blobs matched the approved readiness pins before editing:

| Input | Git blob | Result |
| --- | --- | --- |
| `RockchipDeviceDiscovery.swift` | `67f585324d002f80c2682a1bdaa9ae7d11ed035a` | match |
| `RockchipDeviceDiscoveryContractTests.swift` | `1f7cacda22ed6cef97d4a25ed63c3e4aa890cbb6` | match |
| `scripts/rockchip_e0_probe/probe.py` | `92eb2876bfe9dcd0ffadf1d0318b9b7b05c93857` | match |
| canonical discovery registry | `f7fa0945f70730bca601f81955a3faea411a19f3` | match |

This remediation changes only the approved E0/read-only discovery surface. The existing
destructive Provider, Profile, authorization, manifest validator and hardware matrix remain on
`038a8a0e…3611`; no forbidden path changed.

## Implementation

- Repinned the canonical RockUSB discovery profile, bundled registry fixture, Swift discovery
  adapter, Python harness and signed probe target to clean artifact
  `bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923`.
- Kept exact version `rkdeveloptool ver 1.32`, upstream commit
  `304f073752fd25c854e1bcf05d8e7f925b1f4e14`, explicit user-selected bookmark source and the
  sole argv `["ld"]`.
- Added explicit old-hash rejection in the Swift and Python discovery tests.
- Split the Swift constants so the default discovery adapter uses
  `pinnedReadOnlyDiscovery`, while the existing destructive consumers retain their old
  compatibility identity. This prevents the E0 repin from silently changing Flash authorization,
  process execution or manifest bytes.

The first full-suite run exposed that destructive code also consumed the historical
`pinnedProduction` symbol: directly changing that symbol caused the Flash manifest validator to
reject the new hash. The final implementation keeps that destructive symbol unchanged and routes
only E0 discovery through the new identity. The final full suite passed.

## Verification

| Command / check | Result |
| --- | --- |
| `python3 -m unittest scripts/rockchip_e0_probe/test_probe.py` | PASS: 6 tests, 0 failures |
| canonical registry/resource files vs bundled copies (`cmp`) | PASS: byte-identical |
| discovery + Flash execution targeted Swift tests | PASS: final covered 7 discovery + 3 Flash execution tests |
| signed probe host-only build | PASS: ad-hoc signed, Hardened Runtime, exact six entitlements |
| `codesign --verify --deep --strict <probe-app>` | PASS |
| signed probe executable SHA-256 | `8620527d3190f0086e4d387ae603751c618e7d574952a6604f8dd8741979841b` |
| `CI=true swift test --package-path Packages/ArkDeckKit` | PASS: 383 tests, 1 manual sleep/wake test skipped, 0 failures |
| `ARKDECK_PYTHON=/opt/homebrew/anaconda3/bin/python3 CI=true sh scripts/check-sdd.sh` | PASS: 0 errors, 0 warnings, 111 acceptance IDs |
| `git diff --check` | PASS |

The signed probe was built in a fresh temporary directory but was not opened. Therefore this run
does not claim security-scoped tool selection, direct USB access or a Loader observation.

## Safety counters and conclusion

| Counter / gate | Result |
| --- | --- |
| real `rkdeveloptool ld` | 0 |
| signed probe App launch | 0 |
| HDC / mode switch | 0 / 0 |
| device mutation / destructive | 0 / 0 |
| `ppt` / `wlx` / `rd` | 0 / 0 / 0 |
| sudo/elevation/helper/driver/system mutation | 0 |
| network | 0 |

The clean-tool implementation repin is complete and the old quarantined hash now fails the E0
discovery gate. `AC-FLASH-001-01` and `AC-UX-007-01` retain their passing contract evidence, but
TASK-RKFUI-001 remains `ready`: a separate signed Sandbox E0 run must still select the clean tool
and observe the approved Loader target before direct-access readiness can pass. This record does
not substitute for TASK-RKFUI-001A E1 evidence and does not unblock destructive execution.
