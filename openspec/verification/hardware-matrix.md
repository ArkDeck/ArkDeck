# Real Hardware Support Matrix

> Status：empty / pending M0B  
> Rule：simulation、fake 和 plan-only 不得进入 verified hardware rows

本文件是人类可读视图，不是权威证据源。机器事实来自
`verification/hardware-evidence/*.json`，每条记录必须通过
`hardware-evidence.schema.json`、有效期和仓库外 verifier 的独立批准；表格文字本身不能让硬件验收通过。

## Required dimensions

每条证据至少记录：

- board/device model、chip/vendor；
- OpenHarmony build/API、user/root build；
- HDC client/server/daemon version 与 tool hash；
- transport；
- Provider/Profile/version；
- controlled-lab Task run ID、仓库外批准的 lab authorization ID、canonical plan hash、稳定 device identity 与 binding revision；
- UI Dump/Trace/Debug/Flash capability；
- prerequisite 和 recovery tool/path；
- evidence date、tester、artifact hash/controlled location；
- passed AC IDs、known limitations、expiry/revalidation trigger。
- 每个 passed realHardware AC 所绑定的平台 case manifest hash、Test ID、method、minimum evidence、hardware capability 与 canonical definition hash；Core/behavior case hash 包含 canonical Scenario block SHA，platform-local case hash 包含 exact expected result。

## Matrix

| Evidence ID | Device / build | HDC / transport | Capability / Provider | AC coverage | Status | Date |
| --- | --- | --- | --- | --- | --- | --- |
| — | 首批设备待确认 | — | — | — | notStarted | — |

## Status rules

- `observed`：能连接或执行部分流程，不构成支持。
- `partial`：部分 required AC 通过。
- `verified`：该精确组合所有 required hardware AC 通过且 evidence 可复查。
- `expired`：固件、HDC、Provider 或验收标准变化，需要重验。
- `nonConformant`：明确无法满足适用 Core Requirement。

支持声明不得外推到未测试的相近型号、固件或工具版本。
`verified` 记录必须机器关联到同一 owner-attested done run，并与 pre-dispatch authorization 中的 exact plan、target、固件、transport、HDC 与 Provider 完全一致；其 case binding 必须与当前平台 profile 固定的 conformance case manifest 逐项相等。事后补写表格或 evidence JSON 不能补发执行授权，也不能把旧 case 的通过结果解释成已修改 case 的证据。
发布/支持判定还必须由受保护 CI 注入 `ARKDECK_EVALUATION_TIME`；超过 `validUntil`、observedAt 晚于评估时刻或缺少该受保护时刻时，记录不能保持 verified。
