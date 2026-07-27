# TASK-DEC-002 implementation run

- Task:TASK-DEC-002(host_loop 实例与协议常量收口,全链收尾)
- Executor:agent(会话实现;never-claim,循环零认领)
- Date:2026-07-27
- Readiness:r1 = #646(merge `fa53215…`,lvye APPROVED/mergedBy lvye)
- Implementation base:`fa53215`(= r1 合入后的 main)
- Hardware:none(host-only)。设备零触碰、GitHub **零写入**。

## Input gate 复核

r1 的十个 blob 在实现 base 上**逐一 HOLD**:`backends.py` `682f7fb4…`、
`lease.py` `7f4c0ee0…`、`transport.py` `39a28dfc…`、`cursor.py`
`0961ec62…`、`pr_envelope.py` `1afe0515…`、`identity.py` `14fa2262…`、
`reviewer.py` `7e92c585…`、`worker.py` `2f4d9f84…`、`__main__.py`
`5200a967…`、`recovery.py` `c4271d2b…`。

## 交付

**新模块 `scripts/host_loop/instance.py`** — 37 个常量,分五族(refs/
命名空间、协议标识、可归因身份、部署实例、时间),外加两个渲染模板。
**纯数据**:无逻辑、无 I/O、无 host_loop import;该性质由
`InstanceIsDataOnly` 以 AST 断言(模块顶层只允许赋值,且全树不得出现
`Call`/`Import`/`FunctionDef`/`ClassDef`/`With`/`Try`)。

**收敛的三族(r1 清单逐一落实)**:

- **lease 命名空间**:`lease.py` 两前缀改为从 `instance` 导入;
  `__main__.py:343` 的 `refs/heads/agent/host-loop/leases/*` 改
  `f"{LEASE_REF_PREFIX}*"`;`__main__.py:368` 与 `reviewer.py:461` 的
  `agent/host-loop/tasks/{task}` 改 `f"{TASK_NAMESPACE}/{task}"`;
  `transport.py` 的 `RESERVED_REF_RE` **由命名空间拼出**而非再写一遍
  (`re.escape(f"{REF_HEADS_PREFIX}{AGENT_NAMESPACE}/")` +
  `RESERVED_NAMESPACE_SEGMENTS` 的 alternation)。
- **task 文法**:`__main__.py` 两处(`_TASK_HEADER_RE` 与 depends 解析)
  与 `pr_envelope.py` 一处全部改用 `instance.TASK_TOKEN_TEXT`。
  **`scripts/check_pr_paths.py` 的第四处在 host_loop 之外、属 Forbidden
  paths,未触碰**;`test_token_parity.py` 保持绿(5 tests OK)。
- **base 分支**:五处(`identity.py` 两处、`reviewer.py`、`transport.py`、
  `worker.py`)全部改用 `BASE_BRANCH`;三处错误消息里原本硬写的
  `main` 一并改为插值,否则消息会在改值后说谎。

**其余实例/协议常量**:lease schema、cursor 与 envelope 双 marker、
cursor schema、git author/committer 身份四项、user-agent、API root、
owner/repo/owner-run 缺省、四个环境变量名、ttl/两个 timeout/lease 写入
余量、两个渲染模板(task branch commit subject 与 dispatch PR title)。

**取值零变更**:全部为搬移,`ConsolidatedValuesAreFrozen` 以独立书写的
副本逐一比对(见下)。

## 验收

**零行为变更**:host_loop `-m unittest discover` **624 → 631 OK + 1
expected failure**(增量恰为本次新增的 7 条冻结/清点测试);
`check-sdd` **0/0/111**;`test_check_pr_paths.py` **49 OK**;
`test_token_parity.py` **5 OK**。既有断言**一处未改**。

**变异门 16/16 击杀 + 负对照存活**:

| 变异 | 结果 |
| --- | --- |
| `LEASE_SCHEMA`(r1 实测原为**未钉**) | KILLED |
| `CURSOR_OPEN_MARKER`(原未钉) | KILLED |
| `API_ROOT`(原未钉) | KILLED |
| `USER_AGENT`(原未钉) | KILLED |
| `ENV_TOKEN`(原未钉) | KILLED |
| `DEFAULT_OWNER_RUN`(原未钉) | KILLED |
| `LEASE_WRITE_MARGIN_SECONDS`(原未钉) | KILLED(2) |
| `HTTP_TIMEOUT_SECONDS`(原未钉) | KILLED |
| `BASE_BRANCH` / `LEASE_NAMESPACE` / `GIT_AUTHOR_EMAIL` | KILLED |
| `TASK_TOKEN_TEXT` / `DISPATCH_PULL_TITLE` | KILLED |
| 清点:reviewer 重写 base 分支字面量 | KILLED(2) |
| 清点:reviewer 重写 task 命名空间 | KILLED(2) |
| 清点:backends 重写 API root | KILLED(2) |
| **负对照**:仅改注释 | **SURVIVED**(正确) |

