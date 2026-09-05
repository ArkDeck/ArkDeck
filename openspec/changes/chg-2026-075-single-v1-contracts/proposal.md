---
id: CHG-2026-075-single-v1-contracts
revision: 1
status: proposed
class: core
core_change_level: major
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos, windows]
---

# CHG-2026-075 — Consolidate prerelease contracts on one v1

> 本 PR 只交付供后续 AI 执行的完整任务方案；不包含产品实现，不声明 approved、
> verified 或 REAL_DEVICE_PASS。维护者 review + merge 是范围批准载体。
> 任务合入 protected main 后由用户交给 AI 按依赖实施，不另开 readiness/status-only PR。

## Why

项目尚未对外发布，无需承担历史协议、开发期持久化格式的多版本兼容。
现行实现已积累 control 1.0/2.0 双协议、Journal 五代、Manifest 四代、Evidence V6，
并在 App/CLI/daemon、导出、恢复与测试之间传播。清理目标是当前完整语义的唯一 v1，
不是恢复历史 v1 的能力或安全策略。

扫描代码基点为 706d05f9e167ef3f8d5baa3c2f1ae9a42503305a；本任务包基于 main 的完整修订
ad59175aa0da5997e3ba9154b68bdfdf0a1d009d。文件行号/方法计数只用于导航，实施 AI 应以其开工 base 的
实际调用链为准。已核验 main 新增提交只修订 CHG-074 方案，不改变扫描涉及的生产实现。

## What changes

- 唯一控制协议及 Runtime request/result；所有仍有产品用途的 CLI/App/Executor 调用
  同批迁移；删除 semver 协商、health fallback、major/minor 选择及 legacy/target 分流。
- 唯一 Journal、Manifest、Job/capability store、SQLite schema 与完整恢复状态；
  删除历史 authority/campaign decode 兼容及缺字段重建，不承诺开发期旧数据续跑。
- 当前完整 hardware evidence、debug invocation/permit、内部 Provider descriptor
  标识统一 v1；类型/文件名不带 V2/V6。
- 移除旧偏好、旧配置与旧签名存储形态的兼容；当前 Data Protection Keychain、
  Runtime-owned 设置、bundle 配置和用户自定义材料能力保留。
- 同步契约源、生成器、生成物、脚本、fixtures、测试与现行使用说明。
- CHG-074 r6 在同车文档中改为消费此单 v1 基线，不再新增 2.1.0 或复活旧世代。

## Scope and compatibility delta

当前结构只保留一个形态；需要格式标记的文档固定 1 或 1.0.0，已有 /1、@1、
.v1 身份可保留。不引入新的通用版本管理、自动迁移或协商框架。
具体约束与逐项替代关系见 [design.md](design.md)、
[spec-delta.md](spec-delta.md)，实施边界见 [tasks.md](tasks.md)。

兼容行为发生显式破坏性变化，故 class=core、core_change_level=major；
这不是新 destructive admission policy。Core baseline 的审计版本与 wire version
不同，本 PR 不将 CORE-* 重置为 v1、不 ratify candidate，也不直接编辑 accepted
Requirements/Scenarios。实现按本 scoped delta 保留 Core 安全语义；实际归档按仓库现行
规则处理 baseline 与 current spec 的一致性，不为本次清理先造新治理框架。

受影响项：REQ-ART-001/002/003/004/006、现行 Job/recovery Core 要求；
POL-SAFETY-001、POL-TARGET-001、POL-RECOVERY-001、POL-ARTIFACT-001、POL-AGENT-002
全部保持。CLI 产品契约 §12 / CLI-REQ-025 中冻结 1.x、长期 major 兼容的开发期承诺，
以及 CHG-074 的多版本交付目标，由本 change 的单格式策略替代。
验收为 change-local SVC-AC-01..10，定义于 [verification.md](verification.md)，
不提前加入全局 acceptance registry。

## Out of scope

- 新 Catalog operation、provider、integration/device profile、transport 或平台实现；
  operation @1 及 capability 的 operation/version pin 保留。
- generation、bindingRevision、state/row revision、内容 digest 与幂等指纹的递增/校验。
- ArkTrace adapter/index schema、ArkForge 外部协议、HDC/SDK/OS/toolchain 版本、
  Source Map v3、sqlite3_*_v2、ABI、签名格式、CI cache namespace。
- 历史 change/baseline/raw evidence 的批量重编号、Artifact 原地重编码。
- 放宽 XPC 权限、RuntimeCapability、Provider coverage 或 unknown-outcome 规则；
  不创建 capability/admin 或 caller 提供 trusted facts 的新入口。
- Rust/Windows 交付仍属于 CHG-074；本 change 只给出它必须消费的共享契约基线。

## Data, rollout and platform impact

- 新客户端和新 daemon 作为同一开发构建更新；本阶段不支持混合旧构建或自动协议降级。
  transport peer 身份、frame/response 校验和错误后的零重派发规则仍有效。
- 可再生成的缓存、偏好可由用户明确重建；用户自定义设置通过当前入口重新配置。
  旧 Runtime 权威状态保持原样，禁止自动删除、重标版本、清账或释放 target lane。
  旧 v1 和新 v1 的同名碰撞按完整契约和存储布局辨识；无法证明时 fail closed。
- 不提供“换空目录即可继续刷机”的快捷恢复；未决 intent/reservation/unknown lineage
  必须维持阻断。可见错误说明不支持的开发状态与当前可用入口，不能建议绕过。
- macOS：重验 CLI、App facade、安装/配置和受影响 GJ。Windows 尚未交付，直接消费
  单 v1，不能建立第二份兼容实现；本 PR 不更新其 verified 状态。
- 回退使用匹配的一整套旧构建及其未改写的旧状态，只在无活动/未决副作用且状态
  所有权一致时进行；不让旧程序接管新格式，不以回滚二进制消除未知结果。

## Delivery

1. TASK-SVC-001：控制面、Runtime 请求、CLI/App/Executor 原子收敛。
2. TASK-SVC-002：持久化、恢复和旧 authority 原子收敛。
3. TASK-SVC-003：证据、debug、内部 Provider 格式及其消费者收敛。
4. TASK-SVC-004：开发期配置/偏好兼容清理，完成剩余范围审计。
5. TASK-SVC-005：已合入实现的 headless 产品验收、App 呈现检查与最终交付。

每个实现任务同车完成针对性验证、生成物和文档，不能把所有测试推迟到最后。
第五项只执行已发布 typed operation 并记录实际结果，不授权 raw 设备命令。
