---
id: CHG-2026-063-arkforge-native-rockusb
revision: 1
status: proposed
class: integration
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# CHG-2026-063 — ArkForge 原生 RockUSB：完全替换 rkdeveloptool

> **本文件不构成批准。** 本 proposal 经维护者 review/merge 进 protected
> `main` 后，各 Task 方可开始实现 PR；merge 同时构成 AFD-0001 修订的批准。

## 目标

`arkforged` 原生实现 DAYU200 刷机所需的 RockUSB 协议子集，彻底退役 vendored
`rkdeveloptool`。终态：写入、读回、复位、枚举全部由 arkforged 自己的 typed
端口完成；ArkDeck 不再绑定 vendor 工具路径；信任面收敛为 arkforged 自身的
签名与摘要。

## 为什么现在可行（2026-08-18 实测盘点）

- **工具面已收敛到 5 条语义指令**：`ld`/`ppt`/`wlx`/`rl`/`rd`
  （`crates/arkforge-provider/src/rockchip_execute.rs` 的 `RockUsbCommand`，
  argv 只在一处生成）。
- **替换缝现成**：全部调用经过唯一的 `FixedToolPort` trait
  （`crates/arkforged/src/dispatch.rs`）。
- **寻址知识已自持**：写前强制读设备自身分区表并核对 offset
  （`write_partition` guard #2，`session.observed_table()`）——原生
  WRITE_LBA 的 name→LBA 解析数据已在 daemon 手里。
- **绿基线存在**：`job-a4b7d539571082b1958ebaaf2c14bd2c` 已用 vendor 工具
  跑通全绿 `succeeded`，A/B 互证有对照物。

## 决策记录：AFD-0001 修订

现行 AFD-0001：arkforge-transport 无三方依赖、无 FFI（枚举走只读 `ioreg`）。
RockUSB 需要 bulk 传输，二选一：

1. **原生 IOKit FFI（IOUSBHost/IOUSBLib user client）— 本 proposal 采纳**。
   保持零三方依赖；FFI 面收敛在一个新 crate（`arkforge-usb`）内，其余代码
   不见 unsafe。与仓库"自持一切、最小信任面"的性格一致。
2. rusb/libusb：引入三方 C 依赖 + 其构建链。否决：审计面更大，且 macOS 上
   libusb 与 IOKit 的独占声明常有摩擦。

merge 本 proposal 即批准该修订（仅对 `arkforge-usb` crate 放开 FFI）。

## 范围边界（明确不做）

- **只覆盖 Loader 模式**（PID 0x350a，"USB download gadget"）。Maskrom
  救砖（`db`/`ul`/`gpt`）一直被刻意排除在授权面外，替换后依旧属于外部救援
  工具，不进 arkforged。
- 不改变授权模型：StepPermit / managed-control / capability 代数照旧。
- 不动 hdc 半边：HDC 传输仍归 ArkDeck（architecture.md 9.2）。

## 治理含义（by design 的代价）

toolchain identity 是 maturity key 的组成部分。换工具 = 新组合 = 回到
`hardwareGated`，必须以新的验收 campaign（**AFA-AC-7**）在真机把
(rockchip, dayu200, native-toolchain, host, …) 打到 `productionVerified`。
过渡期双端口并存，vendor 工具降为 fallback，campaign 通过后退役。

## 成功判据

新 toolchain 身份下，`flash.dayu200` 全绿 `succeeded`（九分区写入、逐分区
读回、复位、首启等待、postflight 身份+构建验证），全程无 vendor 工具进程
spawn；打包产物不再携带 `rkdeveloptool`；`ARKDECK_RKDEVELOPTOOL_PATH`
从 lane 组合要素中退场。
