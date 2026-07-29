# Tasks

> 垂直 PR 模型(CHG-2026-046):实现、测试、文档、evidence 与状态翻转
> 由一个实现 PR 交付;真机 evidence 由设备窗口后 evidence-only PR 补记。

## TASK-BER-001 — MU-3 垂直交付:Bootstrap + E0 Action Pack + 真实 walking skeleton

- Status:done
- Done scope(**代码面 done,硬件面 pending**):`BER-BOOT-001`/
  `BER-E0-001`/`BER-SKEL-001` 由实现 PR 交付并通过
  (`evidence/runs/TASK-BER-001/run-r1.md`;swift 607/1 skipped/0
  failures,含 24 项新测试与两条自测发现缺陷的回归+变异对照;
  check-sdd 0/0/111)。**`BER-HW-001`/`BER-HW-002` 仍未满足
  (hardware-pending)**:需维护者设备窗口,计划见
  `evidence/runs/TASK-BER-001/device-window-plan.md`,窗口后以
  evidence-only PR 补记。**T11 是清单强制门槛:两条真机 AC 关闭前
  不开工 MU-4。**
- Grade:D1(代码/契约/fake 面;真机执行属设备窗口,由维护者亲手运行,
  Agent 零设备命令——窗口安排本身是 D2 决策,独立载体)
- Platform:macos
- Requirements:兼容实现;E0 执行分级与 POL-AGENT-002 零弱化
- Acceptance:`BER-BOOT-001`、`BER-E0-001`、`BER-SKEL-001`(contract/
  fake,随实现 PR)+ `BER-HW-001`、`BER-HW-002`(realHardware,窗口后
  补记;补记前实现 PR 内如实标 hardware-pending)
- Depends on:本 proposal PR 合并(即批准);CHG-2026-046/047 已合入
  (满足)
- Scope(三子面,不拆分为独立 PR):
  1. **T09**:Bootstrap 状态机(E0-only、waitForPhysicalTrust、幂等
     adopt、durable target 存储)+ daemon doctor/target.* 转正 + CLI
     doctor/device list/adopt;
  2. **T10**:HDC E0 typed action 全集(property/HiLog/UI Dump/trace/
     receive artifact/temp cleanup,有界 typed 输入 + semantic parser +
     provider-owned remote temp);
  3. **T11**:生产 dispatcher(descriptor 绑定)+ HDC 生产 facts/
     lowering 组合 + observe.device@1 端到端(CLI→daemon→engine→
     artifacts→restart 可查;identity mismatch fail-closed)。
- Verification:见 `verification.md`;contract/fake 随 PR,真机两条
  窗口后补记
- Stop conditions:任何既有测试无法在不弱化断言的前提下保持通过;
  发现需要 mutation 面才能完成 bootstrap;发现需改 `Catalog/` 数据或
  `openspec/specs/**`——任一命中即停,登记 blocked 并说明
- Hardware required:yes(仅 `BER-HW-*` 两条;contract/fake 面不需要。
  真机执行 = 维护者设备窗口亲手运行,Agent 起草步骤与核验,零设备
  命令、零 destructive dispatch)
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-048-bootstrap-and-real-e0/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、
    `openspec/contracts/**`、`openspec/verification/**`(全局)、
    `openspec/integrations/**`、`openspec/platforms/**`、
    `openspec/baselines/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:medium-high(生产 dispatch 首次接线——以 descriptor 校验、
  E0 默认策略、profile fail-closed 三层约束;bootstrap 为新 admission
  面——以结构性 E0-only 约束)
