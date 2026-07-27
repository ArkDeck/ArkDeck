# CHG-2026-040 体检台账（review-findings）

> 本文件是 CHG-2026-040 各任务的事实源。审查覆盖全部自动化生产脚本，
> 分五簇独立进行（check_sdd / check_pr_paths+workflows / host_loop worker /
> host_loop transport / host_loop reviewer）。每条 HIGH 均以构造性 fixture、
> 真实 git（2.55）或双 HTTP 服务器实测复现并在起草会话独立重跑坐实，非
> 目测。行号在 audit base（propose 时 origin/main = #594 `87e1428`，
> transport 簇部分行号取 #593/#594 后）采集;各任务 readiness 时按当时
> main 重钉 exact blob。ID 前缀:A=check_sdd,B=check_pr_paths/workflows,
> C=worker/discovery,D=transport/lease/backends/minter,E=reviewer/envelope/
> recovery。

## Readiness 勘察实测（2026-07-27,audit base `cac07003836889881994367bde7ba3e0bdca70c0`）

approval（#598 `cac07003…`,lvye APPROVED,mergedBy lvye）合入后、四个无
前置任务 readiness 起草前做的采集。三项结果改变了后续 readiness 的门形态,
故记入正本:

1. **基线**:host_loop `-m unittest discover` = **536 OK + 1 expected
   failure**;`check-sdd` = **0 error / 0 warning / 111 acceptance IDs**;
   活跃 `chg-*/tasks.md` = 13 份。
2. **DEC-003 存量清点 = 零违规**（在 audit base 上以收紧版逐检查复算）:
   逐任务 Status 配对不等于 1 → 0;宽正则匹配而严正则不匹配（`readyish`
   族）→ 0;全角冒号 Status 行 → 0;需跨任务边界吸收才成立的 scope 认领
   → 0;解析为 None 的治理文件 → 0;重复 capability id → 0;`changes/`
   下游离条目 → 0。**推论:A-H1/H2/M1/M2/M3/L5 的收紧完全落在 DEC-003
   自己的 allowed paths 内,不需要改任何 openspec 内容,不触发
   「存量修正超出授权即停」的停机制**。
3. **三个最小修复的干跑变异 = 各零断言反应**（D-H2 refname 等值+单行、
   D-H3 `_advance` owner_run 校验、E-H1 verdict 末行契约;各自单独施加后
   全套件均 536 OK + 1 xf）。**这不是"无事发生",而是双重事实**:
   (a) 零构造点——修复不依赖任何既有断言的具体形状;(b) **这三条性质
   在现套件中零覆盖**。故三者的 readiness 必须把「新增测试 + 撤销修复
   该测试必红」的变异门写成硬条件:没有会因 revert 变红的测试,修复等于
   没修。E-H1 的连带更正见下方 E 簇条目。

## 总体质量判断

三个新代设计面工程质量高、fail-closed 纪律好，本仓历史反复烧过的缺陷类
（bool-as-int 在校验器、`\s*` 跨行在标量字段、len() 钉 allowlist、管道吞
退出码）在核心路径均已修正。残余缺陷几乎是同一形状：**一条控制在注释或
测试里被声明，但代码路径上并未真正承载它**。守卫授予工作的门（claim
gates）全程 fail-closed，没有发现「授予执行权」方向的 fail-open;残余风险
集中在信任边界取值来源、观测/审计真话、以及随 NAV 全仓扫描上线的解析
语义。

---

## A — check_sdd 簇

- **A-H1**（check_sdd.py:376-387 `requirements_ac_claim_surfaces`）scope
  认领面在 `- Requirements/AC:` bullet 后扫描到下一个 `- ` 开头行为止，
  期间非 bullet 行（标题/空行/散文）不终止 surface，任何缩进行被并入 →
  出现在**后续 `## TASK-` 标题下**缩进散文里的 AC 被算作已认领。实测
  fixture 0 error（应 1）。假 PASS，弱化治理最依赖的检查。
