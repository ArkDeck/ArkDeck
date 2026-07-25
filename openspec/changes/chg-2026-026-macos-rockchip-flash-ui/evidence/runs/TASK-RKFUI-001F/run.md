# TASK-RKFUI-001F — read-only bookmark option remediation

- Captured:2026-07-25T02:54:07Z–2026-07-25T02:55:51Z
- Executor:agent（两次 `NSOpenPanel` 选择由维护者完成）
- Evidence class:`signedSandboxHostOnlyBookmarkOptionRemediation`
- Result:`passed`
- Hardware required/used:no/no

## Input closure

- proposal r8 由 PR #513 合入，merge OID
  `177c50086b413536b4b867c9885ecb2f0ce2fee2`；本分支从该 exact `main` 创建。
  从 PR #512 merge OID `56af827a26470f5a9273ca684c9a32b9d39afc4c` 到 r8 merge
  只修改本 change 的 `proposal.md`、`design.md`、`tasks.md` 与 `verification.md`。
- r8 merge 后四个治理文件 blob 为
  `094c939e938b3845de07c0decdb9a22ef700134c` /
  `0e11d6d592189dda5fcfced069dd70e1d4132450` /
  `f3023104926fc24463c882eaf5a8979bb8c1f038` /
  `395e801f57f9cc93f840999b803df181ade4246c`。
- implementation 开始前，main Probe Python/App/entitlement/tests 精确命中 r8 pins：
  `b703baecb0c80a18e73b40028163cc1adda22133` /
  `2c763da059c7adf65a4aec170e71c042dbed4288` /
  `dab555e5b3d03480ab43403ae25a34a6e6822e11` /
  `3ffc0f7ac675af1bf9ed3b6e21daf1c059feec2a`。
- PR #512 direct/symlink historical receipt SHA-256 分别精确为
  `9525cae0b8a45bf0107ed08d9f6d4d383c312b7e3cc2c5b72e366630d6c7fc47` /
  `4de519e88e685ab32b36a0c497087bc08a387c8c98d0a7b164282aec18e15ddf`；
  两份 blocked evidence 未改写或重分类。
- 实现后的 Probe Python/App/entitlement/tests/README/fixture-source blobs 为
  `3ff1a3ea6e22f7b15509274f871482cd96708f1a` /
  `cc75588161682254083d70278e9fb43023666c9f` /
  `f2c71dc71c38abe01829e6000d10ae49a2272f04` /
  `68db205919b6bc66e4b7383273697186e51565e4` /
  `d40220be3480fcc685096d597697c811dd859e1c` /
  `3556f0204fc706d29f407c732ca97b83bb3c97ae`。

## Platform/API basis

- Apple `withSecurityScope` 与 `securityScopeAllowOnlyReadAccess` 文档所定义的合法组合：
  <https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/withsecurityscope>
  与
  <https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/1418284-securityscopeallowonlyreadaccess>。
- Xcode 26.6 macOS 26.5 SDK 的 `Foundation/NSURL.h` 登记
  `NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess` 自 macOS 10.7 可用，并说明它与
  security scope 合用时只授予 read access。
- 相对 #512 临时候选，行为变量精确为 bookmark creation options 从
  `[.withSecurityScope]` 变为
  `[.withSecurityScope, .securityScopeAllowOnlyReadAccess]`。resolution 仍精确为
  `[.withSecurityScope, .withoutUI]`。
- `user-selected.read-write` 只替换为 `user-selected.read-only`；其余五项 entitlement、
  bundle ID、Hardened Runtime、pinned hash/signature/quarantine ordering 与固定
  `["ld"]` adapter 不变。没有 document-scope、implicit-only fallback、
  `user-selected.executable`、Info.plist quarantine override 或主 App 变更。
- bookmark failure 拆成 `bookmarkCreationFailed` /
  `bookmarkResolutionFailed`，只允许 Foundation error domain/code；message、path、
  locator、bookmark bytes 与 raw xattr 不进入 sanitized receipt。
- bookmark 已创建、但后续 executable inspection 失败时如实保留
  `bookmarkCreated=true`；preflight 仍以 `executableInspectionFailed` fail closed，
  不产生 child dispatch。

## Environment and build

- macOS `26.5.2` (`25F84`), arm64
- Xcode `26.6` (`17F113`)
- Apple Swift `6.3.3`
- Apple clang `21.0.0` (`clang-2100.1.1.101`)
- Python `3.14.6`

具体 build/run 路径均位于一个 fresh private-temp root，以下以占位符记录：

```text
python3 scripts/rockchip_e0_probe/probe.py build-fixture \
  --output-root <private-temp>/fixture
python3 scripts/rockchip_e0_probe/probe.py build \
  --output-root <private-temp>/direct-app
python3 scripts/rockchip_e0_probe/probe.py build \
  --output-root <private-temp>/symlink-app
```

- disposable fixture basename=`rkdeveloptool`，SHA-256
  `ac16dc31b98440622c19af303c4c5082a872669dffe88fab36a9b0b3bbec257b`，
  与 registry pin 不同；regular/executable、ad-hoc signed、CDHash
  `5646303119253586ce9c21f8440def813a259801`、quarantine absent。
