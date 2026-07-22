# CHG-2026-028 Tasks

> 四任务全 host-only、各自独立 readiness/实现/done PR。MECH-002→003 串行
> (同改 guard 两文件);MECH-001/004 与其余零文件交集可并行。本 change 首 PR
> 只 proposal 五件套,零实现、零 evidence。

## TASK-MECH-001 — macOS Swift build+test CI job

- Status:ready(2026-07-22 本 readiness PR;前置 ① 已满足 = approval #318
  merge `c15814593ea3d46149e749d3a47121ea70af1cea`;状态仅在维护者
  review/merge 本 PR 后生效)
- Readiness(r1,base = main `c15814593ea3d46149e749d3a47121ea70af1cea`):
  - 本地全量基线(worktree @ base 实测,2026-07-22;toolchain = Apple Swift
    6.3.3(swiftlang-6.3.3.1.3)/ Xcode 26.6(17F113)):**346 tests /
    1 skipped / 2 failures(0 unexpected)**;该 2 失败为已知 `/private/tmp`
    worktree 环境性族并逐名确认 =
    `HDCGoldenResourceContractTests.testGoldenPackContainsExactRegisteredFixtureSetWithMatchingHashes`
    与 `HDCProbeRegistryContractTests.testPackContainsExactPinnedResourceSetAndHashes`
    (`/private` 前缀 #filePath 解析,先例 #301/#305 在案)。**CI 正常路径
    checkout 口径 = 346/1 skip/0 failures**;若 runner 上述两测试复现失败,
    处置 = 显式豁免清单 + 具名注记(实现 PR 载明),禁止静默 skip/`|| true`。
  - Runner pins:GitHub-hosted `macos-15`;实现时该 label 不可用或排队异常
    → 停回 readiness 重钉,不静默换 image;CI 实际 Xcode/Swift 版本以首个
    run 记 evidence(与本地 6.3.3 差异如实记录,不作为失败豁免理由)。
  - workflow 形态钉定:触发 = `pull_request` + push `main`/`agent/**`(与
    sdd-guard 对齐);`permissions: contents: read`、零 secret;
    `timeout-minutes: 30`;concurrency = 同 ref 后发取消先发;v1 无 cache
    (零第三方依赖,增量 cache key 复杂度 > 收益,时长成瓶颈另立);路径感知
    首步 = diff 触碰 `Packages/**`/`Package.*` 判定,未触碰秒级 success 并
    job summary 注记;App/XCUITest 不覆盖亦注记进 summary(不伪装覆盖)。
  - 待改文件:`.github/workflows/swift-ci.yml` 于 base 不存在(纯新增,
    零既有文件触碰);交付形态 = 当前凭据经 SSH 推送不受 `workflow` scope
    限制,agent 可直接推;TASK-BAP-003 收权落地后按 design §5 复核
    (agent 起草 + 维护者应用)。
  - canary 钉定:丢弃分支(`agent/mech-001-canary`)注入必败测试 → run 红 →
    evidence 记链接 → 删分支,永不合入。
  - Review boundary:本 PR 只翻转 `blocked→ready` 并登记 pins/基线;实现 PR、
    `ready→done` 状态 PR 各自独立,均须维护者 review/merge。
- Objective:交付 `.github/workflows/swift-ci.yml`(design §1):macOS runner
  上对 PR 与 `main`/`agent/**` push 跑 ArkDeckKit `swift test` 全量;路径感知
  恒运行(未触碰 Swift 面秒级 success);零 secret、`contents: read`、
  timeout + concurrency 取消;App/XCUITest 面不覆盖且在 job summary 如实注记。
- Requirements/AC:change-local `MECH-CI-001`(见 acceptance-cases.yaml)。
- Depends on:approve。
- In scope:上述 workflow 文件;canary 红反证(注入必败测试的丢弃分支,
  永不合入);evidence run(真实 PR 绿 ≥3 + canary 红 run 链接)。
- Out of scope:branch protection required 翻转(维护者 GitHub 设置动作,
  evidence 只记录其发生与时点);App/XCUITest CI;覆盖率/性能门。
- Allowed paths:`.github/workflows/swift-ci.yml`、本 change `evidence/**`、
  本 change `tasks.md`(仅本任务状态)。
- Risk:low-medium(CI 时长/稳定性风险;失败模式 = check 不可靠则维护者不翻
  required,回到人工核验,零治理损失)。
- Hardware required:no。
- Verification:`MECH-CI-001`;check-sdd 绿。
- Evidence gate:workflow 合入 + 绿/红双向 run 证据在案后 `ready→done` 独立
  状态 PR。

## TASK-MECH-002 — guard 三方 revision 同步校验

- Status:blocked(双前置:① approve;② 独立 readiness PR——须钉
  `scripts/check_sdd.py`/`scripts/test_check_sdd.py` 基 blob(全 OID)与当期
  active changes 三元组实测清单;存量漂移如有,先以所属 change 名义独立 PR
  修复)
- Objective:`check_sdd.py` 新增校验(design §2):active changes 的 proposal
  `revision` == acceptance-cases `change_revision` == verification `@rN`,
  不一致每 change 恰一条具名 err(含三处实值);header 缺失/不可解析 err
  (fail closed);`archive/**` 豁免;合成 fixture 正反例测试。
- Requirements/AC:change-local `MECH-REV-001`(见 acceptance-cases.yaml)。
- Depends on:approve。
- In scope:guard 与其测试;evidence run(fixture 测试结果 + 真实基线前后
  0/0/111 对照)。
- Out of scope:存量漂移修复本体(所属 change 名义独立 PR);archive 目录
  任何改动。
- Allowed paths:`scripts/check_sdd.py`、`scripts/test_check_sdd.py`、本
  change `evidence/**`、本 change `tasks.md`(仅本任务状态)。
- Risk:low(只读校验;误报以 0/0/111 基线保持为门)。
- Hardware required:no。
- Verification:`MECH-REV-001`;check-sdd 绿。
- Evidence gate:实现 PR 合入后 `ready→done` 独立状态 PR。

## TASK-MECH-003 — pins 结构化全 hash 校验

- Status:blocked(三前置:① approve;② TASK-MECH-002 done(同文件串行,
  design §6);③ 独立 readiness PR——须重钉 guard 两文件基 blob 与 pins block
  语法定稿)
- Objective:定义 fenced `pins` block 约定并入 guard 校验(design §3):
  `blob`/`commit` 恰 40 hex、`sha256` 恰 64 hex,yaml 不可解析/长度非法即
  具名 err;无 block 文档不校验(opt-in 收紧)、`archive/**` 豁免;
  `openspec/templates/change/` 相关模板加 pins block 示例与"新 readiness 应
  使用"注记(模板改写先例 = CHG-2026-025 TASK-AIN-001);合成 fixture
  正反例测试。
- Requirements/AC:change-local `MECH-PIN-001`(见 acceptance-cases.yaml)。
- Depends on:approve、TASK-MECH-002 done。
- In scope:guard 与其测试;change 模板 pins 示例;evidence run。
- Out of scope:既有文档的 pins 追溯改写;prose 缩写惯例(不受限)。
- Allowed paths:`scripts/check_sdd.py`、`scripts/test_check_sdd.py`、
  `openspec/templates/change/**`、本 change `evidence/**`、本 change
  `tasks.md`(仅本任务状态)。
- Risk:low(opt-in 结构,零存量影响)。
- Hardware required:no。
- Verification:`MECH-PIN-001`;check-sdd 绿。
- Evidence gate:实现 PR 合入后 `ready→done` 独立状态 PR。

## TASK-MECH-004 — PR allowed-paths diff 校验

- Status:blocked(双前置:① approve;② 独立 readiness PR——须钉任务声明
  解析约定定稿(标题/body/分支名优先序)、敏感面清单、glob 语义与交付形态
  (design §5 凭据注记))
- Objective:新 CI job(design §4,`pull_request` event,可并入 sdd-guard
  workflow):声明 `TASK-*` 的 PR 校验 diff ⊆ 该任务 Allowed paths(反引号
  token 提取为 glob,`本 change` 前缀解析;行缺失/零 token/任务不存在 err,
  fail closed);未声明任务的 PR 触碰敏感面(`Packages/**`、`ArkDeckApp/**`、
  `ArkDeckAppUITests/**`、`scripts/**`、`.github/**`)即红,纯 docs/governance
  diff 通过;校验脚本 + 单元测试 + canary 红反证。
- Requirements/AC:change-local `MECH-PATH-001`(见 acceptance-cases.yaml)。
- Depends on:approve。
- In scope:`.github/workflows/sdd-guard.yml`(新增 job)、校验脚本与测试;
  canary draft PR(触碰 forbidden path 证红,丢弃不合入);evidence run
  (三类真实形态 PR 绿 + canary 红)。
- Out of scope:谎报任务声明的防御(guard-rail 边界,design §4;防线 =
  维护者 review);tasks.md 格式改造(解析现行格式)。
- Allowed paths:`.github/workflows/sdd-guard.yml`、
  `scripts/check_pr_paths.py`、`scripts/test_check_pr_paths.py`、本 change
  `evidence/**`、本 change `tasks.md`(仅本任务状态)。
- Risk:medium(误报会挡正常 PR;失败模式 = job 移除/修复走独立 PR,
  维护者可随时不设 required,零治理损失)。
- Hardware required:no。
- Verification:`MECH-PATH-001`;check-sdd 绿。
- Evidence gate:job 合入 + 绿/红双向 run 证据在案后 `ready→done` 独立状态
  PR。
