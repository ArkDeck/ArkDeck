# CHG-2026-023 Tasks

> 两任务分期,各自独立 readiness/实现/done PR。本 change 首 PR 只 proposal +
> design,零实现、零依赖引入、零 evidence。

## TASK-AU-001 — 更新机制评估与选型(documentReview,host-only)

- Status:done(2026-07-23 D0 完成状态；仅在维护者 review/merge 本独立状态
  PR 后生效。选型/evidence PR #429 head
  `4085fe7f4e05072edd2631d5fe8d28b44c1ef9ae` 已由 `lvye` exact-head
  APPROVED 并合入 protected `main`
  `a8084cd1a77205b7014c45e7733445c30642ffd9`；合入版
  `evaluation.md`/`sources.md`/`run.md` blobs =
  `fcbfa0dd23220b833e3a2b4eef28129ea88b3a0f`/
  `2efee2309b7eb59cc0ed7f5fe6e036756c174322`/
  `e897ec3d938225483491ce10735ce3aebd8c85b4`。`TEST-AU-EVAL-001` =
  **PASS(candidate evidence)**：五维 documentReview 推荐最小自研
  check+download+verify，以显式 EdDSA **AND** same-Team gate 后再由用户
  挂载 DMG/手工替换；third-party dependency/file download/code execution =
  0/0/0，`check-sdd` = 0 error/0 warning/111 acceptance IDs，exact-head
  Swift/guard/PR allowed-paths 均绿。本翻转仅确认 TASK-AU-001 done，不把
  change 标为 verified、不授权产品实现；TASK-AU-002 仍 blocked 于本状态 PR
  合入后的独立 readiness，须固定选型合同与 implementation base)
