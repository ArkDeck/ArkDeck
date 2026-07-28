# CHG-2026-022 Tasks

> 现为三任务分期,各自独立 readiness/实现/done PR。r1 首 PR 只 proposal +
> design；r3 同样只做 governance remediation，零实现、零真机、零 evidence。
> 全程 host-only;真机观察本身属 TASK-M0B-002(本 change done 后经新
> readiness 解锁)。

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

## TASK-OBS-001R — Kit App-facing fan-out remediation

- Status:ready(fresh D1 readiness candidate；仅在维护者对本独立 readiness PR
  exact head review/merge 后生效。生效后一次性授权一个标题声明本任务的独立
  implementation/evidence PR，且只能修改本段 Allowed paths、实现下述 exact
  contract。readiness merge 不产生 AC evidence、不翻 done、不恢复 OBS-002
  readiness；exact head 未 merge 前仍按 blocked、零 implementation。)
- Historical Status:blocked(r3 governance 经 PR #704 merge
  `02907b69b8fd7d1347ba26822e4a1961415fbc16` 生效；其只登记 remediation
  scope，明文要求本 fresh D1 readiness。)
- Origin:PR #700/TASK-OBS-002 blocked-readiness(merge
  `14fd6fede8707a46a1510ad6d7b419b76e6e2bc1`)证明 OBS-001 已交付的 device
  fan-out 仍为 OpenHarmony internal，production Workflows facade 零 composition
  owner/poll/cancel，public presentation 零 timestamped device events。App-only
  OBS-002 无法越 package boundary 补齐，故采用该记录的 remediation 方案 (a)，
  新增独立 Kit-only predecessor；不重开或重判已 done 的 TASK-OBS-001。
