# CHG-2026-031 Tasks

> proposal、approval、readiness、implementation/evidence、done、verified 分离。
> 三项任务均 host-only，测试只使用临时 Session fixture；不得读取或删除用户真实
> Session。proposal 合入不使任何任务 ready。
>
> r2（2026-07-25，on merge）接受 #436/#503 的 production-reachability blocker，
> 选择由 CHG-2026-026 `TASK-RKFUI-002` 的 App-process plan-only facade 消费同一
> Session runtime，并新增只读复验任务 `TASK-SSET-001R`。r2 不修改另一 change、
> 不使任何 task ready，也不授权 App/CLI/entitlement/IPC 实现。

## TASK-SSET-001 — Settings、retention catalog 与 production storage wiring

- Status:blocked（2026-07-25；仅在维护者 review/merge 本独立 D0 状态 PR 后生效。
  implementation/evidence PR #436 exact head
  `ad389a2190af2132365112f9a107105fbebf3b8e` 已由 `lvye` APPROVED，并合入
  protected `main` `9346a6da81fc42285c228ded183df089fc596c4a`；merged run blob
  `e622e62c0dc507851c0739747395bc122644b4a1` 如实记录
  `SSET-CONFIG-001`/`SSET-CATALOG-001` 与适用 canonical AC 的 contract candidate
  PASS，但 `SSET-RETENTION-001` 因 App-owned runtime 到真实 Host consumer 的
  production reachability 未闭合而 BLOCKED。进一步实现必须先经独立 D1
  scope-remediation 选择 App-process consumer、受签名共享载体或显式收窄
  production reachability；本状态 PR 不作该判断、不修改实现/evidence，也不使
  `TASK-SSET-002` ready。）
- Blocked recheck（protected `main`
  `1c1ae70a869d03e50a3a012e53d2a1b47a9f311d`）：
  - #436 的八个 implementation/evidence path 从 merge 至本 base 零漂移；run blob
    与 merge 时逐字一致；
  - `SessionSettingsContractTests` 在本 base 重跑 17/17 PASS，证明已实现的
    settings/catalog/同进程 composition contract 未回退，但测试中的依赖注入不替代
    App→真实 Host consumer reachability；
  - production 调用仍只有独立 `ArkDeckCLI` 构造
    `RockchipFlashExecutionHost()`；`ArkDeckApp/**` 对
    `SessionStorageApplicationRuntime`/`RockchipFlashExecutionHost` 零引用，
    entitlement 中也没有 App Group/shared preferences 载体，因此 blocker 仍成立；
  - #501/#502 已分别合入本 base；其完整文件集只位于 CHG-2026-030 evidence 与
    CHG-2026-026 tasks，与本状态路径零重叠。状态起草时公开 API 的 open PR count
    为 0。
- r2 remediation route（仅在 r2 经维护者 review/merge 后生效）：
  - 选择 App-process real consumer，不选择 App Group/shared preferences/bookmark IPC，
    也不收窄 `SSET-RETENTION-001` 为同进程 contract；
  - product implementation owner 固定为 CHG-2026-026 `TASK-RKFUI-002`。该任务未来
    readiness 必须显式接受本 dependency、pin r2/#436，并要求
    `RockchipFlashApplicationFacade` 的 plan-only production route 通过同一
    `SessionStorageApplicationRuntime` 创建 owned Session/plan Artifact；
  - CHG-2026-031 不得在该 cross-change readiness/implementation/done 前投机修改
    App/Flash source。其合入后再由 `TASK-SSET-001R` 独立 documentReview/contract
    revalidation；001R done 后本任务才可单独 `blocked→done`；
  - standalone CLI 保持独立 process-local settings domain；CLI contract 或 host
    可构造性不替代 App production reachability。
