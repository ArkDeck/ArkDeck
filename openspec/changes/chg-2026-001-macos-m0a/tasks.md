# Tasks — CHG-2026-001 macOS M0A

> V2 治理:本文件是任务的唯一事实源(原 immutable task packets 已废止,历史见 git)。
> 状态经 PR review 合入生效。AC-HDC-005-01(parserGolden)已移出本 change 范围,fixture 由本 change 产出、后续 change 认领。
> 2026-07-20 traceability remediation:依既有 verification matrix 与 run evidence,
> 将 `…`/`*`/`01/02`/`等` 简写替换为 scope 中的显式完整 acceptance ID,
> 作为 CHG-2026-017 r2 精确覆盖校验的基线输入;不改变任务状态、归属、evidence
> 或验证结论。

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
- Requirements/AC:AC-HDC-001-01、AC-HDC-001-02、AC-JOB-005-01、
  AC-NFR-002-01、MAC-M0A-PROC-001、MAC-M0A-HDC-001(见 verification.md)
- Depends on:TASK-M0A-001
- Allowed paths:`Packages/ArkDeckKit/Sources/ArkDeckProcess/**`、`.../ArkDeckOpenHarmony/**`、对应 Tests 与 Fixtures、本 change `evidence/**`
- Risk:low;Hardware:no
- Deliverables:argv 数组、分离流、timeout/取消的 ProcessExecutor 原型;external-first HDC 候选发现与 per-Job toolchain 快照原型;语义化 HDC 成功/失败 fixtures(含 exit-0 失败与大流量输出)。

## TASK-M0A-003 — host-wide HDC supervisor 与 ownership/lifecycle 安全门

- Status:done
- Requirements/AC:AC-HDC-002-01、AC-HDC-003-01、AC-HDC-003-02、
  AC-HDC-004-01、AC-HDC-009-01、AC-HDC-010-01、AC-HDC-010-02、
  AC-HDC-010-03、MAC-M0A-HDC-002
- Depends on:TASK-M0A-002
- Allowed paths:`Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/**`、对应 Tests 与 `Fixtures/HDCServer/**`、本 change `evidence/**`
- Risk:low;Hardware:no
- Deliverables:单 host-wide supervisor 原型(endpoint/ownership/generation);external/unknown server 零自动 kill 的调用计数证明;typed lifecycle 影响预览、确认、critical-Job 阻断与审计 fixture 覆盖。

## TASK-M0A-004 — 单实例、durable journal intent 与电源活动原型

- Status:done
- Requirements/AC:AC-JOB-002-01、AC-JOB-008-01、MAC-M0A-RUNTIME-001、
  MAC-M0A-JOURNAL-001、MAC-M0A-POWER-001
- Depends on:TASK-M0A-001
- Allowed paths:`Packages/ArkDeckKit/Sources/ArkDeckRuntime/**`、`.../ArkDeckStorage/**`、对应 Tests、本 change `evidence/**`
- Risk:low;Hardware:no
- Deliverables:kernel-backed 单写者守卫与第二实例零副作用 fixture;append-only journal intent/checkpoint 原型与故障注入;引用计数电源活动租约(成功/失败/取消/throw 全释放)。
- Note:人工 idle-sleep observation 已于 2026-07-15 由维护者执行并记录于 `evidence/runs/TASK-M0A-004/run.md`（观察记录段）。

## TASK-M0A-005A — Sandboxed 原型、entitlement dump 与只读硬件测试计划

> 2026-07-15 由维护者决定从原 TASK-M0A-005 拆分:本任务承载无需 clean-VM/Developer ID 前提的交付物;拆分经本 PR review 合入生效。

- Status:done
- Requirements/AC:AC-HDC-001-01(Sandboxed prototype 部分);为 TASK-M0A-007
  提供冻结计划
- Depends on:TASK-M0A-001、TASK-M0A-002、TASK-M0A-003
- Allowed paths:`ArkDeck.xcodeproj/**`、`ArkDeckApp/**`、`Configurations/**`、`docs/adr/**`、本 change `evidence/**`
- Risk:low;Hardware:no
- Deliverables:Sandboxed 签名原型(含 App Sandbox entitlement 与真实 entitlement dump;签名等级如实披露,ad-hoc 可接受并注明与 Developer ID 的差异);供 TASK-M0A-007 使用的只读 USB/UART/TCP 测试计划与目标先决条件。本任务不声称真机、Gatekeeper 或分发证据。

