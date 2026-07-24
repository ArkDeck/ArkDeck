# CHG-2026-030 Tasks

> 本 change 的每个 task 均 host-only，零真实设备/HDC/effect dispatch。proposal PR
> 只含本 change package；批准、readiness、实现/evidence、done、verified 均为独立 PR。
> D2 host/credential 配置与源码 PR 分离；任何判断门未合入前不做门后的成 PR 工作。
> r3 新增 TASK-HLR-002A 划分 `agent/host-loop/**` exclusive creator namespace；
> 该 task done 前 HLR-002 不得 ready，零 identity/secret/scheduler/probe 动作。
> r4 因 #412 首个 pull-request `allowed-paths` 暴露 canonical suffix task grammar
> 不兼容而 fail closed；r4 只扩 HLR-002A 的 parser/test scope，不使其 ready。
> r6 因 #435 的全仓漂移/open-PR/绝对窗口模型产生无关阻塞而 fail closed；新增
> TASK-HLR-002B 先实现 scoped D2 gateway/lease。HLR-002A 回到 blocked，旧 r5
> executor 永久失效；新的 Agent D2 只能在维护者 standing authorization 与
> merge-relative window 内执行。

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

## TASK-HLR-002A — Legacy bootstrap namespace partition

- Status:blocked（r6 stop gate：#435 已批准的是 r5 exact-current-main、zero-open-PR
  与绝对窗口计划；它没有产生 D2 receipt/PASS，且被本 r6 revision supersede。
  解除前置：① r6 由维护者 review/merge；② TASK-HLR-002B done；③ 维护者创建并
  merge authorization-bearing r6 scoped D2 readiness，固定
  sensitive manifest、overlap classifier、relative window、lease key、gateway
  source/identity 与 fresh target refs。旧 r5 executor/UUID/window 不得补跑。）
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
- r6 remediation：
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
- Requirements/AC:change-local `HLR-LEASE-001`、`HLR-WORKER-001`、
  `HLR-D2-GATE-001`
- Depends on:change revision r6、TASK-HLR-001 done、TASK-BAP-003 done、
  TASK-HLR-002B done、maintainer-created authorization-bearing scoped D2 readiness
- In scope:`agent-pr.yml` push filter 保留 `agent/**` include、增加
  `!agent/host-loop/**` exclude；固定 task/lease/probe 三个 reserved family；
  branch-filter contract test；MECH-004 title/body/full task token 对齐现有 active
  task-header grammar，并覆盖单字母 suffix 正反 fixtures；Agent 在维护者已 merge 的
  finite standing authorization 下经 TASK-HLR-002B constrained gateway 将 ruleset
  target 从单层 Agent ref 精确扩展到多层 Agent ref，保留其他收权；sensitive-input
  drift/overlapping-PR/merge-relative-window/scoped-lease preflight；单层/多层正向与
  non-agent/main 负向 ref matrix；implementation merge 后的 fresh control/canary live
  evidence；本 change evidence 与本任务状态。
- Out of scope:修改 `sdd-guard.yml`；除本任务明确的 target-pattern additive delta 外
  创建 bypass、停用/删除 ruleset 或改变其他 repository permission；Agent 直接持有
  maintainer/admin credential、调用 generic API 或创建/修改/批准 standing
  authorization；创建/配置
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
  ruleset exclude 过宽会扩大 Deploy Key ref 写面，过窄会阻断 runtime。D2 exact
  read-back、正负 probes 与完整 rollback 缺一即 fail closed）。
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
- ruleset 保留 `~ALL`、creation/update/deletion 与 human-only bypass，target exclude
  同时覆盖 single-level `refs/heads/agent/**` 和 multi-level
  `refs/heads/agent/**/*`；Deploy Key 的单层/多层正向与 non-agent/main 负向矩阵
  全部通过；
- implementation 合入后 live canary：普通 control branch 仍由 legacy creator 创建唯一
  PR；reserved probe branch 的 head guard 出现但 legacy PR/workflow run 数为 0，canary
  清理不以 branch disappearance 代替查询结果。

### Verification

- `HLR-LEASE-001`/`HLR-WORKER-001` bootstrap slice：contract fixtures 全通过；
  control/canary 的 branch/head/full run/PR IDs 可复查；reserved branch 零
  `github-actions[bot]` PR，普通 control 恰一 legacy PR；
- ruleset before/after JSON/hash 与 active-rule evaluation 可复查，after 相对 before
  只追加一个 multi-level exclude；main/non-agent 负向前后 OID/ref 不变；
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

- Status:ready（本 D1 readiness 经维护者 review/merge 后生效；只授权下述纯离线
  source/contract implementation，不 provision credential、不创建 standing
  authorization、不执行 ruleset/ref/PR/Issue write。）
