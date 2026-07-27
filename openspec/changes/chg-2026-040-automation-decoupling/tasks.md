# CHG-2026-040 Tasks

> 八任务全部改动自动化自身代码/测试/CI 面，照 TASK-HLR-003 与 NAV 先例
> 均为 never-claim（会话实现、维护者合并;`NEVER_CLAIM_ROOTS` 的
> `TASK-DEC` 根由 TASK-DEC-005 落码）。`Decision-Grade` 行由维护者亲笔
> （#577 先例），本文件不代写。修复对象的行号引用见 review-findings.md;
> 该台账的行号在 audit base 上采集，各任务 readiness 时按当时 main 重钉
> exact blob。

## TASK-DEC-001 — 敏感路径配置抽取与框架/产品边界文档

- Status:blocked（前置：① 本 change approval-only PR merge;②
  TASK-NAV-002 done——同文件 check_pr_paths.py/test_check_pr_paths.py，
  避免与 archive-glob 实现冲突;③ 独立 readiness PR 钉受改文件 exact
  blob 与配置 schema。）
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

- Status:blocked（前置：① approval merge;② 独立 readiness 钉四文件与
  测试 exact blob、verdict 新契约文本、历史 body 兼容清单。）
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

- `DEC-REV-001`:尾部引用 VERDICT fixture 不再翻转（旧钉测试已反转;
  变异门：撤销修复该 fixture 必绿=红检测）;(number,head) 去重双 fixture
  （同 head 重放拒绝、新 head 重审）;`(#N)` 提及型 fixture 不再假确认/
  假歧义;\s 修复的 phantom header/跨行 id fixture;confirm_merge 零
  引用 grep;历史 PR body 语料（现存 worker PR）解析回归绿。

## TASK-DEC-007 — worker/discovery 解析与观测硬化

- Status:blocked（前置：① approval merge;② TASK-NAV-001 done（同文件
  worker.py/__main__.py）;③ 独立 readiness 按 NAV-001 合入后的 main 重
  钉 exact blob 与逐项契约。）
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
- Allowed paths:`scripts/host_loop/__main__.py`、`scripts/host_loop/worker.py`、`scripts/host_loop/cursor.py`、`scripts/host_loop/test_discovery_contract.py`、`scripts/host_loop/test_worker_cursor.py`、`scripts/host_loop/test_cursor_contract.py`、`scripts/host_loop/test_check_verdict_contract.py`、本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）
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

## TASK-DEC-008 — minter 脚本修复与部署副本重装（D2 窗口）

- Status:blocked（前置：① approval merge;② 独立 readiness 钉脚本
  exact blob、重装步骤与回滚 digest;③ 维护者 D2 窗口排期——窗口未开
  实现 PR 可先行，重装与 done 须窗口 receipt。）
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
