# CHG-2026-046 Design — MU-1 治理与 Runtime Contract

## 1. 两平面模型(T01)

```text
Repo Agent Plane(经 OpenSpec + PR,人审合并)
  改代码 / 契约 / Catalog / provider / profile / E2 策略
          │ 发布(merge 到 protected main)
          ▼
Device Agent Runtime Plane(零 Git 依赖)
  执行已发布 operation → runtime job / session / artifact
```

- Runtime Plane 的日常执行(E0、已授权 E1)只产生 runtime job 记录,
  不产生 OpenSpec task、不开 PR、不要求 changeId/taskId。
- 需要回到 Repo Plane 的恰四类:新 operation 或破坏性修改、新 provider、
  新 integration/device profile、E2 安全策略变化。
- 风险分级 D0/D1/D2(决策分级,批准视角)与 E0/E1/E2(执行效果分级,
  runtime 视角)正交:D 级决定"谁批准变更",E 级决定"执行需要什么凭据"。
- PR 形态:一个垂直交付单元一个 PR(代码+测试+文档+evidence);proposal
  可携带 `status: approved` 落地,merge 即批准;任务状态翻转随实现 PR。
  独立 readiness/done/verify-status PR 形态废止(change 级 verify/archive
  仍为独立动作,因其本身就是独立决策)。

## 2. Runtime API v2(T02)

```swift
public struct RuntimeOperationRequest {   // schemaVersion "2.0.0"
  let requestID: String                   // 幂等观察键(重复提交可见)
  let idempotencyKey: String              // 副作用去重键(engine 层,MU-2 消费)
  let target: DurableTargetReference      // targetID + 可选期望 binding revision
  let operation: RuntimeOperationReference// id@version,catalog 封闭
  let inputs: RuntimeOperationInputs      // canonical JSON object,schema 由 catalog 定
  let requestedOutputs: [RuntimeRequestedOutput]
  let authorization: RuntimeCapabilityReference?  // E1/E2 必填,E0 可空
  let clientContext: RuntimeClientContext?        // 展示/溯源,零授权语义
}

public struct PublishedOperationBundleManifest {
  let operation: RuntimeOperationReference
  let catalogDigest: String               // sha256,与生成常量一致
  let sourceRevision: String?             // 以下三项全部可选:仓库溯源
  let sourceChangeID: String?
  let sourceTaskID: String?
}
```

关键决策:

- **治理字段结构性排除**:v2 解码器在顶层显式侦测
  `changeId`/`taskId`/`approvalPRNumber`/`mainCommitOID`/
  `authorizationBlobOID` 键,命中即 `governanceFieldRejected`(fail-closed,
  不是忽略)。防止旧调用方"带着旧字段照跑"造成语义漂移。
- **版本策略**:major≠2 → `unsupportedVersion` fail-closed;major=2 的
  未知顶层键容忍(前向兼容),但重复 JSON 键仍拒绝(复用既有
  strict duplicate validator)。
- **错误码封闭集**:invalidRequest / unknownOperation / invalidInput /
  targetNotFound / authorizationRequired / conflict / unsupportedProfile /
  unsupportedVersion / governanceFieldRejected。v1 的
  `policyBlocked 丢失 blockerCode` 缺陷在 v2 结果模型中修正(错误码始终
  随拒绝返回)。
- **v1 adapter 单向**:`AgentDeviceOperationRequest`(v1)→ v2 升级,
  changeID/taskID 降级为 `clientContext.provenance` 注记并标记
  deprecated;不提供 v2→v1 反向路径;新内核(MU-2)只接受 v2。
- 所有新类型 Foundation-neutral(String/Int/Bool/嵌套值类型),为未来
  Windows/Linux 端口保留边界。

## 3. Runtime Capability(T03)

```swift
public struct RuntimeCapability {
  let capabilityID: String                // CAP-RT-...
  let targetScope: RuntimeCapabilityTargetScope   // anyTarget | stableIdentity(sha256)
  let operationScope: [RuntimeCapabilityOperationScope] // 精确 id@version 集
  let effectCeiling: WorkflowEffect       // 复用既有四级效果序
  let inputConstraints: [String: RuntimeCapabilityInputConstraint]
  let issuedAtUTC / expiresAtUTC          // E1/E2 必须有失效时间
  let maximumUses / (store 维护 remainingUses)
  let issuer: RuntimeCapabilityIssuer     // human maintainer + 可选仓库溯源
  let exactPlanDigest: String?            // E2 必填:绑定精确 plan + artifact hash
  let revocation: RuntimeCapabilityRevocation
}
```

