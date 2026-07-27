# TASK-DEC-004 implementation run

- Task:TASK-DEC-004(check_pr_paths 信任边界与解析硬化)
- Executor:agent(会话实现;never-claim,循环零认领)
- Date:2026-07-27
- Readiness:r1 = #642(merge `b75212cfc6b2447545591f01382949a0a758b4b9`);
  r2 = #643(merge `6707699f23923322acadd9b455ac6da23babda23`,单文件跨分区
  扩权;二者均 lvye APPROVED、mergedBy lvye)
- Implementation base:`6707699f23923322acadd9b455ac6da23babda23`
  (r1 五个 blob 在 r1 base `b75212cf…` 上逐一 HOLD;r2 只改 tasks.md,
  对五个受钉文件零触碰,故基线在 rebase 后继续成立)
- Hardware:none(host-only)。设备零触碰、GitHub 零写入。

## Input gate 复核

r1 五个 blob 在实现 base 上**逐一 HOLD**(`git show <base>:<path> |
git hash-object --stdin`):`check_pr_paths.py` `784b15c4…`、
`test_check_pr_paths.py` `7ff31e85…`、`test_agent_pr_workflow.py`
`10b32515…`、`automation_config.json` `aeafbc4b…`、`agent-pr.yml`
`a514d9e5…`。

## 停条件如实命中并停下(r1 → r2)

