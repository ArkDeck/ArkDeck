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
> Base:main `6383f5b9e8c61e61c798ee7f7cf09035faff2a3d`。消费契约全部引自该树源码
> (文件:行号),且实测 `git rev-list --count 6e45a22..HEAD --
> Packages/ArkDeckKit/Sources/ArkDeckWorkflows/` = **0**——r3 D-1 表所依据的
> `load()` 契约在本 base 上零漂移。

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
| 1 | Tool bookmark | UserDefaults `ArkDeck.Rockchip.ToolBookmark` | Data;以 `[.withSecurityScope, .withoutUI]` 可解析、`stale == false`、file URL、绝对路径、`startAccessingSecurityScopedResource()` 为 true | Host:777–791 |
| 2 | Quarantine 断言 | UserDefaults `ArkDeck.Rockchip.ToolQuarantinePresent` | 键存在(`object(forKey:) != nil`),按 Bool 读取 | Host:794–799 |
| 2b | Code trust(admission 层伴生键,r3 表未列,见 §8) | UserDefaults `ArkDeck.Rockchip.ToolCodeTrust` | String,`RockchipPlatformCodeTrust` rawValue;缺省解为 `.unknown` | Host:792–793;Discovery:44–50 |
| 3 | GitHub provenance token | Keychain generic password,service `dev.arkdeck.github-provenance`,account `protected-main-reader` | 存在、可读、UTF-8 解码后非空 | Host:807–811、829–845 |
| 4 | Durable binding snapshot | `~/Library/Application Support/ArkDeck/rockchip-binding.json` | 恰四字段 `revision`/`serial`/`usbTopology`/`evidence`;`revision > 0`、serial 非空、usbTopology 全 ASCII 数字非空、evidence 非空且元素非空 | Host:732–737、812–823 |

UserDefaults 域:`arkdeck` 是无 bundle identifier 的 CLI,`UserDefaults.standard`
(Host:777)按 CFPreferences 惯例落**进程名域 `arkdeck`**
(`~/Library/Preferences/arkdeck.plist`)。r3 已实测全部真实域(含
`com.arkdeck.desktop`)均无这些 key。本 runbook 一律对域 `arkdeck` 写入与取证;
若 §7 探针仍报 bookmark 未安装,先重测宿主进程实际 preferences 域并修订本文件,
**不得**以写 NSGlobalDomain 兜底(污染全部进程,且掩盖域判定错误)。

辅助事实(无需安装):`load()` 自建 `~/Library/Application Support/ArkDeck/` 与
其下 `AuthorizationUsage/`(0o700 并 chmod 强制;Host:762–775),零人工步骤。

## 2. 第 1 项:security-scoped tool bookmark

- **契约**:key `ArkDeck.Rockchip.ToolBookmark`(Host:778)须为
  `URL.bookmarkData(options: [.withSecurityScope])` 产物;load() 以
  `[.withSecurityScope, .withoutUI]` 解析并要求非 stale、绝对 file URL、
  security scope 可进入(Host:783–791)。admission 期以同字节再次解析,并断言
  解 symlink、标准化后与 executableURL 相同(Discovery:501–527),bookmark 缺失
  按 `requiresSecurityScopedBookmark = true` 拒绝(Discovery:29、564–566)。
  被 bookmark 的实体必须是 destructive 面 pinned 工具
  `~/dayu200-rehearsal/rkdeveloptool/rkdeveloptool`(r3 实测 SHA-256 命中
  `pinnedProduction.executableSHA256` =
  `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`,
  Discovery:21–29)。**不得**用 `/opt/homebrew/bin/rkdeveloptool` 等
  `bbd7bdc0…9923`(`pinnedReadOnlyDiscovery`,E0 只读面)实体——错装不会执行错
  工具(prepare 期 `expectedSHA256` 与 admission 断言双 hash 门 fail closed,
  Host:196–200;Facts:340、349–352),但 r4 会白跑。
- **可行性依据**:r3 已单独实证非 sandbox CLI 能创建并解析 `.withSecurityScope`
  bookmark(824 B、resolve 回原路径、stale=false、startAccessing true),故此项
  属「未安装」而非「架构上不可能」;下述 helper 即该已证途径的固化。
