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

## GJ-2 confirmed-failure compensation: candidate scoped delta

本节是针对真实 GJ-2 缺陷的窄修订候选，随 TASK-SVC-002 范围补充供维护者 review。
它不修改 current Core spec、Task/change 状态、已发布 operation、Runtime authority 或
历史 Runtime/evidence；本范围 PR 不包含下面描述的生产实现。来源、精确文件与
正负/崩溃矩阵见[审查记录](evidence/runs/TASK-SVC-002/gj2-compensation-scope-review.md)。

### Proposed addition to REQ-JOB-001

在原 external-effect intent 由 Provider reconcile 确认为失败，且此前设备身份和全部
external-effect outcome 均已确认后，execute Job 可在 `finalizing` 执行适用于该 failure
path 的、已由成功 source Step 预先 durable 声明的 typed compensation。
此路径 SHALL 使用既有 `compensationIntent` / `compensationOutcome`；它不是普通 Step
派发窗口。`finalizing` 的普通 Step 仍只允许 `finalizeSession`，不得先伪造
`running` / `planning`，也不得重放原 unknown intent。

补偿前 SHALL 重新验证原完整 materialized plan、精确 RuntimeCapability、fresh
target/identity/binding/tool facts 和必要 Artifact；只能执行该 plan 已声明的精确补偿。
任一补偿的 identity 或 external-effect outcome 未知时，Job SHALL 由新增的 execute
pair `finalizing → waitingForRecovery` 停车并保留 exact outstanding intent 和 capability
lineage；不得进入 terminal 或以原 failure 的已知性掩盖补偿的未知结果。此 pair
不授权任何新 operation、普通 Step、plan-only mutation 或未声明的补偿。

该补偿的独立只读 reconcile 只有在其 outcome、identity 和 safe boundary 都已确认时，
才可回到原 failure 的 `finalizing`；confirmed completion 和 confirmed non-execution
都不得把 Job 转成普通 `running` 或把原 operation 改成 succeeded。若补偿仍 unknown，
则保持 `waitingForRecovery` 且后续 mutation dispatch 为 0。原 intent 和任何已经有
durable intent 的补偿都不自动重放。

### Proposed clarification to REQ-JOB-004

source Step 的 typed compensation descriptor SHALL 在该 source intent dispatch 前
durable 保存，并与其 target、binding、argumentsHash 和 source identity 关联。
`debug.hap@1` 的 failure path 只调度已确认成功 source 所声明的 stop、按 cleanupPolicy
选择的 uninstall 和 job-owned staging cleanup。`uninstallPackage` 使用已有 typed kind
与参数/effect/binding 约束；本修订仅将其加入既有 compensation descriptor vocabulary。

原始 operation failure SHALL 在补偿、reconcile 和 restart 后保留；补偿 outcome 独立
记录，不覆盖原失败。confirmed failed cleanup 的 residue SHALL 幂等记录，保存精确
typed action，并按现行规则呈现 debt/needsAttention；持久化失败不得被吞掉后提前结算。
已有 failed cleanup 的显式 debt continuation 语义保持，不能用 debt 代替 unknown
compensation 的 journal/recovery 路径。

restart 本身 SHALL 零 device dispatch。含尚未完成、预先声明补偿的 clean `finalizing`
不得被自动终结而丢弃补偿职责；显式既有 continuation 只能执行剩余未派发补偿。
intent/outcome、debt、terminal 和 capability outcome 各崩溃窗口均以 durable 事实恢复，
不重复补偿、不重复记债、不提前释放 capability。只有所有 external-effect outcome
已确认，且适用补偿已完成或其 confirmed failure 已单独保存，才可完成原 `failed`
终态并结算 capability。缺少预声明或完整证明的历史 Job 不补造 descriptor，也不因
升级自动产生新 dispatch。

## Current Session publication: candidate scoped delta

