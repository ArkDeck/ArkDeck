# TASK-AU-001 一手来源清单

- Access date:2026-07-23
- Source boundary:Sparkle 官方站/固定 Git OID、Apple Developer Documentation/
  本机 Apple SDK public interface、本仓库 pinned inputs。
- Read mode:网页、Git tree/blob、SDK header/interface 只读。
- Prohibited/observed absent:clone/install/build/run Sparkle = 0；release ZIP
  download = 0；release tool/feed/key/service creation = 0。

## Sparkle 2.9.4

固定 source identity：

- tag:`2.9.4`
- peeled Git OID:`b6496a74a087257ef5e6da1c5b29a447a60f5bd7`
- tree:
  <https://github.com/sparkle-project/Sparkle/tree/b6496a74a087257ef5e6da1c5b29a447a60f5bd7>

| ID | Stable URL / pin | 本评估采用的事实 |
| --- | --- | --- |
| `SP-SBX` | <https://sparkle-project.org/documentation/sandboxing/>；accessed 2026-07-23 | sandboxed App 需要 Installer XPC；exact Mach lookup temporary exception；已有 `network.client` 时不要启用 Downloader XPC；Archive/Export 与嵌套签名差异 |
| `SP-CFG` | <https://sparkle-project.org/documentation/customization/>；accessed 2026-07-23 | 自动检查/安装、profiling、signed feed、pre-extraction verification、20 天 failure expiration 与 sandbox service 配置 |
| `SP-PROFILE` | <https://sparkle-project.org/documentation/system-profiling/>；accessed 2026-07-23 | profiling 字段列表、GET 参数及显式 opt-in |
| `SP-UI` | <https://sparkle-project.org/documentation/custom-user-interfaces/>；accessed 2026-07-23 | custom user driver 必须展示 UI；silent install 属 automatic update 路径；授权提示须由用户控制 |
| `SP-SECURITY` | <https://sparkle-project.org/documentation/security-and-reliability/>；accessed 2026-07-23 | 2.9.4 安装超时、delta symlink 与 appcast spoof/race 修复；历史原子 file operation/installer hardening |
| `SP-SECURITY-SOURCE` | [Documentation/Security.md](https://github.com/sparkle-project/Sparkle/blob/b6496a74a087257ef5e6da1c5b29a447a60f5bd7/Documentation/Security.md#L9) | 组件/XPC privilege separation；installer 同进程承担 extraction/validation/installation；XPC Team checks |
| `SP-PKG` | [Package.swift](https://github.com/sparkle-project/Sparkle/blob/b6496a74a087257ef5e6da1c5b29a447a60f5bd7/Package.swift#L4-L25) | version/tag = 2.9.4；binary target release URL；上游 artifact checksum |
| `SP-LICENSE` | [LICENSE](https://github.com/sparkle-project/Sparkle/blob/b6496a74a087257ef5e6da1c5b29a447a60f5bd7/LICENSE) | MIT 主许可与 bundled external licenses |
| `SP-VALIDATOR` | [SUUpdateValidator.m](https://github.com/sparkle-project/Sparkle/blob/b6496a74a087257ef5e6da1c5b29a447a60f5bd7/Sparkle/SUUpdateValidator.m#L330-L418) | EdDSA 与 code-signing 分别计算；实际 accept 条件为 `passedDSACheck \|\| passedCodeSigning` |
| `SP-CODESIGN` | [SUCodeSigningVerifier.m](https://github.com/sparkle-project/Sparkle/blob/b6496a74a087257ef5e6da1c5b29a447a60f5bd7/Autoupdate/SUCodeSigningVerifier.m#L26-L142)；[Developer ID Team fallback](https://github.com/sparkle-project/Sparkle/blob/b6496a74a087257ef5e6da1c5b29a447a60f5bd7/Autoupdate/SUCodeSigningVerifier.m#L323-L443) | designated requirement/all-architecture validation；Developer ID Team requirement 构造存在，但 update validator 将它作为 fallback/OR 信任链使用 |
| `SP-DELEGATE` | [SPUUpdaterDelegate.h](https://github.com/sparkle-project/Sparkle/blob/b6496a74a087257ef5e6da1c5b29a447a60f5bd7/Sparkle/SPUUpdaterDelegate.h#L232-L356) | 下载前可拒绝；download/extract/install 周期公开回调为通知，未暴露额外安装 admission 返回门 |
| `SP-UA` | [SPUUserAgent+Private.m](https://github.com/sparkle-project/Sparkle/blob/b6496a74a087257ef5e6da1c5b29a447a60f5bd7/Sparkle/SPUUserAgent%2BPrivate.m#L12-L38) | 默认 User-Agent = App name/display version + Sparkle version |
| `SP-UPDATER` | [SPUUpdater.h](https://github.com/sparkle-project/Sparkle/blob/b6496a74a087257ef5e6da1c5b29a447a60f5bd7/Sparkle/SPUUpdater.h#L329-L350)；[SPUUpdater.m](https://github.com/sparkle-project/Sparkle/blob/b6496a74a087257ef5e6da1c5b29a447a60f5bd7/Sparkle/SPUUpdater.m#L108-L116) | User-Agent/header 可公开覆盖；默认值由 main bundle 生成 |
| `SP-APPCAST` | [SUAppcastDriver.m](https://github.com/sparkle-project/Sparkle/blob/b6496a74a087257ef5e6da1c5b29a447a60f5bd7/Sparkle/SUAppcastDriver.m#L66-L106) | appcast request 注入 User-Agent/Accept header；signed feed 在 parse 前抽取并验证 |

固定 OID 下还只读检查了 `SUConstants.m`、`SPUDownloadDriver.m`；它们只用于
交叉核对 key/header 控制流，没有引入额外结论来源。

## Apple

| ID | Official URL / local SDK anchor | 本评估采用的事实 |
| --- | --- | --- |
| `APPLE-ED25519` | <https://developer.apple.com/documentation/cryptokit/curve25519/signing/publickey/isvalidsignature(_:for:)>；macOS 26.5 SDK `CryptoKit.swiftinterface` | `Curve25519.Signing.PublicKey.isValidSignature` 可验证 Ed25519/EdDSA signature；macOS 10.15+ |
| `APPLE-STATIC` | <https://developer.apple.com/documentation/security/secstaticcodecheckvalidity(_:_:_:)>；macOS 26.5 SDK `Security.framework/Headers/SecStaticCode.h` lines 128-199 | static validation 验证签名、sealed components 与可选 requirement；`kSecCSCheckAllArchitectures` 覆盖 universal binary 全部架构 |
| `APPLE-DESIGNATED` | <https://developer.apple.com/documentation/security/seccodecopydesignatedrequirement(_:_:_:)>；macOS 26.5 SDK `Security.framework/Headers/SecCode.h` lines 307-328 | 可从旧 code object 取得 designated requirement 作为后续 identity check 输入 |
| `APPLE-TEAM` | <https://developer.apple.com/documentation/lightweightcoderequirements/teamidentifier>；macOS 26.5 SDK `Security.framework/Headers/SecCode.h` line 497 | code signing information/requirement 可约束 Team identifier |
| `APPLE-TEMP-ENT` | <https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html> | global Mach lookup temporary exception 会扩大 sandbox lookup 能力，必须精确列名 |

本机 SDK 只作为 Apple 安装工具链的公开 interface 镜像复核；没有编译或运行
任何验证代码，也没有把 SDK 版本可用性冒充 AU-002 的运行 contract。

## ArkDeck pinned inputs

| ID | Path | Git blob OID / fact |
| --- | --- | --- |
| `LOCAL-DESIGN` | `openspec/changes/chg-2026-023-macos-auto-update/design.md` | `f25882d74e7d1a7ba7953ad33f255e414398271f`；双层 AND、零静默、隐私白名单与两候选定义 |
| `LOCAL-VERIFY` | `openspec/changes/chg-2026-023-macos-auto-update/verification.md` | `e171304af3bf02a4641fc72dc25465e12d5ec8aa`；`AU-EVAL-001` 与后续 negative matrix |
| `LOCAL-AC` | `openspec/changes/chg-2026-023-macos-auto-update/acceptance-cases.yaml` | `dd3264dea573bf04e776a47cc4344f15c7a46a03`；不同 Team/未签名/中断/截断均零安装动作 |
| `LOCAL-ADR` | `docs/adr/0002-macos-v1-sandboxed-distribution.md` | `5111bb8c8657d0ed05e0184fbbaeb88af5fc5d8f`；当前六项 entitlement 基线 |
| `LOCAL-PROFILE` | `openspec/platforms/macos/profile.md` | `a9a5931ffedd304a7ce3a088f4397c26fd87e744`；macOS sandbox/network/signing profile |
| `LOCAL-PKG` | `Packages/ArkDeckKit/Package.swift` + `ArkDeck.xcodeproj/project.pbxproj` | `91a1032f8a5ff9285154ef6f48ef35470b294eb7` / `e7943096688728a22f4b940e536a32f3b8eaaf98`；零 external package / 零 `XCRemoteSwiftPackageReference`；仓库无 `Package.resolved` |
| `LOCAL-ENT` | `ArkDeckApp/ArkDeckApp.entitlements` | `6435d00f8493ce4fbca24a806ca7f320db9fbfa6`；精确六项且含 `network.client` |

另两个 readiness pins 也已复核无漂移：

- `proposal.md` =
  `c7515254522f3f049fc7e89098eb3d522a91ded9`
- `verification.md` 已列为 `LOCAL-VERIFY`

所有 local OID 均相对实际 base
`ba67d59980a2e3f84efe142f607f092ee3f29c6d` 复核；本 evidence 没有改动这些
输入。
