---
id: CHG-2026-039-host-loop-repo-wide-discovery
revision: 2
status: archived # 2026-07-27 本 archive PR（先例 #235/#241/#572/#605）；verify #601；引用扫描：目录外精确路径引用 0（NEVER_CLAIM_ROOTS/测试中的 TASK-NAV-* 为名称引用不断链）；归档后循环对本 change 的可见性终止属设计（done 集经 #548 archive glob 永续）
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# host-loop 全仓 discovery、idle 真话与 archive 免疫

## Why

**三个已实测的机械缺陷，共同使「无人值守迭代」停在纸面**（全部于
2026-07-26 逐门复测）：

1. **生产循环永久空转在一个已完结的 change 上**。LaunchAgent
   `com.arkdeck.host-loop.runtime` 的 argv 不含 `--change`，而
   `scripts/host_loop/__main__.py` 的 `--change` 默认值是字面量
   `CHG-2026-030-host-loop-runtime`——该 change 八任务全 done、change 已
   verified（#571）。循环每 900s 醒来一次，扫描一个不可能再产生候选的
   change，31+ 轮 idle 实录在案。全仓其余十个活跃 change 对循环不可见；
   `Decision-Grade` 播种（#577）后出现的 gated-ready 任务（如
   TASK-RKFUI-001G）也不会出现在循环的报告里。
2. **idle 判词说谎**。`worker.py` `select()` 的 `ONLY_NEVER_CLAIM_READY`
   分支对**全部候选**检查 never-claim 成员资格而不过滤 `ready` 状态：
   TASK-HLR-003 于 #552 翻 done 后，循环仍每轮打印
   `only never-claim tasks are ready (['TASK-HLR-003'])`——消息文本声称
   "are ready"而条件从未检查 ready。空转原因误诊曾在当日的战略盘点中
   造成一次真实误判（险些定性为「循环读到陈旧树」）。idle 行亦无时间戳，
   无法与轮次对账。
3. **归档会打红套件，三个 verified change 因此滞留**。#573 实测：把
   chg-2026-030 `git mv` 进 `archive/` 后 `test_check_pr_paths` 1 error、
   host_loop ≥5 error（`test_backends_cli.BodyRendering` 三项、
   `DiscoveryIsAReaderOnly.test_it_parses_the_live_change`、
   `test_pr_envelope` 多个 pr_type 子例）。根因是刻意的质量选择——
   TASK-HLR-003 立的规矩「解析器必须对着真实仓内文件断言」，这些测试以
   chg-2026-030 为活体样本；而 `check_pr_paths.py` 的任务查找只 glob
   `chg-*/tasks.md`（`check_pr_paths.py` 第 271 行），不含 `archive/`——
   #548 已为 `done_task_ids` 补过同型 glob，任务查找侧漏同一课。#573 已
   把两条收口条件写入 chg-030 proposal 的 dated 注记并声明独立立项；本
   change 即该立项。chg-2026-027/028 的归档也在同一条链上等待。

## What changes

### In scope

- **TASK-NAV-001（全仓 discovery 与 idle 真话）**：`--change` 缺省行为从
  单一字面量改为**扫描全部活跃 change**（`openspec/changes/chg-*/tasks.md`
  字典序；显式 `--change <id>` 保留单 change 语义）；每轮至多认领一个任务的
  不变量不变，change-approved 门逐 change 判定；`--explain` 缺省同样全仓
  枚举。`select()` 的 never-claim 分支收紧为**仅对 `ready` 候选**判定；
  idle/claim 日志行加 UTC 时间戳与扫描范围计数。修复以回归测试钉死
  （done 状态的 never-claim 任务不得再触发该判词）。
- **TASK-NAV-002（archive 免疫）**：`check_pr_paths.py` 任务查找扩展到
  `archive/*/tasks.md`（正/负 fixture 各至少一例）；五处活体样本测试引入
  「active-or-archive」路径解析（先查 `changes/<id>/`，再查
  `changes/archive/*-<id>/`，恰一处存在），**不削弱对真实文件断言的规矩**。
  验收含归档演练：scratch worktree 内 `git mv` chg-2026-030 至 `archive/`
  后全量 suite 与 `check_pr_paths` 必须保持绿。
- 两任务零共享文件、可并行；acceptance 全部 change-local（见
  verification.md：NAV-DISC-001 / NAV-TRUTH-001 / NAV-ARCH-001）。

### Out of scope

- `DISPATCHABLE_GRADES`（保持 `{"D0"}`）、never-claim 政策本体、grade 行
  （维护者亲笔）；
- transport/lease/identity/reviewer/recovery/cursor 面（零触碰）；
- launchd unit/plist（**零动作**：plist 本就不传 `--change`，行为经代码
  缺省值生效；生效条件 = 本机 checkout 前进到含实现的 main，两 unit 保持
  left-running 不重载）；
- Phase 4 cursor Issue 写入（另行授权）；
- chg-2026-030/027/028 的 archive PR 本身（本 change done 后按既有归档
  先例独立走）。

## r2 更正（2026-07-27，NAV-002 实现预检实测；原文如实保留不改写）

