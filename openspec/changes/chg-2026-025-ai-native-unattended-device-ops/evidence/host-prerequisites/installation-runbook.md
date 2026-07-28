# D-1 宿主前置安装 runbook(TASK-AIN-004)

> 定位:本文件是 tasks.md「Readiness pins(r3)」§「r4 的二值前置」第 2 条所要求的
> 「安装步骤与责任人」**仓内载体**,补 r3 D-1 段实测出的空缺(「本 change 全目录
> 零处记载这四项前置由谁、以何步骤安装」)。形态先例 =
> `openspec/governance/host-loop-runbook.md`(只细化操作,不放宽正本)。
>
> 效力边界:本文件**不构成任何设备操作或 dispatch 授权**,也不改变 TASK-AIN-004
> 的 blocked 判定。授权语义正本 = `evidence/authorizations/README.md` 与 tasks.md
> r3 段;装后四项快照**证据**由 r4 独立载体按 r3「r4 的二值前置」第 2 条入仓,
> 本文件只给步骤、责任人、快照命令与失败/回滚注记,不预写任何快照结果。
>
> Implementation base:protected main
> `f065ac90e69ff89c9ebb8817bfb4f9ebb1b0ed7d`；TASK-AIN-BKMK-001 fresh D1
> readiness #710 merge
> `70739c4c483232ff6a5d094d753811114e3b9702` 已为其祖先。消费契约按当前符号
> `RockchipProductToolBookmarkStore`、`RockchipProductExecutionSettings.load()`
> 与 `RockchipDeviceDiscoveryAdapter` 记载，不以历史行号替代源码复核。

## 1. 消费契约总表(源码为准,维护者可逐行核对)

执行宿主 = `arkdeck` CLI(SwiftPM product `arkdeck` → target `ArkDeckCLI`,
`Packages/ArkDeckKit/Package.swift:15`;无 bundle 的普通可执行文件)。调用链:
`arkdeck flash execute --authorization-id …` →
`RockchipFlashExecutionHost()`(`Sources/ArkDeckCLI/ArkDeckCLIMain.swift:116`)→
`RockchipProductionExecutionComposition.make()` →
`RockchipProductExecutionSettings.load()`
(`Sources/ArkDeckWorkflows/RockchipFlashExecutionHost.swift:669–671`,定义
`:739–846`;下文行号省略 `Sources/ArkDeckWorkflows/` 前缀,`Host` =
`RockchipFlashExecutionHost.swift`,`Discovery` = `RockchipDeviceDiscovery.swift`,
`Facts` = `RockchipAuthorizationFacts.swift`)。

| # | 前置 | 精确 key/位置 | 期望(load() 层) | 源码 |
| --- | --- | --- | --- | --- |
| 1 | Tool bookmark | UserDefaults 新 key `ArkDeck.Rockchip.ToolOrdinaryBookmarkV1`；旧 key `ArkDeck.Rockchip.ToolBookmark` 必须不存在 | Data；以 `[.withoutUI]` 可解析、`stale == false`、绝对 canonical/non-symlink file URL；旧键只作 migration detector，legacy-only/dual-key 均拒绝 | `RockchipProductToolBookmarkStore` |
| 2 | Quarantine 断言 | UserDefaults `ArkDeck.Rockchip.ToolQuarantinePresent` | 键存在(`object(forKey:) != nil`),按 Bool 读取 | Host:794–799 |
| 2b | Code trust(admission 层伴生键,r3 表未列,见 §8) | UserDefaults `ArkDeck.Rockchip.ToolCodeTrust` | String,`RockchipPlatformCodeTrust` rawValue;缺省解为 `.unknown` | Host:792–793;Discovery:44–50 |
| 3 | GitHub provenance token | Keychain generic password,service `dev.arkdeck.github-provenance`,account `protected-main-reader` | 存在、可读、UTF-8 解码后非空 | Host:807–811、829–845 |
| 4 | Durable binding snapshot | `~/Library/Application Support/ArkDeck/rockchip-binding.json` | 恰四字段 `revision`/`serial`/`usbTopology`/`evidence`;`revision > 0`、serial 非空、usbTopology 全 ASCII 数字非空、evidence 非空且元素非空 | Host:732–737、812–823 |

