# Tasks — CHG-2026-002 macOS M1 shared infrastructure

> V2 治理:本文件是任务的唯一事实源。change 尚为 proposed;approved 前任务不可执行。

## TASK-M1-001 — ArkDeckCore 域模型、封闭 typed-step registry 与 Job 状态机

- Status:ready(待 change approved)
- Requirements/AC:AC-WF-001-01、AC-WF-002-01 等
- Depends on:none
- Allowed paths:`Packages/ArkDeckKit/Sources/ArkDeckCore/**`、对应 Tests、本 change `evidence/**`
- Deliverables:未知 kind 按 destructive/unsupported 拒绝的封闭 WorkflowStep decode;精确 Core 迁移图的 Job/终态状态机与 property tests;保持原始失败分类的补偿顺序。

## TASK-M1-002 — 生产级 ProcessExecutor(语义结果分类、有界流)

- Status:ready(待 change approved)
- Requirements/AC:AC-JOB-005-01、AC-NFR-002-01 等
- Depends on:TASK-M1-001
- Allowed paths:`.../ArkDeckProcess/**`、对应 Tests 与 Fixtures、本 change `evidence/**`
- Deliverables:argv 启动、byte-safe 流、timeout/cancel;exit-0 ≠ 成功的语义层;大输出 fixture 与有界内存断言。

## TASK-M1-003 — write-ahead journal、snapshot、崩溃 reconcile 与审计放弃

- Status:ready(待 change approved)
- Requirements/AC:AC-JOB-002-01、AC-JOB-006-01 等
- Depends on:TASK-M1-001
- Allowed paths:`.../ArkDeckStorage/**`、`.../ArkDeckWorkflows/**`、对应 Tests、本 change `evidence/**`
- Deliverables:append-only intent/outcome journal、原子 snapshot 替换、torn-tail 检测;intent-without-outcome → outcomeUnknown 且永不重放 destructive;审计化放弃与设备 hazard 保留。

## TASK-M1-004 — macOS runtime ports:单实例、激活、电源、双时钟、睡眠观察

- Status:ready(待 change approved)
- Requirements/AC:AC-JOB-008-01、AC-NFR-001-01 等
- Depends on:TASK-M1-001
- Allowed paths:`.../ArkDeckRuntime/**`、对应 Tests、本 change `evidence/**`

## TASK-M1-005 — Session/Artifact store、manifest 管线与 host-volume 协调

- Status:ready(待 change approved)
- Requirements/AC:AC-ART-001-01、AC-ART-002-01、AC-STO-* 等
- Depends on:TASK-M1-001、TASK-M1-003
- Allowed paths:`.../ArkDeckStorage/**`、对应 Tests、本 change `evidence/**`

## TASK-M1-006 — HDC supervisor、endpoint 隔离、授权工作流与 fake-hdc 对抗

- Status:ready(待 change approved)
- Requirements/AC:AC-HDC-001-01/02、AC-HDC-005-01(parserGolden,fixture 在本 change 落地)等
- Depends on:TASK-M1-002、TASK-M1-003
- Allowed paths:`.../ArkDeckOpenHarmony/**`、对应 Tests 与 Fixtures、本 change `evidence/**`

## TASK-M1-007 — device binding revision、transport 重绑定边界与 per-device mutation lane

- Status:ready(待 change approved)
- Requirements/AC:AC-DEV-001-01、AC-DEV-002-01 等
- Depends on:TASK-M1-006
- Allowed paths:`.../ArkDeckOpenHarmony/**`、`.../ArkDeckWorkflows/**`、对应 Tests、本 change `evidence/**`

## TASK-M1-008 — SimulatedFlashProvider 隔离 harness

- Status:ready(待 change approved)
- Requirements/AC:AC-FLASH-006-01、MAC-M1-SIM-001
- Depends on:TASK-M1-003、TASK-M1-007
- Allowed paths:`.../ArkDeckWorkflows/**`、对应 Tests、本 change `evidence/**`
- Deliverables:可配置延迟/失败/断连/outcomeUnknown 的合成设备 provider;不接受真实 connectKey、不启动外部工具的隔离证明;simulated 证据永不进入硬件支持矩阵。

## TASK-M1-009 — 诊断骨架:分类脱敏日志与有界本地诊断导出

- Status:ready(待 change approved)
- Requirements/AC:AC-DIAG-001-01/02 等
- Depends on:TASK-M1-001
- Allowed paths:`.../ArkDeckRuntime/**`、`.../ArkDeckStorage/**`、对应 Tests、本 change `evidence/**`
