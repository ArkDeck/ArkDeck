# TASK-AU-001 更新机制评估与选型

- Date:2026-07-23
- Method:`documentReview`
- Actual base:`ba67d59980a2e3f84efe142f607f092ee3f29c6d`
- Candidate set:`{Sparkle 2.9.4 sandbox/XPC, 最小自研
  check+download+verify}`
- Recommendation:**选择最小自研 check+download+verify，安装阶段由用户显式
  挂载已验证 DMG 并手工替换 App**
- Decision state:`candidate`。本记录经维护者 review/merge 后才构成路线认可；
  本 PR 不把 TASK-AU-001 翻为 `done`，也不使 TASK-AU-002 ready。

本次结论首先服从 `design.md` §0 的硬边界，不以安装体验、依赖流行度或实现
便利覆盖安全不变量。评估没有 clone/install/build/run Sparkle，没有下载其发布
二进制，没有修改产品、依赖、工程、entitlement、ADR 或 profile。

## 决定性结论

Sparkle 2.9.4 能提供成熟的 sandbox/XPC 安装器、原子替换与失败处理，但固定
tag 的实际验证语义不能满足 ArkDeck 的双层 **AND**：

1. `SUUpdateValidator.m` 同时计算 EdDSA 与 Apple Code Signing 结果，但在
   2.9.4 的安全关键返回分支中明确执行
   `passedDSACheck || passedCodeSigning`。当归档 EdDSA 有效、更新 App 的签名
   本身有效但 identity 与旧 App 不同，代码会接受 EdDSA 结果；这与
   `AU-CONTRACT-001` 的“不同 Team identity 必须零安装动作”直接冲突。
2. `SPUUpdaterDelegate` 的可拒绝钩子
   `shouldProceedWithUpdate` 位于下载前；下载、解包、安装前后的公开回调均为
   通知型 `void` 方法，没有“拿到解包路径、执行额外同 Team 验证、失败后阻止
   安装”的公开门。
3. fork/patch Sparkle 或另包一层私有安装门会形成候选集合之外的第三路线，并
   把安全补丁同步责任转为 ArkDeck 自担；TASK-AU-001 无权静默扩展范围。

相比之下，最小自研路线可在任何用户交接前顺序执行并要求两个结果同时为真：

1. 用系统 CryptoKit 验证固定公钥下的 Ed25519 签名，并使签名内容绑定版本、
   最低系统、arch、下载 URL 与制品摘要；
2. 用系统 Security framework 对下载快照执行静态代码签名校验以及显式
   Developer ID Team requirement 校验；
3. 仅在两项都成功且用户再次明确同意后，才允许打开/展示 DMG；ArkDeck 本身
   不替换已安装 App，因此失败时当前安装保持原样，也不虚构“自动回滚”。

这条路线牺牲应用内原子安装体验，并要求 ArkDeck 自担 feed canonicalization、
下载状态、TOCTOU 与错误分类维护；但它是封闭候选集中唯一能直接实现既定
fail-closed 合同且不扩 entitlement/XPC 面的路线。

## 五维评估

### 1. Sandbox/XPC 兼容与 exact entitlement/signing diff

#### Sparkle 2.9.4 sandbox/XPC

- **Fact:**sandboxed App 必须启用 Installer XPC：
  `SUEnableInstallerLauncherService=YES`。主 App 还必须新增：

  ```text
  + com.apple.security.temporary-exception.mach-lookup.global-name
      - $(PRODUCT_BUNDLE_IDENTIFIER)-spks
      - $(PRODUCT_BUNDLE_IDENTIFIER)-spki
  ```

  ArkDeck 已有 `com.apple.security.network.client`，因此官方文档要求**不要**
  启用 Downloader XPC。标准 Xcode Archive/Export 会重签 framework 内的 XPC
  与 helper；单纯 `Code Sign on Copy` 不会重签全部嵌套项。
- **Source:**`SP-SBX`、`SP-CFG`、`LOCAL-ENT`、`LOCAL-ADR`。
- **ArkDeck consequence:**相对 ADR-0002 当前精确六项，App entitlement diff
  是新增上述一个临时 Mach lookup exception key/两个值；另有嵌套
  Installer.xpc/helper 的签名与 Hardened Runtime 验证面。若选择此路线，
  AU-002 必须同 PR 更新 ADR-0002、断言最终 entitlement 集，并验证 archive/
  export 后全部嵌套签名；Downloader XPC 必须保持关闭。
- **Uncertainty:**本任务没有 archive/export，因此没有声称实际嵌套签名通过；
  实际 bundle identifier 展开值和 release 构建产物只能由 AU-002 contract
  固定。临时 exception 是否长期可接受还需维护者在实现 readiness 明确认可。

