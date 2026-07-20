# Session, Artifact, and Host Storage Specification

> Version：1.0.0  
> Status：in baseline CORE-2.0.0（ratification 状态见 `openspec/baselines/CORE-2.0.0.yaml`）  
> Baseline：CORE-2.0.0  
> Applicability：all platforms

## Purpose

定义 Session durable truth、Artifact 不可变性、manifest 语义和多 Job 共享卷的准入规则。

## Requirements

### Requirement: REQ-ART-001 Session is the durable Job boundary

每个 Job SHALL 有独立 Session，包含 append-only journal、原子 snapshot、命令/事件日志、raw/derived 目录和 final manifest。Session 即使 failed、cancelled、interrupted 或 App 崩溃也 SHALL 保留可诊断状态。

#### Scenario: AC-ART-001-01 失败 Session 不伪装成功

- GIVEN Artifact 接收中断
- WHEN Job finalization
- THEN Session 保留 journal、partial 状态和错误摘要
- AND manifest status 不是 succeeded

### Requirement: REQ-ART-002 Raw artifacts are immutable

设备 stdout、sidecar、trace 和 log 的 raw bytes SHALL 不被原地修改。过滤、合并、去 chatter 或其他处理 SHALL 生成 derived Artifact，并记录输入 hash、参数和统计。

#### Scenario: AC-ART-002-01 Trace 过滤可重建

- GIVEN raw trace 和过滤配置
- WHEN生成 filtered trace
- THEN raw hash 保持不变
- AND删除行数与派生参数进入 manifest

### Requirement: REQ-ART-003 Atomic publication

Artifact SHALL 先写 `.part` 或等价临时文件，验证非空、基本格式和可选 checksum 后原子发布。Snapshot SHALL 原子替换；journal 尾部半行和 schema 不兼容 SHALL 可检测。

#### Scenario: AC-ART-003-01 Receive 中途断电

- GIVEN正在写 `.part`
- WHEN进程异常退出
- THEN不会出现被标记为完整的最终 Artifact
- AND reconcile 能识别 partial

### Requirement: REQ-ART-004 Manifest preserves execution semantics

Manifest SHALL 至少保存 schema/app version、Job/Session ID、terminal status、executionMode、outcomeCertainty、sessionDisposition/archivedAt、original target、binding history、toolchain、Provider/fixture identity、step execution disposition、parameter state、Artifact metadata、warning/failure、recovery/abandon audit 和关联 Recovery Session。

#### Scenario: AC-ART-004-01 Simulation 导出仍可辨识

- GIVEN simulated Job 已归档和导出
- WHEN另一工具读取 manifest
- THEN executionMode 为 simulated 且包含 fixture/scenario identity
- AND不得被解释为真实硬件成功

### Requirement: REQ-STO-001 Per-volume host coordination

`StorageBudget` SHALL 估算单 Job 峰值；host-wide `HostStorageCoordinator` SHALL 按真实 volume identity 聚合所有 claim，而不是按目录字符串判断共享空间。

#### Scenario: AC-STO-001-01 同卷不同目录

- GIVEN 两个输出目录位于同一卷
- WHEN两个 Job 请求 heavy writer claim
- THEN它们被识别为同一共享资源

### Requirement: REQ-STO-002 Metadata and finalization headroom

Job/Session 创建时 SHALL 先取得有界 metadata/finalization headroom，专供 journal、checkpoint、错误/abandon/reconcile 审计和 manifest finalization。可选 Artifact SHALL NOT 侵占该逻辑额度；真实写入仍失败时 SHALL fail closed。

#### Scenario: AC-STO-002-01 低水位优先保状态

- GIVEN卷空间降到低水位
- WHEN可选 Artifact 仍在增长
- THEN系统先停止可选写入并 finalize 已完成分片/partial
- AND尽最大努力保存 terminal audit

### Requirement: REQ-STO-003 Heavy writer admission

MVP 在同一卷 SHALL 最多准入一个 heavy writer。有明确上限且总额度足够的 light writer MAY 并行；unknown/unbounded writer SHALL 串行并具有上限/中止策略。HiLog SHALL 使用 rolling quota。

#### Scenario: AC-STO-003-01 两设备同时大写入

- GIVEN设备 A 正在同卷写大 trace
- WHEN设备 B 请求同卷 GB 级 Flash/trace writer
- THEN第二个 Job 保持 `queued` 且 reason 为 `waitingForStorage`，直到 claim 可用或用户取消
- AND不同卷在其他资源允许时 MAY 并行

### Requirement: REQ-STO-004 Soft claims are not disk reservations

Coordinator SHALL 明确 claim 是 ArkDeck 内部准入记账，不是真实块预留。运行中 SHALL 复检 free space 并处理外部占用和 ENOSPC。Claim 更新 SHALL 按剩余未来增长计算，避免 double-count。

#### Scenario: AC-STO-004-01 外部进程耗尽磁盘

- GIVEN Job 已获 claim 但外部进程快速占满卷
- WHEN下一次复检或写入返回 ENOSPC
- THEN Job 进入明确失败/partial finalization
- AND不宣称 claim 保证了物理空间

### Requirement: REQ-STO-005 Lease and crash reconciliation

Artifact lease SHALL 在 success/failure/cancel/throw 后释放；terminal journal/finalization 前 SHALL 保留 metadata headroom。App 崩溃后 SHALL 根据 partial、已完成分片、当前卷身份和 free space 重新准入，不继承失效的内存 lease。卷重挂 SHALL NOT 静默改写到其他卷。

#### Scenario: AC-STO-005-01 外置卷重挂为不同身份

- GIVEN Session 原卷被拔出并出现相同路径但不同 volume identity
- WHEN reconcile
- THEN系统暂停并要求处理
- AND不向新卷静默续写

### Requirement: REQ-ART-005 Input images are referenced by default

GB 级输入镜像默认 SHALL 原地流式 hash 和引用，不自动复制进 Session。用户选择归档镜像时 SHALL 单独计算峰值预算。

#### Scenario: AC-ART-005-01 默认不复制镜像

- GIVEN用户选择一个大镜像用于 Flash
- WHEN普通 preflight 完成
- THEN Session 保存必要的受控引用、size 和 hash
- AND没有镜像副本占用

### Requirement: REQ-ART-006 Local-first retention and export

Artifact 默认 SHALL 本地保存，不自动上传。导出 SHALL 提示 UI Dump/Trace/hilog 可能包含文本、路径、标识和时序，支持设备标识脱敏、保留期、总配额和 pinned Session。

#### Scenario: AC-ART-006-01 诊断包默认排除设备 raw

- GIVEN用户导出 ArkDeck 诊断包
- WHEN未主动勾选设备数据
- THEN UI Dump/Trace/hilog raw 不在包内

#### Scenario: AC-ART-006-02 Retention 不删除 pinned Session

- GIVEN 本地产物达到总配额且同时存在过期普通 Session 与 pinned Session
- WHEN retention 清理运行
- THEN 先按声明策略删除普通 Session，pinned Session 保持不变
- AND 若仍无法回到安全余量则阻止新的重写入 Job 并提示用户，而不是越过 pin
