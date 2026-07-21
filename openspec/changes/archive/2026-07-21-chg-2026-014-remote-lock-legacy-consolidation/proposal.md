---
id: CHG-2026-014-remote-lock-legacy-consolidation
revision: 1
status: archived # 2026-07-21 archive PR(先例 #178;consolidation 账本的 active-audit-input 角色随 M1-006 done/#207 与 CHG-002 verified/#208 完成;chg-008 引用面同 PR 内 dated note 收口);verified 于 2026-07-19 closure PR。原注: 2026-07-19 verification closure candidate；四项 RLC gate PASS；仅在本 PR 维护者 review/merge 后生效
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# Remote-lock legacy consolidation：锁屏遗留实现汇入单一非阻塞任务

## Why

远程 macOS host 锁屏后，两个在途任务无法按原 verification gate 闭环：

- `CHG-2026-002/TASK-M1-006` 的生产 HDC 实现已保存在完整 commit
  `ae708518ce6cc8bbd5ad39943d948b2d81209f03`，但所需 integration probe 尚未批准，
  signed XCUITest 还要求可交互 Developer Tools 环境；
- `CHG-2026-009/TASK-PD-001` 的 r2 实现已在 `main`
  `0076e44dcaed45605c1cccefc093a82b246a4ef5`，但 NSOpenPanel/PowerBox 需要解锁后
  人工选择 pinned archive，且 DEFLATE sliding-history 的 change-local AC 边界仍需
  维护者决定。blocked attempt 已在
  `0db5f22c0878d059697d32a3022fa260c83e2798` 合入。

继续把“代码是否可以安全进入 main”和“交互/平台证据是否全部通过”绑定为同一个
调度条件，会让已经 fail-closed、可由 headless contract 检查的实现长期停留在遗留
分支，也阻止与未通过 AC 无关的后续实现准备。本 change 建立一个窄范围的合并载体：
把固定 commit 的既有实现视为 `TASK-RLC-001` 的不可变输入，由一个新的实现 PR 做
来源审计、fail-closed 收敛与 headless 验证。原任务未完成的 AC 不被转移、删除或
重判，仍阻止对应 capability verification、hardware/support 与 release claim。

## What changes

### In scope

- 新建单一 `TASK-RLC-001`，允许从下列固定 OID 导入或引用遗留产物，而不要求来源
  Task 先变为 `done`：
  - M1-006 implementation input：
    `ae708518ce6cc8bbd5ad39943d948b2d81209f03`；
  - PD-001 implementation input：
    `0076e44dcaed45605c1cccefc093a82b246a4ef5`；
  - PD-001 blocked-attempt record：
    `0db5f22c0878d059697d32a3022fa260c83e2798`。
- 以新任务为“一任务一实现 PR”的评审单元，生成逐文件 provenance manifest，记录
  source Task、完整 OID、导入路径、未关闭 AC、runtime reachability、测试与回滚点。
- M1-006 遗留代码只有在默认 fail-closed、无真实 `hdc`/设备/非 loopback dispatch、
  无 external/unknown server 自动 lifecycle、且未验证入口不能铸造执行 authority 时
  才可进入 main；必要的隔离修复属于本任务。
- PD-001 已合入代码只作为 ledger 输入；本任务不得运行其交互 collector、不得产生
  fresh passing evidence，也不得改变其 blocked 结论。
- 原 Task 保持**非 `done`**并如实保留当前状态与 blocker；PD-001 继续 `blocked`，M1-006
  在权威 main 中当前仍为 `ready`，其遗留分支提出的 `blocked` 只有经独立 status PR 合入
  才生效。后续可在独立治理 PR 追加 `Consolidated by TASK-RLC-001` disposition 与固定
  OID。`TASK-RLC-001 done` 只表示遗留 bytes 已安全汇入/登记，不表示来源 Task done。
