# Tasks

> 垂直 PR 模型(CHG-2026-046):实现、测试、文档、evidence 与状态翻转
> 由一个实现 PR 交付;真机 evidence 与 E1 capability 由后续独立载体
> 补记/签发。

## TASK-DHA-001 — MU-4 垂直交付:Agent runner + Artifact + diagnostics/HAP

- Status:ready（**仅在**承载
  `evidence/runs/TASK-DHA-001/window-attempt-2-plan.md` 的独立 D2 window
  PR 经维护者 review/merge 后生效；attempt#2 只恢复一次
  `DHA-HW-001` E0 Agent execution。attempt#1 的 blocked evidence 已由
  PR #791 合入 `d037768f5e92850861219cd64edf53bfbb4b56ae`；
  contract/fake 结论不变，`DHA-HW-002` 仍未执行）
- Grade:D1(代码/契约/fake 面。真机 host Runtime 由 Device Runtime Agent
  执行;**E1 capability 的签发/接受是 D2 决策**,独立载体,Agent 不得
  自签或自批;人类只提供必要物理协助)
- Platform:macos
- Requirements:兼容实现;POL-AGENT-002 的 E0/E1 分级零弱化
- Acceptance:`DHA-AGENT-001`、`DHA-ART-001`、`DHA-CAP-001`、
  `DHA-HAP-001`(contract/fake,随实现 PR)+ `DHA-HW-001`、
  `DHA-HW-002`(realHardware,Agent 执行后补记;补记前如实标
  hardware-pending)
- Depends on:r2 proposal revision 合并(即 fresh-readiness 批准);
  CHG-2026-046/047/048 已合入，T11 门槛已由 `chg-2026-048` 的
  `BER-HW-001/002` 关闭；`CHG-2026-050/TASK-WSC-001` 已由 PR #789
  合入 `d13dfec6d395dd73662494f16ead9674711fe6ff`(满足)
- Fresh-readiness base:
  `d13dfec6d395dd73662494f16ead9674711fe6ff`
- Readiness input pins:

  ```yaml pins
  - path: Catalog/operations/observe.device.v1.json
    blob: 6efb682bd5e07cd4cab49667b714a889fa44fc56
  - path: Catalog/operations/capture.diagnostics.v1.json
    blob: 37ce723faf58780e00c11f5718f78a4271aef5ae
  - path: Catalog/operations/debug.hap.v1.json
    blob: 1189c9f5d4e73eab71c8ec3d52e7aa53eadf1627
  - path: Catalog/schema/operation.schema.json
    blob: d0320ec62c6346fb59e6fa21d59533e851ce52d0
  - path: openspec/contracts/workflow-step.schema.json
    blob: 91146408bae344df493a1ea21338e2c37114fa45
  - path: openspec/contracts/workflow-step-registry.yaml
    blob: d9121ef78531560ab856dfa07468ce1ab4d42df6
  - path: openspec/contracts/catalogs/diagnostics-stdout.yaml
    blob: 2ba63e79183638bca4202e604bd4816a58014bba
  - path: openspec/contracts/catalogs/remote-operations.yaml
    blob: fe3841d992bbae89bb8f954a1bcdeab0c4f714d1
  - path: openspec/integrations/openharmony/profile.md
    blob: 2ae13490e075f327bb7448ccacf908be5ba7e3aa
  - path: openspec/platforms/macos/profile.md
    blob: b7471666b0bbfbfade3fbd510ad831e45b3cf9b8
  - path: Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogGenerated.swift
    blob: c4f22f82ab983dc6ae8a119d52598aed50d9f434
  - path: Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogTypes.swift
    blob: f51d5f327a12f8f0b681a651c3d435107ccd318e
  - path: Packages/ArkDeckKit/Sources/ArkDeckCore/WorkflowStep.swift
    blob: 6aae31f911ca56f14676c5ae94fd975576daea0f
  - path: Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeCapability.swift
    blob: 24563705c73618cd1fec1bc48ef8d26a311c2d1b
  - path: Packages/ArkDeckKit/Sources/ArkDeckStorage/RuntimeCapabilityStore.swift
    blob: 34b38a58d47709ebb706f0b763126bc4896f233d
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentDeviceOperations/RuntimeOperationModelsV2.swift
    blob: 432765beaf932a7d81a926bfd21e9cf170af4e08
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift
    blob: 476c7c8d1654a50b33913a9fbce94eb0d4e868ea
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderContract.swift
    blob: ad98248aa5b6f28fe0c5a170aa1f76d6a50d912f
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderAdapters.swift
    blob: c9fbd8855cb8214e8d83ffc1faab7f6458d03d99
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/HDCE0ActionPack.swift
    blob: 50db01757444f44d3014322e7c915ed729a261d9
  - path: Packages/ArkDeckKit/Sources/ArkDeckAgentClient/AgentClient.swift
    blob: f73bf875e9a984cef7ff0563280ed06c25b0d119
  - path: Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/AgentDaemon.swift
    blob: 0d72178c976bf9a1b22648a4ff0ea580ace3be35
  ```
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
- Resolved blocker(2026-07-29):`CHG-2026-050/TASK-WSC-001` 已将四个
  stdout step 的 exact `actionRef` 写入 reviewed Catalog 与 generated Swift，
  并使 `arkdeck-diagnostics/boundedHilog|componentTree` 在 JSON Schema 和
  Swift validator 中可如实表达。generator/WorkflowStep 合约与 exact merged
  tree 已复验通过；原 blocker 关闭。
- Saved-draft handoff:原 `agent/task-dha-001` 工作树保留 10 个 tracked
  修改和 5 个 untracked 新文件，未提交、未计 evidence；与
  `dac5f82..d13dfec` 的 main 改动路径交集为 0。r2 合入后恢复时必须先把
  该草稿迁移到 fresh base，并把 stdout action 构造改为消费 generated
  `CatalogStepDescriptor.actionReference`；禁止保留按 `stepID` 猜
  catalog/action 的 fallback。构造的 `WorkflowStep` 还必须携带
  diagnostics contract 要求的 exact typed parameters/bounds。
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