- Readiness(fresh D1；audit base = protected main
  `14b46e3066c52f54568e97545c59b3506ffc62a4`,2026-07-28):
  - **Approval/dependency gate:satisfied。**r3 exact head
    `7a5da66fdf4e1cf09018a538312523899dacdeba` 经维护者 `lvye` APPROVED，
    PR #704 由同一维护者 merge 为
    `02907b69b8fd7d1347ba26822e4a1961415fbc16`，该 merge 为上述 audit base
    ancestor；TASK-OBS-001 implementation #687 merge
    `ca84cc2821e11ad691cb9d8dcdef4e2dc873d1d3` 与 done #693 merge
    `d8287aa5558f295caa086bb5a90516b6e9892fc8` 均实测为 ancestor。PR #700
    blocker merge `14fd6fede8707a46a1510ad6d7b419b76e6e2bc1` 同为 ancestor。
  - **Drift/concurrency gate:satisfied。**PR #700 的 source audit base
    `e114d9d3ae668bff68d2cfb69c59fa6f4dff00ec` 到本 audit base，三个目标
    production source、既有 OBS-001 contract 与 `Package.swift` 的 diff 均为空，
    故 #700 blocker 仍逐项成立且无未裁定代码漂移。起草末端 #705/#706
    合入后只触碰 CHG-2026-042/025，rebase audit 对本 change、Packages 与
    integration registry 的 diff 仍为空；重基前后 open PR 均为 0。
    开工前须再次 fetch protected main、复核 pins 与 open-PR 文件交集，任一漂移
    立即停回 readiness。
  - **Exact base pins(完整 Git blob OID + file SHA-256；实现开工逐项复核，
    invariant 必须逐字节不变):**

    | File | Git blob OID / state | File SHA-256 | 性质 |
    | --- | --- | --- | --- |
    | `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/ArkDeckOpenHarmony.swift` | `0d91c7d306d45909b8632f0a98ab13218c23c9cb` | `0de8ebbdc862b9394f4d1fd133d6849a4cfc0d844f9d192a2fa144f6219d8838` | 待改：internal event → package bridge/buffer |
    | `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCProduction.swift` | `e417f8ce1d0334455e6c6a3d4b9b5720cc33e195` | `6df378121d5f4f4f87f90b67dd6f1ad9831b81586e331de3e04d4ab894093acd` | 待改：public projection + exact production factory |
    | `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift` | `df1bc2a030bbb924274377fff309ead944576698` | `3d6b08ca1744fe91ba0399e0a3eb7b0d44ec7be002beb48eddf71db5d42adf84` | 待改：production owner/refresh/reset + fixture |
    | `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationPresentationContractTests.swift` | absent at audit base | absent | 只允许新增 |
    | `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCSupervisorObservabilityContractTests.swift` | `3877c216fb985109f7bccefc1532b6a011143ac5` | `79ee77d04c67ef68ec097039625d2a7ce2314400160b20c39aa11a6e31653f8b` | invariant；既有 25 tests 零修改 |
    | `Packages/ArkDeckKit/Sources/ArkDeckProcess/ArkDeckProcess.swift` | `d68939a5446a7026db7607086b58ba700d642701` | `fa47356760ff18cf0cfca943c8c1615b52daae9759879711ae0549ee23c379c9` | invariant；owned-child cancellation 机制 |
    | `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCServerLifecycleJournalAdapter.swift` | `9f8de3c6a707b1506df9e3c760ab359a80e22ed9` | `d1d9ebfdf99842bd305ef63373215f2416a872c3fcd7ed85c5810927d6f8ff01` | invariant；不改 lifecycle host |
    | `Packages/ArkDeckKit/Package.swift` | `292135a2c80c63ddf7182f58e2f81ff7c7d6104d` | `be071dcfc5ad717120332d09bb2774fcd93143486a9e4bd8de32ee2a2c436ec7` | invariant；test target 自动纳入新文件 |
    | `openspec/integrations/openharmony/device-observation-probes.yaml` | `399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6a` | `79814e45901ab7e4d9f9a271645cad62b0053a50534cba884cdff0c2e50b9d49` | invariant；registry 不修改 |
    | 本 change `proposal.md` | `10797acb07d650a3075f509074e12b198ff5baa6` | `8684b99a4af56b939b405a521d897e0b971827d85049173071b219eefdc3220b` | invariant |
    | 本 change `design.md` | `ffb1fb636c3c419eda0cbcaf063215e0d4928ed1` | `392727d825cba5b3cd265af8ed2d0a3977fb00f4ef874da1d85e5c7fca489d59` | invariant |
    | 本 change `verification.md` | `e5c4d79c3a25b45d467ec3fb4c390bffc98bb740` | `f35b7ddff0b0aaa0050a6c0ed69bac4f19ce6eeeae1bfc2100840e6a2ce67ffb` | invariant |
    | 本 change `acceptance-cases.yaml` | `f8f4d913f8e9ccd9acfcff9a75225778a5750c11` | `cc336e77476cdf153d67cd65e4d6676bae90ece1993c461e944e8ace1a564b71` | invariant |
    | TASK-OBS-001 `evidence/runs/TASK-OBS-001/run.md` | `4148b50a8d5ef6614058fdf24972d3d921f01de0` | `15eddd72a2725d610301121ef9715703e9391134cb5351ee493f4717d0ce4063` | invariant；只作前置交付证据 |
    | 本 change `tasks.md`(本 PR 改前) | `ea4a5348b8a7fd5749703ea6e8ef0fc51c4acd3d` | `bc73ca9496685404980be9419eac36504046b5d7b2fe807ced0e0797867f31cf` | 本 readiness 唯一载体 |

  - **Public shape pin(实现不得另做产品决策):**
    `HDCDeviceObservationPresentationKind` 为 public closed raw-string enum，
    exact cases = `appeared`/`disappeared`/`observationUnknown`/
    `observationUnavailable`；`HDCDeviceObservationPresentationEvent` 为 public
    immutable `Sendable,Equatable` value，exact readable fields =
    `timestamp:String`、`kind`、`redactedDeviceIdentifier:String?`，构造器仅
    package。`HDCDiagnosticsPresentation` 新增 public immutable
    `deviceEvents:[HDCDeviceObservationPresentationEvent]`，public initializer
    参数默认 `[]`，全部既有 caller source-compatible；App 得到只读值，不能构造
    source/composition/HMAC key。
  - **Timestamp/identity pin:**bridge 注入 `@Sendable () -> Date` clock；每个被
    接受的 public event 在 ingest 时以 UTC、Internet date-time + fractional
    seconds 格式化为 RFC 3339，fixture 用固定 Date，不接受 caller-supplied 已格式化
    字符串冒充 clock。`.unchanged` 不调用 clock、不追加 public history。
    appeared/disappeared 只接受 exact
    `redacted-device-[0-9a-f]{24}`；任何不合形 identifier fail closed 为
    `observationUnknown` + nil identifier，raw 字节不得进入 public value/error/log。
    unknown/unavailable 同样 nil identifier，reason 保留 internal、不进 public。
  - **Production composition pin:**在 `HDCProduction.swift` 内新增 package-only
    application session/factory，production factory **不接受 source/runner/argv
    注入**；它先校验 candidate SHA-256 ==
    `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`
    且 endpoint == `127.0.0.1:8710`，不匹配则每次显式 refresh 只追加一条
    unavailable、child dispatch = 0。匹配时由该文件内部唯一构造
    `HDCRegisteredDeviceObservationSource` + `HDCDeviceObservationComposition`
    (capacity 64)；source 继续执行 registry exact `list targets -v` 与 stable
    pre/post identity bracket，拥有单一随机 session HMAC key。contract-only mapper/
    source seam 可以 package/internal 存在，但 production factory 与 Workflows
    production 路径不得引用它。
  - **Refresh/overlap/cancel pin:**Workflows production actor 为当前
    `(candidate canonical identity,endpoint,execution session identity)` 持有唯一
    observation session；既有显式 `refresh()` 每次最多调用其一次，再用 package-only
    copy/overlay helper 把完整 0...64 events 放进同一 base presentation。session
    actor 在 await 前设置 in-flight gate；并发 refresh 只 coalesce/返回当前 buffer，
    绝不启动第二 child、排队自动 retry 或新增 timer。Task cancellation 沿既有
    `FoundationProcessExecutor` cancellation handler 只 SIGTERM ArkDeck-owned
    observation process group，结果映射 unavailable；HDC server、lifecycle/
    subserver/device mutation dispatch = 0。user-selected executable、candidate/
    endpoint/execution identity 变化或 bootstrap failure 均先丢弃旧 session、
    buffer 与 HMAC key。
  - **Fixture pin:**`HDCApplicationDiagnosticsFacade.make` 只有包含 exact
    `--ui-test-hdc-diagnostics` 才选择 fixture provider；fixture 经同一 public
    presentation type 固定给两条 ordered events：
    `2026-07-28T00:00:00.000Z appeared redacted-device-0123456789abcdef01234567`
    与
    `2026-07-28T00:00:01.000Z disappeared redacted-device-0123456789abcdef01234567`。
    无 flag 的 production provider/source 不含这些值；fixture 仍无 process/
    lifecycle/device capability，不能作为真实设备或 M0B-002 evidence。
  - **Scope feasibility:closed。**base 实树已验证：
    (a) internal snapshot/event/fan-out/composition 与 capacity-64 production
    constructor 位于 `ArkDeckOpenHarmony.swift` L2128-2279，可在同文件加 mapper/
    package wrapper而不开放 raw 类型；
    (b) registry constants、raw parser、source/runner/identity observer 同位于
    `HDCProduction.swift` L2168-2324，故 exact production factory 不需要暴露或
    修改 Process/lifecycle adapter；当前 source 只查 family+endpoint，**尚未查
    registered target SHA**，该缺口只能在新 production factory dispatch 前修复，
    不得直接收紧 source 从而破坏 OBS-001 F3 fixture；
    (c) public presentation 的 additive-default init 位于同文件 L1746-1866；
    (d) Workflows production actor 已持 candidate/endpoint/execution identity，
    refresh/selection/reset 落点在
    `HDCApplicationDiagnosticsFacade.swift` L44-150，fixture 落点 L225-309；
    (e) Process cancellation handler 位于 invariant
    `ArkDeckProcess.swift` L557-578；
    (f) SwiftPM test target 自动收录新增 `.swift`，`Package.swift` 无需修改。
    因此 exact task 可在一个独立 PR 闭环；若实现证伪任一项，stop 回 governance，
    不得触碰额外文件。
  - **Executable verification matrix(18 cases；全部进入唯一新增 test file，
    既有 OBS-001 25 tests 零修改):**
    - DP1 public type exact cases/fields/access：App-facing fields 可读，raw
      snapshot/source/composition/HMAC 构造能力零暴露。
    - DP2 presentation initializer 默认 events = `[]`；既有
      `.unprobed`/`.loading` 与所有旧 caller 值不变。
    - DP3 appeared/disappeared 各用 injected Date 生成 exact UTC RFC 3339
      fractional timestamp，identifier exact regex。
    - DP4 `.unchanged` 更新 internal presence 但 public count/clock-call count
      均 +0。
    - DP5 unknown/unavailable 各追加一条、identifier nil、internal reason 不出
      public value。
    - DP6 malformed/non-redacted identifier 输入不泄漏，转 unknown + nil。
    - DP7 public capacity 输入 64+K 后 count == 64 且等于最新 64、稳定顺序。
    - DP8 wrong candidate SHA：unavailable + child/argv log 0。
    - DP9 wrong endpoint：unavailable + child/argv log 0。
    - DP10 before identity unavailable：unavailable + child/argv log 0。
    - DP11 stable bracket 阳性沿 OBS-001 F3 registered source腿：exact argv
      `list targets -v` 一次，raw connect key 不进入 public event。
    - DP12 post identity drift：exact child 一次但 payload 丢弃，只呈
      unavailable；不产生 appeared/disappeared。
    - DP13 production factory API/source scan：无 source/runner/argv 参数，
      test-only factory/source 不能被 Workflows production 路径引用。
    - DP14 sequential explicit refresh：每次最多一次 poll，typed transitions
      逐次追加并 overlay 到同一 diagnostics presentation。
    - DP15 two concurrent refreshes：in-flight spy 最大值 = 1、observe count = 1，
      无隐式排队第二次/retry。
    - DP16 cancellation：cancelled in-flight source 得 unavailable；owned child
      被终止，server/lifecycle/subserver/device mutation spy 全 0；既有 Process
      cancellation contract 保持绿。
    - DP17 candidate/endpoint/execution session change：旧 buffer 清空；同一 raw
      key 在两个固定 test HMAC key 下 pseudonym 不同，证明不承诺跨 session 关联。
    - DP18 facade flag matrix：exact UITest flag 得两条 pinned fixture；无 flag
      production 路径零 fixture literals/test-only source，且显式 refresh 之外
      poll/timer/retry callsite = 0。
  - **Anti-cheat/fail criteria:**任一 public raw connect key/reason；把
    `.unchanged` 记作新 history；用 caller-supplied timestamp string；hash/
    endpoint/identity mismatch 后 child >0；production 接受 test source/runner/
    argv；并发或 timer/retry 产生第二 poll；cancel 影响 HDC server 或任何 mutation；
    修改 invariant/既有 OBS-001 test/registry/profile；均使
    `OBS-DEVICE-PRESENTATION-001` 整体 FAIL。
  - **Environment/baseline:**Apple Swift 6.3.3
    (`swiftlang-6.3.3.1.3`,arm64-apple-macosx26.0)，Xcode 26.6 (`17F113`)，
    macOS 26.5.2 (`25F84`) arm64。首次 local full run 发现 `.build` 生成物
    `ArkDeckFakeHDCFixture` 单独残留 `com.apple.quarantine`
    (`0082;6a684fbb;ArkDeck;`，其余生成 executable 无该 xattr)，导致 macOS
    SIGKILL fixture 并制造 HDC timeout；该 run 与随后用于定位的 targeted run
    明确 invalidated，不作 baseline。只清除这个 ignored `.build` 文件的 quarantine
    后，手工 `list targets -v` 立即 exit 0；同一源码重跑
    `swift test --filter HDCSupervisorObservabilityContractTests` =
    `Executed 25 tests, with 0 failures`，exit 0。随后 full build+test exit 0，
    再以 `swift test --skip-build` 提取精确汇总 =
    `Executed 442 tests, with 1 test skipped and 0 failures (0 unexpected)`，
    exit 0；重基到上述 exact audit base 后再次 `--skip-build` 得同一汇总
    (50.417 seconds)，exit 0。此本地 xattr 清理零 tracked diff、不触碰产品源码
    或系统级权限配置；CI 必须在 clean runner 独立复验。`./scripts/check-sdd.sh` =
    `0 error(s), 0 warning(s), 111 acceptance IDs`；paths guard 49 单测 PASS，
    readiness 标题声明本任务 + 单文件 `tasks.md` 集合的 base-tree guard 模拟
    PASS(解析 6 个 exact patterns)，`git diff --check` PASS。实现回归底线 =
    442 + DP1-DP18 / 1 skipped / 0 failures，并须在实现开工重测。