- Readiness review(2026-07-23；host-only，external code/network service/device
  dispatch 0):
  - Approval/dependency gate:satisfied。CHG-2026-023 r1 approval 已在 protected
    `main` commit
    `21b5b9975beb960ba4f57a78a59d6246a4f86b0b` 生效；本任务无前序 task，
    CORE-2.1.0 已 ratified。approval 不替代本次 readiness，本 PR merge 只使
    AU-001 ready，不使 AU-002 ready，也不构成路线选择、依赖批准或 release。
  - Objective/scope gate:satisfied。候选集合封闭为
    `{Sparkle 2 sandbox/XPC, 最小自研 check+download+verify}`；评估矩阵封闭为
    design §1 的五维度：sandbox/XPC 与 exact entitlement/signing diff、供应链与
    自研维护成本、双层 fail-closed 验签、失败/回滚诚实性、隐私最小化。
    每一格必须记录 `fact | source | ArkDeck consequence | uncertainty`；最终记录
    必须明确推荐路线及未选路线排除理由。新增第三路线、改变 design §0 安全
    不变量或需要新的产品/Safety 决策时立即 blocked 并修订 change。
  - Git/input pins:actual implementation base = protected `main`
    `e56baa2f39998c1b3c2f7c6681b112dd1643ca7c`。下列输入以完整 Git blob OID
    固定；开始 documentReview 前任一漂移即停止并重做 readiness：
    - `proposal.md` =
      `c7515254522f3f049fc7e89098eb3d522a91ded9`；
    - `design.md` =
      `f25882d74e7d1a7ba7953ad33f255e414398271f`；
    - `verification.md` =
      `e171304af3bf02a4641fc72dc25465e12d5ec8aa`；
    - `acceptance-cases.yaml` =
      `dd3264dea573bf04e776a47cc4344f15c7a46a03`；
    - `docs/adr/0002-macos-v1-sandboxed-distribution.md` =
      `5111bb8c8657d0ed05e0184fbbaeb88af5fc5d8f`；
    - `openspec/platforms/macos/profile.md` =
      `a9a5931ffedd304a7ce3a088f4397c26fd87e744`。
  - Repository baseline gate:satisfied/read-only。`Package.swift` blob
    `91a1032f8a5ff9285154ef6f48ef35470b294eb7` 声明零 external package；
    `project.pbxproj` blob
    `e7943096688728a22f4b940e536a32f3b8eaaf98` 无
    `XCRemoteSwiftPackageReference`；仓库无 `Package.resolved`。当前 App
    entitlement blob `6435d00f8493ce4fbca24a806ca7f320db9fbfa6` 精确为 ADR-0002
    六项。AU-001 只读这些事实，禁止修改 package/project/entitlement/ADR/profile。
  - Official-source boundary:只允许一手资料。Sparkle 面固定为官方文档
    `https://sparkle-project.org/documentation/`、`/documentation/sandboxing/`、
    官方 GitHub `sparkle-project/Sparkle` 的 stable `2.9.4` tag
    `b6496a74a087257ef5e6da1c5b29a447a60f5bd7` 下 LICENSE/Package.swift/
    Configurations/Documentation/source；Apple 面固定为 developer.apple.com 的
    App Sandbox entitlement、Code Signing Services、`SecStaticCode` validity/code
    requirement 与 Team Identifier 文档。允许只读网页/源码；禁止 clone/install/
    build/run Sparkle，禁止执行 release tool，禁止创建 feed、key 或网络服务。
    二手博客、社区流行度、搜索摘要不能支撑 fact。
  - Readiness source-repin r2(2026-07-23；仅在本独立 D1 remediation PR
    review/merge 后生效)：PR #427 固定 `2.9.2`
    (`6276ba2b404829d139c45ff98427cf90e2efc59b`) 后、AU-001 开工前的官方
    `git ls-remote` 复核发现 stable `2.9.3` 与 `2.9.4` tags 已存在；官方
    security/reliability 文档还列出 2.9.4 的 installation timeout、delta symlink
    与 appcast-item race 修复。继续只读 2.9.2 会使安全/失败维度失真，故在产生
    evaluation/evidence 前 fail closed 暂停。本 r2 仅把 Sparkle source boundary
    精确替换为上述 2.9.4 tag；候选集合、五维度、Apple/local inputs、allowed
    paths、零下载/执行/实现与验证门全部不变。r2 audit base = PR #427 merge
    `2c04d0d3ad337a1bdaf074c132a50c4474fe99cb`；除本 task status/source pin 外
    零文件变化，r1 固定的九个 local input blob OID 全部复核无漂移。
  - Verification/evidence gate:satisfied。交付只写本 change `evidence/**`：
    evaluation/selection record、逐来源访问日期/稳定 URL/tag OID、`run.md` 与
    `TEST-AU-EVAL-001` 二值结论；记录 third-party dependency/file change/
    execution count 全 0。`scripts/check-sdd.sh`、source/privacy/secret scan 与
    allowed-path diff 必须通过。交付 PR 不翻 `ready→done`；done 使用独立 D0
    状态 PR。
  - Environment/concurrency gate:satisfied。macOS 26.5.2、Xcode 26.6
    (17F113)、Apple Swift 6.3.3 可得；本任务不依赖编译器。readiness 审计时
    GitHub open PR = 0，工作区既有未跟踪 fixture/log 不在 allowed paths 且保持
    untouched。若开工前出现 allowed-path overlap，先消除冲突或保持 blocked。
- Objective:在 {Sparkle 2 sandbox/XPC 模式, 最小自研 check+download+verify} 间
  做有据选型(design §1 五维度逐维落 facts:sandbox/XPC 与 entitlement diff、
  供应链面(首个第三方依赖 vs 自研维护)、验签链 fail-closed、失败/回滚诚实性、
  隐私最小化),产出选型决策记录;owner review/merge = 选型认可。
- Requirements/AC:change-local `AU-EVAL-001`(见 acceptance-cases.yaml)。
- Depends on:approve;信息源 = 官方文档/源码(Sparkle 仓库、Apple 文档)与本
  仓库 ADR-0002/profile 基线,零安装零执行第三方代码。
- In scope:评估文档 + 选型记录 + evidence run;facts 逐条带来源。
- Out of scope:任何依赖引入/实现/网络服务搭建;改 ADR/profile(同步归 AU-002
  或独立 ledger PR)。
