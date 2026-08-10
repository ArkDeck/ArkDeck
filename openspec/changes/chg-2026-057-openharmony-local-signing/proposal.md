---
id: CHG-2026-057-openharmony-local-signing
revision: 1
status: approved # 维护者 review + merge 本 proposal PR 后才生效；合入前 TASK-OHS-001 不开工
class: capability
core_change_level: none
owner: lvye
core_baseline: CORE-3.0.0
platforms: [macos]
---

# OpenHarmony HAP 本地签名进入 typed Runtime

> 恰四类声明：本 change 新增 published operation
> `workspace.sign-openharmony-hap@1`，因此按 `AGENTS.md` 控制平面条款走
> OpenSpec + 维护者 PR review/merge。它复用现有 `workspace` provider、
> `RuntimeJobEngine`、Artifact store、daemon 与 UDS，不新增 provider、设备 profile、
> daemon 或设备执行栈，也不改变 destructive 自动化准入。

## §19 治理循环四问

1. **对应的真实安全风险**：若直接把上游 hapsigner 命令拼进现有 build 或让 Agent
   提供路径/口令，会把私钥口令写进 argv/journal/log，允许调用方选择任意 executable
   或文件，并可能把未验证的输出文件冒充 signed HAP。若改用 `deveco-cli signature
   generate`，还会引入直接枚举 HDC target 和访问账号证书/Provision 服务的第二条设备
   路径。两种做法分别命中 `POL-PRIVACY-001`、`POL-WORKFLOW-001` 与
   `PRODUCT-LOOP.md` §3-7/8/9。
2. **为什么不能直接通过 Runtime 缺陷修复**：仓内没有任何签名 operation、typed step
   或 provider action；新增 published operation 是 `AGENTS.md` 明列必须审批的 Repo-plane
   变化。实现仍全部落在 Swift 产品代码，不新增治理框架。
3. **推进哪个 Golden Journey**：GJ-2 与 GJ-5。今天两者只能消费已经在 ArkDeck 之外
   签好的 HAP；本 change 把「unsigned Artifact → 本地签名 → verified signed Artifact
   lease → debug.hap」闭合为 Runtime 内 typed 路径，移除每轮打开 DevEco 或人工运行
   hapsigner 的步骤。
4. **为什么不会产生后续治理连锁**：本 proposal 合入即批准；只创建一个垂直实现任务
   `TASK-OHS-001`，其实现 PR 同车交付 Catalog、Swift、测试、最小文档、真实签名与适用的
   真机验证、Task done 和 verification 结论。不创建 readiness-only、verified-only 或
   archive-only PR；历史 change 归档继续冻结。

## Why（根因）

ArkDeck 目前只在 `Packages/ArkDeckKit/LaunchAgents/README.md` 说明如何在产品外部准备
OpenHarmony 本地签名：操作者把 keystore/certificate/profile 写入工程
`build-profile.json5`，由 Hvigor 产出 signed HAP，再执行 `artifact import-hap`。这不是
ArkDeck 能力：

- Catalog 没有签名 operation，Agent 无法提交 typed signing Job；
- Runtime 不拥有 unsigned input、签名输出或签名 postflight 的 Artifact lineage；
- LaunchAgent 没有 hapsigner/Java 的绝对路径、摘要、配置状态或漂移诊断；
- hapsigner 的常见命令行示例把 `keyPwd`/`keystorePwd` 放在 argv，现有 dispatcher
  也没有 secret-safe interactive lane；
- 文件名 `*-signed.hap` 和进程 exit 0 都不能证明签名有效；
- 签名后若丢失输入 Artifact 的 target/binding，产物不能被现有 `debug.hap@1`
  安全消费；若错误继承，则可能跨设备复用过期 binding。

上游 `developtools_hapsigner` 的 SDK JAR 已提供 host-only `sign-app` / `verify-app`，并支持
`-pwdInputMode 1` 的交互密码输入。它不需要 DevEco Studio UI，也不访问 HDC。缺的是把这条
host 工具路径纳入 ArkDeck 现有 typed Runtime，而不是再造一个签名脚本或设备控制栈。

## What changes

### 1. 新 published operation

新增 `workspace.sign-openharmony-hap@1`：