UserDefaults 域:`arkdeck` 是无 bundle identifier 的 CLI,`UserDefaults.standard`
按 CFPreferences 惯例落**进程名域 `arkdeck`**
(`~/Library/Preferences/arkdeck.plist`)。r3 已实测全部真实域(含
`com.arkdeck.desktop`)均无这些 key。本 runbook 一律对域 `arkdeck` 写入与取证;
若 §7 探针仍报 bookmark 未安装,先重测宿主进程实际 preferences 域并修订本文件,
**不得**以写 NSGlobalDomain 兜底(污染全部进程,且掩盖域判定错误)。

辅助事实(无需安装):`load()` 自建 `~/Library/Application Support/ArkDeck/` 与
其下 `AuthorizationUsage/`(0o700 并 chmod 强制;Host:762–775),零人工步骤。

## 2. 第 1 项:ordinary tool bookmark

- **契约**:唯一可消费键为
  `ArkDeck.Rockchip.ToolOrdinaryBookmarkV1`。其值必须由产品安装入口创建，
  `load()` 只用 `[.withoutUI]` 解析，要求非 stale、绝对 file URL，且解析原始
  URL 的 standardized path 与解 symlink 后的 canonical path 逐字相等。
  production discovery 以 typed `installedOrdinaryBookmark` 再次解析并要求与
  selected executable 精确相等，且**不调用**
  `startAccessingSecurityScopedResource()`。旧键
  `ArkDeck.Rockchip.ToolBookmark` 永不解析；旧键单独存在或与新键并存都在
  第 1 项 fail closed。
- **工具实体**:必须是 destructive 面 pinned 工具
  `~/dayu200-rehearsal/rkdeveloptool/rkdeveloptool`，SHA-256 必须逐字等于
  `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`。
  安装入口通过 descriptor-bound prepare 门独立检查 regular、executable、
  `O_NOFOLLOW` 与该 hash，随后立即关闭 prepared token；不会 launch 工具。
  `/opt/homebrew/bin/rkdeveloptool` 等 E0 实体不满足此 pin。
- **安装步骤**:
  ```sh
  TOOL="$HOME/dayu200-rehearsal/rkdeveloptool/rkdeveloptool"
  swift build --package-path Packages/ArkDeckKit -c release --product arkdeck
  Packages/ArkDeckKit/.build/release/arkdeck flash install-tool --path "$TOOL"
  ```
  installer 先完成 ordinary bookmark self-roundtrip/path-match，再写新键并做
  exact Data readback；全部成功后才删除旧键。它不写 quarantine/code-trust、
  Keychain、binding、authorization 或其他 D-1 项。
- **跨构建语义**:普通 bookmark 不携带 security scope，允许同 basename、
  同 `arkdeck` preferences 域但 Identifier/CDHash 不同的后续 `arkdeck` build
  消费。创建与消费仍须是同一 macOS 用户账户。
- **责任人**:维护者，或处于已批准 host-only 任务边界内的 Agent 会话。安装不含
  设备/授权判断；r4 快照取证与是否满足前置的最终认定仍归维护者。
- **装后自证快照**(只证明存在性/类型/长度，不输出 bookmark bytes):
  ```sh
  defaults read-type arkdeck ArkDeck.Rockchip.ToolOrdinaryBookmarkV1
  defaults read arkdeck ArkDeck.Rockchip.ToolOrdinaryBookmarkV1 | wc -c
  defaults read arkdeck ArkDeck.Rockchip.ToolBookmark
  # 前两条应显示 Data/非零长度；旧键读取应以“不存在”失败
  ```
- **失败、迁移与恢复**:missing/wrong-type/corrupt/stale/non-canonical new key
  均输出受控 `productionConfigurationUnavailable` 并保持 process dispatch=0。
  legacy-only 时直接运行上述 installer；若一次迁移在删除旧键处中断，最坏为
  dual-key，`load()` 继续拒绝，原路径重跑 installer 可完成恢复。工具移动或
  重建后必须用新的 canonical 实体重装。明确回滚到 fail-closed:
  `defaults delete arkdeck ArkDeck.Rockchip.ToolOrdinaryBookmarkV1`。
- **历史勘误归档**:此前使用 Swift helper 创建
  `.withSecurityScope` bookmark 并直写 `ArkDeck.Rockchip.ToolBookmark` 的步骤
  已退役，**不得照做**；其跨 signing identity 的 Code=259 缺陷由
  TASK-AIN-BKMK-001 的 ordinary route 修复，旧字节只用于迁移检测，绝不尝试
  按普通 bookmark 猜测解析。

## 3. 第 2 项:quarantine 断言(+ admission 层伴生键 code trust)

