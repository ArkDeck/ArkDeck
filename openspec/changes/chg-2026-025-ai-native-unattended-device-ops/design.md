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

- 迁移:approval 后按 tasks.md 分期;archive 前的无人值守执行依据 approved delta
  overlay 合法进行(实现期有效规格规则);
- 人工执行模型作为**可选路径保留**:人类操作者亲手执行仍产生有效 evidence
  (executor.kind=human),用于 Agent 主机不可达等场景;
- 回滚:revert delta(独立 change),已产出 evidence 保留并如实标注授权依据;
  standing authorization 全部作废即回到纯人工模型。
