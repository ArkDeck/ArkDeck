# CHG-2026-022 Tasks

> 两任务分期,各自独立 readiness/实现/done PR。本 change 首 PR 只 proposal +
> design,零实现、零真机、零 evidence。全程 host-only;真机观察本身属
> TASK-M0B-002(本 change done 后经新 readiness 解锁)。

## TASK-OBS-001 — Kit 仪表化与分类面

- Status:done(2026-07-28 completion;仅在维护者 review/merge 本独立
  `ready→done` PR 后生效。**实现载体 = #687**(merge
  `ca84cc2821e11ad691cb9d8dcdef4e2dc873d1d3`):Readiness r2 四机制全部
  落地——(a) identity-bound successful-spawn 唯一 hook(ArkDeckProcess
  package 级回调,public API 零变更)、(b) opaque confirmed/managed
  permit(class-identity + TaskLocal 绑定)、(c) caller 零 origin 输入
  (monitor 记录口 fileprivate)、(d) fake-process mutation seam;外加
  ownership 四证据 `.external` 判定 + managed provenance
  reconcile/retire、endpoint source 穿透与 child-env 注入清单、只读设备
  fan-out(生产源腿仅 CHG-2026-024 registered family)。新契约文件
  `HDCSupervisorObservabilityContractTests.swift` 25 用例 = r2 验证计划
  附录 25 条逐条直译(C1-C8/O1-O8/E1-E4/F1-F5),四 change-local AC
  (OBS-COUNTER/OWNERSHIP/ENDPOINT/FANOUT-001)全部可判定且逐条 PASS。
  **授权链**:readiness r2 = #678(merge
  `a8666bddd51b4cb469be6c8cc1f21c421508b12d`),其一次性实现授权已由
  #687 全额消耗。**evidence** =
  `evidence/runs/TASK-OBS-001/run.md`(blob
  `4148b50a8d5ef6614058fdf24972d3d921f01de0`,SHA-256
  `15eddd72a2725d610301121ef9715703e9391134cb5351ee493f4717d0ce4063`,
  在树;含授权链、双 rebase 注记、pin 复核、25 条逐条映射与反作弊
  自查)。
  **flip base recheck(在翻转后的树上实测,非 /private/tmp worktree;
  HLR-003 r5 教训)**:(a) #678 与 #687 两 merge 均为 flip base
  ancestor;#687 之后本 change 目录零 commit 触及,本文件改前 blob
  `ac498a4eefd4bce7c94a47158b847af72e045cc7` == #678 merge 产物(#687
  未触本文件);(b) `swift test --filter
  HDCSupervisorObservabilityContractTests` = `Executed 25 tests, with
  0 failures (0 unexpected)`,exit 0;全量 swift test = `Executed 440
  tests, with 1 test skipped and 0 failures (0 unexpected) in 63.603
  (63.673) seconds`,exit 0(440 == #687 记录的 main 自身基线 415 +
  新增 25,零回归、既有 skip 不变;汇总行取自完整输出文件);(c)
  `check-sdd` = `0 error(s), 0 warning(s), 111 acceptance IDs`,
  exit 0;(d) host_loop `done_task_ids` == 104 且含 `TASK-OBS-001`,
  `--explain` 对本任务报 rejected(`status 'done' is not ready` +
  decision grade D1 human-gated),不再 claimable;(e) 本 flip 单文件;
  guard 模拟判定
  (title 声明本任务,文件集 = 仅本文件)PASS;verification.md 无本任务
  status 格(#150 同步形态不适用),其 `Status:planned` 为 change 级,
  由 change verify PR 翻转。
  **不声称**:change 级 `verified`(为下一独立 PR,前提含两 task
  done);OBS-002/M0B-002/macOS conformance 任何进展;F 组绿不构成
  M0B-002 真机观察进展。
  **连带效果**:本翻转使 TASK-OBS-002 前置②「TASK-OBS-001 done」满足
  (其前置① r2 remediation merged 此前已满足)——OBS-002 仍
  blocked,待其前置③独立 readiness PR(须钉 OBS-001 交付 hash 与
  XCUITest 环境复核);本 PR 不动 OBS-002 段。)
- Historical Status:ready(r2 readiness = #678 merge
  `a8666bddd51b4cb469be6c8cc1f21c421508b12d`;其一次性实现授权已由 #687
  全额消耗。原 r2 Status 正文如下作历史保留。)
