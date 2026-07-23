# TASK-MECH-003 run — structured full-hash pins guard

- Date:2026-07-23;executor:agent(host-only contract;零真实设备、零真实 HDC/
  rkdeveloptool、零 product network dispatch、零 secret;Swift suite 只运行
  host-side synthetic fixtures)。
- Implementation-start base:fresh `origin/main`
  `65ffe6d90457569e10cdde43a46d5478e972c664`;final delivery rebase base =
  `583b1c1d4de1a77fc0554908f9b45e28fe604a56`。
- Readiness gate:#350 由 `lvye` 对 exact head
  `2e99156135ba8ec7b965bb2dbdea705e1b5a638b` APPROVED 后合入;merge OID =
  `65ffe6d90457569e10cdde43a46d5478e972c664`;main push SDD Guard
  `29967920370` 与 Swift CI `29967920317` 均 SUCCESS。
- Readiness pins:
  - `scripts/check_sdd.py` blob
    `269f58bc70fc8e72f4daaffc03a20f59c0964c27` = **MATCH**;
  - `scripts/test_check_sdd.py` blob
    `e21500d22e80bdc9fedb3df8a3f1c97710517b02` = **MATCH**;
  - `openspec/templates/change/tasks.md` blob
    `7288cfe9bed5d8c5e998ee4d8baf1bf197f7ef74` = **MATCH**。
- Environment:Python 3.14.6 / PyYAML 6.0.3,位于
  `/private/tmp/arkdeck-mech003-venv`;依赖按仓库
  `scripts/requirements-sdd.txt` 安装,未写入仓库。
- Evidence class:offline contract + repository baseline + host-only Swift suite;
  不构成批准、授权或 hardware evidence。

## Pre-implementation scan

- exact `yaml pins` active inventory = **4 blocks / 8 digest values**:
  CHG-027 tasks 1 block/2 values、CHG-028 tasks 3 blocks/6 values;八值均为
  完整 40-hex blob。exact `yaml pin-example` active inventory = **1 block**,
  位于 CHG-028 design,按 r2 不作为 carrier。
- 三枚待改文件 blob 与 readiness 完整 OID 精确匹配。实现末 #351 由
  `lvye` 对 exact head `e09b80d68ad83e75a2a4eab63b33031246eba78d`
  APPROVED 后合入;merge OID =
  `583b1c1d4de1a77fc0554908f9b45e28fe604a56`,main push SDD Guard
  `29968836310` 与 Swift CI `29968836255` 均 SUCCESS。#351 只涉及
  CHG-015 归档/探针材料,与本任务 allowed paths 零交集;在新 main 上重验
  三枚 pin 仍精确 MATCH 后,本分支 rebase 到该 OID。
- 未修改基线:`test_check_sdd.py` = **13/13**、PR path contract =
  **12/12**、`check-sdd` = **0 errors / 0 warnings / 111 acceptance IDs**。

## Deliverables

- `check_structured_pins` 仅枚举 active
  `openspec/changes/chg-*` 下的 Markdown;逐行去首尾空白后,只有精确
  `yaml pins` opening 生效,精确三反引号 closing 结束。额外 info token、
  `yaml pin-example`、无 carrier 文档与顶层 `archive/**` 均不扫描;
  unterminated carrier fail closed。
- real carrier 使用仓内 `StrictLoader`;top-level 必须为 non-empty sequence,
  每项必须为 mapping,允许 key 封闭为 `path`/`artifact`/`blob`/`commit`/
  `sha256`;每项至少一个 digest。path/artifact 必须为非空 string,
  blob/commit 必须为完整 40-hex string,sha256 必须为完整 64-hex string。
- 每个非法 block 只追加一条具名错误,包含相对文件、opening line 与去重后
  确定性排序的原因;duplicate key、非 YAML、unknown key、错误类型、空
  sequence、无 digest、placeholder 与长度错误均 fail closed。
- change tasks 模板只加入非载体 `yaml pin-example` 及实例化指引:新 readiness
  必须改用 `yaml pins` 并填完整真实 hash;未追溯改写历史 carrier。

## Verification

| Command/check | Result |
| --- | --- |
| `/private/tmp/arkdeck-mech003-venv/bin/python scripts/test_check_sdd.py` | PASS:19 tests,0 failures/errors/skips(含 6 个 structured pins contract test methods) |
| `python3 scripts/test_check_pr_paths.py` | PASS:12 tests,0 failures/errors/skips |
| `/private/tmp/arkdeck-mech003-venv/bin/python -m py_compile scripts/check_sdd.py scripts/test_check_sdd.py` | PASS |
| `ARKDECK_PYTHON=/private/tmp/arkdeck-mech003-venv/bin/python ./scripts/check-sdd.sh` | PASS:0 errors,0 warnings,111 acceptance IDs |
| `CI=true swift test --package-path Packages/ArkDeckKit` | PASS:358 tests,1 skipped,0 failures;host-only fixtures,零真实设备/HDC/network dispatch |
| `git diff --check` | PASS |