- Platform:macos（host control plane；零产品/设备平台声明）
- Requirements/AC:change-local `HLR-D2-GATE-001`、`HLR-LEASE-001`、
  `HLR-RECOVERY-001`
- Depends on:change revision r6、TASK-HLR-001 done、TASK-BAP-003 done、
  independent readiness
- In scope:canonical sensitive-input manifest builder/validator；完整 open-PR/files
  pagination 与 overlap classifier；GitHub `merged_at` relative-window validator；
  durable CAS scoped lease；standing-authorization parser/validator/revocation/use
  accounting；仅暴露
  `executeAuthorizedRulesetDelta(canonicalRequest)` 的 constrained gateway；
  authenticated before/one-shot mutation/immediate read-back/rollback 状态机；
  immutable redacted receipt；pure fixture、fault、route-inventory tests 与本任务
  evidence/status。
- Out of scope:创建/修改/批准/撤销真实 standing authorization；向 Agent 暴露 raw
  credential；provision secret/keychain/launchd；真实 ruleset/ref/PR/Issue write；
  generic REST/GraphQL、任意 method/URL/body、branch protection、review/merge、
  arbitrary ref mutation；修改既有 workflow/parser、Core/governance 或产品代码。
- Allowed paths:`scripts/host_loop/d2_gateway/**`、本 change `evidence/**`、本 change
  `tasks.md`（仅本任务状态/evidence 引用）。
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/**`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`、`.github/**`、`scripts/check_pr_paths.py`、
  `scripts/test_check_pr_paths.py`、`scripts/test_agent_pr_workflow.py`、产品
  source/tests、其他 change。
- Risk:high（gateway/lease/auth parser 缺陷可能扩大仓库管理权限或重复执行；任何
  ambiguity、fence mismatch、clock discontinuity、unknown outcome 均 fail closed）。
- Hardware required:no。
- Readiness（r1，audit base = protected `main`
  `e8eaef86acc13ef76270e29f7a63873d0b2fa6cb`）：
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
      commit: e8eaef86acc13ef76270e29f7a63873d0b2fa6cb
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

    `scripts/host_loop/d2_gateway/**` 在 audit base 全部 absent。截至
    `2026-07-24T03:26:14Z`，GitHub all-open PR = 0；readiness branch
    `agent/chg-2026-030-hlr-002b-readiness` 与固定 implementation branch
    `agent/task-hlr-002b-scoped-d2-gateway` 的 remote ref/all-state exact-head PR
    均为 0。implementation 前只重新阻断真实 overlap，不因无关 PR 或无关 main
    commit 停止。
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

- Status:blocked（r6 stop gate：#421 已证明 multi-level reserved ref 被 active ruleset
  拒绝，故在 TASK-HLR-002A remediation done 前无法形成新 identity create-PR 正例。
  解除前置：① CHG-2026-030 revision r6 经维护者 review/merge；② TASK-BAP-003 done；
  ③ TASK-HLR-002A done；④ 独立 D2 readiness/维护者窗口钉定实际 integration
  identity、单仓 scope、最小 categories、非 CODEOWNER/bypass 事实、secret storage、
  scheduler owner/label reservation、rollback contact 与正/负 probe。Agent 不得代为
  创建、修改或批准仓外 D2 配置。r2 历史 finding：2026-07-23 勘察确认 GitHub
  `Pull requests:write` 同时覆盖 PR create/review，`Contents:write` 同时覆盖
  `agent/**` ref/merge endpoint；r1 的正向能力与“零 review/merge API permission”
  无法同时由 permission manifest 证明。）
- Platform:macos（受控 host 运维；零产品平台声明）
- Requirements/AC:change-local `HLR-LEASE-001`
- Depends on:change revision r6、TASK-BAP-003 done、TASK-HLR-002A done、
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

- Status:blocked（前置：① change revision r3 approval；② TASK-HLR-001 done；
  ③ TASK-HLR-002A done；④ TASK-HLR-002 done；⑤ 独立 readiness PR 钉定
  `agent-pr.yml`、MECH-004 parser、identity/staging receipt、scheduler activation
  plan 与 runtime blobs，并确认 reserved namespace 零 creator conflict。）
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

- Status:blocked（前置：① 本 change approval；② TASK-HLR-003 done；③ 独立
  readiness PR 钉定 reviewer adapter interface、failure matrix、batch Issue schema 和
  merge-OID sources；④ 不产生 PR 的 reviewer backend availability probe。）
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

- Status:blocked（前置：① 本 change approval；② TASK-HLR-003 done；③ TASK-HLR-004
  done；④ 独立 readiness PR 钉定一个天然出现的已批准 ready host-only task、
  integration identity receipt、预期 checks、reviewer session、batch Issue 与
  rollback/close plan。不得为了演练凭空制造产品任务。）
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