- 两个 fresh App executable SHA-256 都为
  `9c1b65ab89a862f5d60c88279c07fd7fd91073e6e9bfa35a75f74b5dbea9099c`；
  均通过 `codesign --verify --deep --strict`、Hardened Runtime 与 exact six-entitlement
  equality。
- fixture build receipt SHA-256 =
  `5607c3fd3a243f1e9d1690e3153e6ed8c88bf377b2956dc5e03c8073a5b2ba1d`；
  两个 App build receipt SHA-256 都为
  `39830ab2a5f3d278abb44d91c2464c12b7473d5c1b33aeaaf3d8b9196ec17e89`。

## Run matrix

### Canonical direct

```text
python3 scripts/rockchip_e0_probe/probe.py characterize \
  --app <private-temp>/direct-app/RockchipE0ProbeApp.app \
  --fixture-root <private-temp>/fixture \
  --selector canonicalDirect \
  --receipt <private-temp>/direct-selection-receipt.json \
  --raw-root <private-temp>/direct-raw
```

- Exact canonical entry selected；returned URL lexical match 与 resolved-target equality
  均为 true。
- bookmark creation/resolution/security scope 全部成功；App 观察到 fixture exact hash、
  valid signature 与 quarantine absent。
- `preflightFailure=executableHashMismatch`、`childLaunchAttempted=false`，fixture 未执行。
- Host pre/post target bytes/size/CDHash/signature 不变且 quarantine absent。
- Verdict:`passed`；sanitized receipt SHA-256 =
  `6c1ceecec431468bdee7f097f4516659baa62289fdf84d48ee2e2e5ce0641a98`。

### Single-layer symlink

```text
python3 scripts/rockchip_e0_probe/probe.py characterize \
  --app <private-temp>/symlink-app/RockchipE0ProbeApp.app \
  --fixture-root <private-temp>/fixture \
  --selector singleLayerSymlink \
  --receipt <private-temp>/symlink-selection-receipt.json \
  --raw-root <private-temp>/symlink-raw
```

- Host pre/post 都证明 picker input 是一层 symlink，且解析到同一 fixture。
- `NSOpenPanel` returned URL 未 lexical 保留 symlink entry
  (`selectedEntryLexicallyMatched=false`)，但 resolving 后精确命中同一 target；按 r8
  这是 observation，不是失败门。
- bookmark、App hash/signature/quarantine、wrong-hash preflight 与 host metadata gates
  全部同 canonical run PASS；fixture 未执行。
- Verdict:`passed`；sanitized receipt SHA-256 =
  `6bbd415b649a17e9a5b549bec4cd1880f094818abe2abe218efd2fb33975267d`。

## Safety and dispatch accounting

两个 sanitized receipt 的以下计数全部为 0：

```text
selectedProcess ldReadOnly usb network hdc device deviceMutation destructive
sudoOrPrivilegeElevation helper driverInstall systemRuleMutation groupMutation
aclMutation xattrWrite
```

没有运行 fixture 或真实 `rkdeveloptool`，没有 HDC、USB/device、E1/E2、mutation、
destructive、network、privilege、install、system-rule/group/ACL 或 xattr-write dispatch。
raw stdout/stderr 为空。仓内 evidence 不含 locator、full path、bookmark bytes、raw xattr、
serial 或 LocationID。

## Verification

```text
python3 -m unittest scripts/rockchip_e0_probe/test_probe.py -v
# 11 tests, PASS

ARKDECK_PYTHON=<private-temp-sdd-venv>/bin/python sh scripts/check-sdd.sh
# 0 errors, 0 warnings, 111 acceptance IDs

python3 <repository-safe receipt assertions>
# PASS

git diff --check
# PASS
```

Tests 明确覆盖 exact six-key entitlement、creation/resolution option sets、禁止的
read-write/executable-writing entitlement、Info.plist quarantine override、document/implicit
bookmark options、stage-specific sanitized error contract、deterministic wrong-hash fixture、
symlink lexical non-gate 与全零 dispatch surface。

额外运行完整 `CI=true swift test --package-path Packages/ArkDeckKit`：400 tests 中
397 passed、1 skipped、2 failed。失败仅为既有
`HDCGoldenResourceContractTests.testGoldenPackContainsExactRegisteredFixtureSetWithMatchingHashes`
与
`HDCProbeRegistryContractTests.testPackContainsExactPinnedResourceSetAndHashes`；
两者在 `/private/tmp` worktree 下把 resource path 前缀错误归一化为
`/private1.0.0/...`。同两组测试在 exact `origin/main`
`177c50086b413536b4b867c9885ecb2f0ce2fee2` 的独立 `/private/tmp` worktree
同样为 10 tests / 2 failures。本任务未修改 `Packages/**`，该路径归一化问题不在
001F allowed paths，未在本 PR 中顺带修复。

## AC conclusion and handoff

- TASK-RKFUI-001F implementation/evidence result:`passed`。
- 本结果只证明 disposable fixture 上的 signed Sandbox read-only PowerBox/bookmark
  metadata 行为；不是 external executable launch、RockUSB/Loader、realHardware、主 App
  output-directory 或 product-delivery evidence。
- 本 PR 不修改 task status。按 r8 sequencing，implementation/evidence 合入后只允许独立
  D0 status PR；TASK-RKFUI-001 继续 blocked，产品/真实 E0 boundary 仍须新 D1。
