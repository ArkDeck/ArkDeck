# TASK-MECH-004 run — PR allowed-paths diff guard

- Date:2026-07-22;executor:agent(host-only contract/CI;零设备、零 HDC、零
  network dispatch、零 secret)。
- Base:`2c8aacad5ca8bf78e62171d4a71bbc2cabdd9bd0`(fresh `origin/main`)。
- Readiness pin:`.github/workflows/sdd-guard.yml` blob
  `4a44098728cab7ac9752a6c539b28eaeb83ed13f` = **MATCH**;
  `scripts/check_pr_paths.py`/`scripts/test_check_pr_paths.py` 于 base 不存在;
  open PR 扫描为 0,零文件竞争。
- Evidence class:contract + live CI guard-rail;不构成批准/授权、安全边界或
  hardware evidence。

## Deliverables

- `scripts/check_pr_paths.py`:从 `$GITHUB_EVENT_PATH` 读取 PR title/body/head
  ref/base+head full OID,不把不可信字段插入 shell;按 body 独立 `Task:` 行 →
  title token → `agent/task-*` 顺序解析声明,互异声明/未知 task/无或空
  Allowed paths 均具名 fail closed;只扫描 active `chg-*/tasks.md`,archive
  不参与;用 `git diff --no-renames --name-only -z base..head` 与 fnmatch
  校验;未声明 task 的敏感面五类封闭列举。
- `scripts/test_check_pr_paths.py`:合成 fixture 覆盖声明优先级/歧义、exact+
  `**` 跨层 glob、`本 change` 展开、全部五类敏感面、docs-only 通过、未知
  task、Allowed paths 缺失/零 token、archive 跳过、现有 label 变体、复杂
  task header 分段以及 implementation/status/propose 三种形态。
- `.github/workflows/sdd-guard.yml`:保留既有 `guard` job 字节不动;新增只在
  `pull_request` event 执行的 `allowed-paths` job,`contents: read`、
  fetch-depth 0、10 分钟 timeout;先跑 contract tests 再审 live diff。

## Local verification

| Command/check | Result |
| --- | --- |
| `python3 scripts/test_check_pr_paths.py` | PASS:10 tests,0 failures/errors/skips |
| `python3 -m py_compile scripts/check_pr_paths.py scripts/test_check_pr_paths.py` | PASS |
| `ARKDECK_PYTHON=<PRIMARY_CHECKOUT>/.venv-sdd/bin/python ./scripts/check-sdd.sh` | PASS:0 errors,0 warnings,111 acceptance IDs(Python 3.14.6/PyYAML 6.0.3) |
| `git diff --check` | PASS |
| static shell audit | PASS:`subprocess.run` 仅 executable+argv array,零 `shell=True`/`os.system`;workflow 零 PR title/body/head expression 插值 |

首轮曾以 `python3 -m unittest -v scripts/test_check_pr_paths.py` 调用,因该
module 形态不把 `scripts/` 放入 import path 而产生 `ModuleNotFoundError`;
实现随即把 workflow 改为与仓库既有 guard test 相同的直接脚本入口,最终
direct run 10/0。该失败发生在 test harness import 阶段,未计为 guard
contract failure,亦未以强制 success 绕过。

## Active-format compatibility audit

实现前后以同一解析器扫描 active task headers:40 个 active task 中 31 个
符合 readiness 钉定的声明 token grammar;其中 27 个 Allowed paths 行可解析,
4 个会如实 fail closed:TASK-AIN-004 有多个 Allowed paths 行;
TASK-AU-002/TASK-OBS-001/TASK-OBS-002 缺该行。这四项当前均非 ready,未来
readiness 应在成 PR 工作前闭合格式,本任务不越界改写它们。

另有一个**当前 ready lane 的合并顺序风险**:TASK-TR-003 的 Allowed paths
行只有 `Packages/ArkDeckKit/Sources/**` 与 change evidence/tasks 两类
backtick token;其 prose“对应 Tests”不是机器 token,故本 guard 会拒绝
readiness 正文另行钉定的
`Packages/ArkDeckKit/Tests/ArkDeckContractTests/TraceAdapterGoldenTests.swift`。
不得在本实现 PR 内改写 TR-003 readiness。处置须二选一:TR-003 实现 PR
先于本 job 合入,或维护者先批准独立 D1 readiness/allowed-paths 规范化;
拿不准时 fail closed。

## Live evidence / AC state

