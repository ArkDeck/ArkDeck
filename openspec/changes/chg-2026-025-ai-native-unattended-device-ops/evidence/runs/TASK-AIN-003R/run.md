# TASK-AIN-003R run log

## implementation + contract run（2026-07-28,host-only）

### 授权链与环境

- 授权 = 独立 readiness r1(#690,merge
  `0d36375f875fae327f32860d60f0c4727b84a58c`,本任务段 `Status: ready`)的
  一次性实现授权;本 run 逐字落实其钉定的方向 A 与验证计划四条,零重新设计。
- 取证环境:独立非 /private/tmp worktree `~/wt-ain003r-impl`(CHG-2026-024 r2
  教训:/private/tmp 检出内 Swift 契约测试红绿不可作结论;本 run 全部测试结论
  均在该非 /private/tmp 检出得出)。Apple Swift 6.3.3
  (arm64-apple-macosx26.0),Darwin 25.5.0 arm64。
- base = `origin/main` `0d36375f875fae327f32860d60f0c4727b84a58c`(#690 merge,
  即 readiness 载体自身),分支 `agent/chg-2026-025-ain003r-impl`。
- 本 run 不翻转任务 status(`ready→done` 为后续独立状态 PR,Decision-Grade 行
  由维护者亲笔),不触碰 `verification.md`。
- **E2 面声明:本 PR 零 dispatch**——全程零设备命令、零 rkdeveloptool 调用、
  零真机接触;测试进程仅引用 `/usr/bin/true` 路径做声明门形态输入,且两条新
  用例实测 spawn=0(launchObserver 计数断言)。TASK-AIN-004 的 E2 面可达性
  裁定不由本 run 宣称。

### Readiness pin 复核(实现开工前,`git ls-tree` 逐项 @ `0d36375`)

- readiness Input pins 表九项逐项复核:八项内容 pin(Host、Discovery、Facts、
  五个 Tests 文件)与 readiness 表**逐字节同值,零漂移**:
  Host `50c23bf2…`、Discovery `38e38a2a…`、Facts `971fe98f…`、
  DiscoveryContractTests `2a8318f6…`、RockUSBFlashProvider `db5986dd…`、
  StandingAuthorization `d3750b77…`、FlashExecution `82629470…`、
  FlashExecutionFault `4a67cf7f…`。
- 第九项(本 change `tasks.md`,pin 语义 =「本 PR 改前」):readiness rebase
  base `495c7356081a83d18538ae6fcdb3e3580134dfbf`(#683 merge)实测 ls-tree ==
  pin 值 `6de7ebe1d481be41c74de0f816cda8538fb80d05`;`495c735 → 0d36375` 区间
  对 tasks.md 的唯一改动即 #690 自身两个 hunk(@254 状态翻转、@307 readiness
  段),均落本任务段内——与 pin 语义一致,非漂移。
- 交集重测(readiness 环境节要求):起草时在飞的 #687(feat TASK-OBS-001,
  Packages HDC/Process/OpenHarmony 面)与 #689(TASK-ASP-002,scripts/
  chg-2026-041 面)现均已 merge 入 base;其与本任务 pinned 实现面零交集由上述
  八项 blob 同值直接证明。当前在飞 open PR 与本 PR 文件集交集 = 0(实现期间
  main 零前进,未发生 rebase 事由)。
- 缺陷在场复核:Host:1039 组装行实测仍为缺省 `RockchipDeviceDiscoveryAdapter()`
  (blob 同值即逐字同 readiness 所记),无上游另行修复。

### 方向 A 落实(最小 diff,逐字按 readiness)

- `RockchipFlashExecutionHost.swift` 两处、且仅两处:
  1. 新增 internal 命名 seam `RockchipProductionDiscoveryComposition`
     (`admissionDiscoveryAdapter()` 工厂,置于
     `RockchipProductionAdmissionPort` 前):经 Discovery **既有** internal
     `init(profile:executor:)`(Discovery:547–553)注入 `.pinnedProduction`;
  2. 组装行(原 1039)改为消费该 seam:
     `adapter: RockchipProductionDiscoveryComposition.admissionDiscoveryAdapter()`。
- **`RockchipDeviceDiscovery.swift` 零修改、`RockchipAuthorizationFacts.swift`
  零触碰**:`git diff origin/main` 文件集 = Host + 新测试文件 + 本 run 记录,
  不含 Discovery/Facts;缺省 init 语义、两 pin 常量、声明门(555–575)、
  Facts 断言(340/345–352)逐字不变。
