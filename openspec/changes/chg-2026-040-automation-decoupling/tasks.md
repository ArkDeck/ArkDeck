# CHG-2026-040 Tasks

> 八任务全部改动自动化自身代码/测试/CI 面，照 TASK-HLR-003 与 NAV 先例
> 均为 never-claim（会话实现、维护者合并;`NEVER_CLAIM_ROOTS` 的
> `TASK-DEC` 根由 **TASK-DEC-007** 落码——r1 起草时从 DEC-005 移交,因
> DEC-007 独占 `worker.py`,两任务并行改同一文件会真冲突）。
> **⚠ 顺序硬约束（2026-07-27 实测)**:`NEVER_CLAIM_ROOTS` 现为
> `{TASK-HLR-003, TASK-NAV-001, TASK-NAV-002}`,**不含 `TASK-DEC` 根**,
> 故 `is_never_claim("TASK-DEC-003")` 实测为 `False`;而 `--explain` 对已
> ready 的 DEC 任务打出 `one Decision-Grade line from claimable`。
> **在 TASK-DEC-007 的实现（含本表扩充）合入 main 之前,不得为任何
> TASK-DEC 写 `Decision-Grade` 行**——否则活循环会认领本 change 声明为
> 会话实现的任务,且 DEC-005/007 恰是改写"决定它能认领什么"的那段代码。
> `Decision-Grade` 行由维护者亲笔
> （#577 先例），本文件不代写。修复对象的行号引用见 review-findings.md;
> 该台账的行号在 audit base 上采集，各任务 readiness 时按当时 main 重钉
> exact blob。

## TASK-DEC-001 — 敏感路径配置抽取与框架/产品边界文档

- Status:ready（r1 implementation readiness;前置① approval 已合 = #598
  `cac07003…`,前置② TASK-NAV-002 已 done（#599,chg-2026-039 已 archived
  于 #610）,前置③ 即本 readiness。授权范围与门见下方「Readiness r1」节;
  任一门不满足即停,不得降门执行。）
- Platform:macos（host-only）
- Requirements/AC:change-local `DEC-CONF-001`
- Depends on:TASK-NAV-002
- In scope:新文件 automation_config.json（schema 字段 + sensitive_paths
  列表，初值与现硬编码五项逐字节相同）;check_pr_paths.py 改为 fail-closed
  加载（缺失/未知 key/空表/非字符串/重复项 = CheckError）;新文件
  scripts/README.md 边界地图（framework vs 产品工具清单、实例参数索引）。
- Out of scope:路径匹配语义变更（TASK-DEC-004）、workflow 文件、
  host_loop、openspec 布局常量。
- Allowed paths:`scripts/check_pr_paths.py`、`scripts/test_check_pr_paths.py`、`scripts/automation_config.json`、`scripts/README.md`、本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`scripts/host_loop/**`、`scripts/check_sdd.py`、`.github/**`、`openspec/governance/**`、`openspec/specs/**`、产品 source/tests、其他 change。
- Risk:low（值等同搬移 + 加载只增拒绝路径;回退 = revert）。
- Hardware required:no。

### Verification

- `DEC-CONF-001`：配置文件五项与原硬编码逐字节相同（对照测试）;加载
  fail-closed 五种畸形各有红 fixture;敏感判定行为对既有 fixture 语料
  零漂移;README 覆盖 scripts/ 下全部一级条目。

### Readiness r1（2026-07-27）

**Audit base** = `ecd5320b35308ddd44f67fb6a825a9c5f9e3fc1b`。

**开工基线声明（Ordering 义务,非 drift gate)**

```yaml pins
- path: scripts/check_pr_paths.py
  blob: 02332a9b572013e99b74acd46db8810ba4f7275a
- path: scripts/test_check_pr_paths.py
  blob: a2f11b0450dafd4e2dbf3d0b35008d0ecbf01880
```

**待搬移值的实测正本（本 readiness 的锚,实现须逐字节相同）**

audit base 上 `check_pr_paths.SENSITIVE_PATTERNS` 实测为**恰五项、按此
顺序**（锚是下列字面量文本本身,实现须逐字符比对;其字节权威在上表钉定
的 `check_pr_paths.py` blob `02332a9b…` 内）:

1. `Packages/**`
2. `ArkDeckApp/**`
3. `ArkDeckAppUITests/**`
4. `scripts/**`
5. `.github/**`

**配置载体的两条硬约束（均为实测得出,不是偏好）**

1. **必须落在 `scripts/**` 之下**。该表本身决定"无任务声明的 PR 不得
   触碰哪些路径";若配置文件落在非敏感路径（如 `openspec/**`）,一个
   task-less PR 就能先改配置再触产品路径——自引用削弱。落在
   `scripts/**` 下时配置文件受它自己声明的规则保护。**选定路径 =
   `scripts/automation_config.json`。**
2. **必须是 stdlib 可解析格式（JSON,不用 YAML）**。`agent-pr.yml` 与
   `sdd-guard.yml` 的 allowed-paths job **不执行 `pip install`**
   （`requirements-sdd.txt` 只在 guard job 装）,`check_pr_paths.py` 现
   零第三方 import;引入 YAML 会使守卫在依赖缺失时无法运行。

**加载语义 = fail-closed(五类畸形逐一拒绝)**

文件缺失 / 顶层非对象或 schema 字段不符 / 出现未知 key /
`sensitive_paths` 为空表或非列表 / 元素非字符串或有重复项 —— 一律
`CheckError`,**绝不静默回退到硬编码默认值**。回退默认值会让"配置被删
或被写坏"表现为"守卫照常绿",正是本 change 台账反复记录的形状。

**Pass/fail boundary**

1. **等价性对照测试**:配置文件解析结果与 r1 记录的五项**逐字节、按序**
   相同;该测试须能因任一项改动而变红。
2. 五类畸形各有红 fixture,且**各配正对照**（合法配置必绿）。
3. **行为零漂移**:既有 `test_check_pr_paths.py` 全部 24 测试保持绿,
   不得为通过而放宽任何断言;task-less PR 的敏感判定对既有 fixture 语料
   结果不变。
4. **变异门**:删除 fail-closed 加载的任一分支,对应 fixture 必红;把
   加载改回硬编码默认,等价性测试之外必须另有测试变红（否则该配置是
   装饰性的）。
