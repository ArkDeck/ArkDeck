# Tasks — CHG-2026-075

入口：[proposal](proposal.md)、[design](design.md)、[scoped delta](spec-delta.md)、[verification](verification.md)。

## Execution contract

- 本文件定义待执行任务，不声明实现完成。Status:ready表示任务描述已备齐；只有本PR经
  维护者review合入main且Depends on对应实现已合入后才能执行，不另开状态/准备PR。
- 全部为D1 Repo任务；Hardware required:no不代表D0，不交给host_loop自动领取。
  设备执行仍由protected-main Runtime完成，任务文档不提供设备authority。
- 一个Task一个垂直实现PR，producer/consumer、测试、生成物、文档与run记录同车。
  不并行合并共享文件上的依赖任务，不先提交仅版本号/仅删handler的破坏性中间态。
- 每项Allowed paths列明该Task可修改的路径，宽测试目录仅供本目标关联fixture/断言同步；
  禁止放宽Core AC、安全校验或外部格式golden。当前任务状态/evidence在本change内维护。
- 常规局部实现选择由执行AI判断；发现本表外必要路径先给出具体diff和原因交维护者
  review，不通过扩大Allowed paths绕过检查。全部Raw Artifact/旧evidence保持原样。
- 执行顺序：001 → 002 → 003 → 004 → 005。XPA-001依赖001..004的最终契约；
  XPA owner迁移/硬件声明仍遵循其自己的验收要求。

## TASK-SVC-001 — Unify control-plane, Runtime requests, CLI and App on one v1

- Status:done
- Platform:macos（契约供Windows/Rust复用，本Task不实现新平台）
- Decision grade:D1
- Requirements/AC:SVC-AC-01, SVC-AC-02, SVC-AC-03, SVC-AC-04; POL-SAFETY-001, POL-TARGET-001, POL-RECOVERY-001, POL-AGENT-002
- Depends on:none
- Production reachability:CLI/App facade/AgentRuntimeExecutor → UDS/XPC → 唯一 strict control handler → 现有 Runtime typed admission；不增加新权限或dispatch点
- Trusted fact sources:现有 Runtime observation/binding、peer身份与published Catalog；客户端不得提供trusted facts或capability authority
- Allowed paths:
  - `Packages/ArkDeckKit/Contracts/control-negotiation.json`
  - `Packages/ArkDeckKit/Contracts/control-protocol.json`
  - `Packages/ArkDeckKit/Scripts/generate-control-contract.py`
  - `Packages/ArkDeckKit/APIBaseline/Sources/APIBaseline/APIBaseline.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/ControlProtocol*.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/ControlFrameJSON.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/AgentXPCContract.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/RuntimeOperationModelsV2.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/RuntimeOperationModels.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/RuntimeOperationFailure.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/XPCConnectionBox.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceListApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceControlFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DiagnosticSessionUIFixture.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCApplicationDiagnosticsFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/FlashApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DebugApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/TraceApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/UIDumpApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/OverviewCapabilityApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipDeviceAccessApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeHistoryApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeHistoryFilterApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobControlApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeTraceCacheApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeAdmissionService.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobReadProjection.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobRecord.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeWorkspaceContinuation.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/RuntimeDebugInvocation.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentExecutionCoordinator.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentExecutionStore.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Artifacts/RuntimeImportStore.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Artifacts/RuntimeArtifactStore.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeSessionCleanupRecordStore.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeSessionExportRecordStore.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeSnapshotPager.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckBootstrap/BootstrapToolRegistry.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckBootstrap/BootstrapBundleRegistry.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckBootstrap/BootstrapDevEcoToolchainRegistry.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Bootstrap/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Settings/SettingsApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/RuntimeJobRepository.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/RuntimeHDCControlActionStore.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/RuntimeToolSelectionControlActionStore.swift`
  - `openspec/contracts/runtime-control-plane.schema.json`
  - `openspec/contracts/cli-*`
  - `openspec/contracts/app-product-capability-registry.yaml`
  - `scripts/bench/control.py`
  - `scripts/bench/harness.py`
  - `scripts/bench/test_harness.py`
  - `scripts/bench/README.md`
  - `scripts/manual_ui_flash/manual_ui_flash.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckRuntimeSoakFixture/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckEngineCrashFixture/**`
  - `docs/design/arkdeck-cli-product-spec.md`
  - `docs/design/cli-*.md`
  - `README.md`
  - `README.zh-CN.md`
  - `openspec/changes/chg-2026-075-single-v1-contracts/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/changes/archive/**`
  - `Catalog/**`
  - `AGENTS.md`