负反证逐 case 断言 errors 增量恰为 1,并断言具名文件、opening line 与原因:
39/41-hex blob、63-hex sha256、placeholder、unknown/duplicate key、mapping/
scalar/empty top-level、scalar item、空 path、非 string artifact/digest、无 digest、
空 block、非 YAML 与 unterminated fence。多原因 block 另断言排序后的唯一错误;
非法 `yaml pin-example`、`yaml pins extra`、普通 prose 与 archive carrier 均断言
零错误。合法正例同时覆盖 blob、commit、sha256、大小写 hex、list indentation
与 fence trailing whitespace。

## Deviation and residual risk

- host Homebrew Python 3.14.6 初始未安装 PyYAML,首次两个 baseline 命令因
  `ModuleNotFoundError` 未形成校验结论;按锁定 requirements 在 `/private/tmp`
  建隔离环境后,以 Python 3.14.6 / PyYAML 6.0.3 重跑全部基线与实现后验证
  均通过。该环境修复未改变仓库 diff。
- 校验只证明 carrier、schema 与 hash 文本完整;不解析 Git object、不比较
  path 当前 blob、不证明 pin freshness/存在性/语义正确。真实性与 currency
  仍由 readiness review/evidence 负责,CI 绿不构成批准。
- Swift suite 仅出现既有编译 warning,358/1/0 结论不受影响。本任务没有执行
  真实设备、HDC、rkdeveloptool、deviceMutation 或 destructive step。
- 本 implementation PR 不翻 TASK-MECH-003 状态;合入后仍须独立
  `ready→done` D0 状态 PR。

## Live PR evidence

- PR #352 initial implementation head =
  `b529a7766ba904dd40068a1a6c1e06695cd5487b`;base =
  `65ffe6d90457569e10cdde43a46d5478e972c664`。push SDD Guard
  `29968709673` = SUCCESS。push Swift run `29968709691` = SUCCESS:
  macOS 26.4/Xcode 26.6/Apple Swift 6.3.3,因新分支无可靠 diff base 而
  fail closed 跑 ArkDeckKit 全量,日志为 **358 tests / 1 skipped /
  0 failures**。
- Agent PR 初次 open 产生的 pull_request runs `29968719713`/
  `29968719718` 为 `action_required`,不记作绿证据。补齐 PR body 的唯一
  `Task: TASK-MECH-003` 声明后,同 initial head 的真实 pull_request SDD
  Guard run `29968777617` = SUCCESS;其中 `guard` 与 live
  `allowed-paths` 两个 jobs 均实际运行并 SUCCESS。
- 不同 AI 会话对 initial head `b529a7766ba904dd40068a1a6c1e06695cd5487b`
  独立复核 = **APPROVE**;逐项重跑 19/19、12/12、0/0/111、Swift
  358/1/0 与 diff check,核对 #350 exact-head approval/merge、#351 零路径
  交集、allowed paths、schema/fence/error 聚合、模板与 evidence 诚实边界。
  reviewer 未修改文件、未提交 GitHub review 或 merge。
- rebase 前的 evidence-bearing head
  `cc8bd4d2d070e8a4961a8e0ee8c290c45bbc6e76` 亦取得完整 attached checks:
  push SDD/Swift `29968915301`/`29968915261`、pull_request SDD/Swift
  `29968917408`/`29968917418` 全部 SUCCESS;live `allowed-paths` 实际运行
  SUCCESS,PR Swift 全量为 358/1/0。不同 AI 会话对该 exact head 的复核亦
  **APPROVE**。随后只因 #351 已合入且 pins 未漂移,把相同任务 diff 重放到
  最新 main;旧 head 的绿检查不冒充 post-rebase head 检查。
- 承载本段 live 数据的后续 evidence commit 无法在自身内容中预写自身
  exact-head checks;其 pull_request Actions 与 final-head 独立复核必须以
  PR #352 attached checks/审查结果另行核验,未出现的 check 不推断为通过。

## AC conclusion(candidate)

`MECH-PIN-001`:本地 contract、真实 baseline、模板契约、host-only full
suite、initial implementation head live CI 与不同 AI 会话复核均 PASS;
evidence-bearing final head 仍须其自身 attached checks 与独立复核,且仅在
维护者 exact-head review/merge 后进入 protected main。本记录不把
task/change 标为 done/verified。
