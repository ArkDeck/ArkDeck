# TASK-HOR-001 verification closure replay r1

Date:2026-07-29

Classification:`contract` + signed macOS build inspection. The accepted
signed UI behavior evidence remains the exact #772 `platform` run in
`implementation-r1.md`. This record is not installed-HDC or `realHardware`
evidence.

## Verdict

Protected-main base
`c2dd6412d42be259623d5922e82eb43b4b36af74` contains implementation merge
`7125cda045cb45ccb992997bcbe43fa5da90bdb3`. The six implementation/test
blobs and all production HDC authority inputs used by CHG-045 are unchanged.
Focused and full contract regressions, SDD/path checkers, localization and
strict codesign pass.

All four `HOR-*` conclusions therefore remain PASS using the concrete
same-revision evidence in `implementation-r1.md`. This record does not itself
approve `done` or `verified`; those states take effect only if the maintainer
reviews and merges the verification closure PR.

## Delivery and evidence identity

- PR #772 exact head
  `25a0d4a3789fdda985f9f13057e7e0dd8f217bde` was approved by maintainer
  `lvye` and merged as
  `7125cda045cb45ccb992997bcbe43fa5da90bdb3`.
- #772 checks:Agent PR open-pr/allowed-paths, SDD Guard and Swift CI =
  `SUCCESS`.
- Implementation run blob:
  `c8e104d809d6bcc9813b9ea5977ae64592a27680`.
- Implementation blobs retained at closure:

  ```text
  57d45bf03f314f21ea1b91898eb876ea708ce0f9  ArkDeckApp/App/ArkDeckApp.swift
  4841248c51347ba5332c9f0139c53f07df8dcf45  ArkDeckApp/Features/HDC/HDCStatusView.swift
  038ce1067f17b6c857d80508b13dcd3cefef0647  ArkDeckApp/Resources/Localizable.xcstrings
  9e09c41e01ee683981a717e2b2e8deda0b5e0edd  ArkDeckAppUITests/HDC/HDCStatusUITests.swift
  d4fda35b8040ada790bfe0c1990d3346978ea169  Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift
  daf0d88830be9b5a73e877e019a77deef908bbd1  Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationPresentationContractTests.swift
  ```

- Production/authority blobs retained at closure:

  ```text
  c7f71e5af90bc3d468d5f0817734d297f0c339a2  Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCProduction.swift
  399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6a  device-observation-probes.yaml
  b202b9d34680a0e7bbdba1d02637279ca4819d3f  supervisor-observation-probes.yaml
  2ae13490e075f327bb7448ccacf908be5ba7e3aa  OpenHarmony profile
  836d4ccc8c34c5826b6c53dcf9004e678a506d25  integration lock
  b7471666b0bbfbfade3fbd510ad831e45b3cf9b8  macOS profile
  ```

## Closure replay

Environment:

```text
macOS 26.6 (25G72), arm64
Xcode 26.6 (17F113)
Apple Swift 6.3.3 (swiftlang-6.3.3.1.3, clang-2100.1.1.101)
```

| Command/gate | Result |
| --- | --- |
| five focused HDC suites (`HDCDeviceObservationPresentation`, device/supervisor registries, supervisor observability and supervisor) | PASS, 132/132 |
| `CI=true swift test --package-path Packages/ArkDeckKit` | PASS, 557 listed tests, one existing opt-in manual sleep/wake skip, 0 failures |
| `scripts/check-sdd.sh` | PASS, 0 errors / 0 warnings / 111 IDs |
| shared SDD Python `scripts/test_check_sdd.py` | PASS, 62/62 |
| `python3 scripts/test_check_pr_paths.py` | PASS, 50/50 |
| JSON parse + `xcstringstool compile --dry-run` | PASS, `en` and `zh-Hans` |
| `git diff --check` | PASS |
| strict `codesign --verify --deep --strict` for current App and UI runner | PASS |

Current signed build identity:

```text
App Identifier=com.arkdeck.desktop
App Signature=adhoc
App CDHash=ce104b4d61c11396c07fc2fd9cccabf65d62c50d
App executable sha256=4f453d7abc8e310d3a592e3c92e1853f0943914ecc466edb43c9ee963a899905
App executable size=15008032

Runner Identifier=com.arkdeck.desktop.hdcuitests.xctrunner
Runner Signature=adhoc
Runner CDHash=984d12e3d7cecf43cf69650333c25b0eb338ae6c
Runner executable sha256=ac1c690254ca77990459b4273893e4e820667cb741986d68e76ea519c1ad93a6
Runner executable size=93232
```

## Signed UI replay observation

The current SwiftPM fake source blob is unchanged. Its closure rebuild was
131,888 bytes with SHA-256
`81d8cda98074c4c5c75670802b03fd156445dc1a6b72e2e60d6d273c67912b9f`.
A visible hardlink with the same inode/digest was created for the UI harness,
then removed; the worktree returned clean.

Two extra UI replay attempts were rejected by macOS LocalAuthentication
before any test executed because the Mac was locked (`System authentication
is running`, xcodebuild exit 65). Restarting the failed test's
`testmanagerd` did not alter that OS gate. No authentication, permission or
system-setting change was requested or granted.

These attempts are not counted as PASS. `HOR-UI-001` and the platform part of
`HOR-BOUNDED-001` rely on the exact #772 signed UI result (16/16, 0 failures)
in `implementation-r1.md`; every App/fixture/UI-test blob from that run is
byte-identical at the closure base. The locked-host observation is an
environmental replay limitation, not hardware or product evidence.

## AC and effect boundary

- `HOR-UI-001`:PASS (`platform` + `contract`), using #772 signed 16/16 and
  unchanged source/test blobs.
- `HOR-SESSION-001`:PASS (`contract`), with closure-focused sequential
  same-session coverage.
- `HOR-BOUNDED-001`:PASS (`platform` + `contract`), using #772 delayed signed
  UI evidence plus closure-focused admission/source contracts.
- `HOR-SAFETY-001`:PASS (`contract`), with exact source/blob identity and
  closure regressions.

Closure activity executed no installed HDC and accessed no real device.
Declared counters remain:

```text
installed_hdc_child=0
real_device=0
server_lifecycle_dispatch=0
subserver_dispatch=0
authorization_or_adoption=0
binding_or_device_mutation=0
destructive=0
non_loopback_product_network=0
```

Open PR #777 was audited at this base. It proposes a future modification to
`HDCProduction.swift`, but is unmerged, has no maintainer review and its
allowed-paths check is red. It supplies no current authority. If it or any
other PR changes a pinned production/implementation input before this
closure merges, verification must rebase and replay rather than infer
equivalence.
