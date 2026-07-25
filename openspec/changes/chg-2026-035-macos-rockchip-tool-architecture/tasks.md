# CHG-2026-035 Tasks

> r1 proposal PR 只登记 change package。它不批准任何候选、不创建 ADR、不修改
> platform/decision inventory，也不产生 execution evidence。正式 approval、D1
> readiness、decision/evidence 与 `ready → done` 分别使用独立 PR。

## TASK-RKTA-001 — 评估并决定 macOS Rockchip 工具执行架构

- Status:done（2026-07-25 D0 completion；仅在维护者 review/merge 本独立
  `ready → done` PR 后生效。decision/evidence #530 exact reviewed head
  `91a9cc3fa29303d78e1079b0e7f1f4210f51cd46` 已由 `lvye` APPROVED，并以
  `94704827e541cc13c34da9395f5d9810b78cca17` 合入 protected `main`；
  `open-pr`、`guard`、`swift` 与 final `allowed-paths` checks 均 SUCCESS。
  accepted outcome = `selected:bundledRockchipComponent`，run/matrix blob 分别为
  `49d2688b0cba20b0f4d142d63d3ba46a3739313d` /
  `7af58939d359aca7b1626c18070c676b16c5f04b`。本 done 只闭合 host-side
  `documentReview` architecture selection；不构成 change `verified`、产品实现、
  App/tool/helper/USB/device effect 或 CHG-2026-026 revision/readiness 授权。）
- Historical Status:ready（r1 D1 readiness #528 exact reviewed head
  `651b75290c733df213f5aea905836a0e38c262b1` 已由 `lvye` APPROVED，并以
  `8f035b5eb64c731f5c1a19affd06e58c93a17d5b` 合入 protected `main`。该状态只授权
  decision/evidence document review，不预先接受候选或形成 done。）
- Historical Status:blocked（r1 proposal #526 与 approval-only #527 已依次合入；
  两者均未选择架构或自动产生 readiness。）
- Accepted decision/evidence（PR #530 已由维护者 review/merge；本独立 D0 PR 只记录
  其确定性结果）：outcome =
  `selected:bundledRockchipComponent`。ADR-0003/DEC-011/macOS profile 与
  `evidence/runs/TASK-RKTA-001/candidate-matrix.md`、`run.md` 同步选择 App-owned
  source-pinned Rockchip nested component 的 direct child route；无 XPC/broker/
  login item/LaunchAgent/LaunchDaemon/privileged helper/external fallback/distribution
  reopen。后续实现必须另立 approved change，先关闭 GPL-2.0、dependency/SBOM、
  reproducible artifact、nested signing/notarization、file/USB E0、clean-host 与
  CHG-2026-026 revision/readiness gates。当前 product/process/USB/device effect 和
  CHG-2026-026 状态变化均为 0。