- Risk:high
- Hardware required:no

### Deliverables

1. 产出 methods.md：对最新base的所有dispatch method和生产调用方建立完整处置表，
   字段见design §2；同名Job/Artifact/Device/Workspace/health/doctor/debug资源选择
   当前严格typed形态。operation、Flash、Debug、Trace、cancel/reconcile等仍有用途的
   方法必须保留或有已验证等价入口；禁止重新开放capability管理占位。
2. 原子迁移App facade/XPC、CLI、Executor与daemon。四组专用import迁到通用typed
   import；HDC/status、job分页、observation/adopt统一。保留现有UI需要的事实投影，
   不通过删UI能力完成迁移。通用method的XPC准入按kind/owner/target限制，不扩大权限。
3. 单一registry和currentVersion=1.0.0；移除legacy/target、semver排序/交集/required
   major、health fallback、1.x宽容与业务版本分支。移除protocol.negotiate及CLI
   --require-protocol，从help/completion/schema/fixture一起移除。
   旧daemon也自报v1时，以当前严格health/contract identity或成套daemon构建身份
   在mutation前拒绝混合构建；不能只比较1.0.0，也不新增协商/fallback。
   检查绑定实际dispatch实例，重连/peer更换需重验；daemon拒绝缺失当前契约身份
   约束的旧client。该约束只辨识格式，不授予authority或引入新认证策略。
4. Runtime request/result采用当前完整v1，文件名去V2。codec、直接Codable及durable
   Job load一致验证版本、key set、旧权限输入；同步内层XPC校验和executor builder。
   旧campaign字段删除后仍显式拒绝，不能默默忽略。SVC-002负责其余历史存储类型删除。
   RuntimeDebugInvocation在本Task只同步被删除的请求字段/严格decoder调用；自身
   permit/document版本标签的归一仍归SVC-003，避免前置Task无法独立编译。
   AgentExecutionStore同批移除对旧request.campaignReservation属性的直接依赖，
   以公共严格decoder的拒绝保证替代旧guard，不削弱校验。
   manual_ui_flash中的Runtime request检查与RuntimeSoakFixture的请求producer
   同车更新；工具自身candidate/session标签仍归SVC-003。
5. CLI显示格式不再选择协议，submit --wait保留等待、deadline与单次结果输出；
   Executor只用一个client，正确处理recovered、structured error、零派发证明与
   未知结果。网络中断不产生隐式重派发。
6. 同步契约源/生成器/生成物、Python benchmark与CLI设计/操作runbook。Runtime/
   Storage文件的本task范围仅为请求形态、调用方和无调用legacy list包装，不提前
   改Journal/Manifest/capability布局。每个生产caller必须有测试，不只修改mock。
   协商类型内被多处复用的decodeObject严格JSON能力提取到ControlFrameJSON，保留
   重复key/大小/换行校验；Bootstrap registry、两个ControlActionStore、Execution
   store/coordinator、Import/Session记录和SnapshotPager只迁移helper调用，不改变
   各自持久化格式或信任边界。不得因删除协商类一并丢掉这些通用严格解析能力。

### Verification

- wire/client：ControlProtocolVersionContractTests、替换后的单协议帧测试、
  AgentDaemonContractTests、AgentClientDeadlineContractTests；
  旧1.7.3/2.0.0、重复key、超限、错ID、未知method、旧权限字段全部拒绝。
