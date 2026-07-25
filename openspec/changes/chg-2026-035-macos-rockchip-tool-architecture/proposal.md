---
id: CHG-2026-035-macos-rockchip-tool-architecture
revision: 1
status: verified # 本 2026-07-25 verification-closure PR 经维护者 review/merge 后生效；完整 OID 链见 Verification closure；archive 另行
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# macOS Rockchip 工具执行架构决策

## Why

CHG-2026-026 `TASK-RKFUI-001G` 已在 exact v1 六 entitlement 的 signed Sandbox
product shape 下执行 Stage A。系统文件选择器返回的条目未通过 canonical regular-file
gate，run 以 `selectedEntryNotRegularFile` fail closed；security scope、bookmark、
hash、Process、Stage B、真实工具、USB 与设备 dispatch 均为 0。该 blocked run 已由
PR #525 合入 protected `main`，receipt SHA-256 为
`240503c81b9f5a7f9d3e7e4fbb6be806f1417992d7fa52bcc3dd47af1b6d5d8e`。

001G r9 明确禁止在原任务内继续 retry、Stage B、symlink/alias fallback、entitlement
扩集、copy/bundle/helper 或真实工具/设备尝试；下一技术方向必须由独立 ADR/change
决定。当前 ADR-0002 同时固定 Sandboxed 单一 DMG、精确六 entitlement 与外部优先工具
模型，但它没有基于 001G 的新事实决定 Rockchip `rkdeveloptool` 应由 App 直接启动、
捆绑、经 broker/helper 运行，还是退化为 plan-only 人工交接。

在继续产品实现前，需要一个封闭、可复查且无执行副作用的架构判断门，避免把某个
probe workaround 偷渡成 v1 产品架构。

## What changes

### In scope

- 对下列五类完整 end-state 候选进行同一张证据矩阵评估，不把低层 workaround 当作
  独立候选：
  1. 保持 Sandboxed 分发与用户选定外部 `rkdeveloptool`，但重新设计选择、持久访问与
     child-launch 边界；
  2. 在 ArkDeck App bundle 内捆绑并签名/公证经过固定来源审核的
     `rkdeveloptool` component；
  3. 使用 sandboxed XPC service、独立 broker/login item 或 helper 承载受控工具执行；
  4. App 只生成 typed plan/Artifact，由用户在 App sandbox 外人工执行并回传结果；
  5. 重开 DEC-004/ADR-0002，采用非 Sandbox 或其他分发形态。
- 对每个候选逐项记录：与 Core/现行产品范围的兼容性、最小权限、production
  composition/authority/effect 边界、工具与依赖供应链、签名/公证/更新、输入文件访问、
  fixed argv/no-shell、取消/崩溃/recovery、诊断/隐私、测试与 clean-host evidence、
  Windows/Linux 后续端口以及 rollback。
- 形成一个维护者可判断的 ADR 结论：选择一个完整架构，或明确判定当前候选均不可行并
  指出必须重开的产品/Core 决策。结论同步到 macOS profile 与 decision inventory，
  并给出后续 change 的封闭 handoff。
- 保持 001G blocked evidence 原样；架构评估只读取已合入事实和权威的一手平台/供应链
  文档。

### Out of scope

- 不重试 001G，不构建或运行新的 probe/fixture/Stage B，不调用真实
  `rkdeveloptool`/HDC，不访问 USB/设备，不执行 E1/E2 或 destructive step。
- 不实现任何候选，不修改 App、Swift package、entitlement、Xcode project、打包、
  updater、helper/XPC、installer、系统配置或真实用户文件。
- 不把 symlink/alias、复制外部 binary 到 container、动态下载、自行去除 quarantine、
  重签未知工具、PATH 搜索或 shell command 当作隐式 fallback。
- 不重开或改变 HDC 的 external-first/bundling 决策；本 change 只处理 Rockchip
  `rkdeveloptool` 执行边界。
- 不修改 Core Requirement/AC、locked contract/schema、hardware support matrix 或
  CHG-2026-026 的任务状态。任何候选若需要这些变化，必须在结论中标记为后续独立
  change/decision 前置。

### Observable behavior before/after

- Before：001G 已如实 blocked，Rockchip 外部工具在 v1 Sandboxed product shape 下没有
  可继续实现的 approved execution architecture。
