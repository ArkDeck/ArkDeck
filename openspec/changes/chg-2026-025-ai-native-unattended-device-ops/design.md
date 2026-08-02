# Design:AI Native 无人值守设备操作模型

> Change:CHG-2026-025-ai-native-unattended-device-ops
> Status:draft(随 propose PR 登记;approval PR merge 后本设计约束生效)
>
> r6 ownership note（2026-07-29）：§4 的 r1 schema shape 已由
> `CHG-2026-051-agent-hardware-evidence` 接管并替换；本 design 继续拥有
> E0/E1/E2 execution、capability、standing authorization 与 human-boundary，
> hardware-evidence current contract/Runtime projection 以 CHG-2026-051 archived
> V3 为准。
>
> r7 authority note（2026-08-01）：§1—§3 的 E2 authority 由单一 standing
> authorization 扩展为 `standingAuthorization | chatConfirmation`。后者是用户监督式
> 交互会话的一次性 authority，不具有 GitHub/签名 provenance；维护者批准本 revision 即
> 接受该 residual risk。它不得用于 CI、后台无人值守、自动重试或 recovery replay。
>
> r8 campaign note（2026-08-02）：在不改变 r7 one-shot bytes 的前提下新增
> `evolutionCampaignConfirmation`。用户一次确认 delegated envelope；r8 最多 8 attempts/
> 4 hours/1 concurrency。未合入候选在隔离、无设备 capability 的固定 target 中运行，
> 每个 candidate identity 经确定性门与独立 AI 对抗审查后成为 attempt 派生 pin；只有
> protected-main broker 可以 preflight/readback/reserve 并执行 closed typed action。
> AI review 不能单独成为 authority，任何 unknown destructive outcome 永久终止 campaign。
>
> r9 default-path note（2026-08-02）：bounded evolution campaign 成为交互式 Agent E2
> 默认入口；standing authorization 继续服务 protected-main 后台执行。r7 chat reference 只保留
> 历史 decoder/Journal/Manifest/export compatibility，不再允许新 reservation、admission 或
> dispatch。Harness workspace policy 自动选择 isolation/review，caller 不再选择 mode。
>
> r10 single-model note（2026-08-02）：删除活跃 Harness execution-mode 类型、snapshot/status
> 字段与 coordinator 分支。workspace policy 直接决定是否需要 isolation；旧 snapshot mode
> 仅是 decoder-only consistency check，迁移后不再写回。task wire 只使用 workspace vocabulary，
> 历史 chat authority 不再提供 public validated creation factory。
>
> r11 autonomous-repair note（2026-08-02）：同一 invocation 在 `safeToReflash` 后自动产生
> 下一份 closed typed strategy、完成 candidate build/test/adversarial review，并由 merged broker
> 取得 fresh reservation 后继续；用户无需逐次确认。unknown/unresolved/unsafe partial、身份或
> admission 漂移、无新 reservation、repair/review 拒绝、success、超时或超次仍永久停止。
>
> r14 GJ-4 verification note（2026-08-03）：broker 只有在所有 mapped partition 的 exact
> prefix hash 回读、正常模式重连、profile 型号/完整 build pin 精确相等后才可确认 Flash；
> `full` 还要求 bounded nonempty HiLog roundtrip 证明 Debug Runtime，`basic` 不采集该诊断。
> attempt 上限提高到 16，其他停止与分权条件不变。

## §0 设计原则

一句话:**把人从执行环里移出去,把人留在批准环里。**

- 批准权不动:唯一信任根仍是受保护 main + 维护者 review;一切授权载体都是
  merged PR,Agent 不得自批(POL-AGENT-001)。
- 执行权下放:授权一旦以机器可核验的形式存在,执行不再需要人在场;无人值守是
  默认形态而非例外。
- 安全由门承载:人手的位置由 fail-closed 执行门补位——校验不过 = 零 dispatch,
  永不降级为"警告后继续"。
- 审计密度不降:每次无人值守执行产出的 evidence 字段只增不减(新增 executor 与
  authorizationRef)。

## §1 执行分级(E0/E1/E2)