- provider：复用 `workspace`；binding：`none`；effect：`hostOnly`；authority：
  `defaultReadOnly`。它只读取 immutable Artifact 与固定签名材料，并写入 Job-owned
  derived Artifact；不修改 workspace 或设备。
- caller 只能提交 `projectRef`、closed `signingPresetRef` 与
  `unsignedHapArtifactLease`。不得提交本地 path、executable、JAR、argv、口令、key alias、
  certificate/profile path、输出 path 或 shell 字符串。
- 新 typed step `signWorkspaceOpenHarmonyHap` 在 workflow-step registry、JSON Schema、
  Swift validator、catalog generator 与生成物中 lockstep 登记；未知/错 kind/错 effect/
  设备 binding 一律生成期或准入期 fail closed。
- required outputs：`signed.hap`（OpenHarmony HAP）与 `signing-report.json`。前者是
  后续 `debug.hap@1` 可消费的 Artifact lease；后者只含非秘密 provenance 与 postflight
  事实。

### 2. macOS 本地签名 preset 与可逆管理

新增 Swift `arkdeck signing install|status|remove`：

- `install` 只接受 canonical absolute Java executable、`hap-sign-tool.jar`、keystore、
  app certificate、signed profile 与 closed key alias/sign algorithm；逐文件拒绝 symlink、
  非 regular file、不安全权限或无效格式，并记录 SHA-256；
- keystore/key password 只从真实 TTY 的无回显 prompt 读取，写入当前登录用户 Keychain；
  CLI 不接受 password flag/environment/stdin pipe，LaunchAgent plist 与安装收据不含 secret；
- 非秘密 preset receipt 位于用户私有 ArkDeck Application Support，目录/文件权限分别
  `0700`/`0600`；`status --json` 只报告路径、摘要、secretPresent 与 drift，不返回 secret；
- `remove` 删除 ArkDeck 的 preset receipt 与对应 Keychain items，但不删除用户原始
  keystore/certificate/profile；无需管理员权限，可逆；
- daemon 启动时从固定用户私有位置读取 preset。缺失、Keychain locked/not found、文件或
  hash 漂移均使 operation `UNAVAILABLE`，不会退回 PATH、DevEco 自动发现或默认口令。

### 3. secret-safe Swift dispatch

- provider 生成完整固定 argv，但永不包含 `-keyPwd`/`-keystorePwd`；签名 invocation 固定
  使用 `-pwdInputMode 1`。
- Swift dispatcher 仅对 typed signing action 建立 PTY，等待 hapsigner 两个 exact、
  bounded prompt，再从 Keychain 取出对应 secret 写入 PTY。未知 prompt、重复 prompt、
  超时、Keychain 失败或输出超预算均终止并 fail closed。
- secret 不进入 `TypedProviderAction`、`TypedProcessPlan` argument summary、WAL、receipt、
  stdout/stderr、Artifact、安装收据或诊断。PTY transcript 在交给通用 receipt 前删除 prompt
  交互片段；任何回显 secret 的上游行为按 privacy failure 拒绝发布。
- executable 仍走 identity-bound spawn；Java 与 JAR 两个文件都在每次 dispatch 前重新
  验证摘要。JAR 是 argv 中唯一固定工具资源，不由请求选择。

### 4. Artifact、postflight 与 recovery

- Runtime 在授权前解析 `unsignedHapArtifactLease`，重新检查文件 size/SHA-256 与 ZIP/HAP
  形态；请求 target ID 必须等于 source Artifact 的 target ID。host-only request 不伪造
  binding revision 或设备 facts。
- 输出先写 provider-owned Job 临时目录；`sign-app` 成功后必须由同一 pinned JAR 执行
  `verify-app`，要求 certificate chain 与 profile readback 均为 non-empty regular file，
  并对 signed HAP 重新计算 size/SHA-256。只有全部 postflight 成立才原子发布
  `signed.hap` 与 `signing-report.json`。
- `signed.hap` 精确继承 source Artifact 的 target ID、binding revision 与 stable identity；
  provenance 同时记录 source Artifact ID/SHA-256、preset ID、Java/JAR/cert/profile/keystore
  SHA-256、输出 SHA-256 与验证结果。口令和私钥 bytes 永不记录。
