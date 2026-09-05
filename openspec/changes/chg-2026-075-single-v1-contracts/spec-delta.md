# Scoped compatibility delta — CHG-2026-075

此文件描述本 proposal 请求维护者审查的精确兼容行为变化，不自行修改 accepted
Requirements/Scenarios。非本表范围的语义继续受现行 Core 和 approved recovery delta
约束。实现 PR 同车更新现行机器契约及相应产品设计文档；历史归档不改写。

| Surface | 清理前 | 本 change 的唯一目标 | Owner |
| --- | --- | --- | --- |
| control registry/generator/runtime-control-plane schema | legacy 1.0 + target 2.0，semver negotiation/fallback、按版本方法表 | 精确 1.0.0、一个方法表、严格 framing，未知版本在业务处理前拒绝 | SVC-001 |
| Runtime request/result schema | 2.0.0，major=2 接受与历史 campaign 字段 | 当前 typed 形态固定 1.0.0，所有 decode 入口同一校验，拒绝旧权限字段 | SVC-001 |
| CLI 产品契约 §12 / CLI-REQ-025；negotiation 与 machine 文档 | 冻结旧 1.x、指定 required major、与旧 daemon 混用 | 开发期不承诺旧版本兼容；成套 client/daemon 更新；无 --require-protocol 或降级 | SVC-001 |
| App/CLI/Executor resource shapes | 同名方法存在两种 params/result；部分 App 只用旧方法 | 当前资源形态，迁移全部有用途调用方；保持 typed XPC 权限与业务能力 | SVC-001 |
| Journal/Manifest/JobState + current schemas | 多代能力表、Flash 与非 Flash 不同 writer、旧权限关联形状 | 一套当前恢复能力齐全的 v1、按业务 proof 校验、删除历史形状适配 | SVC-002 |
| SQLite/Job/capability 持久化 | user_version=2 + v1升级、旧字段重建、capability doc=2 | 新结构固定 v1，实际布局校验；当前 ledger/lineage 保留，旧状态不自动转换 | SVC-002 |
| 硬件 evidence schema/projector | V6 writer、V1..V6 discriminator | 当前所有安全关联字段的 v1 writer/reader，旧raw bytes不可变 | SVC-003 |
| debug invocation/permit、内部 Provider descriptors | 单一实现标记2/3，bound action后缀v2 | 当前实现标记v1、类型无版本后缀、bound identity与digest校验不变 | SVC-003 |
| Settings/History/LaunchAgent/signing配置 | 旧偏好/三key/旧secret形态迁移 | 只支持当前配置形态，旧配置显式拒绝或非权威偏好回默认，不删除用户材料 | SVC-004 |
| CHG-074 future per-method/Rust基线 | 新增2.1并保留1.x/2.0、补记历史Journal代际 | 消费SVC完成后的单v1；跨语言契约仍逐method共享，不维护第二份历史协议 | 同车074 r6 |

## Preserved requirements

- REQ-ART-001/002/003/004/006：Session/Job durable boundary、raw不可变、原子发布与
  schema不兼容可检测、完整manifest执行语义、local-first/explicit export全部保留。
  schema/app version 元数据不删除；它们不能被一概当作“版本管理”清掉。
- POL-AGENT-002：只有 protected-main Runtime materialize/pin/reserve/consume capability；
  operation/version pin、fresh trusted facts、预算和 typed-only dispatch不变。
  历史 authority不成为新writer、admission、reservation、dispatch或recovery输入。
- POL-RECOVERY-001：unknown intent永不replay，完整机械证明、独立recovery epoch、
  supersession与原outcome不可变；格式不支持本身不能释放lane。
- POL-SAFETY-001 / POL-TARGET-001 / POL-ARTIFACT-001 / POL-PRIVACY-001：
  身份、权限、未知结果、原始证据、secret边界不变。
- 当前合法 optional、revision/generation、外部工具版本与格式维持其业务意义。
  accepted Core AC不能因移除历史兼容测试而删掉或放宽；若实施发现本表外Core变化，
  只提出有具体文本/理由的scoped修订，不自行改安全规则。

## Acceptance ownership

SVC-AC-01..10 是本 change 的局部验收，在 [verification.md](verification.md) 登记。
多版本支持测试改为当前单格式正向及旧/错格式负向；这不移除当前安全行为测试。
本 PR 不添加全局 AC、不替换 Core ID、不改变 baseline/平台验收状态。
