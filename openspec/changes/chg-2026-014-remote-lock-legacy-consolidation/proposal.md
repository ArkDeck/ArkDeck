---
id: CHG-2026-014-remote-lock-legacy-consolidation
revision: 1
status: approved # 本分支仅起草；维护者 review/merge 后才在 main 生效
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
