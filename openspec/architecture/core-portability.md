# Core Portability Model

> Decision：language-neutral contracts with conforming native implementations  
> Status：review candidate  
> Baseline：CORE-1.0.0

## Decision

ArkDeck Core 的规范物理形态是 language-neutral 的 SDD、JSON/YAML contracts、closed registries、状态转换表、canonical fixtures 和 Conformance cases；它在 v1 **不是**一个要求所有平台链接的共享 Swift/Rust/C++ 二进制 ABI。

macOS MAY 以 Swift 实现，Windows MAY 以 C#/.NET 或 C++ 实现，Linux MAY 以 Rust/C++/其他适合桌面的语言实现。每个实现都必须消费或从同一锁定来源生成以下资产，并通过同一 Test ID/expected result：

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

V1 的三个 Profile 统一固定策略值 `native-conforming-shared-contract-vector-suite`，即方案 2：各平台使用适合本平台的 native implementation，直接运行相同、hash 固定的 schema/contract/vector/conformance suite。该值必须出现在 Profile metadata 并由 guard 校验；平台实现 Agent 不再选择 Core 的物理形态。未来若引入 code generation 或共享 library，必须先走 architecture/platform change 并同步更新所有受影响 Profile 与验证计划。

## Future shared library

未来 MAY 通过批准的 implementation/architecture change 引入共享 Rust/C++/WASM library 来减少重复实现，但前提是它不改变 Core 可观察语义、平台可用性或 AC。共享二进制是优化选项，不是 Windows/Linux 开始实现前需要重新决定的产品规则。
