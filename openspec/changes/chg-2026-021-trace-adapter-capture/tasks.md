# CHG-2026-021 Tasks

> r1 三任务分期实现；r2 新增 TASK-TR-002R remediation。每个任务各自独立
> readiness/实现/done PR。真机采集由人类维护者亲手执行,Agent 零设备命令。

## TASK-TR-001 — trace 工具 provenance 登记(integration 面,device-gated)

- Status:ready(readiness;仅在维护者 review/merge 本独立状态 PR 后生效。单文件、
  不含实现、不产生 evidence、不执行真机)
- Readiness review(2026-07-21;host-only,零设备命令):
  - Approve gate:satisfied(#253 squash `684c42c`);design §0 候选命令面、§4
    登记形态随批准生效。
  - 执行时 pins(本 readiness 实测复核):hdc = DevEco toolchains 路径,SHA-256
    `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`、
    `Ver: 3.2.0d`(与 M0B/I15 pinned tuple 逐字一致);设备 = DAYU200 OpenHarmony
    7.0.0.34(M0B evidence `EVD-M0B-DAYU200-20260718-001`)。采集前须再复核,
    任一漂移即停。
  - runbook/harness:属本任务实现交付物(in scope 既列)——封闭白名单
    (hitrace/bytrace 存在/help/tag-list 探测 + 最小 capture + recv)在实现 PR
    起草并经维护者 review 后方可用于窗口;形态复用 m0b/ud harness 信任链
    (argv 无 shell、分流 byte-exact、敏感自检、redacted manifests)与既有
    redaction 工具链;白名单外命令零授权。
  - 具名设备窗口:维护者自选的连续设备窗口,窗口内无其他设备操作并行(与
    TASK-M0B-002、chg-008 Phase B 等互斥,可同日先后);执行前在 run.md 记录
    实际日期/时段。
  - 执行模型:维护者亲手跑 runbook,Agent 零设备命令、只起草/核验/起草
    evidence;trace 采集含 deviceMutation 级 capture(非 destructive),参数
    set/restore 若用须逐项确认+readback+恢复;中止如实记录 blocked-attempt。
  - Review boundary:本 readiness 只翻转状态并记录 pins/窗口/执行模型;实现
    (runbook+采集+登记)仍须满足 TRACE-PROV-001 与 verification gate;
    `ready→done` 另用独立状态 PR。
- Objective:在 DAYU200 真机受控采集 hitrace/bytrace 的存在/help/tag-list/最小
  capture 输出,登记版本化 trace probe/golden registry(design §4 形态),bump
  OPENHARMONY-TOOLS 与 INTEGRATION-PROFILES.lock。
- Requirements/AC:change-local `TRACE-PROV-001`(见 acceptance-cases.yaml);为
  TASK-TR-003 的 `AC-TRACE-001-01`/`AC-TRACE-007-01`(parserGolden)提供 fixture
  事实前置。
- Depends on:approve;M0B-001 done(设备/授权/工具链事实,已满足);采集 harness
  (scripts/ud_capture 或 m0b_capture 复用评估归 readiness)。
- In scope:采集 runbook(Agent 起草、维护者执行)、registry + golden fixtures +
  hash closure + redacted manifests、integration profile/lock bump、evidence run。
- Out of scope:adapter 实现(TR-003);Core/spec 改写;trace 之外命令。
- Allowed paths(approve/readiness 后细化):`openspec/integrations/**`、
  `scripts/**`(采集 harness 若需新增)、本 change `evidence/**`、本 change
  `tasks.md`(仅本任务状态)。
- Risk:medium(真机在场;采集含 deviceMutation 级 capture 与可选参数 set/restore,
  非 destructive;设备窗口与其他设备任务互斥)。
- Hardware required:yes(物理 DAYU200 + USB;操作者=维护者)。
- Verification:registry/golden 逐文件 SHA-256 closure、redaction 自检、
  `TRACE-PROV-001` documentReview;中止如实记录 blocked-attempt。

## TASK-TR-002 — host contract 面(typed trace workflow,零设备)

- Status:done(TASK-TR-002 implementation + evidence PR #270 已由维护者 review/merge
  合入 `main` merge commit `cec2cc20c995471602cdd056ec5d9a2460b48ecc`;本独立状态
  PR 依据下列 completion evidence 起草 `ready→done`,仅在维护者 review/merge 后生效。
  本状态只关闭 host-only typed trace workflow contract 面,不改变 TASK-TR-001
  (`ready`)、TASK-TR-003(`blocked`)、change `verified`、真实 adapter/provenance、
  hardware/compatibility/support/conformance/release 状态)
- Done recheck(2026-07-21;于合入版 `main` `cec2cc2`):
  - implementation source `40cce74ec285a0049364ded00be97fbef1cac9b0`;六个交付文件
    均在 allowed paths,不含 `tasks.md` 状态、真实 hitrace/bytrace argv/parser、CLI/UI、
    Core/schema 或真实设备 dispatch。
  - `TraceWorkflowContractTests` 14/0,七条 canonical AC PASS 行全部复现;Swift 全量
    316 tests/1 个既有 opt-in skip/0 failures;`check-sdd` 0 errors/0 warnings/111
    acceptance IDs。
  - evidence class 保持 `contract`,全部 Trace 观察为 in-memory synthetic;真实
    device/HDC/network/external-process dispatch = 0,不冒充 provenance 或真机证据。
- Completion evidence:`evidence/runs/TASK-TR-002/run.md`(七条认领 AC 均 PASS;
  catalog pins、scope、命令结果、偏差与 residual risk 可复查),并由
  `evidence/summary.md` 限定 claim 边界。
- Readiness review(2026-07-21;host-only,零设备命令):
  - Approve gate:satisfied(#253 squash `684c42c`);三任务 scope/design 约束/
    认领面随批准生效。
  - 基座 pins(于 main `1e4a7c4` 实测):catalog `trace-presets`@1.0.0
    (`12c0f050…`)与 `attachment-debug-profile`@1.0.0(`10ee4c38…`)已登记
    INTEGRATION-PROFILES.lock 0.4.0;所需 WorkflowStep kind 全部在 CORE-2.1.0
    契约在案(design §1 映射)。实现时 catalog hash 漂移即停。
  - 基线:Swift 全量 302/1 skip/0 failures、check-sdd 0/0/111(均于 `1e4a7c4`
    实测)。
  - 竞争面:复核时 open PR 为 0;**文件级分工**——本任务只在
    `Sources/ArkDeckWorkflows` 新增 `Trace*` 前缀新文件 + 对应 Tests 新文件,
    不触碰 `HDC*`/`Rockchip*`/`Simulated*` 既有文件;与 TASK-OBS-001
    (CHG-2026-022,supervisor 既有文件面)零文件交集,可并行执行;与 chg-008
    线零交集。
  - 实现序:typed trace workflow(catalog 消费/capability 受限配置 → 参数
    snapshot/set-readback/restore(catalog 绑定收紧,design §3)→ 隔离接收/
    partial → progress/completeness → reboot/rebind 面)→ 7 条 contract AC 测试
    逐条 PASS → evidence run。fake/fixture 一律显式标注,不冒充已登记 adapter
    形态(TR-001 未 done,不实现任何真实输出解析)。
  - Review boundary:本 readiness 只翻转状态并记录 pins/分工/序;实现仍须满足
    全部认领 AC/verification gate;`ready→done` 另用独立状态 PR。
- Objective:实现 typed trace workflow 的 host contract 面:capability 受限配置
  (trace-presets catalog)、参数 snapshot/set-readback/restore(绑定
  attachment-debug-profile,design §3 收紧)、隔离接收/partial、honest progress、
  artifact completeness、reboot→binding 恢复;contract 测试全绿。
- Requirements/AC:认领 `AC-TRACE-002-01`/`003-01`/`004-01`/`005-01`/`006-01`/
  `008-01`/`009-01`(7 条,canonical method 均 contract);复用 M1 seam(design §1)
  不改其语义。
- Depends on:approve;两 catalog 已登记(lock 0.4.0,满足);无 TR-001 依赖
  (不实现真实 adapter 解析)。
- In scope:Sources/ArkDeckWorkflows trace workflow + 对应 contract 测试 + evidence
  run;fake/fixture 一律显式标注,不冒充已登记 adapter 形态。
- Out of scope:hitrace/bytrace 真实输出解析(TR-003);CLI/UI 接入(独立后续);
  Core kind/schema 变更。
- Allowed paths(approve/readiness 后细化):`Packages/ArkDeckKit/Sources/**`、
  对应 Tests、本 change `evidence/**`、本 change `tasks.md`(仅本任务状态)。
- Risk:low-medium(host-only;deviceMutation 语义面须 fail-closed 方向)。
- Hardware required:no。
- Verification:7 AC contract 测试逐条 PASS 行、全量基线零回归、check-sdd 绿。

## TASK-TR-003 — adapter golden 面(hitrace/bytrace 识别与 ftrace 过滤)

- Status:blocked(四前置:① approve;② TASK-TR-001 done(golden fixture/registry
  在案);③ TASK-TR-002R done;④ 独立 readiness PR——须钉 TR-001 登记的
  registry/fixture hash)
- Objective:实现 adapter 选择(help family 识别,未知 fail-closed)与 ftrace
  header 保留过滤,against TR-001 golden fixture;parserGolden 测试全绿。
- Requirements/AC:认领 `AC-TRACE-001-01`/`AC-TRACE-007-01`(parserGolden)。
- Depends on:approve、TASK-TR-001 done、TASK-TR-002 done(workflow 骨架)、
  TASK-TR-002R done(host-contract remediation)。
- In scope:adapter family 解析器 + golden 测试 + evidence run。
- Out of scope:未登记 family 的任何支持声明;新固件族。
- Allowed paths(approve/readiness 后细化):`Packages/ArkDeckKit/Sources/**`、
  对应 Tests、本 change `evidence/**`、本 change `tasks.md`(仅本任务状态)。
- Risk:low(host-only,golden 驱动)。
- Hardware required:no(fixture 已由 TR-001 登记)。
- Verification:2 AC parserGolden 测试 PASS、fixture hash 与 registry closure 一致。

## TASK-TR-002R — remediate trace host-contract fail-closed gates

- Status:ready(readiness;仅在维护者 review/merge 本独立状态 PR 后生效；本 PR 只修改
  `tasks.md`，不含实现/evidence，不执行 device/HDC/network/external-process)
- Readiness review(2026-07-22;host-only,零设备命令):
  - Approve gate:satisfied。r2 amendment PR #276 已由维护者 `lvye` APPROVED 并合入
    `main` merge commit
    `6e85a784579809b0b79a95bb117d48033892fdf4`；本 readiness 以该完整 OID 为 base。
  - 待改 source blob pins(实现时任一漂移即停并重做 readiness):
    `TraceCatalogContracts.swift` = `95fe72b406c615f6d99b381a4c08c770d6279c00`、
    `TraceParameterContracts.swift` = `e1e2a8b692e71c78bf66195b645335b1ba122840`、
    `TraceWorkflowContracts.swift` = `f6cbec4bb9fe8f441d83c54931b8c378c106f06d`；
    唯一测试文件 `TraceWorkflowContractTests.swift` =
    `553cd7d436b83ea732adb072d258151734cdc745`。
  - 只读 seam pins(不得在本任务修改):`ArtifactStorage.swift` =
    `635f4da53094305dc52dff6ebdb26e1ccb026ea1`、`SessionLayout.swift` =
    `ed48f90a96ee239769e86727ae9272017fea72f7`、`SessionStorageTypes.swift` =
    `04aa1c185defc6bdc5da0c041b20d5c538e167f2`、`HostStorage.swift` =
    `e052657f08c6ef98fa1019269541a1ad5deb7000`、`DeviceTargeting.swift` =
    `13a052ba2359e90bfe86fed4884b10fa1f4dd5cf`、`Package.swift` =
    `a47bccf05a0c044ef506ddd015fe8c0ecaaa89e2`。
    `ArkDeckWorkflows` 已依赖 `ArkDeckStorage`；现有 public
    `SessionArtifactStore.publish(from:request:claim:) -> PublishedArtifact`、
    `SessionLayout.partialDirectory`、`SessionStorageFaultInjector`/publication fault
    points 与 `DurableCurrentDeviceBinding`/`DeviceBindingReference` 足以在四个 allowed
    文件内闭环。若实现证明不足，任务必须停回 blocked 并先做 scope amendment。
  - 实现序与二值门:
    ① expected target + pre-reboot revision + exact selected candidate 创建 rebind context，
    wrong target、same/older/skipped revision、connect key/transport/identity drift 全部
    capture dispatch=0，只有 exact `revision + 1` receipt 产生携带新 binding reference 的
    capture authorization/plan；② receive 只写 `artifacts/partial/*.part`，调用真实 store
    publication，并且只有匹配 `PublishedArtifact` 才能产生 remote-cleanup authority；对
    write/source validation/file sync/validation/rename/final+partial directory sync/recovery
    fault 逐项注入，cleanup dispatch 恒为 0；③ parameter capability receipt 固定 durable
    binding + 参数名 + disposition，缺失/unsupported/permissionDenied/
    needsDeveloperMode/unknown/stale/wrong-name 全阻断，persistent 另需显式 capability +
    confirmation；④ reliable-total receipt 只能由当前 adapter capability=true factory
    产生，false/缺失/drift/非法 total 均保持 indeterminate + elapsed。
  - 基线(Apple Swift 6.3.3、Xcode 26.6/17F113):`swift build --build-tests` PASS
    (仅既有 no-async-await warnings)；`TraceWorkflowContractTests` 14/0；
    `SessionArtifactStorageContractTests` 58/0；Swift 全量 316 tests/1 个既有 opt-in
    skip/0 failures；`check-sdd` 0 errors/0 warnings/111 acceptance IDs。
  - 竞争/隐私边界:readiness 审计时 open PR=0；工作树既有未追踪 fixture/log/branch
    snapshot 均在 allowed paths 外并保持不动。本任务不得读取或记录真实设备标识、
    用户路径、secret 或 raw Artifact；所有新测试仅使用 synthetic identity 和临时目录。
  - Review boundary:本 PR 只翻转 `blocked→ready` 并登记 pins/测试矩阵；实现+evidence、
    `ready→done` 与 change `verified` 仍分别使用独立 PR，且均须维护者 review/merge。
- Platform:macos
- Objective:修复 TASK-TR-002 post-merge review 的四个缺口：reboot durable binding
  continuity、SessionArtifactStore atomic-publication → remote-cleanup authority、typed
  per-device parameter capability、capability-gated reliable progress total。
- Requirements/AC:重新验证 `AC-TRACE-003-01`/`004-01`/`005-01`/`006-01`/
  `008-01`；change-local `TRACE-REBIND-GATE-001`、`TRACE-ATOMIC-PUBLISH-001`、
  `TRACE-PARAM-CAPABILITY-001`、`TRACE-PROGRESS-CAPABILITY-001`。
- Depends on:r2 amendment approval、TASK-TR-002 done(已满足)、独立 readiness PR。
- Allowed paths after readiness:
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/TraceCatalogContracts.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/TraceParameterContracts.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/TraceWorkflowContracts.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/TraceWorkflowContractTests.swift`
  - `openspec/changes/chg-2026-021-trace-adapter-capture/evidence/**`
  - 本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`
  - `openspec/specs/**`、`openspec/contracts/**`、`openspec/baselines/**`
  - `openspec/contracts/catalogs/**`、`openspec/integrations/**`
  - `ArkDeckApp/**`、`ArkDeckAppUITests/**`、`ArkDeck.xcodeproj/**`
  - TASK-TR-001/002/003 的既有 evidence
- Risk:high(host-only，但控制 device mutation、远端清理与身份绑定授权边界)。
- Hardware required:no；只允许 deterministic contract/fault-injection，真实 device/HDC/
  network/external-process dispatch 恒为 0。

### Deliverables

- reboot gate 验证 expected target/candidate 与 exact +1 durable revision，并将新 binding
  reference 保留到 capture authorization/device steps；
- receive flow 使用 `artifacts/partial/*.part`，由真实 `SessionArtifactStore.publish`
  返回值生成 cleanup authority；发布成功前不存在 cleanup step；
- 参数 mutation authorization 要求与当前 durable binding 匹配的 typed per-device probe
  capability，persistent mode 另要求 persistent write supported + 显式确认；
- reliable total 只能由 adapter capability-gated factory/receipt 生成；capability=false
  即使提供 total 仍 indeterminate；
- 四项 change-local tests 与五条受影响 canonical AC 的回归证据。

### Verification

- 定向运行 `TraceWorkflowContractTests`，覆盖 verification.md r2 matrix 的全部 positive/
  negative/fault-injection branch；
- `swift build --package-path Packages/ArkDeckKit --build-tests`；
  `swift test --package-path Packages/ArkDeckKit --filter TraceWorkflowContractTests`；
  `swift test --package-path Packages/ArkDeckKit`；`scripts/check-sdd.sh`；
  `git diff --check`；allowed/forbidden-path 与 secret/privacy scan；
- 在 `evidence/runs/TASK-TR-002R/run.md` 记录 pinned base/blob、完整命令与结果、九项
  AC/evidence ID 二值结论、dispatch counters、偏差与 residual risk。

### PR boundary

r2 amendment、readiness、implementation+evidence、`ready→done` 与 change `verified`
分别使用独立 PR。implementation PR 不改 accepted specs/Core/storage/catalog，也不改
TASK-TR-002 历史记录。
