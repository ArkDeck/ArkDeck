---
id: CHG-2026-040-automation-decoupling
revision: 2
status: approved
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