#### 最小自研

- **Fact:**候选只使用 App 已有的出站网络能力下载到 App 自有容器，并在验证后
  由用户手动挂载 DMG/替换 App；不需要 Installer/Downloader XPC。现有
  `network.client` 已在 ADR-0002 六项内。
- **Source:**`LOCAL-DESIGN`、`LOCAL-ENT`、`LOCAL-ADR`、`APPLE-STATIC`。
- **ArkDeck consequence:**exact entitlement diff = **空集**；XPC/helper
  signing diff = **空集**。AU-002 仍须证明下载缓存、临时文件与用户交接都在
  sandbox 允许范围内。
- **Uncertainty:**DMG 的最终 handoff UI、缓存保留期和 sandbox bookmark
  边界尚未实现；这些是 AU-002 的 contract/实现问题，不改变本次“无新增
  entitlement”的路线事实。

**Dimension conclusion:**最小自研胜出；它不扩张当前 sandbox 信任面。

### 2. 供应链面：首个第三方依赖 vs 自研维护

#### Sparkle 2.9.4

- **Fact:**ArkDeck 当前 Swift package 与 Xcode 工程均无 external package。
  Sparkle 2.9.4 的官方 `Package.swift` 是 binary target，指向 release ZIP，
  内含上游 SHA-256
  `cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0`；
  主许可证为 MIT，`LICENSE` 还列有 bundled external licenses。2.9.4 官方
  security/reliability 记录包含安装超时、delta symlink 与 appcast-item
  spoof/race 修复。
- **Source:**`LOCAL-PKG`、`SP-PKG`、`SP-LICENSE`、`SP-SECURITY`。
- **ArkDeck consequence:**这是首个第三方 binary package；若采用，必须 exact
  version/revision + artifact checksum pin、SBOM、完整 license notice、发布
  二进制与固定源码 OID 的可追溯关系，并持续跟进安全公告。
- **Uncertainty:**本评估未下载 release ZIP，所以上游 manifest 内的 checksum
  没有冒充 ArkDeck 的独立制品复验；二进制与源码的供应链复验须在 AU-002
  readiness/实现中完成。

#### 最小自研

- **Fact:**可仅依赖 macOS 系统的 Foundation/URLSession、CryptoKit 与 Security
  framework，不引入 external package。CryptoKit 提供
  `Curve25519.Signing.PublicKey.isValidSignature`；Security framework 提供
  静态代码签名、requirement 与 Team identifier 验证构件。
- **Source:**`APPLE-ED25519`、`APPLE-STATIC`、`APPLE-TEAM`、`LOCAL-PKG`。
- **ArkDeck consequence:**第三方依赖、SBOM 新项和 XPC binary supply-chain
  surface 均为 0；代价是 ArkDeck 自担 signed-feed canonicalization、版本/
  最低系统/arch 选择、下载/中断/截断、临时文件、代码签名 requirement、
  TOCTOU、错误分类和长期测试维护。
- **Uncertainty:**feed schema、签名 payload 的 canonical bytes、版本比较规则、
  私钥侧签名工具与 key rotation 尚未定义；AU-002 readiness 必须先固定这些
  contract，不能边实现边猜。

**Dimension conclusion:**最小自研避免首个 binary dependency，但“零依赖”
不是零成本；选择明确接受受 contract 约束的自研维护成本。

### 3. 验签链 fail-closed

#### Sparkle 2.9.4

- **Fact A:**`SURequireSignedFeed=YES` 依赖
  `SUVerifyUpdateBeforeExtraction=YES`。默认
  `SUSignedFeedFailureExpirationInterval` 是 20 天；到期后框架会展示新
  update，只有显式设为 `0` 才禁止签名失败过期。
- **Fact B:**即使上述配置全开且 expiration 设为 0，2.9.4 App update validator
  仍以 `passedDSACheck || passedCodeSigning` 接受任一信任链；它不是 ArkDeck
  要求的 EdDSA **AND** same-Team identity。
- **Fact C:**公开 delegate 在下载后只有通知型回调，没有暴露下载/解包 URL
  并允许客户端返回失败以阻止后续安装的门。
- **Source:**`SP-CFG`、`SP-VALIDATOR`、`SP-DELEGATE`、
  `SP-CODESIGN`。
- **ArkDeck consequence:**仅靠公开配置/API，Sparkle 2.9.4 无法让
  “有效 EdDSA + 不同 Team”以零安装动作失败，故不符合 design §0 与
  `AU-CONTRACT-001`。官方历史页“doubly verify”描述不能覆盖固定 tag 源码的
  实际 OR 返回语义。