5. `scripts/README.md` 边界地图须覆盖 `scripts/` 下**全部一级条目**
   （framework 与产品工具逐一分类,并标出各自实例参数所在);以清点对照
   `ls scripts/` 为证,遗漏即不合格。
6. 全套件 `check_pr_paths` **24 → ≥24 OK**;host_loop **≥536 OK + 1
   expected failure**;`check-sdd` 保持 0/0/111。

**Risk acceptance（首次）**：把安全相关的常量移出代码进入数据文件,
本质上把"改这张表"的门从 code review 降为 data edit。已接受,理由:
①文件位于 `scripts/**`,受自身声明的敏感规则保护,改它的 PR 仍需任务
声明或触发 task-less 拒绝;②加载 fail-closed,损坏不会静默放行;
③等价性测试锁住初值。**若实现时发现①不成立（例如该路径未被自身规则
覆盖）,即停并转 r2。** 回退 = revert。

**Stop conditions**：配置路径落在 `scripts/**` 之外;引入任何第三方
依赖;任何既有断言为通过而被放宽;需要触碰 `.github/**`（workflow 无需
改动——`check_pr_paths.py` 自读配置）或 `scripts/host_loop/**`。

**不授权**：路径匹配语义变更（`fnmatch` 单星跨 `/` 等属 DEC-004）;
`SENSITIVE_PATTERNS` **内容增删**（本任务只搬移,不改集合;扩项属
DEC-004 且须维护者在其 readiness 认可清单）;两 checker 文法统一;
`Decision-Grade` 代写。

## TASK-DEC-002 — host_loop 实例与协议常量收口（全链收尾）

- Status:blocked（前置：① approval merge;② TASK-NAV-001、TASK-DEC-005、
  TASK-DEC-006、TASK-DEC-007 全部 done——本任务是对同一批文件的纯搬移
  收口，排最后避免与行为修复冲突;③ 独立 readiness 钉全部受改文件
  exact blob 与常量清单。）
- Platform:macos（host-only）
- Requirements/AC:change-local `DEC-CONST-001`
- Depends on:TASK-NAV-001、TASK-DEC-005、TASK-DEC-006、TASK-DEC-007
- In scope:新模块 instance.py 收口实例/协议常量（lease schema、cursor
  与 envelope marker、git author/committer、user-agent、API root、owner/
  repo/env 名缺省、ttl/timeout、PR 标题模板）;lease 命名空间四处、task
  文法三处、base 分支四处收敛单一定义;精确内容冻结测试（各值与测试内
  字面量副本逐字节相等）+ 既有 parity 测试保持。
- Out of scope:任何常量取值变更、任何行为变更、launchd/plist。
- Allowed paths:`scripts/host_loop/instance.py`、`scripts/host_loop/*.py`（仅 import 与常量定义点搬移）、`scripts/host_loop/test_*.py`、本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`scripts/check_pr_paths.py`、`scripts/check_sdd.py`、`.github/**`、`openspec/governance/**`、launchd/plist 面、产品 source/tests、其他 change。
- Risk:low-med（触文件面宽但语义为零行为搬移;冻结测试 + 全量套件门;
  回退 = revert）。
- Hardware required:no。

### Verification

- `DEC-CONST-001`：冻结测试对每个搬移值断言字节相等;lease 命名空间/
  task 文法/base 分支各余恰一处定义（grep 清点入 evidence）;全量套件
  与 check-sdd 基线保持;线上 lease ref、cursor Issue、既有 PR body 的
  解析回归绿。

## TASK-DEC-003 — check_sdd fail-closed 修复与测试基建接线

- Status:ready（r1 implementation readiness;前置① approval 已合
  = #598 `cac07003836889881994367bde7ba3e0bdca70c0`（lvye APPROVED,
  mergedBy lvye）,前置② 即本 readiness。授权范围与门见下方
  「Readiness r1」节;任一门不满足即停,不得降门执行。）
- Platform:macos（host-only）
- Requirements/AC:change-local `DEC-SDD-001`
- Depends on:none（与 NAV/其他 DEC 任务零文件交集）
- In scope:台账 A-H1（认领面跨任务边界吸收）、A-H2/A-M3（解析为 None
  的 scope.yaml/registry/locks/conformance 静默跳过改显式 error）、
  A-M1（状态行逐任务配对 + 词表尾边界）、A-M2（capability id 重复
  显式 error）、A-M4（present-but-null 崩溃族改干净 error）、A-L2 死
  replace 清理、A-L5（changes/ 下非 chg-*/archive/README 条目显式
  error）;sdd-guard.yml guard job 接入 test_check_sdd.py 与 host_loop
  套件（unittest discover）。
- Out of scope:check_pr_paths（另任务）、两 checker 文法统一（记台账
  待 DEC-004 后评估）、openspec 内容文件修正。
- Allowed paths:`scripts/check_sdd.py`、`scripts/test_check_sdd.py`、`.github/workflows/sdd-guard.yml`、本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`scripts/check_pr_paths.py`、`scripts/host_loop/**`（读不写;CI 接线只改 workflow）、`openspec/specs/**`、产品 source/tests、其他 change。
- Risk:low-med（检查只收紧;现仓必须保持 0 error——修复前先对全仓跑
  收紧版并清点新报错，若命中存量畸形则在任务内修 openspec 存量或按
  维护者裁量豁免——存量修正若超出 allowed paths 即停，走独立载体）。
- Hardware required:no。

### Verification

- `DEC-SDD-001`：每项修复配「撤销即红」fixture（H1 跨界吸收、H2 空
  scope、M1 双行/零行与 done-ish、M2 重复 id、M4 各 null 形态）;CI
  workflow 运行两套件的 run 证据;现仓 guard 保持 0 error（或附清点与
  处置记录）。

### Readiness r1（2026-07-27）

**Audit base** = `005e1ffc321b2dbc87409895ac28c290b93f7e24`。approval merge
是 `cac07003836889881994367bde7ba3e0bdca70c0`（#598）;其后合入的
#600/#599/#523（NAV 两任务 done 翻转与 chg-034 propose）**对本任务的三个
受改文件零触碰**——十九个受钉 blob 在两个 OID 上逐一比对全部相同,故
下表与勘察结论在新 base 上继续成立。

