# Tasks — CHG-2026-009 DAYU200 partition decode(read-only)

> V2 治理:本文件是任务的唯一事实源;任务状态变化只有经维护者 review/merge 后
> 生效。本 change 零设备操作、零网络、零 production subprocess。r4 只拆分
> implementation 与 interactive platform evidence,不改变 r3 codec/trusted-fd 语义。

## TASK-PD-001 — r3 codec audit headless remediation + contract evidence

- Status:done(TASK-PD-001 r5 implementation + evidence PR #160 已由维护者
  review/merge 合入 `main` squash commit `33aff46`;本独立状态 PR 依据下列
  completion evidence 起草 `ready→done`,仅在维护者 review/merge 后生效。本状态
  只关闭 r5 broker-receipt remediation 的 contract evidence(r4 headless done 此前
  已闭),不改变三项 platform AC(仍归 TASK-PD-002)、change verification、
  gap/DEC-002、compatibility、support 或 release 状态)
- r5 completion evidence:`evidence/runs/TASK-PD-001/r5-broker-receipt/run.md`
  (source revision `b81922d9901a0319d5425737f262e82e4a6a5b6a`;三文件 SHA-256 与
  `main` 合入版逐字节一致——main.m `4bb1e1ca…`、collect_platform_evidence.py
  `b78aca7d…`、test_collect_receipt_validation.py `b240c845…`;
  `TEST-DECODE-DAYU200-RECEIPT-CONTRACT-001` contract PASS——新套件 14/0、
  `test_decode.py` 只读重跑 43/0 零回归、clang -fsyntax-only -Werror 通过、
  check-sdd 0/0/111、broker/GUI/archive/device/network dispatch 均 0)。状态 PR
  复核(2026-07-20,当前 `main` `7c77672`,#159 之后基线,零 partition_decode
  变更):14/0 与 43/0 复现、三文件 hash 相符——该复核只确认 evidence 在现基线
  可复现,不构成新的 acceptance 结论。merge 本 PR 后,TASK-PD-002 依 r5 gate 经
  独立 readiness amendment 重钉三个 broker 文件 hash 并恢复 `ready`。
