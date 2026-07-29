# CHG-2026-047 Design — MU-2 统一 Runtime 基础

## 1. 目标拓扑(本 MU 落地的部分)

```text
ArkDeckAgentClient ──UDS(JSON 行协议 v1)── arkdeck-agentd(exec)
                                              └─ ArkDeckAgentDaemon(库)
                                                   ├─ RuntimeControlPlaneHandler(与 transport 分离)
                                                   ├─ RuntimeJobEngine(ArkDeckWorkflows)
                                                   │    ├─ catalog 校验(RuntimeOperationCatalog)
                                                   │    ├─ RuntimeCapabilityStore / DefaultReadOnlyPolicy
                                                   │    ├─ durable idempotency ledger
                                                   │    ├─ WriteAheadIntentGate → DeviceProvider dispatch
                                                   │    └─ JournalReplay 恢复 / DeviceMutationLaneCoordinator
                                                   └─ DeviceProviderRegistry {hdc, rockchip}
```

## 2. T05 Provider Contract(落位 `ArkDeckWorkflows/DeviceProviders/`)

- `DeviceProvider` 协议四方法:`resolveFacts(target)` /
  `lower(action, context) -> TypedProcessPlan` /
  `verify(receipt, action, context) -> SemanticOutcome` /
  `reconcile(intent, context) -> ReconcileOutcome`。
- `TypedProviderAction` 封闭:`case hdc(HDCProviderAction)` /
  `case rockchip(RockchipProviderAction)`;payload 均为无字符串命令面的
  枚举(HDC 本 MU 只含观察族:observeTool/observeServer/
  listDeviceCandidates/observeDevice;T10 扩容)。**协议与 action 位于
  Workflows 是迁移期决定**(Core 纯化属 T23),对外不暴露 argv。
- `SemanticOutcome` 封闭:`verified(...)/failed(...)/unknown(reason)/
  unsupported(reason)`——不存在"exit 0 即成功"的构造捷径。
- Adapter:`HDCObservationProviderAdapter` 包既有 supervisor/observation
  组合;`RockchipFlashProviderAdapter` 包 `RockchipFlashExecutionHost`
  (execute 整体为一个 destructive action;其内部 journal/manifest 保留,
  引擎层记 receipt 引用)。零第二状态机。

## 3. T06 HDC Foundation 拆分(`ArkDeckOpenHarmony/`)

- 纯移动(实测定界):`HDCProduction.swift` → `HDCEndpointSelection.swift`
  (endpoint source/selection/selector)与
  `HDCAuthorizationAndSecurity.swift`(设备授权工作流、channel
  protection、安全呈现)。**两段留守是发现的硬约束而非偷懒**:
  ① dispatch-security 核心(semantic binding → prepared command →
  dispatch permit → lifecycle executor)由 `private`/`fileprivate` 织成
  **反伪造边界**(permit 的 fileprivate-only init 即防伪机制),拆开必须
  放宽可见性 = 安全语义弱化;② 诊断用例段与设备观察族被兄弟 change 的
  源码扫描守卫(DP1/DP13/DP19、C6)**钉在该文件路径**,迁移需其修订
  同意——两者均记入文件内 NOTE,物理迁移递延 T23。既有测试文件
  一个字节不动是"纯移动"的机械判据(159 项 HDC 套件零修改零回归)。
- 新增(增量,不改旧判定):`HDCCompatibilityProfile.swift` ——
  版本 profile 注册表(3.2.0d/3.2.0f 族)+ 观察族 semantic parser:
  `list targets -v`/`checkserver`/`-v` 输出的**结构化解析**(行序无关、
  空白正规化、诊断行忽略),显式 outcome:`parsed/truncated/
  invalidEncoding/empty/unsupportedVersion`。golden fixture 以真实版本
  来源登记。destructive/lifecycle 面不接 parser,继续精确 pin。

## 4. T07 daemon(新目标 ×3)

- `ArkDeckAgentDaemon`(库):`AgentDaemonServer`(UDS listener,
  Darwin socket;socket 路径 `<stateDir>/agentd.sock`,目录 0700、
  socket 0600、`unlink` 后 bind;零 TCP)。协议 = 每行一个 JSON 帧:
  请求 `{protocolVersion:"1.0.0", id, method, params}`,响应
  `{id, ok, result | error{code, message}}`;major≠1 拒绝;方法表封闭。
- handler 与 transport 分离:`RuntimeControlPlaneHandler.handle(method,
  params) -> Result` 纯函数化,内存 transport 可测。
- single-instance:复用 `RuntimeInstanceCoordinator`;二次启动读
  `instance.json`(pid/socket 路径/版本)返回既有实例信息。
- `ArkDeckAgentClient`(库):同步/async 客户端,供 CLI(T20)与测试;
  `arkdeck-agentd`(exec):组装生产 provider registry + 状态目录
  (`~/Library/Application Support/ArkDeck/Agentd/`)。

## 5. T08 引擎(`ArkDeckWorkflows/RuntimeJobEngine.swift`)

- submit 流水:decode(v2 codec)→ catalog descriptor(未知 →
  unknownOperation)→ inputs 按 catalog field 表校验 → effect 解析
  (计划步骤 max-fold,复用既有语义)→ 授权:E0 走
  `RuntimeDefaultReadOnlyPolicy`,E1/E2 走 `RuntimeCapabilityStore.consume`
  (reservation = jobID)→ **durable idempotency ledger**
  (`<stateDir>/idempotency.json`,同 key 返回原 jobID)→ SessionStore
  建 session + journal `jobCreated` → 步骤循环。
- 步骤循环:`persist intent(WriteAheadIntentGate)` → provider.lower →
  dispatch(本 MU 由 fake/fixture 驱动;真实 HDC dispatch 在 MU-3 接)→
  provider.verify → `appendOutcome`;dispatch 后无法判定 →
  outcomeUnknown → `waitingForRecovery`,**零自动重放**(journal 校验器
  本就禁止 unknown 后继续 intent)。
- 状态呈现:`RuntimeJobStatus` = f(JobStateMachine 状态, 未决
  HumanAction)——`waitingForHuman` 是视图态,持久图不改(18 态与
  journal 交叉校验保持原样)。
- 互斥:`DeviceMutationLaneCoordinator` per stable identity;重启时
  `adoptActiveLease` 依据 replay 的未终态 job。
- cancel:置 cancelRequested,由步骤边界收敛(critical 步不中断)。
- 恢复:daemon 启动扫 sessions → `JournalReplay.inspect` →
  requiresRecovery ⇒ reconcile(provider.reconcile)或保持 unknown。

## 6. 测试布局

- `ArkDeckContractTests/DeviceProviderContractTests.swift`(T05)
- `ArkDeckContractTests/HDCCompatibilityProfileTests.swift`(T06 parser
  矩阵;拆分本身由既有套件零回归证明)
- `ArkDeckContractTests/AgentDaemonContractTests.swift`(T07:双客户端、
  权限、协议负向、重启、single-instance)
- `ArkDeckContractTests/RuntimeJobEngineContractTests.swift`(T08:
  idempotency、互斥、cancel、timeline、WAL)
- `Tests/ArkDeckEngineCrashFixture`(可执行 fixture:两窗口 SIGSTOP,
  驱动测试 SIGKILL 后 replay 断言;仿既有 JournalCrashFixture 形态)

## 7. ADR

`docs/adr/0005-agentd-uds-control-plane.md`:UDS + JSON 行协议 + 单实例
+ 零网络的持久决策与端口可替换性论证。