| 级别 | 操作面 | 授权载体 | 无人值守 |
| --- | --- | --- | --- |
| **E0 只读** | `list targets`、readonly probe registry 命令面、hilog/hitrace/hidumper 采集到 owned 路径、artifact 拉取、host 侧分析 | approved change 的 ready 任务(现行机制,无新增载体) | 是,随时可执行,无窗口概念 |
| **E1 可逆 mutation** | `setParameter`(snapshot/readback/结束恢复)、send file 到 owned 路径、rebootDevice、启停采集 | ready 任务 + per-device typed capability evidence(TR-002R 门原样保留) | 是 |
| **E2 destructive** | flash/erase/format/unlock/真实 update dispatch | ready 任务 + **standing authorization** 或同会话硬预算 **evolution campaign confirmation**(§2) | standing authorization 可无人值守；evolution campaign 只允许 merged broker 在闭合委托内 continuation |

E0/E1 的既有约束原样保留:owned-path UUID 隔离与 verified-before-cleanup
(REQ-TRACE-006)、序列号字节不入仓(redaction 工具链)、ownership unknown 即
fail closed(POL-HDC-001/POL-SAFETY-001)。

## §2 E2 authority 载体

### §2.1 standing authorization

**形态 = readiness PR 中的机器可读授权块**。本仓库 readiness PR 本就 pin 全套执行
前提(全 OID/全 hash 惯例),standing authorization 只是把这套 pins 收敛成一个
可被执行门逐项校验的结构化块,不新增流程环节:

```yaml
# readiness PR 内,evidence/authorizations/AUTH-<id>.yaml
authorization:
  id: AUTH-2026-025-DAYU200-001
  target:
    model: "DAYU200 (RK3568)"
    serial_sha256: "<digest>"          # 序列号字节不入仓,入 SHA-256 摘要
    binding_revision: <N>              # dispatch 前须与 durable binding 一致
  firmware:
    image_ref: "参考镜像 7.0.0.33"
    image_sha256: "fc7637f3…5280"      # 全 hash,此处示意
  transport: usb
  hdc_version: "3.2.0d"
  provider: RockchipRockUSBFlashProvider
  steps:                               # 精确 typed step 集合
    - kind: flashPartition
      partitions: [<PD-002 mapped 九分区>]
  plan_sha256: "<待执行 typed plan 的规范化 hash>"
  recovery: "CHG-2026-016 Loader wlx 重刷(archived runbook)"
  valid_until: "2026-08-31T00:00:00Z"
  max_runs: 0                          # 0 = 有效期内不限次
```

规则:

- 授权经维护者 merge readiness PR 生效;**Agent 可起草,不得自批**;
- 授权中任何 pinned 内容漂移(镜像 hash、工具版本、binding revision)即整体失效,
  须新 readiness PR 重新授权(与现行 pins 漂移即重查惯例同构);
- 吊销 = 维护者 merge 删除/作废该授权块的 PR;git 历史即授权审计账本;
- 序列号等设备敏感字节按现行 redaction 规则只入摘要。

### §2.2 historical chat confirmation compatibility

r7 chat reference 的 closed bytes、Journal/Manifest/ledger decoder 与 export 必须保持可读，
以免历史真实设备 evidence 因产品升级失真。r9 起它不是可创建的 authority：usage ledger
拒绝新 reservation，Rockchip request/admission/Loader-confirm/dispatch 不再暴露该分支，旧 CLI
fields 返回 usage error。历史 record 不得升级或解释成 campaign，也不得进入 recovery replay。

### §2.3 bounded evolution campaign confirmation

evolution campaign 是交互式 Agent E2 的默认 authority kind，不解释或迁移 §2.2 的历史
one-shot reference。用户
确认前展示的 canonical envelope 至少包含：protected-main base OID、fixed candidate build
target/toolchain、allowed source paths、`maxChangedFiles`/`maxDiffLines`、plan/archive/step-set、
target stable identity 与 binding lineage root、userdata impact、`maxAttempts` 与 `validUntil`。
r14 validator 硬上限：`maxAttempts <= 16`、有效期不超过 4 小时、并发 attempt = 1；更大或
缺失字段整体拒绝，不能静默截断。

#### Candidate / broker 分权

candidate 由 task-owned workspace 的 base + immutable patch 构建。固定 builder 记录 source
tree、diff、allowed-path set、executable 与 toolchain digest；sandbox 拒绝 network、USB、HDC、
RockUSB、raw shell、任意 executable/argv、host path 与 authority bytes。candidate 唯一输出是
现有 Catalog operation 可表示的 typed strategy bundle。protected-main broker 重新 materialize
计划并拒绝以下任一项：非既有 operation/step/actionRef、plan/archive/step-set 漂移、Catalog/
profile/broker/authorization 文件变更、raw surface、目标或预算扩张。