- r5 remediation amendment(2026-07-20;本块为 r5 执行的唯一权威 scope,下方 r4 各块
  保留为历史记录不再授权执行):
  - Motivation:TASK-PD-002 首次 fresh platform run(2026-07-20,preflight 全过)被
    collector `_validate_runtime_receipt` fail-closed 拒绝,零 partial output。零侵入
    诊断(复用未修改 collector 的 build→inspect→launch 管线+逐项校验,维护者亲跑)
    实锤根因:`main.m` 以 `@(expr != 0)` 装箱 sandbox_check 结果产生 NSNumber(int),
    NSJSONSerialization 序列化为 JSON `1` 而非 `true`;collector 对 `network-outbound`/
    `process-exec` 用 `is True` 身份检查,`1 is not True` 恒 FAIL;四个 device 路径的
    dict 相等比较因 Python `1 == True` 意外通过。sandbox 策略本身全部真实 denied;
    其余 16 项校验全部 PASS。CDHash 嫌疑已以独立 ad-hoc 探针证伪(kSecCodeInfoUnique
    = 20 字节截断,与 `codesign -d` 的 `CDHash=` 行逐字一致)。本 signed-broker 管线
    为首次端到端运行(r1 失败/r2 锁屏/r4 headless),缺陷因此从未暴露。attempt
    record 见 `evidence/runs/TASK-PD-002/platform-attempt-2026-07-20.md`。
  - In scope(最小修复,三项):
    1. `main.m`:policyChecks 全部 sandbox_check 派生字段改显式 BOOL 装箱
       (`(expr != 0) ? @YES : @NO`),receipt 布尔字段序列化为 JSON true/false;
    2. `collect_platform_evidence.py`:`_validate_runtime_receipt` 合取拆为逐项判定,
       每项失败以字段名+实际值报错(receipt 无敏感字段);严格性不放宽——`is True`
       与精确 dict 相等保持,布尔语义修正后 device 路径由 `1 == True` 的意外通过
       收敛为真布尔相等;
    3. 新建 `test_collect_receipt_validation.py`(headless,零 broker/GUI):合成
       receipt 向量矩阵——canonical true 版全项通过、int-boxed 版被拒且报出字段、
       逐项缺失/篡改各有具名错误;并以 source-literal 断言钉住 `main.m` 的显式
       BOOL 装箱形态(README/runbook 字面同步测试先例)。
  - Out of scope:`decode.py`/`evidence.py`/`README.md`/`test_decode.py`(r4 四文件
    保持 r4-done 字节,TASK-PD-002 对其 pins 不因 r5 漂移);三项 platform AC 判定
    (仍归 TASK-PD-002);任何 entitlement/policy/sandbox 语义变更。
  - Requirements/AC(r5):`DECODE-DAYU200-RECEIPT-CONTRACT-001`
    (`TEST-DECODE-DAYU200-RECEIPT-CONTRACT-001`,minimum evidence:`contract`)。
    `DECODE-DAYU200-HEADLESS-001` 保持 r4 done 已闭不重判;原三项 platform AC 保持
    pending 归 TASK-PD-002。
  - Allowed paths(r5):
    - `scripts/partition_decode/macos_input_broker/main.m`
    - `scripts/partition_decode/macos_input_broker/collect_platform_evidence.py`
    - `scripts/partition_decode/macos_input_broker/test_collect_receipt_validation.py`(新建)
    - `openspec/changes/chg-2026-009-dayu200-partition-decode/evidence/runs/TASK-PD-001/r5-broker-receipt/**`
    - 本 `tasks.md`(implementation PR 只追加 run/completion 引用,不标 `done`)
  - Verification(r5):新测试文件全部 PASS;`test_decode.py` 既有回归只读重跑不回归;
    `scripts/check-sdd.sh`;`git diff --check`;broker 启动/collector 发布/pinned
    archive/GUI/设备/网络 dispatch 均为 0(纯 headless 合成向量)。
  - Evidence gate:同一 revision 全部 PASS 后另起独立状态 PR 起草 `done`;done 后
    TASK-PD-002 经独立 readiness amendment 以 r5 合入后字节重钉 `main.m`/
    `collect_platform_evidence.py`/新测试文件 SHA-256(r4 readiness 其余 pins——
    archive identity、console、操作者、decoder 四文件——保持有效)并恢复 `ready`,
    再行重跑 fresh platform run。
- r5 implementation + evidence candidate:`evidence/runs/TASK-PD-001/r5-broker-receipt/run.md`
  (source revision `b81922d9901a0319d5425737f262e82e4a6a5b6a`;
  `TEST-DECODE-DAYU200-RECEIPT-CONTRACT-001` contract PASS——新套件 14/0、
  `test_decode.py` 只读重跑 43/0 零回归、clang -fsyntax-only -Werror 通过、
  check-sdd 0/0/111;broker/GUI/archive/device/network dispatch 均 0。本
  implementation PR 保持 `ready`,`ready→done` 仍须独立状态 PR 经维护者
  review/merge)
- Historical disposition(r4,closed):r4 headless remediation 已完成——implementation
  PR #124(merge `110071c1003ecc06eb4106d2e8ea5b554029329a`)、done 状态 PR #125;
  completion evidence `evidence/runs/TASK-PD-001/r4-headless/run.md`
  (`TEST-DECODE-DAYU200-HEADLESS-001` contract PASS;43 项 unit/fault/static 回归、
  archive characterization 36 项回归、SDD 0/0;collector/pinned archive/device/
  network/production subprocess dispatch 均 0)保持 immutable 且不被 r5 重判。r5 只
  覆盖 broker receipt 布尔语义与 collector 可诊断性,不触碰 r4 四个 decoder 文件。