本节修复当前 Job 未生成正式 Session，以及 unrelated manifestless Session 阻断精确
导出的实测产品缺口。现象和固定契约见
[审查记录](evidence/runs/TASK-SVC-002/session-publication-scope-review.md)，实际 host
执行见[验收记录](evidence/runs/TASK-SVC-005/host-import-export-20260908.md)。
本候选不修改 current Core spec、Task/change 状态、operation、authority 或用户数据。

### Proposed clarification to REQ-ART-001/002/004

新 production admission SHALL 由同一 Runtime-owned storage policy/root 和 host-wide
coordinator 建立 durable Job/Session ownership，先取得 metadata/finalization headroom。
完整 output/copy 增长预算未获准时保持 queued，零 Provider/可选 Artifact dispatch；
不得把 heavy/unknown writer 改称 light。只有完整 claim 升级已耐久保存才开始执行。

执行终态与 Session publication SHALL 分别读回。status/summary 及其 CLI/App/Agent
消费者增加同一 required closed `sessionPublication`；缺当前 ownership 时为 unavailable，
不从 sessionId、Job success、历史目录或人工确认推断 published。publication 失败或未知
不得改写原 operation outcome、产生新的 device dispatch 或释放未决 capability。
Agent 的 compact job 仅在已有 Job 的分支同步该 required 字段；no-Job 和其他 HAR/
controlAction/challenge 分支保持现有形状。runner receipt 的 publication key 始终存在，
未取得可信 Job status 时显式 null，不把未观察状态伪造为 unavailable。

Runtime SHALL 从本次 Job 的实际计划、Journal、outputs、binding 和 admission 证明构造
当前 Manifest，固定 proposal 后封闭原 Journal，再以相同字节和已验证的 Artifact 副本
发布 Session、登记 catalog、耐久保存 receipt，最后释放 claim。crash recovery 仅处理
已有 authoritative ownership，重新准入剩余增长，重验 root/configuration/identity 与
原始 hashes；不继承旧内存 lease，不重写已封闭 Journal，不重放 Provider intent。

Manifest SHALL 忠实表达现行 defaultReadOnlyPolicy/runtimeCapability、无设备 host target
及 recovered 语义，不伪造 interactive/lab actor 或缺失的 consumption/coverage/epoch。
pre-consume failure/cancellation 只有在 Journal 中机械证明零 mutation intent 时允许
没有 consumed authority。recovered 必须携带属于本次独立恢复的完整 consumption、
coverage、postflight 和 supersession 关联；原 covered Jobs 保留 unknown。只有一种
current v1 布局；schema、Swift validator、writer、隐私导出和正负 fixtures 同车更新。

### Proposed narrow clarification to exact Session export

既有 `session.export.preview/apply` MAY 导出正式登记、完整 finalized 的精确目标，
即使同一根目录中存在已机械定位为 unrelated leaf 的未计入 catalog 内容。成功响应
SHALL 显式携带全局 incomplete/blocker/count/已测 bytes 与精确源 identity、Manifest
及 Journal hashes；这些事实均纳入既有完整 JCS previewDigest，apply 重新验证。

root/volume 不可信、catalog corrupt/unavailable、unscoped unknown、duplicate Session
identity、目标本身 incomplete 或无匹配 catalog entry 时仍 SHALL fail closed，零导出
输出。全局 list/show/pin/unpin/cleanup、heavy writer 准入、stale preview 与 applying
unknown 永不 replay 的规则保持；不得以 partial catalog、目录迁移或补造 manifest 隐去
旧 unknown。默认隐私规则及 raw/partial 排除保持，新增 audit 字段的源 digest 和关联
脱敏同车验证。导出派生物不能成为新 Runtime authority 或原始 Session。

## Acceptance ownership

SVC-AC-01..10 是本 change 的局部验收，在 [verification.md](verification.md) 登记。
多版本支持测试改为当前单格式正向及旧/错格式负向；这不移除当前安全行为测试。
本 PR 不添加全局 AC、不替换 Core ID、不改变 baseline/平台验收状态。
