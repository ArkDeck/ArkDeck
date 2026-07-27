---
id: CHG-2026-040-automation-decoupling
revision: 2
status: archived
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# 自动化框架仓内解耦与全面体检修复

## Why

维护者 2026-07-27 决定：暂不把自动化框架抽出仓库（无第二消费者，抽仓
是净成本），但要求 **(1) 仓内参数化，把框架代码与 ArkDeck 实例数据的边界
做实**，并 **(2) 对全部自动化脚本做一次全面体检**（冗余、bug、规范）。

体检已完成（五个独立审查线覆盖 check_sdd / check_pr_paths+workflows /
host_loop worker / host_loop transport / host_loop reviewer 五簇，全部
生产文件逐行读毕；每条 HIGH 级发现均以构造性 fixture、真实 git、或双
HTTP 服务器实测复现，非目测）。完整台账见本 change `review-findings.md`。
结论概要：

1. **参数化的底数比预想好**：transport 的 owner/repo 本就是构造参数，
   reviewer 后端命令是构造参数，App id / installation id 未硬编码。真正
   的实例数据集中在:check_pr_paths 的 `SENSITIVE_PATTERNS`（三项产品
   路径）、host_loop 的协议常量（lease schema、cursor/envelope marker、
   git 身份、user-agent——**值已持久化在线上 refs/Issue/PR body 里，只可
   收口不可改值**）、`--owner/--repo/env 名`等 CLI/env 缺省、以及同一
   语义散落 2-4 处的重复定义（lease 命名空间 4 处、task 文法 3 处、
   base `main` 4 处、tasks.md 解析器 2 套且语义已分歧）。
2. **守卫层存在一族"声明了但未真正落地"的控制**（详见台账;均已实测）：
   check_pr_paths 的授权面全部取自被审 head 树（自扩权可过）、Allowed
   paths 块会把散文里的反引号词吸收进 allowlist（`chg-2026-025` 里一句
   「`Packages/**` forbidden」按现解析是 allowed）、`--event` 模式零身份
   校验;transport 的 `UrllibSender` 静默跟随 HTTP 重定向（allowlist 可被
   绕过、installation token 会重放到目标主机;GitHub 改名仓库即触发 301）、
   `RefPort.read` 不校验 ls-remote 返回的 refname（影子 ref 可顶替 fence
   比较对象）、`renew()` 未校验 owner_run（可绕过 takeover 全部前置偷取
   未过期租约）;reviewer 裁决解析取「最后一条 VERDICT: 行」（审阅输出尾部
   引用的 `VERDICT: APPROVE` 可翻转 REQUEST_CHANGES，且现契约测试把该
   行为钉成正确）;discovery 对空值 `- Depends on:` / `- Allowed paths:`
   fail-open（NAV-001 全仓扫描 #594 合入后已属线上行为）。
3. **两个测试基建缺口**：`test_check_sdd.py`（19 测试）与 host_loop 全套
   件（480+）未接入任何 workflow;`test_discovery_contract.py` 的
   `unittest.main()` 位于文件中部第 340 行，按 shebang 直跑只执行 34 个
   测试中的 19 个——恰好漏掉最新的 fail-open 回归类。
4. check_sdd 的四个初代检查族有一致的 fail-open 边（scope.yaml 解析为
   None 即整检查静默失效、认领面跨任务边界吸收缩进文本、状态行只做总数
   对账、capability id 重复 last-wins）;三个新代检查族（revision/scope/
   pins）工程质量良好。

## What changes

### In scope（八任务，全部 never-claim，会话实现、维护者合并）

**A. 参数化 / 解耦（用户诉求 #1）**

- **TASK-DEC-001 敏感路径配置抽取与边界文档**：`SENSITIVE_PATTERNS` 从
  check_pr_paths.py 硬编码迁至新文件 `scripts/automation_config.json`
  （JSON 而非 YAML——两个 workflow 的 allowed-paths job 均不安装依赖，
  必须 stdlib 可解析;落在 `scripts/**` 下自身即受敏感路径保护，避免
  task-less PR 先改配置再触产品路径的自引用漏洞）。加载 fail-closed：
  文件缺失/未知 key/空表/非字符串/重复项一律 CheckError，绝不静默回退。
  另交付 `scripts/README.md` 一页边界地图：framework（check_sdd/
  check_pr_paths/host_loop/sdd-guard/agent-pr）vs 产品工具（rockchip_*、
  *_capture、e0_readback、partition_decode、ui_dump_redaction 等）清单
  与各自实例参数所在。