- **Uncertainty:**对固定 OID 的源码语义无剩余文档不确定性；本任务没有执行
  第三方代码，因此运行期行为仍须被视为未执行，但不能用未执行来忽略明确
  的控制流。

#### 最小自研

- **Fact:**系统 API 可分别验证 Ed25519 签名、静态代码的 sealed components/
  requirement 与 Team identifier，并可用
  `kSecCSCheckAllArchitectures` 覆盖 universal binary 的全部架构。
- **Source:**`APPLE-ED25519`、`APPLE-STATIC`、`APPLE-DESIGNATED`、
  `APPLE-TEAM`；本机 macOS 26.5 SDK 同名公开 headers/interface 只读复核。
- **ArkDeck consequence:**AU-002 可把两项验证写成显式顺序 AND gate，任何
  缺签/坏签、Team 不符/未签名、中断/截断均在打开 DMG 或其他 handoff 前
  失败；安装动作和已安装字节计数保持 0。
- **Uncertainty:**必须在 AU-002 固定：
  1. feed 签名的 canonical bytes 与反重放/降级字段；
  2. signed feed 对 URL、length、digest、version、OS、arch 的绑定；
  3. DMG 与其内 App 的验证对象、Developer ID requirement 文字及 nested-code
     策略；
  4. 验证快照到用户打开之间的 TOCTOU 防护（不可变文件或打开前复验）。

**Dimension conclusion:**最小自研是唯一能在封闭候选内直接表达严格 AND 的
路线；这是本次选型的决定性维度。

### 4. 失败/回滚诚实性

#### Sparkle 2.9.4

- **Fact:**框架把下载、解包、验证、安装分层，并提供 sandboxed Installer XPC；
  官方历史记录有原子 file operations、独立 launchd installer、下载/安装
  安全修复。它也支持自动下载、静默安装和 quit 时安装，但可用
  `SUAutomaticallyUpdate=NO`、`SUAllowsAutomaticUpdates=NO` 禁止这些路径。
- **Source:**`SP-SECURITY`、`SP-SECURITY-SOURCE`、`SP-CFG`、
  `SP-UI`。
- **ArkDeck consequence:**若安全合同兼容，Sparkle 的安装恢复成熟度和用户
  体验显著优于自研；但其 OR 验签会在 ArkDeck 必须拒绝的场景进入安装器，
  成熟安装流程不能抵消前置 admission 失败。
- **Uncertainty:**本任务未运行安装器，没有把上游历史声明记作 ArkDeck
  release 证据；实际 archive/install/rollback 仍需产品级测试。

#### 最小自研

- **Fact:**候选定义止于“检查 + 下载 + 验证 + 引导用户挂载 DMG 替换”，
  ArkDeck 不修改当前安装。失败、中断、取消或验签失败只影响 App 容器内的
  未信任临时下载，不能触碰已安装 App。
- **Source:**`LOCAL-DESIGN`、`APPLE-STATIC`。
- **ArkDeck consequence:**可诚实承诺的是“验证成功前零 handoff、所有失败零
  已安装字节变化”；不能声称自动安装或自动回滚。验证成功后的 Finder/用户
  替换是显式的人类动作，失败恢复依赖 macOS/Finder 与用户保留旧版本。
- **Uncertainty:**AU-002 必须固定部分文件隔离/清理、断点续传是否支持、
  磁盘不足、取消、重试、缓存过期和错误文案；在这些 contract 通过前不能
  启动真实 feed/release。

**Dimension conclusion:**Sparkle 的安装成熟度更强；最小自研通过“不执行安装”
缩小失败面，并对缺失的自动回滚能力保持诚实。安全不变量优先后选择后者。

### 5. 隐私最小化

#### Sparkle 2.9.4

- **Fact:**system profiling 默认关闭；启用后会发送 CPU、Mac model、core
  数、CPU 速度、RAM、App 名、语言等，明显超出 ArkDeck 白名单。2.9.4 默认
  User-Agent 还包含 App 名、display version 与 Sparkle version；公开
  `userAgentString`/`httpHeaders` 可覆盖，delegate 也能追加 feed 参数。
- **Source:**`SP-PROFILE`、`SP-UA`、`SP-UPDATER`、`SP-DELEGATE`。
- **ArkDeck consequence:**若采用，必须保持 profiling off、禁止额外 feed
  参数、覆盖默认 User-Agent、限制/关闭 release notes 额外请求，并抓取实际
  appcast/archive/redirect 请求证明只有 App version、OS version、arch。
  默认配置本身不满足封闭白名单。