- Historical Status:ready(r2 readiness；仅在维护者对本独立 readiness PR exact head
  review/merge 后生效,生效后一次性授权按下方 Readiness r2 契约的实现交付;
  r1 readiness 与 prototype #265 仍不可引用)
- Historical Status:blocked(r2 review-remediation candidate；仅在本治理 PR 由维护者
  review/merge 后生效。r1 readiness 与 prototype #265 不可用于开工/合入。该
  remediation 已 merge 生效;本 r2 readiness 即其预告的独立 blocked→ready 载体)
- r1 readiness invalidation(2026-07-21;host-only review):
  - Approved gate 仍为 satisfied：r1 change 经
    `1e4a7c4027ecdd1142ceab2b80f4423eec586d6d` 批准；本 r2 不撤销 change，
    只撤销 TASK-OBS-001 readiness 结论。
  - r1 readiness commit 为
    `f3c9685ea70b32099c20bf7fe022bbc9aa688709`。当时三文件的精确 historical
    Git blob OID / file SHA-256 为：

    | File | Git blob OID | File SHA-256 |
    | --- | --- | --- |
    | `HDCProduction.swift` | `8a2e9599515997508acc03b678fd3a966adec5fe` | `3f74aa37d8d3f95354e2c944f11ceb9bcb6bbf972e5cbc5716da7a518a483c19` |
    | `ArkDeckOpenHarmony.swift` | `0626661efb81db412fff60b85c81adf397dcea85` | `2c529869beed6088b23753d2c36ef2fc6ca1ddbbf601b30e6eb18ea84eedadd3` |
    | `HDCApplicationDiagnosticsFacade.swift` | `9eab3cd5d3aad600b3576e90d059b161eb2987bc` | `1e37e67430b2d5da73dbbffbd5dd0a2897ce8e395977387669230b0dce5bb1cc` |

    r1 的 8-hex + ellipsis 不是精确 pin；上表只修复历史记录，不能作为未来
    readiness base。
  - Blocker FANOUT：macOS/current integration profile 没有任意设备枚举或
    zero-to-many snapshot family；selected-device authorization capture 不具备该
    语义。测试注入缓冲不能解锁 M0B-002。
  - Blocker COUNTER：不存在 automatic production caller；caller-supplied origin
    可伪造且不是唯一 successful-spawn hook。
  - Blocker OWNERSHIP：三证据未排除 active/unreconciled managed provenance，
    允许 registered observation 覆盖既有 managed claim。
  - Prototype PR #265 为 draft/invalidated diagnostics，不得 merge 为 TASK 完成，
    其中测试/evidence 不得被后续 readiness 复用或重判。
- Unblock prerequisites(全部满足后另起独立 `blocked→ready` PR):
  1. 独立 OpenHarmony integration change 已 approved/done，注册参数化 zero-to-many
     device snapshot family，并钉 exact argv/raw family、server identity bracket、
     empty/success/failure/unknown 与隐私语义；macOS profile 已同步。
  2. readiness 逐文件钉 actual implementation base 的完整 commit OID、Git blob OID
     或明确标注的完整 SHA-256；不得用省略前缀。
  3. readiness 复核 design §1 的 opaque confirmed/managed permit、caller 无 origin
     输入、identity-bound successful-spawn 唯一 hook 与 fake-process mutation seam
     均可在 allowed paths 内实现；若需修改 `ArkDeckProcess`，须显式列入文件级范围。
  4. ownership 四证据与 managed→external 禁止矩阵、external/unknown 授权门等价
     diff 测试已写成可执行验证计划。
  5. 重新审计与其他 open PR 的文件交集、Swift/SDD 环境及完整基线；不得引用
     #265 的 PASS 数字作为新 baseline evidence。
- Readiness(r2;audit base = protected main
  `5427fbccd0cd83d95d4d8dde029841763b0f4204`,#672 merge;2026-07-28 于该 base
  的独立非 /private/tmp worktree 起草,全部 pin/断言/基线为本次实测,零处
  引用 #265 或 r1 readiness 的输出):
  - **Approval boundary:pending human merge。**本 readiness 仅在维护者对本
    独立 readiness PR 的 exact head review/merge 后生效;载体只改本文件的本
    任务段。生效后一次性授权一个实现交付:按本段契约与验证计划附录完成四
    change-local AC 的实现 + contract 测试 + evidence run,载体 = 另一个标题
    声明本任务的独立 agent/* PR;`ready→done` 与 change `verified` 再各自
    独立。r1 readiness(`f3c9685ea70b32099c20bf7fe022bbc9aa688709`)与
    prototype #265 的任何测试/evidence/PASS 数字仍不可引用。
  - **Prerequisite 1(独立 integration change):satisfied。**CHG-2026-024 已
    done+verified:实现 #664 merge `ffca996f41be37d27137e7245c8fba3645fb0fb4`、
    done 翻转 #665 merge `66de578de6ae2756032f8a3f8bb058ae1585ebd4`、change 级
    verify #666 merge `ffc87dd7fbfde5359a4188f05aaadd52c58989cf`,三者实测均为
    audit base ancestor。交付面(base 树实测读出;OBS-FANOUT-001 生产源腿的
    唯一合法输入):registry `OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES@1.0.0`
    唯一 entry `openharmony-hdc-device-observation-snapshot-3.2.0f-macos`,
    family `deviceObservationSnapshot`,status supported、invocationAllowed
    true、exactArgv = list targets -v、endpoint policy = exact 127.0.0.1:8710
    + existing server required、presenceRule = presence 由 state 列判定,行
    不删除、行消失不得作 presence 信号,observedEmpty = 零 Connected 行,
    empty marker 与全 Offline 两形态等价;toolContext 3.2.0f,与
    readonly/trace 侧 3.2.0d 非同一工具,entries 不得混编;profile
    `OPENHARMONY-TOOLS@0.5.0`、lock `INTEGRATION-PROFILES-0.6.0`、macOS
    mapping 已同步登记。
  - **Prerequisite 2(逐文件完整 OID pin):closed。**audit base 实测 Git blob
    OID;实现开工须逐项复核未漂移,标注 invariant 者实现前后必须逐字节不变:

    | File | Git blob OID(audit base) | 性质 |
    | --- | --- | --- |
    | `Packages/ArkDeckKit/Sources/ArkDeckProcess/ArkDeckProcess.swift` | `b1d5f423c004f4ba15b15a8cf862ed2085d8bcc9` | 待改(机制 a) |
    | `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCProduction.swift` | `8a2e9599515997508acc03b678fd3a966adec5fe` | 待改;= r1 表同值,r1 以来零漂移 |
    | `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/ArkDeckOpenHarmony.swift` | `0626661efb81db412fff60b85c81adf397dcea85` | 待改;= r1 表同值 |
    | `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCReadOnlyProbeRegistry.swift` | `2dfe8e9d8290d6e939b4e3531ac81bb332a7cc29` | 仅如需扩收据/basis 暴露 |
    | `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCServerLifecycleJournalAdapter.swift` | `8648cc5f8c7decce50c98d3611d917073aa3e2da` | 待改(组合穿透) |
    | `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift` | `9eab3cd5d3aad600b3576e90d059b161eb2987bc` | 待改(E4);= r1 表同值 |
    | `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCSupervisorContractTests.swift` | `c09f6255d50b9c7b008f82f7f696c47f352fcb9b` | 仅新增用例,既有用例零修改 |
    | `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkDeckContractTests.swift` | `92711058a883ef6ded4de03e334a709b417bcaa4` | 既有用例零修改 |
    | `Packages/ArkDeckKit/Tests/ArkDeckFakeHDCFixture/main.swift` | `0e4fb857b124a8c7d31a8d4f428ca40c63687d01` | 待改(新增 subserver mode) |
    | `openspec/integrations/openharmony/device-observation-probes.yaml` | `1130ca663f686d9f202f53ceb8814320ebc862bd` | invariant(路径外) |
    | `openspec/integrations/openharmony/profile.md` | `32ce163d053824f555bccd530834f3d6f3a68706` | invariant(路径外) |
    | `openspec/integrations/INTEGRATION-PROFILES.lock.yaml` | `129abc6216593d73e401167181f61924addf602f` | invariant(路径外) |
    | `openspec/platforms/macos/profile.md` | `2d7b28296e48a46690f825f4451ce819e63e7c06` | invariant(路径外) |
    | 本 change `tasks.md`(本 PR 改前) | `315d1abbd9e09ab8a1103acb9c7736de6809d21a` | 本 PR 载体 |

    Sources 六文件自 736d5cf(预勘察基线)至 audit base 零变更(git diff
    实测该区间无任何 Packages Sources 文件),下列行号引用均在 audit base
    逐项复核命中。
  - **Prerequisite 3(design §1 四机制可实现性):closed;唯一必需的文件级
    显式化 = ArkDeckProcess.swift,已写入本段实现边界与 In scope/活声明的
    条款层括注——机械 glob 本就覆盖该文件,不放宽任何机械面。逐机制核验
    (全部 base 树实测):**
    (a) identity-bound successful-spawn 唯一 hook:**今天不存在,须新增**。
    唯一 spawn 成功判定点在 FoundationProcessExecutor 私有 spawn() 的
    guard spawnResult == 0(ArkDeckProcess.swift L769);现有成功后回调
    launchObserver 只收 pid_t、plain execute() 与 identity-bound 两路共同
    触发、生产 public init(L348)全 no-op 仅 package init(L355)可装,非
    identity-bound,不满足 design §1。以既有回调在 HDC 层合成(pid→argv
    关联)在并发下不可靠,且与「同一 hook 内判族+验 permit」冲突,不采。
    落点 = startPreparedIdentityBound(L621-658)spawn 成功返回点新增
    package 级回调,签名至少含 ProcessExecutableIdentityReceipt、argv 或
    ProcessRequest、pid_t 三元;public API 与 plain execute() 语义零变更。
    (b) opaque confirmed/managed permit:scope 内可实现,permit 本身不动
    ArkDeckProcess。铸造点沿既有链:confirmed = durable confirmation +
    当前 dispatch lease 同回合(lease 仅 dispatchValidated 铸造、
    consumeDispatchLease L1645 原子消费);managed = absent-endpoint
    authorization(authorizeManagedStart L1354)+ 留存 managed-launch
    evidence(recordManagedStart L1362,五重活体核验)。opaque 形态沿
    ProcessAtomicLaunchGate 的 class-identity/引用同一性先例,值伪造不可;
    permit 随 prepare 产物入 runner,在 (a) hook 内核验。
    (c) caller 无 origin 输入:main 现状已干净——全 Sources 无任何 spawn
    相邻 origin enum/string/flag(r1 的 caller-supplied origin 只存在于已
    作废的 #265,从未进 main);HDCServerEndpointSource 是 endpoint 出处,
    与 dispatch origin 无关。工作量在守住:monitor 记录口非 public/package,
    仅 hook 闭包持有写入口(C6 钉)。
    (d) fake-process mutation seam:scope 内可实现,先例齐备——package init
    装 hook + runner executor 注入(HDCSupervisorContractTests
    L2832-2836)、fixture 可执行 + ARKDECK_FAKE_HDC_INVOCATION_LOG 调用
    日志、fault seam 先例 ProcessIdentityBoundLaunchFault(L269)。seam
    形态 = permit 铸造与 hook 核验之间的 package 级注入点,默认无效果。
  - **Prerequisite 4(可执行验证计划):closed = 本段验证计划附录(25 条
    inline 于本 readiness,不外置文件;先例 = CHG-2026-024 r1 的 inline
    实现契约形态)。**
  - **Prerequisite 5(交集/环境/基线):closed(全部起草时实测)。**
    - open PR 交集:起草时 open PR == 0(gh 实测);远端 agent/* 仅
      agent/chg-2026-040-r2(已归档 change 的遗留残枝,零交集)。起草期间
      #673(chg-2026-008 tasks.md,即主副本并行会话的预期面)与 #674/#675
      (chg-2026-041)合入,#676(chg-2026-025 evidence)与 #677
      (chg-2026-041)开启在飞——以上与本 PR 文件集及本任务实现面全部零
      交集(gh + git diff 实测)。实现开工时须以当时在飞集合重测。
    - rebase 注记:因上述合入,载体已 rebase 到
      `fd478664f5e3dc079b10ccd5c0c7bf31b8f83cae`(#675 merge)。audit base
      → 该 OID 区间仅 5 个 chg-2026-008/041 openspec 文件,Packages 构建
      输入零漂移(git diff --name-only 实测);prerequisite 2 全部 blob pin
      已在该 OID 逐项 ls-tree 复核同值,Swift/check-sdd 基线可迁移。
    - 环境:独立 worktree ~/wt-obs-readiness(非 /private/tmp;CHG-2026-024
      r2 教训:/private/tmp 检出内契约测试红绿不可作结论),Apple Swift
      6.3.3(arm64-apple-macosx26.0),树 = audit base。
    - Swift 全量(本 worktree 实测):Executed 413 tests, with 1 test
      skipped and 0 failures,exit 0;汇总行取自完整输出文件、不经管道截断
      (AIN-004 r3 方法学注记沿用)。回归底线:实现后 = 413 + 新增 /
      1 skipped / 0 failures,且既有用例零修改。
    - ./scripts/check-sdd.sh(本 worktree 实测):0 error / 0 warning /
      111 acceptance IDs,exit 0(本 change 四 AC 为 change-local,不进
      canonical 计数)。
    - guard 解析(实测):check_pr_paths.extract_allowed_patterns 于 audit
      base 树对本任务恰得四 glob,全仓 45 个 active 任务解析零异常;本
      readiness 载体(标题声明本任务、文件集 = 仅本文件)本地模拟判定 PASS。
  - **r1 三 Blocker 对应闭合**:Blocker FANOUT → prerequisite 1;Blocker
    COUNTER → 偏差 1/5 裁定 + 附录 A 组;Blocker OWNERSHIP → 偏差 2/6 裁定
    + 附录 B 组。闭合以实现 + evidence 落地为准,本 readiness 只钉契约。
  - **design §1 偏差裁定(7 项;逐项 = 实现边界内处置 + 二值验收;实现中
    任何一项被证实需越出本段边界即触发 stop gate,停手回 readiness,不得
    硬翻):**
    1. **hook 缺失(r1 Blocker COUNTER 在 main 的残余)**:design §1 以陈述
       语气写的 identity-bound 成功 spawn hook 不存在(prerequisite 3a)。
       处置 = 按 3a 落点新增,ArkDeckProcess.swift 显式列入文件级范围,计数
       写入口仅 hook 闭包持有。验收 = C1/C2/C3/C7(同一 hook 真实 spawn
       计数,调用日志逐次 +1)+ C5(pre-spawn 失败零计数)+ C6(public
       init 零 hook 形参、monitor 零 public/package 写入口)。
    2. **managed claim 被静默覆盖,reconcile/retire 不存在**:
       observeUnidentifiedServer(ArkDeckOpenHarmony.swift L1282)与
       observeRegisteredServerIdentity(L1312)无条件以 .unknown 覆盖既有
       .arkDeckManaged、不重跑 managedProcessInspector、覆盖后状态无残留,
       recordManagedStart 亦不留可查询 provenance——证据④所需「active or
       unreconciled」现无任何表示。处置 = 新增留存 managed provenance 与
       显式 reconcile/retire 记录;两条观察路径改为「evidence 实时重验有效
       → 保持 .arkDeckManaged;否则降 .unknown 并留 unreconciled 标记」
       (design §1 明文行为,非新增语义)。与「既有测试零修改」不冲突:
       base 实测 Tests 零处调用这两条路径、零处钉旧覆盖行为。验收 = O5 +
       O6 矩阵 M1-M6(M5 钉「失忆≠出清」,M6 钉本偏差修复方向)+ O8。
    3. **ownership 已参与 scopeHash 与 lease 重验,非纯展示**:
       ownership.rawValue 编入 HDCServerImpactCanonicalScope(L744-767),
       consumeDispatchLease/lifecycleStateStillMatches 比较 expectedOwnership
       (L1656/L1776);unknown→external 判定落地会使在途 preview/
       confirmation/lease 经既有 stale-scope 路径失效(fail-closed 方向)。
       裁定 = 不改 scopeHash 编成与 lease 比较(改之才是门语义变更);
       design §0「判定升级仅改变标签与证据展示」按本条收窄:门等价 =
       external/unknown 两值对称,不承诺「判定翻转对在途 scope 不可见」;
       in-flight scope 因判定升级而 stale 属既有 fail-closed 行为。验收 =
       O7 双臂等价 diff(每臂全程固定 ownership;逐步骤 gate 结果相等;
       显式断言允许且仅允许 ownership 字面与 scopeHash 两处差异)+ 既有门
       测试零修改腿(evidence 以 diff 范围断言背书)。
    4. **endpoint source 真值在 Session 组合边界被丢弃**:facade
       attachSessionIfConfigured(HDCApplicationDiagnosticsFacade.swift
       L115-128)只把 endpoint.rawValue 装入 snapshot,compose
       (HDCServerLifecycleJournalAdapter.swift L1871)以
       select(explicitEndpoint:) 重导出恒 .explicit——Session 侧直读组合
       结果则展示面恒显 explicit,即造假展示。处置 = 把原始 selection 或其
       source 穿透 snapshot 与组合(两文件均在 scope 内)。验收 = E1(三态
       如实)+ E4(default/inherited 经组合不得翻成 explicit)+ E2(child-
       env 注入清单精确键集合)+ E3(父 env 零修改,既有断言零修改沿用)。
    5. **sealed 分类器无 subserver 族(二选一,本 readiness 裁定)**:
       HDCRegisteredCommandFamily 无 subserver case,spawn-sub/killall-sub
       现分类 .unregistered,prepare 守门(HDCProduction.swift L434)对
       unregistered+nil binding 放行 spawn。裁定 = **建族且配 nil-stdout
       binding(与 lifecycle 族同构)**:保持 prepare 对该 argv 的放行结论
       与今天一致,hook 可达、变异实验对 subserver 计数为真;弃「建族不配
       binding」,因其使 prepare 直接 throw、hook 永不可达、计数器空转常真。
       semantic 面保持 fail-closed;registry subserverCapability =
       unsupported/invocationAllowed false 的注册面事实不动(invariant pin
       背书);生产 caller 保持零。验收 = C3(subserver 计数 0→1 经真实
       spawn)+ C4(计数是测量值非分支常量)+ C5。
    6. **.external 生产铸造路径为零 + 内部注入面宽**:生产观察路径一律铸
       .unknown、managed 只经 recordManagedStart;HDCExistingServerObservation
       precondition(L418-425)仅挡 .arkDeckManaged,模块内可注入 .external
       ——base 实测既有契约测试大量经该 internal seam 注入 .external(约
       19 处,多为授权门测试)。裁定 = 四证据判定成为生产组合内唯一
       .external 铸造路径;internal 注入 seam 如实保留为既有测试 seam(将
       其完全 permit 化会击碎上述既有门测试,与零修改腿直接冲突,不采),
       但不得新增任何 public/package 级 ownership 注入面。验收 = C6 扩展
       源面扫描(Sources 内 .external 构造点精确集合 == 四证据判定落点与
       --ui-test-hdc-diagnostics fixture 落点(Facade L296/L318)两处)+
       O1-O4(四证据齐才 external,任一缺失不判)+ O6(bracket 自身不得
       完成 managed→external)。
    7. **FANOUT 生产源前提**:r1 Blocker FANOUT 已由 prerequisite 1 闭合;
       但 base 上 Sources 仍零 producer/consumer(automaticLifecycle*/
       automaticSubserver* 计数器、设备事件类型、环形缓冲全仓零命中,
       实测)。处置 = 本任务实现消费面(diff/broadcast/presentation 有界
       环形缓冲)与生产源腿,生产源只允许绑定 registered family(exactArgv/
       endpoint policy/identity bracket/presenceRule/observedEmpty 语义逐项
       遵守);设备观察 recipient 走独立注册面,不进 lifecycle critical-
       participant/impact scope。验收 = F1-F5(F1 presence 语义按 registered
       presenceRule;F3 族缺席必须 FAIL 而非 skip;F5 test-only 源进生产
       组合必须被拒)。
  - **实现边界(文件级;机械 guard 面不变)**:活声明保持四 glob 原样,
    本 PR 仅在其括注做条款层显式化,不放宽、不增行。实现预期文件集(超出
    即触发 stop gate):Sources 六文件 = ArkDeckProcess.swift(唯一跨
    target 例外,新增 package 级 identity-bound 成功回调与 init 扩展)、
    HDCProduction.swift、ArkDeckOpenHarmony.swift、
    HDCReadOnlyProbeRegistry.swift(仅如需扩收据/basis 暴露)、
    HDCServerLifecycleJournalAdapter.swift、
    HDCApplicationDiagnosticsFacade.swift;Tests = ArkDeckContractTests 新
    契约文件或既有文件仅新增用例、ArkDeckFakeHDCFixture/main.swift 新增
    subserver mode;外加本 change evidence 与本文件(仅本任务状态)。
  - **ArkDeckProcess.swift 单列风险**:该 target 仅此一文件,
    startPreparedIdentityBound 为 HDC、Rockchip flash、discovery 全部
    identity-bound 生产 spawn 的共用路径。缓解 = 仅新增 package 级回调存储
    属性、package init 形参与成功点一处调用,public init/公共 API/plain
    execute() 语义零变更;以全量既有测试零回归 + C5/C6 背书。
  - **stop gate**:实现若需上述清单之外文件(含 Packages/ArkDeckKit/
    Package.swift、Core/specs/contracts/baselines、App/xcodeproj),停手、
    先以独立治理 PR 修订本任务 scope,不得静默扩展(CHG-2026-024 r2 先例)。
    预判:新契约测试文件落既有 target 目录、fixture 只改既有 main.swift,
    均不需 Package.swift。
  - **验证计划附录(25 条;全部可直译 XCTest、断言二值;A/B/C/D 组对应
    OBS-COUNTER/OWNERSHIP/ENDPOINT/FANOUT 四 AC;fake 进程一律经
    Tests/ArkDeckFakeHDCFixture 的 .build/debug 定位形态 +
    ARKDECK_FAKE_HDC_INVOCATION_LOG 调用日志;语义档 = testOnlyFake;
    hook/permit/seam = prerequisite 3 的 (a)/(b)/(d)):**
    - A 组(8 条,TEST-OBS-COUNTER-001):
      - C1 完整确认链 + 完好 permit 对 fixture 真实 dispatch(lifecycle
        restart 族):调用日志恰 +1;automatic lifecycle 与 subserver 计数
        均 == 0;confirmed 独立计数/审计 == 1。
      - C2 与 C1 同链同 argv,seam 在 permit 铸造后、spawn 前移除 permit:
        同一 hook 真实 spawn(日志 +1);automatic lifecycle 0→1;
        subserver 仍 0;未变异对照恒 0。
      - C3 sealed subserver 族 argv(偏差 5 裁定的族+binding;fixture 增
        对应 mode)经同一 runner+hook,seam 移除 permit:subserver 计数
        0→1;lifecycle 计数不动;日志 +1。
      - C4 反套套逻辑核:连续两次 C2 形态变异后计数恰 == 2(非「非零即 1」
        分支常量);无 spawn 的 presentation 刷新三次计数不变;计数差 ==
        调用日志行数差(逐值相等)。
      - C5 pre-spawn 失败不计数:(i) prepare 期 hash 不匹配;(ii) launch
        window 后 ProcessAtomicLaunchGate invalidation 赢在 posix_spawn 前
        (复用既有模式)。两情形日志 +0、两计数不变;(ii) 保持既有
        outcomeUnknown 文案(零回归)。
      - C6 声明面/源面扫描(二值;复用既有 #filePath 源扫描先例):spawn
        相邻 API 与 monitor 类型零 origin 语义形参;monitor 记录口非
        public/package;FoundationProcessExecutor public init 零 hook 形参;
        Sources 内 .external 构造点精确集合 == 偏差 6 所列两处。
      - C7 managed permit 阳性对照:authorizeManagedStart(endpoint 缺席)
        铸 permit → fixture managed-server mode 经同一 hook spawn →
        recordManagedStart 以真实 PID/argv/监听证据登记:日志 +1;两
        automatic 计数均 0;ownership == .arkDeckManaged。
      - C8 presentation 镜像:C2 后 refresh,presentation 的 autoLifecycle/
        autoSubserver 字段值 == monitor 快照值(逐值);confirmed/managed
        独立计数不被相减、不被改名 automatic(字段名+值双断言)。
    - B 组(8 条,TEST-OBS-OWNERSHIP-001;四证据 = ①pre-existing receipt、
      ②本会话 automatic lifecycle 计数 == 0、③generation 铸自观察收据、
      ④无 active/unreconciled managed provenance):
      - O1 四证据齐 → .external,basis 逐项 present(4 个二值断言)。
      - O2 before 收据 unavailable → 不 spawn checkserver(日志 +0,既有
        前置语义保持)、ownership 保持 .unknown。
      - O3 先经 C2 变异使计数 == 1,再走 O1 合格观察 → .unknown,basis
        证据② absent、其余 present。
      - O4 generation 来自 lifecycle succeeded 路径而非观察铸造 →
        .unknown,basis 证据③ absent。
      - O5 C7 建立活体 managed claim 后合格 bracket 观察 → .arkDeckManaged
        (非 unknown、非 external),basis 证据④ absent 且 managed evidence
        live == true。
      - O6 managed→external 禁止矩阵(6 行逐行独立断言):M1 active +
        evidence 实时有效 + 合格观察 → .arkDeckManaged;M2 active +
        evidence 已失效(杀 fixture server 进程)+ 无 reconcile 记录 →
        .unknown;M3 已写 reconcile,同一观察周期 bracket → .unknown
        (bracket 自身不得完成 managed→external);M4 reconcile/retire 后
        独立新 pre-existing 观察 + 其余三证据 → .external(唯一放行行,
        阳性对照);M5 unreconciled(claim 曾被覆盖、无记录)→ .unknown
        (失忆≠出清);M6 active claim 遇 observeUnidentifiedServer → 不得
        external,evidence 仍 live 时保持 .arkDeckManaged(同钉偏差 2)。
      - O7 external/unknown 门等价 diff(偏差 3):两臂逐字段同状态、仅
        ownership 异;依次 createImpactPreview restart/confirm/dispatch/
        startManaged preview/critical-job 阻断/consumeDispatchLease 失效;
        每步 gate 结果逐一相等;显式断言仅 ownership 字面与 scopeHash 两处
        不同。第二条腿 = 既有全量 lifecycle/supervisor 契约测试零修改通过。
      - O8 basis 暴露为逐证据二值(4 项独立可读,与注入矩阵逐格相等),
        不得聚合成单布尔。
    - C 组(4 条,TEST-OBS-ENDPOINT-001):
      - E1 explicit/inherited 即 OHOS_HDC_SERVER_PORT/default 三组 selection
        → presentation source 三态逐一如实。
      - E2 child-env 注入清单 ==(排序后)ARKDECK_FAKE_HDC_INVOCATION_LOG
        与 OHOS_HDC_SERVER_PORT 两键精确集合(只含键);键冲突时 selection
        值胜出(既有 merge 语义,值断言一次)。
      - E3 全流程前后 ProcessInfo 环境快照逐键相等;既有 child-only overlay
        契约断言零修改保持绿。
      - E4 default/inherited 来源经 facade→compose 组合后 presentation
        source 仍为原值,不得被重导出翻成 explicit(钉偏差 4)。
    - D 组(5 条,TEST-OBS-FANOUT-001;生产源语义以 prerequisite 1 的
      registered family 为唯一输入):
      - F1 typed snapshot 序列 A,B → B,C → 成功空 → failure/unknown:事件
        序列逐条 == appeared/unchanged/disappeared 期望;成功空
        (observedEmpty 两形态)= 全消失且状态「空且已知」;failure/unknown
        不产生 disappearance、缓冲追加 unknown 标记(空 ≠ unknown 双向);
        presence 判定遵 registered presenceRule(state 列,非行存在性)。
      - F2 容量 N 缓冲推 N+K 条:len == N、内容 == 最新 N 条且序稳定
        (逐条相等),无丢弃引发的重排/合并。
      - F3 完整 fan-out 组合对 fixture 运行:调用日志 argv 全部属于已注册
        exact argv 集;zero-to-many 族存在性与 registered family 绑定,族
        缺席时本测试必须 FAIL 而非 skip。
      - F4 设备观察 recipient 与 lifecycle impact 分离:impact snapshot 的
        affectedDeviceCoordinators/affectedJobs/criticalJobs 不含设备消费者
        (集合精确等于仅 lifecycle 参与者);设备消费者收设备事件、收不到
        lifecycle 广播(双向)。
      - F5 test-only snapshot 源接生产组合入口 → 拒绝(fail-closed 二值
        可判);仅 integration 源标记可进生产差分路径。
  - **反作弊红线(任一出现即整体 fail)**:直接调用 monitor record;构造
    origin 枚举/字符串/flag;仅断言类型存在;把 confirmed/managed 计数相减
    冒充 automatic;以 skip/vacuous-pass 处理缺席的 zero-to-many 族;生产
    路径 fixture 注入。
  - **本 r2 不声称**:任何 AC PASS(待实现 + evidence run 后逐条判定);
    OBS-002/M0B-002/macOS conformance 的任何进展;Decision-Grade 变更
    (维护者亲笔);把 F 组局部绿当作 OBS-FANOUT-001 整体 PASS 的许可。
- Objective:supervisor 自动 lifecycle/subserver dispatch 计数器(成功 spawn 唯一
  hook + opaque permit + 变异可证伪)、ownership `.external` 判定(design §1 四证据)、
  endpoint source 与 child-env 注入清单暴露、只读设备 fan-out feed(有界环形
  缓冲);presentation 全量透出;contract 测试全绿。
- Requirements/AC:change-local `OBS-COUNTER-001`/`OBS-OWNERSHIP-001`/
  `OBS-ENDPOINT-001`/`OBS-FANOUT-001`(见 acceptance-cases.yaml;canonical Core
  AC 零认领——本 change 不改 Core 面)。
- Depends on:approve;M1-006 done(已满足);上述 integration producer
  (CHG-2026-024 done+verified,#665/#666,已满足)与 r2 unblock
  prerequisites(已由本 Readiness r2 逐条核验闭合)。
- In scope:`Packages/ArkDeckKit/Sources/**`(OpenHarmony/Workflows 可观察性面;
  r2 readiness 显式扩含 ArkDeckProcess.swift 的 identity-bound 成功 spawn 回调
  新增)、对应 Tests、本 change `evidence/**`、本 change `tasks.md`(仅本任务
  状态)。
- Out of scope:任何 lifecycle/dispatch/安全门语义变更;App UI(OBS-002);Core
  contract/schema;M1-009 导出接线。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/**`(OpenHarmony/Workflows 可观察性面;含 r2
    readiness 显式列入的 ArkDeckProcess.swift identity-bound 成功 spawn 回调
    新增——机械 glob 本就覆盖该文件,此括注为条款层显式化,文件级边界见
    Readiness r2 实现边界段)
  - `Packages/ArkDeckKit/Tests/**`(对应 Tests)
  - 本 change `evidence/**`
  - 本 change `tasks.md`(仅本任务状态)
- Risk:medium(触碰 supervisor 生产文件;不变量 = 零语义变更,须既有全量测试
  零回归 + 新增门语义 diff 测试背书)。
- Hardware required:no。
- Decision-Grade:D1。
- Verification:四 change-local AC contract 测试逐条 PASS(成功 spawn 计数器
  变异实验、ownership 四证据/managed provenance 矩阵、endpoint source/child-env、
  production-source fan-out 差分);全量基线零
  回归;check-sdd 绿。
- Evidence gate:实现 + evidence run 合入且全部 AC 可判定后,`ready→done` 独立
  状态 PR。

## TASK-OBS-002 — App 观察面与 signed XCUITest

- Status:blocked(三前置:① r2 remediation merged;② TASK-OBS-001 done;③ 独立 readiness
  PR——须钉 OBS-001 交付 hash 与 XCUITest 环境(DevMode/repo 根硬链)复核)
- Objective:HDCStatusView 新增计数/endpoint source/ownership 依据/设备事件列表
  字段(static-text 可访问 id,design §2),signed XCUITest 覆盖;M0B-002 四观察
  点的 App 取证载体就位(design §3 映射)。
- Requirements/AC:change-local `OBS-APPFACE-001`(见 acceptance-cases.yaml)。
- Depends on:approve、TASK-OBS-001 done。
- In scope:`ArkDeckApp/**`、`ArkDeckAppUITests/**`、本 change `evidence/**`、
  本 change `tasks.md`(仅本任务状态)。
- Out of scope:Kit 语义(OBS-001 已定);诊断导出接线;真机观察执行。
- Allowed paths:
  - `ArkDeckApp/**`
  - `ArkDeckAppUITests/**`
  - 本 change `evidence/**`
  - 本 change `tasks.md`(仅本任务状态)
- Risk:low-medium(UI 面;XCUITest 环境依赖如实记录)。
- Hardware required:no(XCUITest 用 fixture 门;真机观察属 M0B-002)。
- Decision-Grade:D1。
- Verification:`OBS-APPFACE-001` XCUITest PASS(新字段存在+值形态+可访问性)、
  生产路径零 fixture 断言、全量零回归。
- Evidence gate:同 OBS-001 形态;done 后 TASK-M0B-002 具备新 readiness 条件。