- Readiness review:
  - **Approval/dependency gate:satisfied。**001G blocked evidence #525 exact head
    `9fed8772def1fb1f4743ddb0c37277805c36ba84` 经 `lvye` APPROVED，并以
    `2b15a53986054f0984a71a0f113a5a2b807c3914` 合入 protected `main`；CHG-2026-035
    proposal #526 exact head `15755c9e467ead1b99cf46f502b90aa6b003c362` 经同一维护者
    APPROVED，并以 `4bee496d9b33f271fe4d80bb93690befdf5ff30f` 登记；approval-only
    #527 exact head `4e801d764b204ce258644107db800b06dd55bc13` 经同一维护者 APPROVED，
    并以 `c74fa46a810f6713b987c639ce23246ddf24a307` 合入。三条 merge OID 在当前
    `main` 上形成连续 ancestry；proposal/approval 均不替代本 D1。
  - **Audit base/input pins:closed。**readiness audit base =
    `c74fa46a810f6713b987c639ce23246ddf24a307`。以下 Git objects 均从该 base
    实测；`tasks.md` 为本 PR 自载体，其 blob 只表示修改前输入。decision/evidence
    开工时必须基于本 readiness 的 merged OID，确认 approval merge 为 ancestor，并
    逐项重核所有非自载体 pin；`tasks.md` 改核 readiness merge 中 reviewed 内容。
    若 main 在 merge 前后由无重叠 PR 前进，不单凭 whole-main OID 失效；但任一 pinned
    blob、一手来源语义、ADR/DEC/evidence absence 或 allowed-path ownership 漂移，
    必须回到 `blocked` 并 fresh readiness：

    ```yaml pins
    - artifact: TASK-RKTA-001 readiness audit base
      commit: c74fa46a810f6713b987c639ce23246ddf24a307
    - artifact: CHG-2026-035 proposal merge
      commit: 4bee496d9b33f271fe4d80bb93690befdf5ff30f
    - artifact: CHG-2026-035 approval merge
      commit: c74fa46a810f6713b987c639ce23246ddf24a307
    - artifact: TASK-RKFUI-001G blocked evidence merge
      commit: 2b15a53986054f0984a71a0f113a5a2b807c3914
    - path: openspec/changes/chg-2026-035-macos-rockchip-tool-architecture/proposal.md
      blob: 69d598e5336f645e5b95dde26f942289e17935a8
    - path: openspec/changes/chg-2026-035-macos-rockchip-tool-architecture/design.md
      blob: a7c05328b4f569533a71492100f6cbbc83f06a12
    - path: openspec/changes/chg-2026-035-macos-rockchip-tool-architecture/tasks.md
      blob: 51b48e0d4424a8a7715de5664e15532118fe90a3
    - path: openspec/changes/chg-2026-035-macos-rockchip-tool-architecture/verification.md
      blob: 87a8c14b95037d0ff8bb79be66d470fd82b74d92
    - path: openspec/changes/chg-2026-035-macos-rockchip-tool-architecture/acceptance-cases.yaml
      blob: c9877970490155c9b0f43b5afc277d984f549e09
    - path: openspec/changes/chg-2026-035-macos-rockchip-tool-architecture/spec-impact.md
      blob: 3520700a753a466f1cff8a03bd8e99af7fdb93c5
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/proposal.md
      blob: 7392e120dcdcdd8e0e7d3b4ef90b201501551f1b
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/design.md
      blob: e97889463f86ab103aaa921faf209761ab31d0d6
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/tasks.md
      blob: e83bcfea555fda6c8b6309ed16bf5f6e33fa40a0
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/verification.md
      blob: d90b29c0d7ce9091fe6737ffe5bea450fad612a4
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001G/run.md
      blob: 3e895a3391b8174f3d814f54c386f3f577c5091d
    - path: openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001G/blocked-stage-a-selector-2026-07-25.json
      blob: 14e0790553d4be620a1216b6188bc4a87b003cd0
    - path: docs/adr/0002-macos-v1-sandboxed-distribution.md
      blob: 5111bb8c8657d0ed05e0184fbbaeb88af5fc5d8f
    - path: openspec/planning/open-questions.md
      blob: 9c3d39809a697a09b136bfe35f4e4be476f35e8f
    - path: openspec/platforms/macos/profile.md
      blob: a9a5931ffedd304a7ce3a088f4397c26fd87e744
    - path: ArkDeckApp/ArkDeckApp.entitlements
      blob: 6435d00f8493ce4fbca24a806ca7f320db9fbfa6
    - path: openspec/integrations/rockchip/profile.md
      blob: 706e94f0e3704ed76809cce1c42002faa3d14d9c
    - path: openspec/integrations/rockchip/rockusb-discovery/1.0.0/registry.yaml
      blob: 394e2a8c588c531208cd3154a1dc8638ad77010e
    - path: openspec/specs/flashing/spec.md
      blob: c914d587bf4893a3f4a9f776a28c74e7ef002c8e
    - path: openspec/specs/workflow-journal-recovery/spec.md
      blob: f97c64785533f832d6798a63e8c7c96080bb7b69
    - path: openspec/specs/desktop-ux-observability/spec.md
      blob: 8f7613a4443605fcdac2aec0346b925948fcae09
    - path: openspec/contracts/provider-contracts.md
      blob: ceb6709fb405fc46d72ef2126b715e252ac720ab
    - path: openspec/contracts/workflow-step-registry.yaml
      blob: d9121ef78531560ab856dfa07468ce1ab4d42df6
    - path: openspec/planning/agent-failure-patterns.md
      blob: ed539ff8436bccda1d8bb8a3b85a0f6e494fea81
    ```

    `docs/adr/0003-macos-rockchip-tool-execution.md`、DEC-011 与
    `evidence/runs/TASK-RKTA-001/` 在 audit base 均不存在，只允许本任务创建；
    不得覆盖并发 owner 或复用未合入草稿。
  - **001G trigger gate:closed。**合入版 sanitized receipt SHA-256 =
    `240503c81b9f5a7f9d3e7e4fbb6be806f1417992d7fa52bcc3dd47af1b6d5d8e`。
    唯一可用结论是：exact six-entitlement Stage A 在
    `selectedEntryNotRegularFile` 停止；security-scope/bookmark/hash/signature/
    quarantine/Process 与 Stage B 均未到达，selected fixture/real tool/HDC/USB/device/
    network/helper/privilege/mutation dispatch 均为 0；candidate 对
    `bookmarkCreated` 的 pre-bookmark 自报错误已由 sanitizer 修正。不得从该 run
    推断 child launch 可行/不可行、USB 可达或任何 workaround 成功；candidate source
    已移除，禁止重建、重跑或借本 task 延伸 001G。
  - **Apple primary-source dossier:closed for review。**2026-07-25
    （retrieval UTC `2026-07-25T06:23:43Z`）只读复核并冻结以下官方资料集合；decision
    run 必须重新记录 page title、retrieval time 与支持每个 matrix cell 的简短 paraphrase，
    不保存长引文。页面不存在、语义改变或需要集合外平台事实时，任务立即 blocked 并
    先修订 readiness：
    - `https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox`
      固定 user-selected file access、persistent bookmark、cross-process bookmark
      sharing 与 executable-location 限制是彼此独立的判断，不得把 file access 推断成
      任意外部 executable authority；
    - `https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app`
      固定 Xcode-built/external-build embedded tool、Code Sign On Copy、Hardened
      Runtime、architecture 与 helper 仅 `app-sandbox + inherit` 的候选要求；
    - `https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox`
      与 `https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox`
      固定 App Sandbox/entitlement 的 least-privilege 基线；
    - `https://developer.apple.com/documentation/servicemanagement/` 与
      `https://developer.apple.com/documentation/servicemanagement/smappservice`
      固定 LoginItem/LaunchAgent/LaunchDaemon 的不同 lifecycle、approval 与 privilege
      面；三者不得折叠成一个“helper”；
    - `https://developer.apple.com/documentation/xpc/xpc_listener_set_peer_requirement`
      固定 broker/XPC 必须显式验证 peer code-signing requirement，IPC channel 存在
      不自证 caller authority；
    - `https://developer.apple.com/documentation/security/constraining-a-tool%27s-launch-environment`
      固定 embedded/helper 候选需评估 parent/team launch constraints；
    - `https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/`
      与 `https://developer.apple.com/documentation/security/customizing-the-notarization-workflow`
      固定 nested code 的 inside-out signing、Developer ID/Hardened Runtime 与
      notarization/ticket 检查面。
  - **Rockchip upstream/supply-chain dossier:closed for review。**唯一 upstream =
    `https://github.com/rockchip-linux/rkdeveloptool` 的 exact commit
    `304f073752fd25c854e1bcf05d8e7f925b1f4e14`、tree
    `9908d5bd43d32659500e6f0d0734755ee557122e`（authored/committed
    `2025-03-07T07:34:30Z`）。exact `license.txt` blob =
    `25e216a7063f10f19bf5b77b3a351f5bbd62e268`、`CMakeLists.txt` blob =
    `90faa72f90bf6111d26559d278685cdb5c39811a`、`Readme.txt` blob =
    `2561f1e2e153488efd1ad0628ef00a9dfaac1f5d`。upstream metadata 标记 GPL-2.0；
    pinned macOS CMake 输入显式引用 libusb 1.0.22 与 libiconv 路径。matrix 必须把
    license/notice、source offer、依赖来源/version/hash/license、reproducible
    universal build、SBOM、sign/notarize、update/CVE/rollback 分开判定；这些 object
    只证明 source facts，不构成法律批准、可分发性或现有 binary reproducibility。
    需要其他 commit/dependency/source 时先回到 blocked，不临场扩 dossier。
  - **Five-candidate matrix gate:binary。**顶层行固定为
    `selectedExternal`、`bundledRockchipComponent`、`brokerOrHelper`、
    `planOnlyHandoff`、`distributionRevisit`；`brokerOrHelper` 必须再分
    sandboxed XPC、embedded inherited helper、LoginItem/LaunchAgent 与 privileged
    LaunchDaemon 四个 subrow，不能用一个 subrow 的优点替代另一个。每行至少包含：
    product/Core compatibility、component/executable location、sandbox/entitlements、
    tool/image/key/output access、USB/device access、composition root、authority
    minting、IPC peer authentication、fixed argv/no shell/PATH、tool provenance、
    license/dependency/SBOM、sign/notarize/update、cancel/crash/reconcile、diagnostics/
    privacy、clean-host verification、Windows/Linux portability、rollback、source
    refs、fact-vs-inference 与 verdict。每个 cell 只接受
    `pass | fail | unknown | requires-new-change`；空白、`n/a` 无理由或合并 cell
    均 FAIL。
  - **Decision rule:binary。**只有不存在 `fail/unknown`、且每个
    `requires-new-change` 都有先于实现的 exact gate，候选才可推荐。最终 ADR/DEC-011/
    profile 必须逐字同意一个 `selected:<candidate-id>`，或同意
    `no-viable:execute-remains-blocked`；若选择 `brokerOrHelper`，outcome 必须细化为
    `selected:brokerOrHelper/<subrow-id>`。组合方案必须作为完整新增行重新评估，不能
    拼接既有 cell。结论必须记录 rejected alternatives、residual risks、
    revalidation triggers、rollback 与后续 change handoff。“继续探索”“先实现”
    “重跑 001G”均不是合格结论。
  - **Authority/effect gate:binary。**selected execution candidate 必须画出
    `ArkDeckApp composition root → typed workflow/binding/plan → single authority
    minting point → component boundary → exact tool/argv/file leases → process/device
    dispatch → durable intent/outcome`，并逐项说明 fake/plan-only 与 production
    结构差异。plan-only/no-viable 必须明确 ArkDeck process/device dispatch 不存在，
    人工外部结果不能进入 ArkDeck `succeeded`。任何 helper 都不能同时自报 caller
    facts、mint authority 并证明自己的 effect；unknown identity/outcome 保持
    `waitingForRecovery`，不得靠 restart/replay 猜测。
  - **No-workaround/no-effect gate:binary。**本 task 只允许 Git/GitHub read、官方
    HTTPS documentation/upstream GET 与仓库 checker 作为 review tooling；这些读取
    必须与 ArkDeck product/tool network effect 分栏记录。App/probe/fixture build/run、
    `Process`/rkdeveloptool/HDC launch、USB/device、bookmark/picker、XPC/helper/login
    item/daemon、install/register、sudo/pkexec/privilege、entitlement/sign/quarantine/
    xattr/system-rule/group/ACL mutation、E1/E2/destructive dispatch 均为 0。不得
    下载/编译 dependency 或 binary，不得 clone/checkout upstream，不得写用户目录；
    发现需要实验只能在 handoff 中另立 change，不能扩本任务。
  - **Deliverable/consistency gate:closed。**decision/evidence PR 只创建 ADR-0003、
    `evidence/runs/TASK-RKTA-001/candidate-matrix.md` 与同目录 `run.md`，在
    `open-questions.md` 新增 DEC-011，并同步现有 design/verification/tasks/profile；
    task 状态仍为 `ready`。不修改 proposal、acceptance-cases、spec-impact、
    CHG-2026-026、Core/spec/contracts、integration registry、entitlements、
    product/test/script/workflow。ADR、DEC-011、profile、matrix 与 run 的
    outcome/candidate ID 必须一致；任何一处不一致或把 future gate 写成已满足，
    `RKTA-DECISION-001/RKTA-HANDOFF-001` 均 FAIL。
  - **Environment/check gate:satisfied。**audit host = macOS 26.5.2
    (`25F84`) arm64、Xcode 26.6 (`17F113`)、Apple Swift 6.3.3、Git 2.55.0、
    GitHub CLI 2.96.0。base 上 `scripts/check-sdd.sh` = 0 error / 0 warning /
    111 acceptance IDs，`python3 scripts/test_check_pr_paths.py` = 24/24 PASS。
    decision/evidence 必须复跑两者与 `git diff --check`，并以 changed-path、
    forbidden-path、secret/privacy scan 证明范围。task 本身不主动运行 Swift/product
    build；仓库 push CI 的既定 Swift regression 仍须通过，但不作为 architecture
    acceptance evidence。
  - **Concurrency/review gate:satisfied。**`2026-07-25T06:23:43Z` 公开 open PR
    只有 #523（仅 CHG-2026-034 七路径）与 #524（仅 `scripts/host_loop/**`），与本
    task/change/ADR/profile/decision/evidence paths 零重叠；planned ADR、DEC 与
    evidence 目录均 absent。decision 开工前重做分页完整 files/heads 与 absence；
    overlap、查询不完整或新 owner 抢占立即 blocked。readiness PR 本身只修改本
    `tasks.md` 的 TASK-RKTA-001 section，零 matrix/ADR/evidence/profile/DEC/product
    变化。
