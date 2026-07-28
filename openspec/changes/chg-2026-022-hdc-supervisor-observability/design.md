# CHG-2026-022 Design:supervisor 可观察性

> Status:r3 candidate。仅在对应治理 PR 由维护者 review/merge 后生效；本文件
> 不构成 TASK-OBS-001R 或 TASK-OBS-002 readiness。
> Core baseline:CORE-2.1.0(零 Core 变更)

## 0. 不变量(硬边界)

- **纯可观察性**:本 change 只加"计数、标签、来源、事件的暴露",不加任何新的
  dispatch/lifecycle/设备 mutation 路径;M1-006 的 external-first、零自动
  lifecycle、endpoint 子进程隔离、registry fail-closed 语义逐条保持。
- **仪表化真实性(M1-010/004 准则)**:计数器只在 identity-bound
  `posix_spawn` 成功返回后的唯一 hook 递增；prepare、gate reject、spawn failure
  均不计数。origin 不接受 caller-supplied enum/string/flag；contract 测试须通过
  同一真实 hook 的 fake-process mutation seam 证伪，不得直接调用 monitor。
- **ownership 升级不降门**:`.external` 与 `.unknown` 在 lifecycle 授权门的语义
  同等(M1-006 design 既定);判定升级仅改变标签与证据展示,任何门逻辑 diff 即
  整体 fail。

## 1. Kit 面(TASK-OBS-001)

- **计数器与 origin**:
  - supervisor 侧暴露 `automaticLifecycleDispatchCount`/
    `automaticSubserverDispatchCount`，并保留 confirmed lifecycle 与 managed-start
    的独立计数/审计，presentation 不得把后二者相减或重命名成 automatic；
  - `FoundationProcessExecutor` 的 identity-bound 成功 spawn hook 是唯一计数点。
    HDC 层在该 hook 以 sealed typed argv family 判 lifecycle/subserver，并验证
    supervisor 铸造的 opaque dispatch permit；普通 process/HDC caller 无构造器、
    无 origin 参数、无 monitor 写入口；
  - confirmed lifecycle permit 只能由 durable confirmation + current dispatch lease
    铸造；managed-start permit 只能由 absent-endpoint authorization + retained
    managed-launch evidence 铸造。spawn 时无匹配 permit 的 lifecycle/subserver
    invocation 才计入 automatic；人工确认和 managed start 不得计入；
  - mutation contract 必须让 fake executable 经相同 identity-bound spawn hook 实际
    启动一次，同时由 fault seam 移除/破坏 permit，证明 automatic counter 从 0
    变为正数；直接 `record`、构造 origin enum 或只验证类型存在均失败；
  - 当前生产仍不得新增 automatic lifecycle/subserver producer。该 hook 是对任何
    未来回归的检测，不是 dispatch 授权。
- **ownership 判定**:`observeRegisteredExistingServer` 族在满足全部证据时判
  `.external`:① probe 前 server 已存在(pre-existing receipt);② 本会话
  automatic lifecycle dispatch 计数 = 0;③ generation 铸造自观察收据而非
  ArkDeck 启动;④ supervisor 无 active 或 unreconciled managed-launch provenance。
  任一证据缺失 → 保持 `.unknown`，但经实时 evidence 仍有效的 managed claim
  保持 `.arkDeckManaged`。既有 managed claim 只有经显式 reconcile/retire 记录后，
  后续独立 pre-existing observation 才可参与 external 判定；bracketed observation
  自身不得直接完成 managed → external。判定依据随 presentation 暴露。
- **endpoint source**:`HDCServerEndpointSource`(已有类型)进 presentation;
  另暴露"child-env 注入清单"(注入了哪些键;父进程 env 零修改契约由既有测试
  保持)。
- **设备 fan-out feed**:consumer/diff/broadcast/presentation 环形缓冲仍属本
  change，但 production producer 不存在于当前 `OPENHARMONY-TOOLS@0.3.0`：
  `selectedDeviceAuthorizationBinding` 只允许既有 durable binding 的精确 capture，
  失败/不同 row/空输出均为 unknown，不能表示设备集合或 disappearance。实现前
  必须有独立 approved/done integration change 注册参数化 zero-to-many 只读设备
  snapshot family、identity bracket、success/failure/unknown 语义与隐私规则；本
  change 只消费该 typed snapshot，不能新增未注册 argv。设备观察 recipient 与
  lifecycle critical-participant registry 分离，不能借 fan-out 改变 impact scope。

