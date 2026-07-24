---
id: CHG-2026-023-macos-auto-update
revision: 1
status: archived # 2026-07-24 本 archive PR；verified #489 merge `9094c92c402c69b4bb7b21a8ca5534f6e1a5797e`；platform change、零 spec/registry delta，故只迁移 change 目录并记录归档状态；仅在维护者 review/merge 本 PR 后生效。原注:approval #266 merge `21b5b9975beb960ba4f57a78a59d6246a4f86b0b`；r1 proposal 经 #262 合入 `e9a4989`
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# macOS v1 应用内自动更新(DEC-004/ADR-0002 载体)

## Why

DEC-004(#261,decided)与 ADR-0002 把自动更新纳入 v1 更新渠道,并明确"选型/
XPC/签名链/隐私披露/网络面由独立 change 评估落地,verified 前手动公证 DMG 过渡"
——本 change 即该载体。既有输入:

- macos platform profile "Auto-update backlog" 节已固定安全基线:HTTPS、
  Developer ID/公证、archive **EdDSA** 签名与**私钥隔离**;Sparkle 2.9+ signed
  feed 须同时启用 `SURequireSignedFeed` 与 `SUVerifyUpdateBeforeExtraction`;
- ADR-0002 分发形态 = Sandboxed + 六 entitlement(`network.client` 已在集内);
  自动更新框架若需 XPC service 内嵌,附加 entitlement/签名面须显式声明批准,
  不得静默扩集;
- **供应链事实:本仓库当前零第三方依赖**。引入 Sparkle 将是首个外部依赖决策
  (license/SBOM/版本与 hash pin/依赖审计),与最小自研路线(appcast 检查 +
  DMG 下载 + 验签 + 引导安装)之间的取舍是本 change 的核心评估项;
- 隐私边界:更新检查是产品第一个合法出站网络调用;DEC-008(remote crash/
  telemetry)保持独立,更新检查不得夹带遥测。

## What changes(两任务分期;本 change 首 PR 只 proposal + design,零实现)

- **TASK-AU-001 — 更新机制评估与选型(documentReview,host-only)**:在
  {Sparkle 2(sandbox/XPC 模式), 最小自研(appcast JSON over HTTPS + DMG 下载 +
  代码签名/Team identity 验证 + 引导安装)} 间做有据选型。评估维度(全部落
  facts):sandbox/XPC 兼容性与所需 entitlement/签名面 diff;供应链面(依赖
  license/SBOM/pin/hash/审计成本 vs 自研维护成本);签名链 fail-closed(EdDSA
  feed 签名、下载物必须验签到同一 Developer ID Team,任一失败零安装动作);
  失败/回滚诚实性;隐私(更新检查请求携带的确切字段,零设备/用户标识)。
  产出选型决策记录,owner review/merge = 选型认可。
- **TASK-AU-002 — 实现与发布管线面(blocked 于 AU-001 done + readiness)**:按
  选型集成;更新检查默认频率与用户开关、显式同意后才安装(零静默安装);
  contract 测试覆盖验签 fail-closed 矩阵与隐私字段断言;发布侧 = feed/appcast
  生成与 EdDSA 私钥处理规程(**私钥永不入仓**,与 V1 治理教训一致);若引入
  XPC/entitlement 变化,同 PR 显式更新 ADR-0002 entitlement 集声明。

## Out of scope / Non-goals

- 远程 crash/telemetry(DEC-008 独立)、delta 更新、多渠道(beta/stable)分轨、
  MAS(ADR-0002 排除);
- 不改 Core spec/contract/schema;不动 ADR-0002 已定的分发形态本体;
- 首 PR 不引入任何依赖、不写实现、不产生 evidence。

## Approval and flow

V2 治理:本 propose PR 合入仅登记提案;批准须独立 approval-only PR;两任务各自
独立 readiness/实现/done PR。change verified = ADR-0002 release gate #3 满足;
在此之前手动公证 DMG 过渡通道保持。

## Approval

- r1 proposal 经 PR #262 合入 main(squash `e9a4989`,status:proposed)。
- 正式批准:2026-07-21 由本 approval-only PR(先例 #55/#89/#171/#195/#226/#253/
  #254)将本 change 置为 `approved`;批准由维护者 review/merge 本 PR 构成。
  merge 即批准:
  - **两任务分期 scope 与边界**:TASK-AU-001(选型评估,documentReview,
    host-only,零依赖引入零第三方代码执行)与 TASK-AU-002(实现与发布管线,
    blocked 于 AU-001 done)的 objective/scope/allowed-paths;
  - **design §0 安全不变量**:验签 fail-closed 双层(EdDSA feed + 下载物验到
    同一 Developer ID Team,任一失败零安装动作)、零静默安装且用户可关自动
    检查、隐私最小化封闭白名单(零设备/用户标识、零遥测,DEC-008 边界)、
    EdDSA 私钥只存维护者发布环境永不入仓/CI、entitlement/XPC 增项须显式过
    ADR-0002 声明并测试断言一致;
  - **验收面**:三 change-local AC(AU-EVAL-001 documentReview、
    AU-CONTRACT-001/AU-PRIVACY-001 contract);canonical Core AC 零认领;
    change verified = ADR-0002 release gate #3。
- 本批准不产生任务执行:两任务保持 `blocked`,各须独立 readiness PR 转
  `ready`;不引入任何依赖(依赖决策属 AU-001 选型 + AU-002 readiness 的
  pin 方案);verified 前手动公证 DMG 过渡通道保持。不构成 release、兼容性或
  支持声明。

## Verification closure（2026-07-24）

依 `verification.md` Gate 于 protected `main`
`dbb15236cc1dae63398ceff8a697d5d8b24c9ead` 逐项独立复核。本 PR 是 D0
状态推进，只修改本 proposal 的状态/evidence 引用与 `verification.md` 抬头，
零实现、零 evidence 改写、零 release/publish；`verified` 仅在维护者
review/merge 本 PR 后生效。

### 批准、任务与证据链

- change approval：#266 merge
  `21b5b9975beb960ba4f57a78a59d6246a4f86b0b`；
- TASK-AU-001：evaluation/evidence #429 merge
  `a8084cd1a77205b7014c45e7733445c30642ffd9`，done #430 merge
  `2ee97120c27e178ed9e54a0cf4a59b4d7413fae4`；
- TASK-AU-002：readiness #447 merge
  `b8a6656ad2d04ead59443053cd646e31907c873c`，implementation/evidence #457
  merge `9ae1bbd2d3351a2b6980255d0eef55078d09cd37`，done #486 merge
  `dbb15236cc1dae63398ceff8a697d5d8b24c9ead`。

上述 OID 全部是 verify base 的 ancestor。#457 final head 与 merge tree 相同；
#486 已由 `lvye` 对 exact head
`f0046fb25804bd2471dc41ee228dbc458adfae5a` APPROVE 后合入。早先被
CHG-2026-033 bootstrap 显式替换的 PR #466 original head 不承载本状态的批准语义。
closure carrier 随后快进到 main
`26c59d0798374db26dc9b5d892620843435faf0f`；新增 #487 只修改
CHG-2026-026 evidence，与本 change、App、updater、package、CLI、logger、
测试及发布规程路径均零重叠，AU 验证输入无漂移。

### `AU-EVAL-001` — **passed**（documentReview）

`evidence/runs/TASK-AU-001/evaluation.md`、`sources.md` 与 `run.md` 的 merge
blob 仍精确为
`fcbfa0dd23220b833e3a2b4eef28129ea88b3a0f`、
`2efee2309b7eb59cc0ed7f5fe6e036756c174322`、
`e897ec3d938225483491ce10735ce3aebd8c85b4`。五维评估均含可追溯
fact/source/consequence/uncertainty；推荐最小自研
check + download + verify + Finder handoff，并明确排除 Sparkle 2.9.4
`EdDSA OR code signing` 与新增 dependency/XPC/entitlement 面。评估自身
third-party download/execution/dependency change = 0。

### `AU-CONTRACT-001` — **passed**（contract）

证据：`evidence/runs/TASK-AU-002/run.md`（merge blob
`91bff70f3619de5e7c795dc439f7da837e19f94a`）。verify base 独立重跑
`AutoUpdateContractTests` = **17 tests / 0 failures**：

- 缺失/坏/错 key/错 signer 签名、unknown/duplicate/noncanonical feed、
  downgrade/replay/expiry、非法 URL/redirect 全部 fail closed；
- overflow/truncate/digest mismatch/interruption/cancel 均清理 partial；
  unsigned/different-Team、下载后替换、owner-writable mutation、缺少最终同意
  均使 Finder handoff = 0，installed-byte sentinel 不变；
- positive 路径仍需“用户启动下载 + 最终独立同意”两次动作，自动检查不会下载；
- entitlement 精确为 ADR-0002 六项，external package/XPC/helper/private-key
  material = 0。

Security.framework production 路径由 SwiftPM 与 Xcode 编译；unsigned/
different-Team 矩阵在 typed code-signing seam 上以 `contractFake` 验证。本
closure 没有 Developer ID/notarized DMG fixture，不把该结果写成真实
Team-signed 制品、notarization 或 release 验收。

### `AU-PRIVACY-001` — **passed**（contract）

同一 17-test suite 通过 URLProtocol 捕获实际 `URLSession` feed/artifact/
redirect request：初始产品字段精确为
`{appVersion,osVersion,arch}`；redirect 移除三字段；仅固定
`Accept`/`User-Agent`，body/cookie/Authorization/credential = 0。App 披露文案
与该白名单一致，设备/硬件标识、用户路径、locale 与 telemetry 字段 = 0。

### 共同门与回归

- `CI=true swift test --package-path Packages/ArkDeckKit` =
  **400 tests / 1 个既有 opt-in manual sleep/wake skip / 0 failures**；
- macOS Xcode Debug no-sign build PASS；
- `scripts/check-sdd.sh` = 0 errors / 0 warnings / 111 acceptance IDs；
  `git diff --check` PASS；
- `ArkDeckApp.entitlements` 恰为六个 `true` key；`Package.resolved`、
  `.package(` 与 `XCRemoteSwiftPackageReference` 均不存在；
- `docs/release/macos-auto-update.md`（blob
  `ecc8d8a02dbe37d66ca1716aeeafa1491f3a7af8`）固定 archive/sign/notarize/
  staple/static verify/digest/隔离交互签名/self-verify/fetch-back/feed-last 顺序；
  本次 production private-key access/sign、真实 feed/artifact network、
  upload/publish、DMG mount/open/install/App replacement、production Finder
  handoff 全部为 0。

### verified 的边界

本 closure 满足 ADR-0002 release gate #3（自动更新 change verified），但不
构成 ArkDeck release，也不满足或替代其余 Developer ID、clean-host/clean-VM、
distribution profile 等 release gates；不改变 platform conformance/support/
compatibility 状态，不声称真实 Team-signed DMG positive acceptance。release、
feed publish 与 change archive 均须后续独立流程。

## Archive record（2026-07-24）

- 前置：verification closure PR #489 已由 `lvye` 对 exact head
  `244534d3587a5541e1835477a8e32b63d97ceb08` `APPROVED`，并 squash 合入
  protected `main` 为
  `9094c92c402c69b4bb7b21a8ca5534f6e1a5797e`；本 archive audit base 即该
  merge OID。
- 归档目录：
  `openspec/changes/archive/2026-07-24-chg-2026-023-macos-auto-update/`。
  整棵 change 共 9 个文件完成迁移；除本 proposal 的
  `verified` → `archived` 与本记录外，其余 8 个文件内容不变。
- 归档前对
  `openspec/changes/chg-2026-023-macos-auto-update` 的目录外精确路径扫描只有
  2 处命中：CHG-2026-030 的
  `evidence/runs/TASK-HLR-001A/post-merge-live.md` 记录 #486 合入时的
  changed-file list；CHG-2026-033 的
  `evidence/runs/TASK-RPT-001/2026-07-24-d2-fail-closed.md` 记录 #466
  original changed-file list。两处都是带 OID/PR 的 dated 历史过程证据，不是
  living consumer、权威 pin 或可点击导航链接，故不改写；长期文档对本 change
  仅以 `CHG-2026-023` ID 引用，归档不造成断链。
- 本 change 为 `platform` class，批准范围明确不改 Core spec/contract/schema；
  change-local acceptance cases 不进入 canonical acceptance registry。
  TASK-AU-002 已在 #457 同步产品实现、macOS platform profile 与发布规程，本次
  archive 没有 delta 需要合入 current specs、registry、baseline 或 profile。
- 本 archive 只改变治理位置与状态，不重新执行或放宽历史 AC，不构成 release、
  feed publish、Developer ID/notarization 验收、真实网络或设备操作。目录合入后
  冻结，不再改写。
