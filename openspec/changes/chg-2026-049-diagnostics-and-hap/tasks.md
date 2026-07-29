# Tasks

> 垂直 PR 模型(CHG-2026-046):实现、测试、文档、evidence 与状态翻转
> 由一个实现 PR 交付;真机 evidence 与 E1 capability 由后续独立载体
> 补记/签发。

## TASK-DHA-001 — MU-4 垂直交付:Agent runner + Artifact + diagnostics/HAP

- Status:blocked
- Grade:D1(代码/契约/fake 面。真机 host Runtime 由 Device Runtime Agent
  执行;**E1 capability 的签发/接受是 D2 决策**,独立载体,Agent 不得
  自签或自批;人类只提供必要物理协助)
- Platform:macos
- Requirements:兼容实现;POL-AGENT-002 的 E0/E1 分级零弱化
- Acceptance:`DHA-AGENT-001`、`DHA-ART-001`、`DHA-CAP-001`、
  `DHA-HAP-001`(contract/fake,随实现 PR)+ `DHA-HW-001`、
  `DHA-HW-002`(realHardware,Agent 执行后补记;补记前如实标
  hardware-pending)
- Depends on:本 proposal PR 合并(即批准);CHG-2026-046/047/048 已合入,
  T11 门槛已由 `chg-2026-048` 的 `BER-HW-001/002` 关闭(满足)
- Scope(四子面,不拆分为独立 PR;实现顺序 T00 → T14 → T12 → T13):
  1. **T00**:one-shot Device Runtime Agent runner(只经 AgentClient/daemon
     typed API) + structured humanAction pause/resume + 脱敏 execution
     receipt;Agent surface 无 HDC/argv/shell 与 capability 管理入口。
  2. **T14**:artifact 元数据模型 + 发布/读取/导出面 + quota/retention/
     GC/cleanup debt + 默认 redaction + manifest;补齐 `observe.device@1`
     四 artifact 落盘(MU-3 递延项);daemon `artifact.*` 方法。
  3. **T12**:`capture.diagnostics@1` 编排(授权前按选中步骤计算 effective
     effect;remote trace/cleanup 升为 E1;含部分成功逐项标注、cancel
     安全边界收取、byte budget 有序截断、远端 cleanup debt)。
  4. **T13**:HDC E1 typed action(send/install/readback/start/stop/
     uninstall/port-forward)+ `debug.hap@1` 编排(readback 判定成功、
     补偿策略、unknown 即停)。
- Verification:见 `verification.md`;contract/fake 随 PR,两条真机由
  Device Runtime Agent 执行后补记
- Stop conditions:任何既有测试无法在不弱化断言的前提下保持通过;
  发现需要修改 `Catalog/` 既有 operation 语义或 `openspec/specs/**`;
  发现 E1 判定无法在不看 exit code 的前提下成立;发现 remote trace/
  cleanup 无法在 dispatch 前升级 effective effect;发现真机 AC 只能靠
  维护者代跑 host CLI——任一命中即停,登记 blocked 并说明
- Blocker(2026-07-29):实现 `capture-hilog` durable typed intent 时确认
  current `captureRemoteStdout` schema/Swift validator 只允许
  `arkui-ui-dump` action，无法如实表示 Catalog 已发布的 HiLog step；
  以 UI Dump action 冒充会伪造 journal evidence。已按 stop condition
  停止并起草 `CHG-2026-050-diagnostics-step-contract`。该 change 完成并
  合入后，本任务仍需 fresh readiness PR 才可恢复为 ready。
- Hardware required:yes(仅 `DHA-HW-*` 两条;contract/fake 面不需要。
  硬件存在不等于人工执行:`DHA-HW-001` 由 Agent 直接走 E0;
  `DHA-HW-002` 在维护者签发/接受 E1 capability 后由 Agent 执行。
  Agent 零签发/零自批;人类仅处理设备信任、歧义选择与物理动作)
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
- Risk:high(首个 Agent-operated E1 mutation 面——以 plan effective effect、
  capability fail-closed、readback 判定、unknown 即停四层约束;artifact
  面触及磁盘与隐私——以 quota、redaction、privacy class 三层约束)