## 2. App-facing fan-out bridge(TASK-OBS-001R)

- **Public typed projection**:
  `HDCDiagnosticsPresentation` 增加 immutable `deviceEvents`，元素至少包含
  `timestamp`、closed kind 与可选 `redactedDeviceIdentifier`。`timestamp` 必须
  是 injected clock 在事件接受点生成的 UTC RFC 3339 字符串；kind 仅允许
  `appeared`/`disappeared`/`observationUnknown`/
  `observationUnavailable`。internal `.unchanged` 只更新已知 presence，不追加
  presentation history，避免每次 refresh 伪造新“事件”。appeared/disappeared
  必须携带 `redacted-device-<24 lowercase hex>`；unknown/unavailable 不得携带
  设备标识。raw connect key 在 adapter 内终止，public API、日志与 fixture 均
  不得出现。
- **Production composition ownership**:
  `ArkDeckWorkflows` production facade 为当前 candidate/endpoint/session 持有唯一
  composition 与同一 session-scoped pseudonym key。只有 candidate identity
  精确匹配 registered 3.2.0f SHA-256，endpoint 精确为 `127.0.0.1:8710`，且
  stable existing-server identity bracket 可建立时才允许发出 registered
  `list targets -v`；任一前置缺失/漂移均 fail closed 为 unavailable，零其他
  HDC argv dispatch。切换 executable、session identity 或 endpoint 时丢弃旧
  composition/buffer/key，不承诺跨 session 关联。
- **Refresh/cancel lifecycle**:
  复用既有 App/provider 显式 `refresh()`；每次 refresh 最多执行一次
  registered observation，并把接受到的 transition/status events 追加到
  presentation buffer。不得新增 timer、后台轮询或自动 retry；同一 facade 上
  observation 串行化，取消/失效 refresh 只可终止它拥有的 observation child，
  结果为 unavailable，绝不能 stop/restart/kill/adopt HDC server，也不能触发
  subserver/device mutation。presentation buffer 容量固定为既有 production
  composition 默认值 64，溢出只保留最新 64 条且顺序稳定。
- **Fixture boundary**:
  `--ui-test-hdc-diagnostics` 的 presentation-only provider 经同一 public 类型
  提供确定性 appeared/disappeared 事件及固定 RFC 3339 时间戳，用于 OBS-002
  signed XCUITest；production factory 不得接受 fixture/test-only source，
  无 flag 路径必须证明零 fixture 值。fixture 不构成真实设备或 M0B-002 evidence。
- **Package boundary**:
  App 仍只 import `ArkDeckCore`/`ArkDeckWorkflows`；OpenHarmony raw snapshot、
  diff event、source、composition 与 HMAC key 均不得成为 App 可构造能力。

## 3. App 面(TASK-OBS-002)

- HDCStatusView 新增字段(全部 static-text 可访问 id,截图/Accessibility 双载体):
  `hdc.counters.autoLifecycle`/`hdc.counters.autoSubserver`、`hdc.endpoint.source`、
  `hdc.ownership.basis`(判定依据摘要)、设备事件列表 `hdc.devices.events`
  (按顺序显示时间戳+appeared/disappeared/observation 状态+脱敏后的设备标识；
  connect key 永不显示)。设备列表只消费 OBS-001R public presentation，
  不 import/构造 OpenHarmony source 或 composition。
- signed XCUITest:新字段存在性+值形态断言(M1-006 XCUITest 模型与 fixture 复用);
  fixture 路径经 `--ui-test-hdc-diagnostics` 门,生产路径零 fixture。

## 4. M0B-002 取证映射(本 change done 后)

| M0B-002 观察点 | 取证载体 |
| --- | --- |
| external ownership 分类 | `hdc.ownership` = external + `hdc.ownership.basis`(截图/AX 读值) |
| 仪表计数 = 0 | `hdc.counters.*` 读值(实测 0,变异测试背书其真实性) |
| endpoint 隔离 | `hdc.endpoint.source` + child-env 注入清单(父 env 零修改) |
| 设备 fan-out | 仅在独立 integration producer done 后由 `hdc.devices.events` 读取真实插拔事件；测试注入不构成此观察点 evidence |

## 5. 边界与波及

- CHG-2026-006 acceptance 不改写(ownership 字面在 external 判定落地后可达);
- 与 CHG-2026-021(trace)零文件交集;与 chg-008(UD 线)零交集;
- Windows/Linux not started 保持;平台端口不得改变 supervisor 保护语义(AGENTS
  边界)。
