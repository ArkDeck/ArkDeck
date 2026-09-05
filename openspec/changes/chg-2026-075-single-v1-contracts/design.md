# Design — one current contract, labelled v1

## 1. Outcome and naming

所有生产 writer/reader 只实现当前完整形态。control protocol 与 Runtime request/result
固定精确 1.0.0；不接受任意 1.x，不返回可协商版本列表，不以 method/operation/render mode
选 schema。已有 /1、@1 和 .v1 标识保持；无须区分格式的 Swift 类型、文件和 UI key
使用无版本后缀名称。普通格式校验保留，它不是多版本管理。

一套 protocol methods registry 是唯一方法源。能力发现可保留 publishedMethods 等信息，
但不能继续选择版本。删除 protocol.negotiate 及 --require-protocol，错误版本或未知旧
入口在公共边界拒绝；不会自动再发到另一个协议。

旧daemon也可能自报1.0.0，因此仅比较版本字符串不能证明构建匹配。现有连接/安装
路径必须在任何mutation前验证当前严格health/contract identity或已选daemon的成套
构建身份；旧health响应缺失当前契约必需字段、结构或身份不符即拒绝，零业务重派发。
这只是当前契约身份核对，不选择版本、不维护兼容列表。XPC同样保留peer身份与当前
typed shape校验，不能因为签名相同就认为旧构建兼容。
核验绑定实际dispatch的daemon实例；每请求重连、重启或peer身份变化必须重新核验。
唯一mutation帧携带当前契约身份约束，daemon拒绝缺失约束的旧client；该标识只辨识
当前格式，不授予authority、不引入新认证策略/配置或第二种受支持格式。测试覆盖
新client→旧daemon、旧client→新daemon及health后peer更换，三者零mutation dispatch。

## 2. Control-plane capability preservation

扫描时 daemon 主 dispatch 有 118 个方法名，targetMethods 有 75 个，差集 43 个
包含三项禁止 capability 管理的占位。这是扫描事实，不是验收时应凑齐的数字。
TASK-SVC-001 必须从其最新 base 生成完整映射，逐行登记：原 method、唯一入口、
request/response shape、生产调用方、保留/合并/删除理由和回归用例。
任何有生产调用方的行均须有去向；不把拒绝占位当成功能重新开放。

| Family | 唯一形态与迁移要求 |
| --- | --- |
| Job plan/submit/run/status/result/evidence/list | 当前 typed request、Runtime 资源投影、分页与 cursor；保留 submit --wait、cancel/reconcile 和真实 recovered 终态 |
| Artifact list/inspect/read/export | 当前 tagged owner (Job/Import)、分页、敏感访问与显式导出；迁移旧 jobId 参数调用方 |
| 四组专用 import | 迁到现有 artifact.import.* 的 typed kind；保留 HAP/FlashBundle/NativeLibrary/WorkspacePatch 的检查、binding、chunk offset/generation、abort/commit；不保留重复兼容别名 |
| device.candidates/observations + target.adopt | 当前物理 observation reference/generation，补全 App 显示所需投影；不回退 connectKey candidate 或启动缓存 |
| runtime.hdc-status | runtime.hdc.status 的实时事实，迁移 App parser |
| job.list-page | 当前 job.list 分页，统一顺序 token 与 CLI 参数 |
| workspace project/preset | Runtime 拥有的实时资源、generation 与统一响应包装，删除启动配置投影 |
| operation/Flash/Debug/Trace/cleanupDebt | 仍被产品使用的能力保留在唯一方法表；不在旧 targetMethods 不能成为删除依据 |
| capability.draft/install/revoke | 继续拒绝或按未知 method 拒绝，永不发布为可用管理能力 |

新通用 import 不能把 daemon 全方法表直接变成 XPC allowlist。
XPC 的 typed kind/operation/target、caller ownership、one-shot gate 和取消权限范围
必须与现行产品能力相等；替换方法名不会授予额外能力。

CLI 的 human/JSON/JSONL 与已有渲染选项只改变输出。
Executor 只持有一个 client，不再区分旧 read/new submit。总 deadline、request ID、
structured error、preAdmission/newDispatchCount=0 证明以及 unknown outcome 规则保留：
只有能证明未到达 authority 才报告零派发，不把丢响应/超时当安全重试信号。
recovered 保持独立终态，不映射成 succeeded，也不触发误取消。

## 3. Runtime request and authority boundary

RuntimeOperationModelsV2.swift 改为 RuntimeOperationModels.swift，保留当前 typed inputs、
target、requested outputs、预算与合法 optional；required schema 固定 1.0.0。
移除 major/minor 容忍和历史 campaign 字段。codec、直接 Codable decoder、嵌套
RuntimeJobRecord.load 都执行同一当前契约；只改外层 wire codec 不算完成。