- Platform:macos
- Requirements：`REQ-FLASH-001`、`REQ-FLASH-004`、`REQ-FLASH-005`、
  `REQ-FLASH-015`、`REQ-JOB-005`、`REQ-UX-007`
- Acceptance：`AC-FLASH-001-01`、`AC-FLASH-005-01`、
  `AC-FLASH-015-01`、`AC-JOB-005-01`、`AC-UX-007-01`、
  `RKTA-OPTIONS-001`、`RKTA-DECISION-001`、`RKTA-BOUNDARY-001`、
  `RKTA-HANDOFF-001`
- Depends on：CHG-2026-035 approval、independent readiness、PR #525 merge
  `2b15a53986054f0984a71a0f113a5a2b807c3914`
- Readiness input pins：见上方 r1 D1 readiness；decision/evidence 开工时从 readiness
  merge 重新核验
- Applicable failure patterns：`AF-001`、`AF-002`、`AF-007`、`AF-009`、
  `AF-010`、`AF-017`
- Production reachability：not applicable；本任务只做 host-side document review，
  不构造 App/CLI/fixture production route，不产生 authority 或 effect dispatch
- Trusted fact sources：protected-main Git objects 与 exact PR review/merge metadata；
  #525 sanitized receipt/hash；current specs/contracts、ADR/decision/profile、tool
  registry/provenance；带版本/URL/检索日期的平台与供应链一手文档。candidate 自报、
  未合入 branch、二手文章与聊天描述不能自证事实
