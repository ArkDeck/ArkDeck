# Verification and Agent Execution Policy

> Version：1.0.0  
> Status：review candidate  
> Baseline：CORE-1.0.0

## Verification layers

1. **Spec lint**：重复/非法 ID、孤立 SHALL、Requirement 无 Scenario、阻塞性 TBD、平台 override、损坏 schema。
2. **Pure Core tests**：状态机、effect/cancellation、binding policy、journal/schema、storage accounting、clock 和 property-based invariants。
3. **Parser golden tests**：HDC、Unauthorized、help/tag、HiDumper、HiLog 和 Flash 输出的已声明 family。
4. **Platform port contract tests**：进程、锁、电源、卷、持久文件访问、工具信任、日志和时钟。
5. **Workflow integration/fault injection**：fake executable、断线、崩溃窗口、ENOSPC、恢复/补偿失败。
6. **Real platform tests**：clean-host、Sandbox/SmartScreen、签名、安装、更新和辅助技术。
7. **Real hardware matrix**：精确设备、固件、HDC、transport、权限和 Provider。

低层测试不能替代高层证据。Simulation/fake 只能证明 orchestration，不证明硬件支持。
普通 Agent/CI 即使连接了真实 USB 设备也不得执行 destructive workflow；真实 Flash evidence 只来自 `controlledHardwareLab`、独立外部授权和人类物理目标确认。

## Core property invariants

性质测试至少覆盖：

- 任意操作序列中同设备同时最多一个 mutation lane；
- external/unknown HDC server 自动 kill 调用数恒为 0；
- 身份确认和 binding revision durable 前 device mutation dispatch 为 0；
- TCP/UART 断线后不存在自动 rebind 路径；
- outcomeUnknown destructive step 不自动重放；
- plan-only mutation/destructive dispatch 为 0；
- simulated Provider 不接收真实 binding/process executor；
- journal/schema encode/decode round-trip；
- terminal Job 不再接受新 mutation；
- HostStorageCoordinator 不超过内部保留线，claim update 不 double-count；
- raw Artifact hash 在所有派生操作前后不变。

性质测试不能替代 HDC contract、平台 Port 或真机验收。

## Definition of Ready

Task 进入 `ready` 前必须全部满足：

- 固定 `CORE-x.y.z` baseline 和 approved change revision；
- 固定 accepted Integration lock 下的 profile version+hash、accepted platform profile version+hash、accepted Core conformance suite hash 和真实 Git base revision；
- 存在绑定 immutable Task packet hash 的有效 human approval；Task 在 `ready/unclaimed` 后才允许原子 claim；
- Task 所属 Change 必须是 approved supersession lineage 的当前 head；successor 必须有绑定完整 claim ledger inventory 与单调 lineage sequence 的受保护 barrier proof，旧 Change 被替代后 packet 保留但不再 claimable；
- replacement Task 在 exact `taskSupersession` approval 前不得 claim；replacement claim 必须绑定 superseded run/approval 且严格晚于 approval；
- 所有关联 Requirement/AC 已 accepted，且没有影响任务的 TBD/未决 decision；
- 必需 ADR/contract 已接受；
- objective、in/out of scope、allowed/forbidden paths 明确；
- 依赖完成，或 fake/fixture contract 已固定；
- 每个 AC 的验证方法和所需 evidence 明确；
- 风险等级、危险操作、取消和恢复边界明确；
- runtime capabilities 明确列出 repo process、外部工具、网络、真机、安装、提权和仓库外写入；缺失能力默认禁止；
- 所需硬件/toolchain/系统环境可得；否则任务是 Spike/verification 而非实现；
- 与并行 Agent 的文件、设备、HDC server、输出卷等 exclusive resource 已声明；
- 任务可在一个 Agent turn 或一个独立可评审 PR 内闭环；
- 执行 Agent 不需要做新的产品或 Safety 决策。

## Definition of Done

Task 只有在以下全部满足时才能标记 `done`：

- deliverables 完成且没有越过 allowed scope；
- 关联 AC 已通过并有可复查 evidence；
- 适用的正常、错误、取消、崩溃/重启/恢复场景覆盖；
- build、lint、unit、contract/integration tests 通过；
- Requirement → AC → Test → Evidence trace 更新；
- 没有未经批准的 Core、AC、schema 或 safety policy 变化；
- 没有把 simulation/plan-only/fake 记为真机证据；
- 新的持久技术选择形成 ADR，产品变化走 change delta；
- diff 自审，无 secret、私钥、真实敏感 Artifact 或无限日志；
- run record 和 handoff 已持久化；
- finalized done run 已取得绑定 exact bytes/hash 的外部 result approval；
- 没有仍属于本 Task 的 TODO。无法完成则保持 blocked。

## Change acceptance and release gates

