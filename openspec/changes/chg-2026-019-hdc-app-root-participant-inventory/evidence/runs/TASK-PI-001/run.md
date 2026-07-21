# TASK-PI-001 Run — App-root participant registry 与 production inventory feed

- Date:2026-07-21
- Base revision:`3325d42`(= readiness PR #202 squash;readiness pins 复核基准 `94fe6f8`
  之后 main 仅前进 #202 本身与 #203/#204 的治理分支——目标代码面自 `c61e10e` 起零漂移,
  readiness 有效)
- Environment:macOS 26.5.2 arm64,Xcode 26.6,Swift 6.3.3;解锁态;签名 = ad-hoc
  (`Signature=adhoc`,TeamIdentifier not set,与 M1-006 addendum 21 同级);验证仅
  fake/loopback/临时目录,零真实 hdc/设备/非 loopback 网络。

## Implemented closure

- `HDCApplicationParticipantRegistry`(新文件,package actor):App-root 唯一注册路径;
  duplicate 注册与 unknown-recipient 更新均使 `isConsistent=false`,此后 inventory 恒
  fail-closed `.unavailable`;`inventory(for:)` 产出 endpoint 范围内构造性完备的
  `.complete`(当前产品态 = 空但完备)。
- Production facade:硬编码 `.unavailable` inventory 替换为
  `HDCApplicationParticipantRegistry.shared.inventory(for:)`。App 可达面(App 只能
  import Core/Workflows,`package` 符号对 App 不可见)不含任何 registry 外的 recipient
  注册路径——完备性由构造成立。
- Supervisor 安全不变量零触碰:两类显式 reliability receipt 语义、duplicate/跨 endpoint
  fail-closed 分支、`@_spi(Testing)` 边界均不变(本任务只满足它们,不放宽)。
- UI 面:production 启动的 inventory-unavailable 文案消失;participant 门由 registry feed
  满足后,阻断理由收敛为 server-identity/endpoint 前置(`impactCannotBeReliablyDetermined`,
  对非 pinned `/usr/bin/true` 候选)。App Swift 源码零改动(facade 为 Workflows 内部)。

## Static completeness argument(构造性完备)

- App import contract(既有 `ArkDeckContractTests` 依赖/import 扫描,本 run 全量套件内
  复跑通过):App 仅 import ArkDeckCore/ArkDeckWorkflows;`package` 可见性使
  `HDCApplicationHostImpactInventory`/`compose`/registry 对 App 均不可直接构造或绕行。
- 静态扫描(本工作树):`HDCApplicationDiagnosticsFacade.swift` 中 `impactInventory:`
  唯一来源 = registry(`grep -c "impactInventory:"` = 1,literal `.complete(` 计数 0);
  `HDCSessionDiagnosticsBootstrap.makeHost` 保持 fileprivate(#191 收口不变)。

## Commands

| Command / check | Result |
| --- | --- |
| `xcrun swift-format lint --strict <4 changed Swift files>` | pass,0 diagnostics |
| `CI=true swift test --package-path Packages/ArkDeckKit --filter HDCSupervisorContractTests` | pass,55 tests / 0 failures(+3:registry 空-完备/critical-gate/duplicate) |
| `CI=true swift test --package-path Packages/ArkDeckKit` | pass,287 tests / 1 existing opt-in skip / 0 failures |
| signed `xcodebuild ... -derivedDataPath /private/tmp/arkdeck-pi-001-derived-20260721-1130 test`(attempt 2) | pass,9 / 9 / 0 failed;bundle `Logs/Test/Test-ArkDeck-2026.07.21_11-35-36-+0800.xcresult` |
| 同命令 attempt 1(如实记录) | 8/9;唯一失败 = `testUserPickerPersistsBookmarkAcrossRelaunch`,因可见 picker 硬链 `ArkDeckFakeHDCFixture-M1-006` 缺席回退到隐藏 `.build` 路径导致 Finder 选择未落地(M1-006 已知环境适配,addendum 21 同因);按操作者惯例重建硬链(与 repo fake 字节相同,`cmp` 验证)后全绿。硬链为操作者环境产物,不入仓 |
| `codesign --verify --deep --strict <ArkDeck.app>` | pass;ad-hoc,TeamIdentifier not set |
| App executable SHA-256 | `bf19e60a452b7fc1d9badafcaf9ef65cb02b9589c4ac66f5daad9cb3e5bd7717` |
| `./scripts/check-sdd.sh` | pass,0 error / 0 warning / 111 acceptance IDs |
| `git diff --check` | pass |

## Binary conclusions

| Evidence ID | 结论 | Evidence class |
| --- | --- | --- |
| `PI-HDC-INVENTORY-001` | PASS — 空-完备 → participant receipt 满足且 identity receipt 缺失仍 blocked;registry 注入 critical Flash Job → preview `affectedJobs` 精确含之、dispatch `.blocked(.criticalJobs)`、invocation log 缺席(实测 0);duplicate/unknown-update → inventory fail-closed、preview unavailable;跨 endpoint participant 不入本 endpoint scope | contract |
| `PI-HDC-INVENTORY-002` | PASS — production 启动(非 fixture)inventory-unavailable 文案缺席断言 + `recoveryBlocked` 精确值 `impactCannotBeReliablyDetermined`;fixture 场景既有断言零回归(9/9);签名产物 hash/身份在案 | platform(signed) |

## Boundaries

TASK-M1-006 closeout 缺口 ① 的产品面与证据面由本 run 关闭;M1-006 自身状态、其 done/
closeout 修订、CHG-2026-002 verified、platform conformance、hardware/support、release
均不由本 run 构成。`done` 翻转须独立状态 PR。
