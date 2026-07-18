# TASK-FP-001 run — DAYU200 烧写协议事实清单(doc-only)

- Change:CHG-2026-011-dayu200-flash-protocol-research / Task:TASK-FP-001
- 执行日期:2026-07-18;执行形态:纯文档研究(web 检索 S2/S3 来源 + 引用
  仓库内已合入 M0B/CHG-2026-010 evidence);**零设备操作、零工具执行、零二进制
  下载**(doc-only gate 自证:本 PR 仅新增两个 markdown 文件;网络仅用于
  文档检索)
- 交付物:`../../flash-protocol-facts.md`(五节齐备)

## 二值结论(per acceptance-cases.yaml,方法=document review)

| Test ID | 结论 | 依据 |
| --- | --- | --- |
| TEST-PROTOCOL-DAYU200-CHANNELS-001 | PASS | 五节齐备(§1 通道枚举含 RockUSB MaskRom/Loader、flashd/hdc、fastboot/sideload 及适用态;§2 进入方式+USB 识别 VID/PID 文档值,TCP/UART 显式 out of scope;§3 工具映射含 macOS 可用性与版本约束;§4 只读观察草案;§5 S2/S3 分级引用);逐条 S2/S3 标注;凡仅 S3 支撑或源码推断的结论(DAYU200 按键序列、RK3568 PID 0x350a、flashd 态 PID 沿用 0x0018、`hdc target boot flashd` 链式推断、U-Boot rockusb 可用性、flashd 端到端 DAYU200 可用性)均标【待真机确证】;首段显式「不构成兼容性/支持声明、不解除 gap、非执行授权」 |
| TEST-PROTOCOL-DAYU200-OBSERVATION-PLAN-001 | PASS | §4.1 第一阶段候选逐条标【只读】并注前提(host-only/设备在线/须已处特定态);§4.2 将全部模式切换/写设备候选(target boot、write_updater/reboot、update/flash/erase/format/sideload、mount/smode/tmode、rkdeveloptool db/ul/wl/wlx/gpt/prm/ef/rd/cs、物理按键进态)逐条标【第二阶段·写设备·RECOVERY 先行】;§4 首段声明草案执行属后续独立 change、本文档不构成执行授权 |

## 偏差 / 遗留

- 关键缺席结论:DAYU200 的官方烧写文档(OH quickstart + HiHope)只覆盖
  Windows RockUSB 路径(RKDevTool/DriverAssitant),flashd 端到端流程与任何
  macOS 烧写路径均无官方文档——这是 GAP-DAYU200-FLASH-PROTOCOL 保持 open 的
  核心事实,供 DEC-002 决策输入。
- RK356x PID 未进 Rockchip 官方 wiki 的 per-SoC 表(止步 RK3399);`2207:350a`
  仅 Radxa RK3568 板文档实录,DAYU200 上呈现形态待真机确证。
- flashd 需 root 设备且处 updater 模式(hdc 指导);M0B 实测仅覆盖正常系统
  只读白名单,对 flashd 模式零观察——本 change 不改变该状态。
- `GAP-DAYU200-FLASH-PROTOCOL` 保持 unknown;DEC-002 保持 open。

## Boundary

doc-only;不构成执行授权、支持声明或兼容性结论;不触碰 matrix/specs/
contracts;§4 观察草案的执行(含只读条目)须独立立项/approve;写设备候选
受 RECOVERY 先行硬序约束(演练 change 须引用 CHG-2026-010 §6 检查单作前置
gate);`done` 翻转由独立状态 PR 执行。
