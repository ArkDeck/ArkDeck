# r3 Manual Boundary Inventory

> Change:CHG-2026-025-ai-native-unattended-device-ops@r3
> Audited base:`d42c002609177e47ef95320cb5bdc0a42f0b510e`
> Remote check:`refs/heads/main` resolved to the same OID on 2026-07-28
> Classification:proposal input;no device/HDC/tool dispatch

## Finding

治理层已经允许 Agent 在 ready task 内无人值守执行 E0、持 per-device typed
capability 执行 E1、持 standing authorization 执行 E2。当前主要缺口不是继续放宽
governance，而是把已有 typed contract 接到 product-owned executor，并停止把 E0/E1
工具硬编码为 human-only。

## Current manual seams

| Surface | Current evidence | Current effect | r3 disposition |
| --- | --- | --- | --- |
| M0B/device/tool/HiDumper probe | `scripts/m0b_capture/capture.py:3-36` 声明 `Human-operated`，`:426` 写 `controlledHumanCapture` | E0 | allowlist/parser/redaction 迁入 trusted E0 executor；历史 harness 只作 fixture/provenance |
| Trace probe/minimal capture | `scripts/trace_capture/capture.py:3-38` 要维护者执行，`:470`/`:866` 固定 human evidence | probe=E0；owned remote capture/cleanup=E1 | product Trace executor 自动 probe→capture→receive→cleanup/restore |
| ArkUI UI Dump + fixture | `scripts/ud_capture/capture.py:3-23` 为 `Human-operated only`，`:1183` 固定 human evidence | stdout Recipe=E0；sidecar/parameter/HAP fixture=E1 | product UI Dump executor；HAP fixture 经 E1 deployment |
| E0 identity readback | `scripts/e0_readback/capture.py:1-31` 已是封闭只读，但 `:439` 仍假设 device-window operator | E0 | 复用为 trusted resume/readback port，不再需要人类代跑 |
| Rockchip Flash | `ArkDeckCLIMain.swift:104-136` 已有 `--authorization-id` → product executor；human fallback 仍存在 | E2 | r2 路径保留并完成 AIN-004；不是 r3 重写目标 |
| Generic Agent API | `ArkDeckCLIMain.swift:23-29` 只有 `flash`/`update-feed`，`:534-538` 的 AI surface 仅描述 Flash | all | 新增统一 submit/status/cancel/reconcile/result contract |
| HDC typed lowering | `HDCDeviceCommand.swift:29-47` 当前只 lower `rebootDevice` | E1 subset | 覆盖 registry 中的 capture/package/app/file/forward operations，仍无 raw argv surface |
| Typed step inventory | `workflow-step-registry.yaml:20-56` 已登记 capture/send/receive/parameter/package/app/forward/log/reboot/flash | E0/E1/E2 | 作为统一 effect/admission 真值；只为 `.so` publish 增加必要的 closed step/profile |

## Human action allowlist

以下动作保留人为执行或判断，并必须产生 `humanActionRequired`：

1. 物理插拔、按键/跳线/断电、设备解锁、首次 HDC trust prompt；
2. OS picker、Sandbox/entitlement、driver/helper、udev/group/ACL、Keychain、签名/
   公证凭据和其他 Agent 无法合法取得的外部配置；
3. TCP/UART 断线、多个 USB 候选、证据不足时的 identity diff 确认；
4. external/unknown HDC lifecycle、持久 Debug/buffer 设置、HAP 数据丢失操作等 impact
   approval；
5. outcomeUnknown、不可自动恢复、需要物理 recovery 时的风险处置；
6. D1/D2 review、E1 capability 接受、E2 standing authorization 创建/修改/吊销。

## Automation target

除上述白名单外，目标路径全部为 Agent-owned：

```text
observe/bind
  → probe capabilities
  → deploy HAP or profiled .so when requested
  → start/restart application
  → collect bounded HiLog + ArkUI UI Dump + Trace
  → publish immutable raw and reproducible derived Artifacts
  → analyze/correlate
  → submit the next typed operation through fresh admission
  → finalize evidence
```

任何阶段缺少 binding、tool/server fact、E1 capability、E2 authorization、storage、
parser family 或 recovery certainty时 fail closed，并返回精确 blocker；不得回退为让
维护者复制粘贴命令。
