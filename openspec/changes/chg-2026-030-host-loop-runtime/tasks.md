# CHG-2026-030 Tasks

> 本 change 的每个 task 均 host-only，零真实设备/HDC/effect dispatch。proposal PR
> 只含本 change package；批准、readiness、实现/evidence、done、verified 均为独立 PR。
> D2 host/credential 配置与源码 PR 分离；任何判断门未合入前不做门后的成 PR 工作。
> r3 新增 TASK-HLR-002A 划分 `agent/host-loop/**` exclusive creator namespace；
> 该 task done 前 HLR-002 不得 ready，零 identity/secret/scheduler/probe 动作。
> r4 因 #412 首个 pull-request `allowed-paths` 暴露 canonical suffix task grammar
> 不兼容而 fail closed；r4 只扩 HLR-002A 的 parser/test scope，不使其 ready。
> r7 因 CHG-2026-033 approval #455 已把 ref-protection 管理操作收回人类隔离会话，
> 而后合入的 #454 又把 r6 TASK-HLR-002B gateway 标为 ready，故 fail closed：
> #449/r6 gateway 与 #454 readiness 均 superseded，TASK-HLR-002B/002A blocked，
> Agent control-plane/ruleset/ref probe dispatch = 0。HLR-002A fresh readiness
> 依赖 CHG-2026-033 TASK-RPT-001 done/evidence merge OID。
> r9 因 #480 实证 routine `GITHUB_TOKEN` bot-created PR 仍需人工放行
> pull-request workflows，新增 TASK-HLR-001A；其 source/live evidence/done 前，
> r8 HLR-002A canary readiness/UUID 均 superseded，canary/ref dispatch = 0。

## TASK-HLR-001 — 结构化 PR envelope 与纯 runtime contract

- Status:done（2026-07-23 D0 completion；仅在维护者 review/merge 本独立
  `ready→done` PR 后生效。implementation/evidence #401 exact head
  `2472c946a255f8c40ecc5d102fa6341871c97121` 已由 `lvye` APPROVED，并以
  `145d46384251e535a563aa94a142d83860f2a710` 合入 protected `main`；merge
  subject 携 `(#401)`，reviewed head→merge 的六个交付路径 tree diff = 0。
  合入树复验：HLR envelope = 17/17、MECH-004 path contract = 20/20、SDD
  contract = 19/19、`check-sdd` = 0 errors / 0 warnings / 111 acceptance IDs、
  Python compile/diff check = PASS；run =
  `evidence/runs/TASK-HLR-001/run.md`。本 done 只闭合 HLR-001 contract slice，
  不构成 HLR-005 live first-event evidence、HLR-002 D2 readiness、后续任务
  ready 或 change `verified`。）
- Historical Status:r3 `ready`（#400 merge
  `ece39d9d2a94640e56bb0a3bc7b47e5dc8804cc6` 后生效；2026-07-23 D1
  readiness r3）；r2 #390 的 GitHub PR base 虽为
  `00bbc5a2c7888e628997537a5ca859b46d772215`，但实际 merge
  `2782f47f98c7fca95996a02560e1a2be31525dc5` 的 first parent 已前进为
  `d53da289b7da80a4ee2282f5dea3122ebf97325a`，不满足 r2 自身“merge parent
  恰为 audit base”的二值门，因此 fail closed，未开始实现。r3 三前置闭合：
  ① CHG-2026-030
  approval #361；② 本 readiness 重新钉定 envelope v1 grammar、runtime/template
  inputs、测试矩阵与当前 protected `main` 基线；③ TASK-BAP-003 done #376。
  r2 `ready` 因上述 exact-parent mismatch 被 r3 supersede，零
  implementation/evidence 被复用。
- Readiness（r3，base = protected `main`
  `09d4afd77b213efd07a5f8b0d07f1be23d71d095`）：
  - **Approval/dependency gate:satisfied。**approval-only #361 的 exact head
    `1144aedd82d913d5497bb56c702017c234064af6` 由维护者 `lvye` APPROVED，并以
    `3434d4e80e0785af2abaa44614d24cadee55b12e` 合入 protected `main`；
    TASK-BAP-003 的 human execution evidence #375 与独立 done #376 已依次合入，
    done merge OID = `6a6b6b7010b6563d67aa7d96e6838505e82eb25a`。本任务只消费
    已批准的凭据分离事实，不读取或配置任何 credential。
  - **Base/input pins。**以下 carrier 均在本 base 由 Git object 实测；implementation
    开工时必须基于本 readiness 合入后的最新 protected `main`，逐项重核 exact blob 与
    absence。任一漂移、路径抢占或被后续 revision supersede，立即停止并重新 readiness。
    `tasks.md` 是本 readiness 的自载体，表中只钉 r3 PR 开工前 blob；r3 merge 后不得要求
    它等于自身修改前 blob，而须核对该 merge 的 parent 恰为本 base、diff 只含本 HLR-001
    readiness section，并把 r3 完整 merge OID 作为 implementation 的状态事实。r3 延续
    r2 对 CHG-2026-027 `tasks.md` whole-file blob pin 的窄化：该依赖保持
    TASK-BAP-003 done merge ancestry 与唯一 TASK-BAP-003 section hash 的双重固定；
    其余输入在本 audit base 重新实测：

    ```yaml pins
    - artifact: TASK-HLR-001 readiness audit base
      commit: 09d4afd77b213efd07a5f8b0d07f1be23d71d095
    - artifact: CHG-2026-030 approval merge
      commit: 3434d4e80e0785af2abaa44614d24cadee55b12e
    - artifact: TASK-BAP-003 done merge
      commit: 6a6b6b7010b6563d67aa7d96e6838505e82eb25a
    - path: openspec/changes/chg-2026-030-host-loop-runtime/proposal.md
      blob: e59001c14b528c19207ecdd0d262c2114c778a48
    - path: openspec/changes/chg-2026-030-host-loop-runtime/design.md
      blob: d47987ed6ae19d07926f59e6a8ed50b371074e0c
    - path: openspec/changes/chg-2026-030-host-loop-runtime/tasks.md
      blob: 69683398045f90b20e46e88a186db4014900d6d9
    - path: openspec/changes/chg-2026-030-host-loop-runtime/verification.md
      blob: f62d9f08648f5741206144cf650620d82ffd5ee0
    - path: scripts/check_pr_paths.py
      blob: 7fdc47933b98284c556d5cba6fd8cfe99b87e0ad
    - path: scripts/test_check_pr_paths.py
      blob: 1f7093402034c622553a11a71b6fc50cb8622bec
    - path: .github/workflows/agent-pr.yml
      blob: 2b9b03a90d70671d85da21be6a667e2f2f9c8acb
    - artifact: TASK-BAP-003 section
      path: openspec/changes/chg-2026-027-decision-grading-batch-approval/tasks.md
      sha256: 6f377758c7d96534b38e6a3373cd191d0189f3e3a16949e12fcb386e089948e0
    ```

    section extractor 必须先确认全文件中只有一行以 exact task-header token
    `## TASK-BAP-003`（token 后为 whitespace 或 EOL）开头；零个或多个匹配均视为
    pin drift。唯一 section 从该行的首字节起，至下一行以 `## TASK-` 开头前或 EOF
    的 UTF-8 bytes 止；预期 byte count = `3724`。本 section 的 byte count/SHA-256
    在 #376 done merge、#385 r1 merge、#390 r2 merge 与本 r3 audit base 均相同；
    BAP-001/002 独立
    section 变化不再误伤本 lane。
    `scripts/host_loop/**` 与 `openspec/templates/agent-pr-body.md` 在本 base **均不存在**；
    它们是本任务唯一获准的新输出根/文件，不得覆盖或迁移其他 owner 的内容。
    在 #386 已使 r1 pin 漂移后，共享会话误将候选 head
    `d18b38164e6eef9d5e7aee6769e747896efc64a3` 推送到远端分支
    `agent/task-hlr-001-envelope-r2`，并于 `2026-07-23T03:59:17Z` 自动创建 #389；
    这违反 r2 merge 前零成 PR 边界，作为偏差记录而非任何批准。#389 已于
    `2026-07-23T04:00:35Z` 关闭，`merged_at = null`、零维护者 approval/merge，
    远端分支已删除。该 head/base/evidence 永久 superseded，不得 reopen 或复用；
    r3 合入后必须从最新 protected `main` 建立新 branch、形成新 exact head、重跑全部
    verification 并取得针对该新 head 的独立 review，才可创建新的 implementation PR。
  - **Envelope v1 grammar:closed。**canonical renderer 输出 UTF-8/LF 文本；首个
    non-empty line 必须恰为 `<!-- arkdeck-pr-envelope:v1 -->`，machine block 以独立行
    `<!-- /arkdeck-pr-envelope -->` 结束，两个 marker 各且仅出现一次。block 内 scalar
    各恰一行，字段顺序固定为 `Envelope-Version: 1`、`PR-Type:`、`Change:`、`Task:`、
    `Base-OID:`、`Head-OID:`、`Decision-Grade:`、`Depends-On:`、`Evidence:`、
    `Attribution:`；`Depends-On` 是 design §2 规定的 scalar，`Evidence`/`Attribution`
    是以两个空格 + `- ` 开头的列表块。renderer 与 parser 共用单一 field definition，
    不各自维护枚举。解析器拒绝 marker 缺失/重复/倒序、block 内 duplicate/unknown/
    missing field、非 UTF-8、CR、前后空白歧义、空列表和列表外游离文本；人类说明只允许
    位于 closing marker 之后，且不得反向覆盖已解析值。
  - **Type/task mapping:binary。**`PR-Type` 取值域固定为 `implementation`、`status`、
    `verification`、`archive`、`proposal`、`approval`、`readiness`。前四类必须有独立
    `Task: TASK-*` 行；后三类必须恰为 `Task: none`，并以 `Change:` 表达范围。
    `Change:` 必须与唯一 active change 的 `proposal.md` frontmatter canonical `id`
    （`CHG-*`）逐字匹配；task-bound 类型还须由同目录 active `tasks.md` 唯一解析该 task。
    该 mapping 不新增批准语义：validator 只判结构，不判 task/change 已批准、ready、
    done 或 verified。
  - **Field validation:fail closed。**base/head 必须各为小写完整 40-hex 且不同；
    decision grade 只接受 `D0`/`D1`/`D2`；`Depends-On` 按 design §2 只接受单值
    `#<positive decimal PR number>` 或 `none`。`Evidence` 每项只接受仓库相对路径；确无
    evidence 时整块只接受单项 `none: <non-empty reason>`，绝对路径、`..`、URL 与空
    reason 拒绝。Attribution 恰含从显式 configuration 注入的 `producer`、固定
    `runtime: host-loop/1` 与 opaque non-empty `run`。生产 template/source/default
    禁止硬编码 Claude、OpenAI 或其他 provider 名称；negative fixture 可使用明确 sentinel
    验证 hard-coded provider 被拒绝，但该 sentinel 不得成为 renderer 默认值。
  - **MECH-004 compatibility:binary。**task-bound renderer 的 `Task: TASK-*` 必须被当前
    `scripts/check_pr_paths.py` 的 `TASK_LINE_RE`/`resolve_task_declaration` 原样识别；
    `Task: none` 不得产生 task declaration。测试用真实 active task fixture 同时证明：
    完整 task envelope 可进入现有 allowed-path resolver；多个/不一致 Task、短 OID、
    unknown grade、type/task mismatch 与零/多 active task 命中分别具名失败。不得修改
    MECH-004 parser、tests 或 workflow 来迁就本实现。
  - **Runtime boundary:closed。**本任务仅实现纯 renderer/parser/validator 与 Markdown
    template；零 GitHub/API/network/subprocess/shell、零 Issue/ref/lease、零 credential、
    零现有 workflow 修改。实现使用 Python 3 standard library，external command
    构造与执行调用数均为 0；任何 live PR 创建/更新留给 HLR-003/005。
  - **Test/evidence gate:binary。**固定命令为
    `python3 -m unittest discover -s scripts/host_loop -p 'test_*.py'`、
    `python3 scripts/test_check_pr_paths.py`、`scripts/check-sdd.sh` 与
    `git diff --check`。fixture 至少覆盖完整 task、proposal/approval/readiness 的
    `Task: none`、七类 type mapping、每个必填字段单独缺失、marker 缺失/重复/倒序、
    duplicate/unknown field、short/uppercase/same OID、unknown grade、multiple Task、
    `Depends-On` 非 `#<PR>`/`none`、empty/no-reason evidence、绝对/traversal evidence、
    configured attribution 与 hard-coded provider sentinel regression；run 记录精确 test
    数、allowed/forbidden diff、archive/Core/governance/product/workflow diff = 0。任一失败
    即不形成 `HLR-ENVELOPE-001` PASS。
  - **Concurrency/review gate:satisfied。**`2026-07-23T06:40:00Z` 经 GitHub
    connector 检索 open PR = 0、open HLR-001 PR = 0；失效实现 PR #389 仍为
    `closed`、`merged=false`，远端分支已删除。本 audit base 中
    `scripts/host_loop/**` 与 `openspec/templates/agent-pr-body.md` 均不存在，也无
    其他 active task 获准占用本任务的新输出路径。出现同路径 PR、canonical conflict
    或需要 forbidden path 时立即回到 `blocked`。
  - **Review boundary。**本 PR 只修改本文件 TASK-HLR-001 section，将
    r2 readiness 重钉为 r3 并登记 exact-parent mismatch、D1 base/pins/concurrency；
    零 runtime/template/evidence、
    零 HLR-002 D2 准备、零 implementation。readiness merge 不构成
    `HLR-ENVELOPE-001` PASS；implementation/evidence 与后续 `ready→done` 各使用独立 PR。
- Platform:macos（纯 host runtime；不产生产品平台支持声明）
- Requirements/AC:change-local `HLR-ENVELOPE-001`
- Depends on:change approval、independent readiness、TASK-BAP-003 done
- In scope:版本化 envelope renderer/parser/validator；task 与 non-task PR type
  mapping；base/head OID、grade、evidence、dependency 与事实性 attribution 字段；纯
  fixture/contract tests；task run evidence。
- Out of scope:调用 GitHub API、创建 PR/Issue/lease、修改既有 workflow、自动 review/
  merge、任何 GitHub credential 配置。
- Allowed paths:`scripts/host_loop/**`、`openspec/templates/agent-pr-body.md`、本
  change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）。
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、`openspec/governance/**`、
  `openspec/specs/**`、`openspec/contracts/**`、`openspec/changes/archive/**`、
  `.github/**`、产品 source/tests。
- Risk:low-medium（metadata 缺失/歧义会使 guard 输入失真；validator 必须 fail closed）。
- Hardware required:no。

### Deliverables

- PR envelope 的 renderer、parser 和 validator，以及非 task PR 的 `Task: none` 边界；
- fixtures 覆盖完整 task envelope、proposal envelope、短 OID、未知 grade、多个 Task、
  空 evidence/依赖理由、配置 attribution 与 hard-coded provider 回归；
- 无 shell-string external command 的静态审计与 run record。

### Verification

- `HLR-ENVELOPE-001` contract：完整 task envelope 可被现有 `MECH-004` 读取；每个
  必填字段单独缺失/非法都具名失败；non-task PR 不产生 `TASK-*` 声明；renderer 不含
  固定 Claude/其他厂商 attribution；`check-sdd` 与 diff check 通过。

### Notes / handoff

- Implementation/evidence：#401 merge
  `145d46384251e535a563aa94a142d83860f2a710`；
  `evidence/runs/TASK-HLR-001/run.md` 只声明
  `HLR-ENVELOPE-001` 的 HLR-001 contract slice，live first-event 证据仍归
  TASK-HLR-005。
- implementation/evidence PR 不翻 `ready→done`；done 使用独立 D0 状态 PR；
- readiness 若发现 templates 或 current `MECH-004` grammar 冲突，停止并提议 scope
  revision，不在本 task 改 canonical governance。

## TASK-HLR-001A — Bot-authored Agent PR automatic exact-head checks

- Status:done（2026-07-24 D0 completion；仅在维护者 review/merge 本独立
  `ready→done` PR 后生效。implementation #485 exact final head
  `6717ae3c8cfbc464294de284a173e914ed1024bf` 已由 `lvye` APPROVED，并以
  `cae9a4c378b75409a4d7a31205583560f17d73aa` 合入 protected main。
  #488 只形成 create/existing-path partial PASS；其未执行 human
  `edited/reopened` 且 final `allowed-paths` 失败的事实永久保留，不作为 done
  依据。fresh evidence closure #490 exact final head
  `f578c23dedaba38119c157b6d0cb93da4a53e971` 已由 `lvye` APPROVED，并于
  `2026-07-24T15:20:23Z` 由 `lvye` 以
  `89ce135c109871c5428022ad0620a383430635dc` 合入 protected main。
  #490 自动 create、human `edited`、human `reopened` 与 final-head push
  checks 均 success、零 `action_required`；contract tests = 8/8 + 24/24，
  host-loop = 17/17，`check-sdd` = 0 errors / 0 warnings / 111 acceptance IDs。
  evidence = `evidence/runs/TASK-HLR-001A/source-run.md`、
  `evidence/runs/TASK-HLR-001A/post-merge-live.md`、
  `evidence/runs/TASK-HLR-001A/post-merge-live-closure.md`。本 done 只闭合
  `HLR-AUTOCI-001`；不修改 GitHub setting/credential，不形成 change
  `verified`，不使 HLR-002A ready，也不授权任何旧 r8 ref/UUID/canary。）
- Historical Status:ready（r9 compatible revision/readiness #483 exact reviewed
  head `83f508aa6d64ba26789edd6e82ce0c2f8dff5fb3` 已由 `lvye` APPROVED，并以
  `c2fd6d1dff71717f8a8dd3137c68b4a06cf569cf` 合入 protected main。）
- Readiness（r1；audit base = protected `main`
  `0f0a79aff7ede1519b9fbc0cbdca12b5c687ef07`）：
  - **Authority/dependency gate:closed。**#480 exact reviewed head
    `fea214bac75711c075f6a023086688eee28822d3` 由 `lvye` APPROVED，并于
    `2026-07-24T13:29:03Z` 以 squash merge
    `2b46558629ba67c8fa1fcd6f80b8234cd8c8d0c6` 进入 protected main；
    `mergedBy=lvye`，base `70c043d901e1180af1cc3383f3345ae9edabc5c3`。
    后续 #481 只修改 CHG-2026-026，形成当前 audit base；它与本 task
    workflow/parser/test paths 零交集。
  - **Observed trigger:closed。**#480 initial bot head
    `a841962cc7ce371d0921383584543fba03054ab9` 的 pull-request Swift/SDD runs
    `30096501384`/`30096501389` 均为 `action_required`；维护者 update branch
    产生 final head 后，pull-request runs `30096750425`/`30096750430` 才为
    success。GitHub current `GITHUB_TOKEN` 文档明确此为 workflow-created PR 的
    recursion gate，不是 main protection/ruleset bypass。
  - **Input pins:closed。**以下 blobs 均从 audit base Git object 实测；r9
    readiness merge 后 implementation 开工时必须逐项相等，任一漂移即停止并
    重新 readiness：

    ```yaml pins
    - artifact: TASK-HLR-001A readiness audit base
      commit: 0f0a79aff7ede1519b9fbc0cbdca12b5c687ef07
    - path: .github/workflows/agent-pr.yml
      blob: 41426544637db25224dc6c6b3718abd4ebbfca7c
    - path: .github/workflows/sdd-guard.yml
      blob: 809147e462512d970813d1992a3fcdf41f8b4b10
    - path: .github/workflows/swift-ci.yml
      blob: 640065f3f3849e1add0cc6bfa92078873eb315ef
    - path: scripts/check_pr_paths.py
      blob: 267417ca5d0f9a2bd5ef775314b93915717aea9b
    - path: scripts/test_check_pr_paths.py
      blob: 2aa1e2cb37ef0085d2e101adb34d2b3615246b82
    - path: scripts/test_agent_pr_workflow.py
      blob: 6a256a1556827c2153df0785479c5cbc53796f28
    ```

    `AGENTS.md` blob
    `3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164` 与
    `openspec/governance/enforcement.md` blob
    `e8ff3c130e1b8b15f8405d150ad567e774a0d82b` 均须零 diff。
  - **Exact workflow delta:closed。**`agent-pr.yml` 保留 exact ordered push
    include/exclude 与 `github-actions[bot]` authorship；`open-pr` 必须
    create-or-find 唯一 same-repository PR、复核 number/main/exact
    head/author/unmerged 并输出 validated number，不能因 PR 已存在直接跳过
    validation。其 dependent `allowed-paths` job 仅
    `contents:read`/`pull-requests:read`，从固定 PR endpoint 获取 JSON，在
    Python 内解析不可信 metadata，运行 MECH-004 contract + exact base/head diff。
    `sdd-guard.yml` 的 routine initial/synchronize coverage 改由 push
    `guard` + Agent PR `allowed-paths` 承担，仅保留 human `edited/reopened`
    pull-request revalidation；`swift-ci.yml` 使用 push-only。不得引入
    `pull_request_target`、PAT、App/private key、secret、OIDC、Actions/Checks/
    Administration/Workflows/Contents write、review/merge route。
  - **Branch/concurrency gate:closed。**discovery 时 remote protected main =
    audit base；随后 open PR 从 0 变为 exactly #482，head
    `0506f2f3010b75973c9fd82daa5439c35906f829`。其分页完整 files 恰为
    CHG-2026-026 TASK-RKFUI-001C evidence/registry 与
    `scripts/rockchip_loader_transition_probe/**` 六个路径，不触碰本 change、
    三个 workflow、三个 parser/test input、计划分支或 canary namespace，
    故为已审计 non-overlap。planned revision branch
    `agent/chg-2026-030-r9-auto-ci`、implementation branch
    `agent/task-hlr-001a-auto-ci`、evidence branch
    `agent/task-hlr-001a-auto-ci-evidence` 与 r8 canary namespaces 均 absent；
    Agent-side `gh auth status` 为 zero logged-in hosts。implementation 开工前
    重做全部 open-PR files、remote refs 与 input pins；查询不完整或 overlap
    即停止。
  - **Live/evidence separation:binary。**implementation PR 本身必须在不点击
    workflow approval 的情况下取得 exact-head push `guard`、Swift、
    `open-pr` 与 new `allowed-paths` success；旧 base 对该 PR 可能仍展示
    approval-required duplicate pull-request runs，但它们不得是 merge 所需事实。
    implementation merge 后，另以 ordinary Agent evidence PR 验证 base 已不再
    为 bot `opened` 产生 routine approval gate，human metadata edit/reopen
    revalidation 仍有效。source/offline evidence、post-merge live evidence 与
    `ready→done` 分离；任一 0/2 PR/check、wrong head/base/author、缺失
    revalidation 或仍需 workflow approval 才能满足治理门均 FAIL。
  - **HLR-002A supersession:binary。**r9 merge 使 r8 reserved
    `agent/host-loop/probes/8bd61cc3-d7c7-41ff-bfc8-0c62952afba3`、
    ordinary `agent/hlr-002a-control/5a2570ed-5916-4cc8-ac84-4afa294e4b9e`
    及其 pins/readiness 永久不可执行。TASK-HLR-001A done 后，HLR-002A
    必须从届时最新 main 以全新 UUID/branches/complete pins 重新 D1 readiness。
- Platform:github-actions + macos（host CI/control plane；零产品平台声明）
- Requirements/AC:change-local `HLR-AUTOCI-001`
- Depends on:change revision r9（本 compatible revision/readiness PR 合入后）、
  TASK-HLR-001 done、TASK-RPT-001 done、TASK-RPT-002 implementation merge #480
- In scope:`.github/workflows/agent-pr.yml`、
  `.github/workflows/sdd-guard.yml`、`.github/workflows/swift-ci.yml`、
  `scripts/check_pr_paths.py`、`scripts/test_check_pr_paths.py`、
  `scripts/test_agent_pr_workflow.py`、本 change `evidence/**`、
  本 change `tasks.md`（仅本任务 evidence/status 引用）。
- Out of scope:GitHub settings、branch protection、ruleset、required checks、
  credential/App/PAT/private key/secret/OIDC、`pull_request_target`、review、merge、
  auto-merge、Core/canonical governance、product/device code、r8 canary execution。