**Input gate（实现开工前逐条复核,任一不符即停并转 r2）**

本任务的三个受改文件按 Ordering 义务而非 drift-gate blob pin 处理——
readiness 授权的 PR 必然改写它们,把自己的产物钉进「任一漂移即零工作」
的表会造成 HLR-003 r3 式自噬。实现 PR 的 evidence 须以
`git show <audit base>:<path>` 三元组记录开工时的字节:

```yaml pins
- path: scripts/check_sdd.py
  blob: 87e39df7136864d3c6a10417388d30ecdd11a480
- path: scripts/test_check_sdd.py
  blob: 2e40b5534764877a6dcb6c5107e5e5763fa7535b
- path: .github/workflows/sdd-guard.yml
  blob: c64135e1f9dc253a92640a30bbcad42b0afa86fa
```

上表是**开工基线声明**（记录用),不是 drift gate。若开工时实测值与上表
不符,说明另有载体先动了同一文件,停并转 r2 重钉。

**存量清点（已实测,r1 据此免除停机制）**：在 audit base 上以收紧版逐
检查复算真实 openspec 树,七类**全为 0**（逐任务 Status 配对≠1、宽严
正则差集、全角冒号 Status 行、需跨界吸收才成立的 scope 认领、解析为
None 的治理文件、重复 capability id、`changes/` 游离条目）。**故本任务
的收紧不需要修改任何 openspec 内容,全部落在 allowed paths 内**;若实现
时复算出现非零,即触发 tasks.md 的 Risk 停条款——停并走独立载体,不得在
本任务内顺手改 openspec 正文。

**Pass/fail boundary**

1. 六个修复族（A-H1/A-H2+M3/A-M1/A-M2/A-M4/A-L5）各有至少一个「撤销该
   修复即变红」的 fixture;A-L2 死代码删除以行为等价测试兜底。
2. **变异门**：逐条撤销修复后对应 fixture 必红,且正对照（合法输入）必绿;
   任一条撤销后仍全绿 = 该修复无效,整轮作废。
3. `check-sdd` 对真实仓保持 **0 error / 0 warning / 111 acceptance IDs**。
4. `sdd-guard.yml` 的 guard job 实跑 `test_check_sdd.py` 与 host_loop
   套件（`-m unittest discover`,直跑单文件不算——见台账 C-H3）,以 CI
   run 链接为证据;host_loop 期望计数 **536 OK + 1 expected failure**。
5. workflow 改动不得新增任何 permission、secret 或 `pull_request_target`;
   `test_agent_pr_workflow.py` 的 forbidden-capability 扫描保持绿。

**Risk acceptance（首次）**：收紧后的 check_sdd 对**未来**畸形输入更
严格,可能使某个尚未写出的 tasks.md 形态被拒。已接受:方向为 fail-closed,
且存量清点为零证明现有语料不受影响。回退 = revert 实现 PR。

**Stop conditions**：存量复算非零;任一变异门不成立;guard 计数偏离;
需要触碰 allowed paths 外任何文件（含 openspec 正文与其他 workflow）。

**不授权**：任何 openspec 内容修改;check_pr_paths 侧改动（DEC-004）;
两 checker 的 task 文法统一（记台账待评估）;`Decision-Grade` 代写。

## TASK-DEC-004 — check_pr_paths 信任边界与解析硬化

- Status:blocked（前置：① approval merge;② TASK-DEC-001 done（同
  文件）;③ 独立 readiness 钉 exact blob、各修复的语义决策（base 权威
  的两 workflow 适配、glob 方言声明）与回归清单。）
- Platform:macos（host-only）
- Requirements/AC:change-local `DEC-PRP-001`
- Depends on:TASK-DEC-001
- In scope:台账 B-H1（任务定义主路径改 base 侧权威 + head 侧仅补充
  校验）、B-H3（Allowed paths 解析改定界模式，停止吸收散文反引号;
  终止符含缩进 bullet/三级标题）、B-H4（--event 模式身份与 base 祖先
  校验）、B-M2/M3（Task 行与标题 token 的跨行/homoglyph）、B-M8
  （--identity-only 回读改断言 API 读回值）、B-M4（SENSITIVE 大小写、
  根级配置文件盲区按维护者在 readiness 认可的清单扩充）、B-M1（fnmatch
  方言：单星语义收紧或在 README 显式声明，readiness 定夺）。
- Out of scope:agent-pr.yml 结构重构（B-H2 的 checkout 信任问题记台账
  为架构级观察，本任务只在 workflow 内做低成本缓解或显式记录）、
  concurrency 守卫（B-M6，noted）、swift-ci/rockchip workflow。
- Allowed paths:`scripts/check_pr_paths.py`、`scripts/test_check_pr_paths.py`、`scripts/test_agent_pr_workflow.py`、`.github/workflows/agent-pr.yml`、本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`scripts/host_loop/**`、`scripts/check_sdd.py`、`.github/workflows/sdd-guard.yml`（DEC-003 已改;若 base 权威需动其 --event 调用则在 readiness 显式扩权）、`openspec/specs/**`、产品 source/tests、其他 change。
- Risk:med（守卫语义变更;现存 5 个任务 Allowed paths 天然拒绝、8+ 全角
  冒号行等存量畸形在收紧下的行为变化须逐项清点入 evidence;回退 =
  revert）。
- Hardware required:no。

### Verification

- `DEC-PRP-001`:自扩权 fixture（同 PR 改 tasks.md 放宽 + 触敏感路径）
  被拒;散文吸收 fixture（chg-2026-025 形态）零吸收;--event 伪 base
  fixture 被拒;homoglyph 标题产生歧义错误;--identity-only 对 API 读回
  篡改 fixture 变红;全部修复各有「撤销即红」对照;对现仓全部 active
  tasks.md 的解析清点报告（吸收项归零或逐项裁决）。

## TASK-DEC-005 — host_loop transport/lease/backends 硬化

- Status:ready（r1 implementation readiness;前置① approval 已合
  = #598 `cac07003836889881994367bde7ba3e0bdca70c0`,前置② 即本
  readiness。授权范围与门见下方「Readiness r1」节;任一门不满足即停,
  不得降门执行。）
