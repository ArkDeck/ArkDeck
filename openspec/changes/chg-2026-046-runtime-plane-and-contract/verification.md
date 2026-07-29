# CHG-2026-046 Verification Plan

> Change:CHG-2026-046-runtime-plane-and-contract@r1
> Status:passed # 2026-07-29；仅在维护者 review/merge verification PR 后生效
> Core baseline:CORE-2.1.0 (canonical Core AC not claimed)

## Environment

- protected-main checkout,macOS arm64,Swift 6.3.x;
- 全部验证为 contract/unit/脚本层:`swift test`(ArkDeckKit 全量)、
  `scripts/check-sdd.sh`、`scripts/test_check_sdd.py`、
  `scripts/catalog_gen` 自测;
- 安装态 HDC、真实设备、网络、设备 mutation、D2 窗口对本 change 全部禁止。

## Acceptance matrix

| AC ID | Verification method | Expected result | Minimum evidence |
| --- | --- | --- | --- |
| `RTC-GOV-001` | 治理文本审阅 + 文本不变量检查 | 两平面定义、四类需审批变化、D0/D1/D2 分级、状态-only PR 废止与 host_loop 边界均成文;D2/E2 既有规则逐条保留 | contract |
| `RTC-API-001` | v2 round-trip 契约测试 + 治理字段拒绝矩阵 | 仅凭 target+operation+inputs 可构造合法 v2 请求;顶层出现 changeId/taskId/PR/commit 字段即稳定错误码拒绝;未知主版本 fail-closed,次版本未知字段前向兼容 | contract |
| `RTC-CAP-001` | capability 模型不变量 + durable store 契约测试 | E1 无 taskID 可授权、缺 capability 明确拒绝;跨 target/operation/effect ceiling、过期、撤销、耗尽全部 fail-closed;原子消耗在重试/恢复窗口不重复消耗 | contract |
| `RTC-CAT-001` | catalog schema 校验 + 生成器 drift 双向比对 + 词表封闭检查 | 六个 operation 全部通过 schema;steps 全部落在 workflow-step-registry 词表;generic shell step 结构性不可表达;生成 Swift/matrix 与 catalog 漂移即 check-sdd 红 | contract |
| `RTC-COMPAT-001` | 既有全量套件 + v1 adapter 平行向量 | 既有 Swift/脚本套件零回归;v1 请求经 adapter 升级为 v2 后语义等价并携带 deprecation 注记 | contract |

## `RTC-GOV-001`

- AGENTS.md 含 Repo Agent / Device Agent Runtime 两平面定义与职责边界;
- 仅四类变化需 OpenSpec/PR:新 operation 或破坏性修改、新 provider、新
  integration/device profile、E2 安全策略变化;已发布 operation 的执行只
  产生 runtime job;
- D0/D1/D2 分级与既有 E0/E1/E2 执行分级正交成文,现行 D2 审批与 E2
  standing authorization 规则零弱化(逐条 diff 审阅);
- readiness-only/status-only/done-only/verified-only PR 形态废止,任务
  状态翻转随实现 PR;proposal 可携带 approved 落地,merge 即批准;
- host_loop 仓库任务边界成文,其代码零改动(diff 为证)。

## `RTC-API-001`

- `RuntimeOperationRequest` 2.0.0 编解码 round-trip 稳定(canonical JSON);
- 必填面:requestID/idempotencyKey/target/operation/inputs;可选面:
  requestedOutputs/authorization/clientContext;
- 拒绝矩阵:顶层 `changeId`、`taskId`、`approvalPRNumber`、
  `mainCommitOID` 等治理键各自触发 `governanceFieldRejected` 类稳定错误;
- 版本策略:major≠2 fail-closed;major=2 未知顶层键容忍(前向兼容);
  重复 JSON 键拒绝;
- `PublishedOperationBundleManifest` 的 source* 字段全部可选且缺省合法。

## `RTC-CAP-001`

- 模型不变量:E2 capability 必须携带 exactPlanDigest 且 maximumUses==1;
  E1/E2 必须有失效时间;effect ceiling 单调(不得授出高于 ceiling 的步骤);
- store 契约:install/list/inspect/revoke 往返;consume 原子且幂等重试
  (同 reservation 键重试返回原结果,字段漂移拒绝);
- fail-closed 矩阵:过期、revoked、剩余次数 0、target scope 不匹配、
  operation scope 不匹配、effect 超 ceiling、plan digest 不匹配(E2)
  ——每格一条红路径测试;
- E0 默认策略:仅 readOnly 且带 timeout/bytes 上限,拒绝一切 mutation。

## `RTC-CAT-001`

- schema:六个 operation 文档逐一通过 `operation.schema.json`;
- 词表封闭:每个 step.kind ∈ workflow-step-registry.yaml;schema 层不存在
  可表达任意 executable/argv/shell 的字段(负向测试:含 `command`/
  `argv`/`shell` 键的输入文档被拒);
- E2 面:`deploy.native-library.system.v1` 与 `flash.dayu200.v1` 的
  effect 固定 destructive、authorization 固定一次性 exact-plan;
- drift:修改 catalog 任一字节而不重新生成 → check-sdd 报错;修改生成物
  而 catalog 未变 → 同样报错(双向);
- 生成器确定性:同输入两次生成字节相同。

## `RTC-COMPAT-001`

- 全量 `swift test` 与全部脚本套件在实现后保持通过(与 PRE-00 基线对账);
- v1→v2 adapter:v1 合法请求向量升级后,target/operation/inputs 语义等价,
  changeID/taskID 仅出现在 clientContext provenance 注记且标记 deprecated;
- v1 契约测试(AgentDeviceOperationContractTests 等)零修改零回归。

## Result gate

- [x] `RTC-GOV-001` 有 current-governance 文本审计与完整脚本回归；
- [x] `RTC-API-001` 有 v2/legacy adapter current-main 契约回归；
- [x] `RTC-CAP-001` 有模型与 durable store current-main 契约回归；
- [x] `RTC-CAT-001` 有 schema/词表/生成器/drift current-main 回归；
- [x] `RTC-COMPAT-001` 有 ArkDeckKit 全量与全部声明脚本套件回归；
- [x] evidence 准确分类为 `contract`，未冒充真实设备或 hardware evidence；
- [x] change `verified` 由独立 verification PR 翻转，仅引用具体 run/复验
      记录，不夹带产品实现。

Closure receipt:`proposal.md#verification-closure2026-07-29`。实现 evidence =
`evidence/runs/TASK-RTC-001/run-r1.md`；latest-main 复验 =
`evidence/runs/TASK-RTC-001/verification-r1.md`。`passed` 与 proposal
`verified` 只在维护者 review/merge 本 verification PR 后生效。
