# CHG-2026-022 Verification Plan

> Status:planned
> Change:CHG-2026-022-hdc-supervisor-observability@r1
> Core baseline:CORE-2.1.0(零 Core 变更;canonical Core AC 零认领)

本 change 是纯可观察性 change:不认领任何 canonical Core AC,验收面全部为
change-local contract(见 acceptance-cases.yaml)。任何 lifecycle/授权门语义
diff、任何以分支常量冒充仪表计数、任何生产路径 fixture 注入,整体 fail。

## Change-local

| Evidence ID | Task | Method | Expected result |
| --- | --- | --- | --- |
| OBS-COUNTER-001 | OBS-001 | contract(变异实验) | 自动 lifecycle/subserver dispatch 计数器在真实调用点递增:注入一次自动 dispatch → 计数 >0(红/绿对照在案);无注入 → 快照恒 0;presentation 透出与快照一致 |
| OBS-OWNERSHIP-001 | OBS-001 | contract(证据矩阵) | pre-existing receipt + 零 lifecycle 计数 + 观察铸造 generation 三证据齐 → `.external` 并暴露判定依据;任一缺失 → `.unknown`;门语义零 diff(external/unknown 授权路径等价性测试) |
| OBS-ENDPOINT-001 | OBS-001 | contract | presentation 暴露 endpoint source(explicit/inherited/default)与 child-env 注入清单;父进程 env 零修改既有断言保持 |
| OBS-FANOUT-001 | OBS-001 | contract | 设备快照差分产生 appeared/disappeared 事件进 fan-out 与有界缓冲;零新增设备命令(只读 probe 面复用断言) |
| OBS-APPFACE-001 | OBS-002 | contract(signed XCUITest) | 新字段(计数/endpoint source/ownership 依据/设备事件)以 static-text 可访问 id 呈现、值形态正确;生产路径零 fixture |

## Gate

本 change `verified` 前提:两 task done(各有 merged 实现 + 独立 done PR +
evidence);五 change-local AC 有可复查证据;M1-006 语义不变量(零自动 lifecycle、
endpoint 子进程隔离、registry fail-closed、external/unknown 门等价)经既有 + 新增
测试零回归背书。本 change 不构成 TASK-M0B-002 的观察结论——真机观察仍须其新
readiness + 设备窗口 + 维护者执行。
