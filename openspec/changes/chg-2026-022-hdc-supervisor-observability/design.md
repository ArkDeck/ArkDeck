# CHG-2026-022 Design:supervisor 可观察性

> Status:candidate(随 proposal r1;approve 前不构成实现授权)
> Core baseline:CORE-2.1.0(零 Core 变更)

## 0. 不变量(硬边界)

- **纯可观察性**:本 change 只加"计数、标签、来源、事件的暴露",不加任何新的
  dispatch/lifecycle/设备 mutation 路径;M1-006 的 external-first、零自动
  lifecycle、endpoint 子进程隔离、registry fail-closed 语义逐条保持。
- **仪表化真实性(M1-010/004 准则)**:计数器在真实调用点递增;contract 测试须
  变异证伪(测试注入自动 dispatch → 计数变化;无注入 → 恒 0 有绿对照),不接受
  分支常量或"结构性不存在即为零"的推断替代仪表。
- **ownership 升级不降门**:`.external` 与 `.unknown` 在 lifecycle 授权门的语义
  同等(M1-006 design 既定);判定升级仅改变标签与证据展示,任何门逻辑 diff 即
  整体 fail。

## 1. Kit 面(TASK-OBS-001)

- **计数器**:supervisor 侧 `automaticLifecycleDispatchCount`/
  `automaticSubserverDispatchCount` 快照(actor 隔离,M1-008
  SimulatedFlashIsolationMonitor 同构形态);计数点 = 实际 executor 派发入口
  (当前生产无此路径,计数点落在防御性入口上——若未来引入自动路径,计数器天然
  覆盖);presentation 透出快照。
- **ownership 判定**:`observeRegisteredExistingServer` 族在满足全部证据时判
  `.external`:① probe 前 server 已存在(pre-existing receipt);② 本会话
  lifecycle dispatch 计数 = 0;③ generation 铸造自观察收据而非 ArkDeck 启动。
  任一证据缺失 → 保持 `.unknown`(fail-closed 方向不变);判定依据随
  presentation 暴露(供 M0B-002 落盘)。
- **endpoint source**:`HDCServerEndpointSource`(已有类型)进 presentation;
  另暴露"child-env 注入清单"(注入了哪些键;父进程 env 零修改契约由既有测试
  保持)。
- **设备 fan-out feed**:新增只读 device-observation recipient:以既有
  external-first discovery 的设备快照差分产生 appeared/disappeared 事件,进
  supervisor broadcast 与 presentation 环形缓冲(有界,如最近 32 条);零设备
  命令新增(复用既有只读 probe 面)。

## 2. App 面(TASK-OBS-002)

- HDCStatusView 新增字段(全部 static-text 可访问 id,截图/Accessibility 双载体):
  `hdc.counters.autoLifecycle`/`hdc.counters.autoSubserver`、`hdc.endpoint.source`、
  `hdc.ownership.basis`(判定依据摘要)、设备事件列表 `hdc.devices.events`
  (时间戳+appeared/disappeared+脱敏后的设备标识形态——connect key 不明文全显,
  沿用既有脱敏策略)。
- signed XCUITest:新字段存在性+值形态断言(M1-006 XCUITest 模型与 fixture 复用);
  fixture 路径经 `--ui-test-hdc-diagnostics` 门,生产路径零 fixture。

## 3. M0B-002 取证映射(本 change done 后)

| M0B-002 观察点 | 取证载体 |
| --- | --- |
| external ownership 分类 | `hdc.ownership` = external + `hdc.ownership.basis`(截图/AX 读值) |
| 仪表计数 = 0 | `hdc.counters.*` 读值(实测 0,变异测试背书其真实性) |
| endpoint 隔离 | `hdc.endpoint.source` + child-env 注入清单(父 env 零修改) |
| 设备 fan-out | `hdc.devices.events` 插拔事件读值 |

## 4. 边界与波及

- CHG-2026-006 acceptance 不改写(ownership 字面在 external 判定落地后可达);
- 与 CHG-2026-021(trace)零文件交集;与 chg-008(UD 线)零交集;
- Windows/Linux not started 保持;平台端口不得改变 supervisor 保护语义(AGENTS
  边界)。