- Allowed paths:
  - `docs/adr/0003-macos-rockchip-tool-execution.md`
  - `openspec/planning/open-questions.md`
  - `openspec/platforms/macos/profile.md`
  - `openspec/changes/chg-2026-035-macos-rockchip-tool-architecture/design.md`
  - `openspec/changes/chg-2026-035-macos-rockchip-tool-architecture/tasks.md`
  - `openspec/changes/chg-2026-035-macos-rockchip-tool-architecture/verification.md`
  - `openspec/changes/chg-2026-035-macos-rockchip-tool-architecture/evidence/**`
- Forbidden paths:
  - `AGENTS.md`
  - `openspec/constitution.md`
  - `openspec/governance/**`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/verification/acceptance-index.txt`
  - `openspec/verification/acceptance-cases.yaml`
  - `openspec/changes/archive/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/**`
  - `ArkDeckApp/**`
  - `ArkDeckAppUITests/**`
  - `ArkDeck.xcodeproj/**`
  - `Packages/**`
  - `.github/**`
  - `scripts/**`
- Risk:low（文档判断本身无 effect；错误结论会决定后续高风险产品边界，因此必须 D1）
- Hardware required:no

### Deliverables

- 一份 source-pinned candidate matrix，完整覆盖 selected external、bundled Rockchip
  component、XPC/broker/helper、plan-only handoff 与 distribution revisit；
- `ADR-0003`：唯一推荐 end-state 或明确 no-viable 结论、rejected alternatives、
  residual risks、revalidation triggers 与 rollback；
- 同步后的 DEC inventory 与 macOS profile，不与 ADR/Core/CHG-2026-026 互相矛盾；
- 一个后续 change handoff：精确列出必须先批准的 spec/ADR/entitlement/distribution/
  supply-chain/readiness gates、允许实现范围和仍禁止的真实 effect；
- `evidence/runs/TASK-RKTA-001/run.md`，记录输入 pins、资料版本、矩阵结论、diff、
  命令、AC verdict、偏差与全部 effect counter = 0。

### Verification

- `RKTA-OPTIONS-001`：五类 candidate envelope 与全部 mandatory criteria 均有
  `pass|fail|unknown|requires-new-change`、一手来源和事实/推断标记；
- `RKTA-DECISION-001`：结论恰为一个完整 end-state 或 no-viable；ADR、DEC inventory
  与 profile 一致，所有 rejected/unknown/reopen 条件显式；
- `RKTA-BOUNDARY-001`：结论给出 root→authority→component→process/device effect 与
  file/tool/provenance boundary；plan-only/no-viable 明确零 dispatch；
- `RKTA-HANDOFF-001`：后续实现/change 依赖封闭，HDC external-first、Core、
  CHG-2026-026 状态与 001G evidence 未被静默改变；
- `scripts/check-sdd.sh`、`python3 scripts/test_check_pr_paths.py`、
  `git diff --check` 全绿；allowed/forbidden path 与 secret/privacy scan 通过。

### Notes / handoff

- decision/evidence PR 不翻 `ready → done`；合入后使用独立 D0 状态 PR。
- 评估中不得 build/run probe、fixture、App 或外部 tool，也不得触碰 USB/设备/用户文件。
- 任一来源不完整、候选需要超出 allowed paths 的现行规则修改、或 concurrent PR
  overlap 时，任务回到 blocked 并先修订 change/readiness。
- TASK-RKTA-001 done 只完成架构选择，不授权实现。后续产品工作必须使用独立 approved
  change；CHG-2026-026 是否以及如何修订由该 handoff 再决定。
