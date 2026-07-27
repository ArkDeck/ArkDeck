# TASK-DEC-003 implementation run

- Task:TASK-DEC-003（check_sdd fail-closed 修复与测试基建接线）
- Executor:agent（会话实现;never-claim,循环零认领）
- Date:2026-07-27
- Readiness:r1(#606 merge `5597a2e498fcd1ae5174b11a219236f4c3360cbf`,
  lvye APPROVED)
- Implementation base:`82512d419e176bd34d79474ddec18f20b60040d4`
- Hardware:none(host-only)。设备零触碰、GitHub 零写入。

## Input gate 复核

r1 三个 blob 在实现 base 上**逐一 HOLD**:`check_sdd.py` `87e39df7…`、
`test_check_sdd.py` `2e40b553…`、`sdd-guard.yml` `c64135e1…`。

## 存量清点复算（readiness 免停机制的前提,已在实现 base 上重跑）

r1 的七类清点在**当前 main 上仍全为零**:逐任务 Status 配对≠1、宽严正则
差集、全角冒号 Status 行、需跨界吸收才成立的 scope 认领、解析为 None 的
治理文件、重复 capability id、`changes/` 游离条目。**故收紧完全落在本任务
allowed paths 内,未触发「存量修正超出授权即停」条款,零 openspec 内容
改动。** 收紧后对真实仓复跑:`check-sdd` **0 error / 0 warning / 111**。

## 交付

- **A-H1**:claim surface 的终止符由「仅下一个顶层 bullet」改为
  `^(?:- |#{1,6}[ \t])`——任何层级的标题同样终止。修复前实测:出现在
  **后续 `## TASK-` 标题下**缩进散文里的 AC 被算作前一任务已认领。
- **A-H2 / A-M3**:`load_yaml` 新增 `empty_is_error`;scope.yaml、
  capability-registry、两个 lock、core-conformance 五处必需文档改为
  「解析为 None 即报错」,不再 `if not data: return` 静默跳过整检查。
- **A-M1a**:Status 行改为**逐任务配对**（每个 `## TASK-` 段恰一条),
  取代两个总数相减。
- **A-M1b**:状态词表加尾边界 `(?![A-Za-z0-9_-])`,并把 `[::]`（两个
  ASCII 冒号）修为 `[:：]`,与 check_pr_paths 的容忍面一致。
- **A-M2**:capability 列表逐项构建并显式报重复 id,取代 last-wins 字典
  推导;`requires` 的 `or []` 兜住 present-but-null。
- **A-M4**:acceptance case 非 mapping / 缺 `acceptance_id`、front matter
  非 mapping、locks 的 `profiles:`/`catalogs:` 为 null、缺
  `acceptance-index.txt` —— 全部由 traceback 改为具名 error。
- **A-L2**:`line.replace("(", " (")` 死代码随 A-M1a 重写移除。
- **A-L5**:`changes/` 下非 `chg-*`/`archive`/`README.md` 的条目显式报错
  （含仅大小写不同的目录名);`changes/` 缺失亦报错而非崩溃。
- **A-H3（CI 接线）**:`sdd-guard.yml` 的 guard job 新增两步——
  `python scripts/test_check_sdd.py` 与
  `python -m unittest discover -s host_loop -t .`（`working-directory:
  scripts`）。**刻意用 discover**:直跑套件文件只会收集其模块级
  `unittest.main()` 之前的部分,本仓已两次因此静默漏测。

## 验收

**变异门 8/8 全部击杀,负对照正确存活**:

| 变异 | 结果 |
| --- | --- |
| A-H1 终止符退回仅 bullet | KILLED(2) |
| A-H2 空文档又被静默接受 | KILLED(3) |
| A-M1a 退回总数相减 | KILLED(1) |
| A-M1b 去掉词表尾边界 | KILLED(3) |
| A-M2 重复 id 又 last-wins | KILLED(1) |
| A-M4 去掉 front matter 类型检查 | KILLED(1 error) |
| A-L5 游离条目又不检查 | KILLED(2) |
| A-H3 把 host_loop 改为直跑单文件 | KILLED(1) |
| **负对照**:仅改注释文字 | **SURVIVED**(正确) |

**A-M1a 首轮变异存活,如实记录并已修正**。首版 `StatusLinesArePairedWith
TheirTask._errors` **在测试里重新实现了配对循环**,断言的是它自己那份
逻辑而非 `check_changes()`——生产检查被禁用后测试照绿。这正是本仓记录
过 5 次以上的「套套逻辑」缺陷类,由变异 harness 逮到。修法 = helper 改为
真正驱动 `check_sdd.check_changes()` 并只筛其产出的 error。

**另一处自查**:A-L5 引入的 `changes_dir.iterdir()` 在目录缺失时会抛
`FileNotFoundError`（原 `glob` 返回空）。已补 `is_dir()` 守卫改为具名
error——**这是我引入的健壮性回归,由新测试当场发现**。

**套件与 guard**:`test_check_sdd.py` **40 tests OK**（基线 19）;
`check-sdd` 对真实仓 **0/0/111**;`test_agent_pr_workflow.py` **OK**
（workflow 契约未被本次改动破坏）。

**workflow 卫生**:guard job 顶层 `permissions: contents: read` 未变、
零 `secrets.`、零 `pull_request_target`、零 `contents: write`（以断言
钉死）。

## 遗留（不在 In scope,如实记录）

- 两 checker 的 task 标题文法/冒号容忍仍有分歧（台账 C-M7、A-L1 的
  check_pr_paths 侧）:本任务只统一了 check_sdd 的 Status 冒号面;
  `Depends on`/`Allowed paths` 的全角冒号分歧属 host_loop 侧,DEC-005
  已如实记录并保持 ASCII。统一与否留维护者裁量。
- A-L1/L3/L4/L6/L7/L8 等 LOW 项按台账 noted-not-tasked,未做。