- **TASK-DEC-002 host_loop 实例与协议常量收口**（排全链最后）：新模块
  `scripts/host_loop/instance.py` 收口全部实例/协议常量，**值逐字节
  不变**（wire/persisted 兼容），配精确内容冻结测试;lease 命名空间 4 处、
  task 文法 3 处、base `main` 4 处收敛为单一定义 + parity 测试。

**B. 体检修复（用户诉求 #2;只列已实测项，LOW/观察项在台账中记录不立任务）**

- **TASK-DEC-003 check_sdd fail-closed 修复与测试接线**：修复台账
  A-H1/A-H2/A-M1..M4 族;`sdd-guard.yml` 接入 `test_check_sdd.py` 与
  host_loop 套件（`-m unittest discover`，同时使 test_discovery_contract
  的中部 main() 缺陷在 CI 面失效）。
- **TASK-DEC-004 check_pr_paths 信任边界硬化**：任务定义以 base 侧为
  权威（`load_task_definitions_at_commit` 升为主路径）、Allowed paths
  块解析改为定界模式停止散文吸收、`--event` 模式补身份/祖先校验、
  `\s` 跨行与 homoglyph 标题、`--identity-only` 套套回读改真校验、
  SENSITIVE 大小写与根文件盲区。
- **TASK-DEC-005 transport/lease/backends 硬化**：no-redirect opener +
  URL 前缀断言（D-H1）;`RefPort.read` refname 等值校验并拒多行（D-H2）;
  `_advance` owner_run 校验（D-H3）;git 子进程环境改白名单构造、
  `GIT_CONFIG_*` 硬设;403 限流歧义化;绑定器 bool 排除;退役死代码
  （Python minter、恒假 fence 断言、无调用 assert_no_secret 的裁决）;
  `NEVER_CLAIM_ROOTS` 加入 `TASK-DEC` 根。
- **TASK-DEC-006 reviewer/envelope/recovery 硬化**：verdict 改「最后一
  非空行、列 0」契约并反转现钉测试（E-H1）;review 去重键改
  (number, head)（E-M1）;`(#N)` 改尾锚定（E-M2）;`\s`→`[ \t]`（E-M4）;
  退役 identity.confirm_merge 死分类器;reviewer 子进程卫生
  （stdin=DEVNULL、输出上限、err 细节保留、recorded_at）。
- **TASK-DEC-007 worker/discovery 解析与观测硬化**：空值 Depends/
  Allowed fail-closed 与散文捕获关闭（C-H1;#594 后属线上行为）;cursor
  载入错误 exit 1→20（C-H2）;corrections 异常轮不丢弃;build_truth PR
  半侧完整性;cursor env 拼错静默禁用改 fail-closed;
  test_discovery_contract 的 main() 移至文件尾。
- **TASK-DEC-008 minter 脚本修复（含 D2 重装窗口）**：cleanup trap 覆盖
  staged 文件;sidecar 新鲜度改 root 属主 600。部署副本按 digest pin 于
  main OID，合入后需维护者 D2 窗口重装——窗口未开则保持 blocked。

### Out of scope

- 框架抽出仓库（独立仓/pip 包/reusable workflow）——显式推迟到出现第二
  个消费者;本 change 只保证"可抽性"。
- CHG-2026-039 范围（全仓 discovery 缺省、idle 判词、archive glob）与
  其收账链;NAV 两任务的 done/verify/archive 不在本 change。
- 任何 wire/persisted 常量的**取值**变更（marker、schema、ref 前缀、
  exit code、envelope 字段序）;任何 GitHub 面配置（branch protection、
  ruleset）;launchd unit 除 DEC-008 声明的重装外零动作。
- 产品工具脚本（rockchip_*、*_capture 等）与产品 CI（swift-ci、
  rockchip-component）的行为变更——台账中对它们的观察（swift-ci 的
  fail-open、action 未按 SHA pin 等）记录为待维护者裁量项。
- 台账「noted-not-tasked」节列出的 LOW/风格项。

## Scope（涉及的 Requirement/AC）

- Requirements：无 canonical Core REQ/AC 认领（implementation-only）。
- Acceptance：全部 change-local（DEC-CONF-001 / DEC-SDD-001 /
  DEC-PRP-001 / DEC-HL-001 / DEC-REV-001 / DEC-NAV-001 / DEC-CONST-001 /
  DEC-MINT-001，见 verification.md）。
- Core baseline bump：不需要。

## Safety, privacy, and compatibility

