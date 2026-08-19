# Real Hardware Support Matrix

> Status：现行 `verified` 行 ×2（AFA 2026-08-18 authority 分界首刷、NRU 2026-08-19
> 原生换轨复验）;RF-002 的 verified 记录随执行归属/Provider 变更转 `expired`
> （其组合已被 chg-2026-059/063 替代）;两条 `observed` 行在案  
> Rule：simulation、fake 和 plan-only 不得进入 verified hardware rows

本文件是人类可读视图，不是权威证据源。机器事实来自各 change `evidence/` 下符合
`contracts/hardware-evidence.schema.json` 的记录（由 human 或 Agent executor
产生；Agent authority 按实际 effect 分别记录 default read-only policy、
RuntimeCapability 或 standing authorization，并经维护者 PR review）；
表格文字本身不能让硬件验收通过。

## Required dimensions

每条证据至少记录：

- board/device model、chip/vendor；
- OpenHarmony build/API、user/root build；
- HDC client/server/daemon version 与 tool hash；
- transport；
- Provider/Profile/version；
- executor（human 或 agent）、实际 effect/typed step kinds 与 effect-matched
  authority reference、执行前的目标确认
  （人工物理确认或机器身份读回）、稳定 device identity 与 binding revision；
- UI Dump/Trace/Debug/Flash capability；
- prerequisite 和 recovery tool/path；
- evidence date、tester、artifact hash/controlled location；
- passed AC IDs、known limitations、expiry/revalidation trigger。
- 每个 passed realHardware AC 与其验证方法、最低证据等级。

## Matrix