- After：仓库有一个经维护者选择的 Rockchip 工具执行 ADR 与精确后续 handoff，或者
  有一个“当前无可行候选”的明确阻塞结论；仍然没有新的产品实现、工具 launch、设备
  支持或发布声明。

## Scope(涉及的 Requirement/AC)

- Requirements：`REQ-FLASH-001`、`REQ-FLASH-004`、`REQ-FLASH-005`、
  `REQ-FLASH-015`、`REQ-JOB-005`、`REQ-UX-007`
- Canonical Acceptance：`AC-FLASH-001-01`、`AC-FLASH-005-01`、
  `AC-FLASH-015-01`、`AC-JOB-005-01`、`AC-UX-007-01`
- Change-local Acceptance：`RKTA-OPTIONS-001`、`RKTA-DECISION-001`、
  `RKTA-BOUNDARY-001`、`RKTA-HANDOFF-001`
- Contracts/schemas：零修改
- 是否需要 Core baseline bump：否；`spec-impact.md` 记录 no-op delta

## Safety, privacy, and compatibility

- 本 change 的任务仅为 document review。外部进程、USB、设备、网络、权限、安装、
  helper、用户文件与 destructive dispatch 必须全部为 0。
- 候选矩阵必须把“用户选择文件”与“允许执行该文件”、App 可访问输入与 child 可访问
  输入、工具 identity 与运行结果分别处理；任一未知不得用推断补齐。
- 任何 bundled component 必须单独闭合 upstream commit、reproducible artifact、
  license/notice、依赖、SBOM、架构、签名、公证、更新与漏洞响应；不能因位于 App
  bundle 内就自证可信。
- 任何 broker/helper 候选必须区分 sandbox-inherited XPC、普通 login item 与 privileged
  helper，记录 IPC 调用方认证、least privilege、安装/升级/移除、crash/recovery 与
  audit 边界；不得把 root/helper 视为默认答案。
- 任何 plan-only/handoff 候选必须如实说明它是否仍满足 v1 用户可观察能力；不满足时
  必须要求独立 capability/Core change，不能在 platform ADR 中降低要求。
- ADR/decision/profile 三处若不能保持一致，或结论需要未批准的 Core/entitlement/
  distribution 变化，任务保持 blocked。rollback 是撤回尚未实现的决策文本；现有
  001G evidence 与产品代码不改写。

## Approval and flow

本 proposal PR 只登记 change package，零架构选择、零 ADR/profile/decision 修改、零
execution evidence、零状态翻转。正式批准必须由独立 approval-only PR 完成；
`TASK-RKTA-001` 保持 `blocked`，批准后仍须独立 D1 readiness 固定事实源、评估版本、
allowed paths 与验证命令。架构判断/evidence 和后续 `ready → done` 分别使用独立 PR。

proposal 或 approval merge 均不授权任何候选实现。只有架构任务 done 且 decision
carrier 合入后，才能另立或修订后续 implementation change；CHG-2026-026 不因本 change
自动恢复。

## Approval

- r1 proposal 已由 PR #526 登记：exact head
  `15755c9e467ead1b99cf46f502b90aa6b003c362` 经维护者 `lvye` APPROVED，并以 merge
  OID `4bee496d9b33f271fe4d80bb93690befdf5ff30f` 合入 protected `main`。该 merge
  只登记 `status: proposed` 的 change package，不构成正式批准、task readiness 或
  架构选择。
- 正式批准由本 approval-only PR 将 `status: proposed → approved`，并仅在维护者对
  exact head review/merge 后生效。批准范围封闭为一个 host-only document-review
  task、四条 change-local AC，以及对 selected external、bundled Rockchip component、
  XPC/broker/helper、plan-only handoff 与 distribution revisit 五类完整 end-state 的
  source-pinned 同矩阵评估。
- 批准同时接受 `design.md` 的 frozen-facts、candidate-envelope、binary-decision、
  authority/effect mapping 与 no-workaround 边界，以及 `spec-impact.md` 的零 Core、
  零 HDC external-first、零 CHG-2026-026 变化结论。最终 carrier 必须选择一个完整
  end-state 或明确 no-viable；任何 Core/entitlement/distribution/contract 变化只可
  成为后续独立 change gate。