- input lease、preset identity 或 source binding 漂移时零 dispatch。崩溃/取消后只对
  Job-owned output 做 dedicated readback + `verify-app`；可证明完整则确认 completed，不能
  证明则保持 unknown/failed 并清理临时文件，绝不盲重放签名 invocation，也不影响设备 lane。

### 5. 产品入口与文档

- daemon/CLI/Agent 继续使用现有 UDS 与 `job.submit`/`job.run`；App 的 read-only XPC
  门不增加写入方法。
- `doctor` / `operation.list` / `arkdeck signing status` / `agentd status` 给出 machine-readable
  availability 与漂移原因；锁屏时登录用户 LaunchAgent 可从 Keychain 读取即继续，无权限时
  如实失败，不弹出或伪造人工批准。
- 最小文档覆盖一次性 keystore/profile 准备、preset 安装、unsigned HAP 导入、typed sign
  submit、signed lease 交给 `debug.hap@1`、锁屏运行、日志、撤销与 HarmonyOS 商用签名边界。

## Out of scope

- 不生成 keystore、私钥、certificate 或 Provision profile，不接账号云服务；
- 不调用 `deveco-cli signature generate`，不从 signing lane 执行 HDC 或读取设备 UDID；
- 不允许 Agent 选择 path/argv、安装/删除 signing identity、读取 secret 或管理 capability；
- 不改变 `debug.hap@1`、workspace build、device/profile、E1/E2/destructive policy；
- 不声称 OpenHarmony 本地 profile 可替代 HarmonyOS 商用账号/UDID Provision；
- 不新增 App 写入 XPC 或第二个 daemon/runtime/artifact store；
- Windows/Linux 当前 not started，不做兼容性豁免或支持声明。

## Scope

- Requirements：change-local `OHS-REQ-001`（typed local signing）、
  `OHS-REQ-002`（secret/identity fail closed）、`OHS-REQ-003`（Artifact lineage/recovery）
- Acceptance：`OHS-AC-1..8`，登记于 `verification.md`
- Contracts/schemas：operation Catalog、workflow-step registry/schema、Swift workflow-step
  validator 与 generated catalog；不修改 accepted current specs、安全不变量或全局
  Acceptance registry
- Core baseline bump：不需要。新增 macOS capability，在既有 typed-only、Artifact、privacy、
  identity 与 fail-closed Core 约束内实现；不改变既有 operation 结果。

## Safety, privacy, compatibility and rollback

- 任何 secret 缺失/回显、path/hash/permission 漂移、input binding mismatch、签名/verify
  不一致都零 Artifact publication；调用方确认不能 override。
- operation 是 additive `@1`；现有 Catalog ID/version、daemon UDS、CLI、App XPC、GJ-1..5
  已发布路径不变。
- 卸载 preset 后 operation 保留在 Catalog 但如实 `UNAVAILABLE`；已发布 Artifact 与 durable
  Job 历史保留。代码回滚删除新 operation/step/config入口即可，不修改用户原始签名材料。
- 真实签名通过只证明 host cryptographic path；只有 signed lease 再经
  `debug.hap@1` 在真实设备安装/readback 才能记录 GJ-2 真机结果。

## 强制重复与新任务自检（PRODUCT-LOOP §5/§17）

- Backlog/open PR/最近 30 个合入 PR：无同语义任务；#1251 只交付无头宿主与配置闭合，
  明确把 hapsigner 留在产品边界外。
- Catalog/DeviceProviders/tests：无 sign operation/action/provider lowering；现有
  `workspace.build-openharmony@1` 只产出 build log，`debug.hap@1` 只消费 signed lease。
- 历史 OpenSpec：CHG-2026-049 明确把获取/生成/签名排除在外；CHG-2026-054/055 交付
  workspace/harness，不拥有签名。
- §17 五问：减少每轮人工签名步骤；直接闭合 build→Artifact→debug；没有现有 task/PR
  覆盖；不是状态/证据补全；推进 GJ-2/GJ-5 的 unsigned-build 输入路径。
- 结论：语义重复 = 否；本轮新建产品任务 = 1（`TASK-OHS-001`）。
