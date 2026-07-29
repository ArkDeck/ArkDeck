# TASK-HOR-001 post-merge concurrency replay r2

Date:2026-07-29

Classification:`contract` + signed macOS fixture `platform`. This record is
not installed-HDC or `realHardware` evidence.

## Why this replay exists

PR #777 merged immediately before the CHG-045 verification PR:

```text
#777 head  = 5c30a59f88446050cd69cbec62e39476d0588747
#777 merge = 031ad5a0c7f186c389d5789acfb553e3f37a2ac6
#778 head  = 27272b99298ea5ec9a1f7370dd0decb15ac528a5
#778 merge = eb24e6625a345578108781649ed19b2598024ade
```

Both PRs were approved by maintainer `lvye`. The #778 squash commit has
`031ad5a0c7f186c389d5789acfb553e3f37a2ac6` as its sole parent, so protected
main contains both changes in that order. However, `verification-r1.md` was
executed before #777 merged and explicitly required a replay if #777 changed
a pinned production input. #777 changed `HDCProduction.swift`; applying #778
on top of #777 did not itself execute the CHG-045 verification commands.

This D0 evidence rerun repairs that concurrency condition on protected-main
commit `eb24e6625a345578108781649ed19b2598024ade`. It changes no scope, product
code, authority, task state or acceptance conclusion. The archive gate remains
held until this record is reviewed and merged; archive stays a later,
standalone decision.

## Drift audit

The six CHG-045 implementation/test blobs remain byte-identical to the accepted
#772 platform run:

```text
57d45bf03f314f21ea1b91898eb876ea708ce0f9  ArkDeckApp/App/ArkDeckApp.swift
4841248c51347ba5332c9f0139c53f07df8dcf45  ArkDeckApp/Features/HDC/HDCStatusView.swift
038ce1067f17b6c857d80508b13dcd3cefef0647  ArkDeckApp/Resources/Localizable.xcstrings
9e09c41e01ee683981a717e2b2e8deda0b5e0edd  ArkDeckAppUITests/HDC/HDCStatusUITests.swift
d4fda35b8040ada790bfe0c1990d3346978ea169  Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift
daf0d88830be9b5a73e877e019a77deef908bbd1  Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationPresentationContractTests.swift
```

The registry/profile inputs also remain byte-identical:

```text
399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6  openspec/integrations/openharmony/device-observation-probes.yaml
b202b9d34680a0e7bbdba1d02637279ca4819d3f  openspec/integrations/openharmony/supervisor-observation-probes.yaml
2ae13490e075f327bb7448ccacf908be5ba7e3aa  openspec/integrations/openharmony/profile.md
836d4ccc8c34c5826b6c53dcf9004e678a506d25  openspec/integrations/INTEGRATION-PROFILES.lock.yaml
b7471666b0bbfbfade3fbd510ad831e45b3cf9b8  openspec/platforms/macos/profile.md
```

#777 changed the production source identity:

```text
old c7f71e5af90bc3d468d5f0817734d297f0c339a2  HDCProduction.swift
new aadaa46d2338155ffa97a53a8b1468f186fb2111  HDCProduction.swift
new 0b2d4edbccb038f9b8a39fa0343678791db75982  HDCEndpointSelection.swift
new a8c13c52266826eb51caedffdeaae86886597dac  HDCAuthorizationAndSecurity.swift
```

The diff moves endpoint selection and authorization/security declarations into
same-module sibling files, adds their shared imports/headers, and leaves the
device-observation family plus dispatch-security core in
`HDCProduction.swift`. The current-source DP1/DP13/DP19 and C6 scans, exact
registry tests and the full regression replay below pass; equivalence is
therefore demonstrated rather than inferred from the #777 description.

## Replay environment

```text
macOS 26.6 (25G72), arm64
Xcode 26.6 (17F113)
Apple Swift 6.3.3 (swiftlang-6.3.3.1.3, clang-2100.1.1.101)
```

## Commands and results

| Command/gate | Result |
| --- | --- |
| five focused HDC suites (`HDCDeviceObservationPresentation`, device/supervisor registries, supervisor observability and supervisor) | PASS, 132/132 |
| `CI=true swift test --package-path Packages/ArkDeckKit` | PASS, 583 executed, one existing opt-in manual sleep/wake skip, 0 failures |
| signed `xcodebuild ... test -only-testing:ArkDeckHDCUITests/HDCStatusUITests` on current main | PASS, 16/16, 0 failures |
| strict `codesign --verify --deep --strict` for the rebuilt App and UI runner | PASS |
| `scripts/check-sdd.sh` | PASS, 0 errors / 0 warnings / 111 IDs |
| shared SDD Python `scripts/test_check_sdd.py` | PASS, 62/62 |
| `python3 scripts/test_check_pr_paths.py` | PASS, 50/50 |
| `jq -e` plus `xcstringstool compile --dry-run` | PASS, `en` and `zh-Hans` |
| `git diff --check` | PASS |

The signed UI suite used
`Packages/ArkDeckKit/.build/debug/ArkDeckFakeHDCFixture`. Its temporary visible
hardlink had the same inode, size and SHA-256, then was removed:

```text
inode=102540497
size=131888
sha256=81d8cda98074c4c5c75670802b03fd156445dc1a6b72e2e60d6d273c67912b9f
```

Current signed build identity:

```text
App Identifier=com.arkdeck.desktop
App Signature=adhoc
App CDHash=f833e4ff9b83b95fd07217b04650cef5dea52765
App executable sha256=b8720b1a763dc99da5b01a9c439daba1b6703c73d56b41cea4ae9ef52ed83227
App executable size=15483392

Runner Identifier=com.arkdeck.desktop.hdcuitests.xctrunner
Runner Signature=adhoc
Runner CDHash=ce9cedc1861665e3b956ed41234b5e90a3dc8a60
Runner executable sha256=9ff19f25d6b4656bb8c1da40ea5b39f778c11a12663e4c3d1a76c5226871f24a
Runner executable size=93232
```

The system `python3 scripts/test_check_sdd.py` probe lacks PyYAML and is not
the repository contract; `check-sdd.sh` selected the pinned shared interpreter,
which passed all 62 tests. A sandboxed ancillary `xcresulttool` summary export
could not write its private `TestReport` scratch file; the authoritative
`xcodebuild` command itself exited zero and reported 16/16 in both console and
the generated result bundle.

## Acceptance and effect boundary

- `HOR-UI-001`:PASS (`platform` + `contract`) on the fresh current-main signed
  English/Simplified-Chinese accessibility and callback replay.
- `HOR-SESSION-001`:PASS (`contract`) through the fresh same-session sequential
  observation and production-root suites.
- `HOR-BOUNDED-001`:PASS (`platform` + `contract`) through the fresh delayed
  fixture, duplicate-action and exact one-provider-call replay.
- `HOR-SAFETY-001`:PASS (`contract`) through current-source scans, exact
  registries, strict signed production/fixture separation and zero forbidden
  effects.

The signed run executed only the contract fixture. It did not use an installed
HDC or a real device and did not grant lifecycle/device authority:

```text
contract_fixture_process=yes
installed_hdc_child=0
real_device=0
server_lifecycle_dispatch=0
subserver_dispatch=0
authorization_or_adoption=0
binding_or_device_mutation=0
destructive=0
non_loopback_product_network=0
```