| Evidence ID | Device / build | HDC / transport | Capability / Provider | AC coverage | Status | Date |
| --- | --- | --- | --- | --- | --- | --- |
| `EVD-M0B-DAYU200-20260718-001` | DAYU200(RK3568)/ OpenHarmony 7.0.0.34、API 26.0.0(operator 设备屏观察) | hdc 3.2.0d(client+server),binary sha256 `48395ba8…d260` / USB | discovery+authorization observation+raw capture+hidumper probe;Provider `none`;无 UI Dump/Trace/Debug/Flash capability 事实 | `HW-M0B-DAYU200-DISCOVERY-001` PASS、`HW-M0B-DAYU200-RAWCAPTURE-001` PASS、`HW-M0B-DAYU200-UIDUMP-PROBE-001` PASS、`HW-M0B-DAYU200-AUTH-001` PASS(r2 分支 B:无信任 UI 设备族;r1 as-written FAIL 保持在案,重评见 run.md Addendum) | observed | 2026-07-18 |
| `EVD-RF001-DAYU200-20260721-001` | DAYU200(RK3568)/ pinned 参考镜像 7.0.0.33(CHG-2026-003 archive `fc7637f3…5280`) | rkdeveloptool 1.32,binary sha256 `038a8a0e…3611` / USB RockUSB(Loader `0x2207:0x350a`) | Flash 正向烧写九个 PD-002 mapped 分区(Loader 态 `wlx` over 既有分区表);Provider = Rockchip RockUSB(人工 crib `flash-forward.sh`;Swift `RockchipRockUSBFlashProvider` = TASK-RF-002);恢复路径 = CHG-2026-016 Loader `wlx` | `RF-REALFLASH-001` PASS;`AC-FLASH-003-01`/`AC-FLASH-015-01`/`AC-FLASH-015-02` 真机命令面/契约/人工执行边界面 PASS(完整 Flash Provider AC 已由 `EVD-RF002-DAYU200-20260721-001` 验收) | observed | 2026-07-21 |
| `EVD-RF002-DAYU200-20260721-001` | DAYU200(RK3568)/ pinned 参考镜像 7.0.0.33(CHG-2026-003 archive `fc7637f3…5280`) | rkdeveloptool 1.32,binary sha256 `038a8a0e…3611` / USB RockUSB(Loader `0x2207:0x350a`);hdc 3.2.0d(`48395ba8…d260`)仅 postcheck 只读 | `arkdeck flash` 产品路径端到端(validate → exact plan → 人工确认 gate → 人工 handoff 九分区 `wlx` → `rd` → postflight 语义判定 succeeded/confirmed);Provider = `RockchipRockUSBFlashProvider`@1.0.0 / Profile `arkdeck.rockchip-rockusb-flash-profile.dayu200`@1.0.0(main `32908a9`);operator = lvye,恢复路径 = CHG-2026-016 Loader `wlx`(未触发) | `RF-ACCEPT`(realHardware)PASS;`AC-FLASH-001/002/004/007/008/012/013/015-01/015-02` contract 全绿(#236)+ 真机面 PASS(evidence `runs/TASK-RF-002/acceptance-2026-07-21.md`;非 TTY execute policyBlocked 实测、mode-gate 先行、postflight fail-closed 双向实测);Agent destructive dispatch 0 | expired（2026-08-19：执行归属移交 arkforged(chg-2026-059)且 Provider/工具组合退役(chg-2026-063),该精确组合不再存在;后继 verified 行见下两条） | 2026-07-21 |
| `EVD-AFA-DAYU200-20260818-001` | DAYU200(RK3568)/ 刷入 bundle `OpenHarmony-7.0.0.37`(sha256 `4fd35765…c674`) | hdc 3.2.0d(`05b2bf7a…8f83`)仅模式切换/观察/postflight;USB RockUSB(Loader `0x2207:0x350a`);执行 daemon = arkforged fixed-tool era(`aa7fe808…0085`,绑定捆绑 rkdeveloptool 1.32 `231a05ef…c79e`) | `flash.dayu200` 端到端(chg-2026-059 authority 分界:ArkDeck 物化计划+签发单次 StepPermit+管控回执,arkforged 执行九分区写入/回读/复位;postflight `exact-published-profile-and-bound-hdc`);executor=agent(runtime capability `…3E578…-G14` use 1),job `job-a4b7d539…` `succeeded` | `AFA-AC-6`/`AFA-AC-7`/`AFA-AC-8` PASS(evidence `openspec/changes/chg-2026-059-arkdeck-arkforge-authority/evidence/runs/EVD-AFA-DAYU200-20260818-001.json`;ArkForge 仓 AD-033) | verified | 2026-08-18 |
| `EVD-NRU-DAYU200-20260819-001` | DAYU200(RK3568)/ 刷入 bundle `OpenHarmony-7.0.0.37`(同上) | hdc 3.2.0d(同上);USB RockUSB;执行 daemon = arkforged **原生 RockUSB**(`f3dfc624…66d9`,晚于 ArkForge `c049a11` 移除 vendor 运行时,二进制零 vendor 字符串,回执自证摘要) | `flash.dayu200` 端到端同上,vendor 全面退役后的终局回归;executor=human(FlashWorkspace UI,runtime capability `…C67A6…-G1` use 1),job `job-b00e006a…` `succeeded`;readback 证据与 08-18 逐分区同形 | `NRU-AC-10` PASS(evidence `openspec/changes/chg-2026-063-arkforge-native-rockusb/evidence/runs/TASK-NRU-004/EVD-NRU-DAYU200-20260819-001.json`;ArkForge 仓 AD-033) | verified | 2026-08-19 |

## Status rules

- `observed`：能连接或执行部分流程，不构成支持。
- `partial`：部分 required AC 通过。
- `verified`：该精确组合所有 required hardware AC 通过且 evidence 可复查。
- `expired`：固件、HDC、Provider 或验收标准变化，需要重验。
- `nonConformant`：明确无法满足适用 Core Requirement。

支持声明不得外推到未测试的相近型号、固件或工具版本。
`verified` 记录必须与适用的 admission authority、plan、target、固件、transport、HDC 与 Provider 一致；事后补写表格或 evidence JSON 不能补发执行授权，也不能把旧 case 的通过结果解释成已修改 case 的证据。超过 `validUntil` 或验收标准变化后，记录回到 expired,需重验。
