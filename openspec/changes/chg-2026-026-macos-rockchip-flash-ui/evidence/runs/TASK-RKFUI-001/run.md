# TASK-RKFUI-001 implementation and E0 run

- Run time: 2026-07-22T06:20:49Z
- Executor: autonomous agent
- Change/baseline: CHG-2026-026 approved by merged PR #298 at
  `b063217080f715933faace1aba664a27a152ed08`; CORE-2.0.0
- Platform: macOS 26.5.2 (25F84), arm64; Xcode 26.6 (17F113); Apple Swift 6.3.3
- Evidence classification: contract/fake plus signed-Sandbox host-only blocked attempt
- Overall result: **BLOCKED**; TASK remains `ready`, and TASK-RKFUI-003 remains `blocked`

## Readiness and immutable inputs

The implementation started from `origin/main` at the approval commit above. Recomputed pins:

| Input | SHA-256 | Result |
| --- | --- | --- |
| `Packages/ArkDeckKit/Package.swift` before implementation | `60bd68200aa8d25eb209e5fdd6f9d1e20594af07743849841f31defa4b9b5175` | match |
| existing RockUSB Provider | `81ff71a69f4dd3556de38d5fdf15526e57015529f23384d0fe6832ca32f86eee` | match/read-only |
| existing Flash Profile | `62c51f992654303ed0237b27c1642462dd1d8531b4d4a29661e718c962c2537b` | match/read-only |
| existing Flash Authorization | `e3b6cdc334410b67d93782184c705ab55cdefb2cd4340f8c6fe0b35970552edb` | match/read-only |
| selected `rkdeveloptool` | `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611` | match |

The selected tool's reported-version authority remains the approved registry pin
`rkdeveloptool ver 1.32`, bound to upstream commit
`304f073752fd25c854e1bcf05d8e7f925b1f4e14` by the exact executable SHA-256. The device
window did not run an additional `-v` command.

## Implemented deliverables

- Added `ROCKCHIP-ROCKUSB-DISCOVERY@1.0.0`, a closed integration registry for exact argv
  `["ld"]`, the pinned tool identity, strict output grammar, typed access diagnostics, limits and
  forbidden-effect list.
- Added byte-pinned Loader, multi-device, Maskrom, similar-family, malformed, duplicate,
  unknown-mode, permission and driver fixtures plus a resource manifest.
- Added a whole-output parser that rejects invalid UTF-8, stderr, unknown/extra lines, duplicate
  DevNo/LocationID, unknown modes, oversized output and non-success termination. Multi-device
  observations remain visible, but only `0x2207:0x350a + Loader` is Provider-applicable.
- Added a user-selected tool descriptor, platform-trust receipt, typed DeviceAccessAdvisor,
  identity-bound executable request and fixed `["ld"]` adapter. No caller argv/environment/shell
  surface exists.
- Added a minimal AppKit E0 harness using the frozen six-entitlement App Sandbox shape,
  security-scoped selection/bookmark, pinned hash, signature-integrity/quarantine preflight,
  fixed `Process.executableURL + ["ld"]`, and sanitized receipt generation.

No existing Provider/Profile/Authorization source, App source, Core spec, contract schema or
standing authorization was changed.

## Verification results

| Command / check | Result |
| --- | --- |
| `swift test --package-path Packages/ArkDeckKit --filter RockchipDeviceDiscoveryContractTests` | PASS: 5 tests, 0 failures |
| `python3 -m unittest scripts/rockchip_e0_probe/test_probe.py` | PASS: 3 tests, 0 failures |
| `python3 -m py_compile ...` | PASS |
| `xcrun swift-format lint --strict <three new Swift files>` | PASS |
| `ARKDECK_PYTHON=<temporary PyYAML-6.0.3 env> scripts/check-sdd.sh` | PASS: 0 errors, 0 warnings, 111 acceptance IDs |
| signed probe build + `codesign --verify --deep --strict` + entitlement equality | PASS; ad-hoc signature, Hardened Runtime, exact six entitlements |
| `swift test --package-path Packages/ArkDeckKit` | **PASS**: 328 tests executed, 1 skipped, 0 failures; allowed-paths blocker cleared by merged remediation PR #303 |