- **策略解析**:E0 → 内置默认只读策略(无需 capability,仍受
  timeout/bytes/privacy 约束);E1 → standing capability,scope 精确匹配;
  E2 → 一次性 capability(maximumUses==1 且 exactPlanDigest 必填),
  plan/artifact/device identity 任一变化即失配。
- **原子消耗**:store 采用 reservation 两段式(reserve → consume/release),
  同 reservation 键重试返回原结果、字段漂移拒绝——与
  `AuthorizationUsageLedger` 已验证的崩溃窗口语义同构,复用
  `ArkDeckStorage` durable 原语(flock + full-sync + 严格 JSON)。
- **与 legacy 的关系**:`AgentExecutionAuthorityKind.readyTask`(以
  change/task 为凭据)不进入 v2 路径;`standingAuthorization`/
  `deviceCapability` 由 adapter 映射为 RuntimeCapability 视图,原 ledger
  在迁移期继续服务 v1 调用,T25 收尾退役。**不存在两套并行生效的授权
  判定**:v2 内核只咨询 RuntimeCapability。

## 4. Operation Catalog v1(T04)

```text
Catalog/
  schema/operation.schema.json      # 封闭 schema:additionalProperties=false
  operations/<id>.v1.json           # 六个 operation 文档
  profiles/openharmony-standard.v1.json
  profiles/dayu200.v1.json
  generated/effect-authorization-matrix.md   # 生成物(文档面)
Packages/.../ArkDeckCore/RuntimeOperationCatalogGenerated.swift  # 生成物(代码面)
```

- operation 文档字段:`id`/`version`/`provider`、`effect`(minimum +
  permitted)、`authorization`(defaultReadOnly | standingCapability |
  oneShotExactPlan)、`binding`、`inputs`(typed schema)、`outputs`、
  `steps[]`(ordered,`kind` 封闭于 `workflow-step-registry.yaml` 41 词表,
  每步声明 effect/cancellation/binding 且不得低于词表最小值)、
  `timeoutSeconds`/`outputByteBudget`、`retry`(仅 preflight/readOnly 步
  可重试;mutation 步 attempts 固定 1)、`unknownOutcome`(固定
  `reconcileRequired`,结构性禁止 auto-retry)、`compensation`、
  `artifacts`(role/privacy/retention)、`concurrencyKey`、`profiles`。
- **禁止 generic shell**:schema 无任何可承载 executable/argv/shell 的
  字段;step `arguments` 键名黑名单(`argv`/`shell`/`exec`/`command`/
  `runHDC`)在 schema 与生成器双层拒绝——与既有
  `WorkflowStepRegistry` 的运行时黑名单同构。
- **生成器**(`scripts/catalog_gen/generate.py`,PyYAML 仅用于读取
  step registry):确定性输出 Swift 常量表 + matrix 文档;catalogDigest =
  全部 operation canonical JSON 的 sha256。
- **drift 检查**:`check_sdd.py` 新 family `check_operation_catalog()`:
  schema/词表/E2 不变量校验 + 重新生成→字节比对(双向:catalog 变或
  生成物变都红)。零仓库写入(生成到内存比对)。
- 六个 operation 的 effect/authorization 概览:

| operation | effect | authorization |
| --- | --- | --- |
| `observe.device@1` | readOnly | defaultReadOnly |
| `capture.diagnostics@1` | readOnly→deviceMutation(按 plan) | defaultReadOnly / standingCapability |
| `debug.hap@1` | deviceMutation | standingCapability |
| `deploy.native-library.app-owned@1` | deviceMutation | standingCapability |
| `deploy.native-library.system@1` | destructive(固定) | oneShotExactPlan(默认不签发) |
| `flash.dayu200@1` | destructive(固定) | oneShotExactPlan |

## 5. 模块落位与依赖方向

- `ArkDeckCore`:RuntimeCapability 模型、catalog 生成常量、v2 引用类型
  (零依赖,纯值);
- `ArkDeckStorage`:RuntimeCapabilityStore(依赖 Core;复用本模块 durable
  原语);
- `ArkDeckWorkflows/AgentDeviceOperations`:v2 wire 模型、错误码、
  v1 adapter(与 v1 文件并列,便于 T25 收敛删除);
- 不新建 SwiftPM target(T23 再做模块重构);不动
  `TrustedDeviceOperationHost`(MU-2 接 v2 内核时演进)。

## 6. ADR

新增 `docs/adr/0004-runtime-plane-separation.md`:记录两平面分离与
"runtime job 不产生 Git task"的持久决策及其安全论证。