与 patch producer 不同的 read-only adversarial reviewer 读取 immutable diff、构建/测试证据、
materialized plan 与历史 attempt；只有 PASS 且没有 HIGH/CRITICAL issue 才能写入派生 candidate
pin。reviewer 没有 repair、Runtime、device 或 authority port。AI verdict 不是 E2 authority，
只能作为已确认 campaign 的必要且不充分 admission fact。

产品持久化 campaign reference 与 append-only attempt ledger。每个 attempt 有独立 ordinal、
candidate pins、review receipt、Job、Session、usage reservation、stepIntent/outcome 和 terminal
correlation；ordinal 一经 reserve 不退款。reserve 发生在以下 E0/host-only deep preflight
全绿之后：

1. reconcile 已中断 session，并确认没有 unresolved destructive intent/outcomeUnknown；
2. retention/heavy-writer admission 与 finalization headroom 可用；
3. archive 与 published members、candidate/build/test/review pins 校验成功；
4. staging、closed lowering、power/lifecycle prerequisite 与 merged broker identity 有效；
5. fresh target readback 匹配 stable identity，binding revision 只沿 broker 已确认的 campaign
   lineage 单调推进。

只有上一 ordinal 已 durable terminal，且 merged broker 根据完整 intent/outcome/readback 给出
`safeToReflash`，才可进入下一 ordinal。该分类仅允许 destructive intent 前的明确失败，或每个
已发出的 destructive step 都有 confirmed outcome 且专用 readback 证明可重新执行的已知失败；
candidate/reviewer 不能提供或覆盖分类。process timeout/disconnect、outcome 持久化失败、
unresolved intent、identity uncertainty、broker/reviewer crash、取消时已有 destructive intent、
postflight lineage mismatch 与 recovery-required 一律终止 campaign。成功也终止并禁止剩余
额度复用。每次 continuation 重算全部 trusted facts；plan/archive/step-set/stable target/
toolchain/base/allowed-path envelope 漂移使 campaign 整体失效。

campaign 不是 standing authorization，ordinary CI/daemon/scheduler 不能自行 mint 或扩大。
未合入 candidate code 可以在上述 sandbox 中运行并影响 typed strategy，但真实 transport 与
destructive dispatch 永远属于 protected-main broker；candidate 不能替换或动态加载 broker。

#### Autonomous safe-repair loop

同一交互 invocation 消费一次有效 campaign confirmation 后，产品 SHALL 自行推进
`repair → candidate build/test → adversarial review → fresh reservation → broker execute →
durable terminal classification`，直至 success 或 campaign 停止条件成立。第一个 candidate
使用 protected-main 默认策略；仅当前一 attempt 的 durable terminal 被 broker 分类为
`safeToReflash`，repairer 才能接收标准化失败码、ordinal 与至多 8 个既往策略摘要。repairer
运行在 owner-only、read-only、无仓库内容、无 network/device/Runtime/authority port 的目录，
只能返回 closed strategy：`allowedStartingModes` 及 Loader/HDC/read-only 的有界 timeout/poll。
它不得提出或修改 argv、operation、partition、archive、step-set、plan、target、broker 或
authorization。

candidate target SHALL 再次严格解码并回显 proposed strategy；即便源码树无变化，builder 也
必须将 canonical strategy 作为 immutable synthetic diff/test artifact 纳入 candidate digest 与
独立 adversarial review。broker 只能消费与 assertion、candidate、review 完全一致的 strategy，
并保持 Provider 生成的 exact argv 不变。candidate evaluation 次数与 Flash reservation 次数均受
`maxAttempts` 约束；相同 strategy 不得重复。

自动 continuation 必须以本轮新增的 durable reservation 与 terminal correlation 为依据，不能
复用旧 attempt 的 `safeToReflash`。admission/fresh-target fault 导致未创建 reservation 时，campaign
以 `admissionOrTargetDrift` 封口。Loader transition 失败只有在 destructive intent 前，且 merged
broker 现场重新读到同一 durable target 仍处于 registered HDC-normal/Loader mode 时，才可记为
known failure 并自动修复；target/topology 漂移、timeout/disconnect 且无法完成该证明时保持
outcomeUnknown/unsafe，永久停止且不得猜测重试。旧 strategy bytes 缺少 r11 tuning 字段时仅按
固定默认值兼容解码，新的输出必须是完整 closed shape。

