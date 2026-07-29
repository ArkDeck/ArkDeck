# Tasks

> 垂直 PR 模型(CHG-2026-046):实现、测试、文档、evidence 与状态翻转
> 由一个实现 PR 交付;真机 evidence 与 E1 capability 由后续独立载体
> 补记/签发。

## TASK-DHA-001 — MU-4 垂直交付:Artifact 模型 + capture.diagnostics@1 + E1 pack/debug.hap@1

- Status:ready
- Grade:D1(代码/契约/fake 面。真机执行属设备窗口,由维护者亲手运行;
  **E1 capability 的签发是 D2 决策**,独立载体,Agent 不得自签)
- Platform:macos
- Requirements:兼容实现;POL-AGENT-002 的 E0/E1 分级零弱化
- Acceptance:`DHA-ART-001`、`DHA-CAP-001`、`DHA-HAP-001`(contract/fake,
  随实现 PR)+ `DHA-HW-001`、`DHA-HW-002`(realHardware,窗口后补记;
  补记前如实标 hardware-pending)
- Depends on:本 proposal PR 合并(即批准);CHG-2026-046/047/048 已合入,
  T11 门槛已由 `chg-2026-048` 的 `BER-HW-001/002` 关闭(满足)
- Scope(三子面,不拆分为独立 PR;实现顺序 T14 → T12 → T13):
  1. **T14**:artifact 元数据模型 + 发布/读取/导出面 + quota/retention/
     GC/cleanup debt + 默认 redaction + manifest;补齐 `observe.device@1`
     四 artifact 落盘(MU-3 递延项);daemon `artifact.*` 方法。
  2. **T12**:`capture.diagnostics@1` 编排(含部分成功逐项标注、cancel
     安全边界收取、byte budget 有序截断、远端 cleanup debt)。
  3. **T13**:HDC E1 typed action(send/install/readback/start/stop/
     uninstall/port-forward)+ `debug.hap@1` 编排(readback 判定成功、
     补偿策略、unknown 即停)。
- Verification:见 `verification.md`;contract/fake 随 PR,两条真机窗口后
  补记
- Stop conditions:任何既有测试无法在不弱化断言的前提下保持通过;
  发现需要修改 `Catalog/` 既有 operation 语义或 `openspec/specs/**`;
  发现 E1 判定无法在不看 exit code 的前提下成立——任一命中即停,登记
  blocked 并说明
- Hardware required:yes(仅 `DHA-HW-*` 两条;contract/fake 面不需要。
  `DHA-HW-002` 另需维护者签发的 E1 capability,Agent 零签发、零设备
  命令)
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-049-diagnostics-and-hap/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、
    `openspec/contracts/**`、`openspec/verification/**`(全局)、
    `openspec/integrations/**`、`openspec/platforms/**`、
    `openspec/baselines/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(首个 E1 mutation 面——以 catalog effect 上限、capability
  fail-closed、readback 判定、unknown 即停四层约束;artifact 面触及磁盘
  与隐私——以 quota、redaction、privacy class 三层约束)
