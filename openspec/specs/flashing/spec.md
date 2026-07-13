# Flashing Specification

> Version：1.0.0  
> Status：review candidate  
> MVP：one verified HDC/flashd provider  
> Applicability：all platforms

## Purpose

定义刷机 Provider、preflight、执行模式、危险步骤、恢复和硬件支持声明。平台差异不得改变安全门。

## Requirements

### Requirement: REQ-FLASH-001 Typed Provider contract

每个 Flash Provider SHALL 提供 probe、validate、makePlan 和 recover，并生成 typed FlashStep。HDC/flashd、fastboot、Rockchip 或厂商工具 SHALL 是独立 Provider；系统 SHALL NOT 承诺一套命令覆盖所有设备。

#### Scenario: AC-FLASH-001-01 Unsupported protocol

- GIVEN设备不支持当前 Provider
- WHEN probe/validate
- THEN preflight 阻断
- AND不会尝试“相似命令”

### Requirement: REQ-FLASH-002 Explicit prerequisites

Provider SHALL 声明 `root | updater | flashd | unlocked | stablePower | recoveryPath | ...` 的 required/optional/notApplicable 和 satisfied/unsatisfied/unknown。任何 required prerequisite 为 unsatisfied 或 unknown 时 SHALL 在临界步骤前阻断。

#### Scenario: AC-FLASH-002-01 Flashd 未验证

- GIVEN设备已进入 updater 但无法确认 flashd 能力
- WHEN destructive confirmation 前 preflight
- THEN执行分支不可开始

### Requirement: REQ-FLASH-003 Validated image set and exact plan

Profile SHALL 声明允许分区、必需文件、大小范围、hash 和顺序。UI SHALL 展示设备身份、Provider、镜像路径/hash、分区、数据擦除和完整计划。

#### Scenario: AC-FLASH-003-01 镜像 hash 不符

- GIVEN image hash 与 Profile 不匹配
- WHEN validate
- THEN执行和 planned-success 都被阻断

### Requirement: REQ-FLASH-004 Distinct execution modes

`execute | planOnly | simulated` SHALL 在 UI、Job、manifest、History 和导出中持续可辨识。只有 execute MAY 触发真实设备 mutation。

#### Scenario: AC-FLASH-004-01 模式标识持久化

- GIVEN任一模式完成或失败
- WHEN Session 导出
- THEN manifest 保留 executionMode 和相应 Provider/fixture identity

### Requirement: REQ-FLASH-005 Plan-only produces a full non-executed plan

真实 Provider 的 plan-only SHALL 复用真实 probe/validate/makePlan，允许 hostOnly/readOnly probe 和流式 hash。完整计划 SHALL 保留 deviceMutation/destructive steps、顺序和参数摘要并标记 `notExecuted(planned)`，但 SHALL NOT 派发它们。任何错误派发尝试 SHALL fail closed；只有 plan Artifact finalization 成功后状态为 planned。

#### Scenario: AC-FLASH-005-01 完整计划且零 mutation

- GIVEN有效 Profile 含 enterUpdater、erase 和 flashPartition
- WHEN plan-only 成功
- THEN三个步骤均出现在 plan Artifact
- AND mutation/destructive runner 调用数为 0
- AND terminal status 为 planned

#### Scenario: AC-FLASH-005-02 Finalization 失败

- GIVEN完整计划无法持久化
- WHEN finalization 失败
- THEN status 为 failed 而不是 planned

### Requirement: REQ-FLASH-006 Simulation is isolated from real devices

Simulated Provider SHALL 使用合成设备/fixture 和可配置 delay/failure/disconnect/outcomeUnknown，不接受真实 connectKey、不启动外部工具。Release 中如保留 SHALL 只在明确 Demo/Developer Mode 出现，并持续标识模拟。

#### Scenario: AC-FLASH-006-01 Simulation 不进入硬件矩阵

- GIVEN模拟刷机全部成功
- WHEN生成 verification evidence
- THEN evidence 类型为 simulated
- AND hardware support matrix 不新增 verified 记录

### Requirement: REQ-FLASH-007 Destructive confirmation

Execute 分支 SHALL 在显示 exact plan 后要求危险确认；erase、format、unlock 或 downgrade SHALL 使用更强确认。确认 SHALL 包含设备、镜像、Provider、分区和数据影响。

#### Scenario: AC-FLASH-007-01 用户取消确认

- GIVEN exact plan 已生成
- WHEN用户拒绝 destructive confirmation
- THEN任何 updater/flash/erase 调用数为 0

### Requirement: REQ-FLASH-008 Critical writes are not force-killed

分区写入 SHALL 标为 criticalNonInterruptible 或 Provider 证明的等价安全策略。取消只 SHALL 阻止后续步骤并在安全边界生效。

#### Scenario: AC-FLASH-008-01 写分区时退出请求

- GIVEN App 收到正常退出且 critical write 在运行
- WHEN退出协调开始
- THEN请求被 durable 记录并延迟到安全边界

### Requirement: REQ-FLASH-009 Power activity with honest limits