- Platform:macos（host-only;零设备面）
- Requirements/AC:change-local `DEC-HL-001`
- Depends on:none（transport/lease/backends 为 NAV Forbidden 文件，零
  交集;与 DEC-006/007 文件分区见各任务 Allowed paths）
- In scope:台账 D-H1（no-redirect opener + 绝对 URL 逃逸口关闭 + API
  root 前缀断言）、D-H2（read/observed_main 的 refname 等值校验、拒
  多行）、D-H3（_advance 校验 owner_run）、D-M3（git 子进程环境白名单
  构造、GIT_CONFIG 守卫硬设、token 不入子进程 env 的形态评估）、D-M6
  （403 限流歧义化，含 sender 暴露限流头）、D-M7（绑定器 bool 排除）、
  D-M8（committer 身份硬设）、D-M9（assert_still_held 最小剩余 TTL
  余量）;死代码退役：Python minter 与其 sudo-openssl 测试、恒假 fence
  断言换真监控注释、assert_no_secret 接线或删除、AGENT_REF_RE 冗余
  分支;测试替身补真实字段（FakeApi 的 GET issue 路由、pull 字段、
  check-run id）;backends 渲染侧 none 声明改 `none:` 文法（台账 E-M3
  渲染半侧）。
- Out of scope:reviewer/recovery/pr_envelope/identity（TASK-DEC-006）、
  worker/__main__/cursor 含 NEVER_CLAIM_ROOTS（TASK-DEC-007 独占
  worker.py，本任务零触碰以免并行冲突）、minter shell（TASK-DEC-008）、
  ALLOWED_ROUTES 集合变更（零路由增删）。
- Allowed paths:`scripts/host_loop/transport.py`、`scripts/host_loop/lease.py`、`scripts/host_loop/backends.py`、`scripts/host_loop/test_fault_matrix.py`、`scripts/host_loop/test_backends_cli.py`、`scripts/host_loop/test_token_parity.py`、本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`scripts/host_loop/worker.py`、`scripts/host_loop/reviewer.py`、`scripts/host_loop/recovery.py`、`scripts/host_loop/pr_envelope.py`、`scripts/host_loop/identity.py`、`scripts/host_loop/cursor.py`、`scripts/host_loop/__main__.py`、`scripts/host_loop/mint_installation_token.sh`、`.github/**`、`openspec/specs/**`、产品 source/tests、其他 change。
- Risk:med（安全修复触 live 循环的写路径;全部为收紧方向;两 left-running
  unit 零动作，行为经 checkout 前进生效;回退 = revert）。
- Hardware required:no。

### Verification

- `DEC-HL-001`:重定向 fixture（3xx 以状态呈现、不跨主机跟随、token 不
  外发）;影子 ref fixture（read 拒绝 refname 不等/多行;正对照单行等值
  通过）;异主 HeldLease renew → FenceLost（正对照同主 renew 通过）;
  GIT_CONFIG 注入 fixture 失效;403+限流头 → TransportError 而非
  Refused;每项「撤销即红」;死代码退役后套件全绿且 grep 零残留;真实
  远端只读冒烟（observe/read 对现存 lease 命名空间行为不变）。

### Readiness r1（2026-07-27）

**Audit base** = `005e1ffc321b2dbc87409895ac28c290b93f7e24`（approval
`cac07003…` 之后的 #600/#599/#523 对本任务受改文件零触碰,十九 blob 逐一
比对相同）。

**开工基线声明（Ordering 义务,非 drift gate)**

```yaml pins
- path: scripts/host_loop/transport.py
  blob: 537d57a02ea2f6996f58def3961854ef2abc94be
- path: scripts/host_loop/lease.py
  blob: 685fb3c3c8c8266c52816027c92b300ea7cd6732
- path: scripts/host_loop/backends.py
  blob: 0efa3e8c74c7935f96742d4d9f1649cc91534dd2
- path: scripts/host_loop/test_fault_matrix.py
  blob: 7a3b2d94e0a4f493c82e4a1c73ed490052a9a28b
- path: scripts/host_loop/test_backends_cli.py
  blob: 08f87845c142de2d05369a193e2aef5e0a3470e8
- path: scripts/host_loop/test_token_parity.py
  blob: efb937541d8da2049819267acc45bf94f3f3be64
```

**干跑实测（本 readiness 起草时执行,是下方变异门的依据）**

对 D-H2（`RefPort.read` refname 等值 + 拒多行）与 D-H3（`_advance` 校验
`owner_run`）各自单独施加最小修复后,全套件 **536 OK + 1 expected
failure,零断言反应**。**这不是"改动无影响",而是两件事**:①零构造点——
修复不依赖任何既有断言的具体形状,可安全落地;②**这两条性质在现套件中
零覆盖**。故下方变异门是本 readiness 的核心条件:**没有会因 revert 变红
的测试,修复等于没修**。

**Pass/fail boundary**

1. **每个修复必须有一个「撤销该修复即变红」的新测试**,且各配正对照
   （合法输入必绿）。逐项覆盖 D-H1/D-H2/D-H3/D-M3/D-M6/D-M7/D-M8/D-M9。
   任一修复撤销后套件仍全绿 = 该项无效,整轮作废。
2. **D-H1 的判据是"3xx 到达 `_call` 成为状态"**,不是"测试通过":需
   双服务器或等价替身证明 GET/POST 不跨主机跟随、Authorization 头不外
   发、绝对 URL 逃逸口关闭;并使既有
   `test_non_success_status_is_not_treated_as_applied` 对 GET/POST 真正
   可达（台账记该守卫今日仅 PATCH 触发）。
3. **`ALLOWED_ROUTES` 恰 8 条且内容集不变**——零路由增删,以精确内容集
   断言（既有 `test_allowlist_contents_are_pinned_exactly` 保持绿;
   `len()` 型断言不作数）。D-M1 记录的 minter 未钉路由**本轮不改**
   （其载体是 DEC-008 与 instance 收口,此处只在 evidence 说明现状）。
4. **测试替身补真实字段后不得放宽任何断言**:FakeApi 补 GET issue 路由、
   pull 的 merged/auto_merge/merge_commit_sha/html_url、check-run `id`;
   补齐后既有断言若变红,按"替身此前比真接口宽松"处理——修被测代码,
   不改断言就绿。
