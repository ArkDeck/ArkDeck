# TASK-DEC-009 implementation run

- Task:TASK-DEC-009（跨分区遗留收口）
- Executor:agent（会话实现;never-claim,循环零认领）
- Date:2026-07-27
- Readiness:r1(#635 merge `c74f135a0e8f442a711b8ebf53917071c2461928`,
  lvye APPROVED)
- 立项载体:change r2 修订 = #634
  (merge `6ee7242decfb990f2788c6176c2c1e9ec99d3efa`)
- Implementation base:`c74f135a0e8f442a711b8ebf53917071c2461928`
- Hardware:none(host-only)。设备零触碰、launchd 零动作、GitHub 零写入。

## Input gate 复核

r1 四个 blob 在实现 base 上**逐一 HOLD**:`__main__.py`
`bbe92598…`、`test_worker_cursor.py` `0a878006…`、`test_fault_matrix.py`
`fb4b9682…`、`test_navigation_contract.py` `48b1f947…`。

## 交付

**①`observed_main` refname 等值 + 拒多行**（台账 D-H2 的另一半,本 change
最后一条存活的安全缺陷）。修复前实测:两行输出（`refs/backup/refs/heads/
main` 排在前）返回**影子 OID** `6666…` 而非受保护 main 的 `aaaa…`。
修复后双向实测:影子在前 → `BackendError: ambiguous ls-remote …: 2 refs
matched`;单行但 refname 不等 → `BackendError: ls-remote answered for
'refs/backup/refs/heads/main' …`;**单行精确 → 仍返回 `aaaa…`**（正对照）。

**②`FakeApi` 补 `GET /issues/{n}` 路由 + 复活死测试**。路由返回真实端点
恒发的 `number`/`state`/`title`/`body`/`pull_request` 形状,并提供
`fake.issues[n]` 暂存面。`test_closed_cursor_issue_is_refused` 改为经
该面暂存 closed payload,**不再把 `serve` 赋成实例属性**。

**③TASK-DEC-005 记录矛盾更正**:从其 Forbidden paths 移除
`identity.py` 与 `pr_envelope.py` **恰两项**;Allowed 侧与该任务其余文字
一字未动（实测 Allowed 仍 13 项）。

## 验收

**变异门 4/4 全部击杀,负对照正确存活**:

| 变异 | 结果 |
| --- | --- |
| ①回退为 `out.split()[0]` | KILLED(2) |
| ①只去掉 refname 等值 | KILLED(1) |
| ①只去掉单行规则 | KILLED(1) |
| ②移除 `FakeApi` 的 issues 路由 | KILLED(1 error) |
| **负对照**:仅改注释文字 | **SURVIVED**(正确) |

**②首轮变异存活,如实记录并已修正**。首版复活只加了「Issue lookup 调用
计数 == 1」的断言,而 `FakeApi` 在**路由之前**就把调用记进 `self.calls`
——计数在「staged payload 被返回」与「`{}` 回落」两种情况下**完全相同**。
移除路由的变异因此存活,即该测试**仍在靠回落值巧合通过**,与它原本的
死因同型。修法 = 增加正对照
`test_the_staged_issue_is_what_load_actually_reads`:暂存一个 **open** 的
Issue 并断言 `load()` 成功返回该 body 解析结果——没有路由时回落 `{}` 使
`state != "open"`,该用例直接报错。二轮变异 4/4 全杀。
**这正是 readiness 把「不得仅依赖回落值」写进门的理由。**

**r1 gate 3（记录交集）**:更正后 TASK-DEC-005 段
`Allowed ∩ Forbidden = []`（解析清点为证）,Allowed 计数 13 不变。

**套件与 guard**:host_loop `-m unittest discover` **624 OK + 1 expected
failure**(基线 617 OK + 1 xf;+7 测试);`check-sdd` **0/0/111**。

**零回归**:NAV-001/DEC-005/DEC-006/DEC-007 的既有契约测试全绿,未为本
任务放宽任何断言;`observed_main` 的成功路径返回值不变,故 `--once` 与
`--explain` 的既有退出码语义不变。

## 结论

本任务 done 后,CHG-2026-040 台账中**不再有已知未闭合的安全缺陷**。
`observed_main` 与 `RefPort.read`（DEC-005 已修）现在对同一条
「ls-remote 按尾部匹配」陷阱采取同一形态的拒绝。
