# CHG-2026-049 Verification Plan

> 产品闭环兼容说明（2026-07-30）：当前 E1 生产路径由 Runtime 按已发布
> Catalog 自动签发 durable capability，不再等待人工文件或 review；target、
> binding、typed inputs、plan digest、lineage 与 `outcomeUnknown` 门保持。
> 下文 r2 的人工 capability 步骤是历史计划；E2 不变。

> Change:CHG-2026-049-diagnostics-and-hap@r3
> Status:planned
> Core baseline:CORE-2.1.0 (canonical Core AC not claimed)

## Environment

- contract/fake 面:protected-main checkout,macOS arm64;fixture 工具
  (`ArkDeckFakeHDCFixture`)经 descriptor 绑定 dispatcher 真实 spawn;
- realHardware 面:Device Runtime Agent + DAYU200 + 安装态 HDC 3.2.0f;
  Agent 执行全部 host Runtime 调用,人类仅作为 `physicalAssistant`;
  `DHA-HW-002` 另需维护者经 merged PR 签发的 E1 RuntimeCapability;
- 设备原始日志/trace/dump 永不入仓;E2 面对本 change 全程禁止。

## Acceptance matrix

| AC ID | Verification method | Expected result | Minimum evidence |
| --- | --- | --- | --- |
| `DHA-AGENT-001` | one-shot Agent runner contract + fake daemon integration | Agent 经 typed daemon API 完成 doctor→adopt→submit/wait→artifact query;不接触 HDC/argv/shell;需要设备信任或目标选择时产出 structured humanAction 并可恢复;receipt 如实记录 executor/authority/job/binding,Agent surface 无 capability 管理入口 | contract |
| `DHA-ART-001` | artifact 模型契约 + 安全负向 + GC/quota 矩阵 | 元数据完整(含 hash/privacy/retention/binding snapshot);客户端只能按 ID/lease 访问,路径不可指定;path traversal/symlink 逃逸被拒;GC 不删 active/pinned;quota 逼近时拒新采集而非破坏既有;`observe.device@1` 四 artifact 真正落盘且可读 | contract |
| `DHA-CAP-001` | capture.diagnostics@1 编排契约 + effective-effect/部分失败/取消/预算矩阵 | 不含 remote trace 的 plan 走 E0;选择 remote trace/cleanup 的 plan 在 dispatch 前升为 E1且缺 capability 零 dispatch;产物缺失逐项标注;cancel/预算/cleanup debt 均有界 | contract |
| `DHA-HAP-001` | debug.hap@1 编排契约 + E1 授权/补偿矩阵 | install 成功仅由 **package readback** 判定、start 成功仅由 **process/ability readback** 判定(exit 0 + 无 readback ⇒ 不得 succeeded);缺/错 capability fail-closed;失败按 cleanup policy 补偿;unknown 即停后续 mutation 并 reconcile;HAP 只能来自 artifact lease | contract |
| `DHA-HW-001` | Device Runtime Agent:真机 E0 capture.diagnostics@1 | Agent 一次执行产出只读 artifact 集合并经 `artifact.*` 读取;receipt 记录 executor=agent/default-readonly authority;除结构化 physical assistance 外零人工 host 命令 | realHardware(Agent 执行后补记) |
| `DHA-HW-002` | Device Runtime Agent + 维护者签发的 E1 capability:真机 debug.hap@1 | Agent 一次执行 install→start→capture→stop;readback 齐全;capability 消耗一次;缺 capability 零 dispatch;人类不代跑 host CLI | realHardware(Agent 执行后补记) |

## `DHA-AGENT-001`

- runner 只组合 `ArkDeckAgentClient` 的 health/target/job/artifact typed
  方法;无 executable、argv、shell、raw HDC 或任意路径输入;
- 单次 run 最多提交一个已发布 operation,具有总 timeout、轮询上限与
  cancellation;不是多轮 AI debug loop;
- unauthorized/offline 或多候选返回 closed `humanAction`(trustDevice /
  selectTarget / physicalReconnect),持久化 resume token;恢复后沿同一
  target/binding 继续,不得重建或猜选;
- receipt 至少记录 executor=`agent`、operation@version、jobID、
  targetID/binding revision、catalog digest、E0 default-policy reference
  或 E1 capabilityID、humanAction 时间线、terminal state;
- agent-facing surface 只允许 capability reference/list/inspect/use,
  不允许 install/create/modify/revoke 或提交 capability JSON。

## `DHA-ART-001`

- 元数据:每个 artifact 具 ID、session/job/step、media type、size、
  SHA-256、created time、provider、target binding snapshot、source
  operation@version、privacy class、retention deadline;
- 访问面:`artifact.list/inspect/read/export` 只接受 artifact ID;
  任意路径参数在协议层不存在(结构性);`read` 有界;