## TASK-M0A-005B — Developer ID 原型与干净 VM 信任矩阵

- Status:blocked
- Requirements/AC:AC-HDC-003-01、AC-HDC-006-01、MAC-M0A-TRUST-001、
  MAC-M0A-TRUST-002、MAC-M0A-TRUST-003、MAC-M0A-TRUST-004
- Depends on:TASK-M0A-001、TASK-M0A-002、TASK-M0A-003
- Allowed paths:`ArkDeck.xcodeproj/**`、`ArkDeckApp/**`、`Configurations/**`、`docs/adr/**`、本 change `evidence/**`
- Risk:medium(外部工具与网络);Hardware:no
- Deliverables:非 Sandbox Developer ID + Hardened Runtime 原型与真实 entitlement dump;干净 VM Gatekeeper/quarantine 矩阵(TRUST-001…004)。
- Blocker:无 clean macOS VM snapshot/控制器;`security find-identity -v -p codesigning` 为 `0 valid identities found`(见 `evidence/runs/TASK-M0A-005/run.md`)。维护者于 2026-07-15 决定暂不补齐前提;相关矩阵行以 blocked 状态进入 TASK-M0A-006 汇总,解封需要维护者提供 clean VM 与 Developer ID 证书。

## TASK-M0A-006 — M0A 分发 ADR 与 hash 索引的证据汇总

- Status:done
- Note:交付物见 `docs/adr/0001-macos-v1-distribution.md` 与 `evidence/runs/TASK-M0A-006/`;MAC-M0A-DIST-001 保持 blocked(选定分发的签名产物与 clean-VM 证据不存在),不因任务完成升级。
- Requirements/AC:MAC-M0A-DIST-001
- Depends on:TASK-M0A-002…004、TASK-M0A-005A(TASK-M0A-005B 与 TASK-M0A-007 的矩阵行以 blocked 状态入汇总,不构成完成依赖;ADR 须声明由此缺失的证据基础)
- Allowed paths:`docs/adr/**`、本 change `evidence/**`
- Risk:low;Hardware:no
- Deliverables:选择 Sandbox 或非 Sandbox Developer ID 分发的 ADR(含被拒方案与复验触发);全部矩阵行 passed/failed/blocked 的证据汇总;下一版 macOS profile/verification 修订草案(作为 evidence 提交,另行批准)。

## TASK-M0A-007 — 真机只读 USB/UART/TCP 与持久文件访问矩阵

- Status:blocked
- Requirements/AC:MAC-M0A-SANDBOX-001(minimum evidence:realHardware)
- Depends on:TASK-M0A-005A
- Allowed paths:本 change `evidence/**`
- Risk:medium(真机只读);Hardware:**yes,由人类操作者亲自执行**
- Deliverables:按 TASK-M0A-005A 冻结的只读计划,由人类在真实设备上执行签名原型的 USB/UART/TCP 与文件访问矩阵;非 Sandbox Developer ID 原型的矩阵列因 TASK-M0A-005B blocked 而记录为 blocked,不得伪造;evidence 记录操作者、设备身份/固件/transport、执行时间与逐格结果;destructive dispatch 恒为 0。
- 注:V2 治理下不再需要 lab-authorization JSON;人类执行 + evidence 记录 + PR review 即构成授权链(见 `governance/enforcement.md`)。
- Blocker:M0A 应用壳没有 supervised 只读探测面(TASK-M0A-001 有意设计为纯静态导航;005A 冻结计划第 5 条前置明确"集成不存在时相关格记 blocked,Terminal 直跑 hdc 不能替代")。按计划执行只会产出全 blocked 矩阵,维护者 2026-07-15 决定不执行该形式化真机运行;矩阵移交 M1(chg-2026-002)补齐探测面后以新 change 重测。解封条件:app 提供 supervised 只读探测集成。