- Readiness review（2026-07-19；不执行 TASK-PD-001、不启动 collector）：
  - Change gate:satisfied。CHG-2026-009@r4 已由维护者批准并经 PR #116 合入
    `main` merge commit `7585603d459ae26ad566b9aaeecc953f9c26bd98`；change 保持
    `approved`，唯一 task truth source 已把 headless implementation 与 interactive
    platform evidence 拆为 TASK-PD-001/TASK-PD-002。
  - Dependency gate:satisfied。r2 implementation/blocked record、r3 revision/readiness
    均在 `main` 保持 immutable provenance；CHG-2026-014 为 `verified`、TASK-RLC-001
    为 `done`。本任务不继承、复制或重判 r1/r2 evidence。
  - Contract gate:satisfied。execution 仅消费
    `DECODE-DAYU200-HEADLESS-001` / `TEST-DECODE-DAYU200-HEADLESS-001`
    (`minimum_evidence:contract`)；原三项 platform AC 保持 pending，且明确归
    TASK-PD-002 所有。
  - Scope gate:satisfied。可写源码固定为本任务 `Allowed paths` 中四个
    `scripts/partition_decode/` 文件；新 run 固定写入
    `evidence/runs/TASK-PD-001/r4-headless/**`，本 `tasks.md` 只可追加 run/completion
    引用且不得在 implementation PR 中标 `done`。broker/collector、其他 product/spec/
    change/evidence 均保持只读或禁止。
  - Environment gate:satisfied。macOS 26.5.2 (25F84)、CPython 3.14.6/stdlib；
    `env PYTHONWARNINGS=error python3 scripts/partition_decode/test_decode.py` 在
    readiness base `4e0c4f94d12e0ab55902580e43bd6dd61c4e6e79` 为 35 tests、0 failures。
    这是现状基线，不是 headless AC evidence 或 r2 blocker 的重判。
  - Headless boundary:satisfied。console 观测为 `CGSSessionScreenIsLocked=Yes`；该状态
    阻止 TASK-PD-002，但不阻止本任务。readiness 未请求 GUI/PowerBox，未运行 broker/
    collector，未读取 pinned archive，未访问设备/HDC/vendor tool/网络，未产生 mapping、
    reconciliation 或任何 platform Test ID 结论。
  - Execution boundary:后续仅一个 TASK-PD-001 implementation + fresh headless contract
    evidence PR；实现完成后仍须独立 `ready→done` 状态 PR。任何原三项 platform AC
    二值验证均留给满足其独立 readiness 的 TASK-PD-002。
- Historical disposition:r3 readiness PR #111 已合入 `main`
  `82a9ac791e86e2092dad08297e15cd47f1cdc914`；当时的 `ready` 同时绑定 implementation
  与 fresh platform run。r4 变更该执行范围,因此在新的 readiness 前 fail closed。
  r1/r2 FAILED/BLOCKED run 与 top-level evidence 保持 immutable,不得复用、复制或重判。
  r2 implementation `0076e44dcaed45605c1cccefc093a82b246a4ef5` 与 blocked-attempt
  record `0db5f22c0878d059697d32a3022fa260c83e2798` 只作为 provenance/read-only 输入。
- Objective:在锁屏 headless shell 中,以最小源码修改把现有 r2 固定 blocker 改为
  r3 fail-closed codec configuration/lifecycle audit,完成 branch-complete contract/fault/
  static 回归；不运行 collector、不读取 pinned archive、不产生任何原 platform AC 结论。
- Requirements/AC:`DECODE-DAYU200-HEADLESS-001`
  (`TEST-DECODE-DAYU200-HEADLESS-001`,minimum evidence:`contract`)。
  原 `DECODE-DAYU200-PARTITION-001`、`DECODE-DAYU200-INPUT-BOUNDARY-001`、
  `DECODE-DAYU200-RECONCILE-001` 不属于本任务 completion evidence,保持 pending。
