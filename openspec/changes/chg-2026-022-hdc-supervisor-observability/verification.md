# CHG-2026-022 Verification Plan

> Status:planned
> Change:CHG-2026-022-hdc-supervisor-observability@r2
> Core baseline:CORE-2.1.0(零 Core 变更;canonical Core AC 零认领)

本 change 是纯可观察性 change:不认领任何 canonical Core AC,验收面全部为
change-local contract(见 acceptance-cases.yaml)。任何 lifecycle/授权门语义
diff、任何以分支常量冒充仪表计数、任何生产路径 fixture 注入,整体 fail。

## Change-local

| Evidence ID | Task | Method | Expected result |
| --- | --- | --- | --- |
| OBS-COUNTER-001 | OBS-001 | contract(成功 spawn 变异实验) | 唯一 identity-bound spawn hook 只在 `posix_spawn` 成功后计数；origin 由 opaque supervisor permit + typed argv family 判定，caller 无 enum/string/flag/monitor 写入口；移除 permit 的 fake-process mutation 经同一 hook 实际 spawn 后 automatic lifecycle/subserver 分别 >0，无 mutation 恒 0；confirmed/managed dispatch 不混入，presentation 与快照一致 |
| OBS-OWNERSHIP-001 | OBS-001 | contract(四证据 + provenance 矩阵) | pre-existing receipt + 零 automatic lifecycle 计数 + observation-minted generation + 无 active/unreconciled managed provenance 四证据齐 → `.external` 并暴露依据；任一缺失 → `.unknown` 或保留实时有效 `.arkDeckManaged`；既有 managed 未 reconcile/retire 不得直接 external；external/unknown lifecycle 授权门等价 |
| OBS-ENDPOINT-001 | OBS-001 | contract | presentation 暴露 endpoint source(explicit/inherited/default)与 child-env 注入清单;父进程 env 零修改既有断言保持 |
| OBS-FANOUT-001 | OBS-001 | integration-backed contract | 输入必须来自先行 approved/done integration change 的参数化 zero-to-many 只读设备 snapshot family；生产 composition 的 appeared/unchanged/disappeared 差分进入 fan-out 与有界 presentation buffer；empty 与 unknown 不混淆；无未注册设备命令；纯测试注入不能单独 PASS |
| OBS-APPFACE-001 | OBS-002 | contract(signed XCUITest) | 新字段(计数/endpoint source/ownership 依据/设备事件)以 static-text 可访问 id 呈现、值形态正确;生产路径零 fixture |

## Gate

本 change `verified` 前提:两 task done(各有 merged 实现 + 独立 done PR +
evidence);五 change-local AC 有可复查证据;M1-006 语义不变量(零自动 lifecycle、
endpoint 子进程隔离、registry fail-closed、external/unknown 门等价)经既有 + 新增
测试零回归背书。本 change 不构成 TASK-M0B-002 的观察结论——真机观察仍须其新
readiness + 设备窗口 + 维护者执行。

r1 readiness 后的 draft prototype #265 与其 host-only PASS 输出已被 review
invalidate，不得引用为上述 AC 的通过证据。r2 本身是 plan-only remediation，
不产生 implementation/contract/hardware evidence。