- Failure modes：全部修复方向为收紧（fail-open→fail-closed）或等值搬移;
  每项修复配「撤销即红」回归测试。守卫收紧可能使既有畸形 tasks.md 行
  从静默通过变为显式报错——属预期（台账列出现存 8+ 处全角冒号行等
  受影响面，修复任务须附带清点报告而非静默）。
- Data/schema compatibility：协议常量值冻结（lease refs、cursor Issue、
  历史 PR body 必须继续可解析）;envelope evidence 分支收紧前须先修
  backends 渲染侧并保留对历史 body 的解析兼容（台账 E-M3 记录了两步
  次序约束）。
- 平台影响：macos host-only;Windows/Linux 未启动，一句带过：无影响。
- Rollback/migration：每任务独立 PR、独立 revert;instance.py 收口为
  纯搬移，revert 无状态残留;DEC-008 含部署副本重装，rollback = 按旧
  digest 重装旧副本（receipt 记录双向 digest）。

## Tasks

**r2（2026-07-27）新增 TASK-DEC-009,九任务见 tasks.md。** 新增理由:
DEC-005/006/007 的实现链在三处命中分区边界并如实停下,三项都需要一个
可触碰 `scripts/host_loop/__main__.py` 与 `test_worker_cursor.py` 的载体,
而唯一曾授权 `__main__.py` 的 TASK-DEC-007 已 done——**没有任何活任务能
承载它们**。其中 `observed_main` 是本 change 台账里**唯一仍然存活的安全
缺陷**。逐项:①`__main__.py` 的 `observed_main` 用 `out.split()[0]` 取
多行 ls-remote 输出的首个空白分隔 token,任何尾为 `refs/heads/main` 的 ref
可顶替受保护 main 的 OID（与 D-H2 同型,DEC-005 已修 `RefPort.read` 那
一半）;②`FakeApi` 缺 `GET /issues/{n}` 路由,补上会打红
`test_worker_cursor.test_closed_cursor_issue_is_refused`——该测试经查为
死测试（`__call__` 设为实例属性,其 fake 从不被调用,靠 `{}` 回落巧合
通过）;③TASK-DEC-005 的记录自身矛盾:r2 把 `identity.py` 与
`pr_envelope.py` 加入 Allowed paths 时未从 Forbidden paths 移除。

八任务原文如下。依赖链：DEC-003/005/006/008 无前置可先行;DEC-001 待
TASK-NAV-002 done;DEC-004 待 DEC-001;DEC-007 待 TASK-NAV-001 done;
DEC-002 收口在 DEC-005/006/007 全部 done 之后。全部任务改动自动化自身，
照 TASK-HLR-003/NAV 先例为 **never-claim**（会话实现;`NEVER_CLAIM_ROOTS`
的 `TASK-DEC` 根由 DEC-005 落码）;`Decision-Grade` 行由维护者亲笔，本
文件不代写。propose 合入 ≠ 批准。

## Verification closure（2026-07-27）

九个任务全部 done 于 protected main 在案,九条 change-local AC 的证据可
逐条复查;本 PR 仅状态翻转 + 引用,零实现夹带（先例 #224/#239/#570/#571）。

- **载体链**:propose #596 `7be0ac3d7273b6f296fb3b74efe304420e2f214d`;
  approval #598 `cac07003836889881994367bde7ba3e0bdca70c0`;
  readiness r1 #606/#607/#608/#614/#615 与 r2 #628/#643/#650;实现
  #623/#627/#629/#630/#636/#638/#640/#644/#647/#649;done 翻转
  #625/#626/#631/#632/#637/#639/#641/#645/#648/#653;窗口 receipt #652
  `b1a6c61ad26c172ad79d63da673c2c45f5dc121a`。全部 lvye APPROVED、
  mergedBy lvye。
- **AC 逐条结论(九条全 PASS)**:

