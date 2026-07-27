# TASK-DEC-005 implementation run（r2 移交三项）

- Task:TASK-DEC-005
- Executor:agent（会话实现;never-claim,循环零认领）
- Date:2026-07-27
- Readiness:**r2**(#628 merge `67397e249946b86ae25a39c7396a4a19247088fe`,
  lvye APPROVED)
- 前序:r1 授权面已交付并合入 = **#629**
  (merge `066034af6ab48327e66f1a08bb3d5e544c84ca45`)
- Implementation base:`066034af6ab48327e66f1a08bb3d5e544c84ca45`
- Hardware:none(host-only)。设备零触碰、launchd 零动作、GitHub 零写入。

## 交付(r2 移交三项 + r1 遗留的替身补全)

1. **`identity.confirm_merge` 退役**。函数整体删除,原位留注释记明它与
   `recovery.confirm_merged` 的语义漂移(truthy `merged`、无 subject 交叉、
   sha-null 当终态)。`test_fault_matrix.MergeConfirmation` 的四个用例
   **改指 `recovery.confirm_merged` 正本**(未删),并**加三例**覆盖旧
   duplicate 从未有过的严格性:subject 必须携带 `(#N)`、truthy 非布尔
   `merged`(`1`/`"true"`/`"yes"`)不算 merged、退役符号缺席断言。
2. **envelope evidence path 分支收紧**。含空白的条目不再作为路径通过
   （散文即拒）。**历史兼容以显式只读兼容实现**:`_LEGACY_NONE_PREFIX`
   识别旧的 `none — ` 声明;`render_envelope` 只产 `none:`。
3. **`test_v3_hardening.py` 的中部 `unittest.main()` 移至文件尾**,并在
   **同一提交**内摘除 TASK-DEC-007 留在 `test_navigation_contract.py` 的
   `@unittest.expectedFailure` 与 `_OTHER_PARTITION` 排除项。
4. **测试替身补全(r1 In scope,r1 PR 未做)**:`FakeApi` 的 `get_pull`
   现补齐真实 API 恒发字段(`merged`/`auto_merge`/`merge_commit_sha`/
   `html_url`);`POST /issues` payload 补 `state`/`title`/`body`。

## 验收

**变异门 4/4 全部击杀,负对照正确存活**:

| 变异 | 结果 |
| --- | --- |
| 重新引入漂移的 `confirm_merge` | KILLED(1) |
| path 分支又接受散文 | KILLED(2) |
| 去掉 legacy `none — ` 兼容 | KILLED(1 error) |
| stray main guard 放回文件中部 | KILLED(1) |
| **负对照**:仅改注释文字 | **SURVIVED**(正确) |

**r2 gate 8（零引用）**:`grep -c "confirm_merge\b"` 在 `identity.py` 仅
命中注释一处,生产与测试零调用。

**r2 gate 9（历史 body 兼容,硬门）**:线上真实 worker PR **#564** body 的
`parse_envelope` 结果 `repr` sha256 = `ace6adb602d6ab7b`,与收紧前基线
**逐字节相同**。
**过程如实记录**:首版收紧**打破了该门**——#564 用的正是旧 `none — `
形式,收紧后抛 `EnvelopeError`。这正是 r2 把历史兼容写成硬门的作用。修法
不是放宽散文拒绝,而是加显式只读兼容前缀。

**r2 gate 10**:`test_v3_hardening.py` 直跑 **52** = 模块跑 **52**
(修复前 42 / 52);expectedFailure 与排除项**一并移除**;套件
`expected failures` 由 **2 → 1**(剩余一条是既有的、与本次无关的),
**零 unexpected success**。

**r2 gate 11（授权面限定）**:对 `test_navigation_contract.py` 的改动为
**纯删除、恰两处**(`_OTHER_PARTITION` 常量与其 continue 分支、
`test_the_out_of_partition_module_is_also_whole`),`git diff --stat` =
`21 deletions(-)`,零新增、零其他改动。

**套件与 guard**:host_loop `-m unittest discover` **617 OK + 1 expected
failure**(本 PR 基线 607 OK + 2 xf;+10 测试,-1 expected failure 即
gate 10);`check-sdd` **0/0/111**。

## 未交付(命中分区边界,如实记录并留证)

**`FakeApi` 的 `GET /issues/{n}` 路由仍缺席**,且这不是疏漏:补上该路由
(返回真实端点恒发的 `state:"open"` payload)会**打红**
`test_worker_cursor.test_closed_cursor_issue_is_refused`。原因已查明并
与台账 C-测试替身条目一致——该测试把 `__call__` 设为**实例属性**,而
Python 在**类型**上解析 `__call__`,故其 fake 从不被调用;它此前通过,
只是因为 fake 缺该路由、回落 `{}` 恰好触发同一个 `state != "open"` 检查。
**该测试是死的**,但 `test_worker_cursor.py` 属 **TASK-DEC-007 分区**,
不在本任务(含 r2)授权面内。已在 `test_fault_matrix.py` 原位留下注释
记明缺席理由与复现路径,待独立载体收口。

**D-H2 的 `observed_main` 半侧**仍未做(见 r1 evidence):该函数在
`scripts/host_loop/__main__.py`,属本任务 Forbidden paths。缺陷仍在:
`out.split()[0]` 取多行输出首 token,任何尾为 `refs/heads/main` 的 ref
可顶替受保护 main 的 OID。

## 遗留

reviewer/recovery 仍未接线生产(live dispatch 属 TASK-HLR-005)。本任务
两个实现 PR(#629 + 本 PR)合计覆盖 r1 与 r2 全部授权面,除上述两项已
记录的分区外无遗漏。