- 新契约测试文件 =
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipProductionCompositionContractTests.swift`
  (入既有 ArkDeckContractTests target,#678 先例;`Package.swift` 零接触)。

### 验证计划四条(逐字执行,全部二值)

1. **正向(AIN-COMP-001 正腿)PASS**:测试侧以完整 64-hex 字面量独立 pin
   `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`
   (`independentlyPinnedProductionSHA256`,不 import 生产常量做锚);seam 返回
   的 adapter 对按 Host 生产形态(user-selected bookmark、pinnedProduction
   reportedVersion/sha256、非 quarantine trust)声明的 tool 走真实
   `processRequest`(Discovery:555–575)成功,断言
   `ProcessIdentityBoundRequest.expectedSHA256 == 字面量` 且
   `RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256 ==
   字面量`——composition/Facts/测试三方一致,无
   `pinnedProduction == pinnedProduction` 套套断言。实测输出:
   `TEST-AIN-COMP-001 PASS leg=positive composition_pin=facts_pin=independent_literal declaration_gate=accepted device_dispatch=0`。
   **突变探针(套套性反证)**:临时把 seam 体改回缺省
   `RockchipDeviceDiscoveryAdapter()`(= 缺陷原线)重跑该用例,实测红:
   `failed: caught error: "executableHashMismatch"`(Discovery:571 真声明门)
   ——用例确能命中原缺陷;随后恢复方向 A 实现再跑绿。
2. **负向(AIN-COMP-001 负腿,real-fault)PASS**:以 Discovery:547–553 init
   注入 `.pinnedReadOnlyDiscovery`(= 今日缺陷组合)对同一声明 tool:
   `processRequest` 实测抛 `RockchipToolValidationError.executableHashMismatch`
   (570–572);并经 `RockchipDiscoveryToolDeviceFactPort`(Facts:115
   internal init)走 `observeToolAndDevice()` 实测抛
   `RockchipAuthorizationFactError.toolOrDeviceObservationUnavailable`
   (140–143)——错误形态与既有类型逐字一致,零新增放行路径;
   launchObserver 计数断言 **spawn=0**(声明门失败即 blockedToolAttempt,
   零进程 spawn),用例封闭。实测输出:
   `TEST-AIN-COMP-001 PASS leg=negative real_fault=readOnlyProfileInjection gate=executableHashMismatch admission=toolOrDeviceObservationUnavailable spawn=0 device_dispatch=0`。
3. **015-01/02 零修改腿 PASS**:
   `RockchipRockUSBFlashProviderContractTests.swift` 与
   `StandingAuthorizationContractTests.swift` 不在本 PR diff 中(blob 复核
   同值);实现前后全量日志各自提取三条 PASS 行,`/usr/bin/diff` 实测
   **逐字节相同**:
   - `TEST-AC-FLASH-015-01 PASS destructive_dispatch=0 job=policyBlocked handoff=controlled`
   - `TEST-AC-FLASH-015-01 PASS agent=policyBlocked ci=policyBlocked planOnly=allowed dispatch=0`
   - `TEST-AC-FLASH-015-02 PASS mismatch_fields=8 stale_plan_blocked=1 real_dispatch=0 realhardware_evidence=none`
4. **全量零回归 PASS**:汇总行均取自完整输出文件(非管道截断;XCTest
   Executed 行为权威,末尾 swift-testing「0 tests in 0 suites」行不作数):
   - base(`0d36375`,改动前本 worktree 实测):`Executed 440 tests, with 1
     test skipped and 0 failures (0 unexpected) in 55.593 (55.667) seconds`,
     exit 0——440 = readiness 所记 415 + #687 合入的 25,底线按实测上移,
     高于任务卡底线 400/1/0;
   - 实现后:`Executed 442 tests, with 1 test skipped and 0 failures
     (0 unexpected) in 59.981 (60.057) seconds`,exit 0——**442 = 440 + 2
     (新增正/负两用例)/ 1 skipped / 0 failures**,既有用例零修改、零回归。

### 自检

- `./scripts/check-sdd.sh`:`check_sdd: 0 error(s), 0 warning(s), 111
  acceptance IDs`;
- `git diff --check`:干净;
- `check_pr_paths` 模拟判定(fake event,base = `0d36375`,head = 本 commit,
  标题声明 TASK-AIN-003R):PASS——文件集 = Host + 新测试文件 + 本 run 记录,
  全部落本任务 Allowed paths;`tasks.md` 本 PR 未触碰(实现载体不改 status)。
- stop gate 检查:实现全程未需 pinned 集之外文件(`Package.swift`、Facts、
  `openspec/specs/**`、`openspec/contracts/**`、`scripts/**` 全部零触碰),
  无停手事由。
