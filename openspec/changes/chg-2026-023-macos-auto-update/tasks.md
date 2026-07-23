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

- Status:blocked(三前置:① approve;② TASK-AU-001 done(选型认可);③ 独立
  readiness PR——须钉选型记录 OID、依赖 pin 方案(如适用)、entitlement diff
  声明与实现基线)
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
- Risk:medium(首个出站网络面 + 可能的首个第三方依赖;fail-closed 与隐私
  边界是核心不变量)。
- Hardware required:no。
- Verification:`AU-CONTRACT-001` 验签 fail-closed 矩阵(feed 签名坏/缺、下载物
  Team 不符/未签名、中断/截断——全部零安装动作)+ 零静默安装 + entitlement 集
  与声明一致断言;`AU-PRIVACY-001` 更新检查请求字段白名单断言(零设备/用户
  标识)+ 披露文案存在;全量基线零回归。
- Evidence gate:contract 全绿 + 发布规程文档在案后合入;`ready→done` 独立状态
  PR;change verified = ADR-0002 release gate #3 满足(另行 verify PR)。