- Allowed paths:`.github/workflows/agent-pr.yml`、
  `.github/workflows/sdd-guard.yml`、`.github/workflows/swift-ci.yml`、
  `scripts/check_pr_paths.py`、`scripts/test_check_pr_paths.py`、
  `scripts/test_agent_pr_workflow.py`、本 change `evidence/**`、
  本 change `tasks.md`（仅本任务 evidence/status 引用）。
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/**`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`、`.gitignore`、产品 source/tests、其他 change。
- Risk:medium（event partition 错误会漏掉 scope/Swift check；PR JSON 或
  create-or-find 不封闭会产生 duplicate/错 head）。
- Hardware required:no。

### Deliverables

- routine Agent PR 的 exact-head push `guard`/Swift/open-pr/allowed-paths 全自动，
  无需 `Approve and run workflows`；
- existing PR 每次 push 仍 validate，0/2 PR、wrong head/base/author fail closed；
- human metadata edit/reopen 自动复验，bot initial/synchronize 不产生必要的
  approval gate；
- source/offline evidence、post-merge live evidence 与 done 独立。

### Verification

- `HLR-AUTOCI-001` contract + live：workflow event/permission/job dependency
  parser fixtures；raw PR JSON 正反解析；MECH-004 全回归；首次 implementation
  push checks；post-merge ordinary PR 零必要 approval gate；human edited/reopened
  revalidation；
- `python3 scripts/test_agent_pr_workflow.py`、
  `python3 scripts/test_check_pr_paths.py`、
  `python3 -m unittest discover -s scripts/host_loop -p 'test_*.py'`、
  `scripts/check-sdd.sh`、`git diff --check` 与 forbidden-path scan。

### Notes / handoff

- Source implementation candidate:#485 first source head
  `e4e94afe52e059c4bfba56ed8897bb5db0006a76`；contract + initial create-path
  evidence 见 `evidence/runs/TASK-HLR-001A/source-run.md`；final reviewed
  implementation head/merge 见本任务 Status。
- Post-merge live evidence:#488 的 create/existing-path partial PASS 与
  incomplete final gate 见 `evidence/runs/TASK-HLR-001A/post-merge-live.md`；
  preserved failure 与 #490 fresh human `edited/reopened` closure 见
  `evidence/runs/TASK-HLR-001A/post-merge-live-closure.md`；#490 exact
  review/merge 见本任务 Status。
- implementation/evidence PR 不翻 `ready→done`；live evidence 与 done 分离；
- current branch protection required `guard` 仍来自 App `15368` 的 push run，
  r9 不修改其设置或语义；
- 本 task done 后必须先重建 HLR-002A fresh readiness，不直接执行 canary。

## TASK-HLR-002A — Legacy bootstrap namespace partition

- Status:done（2026-07-25 D0 completion；仅在维护者 review/merge 本独立
  `ready→done` PR 后生效。source/contract implementation #419 exact reviewed
  head `39965af82bcb9a03f07e9501c844e86691b91d88` 已由 `lvye` APPROVED，
  并以 `99ba8aa4b04018918daad2fc8830009c1030f6da` 合入 protected main。
  #421 的旧 topology live FAIL 与 #501 的 r10 incomplete/fail-closed receipt
  永久保留，不作为 done 依据。r11 readiness #504 exact reviewed head
  `e304f1f2e70a78652accdceea502eda92e2b8519` 已由 `lvye` APPROVED，
  并以 `f1ebdf0b67014cbb921db4ae55f2400448f620ce` 合入 protected main。
  fresh success evidence #506 exact final head
  `dbe4453dd7d2e7437dc33e2589d083855c91ad60` 由 `lvye` 于
  `2026-07-25T00:17:42Z` APPROVED，并于 `00:17:48Z` 由 `lvye` 以
  `1bd36668565d5508dcdd3cd584114631ca4fd6ec` 合入 protected main；
  `auto_merge=null`。r11 reserved/ordinary commits 共用 #504 merge
  parent/tree：reserved SDD Guard/Swift success 且 exact legacy run/PR 双读回
  均为 0；ordinary SDD Guard/Swift/唯一 Agent PR run success，并由
  `github-actions[bot]` 创建唯一 #505；两边 `action_required=0`。Deploy Key
  依序删除 ordinary/reserved refs，两次 read-back 均 absent；#505
  closed/unmerged。machine/human evidence =
  `evidence/runs/TASK-HLR-002A/live-canary-r11-success.json` /
  `evidence/runs/TASK-HLR-002A/live-canary-r11-success.md`，blobs =
  `d695c9098c2478c6627fa312d127e278b1e8a48a` /
  `8f1261e07cef4e2297e3cf9090f1b1b7be197738`，JSON SHA-256 =
  `8965c39a06a8d68c33dea30215f82299e9e67c4b542f1a2e12bddd61529b1bb3`。
  本 done 只闭合 `HLR-LEASE-001`/`HLR-WORKER-001` bootstrap slice；不修改
  ruleset、branch protection、repository setting 或 credential，不创建
  integration identity/scheduler，不构成 change `verified` 或 HLR-002 D2
  authorization；HLR-002 在独立 D2 readiness 前继续 blocked。）
- Historical Status:ready（r10 #498 exact reviewed head
  `c3a35e31b16c17234ba667de56c359eb39af9e0f` 由 `lvye` APPROVED，并以
  `53b4924227bc3931523357e68ee2cb61b5814646` 合入。reserved SDD/Swift 与
  legacy run/PR = 0 通过，但 #497 在 ordinary 前推进 main，故 ordinary
  dispatch = 0、reserved 已清理，combined canary incomplete。failure evidence
  #501 final reviewed head `961410627d779b281e7218536fd12bc05927d6ce`
  已由 `lvye` APPROVED，并以
  `1c1ae70a869d03e50a3a012e53d2a1b47a9f311d` 合入；r11 后 r10 refs/UUID
  永久只作历史。）
- Readiness（r11；audit base = protected `main`
  `1c1ae70a869d03e50a3a012e53d2a1b47a9f311d`）：
  - **Approval boundary:pending human merge。**本 carrier 只修改
    CHG-2026-030 proposal/design/tasks/verification。只有 `lvye` 对 exact
    head APPROVED、required checks 通过、`mergedBy=lvye` 且 squash subject
    `(#N)` 的 merge OID 进入 protected main 后，r11 readiness 才生效。该
    merge 不构成 creator PASS、task done、change verified 或任何 GitHub
    setting/credential mutation。
  - **Dependency/evidence gate:closed at discovery。**r10 readiness #498
    merge `53b4924227bc3931523357e68ee2cb61b5814646` 与 r10 failure evidence
    #501 merge `1c1ae70a869d03e50a3a012e53d2a1b47a9f311d` 均在 audit base。
    #501 machine receipt blob =
    `4ddd4b1b2b6f5b68de09d8d848b48680d546a25e`，file SHA-256 =
    `f649774c02cdd114d50912b1f00fc8bc4efeae3540e9c540d0101b9429448ba0`；
    human receipt blob =
    `14de289897e476915fc776600732a0ed067440de`，file SHA-256 =
    `0922e2c83db3648d615d65f6f3d2ae9d87232aea933c97e3a54c6458fba79179`。
    其结论固定为 reserved PASS、ordinary not-run、combined incomplete、
    cleanup complete；r11 不把它改写为成功。
  - **#501 carrier timing fact:preserved。**#501 final head 的 push
    `guard`/Swift/`open-pr` 成功；`allowed-paths` job `89615675017` 于
    `2026-07-24T23:43:45Z` 开始、其 exact validation step 于
    `23:43:48Z`（与 PR merge 同秒）开始并在 PR 已 closed 后于
    `23:43:49Z` failure。contract-test step 成功，匿名 evidence 未见 stderr；
    因此本 r11 不声称 #501 final carrier all-green，也不猜测 unseen root
    cause。其 merged bytes 仍是 r10 live facts；未来 evidence PR 必须等待
    `allowed-paths` terminal success 后才允许维护者 merge。
  - **Archived topology authority:closed。**CHG-2026-033 verification #497
    merge `ce4a11c3d7cb59686024be9cbd51939c084041d1`、archive #500 merge
    `09ef864e0b7a82fafd480a194aed07144a22578b` 均为 ancestors。current
    repository authority 位于
    `openspec/changes/archive/2026-07-25-chg-2026-033-ref-protection-topology/`。
    topology JSON/human/no-bypass blobs 仍为
    `8eb63bf170e993785acda6345a80558fb6871b76` /
    `6c4541d41c8a166edd201883d10190be031d0bea` /
    `73005c421eb3fc36a16b435873a18f6e84b97369`，JSON SHA-256 =
    `9340eae63e4b4586a07525340e1c6a4b9fe39c0a5958bda1cda55dda16df9d9f`。
    branch-protection projection/full 与 ruleset projection/full hashes
    继续为
    `f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a` /
    `04f09f273fce806afaa44679c9e8257c74cce3e480fe60da27c7dcca06e85f04`
    与
    `9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163` /
    `b172750c1c0764956725393823fa72014146d9e2ec0f1b19c48cf670964d54b5`。
    TASK-BAP-003 currency addendum blob =
    `8dfb87880846d47848a6c6d0ffbcaa4dceccd738`，file SHA-256 =
    `a291a73386e339dbf3bf65cc0eae0722d604250e38407b0640c689fda60c9432`。
    Archive 只移动路径，不授权本 task 修改 topology。
  - **Sensitive input pins:closed。**以下 blobs 从 audit base 实测。canary
    首个 push 前非本 r11 四文档必须逐项相等；四文档必须等于 r11 exact
    reviewed-head/merge tree 且相对 before blobs 只有本 revision delta：

    ```yaml
    chg030_proposal_before: c0027fe6080c928ddacd0c2b9627303099ee645b
    chg030_design_before: bc0f8d7b2937ac2bcbc6d3d871608661edec6d22
    chg030_tasks_before: fc1e53d308a8f67befc5c21ac48f86100d0eb680
    chg030_verification_before: fbd389f4c1056deceaec67a230e6d657548c3608
    agent_pr_workflow: a514d9e539964f9e1960acbe4ffaa696629571da
    sdd_guard_workflow: c64135e1f9dc253a92640a30bbcad42b0afa86fa
    swift_ci_workflow: 01f40a032061bdbc9e30e12ab628bf1ee896c8fb
    agent_pr_contract: 10b32515f9590ba78eb9fa477e8fc7b0b93d15a2
    check_pr_paths: 02332a9b572013e99b74acd46db8810ba4f7275a
    check_pr_paths_tests: feb697f760c8b2ba9e57072ac79f73a96ed7905f
    pr_envelope: c990fcfb17de52ed1166fec55cb1f9365e0e7736
    pr_envelope_tests: 35d9a284e8ddde67fd1076bc1c2f0f11f02d26db
    agents_contract: 3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164
    enforcement: e8ff3c130e1b8b15f8405d150ad567e774a0d82b
    hlr001a_source_evidence: 6d294654f4b28fa8202fcdcbdf5e8132002d2324
    hlr001a_live_evidence: 6b8fcf46355b647cae8064abbd17229cc2d3487a
    hlr001a_closure_evidence: b293c37c4c93baff2a7eba9388cc1ecde159a269
    hlr002a_contract_evidence: 610fad98fe97f0618d04adafd313ebb72bdd0549
    hlr002a_r1_failure: 9fc841f46c9b62ff74eede541b00890e1c6f6dbe
    hlr002a_r10_failure_json: 4ddd4b1b2b6f5b68de09d8d848b48680d546a25e
    hlr002a_r10_failure_md: 14de289897e476915fc776600732a0ed067440de
    ```

  - **Branch/ref/concurrency gate:closed at discovery。**API full-page
    all-open PR count 初始为 0；随后 #503 exact head
    `fbcfd10b9552b4562eed3d83d7cee3bc7cb0eef4` 以 audit base 为 base 开放，
    完整 diff 只含 CHG-2026-031 TASK-SSET-001 `tasks.md`，与 r11
    sensitive manifest/target/evidence 零交集，故为 audited non-overlap。
    remote branches 完整列表只含 exact main、八个历史 `agent/**` branches
    与 #503 branch，main 外没有 ordinary namespace branch；全部
    `agent/host-loop/**`、r11 readiness/evidence branch 与下列 exact target
    refs 均 absent。历史
    `agent/task-hlr-002a-bootstrap-partition` /
    `agent/task-hlr-002-readiness` 以及 r8/r10 branches/UUID 不得复用。
    执行前必须重做完整 open PR/files、remote refs 与 pins；查询不全或 overlap
    即停止。
  - **Fresh target refs:closed。**

    ```yaml
    reserved_canary: agent/host-loop/probes/0f803ee1-332e-4bf3-a58c-32af75ce8579
    ordinary_canary: agent/hlr-002a-control/5dab2542-ec7b-4561-b3d0-ad41046affb6
    readiness_branch: agent/chg-2026-030-r11-hlr002a-readiness
    evidence_branch: agent/task-hlr-002a-canary-evidence-r11
    ```

    两个 UUID 为本次 discovery 生成的 lowercase RFC 4122 v4。任一预存在、
    all-state exact-head PR 非零或临时换名即停止。
  - **Common source:binary。**r11 readiness squash merge 必须在 dispatch
    开始时为 current protected main。两个不同 empty commits 以该 merge 为共同
    parent/tree，subject 明示 `TASK-HLR-002A` 且无 skip instruction；只使用
    Agent attribution 与 Deploy Key。
  - **Reserved-first shortened gate:binary。**push reserved 后要求 exact ref
    receipt、SDD Guard push `guard=success`、exact Swift push run count = 1
    且状态为 queued/in-progress/completed、Agent PR push run count = 0、
    all-state exact-head PR count = 0。此时不等待 Swift terminal。立即重读
    main/pins/两个 refs；main 不再等于 readiness merge 或任一事实漂移即删除
    reserved 并停止。
  - **Ordinary dispatch barrier:binary。**只有 shortened gate 全过才 push
    ordinary；记录 Git receipt 与 exact ref OID 后关闭 dispatch barrier。
    该 receipt 前任何 main drift 一律失败。receipt 后不得重建 commit、改 UUID、
    重推或把失败 job 当作 preserved fact。
  - **Scoped post-dispatch drift:binary。**barrier 后 main 可前进仅当：
    ① current main 是 readiness merge 的 linear descendant；② 每个 intervening
    commit 可绑定 human-reviewed merged PR；③ 全部分页 PR files + cumulative
    Git diff 对三 workflow、parser/tests、AGENTS/enforcement、本 change 与
    evidence、archived topology/BAP addendum、两个 target namespace/ref 零交集；
    ④ canary refs/OIDs 与 exact-head run/job/PR facts 不变。任一 non-linear/
    unknown commit、overlap、API ambiguity 或 job failure即 stop；scoped drift
    只保存已触发事实，不赋予 retry 或 merge 权限。
  - **Terminal creator matrix:binary。**reserved/ordinary SDD Guard 与 Swift
    最终均 success。reserved legacy run/PR 双读回均为 0。ordinary 恰有一个
    terminal-success Agent PR push run，`open-pr`/`allowed-paths` jobs success，
    且恰有一个 open/unmerged、exact head、base=`main`、作者
    `github-actions[bot]` PR；任何 `action_required`、0/2 creator、wrong
    actor/base/head、missing/failed job 均 FAIL。
  - **Cleanup/evidence boundary:binary。**pre-cleanup 再次完整分页固定两边
    facts；随后 Deploy Key 依序删除 ordinary、reserved，并以 Git receipt +
    两次 stable `ls-remote` absence 复核。ordinary PR 必须 closed/unmerged；
    未自动关闭则登记 residual、请人类独立 close 并停止。成功事实只进入
    `agent/task-hlr-002a-canary-evidence-r11` 独立 PR；该 PR 必须等待
    final `allowed-paths` terminal success 后才可供维护者 merge，且不翻状态。
    evidence 合入后另起 D0 `ready→done`。
  - **Permanent supersession:binary。**r10 reserved PASS 只证明旧 exact head；
    r10 combined conclusion仍 incomplete。#421/#435/#454、r8/r10 refs/UUID/
    commits/runs/window/payload/hash 均不得重推、补跑或拼成 r11 PASS。
- Historical Status:blocked（r9 #483 merge
  `c2fd6d1dff71717f8a8dd3137c68b4a06cf569cf` 后生效；r8 #480 readiness
  已合入但 zero canary/ref dispatch，因 sensitive workflow inputs 先发生变化，
  其 refs/pins/UUID 永久 superseded。TASK-HLR-001A implementation #485、
  fresh evidence #490 与 done #495 现已闭合；本 r10 fresh readiness merge
  取代该 stop gate，合入前仍不得 canary。）
- Historical Readiness（r10；audit base = protected `main`
  `47cec786315e79e0aad8a3209c6a7c600e6cfc60`）：
  - **Approval boundary:pending human merge。**本 r10 carrier 只修改
    CHG-2026-030 proposal/design/tasks/verification 四份治理文档。只有维护者
    `lvye` 对 exact head APPROVED、required checks 通过、`mergedBy=lvye` 且
    squash subject `(#N)` 的 merge OID 进入 protected main 后，本状态才为
    effective `ready`。该 merge 不批准 ruleset、branch protection、repository
    setting、credential、integration identity、scheduler、review、merge、
    auto-merge 或任意 generic GitHub API mutation，也不构成 canary PASS、
    task done 或 change verified。
  - **Approval/dependency gate:closed at discovery。**CHG-2026-030 r9 #483
    merge `c2fd6d1dff71717f8a8dd3137c68b4a06cf569cf`、TASK-HLR-001 done
    `d09f5021107e4133d2fc41c1ce65d0bd09d6c12b`、TASK-BAP-003 done
    `6a6b6b7010b6563d67aa7d96e6838505e82eb25a` 与 CHG-2026-033
    TASK-RPT-001 evidence/done #476/#477/#478 均为 audit-base ancestors。
    TASK-HLR-001A #485 implementation
    `cae9a4c378b75409a4d7a31205583560f17d73aa`、#490 fresh evidence
    `89ce135c109871c5428022ad0620a383430635dc` 与 #495 done
    `1815105971b5ec9bee58cb7be04cd759dc01a32b` 已闭合；#488 partial
    evidence 的失败事实不被覆盖。
  - **Current topology evidence pins:closed。**authoritative receipt JSON blob
    = `8eb63bf170e993785acda6345a80558fb6871b76`，file SHA-256 =
    `9340eae63e4b4586a07525340e1c6a4b9fe39c0a5958bda1cda55dda16df9d9f`；
    human-readable receipt blob =
    `6c4541d41c8a166edd201883d10190be031d0bea`；no-bypass operability blob =
    `73005c421eb3fc36a16b435873a18f6e84b97369`。authenticated after
    hashes 固定为 branch protection projection/full
    `f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a` /
    `04f09f273fce806afaa44679c9e8257c74cce3e480fe60da27c7dcca06e85f04`
    与 ruleset projection/full
    `9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163` /
    `b172750c1c0764956725393823fa72014146d9e2ec0f1b19c48cf670964d54b5`。
    ruleset ID = `19595282`。Agent 不从 public projection 猜测 hidden actor；
    live behavior 与 merged authenticated evidence 不一致即停止并回到
    CHG-2026-033，禁止在本 task 修复设置。
  - **Sensitive input pins:closed。**以下 blobs 从 audit-base Git objects
    实测。canary 首个 push 前，非本 r10 四文档的条目必须逐项相等；四文档必须
    与本 readiness exact reviewed head/merge tree 相等且相对下列 before blobs
    只包含本 r10 reviewed delta：

    ```yaml
    chg030_proposal_before: 8eafabff26b173dbbed4fd32bd94e3d39dd07bb8
    chg030_design_before: 250d6392f43e7cec4f149e644f4d7008f0cc2d54
    chg030_tasks_before: f71f65dd202c7c849e53c69ae973922c5151e583
    chg030_verification_before: 5261cefcb0ba101fd1e32c0e4304c1dde2939088
    agent_pr_workflow: a514d9e539964f9e1960acbe4ffaa696629571da
    sdd_guard_workflow: c64135e1f9dc253a92640a30bbcad42b0afa86fa
    swift_ci_workflow: 01f40a032061bdbc9e30e12ab628bf1ee896c8fb
    agent_pr_contract: 10b32515f9590ba78eb9fa477e8fc7b0b93d15a2
    check_pr_paths: 02332a9b572013e99b74acd46db8810ba4f7275a
    check_pr_paths_tests: feb697f760c8b2ba9e57072ac79f73a96ed7905f
    pr_envelope: c990fcfb17de52ed1166fec55cb1f9365e0e7736
    pr_envelope_tests: 35d9a284e8ddde67fd1076bc1c2f0f11f02d26db
    agents_contract: 3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164
    enforcement: e8ff3c130e1b8b15f8405d150ad567e774a0d82b
    ```

    TASK-HLR-001A source/live/closure evidence blobs
    `6d294654f4b28fa8202fcdcbdf5e8132002d2324` /
    `6b8fcf46355b647cae8064abbd17229cc2d3487a` /
    `b293c37c4c93baff2a7eba9388cc1ecde159a269` 与 HLR-002A #419
    contract/#421 failure evidence blobs
    `610fad98fe97f0618d04adafd313ebb72bdd0549` /
    `9fc841f46c9b62ff74eede541b00890e1c6f6dbe` 必须 byte-for-byte
    不变。
  - **Current branch/ref/concurrency gate:closed at discovery。**公开 remote
    branches 完整列表只含 exact main 与 `agent/**`；main 之外没有普通 namespace
    branch。planned readiness/evidence branch、两个 exact target refs 与全部
    `agent/host-loop/**` refs 均 absent。历史 remote branches
    `agent/task-hlr-002a-bootstrap-partition` 与
    `agent/task-hlr-002-readiness` 只作残留记录，不得用作本次 carrier、
    parent、evidence 或 target。#494 exact head
    `f562ede24a5f46a914214f7571f103e9e8fbd05b` 经 `lvye` exact-head
    APPROVED，并以当前 audit base 合入；其完整 diff 只含
    `openspec/changes/chg-2026-033-ref-protection-topology/tasks.md`，与本
    readiness、workflow/parser/evidence/target refs 零交集。其合入后 API
    full-page all-open PR count = 0；随后新开 #497，exact head
    `13d4980f7aa9eb50b0c098ad1f18e904f017148c`、base = audit base，完整
    diff 只含 CHG-2026-033 proposal/verification 两个 verified-state 路径，
    与本 readiness、pinned topology evidence、workflow/parser/target refs
    零交集，故记为 audited non-overlap。执行前必须完整分页重做 all-open
    PR/files 与 remote refs；任何 overlap、main drift 或查询不完整均停止。
    **Archive currency note（2026-07-25）：**#497 已合入 protected `main`
    `ce4a11c3d7cb59686024be9cbd51939c084041d1`；同一独立 archive PR 生效后，上文
    保留的 active-root `tasks.md` 路径按
    `openspec/changes/archive/2026-07-25-chg-2026-033-ref-protection-topology/tasks.md`
    定位。该目录移动与注记不改变 #498 固定的 readiness pins、target refs、执行顺序
    或 fail-closed 门。
  - **Fresh target refs:closed。**

    ```yaml
    reserved_canary: agent/host-loop/probes/7e9bc001-c515-4aef-b3dc-c71d7f0124ee
    ordinary_canary: agent/hlr-002a-control/4a2314d2-72c3-44f8-b579-606735e279b8
    readiness_branch: agent/chg-2026-030-r10-hlr002a-readiness
    evidence_branch: agent/task-hlr-002a-canary-evidence-r10
    ```

    两个 UUID 为本次 discovery 生成的 lowercase RFC 4122 v4。执行前任一
    target/evidence branch 已存在、任一 target all-state exact-head PR 非零或
    readiness merge 不是 current protected main，即停止；不得临时换名、改
    parent 或复用 r8/历史 UUID。
  - **Canary construction/order:binary。**以本 readiness PR 经 exact-head
    human review 与 GitHub/git 双重确认的 squash merge OID 作为两个不同 empty
    commits 的共同 parent；两个 tree 与 parent 相同，subjects 明示
    `TASK-HLR-002A` 且无 Actions skip instruction。严格先 push reserved：
    取得 exact-head SDD Guard push `guard=success` 与 Swift CI push
    `swift=success`，并以 workflow path + `event=push` + branch + head 完整
    分页证明 `agent-pr` run count = 0、all-state exact-head PR count = 0。
    重读 main/pins/reserved facts 不变后才 push ordinary。
  - **Ordinary creator gate:binary。**ordinary exact head 必须取得 SDD Guard
    push `guard=success`、Swift CI push `swift=success`、恰一个 terminal
    success Agent PR push run，且其 `open-pr` 与 `allowed-paths` jobs 均
    success；all-state exact-head PR 查询必须恰有一个 open、unmerged、
    base=`main`、head/base OID 精确、作者 `github-actions[bot]` 的 PR。
    routine success 不依赖 pull-request run；任何 `action_required` run、
    0/2 creator、wrong actor/head/base、missing/duplicate job 或 API ambiguity
    均停止。
  - **Double read-back/cleanup:evidence preserving。**cleanup 前再次执行
    reserved zero-run/zero-PR 与 ordinary unique-run/unique-PR 查询，记录完整
    filters、pagination、full OID、run/job/PR IDs 与 timestamps。事实固定后只用
    Deploy Key 依序删除 ordinary、reserved，逐项记录 Git receipt 并以两次稳定
    `ls-remote` absence 复核。ordinary PR 必须 closed/unmerged；若 ref 删除未
    自动 close，只登记 residual 并停止下游，请人类独立 close。Agent 不 review、
    merge、enable auto-merge、调用 admin/settings route 或借用维护者 credential。
  - **Evidence/state separation:binary。**canary 原始/派生事实只进入后一独立
    `agent/task-hlr-002a-canary-evidence-r10` PR；本 readiness PR 零 canary
    dispatch，evidence PR 不翻状态。evidence exact-head review/merge 后再另起
    D0 `ready→done` PR。任一失败保留 FAIL 并把任务保持 `ready` 或经独立
    remediation 退回 `blocked`；cleanup 不把失败改成通过。HLR-002/003 在
    HLR-002A done 前继续 blocked。
  - **Stop/supersession:binary。**main/input/target/open-overlap drift、API/
    pagination ambiguity、push/delete receipt ambiguity、unexpected workflow
    event、missing check、reserved creator 非零、ordinary creator 非一、PR
    cleanup 不闭合或 merged authenticated topology 不一致均零下一步 dispatch。
    #421/#435/#454 与 r8 的 readiness head/merge/OID/window/payload/hash/ref/
    UUID/run/branch 永久只作历史；TASK-HLR-002B 保持 superseded `blocked`
    tombstone。
- Historical Status:ready（r8 compatible revision/readiness #480 exact reviewed
  head `fea214bac75711c075f6a023086688eee28822d3` 已由 `lvye` APPROVED，
  并以 `2b46558629ba67c8fa1fcd6f80b8234cd8c8d0c6` 合入 protected main。
  该 readiness 从未执行 canary；r9 合入后只作历史，不得补跑。）
- Historical Readiness（r8；audit base = protected `main`
  `d869f9a36ec95e30bc1fba3c649ed414ca36bf0a`）：
  - **Historical approval boundary。**r8 fresh canary-only readiness 仅在维护者
    review/merge #480 后生效。该 merge 只允许执行下述
    reserved-first/ordinary-second creator canary、只读 run/PR/check 查询、ref
    cleanup 与独立 evidence PR；不批准 ruleset、branch protection、repository
    setting、credential、gateway、standing authorization、integration identity、
    scheduler、review、merge 或 auto-merge mutation，也不构成 acceptance PASS、
    task done 或 change verified。
  - **Approval/dependency gate:closed。**CHG-2026-030 r7 #456 merge
    `c5a1a9f0f1c0a9bc0dd3d04275ac01a5738697f7`、
    TASK-HLR-001 done `d09f5021107e4133d2fc41c1ce65d0bd09d6c12b` 与
    TASK-BAP-003 done `6a6b6b7010b6563d67aa7d96e6838505e82eb25a`
    均为 audit base ancestor。CHG-2026-033 TASK-RPT-001 execution evidence
    #476 merge `6f874efc5c4e9fdd39bcdcc91cfcaa6a862e1961`、
    operability evidence #477 merge
    `7a221d24133eefed38aa616fcda376fef33f6cf3` 与 done #478 merge
    `94c23c4123712a46e7fb2f96a0509f84f5f49ba7` 已闭合；TASK-RPT-002
    readiness #479 exact head
    `8096397bcc66890cb496a36d4cecb5e601f37daf` 以 subject
    `governance(TASK-RPT-002): authorize pointer supersession (#479)`、
    parent `94c23c4123712a46e7fb2f96a0509f84f5f49ba7` 合入 audit base。
  - **Current topology evidence pins:closed。**authoritative receipt JSON blob =
    `8eb63bf170e993785acda6345a80558fb6871b76`，file SHA-256 =
    `9340eae63e4b4586a07525340e1c6a4b9fe39c0a5958bda1cda55dda16df9d9f`；
    human-readable receipt blob =
    `6c4541d41c8a166edd201883d10190be031d0bea`；no-bypass operability blob =
    `73005c421eb3fc36a16b435873a18f6e84b97369`。authenticated after
    hashes 固定为 branch protection projection/full
    `f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a` /
    `04f09f273fce806afaa44679c9e8257c74cce3e480fe60da27c7dcca06e85f04`
    与 ruleset projection/full
    `9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163` /
    `b172750c1c0764956725393823fa72014146d9e2ec0f1b19c48cf670964d54b5`。
    Agent 不从匿名/public projection 推断 hidden actor；任何 live behavior 与该
    merged authenticated evidence 不一致即停止并回到 CHG-2026-033。
  - **Sensitive input pins:closed。**下列 blobs 从 audit base 的 Git objects
    实测；本 readiness merge 后、canary 首个 ref push 前必须逐项相等（本
    change 四文档仅允许本 r8 PR 的 reviewed-head→merge tree）：

    ```yaml
    chg030_proposal_before: 890a40585b2898c0fd9e7d2b72f5b2a8e81b515c
    chg030_design_before: 7e2e20bfb884875de32cbbeb5f0399df7a137056
    chg030_tasks_before: 7fc3c14bb207facec9d330a8d74b23fb9aefdb58
    chg030_verification_before: 49f284b397006fa8626e76ec2fa51f5d9a88e307
    agent_pr_workflow: 41426544637db25224dc6c6b3718abd4ebbfca7c
    sdd_guard_workflow: 809147e462512d970813d1992a3fcdf41f8b4b10
    swift_ci_workflow: 640065f3f3849e1add0cc6bfa92078873eb315ef
    agent_pr_contract: 6a256a1556827c2153df0785479c5cbc53796f28
    check_pr_paths: 267417ca5d0f9a2bd5ef775314b93915717aea9b
    check_pr_paths_tests: 2aa1e2cb37ef0085d2e101adb34d2b3615246b82
    pr_envelope: c990fcfb17de52ed1166fec55cb1f9365e0e7736
    pr_envelope_tests: 35d9a284e8ddde67fd1076bc1c2f0f11f02d26db
    ```

    CHG-2026-030 #419 contract evidence blob
    `610fad98fe97f0618d04adafd313ebb72bdd0549` 与 #421 failure evidence
    blob `9fc841f46c9b62ff74eede541b00890e1c6f6dbe` 必须 byte-for-byte
    不变；它们只作 source PASS/live FAIL 历史。
  - **Current branch/ref/concurrency gate:closed。**audit base 的 remote
    `main` 恰为 `d869f9a36ec95e30bc1fba3c649ed414ca36bf0a`；Agent-side
    `gh auth status` 为 zero logged-in hosts。公开 all-open PR 只有 #468，其完整
    diff 仅含 CHG-2026-026 TASK-RKFUI-001A 三个 evidence path，与本 readiness、
    workflow/parser、RPT/HLR evidence 和 target refs 零交集。计划分支
    `agent/task-hlr-002a-canary-readiness` 与
    `agent/task-hlr-002a-canary-evidence-r8`、全部
    `agent/host-loop/**` remote refs 以及下列两个 exact refs 均 absent。
    PR/file pagination、Git/ref query 或 overlap 判定不完整时不得执行。
  - **Fresh target refs:closed。**

    ```yaml
    reserved_canary: agent/host-loop/probes/8bd61cc3-d7c7-41ff-bfc8-0c62952afba3
    ordinary_canary: agent/hlr-002a-control/5a2570ed-5916-4cc8-ac84-4afa294e4b9e
    evidence_branch: agent/task-hlr-002a-canary-evidence-r8
    ```

    两个 UUID 均为本次 discovery 生成的 lowercase RFC 4122 v4，旧 #421/#435/
    #454 ref、UUID、branch、head 一律不得替换或复用。执行前任一 target 已存在
    或 evidence branch/同 head all-state PR 非零即停止，不临时换名。
  - **Canary order:binary。**本 readiness PR 合入后，以其经 exact-head
    `lvye` review、required `guard`、`mergedBy=lvye`、subject `(#N)` 与
    protected-main history 共同确认的 squash merge OID 作为两个 empty commit
    的共同 parent；两个 tree 均与该 parent 相同，commit subject 不含 Actions
    skip instruction。严格先 push reserved，取得 exact-head SDD Guard push
    `guard=success` 且 legacy `agent-pr` run/PR 数均为 0；重读 main 不变后再
    push ordinary，取得 exact-head SDD Guard `guard=success`、唯一 terminal
    success `agent-pr` run 与唯一 `github-actions[bot]` open PR。任一 0/2
    ordinary creator、reserved creator 非零、head guard 缺失、main/blob/ref/PR
    overlap 漂移或 API ambiguity 均停止。
  - **Cleanup/evidence boundary:binary。**cleanup 前重复固定 ordinary PR
    number/head/author/`merged=false` 与两类 run/PR facts；随后 Deploy Key
    删除 ordinary 与 reserved refs并以 Git receipt + stable `ls-remote` absence
    复核。ordinary PR 必须最终 closed/unmerged；若 head deletion 未自动 close，
    只登记 residual cleanup 并停止下游，另请人类独立 close，不得 merge、
    approve、enable-auto-merge 或借用维护者 credential。canary facts只写入
    后一独立 evidence PR，本 readiness/implementation PR 不执行 ref/PR/write
    probe；evidence 合入后再以独立 D0 PR `ready→done`。HLR-002/003 在 done
    前继续 blocked。
  - **Permanent supersession:binary。**#435 OID/window/payload/hash/UUID/
    executor、#449/r6 gateway/authorization/lease、#454 readiness/pins/branch
    与 #421 run/head 只作历史，任何复制、改时间、补跑或重新解释均停止。
    TASK-HLR-002B 保持 superseded `blocked` tombstone。
- Historical Status:ready（r5 resume / r5 D2 re-readiness；维护者已 review/merge
  #435：exact head `a66138b7e9315badf86d2d493e8251dc1c6f7506` 于
  `2026-07-24T01:09:02Z` 以
  `5737c1b7127f2cbe98cfb953434b4a0dfe11498d` 合入 protected `main`；
  该 merge 只批准 r5 计划，未产生 D2 receipt、ref matrix、canary PASS 或 done。
  r6 合入后此状态与其绝对窗口永久 superseded。）
- Historical Status:ready（r5 resume / r5 D2 re-readiness；仅在维护者 review/merge 本独立
  readiness PR 后生效。#426 的 human-operation deferral 已以 exact merge OID
  `e56baa2f39998c1b3c2f7c6681b112dd1643ca7c` 进入 protected `main`，本 r5 从
  最新 main 重新完成 authenticated ruleset before/read-back、fresh refs/UUID、
  零 open conflict 与维护者可执行性勘察，并固定全新窗口
  `2026-07-24T02:30:00Z`→`03:30:00Z`。merge 只批准下述人类 D2 计划，不自行
  修改 ruleset；窗口/pin/read-back 任一不匹配时 PUT/ref/probe dispatch = 0。）
- Historical Status:blocked（#426 exact reviewed head
  `8beef9786a32ebb7e04eb8506a2223c946856d98` 由 `lvye` 对 exact head
  APPROVED，并于 `2026-07-23T14:45:14Z` 以 merge commit
  `e56baa2f39998c1b3c2f7c6681b112dd1643ca7c` 合入；first parent =
  `0dac14d9fe021d7bd52808b54c139003f1aced2f`，second parent = reviewed head。
  deferral 期间 zero PUT/ref/probe、无 receipt/PASS/done；本 r5 readiness 合入后
  仅解除“维护者不可执行”的 stop gate，其他 D2 二值门不放宽。）
- Historical Status:ready（r4 / r5 D2 re-readiness；#425 exact reviewed head
  `30e4d42669bdd256be70c4ee1c82c5f41e1a85ad` 由 `lvye` APPROVED，并以
  `0dac14d9fe021d7bd52808b54c139003f1aced2f` 合入 protected `main`；其唯一
  parent = r4 audit base `b5b4f239c90825bf55e79af6713d75d8c6169277`。r4
  固定的 `2026-07-24T02:00:00Z`→`03:00:00Z` 人类 D2 窗口现按维护者指示主动
  跳过；该 readiness 只批准计划，从未构成 D2 receipt、acceptance PASS 或
  done。）
- Historical Status:ready（r3 D2 re-readiness #424 merge
  `b5b4f239c90825bf55e79af6713d75d8c6169277` 后生效；维护者于旧窗口开始前明确
  选择跳过，zero PUT/ref/probe。`2026-07-23T14:12:17Z` 复查 ruleset
  `updated_at` 未变、仍只有 `refs/heads/agent/**` exclude，reserved/control refs
  与 open PR 均为 0，`gh` zero logged-in hosts。r4 merge 后 r3
  `2026-07-23T14:45:00Z`→`15:30:00Z` 窗口及其 UUID/script 永久 superseded，
  不得补跑或复用。）
- Historical Status:blocked（r5 stop gate；#423 合入 D1 revision 后继续保持，
  直至本 r5 D2 re-readiness 合入。
  implementation PR #419 exact reviewed head
  `39965af82bcb9a03f07e9501c844e86691b91d88` 已由 `lvye` APPROVED，并以
  `99ba8aa4b04018918daad2fc8830009c1030f6da` 合入；但首个 post-merge reserved
  probe `agent/host-loop/probes/ba0df001-6e7c-44de-939f-a355bda0a287` 创建被
  ruleset 以 GH013 `Cannot create ref due to creations being restricted` 拒绝。
  failure evidence #421 exact head
  `6bc957e1e198ffbbd771a2fae60d7a8d38008a86` 由 `lvye` APPROVED，并以
  `e4b33d036f796de7eb4aaed254724329ca040e68` 合入 protected `main`。reserved
  head guard 缺失、ordinary control 依序未执行，故 creator isolation 未建立；
  HLR-002 D2 readiness 禁止。）
- Historical Status:ready（#417 merge
  `e69a0c23b327571327bfce4a87d5e50f406db256` 后生效；r2 re-readiness 已使
  #419 implementation/repository gates 通过，但被 #421 live failure 与 r5 stop gate
  supersede。）
- Historical Status:blocked（r4 stop gate：readiness #411 后的 implementation candidate #412
  虽通过 offline filter contract、首次 branch guard 与唯一 legacy creator，但
  `pull_request/synchronize` SDD Guard run `29992997396` 的 `allowed-paths` job
  `89159873429` 因 pinned MECH-004 不识别 canonical `TASK-HLR-002A` 而失败。
  #412 已于 `2026-07-23T09:12:44Z` 关闭且 `merged=false`；CHG-2026-030 r4
  exact head `55b32e9f27f3cdc04ea772243e46f1f2a681ab4c` 已由维护者 `lvye`
  APPROVED，并以 `33050b0ceed5a4cfa400f3eb6829a724200a71de` 合入 protected
  `main`（#415）。本 r2 re-readiness 重新钉定后解除该 stop gate。）
- Historical Status:ready（#411 merge
  `6b40866e18fe33edc5973de5158f494adfdd48d2` 后生效；其 r1 readiness 因 #412
  首个 PR integration gate failure 被 r4 supersede，不能授权继续实现。）
- Historical Status:blocked（前置：① CHG-2026-030 revision r3 由维护者
  review/merge；② TASK-HLR-001 done；③ TASK-BAP-003 done；④ 独立 readiness PR
  钉定 `agent-pr.yml`/`sdd-guard.yml` blobs、GitHub Actions branch-filter semantics、
  reserved namespace grammar、control/canary 矩阵与零 open workflow conflict。r3
  proposal 合入本身不使本任务 ready。）
- r7 remediation（historical prerequisite；由 merged r8 readiness 闭合）：
  - **Authority gate:required。**CHG-2026-033 TASK-RPT-001 必须先按独立
    D2 readiness 由维护者在人类隔离会话完成 main protection + ordinary ruleset
    fail-closed migration，并以独立 evidence/done PR 合入。Agent、Deploy Key、
    GitHub App、Actions token、integration identity 与本 task 均无 ruleset/
    protection/repository-setting/credential write authority。
  - **Supersession gate:closed。**#449/r6 gateway 与 #454 readiness 只作历史；
    TASK-HLR-002B 不得 implementation/done，standing authorization、gateway
    credential lookup、ruleset PUT/rollback 与其派生 probe dispatch = 0。
  - **Fresh readiness gate:carried by r8。**TASK-RPT-001 done 后，r8
    compatible revision/readiness 固定其 evidence merge OID、current protected
    main、authenticated topology evidence pins、全新 reserved/ordinary canary
    refs 与 concurrency。只有本 r8 PR 经维护者 review/merge 后才解除；该
    readiness 只授权 creator canary/evidence，任何管理设置 drift 退回
    CHG-2026-033，不在本 task 修复。
  - **Historical evidence:preserved。**#419 source/repository PASS 与 #421 GH013
    live FAIL 原样有效；旧 readiness、window、payload、hash、UUID 不能升级为新
    topology 或 fresh canary PASS。
- r6 remediation（historical；由 r7 supersede）：
  - **Supersession fact:closed。**#435 的 exact reviewed head/merge 已进入 protected
    main，但其执行计划把任何 main 前进、任何 open PR 与绝对窗口都作为全局 stop。
    该计划没有形成 ruleset PUT/read-back、ref matrix、canary 或 acceptance PASS。
    r6 merge 后，#435、其 probes 与所有临时 executor 只作历史；不得改时间、改
    preflight 或补跑。
  - **New dependency gate:required。**新增 TASK-HLR-002B 必须先以独立
    readiness/implementation-evidence/done PR 交付并固定 constrained gateway、
    authorization parser、sensitive manifest、overlap classifier、relative-window
    clock 与 scoped lease。HLR-002B 未 done 时 HLR-002A 不得 ready，也不得创建有效
    standing authorization 或 provision privileged gateway。
  - **Sensitive drift gate:binary。**新的 readiness manifest 只固定本 change 四文档、
    `.github/workflows/agent-pr.yml`、`.github/workflows/sdd-guard.yml`、
    `scripts/test_agent_pr_workflow.py`、`scripts/check_pr_paths.py`、
    `scripts/test_check_pr_paths.py`、ruleset `19595282` 的 canonical before/after/
    rollback 与 active-rule projection，以及 fresh exact target refs。执行时 readiness
    merge 必须是 current main ancestor，且这些 path blobs/external projections 全等；
    其他 path 的 main commit 可前进。
  - **Overlap gate:binary。**分页读取全部 open PR 与每个 PR 的完整 files；只有触碰
    sensitive paths、HLR-002A/002B task/evidence、同一 readiness/executor branch、
    同一 operation/lease key 或同一 target refs 才阻断。无关 open PR 不阻断。
    pagination/API/metadata 不完整或无法证明不相交时 fail closed。
  - **Relative window/lease gate:binary。**窗口固定为 readiness GitHub
    `merged_at` 的半开区间 `[+15m,+45m)`；local observation/commit timestamp 不可
    替代。gateway 必须先 CAS acquire
    `ArkDeck/ArkDeck + ruleset:19595282 + target-patterns(agent/**,agent/**/*)`，
    并在每个 privileged
    read/write 前复核 authorization、fence、expiry 与 operation digest。lease 只冻结
    gateway 内同 ruleset/ref namespace 的 D2，不冻结 main 或无关 PR/merge。
  - **Standing authorization gate:required。**维护者必须创建/修改并 merge
    authorization-bearing readiness carrier，固定 authorization ID、
    repository/ruleset/method/endpoint、
    exact body/before/after/rollback/manifest/gateway hashes、target refs、lease key、
    `valid-from=readiness.merged_at+15m`、
    `valid-until=readiness.merged_at+45m`、`maxUses=1`、rollback contact 与 revoke
    conditions。Agent 不得创建、修改、批准或撤销它；raw credential 不得出 gateway。
  - **Agent execution gate:binary。**窗口内 Agent 只能调用
    `executeAuthorizedRulesetDelta(canonicalRequest)`。gateway 依序完成 authorization/
    manifest/overlap/window/lease preflight、authenticated before、exact one-shot
    mutation、immediate exact-after、active-rule/ref verification、immutable redacted
    receipt、consume use、release。timeout 先 read-back；after 不匹配在同 fence 下
    exact rollback/read-back 后停止。generic REST/GraphQL、任意 endpoint/body、
    review/merge/admin CRUD 或 arbitrary ref method 构造数必须为 0。
  - **Evidence/done boundary。**authorization-bearing r6 readiness 由维护者创建/
    修改并 merge，但 merge 本身不执行 D2。gateway receipt + ref matrix + fresh canary
    使用独立 evidence PR，只追加本任务 evidence；其 merge 后再以独立 D0 PR
    `ready→done`。HLR-002 在 HLR-002A done 前持续 blocked。
- Historical human-operation deferral stop gate：
  - **Decision fact:closed。**维护者明确表示无法执行脚本，并要求所有需要本人
    操作的任务跳过；本状态只把 TASK-HLR-002A 从 `ready` 转为 `blocked`，不把
    “跳过”冒充完成、验证或平台豁免。
  - **Zero-execution fact:closed。**截至 `2026-07-23T14:34:46Z` 的公开只读
    read-back，ruleset ID `19595282` 仍是 active、include `~ALL`、仅 exclude
    `refs/heads/agent/**`、creation/update/deletion，`updated_at =
    2026-07-23T02:20:11.425Z`；`agent/host-loop/**` 与
    `agent/hlr-002a-control/**` refs = 0、open PR = 0，`gh` zero logged-in
    hosts。没有 ruleset PUT、probe dispatch、ref create/delete 或 receipt。
  - **Dependency consequence:closed。**TASK-HLR-002 依赖本任务 done，且仍另需
    人类 integration identity/secret/scheduler D2；TASK-HLR-003 依赖 HLR-002，
    HLR-004/005 再依赖 HLR-003。因此本 change 没有可合法跳转执行的 AI-only
    ready task，下游全部 fail closed。
  - **Resume boundary:closed。**以后若恢复，先以独立 readiness PR 从最新
    protected `main` 重做 authenticated ruleset before/read-back、fresh ref
    absence、fresh UUID、exact maintenance window、operator availability 与
    rollback pin；该 PR 合入前仓外写仍为 0。旧 executor 仅是历史载体，不得补跑
    或改时间复用。
  - **Review boundary。**本状态 PR 只修改本文件 TASK-HLR-002A section；零
    ruleset/API/ref/probe/credential/scheduler 仓外写，零 source/workflow/test/
    evidence 改写。merge 只批准暂停和下游停链，不批准任何 D2 动作。
- r5 remediation（D1 revision audit base = protected `main`
  `e4b33d036f796de7eb4aaed254724329ca040e68`）：
  - **Failure fact:closed。**#419 implementation 的 offline、push、bot-PR、
    pull-request `guard`/`allowed-paths` 与 Swift gates 全绿；source 不返工。live r1
    empty commit `93ede0415f14cd28bc69c0e593151a06a247afda` 的 parent =
    #419 merge `99ba8aa4b04018918daad2fc8830009c1030f6da`、tree 与 parent 相同，
    但首次 reserved push exit 1/GH013。exact ref、head-SHA workflow runs 与
    all-state PR read-back 均为 0；这只证明 ref 未创建，不是 legacy creator
    isolation PASS。ordinary run id
    `f9b8ca5a-c7e2-481e-8be8-a3918034403b` 未创建/未推送。完整事实见
    `evidence/runs/TASK-HLR-002A/live-canary-r1-fail.md`（#421）。
  - **Root cause:closed。**TASK-BAP-003 ruleset `agent-ref-boundary`
    ID `19595282` 的在案 target 是 include `~ALL`、exclude
    `refs/heads/agent/**`，真实正向只覆盖单层 `agent/cred-probe`。GitHub ruleset
    `File::FNM_PATHNAME` 下 `*` 不跨 `/`，故 multi-level reserved/control refs
    仍命中 creation restriction。r5 固定最小 delta：保留现有 exclude，**只追加**
    `refs/heads/agent/**/*`；保留 active enforcement、`~ALL`、
    creation/update/deletion rules、Deploy Key non-bypass 与仅维护者 bypass。
  - **Revision boundary:closed。**本 r5 PR 只改本 change proposal/design/tasks/
    verification，把任务 `ready→blocked` 并批准 remediation 方案；零 workflow/
    parser/runtime/evidence 改写，零 ruleset/API/ref/PR/Issue/credential/scheduler
    外部写。r5 merge 是 D1 方案批准，不是 D2 配置授权或 readiness。
  - **Independent D2 re-readiness:required。**r5 merge 后另起只含本任务
    `blocked→ready` 与 readiness 载体的 PR，必须钉定：当时 protected-main OID；
    ruleset ID/完整 before JSON 与 hash；exact additive after；active-rule evaluation；
    维护者操作者/窗口/rollback contact；完整 rollback bytes；fresh 单层/多层/
    non-agent probe names；fresh reserved/ordinary UUIDv4；零 open 冲突与目标 refs
    absent。该 readiness 合入前零仓外配置，门后零投机成 PR。
  - **D2 execution/read-back:binary。**仅维护者在 readiness 窗口应用 exact delta，
    immediately read-back after 并证明除新增 pattern 外 diff = 0。pattern 过宽、
    fields/bypass/rules 漂移或 read-back 不确定时恢复完整 before、停止。Agent 不持
    ruleset admin，不代为修改。
  - **Ref matrix:binary。**同一 Deploy Key 对 single-level `agent/<probe>` 与
    multi-level reserved/control create-delete 成功；对 fresh non-agent ref create
    与基于 empty commit 的 direct-main update 均收到 GH013，且 main OID 前后相同。
    任一负向意外成功是权限扩大事故，cleanup 后仍 FAIL。
  - **Fresh canary:binary。**ruleset after 与 ref matrix 闭合后，重新钉当时稳定的
    protected-main OID；reserved/ordinary 两个 empty commit 共用该 parent/tree，
    run ID/head 不复用 r1。先 reserved 后 ordinary；两者 exact-head SDD Guard
    success，reserved Agent PR run/PR count = 0，ordinary Agent PR run terminal
    success且 bot PR count = 1。main 在两次 push 间前进、API ambiguity 或目标 ref
    预存在均停止。事实闭合后 close control PR、删除 refs，并 read-back PR
    `merged=false`/refs absent；cleanup 不覆盖 PASS/FAIL。
  - **Evidence/done boundary。**D2 receipt + fresh live facts 使用独立 evidence PR，
    只追加本任务 evidence，不改 source/status；其 merge 后再以独立 D0 PR
    `ready→done`。HLR-002 在 HLR-002A done 前持续 blocked。
- Readiness（r5 resume / r5 D2 re-readiness，audit base = protected `main`
  `e9406075cb6ac1401447d2f90c22ffc488a05512`）：
  - **Deferral/resume gate:satisfied。**#426 exact head
    `8beef9786a32ebb7e04eb8506a2223c946856d98` 由 `lvye` 于
    `2026-07-23T14:44:52Z` 起对 exact head APPROVED，并于
    `2026-07-23T14:45:14Z` 以 merge commit
    `e56baa2f39998c1b3c2f7c6681b112dd1643ca7c` 合入 protected `main`；
    merge parents 依序为 #425 merge
    `0dac14d9fe021d7bd52808b54c139003f1aced2f` 与 reviewed head。维护者现已明确
    恢复执行脚本/真机的人类可用性；本 task 仍为 host-only、零真机。#426 至本
    audit base 的后续合入只涉及 CHG-2026-023/031，未修改本 change、workflow、
    parser 或 HLR evidence。r5 D1、#419 source、#421 failure、TASK-BAP-003 done
    与 #426 deferral 均为本 audit base ancestor。
  - **Git/input/concurrency pins。**下列 Git objects 在本 audit base 实测。本
    readiness merge 的 first parent 必须恰为本 audit base、diff 只允许本
    TASK-HLR-002A section；任一 main/input drift、并发路径占用或窗口前未 merge
    立即使 r5 resume 失效，必须重新 discovery/readiness，不顺延窗口或复用 probes。

    ```yaml pins
    - artifact: TASK-HLR-002A r5-resume D2 readiness audit base
      commit: e9406075cb6ac1401447d2f90c22ffc488a05512
    - artifact: TASK-HLR-002A human-operation deferral reviewed head
      commit: 8beef9786a32ebb7e04eb8506a2223c946856d98
    - artifact: TASK-HLR-002A human-operation deferral merge
      commit: e56baa2f39998c1b3c2f7c6681b112dd1643ca7c
    - artifact: CHG-2026-030 revision r5 merge
      commit: b62762010705b3ff6c7fc864a86aec76563d3f01
    - artifact: TASK-HLR-002A implementation merge
      commit: 99ba8aa4b04018918daad2fc8830009c1030f6da
    - artifact: TASK-HLR-002A failure evidence merge
      commit: e4b33d036f796de7eb4aaed254724329ca040e68
    - artifact: TASK-BAP-003 done merge
      commit: 6a6b6b7010b6563d67aa7d96e6838505e82eb25a
    - path: .github/workflows/agent-pr.yml
      blob: 41426544637db25224dc6c6b3718abd4ebbfca7c
    - path: .github/workflows/sdd-guard.yml
      blob: 809147e462512d970813d1992a3fcdf41f8b4b10
    - path: .github/workflows/swift-ci.yml
      blob: 640065f3f3849e1add0cc6bfa92078873eb315ef
    - path: scripts/test_agent_pr_workflow.py
      blob: 6a256a1556827c2153df0785479c5cbc53796f28
    - path: scripts/check_pr_paths.py
      blob: 267417ca5d0f9a2bd5ef775314b93915717aea9b
    - path: scripts/test_check_pr_paths.py
      blob: 2aa1e2cb37ef0085d2e101adb34d2b3615246b82
    - path: openspec/changes/chg-2026-030-host-loop-runtime/proposal.md
      blob: 21ac153075aaeb44a81808effa6257e71561b03c
    - path: openspec/changes/chg-2026-030-host-loop-runtime/design.md
      blob: fbab391e567bee468e84e9f9084023c420147d25
    - path: openspec/changes/chg-2026-030-host-loop-runtime/tasks.md
      blob: 9c97a5135075eb82984234bf9005d93e7941ba8a
    - path: openspec/changes/chg-2026-030-host-loop-runtime/verification.md
      blob: ae3b1baa203362434094f96f7c4af88fb8101882
    - path: openspec/changes/chg-2026-030-host-loop-runtime/evidence/runs/TASK-HLR-002A/live-canary-r1-fail.md
      blob: 9fc841f46c9b62ff74eede541b00890e1c6f6dbe
    - path: openspec/changes/chg-2026-027-decision-grading-batch-approval/evidence/runs/TASK-BAP-003/run.md
      blob: d6eaf28e188b1f5f64317ce4eacad22eae10ab10
    ```

    `tasks.md` 是本 readiness 自载体，上列为修改前 blob；merge 后改为核验其
    parents、reviewed head 与 diff-only-self-section。本 discovery 捕获时
    readiness branch `agent/hlr-002a-r5-d2-readiness-r5` remote ref absent、
    all-state PR = 0，本仓 open PR = 0；`2026-07-24T01:01:22Z` 的公开复核仍为
    open PR = 0、reserved/control refs = 0、protected main = audit base。
  - **Fresh authenticated ruleset before:closed。**维护者控制的 resume discovery
    于 `2026-07-24T01:00:11.764317Z` 以 actor `lvye`
    (`actor_id=4340161`) 执行 authenticated GitHub GET only；schema =
    `arkdeck-hlr002a-r5-resume-discovery/v1`，零 secret value、零 repository/
    ruleset/ref/PR/Issue write。完整 ruleset 响应按 UTF-8、sorted keys、
    separators `(',', ':')`、no trailing LF canonicalize 后 byte count = `702`、
    SHA-256 =
    `a5725db245d84174090de47e1fc45123219dbf5cfdd00d45856b04d801a3d5f2`：

    ```json
    {"_links":{"html":{"href":"https://github.com/ArkDeck/ArkDeck/rules/19595282"},"self":{"href":"https://api.github.com/repos/ArkDeck/ArkDeck/rulesets/19595282"}},"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**"],"include":["~ALL"]}},"created_at":"2026-07-23T10:20:11.391+08:00","current_user_can_bypass":"always","enforcement":"active","id":19595282,"name":"agent-ref-boundary","node_id":"RRS_lACqUmVwb3NpdG9yec5Na16-zgErABI","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"source":"ArkDeck/ArkDeck","source_type":"Repository","target":"branch","updated_at":"2026-07-23T10:20:11.425+08:00"}
    ```

    bypass 恰为维护者 `(4340161, User, always)`；Deploy Key 不在 bypass。
    discovery 完成后维护者已执行 logout，`2026-07-24T01:01:22Z` 的外部
    `gh auth status` 为 zero logged-in hosts；公开 ruleset ID/name/enforcement/
    conditions/rules/created_at/updated_at 与 authenticated before 一致。
  - **Fresh exact rollback bytes:closed。**任一 PUT/read-back/active-rule
    evaluation 或字段比较失败时，维护者必须向 ruleset `19595282` PUT 下列完整
    canonical bytes；byte count = `301`、SHA-256 =
    `5943b6ce840cbb385ad83615da15ff2ee4ec5710bd696fae6140b37302042157`：

    ```json
    {"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**"],"include":["~ALL"]}},"enforcement":"active","name":"agent-ref-boundary","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"target":"branch"}
    ```

    rollback 后立即 authenticated GET、重构同一 write payload 并复核 hash；无法
    证明恢复即停止，TASK-HLR-002A 回到 `blocked`，ref matrix dispatch = 0。
  - **Fresh exact additive after:closed。**唯一获准 endpoint =
    `repos/ArkDeck/ArkDeck/rulesets/19595282`，method = `PUT`；body 必须逐字为
    下列 canonical UTF-8 bytes，byte count = `325`、SHA-256 =
    `8537b85939b7be059c19601360cadb95bdf4f0abe5151d5948bb6f7826405d30`：

    ```json
    {"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**","refs/heads/agent/**/*"],"include":["~ALL"]}},"enforcement":"active","name":"agent-ref-boundary","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"target":"branch"}
    ```

    before→after 只允许 append `refs/heads/agent/**/*`；原 single-level exclude、
    `~ALL`、active enforcement、三个 rules、maintainer-only bypass 与字段顺序均
    保持。PUT 后 immediate authenticated GET；重构 write payload 必须与上述
    bytes/hash 相同。任何 extra/missing/reorder、broad bypass、`updated_at` 不前进
    或 API ambiguity 立即 rollback，不解释性放行。
  - **Fresh maintenance gate:closed。**operator = `@lvye`
    (`actor_id=4340161`)；rollback contact = `@lvye`；固定窗口 =
    `2026-07-24T02:30:00Z`（北京时间 `10:30`）至
    `2026-07-24T03:30:00Z`（北京时间 `11:30`）。本 readiness 未在窗口前
    review/merge、merge first parent 不等于 audit base、main/ruleset/ref/open
    conflict 任一 pin 漂移、operator 不匹配、时钟不确定或窗口外，PUT = 0；
    不得顺延或复用 r3/r4 script/window/UUID。readiness merge 后才可生成绑定本
    PR/head/merge/parents 与下列 probes 的 fresh executor；Agent 不持 ruleset
    admin，不代替维护者执行 PUT。
  - **Fresh active-rule/ref matrix:closed。**authenticated discovery 对 before
    实测：single Agent = 0；reserved/control/canary 四个 multi-level Agent ref、
    `main`、non-agent 与 `agentx/**` 相似前缀均只命中 ruleset `19595282` 的
    creation/update/deletion。after 预期：single 与四个 multi-level Agent refs
    均为 0；`main`、non-agent、similar-prefix 继续命中 exact 三条。七个 target
    refs 全部 exact absent：

    ```yaml probes
    single_agent: agent/hlr002a-single-ee9e135e-0db5-4ec8-8c9c-fbe6ceb858dd
    reserved_matrix: agent/host-loop/probes/ce790c41-8304-48c0-a198-768939cb9e39
    control_matrix: agent/hlr-002a-control/b6499c18-708a-4509-867b-e5b445041b5d
    non_agent: hlr002a-denied-23a0704f-78c4-493a-94a9-8a8f083c8ced
    similar_prefix: agentx/host-loop/probes/2d0c7628-0930-4a19-b8df-78babbeb47f1
    reserved_canary: agent/host-loop/probes/d0e9a475-d5e8-4ecf-af30-0aec950ef3dd
    ordinary_canary: agent/hlr-002a-control/4d6da223-b496-4b12-bbd4-a1697999f824
    ```

    D2 preflight 必须再次读取全部 target refs 与 active rules；任一 ref 存在、
    rule/source/type 漂移、旧 UUID 被误用或 open overlapping operation 出现均停止，
    不换名补跑。
  - **D2 execution/read-back:binary。**readiness merge 后且仅在窗口内：
    (1) 维护者 authenticated GET + exact rollback hash preflight；
    (2) PUT exact after bytes；
    (3) immediate authenticated GET/write-payload hash read-back；
    (4) active-rule after matrix read-back；任一步失败先 PUT exact rollback 并验证，
    随后停止；
    (5) exact after 与 active rules 闭合后，维护者退出 `gh` 并交回零 secret 的
    receipt；此时才允许 non-bypass Deploy Key 依次执行 single/reserved/control
    create-delete、non-agent create GH013 与 direct-main empty-commit update GH013。
    main OID 前后必须相同；任一负向意外成功是权限扩大事故，cleanup 不改变 FAIL。
  - **Fresh canary/evidence order:binary。**ruleset receipt + ref matrix PASS 后重读
    stable protected-main OID；reserved/ordinary 各建 fresh empty commit，共用该
    parent/tree，严格 reserved-first/ordinary-second。两者 exact-head SDD Guard
    success；reserved Agent PR run/PR = 0；ordinary Agent PR run terminal success
    且 bot PR = 1。main 前进、head guard 缺失、0/2 PR、API ambiguity 或 target
    preexist 均停止。闭合后才 close ordinary PR并 read-back `merged=false`、删除
    refs并复查 absent。D2 receipt + ref matrix + canary facts 使用后续独立 evidence
    PR，只追加 evidence；其合入后再走独立 D0 `ready→done`。
  - **Review boundary。**本 r5-resume readiness PR 只修改本文件
    TASK-HLR-002A section，登记 `blocked→ready`、#426 closure、fresh pins/
    authenticated before/window/probes；零 source/workflow/test/evidence，零
    ruleset/API/ref/PR/Issue/credential/scheduler 仓外写。merge 只批准计划，不是
    D2 receipt、acceptance PASS 或 done；HLR-002 在 HLR-002A done 前持续 blocked。
- Historical Readiness（r4 / r5 D2 re-readiness，audit base = protected `main`
  `b5b4f239c90825bf55e79af6713d75d8c6169277`）：
  - **r3 skip fact:closed。**#424 exact reviewed head
    `bba513aebd227195e859165f51573f8beb80a518` 由 `lvye` 于
    `2026-07-23T13:58:33Z` APPROVED，五个 exact-head push/pull-request runs
    全部 terminal success，并于 `2026-07-23T14:03:29Z` squash merge 为
    `b5b4f239c90825bf55e79af6713d75d8c6169277`；其唯一 parent 恰为 r3 audit
    base `b62762010705b3ff6c7fc864a86aec76563d3f01`，reviewed head→merge 的
    `tasks.md` tree diff = 0。旧 executor script 在窗口前
    `2026-07-23T14:08:01Z` 只触发 time-lock，status=`blocked`、write count = 0；
    维护者随后明确跳过本窗口。`2026-07-23T14:12:17Z` 公开 read-back 再证明
    ruleset ID/name/enforcement/conditions/rules/created_at/updated_at 与 r3 before
    相同，`agent/host-loop/**`/`agent/hlr-002a-control/**` refs = 0、open PR = 0，
    maintainer `gh` 仍不可达。没有 D2 receipt，也没有可复用的 PASS。
  - **Approval/base gate:closed。**本 r4 只移动未执行的人类维护窗口并更换全部
    probe UUID；r5 D1、#419 source、#421 failure、#424 r3 readiness 与
    TASK-BAP-003 done 均为本 audit base ancestor。下列当前 Git pins 实测：

    ```yaml pins
    - artifact: TASK-HLR-002A r4 D2 re-readiness audit base
      commit: b5b4f239c90825bf55e79af6713d75d8c6169277
    - artifact: TASK-HLR-002A r3 readiness reviewed head
      commit: bba513aebd227195e859165f51573f8beb80a518
    - artifact: TASK-HLR-002A r3 readiness merge
      commit: b5b4f239c90825bf55e79af6713d75d8c6169277
    - path: .github/workflows/agent-pr.yml
      blob: 41426544637db25224dc6c6b3718abd4ebbfca7c
    - path: .github/workflows/sdd-guard.yml
      blob: 809147e462512d970813d1992a3fcdf41f8b4b10
    - path: scripts/test_agent_pr_workflow.py
      blob: 6a256a1556827c2153df0785479c5cbc53796f28
    - path: scripts/check_pr_paths.py
      blob: 267417ca5d0f9a2bd5ef775314b93915717aea9b
    - path: scripts/test_check_pr_paths.py
      blob: 2aa1e2cb37ef0085d2e101adb34d2b3615246b82
    - path: openspec/changes/chg-2026-030-host-loop-runtime/proposal.md
      blob: 21ac153075aaeb44a81808effa6257e71561b03c
    - path: openspec/changes/chg-2026-030-host-loop-runtime/design.md
      blob: fbab391e567bee468e84e9f9084023c420147d25
    - path: openspec/changes/chg-2026-030-host-loop-runtime/tasks.md
      blob: 8f0a159642bcf2560507290dcab463ef02c8372a
    - path: openspec/changes/chg-2026-030-host-loop-runtime/verification.md
      blob: ae3b1baa203362434094f96f7c4af88fb8101882
    ```

    本 r4 merge 的 first parent 必须恰为 audit base，diff 只允许本
    TASK-HLR-002A section；否则 r4 失效。readiness branch
    `agent/hlr-002a-r5-d2-readiness-r4` 在 audit 时 remote ref absent、all-state
    PR = 0，本仓 open PR = 0。
  - **Ruleset bytes re-pin:closed。**r3 `Authenticated ruleset before` 的完整
    702-byte JSON/SHA-256
    `a5725db245d84174090de47e1fc45123219dbf5cfdd00d45856b04d801a3d5f2`、
    `Exact rollback bytes` 的 301-byte payload/SHA-256
    `5943b6ce840cbb385ad83615da15ff2ee4ec5710bd696fae6140b37302042157` 与
    `Exact additive after` 的 325-byte payload/SHA-256
    `8537b85939b7be059c19601360cadb95bdf4f0abe5151d5948bb6f7826405d30`
    逐字继续构成本 r4 carrier；三段 canonical JSON 原文见紧随其后的 Historical
    Readiness r3，r4 不重排、不省略。公开 ruleset `updated_at =
    2026-07-23T02:20:11.425Z` 未前进，因此 authenticated hidden bypass pin 仍由
    r3 完整响应 + 未漂移 timestamp 双重固定。D2 preflight 仍须 authenticated GET
    逐字复核完整 before/hash；不匹配则 PUT = 0。
  - **New maintenance gate:closed。**operator = `@lvye`
    (`actor_id=4340161`)；rollback contact = `@lvye`；新固定窗口 =
    `2026-07-24T02:00:00Z`（北京时间 `10:00`）至
    `2026-07-24T03:00:00Z`（北京时间 `11:00`）。r4 未在窗口前 merge、main/
    ruleset/ref/open-conflict 任一 pin 漂移、operator 不匹配、时钟不确定或窗口外，
    PUT = 0；不得把旧脚本改时间后复用。r4 merge 后才可生成绑定 r4 PR/head/merge/
    parent 与下列 UUID 的 fresh executor；Agent 仍不持 admin、不执行 PUT。
  - **Fresh active-rule/ref matrix:closed。**以下 ref 在
    `2026-07-23T14:12Z` 后生成，逐个 exact-ref GET = 404。before active-rule
    实测：single Agent = 0；其余六项均只命中 ruleset `19595282` 的
    creation/update/deletion。after 预期：single、reserved/control matrix 与两
    canary = 0；non-agent/similar-prefix 与 main 继续命中 exact 三条。

    ```yaml probes
    single_agent: agent/hlr002a-single-af2cd10c-078d-4af7-b0a3-d385c335a46c
    reserved_matrix: agent/host-loop/probes/9b94a7cf-e3f2-4a6b-b167-3902b95392c3
    control_matrix: agent/hlr-002a-control/3f96c625-ea0b-476a-9e03-19c4819e6c28
    non_agent: hlr002a-denied-435885e9-170d-42db-8384-d3e38e5823d3
    similar_prefix: agentx/host-loop/probes/722d0d68-135f-4166-9e1a-50c2751b33ff
    reserved_canary: agent/host-loop/probes/2b3b5047-a43c-4910-b222-2f6fe784344f
    ordinary_canary: agent/hlr-002a-control/810b17ba-d16d-4cda-aefc-d85e9c810b92
    ```

    任一 ref 在 D2 preflight 前出现、active rules 漂移或旧 r3 UUID 被误用均停止，
    不换名补跑。exact after read-back 后的 ref matrix、fresh canary、cleanup 与
    evidence/done 分离顺序逐字沿用 r3；r4 不放宽任何 PASS/FAIL 门。
  - **Review boundary。**本 r4 PR 只修改本文件 TASK-HLR-002A section，记录旧窗口
    zero-write skip、更新 audit base/window/fresh refs，并把 r3 标为 historical；
    零 ruleset/API/ref/probe/credential/scheduler 仓外写，零 source/workflow/test/
    evidence 改写。merge 只批准新窗口，不是 D2 receipt、acceptance PASS 或 done。
- Historical Readiness（r3 / r5 D2 re-readiness，audit base = protected `main`
  `b62762010705b3ff6c7fc864a86aec76563d3f01`）：
  - **Approval/dependency gate:satisfied。**CHG-2026-030 r5 #423 exact reviewed
    head `4fd9878b50d8dfccc5c36ed08d04e8e30b79efb7` 由 `lvye` 于
    `2026-07-23T11:26:45Z` APPROVED，并于 `2026-07-23T11:26:56Z` 以
    `b62762010705b3ff6c7fc864a86aec76563d3f01` 合入 protected `main`；
    merge first parent =
    `5a60d37fb736a6172a1053fe7a4cfff96f362ab7`（独立 #422），subject 携
    `(#423)`，reviewed head→merge 对本 change 四文档 tree diff = 0。
    #419 implementation merge
    `99ba8aa4b04018918daad2fc8830009c1030f6da`、#421 failure evidence merge
    `e4b33d036f796de7eb4aaed254724329ca040e68` 与 TASK-BAP-003 done merge
    `6a6b6b7010b6563d67aa7d96e6838505e82eb25a` 均为本 audit base ancestor。
    本 readiness decision grade = D2；仓外动作只含维护者在固定窗口对
    ruleset `19595282` 应用 exact one-pattern delta 与 immediate read-back。
  - **Git/input pins。**下列 Git objects 在本 audit base 实测。本 readiness
    merge 的 first parent 必须恰为本 audit base、diff 必须只修改本
    TASK-HLR-002A section；任一 drift、并发路径占用或非 fast current-main
    review 立即使本 readiness 失效，重新起草，不延用本窗口或 probes。

    ```yaml pins
    - artifact: TASK-HLR-002A r5 D2 re-readiness audit base
      commit: b62762010705b3ff6c7fc864a86aec76563d3f01
    - artifact: CHG-2026-030 revision r5 reviewed head
      commit: 4fd9878b50d8dfccc5c36ed08d04e8e30b79efb7
    - artifact: CHG-2026-030 revision r5 merge
      commit: b62762010705b3ff6c7fc864a86aec76563d3f01
    - artifact: TASK-HLR-002A implementation merge
      commit: 99ba8aa4b04018918daad2fc8830009c1030f6da
    - artifact: TASK-HLR-002A failure evidence merge
      commit: e4b33d036f796de7eb4aaed254724329ca040e68
    - artifact: TASK-BAP-003 done merge
      commit: 6a6b6b7010b6563d67aa7d96e6838505e82eb25a
    - path: .github/workflows/agent-pr.yml
      blob: 41426544637db25224dc6c6b3718abd4ebbfca7c
    - path: .github/workflows/sdd-guard.yml
      blob: 809147e462512d970813d1992a3fcdf41f8b4b10
    - path: .github/workflows/swift-ci.yml
      blob: 640065f3f3849e1add0cc6bfa92078873eb315ef
    - path: scripts/test_agent_pr_workflow.py
      blob: 6a256a1556827c2153df0785479c5cbc53796f28
    - path: scripts/check_pr_paths.py
      blob: 267417ca5d0f9a2bd5ef775314b93915717aea9b
    - path: scripts/test_check_pr_paths.py
      blob: 2aa1e2cb37ef0085d2e101adb34d2b3615246b82
    - path: openspec/changes/chg-2026-030-host-loop-runtime/proposal.md
      blob: 21ac153075aaeb44a81808effa6257e71561b03c
    - path: openspec/changes/chg-2026-030-host-loop-runtime/design.md
      blob: fbab391e567bee468e84e9f9084023c420147d25
    - path: openspec/changes/chg-2026-030-host-loop-runtime/tasks.md
      blob: 5bc006b6f41200a1360b4f69a7cdf3cb9013e395
    - path: openspec/changes/chg-2026-030-host-loop-runtime/verification.md
      blob: ae3b1baa203362434094f96f7c4af88fb8101882
    - path: openspec/changes/chg-2026-030-host-loop-runtime/evidence/runs/TASK-HLR-002A/live-canary-r1-fail.md
      blob: 9fc841f46c9b62ff74eede541b00890e1c6f6dbe
    - path: openspec/changes/chg-2026-027-decision-grading-batch-approval/evidence/runs/TASK-BAP-003/run.md
      blob: d6eaf28e188b1f5f64317ce4eacad22eae10ab10
    ```

  - **Authenticated ruleset before:closed。**维护者控制的只读 discovery 于
    `2026-07-23T13:41:38.116565Z` GET
    `repos/ArkDeck/ArkDeck/rulesets/19595282?includes_parents=false`；classification
    = authenticated GET only、零 secret value、零 repository/ruleset/ref write。
    完整响应按 UTF-8、sorted keys、separators `(',', ':')`、no trailing LF
    canonicalize 后 byte count = `702`、SHA-256 =
    `a5725db245d84174090de47e1fc45123219dbf5cfdd00d45856b04d801a3d5f2`。
    canonical bytes 完整如下：

    ```json
    {"_links":{"html":{"href":"https://github.com/ArkDeck/ArkDeck/rules/19595282"},"self":{"href":"https://api.github.com/repos/ArkDeck/ArkDeck/rulesets/19595282"}},"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**"],"include":["~ALL"]}},"created_at":"2026-07-23T10:20:11.391+08:00","current_user_can_bypass":"always","enforcement":"active","id":19595282,"name":"agent-ref-boundary","node_id":"RRS_lACqUmVwb3NpdG9yec5Na16-zgErABI","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"source":"ArkDeck/ArkDeck","source_type":"Repository","target":"branch","updated_at":"2026-07-23T10:20:11.425+08:00"}
    ```

    `bypass_actors` 恰为维护者 `lvye` 的
    `(actor_id=4340161, actor_type=User, bypass_mode=always)`；Deploy Key ID
    `158088026` 不在 bypass。Agent origin 仍为 repository-scoped Deploy Key
    alias。维护者 discovery 后已退出 `gh`；Agent 外部复查 `gh auth status`
    exit 1/zero logged-in hosts。`2026-07-23T13:43:25Z` 再次公开 GET 的
    ID/name/enforcement/conditions/rules/created_at/updated_at 与上述 before
    一致；公开响应按 GitHub 保密边界省略 bypass，不以该省略推断空 bypass。
  - **Exact rollback bytes:closed。**若 after PUT、read-back、active-rule
    evaluation 或任一字段比较失败，维护者必须向同一 ruleset PUT 下列完整
    canonical bytes；byte count = `301`、SHA-256 =
    `5943b6ce840cbb385ad83615da15ff2ee4ec5710bd696fae6140b37302042157`：

    ```json
    {"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**"],"include":["~ALL"]}},"enforcement":"active","name":"agent-ref-boundary","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"target":"branch"}
    ```

    rollback 后立即 authenticated GET，重新构造同一 write payload 并复核上述
    SHA-256；无法证明恢复即停止，TASK-HLR-002A 回到 `blocked`，不执行 ref matrix。
  - **Exact additive after:closed。**唯一获准的 PUT endpoint =
    `repos/ArkDeck/ArkDeck/rulesets/19595282`，method = `PUT`；body 必须逐字为
    下列 canonical UTF-8 bytes，byte count = `325`、SHA-256 =
    `8537b85939b7be059c19601360cadb95bdf4f0abe5151d5948bb6f7826405d30`：

    ```json
    {"bypass_actors":[{"actor_id":4340161,"actor_type":"User","bypass_mode":"always"}],"conditions":{"ref_name":{"exclude":["refs/heads/agent/**","refs/heads/agent/**/*"],"include":["~ALL"]}},"enforcement":"active","name":"agent-ref-boundary","rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"target":"branch"}
    ```

    before→after 只允许 append `refs/heads/agent/**/*`；ID/name/target/
    enforcement/include、原 `refs/heads/agent/**`、三个 rules、bypass actor 与
    顺序均保持。PUT 后立即 authenticated GET；去除 read-only fields 后重构 exact
    write payload，必须与上述 bytes/hash 相同。任一额外/缺失/reorder、broad bypass、
    `updated_at` 不前进或 API ambiguity 立即 rollback，不解释性放行。
  - **Maintenance/rollback gate:closed。**operator = `@lvye`
    (`actor_id=4340161`)；rollback contact = `@lvye`；固定窗口 =
    `2026-07-23T14:45:00Z`（北京时间 `22:45`）至
    `2026-07-23T15:30:00Z`（北京时间 `23:30`）。本 readiness 未在窗口开始前
    merge、merge first parent 不等于 audit base、窗口外/时钟不确定、operator
    不匹配或 authenticated preflight payload hash 不等于 rollback hash时，PUT
    调用数必须为 0；不得自行顺延窗口。Agent 不持 ruleset admin，不执行 PUT。
    维护者完成 exact after read-back 后必须再次退出 `gh`，Agent 只消费脱敏 receipt。
  - **Active-rule evaluation pins:closed。**before 的 GitHub
    `GET /rules/branches/{branch}` 实测为：single-level Agent ref 零命中；reserved/
    control/canary 多层 ref、`main`、non-agent 与 `agentx/**` 相似前缀均只命中
    ruleset `19595282` 的 `creation/update/deletion`。after read-back 后预期：
    single-level 与四个 multi-level Agent refs 均零命中；`main`、non-agent 与
    `agentx/**` 仍各命中 exact 三条。缺/多/其他 ruleset、source/ID/type 漂移均 FAIL。
  - **Fresh branch/ref pins:closed。**discovery 时本仓 open PR = 0；readiness branch
    `agent/hlr-002a-r5-d2-readiness` remote ref absent、all-state PR = 0；
    下列七个 exact target refs 全部 absent，UUID 均为 fresh lowercase RFC 4122 v4：

    ```yaml probes
    single_agent: agent/hlr002a-single-f682845d-a3d2-4a96-8e49-bb41734e22dc
    reserved_matrix: agent/host-loop/probes/bce81c4f-44a6-4665-8404-dfb1a8652231
    control_matrix: agent/hlr-002a-control/5ec939cd-cbd8-4d25-b34f-618644d96a00
    non_agent: hlr002a-denied-d373e018-612d-4e79-bb07-c0b4dced767f
    similar_prefix: agentx/host-loop/probes/b5004775-00c0-4535-951b-068fea80cd0e
    reserved_canary: agent/host-loop/probes/56508656-b94b-4b6d-b2bf-88c5df04a293
    ordinary_canary: agent/hlr-002a-control/1d62d30b-1d77-4773-b53f-e7066a905093
    ```

    D2 preflight 必须再读全部 target refs；任一已存在、open overlapping PR/
    ruleset operation 或 readiness head/base 漂移即停止，不换名续跑。
  - **D2 execution order:binary。**readiness merge 后且仅在窗口内：
    (1) 维护者 authenticated GET + rollback payload hash preflight；
    (2) 维护者 PUT exact after bytes；
    (3) 维护者 immediate authenticated GET/write-payload hash read-back；
    (4) GitHub active-rule matrix read-back；任一步失败先 PUT exact rollback 并
    验证，随后停止；
    (5) exact after 与 active-rule matrix 全部闭合后，维护者退出 `gh` 并把脱敏
    receipt 交回；此时才允许同一 non-bypass Deploy Key 执行 ref matrix。
    ref matrix 顺序固定为 single-agent create/delete、reserved-matrix
    create/delete、control-matrix create/delete、non-agent create rejection、
    direct-main empty-commit update rejection；正向必须成功，两个负向必须为
    GH013，main OID 前后相同，全部临时 refs cleanup 后 absent。任一负向意外成功
    是权限扩大事故，即使 cleanup 成功也永久 FAIL。
  - **Fresh canary order:binary。**ruleset receipt + ref matrix PASS 后重新读取并
    钉 stable protected-main OID；reserved/ordinary canary 各建一个以该 OID 为
    parent、tree 相同的 fresh empty commit。严格先 push `reserved_canary`，取得
    exact-head SDD Guard success 且 Agent PR run/PR count = 0；再确认 main 未前进，
    push `ordinary_canary`，取得 exact-head SDD Guard + Agent PR run terminal
    success且唯一 bot PR。main 前进、head guard 缺失、0/2 bot PR、API ambiguity
    或任一 target preexist 均停止。事实闭合后才 close ordinary control PR（必须
    read-back `merged=false`）、删除两个 refs并复查 absent；cleanup 不覆盖结论。
  - **Evidence/review boundary。**本 readiness PR 只修改本文件
    TASK-HLR-002A section，登记 `blocked→ready`、D2 pins/window/rollback/matrix；
    零 source/workflow/test/evidence 改写，零 ruleset/API/ref/PR/Issue/credential/
    scheduler 仓外写。readiness merge 只批准计划，不是 receipt 或 acceptance PASS。
    D2 receipt + ref matrix + fresh live facts 使用后续独立 evidence PR；其合入后
    再以独立 D0 PR `ready→done`。HLR-002 在 done 前持续 blocked。
- Readiness（r2，audit base = protected `main`
  `33050b0ceed5a4cfa400f3eb6829a724200a71de`）：
  - **Approval/dependency gate:satisfied。**#415 的 exact head
    `55b32e9f27f3cdc04ea772243e46f1f2a681ab4c` 由 `lvye` 于
    `2026-07-23T09:12:18Z` APPROVED，并以
    `33050b0ceed5a4cfa400f3eb6829a724200a71de` 于
    `2026-07-23T09:14:24Z` squash merge；merge parent 恰为
    `2462f72d71dffe26e3a69a8932fe469e667f2a38`，subject 携 `(#415)`，
    reviewed head→merge 对本 change 四文档 tree diff = 0。TASK-HLR-001 done
    `d09f5021107e4133d2fc41c1ce65d0bd09d6c12b` 与 TASK-BAP-003 done
    `6a6b6b7010b6563d67aa7d96e6838505e82eb25a` 均为本 audit base ancestor。
    #412 state=`closed`、merged=`false`、head =
    `6744d353b42faf8da15314c09f3465749be05f77`，只保留失败诊断，不复用。
  - **Base/input pins。**以下 Git objects 在本 audit base 实测；本 readiness merge
    后 implementation 开工前必须重核 exact blob/absence、依赖 ancestry、本
    readiness merge parent 与 diff-only-self-section。任一漂移或路径占用立即停止并
    重新 D1 readiness。

    ```yaml pins
    - artifact: TASK-HLR-002A re-readiness r2 audit base
      commit: 33050b0ceed5a4cfa400f3eb6829a724200a71de
    - artifact: CHG-2026-030 revision r4 reviewed head
      commit: 55b32e9f27f3cdc04ea772243e46f1f2a681ab4c
    - artifact: CHG-2026-030 revision r4 merge
      commit: 33050b0ceed5a4cfa400f3eb6829a724200a71de
    - artifact: TASK-HLR-001 done merge
      commit: d09f5021107e4133d2fc41c1ce65d0bd09d6c12b
    - artifact: TASK-BAP-003 done merge
      commit: 6a6b6b7010b6563d67aa7d96e6838505e82eb25a
    - path: .github/workflows/agent-pr.yml
      blob: 2b9b03a90d70671d85da21be6a667e2f2f9c8acb
    - path: .github/workflows/sdd-guard.yml
      blob: 809147e462512d970813d1992a3fcdf41f8b4b10
    - path: .github/workflows/swift-ci.yml
      blob: 640065f3f3849e1add0cc6bfa92078873eb315ef
    - path: openspec/changes/chg-2026-030-host-loop-runtime/proposal.md
      blob: 8760c1fef107ca90bc043b1706e836f234ba52a5
    - path: openspec/changes/chg-2026-030-host-loop-runtime/design.md
      blob: f7af899c91efdb933be90382a28d2868af190e2b
    - path: openspec/changes/chg-2026-030-host-loop-runtime/tasks.md
      blob: 52952297c43f9493f4981706e4424971f7d8bf29
    - path: openspec/changes/chg-2026-030-host-loop-runtime/verification.md
      blob: 697684800b8ce94a16208ed28012b29ef7e1ca46
    - path: scripts/check_pr_paths.py
      blob: 7fdc47933b98284c556d5cba6fd8cfe99b87e0ad
    - path: scripts/test_check_pr_paths.py
      blob: 1f7093402034c622553a11a71b6fc50cb8622bec
    - path: scripts/host_loop/pr_envelope.py
      blob: c990fcfb17de52ed1166fec55cb1f9365e0e7736
    - path: scripts/host_loop/test_pr_envelope.py
      blob: 35d9a284e8ddde67fd1076bc1c2f0f11f02d26db
    ```

    `scripts/test_agent_pr_workflow.py` 在本 audit base 经 Git object lookup 确认为
    absent；它仍是本 implementation 唯一允许新增的文件。

  - **Implementation scope/branch:closed。**fresh branch 固定为
    `agent/hlr-002a-bootstrap-partition-r2`；截至 `2026-07-23T09:16:08Z`
    all-state exact-head PR query = 0、remote ref = absent，且本仓 open PR = 0、
    remote `agent/host-loop/**` ref = 0。旧
    `agent/task-hlr-002a-bootstrap-partition`/head `6744d353...` 不删除也不复用。
    implementation 只允许修改 `.github/workflows/agent-pr.yml`、
    新增 `scripts/test_agent_pr_workflow.py`、`scripts/check_pr_paths.py`、
    `scripts/test_check_pr_paths.py` 与追加本任务 evidence；不翻状态，不改
    `sdd-guard.yml`/`swift-ci.yml`、HLR envelope、runtime、identity/secret/scheduler。
  - **MECH suffix grammar:binary。**`TASK_TOKEN_TEXT` 必须恰为
    `TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?`，且
    `TASK_TOKEN_RE`、`TASK_LINE_RE`、`FULL_TASK_RE` 与 `TASK_HEADER_RE` 共享该
    definition，不保留第二套 task grammar。title/body 正例至少覆盖
    `TASK-HLR-002A`、`TASK-M1-001R`、`TASK-M0A-005B` 与 numeric
    `TASK-HLR-003`；lowercase、两字符 suffix、缺三位数字、邻接污染、多个不一致
    Task、unknown active task 与描述性 branch slug 分别具名失败。branch fallback、
    active task 唯一解析、allowed-path expansion logic 与 archive semantics 均不改。
  - **Namespace/filter contract:binary。**`agent-pr.yml` 只把 current flow list 改为
    ordered `["agent/**", "!agent/host-loop/**"]` block；新 standard-library contract
    test 继续覆盖 r1 的全部 include/exclude、reserved task/lease/probe grammar 与
    malformed fixtures。`sdd-guard.yml`/`swift-ci.yml` 必须与 pins byte-for-byte
    相同，`scripts/host_loop/**` 零 diff。
  - **Repository integration gate:binary。**首次 source commit subject 必须含
    canonical `TASK-HLR-002A`，push 后 exact head 必须取得 SDD Guard、Swift CI 与
    Agent PR push run terminal success，并由 legacy `github-actions[bot]` 唯一创建
    PR。PR 创建后只允许在同一 evidence 文件追加 first-source-head run/PR IDs 的
    evidence-only commit；该 synchronize head 必须取得真实 pull-request `guard` 与
    `allowed-paths` terminal success、Swift CI success，Agent PR 幂等 run 不得创建
    第二 PR。all-state exact-head/branch 查询始终恰一 PR；不得手工改 body、错绑
    `TASK-HLR-002`、复用 #412 checks 或用 elapsed time 推断。任一 0/2 PR、红/缺 check、
    parser ambiguity 或 source/evidence 越界均停止，不形成 bootstrap PASS。
  - **Fixed validation。**`python3 scripts/test_agent_pr_workflow.py`、
    `python3 -m unittest discover -s scripts/host_loop -p 'test_*.py'`、
    `python3 scripts/test_check_pr_paths.py`、`python3 scripts/test_check_sdd.py`、
    `scripts/check-sdd.sh`、`git diff --check`、allowed/forbidden diff 与 pinned
    workflow/HLR input 的 byte-equality 全部通过；run record 分开声明
    offline、first-source 与 synchronize 事实，不预填 live canary。
  - **Post-merge control/canary:binary。**implementation exact reviewed head 合入后，
    仍按 r1 下列 live plan 从同一 merge parent 先 push reserved probe、再 push ordinary
    control；两者 head guard 绿，ordinary 恰一 legacy run/PR，reserved 的 legacy
    run/PR 均为 0；cleanup 前后 read-back 与失败保持事实性。该 live evidence 使用
    独立 PR，之后再走独立 `ready→done`。
  - **Review boundary。**本 re-readiness PR 只修改本文件 TASK-HLR-002A section，
    登记 r4/#412 closure、r2 pins、fresh branch、suffix grammar 与 repository gate；
    零 implementation/evidence、零 external/D2 write。其 merge 只使任务 ready。
- Historical Readiness（r1，audit base = protected `main`
  `0080403e87527c4487849ee6e3c705236e1437b7`）：
  - **Approval/dependency gate:satisfied。**CHG-2026-030 r3 exact head
    `c54964d76bb843215ad956251e7fc08cea502796` 已由维护者 `lvye` APPROVED，
    并以 `0080403e87527c4487849ee6e3c705236e1437b7` 合入 protected `main`
    （#407）；reviewed head→merge 对本 change 四文档 tree diff = 0。
    TASK-HLR-001 done merge =
    `d09f5021107e4133d2fc41c1ce65d0bd09d6c12b`（#402），TASK-BAP-003 done
    merge = `6a6b6b7010b6563d67aa7d96e6838505e82eb25a`（#376），二者与 r3 merge
    均为本 audit base 的 ancestor。本任务只消费既有 Deploy Key/ruleset 分离事实，
    不读取或改变 credential、ruleset、secret 或 scheduler。
  - **Base/input pins。**以下 carrier 由本 audit base 的 Git objects 实测。
    implementation 只能在本 readiness merge 后从最新 protected `main` 新建
    **non-reserved** branch；开工前逐项重核 exact blob/absence、三个 dependency
    merge ancestry 与本 readiness merge first parent。readiness merge 的 first parent
    若不是本 audit base，或任一 input 漂移/路径被占用，立即停止并重新 D1 readiness。
    `tasks.md` 是本 readiness 的自载体，表中钉修改前 blob；readiness merge 后改为
    核验其 diff 只落在本 TASK-HLR-002A readiness section，并把完整 merge OID 当作
    implementation 状态事实。

    ```yaml pins
    - artifact: TASK-HLR-002A readiness audit base
      commit: 0080403e87527c4487849ee6e3c705236e1437b7
    - artifact: CHG-2026-030 revision r3 merge
      commit: 0080403e87527c4487849ee6e3c705236e1437b7
    - artifact: TASK-HLR-001 done merge
      commit: d09f5021107e4133d2fc41c1ce65d0bd09d6c12b
    - artifact: TASK-BAP-003 done merge
      commit: 6a6b6b7010b6563d67aa7d96e6838505e82eb25a
    - path: .github/workflows/agent-pr.yml
      blob: 2b9b03a90d70671d85da21be6a667e2f2f9c8acb
    - path: .github/workflows/sdd-guard.yml
      blob: 809147e462512d970813d1992a3fcdf41f8b4b10
    - path: openspec/changes/chg-2026-030-host-loop-runtime/proposal.md
      blob: 551cddc2bc0c261f841064a568db87eb025725f6
    - path: openspec/changes/chg-2026-030-host-loop-runtime/design.md
      blob: f2b450aac4ebdb65d5f3ba141b7550ca5f753a0a
    - path: openspec/changes/chg-2026-030-host-loop-runtime/tasks.md
      blob: 558c776016d259a3f7ca2429bbf58b35b7b934a8
    - path: openspec/changes/chg-2026-030-host-loop-runtime/verification.md
      blob: 0e5a55cdd1766d56157d8abceefd7480caa8b1fd
    - path: scripts/host_loop/pr_envelope.py
      blob: c990fcfb17de52ed1166fec55cb1f9365e0e7736
    - path: scripts/host_loop/test_pr_envelope.py
      blob: 35d9a284e8ddde67fd1076bc1c2f0f11f02d26db
    - path: scripts/check_pr_paths.py
      blob: 7fdc47933b98284c556d5cba6fd8cfe99b87e0ad
    - path: scripts/test_check_pr_paths.py
      blob: 1f7093402034c622553a11a71b6fc50cb8622bec
    ```

    `.github/workflows/agent-pr.yml` 与新
    `scripts/test_agent_pr_workflow.py` 是 implementation 唯一 workflow/test
    写入面；`.github/workflows/sdd-guard.yml` 必须与上列 blob byte-for-byte
    相同。`scripts/test_agent_pr_workflow.py` 在本 audit base 不存在，须作为本任务
    唯一新文件创建。implementation 若需其他 workflow、runtime 或 dependency 文件，
    停止并回到 scope revision，不在实现 PR 扩面。
  - **GitHub branch-filter semantics:closed。**按 GitHub Actions 当前官方
    `on.push.branches` 语义，同一列表中正/负 pattern 按顺序求值；正匹配后的
    `!` pattern 排除，后续正 pattern 可重新包含。实现必须把 current flow-style
    单值改成下面 exact ordered block sequence，不得同时出现 `branches-ignore`，
    不得用 job-level `if`、`paths`、title/body 或 runtime shell 代替 event filter：

    ```yaml
    on:
      push:
        branches:
          - "agent/**"
          - "!agent/host-loop/**"
    ```

    pattern 对 branch name（不含 `refs/heads/`）求值。结果固定为：全部
    `agent/host-loop/**` push 零 `agent-pr` workflow dispatch；所有其他
    `agent/**`（含 `agent/task-*`、`agent/host-loopx/**` 与
    `agent/host-loops/**`）继续 dispatch；非 `agent/**` 仍不 dispatch。
    `sdd-guard.yml` 的 `main` + `agent/**` push 和 `pull_request` subscriptions
    保持原样。
  - **Reserved grammar:binary。**production ref 的完整 branch name 必须恰好为：
    `agent/host-loop/tasks/<task-id>`、
    `agent/host-loop/leases/<task-id>` 或
    `agent/host-loop/probes/<run-id>`。`<task-id>` 使用 canonical uppercase token
    `TASK-[A-Z0-9]+-[A-Z0-9]+(?:-[A-Z0-9]+)*`；`<run-id>` 使用 lowercase RFC 4122
    UUIDv4 文本
    `[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}`。
    parser 对完整 branch name 做 full match，不接受 `refs/heads/` 输入。空 leaf、
    额外 segment、`.`/`..`、backslash、percent-encoding、空白、case drift、
    非 v4/uppercase UUID、相似 family/prefix 与 trailing slash 均不命中 reserved
    grammar；它们不得被 runtime 当成 task/lease/probe。event filter 对整个
    `agent/host-loop/**` 的宽排除是 creator quarantine，不把非法 branch 升格为
    reserved identity。
  - **Contract implementation/test matrix:closed。**新测试使用 Python 3 standard
    library，以 UTF-8/LF、indentation-aware 的封闭 extractor 读取 workflow 的
    `on.push.branches` block；duplicate/unknown event/filter key、flow-style list、
    alias、非 scalar、顺序颠倒、缺 positive/negative、额外 re-include、
    `branches-ignore` 或 job-level substitute 均具名失败。ordered pattern evaluator
    至少覆盖 ordinary `agent/task-hlr-002a-bootstrap-partition`、三类合法 reserved、
    namespace root、空/额外 segment、case drift、`..`/backslash、相似 prefix、
    non-agent branch；reserved parser 对每类正/负 fixture 单独断言。测试不执行网络、
    subprocess 或 shell，不 hard-code token/host path，不修改现有 envelope/MECH-004
    parser。
  - **Implementation and repository gate:binary。**implementation branch 固定为
    non-reserved `agent/task-hlr-002a-bootstrap-partition`，以保留 legacy creator
    coverage；PR 只允许修改 `agent-pr.yml`、新增 contract test 与追加本任务的
    contract run evidence，不翻状态、不做 live canary。固定验证：
    `python3 scripts/test_agent_pr_workflow.py`、
    `python3 -m unittest discover -s scripts/host_loop -p 'test_*.py'`、
    `python3 scripts/test_check_pr_paths.py`、`scripts/check-sdd.sh`、
    `git diff --check`，以及相对 implementation base 的 allowed/forbidden diff 与
    `sdd-guard.yml` byte equality。任一失败、实现 PR 未由 legacy
    `github-actions[bot]` 唯一创建、或首个 branch guard 缺失，均停止，不形成
    bootstrap PASS。
  - **Post-merge live control/canary:binary。**仅在 implementation exact reviewed
    head 已以完整 merge OID 进入 protected `main` 后，以该 merge 为共同 parent
    创建两个各含一个 empty commit、零文件 diff 的临时 ref：
    ordinary `agent/hlr-002a-control/<uuid-v4>` 与 reserved
    `agent/host-loop/probes/<uuid-v4>`。先 push reserved、再 push ordinary；两者
    都必须取得 exact head 的 `sdd-guard` push run/`guard` job terminal success。
    ordinary 还必须恰有一个 `agent-pr.yml` push run terminal success，且 exact
    head 恰有一个 open、作者为 `github-actions[bot]` 的 PR。reserved 必须由
    Actions workflow-runs API（workflow path + event + branch/head）返回
    `agent-pr` run count = 0，并由 all-state PR exact-head 查询返回 PR count = 0；
    两个查询在 ordinary control 已闭合后及 cleanup 前各 read-back 一次，记录
    request filters、时间、full head OID 与结果。这里的零结论依赖“相同 source
    tree + contract semantics + reserved head guard delivery + ordinary creator
    liveness + 两类 GitHub read-back”，不得仅凭 elapsed time、branch disappearance
    或 cleanup 推断。
  - **Live cleanup/evidence boundary。**上述事实完整后才 close control PR、删除
    control/canary refs，并再次确认 PR merged=false 与 refs absent；cleanup 不改变
    先前 PASS/FAIL。live evidence 使用独立 PR，只追加本任务 evidence，不改 workflow/
    test/status。任何 reserved legacy run/PR、ordinary 0/2 run/PR、head guard
    缺失、API ambiguity 或 cleanup 前事实不全均保留为 FAIL，TASK-HLR-002A 维持
    `ready` 或回到 `blocked`，不得进入 HLR-002 D2 readiness。
  - **Concurrency/review gate:satisfied。**截至 `2026-07-23T08:19:50Z`，GitHub
    connector 对本仓库 all open PR 查询为 0；open HLR-002A/bootstrap query 为 0；
    fetch 后远端 `agent/host-loop/**` 与 HLR-002A branch 为 0。
    `.github/workflows/agent-pr.yml` 无其他 active task ownership。若 readiness
    review/merge 前出现 workflow/path overlap PR、reserved ref 或新的 owner，停止并
    重做 concurrency audit。
  - **Review boundary。**本 PR 只修改本文件 TASK-HLR-002A section，登记
    `blocked→ready`、pins、grammar、contract 与 post-merge canary 计划；零 workflow/
    test/evidence、零 identity/secret/scheduler/ruleset、零 probe/ref、零 HLR-002
    准备。readiness merge 不构成 HLR acceptance PASS；implementation/contract
    evidence、live canary evidence 与后续 `ready→done` 各自独立 PR。
- Platform:github-actions + macos（host/bootstrap control plane；零产品平台声明）
- Requirements/AC:change-local `HLR-LEASE-001`、`HLR-WORKER-001`
- Depends on:change revision r11、TASK-HLR-001 done、TASK-HLR-001A done、
  TASK-BAP-003 done、CHG-2026-033 TASK-RPT-001 done/evidence merge、
  CHG-2026-033 archive #500、#501 r10 failure evidence、
  本 r11 独立 fresh canary-only readiness merge
- In scope:`agent-pr.yml` push filter 保留 `agent/**` include、增加
  `!agent/host-loop/**` exclude；固定 task/lease/probe 三个 reserved family；
  branch-filter contract test；MECH-004 title/body/full task token 对齐现有 active
  task-header grammar，并覆盖单字母 suffix 正反 fixtures；消费 CHG-2026-033
  TASK-RPT-001 merged evidence 与 authenticated topology projection；使用全新 refs
  执行 reserved-first/ordinary-second creator canary；本 change evidence 与本任务状态。
- Out of scope:修改 `sdd-guard.yml`；创建/修改/回滚 ruleset、branch protection、
  repository setting、bypass、push allowlist 或 credential；Agent 直接持有
  maintainer/admin credential、调用 generic API 或创建/修改/批准/执行 standing
  authorization/gateway；重放 #435/#454 计划；创建/配置
  integration identity/secret/scheduler；PR body/envelope/runtime/lease/cursor 实现；
  移除 legacy bootstrap；真实设备或产品代码。
- Allowed paths:`.github/workflows/agent-pr.yml`、
  `scripts/test_agent_pr_workflow.py`、`scripts/check_pr_paths.py`、
  `scripts/test_check_pr_paths.py`、本 change `evidence/**`、本 change
  `tasks.md`（仅本任务状态/evidence 引用）。
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/**`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`、`.github/workflows/sdd-guard.yml`、
  `scripts/host_loop/**`、产品 source/tests、其他 change。
- Risk:high（workflow filter 过宽会停掉现有 PR bootstrap，过窄会造成双 creator；
  current topology/evidence 不闭合或任何管理设置 drift 时必须回到
  CHG-2026-033，不能由本 task 修复或绕过）。
- Hardware required:no。

### Deliverables

- legacy workflow 对 `agent/host-loop/**` 零 dispatch，对其他 `agent/**` 行为不变；
- exact namespace：
  `agent/host-loop/tasks/<task-id>`、
  `agent/host-loop/leases/<task-id>`、
  `agent/host-loop/probes/<run-id>`；空/额外 segment、`..`、backslash、case drift
  与相似前缀不命中 reserved parser；
- contract test 解析 workflow YAML/event filter，证明 include + exclude 同时存在，
  `sdd-guard.yml` byte-for-byte 零 diff；
- MECH-004 对 `TASK-HLR-002A`/既有单字母 suffix task 可从 title/body 唯一绑定
  active task，malformed/ambiguous/multi-suffix 继续失败，真实 implementation PR
  `allowed-paths` 绿色；
- TASK-RPT-001 merged evidence 证明 ordinary ruleset 与 exact-main branch protection
  的 current projection、actor inventory 和正负矩阵闭合；本 task 不重复管理设置
  mutation，只用 fresh refs 验证 creator partition；
- implementation 合入后 live canary：普通 control branch 仍由 legacy creator 创建唯一
  PR；reserved probe branch 的 head guard 出现但 legacy PR/workflow run 数为 0，canary
  清理不以 branch disappearance 代替查询结果。

### Verification

- `HLR-LEASE-001`/`HLR-WORKER-001` bootstrap slice：contract fixtures 全通过；
  control/canary 的 branch/head/full run/PR IDs 可复查；reserved branch 零
  `github-actions[bot]` PR，普通 control 恰一 legacy PR；
- TASK-RPT-001 evidence/done merge OID、authenticated after JSON/hash、actor
  inventory 与 negative matrix 可复查；fresh canary 前 topology 任一 drift 即 blocked；
- `python3 scripts/test_agent_pr_workflow.py`、HLR envelope regression、扩展后的
  MECH-004 path tests、真实 PR `allowed-paths`、`check-sdd`、`git diff --check`
  与 allowed/forbidden diff 通过。

### Notes / handoff

- implementation/evidence、live canary evidence 与 `ready→done` 分离；canary 分支/PR
  不合入，清理结果如实记录；
- #412 只保留为失败诊断；其 commits、checks、PR 或 branch 均不得作为 r4 后 fresh
  candidate 的 implementation/live PASS 复用；
- #421 只保留为 ruleset gap 的 live FAIL；其 run ID/head/零 run/PR 不得复用为 r5
  fresh canary PASS。r5 不重做已通过的 #419 source implementation；
- TASK-HLR-002A done 只建立 creator 空间，不授权 D2 identity，也不构成 HLR-002
  activation receipt。

## TASK-HLR-002B — Scoped D2 gateway、standing authorization 与 namespace lease

- Status:blocked（r7 superseded tombstone；#454 readiness merge
  `49490a8f8e0212998119cb590de4df48f46d0f1c` 依赖的 #449/r6
  Agent-operated ruleset gateway 与 CHG-2026-033 approval #455 冲突。不得实现、
  provision、执行、标记 done 或复用本 task ID；gateway/control-plane dispatch = 0。）
> 下述 r6 readiness、pins、scope、deliverables 与 verification 仅保留为历史审计记录，
> 自 r7 合入起无 current readiness/authorization/implementation 语义。
- Platform:macos（host control plane；零产品/设备平台声明）
- Requirements/AC:none current；historical r6 `HLR-D2-GATE-001` 已退役
- Depends on:none；tombstone 永久不进入 readiness/implementation/done
- Historical r6 in scope:canonical sensitive-input manifest builder/validator；完整 open-PR/files
  pagination 与 overlap classifier；GitHub `merged_at` relative-window validator；
  durable CAS scoped lease；standing-authorization parser/validator/revocation/use
  accounting；仅暴露
  `executeAuthorizedRulesetDelta(canonicalRequest)` 的 constrained gateway；
  authenticated before/one-shot mutation/immediate read-back/rollback 状态机；
  immutable redacted receipt；pure fixture、fault、route-inventory tests 与本任务
  evidence/status。
- Current out of scope:本 section 下全部 source/test/evidence/status implementation；
  创建/修改/批准/撤销真实 standing authorization；向 Agent 暴露 raw
  credential；provision secret/keychain/launchd；真实 ruleset/ref/PR/Issue write；
  generic REST/GraphQL、任意 method/URL/body、branch protection、review/merge、
  arbitrary ref mutation；修改既有 workflow/parser、Core/governance 或产品代码。
- Allowed paths:none for task execution；后续 governance 只能以独立 approved revision
  修改本 tombstone。
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/**`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`、`.github/**`、`scripts/check_pr_paths.py`、
  `scripts/test_check_pr_paths.py`、`scripts/test_agent_pr_workflow.py`、产品
  source/tests、其他 change。
- Risk:high（gateway/lease/auth parser 缺陷可能扩大仓库管理权限或重复执行；任何
  ambiguity、fence mismatch、clock discontinuity、unknown outcome 均 fail closed）。
- Hardware required:no。
- Historical readiness（r1；superseded，audit base = protected `main`
  `d22cdeeebc781b9c3a1b063dbee6631934c51ac0`）：
  - **Approval/dependency gate:satisfied。**CHG-2026-030 r6 #449 exact reviewed head
    `0bb864ba8f76a53396e24e594a176d233115be7b` 由 `lvye` 于
    `2026-07-24T03:17:01Z` APPROVED，并于 `2026-07-24T03:17:08Z` 以
    `490412f0da3ab29fee254643f0844b705a9e1b1a` squash merge；merge parent =
    `11808179d165c8975b4634ad1480760fa91545a9`，reviewed head→merge 对本 change
    四文档 tree diff = 0。TASK-HLR-001 done merge
    `d09f5021107e4133d2fc41c1ce65d0bd09d6c12b` 与 TASK-BAP-003 done merge
    `6a6b6b7010b6563d67aa7d96e6838505e82eb25a` 均为 audit base ancestor。
  - **Input/concurrency pins:closed。**以下 Git objects 在 audit base 实测；本
    readiness merge 后 implementation 开工前必须确认该 merge 是 current protected
    main ancestor、readiness diff 只落在本 TASK-HLR-002B section，且除本文件由
    readiness 自身产生的预期新 blob 外其余 sensitive blobs 全等。main 可有无关
    前进；任一 sensitive blob、dependency ancestry 或 output absence 漂移即停止并
    重新 D1 readiness。

    ```yaml pins
    - artifact: TASK-HLR-002B readiness audit base
      commit: d22cdeeebc781b9c3a1b063dbee6631934c51ac0
    - artifact: CHG-2026-030 revision r6 reviewed head
      commit: 0bb864ba8f76a53396e24e594a176d233115be7b
    - artifact: CHG-2026-030 revision r6 merge
      commit: 490412f0da3ab29fee254643f0844b705a9e1b1a
    - artifact: TASK-HLR-001 done merge
      commit: d09f5021107e4133d2fc41c1ce65d0bd09d6c12b
    - artifact: TASK-BAP-003 done merge
      commit: 6a6b6b7010b6563d67aa7d96e6838505e82eb25a
    - path: openspec/changes/chg-2026-030-host-loop-runtime/proposal.md
      blob: f119ea3acd283d71e0c1e3ad7f76aeaf9f1d71fb
    - path: openspec/changes/chg-2026-030-host-loop-runtime/design.md
      blob: d599ff8fc196e4b7155ffbf3b8ac61ba3dbd83ee
    - path: openspec/changes/chg-2026-030-host-loop-runtime/tasks.md
      blob: 88243bf02ee189f832cc3c94f6e36b65ca54036e
    - path: openspec/changes/chg-2026-030-host-loop-runtime/verification.md
      blob: b362b36e6264bc05fc8b46badf741693112e210d
    - path: .github/workflows/agent-pr.yml
      blob: 41426544637db25224dc6c6b3718abd4ebbfca7c
    - path: .github/workflows/sdd-guard.yml
      blob: 809147e462512d970813d1992a3fcdf41f8b4b10
    - path: .github/workflows/swift-ci.yml
      blob: 640065f3f3849e1add0cc6bfa92078873eb315ef
    - path: scripts/check_pr_paths.py
      blob: 267417ca5d0f9a2bd5ef775314b93915717aea9b
    - path: scripts/test_check_pr_paths.py
      blob: 2aa1e2cb37ef0085d2e101adb34d2b3615246b82
    - path: scripts/test_agent_pr_workflow.py
      blob: 6a256a1556827c2153df0785479c5cbc53796f28
    - path: scripts/host_loop/__init__.py
      blob: a0e413fbf6bab34fbfeafc236a09f24c7a6c7f00
    - path: scripts/host_loop/pr_envelope.py
      blob: c990fcfb17de52ed1166fec55cb1f9365e0e7736
    - path: scripts/host_loop/test_pr_envelope.py
      blob: 35d9a284e8ddde67fd1076bc1c2f0f11f02d26db
    ```

    `scripts/host_loop/d2_gateway/**` 在 audit base 全部 absent。pre-publication
    `2026-07-24T03:26:14Z` 时 GitHub all-open PR = 0，readiness 与固定
    implementation branch 均 remote ref/all-state exact-head PR = 0；main 随后只以
    #453/#452 前进 CHG-2026-033 与 CHG-2026-026 路径，全部 sensitive inputs
    byte-equal。`2026-07-24T03:32:47Z` repin 时唯一 open PR 是本 readiness #454，
    branch `agent/chg-2026-030-hlr-002b-readiness`；implementation branch
    `agent/task-hlr-002b-scoped-d2-gateway` 仍 remote ref/all-state PR = 0。
    implementation 前只重新阻断真实 overlap，不因无关 PR 或无关 main commit 停止。
  - **Implementation surface:closed。**实现使用 Python 3 standard library，禁止
    network/subprocess/shell 与第三方 dependency；production source 只新增
    `scripts/host_loop/d2_gateway/{__init__,contracts,manifest,authorization,overlap,clock,lease,gateway}.py`，
    tests 只新增同目录
    `test_{manifest,authorization,overlap,clock,lease,gateway,security}.py`，run record
    只追加
    `evidence/runs/TASK-HLR-002B/contract-r1.md`。不得修改既有 host-loop、
    workflow/parser/test、任务状态或其他文件；若该封闭文件集不足，停止并修订
    readiness，不在 implementation PR 扩面。
  - **Manifest v1:binary。**canonical form 是 strict UTF-8 JSON object，sorted keys、
    separators `(',', ':')`、no trailing LF；duplicate/unknown key、非 NFC string、
    非小写 40-hex Git OID/64-hex SHA-256、非 canonical round-trip 均拒绝。顶层固定
    `schema/repository/readiness/repositoryInputs/ruleset/targetRefs/leaseKey/operation`
    八项；`repositoryInputs` 按 path 排序并逐项含 exact blob，`targetRefs` 按 full
    `refs/heads/**` 排序并逐项含 expected state，readiness 固定 PR number/reviewed
    head/merge OID/`merged_at`。ruleset 固定 ID `19595282`、source/type/name/target/
    enforcement、before/after/rollback hashes 与 active-rule projection；operation
    固定 exact method/endpoint/body hash。manifest SHA-256 只对上述 canonical bytes
    计算，不能把 current main OID、无关 open PR 或无关 repository path 加入敏感
    投影。
  - **Ruleset fixture:closed。**只读公开 read-back 于
    `2026-07-24T03:22:48Z` 仍为 repository ruleset `19595282`、name
    `agent-ref-boundary`、active、include `~ALL`、exclude 仅
    `refs/heads/agent/**`、rules 恰为 creation/update/deletion、`updated_at =
    2026-07-23T02:20:11.425Z`。contract fixtures 继续固定 authenticated before
    canonical SHA-256
    `a5725db245d84174090de47e1fc45123219dbf5cfdd00d45856b04d801a3d5f2`、
    before/rollback write SHA-256
    `5943b6ce840cbb385ad83615da15ff2ee4ec5710bd696fae6140b37302042157`
    与 exact additive after SHA-256
    `8537b85939b7be059c19601360cadb95bdf4f0abe5151d5948bb6f7826405d30`；
    after 相对 before 只追加 `refs/heads/agent/**/*`。本 source task 不重新读取
    authenticated bypass、不生成 fresh probe ref，也不把 fixture 当作 live receipt。
  - **Authorization v1:binary。**parser 接受一个 canonical JSON carrier 与 typed
    GitHub/main facts，字段固定为
    `schema/authorizationId/repository/readiness/manifestSha256/operationDigest/ruleset/
    targetRefs/leaseKey/gateway/validFromOffsetSeconds/validUntilOffsetSeconds/maxUses/
    rollbackContact/revokeConditions`；unknown/duplicate/missing field 一律拒绝。
    offset 只允许 `900/2700`，`maxUses` 只接受 `1..100` 的有限正整数；本次
    ruleset remediation carrier 必须为 `1`。method/endpoint 只允许
    `PUT /repos/ArkDeck/ArkDeck/rulesets/19595282`，lease key 逐字为
    `ArkDeck/ArkDeck|ruleset:19595282|target-patterns:refs/heads/agent/**,refs/heads/agent/**/*`。
    validator 必须证明 carrier-changing actor 与 APPROVING reviewer 均为 `lvye`、
    reviewed head = GitHub merge metadata head、merge OID 是 current-main ancestor，
    且 manifest/operation/body/before/after/rollback/targets/gateway source+redacted
    identity hashes 全等；revoked/expired/exhausted、merge facts 不完整或 Agent-authored
    carrier 均在 credential lookup 前拒绝。use 在首次 mutation intent 前 durable
    claim；只有可证明 mutation call count = 0 才可释放，timeout/unknown 永不返还或
    盲重试。
  - **Pagination/overlap:binary。**typed read port 必须消费全部 open-PR pages，并对
    每个 PR 消费全部 changed-files pages；page number/cursor 连续、terminal marker、
    item count、duplicate PR/file 与 declared totals 必须闭合。error、timeout、
    truncation、重复/跳页、malformed envelope/body 或无法证明 complete 均返回
    `query-uncertain`。overlap predicate 只含 r6 五类：manifest sensitive path、
    本 change HLR-002A/002B task/evidence、同 readiness/executor branch、同合法
    operation digest/lease key、同 exact target ref；title/仓库活动/无关 path 与
    无关 PR 明确放行。
  - **Clock/store:binary。**`merged_at` 只接受 GitHub UTC RFC3339 `Z` 时间并计算
    半开 `[+900s,+2700s)`；local observation 与 commit timestamp 不可替代。
    injected clock 在 lease acquire 与每个 authenticated read/write 前同时取 aware
    UTC wall + monotonic snapshot；wall/monotonic delta 差绝对值大于 1 秒、wall
    回拨、monotonic 非递增、窗口外或上界余量不足均零 dispatch。durable backend
    固定 Python `sqlite3`、caller-supplied gateway-private database、WAL +
    `BEGIN IMMEDIATE`；`lease_current/lease_events/authorization_uses/operations/
    receipts` 使用事务性 CAS。fence 对 lease key 严格递增且 release/expiry 后不复用；
    record 固定 authorization/operation/owner/fence/acquired/expires/previous-hash/
    record-hash/state。stale owner/fence、双 owner、expiry、DB busy/corrupt 或 record
    hash mismatch 均停止；expiry/release 不解释 external outcome。
  - **Gateway API/state machine:binary。**package root 只给 worker 暴露
    `D2Gateway.executeAuthorizedRulesetDelta(canonicalRequest)`；credential provider
    与 exact transport 保持 private，零 credential-return/generic request/GraphQL/
    review/merge/admin/ruleset CRUD/arbitrary ref method。route inventory 的唯一写
    route是上述 ruleset PUT，且 body 只接受 carrier 固定的 after 或 rollback
    canonical bytes；read routes仅为 readiness merge/main ancestry、全量 open
    PR/files、同 ruleset GET、manifest exact refs 与 active-rule projection。
    固定 journal 顺序为 validate→overlap→lease→authenticated before→durable
    mutation intent/use claim→one-shot after PUT→immediate read-back→active/ref
    verify→append-only redacted receipt→finalize use→release。mutation timeout 先
    read-back且不得再 PUT after；after/unknown mismatch 在同 fence 下只允许一次 exact
    rollback + read-back。outcome 枚举固定
    `rejected-pre-dispatch/completed/not-applied-stop/rolled-back-stop/
    reconcile-required/rollback-failed`；任何 restart 从 durable operation journal
    只做 read-back/reconcile，不重复 mutation。
  - **Contract/repository gate:binary。**tests 必须覆盖 canonical round-trip 与逐字段
    drift、multi-page PR/files 正交/overlap/截断、window 两端/clock discontinuity、
    SQLite 双连接 owner/CAS/stale fence/expiry/corruption、authorization actor/review/
    merge/ancestor/revoke/expiry/use exhaustion、before/after/rollback/timeout 每个
    outcome、restart 零 duplicate mutation、credential sentinel 零 stdout/stderr/
    exception/receipt，以及 AST/public-surface/route inventory 负向扫描。固定验证为
    `python3 -m unittest discover -s scripts/host_loop -p 'test_*.py'`、
    `python3 scripts/test_check_pr_paths.py`、`python3 scripts/test_check_sdd.py`、
    `scripts/check-sdd.sh`、`git diff --check`、相对 implementation base 的
    allowed/forbidden audit与全部 pinned existing blobs byte equality。implementation
    branch/commit/PR 必须唯一绑定 `TASK-HLR-002B`；任一红/缺 check 或 0/2 PR 均停止。
  - **Review boundary。**本 readiness PR 只修改本文件 TASK-HLR-002B section，
    登记 `blocked→ready` 与上述 pins/contracts；零 source/test/evidence、零
    credential/authorization/lease database、零 network write。merge 只授权纯离线
    implementation，不是 standing authorization、D2 execution receipt、acceptance
    PASS 或 done；source+contract run 合入后仍须独立 D0 `ready→done` PR。

### Deliverables

- manifest v1 固定 CHG-2026-030 四文档、相关 workflow/parser blobs、ruleset
  before/after/rollback/active-rule projection 与 exact target refs；current main
  只需包含 readiness merge
  且上述敏感投影未漂移；
- overlap classifier 全量分页 open PR 与 changed files，只阻断 sensitive-path、
  HLR-002A/002B task/evidence、同 branch、同 operation/lease key 或同 target-ref
  冲突；无关 PR 明确放行，分页/API/metadata 不完整明确拒绝；
- relative window 从 readiness PR 的 GitHub `merged_at` 计算半开
  `[+15m,+45m)`，并以 wall/monotonic clock discontinuity 负例证明边界外零
  privileged dispatch；
- durable lease 以
  `repository + ruleset ID + ref namespace` 为 key，使用 CAS fence/acquire/renew/
  consume/release；它不冻结 main/无关 PR，不以 expiry 推断 mutation outcome；
- authorization validator 只接受维护者 merged carrier，固定 exact hashes/targets/
  gateway identity、relative validity、`maxUses`、rollback/revoke；本次 operation
  `maxUses=1`，expired/revoked/exhausted/unknown merge facts 均拒绝；
- gateway route inventory 只有 exact ruleset method/endpoint，worker 只能调用一个
  typed method；credential provider 只在 gateway 内取值且任何日志/error/receipt
  不含值。mutation timeout 先 read-back；after mismatch 在同 fence 下 exact rollback
  并 read-back，生成不可变脱敏 receipt。

### Verification

- `HLR-D2-GATE-001` contract/fault matrix：无关 main commit/open PR 通过；每个
  sensitive path、ruleset field、target ref 漂移，以及 operation hash、
  authorization/lease/clock validation failure，均在 privileged call 前失败；
  open-PR/files 多页与截断/timeout
  fixtures 证明只阻断 overlap、查询不确定 fail closed；
- 双 owner、stale fence、lease timeout、authorization revoke/expiry/use exhaustion、
  readiness not ancestor、GitHub `merged_at` 缺失/非法、wall-clock rollback、
  mutation timeout、after mismatch 与 rollback mismatch 均有具名 outcome，零
  blind retry/duplicate mutation；
- source scan + route inventory 证明 generic REST/GraphQL、review/merge/admin CRUD、
  arbitrary ref write 与 credential-return method 构造数恒为 0；fixture credential
  sentinel 不出现在 stdout/stderr/receipt；
- `python3 -m unittest discover -s scripts/host_loop -p 'test_*.py'`、
  `python3 scripts/test_check_pr_paths.py`、`python3 scripts/test_check_sdd.py`、
  `scripts/check-sdd.sh`、`git diff --check` 与 allowed/forbidden audit 全部通过。

### Notes / handoff

- source/contract implementation 与 `ready→done` 分离；真实 gateway provisioning、
  maintainer-created standing authorization、ruleset/ref execution 与 receipt 均属于
  HLR-002A 后续独立 D2 carriers；
- TASK-HLR-002B done 只证明机制实现，不创建任何授权，也不使 HLR-002A 自动 ready；
- gateway 的 durable lease store 不是 approval ledger；protected-main merge history
  仍是 authorization/ready/task 状态的唯一信任根。

## TASK-HLR-002 — D2 integration identity 与 host activation

- Status:done（2026-07-25 D0 completion；仅在维护者 review/merge 本独立
  `ready→done` PR 后生效。D2 readiness #508 exact reviewed head
  `f744a11a72dd405df0797a55445dc3bc2615a563` 已由 `lvye` APPROVED，并以
  `c7badb73fa3cf12109344731937b88e8bb3611c5` 合入 protected main；
  `mergedBy=lvye`、`auto_merge=null`。维护者在窗口
  `[2026-07-25T01:04:46Z, 2026-07-25T06:59:46Z)` 内于 Agent/Codex credential
  boundary 外单独执行 D2；Agent privileged dispatch = 0。
  evidence #518 exact reviewed head
  `111ccae0c42c03a960cc7e47fc790cda39c4d31a` 由 `lvye` 于
  `2026-07-25T03:09:59Z` APPROVED，并于 `03:10:05Z` 由 `lvye` 以
  `8e76ea4b9a832b31588f000c35feffde9f0d1c6d` 合入 protected main；
  `auto_merge=null`，carrier scope 恰为本 change
  `evidence/runs/TASK-HLR-002/**` 七个文件。
  retained identity = private App `4388667` /
  `arkdeck-host-loop-runtime-901708a7[bot]`，单仓 installation `148855345`
  （`repository_selection=selected`、`GET /installation/repositories` 权威确认
  为 `[ArkDeck/ArkDeck]`），permission 恰为 Metadata read / Contents read /
  Pull requests write / Issues write，`events=[]`；App 非 CODEOWNER、非 ruleset
  bypass、非 main push actor（安装后复核）。PEM 仅 root-only staging
  （`-rw------- root:wheel`，path 只以 SHA-256 记录），client/webhook secret
  即时丢弃，installation token 仅存于执行内存；JWT 签名交由 root 侧 openssl，
  PEM 从未进入 executor 进程。
  正向 probe：Deploy Key 以 exact `--force-with-lease` 创建/CAS/删除
  `agent/host-loop/leases/**`，stale-fence 写入被服务端 precondition 干净拒绝；
  integration identity 在 `agent/host-loop/probes/**` 创建唯一 PR #514 与携
  exact probe ID 的 Issue #515；reserved head 上 legacy `agent-pr.yml`
  run 数 = 0、全状态 PR 数 = 1。
  负向 7 项全部被拒、零 severity-1：直写 protected main、merge、repository
  admin same-value PATCH、branch protection、ruleset 与 GraphQL auto-merge 均
  为 `Resource not accessible by integration`；self-approval 为 HTTP 422
  平台规则拒绝（`Pull requests: write` 确实触及 review endpoint，如实记录，
  不得误报为 permission absent）。负向后 main OID 未变、PR
  `merged=false`、`auto_merge=null`。
  cleanup：Issue closed、PR closed/unmerged、lease 与 probe refs 两次稳定
  read-back 均 absent；scheduler owner `arkdeckhlr` 与 launchd label
  `com.arkdeck.host-loop.runtime` 仍仅为 reservation，account/plist absent，
  **`workerDisabled=true`**。
  三轮 void receipt 永久保留且不作为 done 依据：preflight r1
  `51f2fcb21d5e6ffd002413dd91824f11c1736862b74fbe4b0f636a52d3294474`
  （envelope-shape fail-closed）、preflight r2
  `6a0b7e26f8cb40b0a7a537f4641e6d52c04826457c359b6f8fb8ca6af726ac07`
  （fail-open，C5 结论 void）、phase b2 首轮
  `b92766acb3f552793c50221320242ae8bc5521a31aade888eb215c773d9c9bc5`
  （auto-merge 使用伪造 GraphQL node id，未达授权层，该项 void）。
  evidence blobs = `43f55a2950e1e77461e3ccde99168fdbd2dc8885`（human summary）/
  `505ca0ab97c8ad7e01c5e902deb9ac03739615fe`（preflight r3）/
  `3f4d0e28f36937cca8f7c6bb7be04f33bc1e142f`（install verify）/
  `365b6724d5a31258d693e98b1d21fe396a0b1648`（phase A）/
  `e39cb93d42321150dd54ba5f8e5fa181676a9e0d`（phase b1）/
  `4cf01bdcb135b9023e4425fe981eb33448fa4d50`（phase b2 valid）/
  `a46868f8bbf0829482f866e7de4d01e818af8e0d`（phase b3）。
  已记录的开放事实：reserved namespace 上 bot `opened` 事件不产生任何
  `allowed-paths` job（`agent-pr.yml` 排除 `agent/host-loop/**`；
  `sdd-guard.yml` 的该 job 受 `pull_request` 限制且 types 仅
  `[reopened, edited]`），维护者授权以一次 PR body update 触发
  `pull_request: edited` 取得所需检查；此即 CHG-2026-030 F1 缺口，作为
  TASK-HLR-003 readiness 输入，修法只能落 `agent-pr.yml`。probe ref 由 `lvye`
  于 `2026-07-25T02:55:42Z` 手动提前删除（#514 timeline `head_ref_deleted`
  归因），未 merge 由 main OID 不变、probe commit 非 main ancestor 与 PR
  `closed/unmerged` 三条不依赖分支存在的证据独立确认。
  本 done 只闭合 HLR-002 的 D2 identity/secret-storage/probe slice；不构成
  change `verified`、不构成 TASK-HLR-003/004/005 的 readiness，也不注册或启用
  scheduler——scheduler registration/enable 与 exact source hash binding 属
  TASK-HLR-003 的分离 D2 evidence 阶段，在其 source PR 合入前 dispatch 恒为 0。）
- Historical Status:ready（r1 D2 readiness；仅在维护者对本独立 readiness PR exact
  head review/merge 后生效。只授权一轮由 `lvye` 在 Agent/Codex
  credential boundary 外执行的 GitHub App identity/单仓 installation/root-only
  secret staging、reserved probe/lease、正负 authority probes、cleanup 与后一
  独立 evidence PR；不授权 Agent 执行 D2、scheduler/service-account 创建、
  worker 注册/启动、runtime/source/workflow/settings/protection/ruleset 修改、
  review/merge/auto-merge 或复用历史 HLR-002 branch/credential。）
- Historical Status:blocked（r11 gate 已由 #507 闭合：#421 保留为旧 topology
  historical FAIL；CHG-2026-033 TASK-RPT-001 current topology、TASK-HLR-001A
  done、TASK-BAP-003 done 与 TASK-HLR-002A fresh canary/evidence/done 均已进入
  protected main。余下门仅为本独立 D2 readiness 与 human-isolated execution。）
- Readiness（r1；audit base = protected `main`
  `901708a7af9893bc91ee654630df6922ea5099f8`）：
  - **Approval boundary:pending human merge。**本 carrier 只修改本文件
    TASK-HLR-002 section。只有 `lvye` 对 exact head APPROVED、required checks
    terminal success、`mergedBy=lvye`、`auto_merge=null` 且 squash subject
    携 `(#N)` 的 merge OID 进入 protected main 后，本 D2 readiness 才生效。
    合入前 App/installation/private key/token/secret path/account/scheduler/Issue/
    PR/ref/probe mutation = 0；本 merge 不构成 D2 evidence、task done 或 change
    verified。
  - **Dependency/authority gate:closed。**r11 readiness #504 merge
    `f1ebdf0b67014cbb921db4ae55f2400448f620ce`、HLR-002A success evidence
    #506 merge `1bd36668565d5508dcdd3cd584114631ca4fd6ec` 与 D0 done #507
    exact reviewed head `dce77d8a7f2954f52484900717c9635873ab8488` / merge
    `901708a7af9893bc91ee654630df6922ea5099f8` 均为 audit-base
    ancestors。#507 由 `lvye` 于 `2026-07-25T00:26:47Z` 对 exact head
    APPROVED，并于 `00:26:53Z` 由 `lvye` 合入；`auto_merge=null`。
    TASK-HLR-001A done merge =
    `1815105971b5ec9bee58cb7be04cd759dc01a32b`，TASK-BAP-003 done merge =
    `6a6b6b7010b6563d67aa7d96e6838505e82eb25a`，CHG-2026-033
    TASK-RPT-001 evidence/done 与 archive merges =
    `6f874efc5c4e9fdd39bcdcc91cfcaa6a862e1961` /
    `7a221d24133eefed38aa616fcda376fef33f6cf3` /
    `94c23c4123712a46e7fb2f96a0509f84f5f49ba7` /
    `09ef864e0b7a82fafd480a194aed07144a22578b`。
  - **Nullable parser failure:preserved zero-write。**维护者于
    `2026-07-25T00:45:19Z` 执行 GET-only discovery；report SHA-256 =
    `6268afddd4ee45dabb05d19d4dfe59d55d3b2ae64e852b7cf3fbb703f05e17f3`，
    generator SHA-256 =
    `d5d52e0de4a74ea230fb527e9ca156c09dd65f901b4ca69a34648c8ae66868cc`。
    它在 identity/installation/host inventory 前 fail closed，全部 GitHub
    non-GET、credential、ref、PR/Issue、account/scheduler mutation = 0。
    根因不是 authority drift：GitHub 对已合入 #507 的
    `merge_commit_sha` 从最初完整 OID 后变为 `null`，同时仍返回
    `merged=true`、`mergedAt=2026-07-25T00:26:53Z`、`mergedBy=lvye`、
    exact reviewed head 与 exact `lvye` APPROVED；protected main 仍精确等于
    authoritative merge OID。本 readiness 禁止要求维护者重跑独立 discovery；
    后一 executor 必须把 nullable observation 与 Git ancestry/subject/tree/PR
    review facts 联合判定，不得把 `null` 当成 merge OID，也不得降低其他门。
  - **Git input pins:closed。**audit base parent =
    `1bd36668565d5508dcdd3cd584114631ca4fd6ec`，tree =
    `f32e2f52efc9486003eb35c8d9192ded96dcf62d`，subject =
    `status(TASK-HLR-002A): mark creator partition done (#507)`。下列 blobs
    必须在 D2 preflight 与 readiness reviewed-head/merge tree 中逐项相等；任一
    drift 即零 D2 write：

    ```yaml
    agents_contract: 3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164
    codeowners: f4edd22f87965efcfc27ea512283a0c2252bf0fb
    enforcement: e8ff3c130e1b8b15f8405d150ad567e774a0d82b
    agent_pr_workflow: a514d9e539964f9e1960acbe4ffaa696629571da
    chg030_proposal: f179c9981d50d0e2a90cf20b93a6b6b23912e4bf
    chg030_design: 9cb3bebd1874e13a2ad580138d4f91eeace2fb6b
    chg030_tasks_before: 0fbdb2c2dde69c3db90d577a19a8b338c55b959a
    chg030_verification: b3154599c3d2d935adfbcade5d9765cd34e3cca5
    hlr002a_success_json: d695c9098c2478c6627fa312d127e278b1e8a48a
    hlr002a_success_md: 8f1261e07cef4e2297e3cf9090f1b1b7be197738
    bap003_evidence: d6eaf28e188b1f5f64317ce4eacad22eae10ab10
    topology_success_json: 8eb63bf170e993785acda6345a80558fb6871b76
    topology_success_md: 6c4541d41c8a166edd201883d10190be031d0bea
    topology_no_bypass: 73005c421eb3fc36a16b435873a18f6e84b97369
    ```

    HLR-002A JSON file SHA-256 =
    `8965c39a06a8d68c33dea30215f82299e9e67c4b542f1a2e12bddd61529b1bb3`。
    topology JSON file SHA-256 =
    `9340eae63e4b4586a07525340e1c6a4b9fe39c0a5958bda1cda55dda16df9d9f`；
    authenticated after hashes 固定为 branch protection projection/full
    `f423ce0ca2eb3f667a34dbb7f9bcfa923266928d073ee0e50763b2f69ee2663a` /
    `04f09f273fce806afaa44679c9e8257c74cce3e480fe60da27c7dcca06e85f04`
    与 ruleset projection/full
    `9bb7ef3d62246733ca1dcaac074a3b07f5b4aead6985d645cd58fbf82db62163` /
    `b172750c1c0764956725393823fa72014146d9e2ec0f1b19c48cf670964d54b5`。
  - **Concurrency/absence gate:closed at discovery。**公开全页 open PR 仅 #503，
    exact head `fbcfd10b9552b4562eed3d83d7cee3bc7cb0eef4`，完整 files 只含
    `openspec/changes/chg-2026-031-macos-session-settings/tasks.md`，与本 task、
    identity/protection/targets 零交集。remote branches 全页只含 protected main
    与九个 `agent/**`；历史 `agent/task-hlr-002-readiness` 存在且永久不得复用。
    本 readiness/evidence branches 与下列 probe/lease refs 均 absent：

    ```yaml
    readiness_branch: agent/task-hlr-002-d2-readiness-r1
    evidence_branch: agent/task-hlr-002-d2-evidence-r1
    probe_ref: agent/host-loop/probes/4020f4b8-19dd-43a7-b8ca-5bc044965b79
    lease_ref: agent/host-loop/leases/899eb606-e25f-4302-b84c-27a589b41cc2
    issue_probe_id: c684f68b-b71a-4c59-8d5f-52d42fae28fd
    ```

    host E0 对 exact launchd label/service-account lookup 分别返回 not-found；
    public App lookup 对下述唯一 slug 返回 HTTP 404。这些只证明当前可见
    absence；executor 必须在任一 write 前以 human auth + host root read-back
    重做完整 inventory，不能把 404/历史列表升级为 authenticated absence。
  - **Exact identity target:binary。**本次只允许 create-new，不允许复用或修改
    任何 existing App/installation：

    ```yaml
    owner: ArkDeck
    app_name: ArkDeck Host Loop Runtime 901708a7
    app_slug: arkdeck-host-loop-runtime-901708a7
    visibility: private
    app_url: https://github.com/ArkDeck/ArkDeck
    manifest_redirect: http://127.0.0.1:53627/callback
    webhook_active: false
    events: []
    repository_selection: selected
    repositories: [ArkDeck/ArkDeck]
    permissions:
      metadata: read
      contents: read
      pull_requests: write
      issues: write
    ```

    其他 repository/organization/account permissions 必须为 none；尤其
    Administration/Actions/Workflows/Members/Secrets/Contents-write = none。
    name/slug/owner/visibility/permission/event/repository selection 任一漂移或
    App/installation 已存在，即在 creation 前停止且不修改 existing actor；
    manifest conversion 后返回不同 slug 则只删除本轮 newly-created actor 并停止。
    assigned App/installation IDs 与 `<slug>[bot]` 只在 successful creation 后进入
    脱敏 receipt，不得预造。
  - **Credential/host containment:binary。**App manifest conversion 返回的 PEM
    只允许在 human-isolated executor memory 与 root-only staging 间流动；client
    secret/webhook secret 立即丢弃且不得输出。staging class 固定为非 repository、
    非用户 home 的 system directory：
    `/Library/Application Support/ArkDeckHostLoop/staging`，directory
    `root:wheel 0700`，PEM `root:wheel 0600`；installation token 只存在于执行
    memory 且不落盘。report/evidence 只记录 storage class、owner/mode、path-string
    SHA-256 与 key fingerprint，不记录 raw path、PEM、token、JWT、client/webhook
    secret 或 shell history。维护者 `gh` credential 不得进入该目录、App、report、
    child environment 或 Agent/Codex 可达 storage。
  - **Scheduler reservation/disabled gate:binary。**future owner short name 固定
    `arkdeckhlr`，launchd label 固定 `com.arkdeck.host-loop.runtime`。本 task 只在
    receipt 中保留两者 reservation；不创建 account、plist/job/socket、worker
    executable，不 load/enable/kickstart scheduler。success after 必须同时证明
    account absent、label unloaded、`workerDisabled=true`。account creation、
    staging ownership transfer、scheduler register/enable 与 source binding 只属于
    TASK-HLR-003 的后一独立 D2 evidence。
  - **Operator/window:binary。**唯一 operator = `lvye`；只在单独 human Terminal、
    Codex GitHub connector disconnected、无 GitHub token/private key 粘贴回 Codex
    的条件下执行。窗口取 readiness PR GitHub `merged_at` 的半开区间
    `[+5 minutes,+6 hours)`；每个 external write 前重读可信 UTC 与 readiness
    authority。窗口外、logout/account 不符、敏感 env token 名存在、operator 不能
    完整 read App/installations/protection/ruleset/Deploy Key inventory即零 write。
  - **Single-session authenticated preflight:binary。**独立 discovery 不重跑；
    executor 在同一 D2 session 的第一个 write 前完成并落入脱敏 receipt：
    ① readiness exact reviewed head/merge/current-main ancestry；②上述 Git pins；
    ③全页 open PR/files、remote branches、targets absence；④ candidate App slug
    在 authenticated App registration 与 ArkDeck installation inventories 均 absent；
    ⑤ `@lvye` 是唯一 CODEOWNER，candidate App 不在 ruleset bypass 或 main push
    allowlist；⑥ ruleset/branch protection authenticated projection/full hashes 与
    topology evidence相等；⑦ staging path/account/label absent；⑧ exact
    Deploy Key inventory 与 BAP-003 evidence相容。API/分页/nullable/HTTP/host
    ambiguity 均在 credential generation、manifest conversion 或 ref create 前停止。
  - **Exact D2 positive sequence:binary。**preflight 全过后，只执行一轮：
    localhost manifest confirmation → create exact private App → selected-repository
    installation → root-only PEM staging → installation token in memory。随后 Deploy
    Key 从当时 protected-main OID 创建 exact empty probe ref；new App 创建唯一
    exact-head/base=`main`、open/unmerged PR 与带 exact issue-probe ID 的 Issue。
    `pull_request` `guard`/`allowed-paths` 与 Swift 必须 terminal success，reserved
    head legacy Agent PR run/PR count 必须保持 0。Deploy Key 另对 exact lease ref
    完成 create→expected-OID CAS update→delete；每步一次 mutation intent、immediate
    exact read-back，timeout 先 GET reconcile、不得盲重试。
  - **Exact negative authority sequence:binary。**同一 App installation token 只可
    调用 executor 内封闭 typed routes，并逐项要求拒绝：direct update protected
    main ref、对自己的 probe PR `APPROVE`、merge probe PR、enable auto-merge、
    repository admin same-value PATCH、branch-protection/ruleset/admin route。
    App 不可构造 generic REST/GraphQL/arbitrary method/body；`Pull requests:write`
    对 review endpoint 的平台 coverage 必须如实记录，不得误报为 permission absent。
    任一负向意外成功即 severity-1 failure：停止后续 probe，保留事实，执行 rollback，
    TASK-HLR-002 保持 `ready` 或经独立 remediation 退回 `blocked`；cleanup 不把
    failure 改写为 PASS。
  - **Success cleanup/after:binary。**固定所有正负 facts 后，先 close probe Issue，
    再删除 lease（若尚存）与 probe ref；PR 必须 closed/unmerged、`auto_merge=null`，
    两次稳定 Git read-back 证明 refs absent。success retained state 只能是：exact
    private App + exact selected single-repo installation + exact minimal permissions +
    root-only PEM staging；App 非 CODEOWNER/bypass/main-push actor，scheduler/account
    absent，`workerDisabled=true`。所有临时 JWT/installation token/manifest code 与
    browser callback state 清零。
  - **Rollback:fail closed。**manifest conversion、installation、secret staging、
    positive/negative probe 或 cleanup 任一步失败/ambiguous，先停止 new writes；
    对 may-have-happened mutation 做 exact GET/read-back。rollback 依序关闭 probe
    Issue/PR、删除 exact lease/probe refs、revoke installation token、remove
    installation、delete only the newly created App registration、remove only the
    exact staging PEM/directory；每步 read-back。preexisting actor/path 绝不删除。
    App creation/deletion或 ref outcome仍不确定时保持 residual、logout、停止并请求
    人类 reconciliation，不猜测成功或补跑。
  - **Evidence/state separation:binary。**executor 及其 exact SHA-256 只能在本
    readiness merge 后生成；不得把本 readiness PR 当 execution。sanitized report
    与 human summary 只进入
    `agent/task-hlr-002-d2-evidence-r1` 独立 evidence PR，包含 before/after/
    rollback hashes、App/install IDs、permission/repository/actor projection、
    run/job/PR/Issue/ref IDs、mutation counts、logout/cleanup/`workerDisabled`
    结论，零 secret/raw payload/用户绝对路径。evidence exact-head review/merge
    后再另起 D0 `ready→done` PR；HLR-003 在 done 前继续 blocked。
- Platform:macos（受控 host 运维；零产品平台声明）
- Requirements/AC:change-local `HLR-LEASE-001`
- Depends on:change revision r11、TASK-HLR-001A done、TASK-BAP-003 done、
  TASK-HLR-002A done、
  independent D2 readiness
- In scope:维护者建立非 `GITHUB_TOKEN`、repository-only、非 CODEOWNER/bypass 的
  PR/Issue integration identity；permission categories 固定为 Metadata read、Contents
  read、Pull requests write、Issues write，其他 repository/organization/account
  permission 为 none；`agent/host-loop/**` ref 继续复用 BAP-003 Deploy Key/ruleset；
  配置 secret storage、scheduler owner/label reservation（worker 保持 disabled）与
  脱敏正/负 probe；本 change evidence 与本任务状态。
- Out of scope:任何批准/合并权威、Actions/Workflows/Administration 或 branch
  protection/ruleset admin、token/key 入仓、runtime 源码、旧 `agent-pr` workflow
  最终迁移、启动尚不存在的 worker。平台共享 Pull requests write 对 review endpoint
  的潜在 coverage 必须如实记录，不能误报为 endpoint permission 不存在。
- Allowed paths:本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence
  引用）。
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、`openspec/governance/**`、
  `openspec/specs/**`、`openspec/contracts/**`、`openspec/changes/archive/**`、
  `.github/**`、`scripts/**`、产品 source/tests。
- Risk:medium（凭据或 scheduler 配错可能扩大权限或造成停摆；默认 fail closed）。
- Hardware required:no。

### Deliverables

- 维护者执行的 D2 evidence：identity 类型/权限类别（不含值）、host owner、secret
  storage 类别、单仓 scope、非 CODEOWNER/bypass readback、reserved lease ref 与
  integration-authored reserved probe PR/Issue 正向操作、protected-main direct write /
  self-approval / merge / admin same-value mutation 的负向拒绝、撤销与 rollback；
- host staging receipt：仅含脱敏 identity/host/scheduler IDs、时间、permission
  categories、secret-storage class、`workerDisabled=true`；不把 scheduler
  owner/label reservation 误写为 worker 已注册或运行。

### Verification

- `HLR-LEASE-001` D2 document/integration review：非 `GITHUB_TOKEN` identity 能创建
  reserved probe PR/Issue，Deploy Key 能创建/CAS/删除
  `agent/host-loop/leases/**` ref；legacy creator 对 reserved probe 零 PR；permission
  manifest/scope 等于 readiness pins，identity 非 CODEOWNER/bypass；直写 main、
  自己的 probe PR approval、merge 和 admin same-value mutation 均被拒；
  token/private key/绝对用户路径为零；`check-sdd`/diff check 通过。任何负向 probe
  意外成功即撤销 identity 并保持 `blocked`，cleanup 不把失败改写为 PASS。

### Notes / handoff

- 维护者须亲自执行并确认 D2 动作；runtime/Agent 只能读取事实性 receipt；
- HLR-002 done 时 worker 必须仍 disabled；实际 scheduler registration/enable 与
  source hash binding 属 HLR-003 的分离 D2 evidence 阶段；
- 未形成可复查 receipt 时，HLR-003/004/005 一律保持 blocked。

## TASK-HLR-003 — Fenced worker loop 与 legacy PR creator 迁移

- Status:done（2026-07-26 D0 completion；仅在维护者 review/merge 本独立
  `ready→done` PR 后生效。授权载体 = r5 #551，exact head
  `7a6d427d281aadc6e654a683c5d0c80db613db9d` 由 `lvye` APPROVED，merge
  `90fa542af7860e1bbfb2265c3a63f15dc853238f`、`mergedBy=lvye`、`auto_merge=null`。
  r5 五项 recheck 义务已于 flip base `90fa542a…` 逐项执行：(a) 链条九 merge 全为
  ancestors——#521 `2667a10b…`、#524 `1a8e235f…`、#529 `05d50035…`、#531
  `d82ceb3d…`、#539 `e70d7863…`、#547 `5307d1b9…`、#548 `891d4f54…`、#549
  `ae597d0d…`、#550 `ba46750c…`；(b) offline suite 406 tests OK + 1
  expectedFailure（= `Decision-Grade` 缺口的在案记录，未摘除），`--explain`
  exit 10、`claimable=none`；(c) #550 六份 receipt JSON 在 main 在位，sha256 与
  `d2-scheduler-staging.md` manifest 逐一相等；(d) 本 done **不声称**下列四项——
  live first-PR proof、old creator coexistence 的 live 观测、lease
  CAS/stale-fence 的 live 充分性（F4）、legacy creator 迁移——均已按 r5 转移至
  TASK-HLR-005（其 Notes/handoff 在案，缺一其 readiness 不得 ready）；
  `Decision-Grade` 缺口仍在案；(e) 本 PR 单文件、只动本 Status 行。主机 standing
  状态不变：两 unit 保持 left-running，r5 冻结条款（下一授权载体前不得触碰）继续
  有效。）
- Historical Status:ready（r5 done-boundary readiness；仅在维护者对本独立 readiness
  PR exact head review/merge 后生效。r4 授权的 ② staging 窗口与 ③ evidence PR 已
  全额消耗（#550）；r5 不授权任何 source PR、任何主机/launchd/token/PEM/unit 变更
  （含 rollback）、Phase 4、dispatch、worker 认领任务。r5 只授权 ① 本 carrier 的
  done 边界判定注记与义务转移（本节 + TASK-HLR-005 Notes，同一文件），② 其后一个
  独立的单文件 done 状态 PR（ready→done，recheck 义务见下）。不授权清单其余与 r4
  逐字相同，含 review/merge/auto-merge/admin route、GitHub
  settings/protection/ruleset 修改、`sdd-guard.yml` 变更、以及**代任何任务撰写
  `Decision-Grade`**。②授权由本 done 翻转消耗。）
- Historical Status:ready（r4 D2 readiness；仅在维护者对本独立 readiness PR exact head
  review/merge 后生效。r3 的前置① 已由 #548 消耗，r4 不再授权任何 source PR；r4 只
  授权 ② 一轮由 `lvye` 亲手执行的 host scheduler staging 窗口 **Phase 0–3**（条款
  = r3 原文 + 下方 r4 更正），③ 其后一个独立 evidence PR。不授权 Phase 4
  （cursor Issue 创建与首次 Issue 写入）、任何 dispatch、Agent 代为执行 D2、worker
  认领任务、legacy creator 在 live proof 前退出、review/merge/auto-merge/admin
  route、GitHub settings/protection/ruleset 修改、App 权限或 PEM 存放位置变更、
  `sdd-guard.yml` 或任何 governance text 变更、以及**代任何任务撰写
  `Decision-Grade`**。②③ 于 2026-07-26 全额消耗：窗口由 lvye 执行完毕
  （terminal=left-running），evidence = #550。）
- Historical Status:ready（r3 D2 readiness；仅在维护者对本独立 readiness PR exact head
  review/merge 后生效。r1/r2 已交付的 offline runtime 与 source 不重新授权；r3 只额外
  授权 ① 一个 D0 source PR 交付 root-owned shell minter 的可 review 源、`--explain`
  干跑模式与两处已实测 fail-closed 缺陷的修复，② 一轮由 `lvye` 亲手执行的 host
  scheduler staging 窗口 **Phase 0–3**，③ 其后一个独立 evidence PR。不授权 Phase 4
  （cursor Issue 创建与首次 Issue 写入）、任何 dispatch、Agent 代为执行 D2、worker
  认领任务、legacy creator 在 live proof 前退出、review/merge/auto-merge/admin
  route、GitHub settings/protection/ruleset 修改、App 权限或 PEM 存放位置变更、
  `sdd-guard.yml` 或任何 governance text 变更、以及**代任何任务撰写
  `Decision-Grade`**。前置① 于 2026-07-25 由 #548 消耗；其 drift gate 与 #548 的
  自相矛盾由 r4 更正。）
- Historical Status:ready（r2 corrective readiness；#529 merge
  `05d500354f802813239803982047b08178c62fcf` 后生效。r2 授权「一个 D0 source PR」，
  由 #524 merge `1a8e235fc7174c647e8e971dee3f1a6d2dd16325` 消耗；**#531 merge
  `d82ceb3d03df09c4650c4edc9fcef2c406e3c0ef` 与 #539 merge
  `e70d7863b2fcdd2cf8c65a2983abd4c84919ecec` 各由维护者在会话内另行显式授权**，不由
  r2 覆盖。r3 起草期曾把三者笼统记为「r2 授权额度」，与 r2 自身文本不符，此处更正。）
- Readiness（r5；audit base = protected `main`
  `ba46750c325c3ed8fa58f58930e495660593b91a`；**纯增注：done 边界判定 + 义务转移，
  零主机变更授权，不删改任何既有 Verification 文字**）：
  - **Approval boundary:pending human merge。**本 carrier 只修改本文件的
    TASK-HLR-003 section 与 TASK-HLR-005 的 Notes/handoff（义务转移的落点，见下）。
    只有 `lvye` 对 exact head APPROVED、required checks terminal success、
    `mergedBy=lvye`、`auto_merge=null` 且 squash subject 携 `(#N)` 的 merge OID 进入
    protected main 后，本 readiness 才生效。合入前 repo/host/GitHub mutation = 0；
    本 merge 不构成 task done——done 是其后独立单文件 PR。
  - **Why r5 exists:live proof 归属环，维护者 2026-07-26 拍板解开。**r3 明文把
    live first-PR proof 的归属「留待 r4 与 HLR-004 readiness 共同钉定」，r4 未钉。
    实测存在环：本任务 Verification 的 live 半幅（唯一有效 lease 创建带完整
    envelope 的 task PR + 首个 `pull_request` checks）需要 Phase 4、
    `Decision-Grade` 补齐与一个天然 D0 任务；而承载 live 全流程的 TASK-HLR-005
    依赖本任务 done。共享 AC 事实：HLR-005 的 Requirements/AC 本就含
    `HLR-LEASE-001`/`HLR-WORKER-001`——live 半幅在 HLR-005 验证与 AC 归属零冲突。
    维护者决定：live 半幅移至 TASK-HLR-005，legacy 迁移随行，义务不灭失。
  - **r4 consumption:closed。**② 窗口于 2026-07-26 由 `lvye` 单次连续会话执行完毕：
    六 receipt（preflight 22 / install-verify 6 / phase1 4 / phase2 8 /
    phase2-after-probe 10 / phase3 11 checks）全 PASS，02:35:26Z–04:27:40Z，
    `terminal=left-running`；③ evidence PR = #550，head
    `11634ce2d046c491d095318b57e789b980738d00` 由 `lvye` APPROVED、merge
    `ba46750c325c3ed8fa58f58930e495660593b91a`、`auto_merge=null`。
    **主机 standing 状态：两个 unit 保持装载（left-running）；本 r5 不授权触碰
    它们（含 rollback）；下一次可触碰的授权载体 = HLR-004/005 readiness 或独立
    r6。**
  - **Done boundary（判定注记；Verification 原文一字不动）。**逐条对应：
    - lease/worker 契约 fail-closed 全案（双 worker acquire、stale-fence write、
      heartbeat loss、create timeout、Issue corruption、0/2 PR lookup 等）→
      offline suite 满足（#524/#531/#539/#548 合入版，406 tests + 各 run 变异
      记录）。
    - typed adapter 只暴露白名单路由、review/merge/admin route 构造数恒 0、fake
      transport/route inventory/source scan → offline suite 满足。
    - scheduler receipt source hash 与 main exact blob 相同 → #550
      `d2-install-verify.json` I3 三元组满足（`5b8cbc06…` @ `ae597d0d…`）。
    - reserved branch 零 legacy creator → TASK-HLR-002 receipt（#518）与 #550
      phase3 S10 零增量满足。
    - `MECH-004` allowed-paths、`check-sdd`、diff check → 各 carrier PR checks
      满足。
    - **移至 TASK-HLR-005 验证（落点 = 其 Notes/handoff 新增条，本 carrier 同时
      写入）**：① 唯一有效 lease 创建带完整 envelope 的
      `agent/host-loop/tasks/**` task PR 并在首个 `pull_request` event 看到
      checks（live）；② old creator coexistence 的 live 观测；③ lease
      CAS/stale-fence 的 live 充分性证明（r1 F4 open 义务，原文「HLR-002 单次
      stale-fence 不构成充分证明」继续有效）；④ legacy creator 迁移——
      `agent-pr.yml` 的移除/禁用不得早于**同 PR** 的新 creator live proof，
      原文约束逐字随移。
  - **Authorized done PR:binary，recheck 义务五项。**(a) 链条九 merge 全为 flip
    base 的 ancestors：#521 `2667a10b…`、#524 `1a8e235f…`、#529 `05d50035…`、
    #531 `d82ceb3d…`、#539 `e70d7863…`、#547 `5307d1b9…`、#548 `891d4f54…`、
    #549 `ae597d0d…`、#550 `ba46750c…`；(b) flip base 上 offline suite 406 绿
    （1 expectedFailure = `Decision-Grade` 缺口的在案记录，不得摘除）且
    `--explain` exit 10、`claimable=none`；(c) #550 六 JSON 在 main 在位且
    sha256 与 receipt manifest 逐一相等；(d) done 注记明写**不声称** live
    proof/迁移/CAS live 充分性（均已转 HLR-005）且 `Decision-Grade` 缺口仍在案；
    (e) 单文件、只动本 task 的 Status 行与 done 注记。
  - **Concurrency/absence:closed at drafting（2026-07-26）。**remote
    `agent/task-hlr-003*` 分支 = 0；本 carrier 分支
    `agent/task-hlr-003-readiness-r5` 与 done 分支 `agent/task-hlr-003-done` 均
    absent。tasks.md audit-base blob = `fb81c1e40cf0b77d6576450397361473684a2e82`；
    review 时须确认本 carrier 相对 audit base 的差异只有：本 r5 block、Status 行
    r4→r5 降级、TASK-HLR-005 Notes/handoff 新增一条。
- Historical Readiness（r4；audit base = protected `main`
  `891d4f542f05e2341a091b6437b491ff9bf64727`；**纯 pin 刷新 + 三处更正，其余 r3
  条款原文有效；②③ 授权已于 2026-07-26 全额消耗（#550），见 r5**）：
  - **Approval boundary:pending human merge。**本 carrier 只修改本文件
    TASK-HLR-003 section。只有 `lvye` 对 exact head APPROVED、required checks
    terminal success、`mergedBy=lvye`、`auto_merge=null` 且 squash subject 携
    `(#N)` 的 merge OID 进入 protected main 后，本 readiness 才生效。合入前
    account/launchd/plist/token-file/PEM/App/installation/Issue/PR/ref/scheduler
    mutation = 0；本 merge 不构成 D2 evidence、task done 或 change verified。
  - **Why r4 exists:r3 的 drift gate 与其自身前置① 自相矛盾（实测）。**r3 把
    `hostloop_main`/`hostloop_worker` 钉进十六 blob drift gate（「任一 drift 即零
    D2 write」），而 r3 前置① 要求的 `--explain`（落在 `__main__.py`）与归档依赖
    修复（落在 `worker.py`）必然修改这两个文件。实测 @ `891d4f5…`：十四 pin 仍逐字
    相等；`hostloop_main` `07d2c8d1…`→`aa47dd45…`、`hostloop_worker`
    `f71d3a98…`→`b9662c76…`；#548 合入前（`5307d1b…`）两 blob 与 r3 pins 逐字相等；
    自 r3 audit base `40bfee1a…` 起触碰 `scripts/host_loop/` 的 commit 有且只有
    #548。故该门在 #548 之后**永远无法通过**——与 r3 自己删除的「sudo 恒假门」同型。
    r4 以 #548 之后的 base 重钉全表；门语义不变。
  - **Prerequisite ① consumed:closed。**#548 head
    `c401e48891d0f0e95d6ddf694c2688adef7fc119` 由 `lvye` 于 exact head APPROVED，
    `2026-07-25T15:17:46Z` 合入为 `891d4f542f05e2341a091b6437b491ff9bf64727`，
    `auto_merge=null`、`mergedBy=lvye`；四文件 = minter 可 review 源、`--explain`、
    归档依赖修复、cursor-env 零写测试，恰为 r3 前置① 四项。**r4 不授权任何新的
    source PR**；若窗口前 `scripts/host_loop/**` 再有任何变更，本 readiness 作废，
    须 r5。
  - **Dependency/authority gate:closed。**r3 carrier #547 reviewed head
    `a0b86f7bb14f627e9e88de1a496dd10c879a570c` 由 `lvye` APPROVED，
    `2026-07-25T13:08:12Z` 合入为 `5307d1b9833333952ae54f41256764394d66f692`，
    `auto_merge=null`；与上条 #548 均为 audit-base ancestors。r3 依赖表六 merge
    不变，仍全部为 ancestors。
  - **Git input pins（r4 drift gate，取代 r3 十六 blob 表）。**audit base parent =
    `5307d1b9833333952ae54f41256764394d66f692`，tree =
    `c81ac589eeb14cf0ce83eb86376eb2c32c4adac3`，subject =
    `feat(TASK-HLR-003): add the token minter, --explain, and close two
    fail-opens (#548)`。下列**十七个 blob 是 drift gate**：必须在 D2 preflight 中
    逐项相等，任一 drift 即零 D2 write。第十七项 `hostloop_minter` 为 r4 新增——
    root 每个间隔都执行它的已安装副本，它属于「循环每轮依赖的字节」，且其存在使
    r3 的 Ordering 义务（installed hash == 仓内 hash @ preflight main OID，三者进
    receipt，仓内侧必须 `git show <main-oid>:<path>` 读取）从「对未来字节的义务」
    变为可同时对 pin 校验；该义务原文继续有效：

    ```yaml
    agents_contract:     3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164
    codeowners:          f4edd22f87965efcfc27ea512283a0c2252bf0fb
    agent_pr_workflow:   a514d9e539964f9e1960acbe4ffaa696629571da
    sdd_guard_workflow:  c64135e1f9dc253a92640a30bbcad42b0afa86fa
    chg030_proposal:     f179c9981d50d0e2a90cf20b93a6b6b23912e4bf
    chg030_design:       9cb3bebd1874e13a2ad580138d4f91eeace2fb6b
    chg030_verification: b3154599c3d2d935adfbcade5d9765cd34e3cca5
    hostloop_init:       7a6c5b9223c68f9d8aadd503fb38842346c710fc
    hostloop_main:       aa47dd45a29ac4531e4c38e3cbe84acaaf2b18a5
    hostloop_backends:   0efa3e8c74c7935f96742d4d9f1649cc91534dd2
    hostloop_transport:  55e17e3caf139522c189dc6284db6ae90272fad2
    hostloop_worker:     b9662c76a0948abb049d293b2b03948a8fb570a5
    hostloop_cursor:     0961ec62409644421dc8ed8eea68230e8fa93b5e
    hostloop_lease:      685fb3c3c8c8266c52816027c92b300ea7cd6732
    hostloop_identity:   d22e62946e3b5b836cbdcd9b48b57031172fe4b1
    hostloop_envelope:   2c286c8da0fa8945d512115dfce9de5150db0831
    hostloop_minter:     4150401c5f875ac282d38d6f70eb4c0c35f97689
    ```

    本文件的 blob 仍**不是** drift gate，只作 provenance：audit-base 值 =
    `327d84139ea6989674e3966e636a8fc38c90d3a2`；preflight 须记录合入后的实际值，并
    确认其与 audit-base 值之间的差异**只有**本 r4 block（含 Status 行的 r3→r4
    降级）。
  - **Minter install path:pinned（维护者 2026-07-25 选定）。**安装路径 =
    `/Library/PrivilegedHelperTools/com.arkdeck.host-loop.mint.sh`。该目录已实测
    存在且 `root:wheel`（`drwxr-xr-t`），全链仅 root 可写，是 macOS 约定的 root
    helper 可执行文件位置。安装形式：从
    `git show <main-oid>:scripts/host_loop/mint_installation_token.sh` 的输出
    （**不得**从工作树文件——工作树对 Agent 可写）经
    `sudo install -o root -g wheel -m 0555` 落位。**该路径本身由本 readiness
    公开钉定，receipt 得引用之**；PEM 目录路径与 PEM staging 路径仍不得以明文出现
    （r3 脱敏面不变）。**手工确认 M1（进 receipt 的
    `manual_confirmations_required`）：operator 确认该目录不是 PEM 所在目录**——
    PEM 位置只有 operator 知道，此判断无法由 Agent 或机器检查替代；若同址，本 pin
    作废，须 r5 另择路径。
  - **Phase 3 非并发观测:如实记录条款（维护者 2026-07-25 决定）。**r3 要求
    minter 与 scheduler「日志每行前缀写入 run_id 与 pid」，但已合入的 #548/#524
    代码不输出该前缀（r3 起草时未对照实现，该观测在现字节上不可产出）。按 r3 自带
    回退条款执行：receipt 将该观测**如实记录为「未证明」**，并补记两条结构性事实
    作为替代观测：① launchd 对同一 label 不并发第二实例——`StartInterval` 到点时
    上一实例未退出则跳过该次触发，表现为缺失；② scheduler 单轮为 `--once` 短进程，
    `pgrep -fl host_loop` 在轮间隔内可抽样为空。**不授权**为补前缀而新开 source
    PR；若未来 revision 引入前缀，归 HLR-004/005 的 readiness。其余 Phase 3 条款
    （连续 ≥3 轮退出 10、增量全 0、反证、abort 条件）原文有效。
  - **Concurrency/absence gate:re-measured 2026-07-25（Agent 起草前只读复测）。**
    `agent/task-hlr-003*` 远端分支 = 0，`agent/host-loop/**` 远端 refs = 0；本
    carrier 分支 `agent/task-hlr-003-d2-readiness-r4` 与 evidence 分支
    `agent/task-hlr-003-d2-evidence-r1` 远端 absent；runtime label 在
    `gui/501` 与 `system` 双域 `print` 均 exit 113，refresh label 在 `system` 域
    exit 113；两域 `print-disabled` 的 host-loop 条目 = 0；`~/Library/
    LaunchAgents/` 8 项、host-loop 者 0；`arkdeckhlr` = eDSRecordNotFound。窗口
    Phase 0 仍须按 r3 absence 表在**同一域**逐项复验，本条不替代之。
  - **Baseline runs @ audit base。**offline suite `python3.14.6` 406 tests OK +
    1 expectedFailure（该 expectedFailure 即 Decision-Grade 缺失的在案记录）；
    `--explain --repo-dir <checkout>` exit 10、八任务逐门拒绝、`claimable=none`
    ——r3「scheduler `--change` 恒为本 change 且零可派发候选」的补偿控制观测已可
    复现。窗口 Phase 1/3 仍须在窗口内重新产出各自的 `--explain` 输出。
  - **Everything else:r3 原文有效，r4 不重述。**操作者与窗口边界（单次连续会话、
    两种终态）、Ordering 义务、Dispatch-authority binding 三项记录、credential
    topology D′ 全部条款（含 sudo 三性质与禁止形态）、scheduler ownership 退役、
    Phase 0–3 全部门与 abort 条件、negative probes、Rollback 六步、Receipt shape
    与脱敏面、Phase 4 三条不授权理由、live first-PR proof 归属留待 r4 与
    HLR-004 readiness 共同钉定的声明——均以 r3 原文为准；本 r4 仅更正上列五处
    （pin 表、audit base、minter 路径、① 消耗记录、Phase 3 观测记录规则）。
- Historical Readiness（r3；audit base = protected `main`
  `40bfee1a3bf2f8981fa752e9e3995d8d04434e00`；十六 blob pin 表经 r4 刷新为十七
  blob 表，其余条款经 r4 确认继续有效）：
  - **Approval boundary:pending human merge。**本 carrier 只修改本文件
    TASK-HLR-003 section。只有 `lvye` 对 exact head APPROVED、required checks
    terminal success、`mergedBy=lvye`、`auto_merge=null` 且 squash subject 携
    `(#N)` 的 merge OID 进入 protected main 后，本 readiness 才生效。合入前
    account/launchd/plist/token-file/PEM/App/installation/Issue/PR/ref/scheduler
    mutation = 0；本 merge 不构成 D2 evidence、task done 或 change verified。
  - **Operator 与窗口边界。**执行者恒为 `lvye`，在 Agent/Codex 不可达的凭据边界外
    亲手执行；Agent 只起草计划与核验 receipt，不得代为执行任何 Phase 步骤。窗口为
    **单次连续会话**，跨会话续做须重跑 Phase 0 全部 absence 复验。窗口的**终态有且
    只有两种**，须在 receipt 中明确宣告其一：`terminal=left-running`（两个 unit 保持
    装载，此后进入 r4 授权范围前不得再有任何变更）或 `terminal=rolled-back`（按下方
    Rollback 全部六步执行并复验缺席）。不得留下「部分装载」终态。
  - **Why r3 exists。**TASK-HLR-002 receipt 的 Boundary 明写 `Worker registration,
    scheduler enablement and source-hash binding belong to TASK-HLR-003's separate
    D2 evidence phase`，但该阶段从未有过授权载体。r2 只授权「交付可执行入口，使
    scheduler 有可绑定的对象」，未授权任何主机侧 staging。r3 是这个载体。
  - **Ordering:source PR 先，readiness 不预钉未来字节。**本 readiness **不**钉定尚未
    写出的 minter 源码 hash——那是把不存在的字节串写成 pin。改为钉定可验证的义务：
    窗口 preflight 必须记录并校验
    `sha256(仓外已安装 minter) == sha256(仓内 minter @ 该次 preflight 时 protected
    main 的 exact OID)`，**两个 hash 与那个 main OID 三者全部进 receipt**；仓内一侧
    的读取必须来自 `git show <main-oid>:<path>` 而非工作树文件，以免读到未提交内容。
    任一不等即零 D2 write。
  - **Dependency/authority gate:closed。**下列均为 audit-base ancestors（已逐一以
    `git merge-base --is-ancestor` 复验），全部由 `lvye` 对 exact head APPROVED 并亲手
    合入，`auto_merge` 全程为 `null`：

    ```yaml
    hlr003_readiness_r1:  2667a10badb8180a0c7f5079636d46b03f637184  # PR #521
    hlr003_source_r1:     1a8e235fc7174c647e8e971dee3f1a6d2dd16325  # PR #524
    hlr003_readiness_r2:  05d500354f802813239803982047b08178c62fcf  # PR #529
    hlr003_entrypoint:    d82ceb3d03df09c4650c4edc9fcef2c406e3c0ef  # PR #531
    hlr003_corrective:    e70d7863b2fcdd2cf8c65a2983abd4c84919ecec  # PR #539
    hlr002_d2_readiness:  c7badb73fa3cf12109344731937b88e8bb3611c5  # PR #508
    ```

    #539 reviewed head = `4a9b429a197b22028b32ef4113ad74900a7d5d28`，`lvye` 于
    `2026-07-25T09:06:06Z` APPROVED、`09:06:44Z` 合入；pushed head
    `63f6dcf69007f81269cce8747323eac84cc2e2a3` 与 reviewed head 之间的 update-branch
    只带入 chg-2026-036 的两个无关文件，本 task 十三个交付件两跳 tree diff = 0。
  - **Git input pins。**audit base parent =
    `e9848ba274123bea46b98e39cbf989bd93dfc225`，tree =
    `120ccd4988ae465108fdde9119b7095b1fd06c1c`，subject =
    `readiness(TASK-BRC-003): pin package blockers (#546)`。

    下列**十六个 blob 是 drift gate**：必须在 D2 preflight 中逐项相等，任一 drift 即零
    D2 write。`hostloop_init` 是 r3 起草期漏掉而循环每轮 import 的模块，此处补入。

    ```yaml
    agents_contract:     3c2d3c6a01d3eaa31cd9e3ee333f3153552f4164
    codeowners:          f4edd22f87965efcfc27ea512283a0c2252bf0fb
    agent_pr_workflow:   a514d9e539964f9e1960acbe4ffaa696629571da
    sdd_guard_workflow:  c64135e1f9dc253a92640a30bbcad42b0afa86fa
    chg030_proposal:     f179c9981d50d0e2a90cf20b93a6b6b23912e4bf
    chg030_design:       9cb3bebd1874e13a2ad580138d4f91eeace2fb6b
    chg030_verification: b3154599c3d2d935adfbcade5d9765cd34e3cca5
    hostloop_init:       7a6c5b9223c68f9d8aadd503fb38842346c710fc
    hostloop_main:       07d2c8d1a4c4d95bc28ce02449e4a724f47a161a
    hostloop_backends:   0efa3e8c74c7935f96742d4d9f1649cc91534dd2
    hostloop_transport:  55e17e3caf139522c189dc6284db6ae90272fad2
    hostloop_worker:     f71d3a9824e80bf0512b0dcf9afc5940e89486aa
    hostloop_cursor:     0961ec62409644421dc8ed8eea68230e8fa93b5e
    hostloop_lease:      685fb3c3c8c8266c52816027c92b300ea7cd6732
    hostloop_identity:   d22e62946e3b5b836cbdcd9b48b57031172fe4b1
    hostloop_envelope:   2c286c8da0fa8945d512115dfce9de5150db0831
    ```

    本文件的 blob **不是** drift gate，只作 provenance：合入本 readiness 必然改变它，
    把它写成「须在 merge tree 中相等」会自我否证。audit-base 值 =
    `ccb808d88c2d2bfc96f7a41135105016269ec7c8`；preflight 须记录合入后的实际值，并
    确认其与 audit-base 值之间的差异**只有**本 r3 block。
  - **Dispatch-authority binding:循环的权威必须来自 protected main，而非可写工作树。**
    已实测:`discover_candidates`/`_change_is_approved`/`done_task_ids` 全部读取本地
    checkout 的文件，而该 checkout 对 Agent 可写。因此每一阶段执行前后都必须记录
    `git rev-parse HEAD`、`git rev-parse origin/main`、以及
    `git status --porcelain -- <上表全部 drift-gate 路径> openspec/changes/*/tasks.md`
    ——三者须满足 `HEAD == origin/main` 且 porcelain 输出为空，否则零 D2 write。
    **这只是窗口期的补偿控制，不是修复**：「循环从可变工作树取得派发权威」是一项
    standing 架构缺口，须由 HLR-004/005 以「从 protected main 的 exact OID 读取治理
    输入」收口；本 readiness 明确不声称已解决它。
  - **Concurrency/absence gate:closed at discovery（2026-07-25）。**`agent/host-loop/**`
    远端 refs 全页计数 = 0。下列均 absent，**每一行都注明其被测量的域**，窗口第一步须
    在**同一个域**复验；r3 起草期曾把 runtime label 的缺席钉在 system 域而 Phase 3 将
    其装入 `gui/$(id -u)`，那样的 113 对一个只住 gui 的 unit 是恒真的非证据，此处更正
    为双域测量：

    ```yaml
    readiness_branch:   agent/task-hlr-003-d2-readiness-r3   # 远端 absent
    source_branch:      agent/task-hlr-003-minter-source     # 远端 absent
    evidence_branch:    agent/task-hlr-003-d2-evidence-r1    # 远端 absent
    refresh_label:      com.arkdeck.host-loop.refresh
      domain: system                                          # print -> exit 113
    runtime_label:      com.arkdeck.host-loop.runtime
      domain_gui: gui/<uid>                                   # print -> exit 113
      domain_system: system                                   # print -> exit 113
    launchagents_dir:   ~/Library/LaunchAgents                # 8 项，含 host-loop 者 0
    disabled_gui:       launchctl print-disabled gui/<uid>    # host-loop 条目 0
    disabled_system:    launchctl print-disabled system       # host-loop 条目 0
    service_account:    arkdeckhlr                            # 不存在（见退役条款）
    ```

    `cursor_issue` 不列为 absence pin——它没有稳定可观测的身份（任何人都可另建一个
    同名 Issue，而「不存在」无法由一次查询证明）。改为正向约束:窗口内
    `--cursor-issue` 一律不传且 `ARKDECK_HOST_LOOP_CURSOR_ISSUE` 一律不在环境中，
    receipt 以「本 App identity 名下 Issue 创建计数 = 0」为观测值。#395 是 batch
    Issue，永久不得复用。
  - **Credential topology:D′，binary。**两种不可互替的凭据:App installation token
    （app_id `4388667`、installation `148855345`、权限 `{metadata:read,
    contents:read, pull_requests:write, issues:write}`）只用于 PR/Issue；
    `agent/host-loop/**` 的 ref 写、以及**每轮两次 `git ls-remote`** 走 TASK-BAP-003
    Deploy Key 的 SSH 别名 `github-arkdeck-agent`。**App 是 `contents: read`，推不了
    ref**；Deploy Key 也不只用于写，读路径同样依赖它。

    token 生命期约 1 小时，而 `main()` 每轮都调 `read_token()`。授权且仅授权如下拆分：

    - **root 侧只做一件事:用 root-only PEM 签名并铸 token。**system 域 LaunchDaemon
      `com.arkdeck.host-loop.refresh`，`ProgramArguments[0]` 为 `/bin/sh`，其执行的
      minter 与全部被调用二进制**必须全部 `root:wheel` 且非 root 不可写**。已实测可用
      集合:`/bin/sh`、`/usr/bin/openssl`、`/usr/bin/curl`、`/usr/bin/base64`、
      `/usr/bin/install`、`/usr/bin/mktemp`、`/bin/chmod`、`/usr/sbin/chown`、
      `/usr/bin/stat`。纯 shell 铸 RS256 JWT 已实测通过独立验签
      （`openssl dgst -sha256 -verify` → Verified OK）。
    - **scheduler 侧以 `lvye` 自己的用户运行仓库代码**，只读
      `ARKDECK_HOST_LOOP_TOKEN_FILE` 指向的路径，**不接触 PEM**。

    **关于 sudo 的如实表述（更正 r3 起草期一处假陈述）:**该 scheduler 用户**持有全权
    sudo**——已实测 `dscl . -read /Groups/admin GroupMembership` = `root fuhanfeng`，
    admin 组成员在本机即可 sudo。因此「scheduler 永不获得任何 sudo 规则」是**假的**，
    且以 `sudo -l -U` 无 openssl 规则作为通过条件是一道**永远无法通过**的门（同一用户
    还需 sudo 执行 Phase 0 的 `ls` 与 Phase 2 的 `bootstrap`）。本 readiness 删除该
    表述与该门，改用三条可检验且确实为真的性质：
    ① **无新增 sudoers 规则**——窗口前后 `sudo -l -U <user>` 输出逐字节相同，且
      `/etc/sudoers.d/` 目录列表与各文件 sha256 前后相同；
    ② **scheduler unit 自身不调用 sudo**——其 `ProgramArguments` 与 minter 之外的任何
      被执行脚本中 `sudo` 出现计数 = 0，且 unit 以非 root 身份运行（`launchctl print`
      显示的 uid 须为该用户）；
    ③ **token 权威严格弱于该用户已持凭据**——受 App 四项权限约束，不含 ref 写、不含
      review/merge/admin，而该用户已持 Deploy Key 与 `gh`（scopes 含
      `repo`/`workflow`/`admin:org`）。故把 1 小时 token 置于该用户可读文件**不新增
      暴露面**；这是本拓扑的真实论证，不得改写成「已隔离」。

    **禁止形态（每条均有实测依据）:**root 进程执行任何非 root 可写的解释器或脚本
    （已实测 `/opt/homebrew` 及 Cellar 属 `fuhanfeng:admin`、`python3.14` 二进制属
    `fuhanfeng`、仓库 checkout 属 `fuhanfeng:staff`；以其作为 root daemon 执行面 = 任何
    以该用户运行的东西可无人值守取得 root，**严格差于给 scheduler 免密 sudo**）；以
    `/usr/bin/python3` 替代（已实测 3.9.6，`import host_loop` 即 `TypeError`，
    `identity.py` 的 `X | None` 运行时求值）；以 `curl -H` 传 JWT（已实测明文进 argv，
    `ps` 对所有本地账号可见；必须 `curl --config -` 从 stdin 喂，已实测 argv 仅
    `/usr/bin/curl --config -`，且配置不得落盘）；scheduler 以 root 运行；把 token 值
    写入 launchd 环境块（只允许写路径）。
  - **Scheduler ownership:`lvye` 自己的用户；`arkdeckhlr` 保留位退役。**三条理由均为
    实测:① `man launchd.plist` 明载 `UserName` 只适用于 privileged system domain 且
    「for agents, the UserName key is ignored」，LaunchAgent 无法以他人身份运行；服务
    账号无 GUI 会话，`launchctl print gui/<其 uid>` 返回 `Could not find domain for
    user gui`，故亦无可 bootstrap 的 agent 域。② `~/Dropbox` 实测 mode `drwx------`，
    服务账号无法遍历进入 checkout，给它访问权必须放松该 0700。③ 见上方 sudo 条款 ③：
    隔离 token 换不到东西。维护者 review/merge 本 readiness 即认可该退役；若不认可，
    窗口不得开启，须以 r4 重钉服务账号供给清单（含 0700 放松方案及其风险评估）。
  - **Blocking prerequisite ①:一个 D0 source PR（本 readiness 授权，含四项交付）。**

    1. **root-owned shell minter 的可 review 源**（仓内 `scripts/host_loop/` 下）。契约
       为二值:`curl --config -` 从 stdin 传 header；原子写（`mktemp` 于**目标同一
       文件系统**、`chmod 600`、`chown` 到 scheduler 用户、最后 `mv`，顺序为先权限后
       改名）；目标目录本身须 `0700` 且属 scheduler 用户；显式 `umask 077`；token 永不
       出现在 stdout/stderr/日志/argv；失败非零退出且**不截断也不删除**既有 token
       文件；`expires_at` 写入**不含 token** 的旁路 receipt。
    2. **`--explain` 干跑模式。**输出每个候选在每一道门上的判定与完整拒绝原因列表，
       零网络写入。这是 Phase 1/3 所要求的「逐门枚举」的产出工具——r3 起草期要求了一个
       当时没有任何命令能产出的观测，此处补齐使该门可判定。
    3. **归档依赖缺陷修复。**已实测 `done_task_ids` 只 glob `changes/*/tasks.md`，
       匹配不到 `changes/archive/<日期>-<change>/tasks.md`；`TASK-RPT-001`/`RPT-002`
       均已 done 且已归档却永久读作未闭，使 TASK-HLR-001A/002A 依赖恒不满足。归档一个
       change 会静默且永久废掉所有指向它的依赖且无任何报出。fail-closed 故不危险，但
       会让循环在未来必然卡住。
    4. **补测试护住「省略 `--cursor-issue` ⇒ 零 Issue 写」。**该保证目前由 `worker.py`
       单一 `if self._cursor_issue is not None` 承担且无测试覆盖；且已实测该参数默认值
       取自 `ARKDECK_HOST_LOOP_CURSOR_ISSUE`，**环境变量会静默供值**，故零写入不能靠
       「不传该 flag」保证。测试须覆盖这条绕过路径。
  - **`Decision-Grade`:不是本窗口前置，但它是当前唯一挡住一个 D1 产品任务的东西
    （更正 r3 起草期一处方向相反的结论）。**实测逐门（**跨全部 11 个活跃 change**，
    非仅本 change）：

    - 在本 change 内，八个候选全部被拒:HLR-001/002 `status=done`；HLR-001A/002A
      `status=done` 且依赖指向已归档 change；HLR-002B/004/005 `status=blocked`；
      **HLR-003 是唯一 `ready` 者而被 `never-claim` 明令禁止自我认领**。故在本 change
      内补齐 grade 不改变可派发性。
    - 但 **`TASK-RKFUI-001G`（chg-2026-026-macos-rockchip-flash-ui）其余每一道门均已
      通过**——`ready`、change 已批准、无硬件、非 never-claim、依赖已闭、allowed paths
      为 `scripts/rockchip_e0_probe/**` 与该 change 的 `evidence/**`——**只差一行
      `Decision-Grade`**。而该任务自身 readiness 写明它是 **D1**（host-only D1
      product-boundary audit）。

    因此 r3 起草期「补齐 grade 也依然一个都派发不出去」的说法是把单 change 结论当成
    全局结论，**方向相反**：`Decision-Grade` 的缺失正是当前唯一挡在循环与一个可认领
    D1 产品任务之间的东西。补齐它是**逐任务的人工判断**，不是批量填空；写错一个 `D0`
    即让循环去认领产品边界任务。**Agent 永不代写该字段**（已列入上方 Status 的不授权
    清单）。窗口期的补偿控制:scheduler 的 `--change` 恒为
    `CHG-2026-030-host-loop-runtime`，receipt 须记录该实参并以 `--explain` 输出证明
    该 change 内零可派发候选。
  - **Phase gates:0→3，逐阶段停。**每阶段完成即停下核验 receipt，任一项不符即停，
    不进下一阶段；不得为放宽任一门而推进。**每条 launchctl 命令必须写明其域**：root
    refresher 恒在 `system`，scheduler 恒在 `gui/$(id -u)`（该域正确，因 scheduler 本
    就以该用户运行）。r3 起草期「全部 launchctl 操作只用 system 域」的表述与 Phase 3
    自相矛盾，若照字面执行会产出被禁止的 root-running scheduler，此处删除。

    - **Phase 0（零主机变更）**:按上方 absence 表逐项复验，**每项在其注明的域内**；
      runtime label 须在 `gui/$(id -u)` **与** `system` 双域均返回 113，并同时检查
      `~/Library/LaunchAgents/` 无 host-loop 条目、两个 `print-disabled` 表无 host-loop
      条目（disabled-but-present 的 unit 不会出现在 `print` 中）。执行
      Dispatch-authority binding 的三项记录。`sudo ls -l <pem>` 须显示 `root` 拥有；
      **观测到的 mode 一律写入 receipt 作为基线，不设「receipt 未记录时自行放宽」的
      退路**。记录 `main` 全 OID 与 `sudo -l -U <user>` 的窗口前基线输出与
      `/etc/sudoers.d/` 清单及各文件 sha256。abort:任何 label/account/ref 已存在，或
      binding 三项不满足。
    - **Phase 1（手工前台单轮）**:命令须给出解释器全路径与 `PYTHONPATH=<repo>/scripts`
      ——已实测 `python3 -m host_loop` 从仓根跑不起来（`No module named host_loop`）。
      须显式 `unset ARKDECK_HOST_LOOP_CURSOR_ISSUE`。**Phase 1 与 Phase 3 必须使用同一
      解释器绝对路径**，该路径写入 receipt 并在 Phase 3 的 plist 中逐字节一致；否则
      Phase 1 的绿不对 Phase 3 构成证据。本阶段依赖前置① 已合入并安装。
      期望:退出码 10；新 PR = 0、新 ref = 0、`agent/host-loop/**` 仍为空；stdout 单行
      且不含 token 或 `/Users/` 路径。**`exit 10` 不是充分证据**——它同时覆盖「无候选」
      「候选全被拒」「候选被 never-claim 拒」等不同原因，故必须另附 `--explain` 输出
      作为逐门枚举。abort:退出码 1（先修环境，**不得**先建 launchd）或 0/20。
    - **Phase 2（root refresher unit）**:plist 置于 `/Library/LaunchDaemons/`，
      **`root:wheel` mode `0644`**（launchd 首先拒绝的就是 plist 属主/权限）；
      `sudo launchctl bootstrap system <plist>`；以
      `launchctl print system/com.arkdeck.host-loop.refresh` 确认存在。**必须配置
      `StandardOutPath`/`StandardErrorPath` 到 root 拥有且非 root 不可写的路径**——未配
      时 launchd 把 stdio 送 `/dev/null`，本窗口全部「观测」都不可观测。`StartInterval`
      定为 **1800s**，并配 `RunAtLoad=true`；因 `StartInterval` 在睡眠期间的触发会被
      跳过而非补偿，minter 必须在每次运行时**先检查既有 token 的 `expires_at`**，剩余
      不足 15 分钟即重铸，且 scheduler 侧遇 401/403 时须以 `Refused` 停止该轮而非重试。
      手工触发命令为 `sudo launchctl kickstart -k system/com.arkdeck.host-loop.refresh`
      （receipt 须记录该命令与其退出码；缺少手工触发命令时「token 文件未出现」与
      「尚未到点」不可区分）。触发后:token 文件 `0600`、owner 为 scheduler 用户、
      **父目录 `0700` 且属该用户**、link count = 1；旁路 receipt 有 `expires_at` 且无
      token；日志经检查不含 token。反证:以一个 root 拥有的空文件作为 PEM 路径参数
      触发（**不移动、不改名、不改权限真 PEM**），须非零退出且既有 token 文件未被截断
      或删除。abort:任一反证未成立，或日志为空。
    - **Phase 3（scheduler unit）**:plist 置于 `~/Library/LaunchAgents/`，**属该用户、
      mode `0644`**；`launchctl bootstrap gui/$(id -u) <plist>`；以
      `launchctl print gui/$(id -u)/com.arkdeck.host-loop.runtime` 确认存在，并确认其
      显示的运行 uid 为该用户（非 0）。`ProgramArguments` 形式为
      `[<python 绝对路径>, "-m", "host_loop", "--once", "--repo-dir", <repo>]`，配
      `WorkingDirectory=<repo>` 与 `EnvironmentVariables` 含
      `PYTHONPATH=<repo>/scripts`——已实测以脚本路径直接执行会因相对 import 失败，
      必须走 `-m` 且提供 `PYTHONPATH`。环境只含 `ARKDECK_HOST_LOOP_TOKEN_FILE`、
      `ARKDECK_REPO`、`PYTHONPATH`、`PATH`、`HOME`（`HOME` **不是** ssh 别名解析所需
      ——已实测 OpenSSH 用 `getpwuid` 定位家目录，r3 起草期该理由是错的；但 git 读
      `~/.gitconfig` 仍看 `HOME`，故仍设置并在 receipt 记录此真实理由）。必须配
      `StandardOutPath`/`StandardErrorPath`。须确认 `ARKDECK_HOST_LOOP_CURSOR_ISSUE`
      不在环境中。`StartInterval` 定为 **900s**。
      连续观察 ≥ 3 轮:每轮退出 10（由日志中每轮一行输出证明，并附一次 `--explain`）、
      PR/ref/Issue 增量全 0。**非并发不以「少一轮」推断**——launchd 的合并行为表现为
      缺失而非可见信号，故改为正向观测:minter 与 scheduler 均须在日志每行前缀写入
      `run_id` 与 pid，receipt 以「同一时间窗内不存在两个不同 pid 的未完成轮次」为
      观测值；若三轮内无法取得该观测，如实记录为「未证明」，不得写成「已证明」。
      反证:临时移除 token 文件后退出 1 且不创建任何东西，且该失败在日志中可见。
      abort:出现并发轮次、任何非 10 的稳定退出码、任何 GitHub 写入、或日志为空。
  - **Negative probes:必须为拒绝或缺席，且逐项以观测值证明。**窗口内不得出现:任何
    dispatch；任何 `agent/host-loop/**` ref 写；任何 Issue/PR 创建或编辑；任何
    review/approve/merge/auto-merge/update-branch/protection/ruleset/admin route；任何
    App 权限或 PEM 存放变更；任何新增 sudoers 规则；任何 legacy `agent-pr.yml` 行为
    改变。可观测项须给出观测值；**确无窗口期观测量者**（例如「未调用某 REST route」）
    改以运行时事实替代:`route_inventory()` 与 `forbidden_capability_count()` 的输出，
    以及 `ALLOWED_ROUTES` 内容与 drift-gate blob 一致这一事实。不得以「未执行」代替
    观测值。
  - **Rollback:先停、验停、再拆、再验缺席。**六步固定，**每步注明域**：
    ① `launchctl bootout gui/$(id -u)/com.arkdeck.host-loop.runtime`；
    ② `sudo launchctl bootout system/com.arkdeck.host-loop.refresh`；
    ③ **验证已停**——runtime 在 `gui/$(id -u)` **与** `system` 双域 `print` 均 113；
      refresh 在 `system` 为 113；`pgrep -fl host_loop` 为空；两个 `print-disabled`
      表无 host-loop 条目。**`bootout` 首次即返回 113 意味着打错了域，不等于「本来就
      没在跑」**；且只有 `print` 返回 113 不足以断定未武装，必须同时确认 plist 已删
      （见 ④）与 disabled 表干净。
    ④ 删除两个 plist 文件（`~/Library/LaunchAgents/` 与 `/Library/LaunchDaemons/`）
      ——只 `bootout` 不删 plist，则下次开机/登录会重新武装；
    ⑤ 删除 token 文件，并**明确记录该删除既不吊销该 token 也不擦除磁盘残留**（已实测
      macOS `rm -P` 在本机文档中为无操作，不得写成「已安全擦除」）；如需真正失效须由
      维护者在 GitHub 侧处置，属 TASK-HLR-002 receipt 范围；
    ⑥ 复验 Phase 0 全部 absence 与 sudoers 基线恢复成立，并宣告
      `terminal=rolled-back`。
    PEM、App、installation、Deploy Key、ruleset、protection 一律不动。lease ref 的
    删除**不在** rollback 内——Phase 0–3 不创建任何 lease ref；若出现属 reconcile
    事件，须停机由人判断，不得由 rollback 顺手写删除。
  - **Receipt shape:**`evidence/runs/TASK-HLR-003/d2-scheduler-*.md` 加配套 `.json`，
    照 TASK-HLR-002 的 `d2-*.json` 形状。须含每阶段命令（含域）/退出码/观测值、
    `--explain` 逐门枚举、三元组（installed hash、仓内 hash、该次 main OID）、
    Dispatch-authority binding 三项记录、`workerDisabled` 状态迁移、label 与 account
    存在性前后对比（注明域）、sudoers 前后基线、全 OID/全 hash（不用截断前缀）、
    negative probes 观测值、终态宣告，以及明写**未做**什么。
    脱敏面**与 TASK-HLR-002 已合入的门一致或更严**:不得含 token、JWT、PEM 内容、
    `Authorization`/`Bearer` 值、任何绝对 `/Users/` 路径、设备序列号、connect key，
    亦不得含 root-only PEM 的**目录路径**或 staging 路径明文。
    **一处如实登记而非假装隐藏:**PEM 路径会出现在 root 进程 argv 中，对本机所有账号
    可见（`openssl dgst -sign <path>` 必须以路径接收密钥）。TASK-HLR-002 只以 SHA-256
    发布该路径；本 readiness 记录该隐蔽性在窗口开启后不再成立。路径本身不是秘密
    （文件对非 root 不可读），但 receipt 不得声称路径仍未公开，也不得因此把路径写进
    receipt 正文。
  - **Phase 4 不在本 readiness 授权范围。**三条理由:① 它是本 change 第一次**永久公开
    写入**（Issue 可关闭不可删除）；② 已实测其当前形态**无法工作**——手工创建的 Issue
    没有机器块，`cursor.load` → `parse_machine_block` 直接拒绝且不代建，每轮 exit 1，
    故 Phase 4 需要先定义「如何合法播种第一个机器块」这一尚不存在的机制；③ 它唯一的
    意义依赖「本 change 内存在可认领的 D0 任务」，而按上方实测该条件在 HLR-003 → done
    且 HLR-004 → ready 之前不成立。现在授权等于在未合入的门后面预先授权。
    另:HLR-003 自身的 live first-PR proof 归属**不由本 readiness 改判**——r3 起草期曾
    把它整体推给 HLR-005，而 HLR-005 依赖 HLR-003 done，构成环。本 readiness 只声明
    Phase 0–3 不产生任何 live PR proof，该 proof 的归属留待 r4 与 HLR-004 readiness
    共同钉定。
- Historical Readiness r2（原 Status，r3 生效后降级为历史；仅在维护者对本独立 readiness PR exact
  head review/merge 后生效。r1 已交付的 offline runtime 不重新授权；r2 只额外授权
  一个 D0 source PR 交付 worker 的可执行入口与生产后端接线，使 scheduler 有可绑定
  的对象；不授权 scheduler 创建/注册/启用、worker 启动、legacy creator 在 live
  proof 前退出、review/merge/auto-merge/admin route、D2 credential 修改、
  `sdd-guard.yml` 或任何 governance text 变更。）
- Readiness（r2；audit base = protected `main`
  `1a8e235fc7174c647e8e971dee3f1a6d2dd16325`）：
  - **Approval boundary:pending human merge。**本 carrier 只修改本文件
    TASK-HLR-003 section。只有 `lvye` 对 exact head APPROVED、required checks
    terminal success、`mergedBy=lvye`、`auto_merge=null` 且 squash subject 携
    `(#N)` 的 merge OID 进入 protected main 后，本修订才生效。合入前
    source/workflow/ref/PR/Issue/scheduler/credential mutation = 0。
  - **Why r2 exists:r1 的 scheduler 条款与 In scope 自相矛盾。**r1 的
    `Scheduler separation` 门写明「不创建 account/plist/socket/**worker
    executable**」，而同一任务 In scope 要求交付 worker `--once` loop。该禁令是从
    TASK-HLR-002 readiness 逐字搬来的——对 identity 任务成立，对 worker 任务则禁掉
    了本任务存在的目的。后果是**无人被授权创建入口**：source PR 被禁止，而 D2 阶段
    是主机/凭据操作，在 D2 窗口内撰写源码本身越界。实测确认 r1 source PR #524 合入
    后，`scripts/host_loop/` 在 protected main 上 `__main__`/`argparse`/`def main`/
    `if __name__`/`--once` 的非测试命中均为 0，`subprocess`/`urllib`/`http` 的
    非测试命中亦为 0——即注入式后端全无生产实现。r2 收窄禁令并显式授权补齐。
  - **Dependency/authority gate:closed。**r1 readiness #521 merge
    `2667a10badb8180a0c7f5079636d46b03f637184`；r1 source #524 merge
    `1a8e235fc7174c647e8e971dee3f1a6d2dd16325`（parent
    `c74fa46a810f6713b987c639ce23246ddf24a307`，改动面恰为
    `scripts/host_loop/**` 十个文件）。两者均为 audit-base ancestors。
  - **Corrected scheduler separation:binary（取代 r1 同名门）。**本 task 的 source
    PR 不得创建 launchd account、plist/job/socket，不得 load/enable/kickstart，
    scheduler dispatch 恒为 0、`workerDisabled=true`。**worker 的可执行入口与生产
    后端属源码，明确在 source PR 授权范围内。**scheduler 绑定 exact merged source
    blob hash 与启用仍属 source PR 合入后的**分离** D2 evidence 阶段；source 未
    合入或 receipt/source hash 漂移时 dispatch 恒为 0。
  - **Authorized second source PR:binary。**只授权在
    `scripts/host_loop/**` 内交付下列面，且必须与已合入的 offline 契约保持行为
    一致（既有 189 项 offline test 不得放宽）：
    - `--once` CLI 入口（`python3 -m host_loop --once` 可被 launchd 直接调用），
      exit code 区分 dispatched / no-dispatch / reconcile-required / error；
    - `ApiPort` 的生产 sender：只发 typed allowlist 路由，token 从环境或 root-only
      staging 读取且不落日志、不进 argv；
    - `RefPort` 的生产 git runner：`ls-remote` 与
      `push --atomic --force-with-lease=<ref>:<expected>`，服务端拒绝与歧义传输
      失败必须仍分别映射到 `Refused`/`PolicyRefused` 与 `TransportError`；
    - `prepare_branch`、`render_body`（复用已合入的 `pr_envelope.render_envelope`）、
      `read_lease_record`、`commit_writer` 的真实实现；
    - installation token 的最小获取路径（JWT 签名交由 root 侧 openssl，PEM 不进
      进程内存），与 TASK-HLR-002 evidence 记录的 containment 一致。
    禁止在该 PR 内新增任何 typed route、放宽任何字段 allowlist、或引入 generic
    request/escape hatch；`ALLOWED_ROUTES` 与 `forbidden_capability_count` 的
    negative proof 必须继续为 0。
  - **Merged source pins:closed。**第二个 source PR 必须以下列 exact blob 为基线；
    任一 drift 即停并重新 readiness：

    ```yaml
    host_loop_init: 7a6c5b9223c68f9d8aadd503fb38842346c710fc
    transport:      6a77e264ed8b5f717d2dc2734f7f19b1226e95c2
    lease:          f260f43d2c2b1e614f33f9ccfaacf2f57ac5b47b
    identity:       d22e62946e3b5b836cbdcd9b48b57031172fe4b1
    cursor:         24063899d0b1f0b4a89511aa6e20fcf3970ce354
    worker:         d3bc77c18a28f2d478b1bf483aa352bdc7a33c2a
    pr_envelope:    2c286c8da0fa8945d512115dfce9de5150db0831
    ```

  - **r1 gates carried forward unchanged:binary。**下列 r1 门在 r2 下继续完整有效，
    不因本修订而重新开放或放宽：F1 的 option B 决议（reserved namespace 的
    `pull_request` 覆盖由 worker 一次 body update 触发 `edited`，`.github/**` 零
    改动；F2 因此不适用且已如实记录）、F3 已交付的 envelope token 统一与 parity
    测试、F4 的 CAS 证明义务（**仍 open**：topology evidence 与 HLR-002 的单次
    stale-fence 均不构成充分证明）、fault matrix、adapter negative proof 三重
    证伪、migration atomicity（legacy coverage 不得早于同 PR 的 live proof 退出）、
    self-claim stop（worker 不得 claim `TASK-HLR-003` 及其后缀变体）。
  - **r1 delivery of record:informational。**r1 source PR #524 经三个 head 与一轮
    自动化 unbound-guard 审计后合入：审计提出 41 项候选、证伪 34 项、确认 7 项，
    其中两项 high 为「required check 判据按名字判定且 `skipped` 计为 green」，
    致 check dispatch 在生产中从未触发且可能在路径契约未被评估的 head 上返回
    `checksGreen`；均已在合入前修复。合入面为 offline 契约与测试，无入口、无生产
    后端——这正是 r2 要补齐的部分。
  - **Live-proof task dependency:open（阻塞后段，不阻塞本修订与第二个 source
    PR）。**live first-PR proof 与 legacy migration 仍需一个**天然产生**的 ready
    host-only D0 task。撰写时 `TASK-RKFUI-001G` 为 `ready`、`hw=no`、macos
    host-only，且其 `G` 后缀正是 r1 F3 统一后才可被 envelope 接受的形态；是否以其
    为 live proof 对象属维护者判断，不得为满足该 proof 制造任务。
  - **Concurrency/absence gate:closed at drafting。**remote 上
    `agent/task-hlr-003*` 分支数 = 0；`agent/host-loop/*` 分支数 = 0。历史
    `agent/task-hlr-003-worker-loop` 已随 #524 合入删除，不得复用。push 前须重查
    全页 open PR 与 remote 分支。
- Historical Status:ready（r1 implementation readiness；仅在维护者对本独立 readiness PR
  exact head review/merge 后生效。只授权一个 D0 source PR 交付 worker `--once`
  loop、Issue cursor、fenced lease、typed GitHub adapter、`agent-pr.yml` 的
  reserved-namespace `pull_request` allowed-paths 覆盖与 expected-author
  参数化、envelope task-token grammar 统一，以及 unit/contract/fault tests；
  不授权 scheduler 创建/注册/启用、worker 启动、legacy creator 在 live proof
  前退出、review/merge/auto-merge/admin route、D2 credential 修改、
  `sdd-guard.yml` 或任何 governance text 变更。）
- Historical Readiness（r1；audit base = protected `main`
  `f0ed7f8e901bc1acf9d740b02c7d9bbb563b39f8`；scheduler 条款经 r2 更正）：
  - **Approval boundary:pending human merge。**本 carrier 只修改本文件
    TASK-HLR-003 section。只有 `lvye` 对 exact head APPROVED、required checks
    terminal success、`mergedBy=lvye`、`auto_merge=null` 且 squash subject 携
    `(#N)` 的 merge OID 进入 protected main 后，本 readiness 才生效。合入前
    source/workflow/ref/PR/Issue/scheduler/credential mutation = 0；本 merge 不
    构成 implementation evidence、task done 或 change `verified`。
  - **Dependency/authority gate:closed。**① change revision r3 approval；
    ② TASK-HLR-001 done merge `d09f5021107e4133d2fc41c1ce65d0bd09d6c12b`
    （`(#402)`）与 TASK-HLR-001A done merge
    `1815105971b5ec9bee58cb7be04cd759dc01a32b`（`(#495)`）；③ TASK-HLR-002A
    done merge `901708a7af9893bc91ee654630df6922ea5099f8`（`(#507)`）；
    ④ TASK-HLR-002 D2 evidence #518 exact reviewed head
    `111ccae0c42c03a960cc7e47fc790cda39c4d31a` 由 `lvye` 于
    `2026-07-25T03:09:59Z` APPROVED、`03:10:05Z` 以
    `8e76ea4b9a832b31588f000c35feffde9f0d1c6d` 合入，done #520 exact reviewed
    head `f729d7156b11a671c083349860939ef23f4d4142` 由 `lvye` 于
    `2026-07-25T03:19:51Z` APPROVED、`03:21:26Z` 以
    `f0ed7f8e901bc1acf9d740b02c7d9bbb563b39f8` 合入；两者 `auto_merge=null`、
    `mergedBy=lvye`。①–④ 均为 audit-base ancestors。
  - **Identity/staging receipt pins:closed。**consume TASK-HLR-002 evidence：
    private App `4388667` / `arkdeck-host-loop-runtime-901708a7[bot]`，单仓
    installation `148855345`（`repository_selection=selected`，
    `GET /installation/repositories` 权威确认为 `[ArkDeck/ArkDeck]`），permission
    恰为 Metadata read / Contents read / Pull requests write / Issues write，
    `events=[]`；App 非 CODEOWNER、非 ruleset bypass、非 main push actor；PEM 仅
    root-only staging（`-rw------- root:wheel`）；scheduler owner `arkdeckhlr`
    与 launchd label `com.arkdeck.host-loop.runtime` 仍仅为 reservation，
    account/plist absent，**`workerDisabled=true`**。evidence blobs =
    `43f55a2950e1e77461e3ccde99168fdbd2dc8885` /
    `505ca0ab97c8ad7e01c5e902deb9ac03739615fe` /
    `3f4d0e28f36937cca8f7c6bb7be04f33bc1e142f` /
    `365b6724d5a31258d693e98b1d21fe396a0b1648` /
    `e39cb93d42321150dd54ba5f8e5fa181676a9e0d` /
    `4cf01bdcb135b9023e4425fe981eb33448fa4d50` /
    `a46868f8bbf0829482f866e7de4d01e818af8e0d`。receipt 漂移即零 implementation
    write。
  - **Git input pins:closed。**下列 blobs 必须在 implementation base 与本
    readiness reviewed-head/merge tree 中逐项相等；任一 drift 即停并重新
    readiness：

    ```yaml
    agent_pr_workflow:      a514d9e539964f9e1960acbe4ffaa696629571da
    sdd_guard_workflow:     c64135e1f9dc253a92640a30bbcad42b0afa86fa
    mech004_parser:         02332a9b572013e99b74acd46db8810ba4f7275a
    mech004_tests:          feb697f760c8b2ba9e57072ac79f73a96ed7905f
    workflow_contract_test: 10b32515f9590ba78eb9fa477e8fc7b0b93d15a2
    host_loop_init:         a0e413fbf6bab34fbfeafc236a09f24c7a6c7f00
    pr_envelope:            c990fcfb17de52ed1166fec55cb1f9365e0e7736
    pr_envelope_tests:      35d9a284e8ddde67fd1076bc1c2f0f11f02d26db
    chg030_design:          9cb3bebd1874e13a2ad580138d4f91eeace2fb6b
    ```

    `sdd_guard_workflow` 为 forbidden-path witness pin：本 task 禁止修改该文件，
    它必须在 implementation 前后完全不变。
  - **Reserved namespace zero-creator gate:closed。**以仓库内
    `scripts/test_agent_pr_workflow.py` 的 ordered evaluator 对 exact patterns
    `('agent/**', '!agent/host-loop/**')` 判定：legacy creator 对
    `agent/host-loop/tasks/**`、`agent/host-loop/leases/**`、
    `agent/host-loop/probes/**` dispatch 恒为 false，对 ordinary `agent/**` 仍为
    true；remote `agent/host-loop/*` 分支数 = 0。TASK-HLR-002 D2 实测复证：
    reserved head 上 `agent-pr.yml` run 数 = 0、全状态 PR 数 = 1。
  - **Reserved `pull_request` check coverage:binary（F1 决议）。**TASK-HLR-002 D2
    实测确立：reserved namespace 上 bot `opened` 事件不产生任何 `allowed-paths`
    job——`agent-pr.yml` 为 push-only 且排除 `agent/host-loop/**`，
    `sdd-guard.yml` 的该 job 受 `if: github.event_name == 'pull_request'` 限制
    且 `types` 仅 `[reopened, edited]`（design §1H 故意排除 bot `opened`）。同一
    实测也确立 `allowed-paths` 逻辑本身对 reserved PR 是**通过**的：probe PR 上
    `guard` = success/success、`allowed-paths` = skipped（push）/**success**
    （`edited`）、`swift` = success，`action_required` = 0。因此缺的只是触发事件。
    本 task 只允许在 `.github/workflows/agent-pr.yml` 内新增 reserved-namespace
    `pull_request` allowed-paths 覆盖；禁止修改 `sdd-guard.yml`，禁止为 ordinary
    lane 重新引入 bot `opened` 或 routine `synchronize`，禁止
    `pull_request_target`。新 job 必须 read-only（`contents:read` +
    `pull-requests:read`）、把 PR JSON 落临时文件后在 Python 内解析、不把 PR
    title/body/head 文本插入 host shell。
  - **PR author parameterization:binary（F2）。**`agent-pr.yml` 现有两处
    `--expected-author 'github-actions[bot]'`（`:97`、`:164`）。legacy push job
    必须继续 exact 期望 `github-actions[bot]`；新 reserved job 必须 exact 期望
    `arkdeck-host-loop-runtime-901708a7[bot]`。任一处放宽为 wildcard、正则或
    空值即 fail closed。
  - **Envelope token grammar unification:binary（F3；跨 HLR-001 契约面）。**
    `scripts/host_loop/pr_envelope.py` 的 `TASK_RE`/`TASK_HEADER_RE` 当前为
    `TASK-[A-Z0-9]+-[0-9]{3}`，比 `scripts/check_pr_paths.py` r4 token
    `TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?` 窄；实测 active task header
    中 14 项（`TASK-HLR-001A/002A/002B`、`TASK-RKFUI-001A/B/C/D`、七个
    `TASK-UD-*`）被 MECH-004 接受而被 envelope 拒绝。本 readiness 显式授权在同一
    source PR 内把 envelope 收敛到该单一 token definition，并加 parity 测试断言
    两处定义逐字节相同以防再分叉。收敛不扩张路径授权：suffix token 仍须唯一解析
    到 active `tasks.md` exact header；malformed、lowercase、多字符 suffix、多个
    不一致 Task 与 token adjacency 继续拒绝；不得把 `TASK-HLR-002A` 别名为
    `TASK-HLR-002`。本项修改 TASK-HLR-001 已 done 的契约面，按 TASK-RPT-002 先例
    在本 readiness 显式声明 scope，不得夹带；`scripts/host_loop/**` 已在 Allowed
    paths 内。
  - **Lease CAS proof obligation:open（F4）。**CHG-2026-033 TASK-RPT-001 topology
    evidence 只证明 Deploy Key 在 `refs/heads/agent/host-loop/**` 四层 ref 上
    create/update/delete 成功，**不构成 compare-and-swap 证明**。TASK-HLR-002 D2
    已额外实测一次 stale-fence 写入被服务端 precondition 拒绝，但仅覆盖单一场景。
    本 readiness 禁止把上述任一 evidence 引用为 CAS 已充分证明；exact
    `--force-with-lease`（指明旧 remote OID）语义必须由本 task 自己的 fault
    matrix 完整证明，且实现必须区分服务端明确拒绝与歧义传输失败——只有前者可
    作为负向证据。
  - **Fault matrix:binary。**下列每项必须 fail closed 且 duplicate dispatch = 0：
    双 worker 同时 acquire、stale fence write、heartbeat loss、create timeout
    （先 GET reconcile，禁止盲重试）、Issue/cursor corruption、PR lookup 命中 0
    或 >1、reserved 分支上 legacy creator 共存。create 意图必须在 create 调用
    **之前**持久化，使响应丢失的 create 不能被重放为第二个 PR。
  - **Adapter negative proof:binary。**typed adapter 只暴露 PR lookup/create/
    update、Issue lookup/create/update 与 `agent/**` ref read/create/CAS/delete。
    review/merge/auto-merge/branch-update/admin route 构造数恒为 0，必须由三重
    证伪同时给出：fake transport 记录全部构造 route、route inventory 断言、
    source scan 排除 generic request/escape hatch。reviewer process 不接收
    integration credential。credential 面因 identity 的 Contents 被钉为 read 而
    必然分离：PR/Issue 走 App installation token，`agent/host-loop/**` ref 的
    create/CAS/delete 走 TASK-BAP-003 Deploy Key；GitHub REST 的
    `PATCH /git/refs/*` 只有 `force` 布尔、无 expected-old-OID 参数，故真正的
    CAS 只能由 git 侧 `--force-with-lease` 实现。该双 backend 结构属本 task
    scope，不得被误判为 scope 蔓延。
  - **Migration atomicity:binary。**`agent-pr.yml` 对 reserved namespace 的
    legacy coverage 移除/禁用不得早于同一 PR 内的新 creator live proof。rollback
    先停 scheduler/worker，再恢复 reserved namespace 的 legacy coverage，然后对
    未释放 lease/开放 PR 做只读 reconcile；branch disappearance 永远不得解释为
    merge（TASK-HLR-002 D2 已出现一次由 `lvye` 手动提前删除 probe ref 的实例，
    未 merge 由 main OID、ancestry 与 PR `closed/unmerged` 三条独立证据确认）。
  - **Scheduler separation:binary。**本 source PR 内 scheduler dispatch 恒为 0、
    `workerDisabled=true`；不创建 account/plist/socket/worker executable，不
    load/enable/kickstart。scheduler 绑定 exact merged source blob hash 与启用
    属 source PR 合入后的**分离** D2 evidence 阶段；source 未合入或 receipt/
    source hash 漂移时 dispatch 恒为 0。
  - **Live-proof task dependency:open（阻塞后段，不阻塞 source PR）。**
    worker 的 live first-PR proof 与 legacy migration 需要一个**天然产生**的
    ready host-only D0 task 供其 claim；本 readiness 撰写时 active changes 中
    ready 任务数 = **0**（`TASK-SSET-001` 与 `TASK-RKFUI-001E` 均已在本日被独立
    会话推进为 `blocked`）。禁止为满足该 proof 而制造任务。因此 readiness、
    source PR 与全部离线 unit/contract/fault tests 不受阻，但 scheduler
    activation、live first-PR proof 与 legacy creator 退出必须等到一个 ready
    host-only task 自然出现。
  - **Self-claim stop:binary。**本 readiness 合入后 `TASK-HLR-003` 自身即为
    `ready` host-only task。worker 不得 claim `TASK-HLR-003`：其 discovery 必须
    显式排除本任务，否则会对正在人工实现的任务另开 PR。如需以本任务作为 live
    proof 对象，须经独立 readiness 明确授权。
  - **Concurrency/absence gate:closed at drafting。**remote 分支全页只含
    protected main 与四个 `agent/**`（`rkfui-001-identity-separation-readiness`、
    `task-hlr-002-readiness`、`task-hlr-002a-bootstrap-partition`、
    `task-rkfui-001f-done`），与本 task 零交集；`agent/task-hlr-003*` 与
    `agent/host-loop/*` 均 absent。历史 `agent/task-hlr-002-readiness` 永久不得
    复用。push 前须重查全页 open PR 与 remote 分支，确认无另一会话同 lane
    （先例 AFP-005）。
  - **Batch:approved。**维护者已批准本 readiness 与 TASK-HLR-002 done PR 攒为
    同一 review 批次；批次内每个 PR 仍为独立 PR、独立 exact-head review，不混装
    scope。
- Platform:macos（host-only）
- Requirements/AC:change-local `HLR-LEASE-001`、`HLR-WORKER-001`
- Depends on:TASK-HLR-001 done、TASK-HLR-002A done、TASK-HLR-002 done、
  independent readiness
- In scope:worker `--once` loop、Issue cursor rebuild、remote fenced lease、heartbeat、
  deterministic PR lookup/create/update、existing `agent-pr` bootstrap 的原子迁移、
  无 generic REST/GraphQL escape hatch 的 typed GitHub adapter、unit/fault tests、
  source 合入后的分离 scheduler registration/enable 与 live worker evidence。
- Out of scope:reviewer adapter/dispatch、batch merge、task/change 状态自动翻转、
  任意 governance text、D2 credential 修改。
- Allowed paths:`scripts/host_loop/**`、`.github/workflows/agent-pr.yml`、本 change
  `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence 引用）。
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、`openspec/governance/**`、
  `openspec/specs/**`、`openspec/contracts/**`、`openspec/changes/archive/**`、
  `.github/workflows/sdd-guard.yml`、产品 source/tests、其他 change。
- Risk:medium（lease split-brain 或 migration 双 creator；fence/identity ambiguity
  必须停 lane，不能创建第二个 PR）。
- Hardware required:no。

### Deliverables

- remote create/CAS renewal/release/takeover 的 fence implementation，以及 crash/
  timeout 后按 stable branch + task + base OID adopt 唯一 PR 的 reconciliation；
- Issue cursor 作为可重建 cache 的实现；cursor/parser API error 与多个 PR 命中均
  `reconcile-required`；
- typed GitHub adapter 只暴露 PR lookup/create/update、Issue lookup/create/update 与
  `agent/**` ref read/create/CAS/delete；review/merge/auto-merge/branch-update/admin
  route 构造数恒为 0，reviewer process 不接收 integration credential；
- migration 仅在新 integration identity 成功的 live probe 后关闭 legacy creator，且
  rollback 记录不把 branch disappearance 解释成 merge。
- source PR 合入后才允许维护者把 scheduler reservation 绑定 exact source hash 并启用；
  activation/evidence PR 与 source PR 分离，启用前 `workerDisabled=true`。

### Verification

- `HLR-LEASE-001`/`HLR-WORKER-001` contract + live integration：双 worker acquire、
  stale-fence write、heartbeat loss、create timeout、Issue corruption、0/2 PR lookup、
  old creator coexistence 分别 fail closed；唯一有效 lease 能创建带完整 envelope 的
  `agent/host-loop/tasks/**` task PR，并在首个 `pull_request` event 上看到 checks；
  reserved branch 零 legacy creator；scheduler receipt source hash 与 main exact blob
  相同；fake transport/route inventory/source scan 证明 generic request 与
  review/merge/admin route 均不可构造；
  `MECH-004` allowed-paths、`check-sdd`、diff check 均绿。

### Notes / handoff

- `agent-pr.yml` 的移除/禁用不得早于同 PR 的新 creator live proof；
- migration 任何失败都先停止 scheduler，并保留旧 workflow 或明确 rollback，不能
  通过手工补 body 把失败伪装为首个 checks 已触发。

## TASK-HLR-004 — 独立 reviewer loop、merge-OID recovery 与 batch handoff

- Status:done（2026-07-26 D0 completion；仅在维护者 review/merge 本独立
  `ready→done` PR 后生效。授权载体 = r1 readiness #553 merge
  `fde34146d6f0cc005a4620977222ee4748e216e1`；source PR = #554 merge
  `f85e8cf2b2e2fd99c884c213a5a918e87d19c829`（`lvye` APPROVED、`mergedBy=lvye`、
  `auto_merge=null`；6 文件 +1556/−4：reviewer.py、recovery.py、73 条契约测试、
  #552 打破的 stale 时点断言按 r1 授权修复、contract-run evidence）。flip base
  `f85e8cf2…` 复验：480 tests OK + 1 expectedFailure（= `Decision-Grade` 缺口在案
  记录，未摘除）；check-sdd 0/0/111；`--explain` 显示本任务被拒且唯一理由 =
  grade unknown（r1 互斥 pin 所预期的补偿观测）；12 source pin 于 #554 前零漂移；
  worker.py/`__main__.py` 零触碰、transport 路由 10 条由测试钉死、变异 12/12 击杀
  + 负对照存活（首轮 M9 存活经加强断言击杀，过程在 evidence）。evidence =
  `evidence/runs/TASK-HLR-004/contract-run.md`（#554 携带入 main）。本 done
  **不声称**：live reviewer session dispatch、batch Issue 的 live 写、live
  first-PR proof、legacy creator 迁移——均属 TASK-HLR-005（r5 转移条 + 本任务
  r1 边界）。r1 的 Decision-Grade 互斥 pin 随本 done 解除：本 change 内补 grade
  的时机约束移交 HLR-005 readiness 统一编排。）
- Historical Status:ready（r1 implementation readiness；仅在维护者对本独立 readiness
  PR exact head review/merge 后生效。只授权 ① 一个 D0 source PR，在
  `scripts/host_loop/**` 内交付 reviewer loop、merge-OID recovery 与 batch gating
  的 **offline** 实现与 contract/fault tests（含下方点名的一处 stale 时点断言
  修复），② 其后一个独立 evidence 记录与 ③ 一个独立 `ready→done` 状态 PR。
  **零 live GitHub 写**：本任务全部验证走既有 fake ports；live dispatch/batch
  Issue 写/legacy 迁移均属 TASK-HLR-005。不授权：GitHub review API 调用、
  review/merge/auto-merge/admin route、任何 scheduler/launchd/unit/host 变更（两
  unit left-running 冻结条款继续有效）、`agent-pr.yml`/`sdd-guard.yml`/governance
  text 变更、transport 新增 route 或放宽 allowlist、以及**代任何任务撰写
  `Decision-Grade`**。①②③ 依次由 #554（source+evidence）与本 done 翻转消耗。）
- Historical Status:blocked（前置：① 本 change approval；② TASK-HLR-003 done；③ 独立
  readiness PR 钉定 reviewer adapter interface、failure matrix、batch Issue schema 和
  merge-OID sources；④ 不产生 PR 的 reviewer backend availability probe。①② 已闭：
  approval 与 #552 done merge `24395db6b15d72781f142991aa06e765cbb695cb`；③ = 本 r1
  readiness；④ 已于 2026-07-26 执行，见 r1。）
- Readiness（r1；audit base = protected `main`
  `24395db6b15d72781f142991aa06e765cbb695cb`）：
  - **Approval boundary:pending human merge。**本 carrier 只修改本文件
    TASK-HLR-004 section。只有 `lvye` 对 exact head APPROVED、required checks
    terminal success、`mergedBy=lvye`、`auto_merge=null` 且 squash subject 携
    `(#N)` 的 merge OID 进入 protected main 后，本 readiness 才生效。合入前
    source/host/GitHub mutation = 0。
  - **Dependency gate:closed。**① change approval（r3 #「approval #455 链」既存）；
    ② TASK-HLR-003 done merge `24395db6b15d72781f142991aa06e765cbb695cb`（#552，
    `lvye` APPROVED、`auto_merge=null`）；③ = 本 carrier；④ backend availability
    probe 已执行（2026-07-26，只读零副作用）：`claude --version` → exit 0、输出
    `2.1.220 (Claude Code)`，可执行文件位于操作者 PATH（`~/.local/bin/claude`）；
    `codex` 不存在。probe 不触碰仓库、不创建 PR/Issue/ref。
  - **Reviewer adapter interface:pinned。**注入式 `ReviewerPort`，唯一方法
    `request_review(ReviewRequest) -> ReviewResult`。`ReviewRequest` 不可变：
    `{change, task, pr_number, head_oid(40-hex), base_oid(40-hex),
    checks_digest, requested_by_run}`；`ReviewResult` 不可变：
    `{verdict ∈ {APPROVE, REQUEST_CHANGES, BLOCKED}, reviewer_run, head_oid,
    recorded_at, reasons}`。硬约束（各配 contract test）：(i) adapter 构造参数
    不含 token/ApiPort——reviewer process 不接收 integration credential；
    (ii) `reviewer_run == requested_by_run` 的结果被拒收（HLR-REVIEW-001 同会话
    禁令）；(iii) 结果序列化恒携「NOT a GitHub approval」声明字段；(iv) production
    adapter = 独立 `claude` 会话 subprocess（独立 run ID/工作目录），**HLR-004 只
    交付其 argv/契约与 availability probe，不做任何 live dispatch**。
  - **Failure matrix:pinned（行为逐条 contract/fault test）。**① adapter
    timeout/crash/非零退出 → `reconcileRequired`，零入队零盲重试；② result.head
    ≠ request.head（head 漂移）→ 旧结论作废、候选退回 discover；③ verdict 非三
    值/解析失败 → `reconcileRequired`；④ 同会话结果 → 拒收 +
    `reconcileRequired`；⑤ `REQUEST_CHANGES`/`BLOCKED` → `workerPaused`，不入
    队；⑥ checks 缺失/未全绿/歧义 → 候选不合格，不发起 review；⑦ 重复结果 →
    后到者拒收；⑧ merge observation 歧义（两源不一致或不可唯一判定）→
    `reconcileRequired`，零 lease release/零 cursor advance；⑨ 任何外部写前
    lease fence mismatch → 停（既有 r1 gate 延续）。
  - **Batch Issue schema:pinned = CHG-2026-027 canonical。**载体
    `openspec/templates/batch-digest.md` exact blob
    `f5f82e3413c88a646f49047f952a0677e92f636b`；digest 条目字段 = Grade、
    Change/Task、内容、Base/Head OID（完整 40-hex）、Files read-back、风险与影响
    面、Evidence/测试指针；**入队三门 = checks 全绿 + 独立会话对 exact head 的
    APPROVE（head 变更即失效）+ digest 全字段完整**，缺一 `batchQueued` 不达。
    batch Issue 仅导航、零批准语义、任何等级无 auto-merge（首屏声明原样）。
    HLR-004 交付 gating + 条目 render + contract tests；live batch Issue 写属
    HLR-005。canonical 载体不可用即记录 blocked，不自建权威载体（Notes 原文）。
  - **Merge-OID sources:pinned（双源交叉，单源永不充分）。**source A = typed PR
    lookup 的 GitHub merge metadata（`merged`、`merged_at`、`merge_commit_sha`
    ——已实测该字段可能事后变 null，`merged=true` 不变，不得单独依赖）；
    source B = protected main git history（`ls-remote origin refs/heads/main` +
    fetch 后 ancestry/subject/tree：candidate OID 须为 main ancestor 且 squash
    subject 携 `(#N)`）。判定：`merged=true` ∧（`merge_commit_sha` 非 null →
    该 OID 须 source B 可证；null → source B 须以 subject `(#N)` 唯一定位 merge
    commit），任一侧缺失/歧义 → `reconcileRequired`。**负例入 tests：branch 消
    失、时间流逝、Issue 声称 merged、CI 绿，均永不充分。**确认后才 release
    lease/advance cursor；crash restart fixtures 覆盖 acquire、PR create
    timeout、body update、heartbeat、review dispatch、merge observation 六窗口。
  - **Source pins:closed。**实现 base 与本 readiness merge tree 中下列 blob 须逐
    项相等，任一 drift 即停并重钉：`__init__` `7a6c5b9223c68f9d8aadd503fb38842346c710fc`、
    `__main__` `aa47dd45a29ac4531e4c38e3cbe84acaaf2b18a5`、`backends`
    `0efa3e8c74c7935f96742d4d9f1649cc91534dd2`、`transport`
    `55e17e3caf139522c189dc6284db6ae90272fad2`、`worker`
    `b9662c76a0948abb049d293b2b03948a8fb570a5`、`cursor`
    `0961ec62409644421dc8ed8eea68230e8fa93b5e`、`lease`
    `685fb3c3c8c8266c52816027c92b300ea7cd6732`、`identity`
    `d22e62946e3b5b836cbdcd9b48b57031172fe4b1`、`pr_envelope`
    `2c286c8da0fa8945d512115dfce9de5150db0831`、`minter`
    `4150401c5f875ac282d38d6f70eb4c0c35f97689`（不得动）、`agent-pr.yml`
    `a514d9e539964f9e1960acbe4ffaa696629571da`（forbidden witness，迁移属
    HLR-005）、`sdd-guard.yml` `c64135e1f9dc253a92640a30bbcad42b0afa86fa`
    （forbidden witness）。允许改动面：`scripts/host_loop/` 新文件（reviewer/
    recovery/tests）+ `worker.py`/`__main__.py` 的最小接线 +
    `test_discovery_contract.py` 的 stale 断言修复；`ALLOWED_ROUTES` 与
    `forbidden_capability_count()` 的 negative proof 必须继续为 0。
  - **Baseline honesty:audit base 上套件为 405 pass + 1 FAIL + 1
    expectedFailure。**该 FAIL = `test_discovery_contract.AgainstTheRealFile.
    test_hlr_003_reads_as_ready`——对真实 tasks.md 的时点断言（「当前在做的任务
    读作 ready」）被 #552 的合法 done 翻转打破；解析器行为正确（`--explain`
    读出 done、`done_task_ids` 83→84）。这是 TASK-HLR-003 done PR recheck 条款
    的设计漏洞（套件跑在翻转前的 flip base 上），如实入账。本 readiness 授权的
    source PR 必须修复之，且修复形态不得再次时点化：以对当前文件 Status 行的
    独立最小抽取对照 parser 输出，而非硬编码某任务的瞬时状态。
  - **Live-loop mutual-exclusion hazard:pinned。**两个 unit 处于 left-running，
    scheduler 每 900s 以 `--change CHG-2026-030-host-loop-runtime` 扫描本文件。
    本 readiness 生效后 TASK-HLR-004 = ready 且各门皆过、唯缺 `Decision-Grade`
    ——**在 TASK-HLR-004 done 之前，维护者不得为本 change 内任何任务补写
    `Decision-Grade` 行**（补写 D0 即把该任务交给活循环认领，与本 readiness 授
    权的 agent 会话形成双写竞态；D1/D2 亦会触发 gated 阻塞记录路径）。该约束是
    时机约束，不改变「grade 由维护者人工判断」本身；HLR-005 readiness 将统一
    编排补 grade 与 pilot 的顺序。
  - **Concurrency/absence:closed at drafting（2026-07-26）。**remote
    `agent/task-hlr-004*` 分支 = 0；分支名钉定：本 carrier =
    `agent/task-hlr-004-readiness-r1`、source = `agent/task-hlr-004-reviewer-loop`、
    done = `agent/task-hlr-004-done`。`agent/host-loop/**` refs = 0。
- Platform:macos（host-only）
- Requirements/AC:change-local `HLR-REVIEW-001`、`HLR-RECOVERY-001`
- Depends on:TASK-HLR-003 done、independent readiness
- In scope:独立 review adapter、immutable review request/result、reviewer scheduling、
  checks/review gate、batch handoff、protected-main/PR merge-OID reconciliation、crash
  restart tests与 evidence。
- Out of scope:GitHub review approval、auto-merge、维护者合并动作、D1/D2 批准、
  修改 batch digest/runbook canonical files、重跑/修改其他 change 的 evidence。
- Allowed paths:`scripts/host_loop/**`、本 change `evidence/**`、本 change
  `tasks.md`（仅本任务状态/evidence 引用）。
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、`openspec/governance/**`、
  `openspec/templates/batch-digest.md`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`、`.github/**`、产品 source/tests、其他 change。
- Risk:medium（review identity/merge result混淆可能绕过人工判断；所有歧义均暂停）。
- Hardware required:no。

### Deliverables

- reviewer run ID/worktree isolation、只读 adapter contract 与结果存档；
- 仅在 checks 全绿、independent pre-merge review `APPROVE`、digest 字段完整后才写入
  batch navigation 的 gating；
- restart 时对 GitHub merge metadata 与 protected-main full OID 双向核验，确认后才
  release lease/advance cursor 的实现与 fault fixtures。

### Verification

- `HLR-REVIEW-001`：同一 worker session 不能作为 reviewer；reviewer write/approve/
  merge 尝试均被拒或不具能力；`REQUEST_CHANGES`/`BLOCKED`/missing checks 不入队；
  `APPROVE` 记录明确不是 GitHub approval。
- `HLR-RECOVERY-001`：worker crash 在 acquire、PR create timeout、body update、
  heartbeat、review dispatch、merge observation 各窗口后重启；只有 exact merge OID
  同时见于 GitHub metadata 与 main history 才续跑。branch删除、时间超时、Issue 声称
  merged、CI green 均为负例；`check-sdd` 与 diff check 通过。

### Notes / handoff

- 真实 batch handoff 只引用 CHG-2026-027 已批准语义；若其 canonical runbook/digest
  尚不可用，记录 blocked，不自行补建权威载体；
- implementation/evidence 与 `ready→done` 状态 PR 分离。

## TASK-HLR-005 — 受控 live pilot 与恢复演练

- Status:ready（r1 pilot readiness；仅在维护者对本独立 readiness PR exact head
  review/merge 后生效。授权且仅授权：① 一次实现内容推送——TASK-TAS-001 的
  chg-037 r1 契约 diff，经 Deploy Key 推到 loop 创建的
  `agent/host-loop/tasks/TASK-TAS-001` 分支（一次性，diff 恰为该契约）；②
  foreground pilot 轮——与已合入代码同字节的
  `python3 -m host_loop --once --change CHG-2026-037-host-loop-transport-allowlist-shrink`
  重复执行至 checksGreen（人手替代 launchd 触发，unit 不参与也不可参与）；③
  reviewer 的**首次 live dispatch**——`SubprocessReviewerAdapter` 拉起独立
  `claude` 会话，结果 serialize 入 evidence，零 GitHub 写；④ merge 后 recovery
  驱动——`confirm_merged` 双源确认 + 过期 lease takeover/release（= 唯一授权的
  ref 删除写）+ 一次 exact-OID 不符负观测；⑤ 其后 evidence PR 与独立 done 状态
  PR。不授权：cursor Issue 创建或任何 Issue 写（Phase 4 剥离，见 r1 更正）、任何
  unit/plist/launchd/host 变更（r5 冻结续）、`agent-pr.yml`/`.github/**` 变更
  （legacy 迁移载体见 r1 钉定）、review/merge/auto-merge/admin route、以及
  **代任何任务撰写 `Decision-Grade`**（TAS-001 的 D0 行由维护者亲手落 main，
  载体自选，时点 = 本 readiness 合入后、S2 之前）。）
- Historical Status:blocked（pre-readiness r0 账目，2026-07-26：① change approval
  已闭；② TASK-HLR-003 done = #552 merge
  `24395db6b15d72781f142991aa06e765cbb695cb`；③ TASK-HLR-004 done = #555 merge
  `6bdad8bfef962b032c1a343650d6ec91cb73712a`（均 `lvye` APPROVED、
  `auto_merge=null`）；④ 独立 readiness 当时不可开：天然可派发任务经全仓扫描不
  存在。**该缺口已闭**：维护者 2026-07-26 决定推进 transport allowlist 收缩线
  （立项记录早于 pilot 触发的存在），CHG-2026-037 经 #557 propose、#558
  approval、#559 readiness（merge `1c6581b163ce64a0c91405a5bc98325f99d6aa50`）
  产出 TASK-TAS-001 = ready、host-only、依赖零缺、唯一拒因 grade unknown 的
  天然任务。）
- Readiness（r2；audit base = protected `main`
  `9bfbb72aa6a0120ace0fb8d2f178359c48b1b308`；**单点更正 r1 的 S1 载体条款，其余
  r1 条款原文有效**）：
  - **Why r2 exists:S1 载体条款经实测不可执行（2026-07-26）。**维护者按 r1 尝试
    「本地直接 push」被 live 拒绝（GH006：must be made through a pull request +
    required check `guard`）；随即 authenticated 读回 main protection 证实
    `required_approving_review_count=1` + `require_code_owner_reviews` +
    `enforce_admins`——GitHub 禁止 PR 作者自批，故**维护者本人 authored 的 PR 在
    现拓扑下永远无法满足 review 门**。r1 括注引用的「直接 push 先例」是
    CHG-2026-033 拓扑迁移（2026-07-24）之前的旧事实，起草失误，如实入账。
    附带正观测：该次误推走的是本 checkout 的 Deploy Key 别名，被 main 拒绝 =
    agent 写身份不可达 main 的又一次 live 负向探针，记入 pilot evidence。
  - **Corrected S1（取代 r1 同名步骤）**：维护者亲手 commit 该行（判断 =
    维护者、git authorship = 维护者，已实测存在：commit
    `e3270cb1a94db716b7a4bb12eaa058db34edf046`，恰 +1 行
    `- Decision-Grade:D0。`）→ **Agent 得将该 exact commit 原样传输**（零
    amend、零字节改动、commit OID 不变）至 `agent/task-tas-001-grade` 分支 →
    bot auto-PR（PR 作者 = `github-actions[bot]` ≠ 维护者，review 门可满足）→
    维护者对 exact head APPROVE + squash merge = 唯一批准载体。Agent 仍不得
    代写、不得修改该行内容；「判断/authorship/批准/合并恒为人，传输可为
    Agent」自此为本仓维护者自发变更的标准载体形态（拓扑事实：现保护下一切
    可合并 PR 必须非维护者 authored）。
  - **其余 r1 文本（对象 pins、S0/S2–S9、四义务、失败面、不授权清单）逐字
    有效，不重述。**
- Historical Readiness（r1；audit base = protected `main`
  `1c6581b163ce64a0c91405a5bc98325f99d6aa50`；S1 载体条款经 r2 更正）：
  - **Approval boundary:pending human merge。**本 carrier 只修改本文件
    TASK-HLR-005 section。只有 `lvye` 对 exact head APPROVED、required checks
    terminal success、`mergedBy=lvye`、`auto_merge=null` 且 squash subject 携
    `(#N)` 的 merge OID 进入 protected main 后，本 readiness 才生效；合入前
    pilot 零动作。
  - **两处更正（fail-closed 如实）**：① r0 曾写 Phase 4 播种 helper
    「`--render-cursor-seed` 留待 r1 授权的小 source PR」——本任务 Forbidden
    paths 含 `scripts/**`，该 helper 不可能在本任务内交付，r0 该句自相矛盾，
    删除；Phase 4（cursor Issue 创建/首次写/loop 挂接）整体**剥离出 pilot**，
    留待独立后续授权（五条 AC 的 live 最小面不需要 cursor；机器块人工播种的
    可行性已实测：`CursorState.render()` round-trip PASS，事实备查）。② r0 与
    TAS-001 r1 的「提前补 grade 即被 unit 提前认领」警示对 TAS-001 **不成立**：
    unit 的 `--change` 恒为本 change（r3 补偿控制），扫不到 chg-037；该警示仅对
    本 change 内任务有效。pilot 轮因此全部 foreground 显式带 `--change`，unit
    全程只跑空轮（其持续 idle 本身就是 left-running 稳定性的并行观测）。
  - **Pilot 对象:pinned。**TASK-TAS-001（CHG-2026-037，readiness #559 merge
    `1c6581b163ce64a0c91405a5bc98325f99d6aa50`）；其三 source blob pins 与实现
    契约（含「恰 3 pin 断言反应」门与 482 期望计数）以该 readiness 原文为准。
    identity = App `4388667` / installation `148855345`（TASK-HLR-002
    receipt）；expected checks = push 侧 `guard`+Swift、PR 侧 worker body-update
    触发 `edited` 后 exact-head `guard`+`allowed-paths` 全 success（
    `REQUIRED_PR_CHECKS` 语义）；reviewer session = `SubprocessReviewerAdapter`
    + `claude` backend（availability probe 于 S0 复跑）；batch Issue =
    `batch-20260726-1` 单项 digest（canonical 模板 blob `f5f82e34…`，维护者手
    建，正文由 Agent 以 `queue_for_batch`/`render_batch_issue` 渲染供贴）。
  - **编排（S0–S9，每步注明 actor；顺序固定，任一 STOP 即停）**：
    S0 preflight（Agent，只读）：`HEAD==origin/main`、TAS-001 三 blob 零漂移、
    `agent/host-loop/**` refs=0、task/lease 分支 absent、两 unit `print` 存活、
    App 身份 PR/Issue 基线、probe 复跑。
    S1 grade 行（**维护者亲手**）：向 chg-037 tasks.md TAS-001 section 落一行
    `- Decision-Grade:D0。`进 protected main（载体自选：本地直接 push 属
    push-allowlist 内先例，或自开 PR；Agent 不代写不代推）。
    S2 认领轮（Agent，foreground）：`--once --change CHG-2026-037-…` → 期望
    exit 0（dispatched）：lease `fence=1` 创建、空 envelope PR 开启（empty
    commit on frozen base，MECH-004 接受空 diff）。记录 PR number/head、
    push-side checks、reserved 分支 legacy creator run/PR = 0（coexistence 正
    观测之一）。
    S3 实现推送（Agent，授权①）：契约 diff 一个 commit 推上 task 分支，head
    前移。
    S4 接力轮（Agent，foreground，≥2 轮）：lease 未过期时先跑一轮 = **foreign-
    lease/stale-fence drill**（期望 exit 10 零写；fault drill 分支「stale
    fence 不创建第二 PR」的活观测）；过期后一轮 takeover（前置=PR identity 重
    查+exact OID）→ adopt 唯一 PR（零第二 PR）→ body-update 重派 checks →
    直至 `checksGreen`。
    S5 reviewer（Agent，授权③）：`ReviewerLoop.review_once` 实跑；结论如实
    （APPROVE 才入队；REQUEST_CHANGES/BLOCKED = workerPaused 如实记录并停）。
    S6 batch（**维护者**）：手建 `batch-20260726-1`，贴 Agent 渲染正文（首屏
    声明原样 + 单项 digest）。
    S7 merge（**维护者**）：对 exact head review + squash merge = 唯一批准载
    体。
    S8 recovery（Agent，授权④）：`confirm_merged` 双源（metadata × ancestry+
    subject）；**CAS 负观测** = 以 takeover 前旧 OID 尝试 lease 删除 → 必须
    Refused/FenceLost；随后正确 takeover 过期 lease → `release`（exact-OID 删
    lease ref）→ `ls-remote` 归零复验。
    S9 evidence PR（分支 `agent/task-hlr-005-pilot-evidence-r1`，已验 absent）
    → 独立 done 链（HLR-005 done、TAS-001 done、chg-037 verify 各自独立 PR）。
  - **r5 四义务逐项钉定**：① live first-PR proof = S2–S4（唯一有效 lease 创建
    带完整 envelope 的 task PR + 首个 `pull_request` event checks 实测）；②
    old creator coexistence = S2 的 reserved 零 legacy 观测 + 同期任一 ordinary
    `agent/*` 分支照常 bot auto-PR（本 carrier 自身即样本）；③ lease CAS live
    充分性（F4 闭）= pilot 全程 ≥3 种 CAS 操作（create/takeover/delete）各≥1
    次真实发生 + S8 的 exact-OID 不符负观测 ≥1 次；④ legacy 迁移 =
    **载体钉定为 live proof 达成后由维护者决定的独立治理 PR**（`agent-pr.yml`
    属本任务 Forbidden paths，Agent 不触碰）；HLR-005 done 条件 = ①②③ 齐备
    且 ④ 已执行**或**维护者显式决定推迟并记录于 done PR——二者其一，如实。
  - **失败面**：S2 非 exit 0、任何第二 PR、checks 非 green 稳定态、reviewer
    非 APPROVE、S8 双源歧义、任何 cursor/Issue 意外写、reserved 分支出现
    legacy creator——一律停在原地如实记录，evidence 记 blocked-attempt，不得
    以 cleanup 改写结论。
- Historical Status:blocked（前置：① 本 change approval；② TASK-HLR-003 done；③
  TASK-HLR-004 done；④ 独立 readiness PR 钉定一个天然出现的已批准 ready host-only
  task、integration identity receipt、预期 checks、reviewer session、batch Issue 与
  rollback/close plan。不得为了演练凭空制造产品任务。）
- Pre-readiness（r0；audit base = protected `main`
  `6bdad8bfef962b032c1a343650d6ec91cb73712a`；**纯账目与触发条件钉定，零授权**——
  本 carrier 不使任何东西 ready、不授权任何 source/host/live 动作）：
  - **Ready 触发清单（全部满足才可起草 readiness r1，缺一不起草）**：(a) 某已批准
    change 中天然出现一个 ready、host-only、依赖闭合、allowed-paths 齐备的 **D0**
    任务（其存在理由独立于本 pilot）；(b) 维护者显式确认以其为 pilot 对象并亲手
    为其补写 `Decision-Grade: D0` 行（时机 = readiness r1 合入后、pilot 窗口开启
    时——活循环每 900s 扫描，提前补写即提前认领）；(c) readiness r1 钉定 Status
    历史④ 全项：integration identity receipt（App `4388667`/installation
    `148855345`，TASK-HLR-002 receipt 为准）、预期 checks（`guard`+`allowed-paths`
    exact-head）、reviewer session 形态（TASK-HLR-004 已合入的 adapter 契约：
    `SubprocessReviewerAdapter` + `claude` backend，availability probe 复跑）、
    batch Issue（`batch-YYYYMMDD-N` 命名 + canonical 模板 blob）与 rollback/close
    plan（不合入的 fault drill 含 stale-lease 或 create-timeout 分支）；(d) r5 自
    TASK-HLR-003 转移的四义务逐项入 readiness（live first-PR proof、old creator
    coexistence live 观测、lease CAS/stale-fence live 充分性、legacy 迁移含「不得
    早于同 PR live proof」原文），见本节 Notes/handoff 转移条。
  - **Phase 4 播种机制：定形（实现留待 readiness r1 授权的小 source PR）。**首次
    cursor Issue 写**保持人类**：维护者创建 Issue 并手工粘贴由只读 helper 渲染的
    机器块（载体 = 既有 `CursorState.render()`；helper 形态 = `--render-cursor-seed`
    干跑 flag，零网络零凭据，同 `--explain` 边界）；`cursor.load` 对手贴块按既有
    parser 校验，loop 侧「配置了 Issue 但不可解析即拒绝且不代建」语义不变。这解除
    r3 记录的 Phase 4 三理由中的第②条（机制缺失），①（永久公开写）③（需可认领
    任务）由 readiness r1 连同 pilot 一并授权与满足。
  - **Decision-Grade 编排：**TASK-HLR-004 done 已解除其 r1 互斥 pin；但两 unit 仍
    left-running，`--explain` 会把任何 D0-ready 任务标为 claimable 并在 ≤900s 内
    被认领。故 grade 补写恒为「readiness r1 合入后、按其钉定的顺序逐任务进行」，
    在此之前不批量补写（含本 change 与其他 change）。
  - **候选路径备考（事实，非指令）**：transport allowlist 收缩（10 条中 2 条任何
    公开方法不可达 = 死能力）已独立立项待维护者决定；若维护者推进该治理线，其
    实现任务天然满足 (a)。
  - **Standing host 状态不变**：两 unit left-running（r5 冻结条款）；本 carrier 与
    未来 readiness r1 生效前，任何 unit/plist/token/PEM/minter 变更均无授权载体。
- Platform:macos（host-only live GitHub integration；零产品/硬件声明）
- Requirements/AC:change-local `HLR-ENVELOPE-001`、`HLR-LEASE-001`、
  `HLR-WORKER-001`、`HLR-REVIEW-001`、`HLR-RECOVERY-001`
- Depends on:TASK-HLR-003 done、TASK-HLR-004 done、independent readiness
- In scope:一个真实、自然出现的 host-only task PR 的完整 metadata/首个 PR checks/
  独立 review/batch handoff/维护者 merge 后 merge-OID recovery；一次不合入的
  stale-lease 或 PR-create-timeout recovery 演练；本 change evidence。
- Out of scope:自动合并、真实设备、伪造 check/review、把本 proposal 预先算作
  MECH-004 live evidence、任何其他 change 实现。
- Allowed paths:本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence
  引用）。
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、`openspec/governance/**`、
  `openspec/specs/**`、`openspec/contracts/**`、`openspec/changes/archive/**`、
  `.github/**`、`scripts/**`、产品 source/tests、其他 change。
- Risk:low-medium（真实 GitHub 写入；无 merge OID 或 reviewer 独立性即停止）。
- Hardware required:no。

### Deliverables

- 可复查的真实 task PR URL、首个 `pull_request` check runs、body envelope、独立 review
  result、batch Issue navigation、维护者 merge 的 full OID 和 restart reconciliation；
- 一次 close/cleanup 完整的不合入 fault drill，证明 stale fence 或 create timeout 不会
  创建第二 PR/推进 cursor；
- 若本 CHG proposal PR 的 actual `allowed-paths` run 已绿，可仅以 URL/run 追加到
  MECH-004 evidence 的候选清单，且由 MECH-004 owning task 的独立 scope PR 决定是否引用。

### Verification

- 六条 HLR acceptance 的 live evidence 与 negative/fault evidence 齐备；无 auto-merge、
  GitHub approval、状态自翻转、secret/absolute path/raw payload；`check-sdd`/diff check
  通过。任何事实不全则整项保持 blocked。

### Notes / handoff

- pilot 完成不自动使本 change `verified`；所有 HLR task done 与 evidence 完整后，
  仍须独立 verify PR。
- **自 TASK-HLR-003 r5（2026-07-26，维护者决定）转入的义务——本任务的 readiness
  必须逐项钉定，缺一不得 ready**：① live first-PR proof：唯一有效 lease 创建带
  完整 envelope 的 `agent/host-loop/tasks/**` task PR，并在首个 `pull_request`
  event 上看到 checks（与既有 In scope 的「首个 PR checks」为同一交付，此处使
  归属显式）；② old creator coexistence 的 live 观测；③ lease CAS/stale-fence
  的 live 充分性证明（HLR-003 r1 F4 的 open 义务：topology evidence 与 HLR-002
  的单次 stale-fence 均不构成充分证明）；④ legacy creator 迁移——`agent-pr.yml`
  的移除/禁用不得早于**同 PR** 的新 creator live proof，任何失败先停 scheduler
  并保留旧 workflow 或明确 rollback（HLR-003 Notes 原文约束逐字随移）。
