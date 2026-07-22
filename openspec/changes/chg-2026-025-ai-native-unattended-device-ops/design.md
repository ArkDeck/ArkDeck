# Design:AI Native 无人值守设备操作模型

> Change:CHG-2026-025-ai-native-unattended-device-ops
> Status:draft(随 propose PR 登记;approval PR merge 后本设计约束生效)

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
| **E2 destructive** | flash/erase/format/unlock/真实 update dispatch | ready 任务 + **standing authorization**(§2) | 是,在授权有效期/次数内 |

E0/E1 的既有约束原样保留:owned-path UUID 隔离与 verified-before-cleanup
(REQ-TRACE-006)、序列号字节不入仓(redaction 工具链)、ownership unknown 即
fail closed(POL-HDC-001/POL-SAFETY-001)。

## §2 standing authorization(E2 授权载体)

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

## §3 执行门校验序列(E2,首个真实设备 Step 前)

1. 定位授权块(main 上存在、未过期、未超次);缺失 → policyBlocked;
2. 逐项比对:model/serial 摘要/binding revision/firmware hash/transport/
   hdc version/provider/step 集合/plan hash,任一不符 → 零 dispatch +
   blocked-attempt 记录;
3. 设备身份读回:向目标设备实际读取身份并与授权 target 比对(机器版"物理目标
   确认");
4. durable 写入 intent(含 authorizationRef)→ dispatch → durable outcome;
5. evidence 落盘:executor(kind=agent, id)、authorizationRef、目标读回、时间、
   恢复路径;schema v3。

失败注入要求:门 2/3 的每个比对分支都必须有 contract test 用真实(非 fake 常量)
不一致输入证伪(TR-002R real-fault 注入先例)。

## §4 evidence schema 3.0.0

- `operator: string`(仅人类)→ `executor: { kind: human|agent, id,
  authorizationRef? }`;`kind=agent` 时 `authorizationRef` 必填(指向 merged PR +
  授权块路径/OID);
- `physicalTargetConfirmation` 保留,agent 场景语义 = pre-dispatch 设备身份读回;
- 其余字段、诚实分类规则(simulation/fake 永不入 realHardware)不变;
- v2 历史记录不迁移;`schemaVersion` 判别并存。

## §5 不变式清单(本 change 明确不动的防线)

- 受保护 main + CODEOWNER review;merge 即批准;凭据分离(Agent 限 `agent/**`);
- POL-AGENT-001:Agent 不得自批规则、范围、Safety、baseline、授权;
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