- **契约(load() 层)**:key `ArkDeck.Rockchip.ToolQuarantinePresent` 必须存在,
  缺席即抛 `tool quarantine assessment is absent`(Host:794–798);值按 Bool 读取
  (Host:799),load() 层值可为 false——与 r3 表一致。
- **契约(admission 层,r3 表之外,见 §8)**:tool/device 观测门要求
  `permitsPinnedDiscovery = quarantinePresent == false && (codeTrust ==
  .developerID || codeTrust == .adHoc)`(Discovery:63–65,guard 于
  Discovery:573–575)。故要达 dispatch:本键实测值必须为 **false**,且伴生键
  `ArkDeck.Rockchip.ToolCodeTrust`(Host:792–793;缺省 `.unknown` 会被拒)必须
  存在且为 `developerID` / `adHoc` 之一(合法 rawValue 见 Discovery:44–50)。
- **安装步骤(只写实测值,禁止写「期望值」)**:
  1. Quarantine 实测(对象 = 第 2 节选定的同一 `$TOOL`):
     ```sh
     xattr -p com.apple.quarantine "$TOOL"
     # 有输出 → 实测 true;`No such xattr` → 实测 false
     ```
     若实测为 true:是否解除 quarantine(`xattr -d`)是**维护者的信任判断**,
     由维护者亲自决定并操作,随后**重新实测**;不解除则本前置按未闭合处理。
  2. 写入实测布尔:
     ```sh
     defaults write arkdeck ArkDeck.Rockchip.ToolQuarantinePresent -bool false  # ← 以实测为准
     ```
  3. Code trust 实测:
     ```sh
     codesign --display --verbose=2 "$TOOL"
     # `Signature=adhoc` → adHoc;Developer ID 证书链 → developerID;
     # `code object is not signed at all` → unsigned:admission 必拒,停,
     # 由维护者决定重签/换实体,禁止写入与实测不符的枚举值
     ```
  4. 写入实测枚举:
     ```sh
     defaults write arkdeck ArkDeck.Rockchip.ToolCodeTrust -string adHoc  # ← 以实测为准
     ```
- **责任人**:测量与写入同第 1 项(维护者或其监督下的宿主会话);解除
  quarantine 的决定必须维护者亲自作出。
- **装后自证快照**(布尔/字符串本身不敏感,可读值):
  ```sh
  defaults read-type arkdeck ArkDeck.Rockchip.ToolQuarantinePresent  # Type is boolean
  defaults read arkdeck ArkDeck.Rockchip.ToolQuarantinePresent       # 0(=false)
  defaults read-type arkdeck ArkDeck.Rockchip.ToolCodeTrust          # Type is string
  defaults read arkdeck ArkDeck.Rockchip.ToolCodeTrust               # adHoc 或 developerID
  ```
- **失败/回滚**:`defaults delete arkdeck <key>` 逐键回退;工具实体更换后两键
  必须重测重写(它们描述的是那个文件的实测状态,不是配置意愿)。

## 4. 第 3 项:Keychain GitHub provenance token(维护者亲装)

- **契约**:`SecItemCopyMatching`,`kSecClassGenericPassword`,service
  `dev.arkdeck.github-provenance`,account `protected-main-reader`,单条返回
  Data(Host:829–845);UTF-8 解码后非空(Host:807–811)。用途 = Bearer token 走
  `api.github.com` **只读** `ArkDeck/ArkDeck`:`branches/main`、contents
  (authorization registry 与 `.github/CODEOWNERS` @ 各 ref)、`pulls/N`(+
  reviews)、compare(Host:1105–1147、1166)。
- **最小权限**:fine-grained PAT,仅授 `ArkDeck/ArkDeck` 一仓:Contents Read +
  Pull requests Read + Metadata Read;**零写权限**。有效期由维护者裁量(建议不
  长于载体 `validUntil` 数量级)。
- **安装步骤(维护者亲手;token 值不经 Agent、不入 argv/shell history/任何
  transcript——r3 D-1 明文「凭据不经 Agent 之手」,POL-AGENT-001 同向)**:
  ```sh
  security add-generic-password -a protected-main-reader -s dev.arkdeck.github-provenance -w
  # 不带值的 -w:security 交互式隐藏输入两次;禁止 -w <token> 形式
  ```
