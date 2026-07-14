# Toolchain and HDC Server Specification

> Version：1.0.0  
> Status：in baseline CORE-1.0.0（ratification 状态见 `openspec/baselines/CORE-1.0.0.yaml`）  
> Baseline：CORE-1.0.0  
> Applicability：all platforms

## Purpose

定义 HDC 工具选择、共享 server 生命周期、授权和通道保护的跨平台行为。平台只能替换发现、进程和信任检查 API。

## Requirements

### Requirement: REQ-HDC-001 External-first tool selection

ArkDeck SHALL 优先使用用户明确配置或 DevEco/OpenHarmony SDK 提供的 HDC，SHALL 展示绝对路径、来源、hash/signature、client/server/daemon version 和 endpoint，且 SHALL NOT 因 `PATH` 顺序变化在 Job 运行中静默切换工具。

#### Scenario: AC-HDC-001-01 Job 固定 toolchain

- GIVEN 设置页存在多个 HDC 候选
- WHEN 用户创建 Job
- THEN Job intent 固定所选 HDC 的 path、hash、version、endpoint 和 server generation
- AND 后续设置变化不影响该 Job

#### Scenario: AC-HDC-001-02 Toolchain 诊断字段完整

- GIVEN ArkDeck 已发现一个 HDC client 及其连接的 server/daemon
- WHEN 用户查看候选详情或 Job toolchain snapshot
- THEN UI 与持久化诊断包含绝对 path、来源、hash、平台签名/信任状态、client/server/daemon version 和 endpoint
- AND 任一字段无法探测时明确标为 unknown/unverified，而不是省略或猜测

### Requirement: REQ-HDC-002 Host-wide supervisor

HDC server SHALL 被建模为 host-wide 共享资源，由单一 `HDCServerSupervisor` 管理发现、健康、版本、endpoint、ownership 和 generation。Per-device coordinator SHALL NOT 各自拥有独立的默认 server 生命周期。

#### Scenario: AC-HDC-002-01 Server 崩溃影响全部设备

- GIVEN 两台设备共享一个 HDC endpoint
- WHEN server generation 变化或健康检查失败
- THEN 两台设备和相关 Job 都收到同一个 host-wide 事件
- AND 事件不得被误报为单设备故障

### Requirement: REQ-HDC-003 Ownership-protected lifecycle

ArkDeck SHALL 将 server 标为 `external | arkDeckManaged | unknown`。任何自动路径 SHALL NOT 对 `external` 或 `unknown` server 执行 kill、restart、`kill -r`、`start -r` 或 `killall-sub`。

#### Scenario: AC-HDC-003-01 DevEco server 不被自动停止

- GIVEN 默认端口已有 DevEco 启动的健康 server
- WHEN ArkDeck 探测、授权失败或版本不匹配
- THEN ArkDeck 只提供诊断和用户确认的恢复选项
- AND 自动 server stop 调用数为 0

#### Scenario: AC-HDC-003-02 Managed ownership 需要证据

- GIVEN endpoint 启动前没有 server
- WHEN ArkDeck 启动并验证 PID、tool path 和 endpoint
- THEN 才能标记为 `arkDeckManaged`

### Requirement: REQ-HDC-010 Audited manual lifecycle mutation

任何用户发起的 HDC server lifecycle mutation SHALL 被视为 host-wide 操作，而不是单设备恢复动作，并且只能通过 registry 中的 `mutateHDCServerLifecycle` typed step 执行。执行前 UI SHALL 显示精确 action、endpoint、server generation、ownership、受影响的设备和 Job、检测到的其他 client，以及预期中断与恢复路径；系统 SHALL 将该 impact snapshot 与用户确认 durable 关联。确认只授权所显示 generation 和 action，不转移 `external | unknown` ownership，也不授权额外的 kill/restart/subserver 操作。

当任何受影响 ArkDeck Job 正执行 `criticalNonInterruptible` Step、正在等待其安全边界，或系统无法可靠确定 endpoint、generation、受影响 ArkDeck Job 与 critical Job gate 时，lifecycle mutation SHALL 被阻断。其他 client 探测 MAY 是 best effort，但预览 SHALL 明示检测结果及“仍可能存在未知外部 client”，不得把未检测到解释为不存在。系统 SHALL 在确认后、dispatch 前重新验证 generation、impact 和 critical Job gate；任一变化 SHALL 使确认失效并要求重新预览。执行 intent、实际 argv/endpoint、结果、generation 变化及所有受影响 Job SHALL 写入 host-wide audit；失败或 outcome 未知 SHALL 广播给共享该 endpoint 的全部 device coordinator/Job 并进入相应 reconcile，不得伪装为单设备成功。

#### Scenario: AC-HDC-010-01 Critical flash 阻断人工 restart

- GIVEN 一台共享 endpoint 的设备正在执行 criticalNonInterruptible flash Step
- WHEN用户请求并确认 restart HDC server
- THEN lifecycle dispatch 数为 0
- AND UI 显示阻断它的 Job、Step 和等待安全边界的恢复动作

