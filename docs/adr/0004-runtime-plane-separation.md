# ADR-0004: Repo Agent 与 Device Agent Runtime 两平面分离

- Status: accepted(CHG-2026-046,2026-07-29)
- Deciders: lvye(merge 即批准)
- Context: chg-2026-025 建立了 typed operation、执行分级 E0/E1/E2 与
  standing authorization,但 runtime 请求模型(v1)把 `changeId`/`taskId`
  定为必填,授权以 ready task 为载体——每次设备执行都被迫经过仓库治理
  流程(建 change/task、开 PR、逐状态翻转),日常调试(抓 HiLog、装 HAP、
  推 `.so`)与治理审批深度耦合,既拖慢迭代又使治理载体膨胀
  (readiness-only / done-only / verified-only PR)。

## Decision

1. **两平面分离**。Repo Agent Plane 负责改代码/契约/catalog/provider/
   profile/E2 策略,载体是 OpenSpec change + PR,信任根不变(protected
   main + 维护者 review)。Device Agent Runtime Plane 负责执行已发布
   operation,只产生 runtime job/session/artifact。恰四类变化需要回到
   Repo Plane:新 operation 或破坏性修改、新 provider、新 integration/
   device profile、E2 安全策略变化。
2. **运行时身份与仓库身份解绑**。Runtime API v2 结构性排除
   `changeId`/`taskId`/PR OID/commit OID(出现即 fail-closed 拒绝);
   仓库溯源降级为 `PublishedOperationBundleManifest` 的可选构建来源信息。
3. **授权凭据从 ready task 换为 Runtime Capability**。E0 默认只读策略;
   E1 standing capability(scope/期限/次数受限、可撤销);E2 一次性
   exact-plan capability。E2 凭据的创建/修改/吊销仍以维护者 merged PR
   为唯一载体——信任根不因平面分离而弱化。
4. **catalog 是两平面的分界物**。operation 语义(effect/输入/步骤/补偿/
   预算/授权)只在 `Catalog/` 定义一份,merge 即发布;catalog 之外不存在
   可执行 operation,catalog 内不可表达 generic shell step。
5. **PR 形态收敛为垂直交付单元**。实现+测试+文档+evidence+任务状态翻转
   同 PR;readiness-only/status-only/done-only/verified-only PR 废止;
   change 级 verify/archive 与 D2 窗口授权保持独立载体。

## Consequences

- 日常 E0/E1 设备运行零 Git 依赖,AI 调试闭环(观察→抓取→部署→验证)
  不再逐步开 PR;治理 PR 数量收敛到真实决策点。
- 安全边界前移到 catalog + capability:审批发生在"发布 operation"与
  "签发 capability"两个低频点,执行期由 fail-closed 校验链
  (validate → authorize → persist intent → dispatch → semantic verify →
  persist outcome)承载。
- host_loop 与 runtime 彻底分工:前者只碰仓库任务(既有硬件门即禁令的
  机械承载),后者(MU-2 的 arkdeck-agentd)结构性不含 GitHub 写路径。
- 迁移期并存:v1 请求经 adapter 升级;`AuthorizationUsageLedger` 作为
  legacy E2 载体保留到 T25 收尾;v2 内核只咨询 RuntimeCapability,不存在
  两套并行生效的授权判定。

## Alternatives considered

- **维持每执行一 task**:被实践证伪(chg-2026-025 AIN-011~017 长期
  blocked 的直接原因之一是每步都要 readiness/授权载体)。
- **完全废除 OpenSpec**:拒绝——operation/provider/E2 策略仍需人审与
  可追溯批准;问题在载体粒度而非治理本身。
- **capability 放进 Git task 字段**:拒绝——可撤销性与次数/期限约束
  需要运行时 durable 载体,Git 状态无法表达"已消耗"。
