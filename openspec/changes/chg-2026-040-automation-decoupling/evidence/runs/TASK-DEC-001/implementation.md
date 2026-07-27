# TASK-DEC-001 implementation run

- Task:TASK-DEC-001(敏感路径配置抽取与框架/产品边界文档)
- Executor:agent(会话实现;never-claim,循环零认领)
- Date:2026-07-27
- Readiness:r1(#615 merge `86f9e72b8ecb4295061d485a0f4925706c847be1`)
- Implementation base:`839e13a6097f51090c55626ec1f578a648b66a02`
- Hardware:none(host-only)。设备零触碰、GitHub 零写入。

## Input gate 复核

r1 两个 blob 在实现 base 上**逐一 HOLD**(以
`git show <base>:<path> | git hash-object --stdin` 同法复核):
`check_pr_paths.py` `02332a9b572013e99b74acd46db8810ba4f7275a`、
`test_check_pr_paths.py` `a2f11b0450dafd4e2dbf3d0b35008d0ecbf01880`。

## 搬移值等价性(r1 锚)

从钉定 blob `02332a9b…` 以 AST 提取 `SENSITIVE_PATTERNS` 五项,与
`scripts/automation_config.json` 解析出的 `sensitive_paths` **逐字节、
按序相同**(`Packages/**`、`ArkDeckApp/**`、`ArkDeckAppUITests/**`、
`scripts/**`、`.github/**`)。锚同时钉进套件:
`test_shipped_config_parses_to_the_r1_anchor_exactly` 以 r1 记录的五项
字面量比对解析结果。

## 交付

- **`scripts/automation_config.json`**(新):schema
  `arkdeck-automation-config/v1` + `sensitive_paths` 五项(初值 = 上节
  锚)。落点在 `scripts/**` 之下,受它自己声明的规则保护(r1 两条硬
  约束之一);纯 stdlib JSON,workflow 的 allowed-paths job 零安装即可
  解析(硬约束之二)。
- **`scripts/check_pr_paths.py`**:`SENSITIVE_PATTERNS` 硬编码删除
  (grep 零残留;`trace_capture/validate_registry.py` 的同名常量是产品
  工具自己的脱敏表,与守卫零耦合,未触碰)。新增
  `load_sensitive_patterns()` fail-closed 加载:缺失/不可读、JSON 不可
  解析、顶层非对象、schema 字段不符、未知 key、`sensitive_paths` 非列表
  或空表、元素非字符串、重复项——一律 `CheckError`,**无任何静默回退
  分支**。`check_paths()` **无条件加载**(含带任务声明、根本不消费该表
  的 PR):配置被删/写坏时不存在"守卫照常绿"的路径。
- **`scripts/test_check_pr_paths.py`**:纯追加(`git diff` 零删除行,
  既有 24 测试与断言逐字未动),新增 6 测试:等价性锚、五类畸形×红
  fixture + 合法正对照、配置非装饰性(自定义配置驱动 `check_paths` 行为
  双向断言)、坏配置阻断带任务声明的 PR、配置文件受自身规则保护
  (risk-acceptance ① 的钉定)、README 边界地图以 `git ls-tree` 清点
  对照全部一级条目。
- **`scripts/README.md`**(新):framework(12 条目)vs 产品工具
  (10 目录)逐条分类 + 各自实例参数所在;`__pycache__` 显式注记为
  未跟踪缓存。覆盖以套件测试固化,后续新增条目漏更新即红。

## 验收

**变异门(生产侧)6/6 击杀,负对照存活,恢复后全绿**:

| 变异 | 结果 |
| --- | --- |
| m1 文件缺失静默回退硬编码 | KILLED(2) |
| m2 顶层/schema 检查移除 | KILLED(1) |
| m3 未知 key 检查移除 | KILLED(1) |
| m4 空表/非列表检查移除 | KILLED(1) |
| m5 非字符串/重复检查移除 | KILLED(1) |
| m6 `check_paths` 回退硬编码表 | KILLED(2:非装饰性测试 + 坏配置阻断测试) |
| **负对照**:仅加注释 | **SURVIVED**(正确) |

m6 印证 r1 第 4 条的设计:等价性测试在该变异下**如预期保持绿**
(配置文件本身仍合法),击杀由等价性之外的两条测试完成——配置非装饰。

**变异门(数据侧)3/3 击杀**:配置内容改动(`scripts/**`→`scripts/*`)、
换序(前两项对调)、删项(去 `.github/**`)各使等价性锚变红(删项另被
既有敏感判定测试同时击杀),恢复后全绿。

**行为零漂移**:既有 24 测试(含敏感判定 fixture 语料
`test_undeclared_sensitive_fails_and_docs_governance_passes`)在新加载
路径下不改一字全绿。

**套件与 guard**(实现树上全量):

- `test_check_pr_paths.py` **24 → 30 OK**(直跑与 `-m unittest` 模块跑
  计数相等);
- host_loop `-m unittest discover -s host_loop -t .` **624 OK + 1
  expected failure**;
- `test_check_sdd.py` **40 OK**(SDD venv 解释器);
  `test_agent_pr_workflow.py` **8 OK**;`test_sdd_runtime_entry.py`
  **33 OK**;
- `check-sdd` **0 error / 0 warning / 111 acceptance IDs**。

**README 清点**:`git ls-tree origin/main scripts/` 20 个既有一级条目 +
本 PR 新增 2(`automation_config.json`、`README.md`)= 22,README 逐一
在册;清点自动化为套件测试(空清单不可空绿:`ls-tree` 零条目即断言失败)。

**Risk acceptance ① 复核(r1 停条件)**:
`path_matches("scripts/automation_config.json", <解析出的表>)` 实测
True,且 task-less PR 触碰该文件被拒(已钉为测试)——①成立,不触发
转 r2。

**Stop conditions 逐条**:配置路径在 `scripts/**` 内 ✓;零第三方依赖
(纯 stdlib `json`)✓;既有断言零放宽(diff 零删除行)✓;`.github/**`
与 `scripts/host_loop/**` 零触碰(diff 面仅 4 文件 + 本 evidence)✓。

## 遗留(不在 In scope,如实记录)

- 路径匹配语义(`fnmatch` 单星跨 `/`、SENSITIVE 大小写、根级配置文件
  盲区)未动,属 TASK-DEC-004;`SENSITIVE_PATTERNS` 集合内容零增删。
- 两 checker 文法统一维持台账 noted。
- `check_sdd.py` 的 openspec 布局常量与 host_loop 实例常量各属
  DEC-003(已 done)遗留台账与 DEC-002,README 中已如实标注归属。