- Readiness review:
  - **Approval/dependency gate:satisfied。**CHG-2026-031 r1 proposal #432 exact
    head `f69ce61282118c530a1a7bf185dae38d8140c2af` 经维护者 `lvye` APPROVED，
    以 merge OID `2eb070353fc3343c604a5cba61d6fd16f865d365` 登记；独立
    approval-only #433 exact head
    `8021bf92db9d14bb2991dd60c7aee29552ab4b74` 经同一维护者 APPROVED，并以
    `39af11ec9e5862a2edddfe73c35bcb3acd010656` 合入 protected `main`。本任务
    无其他 task 依赖；approval 不替代本 readiness，也不使 SSET-002 ready。
  - **Audit base/input pins:closed。**readiness audit base =
    `39af11ec9e5862a2edddfe73c35bcb3acd010656`，其 first parent 是 proposal merge
    `2eb070353fc3343c604a5cba61d6fd16f865d365`、second parent 是上述 approval
    exact head；tree 中 `proposal.md` 已为
    `status: approved`。以下 input 均以该 base 实测；`tasks.md` 是本 PR 自载体，
    其 OID 只表示修改前输入。readiness merge 后 implementation 必须确认该 merge 的
    parent 恰为 audit base、diff 只含本 task readiness，并以新的完整 merge OID 替代
    pre-readiness `tasks.md` blob。任一 pin/absence 漂移或新 allowed-path overlap
    都立即回到 blocked：

    ```yaml pins
    - artifact: TASK-SSET-001 readiness audit base
      commit: 39af11ec9e5862a2edddfe73c35bcb3acd010656
    - artifact: CHG-2026-031 approval merge
      commit: 39af11ec9e5862a2edddfe73c35bcb3acd010656
    - path: openspec/changes/chg-2026-031-macos-session-settings/proposal.md
      blob: 09110cd191a18e06e8e1428b6d759c6dd216f1b2
    - path: openspec/changes/chg-2026-031-macos-session-settings/design.md
      blob: ea4294fb61834ae0c978c9afdbf84443d200e9ac
    - path: openspec/changes/chg-2026-031-macos-session-settings/tasks.md
      blob: 56112ebf9628fbadeb49183035f406e5e3a54a1e
    - path: openspec/changes/chg-2026-031-macos-session-settings/verification.md
      blob: 744e9a3d45e271a653bcb692c5c95918cdab435e
    - path: openspec/changes/chg-2026-031-macos-session-settings/acceptance-cases.yaml
      blob: 64e7ee039e8ee49e4dc2d270a7100cc71359579a
    - path: openspec/changes/chg-2026-031-macos-session-settings/spec-impact.md
      blob: 660410caf70b664af92af7d1cd9ba4ad6e0a43d7
    - path: openspec/planning/open-questions.md
      blob: 9c3d39809a697a09b136bfe35f4e4be476f35e8f
    - path: openspec/specs/session-artifact-storage/spec.md
      blob: 1ce44bc1bcfcb765662275eed20adba16d57f5bd
    - path: openspec/platforms/macos/profile.md
      blob: a9a5931ffedd304a7ce3a088f4397c26fd87e744
    - path: ArkDeckApp/ArkDeckApp.entitlements
      blob: 6435d00f8493ce4fbca24a806ca7f320db9fbfa6
    - path: Packages/ArkDeckKit/Package.swift
      blob: 91a1032f8a5ff9285154ef6f48ef35470b294eb7
    - path: Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionStorageTypes.swift
      blob: 04aa1c185defc6bdc5da0c041b20d5c538e167f2
    - path: Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionManifest.swift
      blob: 2e168e49abad60e165cec6e49df41d429c5d9ff0
    - path: Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionLayout.swift
      blob: ed48f90a96ee239769e86727ae9272017fea72f7
    - path: Packages/ArkDeckKit/Sources/ArkDeckStorage/RetentionAndExport.swift
      blob: ed53dcd3e911bc8ff968b7f1e22f51cefe5a0d94
    - path: Packages/ArkDeckKit/Sources/ArkDeckStorage/HostStorage.swift
      blob: e052657f08c6ef98fa1019269541a1ad5deb7000
    - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecution.swift
      blob: c9f84dce04f8629b8116be979b8f83ae11f251a4
    - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionHost.swift
      blob: 72c11b3936970b76d791d55d7d9e09dcd33552c2
    - path: Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift
      blob: be9bc136ae2f5086153459e8d7252c8c72ec13b1
    - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkDeckContractTests.swift
      blob: 98f98253c0f9ab67ab268255cd7596f8a07ff724
    - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/SessionArtifactStorageContractTests.swift
      blob: 68904a3f9ac87d70c31547c3242af86c232807a1
    - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipFlashExecutionContractTests.swift
      blob: 82629470a4e8c16e5935159fa19aa93a0a2cf43a
    ```

    `Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionRetentionCatalog.swift`、
    `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/SessionSettings/` 与
    `Packages/ArkDeckKit/Tests/ArkDeckContractTests/SessionSettingsContractTests.swift`
    在本 base 均不存在，只允许本任务创建；不得覆盖其他 owner 的实现。
  - **Settings/root contract:closed。**typed snapshot 固定字段 =
    `schemaVersion/generation/rootSource/expectedRootPath/totalQuotaBytes/
    safetyMarginBytes/retentionDays`；fresh domain 的 generation = 0，默认值必须逐字节
    等于 DEC-006 的 `20 * 1024^3`、`2 * 1024^3`、90 和当前 process 的 user-domain
    Application Support `ArkDeck/Sessions`。只有所有 settings keys 均不存在才是 fresh；
    partial/wrong-type/unknown-version/zero/overflow/quota ≤ margin 返回具名错误且不
    覆写。每次成功 save/reset 使 settings generation 单调递增，每次成功 pin/update
    使 catalog generation 单调递增；两者 overflow 均 fail closed。
    自定义根只接受 picker URL 生成的 read-write app-scoped bookmark +
    expected standardized path；resolve 必须 `.withSecurityScope/.withoutUI`、
    `startAccessing... == true` 且 path 相同。stale bookmark 仅在上述条件与 replacement
    bookmark 原子保存均成功时刷新；否则 `requiresReselection`，零 default fallback。
  - **Catalog/data gate:closed。**新增 Storage catalog 只以 descriptor/openat、
    `O_NOFOLLOW`、`fstatat(...AT_SYMLINK_NOFOLLOW)` 走
    `<four-digit-year>/<two-digit-month>/<sessionID>`；不得用跟随 symlink 的递归
    enumerator 决定 deletion candidates。valid finalized candidate 必须同时满足：
    目录 owner/safe、`.session-identity.json` 与 locked manifest 的 session/job identity
    一致、manifest regular-file/size/validation 通过、`completedAt` 为
    `SessionManifestDocument` 解析后的 typed Date、完整 size walk 无 symlink/FIFO/
    socket/read error/overflow。其余目录一律 preserved-unknown，`unknownPressure=true`
    且永不进入 `RetainedSession` deletion list。
  - **Retention metadata gate:closed。**每个 sessions root 只有一个 ArkDeck-owned
    versioned/atomic catalog metadata，记录 catalog generation 与
    `sessionID/completedAt/expiresAt/isPinned/policyGeneration`；不修改 manifest。
    首次索引既有 valid finalized Session 初始化 `isPinned=false`；已有 entry 缺失、
    duplicate、损坏或 identity/time mismatch 时不重建为 unpinned，而转
    preserved-unknown。retentionDays 变化只重算 `expiresAt` 并保留 pin；pin/update
    必须 compare-and-swap catalog generation。known bytes 使用 saturating accounting；
    任一 unknown size 另以 `unknownPressure` 阻断，绝不按 0 解释。
  - **Plan/apply/admission gate:closed。**refresh 以真实 root/volume identity +
    settings/catalog generation 生成 ordered preview。若 known current bytes >
    `quota - margin`、存在 unknown pressure、active claim 对应 Session、或上次 apply
    尚未成功 rescan，shared coordinator 在用户确认前即阻断该 volume 的新 heavy/
    unknown writer；不得直接把 controller 的 projected
    `blocksNewHeavyWriters=false` 当成“已释放”。HostStorage 可增加显式 conservative
    admission API，但保留现有 plan API/既有测试兼容。
  - **Deletion authority gate:closed。**confirmation token 精确绑定 settings/catalog
    generation、standardized root、root/volume identity、ordered deletion IDs 与
    projected bytes；apply 前全部重新读取，任一 drift = zero call to
    `SessionRetentionController.apply`。shared coordinator 必须提供 active
    Session/root snapshot；active/partial/pinned/unknown 不删。apply 成功或部分失败后
    都重新 scan；只有实际 current bytes ≤ safety target、零 unknown pressure 且
    rescan 成功才解除阻断。crash/throw/rescan failure 保持阻断，preview/confirmation
    不跨进程恢复。
  - **Production composition/phase gate:closed。**当前真实 consumer 是
    `ArkDeckCLI` 的同步 `RockchipFlashExecutionHost()`；implementation 必须保持该 public
    initializer 与 CLI source 零改动。shared runtime 可以用 actor + nonisolated immutable
    thread-safe settings/coordinator handles 服务同步 composition，但不得要求把 initializer
    改 async 或新增 CLI/App path。`RockchipProductExecutionSettings.load()` 的 Session
    root/独立 coordinator 必须由同一 process 的 validated settings context/shared
    coordinator 替换；现有 tool bookmark、Keychain provenance、binding、storage
    snapshot/claim 与 device authorization 不变。App Settings scene/点击清理的最终
    reachability 明确属于 SSET-002；SSET-001 evidence 只认 real Workflows facade +
    Rockchip SessionStore consumer，不宣称 App UI 已可达或 change 已 verified。
  - **Module/allowed-path gate:closed。**新代码只用 Foundation/Darwin 与既有
    ArkDeckStorage/Workflows 依赖；`Package.swift` 和 dependency table 不需改变，必须
    保持 pinned blob。`SessionManifest.swift` 只新增 locked validation 后的 read-only
    typed `completedAt` exposure；`HostStorage.swift` 只新增 conservative admission/
    active-session observation；`RetentionAndExport.swift`、`SessionLayout.swift`、
    `SessionStorageTypes.swift`、`RockchipFlashExecution.swift`、CLI 与既有 test files
    均是 read-only consumers。若实现需要其中任一修改、App/Xcode path、locked schema
    或新 module dependency，立即 blocked 并先走 scope remediation。
  - **Fixture/fault/privacy gate:closed。**所有 delete/apply 正例只在
    `FileManager.default.temporaryDirectory` 下由 test 自建 owner-only root，defer
    清理；不得 resolve default Application Support、用户 home、现有自定义 root 或本
    workspace 的未跟踪 fixture/log。preferences 测试使用唯一 ephemeral suite/domain
    并清理；bookmark adapter 用 deterministic fake，真实 signed bookmark reopen 留给
    SSET-002。fault matrix 至少覆盖 partial/wrong settings、stale/mismatch bookmark、
    每层 symlink、FIFO/socket/hardlink、duplicate/identity/manifest/metadata/time drift、
    size overflow/read error、pin/settings/catalog/root/volume drift、第二个 deletion
    注入失败、post-apply rescan failure 与 coordinator bypass；mutation 必须证明
    stale confirmation/delete-port call count = 0、pinned/unknown sentinel bytes 不变。
    logs/evidence 只含相对 Session ID、generation、计数/字节与具名错误，不含 bookmark
    bytes、用户绝对路径、Artifact 内容或设备标识。
  - **Environment/baseline gate:satisfied。**macOS 26.5.2、Xcode 26.6
    (17F113)、Apple Swift 6.3.3。audit base 上受控 host 的
    `CI=true swift test --package-path Packages/ArkDeckKit` PASS（仅既有
    `TEST-MAC-M1-PORTS-001` 手工 sleep/wake harness skipped，零 failure）；
    `scripts/check-sdd.sh` = 0 error / 0 warning / 111 acceptance IDs；
    `python3 scripts/test_check_pr_paths.py` = 21/21 PASS。一次仅为截取输出而在
    filesystem sandbox 内重跑 Swift 时因用户 clang cache 不可写失败，已按环境约定在
    sandbox 外以同一正式命令复验通过；该 sandbox 失败不计产品 failure，也不得从
    evidence 删除。
  - **Concurrency/evidence gate:satisfied。**2026-07-24 readiness audit 时 GitHub
    open PR = 0；新增三路径均 absent。工作区既有未跟踪
    `ArkDeckFakeHDCFixture-M1-006`、`Packages/ArkDeckKit/log/`、`log/` 不在 scope
    且保持 untouched。implementation/evidence 必须追加
    `evidence/runs/TASK-SSET-001/run.md`，逐项记录 contract/fault/production
    composition、allowed/forbidden diff、secret/privacy scan、temporary-fixture-only
    与 real user/device effect = 0；交付 PR 不翻 ready→done，done 使用独立 D0 PR。