5. 死代码退役（Python minter 与其 sudo-openssl 测试、恒假 fence 断言、
   `assert_no_secret` 接线或删除、`AGENT_REF_RE` 冗余分支）后:套件全绿、
   `grep` 零残留、且**退役项不得留下"看起来在岗"的测试**。
6. 全套件期望 **≥536 OK + 1 expected failure**（新增测试使其增长;
   减少即回归）;`check-sdd` 保持 0/0/111。
7. **真实远端只读冒烟**:对现存 `refs/heads/agent/host-loop/leases/*`
   与 tasks 命名空间执行 `observe`/`read`,行为与修复前一致;**零写入**
   （receipt 记 ref_log 与 route_log,写计数必须为 0）。

**Risk acceptance（首次）**：本任务改的是 live 循环的写路径与唯一外呼
通道。已接受:全部为收紧方向;两 left-running unit **零动作**,行为经
运行机 checkout 前进到含实现的 main 生效;`_advance` 加 owner 校验会使
任何依赖"renew 他人租约"的既有调用失败——已确认生产无此调用点
（renew 仅在自持路径调用）,若实现时发现反例即停并转 r2。回退 = revert。

**Stop conditions**：任一变异门不成立;`ALLOWED_ROUTES` 内容集变化;
冒烟出现任何写入;需要触碰 Forbidden paths（尤其 `worker.py` 归
DEC-007、`reviewer.py` 等归 DEC-006）;需要改 launchd/plist。

**不授权**：路由增删;minter shell 修改（DEC-008）;`instance.py` 收口
（DEC-002）;envelope path 分支收紧（DEC-006;本任务只做 backends 渲染侧
`none:` 的一半）;`Decision-Grade` 代写。

## TASK-DEC-006 — reviewer/envelope/recovery 硬化

- Status:ready（r1 implementation readiness;前置① approval 已合
  = #598 `cac07003836889881994367bde7ba3e0bdca70c0`,前置② 即本
  readiness。授权范围与门见下方「Readiness r1」节;任一门不满足即停,
  不得降门执行。）
- Platform:macos（host-only）
- Requirements/AC:change-local `DEC-REV-001`
- Depends on:none（与 DEC-005/007 文件分区互斥）
- In scope:台账 E-H1（verdict 契约改「最后一非空行、列 0、拒尾随」，
  反转现钉测试）、E-M1（去重键改 number+head，状态由记录 verdict 重
  导出）、E-M2（`(#N)` 尾锚定，双向 fixture）、E-M4（`\s`→`[ \t]` 两处
  + 同型全扫）、identity.confirm_merge 退役（含 test_fault_matrix 对应
  用例改指 recovery 正本）、reviewer 子进程卫生（stdin=DEVNULL、输出
  上限、err 细节入 AdapterFailure、recorded_at 用注入时钟）、E-M3 解析
  半侧：evidence path 分支对历史 body 保持解析、渲染侧已由 DEC-005 改
  `none:`，本任务补 path 分支的白名单形状校验并验证历史 PR body 语料
  回归。
- Out of scope:batch digest 字段清洗（E-L6，noted 待 Phase4 前）、
  CRLF 楔死（运维注记）、backends.py（DEC-005 已改）。
- Allowed paths:`scripts/host_loop/reviewer.py`、`scripts/host_loop/recovery.py`、`scripts/host_loop/pr_envelope.py`、`scripts/host_loop/identity.py`、`scripts/host_loop/test_reviewer_contract.py`、`scripts/host_loop/test_recovery_contract.py`、`scripts/host_loop/test_pr_envelope.py`、`scripts/host_loop/test_v3_hardening.py`、本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`scripts/host_loop/transport.py`、`scripts/host_loop/lease.py`、`scripts/host_loop/backends.py`、`scripts/host_loop/worker.py`、`scripts/host_loop/__main__.py`、`scripts/host_loop/cursor.py`、`scripts/host_loop/test_fault_matrix.py`（confirm_merge 用例迁移若需动此文件，readiness 显式扩权）、`.github/**`、产品 source/tests、其他 change。
- Risk:med（review 信任边界语义变更;verdict 新契约使既有"尾部 VERDICT"
  形态转 AdapterFailure→reconcile，方向收紧;回退 = revert）。
- Hardware required:no。

### Verification

- `DEC-REV-001`:尾部引用 VERDICT fixture 不再翻转（变异门:撤销修复该
  fixture 必红）;既有 `test_parses_the_last_verdict_line` **保持绿**
  （见 r1 更正）;(number,head) 去重双 fixture（同 head 重放拒绝、新 head
  重审）;`(#N)` 提及型 fixture 不再假确认/假歧义;\s 修复的 phantom
  header/跨行 id fixture;confirm_merge 零引用 grep;历史 PR body 语料
  （现存 worker PR）解析回归绿。

### Readiness r1（2026-07-27）

**Audit base** = `005e1ffc321b2dbc87409895ac28c290b93f7e24`（十九 blob 与
approval `cac07003…` 时逐一相同）。

**开工基线声明（Ordering 义务,非 drift gate)**

```yaml pins
- path: scripts/host_loop/reviewer.py
  blob: 574746eb8ec16296ddf7a0c7d5039db5e43d3e0e
- path: scripts/host_loop/recovery.py
  blob: d2763e59472ee676ab6231d28273448c94b8f265
- path: scripts/host_loop/pr_envelope.py
  blob: 2c286c8da0fa8945d512115dfce9de5150db0831
- path: scripts/host_loop/identity.py
  blob: d22e62946e3b5b836cbdcd9b48b57031172fe4b1
- path: scripts/host_loop/test_reviewer_contract.py
  blob: aa9dbe949d6498f3ed2612c8feb8d19826826f1e
- path: scripts/host_loop/test_recovery_contract.py
  blob: 1dbf61de9d55c0fbed4a87429a25116b4245ea03
- path: scripts/host_loop/test_pr_envelope.py
  blob: 47fd19f9653e2e7878668e4e7f3eb45f50da4372
- path: scripts/host_loop/test_v3_hardening.py
  blob: fa6a869bc4f104207bdc81275ab272cf5873a1ab
```

**r1 更正:E-H1 不是契约变更（干跑双向实测,台账已同步更正）**

