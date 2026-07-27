# TASK-NAV-002 run log

## implementation（2026-07-27，r2 契约）

### 交付内容

- 新增 `scripts/host_loop/test_support.py`：`change_tasks_path`
  （active-or-archive 恰一处存在，0/2+ loud fail）、`live_sample_change`
  （活跃 change 中候选数最多者；过滤①frontmatter id 与目录名不自洽的
  change——discovery 按目录、envelope 校验按 frontmatter，两形不一致者
  （如短形 `CHG-2026-026`）无法同时服务两面；②headers ≠ candidates 的
  字段不全 change——真实文件契约断言两数相等）、`first_task_id`；三
  helper 自带 11 条单元测试（双向 loud-fail fixture + 对真实仓断言）。
- 四文件活体样本适配（r2 契约②路线分派）：
  - `test_discovery_contract.py`：`REAL_TASKS` 经 `change_tasks_path`
    解析（chg-2026-030 done 后内容冻结，shape/punctuation/Historical
    计数类断言永久稳定）；`AgainstTheRealFile` 的 discovery 半幅改
    动态样本；HLR-003 终态断言 = `done_task_ids` + 冻结正本独立最小
    抽取（status=done），瞬时候选半幅退役；expectedFailure 用例改依
    动态样本并更新 docstring；fence 真实文件用例改为「声明集 ==
    discovery 产出集」集合等值形态。
  - `test_backends_cli.py`：`BodyRendering` 三项 + 漏网的
    `DiscoveryIsAReaderOnly.test_it_parses_the_live_change`（#573 具名
    原件）全部动态采样。
  - `test_pr_envelope.py`：`CHANGE_ID`/`TASK_ID` 动态化；`TASK_ID` 取
    「带字面量 allowed path 的首个任务」，其字面量作为 MECH-004 端到端
    的 changed 文件（原硬编码 chg-030 路径退役）；两处字面量 `.replace`
    改 f-string。
  - `test_check_pr_paths.py`：`test_current_hlr_001a…` 重写为动态采样
    （归档后任务不再供权威是既有设计，原样本不可能存活归档）。
- **`check_pr_paths.py` 零字节变更**（invariant pin
  `02332a9b572013e99b74acd46db8810ba4f7275a`：实现前后 `git diff` 零
  输出，blob 相等）。

### 常态树验证（audit base 前进至 #594/#593 合成树）

- host_loop 套件：**536 OK + 1 expectedFailure**（#593 时点基线 525 +
  本任务新增 11）；`test_check_pr_paths.py` OK；`test_check_sdd.py` OK；
  `check-sdd` 0/0/111；diff 恰为 r2 Allowed 五文件 + 本 evidence。
- r2 基线注记：readiness r2 的「基线 482」钉于 audit base `74e7cf9`；
  其后 #594（TASK-NAV-001 实现）先行合入使基线前进为 525（+43），r2
  的四文件 source pins 与 invariant pin 经 rebase 复核零漂移，故按
  「全绿 + 1 xf 保持、精确计数入 evidence」履约。

### 归档演练（最终裁决门；scratch worktree，弃置不入仓）

```
git worktree add <scratch>/nav002-drill --detach agent/task-nav-002
git -C <scratch>/nav002-drill mv \
  openspec/changes/chg-2026-030-host-loop-runtime \
  openspec/changes/archive/2026-07-27-chg-2026-030-host-loop-runtime
```

- **#573 具名 1+5 error 全消**：`test_check_pr_paths` 真实仓用例、
  `BodyRendering`×3、`DiscoveryIsAReaderOnly.test_it_parses_the_live_
  change`、`test_pr_envelope` pr_type 子例——归档后全部绿。
- `test_check_pr_paths.py` OK（14 条 archive 语义负向测试含内）；
  `test_check_sdd.py` OK；`check-sdd` 0/0/111。
- 动态重采样实证：样本 chg-2026-030 →（mv 后）自动切换（完备过滤下
  为下一个 headers==candidates 的活跃 change），零人工干预。
- **残余 = 恰 7 条，全部位于本任务 Forbidden 的 NAV-001 分工文件**
  （`test_navigation_contract.py` 4 条：
  `test_a_candidate_without_a_change_falls_back_to_the_round_scope`、
  `test_an_explicit_change_still_reports_only_that_change`、
  `test_the_default_dry_run_covers_more_than_the_old_default_change`、
  `test_the_change_that_used_to_be_the_only_one_scanned_is_still_scanned`；
  `test_minter_and_explain.py` 3 条：
  `test_it_names_every_candidate_and_a_reason_for_each_rejection`、
  `test_it_reports_the_archived_dependency_set_size`、
  `test_it_runs_with_no_credential_at_all`）。定性：#594 于本 r2 audit
  base 之后合入的新测试把 chg-2026-030 钉为活跃态（同型活体样本病灶
  的新发），属 TASK-NAV-001 交付的 post-merge finding，已上报维护者；
  修复路线 = 该两文件改用本任务交付的 `test_support` helpers。
- **`NAV-ARCH-001` 判定：本任务分工面 PASS；change 级 gate 待上述
  跨线修复合入后以演练复跑收口**（复跑记录将追记于本 run）。

### 变异/反证记录

- invariant pin：实现 diff 零触碰 `check_pr_paths.py`（blob 相等即
  「零变更」机器证明）；
- `change_tasks_path` 双向 loud-fail：both/neither fixture 各一条单元
  测试（存在两处/零处均 AssertionError）；
- 采样过滤反证：不自洽 id（chg-2026-026 实测）与字段不全 change
  （mv 后的 chg-2026-025 实测，headers>candidates）均被过滤器排除，
  过滤器缺失时的失败形态已于演练首轮实测（11 failures + 3 errors，
  修复后收敛至纯跨线残余）。