- Depends on:
  - CHG-2026-009@r4 经维护者合入并保持 `approved`；
  - r2 implementation/blocked record、r3 revision/readiness 与 CHG-2026-014
    consolidation/verification 均为 `main` 历史（已满足）；
  - 本任务独立 readiness PR 固定 source/test/evidence path 与 headless toolchain。
- In scope:
  1. process audit schema 精确记录 DEFLATE base window bits `15`、zlib gzip
     `wbits=31`、history upper bound `32768` bytes、无 preset dictionary、无 codec
     clone/export/history view、compressed remainder configured/observed maximum 均
     `≤65536` bytes、application plaintext retained into next read 为 `0`；
  2. codec 与 compressed remainder 在成功取得 target、`DecodeFailure`、其他异常与
     cancellation 全部路径通过显式 `finally` 关闭；receipt 证明 lifecycle closed 且
     close 后 remainder 为 `0`；
  3. receipt 缺字段、矛盾、cap 越界或 cleanup 未完成时 fail closed；配置常量不能
     代替 runtime observation；不声称 allocator residue forensic zeroization；
  4. 删除仅针对 r2 歧义的固定 blocker；增加 success/failure/exception/cancellation
     cleanup、receipt missing/tamper、history/remainder cap、preset dictionary、clone/
     export/history view、额外 plaintext buffer 与原有所有正负分支回归；
  5. README 如实区分 headless contract PASS 与尚未执行的 platform AC。
- Allowed paths:
  - `scripts/partition_decode/README.md`
  - `scripts/partition_decode/decode.py`
  - `scripts/partition_decode/evidence.py`
  - `scripts/partition_decode/test_decode.py`
  - `openspec/changes/chg-2026-009-dayu200-partition-decode/evidence/runs/TASK-PD-001/r4-headless/**`
  - 本 `tasks.md`（implementation PR 只追加 run/completion evidence 引用,不标 `done`）
- Read-only inputs:
  - `scripts/partition_decode/macos_input_broker/**`
  - 本 change 既有 `evidence/**`（仅 provenance/negative-history review）
  - archived CHG-2026-003 inventory/identity evidence
- Forbidden paths:`scripts/partition_decode/macos_input_broker/**` 写入、ArkDeckApp、
  Packages、Xcode project、accepted specs/contracts/platform/integration lock、其他
  change/task/evidence；pinned archive、NSOpenPanel/PowerBox、collector、真实/模拟设备、
  HDC/vendor tool、网络、production child-process/device-mutation dispatch。
- Risk:medium（离线纯 Python remediation,但 receipt 若把配置误当 runtime 或 cleanup
  漏分支会制造虚假平台前提；以 tamper/fault tests 与零 dispatch audit fail closed）。
- Hardware required:no。
- Required environment:锁屏 macOS headless shell；仓库 CPython/stdlib、synthetic fixtures
  与本地临时目录。不得要求 GUI、系统授权、网络下载、pinned archive 或签名 broker runtime。
- Deliverables:r3 codec configuration/lifecycle implementation；fail-closed receipt validator；
  branch-complete tests；README contract/platform 边界；
  `evidence/runs/TASK-PD-001/r4-headless/run.md`（命令、环境、结果、唯一 headless Test ID、
  偏差/风险、collector/archive/HDC/device/network/production subprocess dispatch count `0`）。
- Verification:
  - 完整 `scripts/partition_decode/test_decode.py` 全通过；
  - synthetic archive characterization regression 与全部既有正负分支通过；
  - static audit 证明 production decoder 零 path open、subprocess、network、device mutation,
    且无额外 plaintext buffer、preset dictionary、codec clone/export/history view；
  - `scripts/check-sdd.sh` 为 0 errors/0 warnings；`git diff --check` 通过；
  - diff 只含本任务 allowed paths,broker/collector blob hash 与 base 一致。
- Evidence gate:仅 `TEST-DECODE-DAYU200-HEADLESS-001` 有同一 implementation revision
  的可复查 PASS evidence 才能另起 status PR 起草本任务 `done`。该结论不得用于
  TASK-PD-002 readiness 之外的 platform/compatibility/support/release claim。
