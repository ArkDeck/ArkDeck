---
id: CHG-2026-021-trace-adapter-capture
revision: 4
status: verified # 2026-07-23 verification-closure PR #403 merge `95e56eae0102c37a885c0277089089a02b7bc4fb`；r3 archive scope #404 merge `2cddc8a83399e643e11dbe93d1852b1e6417a1bd`；本 r4 只把 #413 后新增的 living handbook link 纳入 archive closure（5→6），不改变 verification 结论或其他 r3 边界，仅在本 D1 PR 经独立 AI premerge review且维护者 review/merge 后生效
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# M2 Trace 侧:hitrace/bytrace adapter 采集 MVP

## Why

roadmap M2 = UI Dump/Trace MVP。UI Dump 侧由 CHG-2026-008 承载(采集链进行中);
Trace 侧尚无 change。现状事实(2026-07-21 盘点):

- **认领面完全未动**:`REQ-TRACE-001…009`(9 REQ / 9 AC)在 traceability 全为
  notStarted;canonical minimum_evidence 分布 = **contract × 7 + parserGolden × 2
  (AC-TRACE-001-01/007-01),零 realHardware**——验收面可由确定性 contract 测试 +
  版本化 parser golden fixture 关闭,真机需求只来自 adapter argv/输出族的
  provenance 固定,不来自 AC。
- **seam 与数据面已就位,零 Core 变更需求**:trace 全链所需 WorkflowStep kind
  (captureRemoteFile 的 `trace-presets` catalog、stopRemoteCapture、send/receiveFile、
  snapshot/set/restoreParameter、waitForDisconnect/Reconnect、rebootDevice、
  verifyArtifact/hashFile、preflight*Storage、postprocessArtifact、
  cleanupOwnedRemotePath、requestConfirmation)均已在 CORE 契约与 registry 登记;
  catalog `trace-presets`@1.0.0(6 preset,attachmentPanorama 带 buffer 资源警告)与
  `attachment-debug-profile`@1.0.0(9 参数,snapshot/readback/restore 规则)已入
  INTEGRATION-PROFILES.lock 0.4.0。
- **核心缺口 = provenance**:hitrace/bytrace 在仓内只有散文级说明(integration
  profile "Trace tools" 节),**没有任何版本化 probe/golden registry、exact argv、
  成败 marker、raw ftrace 形态登记**;hardware-matrix 唯一 M0B observed 行明确
  "无 Trace capability 事实";INTEGRATION-PROFILES fixtures 仅 HDC 五族。对比先例:
  HDC 走了 CHG-2026-005(parser golden)+ CHG-2026-015(readonly probe registry)。
  执行者不得自行发明 argv/marker/fake fixture 后让自己的测试通过(CHG-008 r1 教训
  同族)。

## What changes(分期;本 change 首 PR 只 proposal + design,零实现、零真机、零 evidence)

认领 `REQ-TRACE-001…009` 的 macOS/DAYU200 面(9 AC,逐项 ownership 见
verification.md),三任务分期:

- **TASK-TR-001 — trace 工具 provenance 登记(integration 面,device-gated)**:
  在 DAYU200 真机受控采集 hitrace/bytrace 的存在/help/tag-list/最小 capture 输出
  (人工执行模型,M0B/CHG-008 harness 复用),登记版本化 trace probe/golden registry
  (exact argv、help family、成败 marker 非退出码、raw ftrace 头形态、逐文件
  SHA-256 hash closure),bump OPENHARMONY-TOOLS 与 lock(先例 CHG-2026-015)。
- **TASK-TR-002 — host contract 面(零设备、零 provenance 依赖)**:typed trace
  workflow(capability 受限配置、参数 snapshot/set-readback/restore、隔离接收/
  partial、honest progress、artifact completeness、reboot→binding 恢复),认领
  7 条 contract AC(`AC-TRACE-002/003/004/005/006/008/009-01`);只消费已登记的两个
  catalog,不实现真实 adapter 解析。
- **TASK-TR-003 — adapter golden 面(blocked 于 TR-001)**:hitrace/bytrace help
  family 识别与 adapter 选择、ftrace header 保留过滤,against TR-001 登记的 golden
  fixture,认领 2 条 parserGolden AC(`AC-TRACE-001/007-01`)。

## r2 remediation amendment(2026-07-21 candidate)

PR #270 合入的 TASK-TR-002 host contracts(`40cce74ec285a0049364ded00be97fbef1cac9b0`)
在后续 adversarial review 中发现四个 fail-closed 缺口。TASK-TR-002 的 `done` 历史
保持不改写；r2 新增独立 `TASK-TR-002R` 修复并重新验证受影响面：