- **A-H2**（check_sdd.py:418-419）scope.yaml 解析为 None（空文件/纯注释/
  字面 null）时 `if data is None: continue` 静默跳过整个 scope 检查;
  `load_yaml` 对 null 不记 error（只捕解析异常）。实测纯注释 scope.yaml
  → 0 error。同族 **A-M3**:capability-registry（:220-221）、两 lock
  （:550-551）、core-conformance（:561）均 `if not data: skip` fail-open。
- **A-H3**（sdd-guard.yml:31-34 只跑 check-sdd.sh;agent-pr.yml 只跑
  test_check_pr_paths）test_check_sdd.py（19 测试）与 host_loop 全套件
  未接入任何 workflow。grep 零命中复验。
- **A-M1**（check_sdd.py:284-293 + :254）状态行只做总数对账（task_count
  vs status_count），一任务两 Status 行可补另一任务零行 → 假绿;且
  `TASK_STATUS_RE` 无尾边界 + prefix `.match`，`- Status:readyish` 实测
  匹配。
- **A-M2**（check_sdd.py:222）`{c.get("id"): c for c in ...}` 使重复
  capability id 静默 last-wins（首项 release/requires 不校验，1:1 集合
  比较看不见重复）。实测 len 1、留 bogus。
- **A-M4** present-but-null 字段族崩 traceback（截断后续检查）:cases:null
  （:187）、profiles/catalogs:null（:552）、capabilities/requires:null
  （:222/:229）、safety_coverage:null（:570）、front matter 非 mapping
  （:276 `fm.get` on str）、缺 acceptance_id 致 sorted 混型（:209-213）、
  缺 acceptance-index.txt 裸 FileNotFoundError（:174-176）。退出码仍
  非零（fail-closed）但报告在崩点截断。
- **A-M5**（sdd-guard.yml:6-12）非 agent/** 分支 PR 的 opened/synchronize
  不触发 guard;靠 required-check 缺席 fail-closed 兜底 + push-to-main
  事后跑。记文档级（若确认 branch protection 按名要求这些 check 则
  降 LOW）。
- **A-L1/L2** `[::]` = 两个 ASCII 冒号（意图的全角容忍不存在;与
  check_pr_paths 的 `[:：]` 不一致，全角冒号 Status 行会误报）;
  :288 `line.replace("(", " (")` 实测 no-op 死代码。
- **A-L5** `glob("chg-*")` 大小写敏感 + changes/ 下非 chg-*/archive/
  README 条目零校验。
- **正面**:revision 用 `type(value) is int`（bool 正确排除）;无 `\s*`
  跨行分隔符;check-sdd.sh `set -eu`、无管道、`exec` 传播退出码;
  revision/pins 对缺失/畸形载体 fail-closed;scope allowlist 测试钉
  精确内容非 len()。

## B — check_pr_paths / workflows 簇

- **B-H1**（check_pr_paths.py:602 → :268-281 glob 工作树;agent-pr.yml:113
  checkout github.sha）授权用的任务定义取自**被审 head 树**——同一
  commit 既被审又供给判它的 allowlist。实测:一个 commit 把 tasks.md 的
  Allowed paths 改成 `**` 并同时加 scripts/、.github/ 文件 → PASS。
  base 侧读取器 `load_task_definitions_at_commit`（:336）已存在，但仅
  在 head 缺任务时作回退。
- **B-H2**（agent-pr.yml:122/:156 从 head checkout 跑校验器本身）
  Allowed paths 含 `scripts/**` 的任务可在同 PR 改校验器与其测试，
  再由被改校验器判自己 → 自签环。架构级观察（本 change DEC-004 只做
  低成本缓解或显式记录，结构重构待独立立项）。