- 允许后续 Task 经**独立、维护者批准的 tasks.md revision**，将“代码可编译/接口已
  合入”的实现依赖改指向 `TASK-RLC-001`；仅当该后续 Task 的 Requirement/AC 不依赖
  来源 Task 尚未通过的 evidence 时，才能进入 readiness review。

### Non-blocking boundary

本 change 所称“不阻塞”仅指 implementation scheduling：

1. 来源 Task 是否 `done` 不作为 `TASK-RLC-001` 的依赖；本 change approved + ready 后即可
   按固定 OID 执行 consolidation；
2. 与遗留 AC 无关、且有独立 task revision 的 headless implementation MAY 继续；
3. 来源 Task、其 AC、change verified、platform conformance、hardware/support 和 release
   gate 全部保持 blocked/pending，直到各自原 verification plan 真正满足。

它不自动改写 `TASK-M1-007`、`TASK-M1-008`、`TASK-M0B-002`、`TASK-UD-001` 或
`TASK-FA-001` 的 Depends on；每个 consumer 必须单独证明自己不消费缺失 evidence，
再由维护者批准 dependency revision。

### Out of scope

- 将 M1-006、PD-001 或其 change 标为 `done`/`verified`；
- 修改、删除、放宽或重编号任何 Core Requirement、Acceptance Scenario、contract、
  schema、baseline 或 change-local AC；
- 注册 M1-006 缺失的 HDC integration probe，或决定 PD-001 DEFLATE codec state 的
  规范语义；二者仍须各自独立 change/revision；
- 启用 Developer Mode、自动解锁、操作 NSOpenPanel/PowerBox、运行 signed XCUITest、
  访问真实设备或已安装真实 `hdc`；
- 真机、Flash、server lifecycle、device mutation、非 loopback 网络、support/release claim；
- 用 branch 名或未提交 worktree 代替完整 commit OID。

## Observable behavior before/after

- Before：M1-006 遗留实现只能留在未合入分支；PD-001 代码虽已在 main，但交互验证债与
  M1-006 遗留没有统一可审计 disposition。blocked Task 同时承担代码集成与验收债语义。
- After approval/implementation：固定遗留 bytes 可经一个 fail-closed consolidation PR
  进入/留在 main，并以统一 ledger 追溯；未验证功能默认不可获得执行 authority。原 AC
  与发布结论完全不变，后续 Task 只有经独立 dependency revision 才能使用已合入接口。

## Scope

- Requirements：无新 Core Requirement；回归引用 `REQ-HDC-001`…`REQ-HDC-010`、
  `REQ-DEV-001`…`REQ-DEV-007`、`REQ-WF-001`/`REQ-WF-002`、`REQ-JOB-002`，仅用于
  证明没有放宽既有安全边界。
- Change-local acceptance：`RLC-LEGACY-IMPORT-001`、`RLC-FAIL-CLOSED-001`、
  `RLC-NONBLOCKING-001`、`RLC-AUDIT-ROLLBACK-001`。
- Contracts/schemas：unchanged。
- Core baseline bump：no。

## Platform impact and revalidation

| Platform | Disposition | Reason |
| --- | --- | --- |
| macOS | no conformance transition | 仅收敛遗留实现与调度；原 platform AC 仍 pending |
| Windows | deferred / unchanged | 无实现输入、无支持声明 |
| Linux | deferred / unchanged | 无实现输入、无支持声明 |

## Safety, privacy, and compatibility

- 任一未验证入口可触达真实 process/device/server lifecycle，即 consolidation 整体 fail；
- source evidence 保持 immutable；新 ledger 只引用完整 OID/hash，不改写旧 run；
- 不记录 archive locator、设备标识、私钥、密码或真实敏感 Artifact；
- rollback 是 revert `TASK-RLC-001` implementation PR；原 Task/evidence 不随回滚删除；
- 本 proposal 的 merge 只创建 `proposed` change，不批准 change、不使 Task ready，也不
  允许合入遗留实现。批准和 readiness 必须分别由后续独立 PR 完成。

## Verification closure（2026-07-19）