- PR boundary:remediation implementation + headless contract evidence 一个独立
  `TASK-PD-001` PR；`ready→done` 仍为后续独立 status PR。
- Implementation run（2026-07-19）：
  `evidence/runs/TASK-PD-001/r4-headless/run.md` 仅记录
  `TEST-DECODE-DAYU200-HEADLESS-001` contract PASS、完整源码 hash、43 项
  unit/fault/static 回归与零 collector/archive/device/network/production subprocess
  dispatch；原三项 platform Test ID 保持 pending。本 implementation PR 不将任务标为
  `done`，仍须后续独立 status PR。

## TASK-PD-002 — signed broker fresh platform verification

- Status:ready(r5 readiness amendment candidate;仅在维护者 review/merge 本
  amendment PR 后生效。本 PR 不运行 collector/broker、不读取 archive、不产生
  evidence;实际执行仍需用户人工解锁 console 并本人操作 NSOpenPanel,不需要
  DAYU200 设备)
- Implementation + evidence candidate:`evidence/runs/TASK-PD-002/run.md` 与
  `platform-2026-07-20-r5/**`(2026-07-20 16:58 维护者亲手 fresh run,collector
  exit 0,create-only publication 成功;三项 platform Test ID 同一次 run 全部
  PASS;六文件 hash 经独立复算与 summary/receipt/platform-evidence 三方绑定一致;
  敏感扫描零命中。本 evidence PR 保持 `ready`,`ready→done` 仍须独立状态 PR 经
  维护者 review/merge)
- r5 readiness amendment(2026-07-20;host-only,零 collector/broker/archive/设备
  访问;r5 gate 规定形态):
  - Unblock gate:satisfied。r5 fail-closed 回退的前置 TASK-PD-001 r5 remediation
    `done` 已满足——implementation PR #160(squash `33aff46`)、done 状态 PR #161
    (`946ebfd`)均已由维护者 review/merge;2026-07-20 blocked attempt 的根因
    (receipt 布尔装箱+collector `is True`)已修,collector 校验现为逐项具名报错。
  - Broker-source re-pin gate:satisfied。r5 涉及的三文件以 `main` `946ebfd` 实测
    重钉(执行前必须复算一致,漂移即 blocked;下列值取代 r4 Broker-source gate 中
    对应两行,新测试文件为新增 pin):
    - `scripts/partition_decode/macos_input_broker/main.m`
      `4bb1e1cad4329d9d807a0a98744e5de04efe812360cb01a19a7b01522bc94e22`
    - `scripts/partition_decode/macos_input_broker/collect_platform_evidence.py`
      `b78aca7d86b12cf7afb94e43ad5a8e3ebb7c848ba5cfc46ba917b485da3e3a72`
    - `scripts/partition_decode/macos_input_broker/test_collect_receipt_validation.py`
      `b240c845a1b3df284ecde8b04bb4b13c94b7cb33371aa2b2eab48c7d6370b160`
  - Unchanged-pin gate:satisfied。其余 r4 pins 于 `main` `946ebfd` 实测零漂移,
    保持有效:Broker-source gate 其余五文件(Broker.entitlements `27bcfa03…`、
    Info.plist `fe574559…`、README.md `ab3960e9…`、build_and_sign.zsh `ecf749f0…`、
    policy.json `ee3fe577…`)、Source-identity gate 四个 decoder 文件(r5 明文
    Out-of-scope,零字节改动)、Archive gate(size `732948803`/SHA
    `fc7637f3…5280`)、Environment/console gate 与操作者规则。
  - Review boundary:本 amendment 只翻转本任务状态并重钉上述 pins;三项 platform
    AC 的 expected result/minimum evidence/同一次 fresh run 规则不变;merge 后即可
    重跑 fresh platform run(blocked attempt record 保持 immutable,新 run 使用新的
    create-only out-dir)。
