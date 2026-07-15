# Tasks — CHG-2026-001 macOS M0A

> V2 治理:本文件是任务的唯一事实源(原 immutable task packets 已废止,历史见 git)。
> 状态经 PR review 合入生效。AC-HDC-005-01(parserGolden)已移出本 change 范围,fixture 由本 change 产出、后续 change 认领。

## TASK-M0A-001 — 签名 SwiftUI 应用壳与分离的 package/test targets

- Status:done
- Requirements/AC:MAC-M0A-SHELL-001
- Depends on:none
- Allowed paths:`ArkDeck.xcodeproj/**`、`ArkDeckApp/**`、`Packages/ArkDeckKit/**`、本 change `evidence/**`
- Risk:low;Hardware:no
- Deliverables:签名最小 SwiftUI app + 分离的 ArkDeckKit package targets;unit/contract test targets 与 zh-Hans/en String Catalog 骨架;clean-build 与启动证据(记录确切 Xcode/toolchain 版本)。
- Verification:clean build、签名检查、干净用户启动 smoke → platform 级证据。

## TASK-M0A-002 — ProcessExecutor 与 external-first HDC discovery 原型

- Status:done
- Requirements/AC:AC-JOB-005-01、AC-NFR-002-01 等(见 verification.md)
- Depends on:TASK-M0A-001
- Allowed paths:`Packages/ArkDeckKit/Sources/ArkDeckProcess/**`、`.../ArkDeckOpenHarmony/**`、对应 Tests 与 Fixtures、本 change `evidence/**`
- Risk:low;Hardware:no
- Deliverables:argv 数组、分离流、timeout/取消的 ProcessExecutor 原型;external-first HDC 候选发现与 per-Job toolchain 快照原型;语义化 HDC 成功/失败 fixtures(含 exit-0 失败与大流量输出)。

## TASK-M0A-003 — host-wide HDC supervisor 与 ownership/lifecycle 安全门

- Status:ready
- Requirements/AC:AC-HDC-002-01、AC-HDC-003-01/02、AC-HDC-010-* 等
- Depends on:TASK-M0A-002
- Allowed paths:`Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/**`、对应 Tests 与 `Fixtures/HDCServer/**`、本 change `evidence/**`
- Risk:low;Hardware:no
- Deliverables:单 host-wide supervisor 原型(endpoint/ownership/generation);external/unknown server 零自动 kill 的调用计数证明;typed lifecycle 影响预览、确认、critical-Job 阻断与审计 fixture 覆盖。

## TASK-M0A-004 — 单实例、durable journal intent 与电源活动原型

- Status:done
- Requirements/AC:AC-JOB-002-01、AC-JOB-008-01 等
- Depends on:TASK-M0A-001
- Allowed paths:`Packages/ArkDeckKit/Sources/ArkDeckRuntime/**`、`.../ArkDeckStorage/**`、对应 Tests、本 change `evidence/**`
- Risk:low;Hardware:no
- Deliverables:kernel-backed 单写者守卫与第二实例零副作用 fixture;append-only journal intent/checkpoint 原型与故障注入;引用计数电源活动租约(成功/失败/取消/throw 全释放)。
- Note:人工 idle-sleep observation 已于 2026-07-15 由维护者执行并记录于 `evidence/runs/TASK-M0A-004/run.md`（观察记录段）。

## TASK-M0A-005 — Sandbox/非 Sandbox 原型、干净 VM 信任矩阵与只读硬件测试计划

- Status:ready
- Requirements/AC:AC-HDC-001-01、AC-HDC-003-01、AC-HDC-006-01 等
- Depends on:TASK-M0A-001、TASK-M0A-002、TASK-M0A-003
- Allowed paths:`ArkDeck.xcodeproj/**`、`ArkDeckApp/**`、`Configurations/**`、`docs/adr/**`、本 change `evidence/**`
- Risk:medium(外部工具与网络);Hardware:no
- Deliverables:两种签名原型与真实 entitlement dump;干净 VM Gatekeeper/quarantine 矩阵;供 TASK-M0A-007 使用的只读 USB/UART/TCP 测试计划与目标先决条件。本任务不声称真机证据。

## TASK-M0A-006 — M0A 分发 ADR 与 hash 索引的证据汇总

- Status:ready
- Requirements/AC:MAC-M0A-DIST-001
- Depends on:TASK-M0A-002…005、TASK-M0A-007
- Allowed paths:`docs/adr/**`、本 change `evidence/**`
- Risk:low;Hardware:no
- Deliverables:选择 Sandbox 或非 Sandbox Developer ID 分发的 ADR(含被拒方案与复验触发);全部矩阵行 passed/failed/blocked 的证据汇总;下一版 macOS profile/verification 修订草案(作为 evidence 提交,另行批准)。

## TASK-M0A-007 — 真机只读 USB/UART/TCP 与持久文件访问矩阵

- Status:ready
- Requirements/AC:MAC-M0A-SANDBOX-001(minimum evidence:realHardware)
- Depends on:TASK-M0A-005
- Allowed paths:本 change `evidence/**`
- Risk:medium(真机只读);Hardware:**yes,由人类操作者亲自执行**
- Deliverables:按 TASK-M0A-005 冻结的只读计划,由人类在真实设备上执行两种签名原型的 USB/UART/TCP 与文件访问矩阵;evidence 记录操作者、设备身份/固件/transport、执行时间与逐格结果;destructive dispatch 恒为 0。
- 注:V2 治理下不再需要 lab-authorization JSON;人类执行 + evidence 记录 + PR review 即构成授权链(见 `governance/enforcement.md`)。
