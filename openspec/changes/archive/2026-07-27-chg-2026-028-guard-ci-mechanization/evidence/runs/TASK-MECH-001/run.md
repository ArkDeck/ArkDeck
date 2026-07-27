# TASK-MECH-001 run — macOS Swift build+test CI job

- Date:2026-07-22;executor:agent(host-only;零设备/零 secret)。
- Base:main `42cc63123738313d253b25c9de78220e1e6814b5`(#327 合入后)。
- Readiness #323 pins 复核:`.github/workflows/swift-ci.yml` 于 base 不存在 ✓
  (纯新增,零既有文件触碰);runner 钉 `macos-15`;本地基线 = 346 tests /
  1 skip(worktree 口径另有 2 已知 `/private` 前缀环境性失败,具名见
  readiness;CI 正常 checkout 口径 = 346/1/0)。

## 交付

`.github/workflows/swift-ci.yml`,逐项对照 readiness 钉定:触发
`pull_request` + push `main`/`agent/**` ✓;`permissions: contents: read`、
零 secret ✓;`timeout-minutes: 30` ✓;concurrency 同 ref 后发取消先发 ✓;
v1 无 cache ✓;路径感知首步(PR 以 base sha、push 以 `event.before` 为 diff
基准;基准不可得 = fail closed 跑全量,宁多跑不漏跑)✓;job summary 恒输出
覆盖边界(ArkDeckKit only,App/XCUITest 不覆盖)与"CI 绿 ≠ 批准"注记 ✓。

## Run 证据(双向)

### Attempt #1(如实入档:失败,原因 = runner 默认工具链过旧)

- 首推 run `29923282514`/`29923242782`(head `b2a1dc80…7f50e`):**failure**——
  runner `macos-15` 默认 Xcode 16.4 / Swift 6.1.2,
  `Sources/ArkDeckWorkflows/HDCServerLifecycleJournalAdapter.swift:1275`
  编译错(`DropFirstSequence<String>` 重载解析差异;仓库基线 Swift 6.3.3)。
- **同轮 canary run `29923266563` 的红 = 同一编译错,未到达注入测试 →
  红反证无效,重做**(红必须由测试失败产生才证明"测试挂 = CI 红")。
- 修复:workflow 增 "Select Xcode" 步骤——显式选择镜像上的 Xcode 26.x
  (fail closed:找不到即失败并列出可用项,不静默降级);实现分支重建
  触发 fail-closed 全量路径重跑。

### Attempt #2 追加事实(2026-07-22):macos-15 天花板不足 → readiness r2 重钉

- 显式选择 macos-15 镜像最高 Xcode 26.3/Swift 6.2.4 后 run `29923580984`
  仍同一编译错 → 镜像天花板低于仓库基线;丢弃分支探针 run `29923763807`
  (success)实证 macos-26 镜像(macOS 26.4)载 Xcode 26.0–26.6 全谱。
- **readiness r2 = PR #333 已由维护者 merge(重钉 `macos-26` +
  `/Applications/Xcode_26.6.app` 精确选择,fail closed)**;本 workflow 按
  r2 更新后重跑。探针 auto-PR #332 已按作废 PR 规则立即 close(同 #330)。

### Attempt #3(r2 形态):双向成立

- **绿 run `29924110657`(agent/task-mech-001,push/fail-closed 全量路径)=
  success**:Selected `/Applications/Xcode_26.6.app`,CI 工具链 = Apple
  Swift 6.3.3(swiftlang-6.3.3.1.3)/ Build 17F113,与本地基线完全一致;
  `Test Suite 'All tests' passed`,**Executed 358 tests / 1 skipped /
  0 failures(0 unexpected)**。
  - 与 readiness 钉定 346 的差 = +12:readiness base(`c1581459…`)在
    #326(feat AIN-007 Rockchip typed executor,含新增测试)之前,实现
    分支 base(`42cc6312…` 之后)在其之后——增量可归因、非静默漂移;
    1 skipped = 既有 opt-in skip,无新增 skip;本地于最新 main 复测同数
    (见下)。CI 正常路径 checkout 下,readiness 预告的 2 个 `/private`
    前缀环境性失败如预期未出现(0 failures)。
- **红 run `29924117682`(agent/mech-001-canary)= failure,红因验证 =
  注入测试而非编译错**:log 载
  `MechCanaryAlwaysFailTests.swift:7: error: … testCanaryMustFail : failed -
  MECH-001 canary: this test exists only to prove swift-ci turns red`,
  编译通过(`Compiling ArkDeckContractTests MechCanaryAlwaysFailTests.swift`
  在案)。canary 分支随后删除;其 auto-PR #330/#332/#334 均已按作废 PR
  规则立即 close,注入面从未进入任何 merge。
- 本地复测(最新 main,`/private/tmp` worktree,2026-07-22):Executed 358 /
  1 skipped / 2 failures = 已知环境性两测试(与 CI 0 failures 的差异即该
  环境性族,CI 正常路径 checkout 不复现,与 readiness 口径一致)。
- canary 程序:丢弃分支 `agent/mech-001-canary` auto-PR #330 已按作废 PR
  规则立即 close;分支 run 完成后删除,永不合入;注入面(Packages/** 测试
  文件)只存在于丢弃分支。

## 检查

- check-sdd:0/0/111;diff 范围 = allowed paths 内(workflow 新文件 + 本
  run);tasks.md 未动。
- 字节级 U+200B/U+FEFF 自检零命中。

## AC 结论(candidate)

`MECH-CI-001`:主体达成——workflow 形态与 r2 钉定逐项一致;canary 红
(红因 = 注入 XCTFail,log 为证)✓;CI 工具链版本记录(Xcode 26.6/Swift
6.3.3/17F113)✓;全量绿(358/1skip/0)✓;测试数与 readiness 346 的差
+12 已归因(#326 AIN-007)且本地复测背书。done 前剩:**绿 run 累计 ≥3**
(随后续真实 PR 天然累积,含 docs-only 快速通过型)。required status
翻转 = 维护者 GitHub 设置动作,不属本 PR。

## 偏差与遗留

- **r1 → r2 重钉全程**(macos-15 天花板 Xcode 26.3/Swift 6.2.4 <
  仓库基线 6.3.3):attempt #1/#2 失败与探针事实见上,readiness r2 =
  #333 已 merge;三轮 attempt 均如实入档,零删改。
- 与 readiness 钉定的测试基线差(346→358)由 base 前进归因(见 attempt
  #3);done recheck 时应以当时 main 实测数为准。
- 交付形态:当前凭据可直接推 workflow 文件(SSH);BAP-003 收权后按
  design §5 复核。