Contract anchors observed:

```text
TEST-AC-FLASH-001-01 PASS success=1 multi=1 maskrom=blocked similar=blocked malformed=blocked duplicate=blocked unknown=blocked similar_dispatch=0
TEST-AC-UX-007-01 PASS permission=distinct driver=distinct offline=distinct sudo=0 helper_install=0 system_rule=0 group_acl=0
```

### Full-suite blocker (cleared by remediation PR #303)

`ArkDeckContractTests.testPackageTargetsImportOnlyDeclaredArkDeckModules` had a hard-coded
dependency table in
`Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkDeckContractTests.swift`. It listed
`ArkDeckWorkflows` without `ArkDeckProcess`, so it failed after the approved design's discovery
adapter reuses `FoundationProcessExecutor` and `Package.swift` declares that dependency.

Updating the table was the direct fix, but that file was not in TASK-RKFUI-001 allowed paths.
Bypassing its import scanner, disabling the test, or replacing the shared executor with a second
process implementation would violate the task scope/design. Merged remediation PR #303 added this
exact test file with authority limited to synchronizing the hard-coded dependency table; the full
suite now passes as recorded above.

## Signed Sandbox E0 attempt

The harness was built locally because `security find-identity -v -p codesigning` reported zero
Developer ID identities. The app was nevertheless code-signed ad-hoc with Hardened Runtime,
strictly verified, and carried the same six entitlement keys as the current ArkDeck target. This
is local signed-Sandbox platform evidence only; it is not Developer ID/notarization/release
evidence.

The operator selected the exact pinned `rkdeveloptool` through `NSOpenPanel`; bookmark creation
and security-scope access succeeded. Before child launch, the harness observed valid ad-hoc
signature integrity but `com.apple.quarantine` present and Gatekeeper rejected. It therefore
returned typed `toolBlocked(quarantinePresent)` and launched no child. ArkDeck did not clear or
rewrite quarantine and did not attempt a helper/elevation workaround. The quarantine's origin
was not independently established, so this run records presence only and does not claim which
process added it.

See `sanitized-e0-receipt.json`. No full path, xattr payload, serial, LocationID or raw device
output is committed.

| Counter / gate | Result |
| --- | --- |
| exact user selection + bookmark | PASS |
| pinned hash/source/version tuple | PASS |
| platform trust | BLOCKED: quarantine present; Gatekeeper rejected |
| direct non-elevated `ld` | NOT DISPATCHED |
| USB semantic result | NOT OBSERVED |
| E1 HDC mode switch | 0 |
| device mutation / destructive | 0 / 0 |
| sudo/elevation/helper/driver install | 0 / 0 / 0 |
| system rule/group/ACL/global permission mutation | 0 |
| network | 0 |

## Acceptance conclusion and remaining risk

| AC | Contract result | Platform/E0 result | Conclusion |
| --- | --- | --- | --- |
| AC-FLASH-001-01 | strict parser/fault vectors PASS; similar-command dispatch 0 | real `ld` blocked before launch | partial; no direct-access proof |
| AC-UX-007-01 | permission/driver/offline advisor vectors PASS; all escalation/install/system counters 0 | signed Sandbox correctly exposes tool-trust block, but does not reach a USB permission/driver/offline observation | partial |

The execute-readiness gate is **blocked**. TASK-RKFUI-003/004 must not use sudo, remove
quarantine, copy the tool to evade assessment, install a helper, or otherwise treat this attempt
as PASS. After the allowed-path remediation, a new signed E0 attempt still needs an approved,
non-quarantined tool selection and a semantic single `0x2207:0x350a + Loader` observation before
direct access can pass.