- CLI：CLIArgumentParserContractTests、CLIMachineContractTests、
  CLIProcessGoldenContractTests、RuntimeCLIExitStatusContractTests、
  CLIControlFailureMappingContractTests、CLIWorkspaceContinuationContractTests。
- resources/App：JobReadResourcesContractTests、ArtifactResourcesContractTests、
  DeviceCandidatesContractTests、HDCLiveStatusContractTests、
  AgentXPCTransportContractTests及所有改动facade测试；至少一项同一fake daemon
  同时驱动CLI和App facade，验证真实两端序列化，不仅各自mock通过。
- RuntimeOperation/current request：codec、直接JSONDecoder和Job load三入口
  正/负fixture；非法请求零新Job/dispatch，旧authority不进入默认策略。
- generator --check、benchmark单元测试、仓库统一闸；App build-for-testing必须覆盖。
  本task不声称真机PASS，发布后的产品验收在SVC-005。

### Completion

methods.md无未处置生产caller；所有保留方法只走一个protocol/shape；版本判断只剩
公共准确值拒绝，不用于业务分流；CLI输出模式/等待不改变准入；生成物零漂移。
本task同一PR交付所有producer/consumer，不合入只改常量或只删旧handler的中间态。

### Handoff

在本Task实现/验收PR同车追加`evidence/runs/TASK-SVC-001/run.md`，
记录实际命令、结果、SVC-AC、偏差和残留；所有变化完成后才将本Task标done。

## TASK-SVC-002 — Consolidate durable records and recovery on the current v1