- **Uncertainty:**Foundation 自动 header、重定向后的 header 传播、release
  notes 子请求与框架未来版本差异必须由 URLProtocol/本地 server contract
  观测，不能仅凭 Info.plist 声明。

#### 最小自研

- **Fact:**自有 URLSession request builder 可只构造一个 HTTPS feed 请求和
  一个选定制品请求，不启用 profiling、release-notes WebView 或 delegate
  扩展参数。
- **Source:**`LOCAL-DESIGN`；系统网络能力由 `LOCAL-ENT` 既有
  `network.client` 支持。
- **ArkDeck consequence:**可把请求字段模型封闭为
  `{appVersion, osVersion, arch}`，显式禁止 App 名、设备/硬件标识、用户路径、
  locale、RAM、CPU 数、遥测和任意动态 header；披露文案与同一模型生成。
- **Uncertainty:**即使自研，URLSession 默认 header、TLS/redirect 行为和
  artifact host 请求仍须在 AU-002 用捕获 seam 逐请求断言；“由自己构造”
  不能替代线上字节级证据。

**Dimension conclusion:**两者理论上都可收紧，但最小自研的出站面更小且更易
形成单一封闭 request model。

## 推荐路线的 AU-002 前置合同

本记录只选路线，不授权实现。TASK-AU-002 readiness 至少要先固定：

1. signed feed 的 schema、canonicalization、Ed25519 公钥 pin、签名覆盖字段、
   版本/最低系统/arch 选择与 downgrade/replay 规则；
2. feed 中对制品 HTTPS URL、byte length、cryptographic digest 的绑定；
3. App 容器内的临时下载、partial/cancel/truncate 状态机与不可信缓存清理；
4. Security framework 的 DMG/App 验证对象、same-Team requirement、
   `kSecCSCheckAllArchitectures`/nested-code flags 和验证到 handoff 的 TOCTOU
   防护；
5. 严格顺序门：
   `signed feed → digest/length → static code valid → same Team → explicit
   consent → reveal/open DMG`，任一步失败均零 handoff/零安装动作；
6. 手动与可关闭的自动检查；无自动下载、无 silent install、无 update-on-quit；
7. `{appVersion, osVersion, arch}` 出站白名单的请求捕获 contract、redirect
   contract 与披露文案；
8. EdDSA 私钥只在维护者发布环境，永不入仓/CI；仓库只含 public key；
9. 明确“不提供应用内替换/自动回滚”的用户文案与支持边界。

若维护者希望保留 Sparkle 的应用内安装体验，必须另立 change，显式处理
`OR → AND` 的安全语义（上游能力、受控 fork 或其他新路线）并重新批准；不得
在 AU-002 中把它作为“实现细节”偷偷加入。

## 路线排除理由

**排除 Sparkle 2.9.4 sandbox/XPC：**

- 固定 tag 的 App 验证控制流允许 EdDSA 或旧 App identity matching 任一通过，
  直接违反 ArkDeck 既定双层 AND 与不同 Team negative；
- 公开 delegate 没有可补上严格同 Team gate 的安装前拒绝接口；
- 会新增临时 Mach lookup entitlement、Installer XPC/nested-signing 面和首个
  第三方 binary dependency；
- 默认 User-Agent 含 App 名，默认 signed-feed failure 还会在 20 天后过期，
  都需要额外收紧；
- 上述劣势不是以“框架不成熟”为理由；相反，成熟的原子安装/恢复是它的明确
  优势，只是不能覆盖本 change 的安全不兼容。

**选择最小自研：**

- 无 external dependency、XPC 或 entitlement 增项；
- 可以用系统 API 显式实现 EdDSA **AND** same-Team；
- 在 App 不自动替换自身的前提下，所有 admission failure 都能保持已安装字节
  不变；
- 出站请求可以收敛到单一封闭模型；
- 代价（手工安装体验和自研维护）已逐项列出，并被列为 AU-002 readiness 的
  前置 contract，而不是被隐去。

## AU-EVAL-001 二值结论

`TEST-AU-EVAL-001`:**PASS(candidate evidence)**。

- 五个指定维度均分别记录了 `fact | source | ArkDeck consequence |
  uncertainty`；
- 推荐路线明确，未选路线的排除理由明确；
- third-party dependency introduced = 0；
- third-party release/source files downloaded into workspace = 0；
- third-party code/tool execution = 0；
- product implementation/project/entitlement/ADR/profile file changes = 0；
- external service/feed/key/device action = 0。

`PASS(candidate evidence)` 只表示本次 documentReview 交付完整；维护者
review/merge 才认可选型，独立状态 PR 才能把 TASK-AU-001 翻为 `done`，本结论
不构成 change `verified` 或 release。