台账 r1 曾称 `test_parses_the_last_verdict_line` 把"翻转行为"钉成契约、
修复须反转该测试。**该判断不成立**:该 fixture 的最后一条 `VERDICT:`
**恰好也是最后一非空行**,两种语义在其上同解。施加最小修复（verdict 取
最后一非空行、列 0 匹配）后实测:该测试**仍绿**、全套件 536 OK + 1 xf
**零断言反应**,而攻击形态（`VERDICT: REQUEST_CHANGES` 之后跟附录里缩进
的 `VERDICT: APPROVE`）由 `APPROVE` 变 `AdapterFailure` = 缺陷关闭。
**推论:本任务无需反转任何既有测试;危险形态在现套件零覆盖,故新测试
与变异门是唯一有效性证明。** 若实现时发现某既有测试确因修复变红,
即停并转 r2——那意味着本更正的前提被推翻。

**Pass/fail boundary**

1. **每个修复配「撤销即变红」的新测试 + 正对照**,逐项覆盖
   E-H1/E-M1/E-M2/E-M4 与 reviewer 子进程卫生项。
2. **E-H1 双向断言**:攻击形态必须 `AdapterFailure`（→ 上游
   `RECONCILE_REQUIRED`,**不得**降级为任何 verdict）;既有 pinned
   fixture 必须仍绿。二者缺一即不合格。
3. **E-M2 双向**:提及型 `(#N)` 既不得假确认（回退路径不得把跟进 commit
   当 merge）、也不得假歧义;正对照 = 真 squash subject 尾部 `(#N)` 仍
   唯一命中。
4. **历史兼容是硬门**:现存 worker PR 的 body 语料必须继续解析通过。
   evidence 须列出所取样本 PR 编号与解析结果。**E-M3 的 path 分支收紧
   只能在 backends 渲染侧 `none:` 修复（DEC-005）已合入 main 之后进行**;
   若 DEC-005 未合,本任务只做 path 分支的形状校验而不改 `none` 语义。
5. `identity.confirm_merge` 退役后:生产与测试零引用（grep 为证）,且
   `test_fault_matrix` 中原覆盖它的用例改指 `recovery.confirm_merged`
   正本——**不得直接删测试了事**。若该迁移必须改
   `test_fault_matrix.py`（属 DEC-005 分区）,即停并在 r2 显式扩权。
6. 全套件 **≥536 OK + 1 expected failure**;`check-sdd` 保持 0/0/111。

**Risk acceptance（首次）**：verdict 契约收紧会使"verdict 后仍有内容"的
审阅输出从产出裁决变为 `AdapterFailure` → lane 停给人看。已接受:该方向
正是本修复的目的,且 reviewer 尚未接线生产（live dispatch 属 HLR-005）,
本轮为接线前的契约修复,线上零影响。回退 = revert。

**Stop conditions**：任一既有测试因修复变红（前提被推翻,转 r2）;历史
body 语料解析回归失败;需要触碰 `test_fault_matrix.py` 或其他 DEC-005/007
分区文件;需要改 `backends.py`。

**不授权**：batch digest 字段清洗（E-L6,留 Phase 4 接线前）;CRLF 楔死
处置（仅记运维注记）;`instance.py` 收口（DEC-002）;`Decision-Grade`
代写。

## TASK-DEC-007 — worker/discovery 解析与观测硬化

- Status:ready（r1 implementation readiness;前置① approval 已合 = #598
  `cac07003…`,前置② TASK-NAV-001 已 done（#600,chg-2026-039 已 archived
  于 #610）,前置③ 即本 readiness。**本任务含 never-claim 守卫扩充,是
  其余 DEC 任务被评级前的顺序前置**——见文件头 ⚠ 与下方「Readiness r1」
  节;任一门不满足即停,不得降门执行。）
- Platform:macos（host-only）
- Requirements/AC:change-local `DEC-NAV-001`
- Depends on:TASK-NAV-001
- In scope:台账 C-H1（空值 `- Depends on:`/`- Allowed paths:` 与散文
  反引号捕获改 fail-closed 省略任务 + 判词说明;合法多行续行格式保持）、
  C-H2（cursor 载入 CursorError → exit 20）、C-M4（build_truth PR 半侧
  按全 open-PR 观察或显式 partial 标记，消除假 correction）、C-M5
  （corrections 并入异常轮 detail）、C-M6（cursor env 拼错 →
  ReconcileRequired）、C-M8a（adopt/renew 路径带 pr_number/pr_head，
  消除中间态假字段）、test_discovery_contract 的 `unittest.main()` 移
  文件尾;C-L11（_change_is_approved 的标点截断防护）;
  `NEVER_CLAIM_ROOTS` 加入 `TASK-DEC` 根（本任务独占 worker.py，
  其余 DEC 任务对该文件零触碰）。
- Out of scope:NAV-001 已交付语义（全仓扫描/idle 判词/时间戳——回归
  保持不重做）、explain 双实现合并（noted）、Phase4 cursor 写授权、
  DISPATCHABLE_GRADES。
- Allowed paths:`scripts/host_loop/__main__.py`、`scripts/host_loop/worker.py`、`scripts/host_loop/cursor.py`、`scripts/host_loop/test_discovery_contract.py`、`scripts/host_loop/test_worker_cursor.py`、`scripts/host_loop/test_cursor_contract.py`、`scripts/host_loop/test_check_verdict_contract.py`、`scripts/host_loop/test_navigation_contract.py`、`scripts/host_loop/test_support.py`、本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`scripts/host_loop/transport.py`、`scripts/host_loop/lease.py`、`scripts/host_loop/backends.py`、`scripts/host_loop/reviewer.py`、`scripts/host_loop/recovery.py`、`scripts/host_loop/pr_envelope.py`、`scripts/host_loop/identity.py`、`.github/**`、产品 source/tests、其他 change。
- Risk:med（discovery fail-closed 收紧会使现存畸形行的任务从静默误读
  变为省略;须对全仓 active tasks.md 出清点报告——现存 8+ 全角冒号行
  等在收紧后的可见性变化逐项列出，涉及存量 tasks.md 修正时按 DEC-003
  同款停机制走独立载体;回退 = revert）。
- Hardware required:no。

### Verification