- 本批准不选择或推荐任何候选，不创建 ADR-0003，不授权 001G retry、probe/fixture、
  App/tool launch、网络/USB/设备、helper/install/privilege、E1/E2/destructive 操作，
  也不修改 product source、spec/contract、profile、decision inventory、evidence 或
  task 状态。`TASK-RKTA-001` 保持 `blocked`，必须另走 independent D1 readiness；
  本 PR 零 code、test、evidence 和 platform support 变化。

## Verification closure（2026-07-25）

本 verification-closure PR 只翻 change/verification 状态并引用 protected `main`
上的既有证据，零实现、零新 scope、零新风险接受与零新授权；整体结论仅在维护者
对本 PR 的 exact head review/merge 后生效。

- **批准与任务链：closed。**r1 proposal #526 exact reviewed head
  `15755c9e467ead1b99cf46f502b90aa6b003c362` 以
  `4bee496d9b33f271fe4d80bb93690befdf5ff30f` 登记；approval-only #527 head
  `4e801d764b204ce258644107db800b06dd55bc13` 以
  `c74fa46a810f6713b987c639ce23246ddf24a307` 合入；D1 readiness #528 head
  `651b75290c733df213f5aea905836a0e38c262b1` 以
  `8f035b5eb64c731f5c1a19affd06e58c93a17d5b` 合入；decision/evidence #530
  head `91a9cc3fa29303d78e1079b0e7f1f4210f51cd46` 以
  `94704827e541cc13c34da9395f5d9810b78cca17` 合入；D0 done #532 head
  `692e3e93ac340f585fb3de9e2a9aef958e9cd07b` 以
  `d80027c5c766803b867cecdba7f558f7895da28c` 合入。五个 exact head 均由
  CODEOWNER `lvye` APPROVED，merge OID 构成 protected-main ancestry。
- **任务与 evidence：PASS。**`TASK-RKTA-001` 在 #532 后为 `done`。
  #530 的 merged run/matrix blob 分别为
  `49d2688b0cba20b0f4d142d63d3ba46a3739313d` /
  `7af58939d359aca7b1626c18070c676b16c5f04b`，ADR-0003 blob 为
  `5fc4a1519325002e32bd445355667032d8b34c02`；accepted outcome 为
  `selected:bundledRockchipComponent`。
- **Acceptance：PASS（`documentReview`）。**`RKTA-OPTIONS-001` 由完整五类
  candidate、四个 helper subrow 与 234 个 controlled-verdict cells 证明；
  `RKTA-DECISION-001` 由 ADR-0003、DEC-011、macOS profile、design、matrix 与 run
  的唯一 outcome 一致性证明；`RKTA-BOUNDARY-001` 由 App root → authority mint →
  bundle-owned component → fixed typed command/file leases → effect/durable outcome
  trace 证明；`RKTA-HANDOFF-001` 由七项 pre-implementation gate 与 fail-closed
  rollback/revalidation 证明。五条适用 canonical AC
  `AC-FLASH-001-01`、`AC-FLASH-005-01`、`AC-FLASH-015-01`、
  `AC-JOB-005-01`、`AC-UX-007-01` 的 scoped document-review verdict 也均在
  merged `run.md` 中为 PASS。
- **确定性复验：PASS。**audit base =
  `d80027c5c766803b867cecdba7f558f7895da28c`；五个 merge OID 均为其 ancestor；
  #530 exactly 八个 task-allowed decision/evidence path，#532 exactly 一个
  `tasks.md` path；ADR/DEC/profile/design/tasks/verification/matrix/run outcome
  一致；readiness 后 `openspec/specs/**`、`openspec/contracts/**`、Rockchip
  registry 与 CHG-2026-026 零变化。verification branch 上
  `scripts/check-sdd.sh` = 0 error / 0 warning / 111 acceptance IDs，
  `python3 scripts/test_check_pr_paths.py` = 24/24，`git diff --check` 通过。
- **边界：unchanged。**本 verified 只确认 architecture document-review change；
  不证明 bundled component 已实现、可分发、可访问 USB/RockUSB 或可刷设备，不形成
  macOS platform/hardware conformance claim，也不修改 CHG-2026-026。产品实现必须
  另立 approved change 并逐项关闭 ADR-0003 handoff；archive 使用后续独立 PR。