- reboot capture gate 必须把预期 target、pre-reboot binding revision 和被选 rebind
  candidate 与实际 durable binding receipt 精确关联；revision 必须恰好递增，capture
  authorization 必须携带新的 `DeviceBindingReference`，供后续 device step 使用；
- receive workflow 必须使用 `artifacts/partial/*.part`，并消费
  `SessionArtifactStore.publish` 实际返回的 `PublishedArtifact`。真实原子发布成功前，
  workflow 不得构造 `cleanupOwnedRemotePath`；仅改变内存状态不构成发布 receipt；
- `attachment-debug-profile` catalog membership 只表示候选参数集合，不能替代
  `availability: per-device-probe-required`。任何参数 mutation authorization 前必须有
  与当前 durable binding/参数名匹配的 typed per-device capability evidence；persistent
  change 还须由该 evidence 明确允许；
- reliable byte total 必须通过受 `TraceAdapterCapabilities.reliableByteTotalAvailable`
  gate 的 factory/receipt 产生。capability=false 时，即使 caller 提供 total bytes，
  progress 仍须为 indeterminate。

r2 不改变 Core Requirement、AC、schema、catalog 或 storage contract；它只收紧 macOS
host implementation，使其符合既有 `REQ-TRACE-003/004/005/006/008`。本 amendment
合入只批准 remediation scope；`TASK-TR-002R` 仍须独立 readiness PR 后才可实施。

## Out of scope / Non-goals

- 不修改任何 Core `REQ-TRACE-*`/AC/contract/schema/WorkflowStep kind(零 Core 变更;
  `setParameter` 与 catalog 的绑定收紧在 trace workflow 层实现,见 design §3);
- 内嵌 SmartPerf/Trace Streamer viewer(backlog)、新固件族/厂商工具(roadmap:
  "each new firmware family is separate scope")、Windows/Linux 端口;
- 首 PR 不实现 adapter、不执行真机、不产生 evidence。

## 安全与执行原则

- 真机采集由人类维护者按 runbook 亲手执行(M0B/CHG-008/RF 先例),Agent 零设备
  命令;trace 采集非 destructive,但 `setParameter` 属 deviceMutation——须
  requestConfirmation + readback + 结束恢复(REQ-TRACE-004);
- 设备序列号/用户路径字节不入仓(redaction 工具链复用);
- adapter 未经 TR-001 登记前,任何实现不得宣称兼容性或依据散文说明固定 argv。

## Approval and flow

V2 治理:本 propose PR 合入仅登记提案;批准须独立 approval-only PR;三任务各自
独立 readiness/实现/done PR。TR-002 可在 approve + readiness 后立即执行(零设备);
TR-001 另需具名设备窗口;TR-003 待 TR-001 done。trace capability 为 release
optional 且 `requires: []`,本 change 不影响 required capability 集与依赖闭合。

## Approval

