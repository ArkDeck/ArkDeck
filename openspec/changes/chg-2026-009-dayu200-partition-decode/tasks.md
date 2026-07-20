# Tasks — CHG-2026-009 DAYU200 partition decode(read-only)

> V2 治理:本文件是任务的唯一事实源;任务状态变化只有经维护者 review/merge 后
> 生效。本 change 零设备操作、零网络、零 production subprocess。r4 只拆分
> implementation 与 interactive platform evidence,不改变 r3 codec/trusted-fd 语义。

## TASK-PD-001 — r3 codec audit headless remediation + contract evidence

- Status:done（TASK-PD-001 implementation PR #124 已由维护者 review/merge 合入
  `main` merge commit `110071c1003ecc06eb4106d2e8ea5b554029329a`；本独立状态 PR
  依据下列 completion evidence 起草 `ready→done`，仅在维护者 review/merge 后生效。
  本状态只关闭 headless implementation contract，不改变原三项 platform AC、
  TASK-PD-002、change verification、gap/DEC-002、compatibility、support 或 release 状态）
- Completion evidence:`evidence/runs/TASK-PD-001/r4-headless/run.md`（同一 implementation
  revision 的 `TEST-DECODE-DAYU200-HEADLESS-001` contract PASS；43 项 unit/fault/static
  回归与 archive characterization 36 项回归通过，SDD 0 errors/0 warnings；collector、
  pinned archive、device、network 与 production subprocess dispatch 均为 0）
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

- Status:ready（readiness candidate；仅在维护者 review/merge 本 readiness PR 后生效。
  本 PR 不运行 collector/broker、不读取 archive、不产生 evidence；实际执行另需用户
  人工解锁 console 并本人操作 NSOpenPanel——不需要 DAYU200 设备）
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
