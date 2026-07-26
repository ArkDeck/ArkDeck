# CHG-2026-039 Tasks

> 两任务零共享文件、可并行；均为 host-only、never-claim（改动循环自身
> 代码/测试面，TASK-HLR-003 先例），由会话实现。`Decision-Grade` 行由
> 维护者亲笔（#577 先例），本文件不代写。

## TASK-NAV-001 — 全仓 discovery 缺省与 idle 判词真话

- Status:blocked（前置：① 本 change approval-only PR merge；② 独立
  readiness PR 以 TAS-001 形态钉定实现契约——受改两文件的 exact blob、
  「恰 N 断言反应」变异门、期望套件计数、never-claim 声明与 launchd
  零动作条款。）
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

- Status:blocked（前置：① 本 change approval-only PR merge；② 独立
  readiness PR 钉定受改文件 exact blob、五处活体样本测试清单、正/负
  fixture 形态与归档演练步骤。）
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
