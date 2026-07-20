# Debug Workbench Specification

> Version：1.0.0  
> Status：in baseline CORE-2.0.0（ratification 状态见 `openspec/baselines/CORE-2.0.0.yaml`）  
> MVP：yes  
> Applicability：all platforms

## Purpose

定义设备日志、应用、端口转发和一次性命令工作台。源码级调试器和完整终端不属于 MVP。

## Requirements

### Requirement: REQ-DEBUG-001 HiLog capture and host rotation

系统 SHALL 支持 hilog 启停、等级、domain/tag、PID/关键字过滤、标记和 raw 保存。Host 文件 SHALL 按 size/time 分片，具有单片与总配额、顺序、size/hash 和保留策略；UI 内存窗口 SHALL 有界。

#### Scenario: AC-DEBUG-001-01 长时日志有界

- GIVEN hilog 持续超过总配额
- WHEN rotation 执行
- THEN host 占用不超过声明配额和安全余量
- AND manifest 保留仍存在分片的顺序

### Requirement: REQ-DEBUG-002 Device buffer operations are separate and dangerous

清空、扩容、flush 或设备侧落盘 SHALL 是独立、显式、经能力探测和二次确认的设备操作。普通 host capture 启停 SHALL NOT 自动修改设备 buffer。

#### Scenario: AC-DEBUG-002-01 普通启动不清 buffer

- GIVEN用户点击开始采集
- WHEN hilog stream 建立
- THEN buffer clear/resize/device flush 调用数为 0

### Requirement: REQ-DEBUG-003 App lifecycle tools

MVP SHALL 提供 HAP 安装/卸载、包信息、启动 Ability、停止进程和可调试进程展示，并对每个 mutation 显示目标设备和影响。

#### Scenario: AC-DEBUG-003-01 多设备安装

- GIVEN两台设备在线
- WHEN用户向设备 A 安装应用
- THEN所有命令引用设备 A 的 durable binding revision

### Requirement: REQ-DEBUG-004 Port forwarding management

MVP SHALL 展示 HDC forward/reverse 列表，并支持创建和删除经过参数校验的规则。删除 SHALL 明确目标规则和设备。

#### Scenario: AC-DEBUG-004-01 非法端口

- GIVEN端口超出合法范围或规则格式含自由 shell
- WHEN用户提交
- THEN preflight 拒绝且 HDC 不启动

### Requirement: REQ-DEBUG-005 One-shot commands, not an implied terminal

MVP SHALL 提供一次性 typed command 和批准模板，展示精确 executable/arguments、退出码、耗时、stdout/stderr。它 SHALL NOT 把普通文本框描述成完整 PTY/VT100 终端。

#### Scenario: AC-DEBUG-005-01 需要交互的命令

- GIVEN命令需要 PTY 或交互密码
- WHEN用户尝试运行
- THEN MVP 拒绝或明确标为 unsupported
- AND不自动调用 sudo

### Requirement: REQ-DEBUG-006 Dangerous operations remain explicit

Root/smode、重启、全局 buffer、停止进程和其他高风险操作 SHALL 与只读信息分区，显示影响范围并写审计。

#### Scenario: AC-DEBUG-006-01 Root 不可用

- GIVEN production user build 不支持 root
- WHEN用户查看 root 操作
- THEN能力显示 unavailable/unsatisfied
- AND `smode` 不被解释为 bootloader unlock

### Requirement: REQ-DEBUG-007 Disk pressure preserves completed log shards

磁盘满、停止或取消时，系统 SHALL 尽量 finalize 已完成分片和 manifest，保留 partial 状态，并 SHALL NOT 产生无限增长的单文件。

#### Scenario: AC-DEBUG-007-01 ENOSPC

- GIVEN当前日志分片写入返回 ENOSPC
- WHEN采集终止
- THEN之前完成的分片保持可用
- AND Job 显示明确 storage failure
