# Device Targeting and Rebinding Specification

> Version：1.0.0  
> Status：in baseline CORE-1.0.0（ratification 状态见 `openspec/baselines/CORE-1.0.0.yaml`）  
> Baseline：CORE-1.0.0  
> Applicability：all platforms

## Purpose

保证多设备、重启、升级模式和不同 transport 下的命令不会串线，且 endpoint 永远不被当作设备身份。

## Requirements

### Requirement: REQ-DEV-001 Immutable original target and revisioned current binding

Job SHALL 固化不可变 `OriginalTargetSnapshot`，并使用唯一可派发命令的 `CurrentDeviceBinding(connectKey, revision, identitySnapshot, evidence, confirmedBy, channelProtection)`。`connectKey` SHALL 只表示寻址。

#### Scenario: AC-DEV-001-01 Job 创建绑定

- GIVEN 用户选择一台 ready 设备
- WHEN Job 创建
- THEN original target 和 binding revision 1 被 durable 保存
- AND UI 后续选择变化不能改写它

### Requirement: REQ-DEV-002 Every command pins a durable binding revision

每个设备 Step intent SHALL 在派发前记录 binding revision。每条 device-scoped HDC dispatch SHALL 从该 revision 对应的 durable `CurrentDeviceBinding` materialize `-t <connectKey>`；它 SHALL NOT 使用 HDC 默认目标、UI 当前选择或设置页中的另一个 endpoint。缺少 binding、connectKey 或 revision 不匹配时 dispatch SHALL 为 0。只有 rebind workflow 能在 durable 保存 old/new connectKey、证据和确认结果后产生新 revision。

#### Scenario: AC-DEV-002-01 Rebind 后命令使用新 revision

- GIVEN revision 1 的设备重启并经确认绑定到新 connectKey
- WHEN revision 2 durable 保存后派发下一条命令
- THEN该 intent 引用 revision 2
- AND实际 HDC argv 包含 revision 2 的 `-t <connectKey>`
- AND revision 1 的 endpoint 不再被使用

#### Scenario: AC-DEV-002-02 多设备默认目标不得串线

- GIVEN设备 A 与 B 同时在线，Job 固定设备 B 的 binding revision
- WHEN Adapter 构造 device-scoped HDC 命令
- THEN argv 显式包含设备 B 的 `-t <connectKey>`
- AND缺失或使用设备 A connectKey 时 execution gate 拒绝，进程调用数为 0

### Requirement: REQ-DEV-003 Core-owned USB auto-rebind threshold

USB 只有在 Provider 预期的模式切换、恰好一个候选且 serial/daemon fingerprint、USB topology、预期模式等证据满足 Core minimum policy 时 MAY 自动 rebind。Provider/Profile SHALL 只能加严，不能降低该阈值；model/build 相似 SHALL NOT 单独成立。

#### Scenario: AC-DEV-003-01 强证据单候选

- GIVEN 一个预期 updater 切换和一个满足 Core policy 的 USB 候选
- WHEN Reconciler 评估候选
- THEN Core policy evaluation 返回 `autoRebindEligible`
- AND无论 Provider 选择自动绑定或更严格的人工确认，任何后续 dispatch 前都必须先 durable 保存证据和新 binding revision

#### Scenario: AC-DEV-003-02 Profile 试图降低阈值

- GIVEN Profile 将 model 相同声明为充分证据
- WHEN serial/topology 缺失或多个候选存在
- THEN系统进入 `awaitingRebindConfirmation`
- AND device mutation dispatch 数为 0

### Requirement: REQ-DEV-004 TCP requires explicit add and reconfirmation

TCP endpoint SHALL 由用户显式添加，ArkDeck SHALL NOT 扫描网络。任何断线后，系统 SHALL 重新 probe 并由用户确认；同一 `IP:port` SHALL NOT 被当作同一设备，地址变化时 SHALL NOT 按 model/build 猜候选。

#### Scenario: AC-DEV-004-01 Endpoint 被另一设备复用

- GIVEN TCP 断线后同一 IP:port 指向另一块板
- WHEN目标再次出现
- THEN系统暂停并展示身份 diff
- AND 用户确认前不执行 mutation

### Requirement: REQ-DEV-005 UART requires explicit reconfirmation

UART 设备节点和 USB-UART adapter SHALL NOT 被当作板卡身份。节点重建、断线或模式切换后 SHALL 由用户确认目标。

#### Scenario: AC-DEV-005-01 串口节点重建

- GIVEN `/dev` 或 Windows COM 标识在重连后变化
- WHEN候选重新出现
- THEN系统进入确认状态而不是自动恢复写操作

### Requirement: REQ-DEV-006 Identity gates device effects

身份未确认时，`deviceMutation` 和 `destructive` Step SHALL 被 execution gate 拒绝。候选 diff、用户选择和拒绝 SHALL 写入 journal。

#### Scenario: AC-DEV-006-01 歧义候选阻断刷写

- GIVEN 两个都可能是原设备的候选
- WHEN Flash workflow 请求下一分区写入
- THEN请求被阻断
- AND journal 记录歧义证据与等待状态

### Requirement: REQ-DEV-007 Capability probing is evidence-based

ArkDeck SHALL 通过当前设备实际工具/help 探测 `hidumper`、hitrace/bytrace、param、hilog、root、updater、flashd、tag 和参数能力。未知或解析失败 SHALL 显示 unavailable/raw detail，不得根据产品版本名称猜测支持。

#### Scenario: AC-DEV-007-01 未知 help 输出

- GIVEN 固件输出不属于支持的 golden family
- WHEN Adapter 无法可靠解析
- THEN capability 为 unsupported 或 unknown
- AND raw help 可查看

### Requirement: REQ-DEV-008 Per-device mutation lane

每台设备 SHALL 由一个 coordinator 管理。Flash、UI Dump、Trace 和会改系统参数的操作 SHALL 使用 exclusive lane；只读 observation MAY 在验证安全后并行。不同设备 MAY 并行，但仍受 host-wide HDC 和 storage 资源协调。

#### Scenario: AC-DEV-008-01 同设备双 mutation 被拒绝

- GIVEN 同一设备已有 exclusive Job
- WHEN第二个 mutation Job 请求运行
- THEN第二个 Job 保持 `queued` 且 reason 为 `deviceLaneBusy`，直到 lane 可用或用户取消
- AND任何操作序列中同设备 mutation lane 数不超过 1