- Objective:不修改 decoder 或 broker source,在解锁 macOS console 上由人类经未修改的
  签名 sandbox broker/NSOpenPanel 选择 pinned archive,把已合入 TASK-PD-001 完整
  implementation commit 绑定到同一次 create-only fresh 三项 platform run。
- Requirements/AC:`DECODE-DAYU200-PARTITION-001`、
  `DECODE-DAYU200-INPUT-BOUNDARY-001`、`DECODE-DAYU200-RECONCILE-001`；三项 expected
  result、minimum evidence 与 Test ID 保持 r3 不变。
- Readiness review（2026-07-20；host-only,零 collector/broker/archive/设备访问）:
  - Change gate:satisfied。CHG-2026-009@r4 保持 `approved`（#116）;本 readiness 只
    翻转本任务状态并固定 identity pins,不改三项 platform AC 的 expected result/
    minimum evidence/Test ID。
  - Dependency gate:satisfied。TASK-PD-001 implementation PR #124 已合入 `main`
    merge commit `110071c1003ecc06eb4106d2e8ea5b554029329a`,`done` 状态 PR #125 已
    合入（`3f3752d6daaf96aac8d6aa3139e1300dd74d7457`）。
  - Source-identity gate:satisfied。2026-07-20 于 `main` `48efe97` 实测,四个 decoder/
    validator 文件与 r4-headless run.md 记录零漂移,pinned SHA-256:
    - `scripts/partition_decode/decode.py`
      `a413defecd8658462a821ab14c7be4326ee42ae77673325c691daf6f653fb493`
    - `scripts/partition_decode/evidence.py`
      `aa97e86c5957fe4b722e99b5988b067f86d09199edbc3138a088028e87247e64`
    - `scripts/partition_decode/README.md`
      `3c518ec1be658cb2975b2123cd3d412ab2b02a2a592c855653a965a5cbe8609e`
    - `scripts/partition_decode/test_decode.py`
      `6c8b7f0a61f061b1551f9ad369273bd7b0fbf32675fb1fc4cd2834c9c323634e`
  - Broker-source gate:satisfied。`scripts/partition_decode/macos_input_broker/` 七个
    源文件 pinned SHA-256（执行前必须复算一致,漂移即 blocked）:
    - `Broker.entitlements`
      `27bcfa03139b7ae405bd62099fe7d2660b4ae7148e1b722451cfc04618aed787`
    - `Info.plist`
      `fe57455975dea024fbdb9f4a01bea26b9ce30a1f6b305575136ff18d31d2fc0d`
    - `README.md`
      `ab3960e9e814b7eb501607b3ee31ceb88bac14df7dfb805bcab97b8b9b6ed4c1`
    - `build_and_sign.zsh`
      `ecf749f05f38f0e176d19c0e341627054b2cf8c0547fbf5ad1abcee8bf239bbd`
    - `collect_platform_evidence.py`
      `ae5ab75c7d9efb583983ca894b0e1c6deebc038c7563d4cb01058c3bebdce056`
    - `main.m`
      `060331823ff36a373847bcf50d5873051bd1fdec6d33c92ad585961420c2eb8a`
    - `policy.json`
      `ee3fe577f74a094f121ad9937540f29a9a8098ef12b907ad388cc8062b9adaaf`
    broker artifact 由用户执行时以 `build_and_sign.zsh` 从上述未修改 source 新构建;
    artifact hash、signing identity（无 certificate 时如实记录 ad-hoc）、
    `codesign --verify --strict` 结果与签后 entitlement/policy 均在 run evidence 记录。
  - Archive gate:satisfied。pinned archive identity 引自 archived CHG-2026-003
    evidence:size `732948803` bytes、SHA-256
    `fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280`;本地在场性由
    用户执行时确认,NSOpenPanel 选择后须重新通过 size/SHA identity gate,locator/
    basename/host 目录不入 evidence。
  - Environment/console gate:执行时要求可交互解锁 console
    （`CGSSessionScreenIsLocked` 不为 `Yes`,collector 启动前与 publication 前各确认
    一次）;操作者=维护者本人;OS/arch/Xcode/Swift/Python 版本在 run evidence 执行时
    记录。
  - Review boundary:本 readiness PR 只更新本 `tasks.md` 该任务段,不触碰
    `scripts/partition_decode/**`、broker、archive、任何 evidence 或其他任务状态。
