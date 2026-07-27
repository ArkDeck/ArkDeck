# CHG-2026-039 Tasks

> 两任务零共享文件、可并行；均为 host-only、never-claim（改动循环自身
> 代码/测试面，TASK-HLR-003 先例），由会话实现。`Decision-Grade` 行由
> 维护者亲笔（#577 先例），本文件不代写。

## TASK-NAV-001 — 全仓 discovery 缺省与 idle 判词真话

- Status:ready（r1 implementation readiness；仅在维护者对本独立 readiness
  PR exact head review/merge 后生效。只授权一个实现交付：按下方契约把缺省
  discovery 扩为全仓、修复 never-claim ready 过滤、加 UTC 时间戳/范围
  idle 行、并把 TASK-NAV-001/TASK-NAV-002 计入 `NEVER_CLAIM_ROOTS`；载体
  = 常规会话 agent/* PR（本任务 never-claim，循环不得认领）。不授权：
  transport/lease/identity/reviewer/recovery/cursor/backends/pr_envelope
  变更、launchd/plist 任何动作、`Decision-Grade` 代写、governance 正文、
  NAV-002 分工文件（见契约⑥）。）
- Historical Status:blocked（前置：① 本 change approval-only PR merge；
  ② 独立 readiness PR。① = #587 merge
  `17a9574a368e518ce475ef7d72135c3a6f71f2c7`；② = 本 r1。）
- Readiness（r1；audit base = protected `main`
  `17a9574a368e518ce475ef7d72135c3a6f71f2c7`）：
  - **Approval boundary:pending human merge。**本 carrier 只修改本文件。
    只有 `lvye` 对 exact head APPROVED、required checks terminal
    success、`mergedBy=lvye`、`auto_merge=null` 且 squash subject 携
    `(#N)` 的 merge OID 进入 protected main 后，本 readiness 才生效。
  - **Dependency gate:closed。**propose #586
    `fa4bdeaae305b7898e3412a210656842ff50e2e2`、approval #587
    `17a9574a368e518ce475ef7d72135c3a6f71f2c7`，均 `lvye` APPROVED、
    audit-base ancestors。
  - **Source pins:closed。**实现 base 须逐项等于：`__main__.py`
    `aa47dd45a29ac4531e4c38e3cbe84acaaf2b18a5`、`worker.py`
    `b9662c76a0948abb049d293b2b03948a8fb570a5`；任一 drift 停并重钉。
  - **Implementation contract:binary（2026-07-26 audit base 探针实测）。**
    ① 缺省（无 `--change`）round 与 `--explain` 扫描全部
    `openspec/changes/chg-*/tasks.md`（字典序，archive 除外），
    `--explain` 按 change 分组输出；显式 `--change <id>` 单 change 语义
    保留（`test_minter_and_explain` 既有显式 `--change` 用例零语义
    变更）。
    ② 跨 change 聚合下每轮至多一个 claim 的不变量、change-approved 门
    逐 change 判定，均以正/负 fixture 契约测试钉死。
    ③ never-claim ready 过滤——**audit base 红探针已实测**：status=done
    的 `TASK-HLR-003` 候选经 `select()` 仍产出
    `ONLY_NEVER_CLAIM_READY` 与判词 `only never-claim tasks are ready
    (['TASK-HLR-003'])`；实现后同输入不得再产出该 outcome（回归测试）；
    status=ready 的 never-claim 候选仍产出（正对照 = 既有
    `SelfClaimStop` 用例零修改保持绿，其 fixture 缺省即 ready）。变异
    门：撤销 ready 过滤 → 回归测试必红。
    ④ `NEVER_CLAIM_ROOTS`（worker.py 现 = `{"TASK-HLR-003"}`）增
    `TASK-NAV-001`、`TASK-NAV-002`；新增测试钉**精确三根集合**（先例：
    冻结集合钉内容不钉 len）。
    ⑤ idle/claim 日志行加 UTC ISO-8601 时间戳与扫描范围（change 数/
    候选数），格式契约测试钉死。
    ⑥ **File partition（与 NAV-002 并行零交集）**：本任务只改
    `worker.py`、`__main__.py`、新文件
    `scripts/host_loop/test_navigation_contract.py`，以及仅当缺省
    explain 形态变化打红其无 `--change` 用例时的
    `test_minter_and_explain.py` 最小适配；不触碰 NAV-002 分工的
    `check_pr_paths.py`/`test_check_pr_paths.py`/`test_backends_cli.py`/
    `test_discovery_contract.py`/`test_pr_envelope.py`/
    `test_support.py`。
    ⑦ 套件：audit base 基线 = 482 OK + 1 expectedFailure；实现后 =
    482 + 新增数全绿 + 1 xf 保持（精确计数入 PR body 与 evidence）；
    `check-sdd` 0/0/111；diff 恰在 Allowed paths 内。
  - **Deployment terms:closed。**LaunchAgent plist 不含 `--change`，
    缺省值改动即部署；两 left-running unit 零动作；生效 = 运行机
    checkout 前进至含实现的 protected main。实现合入前不得以
    `--change` 本 change 跑任何 foreground round。
  - **Concurrency/absence:closed at drafting（2026-07-26 23:56）。**
    remote `agent/*nav*` 分支 = 0（推送前实测；本 readiness 与 NAV-002
    readiness 为堆叠双 carrier，按序合并）。
  - **Grade 注记**：`Decision-Grade` 行由维护者亲笔（#577 载体先例）；
    本契约已机器化，符合 D0 三条件；④ 的 never-claim 为结构性防自认领
    门，grade 与 claim 面解耦。
- Platform:macos（host-only；零设备/HDC/网络写入面变更）
- Requirements/AC:change-local `NAV-DISC-001`、`NAV-TRUTH-001`
- Depends on:none
- In scope:`__main__.py` `--change` 缺省从字面量
  `CHG-2026-030-host-loop-runtime` 改为全活跃 change 扫描（字典序；显式
  `--change <id>` 保留单 change 语义；`--explain` 缺省同样全仓枚举，输出
  按 change 分组）；跨 change 聚合下「每轮至多一个 claim」不变量与全部
  既有认领门逐一保持，change-approved 门逐 change 判定；`worker.py`
  `select()` never-claim 分支仅对 `status == ready` 候选判定（修复
  done-never-claim 误报）；idle/claim 日志行加 UTC ISO-8601 时间戳与
  扫描范围（change 数/候选数）。
- Out of scope:`DISPATCHABLE_GRADES` 与 GATED 语义、never-claim 政策
  本体、lease/transport/identity/reviewer/recovery/cursor、launchd
  unit/plist（零动作）、grade 行、任何 governance 正文。
- Allowed paths:`scripts/host_loop/__main__.py`、
  `scripts/host_loop/worker.py`、`scripts/host_loop/test_*.py`（既有
  测试文件的必要适配与新增 navigation 契约测试）、本 change
  `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）。
- Forbidden paths:`scripts/host_loop/transport.py`、
  `scripts/host_loop/lease.py`、`scripts/host_loop/identity.py`、
  `scripts/host_loop/reviewer.py`、`scripts/host_loop/recovery.py`、
  `scripts/host_loop/cursor.py`、`scripts/host_loop/backends.py`、
  `scripts/host_loop/pr_envelope.py`、`scripts/check_pr_paths.py`、
  `.github/**`、`openspec/governance/**`、`openspec/specs/**`、
  `openspec/contracts/**`、`openspec/changes/archive/**`、产品
  source/tests、其他 change。
- Risk:low（扫描范围扩大、认领门全数保持；idle 分支只收紧；回退 =
  revert）。
- Hardware required:no。
- Decision-Grade:D0。

### Deliverables

- 全仓 discovery 聚合（含 change-approved 逐 change 判定与单 claim
  不变量的契约测试：多 change fixture + 对真实仓的活体断言）；
- never-claim ready 过滤修复 + 回归测试（构造 done 状态 never-claim
  任务，断言不再产生 `only never-claim tasks are ready` 判词；正对照 =
  ready 状态 never-claim 仍产生）；
- 带时间戳/范围的 idle 行（格式契约测试）；
- evidence run 记录套件前后计数与 `check-sdd` 0/0 基线、生效条款
  （checkout 前进即生效，两 unit 零动作）。

### Verification

- `NAV-DISC-001`：缺省 round/`--explain` 对全部活跃 change 枚举（对真实
  仓断言 change 计数与已知 gated 任务可见性，形态 = 独立最小抽取对照，
  stale-proof）；显式 `--change` 单 change 语义回归绿；聚合下每轮至多
  一 claim 的不变量被契约测试钉死。
- `NAV-TRUTH-001`：done-never-claim 误报回归测试红→绿证据（变异门：撤销
  ready 过滤该测试必红）；idle 行含 UTC 时间戳与扫描范围。

### Notes / handoff

- 生效条件 = 运行机 checkout 前进到含本实现的 protected `main`（plist
  无 `--change`，缺省值改动即行为改动）；两 left-running unit 零动作。
- 本任务落地后，循环对全仓 gated/ready 状态的报告成为维护者派发队列的
  真实来源；首个自主认领对象 = 此后出现的任意 D0 任务。

## TASK-NAV-002 — check_pr_paths 与活体样本测试的 archive 免疫

- Status:ready（r1 implementation readiness；仅在维护者对本独立 readiness
  PR exact head review/merge 后生效。只授权一个实现交付：按下方契约扩
  `check_pr_paths` 任务查找至 archive、给活体样本测试引入 archive 免疫、
  并以归档演练取证；载体 = 常规会话 agent/* PR（本任务 never-claim，
  循环不得认领；`NEVER_CLAIM_ROOTS` 扩根由 NAV-001 交付）。不授权：
  `check_pr_paths.py` 路径匹配/任务解析语义变更（仅扩查找面）、host_loop
  非测试代码变更、归档 PR 本身、`Decision-Grade` 代写、governance 正文、
  NAV-001 分工文件（见契约④）。）
- Historical Status:blocked（前置：① 本 change approval-only PR merge；
  ② 独立 readiness PR。① = #587 merge
  `17a9574a368e518ce475ef7d72135c3a6f71f2c7`；② = 本 r1。）
- Readiness（r1；audit base = protected `main`
  `17a9574a368e518ce475ef7d72135c3a6f71f2c7`）：
  - **Approval boundary:pending human merge。**本 carrier 只修改本文件。
    生效条件与 NAV-001 r1 同型（`lvye` exact head APPROVED、checks
    terminal success、squash merge 进 protected main）。
  - **Dependency gate:closed。**propose #586
    `fa4bdeaae305b7898e3412a210656842ff50e2e2`、approval #587
    `17a9574a368e518ce475ef7d72135c3a6f71f2c7`，均 `lvye` APPROVED、
    audit-base ancestors。与 NAV-001 readiness 为堆叠双 carrier，按序
    合并；两任务实现可并行（契约④文件分工零交集）。
  - **Source pins:closed。**实现 base 须逐项等于：`check_pr_paths.py`
    `02332a9b572013e99b74acd46db8810ba4f7275a`、`test_check_pr_paths.py`
    `feb697f760c8b2ba9e57072ac79f73a96ed7905f`、`test_backends_cli.py`
    `bb0521083c58b6c204d61d1cc6d2cbd6cab6da0b`、
    `test_discovery_contract.py`
    `c9c8e43edf0fdc764cf6299de00e6b71a28dc7e5`、`test_pr_envelope.py`
    `35d9a284e8ddde67fd1076bc1c2f0f11f02d26db`；任一 drift 停并重钉。
  - **Implementation contract:binary（2026-07-26 audit base 探针实测）。**
    ① `load_task_definitions`（现仅 glob `chg-*/tasks.md`）扩至同时含
    `archive/*/tasks.md`（#548 `done_task_ids` 同型）。**红探针已实测**：
    audit base 上 lookup 共 58 任务，archived `TASK-TAS-001` 与
    `TASK-MPF-001` 均不可见；实现后正 fixture = archived 任务可见
    （`TASK-TAS-001` 级真实样本），负 fixture = 不存在的任务仍拒绝
    （fail-closed 保持）。变异门：撤销 glob 扩展 → 正 fixture 必红。
    ② 活体样本 archive 免疫，两条 #573 已录路线按用例性质取舍并入
    evidence：纯文件读取断言改经新增单一支持文件
    `scripts/host_loop/test_support.py` 的 active-or-archive 解析
    （`changes/<id>/tasks.md` 与 `changes/archive/*-<id>/tasks.md`
    恰一处存在，两处都在/都不在即 loud fail）；以
    `discover_candidates(change_id)` 为被测面的用例改为动态活跃样本
    （字典序首个含任务的活跃 change）或等价保真形态。受改用例清单 =
    `test_backends_cli.BodyRendering` 三项、
    `DiscoveryIsAReaderOnly.test_it_parses_the_live_change`、
    `test_pr_envelope` pr_type 子例、`test_check_pr_paths` 真实仓调用。
    「对真实仓内文件断言」规矩不削弱；归档演练为最终裁决门。
    ③ **归档演练（evidence 门）**：scratch worktree 内 `git mv`
    `openspec/changes/chg-2026-030-host-loop-runtime` →
    `openspec/changes/archive/<date>-chg-2026-030-host-loop-runtime`
    后，全量 suite 与 `check_pr_paths`/`check_sdd` 测试全绿；#573 具名
    1+5 error（`test_check_pr_paths` 真实仓用例、`BodyRendering`×3、
    `DiscoveryIsAReaderOnly.test_it_parses_the_live_change`、
    `test_pr_envelope` pr_type 子例）全消；worktree 弃置不入仓，命令与
    前后计数入 evidence。
    ④ **File partition（与 NAV-001 并行零交集）**：本任务只改
    `check_pr_paths.py`、`test_check_pr_paths.py`、
    `test_backends_cli.py`、`test_discovery_contract.py`、
    `test_pr_envelope.py` 与新文件 `scripts/host_loop/test_support.py`；
    不触碰 `worker.py`/`__main__.py`/`test_navigation_contract.py`/
    `test_minter_and_explain.py`。
    ⑤ 套件：audit base 基线 = 482 OK + 1 expectedFailure；实现后 =
    482 + 新增数全绿 + 1 xf 保持（精确计数入 PR body 与 evidence）；
    `check-sdd` 0/0/111；diff 恰在 Allowed paths 内。
  - **Concurrency/absence:closed at drafting（2026-07-26 23:56）。**
    remote `agent/*nav*` 分支 = 0（推送前实测；本 carrier 与 NAV-001
    readiness 堆叠）。
  - **Grade 注记**：`Decision-Grade` 行由维护者亲笔（#577 载体先例）；
    本契约已机器化，符合 D0 三条件。done 后 chg-2026-030/027/028 归档
    链解锁（归档 PR 独立走）。
- Platform:macos（host-only）
- Requirements/AC:change-local `NAV-ARCH-001`
- Depends on:none
- In scope:`check_pr_paths.py` 任务查找由 `chg-*/tasks.md` 扩展为同时
  查 `archive/*/tasks.md`（#548 `done_task_ids` 同型；未知任务仍 fail
  closed）；host_loop 活体样本测试（`test_check_pr_paths` 的真实仓调用、
  `test_backends_cli.BodyRendering` 三项、
  `DiscoveryIsAReaderOnly.test_it_parses_the_live_change`、
  `test_pr_envelope` pr_type 子例）引入 active-or-archive 路径解析
  （`changes/<id>/` 与 `changes/archive/*-<id>/` 恰一处存在），保持
  「对真实仓内文件断言」规矩不削弱。
- Out of scope:`check_pr_paths.py` 的路径匹配/任务解析语义（仅扩查找
  面）、host_loop 运行时代码、归档 PR 本身、grade 行、governance 正文。
- Allowed paths:`scripts/check_pr_paths.py`、
  `scripts/test_check_pr_paths.py`、`scripts/host_loop/test_*.py`（活体
  样本解析的共享 helper 允许新增单一测试支持文件）、本 change
  `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）。
- Forbidden paths:`scripts/host_loop/` 全部非测试 `.py`、`.github/**`、
  `openspec/governance/**`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`（读不写）、产品 source/tests、其他
  change。
- Risk:low（查找面只扩不收；未知任务拒绝路径保持；回退 = revert）。
- Hardware required:no。
- Decision-Grade:D0。

### Deliverables

- archive glob 扩展 + 正 fixture（archive 内任务被正确解析）+ 负
  fixture（不存在的任务仍拒绝）；
- 活体样本 active-or-archive 解析 helper 与五处测试的适配；
- **归档演练证据**：scratch worktree 内 `git mv`
  `openspec/changes/chg-2026-030-host-loop-runtime` →
  `openspec/changes/archive/<date>-chg-2026-030-host-loop-runtime` 后，
  全量 suite 与 `check_pr_paths` 测试保持绿（#573 所列 1+5 error 全部
  消失），worktree 弃置不入仓。

### Verification

- `NAV-ARCH-001`：归档演练绿 + 正/负 fixture 双向证据 + `check-sdd`
  0/0 基线保持；#573 dated 注记所列两条收口条件由本任务闭合其一
  （glob+fixtures 路线），archive-blocked 的 chg-2026-030/027/028 归档
  链解锁（归档 PR 独立走，不在本任务内）。

### Notes / handoff

- 本任务 done 后，chg-2026-030 proposal 的 dated 注记应在其 archive PR
  中引用本任务为收口证据（该 PR 属后续独立 governance，非本 change
  载体）。
