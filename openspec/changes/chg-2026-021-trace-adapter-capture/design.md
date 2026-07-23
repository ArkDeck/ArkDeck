# CHG-2026-021 Design:hitrace/bytrace adapter 采集 MVP

> Status:r1 approved;r2 remediation approved;r3 archive-relocation approved;r4 link-closure correction candidate
> Core baseline:CORE-2.1.0(零 Core 变更;认领 trace REQ-TRACE-* 的 macOS 面)

## 0. 采集命令面草案(候选;exact argv 由 TR-001 真机 provenance 固定)

probe(只读):hitrace/bytrace 二进制存在性 → help 输出(family 识别)→ tag 列表
(`-l` 类)。capture(deviceMutation,最小样本):带 duration/buffer/tag 的一次
采集,输出到 Job UUID 隔离路径 `/data/local/tmp/arkdeck/<jobUUID>/`(integration
profile 既定推荐)。**本节全部 argv 是登记候选,不是实现依据**——TR-001 登记前
adapter 不得实现;登记后 exact argv/成败 marker/输出族以 registry 为准(先例:
CHG-015 readonly-probes、CHG-008 M0B-后固定 wrapper;M0A/M0B 教训:help 可能
exit 0 回错误行、成功无固定 marker,一律以登记的真实形态为准)。

## 1. REQ → 既有 seam 映射(全部已在 CORE-2.1.0 契约就位,零新增 kind)

| REQ | seam |
| --- | --- |
| 001 adapter 选择 | probeHostTool/probeDevice + TR-001 registry(help family → capability matrix;未知 family fail-closed,AC-001) |
| 002 capability 受限配置 | catalog `trace-presets`@1.0.0(runtime_rule:unsupported diff、显式接受或 fail preflight;buffer 单位 adapter-must-confirm) |
| 003/004 参数快照/回写/恢复 | snapshotParameter/setParameter(readbackPolicy=required)/restoreParameter + catalog `attachment-debug-profile`@1.0.0(missing 不得以 false/0 伪造) |
| 005 reboot/binding | rebootDevice + waitForDisconnect/Reconnect + Core device-binding(歧义 → awaitingRebindConfirmation) |
| 006 隔离接收 | captureRemoteFile(catalogId=trace-presets,ownedRemotePath=Job UUID 隔离)+ receiveFile(host partial → 验证 → 原子发布,M1-005 storage 契约)+ cleanupOwnedRemotePath(仅验证成功后) |
| 007 immutable raw/过滤 | verifyArtifact/hashFile + postprocessArtifact(derived + 删除统计;"删前两行"仅 parser 证实 chatter,AC-007 golden) |
| 008 honest progress | 阶段化进度(config…restore),仅可靠总量显百分比(REQ-FLASH-011 同族语义) |
| 009 artifact completeness | manifest 记录 tool/tag/duration/buffer/before-after-restored/hash/过滤统计;空 trace exit 0 不判 succeeded(exit0≠成功准则) |

## 2. Adapter 选择(REQ-TRACE-001)

help 输出族识别 → 与 TR-001 registry 的已登记 family 精确匹配 → 选 hitrace/bytrace
adapter;不可解析/未登记 family → 该工具 unknown,不可选、不猜测、raw help 可查
(AC-001);并存时按 registry capability matrix 决策,不按工具名/系统版本推断。
与 M1-006 registry 采用同构:fail-closed、hash-pinned、未登记即 unsupported。

## 3. 参数安全(REQ-TRACE-003/004;含契约缺口收紧)

已知契约缺口(2026-07-14 评审在案):Core `setParameter` schema 未绑定 catalog。
本 change 在 **trace workflow 层**收紧:参数 mutation 只接受
`attachment-debug-profile` catalog 内登记的参数名,catalog 外一律拒绝(fail
closed);不改 Core schema(零 Core 变更边界)。set 后 readback 逐项比对,不一致
→ 不进入 capture、dispatch 0、mismatch 审计(AC-004);missing 参数临时恢复禁用、
持久变更须显式确认(AC-003)。

## 4. TASK-TR-001 provenance 登记形态(先例 CHG-2026-015/005)

versioned registry(trace-probes/1.0.0:每命令 exact argv、intent、authority、
timeout、成败判定 marker、输出族样本引用)+ golden fixtures(help family、tag
list、最小 raw ftrace 头样本;`.gitattributes` binary 先行)+ 逐文件 SHA-256 hash
closure + redacted manifests(序列号/用户路径不入仓)+ OPENHARMONY-TOOLS profile
与 lock bump。采集走 runbook + 人工执行(scripts/ud_capture 或 m0b harness 复用
评估归 TR-001 readiness);登记认可 = evidence PR 维护者 review/merge。

## 5. 分期与边界

- TR-002(host contract)与 TR-001(device provenance)无实现依赖可并行;
  TR-003 硬依赖 TR-001 done。三任务各自 readiness/实现/done PR。
- trace capability = release optional、requires:[];本 change 不动 required 集。
- hardware-matrix:本 change 不新增行(9 AC 无 realHardware 面);未来真机 trace
  capability 行须独立 evidence(REQ-TRACE 无此要求,不预设)。
- Windows/Linux:not started 保持;平台不得改变 typed step/effect 语义(AGENTS 边界)。

## 6. r2 host-contract remediation design

### 6.1 Reboot binding continuity

