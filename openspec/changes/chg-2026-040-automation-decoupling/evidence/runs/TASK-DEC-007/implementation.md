# TASK-DEC-007 implementation run

- Task:TASK-DEC-007
- Executor:agent（会话实现;never-claim,循环零认领）
- Date:2026-07-27
- Readiness:r1(#614 merge `15c1ea8ac163766d8eccded95a2bc8fb07e04c7d`,lvye APPROVED)
- Implementation base:`86f9e72b8ecb4295061d485a0f4925706c847be1`
- Hardware:none(host-only)。设备零触碰、launchd 零动作、GitHub 零写入。

## Input gate 复核

readiness r1 的九个 blob 在实现 base 上**逐一 HOLD**(零漂移):

```yaml pins
- path: scripts/host_loop/__main__.py
  blob: d9e62fb7a98e052cef5bba7d3063963a7ca139f4
- path: scripts/host_loop/worker.py
  blob: c26b6a199dd13dbeb211ed22ad02fb7943f3c6bb
- path: scripts/host_loop/cursor.py
  blob: 0961ec62409644421dc8ed8eea68230e8fa93b5e
- path: scripts/host_loop/test_discovery_contract.py
  blob: ab51240c01e681ae30fa732c8d3999e31278b058
- path: scripts/host_loop/test_navigation_contract.py
  blob: 91cad318eb7a5796c32fdac8ddc0891a0abb3415
- path: scripts/host_loop/test_support.py
  blob: dfe9557f7eb0fe14c57b2c54da4e718598fc6e94
- path: scripts/host_loop/test_worker_cursor.py
  blob: 0a878006017e21580a6eebcd0c978949901a5e02
- path: scripts/host_loop/test_cursor_contract.py
  blob: ba969661c7b3b1a3779558e7b3e46defb2142dcb
- path: scripts/host_loop/test_check_verdict_contract.py
  blob: ed7429e2b4538af50127ad13c52ab593ee25a0cf
```

## 交付内容(readiness 顺序:守卫先行)

1. **never-claim 守卫扩充**(worker.py):八个 `TASK-DEC-00N` 根入
   `NEVER_CLAIM_ROOTS`,精确内容集测试同步更新,另加逐任务枚举对照。
2. **C-H1 续行/散文区分**(`__main__.py`):`_DEPENDS_RE`/`_ALLOWED_RE` 改
   为「行内值 + 缩进列表续行」,散文行不再捐 token;空值且无列表续行的
   字段使任务省略(fail-closed)。
3. **C-H2 退出码**:`CursorError`/`ReconcileRequired` 由 `EXIT_ERROR`(1)
   改 `EXIT_RECONCILE`(20);`BackendError`/`TransportError`/`LeaseError`
   保持 1。
4. **C-M4**:`build_truth` 的 PR 半侧观察**全部候选**而非仅 ready。
5. **C-M5**:`_with_corrections` 使 corrections 在两条异常路径上也进 detail。
6. **C-M6**:`_int_env` 对「已设置但不可解析」改抛 `BackendError`。
7. **C-M8a**:`_after_lease_write` 在调用方未给 `pr_number` 时回填
   `held.record.pr_number`。
8. **C-L11**:`_change_is_approved` 用 `_VALUE` 停在真实标点。
9. **C-H3**:`test_discovery_contract.py` 的 `unittest.main()` 移至文件尾;
   另加对全包生效的 AST 结构断言。

## 验收

**变异门 9/9 全部击杀,负对照正确存活**(harness 原地变异、基线红即拒跑):

| 变异 | 结果 |
| --- | --- |
| never-claim: 撤回 TASK-DEC 根 | KILLED(9 failures) |
| C-H1: 恢复吞散文 | KILLED(3) |
| C-H1: 空值读作「声明无」 | KILLED(1) |
| C-H2: CursorError 回 exit 1 | KILLED(1) |
| C-M4: 只观察 ready | KILLED(2) |
| C-M5: 异常轮丢 corrections | KILLED(3) |
| C-M6: env 拼错静默禁用 | KILLED(1) |
| C-M8a: 不再回填 lease 的 PR | KILLED(1) |
| C-L11: 恢复 `(\S+)` 截断 | KILLED(1) |
| **负对照**:仅改注释文字 | **SURVIVED**(正确) |

**活体语料零漂移**:同一份 tasks.md 语料下,旧解析器与新解析器发现的候选
集合**完全相同**(before 30 / after 30,lost 0 / gained 0)。

**空值续行语料清点**(readiness 硬门):现仓 **35** 个任务携带空值
`Depends on:`/`Allowed paths:` 字段——

- 解析出**非空** `allowed_paths`:**22**
- 解析出但 `allowed_paths` 为空:**0**(合法续行零退化 = 门通过)
- 未被发现(其他门,如 hardware/status):13;**逐一核对为基线即未发现**
  (before/after 均 0),非本次改动所致。

**套件与 guard**:host_loop `-m unittest discover` **567 OK + 2 expected
failure**(基线 536 OK + 1 xf;+31 新测试,+1 expected failure 见下);
`check-sdd` **0 error / 0 warning / 111 acceptance IDs**。

**`test_discovery_contract` 直跑 = 模块跑**:34 = 34(修复前 19 vs 34)。

**认领缺口闭合(本任务的首要目的)**,`--explain` 实测对照:

- 修复前:`TASK-DEC-003: rejected / - decision grade 'unknown' is not
  dispatchable`,且末行 `one Decision-Grade line from claimable:
  ['TASK-DEC-003']`。
- 修复后:`TASK-DEC-003: rejected / - never-claim: the readiness forbids
  claiming this task / - decision grade 'unknown' ...`;末行的
  `one Decision-Grade line from claimable` **不再含任何 TASK-DEC**
  (仅余他 change 的 `TASK-BRC-002R`/`TASK-SDR-001`)。

## 范围守纪与如实记录

- **一处 tasks.md 修正**:TASK-DEC-007 的 Allowed paths 行原写作
  `- Allowed paths(r1 扩充,…):`(我在 readiness 起草时所写)。host_loop
  的 `_ALLOWED_RE` 只认 `Allowed paths:`,故**该任务对循环完全不可见**
  (实测 chg-2026-040 只发现 7 个任务)。已改回无限定词形式;**授权路径
  集合逐项不变**(两套解析器均读出 11 项),现 8 个任务全部可见。
- **刻意未做(避免静默扩权)**:
  - **C-M7 全角冒号**:`Depends on`/`Allowed paths` 的冒号类保持 ASCII。
    中途曾改为 `[:：]`,实测使候选集从 30 增至 36(六个 `TASK-BRC-*` 用
    全角冒号书写),属**解析面放宽**且不在本任务 In scope,已回退并在
    代码注释中记明归属。
  - **C-L9 `isinstance(number, int)` 不排 bool**(`build_truth` PR 半侧,
    与 C-M4 同函数):未在 In scope 列举,未改。
  - **`test_v3_hardening.py` 同型缺陷**:新加的结构断言发现该文件同样在
    中部 `unittest.main()`(直跑 42 / 模块跑 52,静默漏 10)。该文件属
    **TASK-DEC-006 分区**,本任务不得触碰;按仓内规矩以
    `@unittest.expectedFailure` 记录(非 skip),DEC-006 修好后会报
    "unexpected success" 逼人摘标记并移除排除项。这是本轮 +1 expected
    failure 的来源。

## 起草过程中自查出的两个测试缺陷(均已修)

- 首版「套件自收集」断言用文本 `source.index("if __name__ ==")` 定位
  guard,**命中了它自己源码里的字符串字面量**,把本文件误报为有缺陷。
  改用 `ast` 结构判定(仓内教训:绝不用读源码文本的方式断言行为)。
- 首版 C-H2 测试用不存在的 `--repo-dir` 驱动 `main()`,在到达目标处理器
  前就以 `BackendError` 退出,测试因错误的理由通过。改为在真实 repo 上
  patch try 块内的 `discover_all` 抛出目标异常,驱动真实分类路径。

## 遗留

本任务不改 `DISPATCHABLE_GRADES`、never-claim 政策本体、Phase 4 cursor
写、explain 双实现合并。两 left-running unit 零动作;行为经运行机
checkout 前进到含本实现的 main 生效。