- Depends on:
  - TASK-PD-001 `done` 状态 PR 与其 implementation commit 均已合入 `main`（已满足:
    #124 `110071c1`、#125）;
  - 完整 commit OID、decoder/validator blob hash 与未修改 broker source hash 已由本
    readiness 固定（artifact hash 执行时记录）;
  - macOS console 由用户人工解锁且 `CGSSessionScreenIsLocked` 不为 `Yes`（执行时）;
  - pinned archive 可由用户在 NSOpenPanel 中选择并重新通过 size/SHA identity gate
    （执行时）;
  - 本 readiness PR 经维护者 review/merge（merge 即上述 pins 的批准）。
- In scope:构建/验证未修改 broker artifact；记录 signing identity、签后 entitlement/policy、
  OS/arch/Xcode/Swift/Python、descriptor-transfer/runtime binding；由同一次 fresh run 生成
  mapping、reconciliation、process audit、summary 与 run；三个 Test ID 全部二值判定。
- Allowed paths:
  - `openspec/changes/chg-2026-009-dayu200-partition-decode/evidence/runs/TASK-PD-002/**`
  - 本 `tasks.md`（evidence PR 只追加 run/completion evidence 引用,不标 `done`）
- Read-only inputs:
  - `scripts/partition_decode/**`
  - archived CHG-2026-003 inventory/identity evidence
  - TASK-PD-001 merged implementation commit 与 headless run
- Forbidden paths:全部 source、broker/collector/policy/entitlement 写入；本 change 既有
  r1/r2/top-level evidence 修改或重判；accepted specs/contracts/platform/integration lock、
  其他 change/task/evidence；archive locator、parameter.txt 原文、真实设备、HDC/vendor
  tool、网络、device mutation/destructive dispatch。
- Risk:medium（只读 platform evidence,但 sandbox/signing/descriptor/implementation binding
  任一不明确即 fail closed；取消、锁屏、picker/identity/AC failure 不得发布 partial output）。
- Hardware required:no；禁止以真实 device node 做负测。
- Required environment:可交互解锁的 macOS console；用户本人操作 NSOpenPanel；pinned archive
  本地在场；仓库既有 CPython/Xcode/Swift/codesign。当前无 certificate identity 时只可如实
  记录 ad-hoc signature,不构成 release signing/support claim。
- Deliverables:一个新建的 run 目录,含 fresh mapping/reconciliation/process audit/summary/
  run 与 signing/platform/runtime-binding evidence；不修改任何旧 evidence。
- Verification:
  - collector 启动前与 publication 前均确认 console 未锁；取消/锁屏/failure 零 governed
    partial output；
  - `codesign --verify --strict`、签后 entitlement/policy/source allowlist、descriptor chain、
    artifact/runtime/source OID/hash 全部一致；
  - 同一次 fresh run 的 `TEST-DECODE-DAYU200-PARTITION-001`、
    `TEST-DECODE-DAYU200-INPUT-BOUNDARY-001`、`TEST-DECODE-DAYU200-RECONCILE-001`
    全部 PASS；任一不可二值化即整体 blocked；
  - `scripts/check-sdd.sh`、`git diff --check` 与 allowed-path diff audit 通过。
- Evidence gate:三项 platform Test ID 全部由同一次 fresh run PASS 后,才能另起状态 PR
  起草 TASK-PD-002 `done`；该状态仍不自动改变 gap/DEC-002、change verified、compatibility、
  hardware、support 或 release claim。
- PR boundary:一个 evidence-only `TASK-PD-002` PR；任何 source 修复必须回到新的
  TASK-PD-001 remediation revision,不得在 platform run PR 内夹带。