`MECH-PATH-001`:**candidate,not done**。离线 contract 面已 PASS;实现 PR 的
live `allowed-paths` 绿、越界 canary 红及 implementation/status/propose 三种
真实形态累计须在 push/PR 后追加原始 run 链接。只有绿证据整体不接受;
canary 分支/PR 必须关闭且永不合入。required-status 翻转仍是 out-of-scope
D2 维护者动作;CI 绿不构成批准。

## Deviations and residual risk

- 零 Core/spec/contract/schema/constitution/enforcement 语义改动;archive 零
  改动;本任务不改变 task declaration grammar/readiness pins。
- guard-rail 不防恶意谎报其他 task;批准防线仍是维护者逐 PR review。
- status/propose live 形态只能在对应真实 PR 出现后累计,不以合成 fixture
  冒充;在 evidence gate 未闭合前不得翻 TASK-MECH-004 done。

## Post-merge independent review and remediation(2026-07-22)

- 实现 PR #335 在 PR-event SDD Guard/Swift CI 均为 `action_required`、
  `allowed-paths` 未执行且独立 review 尚未结束时,由维护者 `lvye` merge;
  merge OID = `72b295f4987410c57c04cf2d11a4b479bc8f63bf`,review head =
  `35507506319527bd13833019e024777f0a9af246`,GitHub `reviews=[]`。合入前
  可见绿只含 push `guard`/Swift;push `allowed-paths` 正确 skipped,不得冒充
  PR check。main push SDD Guard run `29928566248` success,但同样不验证
  pull_request live diff。
- 不同 AI 会话的合后 review 结论 = **REQUEST_CHANGES**,发现两项 blocking:
  1. workflow 使用 GitHub 默认 `pull_request` activity types,PR title/body/base
     被 edited 后不重跑,旧绿可能与当前声明或 `base..head` 脱节;
  2. checker 把 `\\` 改写为 `/`;Linux 上反斜杠是合法文件名字符,根目录
     `scripts\\outside.py` 会被错误改成 `scripts/outside.py` 并匹配
     `scripts/**`,形成具体 fail-open。
- 本独立 remediation 只在原 TASK-MECH-004 allowed paths 内修复:显式订阅
  `opened/synchronize/reopened/edited`;删除反斜杠改写,直接比较 `git -z`
  返回的 repository-relative path;新增两项回归测试。无 task status 翻转,
  不把合后修复伪装成 #335 的合前 APPROVE。

Remediation live PR、canary 红与独立复审链接在新分支 push 后追加;此前
`MECH-PATH-001` 保持 candidate/not done。

### Remediation live evidence

