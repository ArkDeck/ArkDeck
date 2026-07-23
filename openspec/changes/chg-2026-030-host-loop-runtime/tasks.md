# CHG-2026-030 Tasks

> 本 change 的每个 task 均 host-only，零真实设备/HDC/effect dispatch。proposal PR
> 只含本 change package；批准、readiness、实现/evidence、done、verified 均为独立 PR。
> D2 host/credential 配置与源码 PR 分离；任何判断门未合入前不做门后的成 PR 工作。

## TASK-HLR-001 — 结构化 PR envelope 与纯 runtime contract

- Status:ready（2026-07-23 D1 readiness r3；r2 #390 的 GitHub PR base 虽为
  `00bbc5a2c7888e628997537a5ca859b46d772215`，但实际 merge
  `2782f47f98c7fca95996a02560e1a2be31525dc5` 的 first parent 已前进为
  `d53da289b7da80a4ee2282f5dea3122ebf97325a`，不满足 r2 自身“merge parent
  恰为 audit base”的二值门，因此 fail closed，未开始实现。本 r3 仅在维护者
  review/merge 本独立 re-pin PR 后生效。三前置仍闭合：① CHG-2026-030
  approval #361；② 本 readiness 重新钉定 envelope v1 grammar、runtime/template
  inputs、测试矩阵与当前 protected `main` 基线；③ TASK-BAP-003 done #376。
  r3 merge 前不得创建 implementation/evidence PR。）
- Historical Status:r2 `ready`（#390；因上述 exact-parent mismatch 被本 r3
  supersede，零 implementation/evidence 可复用）。
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

- implementation/evidence PR 不翻 `ready→done`；done 使用独立 D0 状态 PR；
- readiness 若发现 templates 或 current `MECH-004` grammar 冲突，停止并提议 scope
  revision，不在本 task 改 canonical governance。

## TASK-HLR-002 — D2 integration identity 与 host activation

- Status:blocked（前置：① 本 change approval；② TASK-BAP-003 done；③ 独立 D2
  readiness/维护者窗口，钉定实际 integration identity、权限面、secret storage、host
  scheduler owner、rollback contact 与正/负 probe。Agent 不得代为创建、修改或批准。）
- Platform:macos（受控 host 运维；零产品平台声明）
- Requirements/AC:change-local `HLR-LEASE-001`
- Depends on:change approval、TASK-BAP-003 done、independent D2 readiness
- In scope:维护者建立非 `GITHUB_TOKEN` integration identity、受限 `agent/**` lease
  ref 权限、PR/Issue 最小写权限、host scheduler registration 与脱敏正/负 probe；本
  change evidence 与本任务状态。
- Out of scope:main bypass、merge 或 GitHub approval 权限、Actions/branch protection
  admin、token/key 入仓、runtime 源码、旧 `agent-pr` workflow 迁移。
- Allowed paths:本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/evidence
  引用）。
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、`openspec/governance/**`、
  `openspec/specs/**`、`openspec/contracts/**`、`openspec/changes/archive/**`、
  `.github/**`、`scripts/**`、产品 source/tests。
- Risk:medium（凭据或 scheduler 配错可能扩大权限或造成停摆；默认 fail closed）。
- Hardware required:no。

### Deliverables

- 维护者执行的 D2 evidence：identity 类型/权限类别（不含值）、host owner、secret
  storage 类别、lease ref 正向操作、main/bypass/merge/review-approval 负向拒绝、撤销与
  rollback 方法；
- runtime 启动前可查询的 host activation receipt，仅含脱敏 IDs 与时间。

### Verification

- `HLR-LEASE-001` D2 document/integration review：非 `GITHUB_TOKEN` identity 能创建
  受限 probe PR/Issue 与 `agent/**` lease ref；直写 main、merge、GitHub approval 和
  admin 操作均被拒；token/private key/绝对用户路径为零；`check-sdd`/diff check 通过。

### Notes / handoff

- 维护者须亲自执行并确认 D2 动作；runtime/Agent 只能读取事实性 receipt；
- 未形成可复查 receipt 时，HLR-003/004/005 一律保持 blocked。

## TASK-HLR-003 — Fenced worker loop 与 legacy PR creator 迁移

- Status:blocked（前置：① 本 change approval；② TASK-HLR-001 done；③ TASK-HLR-002
  done；④ 独立 readiness PR 钉定 `agent-pr.yml`、MECH-004 parser 与 runtime blobs，
  并确认零 open creator migration conflict。）
- Platform:macos（host-only）
- Requirements/AC:change-local `HLR-LEASE-001`、`HLR-WORKER-001`
- Depends on:TASK-HLR-001 done、TASK-HLR-002 done、independent readiness
- In scope:worker `--once` loop、Issue cursor rebuild、remote fenced lease、heartbeat、
  deterministic PR lookup/create/update、existing `agent-pr` bootstrap 的原子迁移、
  unit/fault tests、live worker evidence。
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
- migration 仅在新 integration identity 成功的 live probe 后关闭 legacy creator，且
  rollback 记录不把 branch disappearance 解释成 merge。

### Verification

- `HLR-LEASE-001`/`HLR-WORKER-001` contract + live integration：双 worker acquire、
  stale-fence write、heartbeat loss、create timeout、Issue corruption、0/2 PR lookup、
  old creator coexistence 分别 fail closed；唯一有效 lease 能创建带完整 envelope 的
  task PR，并在首个 `pull_request` event 上看到 checks；`MECH-004` allowed-paths、
  `check-sdd`、diff check 均绿。

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

- 五条 HLR acceptance 的 live evidence 与 negative/fault evidence 齐备；无 auto-merge、
  GitHub approval、状态自翻转、secret/absolute path/raw payload；`check-sdd`/diff check
  通过。任何事实不全则整项保持 blocked。

### Notes / handoff

- pilot 完成不自动使本 change `verified`；所有 HLR task done 与 evidence 完整后，
  仍须独立 verify PR。