- Status:ready
- Platform:macos（契约供Windows/Rust复用，本Task不实现新平台）
- Decision grade:D1
- Requirements/AC:SVC-AC-04, SVC-AC-05, SVC-AC-06; POL-SAFETY-001, POL-TARGET-001, POL-RECOVERY-001, POL-AGENT-002
- Depends on:TASK-SVC-001
- Production reachability:Runtime admission/recovery → Job/capability/Journal/Manifest/SQLite owner → durable intent/ledger → 现有Provider；恢复前机械证明与fresh facts不变
- Trusted fact sources:磁盘原始durable bytes、Runtime-owned identity/reservation/outcome与完整覆盖证明；fixture只能模拟失败窗口
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/JobStateMachine.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeCapability.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/RuntimeOperationModels.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobRecord.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeAdmissionService.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeRecoveryService.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobReadProjection.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HistoricalEvolutionCampaignArchive.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipLegacyFlashJournalReconcile.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/ArkForgeRuntimeJobState.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentExecutionStore.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentExecutionCoordinator.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HDCServerLifecycleJournalAdapter.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Artifacts/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderContract.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/AgentRuntimeExecutor.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/HardwareEvidenceProjector.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/CLIMachineContracts.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/CLICommandRegistry.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/main.swift`
  - `openspec/contracts/cli-command-registry.yaml`
  - `openspec/contracts/cli-feature-coverage.json`
  - `openspec/contracts/journal-event.schema.json`
  - `openspec/contracts/manifest.schema.json`
  - `openspec/contracts/runtime-control-plane.schema.json`
  - `openspec/contracts/hardware-evidence.schema.json`
  - `Packages/ArkDeckKit/Contracts/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckEngineCrashFixture/**`
  - `docs/design/cli-job-resources.md`
  - `docs/design/cli-session-resources.md`
  - `docs/design/cli-runtime-storage.md`
  - `openspec/changes/chg-2026-075-single-v1-contracts/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/changes/archive/**`
  - `Catalog/**`
  - `AGENTS.md`
- Risk:high
- Hardware required:no

### Scope supplement

补充现有CLI入口、命令注册表、daemon组合入口及两个CLI生成契约，覆盖已review的
旧archive消费者删除与mutation state continuity接线。实现仍随本Task同车交付；
本补充合入main后，生产实现才能通过读取base Task范围的路径检查。

### Deliverables

1. 先交付完整当前contract的存储校验，再切writer。建立collision fixtures：
   旧JSON v1/2.x、旧SQLite v1/v2、新当前v1；版本相同仍按key/类型/关系/表结构验证。
   不能静默重建打不开的store，也不能以换目录、重装或defaults回退消除未决状态。
2. Journal五代能力表与operation选writer合并；普通、Flash和独立recovery使用同一v1。
   JobState保留recoveringByCompleteOverwrite/recovered等当前状态；验证器按真实
   operation/profile/proof检查恢复必需字段，不再通过版本打开能力。
3. Manifest四代和旧actor/authority形状合并，保留REQ-ART-004全部执行语义及
   Journal/Artifact/target关联。新export只写当前结构，既有raw bytes不重编码。
4. SQLite新库直接创建最终表/索引，user_version=1，WAL/FULL/transaction约束不变；
   删除旧升级、legacy creation sentinel和迁移分页。row version、admission sequence、
   created-order一致性仍保留，不将并发计数固定成1。
5. capability store当前内容标v1，保留reserve/consume/outcome、ledger续链、
   checkpoint、use预算、幂等和崩溃恢复。移除仅服务旧authority/campaign、
   pre-V5 correlation、旧request fingerprint补造的分支；current optional按业务保留。
   明确区分历史解码helper与当前使用的AuthorizationUsageLedger，不按文件名整删。
6. consumer同车更新。旧change draft schema/硬件样本若被活动测试加载，只迁移
   当前测试的依赖和fixture；历史文件不改写。当前JSON schemas、Swift validator、
   producer与fault tests一次对齐，不能以旧v1 schema约束丢掉新恢复字段。
7. 数据操作说明给出拒绝原因、保留位置与当前配置入口；不提供自动迁移/清账工具。
   真正首次安装与host空目录测试可初始化当前新库；发现旧authority/Journal/ledger、
   更换已配置state root或无法证明旧状态不存在时，mutation面fail closed，不以空库替代。

### Verification

- JournalRecoveryContractTests、CompleteOverwriteRecoveryContractTests、
  SessionArtifactStorageContractTests、RuntimeCapability相关contract tests、
  RuntimeJobRepository相关tests、Session export/retention tests；fixture名称以base
  实际套件为准，覆盖原有行为而非只改预期版本字符串。
- kill/restart：intent前后、reservation/consume前后、write/reply之间、torn tail、
  ENOSPC/SQLite busy/checkpoint失败。确认zero replay、预算不复位、unknown不变。
- 无/缺/错coverage proof、identity/binding drift、未知target都零新destructive
  dispatch；合法完整覆盖recovery仍产生独立epoch和supersession，原Job不变succeeded。
- 旧1.0文档/数据库不冒充新v1；不可读历史未决状态不能自动生成空authority state。
  raw Artifact/evidence前后hash一致，不以fixture声称真实硬件通过。
- 正常Job/readOnly/capability、取消、导出、重启/幂等及全部统一闸通过。

### Completion

生产Journal/Manifest/SQLite/capability仅当前单一布局；无历史版本路由/自动升级/
旧authority适配。安全拒绝、当前恢复能力、ledger与Artifact不变量均通过行为测试。

### Handoff

在本Task实现/验收PR同车追加`evidence/runs/TASK-SVC-002/run.md`，
记录实际命令、结果、SVC-AC、偏差和残留；所有变化完成后才将本Task标done。

## TASK-SVC-003 — Normalize evidence, debug and internal Provider formats

- Status:ready
- Platform:macos（契约供Windows/Rust复用，本Task不实现新平台）
- Decision grade:D1
- Requirements/AC:SVC-AC-07, SVC-AC-08; POL-SAFETY-001, POL-TARGET-001, POL-RECOVERY-001, POL-AGENT-002
- Depends on:TASK-SVC-002
- Production reachability:Runtime facts/Job/Journal → HardwareEvidenceProjector及debug invocation/permit → 当前typed provider descriptor；不引入新device operation
- Trusted fact sources:Runtime持有的实际step/outcome/target/Artifact及reservation/supersession；内部descriptor由同一Catalog计算digest
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/HardwareEvidenceProjector.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/AgentRuntimeExecutor.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobRecord.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/AgentExecutionContract.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/JobStateMachine.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/**`
  - `openspec/contracts/hardware-evidence.schema.json`
  - `openspec/contracts/runtime-control-plane.schema.json`
  - `openspec/contracts/cli-*`
  - `scripts/manual_ui_flash/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckEngineCrashFixture/**`
  - `docs/design/cli-flash-invocation-list.md`
  - `docs/design/cli-debug-probe.md`
  - `openspec/changes/chg-2026-075-single-v1-contracts/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/changes/archive/**`
  - `Catalog/**`
  - `AGENTS.md`
- Risk:high
- Hardware required:no

### Deliverables

1. HardwareEvidenceV6Record重命名为HardwareEvidenceRecord，当前完整字段固定v1；
   同步writer/schema/consumer，删除仅用于测试的V1..V6 discriminator。
2. 保留executor/effect、RuntimeCapability/fresh confirmation、reservation/use ordinal、
   actual typed Steps、target/plan/Artifact digests、uncertain effects/coverage、
   supersession/postflight/terminal disposition。旧权限或不完整关联不可出有效证据。
3. RuntimeDebugInvocation当前permit/document和手工开发工具候选/会话格式统一v1，
   producer/consumer精确校验；不把scripts/manual_ui_flash作为真机验收捷径。
4. 内部bound Rockchip .v2 descriptor改为.v1并同步digest/golden；retired unbound
   verification和旧direct flash intent继续拒绝。只去旧标签/兼容，不改变lowering、
   operation.effect、profile、Partition/plan或Provider覆盖。
5. 删除对应旧类型命名/注释/无caller helper与历史版本正向矩阵。ProviderFacts中的
   optional逐项检查当前host/readOnly场景，不能因“pre-V3”注释把合法optional变required。
   外部ArkForge/ArkTrace、ABI、code-sign格式等版本保持。

### Verification

- HardwareEvidenceProjectionContractTests覆盖readOnly、RuntimeCapability mutation、
  完整覆盖recovery及全部缺字段/关联漂移/legacy authority负向；test结果标fixture。
- Debug invocation/permit、candidate decoder和内部descriptor round-trip/validation；
  重名旧v1与错版本拒绝，当前bound身份不可退化为unbound。
- Schema与Swift结构一致；新派生证据格式不修改既有raw evidence；历史Catalog
  结果不得换标签后声称当前REAL_DEVICE_PASS。统一闸通过。

### Completion

范围内当前格式均固定v1，类型/文件名无V2/V6；实际最新字段、安全校验和digest
关联完整；所有原始历史证据保持原字节。

### Handoff

在本Task实现/验收PR同车追加`evidence/runs/TASK-SVC-003/run.md`，
记录实际命令、结果、SVC-AC、偏差和残留；所有变化完成后才将本Task标done。

## TASK-SVC-004 — Remove prerelease preferences and configuration compatibility

- Status:ready
- Platform:macos（契约供Windows/Rust复用，本Task不实现新平台）
- Decision grade:D1
- Requirements/AC:SVC-AC-09, SVC-AC-10; POL-SAFETY-001, POL-TARGET-001, POL-RECOVERY-001, POL-AGENT-002
- Depends on:TASK-SVC-003
- Production reachability:App设置/History及已存在安装/配置CLI → Runtime-owned resources/LaunchAgent bundle/当前Keychain envelope；无新权限与设备dispatch
- Trusted fact sources:当前Runtime资源generation、签名helper身份与文件digest、用户明确选择的材料；不信任旧偏好提升authority
- Allowed paths:
  - `ArkDeckApp/Features/History/RuntimeHistoryView.swift`
  - `ArkDeckApp/Features/Debug/DebugWorkspaceView.swift`
  - `ArkDeckApp/Features/Devices/DeviceWorkspace.swift`
  - `ArkDeckApp/Features/Settings/SettingsRootView.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Settings/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/SessionSettings/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeHistoryFilterApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/ArkForgeLaneComposition.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/WorkspaceProvider/OpenHarmonyLocalSigning.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/WorkspaceProvider/OpenHarmonySigningCredentialOwner.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/WorkspaceProvider/WorkspaceOperationsProvider.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentComposition/EvolutionWorkspaceManager.swift`
  - `Packages/ArkDeckKit/LaunchAgents/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/**`
  - `openspec/contracts/cli-*`
  - `openspec/contracts/runtime-control-plane.schema.json`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckEngineCrashFixture/**`
  - `ArkDeckAppUITests/**`
  - `docs/design/cli-*.md`
  - `docs/design/arkdeck-cli-product-spec.md`
  - `README.md`
  - `README.zh-CN.md`
  - `openspec/changes/chg-2026-075-single-v1-contracts/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/changes/archive/**`
  - `Catalog/**`
  - `AGENTS.md`
- Risk:medium
- Hardware required:no

### Deliverables

1. History/SessionSettings只读写Runtime-owned当前资源；删除旧UserDefaults迁移及
   SettingsLegacyStorageMigrationPlan。非权威UI key可去版本后缀，首次默认值合理，
   当前filter/storage generation冲突和丢响应read-back仍保留。
2. ArkForge只支持当前单bundle配置；删除三环境变量自动升级及已无用途migration
   标记/入口；保留bundle digest/identity验证、正常install/update/reconfigure/uninstall。
3. 签名只支持当前Data Protection Keychain access-group与secret envelope/receipt；
   删除旧per-executable ACL、旧密码账户迁移及兼容CLI入口。保留自定义签名材料、
   当前安装/重配/卸载和helper身份验证。不可自动删除旧secret/材料，或静默用SDK
   默认替换用户材料；旧配置提示通过当前受支持入口明确重配。
   CredentialOwner必须区分真正absent与unsupported/corrupt receipt；旧receipt+
   缺ledger、旧receipt+中断replace不能通过try?回退生成空stable owner、归零或覆盖材料。
4. 同步现行CLI contracts/help/completion和相关docs。清理范围内旧测试正向兼容矩阵，
   覆盖当前首次配置、重复配置、升级当前构建、读取失败、取消、默认值与资源冲突。
5. 追加 residual-audit.md：扫描自有生产schema/protocol/legacy/migration命中，
   每条按已删除、当前业务语义、外部版本、历史文档、负向fixture说明。
   SVC001..003范围遗漏使用原Task ID和原Allowed paths提交必要的后续修复PR，
   合入后继续依赖任务；不重开已合并PR，不借本Task扩大Allowed paths。
   不按grep结果将外部version、generation、HDC绑定/恢复逻辑删掉。
   不为“一处高版本字符串”批量重写历史changes/evidence或CI cache。

### Verification

- SettingsApplicationFacadeContractTests、SettingsStorageUIFixtureContractTests、
  SessionSettingsContractTests、History filter/facade测试；默认设置和已有当前
  Runtime资源一致，legacy偏好不能触发隐式Runtime配置写入。
- LaunchAgentServiceContractTests、ArkForgeLaneComposition相关tests、
  OpenHarmonyLocalSigningContractTests：只用隔离store/Keychain fake验证旧格式拒绝、
  当前材料与身份不变，不操作开发机真实Keychain/安装状态。
- App build-for-testing；实际呈现变更使用仓库run-ui-tests.sh封装，在安静机器
  单独运行对应suite。未运行及原因写run记录，不能以fake截图声称呈现通过。
- 单格式残留审计无未归属自有兼容分支，相关生成物零漂移；统一闸通过。

### Completion

当前配置入口全可用，旧配置不再自动迁移；没有数据/secret自动删除或新权限。
残留报告给出具体路径和保留理由，不能仅提交“grep零命中”。

### Handoff

在本Task实现/验收PR同车追加`evidence/runs/TASK-SVC-004/run.md`，
记录实际命令、结果、SVC-AC、偏差和残留；所有变化完成后才将本Task标done。

## TASK-SVC-005 — Verify the published single-v1 product through headless journeys

- Status:ready
- Platform:macos（契约供Windows/Rust复用，本Task不实现新平台）
- Decision grade:D1
- Requirements/AC:SVC-AC-01, SVC-AC-02, SVC-AC-03, SVC-AC-04, SVC-AC-05, SVC-AC-06, SVC-AC-07, SVC-AC-08, SVC-AC-09, SVC-AC-10; POL-SAFETY-001, POL-TARGET-001, POL-RECOVERY-001, POL-AGENT-002
- Depends on:TASK-SVC-001, TASK-SVC-002, TASK-SVC-003, TASK-SVC-004
- Production reachability:arkdeck agent run/resume → protected-main Runtime → published typed operations；App检查仅验证呈现，不替代headless运行
- Trusted fact sources:当前实际Catalog digest、Runtime取得的精确target/binding/tool facts和真实Runtime记录；不得创建/篡改capability或硬件证据
- Allowed paths:
  - `openspec/changes/chg-2026-075-single-v1-contracts/**`
  - `docs/design/cli-golden-journey-headless-runbook.md`
  - `docs/design/references/single-v1/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/changes/archive/**`
  - `Catalog/**`
  - `AGENTS.md`
- Risk:high
- Hardware required:yes

### Deliverables

1. 在SVC001..004实现PR已合入main后，对对应构建记录完整commit、实际Catalog digest、
   工具/设备/绑定事实引用，按单v1更新后的headless runbook执行受影响GJ-1..5。
   只用arkdeck agent run和人工动作后的agent resume，不提交raw HDC/shell/刷机命令。
2. 覆盖观察/adopt、HAP debug、native debug、Flash recovery、bounded AI loop；
   同时验证import、job等待/取消、History/Settings与artifact/session导出链。
   Flash与恢复仅经已发布Runtime的机械准入，不新增人为unknown故障注入或超出Catalog的动作。
3. App呈现用现有UI assertions封装验证设备/导入/任务/History/Settings结果；产品
   headless缺陷报告BLOCKED_BY_PRODUCT_DEFECT，使用原实现Task ID及Allowed paths
   提交后续修复PR，合入后再验，不将代码修复塞入本Task的文档/evidence权限。
4. 写总体结果、每项SVC-AC结论、未执行原因与Runtime evidence引用，给出残留审计
   和CHG-074可消费的最终Swift单v1基线（完整OID/contract路径）。
   不手工制作或修改hardware evidence，不将旧结果重标当前PASS。
5. 当前完成条件成立即可交付，不创建无变化status-only PR；本验收PR必须带真实
   新运行记录。不能把此前实现Task的未完成修复隐藏到验收Task中。

### Verification

- 真实设备结果必须属于当前发布Catalog digest；fixture/planOnly只保留其本来类别。
- unknown intent不可replay，缺证明零新dispatch；不通过清空state或换目录解阻。
- 只断言实际完成的GJ与App assertions。机器/硬件不可用时精确报告未执行项，
  不让维护者代跑headless产品路径，不声称全部完成。
- 最终仓库统一闸、相关UI suite结果及方法/格式残留审计汇总。

### Completion

SVC-AC-01..10都有可复查结果，受影响GJ有当前真实Runtime记录，App呈现检查已完成；
未满足的项明确保留为未完成，不能把整个change标verified或自行修改平台支持状态。

### Handoff

在本Task实现/验收PR同车追加`evidence/runs/TASK-SVC-005/run.md`，
记录实际命令、结果、SVC-AC、偏差和残留；所有变化完成后才将本Task标done。