- **安装步骤**(一次性 helper,仓外临时文件,用毕即删,不入仓、不进
  `Packages/**`):
  1. Hash 门(不命中即停,不得继续):
     ```sh
     TOOL="$HOME/dayu200-rehearsal/rkdeveloptool/rkdeveloptool"
     shasum -a 256 "$TOOL"
     # 必须逐字 == 038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611
     ```
  2. 写 helper(如 `/tmp/make-bookmark.swift`),内容与 load() 的解析选项逐字
     同构:
     ```swift
     // make-bookmark.swift — 一次性,用毕即删。
     import Foundation
     let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
     let bookmark = try url.bookmarkData(
       options: [.withSecurityScope], includingResourceValuesForKeys: nil,
       relativeTo: nil)
     var stale = false
     let resolved = try URL(
       resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
       relativeTo: nil, bookmarkDataIsStale: &stale)
     guard !stale, resolved.standardizedFileURL == url,
       resolved.startAccessingSecurityScopedResource()
     else { fatalError("bookmark self-check failed") }
     resolved.stopAccessingSecurityScopedResource()
     FileHandle.standardError.write(Data("bookmark bytes: \(bookmark.count)\n".utf8))
     print(bookmark.map { String(format: "%02x", $0) }.joined())
     ```
  3. 生成并写入 `arkdeck` 域(hex 编码的 bookmark 非凭据,可走 argv):
     ```sh
     swift /tmp/make-bookmark.swift "$TOOL" > /tmp/bookmark.hex
     defaults write arkdeck ArkDeck.Rockchip.ToolBookmark -data "$(cat /tmp/bookmark.hex)"
     rm /tmp/make-bookmark.swift /tmp/bookmark.hex
     ```
- **责任人**:维护者,或维护者监督下的有人值守宿主会话执行(无凭据、无授权
  判断;错值双 hash 门 fail closed)。r4 快照取证与认定归维护者。
- **装后自证快照**(存在性/类型/长度,不贴字节):
  ```sh
  defaults read-type arkdeck ArkDeck.Rockchip.ToolBookmark   # 期望:Type is data
  defaults read arkdeck ArkDeck.Rockchip.ToolBookmark | wc -c # 长度级证明(r3 同规格 824 B 级)
  ```
- **失败/回滚**:`defaults delete arkdeck ArkDeck.Rockchip.ToolBookmark` 即回
  fail-closed(load() 报 `pinned rkdeveloptool bookmark is not installed`,
  Host:779–781)。工具文件被移动/重建 → bookmark 变 stale/解析失败
  (Host:789–791 报 `stale or inaccessible`)→ 重跑本节全部步骤。bookmark 为
  per-user 产物:创建与消费须同一 macOS 用户账户。
- **勘误(2026-07-28;缺陷正本 = tasks.md TASK-AIN-003「Defect record 2」;
  原文历史层保留、不删除)**:本节 helper 途径已被受控实测**证伪**——
  `.withSecurityScope` bookmark 的 resolve **绑定创建者 code-signing 身份**
  (ad-hoc 下 = Identifier+CDHash 粒度)。上列第 2–3 步以 `swift` 解释器进程
  (Apple 签名 `swift-frontend`)创建的 bookmark,产品这类 ad-hoc 二进制按
  load() 同选项 resolve 实测 = `NSCocoaErrorDomain Code=259`(bookmark 字节
  逐字节一致仍然如此);维护者 2026-07-28 实际执行本节 + §7 探针即于该第一站
  裸报 259(load() 的 resolve 调用裸抛,无治理文案)。上方「可行性依据」的
  r3 实证为**同进程自证**,只在同一签名身份内成立,不覆盖「helper 创建、产品
  消费」。SwiftPM 构建的 `arkdeck` 为 ad-hoc 签名且 Identifier 内嵌 LC_UUID
  (签名身份逐内容不同的构建漂移),产品又无任何 bookmark 安装子命令,故改由
  产品自建 bookmark 亦无入口、且重构建后同样失效。**第 1 项在
  TASK-AIN-BKMK-001(tasks.md)done 前不可闭合**;本节安装步骤保留为历史层
  记录,**不得照做**。admission/execute 面的对应出入记录 = §8 第 4 条。

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

