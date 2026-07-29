# Tasks

> 垂直 PR 模型(CHG-2026-046):实现、测试、文档、evidence 与状态翻转
> 由一个实现 PR 交付。

## TASK-URB-001 — MU-2 垂直交付:Provider Contract + HDC Foundation + agentd + Job Engine

- Status:ready
- Grade:D1(纯代码 + 契约/fake 测试;零真实设备 dispatch、零 E2 面变更、
  零既有安全门放宽)
- Platform:macos
- Requirements:兼容实现,不主张 canonical Core Requirement;复用并接入
  既有 journal/state machine/binding/authorization 语义
- Acceptance:`URB-PROV-001`、`URB-HDC-001`、`URB-DAEMON-001`、
  `URB-JOB-001`、`URB-COMPAT-001`
- Depends on:本 proposal PR 合并(即批准);CHG-2026-046 已合入
  (#773/#774,满足)
- Scope(四子面,不拆分为独立 PR):
  1. **T05**:`DeviceProvider` 协议 + typed action 封闭枚举 + HDC/Rockchip
     adapter(包既有栈,零第二状态机);
  2. **T06**:`HDCProduction.swift` 职责拆分(纯移动)+
     `HDCCompatibilityProfile` + 观察族 semantic parser(E0 版本 profile
     判定,destructive pin 不动);
  3. **T07**:`ArkDeckAgentDaemon`/`arkdeck-agentd`/`ArkDeckAgentClient`
     三目标 + UDS 版本化 JSON 协议 + single-instance + 全 API handler;
  4. **T08**:`RuntimeJobEngine`(catalog 校验 → capability →durable
     idempotency → WAL intent → dispatch → verify → durable outcome;
     重启恢复;设备互斥;安全边界 cancel)。
- Verification:见 `verification.md`;contract + fake integration
  (含 crash-window 进程级 fixture),无硬件 evidence 主张
- Stop conditions:任何既有测试无法在不弱化断言的前提下保持通过;
  `HDCProduction.swift` 拆分无法做到纯移动(需语义改动才能编译);
  发现需要改 `openspec/specs/**`/`Catalog/` 数据/E2 门槛——任一命中即停,
  登记 blocked 并说明
- Hardware required:no(真实设备验收属 MU-3 起)
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-047-unified-runtime-foundation/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、
    `openspec/contracts/**`、`openspec/verification/**`(全局)、
    `openspec/integrations/**`、`openspec/platforms/**`、
    `openspec/baselines/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:medium-high(HDC 拆分体量大——以"纯移动 + 全量套件字节级行为
  对齐"约束;daemon 为新面——以零网络、仅本用户 socket、协议 fail-closed
  约束)