- r1 proposal 经 PR #249 合入 main(squash `90f877d`,status:proposed)。
- 正式批准:2026-07-21 由本 approval-only PR(先例 #55/#89/#171/#195/#226)将本
  change 置为 `approved`;批准由维护者 review/merge 本 PR 构成。merge 即批准:
  - **三任务分期 scope 与边界**:TASK-TR-001(hitrace/bytrace provenance 登记,
    device-gated,CHG-2026-015/005 形态)、TASK-TR-002(host contract 面,认领
    7 条 contract AC,零设备零 provenance 依赖)、TASK-TR-003(adapter golden 面,
    认领 2 条 parserGolden AC,blocked 于 TR-001)的 objective/scope/allowed-paths;
  - **design 约束**:§0 候选命令面的"TR-001 登记前不得实现 adapter/不得据散文固定
    argv"、§3 参数 mutation 绑定 attachment-debug-profile catalog 的 workflow 层
    收紧(零 Core 变更)、§4 provenance 登记形态(exact argv/成败 marker 非退出码/
    hash closure/redacted manifests);
  - **认领面**:`REQ-TRACE-001…009` 的 9 条 canonical AC + change-local
    `TRACE-PROV-001`;trace capability 保持 release optional、requires:[]。
- 本批准不产生任务执行:三任务保持 `blocked`,各须独立 readiness PR 转 `ready`;
  TR-001 另需具名设备窗口 + 人工执行模型;TR-002 在 readiness 后即可 host-only
  执行。本批准不构成任何固件族/设备兼容性或支持声明;fixture/fake 永不冒充真机
  形态。

## r2 approval boundary

- r2 只起草 `TASK-TR-002R` 的 remediation scope、design 与 verification gates；
  维护者 review/merge 本 amendment 后才构成 scope 批准。
- scope 批准不等于 task ready。readiness 必须另行钉住 main commit、三份待改 source
  blob、storage publication seam、测试基线和 allowed-path overlap。
- remediation implementation+evidence、`ready→done` 与 change `verified` 分别使用
  独立 PR；任何一步都不得回写或删除 TASK-TR-002 的历史 evidence。

## Archive relocation scope (r3; D1)

本 revision 只为 verified change 的归档建立封闭、可复核的路径迁移例外。它不重开
TASK-TR-001/002/002R/003，不改变 9 条 canonical Core AC、5 条 change-local
evidence、Trace adapter 的 family/capability/authority 结论，也不授予新的
device/HDC/network/mutation authority。只有本 D1 revision 经独立其他会话 AI
premerge review 并由维护者 review/merge 进入受保护 `main` 后，后续独立 archive PR
才可开工。

- 固定归档目标为
  `openspec/changes/archive/2026-07-23-chg-2026-021-trace-adapter-capture/`；archive
  PR 必须原子完成目录移动和 proposal `verified→archived`，不得把状态翻转留给另一 PR。
- 当前目录外精确路径扫描有三类命中：
  1. living trace registry 中 3 个 `provenance.redactedManifests`；
  2. `openspec/planning/agent-failure-patterns.md` 中 5 个 Markdown link target；
  3. CHG-2026-029 `tasks.md` 中 6 个 historical `path` pin 与 1 条 dated historical
     note。
  第 3 类记录的是当时 base 上的 path+blob 事实，禁止由本 archive PR 改写。只要
  CHG-2026-029 仍是 active change 且这些 carrier 未由其自身独立批准的 revision
  解除，本 change 的 archive PR 就保持 blocked；CHG-2026-029 已归档后，其中的
  archive-local 历史字节可原样保留。
- 唯一获准的生产语义字段变化，是 living
  `openspec/integrations/openharmony/trace-probes/1.0.0/registry.yaml` 中上述 3 个
  manifest path 从 active 根精确迁移到固定 archive 根。registry 的其余字段、
  `resources.json`、7 个 resource bytes/hash/size、profile/registry version、
  tool/device tuple、family、argv、effect、precondition、judgement、authority、
  adoption boundary、operator/capture window 与 `acceptedBy` 必须保持不变。
- 该三处替换的确定性候选闭包为：registry size
  `15511→15568` bytes、SHA-256
  `0c093f98b57706b3723a68ae7552bef0db0731a675fb6cc023f69bbe21d6e566`
  → `9d2a390b84092f1d78d86c10bf182884bc3a2ef8b3cdc3d35ed8e7e2b087b613`。
  archive PR 可以且仅可以把新 registry hash 重钉到当前 3 个 living consumer：
  OpenHarmony `profile.md`、`INTEGRATION-PROFILES.lock.yaml` 与
  `TraceProbeAdapterProfile.registrySHA256`。若开工时 consumer 集或候选 hash
  漂移，立即停止并先修订本 D1 scope。
- 5 个手册链接只允许把 target 改到固定 archive 根；链接所支持的 Fact/Inference、
  完整 OID、taxonomy、字段与结论不得变化。若 CHG-2026-029 尚未归档，则只有它自身
  独立批准的 revision 明确允许该 living handbook 迁移后，本 archive PR 才可修改。
- 不 bump `OPENHARMONY-TOOLS@0.4.0`、`OPENHARMONY-TRACE-PROBES@1.0.0` 或
  `INTEGRATION-PROFILES-0.5.0`，因为 parser family、adapter mapping、fixture/
  resource bytes 与 capability judgement 均不变。若归档需要其中任一语义变化，
  本例外失效，须另走 approved integration change/version bump。
- 既有 evidence/run、tasks、design、verification、acceptance-cases 与其中的旧
  OID/hash/path 结论保持冻结；除 proposal 的 archive 状态行外，不得为了匹配新
  living path/hash 而改写 archive-local 历史。`openspec/specs/**`、canonical
  acceptance registry、baseline、traceability、platform profile 与其他产品源码/
  测试均为零 diff。
- 实际目录迁移、3 个 production provenance path、3 个 living hash consumer 和
  5 个 living handbook link 必须在同一独立 archive PR 原子完成。缺任一 closure、
  新增目录外 active 引用、normalized comparison 出现列举外差异或隐私扫描命中时
  fail closed。

## Archive relocation scope correction (r4; D1)

r3 合入后，CHG-2026-029 的独立 r5 remediation implementation PR #413（merge
`99dbacd2923ed40b86dbff9f69ef259e16c9fd94`）为 AF-014 增加了一条指向
`TASK-TR-002R/run.md` 的 living handbook link。该新增 active reference 触发 r3 的
fail-closed 条款；本 revision 只修订这个确定性计数与 target 闭包，不授权 archive
实现，也不改变 r3 的 registry、hash consumer、历史 carrier 或产品语义边界。

- 复核基线为 protected `main`
  `ac0cfaa2091a4ac2b14bcb0308f8c98388a98d77`（#418 merge）；#418 已由维护者
  APPROVED 并把 CHG-2026-029 移入 archive，满足 r3 的前置条件。其父级 #419
  `99ba8aa4b04018918daad2fc8830009c1030f6da` 只修改 Agent PR/allowed-path guard
  与 CHG-2026-030 evidence，和本 closure 零路径交集。
- `openspec/planning/agent-failure-patterns.md` 的 current blob 为
  `4ef0268dd72d22734f704e86375f0114602e5452`；目录外 living handbook closure
  现为 6 个 link target：2 个 `tasks.md`（AF-008/AF-014）之外另有 AF-018 的
  `tasks.md`、1 个 `design.md`、TASK-TR-001 `run.md` 与 TASK-TR-002R `run.md`。
  archive PR 只允许把这 6 个 target 的 active 根替换为 r3 固定 archive 根，
  link text、anchor、Fact/Inference、完整 OID、taxonomy 与其他字节保持不变。
- r3 文本中的“5 个 Markdown/link target/living handbook link”均由本 r4
  **仅在计数与 target 集合上**取代为 6；r3 的 3 个 registry path、3 个 living
  hash consumer、registry `15511→15568` bytes 与
  `0c093f98b57706b3723a68ae7552bef0db0731a675fb6cc023f69bbe21d6e566`
  → `9d2a390b84092f1d78d86c10bf182884bc3a2ef8b3cdc3d35ed8e7e2b087b613`
  候选闭包实测无漂移。
- CHG-2026-029 archive 内全部旧 active-root path+blob 与相对 link bytes 继续作为
  historical evidence 原样保留，不计入 living closure，也不得由 CHG-2026-021
  archive PR 改写。除本 r4 列明的第 6 个 link 外再出现新 active consumer/reference，
  仍须停止并先走新的 D1 scope revision。

## Verification closure(2026-07-23)

依 `verification.md` Gate 于 protected `main`
`145d46384251e535a563aa94a142d83860f2a710` 逐项复核。本 PR 是 D0
状态推进，只包含状态、evidence 引用和 verification/traceability 账本更新，零实现
夹带；`verified` 结论仅在维护者 review/merge 本 PR 后生效。

- **批准与任务链**：r1 approval #253 merge
  `684c42c92bf093c4c1e8d5844d2ad571c844c1ba`、r2 amendment #276 merge
  `6e85a784579809b0b79a95bb117d48033892fdf4` 均为当前 base 的祖先。四 task
  全部有 merged implementation/evidence + 独立 done PR：
  - TASK-TR-001：#282 merge
    `171a269d981b996f4a65c3388d56c7acecc6239e`，done #286 merge
    `54cc94487b42a6918217ba0f8929c0c1f60808ff`；
  - TASK-TR-002：#270 merge
    `cec2cc20c995471602cdd056ec5d9a2460b48ecc`，done #271 merge
    `c29d71705b628591711236fa9eab1e2715f446f8`；
  - TASK-TR-002R：#278 merge
    `4bdad2f037cd62c76dbc483f0cfb4a35ae3af539`，done #279 merge
    `67f46093c3a2a2389f000e3066b1ff004b359cd9`；
  - TASK-TR-003：#358 merge
    `9753b4bbc024b90454c7efc68f28d48a2760c545`，done #367 merge
    `ccc8e5b475066c6485366528b29fefe5e3acf718`。
- **9 条 canonical Core AC = PASS**：
  `TraceAdapterGoldenTests` 7/0 复现
  `TEST-AC-TRACE-001-01`（exact hitrace eligible、bytrace probe-only、未知 family
  unsupported/raw 可查）与 `TEST-AC-TRACE-007-01`（registered ftrace header
  保留、raw SHA-256 不变、零固定行删除）；`TraceWorkflowContractTests` 18/0
  复现 `TEST-AC-TRACE-002/003/004/005/006/008/009-01`，unsupported tag 未接受、
  parameter capability/readback 不满足、歧义 rebind、receive partial、未知总量和
  exit-0 空 trace 均 fail closed，拒绝分支 capture/device dispatch = 0。
- **`TRACE-PROV-001`(documentReview) = PASS**：`python3 -m unittest
  scripts/trace_capture/test_capture.py scripts/trace_capture/test_registry.py -v`
  为 37/0；`validate_registry.py` 输出 `TEST-TRACE-PROV-001 PASS`
  （7 entries、7 resources、14,939 fixture bytes，registry SHA-256
  `0c093f98b57706b3723a68ae7552bef0db0731a675fb6cc023f69bbe21d6e566`，
  resources SHA-256
  `6b77b020b50921ef419720a434a186aba48c13e7284fa66598d4efd0c4f14879`）。
  Registry 逐命令 exact argv/effect/timeout/非 exit-code marker、help/tag/capture/header
  golden、`.gitattributes` 与 lock/profile adoption boundary 齐备；三份 redacted
  manifest SHA-256 分别为 `82a8a78810c638a2ef4b774def83334db848410c6799eee3be2cacb0aa425d10`、
  `a3ef53ff58a3b7c761caf6f327e92e65794ce1cf23ca9a68d3b49e77f788c3a7`、
  `4916e025f1e564da218a95d5336a96a0dd4fe8a3ab975e2477a5720d8fdbaa1f`，
  host user path/private-key/token scan 0。受控采集操作者、窗口、argv、输出与判定见
  `evidence/runs/TASK-TR-001/run.md`；该记录如实保留 schema-1.1 cleanup gate 偏差、
  对实际 capture 的 size/marker/header 人工复核与 schema-1.2 fail-closed remediation，
  未伪造第二次真机运行。本次 verification 未执行任何设备/HDC 命令。
- **四条 r2 change-local contract = PASS**：
  `TraceWorkflowContractTests` 复现
  `TEST-TRACE-REBIND-GATE-001`（9 个 invalid receipt 阻断、exact +1 revision
  与新 binding reference 保留）、
  `TEST-TRACE-ATOMIC-PUBLISH-001`（`artifacts/partial/*.part`、13 publication
  fault、cleanup authority/dispatch = 0、remote retained）、
  `TEST-TRACE-PARAM-CAPABILITY-001`（缺失/unsupported/permissionDenied/
  needsDeveloperMode/unknown/stale/wrong parameter 均在 mutation 前阻断）与
  `TEST-TRACE-PROGRESS-CAPABILITY-001`（false/zero/drift 均 indeterminate，仅
  matching true-capability receipt 产生 percent）。对应细节见
  `evidence/runs/TASK-TR-002R/run.md`。
- **共同门与回归**：`SessionArtifactStorageContractTests` 60/0；
  `CI=true swift test --package-path Packages/ArkDeckKit` 365 tests/1 个既有
  opt-in manual sleep/wake skip/0 failures；`check-sdd` 0 errors/0 warnings/
  111 acceptance IDs。环境为 macOS 26.5.2 arm64、Apple Swift 6.3.3、Xcode
  26.6/17F113。首次 PATH Python 因无 PyYAML 在 SDD 校验前退出，改用仓库既有
  `/opt/homebrew/anaconda3/bin/python3` 后通过；首次 sandbox 内 Swift manifest
  编译被嵌套 sandbox 拒绝，使用既有受控 sandbox-external Swift 前缀后上述定向/
  全量测试通过；两者均为执行环境偏差，不是产品测试失败。
- **账本与边界**：`openspec/verification/traceability.md` 的
  `REQ-TRACE-001…009` macOS 行按本 change Gate 翻转为 `verified`。这只表示本
  change 对 macOS Trace 的 canonical contract/parserGolden 面闭环；不改变
  `PLATFORM-MACOS` 的 `notStarted` conformance 状态，不构成真实硬件、bytrace capture、
  其他设备/固件/toolchain、兼容性、support 或 release 声明。TASK-TR-001 的既有
  controlledHumanCapture 是 adapter-input provenance，不是 realHardware AC；本次
  Agent device/HDC/network/external-process dispatch = 0（全量回归中的既有本地
  fake/process fixture 仍只属于 host contract）。