Execute 分支从进入升级模式前到 postflight 或稳定 recovery/terminal SHALL 持有引用计数的 idle-sleep activity，并在所有 success/failure/cancel/throw 路径释放。UI SHALL 提示勿合盖、主动睡眠、断电或拔线，并 SHALL NOT 承诺阻止这些事件。

#### Scenario: AC-FLASH-009-01 Sleep/wake 仍发生

- GIVEN系统发生无法阻止的 sleep/wake
- WHEN App 恢复
- THEN事件写入 journal
- AND执行 reconnect/reconcile 而非假设步骤继续

### Requirement: REQ-FLASH-010 Rebinding obeys transport identity rules

进入 updater、重启和返回系统模式 SHALL 使用 Core device binding contract。身份未确认时，任何 Flash mutation SHALL 被阻断。

#### Scenario: AC-FLASH-010-01 TCP updater 回连

- GIVEN TCP 设备进入升级流程后断线再出现
- WHEN目标可达
- THEN必须由用户确认 identity diff
- AND不会静默续刷

### Requirement: REQ-FLASH-011 Host/device space and streaming progress

Flash SHALL 对 host Session/归档和设备 staging 的需要执行空间 preflight，并使用 HostStorageCoordinator。Hash 和 transfer SHALL 流式执行；只有 Provider 有可靠 byte total 时 MAY 显示百分比/吞吐/ETA。

#### Scenario: AC-FLASH-011-01 未知传输总量

- GIVEN厂商工具只报告阶段文本
- WHEN镜像传输
- THEN UI 显示 indeterminate 阶段
- AND不按步骤数量伪造百分比

### Requirement: REQ-FLASH-012 Success requires semantic verification and postflight

进程退出 0 SHALL NOT 单独构成刷机成功。Provider SHALL 解析语义输出并完成适用的 postflight、设备/版本校验后才进入 succeeded。

#### Scenario: AC-FLASH-012-01 工具退出 0 但 postflight 不匹配

- GIVEN flash tool 退出 0 但设备未返回或版本不符
- WHEN postflight
- THEN Job 不为 succeeded

### Requirement: REQ-FLASH-013 Recovery is bounded and honest

失败 SHALL 提供当前阶段、最后确认步骤、设备模式和 Provider RecoveryGuide。ArkDeck SHALL 明确刷机可能丢失数据、无法启动或需要厂商恢复工具，且 SHALL NOT 保证所有失败可自动恢复。

#### Scenario: AC-FLASH-013-01 未回连

- GIVEN设备刷写后未在期限内回连
- WHEN recovery UI 显示
- THEN状态不是 succeeded
- AND展示经过 Provider 定义的人工恢复路径与 unknown 状态

### Requirement: REQ-FLASH-014 Hardware support requires real evidence

MVP SHALL 至少在一个明确设备型号、固件、HDC 版本和 Provider 组合上完成真实验收。新增设备或厂商协议 SHALL 独立记录工具、Profile、parser、恢复路径和硬件证据。

#### Scenario: AC-FLASH-014-01 支持矩阵条目

- GIVEN目标设备完成全部 required hardware AC
- WHEN审核 evidence
- THEN support matrix 记录精确组合与证据日期
- AND simulation/fake 不可替代

### Requirement: REQ-FLASH-015 Agent and ordinary CI destructive boundary

自主 Agent/普通 CI 的执行凭据 SHALL 只允许 Flash workflow 的 contract、fake、simulated 或 plan-only 分支，并 SHALL 在真实 binding 与 `destructive` Step 同时出现时 fail closed。真实硬件 Flash/erase/format/unlock/update dispatch SHALL 要求独立 hardware-lab execution class，以及仍在有效期内、仓库外人类批准并精确绑定 operator、immutable Task/claim、canonical plan hash、authorized Step kinds、runtime capabilities、device identity/binding revision、固件、transport、HDC、Provider 与物理目标确认的 pre-dispatch authorization；执行器 SHALL 在首个真实设备 Step 前重新验证全部字段。普通 Task/claim、聊天确认、已连接 USB、事后 run 或 hardware evidence 均不得升级或补发该权限。

#### Scenario: AC-FLASH-015-01 普通 Agent Task 请求真实刷写

- GIVEN 一个普通 AI Agent/CI claim 拥有真实设备 binding，并生成含 flashPartition 的 execute plan
- WHEN workflow authorization gate 校验 execution class
- THEN destructive dispatch 数为 0，Job 标记 policyBlocked 并生成受控人工 handoff
- AND 只有另行批准的 hardware-lab run 才能产生 realHardware evidence

#### Scenario: AC-FLASH-015-02 实验室授权与待执行计划或目标不一致

- GIVEN controlledHardwareLab claim 自报 humanOperator，但 authorization 缺失、过期，或其 plan hash、Step kinds、operator、target binding、固件、transport、HDC、Provider 任一字段与待执行值不同
- WHEN 执行器在首个真实设备 Step 前校验 authorization
- THEN 真实设备 dispatch 数为 0，run 不得产生 verified realHardware evidence
- AND 后续补写 run、hardware evidence 或聊天确认不能把该次执行追认为已授权