- `DEC-NAV-001`:空值/散文 fixture 从误读改省略（正对照:合法续行列表
  仍解析）;cursor 损坏 fixture exit 20（对照:健康路径 exit 10/0 不变）;
  假 correction fixture 消除（open PR 任务翻 blocked 后 cursor 字段
  保持）;corrections 在 reconcile 轮 detail 可见;直跑
  test_discovery_contract 与模块跑计数相等;全仓解析清点报告入
  evidence。

### Readiness r1（2026-07-27）

**Audit base** = `ecd5320b35308ddd44f67fb6a825a9c5f9e3fc1b`。

**开工基线声明（Ordering 义务,非 drift gate)**

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

**授权面扩充（r1 新增两文件,理由为实测）**

r1 把 `test_navigation_contract.py` 与 `test_support.py` 纳入 Allowed
paths。理由不是预防性放宽,而是干跑结论:把 `TASK-DEC` 根加入
`NEVER_CLAIM_ROOTS` 后,全套件**恰一条断言反应** =
`test_navigation_contract.NeverClaimRootsArePinnedByContent.
test_the_exact_root_set`（它以精确内容集钉死该表,正是应当反应的那条;
同文件 `test_each_root_and_its_suffixed_siblings_are_excluded` 也逐根
枚举）。该文件**不在原 Allowed paths 内**,不扩充则本任务必然越界,
只能事后走 remediation（#303 同型先例）。`test_support.py` 是 NAV-002
引入的 active-or-archive 共享 helper,discovery 解析改动可能波及,一并
纳入。**扩充仅此两文件;其余 host_loop 测试仍属 DEC-005/006/008 分区。**

**顺序前置(本任务最重要的产出)**

`NEVER_CLAIM_ROOTS` 现为 `{TASK-HLR-003, TASK-NAV-001, TASK-NAV-002}`,
`is_never_claim("TASK-DEC-003")` **实测 False**;`--explain` 对 ready 的
DEC 任务打出 `one Decision-Grade line from claimable`。**本任务的实现
PR 必须把八个 `TASK-DEC-00N` 根加入该表,且这应是最先落地的一项**;
在其合入 main 前,任何 TASK-DEC 的 `Decision-Grade` 行都会使活循环可
认领本 change 明确声明为会话实现的任务。DEC-005/DEC-007 尤甚——它们
改写的正是"决定循环能认领什么"的代码,恰为 worker.py 注释所述禁忌。

**C-H1 的修复契约（由实测语料定义,非自由裁量）**

现仓 13 份活跃 tasks.md 中,空值 `- Depends on:`/`- Allowed paths:` 共
**34 处,全部为同一种合法形态**:空值行之后紧跟缩进的反引号列表项
（分类实测:continuation-with-backticks 34 / continuation-plain 0 /
immediately-next-bullet 0）。因此:

- **不得**用"空值即省略任务"的简化修复——那会一次性使 34 处合法声明
  变为不可判定。
- 正确形态 = **区分"缩进列表续行"与"散文"**:前者继续解析出非空值,
  后者 fail-closed（既不产生依赖,也不产生 allowed_paths）。
- **验收门**:实现后对现仓逐一复算,**34 处必须全部仍解析出非空值**
  （清点表入 evidence,含每处 change/行号/解析结果）;同时散文 fixture
  必须产出空集而非散文 token。任一合法处退化即整轮作废。

**干跑实测（变异门依据）**

- `TASK-DEC` 根加入 `NEVER_CLAIM_ROOTS`:**恰 1 条断言反应**（上文那条
  内容集测试）,零行为失败 = 零构造点。
- C-H2（`CursorError`/`ReconcileRequired` 由 `EXIT_ERROR` 改
  `EXIT_RECONCILE`）:**零断言反应**（536 OK + 1 xf 不变）→ 该性质现
  套件零覆盖,必须新增测试并配变异门。
- C-H1 探测脚手架:零断言反应 → 同上,现套件不覆盖空值/散文区分。

**Pass/fail boundary**

1. 每个修复配「撤销即变红」的测试 + 正对照,逐项覆盖
   C-H1/C-H2/C-M4/C-M5/C-M6/C-M8a/C-L11 与 never-claim 扩充。
2. **never-claim 扩充以精确内容集断言**（更新 `test_the_exact_root_set`
   为新的 11 根集合;`len()` 型断言不作数）,并加"每个 DEC 根及其后缀
   兄弟被排除"的枚举对照。
3. **C-H1 的 34 处合法语料全部保持解析**（清点表入 evidence）。
4. C-H2 后:cursor 损坏路径 exit **20**;健康路径 exit 0/10 语义不变
   （正对照）;`BackendError`/`TransportError`/`LeaseError` 仍 exit 1。
5. `test_discovery_contract.py` 的 `unittest.main()` 移至文件尾后,
   **直跑与 `-m unittest` 计数相等**（现为 19 vs 34）。
6. 全套件 **≥536 OK + 1 expected failure**;`check-sdd` 保持 0/0/111;
   `--explain` 在实现后对全部 DEC 任务报 never-claim 而非 grade 缺失。
7. **NAV-001 已交付语义零回归**:全仓扫描、idle 判词、UTC 时间戳的既有
   契约测试保持绿,不得为本任务的改动放宽。

**Risk acceptance（首次）**：discovery 收紧会改变解析结果的可见性。已
接受,因为 34 处语料的保持是硬门,散文捕获归零是目的。两 left-running
unit **零动作**,行为经运行机 checkout 前进生效。回退 = revert。

**Stop conditions**：34 处语料任一退化;never-claim 扩充后 `--explain`
仍显示任何 DEC 任务可被 grade 解锁;需要触碰扩充后 Allowed paths 之外
的文件（尤其 `transport.py`/`lease.py`/`backends.py` 归 DEC-005、
`reviewer.py` 等归 DEC-006、`test_minter_and_explain.py` 归 DEC-008——
后者虽引用 `NEVER_CLAIM_ROOTS` 但干跑零反应,若实现时它变红即停并在
r2 显式扩权）。

**不授权**：`DISPATCHABLE_GRADES` 与 GATED 语义;never-claim 政策本体
（仅扩本 change 自己的八根）;Phase 4 cursor 写;explain 双实现合并
（台账 noted）;`Decision-Grade` 代写。

## TASK-DEC-008 — minter 脚本修复与部署副本重装（D2 窗口）