**r1 最重要的一条门达成**:readiness 实测「改坏后零测试反应」的**八项
全部转为必红**。

**首轮清点存活一条,如实记录并已收紧**。首版单一定义清点用**精确相等**
比对字符串常量,于是把 `f"{TASK_NAMESPACE}/{task}"` 改回
`f"agent/host-loop/tasks/{task}"` 的变异**存活**——f-string 存的常量块是
`"agent/host-loop/tasks/"`(带尾斜杠),与清点表里的
`"agent/host-loop/tasks"` 不等,等值比对径直走过。修法 = 结构化字面量
改**子串**匹配,仅 `main` 保留全等(作为子串它会命中 `__main__`、
`remaining` 与任何含该词的散文)。收紧后该变异被击杀。

**收紧后的清点当场又抓到两处我漏掉的**:

1. `__main__.py:602` 的错误消息 `"--repo-dir or ARKDECK_REPO is required"`
   **硬写了环境变量名** —— 真重复,已改 `f"…{ENV_REPO_DIR}…"`。
2. `backends.py:385` 的 envelope 证据行
   `"none: host-loop dispatch carries no evidence file"` 含
   `host-loop dispatch` —— 与标题模板**巧合同短语**,非第二处定义。
   已在清点表中作为**具名例外**记录(附理由),而非放宽匹配。

**清点方法**:AST 遍历,**不是 grep**。理由是本仓实测教训(HLR-003 曾有
一条 grep 源码文本的测试,因分支上方注释含同一措辞而在缺陷引入后仍绿)。
注释天然不进 AST;docstring 按节点显式排除。该性质本身也配了测试
(`test_the_census_reads_the_ast_and_not_the_comments`:注释/docstring 版
产出空集,同一文本移入赋值即被捕获)。

## 线上兼容(r1 第 6 条,**只读、零写入**)

**如实记录一项与 readiness 预期不符的事实**:实测 **`agent/host-loop/**`
命名空间在远端为空**(`git ls-remote origin 'refs/heads/agent/host-loop/*'`
零行),且**不存在 cursor Issue**。故 r1 写的「现存 lease ref」与「线上
cursor Issue」两项冒烟**没有实物可测**——不是失败,是标的不存在。
**不以「无实物」当作通过**,改以可得的最强证据替代:

1. **跨树 wire 值对照**:在 base(`origin/main`)与实现树上分别读取
   cursor 双 marker、cursor schema、lease schema、lease/task ref 前缀,
   **七项逐字节相同**。
2. **跨树 round-trip**:**旧树**渲染的 cursor 机器块(437 字节)交由
   **新树** `parse_machine_block` 解析,`cursor_main_oid`/
   `candidate_task`/`lease_ref`/`pr_number` 四字段全部正确还原 ——
   即线上若存在旧格式机器块,新代码仍能读。
3. **历史 PR body 兼容(有实物)**:线上真实 worker PR **#564**
   (`TASK-TAS-001: host-loop dispatch`)的 body 在两棵树上
   `parse_envelope`,结果 `repr` 的 sha256 **相同** =
   `832b7987cf970fff19ddb42317770e6d3649cb364dfc42f813098f7469897493`。

**写计数 = 0**:全部操作为 `git ls-remote`(只读)与 `gh api` GET;
无 ref 写入、无 API POST/PATCH。

## 遗留(不在 In scope,如实记录)

- `check_pr_paths.py` 的 task 文法第四处按 r1 不授权,未动;两者不漂移
  仍由 `test_token_parity.py` 守卫。
- `test_pr_envelope.py` 的 `BASE_OID`/`HEAD_OID` 按 r1 Stop conditions
  **零触碰**(TASK-DEC-004 r2 刚落码于此)。
- 任何取值变更、launchd/plist、新增行为或路由:未做。