TASK-NAV-002 原 In-scope 首项（`check_pr_paths` 查找面扩展至 archive）**前提
被证伪**：该守卫已内建完整 archive 语义——active 查找失败时回落 **PR base
commit 的任务宇宙**（原子归档 PR 流程，`verify_atomic_archive_fallback`），
两侧均无才以「archive-only tasks are not authority」拒绝；且该不可见性由
**14 条既有具名负向测试**保护（`test_archive_only_task_never_supplies_
authority`、`test_archived_task_is_not_an_active_declaration_target`、
atomic-archive 家族）。裸 glob 扩展在实现预检中实测打红全部 14 条 + 1
error——「archived 任务对 lookup 不可见」是带测试的安全设计而非缺陷，本
proposal 的 red 探针把特性测量成了缺陷。#573 在 `test_check_pr_paths` 的
1 error 真实根因 = `test_current_hlr_001a…` 硬编码活跃期样本
（TASK-HLR-001A + 合成 base OID 使 base 回落 fail closed），归活体样本免疫
路线处理。r2 起：`check_pr_paths.py` **零变更**并列为 NAV-002 Forbidden；
`NAV-ARCH-001` 同步重述；revision 1→2。NAV-001 不受影响。

## Risk

low。两任务均为 host-only 机械变更，行为面收窄或保真：discovery 扫描范围
扩大但认领门（status/hardware/grade/deps/allowed-paths/change-approved/
never-claim）逐一保持；idle 分支只收紧不放宽；check_pr_paths 扩 glob 使
「任务在 archive」从 error 变为正确解析，未知任务仍 fail closed。回退 =
revert 实现 PR。首个风险控制 = readiness 照 TAS-001 形态把「恰 N 断言
反应」与期望套件计数钉为门。

## Tasks

TASK-NAV-001 与 TASK-NAV-002（见 tasks.md），均 blocked 待 approval-only
PR merge 后逐一 readiness。**两任务均改动循环自身代码/测试面，按
TASK-HLR-003 先例为 never-claim：由会话实现、维护者合并；循环的首次自主
认领对象是本 change 落地后出现的下一个 D0 任务。**propose 合入 ≠ 批准。

## Verification closure（2026-07-27）

两任务 done 于 protected main 在案，三条 change-local AC 证据可复查；本 PR
仅状态翻转 + 引用，零实现夹带（先例 #224/#239/#570/#571）。

- **任务链**：propose #586 merge `fa4bdeaae305b7898e3412a210656842ff50e2e2`；
  approval #587 merge `17a9574a368e518ce475ef7d72135c3a6f71f2c7`；readiness
  r1 #589 merge `f8a04449d01e2ed1fa0b4b9bb29db1bb6fb2b14c`（NAV-001）/#590
  merge `a0bc3ff66954a7a2560ce951fc44e1c989bf7c45`（NAV-002）；grade 行
  （维护者亲手 commit `f621d7c2…`，OID 不变传输）#591 merge
  `74e7cf95416ed43c781e7247bfb2fbeb068c8148`；NAV-002 r2 更正 readiness
  #593 merge `5b376275cd958e5f3514cc46b94f487c75c2f7dd`（r1 契约①前提
  证伪，check_pr_paths.py 转零字节 invariant）；实现 = #594 merge
  `87e142801507f6d130404d06fcc64b1db0b26f78`（NAV-001）/#595 merge
  `24401ddc553f72b37e66f73a322ba6e3d559c0da`（NAV-002）；post-merge
  review-fix #597 merge `142330f5ae47fca8cbd1f1c04ec6254c4a071abb`
  （#594 七处活体样本病灶，NAV-001 allowed paths 内闭合）；done #600
  merge `405dbe9e6297d3c0caef29dbe6c6cb44d4acced5`（NAV-001）/#599 merge
  `73b46580fd18b5ff7092af85e51de4fe7738bfc7`（NAV-002）。
- **NAV-DISC-001 = PASS**：缺省 round/`--explain` 全仓枚举（关系式契约
  测试 reported == active_change_ids）；显式 `--change` 单 change 语义
  回归绿；跨 change 聚合每轮至多一 claim 与 change-approved 逐 change
  判定由 `test_navigation_contract.py` 正/负 fixture 钉死；线上 unit
  零 plist 动作经代码缺省值部署（运行机 checkout 前进即生效）。
- **NAV-TRUTH-001 = PASS**：done-never-claim 误报回归（audit base 红探针
  →实现后绿）；`NEVER_CLAIM_ROOTS` 三根精确集合测试；idle/claim 行 UTC
  ISO-8601 时间戳与扫描范围格式契约测试。
- **NAV-ARCH-001 = PASS**：`check_pr_paths.py` 零字节变更（invariant pin
  `02332a9b…` 于实现与 flip base 双复核）；`test_support.py` 双向
  loud-fail 与选样双过滤（id 自洽 + headers==candidates，均由真实仓
  反例实测得出）；归档演练于 #597 合成树全绿（`git mv` chg-2026-030
  入 archive 后 536 OK + 1 expectedFailure 零失败、三守卫 OK、#573
  具名 1+5 error 全消、动态重采样实证）；archive-blocked 的
  chg-2026-030/027/028 归档链解锁。
- **suite 基线现为 536 OK + 1 expectedFailure**（482 → #594 +43 →
  #595 +11）。