- **ACL 注记(无人值守可用性)**:`security` CLI 建项后,`arkdeck` 进程首次
  `SecItemCopyMatching` 会触发 Keychain 允许弹窗;用户拒绝/无人应答时 status 非
  success,load() 抛 `Keychain provenance credential cannot be read`
  (Host:840–843)= fail closed。因此必须在**有人值守窗口**由维护者完成一次读
  授权(「始终允许」;§7 探针顺带达成)。注意「始终允许」绑定二进制签名身份:
  `arkdeck` 重新构建(ad-hoc 签名变化)可能再次弹窗——r4 执行窗口前,应以
  **届时将用于执行的同一构建产物**完成该次授权。
- **装后自证快照**(存在性,不读值;任何入仓证据/transcript 中禁止 `-w` 读值
  形式):
  ```sh
  security find-generic-password -a protected-main-reader -s dev.arkdeck.github-provenance
  # 仅打印 keychain 条目属性(service/account/时间戳),不含 secret
  ```
- **失败/回滚/轮换**:本地删除
  `security delete-generic-password -a protected-main-reader -s dev.arkdeck.github-provenance`;
  远端吊销 = GitHub 侧 revoke 该 PAT(双向独立,建议同时执行);轮换 = revoke +
  delete + 重新 add。
- **责任人**:**维护者亲装,不得由 Agent 执行、代拟或转写含 token 的命令**。

## 5. 第 4 项:`rockchip-binding.json`(维护者,设备窗口,顺序上最后)

- **契约(load() 层)**:路径
  `~/Library/Application Support/ArkDeck/rockchip-binding.json`(Host:762–765、
  812);`Data(contentsOf:options:[.mappedIfSafe])` 读取——文件缺失直接抛文件错
  (fail closed;Host:813)。Schema = `RockchipProductBindingSnapshot`
  (Host:732–737):`revision` Int、`serial` String、`usbTopology` String、
  `evidence` [String]。校验:`revision > 0`、serial 非空、usbTopology 非空且全
  ASCII 数字、evidence 非空且元素非空(Host:815–823)。
- **契约(admission 层,全部为硬断言)**:
  - `durable.reference.revision == authorization.target.bindingRevision`
    (Facts:321–323;载体字段定义 `StandingAuthorization.swift:37–43`,parse 对
    `bindingRevision <= 0` 直接拒绝 `:108–110`)——**本文件 revision 与 r4 载体
    pin 逐字相等**,即 r4 二值前置第 3 条;
  - usbTopology canonical:全数字且无前导零(除单独 `"0"`;Facts:330–334、
    417–420)——`String(UInt64)` 十进制自然满足;
  - `sha256(serial UTF-8) == authorization.target.serialSHA256`(Facts:335–338)
    **且** == 活体 USB 读回摘要(Facts:373–376)——serial 必须是被授权那台
    DAYU200 的**真实序列号字节**(仓内 pin 摘要
    `958780b2ffb7090d4f22cdc1f547f9804ed0f0b605e3020f384e5d4823dc7a7e`,
    EVD-M0B-DAYU200-20260718-001);
  - usbTopology == 活体枚举 `String(locationID)`(Facts:357–360;probe 源
    Host:855–908,读 IOKit `IOUSBHostDevice` 的 `locationID` 与
    `USB Serial Number`)且 == 读回 topology(Facts:380–382)——**执行时设备必须
    插在同一物理 USB 拓扑位**(locationID 随端口/hub 链变化;装后到 r4 执行不得
    换口);
  - transport usb、targetID 关联(Facts:318–320、324–326)。
- **revision 的语义(不可臆造,方向不可倒)**:revision 值只能来自 **durable
  绑定建立**;本文件即当前机制下产品消费的 durable binding snapshot
  (`evidence/authorizations/README.md`「完成路径(r4)」;r3 D-1 段末条)。为
  本 DAYU200 在本宿主首次建立 durable 绑定 = 以 `revision = 1` 写入本文件
  (Core `DeviceBindingHistory` 不变量:首绑 revision 1;r2
  `evidence/runs/TASK-AIN-004/run.md`「bindingRevision 决定」同据);此后任何
  rebind(换设备/重建绑定)递增 revision 并须换新载体 pin。**先有本文件的
  revision,后定 r4 载体 `target.bindingRevision` 抄写之;不得先在载体写数再回头
  把文件凑成那个数。**