- **B-H3**（check_pr_paths.py:379-400）Allowed paths 块延伸到下一个
  `- `/`## ` 行，块内**每个**反引号 token 变 glob。实测合成:块内散文
  「mirrors the layout under `scripts/**` and `Packages/**`」→ patterns
  含 scripts/**、Packages/**。活体:现仓 22 处非路径 token 已在生产
  allowlist（commit SHA、Swift 符号、裸词——均惰性）;chg-2026-025
  tasks.md:304「`Packages/**` forbidden」按现解析是 **allowed**（该任务
  当前因「multiple Allowed paths lines」另故 fail-closed，去一行即武装）。
  终止符弱:`* ` bullet、tab 缩进 `- `、`### ` 标题不断块。
- **B-H4**（check_pr_paths.py:716-719）`--event` 模式只调
  load_pull_request_context（校验形状非身份），base/author/repo/state
  全不校验;base_oid 直入 `git_changed_paths` 两点 diff 不校验祖先。
  实测:base.sha 指向越界 commit 与 head 之间的旁支 → 越界文件从 diff
  消失 → PASS。消费者 sdd-guard.yml:55 的 pull_request 触发含 edited，
  而改 base 分支即触发 edited。（agent-pr.yml 钉了 --expected-base-ref
  故较安全，但 base.sha 本身仍不被校验。）
- **B-M1**（check_pr_paths.py:404 fnmatch.fnmatchcase）`*` 跨 `/`:
  实测 `Packages/ArkDeckKit/Sources/*.swift` 匹配深层嵌套。全仓每个
  单星声明被静默放宽为递归;test_agent_pr_workflow.py:299 的 `_glob_regex`
  却实现正确非跨越语义 → 两 glob 引擎分歧。
- **B-M2**（check_pr_paths.py:24 `\s*`）Task 行分隔符跨行:实测
  `"Task:\nTASK-EVIL-002\n"` 绑定;body 声明优先级高于标题。
- **B-M3**（check_pr_paths.py:23 + :216-220）homoglyph 标题 token（U+2011
  非断连字符）令 `TASK_TOKEN_RE.findall(title)==[]`，歧义检查看不见 →
  标题显示一任务、门执行另一任务 allowlist。
- **B-M4**（check_pr_paths.py:35-41 fnmatchcase）SENSITIVE 大小写敏感 +
  漏根配置:实测 Scripts/、.GitHub/、Package.swift、Package.resolved、
  .gitignore、AGENTS.md、CLAUDE.md、openspec/changes/chg-x/tasks.md 均
  非敏感 → task-less PR 可自由改（含任意任务的 Allowed paths，链入
  B-H1）。
- **B-M5**（swift-ci.yml:43）`git diff | grep -qE` 无 pipefail，diff
  失败 → 空输出 → grep 返 1 → else 置 swift=false → 全套件跳过报绿。
  与 :40 注释「fail closed:跑全量」相反。**产品 CI，记维护者裁量**。
- **B-M6**（agent-pr.yml 无 concurrency）两快速 push 两 open-pr job 可
  都见 none 都 gh pr create;list（:43）与 create（:58）间 TOCTOU 未护。
- **B-M7**（check_pr_paths.py:33）`本\s+change` 才触发 change-relative;
  裸「本 `tasks.md`」→ REPO-ROOT。chg-2026-008 tasks.md 有 8 处裸本;
  方向 fail-closed 但依赖 `\s+` 跨行的意外解析。
- **B-M8**（check_pr_paths.py:728）`--identity-only` 打印
  `expected_number`（即入参），agent-pr.yml:99-102 与自己入参比 → 恒
  真死守卫（真校验在 :183，此处只是假保证非漏洞）。
- **B-dead**:parse_task_definitions 的 repo_root 参数（:239）无引用;
  --pull-list 分支不用 --repo-root;CheckResult.allowed_patterns 无
  非测试消费者;FULL_TASK_RE 锚点惰性;test_agent_pr_workflow.py:24 是
  **第三套** task-id 文法（token parity 测试不知其存在）。
- **B-workflow 卫生**:action 按 tag 非 SHA pin（rockchip-component 全
  SHA pin 反成对照）;`set -eu` 缺 pipefail;test_agent_pr_workflow 的
  forbidden-capability 扫描不覆盖 rockchip-component.yml。**多属产品
  CI，记维护者裁量**。
- **正面**:_positive_integer（:135）排 bool;backslash 非重写（:585-589）
  刻意且有测试;archive 原子性校验器（:473-577）详尽;agent-pr.yml
  permissions:{} + 逐 job 收窄、无 pull_request_target、无 secret。

## C — worker / discovery 簇

- **C-H1**（__main__.py:90-91 `_DEPENDS_RE`/`_ALLOWED_RE` 用
  `^-\s*...:\s*(.+?)(?=^-\s|\Z)` MULTILINE|DOTALL;:166-170）空值
  `- Depends on:` → deps=()（读作「声明无依赖」，依赖门形同虚设）;
  空值 `- Allowed paths:` 后接含反引号散文 → 散文 token 成 allowed_paths
  （满足 worker.py:141-142 claim 门）;bullet 间散文捐 task id 成伪依赖;
  `^-\s*` 跨行。起草会话在 propose base（#594 后）实测仍复现
  （deps=()、allowed=('some/other/**',)）。**随 NAV-001 全仓扫描已上线**;
  合法多行续行格式（chg-2026-006 tasks.md:27）也存在，故缺陷精确在于
  「解析器分不清续行列表与散文」。
- **C-H2**（__main__.py:381 `_load_cursor` 在 try 内;:397-400 catch
  CursorError → EXIT_ERROR=1）cursor.py:7-8/:185-191 契约说损坏/缺失/
  冲突应 reconcile-required(20);同一 CursorError 若在 run_once 内抛
  （worker.py:307-310）映射 20，早 15 行在 load 抛却映射 1。调度器把 1
  当瞬时重试、20 当停机看人 → 恰在损坏这一人工必看的 case 误导。
- **C-H3**（test_discovery_contract.py:340-341）`unittest.main()` 位于
  文件中部，其后 4 个测试类（FieldsDoNotReachAcrossLines、
  DependenciesAreDeclaredNotAssumed、CodeFencesCannotMintTasks、
  TruthIsNeverBuiltFromAnIncompleteObservation——恰是 fail-open 回归类）
  按 shebang 直跑不执行。实测:直跑 Ran 19、`-m unittest` Ran 34。
- **C-M4**（__main__.py:223,242-249）build_truth 的 open_pr_numbers 只
  由**当前 ready** 任务的 head 构建;cursor.py:151-154 当作全集清 →
  对已翻 blocked/done 但 PR 仍 open 的任务记假 correction「pr_number N
  is not open; cleared」。自愈(cursor 非权威)故 MED，但唯一补偿控制
  （corrections 日志）记了假话;讽刺:同函数 lease 半侧拒绝构建不完整
  视图（:230-236）。
- **C-M5**（worker.py:294-310）self._corrections（:334）只在干净返回路径
  （:302-305）并入 detail;两个 except 只用 str(error) → reconcile-required
  轮（操作者实际读的轮）corrections 消失，而 cursor 可能已 mid-round
  持久化 → 写发生、解释丢失。
- **C-M6**（__main__.py:283-290 `_int_env` catch ValueError→None）
  ARKDECK_HOST_LOOP_CURSOR_ISSUE 拼错 → _load_cursor(None) 造内存
  cursor、_persist_cursor 跳过所有写 → 无载入、无校验、无持久化、无
  诊断，退出码与健康运行不可分。审计/导航面 fail-open。
- **C-M7** 两套 tasks.md 解析器已在真实文件分歧:__main__.py:90-91 只
  ASCII，check_pr_paths.py:29-32 收 `[:：]` + 限定词。全角冒号 fixture
  在 discovery 解析为零候选（任务被省略）而 check_pr_paths 接受;现仓
  8+ 处此类行（chg-2026-008:321,518,607;024:14;025:303,480,646,732）。
  **NAV 全仓扫描后这些任务对循环永久不可见而 CI 认为合法** = 静默
  wedge。task-id 文法三重（__main__.py:56、内联:168、check_pr_paths:23-26）。
- **C-M8**（worker.py:370-372 adopt/renew 不带 pr_number/pr_head 而
  record_round 替换全部导航字段 cursor.py:259-263）稳态每轮双 PATCH，
  首写把 pr_number:null 盖到真 open PR 直到轮末恢复;(b) _cursor_body
  轮首捕获后 store 不刷新（worker.py:205,524-527）。
- **C-L9** bool-as-int 残余:__main__.py:246、transport.py:213,218。
- **C-L11**（__main__.py:437-440）`_change_is_approved` 的 `status:` 后
  `(\S+)` 遇 `approved（注）`/`approved#x` 截断 → 静默不可批（fail-closed）;
  大小写敏感 + 前 40 行启发。
- **C-dead**:Worker.explain（worker.py:212-230）生产死 + __main__._explain
  重实现同契约（reason 子串 "decision grade" 分支）;
  cursor.rebuild_and_validate 测试专用且 docstring 假;WorkerState
  DISCOVER/LEASE_HELD/BRANCH_PREPARED 无产出;section-split 在
  discover_candidates 与 done_task_ids 重复;build_truth 手写
  `agent/host-loop/tasks/{task}`（:243）而非 lease.task_branch()。
- **C-测试替身**:FakeApi（test_fault_matrix.py:108-169）无 GET issue
  路由;pull() 缺 merged/auto_merge/merge_commit_sha/html_url（真 API
  必发、confirm_created_pull identity.py:126-129 守之）;check_runs
  缺 id（dedup 守卫 transport.py:469-476 见不到真实数据）。total_count
  已修。test_worker_cursor.py:211-221 把 __call__ 设实例属性（Python 在
  类型上解析 → serve 从不调用，靠 fallback {} 巧合触发同 state 检查）。

## D — transport / lease / backends / minter 簇

- **D-H1**（backends.py:196-216 UrllibSender）urllib 默认跟随 301/302/303，
  GET/POST 透明跟随、Authorization: Bearer <installation token> 重放到
  目标、ApiPort 只见最终 200;assert_route_allowed 只跑原 path。实测
  （双本地 HTTP 服务）:list_check_runs 可由非 api.github.com 主机供全套
  green 视图;SUCCESS_STATUSES 3xx 守卫（:240-244）对 GET/POST 不可达
  （仅 PATCH 触发，urllib 不重定向 PATCH）。GitHub 改名仓库答 301 =
  非纯对抗。另 :197 `path.startswith("http")` 绝对 URL 逃逸口。
- **D-H2**（transport.py:500-512 RefPort.read）`git ls-remote <remote>
  <pattern>` 按 `/` 边界尾匹配，非精确名;read 取 split("\n")[0]，只验
  40-hex，**不验 first[1]==ref**，且丢弃多余匹配行。实测（真 git 2.55）:
  refs/backup/…/leases/TASK-DEMO-001 排序在前 → 影子 OID 顶替真 lease。
  若影子钉旧 lease commit（mirror/backup/残留副本持有），parse 通过、
  assert_still_held 比冻结影子 OID → **另一 worker 已接管后门仍放行**
  = 双主并写。同型一行在 __main__.py 的 observed_main（split()[0]
  跨多行取首 token）→ 任何尾为 refs/heads/main 的 ref 顶替受保护 main。
- **D-H3**（lease.py:238-300 _advance）无条件 `owner_run=self._owner_run`
  （:286），从不校验 held.record.owner_run==self._owner_run;HeldLease
  是公开可构造 dataclass，observe() 正好给出构造所需 (record, ref_oid)。
  实测:B observe A 的未过期租约 → takeover 得 FenceLost（文档控制有效）
  但 renew(HeldLease(...)) 直接偷成 owner=B fence=2，绕过 takeover 全部
  前置（过期检查、pr_identity_requeried）。test_fault_matrix.py:489 已
  这样构造 HeldLease，形态在仓内。
- **D-M1**（backends.py:283-287）minter 的
  `POST /app/installations/{id}/access_tokens` 直建 raw UrllibSender
  调用，不过 assert_route_allowed、不入 route_log、route_inventory/
  forbidden_capability_count 不可见 → transport.py:8-11「每次外呼都来自
  冻结正向 allowlist、无逃逸口」实际是 8 pin + 1 unpin。
- **D-M2**（backends.py:251-308）Python minter（mint_installation_token +
  _openssl_sign）**零生产调用**，且 _openssl_sign 跑
  `sudo openssl dgst -sign`（需 NOPASSWD openssl = 该账户 root 等价升级
  = openssl 可 root 读写任意文件）;shell minter 头（:8-12）明说这是被
  拒绝的设计。留在安全模块 + 被测试钉形态（test_backends_cli.py:274-280）
  = 邀请复采。
- **D-M3**（backends.py:89-107 `env=dict(os.environ)`;:123-126,:168-169
  无硬化）全环境转发 git 子进程。实测:GIT_CONFIG_COUNT/KEY/VALUE 注入
  core.sshCommand → 下次 lease 写（Deploy-Key over SSH）任意命令执行;
  GIT_CONFIG_NOSYSTEM setdefault 可被预置 0 覆盖;token env 形式下
  token 入每个 git 子进程环境块。线上仅靠 plist 钉五变量兜底，代码无
  自防。
- **D-M4**（mint_installation_token.sh:109-112 vs :143-166）cleanup 只删
  response/status_file;$staged（含明文 token）/$staged_meta 在其后建、
  不在 trap;`set -e` 下 chmod/chown/mv 失败静默 abort 留 .mint.XXXXXX
  含 token 在 OUT_DIR。
- **D-M5**（mint_installation_token.sh:82-89,:164-166）sidecar 写 644 +
  chown OWNER，root 从中 parse expires_at_epoch 决定是否重铸 → root
  分支于非特权可写输入:loop 账户可钉 expires 远期永久抑制刷新（lane
  wedge fail-closed 但静默）或清零逼每次铸（App 限流）。
- **D-M6**（transport.py:227-228）HTTP 403 归类为 clean Refused;GitHub
  二级限流/滥用检测返 403（429 已正确处理:229）→ 瞬时限流记为确定
  凭据/权限拒绝。fail-closed 但误标因，需 sender 暴露限流头。
- **D-M7**（transport.py:213,219）bound_to_pull/bound_to_issue 的
  isinstance(x,int) 不排 bool;实测 bound_to_pull(True) → owned_pull==1、
  update_pull(True) PATCH /pulls/1。当前不可达（number 来自 int()）故
  latent 复发。
- **D-M8**（backends.py:162-167）commit_writer 用 env.setdefault → 继承的
  GIT_AUTHOR/COMMITTER 胜出，注释断言相反。应赋值非 setdefault。
- **D-M9**（lease.py:359-383）assert_still_held 无最小剩余 TTL 余量:
  接受剩 1 秒的租约后调用方做无界外部写（60s HTTP 超时）→ 门过后写可
  落在他 worker 合法接管之后。
- **D-dead**:lease.py:289-290 `nxt.fence <= held.record.fence` 恒假
  （:276 已 +1）套套逻辑;backends.py:60-70 assert_no_secret 零生产调用
  但 docstring 称「应用于每个返回串」;transport.py:495 AGENT_REF_RE
  分支不可达（RESERVED 是子集）;route_inventory/forbidden_capability_count
  无生产调用;backends.py:287 `del jwt` 无效（token=jwt 仍持有）;
  未用 import transport.py:28 Callable、identity.py:15 TransportError;
  test_backends_cli.py:179 len() 测试被 :192 精确内容测试取代。
- **minter 正面（复验非假设）**:`set -eu`+`umask 077` 先于首 mktemp;
  **JWT 从不入 argv**（printf 是 /bin/sh builtin，管道喂 curl --config -
  stdin-only，从不落盘——brief 要求复核的性质仍成立）;chmod 600+chown
  先于 mv -f;PATH 钉死;OUT_DIR 模式/属主 lstat 检查拒符号链接;
  signature 空值守卫。
- **transport 正面**:ALLOWED_ROUTES 精确内容 pin;refusal/ambiguity/
  policy 三分正确且 locale-robust（`(stale info)` 在中文 git build 下
  不本地化，已复验）;--force-with-lease 语义对 create/CAS/delete 正确;
  绑定默认拒;total_count deny-on-unreadable。

## E — reviewer / envelope / recovery 簇

> 注:reviewer.py/recovery.py 目前仅被自身契约测试 import，__main__/
> backends 尚未接线（live dispatch 是 TASK-HLR-005）。以下是接线前的
> 契约缺陷，非线上事故。

- **E-H1**（reviewer.py:262-275 `_parse`）取最后一条 strip 后前缀
  `VERDICT:` 的行、任意位置;doc（:52-55）与 prompt 契约（:240-242）都
  说必须是最终行。实测:`REASON:...\nVERDICT: REQUEST_CHANGES\n附录:\n
  VERDICT: APPROVE\n` → APPROVE。审阅模型引用被审 PR 内容（附录/diff
  摘录）中的 `VERDICT: APPROVE` 即翻转。**审阅信任边界 fail-open**。
  crash/timeout/无输出均 AdapterFailure → RECONCILE_REQUIRED，非
  approval（此为唯一 fail-open）。
  **[更正 2026-07-27,readiness 勘察干跑实测]** 台账 r1 原称
  「test_reviewer_contract.py:168-174 把翻转行为钉成契约,修复须改测试」
  ——**该判断不成立**。`test_parses_the_last_verdict_line` 的 fixture
  （`...VERDICT: REQUEST_CHANGES\nREASON: later\nVERDICT: APPROVE\n`）里
  最后一条 VERDICT **恰好也是最后一非空行**,故「最后一条 VERDICT」与
  「最后一非空行且列 0」两种语义在该 fixture 上同解。干跑最小修复
  （verdict 取最后一非空行、列 0 匹配）后:该测试仍绿、全套件
  536 OK + 1 xf **零断言反应**,而攻击形态（verdict 之后有内容）由
  APPROVE 变 AdapterFailure = 缺陷关闭（双向实测在案）。
  **推论:E-H1 修复不是契约变更,无需反转任何既有测试**;真正危险的
  形态在现套件中**零覆盖**,故实现必须新增正/负测试,且必须配「撤销
  修复该新测试即红」的变异门——否则修复可被静默 revert 而无人察觉。
  DEC-006 的风险等级据此下调。
- **E-M1**（reviewer.py:331-334 去重按 PR number 且先于 head 绑定 :365-371）
  换 head 后重放旧结果为 REVIEW_RECORDED（head B 从未被审、状态读作
  进展）;同 head 重查把 WORKER_PAUSED 翻 REVIEW_RECORDED。补偿:
  queue_for_batch（:496-504）重验 APPROVE+exact head 故 batch 门不消费
  旧结果，但 lane-state 消费者无此护。修法:键 (number, head_oid)。
- **E-M2**（recovery.py:58-59 `_subject_carries` 用 `in`;:111-128;
  :35 window 500）sha-null 回退子串匹配 `(#N)`:实测 merged=true+
  merge_commit_sha=null 时孤立历史行 `follow-up ... (#42) (#900)` →
  confirmed=True 且 merge_oid=跟进 commit → RELEASE_AND_ADVANCE 于非
  merge commit。常见 case 反向:2 匹配 → 假 ambiguous → STOP（可用性）。
  修法:endswith 锚定（GitHub squash 把 (#N) 置于 subject 末）。
  sha-present 路径（:89-107）是真双源（REST + ancestry + subject over
  git/Deploy-Key），退化仅限回退。
- **E-M3**（pr_envelope.py:312-324 path 分支无空白禁止/路径形状要求;
  backends.py:371 `none — ...` em-dash）path 分支接受任意散文;唯一
  生产渲染器用 em-dash 声明「无 evidence」却路由进 path 分支验证为
  路径。这些 body 经 render_envelope 校验并入历史 PR → 收紧 path 分支
  会追溯性破坏历史 body 解析。修复次序:先修 backends 渲染侧为 `none:`
  （DEC-005），再评估 path 分支收紧（DEC-006）保留历史兼容。
- **E-M4**（pr_envelope.py:44-47 TASK_HEADER_RE `^##\s+`;:52
  FRONTMATTER_ID_RE `id:\s*`）`\s` 跨行（本仓已命名缺陷类复发）。实测:
  `##\nTASK-HLR-001...` 出 phantom header、`id:\nCHG-...` 跨行匹配 →
  validate_envelope 的「task 在 tasks.md 恰一次」可被散文满足或双计。
  修法:`[ \t]`。
- **E-dead**:identity.confirm_merge（identity.py:133-154）生产零调用、
  语义漂移的 recovery.confirm_merged 平行实现（truthy merged 接受
  1/"true"——recovery.py:83-87 拒绝的形态、无 subject 交叉、sha-null
  当终态），仅 test_fault_matrix.py:822-837 喂绿（「两分类器漂移」+
  「测试让死代码显得在岗」双重已知类）;pr_envelope.py:135-136 不可达
  守卫（:133-134 同谓词已过）;ReviewPhase._now 注入死依赖（:285-288）;
  reviewer._GRADES 复制 pr_envelope.DECISION_GRADES;reviewer.py:400
  手拼 `agent/host-loop/tasks/{task}`;TASK_TOKEN_TEXT 双份
  （pr_envelope:42、check_pr_paths:22 今字节相同、仅注释维系）;
  test_v3_hardening.py:459-478 _manager_over 无调用且引用不存在的
  self.PushFailed。
- **E-LOW**:reviewer 子进程无 stdin=DEVNULL（:198 继承父 stdin 可阻塞
  至 1800s）、无输出上限、err 细节丢弃（:255-256 timeout/缺二进制/真
  124 不可分）、recorded_at 恒 0（:259）、digest 字段可嵌换行/管道符
  伪造 Issue 表行（:464-482）、CRLF 楔死（:113 拒 \r，GitHub web 编辑
  存 CRLF → envelope 不可读）、RestartObservation 无类型校验（:156-168
  open_pr_count=True→ADOPT）、merged 形状纪律跨层不一致
  （reviewer:305 `is True` vs recovery:83-87）。
- **正面**:envelope 块外文本结构性不可能成为字段（前 marker 文本拒
  :133-136、后 marker 字段样行留人类文本、块内 marker 靠 exactly-once
  计数 fail-closed——过去 fence bug 不复发）;crash/timeout/无输出永不
  approval;lease CAS force-with-lease 精确 OID 不能接管移动的 fence;
  两源真异道;v3 hardening 套件与现码零漂移（142 测试逐一手对）。

---

## noted-not-tasked（LOW/风格/产品面/架构级——不构成本 change 验收面）

- 产品 CI 观察（维护者裁量）:swift-ci.yml:43 fail-open（B-M5）、三
  workflow action 未按 SHA pin、set -eu 缺 pipefail、rockchip-component
  未纳入 forbidden-capability 扫描、路径过滤 workflow 作 required check
  报 pending 而非 success。
- 架构级（独立立项）:B-H2 校验器自 head checkout 执行的自签环（本
  change DEC-004 只做低成本缓解/记录，根治需重构 agent-pr.yml 从可信
  ref 跑校验器）;两 tasks.md 解析器文法统一（DEC-002 收敛 task 文法
  定义，但两 checker 的冒号/限定词容忍差异是否统一待 DEC-003/004 后
  评估）。
- 风格/观察:A-L1/L3/L4/L6/L7/L8;B-M6 concurrency、B-M7 裸本、B-dead
  第三套文法;C-M8b、C-L9/L10、C-dead 的 explain 双实现（合并是更大
  重构，本 change 只记录）;D-M6 需 sender 暴露头的更大改动按 DEC-005
  内可行则做、否则记录;E-L6 digest 清洗（Phase4 接线前）、CRLF 运维
  注记。
- config.yaml 现被任何脚本零消费（仅 parse-all 扫其 YAML 合法性），其
  class 词表在 check_sdd.py:253 独立硬编码 → 要么给消费者要么记录其
  纯文档定位。本 change 不动（不在自动化脚本行为面）。