standingAuthorization、evolutionCampaignConfirmation、chatConfirmation、
campaignReservation 等旧权限表达不得被未知字段忽略后进入默认策略或新 capability
准入。拒绝在 Job 创建/dispatch 前发生；持久化内层拒绝不能触发“重建成功记录”。
旧 authority 的 decode/export 限制不是永久 reader 承诺，但任何删除都不能解除拒绝。

## 4. Durable state and old-v1 collision

Journal 1.0/2.0/2.1/2.2/3.0 与 Manifest 1.0/2.0/2.1/2.2 合并为当前完整 v1。
普通和 Flash/recovery writer 使用同一 schema，状态与 proof 决定所需字段，
不以版本决定是否允许 recovery。JobState 包括当前恢复状态；旧 intent 的 outcome
保持 unknown，只有 Runtime 机械证明的独立完整覆盖 recovery 可建立 supersession。

SQLite 新库直接创建当前完整表、索引、WAL/FULL/事务约束，user_version=1；
删除 ALTER v1→v2 与 legacy creation sentinel/order 迁移。row version 继续递增。
capability store 新文档标记 1.0.0，但 reserve/consume/outcome ledger、lineage chain、
checkpoint、幂等与 crash consistency 全保留；不重置 remaining uses。

切换前先实现旧格式辨识与拒绝，再启用新 writer：
- JSON 校验当前完整 key set、类型、枚举与关联；版本字符串相同不是兼容证明。
- SQLite 校验实际表/列/索引与现行约束，旧 schema=1 不能被误当新库。
- 如果完整结构相同且语义仍满足现行规则，可以按当前契约读取，无需旧版本分支；
  语义无法由 bytes/布局区分时拒绝旧 store，在原目录保留数据，不猜测升级。
- 现有未决状态不可读时，原 target lane/整个相关 Runtime mutation 面 fail closed；
  不创建空 store 替代，不清理 reservation，不伪造恢复证明。
- 真正首次安装可初始化当前空库，host/fixture测试同样可用空目录；若发现旧authority/
  Journal/ledger、改变已配置state root或无法证明旧状态不存在，不能用新空库替代。
  生产配置/安装路径不可自动绕过旧状态检查。
  原证据与 Artifact bytes 不重编码；不提供自动迁移/清空工具。

Current schemas、Swift validator、writer、fixtures 必须同一实现 PR 合并。
旧 change 中被现行测试直接加载的 draft schema，迁到 current fixtures 后移除该依赖，
历史目录和硬件 evidence 原文保留。

## 5. Evidence, debug and Provider formats

HardwareEvidenceV6Record 改成 HardwareEvidenceRecord，当前完整字段固定 v1。
删除仅由测试调用的六版本 discriminator。保留 executor/effect、RuntimeCapability、
fresh confirmation、reservation/use ordinal、actual typed Steps、Artifact/plan/target
digests、uncertain effects、coverage、supersession、postflight 和 terminal disposition。
测试 fixture 只能证明形状和投影；新版本标签不能冒充新 Catalog 真机结果。

RuntimeDebugInvocation 的 permit/document、JobState、内部 bound Rockchip descriptor
标签统一 v1；.v2 → .v1 保留 bound identity 校验。实际 provider action lowering、
descriptor digest producer/consumer、fixture pin 必须一致。明确拒绝 retired unbound
verification/旧 direct flash intent，不恢复旧执行实现。
外部 ArkForge、ArkTrace、签名格式/ABI 等版本不在此重编号范围。

## 6. Preferences and developer configuration

只保留当前 Runtime-owned history filter/storage、单 bundle ArkForge 配置、
Data Protection Keychain secret envelope 和签名 receipt 结构。删除开发期旧偏好
搬运、三环境变量升级、per-binary ACL/旧密码账户兼容及对应 CLI migration 入口；
现行安装、更新、重配、卸载路径、用户自定义签名材料继续可用。

非权威 UI key 可直接采用无版本后缀；旧偏好可忽略并显示默认值，用户通过当前设置
重配。自定义材料、Keychain 和 Runtime 状态不因格式拒绝而自动删除，不把用户材料
替换成 SDK 默认材料。旧配置给出可操作错误，不创建新的迁移框架。
合法身份恢复、HDC topology/binding 迁移与进程重启是当前业务语义，不按 legacy
关键词整段删除。

## 7. Dependency and validation

SVC-001 → SVC-002 → SVC-003 → SVC-004 → SVC-005。
共享文件按顺序合入，每个任务在已合入前置的最新 main 上实施；不能让两个 AI 同时
删除同一个兼容层。内部可并行做独立阅读/测试，但 producer/consumer 原子交付。
每步保留当前能工作的功能与失败边界，不能先合入只改版本常量的中间态。

CHG-074 的 XPA-001 在 SVC-001..004 后为最终单 v1 生成逐 method typed schemas；
Rust/Swift 迁移期间的 byte/field freeze 从该最新 Swift 构建开始，不冻结清理前的
历史版本。后续 owner 切换仍保留全部未决状态。
详细测试、真机界限与完成条件见 [verification.md](verification.md)。