- Approval/readiness：CHG-2026-014 经 PR #107 合入 `main`
  `4b4e0b37c82bf03ccfa1317058f06834d68273f5` 置为 `approved`；TASK-RLC-001 经
  PR #108 合入 `main` `840e8306e0f8539072c3931384a21a80269d9027` 置为 `ready`。
- Implementation/evidence：TASK-RLC-001 implementation PR #110 已由维护者合入
  `main` `f7c334857ae5735077254ccbdf3dafac8c8ad83b`；完整 OID/path/blob disposition、
  runtime reachability、零禁止 dispatch counters、测试与 rollback 分别记录在
  `evidence/legacy-import-manifest.md` 与 `evidence/runs/TASK-RLC-001/run.md`。
- Governance/completion：独立 source-task disposition PR #112 已合入 `main`
  `e9689e54d12d8e9baa21c7d7747c2fff9be15be4`；TASK-RLC-001 `→done` 状态 PR #113
  已合入 `main` `e67568e56c53389090958c7aedb9b0681d6f2816`。
- 四项 `TEST-RLC-*` 在同一 implementation revision 的 run 中均为二值 PASS；来源 Task
  继续非 `done`（当前 TASK-M1-006 为 `blocked`、TASK-PD-001 为 `ready`），全部未关闭
  AC/evidence gate 与 consumer dependency 仍显式存在；不构成 conformance、hardware、
  support 或 release claim。
- 上述历史与 evidence 构成本 verification closure PR 的确认范围；本文件的
  `status: verified` 只有在维护者 review/merge 本 PR 后才生效，不自行批准验证结论。
  verified 只证明 CHG-2026-014 的 consolidation 机制按批准范围闭环，不验证来源 Task、
  macOS platform、HDC compatibility、DAYU200 或任何 release capability。本 change 暂不
  archive；其 ledger 仍是后续独立 consumer dependency revision 的活跃审计输入，archive
  留待后续独立 PR 裁量。

> Post-verification status note（2026-07-20，随账本对齐 PR 合入，原文不改写）：本文
> "In scope"节与上方 closure 段对来源 Task 状态的现在时陈述均为各自起草时点的快照，
> 且两处互相矛盾（前者称 PD-001 `blocked`/M1-006 在权威 main 仍 `ready`，后者称
> M1-006 `blocked`/TASK-PD-001 `ready`）。来源 Task 的 current 状态一律以各自 change
> 的 tasks.md 与 git 账本为准：closure（PR #114）时点为 M1-006 `blocked`、TASK-PD-001
> `ready`；2026-07-19 起 TASK-PD-001 已 `done`（implementation PR #124 `110071c1`、
> 状态 PR #125），其 headless/platform 拆分由 PR #116 生效——本 ledger 中"来源 Task
> 保持非 `done`"等表述自该时点起不再是 current 事实。后续 consumer dependency
> revision 引用本 ledger 时须以来源 tasks.md current 状态复核。本注记不改变 verified
> 结论、manifest bytes 或任何 evidence。

> Byte-currency note（2026-07-20，随账本对齐 PR 合入，原文不改写）：
> `evidence/legacy-import-manifest.md` 的"来源路径与 r2 实现 byte-identical"陈述同为
> closure 时点快照。TASK-PD-001 r4 headless remediation（approved implementation PR
> #124 `110071c1`）已改动 PD inventory 中 4 个文件（`scripts/partition_decode/` 下
> `README.md`、`decode.py`、`evidence.py`、`test_decode.py`），其当前 `main` blob OID
> 已不等于 ledger 记载值（例:`decode.py` ledger `51722922…` → 现 `586be8d3…`）；
> M1-006 inventory 13 项经 #126 误合与 #133 逐字节 revert 后净漂移为零。本 ledger 是
> 活跃审计输入,消费者引用其字节恒等声明时须按 `git rev-parse HEAD:<path>` 对当前
> `main` 复核。本注记不改变 verified 结论、manifest bytes 或任何 evidence。
