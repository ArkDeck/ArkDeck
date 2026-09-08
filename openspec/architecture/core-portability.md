# Core Portability Model

> Decision：shared Rust runtime, native UI clients and a shared contract/vector suite（proposed target）
> Status：CHG-2026-074 target pending maintainer PR review; no production cutover or conformance approval
> Baseline：CORE-2.0.0

## Decision

本次变更将 [CHG-2026-074](../changes/chg-2026-074-shared-rust-runtime-core/proposal.md)
及其[设计 §L.1](../../docs/design/cross-platform/rust-core-cross-platform-architecture.md#l1-需要维护者裁决ai-不得自行宣称批准)
的架构目标写成可审查的 Profile 输入；它不以 proposal 的 front matter 或本文件声明批准。
本次策略与 Profile 修订仍需维护者 PR review，生产切换和平台验收由对应任务分别完成。
现有 macOS 生产实现仍为 Swift，XPA-002 只交付独立的 Rust 只读基础。

目标物理形态是一个共享 Rust Runtime（`arkdeck-agentd`）实现 Core 语义，原生客户端
经本地 IPC 消费它：macOS 保留 SwiftUI，Windows 的 WinUI 3 客户端按后续任务交付，
Linux 仍为 future Port。客户端不各自维护 admission、journal、recovery 或 capability
语义；平台 Port 封装 OS 差异。目标不要求 UI 链接共享二进制 ABI。

language-neutral 的 SDD、JSON/YAML contracts、closed registries、状态转换表、canonical
fixtures 和 Conformance cases 继续定义可观察行为。Rust 与迁移期 Swift 必须消费或从
同一锁定来源生成以下资产，并通过同一 Test ID/expected result：

- Requirement/AC、Job transition/effect/cancellation/binding tables；
- `workflow-step`、journal、manifest、Task/evidence schemas；
- operation/catalog IDs 和 Core minimum-risk registry；
- parser golden fixtures 与 deterministic scenario vectors；
- Core conformance acceptance index/cases 和 property-invariant seeds。

## Conformance rule

平台实现可以拥有不同内部类型和并发模型，但 SHALL NOT 手工维护一份含不同状态、默认值或风险等级的“平台 Core”。生成代码的输入 hash、schema ID/version、fixture ID/hash 和 Test ID 必须进入 Task/run evidence。相同 canonical input 在各平台必须得到相同的规范状态、拒绝理由、effect/cancellation 和 manifest/journal 语义；UI 文案与平台错误码 MAY 映射，但不得改变 pass/fail。

平台 Profile 必须明确它采用：

1. 从 contracts 生成 native types/validators；或
2. 独立实现并直接运行共享 contract/vector suite。

无论选择哪种方式，不能把复制测试名称当成共享验收。Conformance runner 必须证明使用的是 Task 固定的 Core、Integration 和 Conformance hash。

CHG-2026-074 为三个 Profile 同步提出策略值
`shared-rust-runtime-native-ui-shared-contract-vector-suite`，替代此前的
`native-conforming-shared-contract-vector-suite`。这是共享 Runtime 加原生客户端的
阶段目标；Profile metadata 的 proposed 注记不表示该平台已经迁移、通过 conformance
或获得支持。生成类型与 validator 仍须运行同一锁定 contract/vector suite，不能以共享
实现本身代替验收。后续物理形态变化仍走 architecture/platform change。

## Phased migration and retirement

迁移遵守[设计 §G](../../docs/design/cross-platform/rust-core-cross-platform-architecture.md#g-persistence-migration-cutover-and-rollback)：
先固定当前单 v1 Swift 基线并交付 Rust 契约/只读链路，再引入控制面 façade，随后按
store owner、authority 和 Provider family 分阶段迁移。每个 durable store 同时只有一个
writer；该计划不改变 Core Requirement、AC、Catalog operation 或任何安全准入语义。

迁移期间保持当前单 v1 schema 和字段集合，逐次验证 Swift/Rust 互读、同 release 的
App/daemon 成对回滚及当前 Catalog digest 上的 macOS GJ-1..5。Swift daemon/引擎/存储
仅在 XPA-018/019 的两个客户端脱钩、XPA-025 性能车道切换和 XPA-017 的纯 Rust 真机
及删除验收满足后退役，不能留下第二份 Runtime 语义实现。XPA-002 不切换 LaunchAgent、
不删除 Swift targets，也不交付 Windows 安装器或 WinUI。

平台 lock 继续记录 macOS `needsReverification`、Windows/Linux `notStarted`。开发基线、
只读拒绝路径、fixture、cross-build 和 hosted CI 都不能替代各平台所需的真实验收。