Reboot 前创建不可公开伪造的 expected-rebind context，至少固定原
`DeviceBindingReference`、target ID 和选中的 `DeviceRebindCandidate`。capture gate
只接受满足以下全部条件的 `DurableCurrentDeviceBinding`：reference target 与预期相同、
revision 等于原 revision + 1、binding 的 transport/connect key/identity snapshot 与选中
candidate 精确相同。错误 target、旧/跳号 revision、其他 candidate 或任一 identity
drift 均以 dispatch=0 fail closed。成功时新的 reference 写入
`TraceCaptureAuthorization`，workflow materialization 必须把它作为 device effect 的
intended binding；不得只保留 `rebootRequired:Bool`。

### 6.2 Receive publication as the cleanup authority

接收目的地遵循既有 `SessionLayout.partialDirectory` / `artifacts/partial/*.part` 契约。
pre-publication plan 只包含 capture、receive、validate/hash 和可选 postprocess；remote
cleanup 不是静态预授权步骤。workflow publication coordinator 必须调用既有
`SessionArtifactStore.publish(from:request:claim:)`，并从返回的 `PublishedArtifact`
提取与当前 Job/artifact/request 一致的 typed cleanup authority。只有该 authority 才能
materialize `cleanupOwnedRemotePath`。内存 tracker 状态、caller assertion、预计算 hash、
文件存在或 process exit 0 均不能替代 store receipt。publish 抛错、fault injection、
receipt/path/artifact mismatch 时 cleanup dispatch 恒为 0，owned remote file 保留。

### 6.3 Per-device parameter capability

catalog entry 只允许参数进入 probe 候选集。新增 typed per-device parameter capability
receipt，固定 durable binding reference、参数名以及 probe disposition；至少区分
supported、unsupported、permissionDenied、needsDeveloperMode 和 unknown。临时与持久
mutation 均要求 matching supported receipt；persistent change 还要求该 receipt 显式
声明 persistent write supported，并继续要求现有 confirmation。receipt 缺失、绑定过期、
参数不匹配或 disposition 非 supported 时 mutation authorization 不可生成，不能等到
set/readback 失败后才发现不支持。authorization 保留 capability/binding reference，供
dispatch 前再次核对。

### 6.4 Capability-gated reliable total

移除 caller 直接构造 reliable-total authority 的路径。factory 同时消费当前
`TraceAdapterCapabilities` 与正数 total；仅当 `reliableByteTotalAvailable == true` 时
产生不可公开构造的 reliable-total receipt。progress report 接受 receipt 而非裸
`.reliable(totalBytes)`；capability=false、receipt 缺失/不匹配或 total 非法均输出
indeterminate + elapsed。capability=true 的 matching receipt 才允许百分比/ETA。

### 6.5 Compatibility and task boundary

上述收紧可能改变尚未发布的 Swift host-contract 调用点，但不改变 Core 或 storage
schema。迁移限定在三份 `Trace*Contracts.swift` 与对应 contract tests；
`ArkDeckCore`、`ArkDeckStorage` 实现、catalog YAML、accepted specs/contracts 均 forbidden。
若现有 `SessionArtifactStore` 或 binding types 不足以闭环，TASK-TR-002R 必须保持
blocked 并先经 scope amendment，不能在任务中扩写 Core/storage contract。

## 7. r3 archive relocation is a bounded immutability exception

已验证的 trace registry/resource pack 与 adapter adoption 在逻辑上保持 immutable。
把本 change 移到
`openspec/changes/archive/2026-07-23-chg-2026-021-trace-adapter-capture/`
只产生一种获准的生产字段变化：3 个 `provenance.redactedManifests` 从 active change
根迁移到固定 archive 根。

- 无 integration/profile/registry version bump，因为 exact argv、family、resource bytes、
  success judgement、effect、authority、capability matrix 与 consumer behavior 均不变；
- `resources.json` 与 7 个 resource bytes/hash/size 保持逐字节不变；只有 registry
  bytes/hash 因三处 path 加长而变化，并只传递到 OpenHarmony profile、Integration lock
  和 Swift adapter 的 exact registry-hash consumer；
- 长期存活的 Agent failure-pattern handbook 只迁移 5 个 link target，不改变其
  Fact/Inference、OID、taxonomy 或结论；
- CHG-2026-029 task carrier 内 6 个 path+blob pin 和 1 条 dated note 是历史事实，不由
  本 change 改写。它们在该 change 仍 active 时构成 archive blocker；待其归档后可作为
  archive-local 历史原样保留，或由其自身独立批准的 revision 先解除；
- archive-local evidence、run、task、design、verification 与 acceptance-cases 不为新
  path/hash 追溯重写；proposal 只做 `verified→archived`；
- normalized before/after 比较必须证明列举外 semantic delta 为 0。任何新 consumer、
  新 active-root reference、resource/hash 漂移或需要 version bump 的变化都会使本例外
  失效，必须停止并先走新的 D1/integration scope。

## 8. r4 closes the post-r3 handbook-link drift

CHG-2026-029 r5 在 r3 合入后为 AF-014 增加了 TASK-TR-002R run 的一手 source link，
使 living handbook target 从 5 增至 6。r4 只把该 target 纳入同一原子路径迁移：

- 6 个 link 仍只替换 active change 根为 r3 固定 archive 根，link text、anchor、
  Fact/Inference、OID、taxonomy 与其他 handbook bytes 不变；
- r3 的 3 个 registry path、3 个 hash consumer、registry candidate bytes/hash、
  resource closure、version 与产品/adapter 语义全部不变；
- 已归档 CHG-2026-029 中的历史 path/link bytes 保留，不参与 living rewrite；
- r4 合入前 archive 不得开工；若再出现新的 active reference，继续 fail closed
  并先做新的 D1 revision。