- Status:ready（r1 implementation readiness,**仅授权 source PR**;前置①
  approval 已合 = #598 `cac07003836889881994367bde7ba3e0bdca70c0`,前置②
  即本 readiness。**前置③ D2 重装窗口未排期,故本 r1 不授权任何重装/
  系统写入**;窗口与 done 的授权载体是后续 r2。见下方「Readiness r1」节。）
- Platform:macos（host-only;root 部署副本人工重装）
- Requirements/AC:change-local `DEC-MINT-001`
- Depends on:none（文件与全部其他任务零交集）
- In scope:台账 D-M4（cleanup trap 覆盖 staged/staged_meta，变量预
  初始化）、D-M5（sidecar 新鲜度 root 属主 600，去 644 放宽）、低成本
  卫生（--pem 属主/权限断言、curl 错误可见性、尾随空值 flag 报错）;
  test_minter_and_explain 对应契约收紧（替换「含数字 2」类弱断言）;
  重装窗口 crib 与 receipt 模板。
- Out of scope:JWT 构造/铸造语义、App/installation id、launchd plist、
  token 文件路径。
- Allowed paths:`scripts/host_loop/mint_installation_token.sh`、`scripts/host_loop/test_minter_and_explain.py`、本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`scripts/host_loop/*.py`（explain 面读不写）、
  `/Library/**`（重装 = 维护者窗口动作，Agent 零系统写）、`.github/**`、
  产品 source/tests、其他 change。
- Risk:med（root 执行面脚本;合入即部署副本 digest 失配，重装前旧副本
  继续按旧字节运行——readiness 须钉「合入→重装」窗口间隔的接受声明;
  回退 = 按旧 digest 重装）。
- Hardware required:no（需维护者本机 root 窗口，非设备硬件）。

### Verification

- `DEC-MINT-001`:staged 阶段注入失败的 fixture 证明 trap 清理（正对照:
  成功路径产物齐全）;sidecar 属主/权限断言测试;弱断言替换后套件绿;
  窗口 receipt:重装前后双 digest、minter 干跑 exit 语义不变、token
  权限 600 复核。

### Readiness r1（2026-07-27）— source-only

**Audit base** = `005e1ffc321b2dbc87409895ac28c290b93f7e24`。

**开工基线声明（Ordering 义务,非 drift gate)**

```yaml pins
- path: scripts/host_loop/mint_installation_token.sh
  blob: 4150401c5f875ac282d38d6f70eb4c0c35f97689
  sha256: 5b8cbc06e7246c83c273f37dd78b07c2eca1e91b541cc88532c9f3c6f5cd9671
- path: scripts/host_loop/test_minter_and_explain.py
  blob: cc1e8a8aa3d7df0262f41cf44735275c2248b6c9
```

上表的 `sha256` **同时是部署副本的当前 digest 与回滚目标**:
`/Library/PrivilegedHelperTools/com.arkdeck.host-loop.mint.sh` 现装的正是
这份字节（TASK-HLR-003 D2 窗口安装,`5b8cbc06…`）。

**授权边界（r1 的核心限制）**

本 r1 **只授权一个 source PR**。**不授权**:任何 `/Library/**` 写入、
任何 `sudo`、任何 launchd 动作、任何对运行中 unit 的触碰、以及本任务的
`done` 翻转。Agent 对系统面零写入,重装是维护者亲手动作。

**合入→重装的间隔必须显式接受**：source PR 合入后,仓内字节与部署副本
**立即 digest 失配**,而部署副本继续按旧字节运行。已接受,理由:①旧字节
是当前 live 且已验证的形态,失配期内行为不退化;②脚本自身的 digest 自检
比对的是"安装时 vs protected main 的 exact OID",失配只表现为下次重装
时的比对基准前移,不影响运行;③本轮修复（trap 覆盖、sidecar 权限）都是
故障路径与权限收紧,不改铸造语义。**失配期内若需回滚,回滚目标 =
`5b8cbc06e7246c83c273f37dd78b07c2eca1e91b541cc88532c9f3c6f5cd9671`
（即不动部署副本,仅 revert 仓内 source PR）。**

**Pass/fail boundary（r1 可验收部分）**

1. **trap 覆盖以注入式 fixture 证明**:在 `chmod`/`chown`/`mv` 阶段注入
   失败,断言 `$OUT_DIR` 内**零 `.mint.*` 残留**;正对照 = 成功路径产物
   齐全且权限正确。变异门:撤销 trap 修复该 fixture 必红。
2. **sidecar 收紧**:新鲜度状态改 root 属主 600,配属主/权限断言测试;
   须同时证明**非特权账户无法再改写 root 的重铸判据**。
3. **弱断言替换**:`test_a_failed_mint_exits_two_and_says_the_token_is_
   untouched` 的 `assertIn("2", ...)` 型断言（对任何含数字 2 的脚本恒真）
   与 `test_every_external_command_is_a_root_owned_absolute_tool`
   （实际只断言 `PATH=` 行存在）必须换成可区分的断言;替换后若变红,
   修脚本而非放宽断言。
4. **JWT 不入 argv 的性质必须保持**:`printf` 为 `/bin/sh` builtin 且经
   `curl --config -` 由 stdin 供给——修改后重新验证该性质,写入 evidence。
5. 脚本保持**单文件、`/bin/sh`、零仓内 import**（既有
   `test_minter_and_explain.py:209-213` 契约不得放宽）;`set -eu`、
   `umask 077`、`PATH` 钉死均保持。
6. 全套件 **≥536 OK + 1 expected failure**;`check-sdd` 保持 0/0/111。

**Risk acceptance（首次）**：修改 root 执行面的脚本源。已接受,因为 r1
的产物只是仓内字节,不进入任何执行路径,直到维护者在独立 D2 窗口亲手
重装;失配期风险如上分析。

**Stop conditions**：任何需要 `sudo`/系统写入的步骤;JWT-not-in-argv
性质无法保持;既有单文件/无 import 契约需要放宽;需要触碰 plist、token
路径或 App/installation id。

**r2 的触发条件（窗口授权,尚未给出）**：维护者排定 D2 窗口时另开
readiness r2,内容须含:重装步骤逐条、新 digest、回滚 digest
（`5b8cbc06…`）、窗口前后的双面 read-back 判据、以及 done 的二值条件。
**在 r2 合入前,本任务不得 done。**