- Change tasks 完成后状态最多为 `review`；verification 通过后才为 `verified`。
- Core change 必须由人类批准，更新 baseline lock，并重跑所有平台 Core conformance。
- Core MINOR/MAJOR change 与其新 baseline 必须在各自批准 gate 独立通过 declared target platform revalidation matrix；当前交付平台只能 `reverifyRequired` 或 `nonConformant`，不得 `deferred`。
- Platform lock 的 `verified_core_baseline` 或 conformance hash 与 current Core 不一致时，状态必须变为 `needsReverification`；只有新 suite 的仓库外批准 evidence 才能恢复 `verified`。
- PCE 的每个 Core AC、Platform case 和 Port result 必须固定 canonical definition hash；每个 result cell 还绑定其 exact support-cell hash。每个 controlled-external evidence item 必须引用 standalone canonical binding record，固定 raw artifact hash/location/classification、Core/Integration/Conformance、Platform profile/verification/case-manifest hashes、implementation revision 与它明确覆盖的 case/Port/support-cell hashes；外部 evidence approval 的 subject hash 是该完整 binding record，而不是 raw artifact hash。聚合报告可以覆盖多项/cell，但必须显式列出且不得只自报 classification。
- 目标平台发布时，所有适用 MUST/Safety AC 必须 100% verified。
- 真实 Flash 支持必须有未过期、匹配支持矩阵的硬件 evidence。
- 未完成硬件证据 MAY 作为独立 verification task，但 capability/release 状态保持未 verified。
- Archive 使用无自引用的分阶段发布：`verification-result.json` 引用较早的 canonical `verification_revision`，并与其 exact approval mirror 单独进入 metadata-only `source_tree_revision`；只有受保护 workflow 可从该完整 live tree创建不可发布的 exact `result_revision` staging subject，后者加入 pre-archive proof/approval 并执行 sync/move。`archive-lock.yaml` 在 staging commit 之后生成并绑定它。baseline/archive approval 全部通过前，staging 不得成为 current spec、accepted baseline、已归档 change 或 release 输入。
- 历史 archive 的重放只读取其固定的 `B/R/S/T/P` Git revisions、archive lock、当时的 Platform/Conformance lock bytes 与 approval refs。不得把旧 staging/publication 与当前 worktree、当前 Platform lock 或当前 Conformance suite 比较；后续合法 baseline/axis revision 不能使旧 archive 失效。

## Evidence and run records

路径：

```text
openspec/changes/<change>/evidence/
  summary.md
  runs/<task-id>/attempt-001/
    claim.json
    run.json
```

Immutable Task packet SHALL 符合 `contracts/task-packet.schema.json`。Claim SHALL 符合 `contracts/task-claim.schema.json`，并由受保护 claim 服务以 `claim-owner-attestation.json` 绑定 exact bytes/hash、owner 和 lease；replacement claim 还绑定且严格晚于原 run 的 `taskSupersession` approval。每次 attempt 在结束时只追加一个 immutable terminal `run.json` 与 `run-owner-attestation.json`，后者证明 run 来自同一 claim owner。Claim 的存在表示运行中，不通过改写 run 表示进度。Task packet 不保存运行态，claim/run/evidence 是独立 sidecar。Run 必须在 claim lease 内结束；新 attempt 需要前一 attempt 的 owner-attested 终态 run。`controlledHardwareLab` 还需在 dispatch 前取得人类批准的 `lab-execution-authorization.json`，它固定同目录 `lab-execution-plan.json` 的 exact bytes/hash、typed Step/effect、target 和 HDC server generation；run 的 plan/authorization ID、first/last real-device dispatch 与批准有效期必须匹配。Run record 保存 baseline、change/task revision、integration/platform profile hash、Core conformance suite hash、base/result Git commit、与真实 Git diff 精确相等的修改文件、执行命令、AC 结果、evidence 索引、deviation、remaining risk 和下一安全恢复点。Task、claim、attempt、run、attestation ID 不得在 archive 后复用。仓库 evidence 必须 canonical resolve 在仓库根内；若它在 Task base 后新增或变化，必须属于该获批 run 的 Git diff，不能借 evidence 路径绕过 `allowedPaths`。controlled external、real-hardware 与 manual-review evidence 需要仓库外 verifier。

所有 active done run 汇合时必须共享 change approval 的同一个 canonical base `B`。受保护 verification workflow SHALL 证明 `B..verification_revision` 的产品/规格路径恰好是各获批 `B..run.resultRevision` diff 的并集；同一路径在两个 run 中得到不同 Git tree identity（mode/type/blob OID，删除为 absent）时 fail closed，最终 tree 也不得覆盖或丢弃任何 run 结果。并集之外只允许从当前 Change 的已校验 Task/claim/run/lab/hardware/approval 引用闭包逐文件推导出的 immutable lifecycle provenance，禁止目录通配。PCE、release subject 与发布批准位于 change verification 之后的独立发布链，不得作为未归属 Task 的实现内容夹入 `verification_revision`。

Verified hardware record 必须引用一个 owner-attested 且结果已批准的 controlled-lab done run；其 AC 集必须精确等于该 run 实际 passed 的 realHardware results，Step kinds、plan/target/HDC/Provider 和 external artifact 必须逐项相等。每个 AC 还必须固定当次平台 conformance case manifest hash，以及该 case 的 Test ID、method、minimum evidence、hardware capability 和 canonical definition hash；Core/behavior case 的 definition hash 必须包含 canonical Scenario block SHA，platform-local case 必须包含 exact expected result。任一规范期望变化后旧硬件记录不能被外推复用。Change 归档后，guard 必须通过已批准 pre-archive proof 与 exact archive tree 重建完整 immutable provenance bundle；不得因 live path 消失而丢弃证据，也不得只凭 archive 中一个同名 run 复活证据。受保护 release/verification CI 通过 `ARKDECK_EVALUATION_TIME` 注入评估时刻；未来时间、已过期或未提供评估时刻的 evidence 不得进入当前支持判断，但只要其原始 approval、观察窗口、Task/run 与当时固定的 Platform case/support cell 仍有效，它继续作为历史审计证据，不能令旧 run/archive 反向失效。

## Stop conditions

遇到以下情况，Agent 必须停止受影响任务并标记 blocked：

- 需要改变 Core/AC/安全默认值；
- 两个权威规格冲突；
- 设备或 server ownership 无法确认；
- destructive outcomeUnknown；
- 需要未授权的新权限、联网、签名或外部系统变更；
- 必需硬件/fixture/工具缺失；
- 验证无法二值化或证据不可复查。
- 当前 Change 已有 externally approved successor；successor 缺 ledger-complete barrier；或 barrier 前仍存在未终态 claim。
