# CHG-2026-048 Design — MU-3 Bootstrap 与真实 E0

> r2 override（2026-07-29）：§3 的 artifact 四文件落盘/`artifact.*`
> 读取 bullet 与 §4 fake-integration 的 `artifacts` 环节不再属于本
> change；该面递延 T14（CHG-2026-049）。
> T11 在本 change 的闭环是 production descriptor-bound dispatch、
> succeeded + durable timeline、restart query 与 drift fail-closed。
> 其余设计不变。

> r3 dependency（2026-07-29）：verification audit 确认现有 production
> binding/facts gate 未闭环；但 PR #804 已批准 CHG-2026-051@r2 独占
> exact-target/model/firmware typed preflight、hardware-evidence V3 与
> receipt projector。本 change 不复制该设计。`TASK-BER-002` 在
> CHG-2026-051 verified/archive 前保持 blocked；之后须经 r4 fresh
> readiness pin current contract，再重放本 change 的 drift/restart AC。

## 1. T09 Bootstrap(`ArkDeckWorkflows/Bootstrap/`)

```swift
public enum BootstrapPhase {  // 封闭八态
  case discoverHostTools, observeHDCServer, enumerateDeviceCandidates,
       waitForPhysicalTrust, observeSelectedDevice, createDurableTarget,
       persistInitialBinding, handedOff
}
public actor DeviceBootstrapMachine { ... }   // E0-only:action 类型 = 观察族子集
```

- 结构性 E0:machine 只接受 `BootstrapObservationAction`(observeTool/
  observeServer/listCandidates/observeDevice 四种),类型面无 mutation
  构造点;admission 层再设负向门(双层)。
- 候选:>1 → `needsSelection([candidateSummary])`(脱敏摘要);=1 自动;
  unauthorized/offline → `waitingForHuman(prompt)`,信任后 resume。
- durable target:`RuntimeTargetStore`(daemon 状态目录
  `targets.json`,原子写 + flock,同 MU-2 ledger 模式):targetID
  (`TGT-<sha 前 12>`)、stablePhysicalIdentitySha256(serial 基,复用
  Core 原语)、bindingRevision、facts snapshot、adoptedAtUTC;重复
  adopt 同 identity → 返回既有 targetID(幂等)。
- binding 持久:journal `bindingCandidate→bindingConfirmed`(复用
  `DeviceBindingJournalAdapter` 语义;bootstrap 专属 session)。
- daemon `target.list`/`target.adopt` 转正 + `doctor` 方法(host tool/
  server/store 健康);CLI `arkdeck doctor|device list|device adopt`
  (AgentClient,零直连)。

## 2. T10 E0 Action Pack(`HDCProviderAction` 扩容)

```swift
case queryProperty(key: HDCAllowlistedProperty)       // 封闭 allowlist 枚举
case captureHilog(HDCHilogCaptureRequest)             // duration/filter/bytes 有界
case captureUIDump(HDCUIDumpRequest)
case captureTrace(HDCTraceCaptureRequest)             // categories/buffer 有界
case receiveOwnedArtifact(HDCOwnedRemoteArtifact)     // provider 生成的 lease
case cleanupOwnedRemotePath(HDCOwnedRemotePath)       // 只认自家路径类型
```

- 每 request 为验证构造(throws init,越界拒绝,默认值内置);
- `HDCOwnedRemotePath` 只能由 provider 铸造(package init,含
  session/job/step 成分,保证唯一且防注入);
- parser 按 MU-2 `HDCCompatibilityProfile` 模式扩:每 action 显式
  outcome 格(parsed/truncated/invalidEncoding/empty/malformed/
  unsupportedVersion);
- artifact 接收:hash 校验 → 登记 → 远端清理或 cleanup debt。

## 3. T11 生产 dispatch 与 walking skeleton

- `TypedProcessPlan.Kind.process` 扩为携带完整 lowering(executable
  descriptor 引用 + 真实 argv + timeout/byte budget)——仍 package-only
  构造,客户端/协议面不可达;
- `DescriptorBoundProcessDispatcher: RuntimeProcessDispatching`
  (ArkDeckWorkflows):plan → `ProcessIdentityBoundRequest` →
  `FoundationProcessExecutor`(既有 O_NOFOLLOW/dev-ino/one-shot gate
  语义)→ receipt;fixture 工具(`ArkDeckFakeHDCFixture` 既有可执行)
  驱动 fake-integration;
- HDC 生产组合:external-first discovery → candidate verifier →
  descriptor(sha256)→ factsPort 生产实现;`arkdeck-agentd` 组装换用
  真 dispatcher(MU-2 的拒绝器仅保留为无配置 fallback);
- artifacts:engine 步骤产物落 job 目录 `artifacts/`(device-facts.json/
  tool-facts.json/binding-snapshot.json/manifest.json),经 daemon
  `artifact.list`/`artifact.read`(元数据 + 有界读)暴露;
- identity gate:observe 的 probe-device verify 将解析出的 stable
  identity 与 durable target 比对,不一致 → conflict fail-closed。

## 4. 测试与硬件分层

- contract:bootstrap 状态机、action pack 边界、parser 矩阵;
- fake-integration:fixture HDC 工具全链(submit→artifacts→restart);
- post-CHG-2026-051 fresh contract:target missing / wrong expected
  revision 均零推进；live identity mismatch 在 typed preflight 后零后续
  operation dispatch；matching binding 的 journal 不含 placeholder；
- realHardware(窗口):BER-HW-001/002,Agent 起草窗口步骤
  (host 自测后交付),维护者亲手执行,evidence-only 补记。

## 5. ADR

`docs/adr/0006-bootstrap-admission.md`:bootstrap 独立 admission、
E0-only 结构约束与"信任提示即人工边界"的持久决策。