按 r1 要求先对 B-H1 施**最小修复**干跑(`check_paths` 的定义源由 head
树改 base 树,其余一字未改),全套件**恰一条**变红:
`host_loop.test_pr_envelope.EnvelopeContractTests.
test_mech_004_reads_task_and_allowed_paths_from_complete_envelope`。该文件
属 r1 Forbidden paths,**当场停下、零 host_loop 改动**,转 readiness r2
请求单文件两常量扩权(#643)。根因见 r2 正文:该测试用合成 OID
(`"a"*40`/`"b"*40`)调 `check_paths`,这只在「校验器从不查 base 树」时
成立——即「测试把缺陷冻结成正确行为」同族。修法是让 fixture 适配更强的
前提,**不是**给校验器留「base 不可解析即回退 head」的 fail-open。

## r2 授权面的交付(逐行示证,r2 Pass/fail #8)

`scripts/host_loop/test_pr_envelope.py` 的改动**恰为两常量 + 其注释 +
一个 `import subprocess`**,断言、用例逻辑、其他常量**逐字未动**:

```diff
+import subprocess
-BASE_OID = "a" * 40
-HEAD_OID = "b" * 40
+# Real, resolvable commits. Synthetic OIDs worked here only while
+# check_pr_paths read its allowlist from the working tree; it now resolves
+# the base tree out of git (TASK-DEC-004), so a fabricated base is a
+# fail-closed error rather than an unused string.
+BASE_OID, HEAD_OID = (
+    subprocess.run(
+        ["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD~1", "HEAD"],
+        ...
+    ).stdout.split()
+)
```

**两个中间态如实记录**:

1. 首版把两常量都取 `HEAD`,打红 20 条——envelope 契约本就钉着「head
   必须不等于 base」(`test_change_and_task_bind_to_unique_active_
   repository_state` 等)。**该契约是被既有断言抓到的,不是我预判的**。
2. 改为 `HEAD~1`/`HEAD` 后本地全绿,**但 CI guard 红**
   (run 30250839337):`git rev-parse HEAD~1` 退出 128。根因 = **guard job
   的 `actions/checkout@v4` 用默认 `fetch-depth: 1`,浅克隆里只有一个
   commit**;本地全历史工作树掩盖了这点(本仓已记教训:「CI 绿 ≠ 本地
   绿」,此处是反向的同一类)。**修法不是给测试加降级分支**,而是收窄
   生产侧对 git 的依赖:`check_paths` 判「任务是否仍活跃于 head」改回读
   **工作副本**(与本任务修改前的行为一致),只有安全相关的 **base
   allowlist 仍从 git 树解析**。于是 head OID 无需可解析,
   `HEAD_OID` 保持合成值、`BASE_OID` 取 `HEAD`(浅克隆下必定存在)。
   该收窄不削弱修复:两个分支各自从两棵树重新推导它们所信的一切,
   且「任务在 head 缺失」只会把判定引向更严的原子归档校验。
   **验证方式 = 真实复现,不是推断**:以 `git clone --depth 1` 造出
   `rev-list --count HEAD == 1`、`HEAD~1` 不可解析的克隆,在其中跑
   host_loop **624 OK + 1 xf**、`test_check_pr_paths` **49 OK**、
   `test_agent_pr_workflow` **8 OK**。
   **附带事实**:真正调用 `check_pr_paths` 的两个 allowed-paths job 用的
   是 `fetch-depth: 0`,base/head 对象俱全,故 r1③ 的「workflow 零改动」
   结论不受影响;红的是只跑套件的 guard job。

**覆盖变强**:该端到端用例现在真的走通了 base 树解析这条路径,而此前
它的 OID 从未被解析过。

## 各修复的实测起点(先复现,再动手)

全部在实现 base 上活体复现,未凭台账落码:

| 项 | 复现结果 |
| --- | --- |
| B-H1 | 同一 commit 把 Allowed paths 改 `**` 并加 `scripts/evil.py` → **PASS** |
| B-H3 | 散文行「the layout mirrors \`scripts/**\` and \`Packages/**\`」→ patterns **真含**二者 |
| B-H4 | `base.sha` 指向含同名文件的旁支 → 两点 diff **变空** → PASS |
| B-M1 | `Packages/ArkDeckKit/Sources/*.swift` **匹配任意深度嵌套** |
| B-M2 | `"Task:\nTASK-EVIL-002\n"` **绑定成功** |
| B-M3 | U+2011 标题 `TASK_TOKEN_RE.findall(title)` == `[]` |
| B-M4 | `Scripts/`、`.GitHub/`、`AGENTS.md`、`.gitignore`、`.python-version`、`ArkDeck.xcodeproj/**` 对 task-less PR **全部非敏感** |

**B-M3 的实测更正**:r1 写的「NFKC 归一」实测**不成立**——NFKC 把
U+2011 映到 U+2010,仍非 ASCII `-`,token 依旧不可见。实现改为
NFKC + 折叠整个 Unicode `Pd`(dash punctuation)类;**跨脚本同形字母
(如西里尔 А)不在本轮claim 范围**,已在代码注释标明边界。

## 交付

- **B-H1**:allowlist 取自 `context.base_oid` 树;head 树仅提供一个
  比特——任务是否仍活跃(区分归档搬移与普通改动)。base 缺任务 =
  `CheckError`,**不回退 head**。`verify_atomic_archive_fallback` 的触发
  条件仍是「head 缺任务」,归档原子性校验未失活(既有 7 条 archive 测试
  保持绿,且变异实测它们对本改动敏感)。
- **B-H4**:`--event` 路径新增 `assert_base_is_ancestor`
  (`git merge-base --is-ancestor`)+ 身份形状校验(state open、merged
  false、base/head 同仓)。**校验顺序刻意保持 OID/形状在前**,故既有
  `test_event_parser_rejects_missing_shape_and_short_oids` 仍以原因不变
  通过。
- **B-H3**:块解析改定界读法——`- Allowed paths:` 行与其 `- ` 子项是
  声明行(允许 `修改`/`新增` 之类前缀);**续行只吸收其首个散文词之前的
  token**,散文一开始列表即结束。括号注释按整块(可跨行)遮蔽且保留行
  结构;40-hex token 判为 pinned blob 注记而非路径。终止符补齐
  `* ` bullet、tab 缩进 bullet、任意层级标题。
  **`本 change` 跨行绑定被保留**:匹配在整块上做,若按行切会把
  「行尾 `本 change` + 次行 token」静默重定基到仓根(实现中间态曾出现
  该回归,由既有测试当场逮到)。
- **B-M1**:自实现 glob 转译器,`*` 限定单段、`**` 跨段,与
  `test_agent_pr_workflow._glob_regex`(本仓早已正确的那份)语义一致,
  并新增**双引擎 parity 测试**(8 pattern × 10 path 交叉积)。
- **B-M2**:`TASK_LINE_RE` 的 `\s*` → `[ \t]*`。
- **B-M3**:confusable token 报**歧义错误**(既不静默接受、也不静默采用
  归一值)。
- **B-M4**:`sensitive_paths` 增四项(`ArkDeck.xcodeproj/**`、
  `AGENTS.md`、`.gitignore`、`.python-version`);敏感匹配改大小写不
  敏感,**Allowed paths 匹配保持大小写敏感**(放宽方向明确不授权,并配
  测试钉死)。`openspec/**` 按 r1⑥**刻意不入表**,配「治理链仍通」测试。
- **B-M8**:`--identity-only` 改打印从 API 响应读回并校验过的 number。
- **B-H2**:按任务卡「只做低成本缓解或显式记录」,在模块 docstring 显式
  记录残留自签环(两 workflow 从被审 head 跑本文件),说明 base 权威已
  移除其 allowlist 半侧、代码半侧属结构问题需独立立项,并写明当下补偿
  控制 = 人类 review。

**DEC-001 等价性锚按 r1 授权更新**:`R1_ANCHOR_PATTERNS`(五项)保留为
命名常量,新增 `DEC_004_ADDED_PATTERNS`(四项),锚 =
`ANCHOR_PATTERNS` 二者串接,**仍为精确内容集**;注释写明「`len()` 或
contains 型断言会让该表被改而无测试察觉」。

## 验收

**变异门 16/16 全部击杀,负对照存活,恢复后全绿**:

| 变异 | 结果 |
| --- | --- |
| B-H1 allowlist 退回被审树 | KILLED(8) |
| B-H1 head-only 任务又可供权 | KILLED(1) |
| B-H4 祖先门摘除 | KILLED(1) |
| B-H4 event 身份校验摘除 | KILLED(1) |
| B-H4 同仓校验摘除 | KILLED(1) |
| B-H3 块内 token 又全吸收 | KILLED(1) |
| B-H3 括号注释不再遮蔽 | KILLED(2) |
| B-H3 终止符退回 bullet/H2 | KILLED(1) |
| B-H3 pinned blob 又当 pattern | KILLED(2) |
| B-M1 单星又跨 `/` | KILLED(2) |
| B-M2 分隔符又跨行 | KILLED(1) |
| B-M3 confusable 又静默 | KILLED(1) |
| B-M3 折叠退回纯 NFKC | KILLED(1) |
| B-M4 敏感匹配又大小写敏感 | KILLED(1) |
| B-M4 四项根级条目删除 | KILLED(2) |
| B-M8 读回又回声入参 | KILLED(1) |
| **负对照**:仅改注释 | **SURVIVED**(正确) |

**两处首轮存活,如实记录并已修正**——二者同源(测试没驱动生产路径):

1. **祖先门摘除首轮存活**:首版测试直接调 `assert_base_is_ancestor`
   helper,故删掉 `main()` 里的调用点无人察觉。改为**新增驱动
   `main()` 全 `--event` 路径的子进程测试**(伪 base → exit 1 且报
   `is not an ancestor of head`;真 base → 走到敏感路径判定)。
2. **B-M8 读回首轮存活**:黑盒不可区分——身份校验已保证入参与响应相等,
   故回声与读回外部行为恒同。改为**在挂起身份校验的前提下驱动
   `main()`**,断言打印值随响应(901)而非入参(483)。这条测试钉的是
   「值从哪来」,不是「值等于几」。

**行为清点(全部入库复算,非抽样)**:

- **B-H3 全仓语料**:51 个 active 任务逐一以新旧解析器对比——
  **路径类 pattern 丢失 0、新增 0**;惰性 token 丢弃 **24**
  (18 个 40-hex pinned blob + `ArkDeckWorkflows`×2、`ArkDeckRuntime`、
  `ArkDeckFakeRockchipFixture`、`executorUnavailable`、`observed`×2、
  `declaredPackageDependencies`、`Package.swift`、`.copy`);pattern 集
  变化的任务恰 **7** 个(AIN-006 14→10、AIN-007 16→10、AIN-008 19→11、
  M0B-001 5→4、M0B-002 4→3、RKFUI-001 11→8、UD-001 11→10),丢弃项逐条
  如上;4 个任务(AIN-004、OBS-001、OBS-002、UD-R2-R4-SEAM-001)在新旧
  两版下**同样自然拒绝**,行为未变。
- **B-H1 判定复算**:readiness 钉的 60-commit 窗口 **36/36 判定相同,
  零回归**(与 r1 记录一致)。**另加深至 200 个 first-parent commit
  (129 个带唯一任务声明):128/129 相同,恰 1 处分歧**——
  `ced32841a39147e3de74787f755d2377ccfba460`(#459
  `governance(TASK-RPT-001): recover bot-authored PR transport`)。查证:
  该 commit **在同一 commit 内给自己的 Allowed paths 增加了
  `proposal.md`/`design.md`/`verification.md`/`acceptance-cases.yaml`
  并同时改动这四个文件**(维护者当时的一次性 bootstrap carrier)。
  **即自扩权形态在本仓真实发生过一次**;base 权威会要求该放宽先以独立
  PR 合入(= 现行 readiness-先合 的常规顺序)。如实记录:该实例并非
  恶意,但守卫**无法与攻击区分**——这正是修复的理由。
- **B-M4 影响清点**:200 个 commit 中 task-less 者 **71** 个,触碰四个
  新增条目的 **0** 个 → 扩项对既有治理链零打断。

**套件与 guard**(实现树上全量):

- `test_check_pr_paths.py` **30 → 49 OK**(直跑与 `-m unittest` 计数
  相等);
- host_loop `-m unittest discover` **624 OK + 1 expected failure**
  (r2 的两常量修正后;修正前恰该一条 error,见上文停条件节);
- `check-sdd` **0/0/111**;`test_agent_pr_workflow.py` **8 OK**;
  `test_sdd_runtime_entry.py` **33 OK**。

**既有断言零放宽**:r1⑤ 的门逐条自查——

- 30 条既有测试的**断言文本未改一处**。两处生产错误文案刻意保留原有
  子串(`does not exist in an active change`、`archive-only tasks are not
  authority`),使既有断言以**原因不变**继续通过。
- fixture 升级(非放宽):`make_repo` 由普通临时目录改为**真 git 仓 +
  真 commit**,`context()` 新增 `oid=` 参数把 fixture 的真实 OID 接进
  base/head。理由:base 权威使「普通目录充当仓库」不再成立,这是前提
  变强而非断言变弱;两处 live-repo 测试同理改用真实 HEAD。
- `test_shipped_config_parses_to_the_r1_anchor_exactly` →
  `..._to_the_anchor_exactly`,锚扩为九项**精确内容集**(r1④⑥授权的
  内容变更)。

## 遗留(不在 In scope,如实记录)

- **B-H2 结构自签环**:仅 docstring 记录 + base 权威关闭 allowlist 半侧;
  代码半侧需「守卫从受信 checkout 运行」的独立立项。
- **`--pull-request` 模式未加祖先门**:r1 只授权 `--event` 侧。附带观察:
  `git diff base..head` 若改三点(`base...head`,即从 merge-base 起算)
  可同时消解「落后分支误报越界」与旁支替换,**但语义变更不在本轮授权**,
  记台账待维护者裁量。
- **B-M7**(裸「本 \`tasks.md\`」→ change-relative)按 r1 不授权;实测该
  token 对仓内任何真实路径零匹配,故本轮丢弃对判定零影响。
- **B-M5/B-M6/B-dead**、rockchip-component workflow 卫生:按任务卡
  Out of scope 记台账。
- **CI 侧缺口如实记录**:`sdd-guard.yml` 的 allowed-paths job 仅在
  `reopened/edited` 触发,实现 PR 的常规 CI **不会跑到 `--event` 路径**;
  该路径的验证以本地真实 event JSON 子进程测试为准(已入套件),
  **不以「CI 绿」冒充**。