| Evidence ID | Task | 结论 | 关键证据 |
| --- | --- | --- | --- |
| DEC-CONF-001 | DEC-001 | **PASS** | 配置五项与钉定 blob `02332a9b…` 的 `SENSITIVE_PATTERNS` 逐字节按序相同（AST 提取比对);五类畸形各红 fixture + 合法正对照;变异门代码侧 6/6 + 数据侧 3/3;README 覆盖以 `git ls-tree` 清点固化 |
| DEC-CONST-001 | DEC-002 | **PASS** | `instance.py` 37 常量逐一冻结（独立书写副本);单一定义清点走 **AST 非 grep**;变异 16/16,含 readiness 实测「改坏零反应」的**八项全部转为必红**;跨树 wire 值七项逐字节相同 + 旧树渲染 cursor 块由新树解析 + PR #564 body 解析 `repr` sha256 两树相同 |
| DEC-SDD-001 | DEC-003 | **PASS** | 六修复族各配撤销即红 fixture;变异 8/8 + 负对照存活;存量清点七类全零;`sdd-guard` 首次实跑 `test_check_sdd` 与 host_loop 套件 |
| DEC-PRP-001 | DEC-004 | **PASS** | 自扩权 fixture 被拒;散文吸收归零（51 任务路径类 pattern 丢失 **0**、惰性 24 出局);`--event` 伪 base 被拒;confusable 标题报歧义;`--identity-only` 读回改真;变异 16/16 |
| DEC-HL-001 | DEC-005 | **PASS** | r1 授权面 #629 + r2 移交三项 #630;`ALLOWED_ROUTES` 内容集不变;真实远端只读冒烟零写入 |
| DEC-REV-001 | DEC-006 | **PASS** | verdict 末行契约、(number,head) 去重、`(#N)` 尾锚定、`\s`→`[ \t]`;变异 8/8;历史 PR body 以 #564 `repr` sha256 `ace6adb602d6ab7b…` 前后相同为证 |
| DEC-NAV-001 | DEC-007 | **PASS** | C-H1 34 处合法语料全保留;cursor 损坏 exit 20;`NEVER_CLAIM_ROOTS` 纳入八 `TASK-DEC` 根,循环对本 change 任务零认领 |
| DEC-LEFT-001 | DEC-009 | **PASS** | `observed_main` 拒 refname 不等/多行;`FakeApi` 路由补齐后死测试真正驱动其 fake;DEC-005 的 Allowed/Forbidden 交集归零 |
| DEC-MINT-001 | DEC-008 | **PASS** | trap 覆盖全部五个暂存路径 + 注入式 harness（macOS 侧真跑三种失败注入);sidecar root 600;两条弱断言替换;**D2 窗口 receipt**:双 digest `5b8cbc06…`→`2df746cc…`、干跑 `exit=2`、强制铸造 `exit=0`、**sidecar 由 `fuhanfeng 644` 翻为 `root 600`**、自然到点触发 `runs 66→67` exit 0 |

- **收口时基线**:`check-sdd` **0 error / 0 warning / 111 acceptance IDs**;
  host_loop `-m unittest discover` **638 OK + 1 expected failure**;
  `test_check_pr_paths` **49 OK**;`test_minter_and_explain` **44 OK**
  (macOS;Linux 下 2 条平台门 skipped);`done_task_ids` **101**。
- **部署面**:minter 部署副本与仓内字节 digest 一致
  （`2df746cc58cf6dcf825a01f072cea4bdfffa61b706f40695c8e0531b3f2d6103`）,
  r1 接受的失配期已由 D2 窗口闭合;回滚源留存。

**如实记录的取证边界(不影响 PASS,但不粉饰)**

1. **DEC-008 的「拒绝路径后 token 未改动」窗口未独立取证**——步骤 5 后
   未单独 stat,步骤 6 的铸造覆盖了证据;该性质记在脚本结构（在
   `[ -f "$PEM" ]` 即退出)与 CI 测试
   `test_nothing_is_written_by_a_refused_invocation` 名下。
2. **失败路径零残留由 CI 注入 harness 证明,窗口只覆盖成功路径**;该
   harness 因 guard job 跑 ubuntu 而 GNU `stat` 不支持 BSD `-f`,**在 CI
   被平台门跳过**,补以所有平台都跑的结构断言（五个暂存变量在 cleanup
   体内、trap 早于首个 `mktemp`、预初始化行),变异实测两条 trap 变异被
   双杀。
3. **DEC-002 的两项线上冒烟无实物可测**:实测远端
   `agent/host-loop/**` 命名空间为空、无 cursor Issue;未以「无实物」当
   通过,改以跨树对照 + 真实 PR #564 解析为替代证据。
4. **DEC-005 有两项经其 readiness 停条件如实未交付**（`observed_main`
   半侧、`FakeApi` 路由),二者由后续 **TASK-DEC-009** 独立收口并已 done。

**台账处置**:`review-findings.md` 中 noted-not-tasked 项（B-M5 swift-ci
pipefail、B-M6 concurrency、B-H2 结构自签环、B-M7、A-L 系列、
rockchip-component workflow 卫生等）**不构成本 change 验收面**,其处置
（立项/接受/搁置）由维护者裁量;B-H2 已在 `check_pr_paths.py` 的模块
docstring 中显式记录为已知残留。