- Platform:macos
- Requirements:`REQ-ART-001`、`REQ-ART-006`、`REQ-STO-001`、
  `REQ-STO-003`、`REQ-STO-004`
- Acceptance:`AC-ART-006-02`、`AC-STO-001-01`、`AC-STO-003-01`、
  `AC-STO-004-01`、`SSET-CONFIG-001`、`SSET-CATALOG-001`、
  `SSET-RETENTION-001`
- Depends on:r2 approval、TASK-SSET-001R done（#436 implementation/evidence 已 merged）
- Readiness input pins:由独立 readiness PR 固定，不在 proposal 预填未来 OID
- Applicable failure patterns:`AF-001`、`AF-002`、`AF-007`、`AF-008`、
  `AF-010`、`AF-017`
- Production reachability:
  `RockchipFlashExecutionHost.init` → `SessionStorageApplicationRuntime`
  settings/root lease/shared coordinator → `SessionStore.createSession`；
  App Settings facade → generation-bound user confirmation →
  `SessionRetentionController.apply`。本任务无 device effect。
- Trusted fact sources:locked manifest 生产 `sessionID/completedAt`；Storage
  descriptor/filesystem probes 生产 root/size/volume；versioned catalog 生产 pin 与
  generation；UserDefaults 只搬运 settings/bookmark，不自证可访问性，bookmark 每次由
  URL/security scope 重新验证。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionManifest.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionRetentionCatalog.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/HostStorage.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionHost.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/SessionSettings/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkDeckContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/SessionSettingsContractTests.swift`
  - `openspec/changes/chg-2026-031-macos-session-settings/evidence/**`
  - `openspec/changes/chg-2026-031-macos-session-settings/tasks.md`
- Forbidden paths:
  - `AGENTS.md`
  - `openspec/constitution.md`
  - `openspec/governance/**`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/archive/**`
  - `ArkDeckApp/**`
  - `ArkDeckAppUITests/**`
  - `ArkDeck.xcodeproj/**`
- Risk:medium（host-local delete 与 production root composition；所有删除只在临时
  fixture 验证，真实 App effect 留给用户确认）
- Hardware required:no
- r2 remaining implementation authority:none。#436 后本任务不再修改产品 source；
  cross-change product wiring 由 CHG-2026-026 自身的独立 readiness/task 承载，本
  change 后续只做 001R revalidation 与状态推进。

### Deliverables

- typed settings snapshot/store、default/custom root access lease 与具名错误；
- secure retention catalog、versioned pin metadata、保守 size/unknown classification；
- shared storage runtime、preview/confirm/apply/rescan/admission state machine；
- Rockchip production Session root/shared coordinator wiring；
- hermetic contract/fault tests 与 task run evidence。

### Verification

- `SSET-CONFIG-001`：默认值、合法持久化、损坏配置、bookmark reopen/stale/path
  mismatch/reset contract；
- `SSET-CATALOG-001`：valid/partial/pinned/unknown/symlink/identity mismatch/overflow
  fixture matrix；
- `SSET-RETENTION-001` 与 canonical AC：expired-first、oldest-first、pin protection、
  generation drift、confirm-before-apply、partial failure/rescan、actual admission state；
- production composition contract 证明 settings root 被真实 `SessionStore` consumer
  使用，断开 bookmark/confirmation 时 create/delete effect = 0；
- `swift test --package-path Packages/ArkDeckKit`、`scripts/check-sdd.sh`、
  `git diff --check` 全绿。

### Notes / handoff

- implementation/evidence PR 不翻 `ready→done`；done 使用独立 D0 状态 PR。
- 如果需要 locked schema、自动删除、用户真实目录或 task allowed paths 之外的消费者，
  立即 blocked 并修订 change，不在实现 PR 扩 scope。

## TASK-SSET-001R — App-process production composition revalidation

- Status:blocked（前置：r2 经维护者 review/merge、CHG-2026-026
  `TASK-RKFUI-002` 独立 readiness/implementation/evidence/done 全部合入、本任务再经
  独立 readiness；本 r2 不执行 revalidation、不新增 evidence）
- Platform:macos
- Requirements:`REQ-ART-001`、`REQ-ART-006`、`REQ-STO-001`、
  `REQ-STO-003`、`REQ-STO-004`
- Acceptance:`AC-ART-006-02`、`AC-STO-001-01`、`AC-STO-003-01`、
  `AC-STO-004-01`、`SSET-RETENTION-001`
- Depends on:r2 approval、#436 implementation/evidence 与 #503 blocker record 已 merged、
  CHG-2026-026 `TASK-RKFUI-002` done、independent readiness
- Applicable failure patterns:`AF-001`、`AF-002`、`AF-009`、`AF-017`
- Production reachability:
  signed/testable `ArkDeckApp` composition root →
  唯一 `SessionStorageApplicationRuntime` →
  `RockchipFlashApplicationFacade` 实际消费同一 runtime →
  validated root lease/shared coordinator →
  App plan-only `SessionStore.createSession` + owned plan Artifact。该 runtime 同时作为
  后续 TASK-SSET-002 Settings facade 的固定生产依赖，但本任务不要求该 facade 已实现。
- Trusted fact sources:CHG-2026-026 merged source/test/evidence 与 full merge OID；
  App composition/runtime identity、实际 created Session root、coordinator/admission
  receipt。UI 文本、fixture DI、standalone CLI 或对象可构造性不能自证 reachability。
- Allowed paths:
  - `openspec/changes/chg-2026-031-macos-session-settings/evidence/runs/TASK-SSET-001R/**`
  - `openspec/changes/chg-2026-031-macos-session-settings/tasks.md`（仅本任务状态/
    evidence 引用与 TASK-SSET-001 dependency/status）
- Forbidden paths:
  - `AGENTS.md`
  - `openspec/constitution.md`
  - `openspec/governance/**`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/archive/**`
  - `Packages/**`
  - `ArkDeckApp/**`
  - `ArkDeckAppUITests/**`
  - `ArkDeck.xcodeproj/**`
- Risk:low（只读合入版 revalidation；零产品修改、零用户数据删除、零设备 effect）
- Hardware required:no

### Deliverables

- append-only run 固定 CHG-2026-026 `TASK-RKFUI-002` exact reviewed head、merge OID、
  source/test/evidence blobs 与 protected-main ancestry；
- document/source review 证明 App composition root 持有并向 Rockchip facade 注入唯一
  runtime/configuration epoch，App plan-only Session 真实落在 validated root 且使用
  shared coordinator；同时确认 TASK-SSET-002 的后续 dependency contract 禁止另建
  production runtime；
- 重跑 production composition contract：missing bookmark、root drift、retention block
  时 Session create = 0；fixture delete/process/device port = 0；
- 明确 standalone CLI 仍是独立 domain，不把其测试结果写成 App evidence。

### Verification

- `SSET-RETENTION-001` 与四条 canonical AC 的 merged producer→consumer evidence
  二值复验；
- CHG-2026-026 evidence 分类必须是 host-only plan-only/platform，不得冒充硬件；
- App Group/shared preferences/IPC/entitlement diff = 0；
- full Swift、相关 App/signed test、`scripts/check-sdd.sh`、`git diff --check` 与
  secret/private-path scan 全绿；
- revalidation/evidence PR 不翻 TASK-SSET-001R 或 TASK-SSET-001 状态；各自后续 D0
  状态 PR 分离。

### Notes / handoff

- 若 CHG-2026-026 的未来 readiness 未接受本 dependency，或其 App facade 另建
  settings/coordinator/root fallback，本任务保持 blocked，不把部分 composition 重判 PASS。
- 若实现要求 App Group、IPC、共享 bookmark 或修改 locked schema，停止并另立
  ADR/change；本 r2 没有批准这些能力。

## TASK-SSET-002 — macOS Settings UI 与 signed UI contract

- Status:blocked（前置：r2 approval、TASK-SSET-001R done、TASK-SSET-001 done、
  独立 readiness PR；
  readiness 须固定 facade API、Xcode project groups/target、String Catalog、signed
  Sandbox entitlement 与 UI fixture 零 delete-port 证明）
- Platform:macos
- Requirements:`REQ-ART-006`
- Acceptance:`AC-ART-006-02`、`SSET-UI-001`
- Depends on:r2 approval、TASK-SSET-001R done、TASK-SSET-001 done
- Readiness input pins:由独立 readiness PR 固定，不在 proposal 预填未来 OID
- Applicable failure patterns:`AF-001`、`AF-002`、`AF-007`、`AF-010`、
  `AF-013`、`AF-017`
- Production reachability:
  `ArkDeckApp.body Settings scene` → `SessionSettingsApplicationFacade.make()` →
  TASK-SSET-001 runtime；fixture facade 的
  `retentionApplyIsProductionComposed=false` 且没有 delete port。
- Trusted fact sources:UI 只呈现 facade snapshot；root/bookmark、catalog、size、pin、
  plan/admission 事实均来自 TASK-SSET-001，accessibility label 或 fixture text 不作为
  production authority。
- Allowed paths:
  - `ArkDeckApp/App/ArkDeckApp.swift`
  - `ArkDeckApp/Features/Settings/**`
  - `ArkDeckApp/Resources/Localizable.xcstrings`
  - `ArkDeckAppUITests/Settings/**`
  - `ArkDeck.xcodeproj/project.pbxproj`
  - `openspec/changes/chg-2026-031-macos-session-settings/evidence/**`
  - `openspec/changes/chg-2026-031-macos-session-settings/tasks.md`
- Forbidden paths:
  - `AGENTS.md`
  - `openspec/constitution.md`
  - `openspec/governance/**`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/archive/**`
  - `Packages/ArkDeckKit/Sources/**`
  - `Packages/ArkDeckKit/Tests/**`
- Risk:medium（用户可见删除确认 UI；fixture 与 production dispatch 必须结构隔离）
- Hardware required:no

### Deliverables

- Settings scene、view model、输出根 picker/reset、quota/margin/days validation；
- Session/pin/unknown/admission 列表、exact cleanup preview 与二次确认；
- 中英文 strings、accessibility identifiers、signed XCUITest；
- UI task run evidence。

### Verification

- `SSET-UI-001` signed XCUITest：默认值、validation、choose/reset、relaunch bookmark
  presentation、pin/unpin、preview/cancel/confirm、stale/reselection、blocked-heavy-writer
  文案与 accessibility；
- fixture route 静态/运行时断言 production delete dispatch 不可达，production facade
  composition test 证明按钮只在真实 facade + fresh confirmation 时可用；
- signed Debug build entitlement 包含既有 app-scope bookmark 与 user-selected
  read-write，entitlement 集不扩大；
- UI suite、全量 Swift suite、`scripts/check-sdd.sh`、`git diff --check` 全绿。

### Notes / handoff

- UI implementation PR 不携带 TASK-SSET-001 source 修改或状态翻转。
- signed UI evidence 只证明 macOS host UI/permission contract，不是用户数据删除证据，
  更不是 hardware evidence。