## §3 执行门校验序列(E2,首个真实设备 Step 前)

1. 定位并验证 authority：standing authorization 必须来自 main 且未过期/超次；evolution
   campaign 必须由当前会话确认，且 durable ledger/budget/base/allowed-path envelope、candidate
   派生 pins、adversarial review 与前序 terminal correlation 全有效；缺失 → policyBlocked;
2. 逐项比对:model/serial 摘要/binding revision/firmware hash/transport/
   hdc version/provider/step 集合/plan/archive/step-set/target digest，任一不符 → 零 dispatch +
   blocked-attempt 记录;
3. 设备身份读回:向目标设备实际读取身份并与授权 target 比对(机器版"物理目标
   确认");
4. durable 写入 intent(含 authorizationRef)→ dispatch → durable outcome;
5. evidence 落盘:executor(kind=agent, id)、实际 authority kind/reference、目标读回、时间、
   恢复路径;schema v3。campaign 另记 ordinal、candidate/review/broker pins 与 terminal/retry
   disposition；campaign authority 不能伪写 standing authorization provenance。

失败注入要求:门 2/3 的每个比对分支都必须有 contract test 用真实(非 fake 常量)
不一致输入证伪(TR-002R real-fault 注入先例)。

## §4 evidence schema 3.0.0（r6 ownership transfer）

- r1/AIN-002 的 `executor.authorizationRef + physicalTargetConfirmation` draft 作为
  历史 migration input 保留，不再由本 change archive 到 current contract。
- current V3 shape、Runtime trusted-fact projection、actor-neutral target confirmation
  与 effect-aware authority mapping 由 `CHG-2026-051` 独占：
  E0=`defaultReadOnlyPolicy`、E1=`runtimeCapability`、
  E2=`standingAuthorization`。
- schema validity 只记录 provenance，不授予 execution authority；本 change 的 E2
  standing-authorization gate 与 fail-closed 规则不变。
- v2 历史记录不迁移；simulation/fake 永不进入 realHardware。

## §5 不变式清单(本 change 明确不动的防线)

- 受保护 main + CODEOWNER review;merge 即批准;凭据分离(Agent 限 `agent/**`);
- POL-AGENT-001:Agent 不得自批规则、范围、Safety、baseline、授权;
- protected main + CODEOWNER review 仍是 policy/broker/Catalog/profile 的唯一发布信任根；
  AI review 仅能在用户确认的 campaign envelope 中缩小未合入 candidate，不能自行授权;
- POL-SAFETY-001 / POL-TARGET-001 / POL-HDC-001 / POL-WORKFLOW-001 /
  POL-RECOVERY-001 / POL-MODE-001 / POL-ARTIFACT-001 / POL-STORAGE-001 /
  POL-PRIVACY-001 / POL-VERIFY-001 全部原文不动;
- 普通 CI 边界:GitHub Actions 等无授权载体的自动化仍限
  contract/fake/simulated/plan-only;
- evidence 诚实分类与维护者 PR review 把关。

## §6 与既有机制的映射

| 新概念 | 复用的既有机制 |
| --- | --- |
| standing authorization | readiness PR + 全 OID/全 hash pins 惯例 |
| 执行门逐项校验 | RF-002 安全门 + TR-002R 四凭据语义门形态 |
| 恢复路径前提 | CHG-2026-016 已演练的 Loader `wlx` 重刷 runbook |
| 目标读回确认 | M0B 真机发现/授权探测命令面 |
| 敏感字节摘要化 | RF-001/RF-002 脱敏 transcript 先例 |
| blocked-attempt 记录 | #104/#173 先例格式 |

## §7 迁移与回滚

- 迁移:r2 amendment approval 后按 tasks.md 依次完成 AIN-005/006/008/007；只有 AIN-004
  再次独立 readiness、取得 fresh authorization 且可信宿主验收通过后，archive 前的无人
  值守执行才可依据 approved delta overlay 合法进行(实现期有效规格规则);
- 人工执行模型作为**可选路径保留**:人类操作者亲手执行仍产生有效 evidence
  (executor.kind=human),用于 Agent 主机不可达等场景;
- 回滚:revert delta(独立 change),已产出 evidence 保留并如实标注授权依据;
  standing authorization 全部作废即回到纯人工模型。

## §8 r2 threat-model correction

r1 的纯函数 validator 能证明“输入字段彼此一致”，不能证明“输入事实真实”。现行 CLI
允许调用方提供任意授权文件路径与 `unattended-context.json`，其中包含 prior run count、
binding revision、prerequisite 状态与 identity readback；授权自身的 `approvedBy` 与
`carrier` 也只是普通字符串。该边界允许同一不可信调用方同时制造 grant 与全部验证事实，
不满足 §0 的批准权/执行权分离。

r2 将信任边界移动到 **TrustedExecutionHost**：AI/CLI 只表达 typed intent 与
`authorizationId`，所有 grant bytes、Git provenance、usage、binding、tool/device facts
均由执行宿主拥有的 port 读取。调用方 JSON、环境变量、工作树文件、CLI flag 和 imported
Manifest 都不是授权或事实来源。

## §9 MaintainerMergedAuthorizationResolver

执行宿主在每次 E2 admission 时 SHALL：

1. fresh fetch `origin/main`，取得完整 main commit OID；网络不可用时只可使用宿主自有、
   未过 freshness deadline 且已验证的缓存 attestation，否则 fail closed；
2. 只按 `authorizationId` 在该 commit 的固定 authorization registry 中解引用 bytes，拒绝
   caller path、工作树覆盖、symlink 与历史 commit 回退；
3. 核对授权文件 blob OID、承载 commit、PR number、GitHub `mergedAt/mergedBy/reviews`，且
   approving reviewer 为 CODEOWNER `lvye`；任何字段只写在 JSON 内但无 GitHub 事实支撑
   均无效；
4. 产生不可由调用方构造的 `VerifiedAuthorizationGrant` capability，包含 full commit/blob
   OID、PR、scope pins、validity 与 usage ceiling；gate 只接受该 capability，不再接受裸
   `RockchipStandingAuthorization` 作为 dispatch authority。

## §10 Trusted execution facts and usage

- binding revision 来自 `DeviceBindingJournalAdapter` 返回的 durable receipt；CLI 的 location
  或 revision 只可作为 selector，不能作为确认事实；
- tool identity 由 descriptor-bound process port 在 launch 前重新 hash；firmware/plan hash
  由产品 validator 现场生成；prerequisite 来自 typed probe receipt；identity readback 必须
  在首个真实 Step 前由目标设备实际 probe，绑定 observation sequence/deadline；
- `AuthorizationUsageLedger` 是 host-wide single-writer durable store。E2 admission 在首个
  intent 前原子写 `reserved`；reservation 一经 durable 即消耗一次额度，crash 不退款，
  防止两个并发 Job 都观察到 `priorRunCount=0`；terminal outcome 只关闭 reservation，不
  改写消费事实；
- usage、binding、readback 或 grant 任一无法关联到同一 Job/plan/target 时 dispatch=0。

## §11 Product-owned dispatch

`authorizedForUnattendedAgentExecution` 不再返回供外部 shell 使用的 command strings，而是
返回 package-owned one-shot dispatch capability。执行链固定为：

```text
typed request
  → verified grant + trusted facts + usage reservation
  → Session/Job + durable stepIntent(authorizationRef)
  → descriptor-bound fixed argv dispatch
  → raw stdout/stderr Artifact + semantic result
  → durable stepOutcome
  → postflight / waitingForRecovery / terminal manifest
```

`RockchipHumanHandoff` 只保留为只读诊断/人工 fallback，不得作为 autonomous execute 的
executor 输入。真实执行宿主必须是唯一 device/tool capability owner；若 Agent 进程仍可绕过
宿主直接调用 HDC/rkdeveloptool 或打开相同 USB capability，该环境不得标记为
`zeroTouchVerified`，AIN-004 保持 blocked。

## §12 r2 contract model

- `executionAuthority` 新增 `authorizedAgent`；只能由 TrustedExecutionHost 在
  `VerifiedAuthorizationGrant` 存在时 mint。`standardAgent` 与 ordinary CI 的 destructive
  execution 仍为结构性禁止；
- destructive `stepIntent` 必须携带可解引用的 `authorizationRef`（authorization ID、main
  commit OID、blob OID、PR）；outcome/manifest 必须引用同一 intent；
- confirmation actor 从固定字符串 `user` 升级为 typed actor：`interactiveUser` 或
  `authorizedAgent`；后者必须引用相同 grant；
- 新增 host-wide authorization usage record，定义 reservation ordinal、ceiling、Job/plan/
  target binding 与 terminal correlation；
- v1 manifest/journal 与历史 evidence 不迁移；只有新版本可表达 authorized-agent real
  destructive success。

## §13 Rockchip persistence/tool identity correction

AIN-007 readiness 合入后、实现开始前的 code-to-contract recheck 发现两项相互独立的
fail-closed 阻断：

1. locked Manifest v2 继续引用 current Manifest 的 HDC-only toolchain definition，只允许
   `kind=hdc|none`。Rockchip execute 若写 `hdc` 会制造虚假工具链证据，若写 `none` 又违反
   non-simulated contract；因此不能产生诚实且可通过 validator 的 terminal Manifest。
2. AIN-006 在 `RockchipTrustedToolDeviceFact` 中验证了 descriptor identity，但
   `RockchipTrustedAuthorizationFacts` 没有保留该 receipt。执行器只能知道 SHA-256 pin，无法
   按 §10/§11 将每次 identity-bound spawn receipt 与同一次 admission 的 device/inode/size/
   mode/hash 逐项再关联。

修正采用只增不改的 contract 版本：Manifest/Journal `2.1.0` 保留 v1/v2 历史 bytes 与语义，
只为 authorized Rockchip execution 增加诚实的 descriptor-bound toolchain shape；Journal
2.1 沿用 v2 的 authorization/usage/intent 相关性，但与 Manifest 维持同版本 Session 不变量。
Rockchip toolchain Manifest 不持久化本机绝对路径或 bookmark bytes，只记录 profile/version、
SHA-256 与 descriptor identity 数字字段。AIN-006 final facts 保留内部、不可序列化的
`ProcessExecutableIdentityReceipt`；它仍不是 authority，只有同一个 one-shot admission 与
每次 Process port 实际返回的 receipt 完全一致时，AIN-007 才可继续。

这项修正不新增 command、effect、设备能力或授权来源，也不放宽 v1/v2；实现前置任务与精确
scope 见 TASK-AIN-008。AIN-007 的 #310 readiness 因只读输入不足而失效，须在 AIN-008 done
后基于新的 main/OID 独立重做 readiness。

## §14 r3 gap analysis：规则允许，产品入口仍拒绝

r3 以远端 `main` `d42c002609177e47ef95320cb5bdc0a42f0b510e` 为盘点基线。
`workflow-step-registry.yaml` 已登记 UI Dump、Trace、HiLog、HAP、文件传输、应用生命
周期、端口转发和 reboot 所需的大多数 typed step，且 r2 已证明可信执行宿主可以持有
grant、facts、journal、usage 与真实 tool/device capability。然而现行入口仍有四类断层：

1. `scripts/m0b_capture/capture.py`、`scripts/trace_capture/capture.py` 与
   `scripts/ud_capture/capture.py` 在代码层声明 `Human-operated`，新 evidence 固定写成
   `controlledHumanCapture`；脚本的安全 allowlist 无法被产品 Job/Session 复用。
2. `TraceWorkflowContracts` 与 UI Dump harness 已有 plan/gate/fixture 逻辑，但缺少从
   durable binding 到真实 HDC typed dispatch、Artifact publication、compensation 和
   terminal manifest 的通用 product executor。
3. `HDCDeviceCommand` 只 materialize 少量操作；HAP install、应用启停、file send/recv、
   HiLog 和 HiDumper/Trace lowering 没有完整的 Agent-facing production composition。
4. CLI 只有 Rockchip `flash --authorization-id` 的 Agent 路径；没有通用 device-operation
   request/status/cancel/reconcile/result surface，也没有 `.so` deployment profile。

r3 不把上述 Python harness 直接改为“允许 Agent 运行”。正确迁移是保留其 exact argv、
parser、redaction 与 negative fixtures，把 effect dispatch 移入与 r2 同级的 product-owned
executor；历史 harness 退为 fixture/golden 生成与兼容复验工具。

## §15 Agent device-operation control plane

产品新增本地 machine-readable control plane，最小命令集合：

```text
submit(request) -> jobId
status(jobId) -> state/stage/blocker/artifacts
cancel(jobId) -> acceptedAtSafeBoundary | rejected
reconcile(jobId) -> state/blocker
result(jobId) -> terminal manifest/evidence references
```

`request` 只表达 intent，不表达 authority 或事实：

- `changeId/taskId`、operation/profile/configuration ID + digest、executionMode；
- durable target selector（仅定位，最终 binding 由宿主读取）；
- artifact lease/profile/configuration references 与期望输出；
- 可选 `authorizationId`（只作 E2 grant lookup key）。

以下字段结构性禁止：executable、argv、shell/command string、任意远端路径、authorization
bytes/path/carrier、binding revision 事实、identity readback、prior usage、prerequisite
verdict、effect override、outcome/success override、Session root。请求 schema 严格
`additionalProperties:false`；未知 operation/profile 一律按 destructive/unsupported
拒绝。

control plane 默认只绑定本机产品进程和同一用户的受控 IPC/CLI；不新增网络监听、远程
RPC 或自动上传。executor/peer identity 由可信宿主从受控 transport/进程上下文 mint，
request 不接受 caller-supplied `submittedBy/executor` 作为审计事实。Agent 身份用于审计
与 policy lookup，不因“来自 Agent”自动获得 E1/E2 权限。

## §16 Human-boundary registry

所有仍需人的动作必须属于封闭 registry，并返回结构化 blocker：

```text
HumanActionRequired
  category:
    physicalConnection | deviceTrustPrompt | osPermission |
    credentialProvisioning | ambiguousIdentity |
    impactApproval | outcomeUnknownDecision | governanceApproval
  reasonCode
  affectedJob/step
  minimumAction
  prohibitedAutomation
  resumeProbe
  expiresAt?
```

允许的人类边界：

- 插拔 USB/UART、物理按键/跳线/断电、设备解锁与首次信任弹窗；
- OS picker、Sandbox/entitlement、driver/helper、udev/group/ACL、Keychain、签名/公证
  凭据等外部配置；ArkDeck 只诊断和给最小指导，不提权或自动修改系统；
- TCP/UART 断线、多个 USB 候选或 Core 证据不足时的 identity diff 确认；
- external/unknown HDC server lifecycle 的 per-generation impact confirmation，以及
  persistent Debug parameter、全局 buffer、HAP uninstall/clear-data/downgrade 等数据影响决策；
- `outcomeUnknown`、不可自动恢复或需要物理 recovery 时的风险决策；
- D1/D2 review、E1 capability evidence 接受、E2 standing authorization 创建/修改/吊销。

不在 registry 的“请人工运行命令/点击继续/等待设备窗口”视为缺陷。人完成动作后，Agent
只能调用声明的 `resumeProbe` 重新获取事实；用户文本不能直接把 Job 标为成功或提升
authority。

## §17 E0/E1 trusted execution

### E0

E0 admission 需要 approved change + ready task、registered operation、fresh durable binding
和 tool/server ownership 事实。无需 D2 设备窗口；可信宿主可自动完成：

- HDC/server/device observation 与 capability/help probe；
- HiDumper window inventory 和不写设备文件的 stdout Recipe；
- HiLog host stream 与 rotation；
- hitrace/bytrace help/tag/capability probe；
- receive owned Artifact、hash、validate、redact、derive 与分析。

E0 不得顺带执行 cleanup、parameter set、device-side persist、install、send、reboot 或
server lifecycle mutation；计划含这些 step 时按实际最低 effect 升级，不能拆名降级。
E0 Agent evidence 使用 CHG-2026-051 current V3 的
`defaultReadOnlyPolicy` authority reference；该 reference 由宿主从 reviewed
execution policy/catalog fact 写入，caller 不提供也不能伪造。

### E1

E1 admission 另需维护者已接受的 per-device typed capability evidence，至少 pin：

- target identity/binding family、transport、tool/profile/version/hash；
- operation IDs、允许的目标 namespace（例如 Job-owned remote root 或 bundle ID）；
- 最大数据影响、时长、并发/次数、validity、compensation/rollback 与 resume probe；
- 需要的 privilege/developer-mode/root 状态及其 fresh probe；
- 禁止的 destructive 邻接面。

可信宿主从受保护 main/accepted registry 与 durable device facts 解引用该 capability；
caller 不能提供 capability bytes 或自报前提。每个 E1 step 仍遵守 intent-before-effect、
semantic outcome、binding revision、device lane、storage claim、cancel/safe boundary、
compensation 和 crash reconcile。任一 capability/pin/fact 漂移即 dispatch=0。
E1 Agent evidence 使用 CHG-2026-051 current V3 的 `runtimeCapability` authority
reference，指向该 per-device capability 的 full main/blob OID 与接受载体；E2 使用
`standingAuthorization`。三类 authority reference 都由宿主解析并写入，不能由
request 自报。

E1 默认覆盖 owned remote capture/cleanup、temporary parameter set/restore、capture
start/stop、保留数据的 HAP install/replace、应用启停、端口转发、reboot 与 Job-owned
staging send。HAP uninstall/clear-data/downgrade、persistent parameter/global buffer 或
其他不可逆 data impact 必须按 profile 提升为 E2，或在现行 Core 要求时返回
`impactApproval`；不得用一次宽泛 E1 capability 静默覆盖。若实际影响超过 profile
（例如 data wipe、system partition overwrite、无 rollback native library 替换），Core
effect 提升到 E2。

## §18 HAP 与 `.so` deployment profile

HAP/SO 的编译发生在独立、已批准的源码构建任务；ArkDeck 不接受 build shell。control
plane 只消费 HostStorage/Artifact subsystem 已建立的 file lease、size/hash 与 provenance，
因此 Agent 可完成“改代码/构建 → 交付 leased Artifact → ArkDeck 部署/采集/复验”，同时
不把设备产品变成任意命令壳。

### HAP

Agent HAP deployment 使用 `installPackage`，输入只能是已取得 host file lease 的 Artifact。
preflight 固定 bundle name、version、signing identity/hash、target binding、install mode、
data impact 与已登记 output family；执行后必须读取 package/version/signing state 并与
期待值比对。卸载、覆盖安装、清数据和 downgrade 是不同 operation/profile，不能由一个
布尔 flag 静默改变影响。无法证明保留数据的 uninstall/replace、clear-data 与 downgrade
必须提升为 E2 或返回 `impactApproval`。

### Native library

`.so` 不允许退化为 `hdc file send <caller path> <caller path>`。profile 必须声明：

- ABI、ELF build ID/hash、目标 bundle/process、目标 namespace 与 canonical path；
- 所有者、mode、SELinux/平台约束及所需 privilege；
- 旧对象 snapshot/hash、staging path、原子 publish 方式；
- loader/linker 验证、目标进程 stop/start 或 Ability restart；
- rollback bytes/步骤、验证和失败后的 hazard 分类。

只向 Job-owned staging path 发送且不激活属于 E1；在可证明的 app-owned writable
namespace 内原子替换、可验证 rollback 也 MAY 为 E1。覆盖 system/vendor、修改只读挂载、
依赖 root/remount、影响 boot/runtime 或无法证明 rollback 的 profile SHALL 为 E2，并使用
standing authorization。未知权限、目标或 publish outcome 必须进入
`waitingForRecovery/outcomeUnknown`，不得盲目重发或把 exit 0 当成功。

## §19 Agent-native debug loop

一个 debug loop 是普通 Job/Session 内的 typed DAG，不是任意脚本：

```text
observe/bind
  → capability probe
  → optional deploy(HAP/.so)
  → start/restart app
  → concurrent bounded HiLog + UI Dump/Trace
  → immutable raw publication
  → host-only symbolization/filter/correlation
  → derived report + proposed next operation
  → optional re-submit through fresh admission
```

每个 effect step 单独写 intent/outcome；并发仍受 per-device mutation lane、HDC server 和
storage coordinator 约束。分析器可以生成下一份 typed request 草案，但不得直接携带
authority、修改 effect、复用过期 readback 或把统计相关性写成设备成功。循环达到预算、
deadline、连续未知结果或同一 blocker 重复阈值时停止并生成可复查结论，不无限重试。

## §20 r3 migration

迁移顺序固定为：

1. 冻结 agent-operation/human-blocker contract 与 effect mapping；
2. 抽取通用 trusted host admission、journal、artifact 与 process lowering；
3. 先接 E0 observation/HiLog，再接 UI Dump、Trace；
4. 接 HAP 与 native-library E1/E2 deployment；
5. 接 control plane 与闭环 orchestration；
6. 真机分别验证 E0、E1、E2，最后修订现有 change 的 human-only task/runbook。

历史 raw/golden/provenance 不改写。任何 capability 在新的 product executor 验证前继续
blocked；不允许以“先把 `Human-operated` 改成 Agent-operated”替代 trusted composition。
