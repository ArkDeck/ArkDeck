# Real Hardware Support Matrix

> Status：first `observed` row(M0B,2026-07-18);no `partial`/`verified` rows  
> Rule：simulation、fake 和 plan-only 不得进入 verified hardware rows

本文件是人类可读视图，不是权威证据源。机器事实来自各 change `evidence/` 下符合
`contracts/hardware-evidence.schema.json` 的记录（由人类操作者产生，经维护者 PR review）；
表格文字本身不能让硬件验收通过。

## Required dimensions

每条证据至少记录：

- board/device model、chip/vendor；
- OpenHarmony build/API、user/root build；
- HDC client/server/daemon version 与 tool hash；
- transport；
- Provider/Profile/version；
- 人类操作者、执行前的物理目标确认、稳定 device identity 与 binding revision；
- UI Dump/Trace/Debug/Flash capability；
- prerequisite 和 recovery tool/path；
- evidence date、tester、artifact hash/controlled location；
- passed AC IDs、known limitations、expiry/revalidation trigger。
- 每个 passed realHardware AC 与其验证方法、最低证据等级。

## Matrix

| Evidence ID | Device / build | HDC / transport | Capability / Provider | AC coverage | Status | Date |
| --- | --- | --- | --- | --- | --- | --- |
| `EVD-M0B-DAYU200-20260718-001` | DAYU200(RK3568)/ OpenHarmony 7.0.0.34、API 26.0.0(operator 设备屏观察) | hdc 3.2.0d(client+server),binary sha256 `48395ba8…d260` / USB | discovery+authorization observation+raw capture+hidumper probe;Provider `none`;无 UI Dump/Trace/Debug/Flash capability 事实 | `HW-M0B-DAYU200-DISCOVERY-001` PASS、`HW-M0B-DAYU200-RAWCAPTURE-001` PASS、`HW-M0B-DAYU200-UIDUMP-PROBE-001` PASS、`HW-M0B-DAYU200-AUTH-001` PASS(r2 分支 B:无信任 UI 设备族;r1 as-written FAIL 保持在案,重评见 run.md Addendum) | observed | 2026-07-18 |

## Status rules

- `observed`：能连接或执行部分流程，不构成支持。
- `partial`：部分 required AC 通过。
- `verified`：该精确组合所有 required hardware AC 通过且 evidence 可复查。
- `expired`：固件、HDC、Provider 或验收标准变化，需要重验。
- `nonConformant`：明确无法满足适用 Core Requirement。

支持声明不得外推到未测试的相近型号、固件或工具版本。
`verified` 记录必须与人工确认的 plan、target、固件、transport、HDC 与 Provider 一致；事后补写表格或 evidence JSON 不能补发执行授权，也不能把旧 case 的通过结果解释成已修改 case 的证据。超过 `validUntil` 或验收标准变化后，记录回到 expired,需重验。