判读:输出仍含四条 `productionConfigurationUnavailable` 文案之一
(Host:779–781/789–791/795–798/808–811/820–822)= 对应前置未装好;越过全部四条、
止于 standing authorization/admission 拒绝且 dispatch=0 = **load() 对四项的消费
全部成功**,同时顺带完成 §4 的 Keychain「始终允许」授权。本探针由**维护者亲手**
执行(它调用真实执行宿主二进制;Agent 不执行,POL-AGENT-002 同向);载体翻非负
(r4 finalize)之后**禁止**再以此命令作探针——届时同命令即真实执行入口。

## 8. 与 r3 D-1 记载的出入(如实,按源码实况)

1. **r3 四项表零漂移**:r3 表 = `load()` 层契约,与本 base 源码逐字一致
   (§头注 rev-list 实测 0 commit)。本 runbook 第 2–5 节即按其起草。
2. **admission 层的补充要求(r3 表未列)**:达 dispatch 还需
   `ToolQuarantinePresent` 实测为 **false** 且第五键 `ToolCodeTrust` ∈
   {`developerID`, `adHoc`}(`permitsPinnedDiscovery`,Discovery:63–65、573–575;
   production 组线 Host:1037–1040)。r3 表「值可为 false」只对 load() 层成立,
   不足以过 admission;r4 快照应含**五**个 key/文件而非四。
3. **上游结构性缺口(本 runbook 无法也不得修复)**:production composition 把
   声明为 `pinnedProduction`(`038a8a0e…`)的 `settings.tool`(Host:800–806)交给
   `RockchipDeviceDiscoveryAdapter()` 缺省实例,而该缺省 init 钉的是
   `pinnedReadOnlyDiscovery`(`bbd7bdc0…`;Discovery:541–544,类注释明言
   「destructive compatibility identity is not accepted by the default adapter」
   Discovery:4–6)。`processRequest` 的声明性 hash 门
   `tool.sha256 == profile.executableSHA256`(Discovery:570–572)因此**恒不等**:
   四项前置装得再对,tool/device 观测也在 `executableHashMismatch` →
   `toolOrDeviceObservationUnavailable`(Facts:140–143)处 fail closed,E2
   admission 今日结构性不可达。换 bookmark 到 bbd7 实体也不通:Facts:349 断言
   观测身份必须 == `pinnedProduction`。修复属 `Packages/**`(本任务 Forbidden;
   按任务卡「发现缺陷回 TASK-AIN-003」),归维护者裁量;本文件的安装步骤不因此
   改变(四项仍是 load() 的必要输入),但 r4 起草者必须知道:**仅装齐宿主前置不
   使 E2 可达,该缺口闭合前不得以「前置已装好」推定可执行**。
4. **第二处上游结构性缺口(2026-07-28 增补;维护者实际执行 §2/§7 时发现,本
   runbook 无法也不得修复)**:`.withSecurityScope` bookmark 的 resolve 绑定
   **创建者 code-signing 身份**(ad-hoc 下 = Identifier+CDHash 粒度;受控
   矩阵与行级证据 = tasks.md TASK-AIN-003「Defect record 2」)。§2 helper
   (解释器进程)所建 bookmark,产品 ad-hoc 二进制 resolve 恒为
   `NSCocoaErrorDomain Code=259`,且该错误在 load() 的 resolve 调用处裸抛
   (无 `productionConfigurationUnavailable` 文案,经 CLI 顶层 `\(error)`
   直出);产品子命令全集无任何安装入口,SwiftPM 产物签名身份逐(内容不同
   的)构建漂移。故第 1 项今日**不存在可行安装途径**,§7 探针在缺陷闭合前恒
   止于第一站(bookmark resolve),到不了「止于授权解析拒绝」的判读位。修复
   属 `Packages/**`(本任务 Forbidden;按任务卡「发现缺陷回 TASK-AIN-003」),
   由 TASK-AIN-BKMK-001(tasks.md)承载;其 done 前不得以「第 1 项已装好」
   推定 load() 可消费,r4 的 D-1 第 1 项快照取证同以其 done 为前置(r4 前置
   清单第 8 条)。§2 末的 dated 勘误注记为安装面的对应记录。

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
