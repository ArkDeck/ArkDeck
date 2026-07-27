# TASK-DEC-006 implementation run

- Task:TASK-DEC-006
- Executor:agent（会话实现;never-claim,循环零认领）
- Date:2026-07-27
- Readiness:r1(#608 merge `beda4dc…`,lvye APPROVED)
- Implementation base:`46ebcc22edef165f73a6f7d4080e433dc84906c1`
- Hardware:none(host-only)。设备零触碰、launchd 零动作、GitHub 零写入。

## Input gate 复核

readiness r1 的八个 blob 在实现 base 上**逐一 HOLD**(零漂移):
reviewer.py `574746eb…`、recovery.py `d2763e59…`、pr_envelope.py
`2c286c8d…`、identity.py `d22e6294…`、test_reviewer_contract.py
`aa9dbe94…`、test_recovery_contract.py `1dbf61de…`、test_pr_envelope.py
`47fd19f9…`、test_v3_hardening.py `fa6a869b…`。

## 已交付

1. **E-H1 verdict 契约**:verdict 必须是转录的**最后一非空行且列 0**;
   任意位置/缩进/尾随内容一律 `AdapterFailure` → 上游
   `RECONCILE_REQUIRED`,不降级为任何 verdict。
   **readiness r1 的更正得到实证**:既有
   `test_parses_the_last_verdict_line` **未反转、保持绿**。
2. **E-M1 去重键**:`_recorded` 由 `{number: result}` 改
   `{(number, head): result}`;重放态由记录的 verdict 经 `_state_for`
   重导出(不再由分支决定),paused lane 重查不再被翻成 REVIEW_RECORDED。
3. **E-M2 `(#N)` 尾锚定**:`_subject_carries` 由子串 `in` 改
   `rstrip().endswith`。
4. **E-M4 `\s` → `[ \t]`**:`TASK_HEADER_RE` 与 `FRONTMATTER_ID_RE` 两处;
   另加 AST 结构扫描,使本模块未来新增的 `\s*`/`\s+` 字面量被同一条测试
   拦下。
5. **reviewer 子进程卫生**:`stdin=subprocess.DEVNULL`(交互式 CLI 不再
   可能阻塞至 1800s);转录上限 4 MiB;`OSError` 与 `TimeoutExpired` 分
   126/124 两码且各带原因(此前同为合成 124 且细节丢弃);
   `AdapterFailure` 携带 backend stderr;不可解析转录携带末三行;
   `recorded_at` 由注入时钟提供(此前恒 0)。

## 验收

**变异门 8/8 全部击杀,负对照正确存活**(原地变异、基线红即拒跑):

| 变异 | 结果 |
| --- | --- |
| E-H1: verdict 任意位置又生效 | KILLED(3) |
| E-M1: 去重仅按 PR number | KILLED(1) |
| E-M1: 重放态忽略记录的 verdict | KILLED(2) |
| E-M2: `(#N)` 回退为子串匹配 | KILLED(2) |
| E-M4: task header 分隔符跨行 | KILLED(2) |
| E-M4: front-matter id 跨行 | KILLED(2) |
| hygiene: AdapterFailure 丢 stderr | KILLED(2) |
| hygiene: recorded_at 回到常量 | KILLED(1) |
| **负对照**:仅改注释文字 | **SURVIVED**(正确) |

**历史 PR body 兼容(readiness 硬门)**:取线上真实 worker PR **#564**
(App 身份首个 task PR)的 body,在**修改前后两棵树**上分别
`parse_envelope`,结果对象 `repr` 的 sha256 **逐字节相同**
(`ace6adb602d6ab7b…`)。#566/#568 经核为非 envelope PR(无 marker),
不构成语料。

**套件与 guard**:host_loop `-m unittest discover` **595 OK + 2 expected
failure**(基线 567 OK + 2 xf;+28 新测试,expected failure 计数不变);
`check-sdd` **0 error / 0 warning / 111 acceptance IDs**。

## 未交付项(readiness 停条件命中,如实记录)

readiness r1 为下列两项预先写了停条件,实测**两项均命中,故未做**:

1. **`identity.confirm_merge` 退役**:该函数生产零调用,但其**唯一**引用
   在 `scripts/host_loop/test_fault_matrix.py:822-837`(4 处),而该文件
   属 **TASK-DEC-005 分区**,不在本任务 Allowed paths 内。readiness 原文:
   「若该迁移必须改 `test_fault_matrix.py`（属 DEC-005 分区）,即停并在
   r2 显式扩权」。**已停**;死分类器保持原样,待 r2 扩权或由 DEC-005
   承接。
2. **E-M3 envelope path 分支收紧**:readiness 规定只能在 DEC-005 落地
   backends 渲染侧 `none:` 之后进行。DEC-005 尚未实现,且实测
   `backends.py:371` 现值
   `"none — host-loop dispatch carries no evidence file"` 含空白、不走
   `none:` 文法——任何 path 形状校验都会拒掉这个**生产渲染值**,而
   `backends.py` 属 DEC-005 分区。**已停**,零改动。

另有一项**不在 In scope 故未做**:`test_v3_hardening.py` 的中部
`unittest.main()`(直跑 42 / 模块跑 52)。该文件虽在本任务 Allowed paths
内,但 stray-main 修复不在 In scope;且实测其修复会使 TASK-DEC-007 在
`test_navigation_contract.py`(**DEC-007 分区**,不在本任务授权内)留的
`@unittest.expectedFailure` 变成 unexpected success,而
`TestResult.wasSuccessful()` 对 unexpected success 返回 **False**(已最小
复现验证)——即**只修一半会把套件打红**。两文件跨分区耦合,需独立载体
或 r2 同时授权二者。

## 起草过程中自查出的一个测试缺陷

`test_a_mention_does_not_make_a_real_squash_ambiguous` 首版 fixture 让
「跟进 commit」也以 `(#42)` 结尾——但按 GitHub squash 约定,以 `(#42)`
结尾的 commit **就是** #42 的 squash,该 fixture 实际断言的是「一个 PR 的
两个 squash 可区分」,不可能成立。改为真实形态(引用在 subject 中部、
自身尾号为 `(#900)`),即台账 E-M2 记载的原始观测形态。

## 遗留

reviewer/recovery 仍未接线生产(live dispatch 属 TASK-HLR-005),本轮为
接线前的契约修复,线上零影响。batch digest 字段清洗(E-L6)、CRLF 楔死
按 readiness 保持不授权。
