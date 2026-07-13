# Legacy Script Analysis

> Source：`dump.rar`、`trace.rar`  
> Role：research input, not normative specification

## Dump recipes extracted from attachments

| Recipe | Arguments | Note |
| --- | --- | --- |
| nodeSummary | `-w <windowId> -default` | 脚本名语义需由固件 fixture 确认 |
| elementTree | `-w <windowId> -element -c` | 当前 element pipeline |
| fullDefaultTree | `-w <windowId> -default -all` | 完整默认树 |
| componentDetail | `-w <windowId> -element -lastpage <compId>` | 指定组件详情 |

窗口发现样本：

```text
hidumper -s WindowManagerService -a '-a'
```

`-render -c` 只作为能力探测后的 legacy fallback。`persist.ace.debug.enabled` 是 Debug Policy，不是额外 Recipe。

## Trace attachment profile

Tag 样本：

```text
sched freq ace app binder disk ohos graphic sync workq ability
```

Buffer 样本：`327680`；duration 样本：15 秒。单位和语义必须由当前设备 help/Adapter 确认。

参数样本：

```text
persist.ace.trace.syntax.enabled=true
persist.ace.trace.layout.enabled=true
persist.ace.trace.build.enabled=true
persist.ace.trace.measure.debug.enabled=true
persist.ace.trace.sync.debug.enabled=true
persist.ace.debug.enabled=1
persist.ace.performance.monitor.enabled=true
persist.sys.graphic.openDebugTrace=1
persist.rosen.animationtrace.enabled=1
```

这些值是附件兼容 Profile 输入，不代表所有固件支持。

## Behaviors that must not be inherited

- 默认单设备且不绑定 `hdc -t <connectKey>`；
- 拼接 window/component/path 到 shell；
- 全局递归查找/删除 `/data`；
- stdout 和 sidecar 同名覆盖；
- 原地 `sed` 修改 raw trace；
- 固定远端文件名；
- 永久修改参数而不保存/恢复；
- 忽略权限、能力、语义错误、空间、断线、超时和完整性；
- 分钟级/区域相关时间戳。

规范化行为已迁移到 UI Dump、Trace、Device、Workflow 和 Artifact specs。