- 安全负向:`../` 穿越、symlink 逃逸、跨 session 覆盖各一条红路径;
- 生命周期:GC 跳过 active job 引用与 pinned;retention 到期可回收;
  quota 逼近 → 新采集被拒且既有 artifact 完好;
- redaction:默认对 token/credential/host path 做基础脱敏,原始高敏
  artifact 显式标记且需授权访问;
- `observe.device@1` 端到端后四 artifact(device-facts/tool-facts/
  binding-snapshot/manifest)可 list/inspect/read,manifest 含 catalog
  digest 与 provider/tool/device facts。

## `DHA-CAP-001`

- 授权先于 dispatch:引擎按实际选中步骤的最大 effect 生成 plan effect;
  `traceCategories` 为空/缺省且无 remote temp/cleanup → E0;
  `traceCategories` 非空、remote capture 或 cleanup 被选中 → E1,
  无匹配 capability 时所有 provider dispatch 计数为 0;
- 编排:preflight → hilog → ui-dump → trace → receive → 校验 → 索引 →
  cleanup → finalize,步骤顺序与 catalog 声明一致;
- **部分成功**:trace 缺失时 `capture-summary.json` 与 job 结果逐项标注
  该 artifact 状态,整体不得记 succeeded-with-all;
- cancel:运行中取消 → 停止仍在跑的采集、在安全边界收取已完成 artifact、
  状态为 cancelled(非 failed 亦非 succeeded);
- 预算:超总 byte budget → 有序截断并标注,或失败;两种都不得写满磁盘;
- 远端:temp 路径由 provider 铸造;清理失败 → cleanup debt 记录并可被
  后续 reconcile 消费(测试驱动一次消费)。

## `DHA-HAP-001`

- 成功判定:构造"install exit 0 但 package readback 查不到"→ 结果不得
  succeeded(红路径);"start exit 0 但进程不存在"→ 同上;
- 授权:无 capability → 零 dispatch;capability scope 不含 `debug.hap@1`
  或 target 不匹配 → 拒绝;过期/撤销/耗尽 → 拒绝;一次授权覆盖整个
  recipe(不逐 step 消费多次);
- 输入:HAP 只能来自 artifact lease;本地任意路径被拒;
- 补偿:install 后 start 失败 → 按 cleanup policy 停止/卸载/恢复,并
  记录补偿结果;
- unknown:任一 mutation 步 unknown → 立即停止后续 mutation、进入
  reconcile、零自动重放。

## DHA-HW-001 / DHA-HW-002

- Device Runtime Agent 启动/连接 daemon,执行 doctor、target
  list/adopt、job submit/wait/status 与 artifact query;人工复制粘贴这些
  host 命令不能满足本 AC;
- 人类 `physicalAssistant` 只可完成设备屏幕信任、多候选物理确认或
  拔插,每次均作为 structured humanAction 记录;不成为 executor;
- `DHA-HW-002` 的 E1 capability 由维护者经 merged PR 签发,Agent 不得
  创建/修改/批准;Agent 只引用 capability ID,receipt 如实记录消耗;
- `DHA-HW-001` 使用不选择 remote trace 的 E0 plan;remote-file trace/
  cleanup 的真机执行必须另持 E1 capability,不得混入 E0 证据;
- 连接键/序列号脱敏入仓;raw 采集产物留 daemon 私有目录;
- 任一步失败如实记 blocked-attempt,不降级、不以 fixture 顶替。

## `DHA-RES-001` 残留被记录,两条路径同等

- 方法:scripted dispatcher 让 `cleanup-uninstall` 的 readback 判定为
  `uninstallIneffective`,分别在(a)正向路径与(b)补偿路径(先让 `start-ability`
  失败以触发 `compensateDebugHAP`)下断言:该 job 出现一条未结清残留记录,
  其持久化 action 就是 `.uninstallPackage(<bundle>)`,理由非空;
  且既有远端路径债务的记录行为逐条不变(同一套测试对 `cleanup-remote-staging`
  失败仍断言原有记录)。
- Evidence:实现 PR 内测试。
- 结论:pending。

## `DHA-RES-002` `succeeded` 不再读作"设备干净"

- 方法:上述 job 的终态仍为 `succeeded`(主目的完成),但其状态必须携带未结清
  残留计数 > 0;清理成功的对照组该计数为 0。断言 `JobStateMachine` 的转移表
  与终态集合**零变化**(不新增 `succeededWithResidue` 之类)。
- Evidence:实现 PR 内测试。
- 结论:pending。

## `DHA-RES-003` 结清由 readback 判定,且不接受任意目标

- 方法:`cleanupDebt.continue` 对 bundle 残留重跑持久化的精确 action;
  (a) readback 说包已不在 → 残留结清、计数归零;
  (b) readback 说包仍在 → 不得结清,记录保留;
  (c) 传入未登记的 bundle/路径 → 拒绝(与远端路径残留同一条查表键语义,
  调用方不能借此指定任意卸载目标)。
- Evidence:实现 PR 内测试。
- 结论:pending。
