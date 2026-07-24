# CHG-2026-032 Spec impact

> implementation-only change：无 behavior/contract delta，本文件替代 no-op spec delta。

## Current specs / contracts

**零影响。**本 change 只改 `openspec/planning/agent-failure-patterns.md` 一个文件的
引用形式与一条编辑约定。不触碰 `openspec/specs/**`、`openspec/contracts/**`、
`openspec/integrations/**`、platform profile、schema 或 Core baseline。

## Capability / platform

- 零 capability 变化；零 platform port 变化；零 conformance/support 状态变化。
- Windows/Linux 未来端口不受影响：手册是跨平台可复用的过程文档，本 change 不改变
  其任何 normative 关系（它本就 non-normative）。

## Authority

手册是**非权威导航索引**（CHG-2026-029 design §1 确立）。本 change 不改变该定位：

- 不新增/删除 `AF-NNN` ID，不改 taxonomy 归属与两轴划分；
- 不改八字段契约、`Automation status` 取值域或首屏的 non-normative/authority/
  conflict/privacy/archive 五项声明的**语义**（TASK-HLD-002 只在其中**增加**一条
  仅约束本手册后续编辑的引用约定）；
- 不改任何案例的事实内容，只改引用形式。

## Evidence / privacy

- evidence class 全部为 `documentReview`；零设备、零硬件、零 dispatch。
- 只引用仓内已脱敏记录与 Git OID；零 secret、零设备标识、零用户绝对路径。

## Archive interaction

本 change 的目的正是消除手册与 change 归档之间的耦合。完成后，被引用的活跃 change
各自归档时不再需要同步改写手册——这也使本 change 自身的归档不产生新的耦合
（本 change 目录不被手册引用）。
