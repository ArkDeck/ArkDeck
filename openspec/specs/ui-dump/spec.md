# ArkUI UI Dump Specification

> Version：1.0.0  
> Status：in baseline CORE-1.0.0（ratification 状态见 `openspec/baselines/CORE-1.0.0.yaml`）  
> MVP：yes  
> Applicability：all platforms

## Purpose

定义基于 HiDumper 的 ArkUI 窗口、组件树和组件详情采集。Fault/Crash Artifact 与 System Diagnostic Snapshot 不属于本规格。

## Requirements

### Requirement: REQ-DUMP-001 Explicit UI Dump scope

产品和 UI SHALL 使用“ArkUI UI Dump”名称，并 SHALL 明确 Fault/Crash Artifact 与 System Diagnostic Snapshot 首版不支持。引用 FaultLoggerd 文档 SHALL NOT 被解释为已实现。

#### Scenario: AC-DUMP-001-01 页面范围可见

- GIVEN用户进入 UI Dump 页面
- WHEN查看功能范围
- THEN页面只提供 ArkUI Recipe
- AND另外两类 Dump 显示非 MVP，不出现可执行入口

### Requirement: REQ-DUMP-002 Window inventory with safe fallback

系统 SHALL 通过 WindowManagerService 获取窗口清单并解析。解析失败时 SHALL 保留 raw output，并 MAY 允许用户输入经过严格验证的 window ID；自由 shell 文本被禁止。

#### Scenario: AC-DUMP-002-01 未知窗口输出

- GIVEN窗口清单输出不属于支持的 parser family
- WHEN刷新窗口
- THEN raw output 可查看
- AND只有格式合法的手工 ID 可继续

### Requirement: REQ-DUMP-003 Four canonical recipes

MVP SHALL 提供以下 typed Recipe；legacy `-render -c` 只有能力 probe 明确支持时 MAY 出现：

| Recipe ID | HiDumper arguments |
| --- | --- |
| `nodeSummary` | `-w <windowId> -default` |
| `elementTree` | `-w <windowId> -element -c` |
| `fullDefaultTree` | `-w <windowId> -default -all` |
| `componentDetail` | `-w <windowId> -element -lastpage <componentId>` |

表中参数为候选映射；实际 HiDumper 调用包装（例如是否需要 `-s WindowManagerService -a` 前缀）SHALL 在 M0B 真机验证后经 integration change 固定，验证前不得据此宣称兼容性。

#### Scenario: AC-DUMP-003-01 Component ID 校验

- GIVEN用户选择 componentDetail
- WHEN component ID 缺失或非法
- THEN preflight 阻断
- AND HiDumper 不启动

### Requirement: REQ-DUMP-004 Explicit debug parameter policy

UI Dump SHALL 提供：不改变 Debug 参数、临时开启并在可逆时恢复、用户二次确认后保持开启三种策略。原值缺失/不可读时 SHALL NOT 承诺自动恢复。

#### Scenario: AC-DUMP-004-01 临时策略恢复失败

- GIVEN参数原值可读写且 capture 后恢复失败
- WHEN Job finalization
- THEN Artifact 仍保留
- AND Job/设备显示 needsAttention 与恢复错误

### Requirement: REQ-DUMP-005 Separate raw origins

stdout 和每个 remote sidecar SHALL 保存为独立 raw Artifact，不得使用同一目标覆盖。只有 Recipe 明确声明且所有输入验证成功时 MAY 生成 merged derived Artifact。

#### Scenario: AC-DUMP-005-01 Sidecar 不覆盖 stdout

- GIVEN一次 capture 同时产生 stdout 和 sidecar
- WHEN接收完成
- THEN manifest 至少有两个不同 origin/path/hash 的 raw Artifact

### Requirement: REQ-DUMP-006 Owned cleanup only

ArkDeck SHALL NOT 全局搜索或递归删除设备 `/data` 中的 dump。只 MAY 删除能证明属于当前 Job 的远端路径；无法证明归属时 SHALL 保留并提示。

#### Scenario: AC-DUMP-006-01 发现其他会话文件

- GIVEN远端存在不属于当前 Job 的 `arkui.dump`
- WHEN cleanup
- THEN该文件不被删除

### Requirement: REQ-DUMP-007 Stale and ambiguous sidecars are rejected

对只能生成固定文件名的旧固件，Adapter SHALL 比较 capture 前后的 path/mtime/size 或等价证据。陈旧、多个或无法归属的结果 SHALL 被标为 ambiguous，不能静默当作当前产物。

#### Scenario: AC-DUMP-007-01 陈旧 sidecar

- GIVEN capture 前后固定文件没有可证明的新变化
- WHEN接收阶段
- THEN该文件不作为成功 Artifact
- AND raw inventory evidence 被保留

### Requirement: REQ-DUMP-008 Sensitive data handling

ArkUI UI Dump SHALL 按可能包含页面文本、包名、组件树和标识符的敏感数据处理，遵守本地优先、显式导出和保留策略。

#### Scenario: AC-DUMP-008-01 诊断导出默认排除

- GIVEN用户导出 App 诊断包
- WHEN没有主动选择 UI Dump raw
- THEN包内不包含页面 Dump 内容