- Remediation PR
  [#336](https://github.com/ArkDeck/ArkDeck/pull/336),head
  `961af7db70847d19ea8d131e483a2481da887711`:PR body `edited` 触发
  [SDD Guard 29929295656](https://github.com/ArkDeck/ArkDeck/actions/runs/29929295656),
  `guard` **SUCCESS** + `allowed-paths` **SUCCESS**;后者先完成 12 项 contract
  tests,再对 live `base..head` diff PASS。这是实际 `pull_request` run,不是
  push skipped job。
- 不同 AI 会话对上述 remediation head 独立复审 = **APPROVE**:两项原
  blocking 均关闭,无新 blocking;复跑 12/12、py_compile、0/0/111、diff
  check 全绿;reviewer 未在 GitHub approve/merge。
- Draft canary
  [#337](https://github.com/ArkDeck/ArkDeck/pull/337),head
  `651c2d6ed783e04c8b8d57ef6a83b443f24e999c`:只额外加入越界
  `docs/mech-004-canary.md`。body `edited` 触发
  [SDD Guard 29929641697](https://github.com/ArkDeck/ArkDeck/actions/runs/29929641697):
  `guard` SUCCESS;`allowed-paths` contract tests SUCCESS;live check **FAILURE**
  并具名
  `declared task TASK-MECH-004 has paths outside Allowed paths:
  docs/mech-004-canary.md`,exit 1。#337 于 2026-07-22T14:40:24Z closed,
  `mergedAt`/`mergeCommit` 为空;远端 canary ref 查询为空,永未合入。

### PR CI gate recheck

初始 `pull_request` Swift CI run `29929220711` 为 `action_required`,当时
确实不可入队;该历史不改写。追加 live evidence 的 synchronize head
`238d2846ce62d38b0e4b23f2caf02462509b7033` 后,预期 PR Actions 已实际出现
并绿色:

- [SDD Guard 29929878055](https://github.com/ArkDeck/ArkDeck/actions/runs/29929878055):
  `guard` SUCCESS + `allowed-paths` SUCCESS(contract tests + live diff 均执行);
- [Swift CI 29929876685](https://github.com/ArkDeck/ArkDeck/actions/runs/29929876685):
  `swift` SUCCESS,路径感知明确判定零 Swift surface,full test 步骤 skipped,
  job summary success;未把快速路径冒充 Swift 全量。

本次文件更新仅把上述已完成 run 固定进 evidence;其后 PR final head 仍须 fresh
确认预期 checks 绿色 + 独立 reviewer 对 evidence-only delta 无新 finding 才可
入队。TASK-MECH-004 仍不得 done:status/propose 两种真实形态绿尚待自然累计,
且 required-status 翻转仍是 out-of-scope D2。

## r3 atomic-archive fallback remediation(2026-07-23)

- Executor:agent(host-only Python/Git contract);零设备、零 HDC、零
  `rkdeveloptool`、零 network dispatch、零 secret、零 device mutation。
- Initial fresh implementation base:
  `03a28162bc4ab75b661e996019056bf682174b54`;pre-push 又依次 fresh rebase 到
  `b53db548197486bd58d9236e183632c744f5276e`(#371,仅 CHG-2026-029
  revision files)与 `e48673fbe8c8440d7e12dbfe6aea5e94f996a4e2`
  (#372,仅 TASK-AFP-004 readiness),均与本任务零路径交集。r3 revision 已由
  #353 合入 main;开工及两次 rebase 后 readiness 两个源码 pins 均仍精确匹配:
  - `scripts/check_pr_paths.py` blob
    `9c8ba3aea54c9ce17e3bb7b033a2a570f34cb1c4`;
  - `scripts/test_check_pr_paths.py` blob
    `38cc148d1c0f238083aa738c5818781ba9422a0c`。
- 实现仅在 head active task 缺失时读取 base 的 active `chg-*/tasks.md`;
  archive tasks 始终不解析、不提供 authority。fallback 要求 base change root
  在 head 完全消失,且其全部 tracked entries 以相同 relative path、object
  type、blob OID 与 mode 迁入唯一、本次新增且具有有效日期的
  `YYYY-MM-DD-<change-dir>` target。经等值证明的 deletion/addition pair
  才豁免;其他 living diff 继续用 base task 的 Allowed paths 校验。
- fail-closed fixture 覆盖 archive-only、partial/extra、mutated、mode drift、
  copied/active-root residue、ambiguous targets、wrong/invalid target name、
  pre-existing target 与 living scope expansion;正例同时带一个明确 allowed
  的 living update,证明非 relocation 路径没有静默扩权。脚本继续只以
  executable + argv 调用 Git,零 host shell 拼接。

### Local verification

| Command/check | Result |
| --- | --- |
| `python3 -m py_compile scripts/check_pr_paths.py scripts/test_check_pr_paths.py` | PASS |
| `python3 scripts/test_check_pr_paths.py` | PASS:20 tests,0 failures/errors/skips |
| `/private/tmp/arkdeck-mech003-venv/bin/python scripts/test_check_sdd.py` | PASS:19 tests,0 failures/errors/skips(Python 3.14.6/PyYAML 6.0.3) |
| `ARKDECK_PYTHON=/private/tmp/arkdeck-mech003-venv/bin/python ./scripts/check-sdd.sh` | PASS:0 errors,0 warnings,111 acceptance IDs |
| `git diff --check` | PASS |

首轮组合命令中,system `python3` 在 20/20 路径合约通过后执行
`scripts/test_check_sdd.py` 时因环境缺少 `yaml` 而在 import 阶段退出;随后
复用已有 Python 3.14.6/PyYAML 6.0.3 环境得到上述 19/19 与 0/0/111。
该环境偏差如实保留,未被记为测试通过,也未下载依赖或强制 success。

首轮独立 review 对 head `a6bf749bee0a17e8e44fb6ce334a4d719c3df264`
给出 **REQUEST_CHANGES**:`datetime.date.fromisoformat()` 也接受
`2026-W01-1` ISO week-date,不满足精确 ASCII `YYYY-MM-DD`。实现随即先以
`^[0-9]{4}-[0-9]{2}-[0-9]{2}$` 封闭形态、再校验真实日历日期,并加入
`2026-W01-1-chg-test-archive` 具名失败反例;最终结论只以修复后的新 head
及其重新复验/复审为准。

### AC conclusion and residual state

- `MECH-PATH-001` r3 离线 atomic-archive 正反 contract:**PASS**。
- 本 remediation 不修改 workflow、任何 archive bytes、task status、Core/
  Safety/spec/contract;既有 r1/r2 live canary 与真实形态证据不被改写。
- 当前 TASK-MECH-004 仍为 `ready`;r3 实现 PR 的真实 pull-request CI、独立
  reviewer 与 merge 尚待后续追加,本记录不把本地结果冒充 PR 绿或人类批准,
  也不构成 change `verified`。

## r3 post-merge evidence closure(2026-07-23)

- r3 implementation PR
  [#373](https://github.com/ArkDeck/ArkDeck/pull/373):base
  `e48673fbe8c8440d7e12dbfe6aea5e94f996a4e2`,reviewed head
  `84d99b61ab52eb69ca11d9dd38e2a51fdcd123ec`;GitHub human review
  `APPROVED` by `lvye` 于 2026-07-23T02:54:46Z,review commit 与该 head
  精确一致。`lvye` 于 2026-07-23T02:54:53Z merge,merge OID =
  `0c10364addc0d5a70f093d69ecc61b8bfb075b09`。
- 不同 AI 会话最终 review 亦钉在该 exact head,结论 **APPROVE**、零 finding;
  其前一轮对旧 head `a6bf749bee0a17e8e44fb6ce334a4d719c3df264`
  的 week-date **REQUEST_CHANGES** 与修复历史继续保留,未被最终结论覆盖。
- Reviewed head 与 merge OID 的完整 tree 均为
  `c45080aeb146d72796c566d8720f504d153554f4`;对本 PR 三个交付路径执行
  `git diff --exit-code <head> <merge> -- <paths>` = PASS,零 tree drift。

### Live CI and timing

- 分支 push 上 [SDD Guard 29975458843](https://github.com/ArkDeck/ArkDeck/actions/runs/29975458843)
  `guard` SUCCESS、push-only `allowed-paths` 正确 skipped;
  [Swift CI 29975458842](https://github.com/ArkDeck/ArkDeck/actions/runs/29975458842)
  SUCCESS。该 Swift run 只按 workflow 自身路径策略解释,不冒充额外
  atomic-archive contract evidence。
- PR body 编辑触发真实 `pull_request` event
  [SDD Guard 29975599680](https://github.com/ArkDeck/ArkDeck/actions/runs/29975599680),
  head 精确为 `84d99b61ab52eb69ca11d9dd38e2a51fdcd123ec`:
  `guard` job `89106568292` SUCCESS;
  `allowed-paths` job `89106568356` SUCCESS,且其“PR allowed-paths contract
  tests”与“Check PR diff against declared task”两步均实际执行并 SUCCESS。
- 时间线必须保留:上述 PR run created at 2026-07-23T02:54:54Z、jobs start at
  02:54:57Z,晚于 #373 merge at 02:54:53Z;故这是**合后 PR-head 复验**,
  不是合前 entry-gate green,不得倒写。维护者 exact-head review/merge 是批准
  事实,CI 完成时序偏差作为 process residual 如实在案。
- Merge OID main push
  [SDD Guard 29975600680](https://github.com/ArkDeck/ArkDeck/actions/runs/29975600680)
  SUCCESS;
  [Swift CI 29975600682](https://github.com/ArkDeck/ArkDeck/actions/runs/29975600682)
  SUCCESS。

### Real-shape evidence gate closure

- implementation 形态与 canary 红反证仍分别由 #336 / #337 及上文 run
  支持。
- propose 真实形态:#359 head
  `39b5a8f5af244b9bf82d3f654b7f954046b2513b`,
  [SDD Guard 29971877142](https://github.com/ArkDeck/ArkDeck/actions/runs/29971877142)
  的 `guard` + `allowed-paths` 均 SUCCESS。
- status 真实形态:#367 head
  `f2948e3a5fd90b8e41260282e3e9137aece9b22d`,
  [SDD Guard 29973955756](https://github.com/ArkDeck/ArkDeck/actions/runs/29973955756)
  的 `guard` + `allowed-paths` 均 SUCCESS。
- 结合 r3 20/20 atomic-archive contract、#373 exact-head human/AI review、
  合后 PR-head green 与 main push green,`MECH-PATH-001` 的 task-level evidence
  gate 现为 **PASS**。本 evidence-only PR 不翻 task status;只有本记录经维护者
  review/merge 后才可另起 `ready→done` D0 状态 PR。required-status 配置仍为
  out-of-scope D2;change 仍非 `verified`。