- **取值方法(设备窗口,只插目标设备,Loader 态 0x2207:0x350a)**:
  ```sh
  ioreg -p IOUSB -l -w0 | grep -e '"USB Serial Number"' -e '"locationID"' \
    -e '"idVendor"' -e '"idProduct"'
  # 人工核对 idVendor = 8711 (0x2207)、idProduct = 13578 (0x350a) 的那一条;
  # locationID 取十进制原样(无前导零),serial 只经下述 getpass 输入,不落
  # shell history
  ```
- **安装步骤(推荐用本 installer:serial 隐藏输入、摘要门前置、0600 原子写)**:
  ```sh
  python3 - <<'EOF'
  import getpass, hashlib, json, os, pathlib, sys
  PIN = "958780b2ffb7090d4f22cdc1f547f9804ed0f0b605e3020f384e5d4823dc7a7e"
  serial = getpass.getpass("serial (input hidden): ")
  if hashlib.sha256(serial.encode()).hexdigest() != PIN:
      sys.exit("serial digest does not match the pinned target; stop.")
  topology = input("usbTopology (decimal locationID): ").strip()
  if not (topology.isdigit() and (topology == "0" or not topology.startswith("0"))):
      sys.exit("usbTopology must be canonical decimal digits.")
  revision = int(input("revision (durable binding; first binding = 1): "))
  if revision <= 0:
      sys.exit("revision must be > 0.")
  evidence = [
      "EVD-M0B-DAYU200-20260718-001 serial digest match",
      "E0 readback run 2026-07-22 evidence/runs/TASK-AIN-004/",
      "installed per evidence/host-prerequisites/installation-runbook.md",
  ]
  root = pathlib.Path.home() / "Library/Application Support/ArkDeck"
  root.mkdir(parents=True, exist_ok=True)
  os.chmod(root, 0o700)
  target = root / "rockchip-binding.json"
  fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
  with os.fdopen(fd, "w") as handle:
      json.dump({"revision": revision, "serial": serial,
                 "usbTopology": topology, "evidence": evidence},
                handle, ensure_ascii=False, indent=2)
  print("written:", target)
  EOF
  ```
  `evidence` 数组元素可由维护者增改,约束:非空、元素非空、**不含序列号原文**、
  逐条指向可核事实。
- **责任人**:**维护者(设备窗口)**——需要原始序列号字节(仓内只有摘要;字节
  同凭据待遇,不经 Agent)、durable 绑定建立与 revision 判断,且与 r4 载体 pin
  互锁,全部属授权判断面。
- **装后自证快照**(结构/摘要证明,不输出 serial 原文;摘要本就入仓为 pin):
  ```sh
  python3 - <<'EOF'
  import hashlib, json, pathlib
  p = pathlib.Path.home() / "Library/Application Support/ArkDeck/rockchip-binding.json"
  d = json.loads(p.read_text())
  print("keys:", sorted(d))                      # ['evidence','revision','serial','usbTopology']
  print("revision:", d["revision"], "(>0:", d["revision"] > 0, ")")
  t = d["usbTopology"]
  print("usbTopology canonical:", t.isdigit() and (t == "0" or not t.startswith("0")))
  print("evidence non-empty:", bool(d["evidence"]) and all(bool(e) for e in d["evidence"]))
  print("serial sha256:", hashlib.sha256(d["serial"].encode()).hexdigest())  # 须 == 958780b2…7a7e
  EOF
  ls -l "$HOME/Library/Application Support/ArkDeck/rockchip-binding.json"   # -rw-------
  ```
- **失败/回滚**:删除该文件即整体回 fail-closed(load() 在 Host:813 抛错);
  设备更换/拓扑变更 → 重走本节(revision 语义按 rebind 递增)并**同步换新载体
  pin**,旧载体随之失效。

## 6. 安装顺序、依赖与 r4 衔接

1. **第 1 项 → 第 2 项**:两项描述同一实体工具(第 2 项测的就是第 1 项
   bookmark 指向文件的 quarantine/签名实况),第 1 项的 hash 门先选定实体,
   第 2 项随后测量;实体更换则两项全部重做。
2. **第 3 项**:独立,可与 1/2 并行或任意先后;但 §7 探针与任何 admission 都
   依赖它,且首读 ACL 授权必须赶在无人值守窗口之前(§4 ACL 注记)。
3. **第 4 项最后**:必须在设备窗口内、身份逐项核验后写入;其 revision 决定 r4
   载体 `target.bindingRevision`(先文件、后载体,逐字相等)。