#### Scenario: AC-HDC-010-02 External server 的影响预览与审计

- GIVEN external server 被两台设备和一个检测到的其他 client 使用
- WHEN用户在影响预览后确认针对当前 generation 的单次 restart
- THEN确认记录包含 action、endpoint、generation、ownership、两台设备、相关 Job 和其他 client
- AND dispatch 前相同 impact 被重新验证
- AND lifecycle intent/outcome 作为 host-wide audit 持久化并广播给两台设备的 coordinator

#### Scenario: AC-HDC-010-03 过期确认不得复用

- GIVEN 用户确认后 server generation 或受影响 Job 集合发生变化
- WHEN系统准备 dispatch lifecycle mutation
- THEN原确认失效且外部 lifecycle 命令不启动
- AND系统生成新的影响预览并要求重新确认

### Requirement: REQ-HDC-004 Endpoint isolation

ArkDeck SHALL 识别默认端口、`OHOS_HDC_SERVER_PORT` 和显式 endpoint，且 SHALL 只为自己的子进程设置选择结果。它 SHALL NOT 修改用户全局 shell 或系统环境。仅更换端口 SHALL NOT 被解释为已经拥有独立 server。

#### Scenario: AC-HDC-004-01 显式 endpoint 不污染用户环境

- GIVEN 用户选择非默认 HDC endpoint
- WHEN Job 完成
- THEN ArkDeck 子进程使用该 endpoint
- AND 用户全局环境保持不变

### Requirement: REQ-HDC-005 Version and semantic compatibility

Client/server version 字符串不同时，系统 SHALL 进入 `mismatchUnverified` 而不是直接判定兼容或不兼容。只读能力 MAY 经 probe 降级；Flash SHALL 只允许已验证的 toolchain/device/provider 组合。退出码 0 SHALL NOT 单独证明 HDC 操作成功。

#### Scenario: AC-HDC-005-01 旧 HDC 静默失败

- GIVEN HDC 退出码为 0 但输出含 `[Fail]`、错误码、Unauthorized 或 Offline
- WHEN Adapter 解析结果
- THEN Step 结果不是 success
- AND raw stdout/stderr 可查看

### Requirement: REQ-HDC-006 Tool-managed authorization keys

MVP SHALL 默认由当前 HDC 管理授权 key，不复制、删除、上传或记录私钥。ArkDeck MAY 记录公钥指纹和诊断状态。默认 key 路径属于版本化实现信息，SHALL NOT 被 Core 硬编码为稳定 API。

#### Scenario: AC-HDC-006-01 Key 不可访问

- GIVEN 平台权限阻止当前 HDC 访问其 key
- WHEN 授权 probe 失败
- THEN UI 显示可诊断错误
- AND ArkDeck 不删除 key、不重置用户目录、不自动重启共享 server

### Requirement: REQ-HDC-007 Explicit unauthorized workflow

Unauthorized SHALL 是可恢复状态：系统提示解锁设备和确认信任，执行有界、可取消轮询，并区分未信任、拒绝和超时。系统 SHALL NOT 为重新弹窗而静默 kill server。

#### Scenario: AC-HDC-007-01 用户完成信任

- GIVEN 设备处于 unauthorized
- WHEN 用户在设备上确认并且 probe 返回 ready
- THEN状态迁移为 ready
- AND Job 可在身份仍匹配时继续

#### Scenario: AC-HDC-007-02 用户拒绝或超时

- GIVEN 设备拒绝信任或超过授权期限
- WHEN 轮询结束
- THEN UI 显示 denied 或 timedOut 和非破坏性重试路径
- AND 不执行 server lifecycle mutation

### Requirement: REQ-HDC-008 Authorization and channel protection are independent

设备授权状态和链路保护状态 SHALL 分开建模。`encryptedVerified` SHALL 携带版本化诊断、ArkDeck-owned server log 或批准的等价 evidence；否则 SHALL 使用 `unverifiedAssumeUnprotected`。系统 SHALL NOT 从授权成功、版本号或环境变量值推断加密已经协商。

#### Scenario: AC-HDC-008-01 授权不冒充加密

- GIVEN TCP 设备已授权但没有可靠协商证据
- WHEN UI 展示连接安全状态
- THEN 显示 authorized 和 channel protection unverified
- AND 应用按未保护通道提示仅在可信、隔离网络中使用

### Requirement: REQ-HDC-009 Conservative subserver policy

MVP MAY 探测 subserver 能力，但 SHALL NOT 自动调用 `spawn-sub` 或 `killall-sub`，因为设备迁移可能影响其他 HDC client。

#### Scenario: AC-HDC-009-01 Subserver 只读探测

- GIVEN HDC 宣称支持 subserver
- WHEN ArkDeck 完成环境诊断
- THEN 能力可显示
- AND 没有自动设备迁移或 subserver lifecycle 操作
