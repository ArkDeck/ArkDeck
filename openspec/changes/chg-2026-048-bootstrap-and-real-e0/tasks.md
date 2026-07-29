# Tasks

> 垂直 PR 模型(CHG-2026-046):实现、测试、文档、evidence 与状态翻转
> 由一个实现 PR 交付;真机 evidence 由设备窗口后 evidence-only PR 补记。
>
> r2 scope reconciliation:T11 的 change-local 闭环止于 succeeded +
> durable timeline/restart query；artifact 文件发布与 `artifact.*` 读取
> 递延 T14(CHG-2026-049)，不作为本任务完成或验证的依据。
>
> r3 verification audit:TASK-BER-001 的历史交付/PR 记录不改写，但
> binding admission 与 formal hardware evidence 尚未满足现行 AC；
> T11 gate 重新打开，由 TASK-BER-002 顺序补救。

## TASK-BER-001 — MU-3 垂直交付:Bootstrap + E0 Action Pack + 真实 walking skeleton

- Status:done
- Done scope(**代码面与硬件面均已满足**):
  - contract/fake 面 `BER-BOOT-001`/`BER-E0-001`/`BER-SKEL-001` 由实现
    PR 交付并通过(`evidence/runs/TASK-BER-001/run-r1.md`);
  - **`BER-HW-001`/`BER-HW-002` 于 2026-07-29 设备窗口 attempt#2 通过**
    (`evidence/runs/TASK-BER-001/window-attempt-2.md`;真 DAYU200 +
    HDC 3.2.0f,`observe.device@1` succeeded 且 timeline 完整,重启后
    历史逐字保持、unknown job 跨三次重启零重发,拔插后同一 targetId);
  - attempt#1 如实记为 blocked-attempt
    (`evidence/runs/TASK-BER-001/window-attempt-1.md`),其暴露的
    checkserver 语义与 daemon 退出两缺陷由 PR #783 修复,判据未改。
  - 基线:swift 609/1 skipped/0 failures;check-sdd 0/0/111。
  **T11 强制门槛已关闭。**
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
     succeeded + durable timeline→restart 可查;identity mismatch
     fail-closed)。
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

## TASK-BER-002 — binding admission 与 formal hardware evidence 补救

- Status:blocked（PR #804 已批准 `CHG-2026-051@r2` 独占
  exact-target/model/firmware typed preflight、hardware-evidence V3 与
  Runtime receipt/projector；必须等待其 TASK-AHE-001 done 且 change
  verified/archive，再以独立 r4 D1 fresh-readiness 恢复。blocked 期间
  implementation PR、D2 window 与 device dispatch 均为 0）
- Grade:D1（dependency/fresh-readiness 与必要 remediation；
  未来真实设备窗口安排仍是独立 D2 决策）
- Platform:macos
- Objective:在不放宽 `BER-SKEL-001`/`BER-HW-002`、不抢占
  CHG-2026-051 ownership 的前提下，消费其晋升后的 current
  target/evidence contract，关闭本 change 的 drift/restart 验证并取得
  fresh schema-valid realHardware evidence。
- Acceptance:`BER-SKEL-001`（binding/identity drift contract 负向）、
  `BER-HW-002`（non-terminal restart、rebind、mismatch fail-closed）；
  `BER-HW-001` 的既有真机成功只作历史输入，新窗口仍须产生一份完整
  schema record，不能借旧字段猜填。
- Depends on:r3 proposal revision merge；r2 PR #802 merge
  `34204b304efa9887dc811e7d99420df4519168ea`（满足）；
  CHG-2026-051 r2 PR #804 merge
  `a09d3243b8bdec133198f843d4c258d39f54aa34`（proposal only，任务与
  change gate 未满足）；CHG-2026-046/047 已 archived（满足）。
- Scope while blocked:
  1. 零代码/Catalog/schema/current spec 修改，零 D2 window、零设备执行；
  2. 只记录 dependency 与 verification blocker，不把 CHG-2026-051 的
     approved scoped delta 当作 current contract。
- Resume scope（仅在 dependency verified/archive 后，由 r4 批准）:
  1. fresh pin current baseline、hardware-evidence schema、三个 operation
     Catalog、generated Swift、production facts/engine/receipt/projector；
  2. 重放 missing target、wrong revision、live identity mismatch、
     matching happy path、descriptor drift、non-terminal restart contracts；
  3. 若 current 实现仍不满足本 AC，r4 列出最小 remediation + allowed
     paths；否则只交付复验 run；
  4. contract 合入后另开 D2 window PR，按届时 current executor/evidence
     模型 fresh 运行并提交 schema-valid record；旧 #784 不追认。
- Verification:见 `verification.md` r3；blocked 期间只允许 read-only
  dependency audit。恢复后的具体命令、pins 与 evidence schema 由 r4
  固定，r3 不提前猜测。
- Stop conditions:CHG-2026-051 未 archived；需要借用其 change-local
  delta；current target/evidence contract 仍无法二值化本 AC；负向仍有
  未允许的后续推进；只能靠旧 run/人工补字段/fixture 充当真机——任一
  命中即保持 blocked，不弱化 AC、不猜 evidence。
- Hardware required:yes（仅在 dependency + r4 + contract/remediation
  gates 全部合入后的独立 D2 窗口）
- Allowed paths while blocked:
  - `openspec/changes/chg-2026-048-bootstrap-and-real-e0/**`
- Forbidden paths:
  - `Packages/**`、`Catalog/**`、`openspec/specs/**`、
    `openspec/contracts/**`、`openspec/verification/**`（全局）、
    `openspec/integrations/**`、`openspec/platforms/**`、
    `openspec/baselines/**`
  - `scripts/**`、`.github/**`、`AGENTS.md`、`ArkDeck.xcodeproj/**`、
    `ArkDeckApp/**`、其他 change 目录
- Risk:medium-high（跨 change Core/current-contract dependency；以
  ownership 单一、archive 后 fresh pin、旧 evidence 不追认、D2 延后
  四层约束）
