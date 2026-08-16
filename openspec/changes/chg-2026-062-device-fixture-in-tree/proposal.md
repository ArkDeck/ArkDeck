---
id: CHG-2026-062-device-fixture-in-tree
revision: 1
status: proposed
class: implementation-only
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# 把设备侧 fixture 纳入仓库，并为 `tests/**` 建立路径权限

> **本文件不构成批准。** 它请求的是一项此前不存在的路径权限：仓库内目前没有任何
> base-tree Task 覆盖 `tests/**`，而 `AGENTS.md` 明确禁止为通过门禁而扩张 Allowed paths。
> 因此该权限只能由维护者经 change proposal 批准后合入，再由后续 PR 使用。

## 产品问题

GJ-5 的崩溃 journey 与 ArkTrace 的 trace 闭环都跑在同一个真实 OpenHarmony 应用上。它至今
只存在于操作者 home 下的一个未跟踪目录（`~/Developer/WaterFlowLayoutDemo`），带来三个具体
后果：

1. **不可 review。** Runtime 侧 pin 了它的项目路径、`entry@default` target、unsigned HAP
   产物路径、`bundleName`/`abilityName` 与崩溃签名；这些 identity 只能靠读
   `WorkspaceProjectProfile.waterFlowDemo` 反推，改动它们会静默作废已铸造的 capability。
2. **不可复现。** 任何人重装机器都无法从仓库得到这个被测对象；它的行为由几个散落的常量
   决定，而这些常量没有任何评审记录。
3. **两种用途曾经互相破坏。** crash probe 在启动约 12 s 后 abort 进程，这正是崩溃 journey
   需要的；而 trace 闭环需要进程存活整个采集窗口并稳定产出等量工作。二者曾是两个可以各自
   开关的布尔量，crash probe 默认开着，在无人察觉的情况下打断了 ArkTrace 的三次采集。

本 change 把该 fixture 纳入 `tests/waterflow-demo/`，并把两种用途收敛为一个互斥选择器
（`FixtureMode.MODE`），使"模式不可能被设了一半"。

## 范围

### In scope

- 新建 `tests/**` 的路径权限，供本 change 声明的 Task 使用；
- 把既有 fixture 工程按原样纳入 `tests/waterflow-demo/`（不改变其被 Runtime pin 的任何
  identity：路径以外的 module、target、产物路径、bundle、ability、崩溃签名均不变）；
- 把 crash probe 与 trace workload 收敛为单一 `FixtureMode` 选择器；
- 记录 Runtime 耦合点与重指路径的正确姿势（`agentd update` 必须同时重传
  `--harness-model-*`，否则被 `Harness local CLI working directory must be the validated
  demo-app project` 拒绝）。

### Out of scope

- 不修改任何 Runtime、Provider、Catalog 或 operation 语义；
- 不改变 `bundleName`（本机签名 profile 按该 bundle 签发，改名即不可签名、不可部署）；
- 不引入新的设备权限、不新增 operation、不触碰 capability 铸造逻辑；
- 不把 fixture 纳入任何自动构建或 CI 车道——它由 Runtime 在需要时构建。

## 为什么需要新的路径权限

`tests/**` 目前不在任何 base-tree Task 的 Allowed paths 内。`AGENTS.md` 允许的"自描述
supplement"明确**不产生路径权限**，且要求 diff 同时含 base Task 已授权的生产路径——纯 fixture
的 diff 不满足该条件。因此这项权限无法由交付 PR 自带，只能先经本 proposal 批准合入。

权限范围刻意收窄为 `tests/**`：它不覆盖 `Packages/**`、`Catalog/**`、`ArkDeckApp/**` 或
`openspec/**`，因此不能被用来绕过任何既有的生产路径审查。

## 风险与边界

- **fixture 会被 Runtime 构建**。它落在仓库内之后，`workspace.build-openharmony@1` 的
  ProjectProfile 需由操作者重指到新路径；该操作已验证可行且不改变 daemon 二进制，
  故不影响 OpenHarmony 签名 receipt 所 pin 的 `trustedDaemonApplicationSHA256`。
- **签名材料不入库**。`build-profile.json5` 的 `signingConfigs` 提交为空数组，
  `*.p12`/`*.p7b`/`*.pem`/`*.cer` 一律 ignore。构建只产出 unsigned HAP，签名由
  `workspace.sign-openharmony-hap@1` 经 closed preset 完成——生产链路本来也只消费 unsigned。
- **默认模式**保持 `crashProbe`，即 GJ-5 journey 的既有行为，避免本 change 静默改变
  崩溃闭环的预期终态。
