---
id: CHG-2026-066-flash-review-single-truth
revision: 1
status: proposed
class: integration
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# CHG-2026-066 — 刷机评审单一事实源：ArkDeck 退出设备地址与伪造计划

> **本文件不构成批准。** 本 proposal 经维护者 review/merge 进 protected
> `main` 后，各 Task 方可开始实现 PR。

## 背景：两处结构性残留（2026-08-19 逐点实测）

CHG-2026-059 把执行归属交给 `arkforged` 时写明「ArkDeck 不再拥有的：
`wlx`/`rl` 的 argv、**扇区地址**、读窗语义、写进度解析」。CHG-2026-063/065
清完了执行与发行面，但两处**声明面**残留还站在旧世界里：

1. **两份分区表。** `RockchipFlashProfile.RockchipMappedPartition` 仍钉着
   FA-001 的九个 `offsetSectors`，字段注释仍称「consumed by the native typed
   write plan」。实测：该字段在全部 Sources 里的唯一读点是 profile 自己
   `init` 里的「按 offset 升序」自检（`RockchipFlashProfile.swift:136`）——
   不进请求、不进展示、不与归档 `parameter.txt` 解析出的 declared 表比对、
   更到不了设备。真正的写寻址在 `arkforged`：它写前实测设备自身分区表并与
   自己的 DeviceProfile 三方比对。ArkDeck 这份地址既是死数据，又与已定边界
   直接矛盾；两表若漂移完全静默。
2. **两个计划模型。** Execute 评审展示的是
   `RockchipRockUSBFlashProvider.makePlan` 现场伪造的九步
   `rk-<nonce>-wlx-N-<partition>` 计划——step id 带 `wlx`、argument 带
   `providerOperationId: "rockusb.wl-write"`（vendor 已退役的词汇）、附带
   provider 自算的 `planDigestSHA256`/`stepSetDigestSHA256`。实测运行时的
   真相是三个别的摘要：engine 物化目录计划的摘要（进 job record 与
   RuntimeCapability 的 `exactPlanDigest`，execute 时复物化比对）、目录
   stepSet 摘要（`stepSetDigest(descriptor:)`，即 admissionEvidence 里的
   `c1ab01f8…`）、以及 lane 侧 `arkforged` 自己的计划摘要（permit 锚）。
   **评审屏上的两个摘要与其中任何一个都对不上**；
   `FlashApplicationFacade.swift` 的注释「Execute review must materialize
   the same canonical plan used by the protected campaign path」已不成立。
   同文件里 provider 的 `assessOutcome`/`RockchipFlashOutcomeAssessment`
   与 `RockchipFlashPlanDocument` 均为零消费方死代码。

## 目标

**用户在评审屏看到的每一个事实，都必须是运行时真正使用的那一个。**

1. `RockchipMappedPartition` 删除 `offsetSectors`（字段、九个钉值、升序
   自检、过时注释）。mappedPartitions 的语义收敛为**覆写范围声明**：
   分区名 + 镜像成员绑定 + 评审展示顺序——不是设备地址，不是写序权威
   （那是 arkforged 对着设备自身的表定的）。请求体的 `partitionPlan`
   输入保留，含义按此改写：调用方对覆写范围的显式确认回声，admission
   照旧逐一比对钉定名单。
2. 删除 `RockchipFlashPlan`、`makePlan`、九步 WorkflowStep 伪造、
   `rk-*-wlx-*` id、`rockusb.wl-write` 词汇、provider 自算摘要，及
   零消费方的 `assessOutcome`/`RockchipFlashPlanDocument`；
   `RockchipRockUSBFlashProvider` 类型随之解散（幸存的小类型——
   prerequisite/probe/mode/verification level——迁至
   `RockchipFlashReviewTypes.swift`）。
3. 评审展示重建为三种真事实：
   - **步骤列表来自 Catalog**：`flash.dayu200` descriptor 的 step 序列，
     经与 engine 相同的输入筛选（engine 的 `stepIsRequested`/
     `stepSetDigest` 提升为 package 可见并复用，不重写第二份）；
   - **stepSetDigestSHA256 就是 engine 钉进 RuntimeCapability 的那个值**
     （用户可拿它与 job record/admissionEvidence 逐字比对）；
   - **plan digest 如实缺席**：它在提交时由 engine 物化、落 job record；
     评审屏标注「提交时物化」，不再展示一个假值。
   分区/镜像/数据影响半边照旧来自 profile 与归档 introspection（本就真）。

## 不变量与边界

- **零 Catalog delta、零请求 schema delta**：`partitionPlan` 输入的线上
  形状与 admission 校验不变，改的是文档化含义。
- 归档 introspection 的 `RockchipDeclaredPartition.offsetSectors` **保留**
  ——那是归档自己 `parameter.txt` 的事实，随 Artifact lease 记录，与设备
  地址无关。
- `manual_ui_flash` 驱动器依赖的 accessibility 身份
  （`flash.execute.submit`、`flash.impact.userdata` 等）不变。
- ArkForge 仓零改动（lane 契约不动）。
- GJ-4 行为不变：submit 流程沿用 presentation 的 profile 事实
  （archiveSHA256/sizeBytes/partitions 名单），已实测这些不经过被删的
  伪造计划。

## 影响面

`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/`
（RockchipFlashProfile、RockchipRockUSBFlashProvider→ReviewTypes、
FlashApplicationFacade、RuntimeJobEngine 的两个 static 提升）、
`ArkDeckApp/Features/Flash/`（FlashWorkspaceView、FlashPlanDetailsView 的
摘要/步骤区）、对应契约测试与 UI 测试。