- Allowed paths:本 change `evidence/**`、本 change `tasks.md`(仅本任务状态)。
- Risk:low(纯文档评估;选型错误的代价由 AU-002 readiness 前的复核兜底)。
- Hardware required:no。
- Verification:`AU-EVAL-001` documentReview——五维度逐维有据、结论可追溯、
  未选路线的排除理由明确;check-sdd 绿。
- Evidence gate:评估+选型 PR 合入后 `ready→done` 独立状态 PR。

## TASK-AU-002 — 实现与发布管线面

- Status:ready(2026-07-24 D1 readiness candidate；仅在维护者 review/merge 本
  独立 readiness PR 后生效。三前置已闭合：① CHG-2026-023 approved；②
  TASK-AU-001 done 且最小自研路线已由维护者认可；③ 本记录固定选型 OID、
  零第三方依赖、entitlement 空 diff、实现基线、public-key/feed/下载/验签/
  隐私/发布合同。本 PR 只修改本任务状态与 readiness 记录，零产品实现、零
  release、零私钥接触；merge 只授权 AU-002 按封闭合同开工，不构成 done、
  verified 或 ADR-0002 release gate #3 满足)
- Readiness review(2026-07-24；host-only，product update/device/release dispatch
  0，Agent private-key access 0):
  - Approval/dependency gate:satisfied。CHG-2026-023 r1 approval 已在 protected
    `main` commit `21b5b9975beb960ba4f57a78a59d6246a4f86b0b` 生效；
    TASK-AU-001 evaluation PR #429 head
    `4085fe7f4e05072edd2631d5fe8d28b44c1ef9ae` 已合入
    `a8084cd1a77205b7014c45e7733445c30642ffd9`，done 状态 PR #430 head
    `2c43bc0c132ad476e7d6690407d556a91ddff19a` 已合入
    `2ee97120c27e178ed9e54a0cf4a59b4d7413fae4`。AU-002 allowed-path
    remediation PR #431 head
    `12da1fef37fdd77f18ce3ce061a51c7b90f5c612` 已合入
    `e3b8838f855d60c5d484f0df5ff7c2dc8b8c64f8`；上述 commit 均为本
    implementation base 的 ancestor。
  - Selection/dependency/entitlement gate:satisfied。选型严格固定为
    **最小自研 check + download + verify + Finder handoff**：Foundation/
    URLSession、CryptoKit、Security 与 AppKit 系统 API，external package、
    XPC/helper、自动安装器均为 0。`Packages/ArkDeckKit/Package.swift` 无
    external package，Xcode 工程仅引用仓库内 `Packages/ArkDeckKit`，
    `Package.resolved` 不存在；dependency pin plan = **N/A/禁止引入**。
    entitlement diff = **空集**，实现后仍须精确等于 ADR-0002 的六项；任何新增
    dependency、XPC/helper、entitlement 或 App 自替换能力都立即 blocked，须另立
    change/readiness，不得在 AU-002 内便利性扩展。
  - Git/input pins:actual implementation base = protected `main`
    `5f34a2aa376bd3677b69ba14410f265f1a29aaf7`。审计期间 base 从
    `73b46b684b27eda23cfbaad06c5b707bff39e2cc` 前进一项，仅修改
    CHG-2026-032 `tasks.md`，下列 AU-002 输入 blob 全部复核无漂移。readiness
    初始取值时 GitHub open PR = 0；下列输入均由
    `git ls-tree origin/main -- <path>` 实测，开始 implementation 前任一相关
    blob 漂移即停止并重做 readiness：
    - `proposal.md`/`design.md`/`verification.md`/`acceptance-cases.yaml` =
      `c7515254522f3f049fc7e89098eb3d522a91ded9`/
      `f25882d74e7d1a7ba7953ad33f255e414398271f`/
      `e171304af3bf02a4641fc72dc25465e12d5ec8aa`/
      `dd3264dea573bf04e776a47cc4344f15c7a46a03`；
    - AU-001 `evaluation.md`/`sources.md`/`run.md` =
      `fcbfa0dd23220b833e3a2b4eef28129ea88b3a0f`/
      `2efee2309b7eb59cc0ed7f5fe6e036756c174322`/
      `e897ec3d938225483491ce10735ce3aebd8c85b4`；
    - ADR-0002/macOS profile/App entitlement/Xcode project =
      `5111bb8c8657d0ed05e0184fbbaeb88af5fc5d8f`/
      `a9a5931ffedd304a7ce3a088f4397c26fd87e744`/
      `6435d00f8493ce4fbca24a806ca7f320db9fbfa6`/
      `e7943096688728a22f4b940e536a32f3b8eaaf98`；
    - `ArkDeckApp.swift`/`Localizable.xcstrings`/`Package.swift`/
      `SystemLogger.swift`/`ArkDeckCLIMain.swift`/共享 target-dependency
      contract 表 =
      `5e1f175d82d2de867b6b783ddd80ea47fee87194`/
      `2f52fac028a4606cfb38783e190f4afafe28820b`/
      `91a1032f8a5ff9285154ef6f48ef35470b294eb7`/
      `8551d6b521b08ccf406bdf419b3f6c24b55435f3`/
      `be9bc136ae2f5086153459e8d7252c8c72ec13b1`/
      `98f98253c0f9ab67ab268255cd7596f8a07ff724`；
    - `Sources/ArkDeckWorkflows/AutoUpdate/**`、
      `AutoUpdateContractTests.swift` 与 `docs/release/macos-auto-update.md`
      在 base 均不存在，implementation 只可在已批准 allowed paths 内新建。
  - Production public-key pin:satisfied by maintainer-provided public material
    only。维护者声明已在 Agent 不可达的独立发布环境重新生成并导出；Agent
    未创建、读取或探测私钥。44-byte Ed25519 SPKI DER 已由
    `openssl pkey -pubin -inform DER -pubcheck` 验证：
    - key ID = `arkdeck-update-2026-07-b949b102`；
    - SPKI DER SHA-256 =
      `b949b102c5eb266084c3d59ee2e05de45681947841a4864afa0fc4136a1e7ddf`；
    - SPKI DER base64 =
      `MCowBQYDK2VwAyEAc5Ho0xkWFQ3Ovzjx98dQhF3n5sytJjffqD3a+ftgP8c=`；
    - CryptoKit raw 32-byte public-key base64 =
      `c5Ho0xkWFQ3Ovzjx98dQhF3n5sytJjffqD3a+ftgP8c=`。
    App 与 contract 必须 pin key ID + raw bytes；仓库、Git history、CI、fixture
    与 log 禁止出现 private material。v1 只信任这一枚 key；轮换须先经独立
    change 发布信任新 key 的 App，再切 feed，不能由 feed 自行下发信任根。
  - Signed-feed wire contract:固定为 UTF-8 JSON envelope，且只允许四个字段：
    `schemaVersion:1`、上述 `keyId`、base64 `payload`、base64 64-byte
    `signature`；duplicate/unknown/missing field、非规范 base64、超限输入均
    fail closed。签名输入精确为
    `ASCII("ArkDeck.UpdateFeed.v1") || 0x00 || UTF8(keyId) || 0x00 ||
    decodedPayloadBytes`，Ed25519 在**解析 payload 前**验证；禁止对已解析
    JSON 重序列化后再验签。payload 是确定性 UTF-8 JSON：sorted keys、零
    无意义 whitespace、slash 不转义、string NFC；实现以 strict decode 后按
    同规则 re-encode 与原 bytes 相等来拒绝重复 key/非规范编码。
  - Signed payload/schema gate:只允许
    `{sequence,version,minimumSystemVersion,architectures,issuedAt,expiresAt,
    artifact,releaseNotesSummary}`；`artifact` 只允许
    `{url,byteLength,sha256}`。`version` 为无前导零的稳定
    `major.minor.patch`，v1 arch 只接受 `arm64`，minimum OS 不低于 macOS 14；
    URL/byte length/lowercase 64-hex SHA-256 全部在签名内。`sequence` 为正
    UInt64 且发布时严格递增；持久化最高 `(sequence,payloadSHA256,version)`：
    较小 sequence、同 sequence 不同 payload 或新 sequence 非递增 version
    均拒绝；同 sequence 同 payload 幂等。candidate 等于当前 App 版本 =
    honest no-update，低于当前版本 = downgrade error/零下载。`issuedAt`/
    `expiresAt` 为 UTC RFC3339，窗口须正且不超过 30 天；过期/尚未生效 feed
    拒绝，配合 sequence 防 replay。
  - Network/privacy/redirect gate:生产 feed URL 固定为
    `https://github.com/ArkDeck/ArkDeck/releases/latest/download/arkdeck-update-feed-v1.json`。
    feed 初始请求的产品字段精确为 query
    `{appVersion,osVersion,arch}`；无 body/cookie/credential/cache、无 locale、
    用户路径、设备/硬件标识或遥测，协议 header 只允许固定、隐私中性的
    `Accept`/`User-Agent` 值。自动检查默认开启、仅 App 启动时且距上次尝试至少
    24 小时；用户可关闭，手动检查不受频率限制；检查绝不触发自动下载。
    redirect 最多 5 跳，每跳必须 HTTPS、无 userinfo/fragment/IP literal，host
    仅 `{github.com,release-assets.githubusercontent.com,
    objects.githubusercontent.com}`；禁止转发 cookie/authorization，初始三个
    产品 query 字段不得泄漏到 redirect request。artifact initial URL 必须与
    signed payload 精确一致；redirect 仍受相同 allowlist，最终 bytes 继续受
    signed length/digest 与 Team gate 约束。URLProtocol/local-server contract
    必须捕获初始/redirect/feed/artifact 的实际 request 逐字段断言。
  - Download/state/cleanup gate:状态机封闭为
    `idle→checking→available→downloading(partial)→verifying→
    awaitingConsent→handedOff`，任一步只能转 `failed`/`cancelled`，失败后不得
    回到 handoff。下载必须由用户显式发起；不支持 Range/resume，在 App container
    owner-only 临时目录写随机名 `.part`，边写边计数且不得超过 signed
    `byteLength`。EOF 后 length 与 SHA-256 双匹配才可同卷原子 rename 为
    owner-read-only verified DMG；cancel/interruption/truncate/overflow/
    digest mismatch/启动恢复时的 orphan partial 全部删除，不可信缓存永不复用。
  - Artifact identity/TOCTOU/handoff gate:对最终 DMG path 使用
    `SecStaticCodeCreateWithPath`，以
    `kSecCSStrictValidate|kSecCSCheckAllArchitectures|kSecCSCheckNestedCode`
    做静态完整性检查；再以当前运行 App 的签名信息动态取得 Developer ID Team
    identifier 并施加 same-Team requirement。当前 App 无 Team identity、
    DMG unsigned/ad-hoc/invalid/different-Team 均 fail closed；生产代码禁止
    hard-code 测试 Team。首次验证记录 no-follow file identity；用户点击最终
    consent 后、Finder handoff 前必须重新 no-follow 打开并复核 identity、
    length、digest、static validity 与 same-Team，任何 replacement/race 均零
    handoff。ArkDeck 只在这次独立同意后 reveal verified DMG；不自动 mount/open、
    不替换 App、不 update-on-quit、不声称自动回滚。用户文案必须明确手工挂载/
    替换与失败支持边界；任一 negative 的 installed-byte mutation 与
    `NSWorkspace` handoff count 均为 0。
  - Release pipeline/key-isolation gate:实现只提供不接触生产私钥的确定性 feed
    prepare/assemble/self-verify 能力；维护者在隔离发布环境依序执行
    `archive → Developer ID sign → notarize/staple → DMG static/Gatekeeper
    verify → length/SHA-256 → canonical payload/signature-input → OpenSSL
    Ed25519 sign → assemble → pinned-public-key self-verify → upload/fetch-back
    byte verify → publish feed`。private key material/passphrase 不作为 CLI
    参数、环境变量、CI secret、日志或 evidence；private path 只可交给隔离
    维护者环境内的本地 OpenSSL，签名时交互读取 encrypted key。feed 必须最后
    发布，失败不得覆盖上一份有效 feed。
  - Verification/evidence gate:实现 PR 必须交付
    `TEST-AU-CONTRACT-001`/`TEST-AU-PRIVACY-001` contract evidence：坏/缺/
    错 key 签名、非规范/未知 feed、downgrade/replay、非法 URL/redirect、
    length/digest mismatch、中断/截断/cancel、unsigned/different-Team DMG、
    verify 后替换、未同意等 negative 全部 honest error + 零 handoff/零已安装字节
    变化；positive 仍须走独立 consent。另须断言 exact entitlement 六项、external
    dependency/private-key material = 0、实际请求白名单与披露一致；发布规程、
    全量 Swift/Xcode 基线、`check-sdd`、allowed-path/secret scan 全绿。实现 PR
    不翻 `ready→done`，done 另走独立 D0 状态 PR。
- Pre-readiness allowed-path remediation(2026-07-24；仅在维护者 review/merge
  本独立 D1 governance PR 后生效)：原任务虽要求 contract tests、feed 生成与发布
  规程，却没有可被 `check_pr_paths.py` 解析的 `Allowed paths` 行，也未列出现有
  SwiftPM test target、`Package.swift`、共享 target-dependency contract 表或发布
  文档的精确路径，因而 AU-002 不能诚实进入 readiness。下列封闭路径补齐这些
  已批准交付面，并把 App 侧限制在现有 source/resource 文件，避免触及显式文件组
  的 `project.pbxproj`。本 remediation 只修改本任务治理声明，不携带产品实现、
  测试、evidence、依赖或状态翻转；TASK-AU-002 保持 blocked，合入后仍须独立
  readiness 固定 AU-001 选型合同、public-key/feed 合同、零第三方依赖、
  entitlement 空 diff 与实现基线。
- Objective:按选型集成应用内自动更新:检查(手动 + 可开关的自动)、显式同意
  安装、验签 fail-closed 双层(design §0)、隐私最小化字段与披露文案、
  SystemLogger 事件类扩展;发布侧 = feed 生成与 EdDSA 私钥处理规程(私钥永不
  入仓);若引入依赖:版本+hash pin 与 license notice 随实现 PR 交付;若引入
  XPC/entitlement 增项:同 PR 更新 ADR-0002 声明并测试断言一致。
- Requirements/AC:change-local `AU-CONTRACT-001`/`AU-PRIVACY-001`(见
  acceptance-cases.yaml)。
- Depends on:approve、TASK-AU-001 done。
- In scope:`ArkDeckApp/**`、`Packages/ArkDeckKit/Sources/**`(更新检查/验签
  逻辑与测试)、发布规程文档、本 change `evidence/**`、本 change `tasks.md`
  (仅本任务状态);依赖清单文件(如适用)。
- Out of scope:遥测/crash 上报(DEC-008)、delta 更新、分轨、release 本身。
- Allowed paths after readiness:
  - `ArkDeckApp/App/ArkDeckApp.swift`
  - `ArkDeckApp/Resources/Localizable.xcstrings`
  - `Packages/ArkDeckKit/Package.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/SystemLogger.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AutoUpdate/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkDeckContractTests.swift`
    (仅同步 ArkDeckWorkflows 的声明依赖表)
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AutoUpdateContractTests.swift`
  - `docs/release/macos-auto-update.md`
  - 本 change `evidence/**`
  - 本 change `tasks.md`(仅本任务状态/evidence 引用)
- Risk:medium(首个出站网络面 + 可能的首个第三方依赖;fail-closed 与隐私
  边界是核心不变量)。
- Hardware required:no。
- Verification:`AU-CONTRACT-001` 验签 fail-closed 矩阵(feed 签名坏/缺、下载物
  Team 不符/未签名、中断/截断——全部零安装动作)+ 零静默安装 + entitlement 集
  与声明一致断言;`AU-PRIVACY-001` 更新检查请求字段白名单断言(零设备/用户
  标识)+ 披露文案存在;全量基线零回归。
- Evidence gate:contract 全绿 + 发布规程文档在案后合入;`ready→done` 独立状态
  PR;change verified = ADR-0002 release gate #3 满足(另行 verify PR)。
