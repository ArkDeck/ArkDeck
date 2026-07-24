# TASK-RKFUI-001 signed Sandbox E0 preflight

- Run time: 2026-07-24T02:17:16Z
- Executor: autonomous agent
- Change/baseline: CHG-2026-026 / CORE-2.0.0
- Evidence classification: signed-Sandbox host-only preflight
- Hardware/device dispatch: 0
- Task/change status change: none
- Overall result: **BLOCKED before child launch**

## Scope and result

Resumed the remaining signed Sandbox E0 work without changing product code or the approved
registry. The probe target was rebuilt from the repository source, signed ad hoc with Hardened
Runtime, verified by `codesign`, and confirmed to carry the frozen six-entitlement shape. No
Developer ID identity was available, so this remains local platform evidence rather than
Developer ID/notarization/release evidence.

The host currently has two relevant `rkdeveloptool` artifacts:

| Candidate | SHA-256 / trust fact | Gate result |
| --- | --- | --- |
| historical approved artifact | approved `038a8a0e…3611`; quarantine present; Gatekeeper assessment failed | blocked |
| current source-tree artifact | `bbd7bdc0…9923`; quarantine absent; ad-hoc signature | blocked: hash mismatch |

Neither candidate satisfies the approved identity and trust tuple. The probe App was therefore
not opened for a device window: choosing either known candidate would deterministically fail
closed before `ld`, while recording no new USB fact. ArkDeck did not remove or rewrite quarantine,
copy/rebuild the approved artifact to evade assessment, broaden the registry, or accept the
hash-drifted artifact.

## Verification

| Command / check | Result |
| --- | --- |
| `python3 scripts/rockchip_e0_probe/probe.py build --output-root <fresh-temp-root>` | PASS outside the filesystem sandbox after the sandboxed Swift compiler could not write its module cache |
| `codesign --verify --deep --strict <probe-app>` | PASS |
| signed entitlement equality | PASS: exact frozen six-entitlement shape |
| probe executable SHA-256 | `d87aa3ac…60a0a` |
| `python3 -m unittest scripts/rockchip_e0_probe/test_probe.py` | PASS: 6 tests, 0 failures |
| `swift test --package-path Packages/ArkDeckKit --filter RockchipDeviceDiscoveryContractTests` | PASS: 6 tests, 0 failures |
| `ARKDECK_PYTHON=<existing PyYAML 6.0.3 environment> scripts/check-sdd.sh` | PASS: 0 errors, 0 warnings, 111 acceptance IDs |
| `git diff --check` | PASS |

## Dispatch and safety counters

| Counter | Result |
| --- | --- |
| signed probe child launch / `ld` | 0 / 0 |
| HDC mode switch | 0 |
| device mutation / destructive | 0 / 0 |
| sudo/elevation/helper/driver install | 0 / 0 / 0 |
| quarantine/system rule/group/ACL mutation | 0 |
| network | 0 |

## Remaining gate

The execute-readiness gate remains blocked. A new E0 device window requires both:

1. a user-selected, non-quarantined executable whose SHA-256 is exactly
   `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`; and
2. the maintainer-controlled DAYU200 physically placed in the approved Loader state so the single
   allowed `["ld"]` invocation can observe exactly one semantic `0x2207:0x350a + Loader` target.

Until both are available, TASK-RKFUI-001 remains `ready`, TASK-RKFUI-001A/002/003/004 remain
`blocked`, and no direct-access or hardware-support claim is made.