- Objective:在既有 production registered device-observation fan-out 与 App-only
  OBS-002 之间补齐最小 Workflows/presentation bridge：公开 immutable、带 injected
  UTC RFC 3339 timestamp 的 typed device events；production facade 持有并在显式
  `refresh()` 中单次驱动 exact registered composition；有界传递到
  `HDCDiagnosticsPresentation`；UITest flag 下提供确定性 fixture 值。
- Requirements/AC:change-local `OBS-DEVICE-PRESENTATION-001`(见
  acceptance-cases.yaml；canonical Core AC 零认领；既有
  `OBS-FANOUT-001` 保持 TASK-OBS-001 已完成结论，不重判)。
- Depends on:r3 approval #704 merge(已满足)；TASK-OBS-001 done(已满足，
  #693 merge `d8287aa5558f295caa086bb5a90516b6e9892fc8`)；本 fresh D1 readiness
  exact head 由维护者 review/merge(待本 PR)。
- In scope:
  `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/ArkDeckOpenHarmony.swift`
  (internal event 到 typed presentation 的最小桥接与 bounded buffer)；
  `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCProduction.swift`
  (`HDCDiagnosticsPresentation` public immutable event surface 与 registered
  source/composition factory 所需最小接线)；
  `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift`
  (production composition owner、显式 refresh/cancel/session invalidation 与
  UITest fixture)；新增
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationPresentationContractTests.swift`；
  本 change `evidence/runs/TASK-OBS-001R/**`；本 change `tasks.md`(仅本任务状态/
  pins/evidence)。
- Out of scope:`ArkDeckApp/**`/`ArkDeckAppUITests/**`(留给 OBS-002)；
  既有 `HDCSupervisorObservabilityContractTests.swift` 与 TASK-OBS-001 evidence
  修改；`Package.swift`；Core/Process/Runtime/Storage；integration/platform
  registry/profile；任何新 HDC argv、timer/background poll/automatic retry；
  lifecycle/subserver/device mutation 与真实设备执行。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/ArkDeckOpenHarmony.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCProduction.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCDeviceObservationPresentationContractTests.swift`
  - 本 change `evidence/runs/TASK-OBS-001R/**`
  - 本 change `tasks.md`(仅本任务状态/pins/evidence)
- Risk:medium(新增 production read-only child 的 composition/lifecycle 接线，但
  exact registry + stable identity bracket + 只读 effect + fail-closed 负向矩阵
  保持边界)。
- Hardware required:no(contract/fake only；fixture/host 测试不得记为真实设备
  evidence)。
- Decision-Grade:D1。
- Verification:`OBS-DEVICE-PRESENTATION-001` contract PASS；新增矩阵全量
  PASS；既有 `HDCSupervisorObservabilityContractTests` 零修改全绿；全量 Swift
  tests + `scripts/check-sdd.sh` 零回归。
- Evidence gate:实现 PR 只做本任务 allowed paths；run.md 记录 exact base/head、
  命令/结果、矩阵逐条 AC 映射、零真实设备/HDC server effect 与偏差；实现 PR
  merged 后再独立 `ready→done` PR。

## TASK-OBS-002 — App 观察面与 signed XCUITest

- Status:blocked(r1 D1 blocked-readiness；前置① r2 remediation merged 与②
  TASK-OBS-001 done 均已满足，但 PR #700 复核出的 OBS-001→App 设备事件投影
  缺口尚未交付。r3 选择新增 TASK-OBS-001R；维护者 merge r3 只登记其 scope，
  OBS-001R done 与本任务其后的 fresh D1 readiness 均合入前，本任务保持
  blocked，零 implementation/evidence。)
- r3 resolution:TASK-OBS-001R 承担 exact Kit bridge，OBS-002 的 App-only
  Allowed paths 不扩张；本任务后续 fresh readiness 必须以 OBS-001R done merge
  为 ancestor，重钉新的 public presentation shape 与 signed XCUITest fixture，
  不得把本 r3 或 PR #700 当作实现授权。
- Readiness review(2026-07-28;protected main
  `e114d9d3ae668bff68d2cfb69c59fa6f4dff00ec`):
  - **Approval/dependency gate:satisfied。**change approval
    `1e4a7c4027ecdd1142ceab2b80f4423eec586d6d`、r2 remediation
    `3147e33c0d4bf0f9f54e6160850a42f370c05cb6`、TASK-OBS-001 r2 readiness
    #678 merge `a8666bddd51b4cb469be6c8cc1f21c421508b12d`、implementation
    #687 merge `ca84cc2821e11ad691cb9d8dcdef4e2dc873d1d3` 与 done #693 merge
    `d8287aa5558f295caa086bb5a90516b6e9892fc8` 均为 audit base ancestor；
    #678/#687/#693 exact head 分别经维护者 `lvye` APPROVED 后 merge。
  - **OBS-001 delivery pins:closed for this audit。**下列 full OID 来自 audit
    base 实树；#687 之后目标 App/UITest 与所列 OBS-001 Sources/Tests 均零
    commit 漂移。后续 remediation/fresh readiness 必须对届时 protected main
    重钉，不能把本 blocked-readiness 当成实现授权：

    ```yaml pins
    - artifact: TASK-OBS-001 implementation merge
      commit: ca84cc2821e11ad691cb9d8dcdef4e2dc873d1d3
    - artifact: TASK-OBS-001 done merge
      commit: d8287aa5558f295caa086bb5a90516b6e9892fc8
    - path: openspec/changes/chg-2026-022-hdc-supervisor-observability/evidence/runs/TASK-OBS-001/run.md
      blob: 4148b50a8d5ef6614058fdf24972d3d921f01de0
      sha256: 15eddd72a2725d610301121ef9715703e9391134cb5351ee493f4717d0ce4063
    - path: Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/ArkDeckOpenHarmony.swift
      blob: 0d91c7d306d45909b8632f0a98ab13218c23c9cb
    - path: Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCProduction.swift
      blob: e417f8ce1d0334455e6c6a3d4b9b5720cc33e195
    - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift
      blob: df1bc2a030bbb924274377fff309ead944576698
    - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCSupervisorObservabilityContractTests.swift
      blob: 3877c216fb985109f7bccefc1532b6a011143ac5
    - path: ArkDeckApp/App/ArkDeckApp.swift
      blob: 1ec424df02550cc9f79780b7a4b61af28d7faf30
    - path: ArkDeckApp/Features/HDC/HDCStatusView.swift
      blob: 23379eb20fafdc79998699738ca0663da0ca921f
    - path: ArkDeckAppUITests/HDC/HDCStatusUITests.swift
      blob: 1118da5c64c0d921884785d8da73c44864224e61
    - path: ArkDeck.xcodeproj/project.pbxproj
      blob: e7943096688728a22f4b940e536a32f3b8eaaf98
    - path: ArkDeck.xcodeproj/xcshareddata/xcschemes/ArkDeck.xcscheme
      blob: 29d0fb995dd3a28ad535569a4cdc4c3964311def
    ```

  - **App-facing contract gate:BLOCKED。**计数四字段、`endpointSource`、
    `childEnvironmentInjectionKeys` 与 `ownershipBasis` 已由 #687 进入 public
    `HDCDiagnosticsPresentation`，可在 App-only scope 内渲染；设备事件则没有
    同等交付面：
    1. `HDCDeviceObservationEvent`/`HDCDeviceObservationFanOut`/
       `HDCDeviceObservationComposition` 均为 `ArkDeckOpenHarmony` internal，
       `HDCDiagnosticsPresentation` 没有 device-events property；
    2. event 只有 appeared/unchanged/disappeared/unknown/unavailable 与脱敏标识，
       没有 design §2 要求的时间戳；
    3. Sources 中 `HDCDeviceObservationComposition` 只有类型定义，
       `ArkDeckWorkflows` production facade 零引用、零 `pollOnce()` 调用；
       production composition 的实例化/轮询/取消边界不存在。全树实际引用只在
       `HDCSupervisorObservabilityContractTests` 的 F3/F5 测试构造；
    4. App package-boundary contract 明确只允许 `ArkDeckCore`/
       `ArkDeckWorkflows` import，故 App 不能绕过 facade 直接消费 internal
       OpenHarmony feed；`--ui-test-hdc-diagnostics` fixture 同样位于当前
       forbidden 的 `Packages/**` 且无设备事件 presentation 值。
  - **Binary conclusion:NOT READY。**只改当前 Allowed paths 的 App/UITest 文件，
    无法取得真实 production device event、无法显示要求的 timestamp，也无法让
    signed XCUITest 对 fixture 值形态作非空断言。App 内伪造事件会违反
    “生产路径零 fixture”与 design §3 的 M0B-002 取证映射；import
    `ArkDeckOpenHarmony` 或修改 `Packages/**` 又超出已批准 TASK-OBS-002 scope。
    这不是 UI 实现 TODO，而是前置交付/scope 缺口。
  - **Required remediation before fresh readiness。**先以独立治理 revision
    明确选择并批准：(a)新增前置 remediation task，或(b)扩展 OBS-002 scope；
    至少须授权 exact Kit paths 并钉定 App-facing typed event projection
    (timestamp + appeared/disappeared + redacted identifier)、production
    source/composition 的实例化与 poll/cancel 生命周期、bounded presentation
    传递、`--ui-test-hdc-diagnostics` 专用 fixture 值，以及 production 零
    fixture/零新增 lifecycle 或 device mutation 的负向测试。该治理门 merge
    前不得起草实现；门 merge 后仍须从届时 protected main 另起 fresh D1
    readiness，重钉文件、风险、测试矩阵与并行 PR。
  - **Signed XCUITest environment:satisfied,但不抵消上述 blocker。**
    `DevToolsSecurity -status`(沙箱外) =
    `Developer mode is currently enabled.`；host = macOS 26.5.2
    (`25F84`) arm64，Xcode 26.6 (`17F113`)，Swift 6.3.3。当前 fake 先以
    `CI=true swift build --package-path Packages/ArkDeckKit --product
    ArkDeckFakeHDCFixture` 成功构建；临时 repo-root hardlink
    `ArkDeckFakeHDCFixture-M1-006` 与 `.build/debug/ArkDeckFakeHDCFixture`
    `cmp` 相同且 inode 同为 `99945963`，signed run 后已删除，工作树无残留。
    默认签名、无 signing override 的
    `xcodebuild -project ArkDeck.xcodeproj -scheme ArkDeck -configuration Debug
    -destination 'platform=macOS,arch=arm64' -derivedDataPath
    /private/tmp/arkdeck-obs-002-readiness.mDrPpR/DerivedData
    -resultBundlePath
    /private/tmp/arkdeck-obs-002-readiness.mDrPpR/ArkDeck.xcresult test`
    = `Executed 9 tests, with 0 failures`/exit 0；`xcresulttool` =
    Passed,total/passed/failed/skipped `9/9/0/0`。App/runner
    `codesign --verify --deep --strict` 均 PASS，均为 `Signature=adhoc`、
    TeamIdentifier not set；App/runner executable SHA-256 分别
    `e73b5bb8b63a8a962c498abf8e67dfb3c3471540d4fb2d343cb010d8d7eadf0a` /
    `dbca722416a30af32c4175711f1a85b39b87ac0b0a54328f658a73eac1ec451e`。
  - **Concurrency/effect boundary。**audit 开始时唯一 open PR #698 只改
    CHG-2026-025 `tasks.md`；其后以
    `51c1d9e9edf38dcbf77638c3e5ea0eb28bc470a8` 合入；首轮 push 后 #699 又只
    archive CHG-2026-041 并以
    `e114d9d3ae668bff68d2cfb69c59fa6f4dff00ec` 合入，导致首轮 agent-pr
    allowed-paths 如实因 base 前进看见反向 archive diff 而失败。本分支已再
    rebase 到 #699 merge；上述全部 pin/blocker 断言复核零漂移，重推前 open
    PR 只剩本 PR #700。本次只做 source/API 审计、host-side fake build 与
    signed local XCUITest；零 installed HDC、零真实设备、零 server
    lifecycle/subserver、零 deviceMutation/destructive、零 credential/权限
    配置变更。本 blocked-readiness PR 只修改当前 `tasks.md` 的 TASK-OBS-002
    段，零 implementation/evidence。
- Objective:HDCStatusView 新增计数/endpoint source/ownership 依据/设备事件列表
  字段(static-text 可访问 id,design §3),signed XCUITest 覆盖;M0B-002 四观察
  点的 App 取证载体就位(design §4 映射)。
- Requirements/AC:change-local `OBS-APPFACE-001`(见 acceptance-cases.yaml)。
- Depends on:approve、TASK-OBS-001 done、TASK-OBS-001R done、其后 fresh D1
  readiness。
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
