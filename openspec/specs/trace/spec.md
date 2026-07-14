# Trace Capture Specification

> Version：1.0.0  
> Status：in baseline CORE-1.0.0（ratification 状态见 `openspec/baselines/CORE-1.0.0.yaml`）  
> MVP：yes  
> Applicability：all platforms

## Purpose

定义 hitrace/bytrace 能力探测、Debug 参数策略、采集、接收和 raw/derived trace 行为。

## Requirements

### Requirement: REQ-TRACE-001 Dynamic adapter selection

系统 SHALL 分别探测 hitrace 和 bytrace 的实际存在、help、tag 和参数能力。两者并存时 SHALL 使用已验证 Profile/能力矩阵选择，SHALL NOT 仅按工具名或系统版本猜测。

#### Scenario: AC-TRACE-001-01 未知 help family

- GIVEN设备 help 输出无法可靠解析
- WHEN用户配置 Trace
- THEN未知选项不可选择
- AND raw help 可查看

### Requirement: REQ-TRACE-002 Capability-constrained configuration

Duration、buffer、tag 和 begin/finish 选项 SHALL 只使用当前 Adapter 明确支持的语义。附件 preset MAY 作为兼容输入，但 SHALL 展示 buffer 资源警告，不能假定所有固件单位一致。

MVP built-in catalog SHALL 包含下列逻辑 preset；运行时只保留当前设备 probe 证实支持的 tag：

| Preset | Logical tags |
| --- | --- |
| Attachment panorama | `sched freq ace app binder disk ohos graphic sync workq ability` |
| ArkUI deep | `ace app ability graphic ohos sched freq sync` |
| Render/animation | `graphic ace app sched freq sync` |
| Scheduling/IPC | `sched freq workq binder sync` |
| I/O | `disk sched workq binder` |
| Custom | 仅 probe 支持的 tag |

Attachment panorama MAY 携带历史 buffer 值 `327680`，但 Adapter SHALL 在当前工具 help/profile 中确认单位和策略，并显示资源警告。

#### Scenario: AC-TRACE-002-01 不支持的 tag

- GIVEN preset 中一个 tag 不被设备支持
- WHEN preflight
- THEN系统展示 unsupported tag diff，并把原配置标记为不可执行
- AND仅在用户显式接受受支持的替代配置后才保存并继续
- AND未接受时 device dispatch 数为 0

### Requirement: REQ-TRACE-003 Typed parameter snapshots

每个 Debug 参数原值 SHALL 保存为 `missing | unreadable | value(String)`。临时恢复只在原值为可写回 value 且 read-back 验证成功时提供；系统 SHALL NOT 把所有值强制转换为 Bool，也 SHALL NOT 用 `false/0` 伪造“原本不存在”。

#### Scenario: AC-TRACE-003-01 Missing 参数

- GIVEN参数读取结果为 missing
- WHEN用户选择临时应用并恢复
- THEN临时恢复选项被禁用
- AND若 Profile 支持持久变更，系统只能把它作为独立模式展示并要求显式确认，不能静默降级

### Requirement: REQ-TRACE-004 Verified parameter mutation and restore

参数 SHALL 逐项设置并 read-back；unsupported、permission denied 和 needs developer mode SHALL 分开显示。确认可逆的值在结束后 SHALL 恢复原始字符串；恢复失败 SHALL 标记 needsAttention。

#### Scenario: AC-TRACE-004-01 Read-back 不一致

- GIVEN setparam 命令返回成功但读取值不同
- WHEN配置阶段验证
- THEN capture 不继续且 device capture dispatch 数为 0
- AND mismatch 被审计

### Requirement: REQ-TRACE-005 Reboot uses device binding contract

参数需要重启时，系统 SHALL 预期断线并使用 Core device binding/rebind 规则恢复。TCP/UART 不得自动匹配；身份未确认前不得继续设备副作用。

#### Scenario: AC-TRACE-005-01 重启后出现歧义设备

- GIVEN Trace 配置触发重启且出现两个候选
- WHEN等待回连
- THEN Job 进入 awaitingRebindConfirmation

### Requirement: REQ-TRACE-006 Isolated remote capture and verified receive

远端临时路径 SHALL 由 Job UUID 隔离。接收 SHALL 写 host partial，验证非空、格式和可用 checksum 后原子发布；只在接收验证成功后 MAY 清理 owned remote file。

#### Scenario: AC-TRACE-006-01 Receive 中断

- GIVEN设备 trace 已完成但 host receive 中断
- WHEN Job 失败
- THEN host 只有 partial 状态
- AND远端 owned file 不被过早删除

### Requirement: REQ-TRACE-007 Immutable raw and reproducible filtering

设备原始 trace SHALL 保存为 immutable raw。过滤（包括可选 `CreateFileAsset` 行） SHALL 在 host 生成 derived trace并记录删除统计。“删除前两行”只有 parser 确认其为 chatter 时 MAY 执行。

#### Scenario: AC-TRACE-007-01 Ftrace header 不被固定行删除

- GIVEN raw 首行属于有效 ftrace header
- WHEN后处理
- THEN header 保留
- AND raw bytes/hash 不变

### Requirement: REQ-TRACE-008 Honest progress and cancellation

Trace SHALL 显示明确的配置、重启、等待、采集、finalize、receive、validate、postprocess、cleanup 和 restore 阶段。只有 Adapter 能提供可靠总量时 MAY 显示百分比/ETA；停止和取消 SHALL 遵守 typed cancellation/remote stop 能力。

#### Scenario: AC-TRACE-008-01 未知总量

- GIVEN Adapter 只报告正在抓取而没有 byte total
- WHEN capture 运行
- THEN UI 显示 indeterminate 和 elapsed time
- AND不伪造百分比

### Requirement: REQ-TRACE-009 Artifact completeness

成功或部分成功 Session SHALL 记录 raw trace、可选 derived trace、capture log、manifest，以及工具、tag、duration、buffer、before/after/restored 参数、时间、hash 和过滤统计。

#### Scenario: AC-TRACE-009-01 空 trace

- GIVEN工具退出 0 但生成空文件
- WHEN validate
- THEN Job 不进入 succeeded
- AND空文件诊断被记录
