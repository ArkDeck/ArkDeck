# CHG-2026-049 Design — MU-4 诊断、HAP 调试与统一 Artifact

实现顺序 **T14 → T12 → T13**:后两者都要往 artifact 面写产物,先把
归宿建好,避免两次改写。

## 1. T14 统一 Artifact(`ArkDeckWorkflows/Artifacts/`)

```swift
public struct RuntimeArtifactMetadata: Codable, Sendable, Equatable {
  let artifactID: String            // ART-<sha256 前 16>
  let jobID: String, sessionID: String, stepID: String
  let name: String                  // catalog 声明的产物名
  let mediaType: String
  let byteCount: Int
  let sha256: String
  let createdAtUTC: String
  let providerID: String
  let sourceOperation: String       // id@version
  let bindingSnapshot: ArtifactBindingSnapshot   // targetID + revision + identity sha
  let privacy: CatalogArtifactPrivacy            // 来自 catalog 声明
  let retention: ArtifactRetention               // class + deadline + pinned
  let status: ArtifactStatus        // published | missing(reason) | truncated(atBytes)
}
```

- **存储**:`<job dir>/artifacts/<artifactID>`,内容寻址命名(ID 由内容
  hash 派生),写入走 temp + fsync + `renameat` + 目录 fsync;**名称永不
  来自调用方**,故 path traversal / symlink 逃逸在构造面即不可表达
  (仍配负向测试钉死)。
- **索引**:`<job dir>/artifacts/index.json`(flock + 原子写),记录全部
  元数据与缺失项;job manifest 引用该索引 digest。
- **访问**:daemon `artifact.list(jobId)` / `artifact.inspect(artifactId)`
  / `artifact.read(artifactId, maxBytes)`(有界,默认 1 MiB)/
  `artifact.export(artifactId, destination)`(仅本地目录,拒覆盖)。
  协议面无路径参数——客户端结构上无法指定存储位置。
- **生命周期**:`ArtifactRetentionSweeper`——GC 跳过 active job 引用与
  `pinned`;`quotaBytes` 逼近阈值时 `preflightHostStorage` 拒绝新采集
  (**拒新不毁旧**);`CleanupDebtLedger` 记录远端清理欠账供 reconcile。
- **redaction**:发布前对文本类 artifact 走
  `ArtifactRedactionPolicy`(token/credential/`<HOME>` 路径),privacy
  `sensitive` 者额外标记且 `read`/`export` 需显式 `--allow-sensitive`。
- **补齐 MU-3 递延**:引擎在 verify 成功后按 catalog 的 `artifacts` 声明
  发布产物;`observe.device@1` 的 device-facts/tool-facts/
  binding-snapshot/manifest 四项由此真正落盘。

## 2. T12 `capture.diagnostics@1`

- 引擎按 catalog steps 执行;**optional 步骤失败不终止 job**,而是登记
  `ArtifactStatus.missing(reason)` 并继续;
- `capture-summary.json` 汇总每个声明产物的最终状态,job 结果据此判定:
  required 全在 → succeeded;required 缺失 → failed;仅 optional 缺失 →
  succeeded **但 summary 逐项标注**(测试钉死:不得出现"整体成功"却
  隐去缺项的形态);
- cancel:步骤边界检查取消 → 停止未启动的采集、收取已完成 artifact →
  cancelled;
- 预算:`totalArtifactByteBudget` 在发布前累计核对,超限则按声明顺序
  截断并标 `truncated(atBytes)`,或(required 项超限)failed;
- 远端:trace 走 provider 铸造的 owned path,receive 后 cleanup;
  cleanup 失败 → `CleanupDebtLedger`。

## 3. T13 E1 Action Pack 与 `debug.hap@1`

新增 `HDCProviderAction` case(全部 typed,零路径/argv 入参):

```swift
case sendArtifactToStaging(HDCStagedArtifact)      // provider 铸造 staging path
case installPackage(HDCInstallRequest)             // 来自 staging 的 lease
case queryPackageReadback(bundleName: String)
case startAbility(HDCAbilityRef)
case verifyProcessState(HDCAbilityRef)
case stopAbility(HDCAbilityRef)
case uninstallPackage(bundleName: String)
case createPortForward(HDCPortForwardSpec)
case removePortForward(HDCPortForwardSpec)
```

- **成功判定与 dispatch 分离**:`installPackage` 的 verify **只**接受
  "install 输出可解析 + 随后的 `queryPackageReadback` 确认版本存在";
  引擎在编排层把 readback 步骤设为 required,readback 失败即整体失败。
  同理 `startAbility` 依赖 `verifyProcessState`。
  (实测教训:`hdc install` 成功输出无 `[success]` 标记,exit 0 亦不
  可靠——判定一律走 readback。)
- **capability 消耗**:`debug.hap@1` 的 effect 为 deviceMutation,引擎在
  submit 时对整个 job 消耗一次 E1 capability
  (reservation = idempotencyKey),不逐 step 消费;
- **补偿**:`cleanupPolicy` ∈ {uninstall, retain, restorePrevious};
  install 成功而后续失败 → 按策略执行补偿步骤并记录结果;
- **unknown 即停**:任一 mutation 步 unknown → 引擎既有路径进入
  `waitingForRecovery`,后续 mutation 一律不 dispatch(journal 校验器
  本就禁止 unknown 后继续 intent,此处再加编排层显式停止)。

## 4. 测试布局

- `ArkDeckContractTests/RuntimeArtifactContractTests.swift`(T14:元数据、
  安全负向、GC/quota、redaction、observe 四产物端到端)
- `ArkDeckContractTests/CaptureDiagnosticsContractTests.swift`(T12:
  部分成功、cancel、预算、cleanup debt)
- `ArkDeckContractTests/DebugHAPContractTests.swift`(T13:readback-only
  成功判定、capability 负向矩阵、补偿、unknown 停止)
- fixture 扩展:`ArkDeckFakeHDCFixture` 增加 install/readback/start/
  process-state 的可脚本化模式,使 fake 能表达"exit 0 但 readback 空"
  这一关键区分(**替身必须能表达被测代码所做的区分**——MU-3 的
  checkserver 教训)。

## 5. ADR

`docs/adr/0007-artifact-lifecycle.md`:artifact ID/lease 访问、内容寻址
命名、privacy/retention 与"拒新不毁旧"的 quota 策略之持久决策。