4. **r4 起草门**:四项(含 2b 伴生键,共五个 key/文件)全部装好、快照取证完成
   后,r4 方可起草;r4 的完整前置以 tasks.md r3 段「r4 的二值前置」清单**原文为
   准**(本文件对应其第 2、3 条,不复述、不放宽其余条款;D-2 已由 DEC-012 裁决
   (a) 关闭,#670)。

## 7. 装后联合自证(维护者,fail-closed 窗口内,可选但推荐)

在 `AUTH-2026-025-DAYU200-002` 于 main 仍为 `target.bindingRevision = -1`
(解析层 `negativeValue` 拒绝,`StandingAuthorization.swift:108–110`)期间:
admission 先 resolve 授权、后采集 facts(`AuthorizationAdmission.swift:97、106`),
故下述探针**必然止于授权解析拒绝**——不需要设备在场、零 destructive dispatch:

```sh
swift run -c release arkdeck flash execute \
  --images <pinned 7.0.0.33 tar.gz 本地路径> \
  --target-location-id <十进制 locationID> \
  --authorization-id AUTH-2026-025-DAYU200-002
```

判读:第 1 项未闭合时输出受控
`productionConfigurationUnavailable`（包括 missing/legacy/dual/wrong-type/
corrupt/stale/non-canonical）；第 1 项消费成功而第 2 项未装时，必须精确止于
`tool quarantine assessment is absent`。继续越过全部四项并止于 standing
authorization/admission 拒绝且 dispatch=0，才说明 **load() 对四项的消费全部
成功**，同时顺带完成 §4 的 Keychain「始终允许」授权。常规 D-1 联合自证由
**维护者亲手**执行；TASK-AIN-BKMK-001 的 host-only 产品 A/B 验收是一次性例外，
只在 old/new/quarantine 三键预检均不存在时安装第 1 项并止于上述 quarantine
缺失门，随后删除新键。载体翻非负(r4 finalize)之后**禁止**再以此命令作探针——
届时同命令即真实执行入口。

## 8. 与 r3 D-1 记载的出入(如实,按源码实况)

1. **r3 四项表零漂移**:r3 表 = `load()` 层契约,与本 base 源码逐字一致
   (§头注 rev-list 实测 0 commit)。本 runbook 第 2–5 节即按其起草。
2. **admission 层的补充要求(r3 表未列)**:达 dispatch 还需
   `ToolQuarantinePresent` 实测为 **false** 且第五键 `ToolCodeTrust` ∈
   {`developerID`, `adHoc`}(`permitsPinnedDiscovery`,Discovery:63–65、573–575;
   production 组线 Host:1037–1040)。r3 表「值可为 false」只对 load() 层成立,
   不足以过 admission;r4 快照应含**五**个 key/文件而非四。
3. **production profile composition 缺口已闭合**:历史版本曾把
   `pinnedProduction` tool 交给缺省 `pinnedReadOnlyDiscovery` adapter，导致
   hash 恒不等；TASK-AIN-003R 已把 production composition 显式注入
   `.pinnedProduction`，而 public/E0 缺省仍保持
   `.pinnedReadOnlyDiscovery`。本 runbook 不把该修复等同于 E2 授权或硬件就绪。
4. **bookmark signing-identity 缺口已闭合**:历史
   `.withSecurityScope` helper 路径会把解析绑定到创建者 signing identity，
   跨构建报 Code=259。TASK-AIN-BKMK-001 以产品 `install-tool`、普通 bookmark、
   新键、typed `installedOrdinaryBookmark` 与 legacy fail-closed migration
   取代该路径；产品 A/B 验收要求 Identifier/CDHash 均不同且 B 到达下一项
   quarantine 缺失门。旧 helper/旧键不能恢复为消费或 fallback 路径。

## 9. 脱敏红线(全文适用)

- token 值、PEM、任何凭据内容、序列号完整字节**绝不入仓**;serial 原始字节与
  凭据同待遇,不经 Agent、不落 shell history(getpass/交互式 `-w`)。
- 一切快照命令都是存在性/类型/长度/结构/摘要证明:`defaults read-type`、
  `security find-generic-password`(永不带 `-w`)、JSON 结构校验与 SHA-256
  摘要;唯一可明文入证的值 = 布尔/枚举(`ToolQuarantinePresent`、
  `ToolCodeTrust`)、`revision`、`usbTopology`、evidence 字符串与既已入仓的
  摘要。
- 含原始 serial 的中间产物只存在于宿主内存/交互输入,不写临时文件、不进任何
  入仓证据或会话 transcript。
