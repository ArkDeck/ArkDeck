# Tasks — CHG-2026-026 macOS Rockchip Flash UI

> PR #297 只登记 proposal；本独立 governance/readiness PR 同时起草 change
> `proposed→approved` 与 TASK-RKFUI-001 `blocked→ready`，仅在维护者 review/merge 后生效。
> 其余任务继续 `blocked`。每个实现任务单独 PR，不混入 readiness/status PR。
>
> r2（2026-07-24，on merge）只起草 discovery clean-tool repin authority、修正
> TASK-RKFUI-001↔001A 的循环依赖，并把 001A 在精确 D2 pins 下 `blocked→ready`。本 PR
> 不携带 repin/probe implementation 或设备 run；后续仍按任务分别提交独立 PR。
>
> proposal r3（2026-07-24，on merge）只把 TASK-RKFUI-001A 的 exact firmware pin 从
> `7.0.0.34` 替换为 E0 读回的 `7.0.0.33`；其余 D2 pins、窗口、次数与安全边界不变。
> r3 合入前 probe implementation/E1 dispatch 仍为 0。
>
> proposal r4（2026-07-24，on merge）只注册 homogeneous LF/CRLF discovery grammar、
> 新增独立 TASK-RKFUI-001B，并归档 CRLF + Maskrom blocked E0 receipt。r4 不接受逐设备
> capability evidence，不授权 E1；001B merge 与后续 evidence PR merge 前 E1 为 0。
>
> proposal r5（2026-07-24，on merge）只把 TASK-RKFUI-001A 的 HDC pin 从
> `3.2.0d` / `48395ba8…d260` 精确替换为 `3.2.0f` / `05b2bf7a…f83`，新增
> TASK-RKFUI-001C registry/probe closure，并归档 HDC drift + persistent Maskrom blocked
> E0 receipt。r5/001C 不接受 capability evidence、不授权 E1。

## TASK-RKFUI-001 — RockUSB discovery contract 与 signed Sandbox E0 access spike

- Status:ready（仅在维护者 review/merge 本独立 governance/readiness PR 后生效；只允许
  contract/fake 与具名窗口内 E0/read-only access spike，零 mode switch、零
  mutation/destructive）
- Readiness review（2026-07-22；host-only 审计，真实 `rkdeveloptool ld`/HDC/device
  dispatch 0）：
  - Approval gate:on merge。PR #297 仅登记 `status: proposed` proposal；本 PR 明确承载
    CHG-2026-026 `proposed→approved` 与本任务 `blocked→ready`，两者由维护者一次 review
    后同时生效。批准的 `REQ-FLASH-015` 解释、E0-only 边界与其他任务继续 blocked 见
    `proposal.md` 的 Approval and readiness boundary。
  - Objective/scope gate:satisfied。目标只包括 strict `ld` discovery contract、固定 executable
    URL + argv adapter 与 signed Sandbox 非提权 E0 spike；in/out scope、allowed/forbidden
    paths、两条 canonical AC、deliverables 与二值 verification 均已固定，不需要执行 Agent
    新做产品或 Safety 决策。
  - Base/input pins:proposal base = `main`
    `88dee1dc83d4e9e4675ea36803d5b261f1cdf3da`；实现必须基于本 readiness 合入后的
    `main`，开始前重核下列 SHA-256，任一漂移即停并重做 readiness：
    - `Packages/ArkDeckKit/Package.swift` =
      `60bd68200aa8d25eb209e5fdd6f9d1e20594af07743849841f31defa4b9b5175`；
    - read-only Provider/Profile/Authorization inputs 分别为
      `81ff71a69f4dd3556de38d5fdf15526e57015529f23384d0fe6832ca32f86eee`、
      `62c51f992654303ed0237b27c1642462dd1d8531b4d4a29661e718c962c2537b`、
      `e3b6cdc334410b67d93782184c705ab55cdefb2cd4340f8c6fe0b35970552edb`；
      本任务只读消费，禁止修改；
    - discovery source/test、Rockchip fixtures/registry、integration directory 与 E0 probe
      script 在 base 均不存在（零路径碰撞）；实现只能在 Allowed paths 新建。
  - Toolchain gate:satisfied。维护者选择的仓库外 executable 于 readiness 重核为
    `rkdeveloptool ver 1.32`、SHA-256
    `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`，与已归档
    CHG-2026-016/TASK-RR-001 pin 一致，来源为官方 upstream commit
    `304f073752fd25c854e1bcf05d8e7f925b1f4e14`。实现/真机 E0 只能由用户显式选择并经
    security-scoped access 获取该 exact identity；禁止 PATH lookup，版本/hash/source
    任一不符即 fail closed。
  - Environment gate:satisfied。macOS 26.5.2、Xcode 26.6 (17F113)、Apple Swift 6.3.3
    可用；任务本身负责生成 signed Sandbox 目标并验证 direct non-elevated access，若目标
    交付形态不能在零 sudo/helper/install/ACL/group/rule modification 下执行，则如实记录
    blocked result，TASK-RKFUI-003 继续 blocked。
  - Hardware/window gate:satisfied for spike。目标为维护者 @lvye 控制的 DAYU200 + USB；
    使用本 readiness 合入后维护者明确开始的首个连续 E0 窗口，并与其他设备任务互斥。
    维护者只负责按已验证物理序列把设备置于 Loader；Agent/App 不发送进态命令。spike 仅可
    执行 exact `["ld"]` 并只接受 semantic `0x2207:0x350a + Loader`；normal/HDC、
    `0x5000`、Maskrom、未知、多候选或权限失败均阻断，不允许用 VID/PID/单设备假设补全身份。
  - Verification/evidence gate:satisfied。contract/golden/fault tests 覆盖 success、malformed、
    multi-device、Maskrom 与相似 family；真实 E0 run 记录 tool identity、signed target、
    entitlements、direct invocation、USB result 与 typed verdict，serial 仅留摘要。fake/simulation
    与 realHardware 分类分离；E1 dispatch、E2 dispatch、sudo/helper/system mutation 计数必须为 0。
  - Concurrency/review gate:satisfied。readiness 审计时 GitHub open PR = 0；本 PR 只修改本
    change 的 `proposal.md`/`tasks.md` 状态与 review record，不携带实现/evidence，也不改变
    其他任务状态。TASK-RKFUI-001 implementation+evidence 与后续 `ready→done` 各用独立 PR。
- Readiness remediation r2（2026-07-22；allowed-paths only，仅在维护者 review/merge 本独立
  governance PR 后生效）：PR #301 按已批准设计为 `ArkDeckWorkflows` 增加
  `ArkDeckProcess` package dependency，但共享 contract test 的硬编码 target 依赖表仍是旧值，
  导致 `testPackageTargetsImportOnlyDeclaredArkDeckModules` 失败。r2 只把该 contract test 文件
  加入 Allowed paths，并仅授权同步这一张硬编码表，使 `ArkDeckWorkflows` 条目与已批准的
  `Package.swift` 声明一致；不授权修改其他测试、源码、依赖、行为或 task status。本 remediation
  PR 只修改治理文档；TASK-RKFUI-001 implementation PR 须在本 r2 合入后再承载该单行 Swift
  表项修复。
- Tool identity remediation r3（2026-07-24；仅在 change proposal r2 governance/readiness
  PR 被维护者 review/merge 后生效）：
  - 2026-07-24 host preflight 重核到两个候选：历史 approved artifact
    `038a8a0e…3611` 仍有 quarantine；无 quarantine 的 current artifact 为
    `rkdeveloptool ver 1.32`、SHA-256
    `bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923`、upstream
    commit `304f073752fd25c854e1bcf05d8e7f925b1f4e14`、ad-hoc signature。两者均在旧
    registry 下 fail closed，`ld` dispatch 0，记录见
    `evidence/runs/TASK-RKFUI-001/e0-preflight-2026-07-24.md`。
  - r3 允许一个独立 implementation remediation 在本任务现有 Allowed paths 内原子更新
    `openspec/integrations/rockchip/**`、`RockchipDeviceDiscovery.swift`、对应 contract
    fixtures/tests 与 `scripts/rockchip_e0_probe/**`，使 discovery identity 精确变为
    `bbd7…9923`。registry/version/resource closure/Swift/Python 四面必须同步，任一旧 pin
    残留即测试失败；不允许接受 hash 列表、通配 version、PATH lookup、quarantine bypass 或
    第二个 argv。
  - 本授权只覆盖 E0/read-only `ld`。Provider/Profile/Authorization 与所有 destructive
    toolchain pin 保持 `038a8a0e…3611` 且仍为 forbidden/read-only input；不得在该
    implementation PR 一并修改。
  - Input base = proposal r2 merge commit；现 main 审计 base
    `a7ee3f88634972cea4f3bb6622d2f6dab6ea6e06`。开始 implementation 前须 rebase 到
    merge 后 main 并复核现有 discovery source/test/probe/registry blobs 分别为
    `67f585324d002f80c2682a1bdaa9ae7d11ed035a`、
    `1f7cacda22ed6cef97d4a25ed63c3e4aa890cbb6`、
    `92eb2876bfe9dcd0ffadf1d0318b9b7b05c93857`、
    `f7fa0945f70730bca601f81955a3faea411a19f3`；任一漂移即停止并重做 readiness。
- Platform:macos
- Requirements:`REQ-FLASH-001`、`REQ-UX-007`、`POL-WORKFLOW-001`
- Acceptance:`AC-FLASH-001-01`、`AC-UX-007-01`
- Depends on:CHG-2026-026 approved（本 PR merge 后满足）；无前序任务
- Allowed paths:
  - `openspec/integrations/rockchip/**`
  - `Packages/ArkDeckKit/Package.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipDeviceDiscovery.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkDeckContractTests.swift`（仅更新
    `declaredPackageDependencies` 的硬编码 target 依赖表，使 `ArkDeckWorkflows` 与已批准的
    `Package.swift` 依赖声明一致；禁止其他修改）
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipDeviceDiscoveryContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/Rockchip/**`
  - `scripts/rockchip_e0_probe/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipRockUSBFlashProvider.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashProfile.swift`
  - `ArkDeckApp/**`
- Risk:medium（E0/read-only 真机 probe；零 mode switch、零 mutation/destructive）
- Hardware required:yes（E0 窗口；contract/fixture no）

### Deliverables

- 版本化 `rkdeveloptool ld` output registry + success/malformed/multi-device/Maskrom fixtures。
- strict parser 与 executable URL + `["ld"]` adapter；shell/sudo/elevation 调用结构性为 0。
- signed Sandbox host/device spike：记录 tool path source/version/hash/trust、entitlements、
  direct non-elevated invocation、USB access result 和 typed DeviceAccessAdvisor verdict。

### Verification

- AC-FLASH-001-01 → golden + real-fault parser tests → 非 RockUSB/Maskrom/未知/畸形 family
  preflight blocked，相似命令 dispatch 0。
- AC-UX-007-01 → signed Sandbox E0 run → permission/driver/offline 可区分，sudo/helper/install/
  ACL/group/rule 修改调用数 0。
- Execute readiness gate：只有 direct non-elevated `ld` 在目标交付形态可用且 tool identity
  pinned 时 TASK-RKFUI-003 才可进入 ready；否则它保持 blocked。

### Notes / handoff

- 完成后在 `evidence/runs/TASK-RKFUI-001/` 追加 contract 与 E0 run；真实 serial 只记摘要。

## TASK-RKFUI-001A — DAYU200 HDC→Loader E1 capability characterization

- Status:blocked（proposal r5 merge 后仍等待 TASK-RKFUI-001C done 的 D0 状态推进，才可
  恢复 E0 capability preparation。E1 继续 blocked：还须确认 pre-existing RockUSB
  candidate 为 0，并由后续维护者 merged PR 接受逐设备 typed capability evidence）
- Readiness review r2（2026-07-24；host-only 审计，device/HDC command dispatch 0）：
  - Approval/dependency gate:on merge。CHG-2026-026 r1 已由 PR #298 批准；001 discovery
    implementation/hardening 已由 #301/#305 合入。r2 修正旧依赖环：维护者选择 HDC 软件进态
    作为本轮 Loader 来源，因此 001A 不再等待 001 signed Sandbox E0 hardware result
    `done`；001A 的 E1 receipt 不能替代 001 的独立 signed E0 receipt。
  - Scope gate:satisfied。唯一 deviceMutation 是一次 typed `enterUpdater` characterization；
    只允许 HDC exact argv、HDC disconnect observation、bounded clean-tool `ld` polling 与
    identity/rebind verdict。`ppt/wlx/rd`、Flash/erase/format/unlock/update、默认 HDC target、
    shell string、sudo/helper/driver/system mutation 全为 0。
  - Base/input gate:on merge。governance audit base =
    `a7ee3f88634972cea4f3bb6622d2f6dab6ea6e06`；implementation 必须基于本 r2 merge 后的
    current main。`scripts/rockchip_loader_transition_probe/**` 当前不存在；只允许在本任务
    Allowed paths 新建。开始前若 r2 文档、serial/firmware evidence、HDC 或 clean
    rkdeveloptool facts 漂移，立即停止并重新 readiness。
  - Target pin（proposal r3 on merge）:DAYU200 (RK3568)，serial SHA-256
    `958780b2ffb7090d4f22cdc1f547f9804ed0f0b605e3020f384e5d4823dc7a7e`，USB，
    OpenHarmony `7.0.0.33`。serial pin 来自
    `TASK-AIN-004/e0-readback-redacted-summary.json`（blob
    `39c4154b7420a78a554f53a81ea16f12b50b1939`）；current firmware 来自本任务固定
    read-only E0 preflight（`blocked-preflight-firmware-drift-2026-07-24.json`），HDC
    historical combination 来自 `TASK-TR-001/run.md`（blob
    `6069642a7b3c13d741383fbbdd17a0f921c6b9f2`）。这些只用作 readiness pins，不冒充本次
    E1 capability evidence。
  - Binding gate:dispatch 前须重新 E0 读回 serial digest，构造并 durable 保存
    `OriginalTargetSnapshot` 与 revision 1 `CurrentDeviceBinding`；raw connect key 只留仓外
    受控 run。若已有 ArkDeck binding、revision 不是 1、connect key 缺失、identity 不匹配、
    多设备或 server ownership 不确定，E1 dispatch = 0 并回到 readiness。
  - HDC pin:absolute executable =
    `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`，
    `Ver: 3.2.0d`，SHA-256
    `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`。2026-07-24
    host-only `-v`/hash 重核匹配；任务不得启动、停止、迁移或重配 HDC server。
  - RockUSB observation pin:clean discovery artifact =
    `rkdeveloptool ver 1.32`，SHA-256
    `bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923`，
    upstream commit `304f073752fd25c854e1bcf05d8e7f925b1f4e14`，quarantine absent，
    ad-hoc signature。只允许 exact `["ld"]`，只接受 semantic
    `0x2207:0x350a + Loader`；该 pin 不修改 destructive Provider/Profile identity。
  - Typed argv/intent gate:唯一 E1 argv =
    `["-t", "<durable-connect-key>", "shell", "reboot", "loader"]`，从 revision 1 binding
    materialize。command 前先 durable 写 `enterUpdater` intent、target/binding revision、
    argv hash 与影响确认；最多一次 dispatch。exit 0 不构成成功，必须观察原 HDC endpoint
    disconnect 与目标 Loader。
  - Window gate:on merge。有效期至 `2026-07-31T16:00:00Z`，`maxRuns = 1`；用户本轮要求
    通过 HDC 进入 Loader，但聊天指令本身不构成 capability evidence或 merge approval。
    维护者 merge 本 r2 PR 才接受本 exact D2 window。窗口过期、失败后重试、任一 pin 漂移
    均须新 readiness PR。
  - Verification/evidence gate:run 必须逐时记录 E0 identity、intent durability、HDC
    receipt/exit/stdout/stderr hash、disconnect、每次 `ld` observation、timeout/candidate/
    topology、rebind evaluation 与最终 `supported|unsupported|unknown`。仓内只存 serial/
    connectKey/location 摘要；E1 ≤ 1，E2/destructive = 0。
  - Concurrency/review gate:satisfied for drafting。审计 base 的 change paths 无并发 PR
    占用；本 PR 只含 proposal/design/tasks/verification 与既有 blocked preflight evidence。
    r2 合入前零 probe implementation/设备 command；合入后 001 tool repin remediation 与
    001A implementation+evidence 仍使用两个独立 PR。
- Firmware pin remediation r3（2026-07-24；仅在维护者 review/merge proposal r3 后生效）：
  - E0 preflight 在 current `main`
    `fee0f9f507f7a008cc75952bb895056205c6d4f1` 确认 serial 摘要、USB transport、HDC、
    pre-existing external same-UID server 与 clean `rkdeveloptool` 全部命中原 pins；固定
    read-only firmware query 返回 `OpenHarmony 7.0.0.33`，与 r2 的 `7.0.0.34` 不符。
    E1/reboot/`ld` dispatch 均为 0，`maxRuns = 1` 未消费。
  - r3 只授权把本任务的 firmware pin 替换为 `7.0.0.33`。serial、transport、HDC
    path/version/hash、server lifecycle 零 mutation、clean discovery tool identity、revision 1
    binding、typed argv、窗口截止与 maxRuns 全部保持 r2 原值；不授权其他固件或重试。
  - r3 input blobs：proposal/tasks/verification 分别为
    `4b8675fe9013fd118231a0c26b031743d59f1aea`、
    `64e6cbfddb423c06b3e4e011dd2a7b5bb46b3af1`、
    `6e809511bc2efb12b70e22d450079c9f826ecfcc`；开始 implementation 前须基于 r3 merge 后
    current `main` 复核，任一治理输入、target/tool/server/window pin 漂移即停止并重新
    readiness。
  - r3 PR 只允许 change 治理文档、`evidence/README.md` 与
    `evidence/runs/TASK-RKFUI-001A/blocked-preflight-firmware-drift-2026-07-24.*`；
    `scripts/rockchip_loader_transition_probe/**` 在 r3 merge 前保持不存在，真实 E1 command
    dispatch 为 0。
  - r4 real-fault gate：PR #460 merge 后的 E0-only preflight 命中 exact target/HDC/tool
    pins，但 clean `rkdeveloptool ld` 返回 CRLF；当前 1.0.0 parser 按已批准 LF-only
    grammar 返回 `unexpectedCarriageReturn`。diagnostic-only normalization 另显示一个
    `0x2207:0x5000 Maskrom` candidate 与 HDC target 同时存在，physical identity
    correlation 为 unknown。两项均在 E1 process start、binding、intent、usage reservation
    前 fail closed；E1/deviceMutation/destructive = 0。
  - r4 E1 gate：TASK-RKFUI-001B 只能修复 line-termination closure，不得接受/隐藏
    Maskrom。001B merge 后，本任务可重新执行 E0 capability preflight；只有其证明
    pre-existing RockUSB candidate = 0、durable original target/revision 1 binding 与全部
    pins 命中，并将逐设备 typed capability evidence 通过后续 PR 由维护者 merge 接受，
    才可进入原 r3 E1 dispatch gate。任一条件未满足均保持 E1 = 0。
- HDC pin remediation r5（2026-07-24；仅在维护者 review/merge proposal r5 后生效）：
  - PR #468 merge 后的 E0-only preflight 在 target/firmware command 前发现同一 DevEco
    absolute path 已变为 client/server `Ver: 3.2.0f`、SHA-256
    `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`，不匹配 r3
    `3.2.0d` / `48395ba8…d260`。server ownership/path 命中，Agent lifecycle mutation 0。
  - 同次真实 USB `ld` 仍观察到一个 `0x2207:0x5000 Maskrom`；沙箱内 offline scout
    不具等价 USB 可见性，不计为 candidate=0 evidence。HDC target/firmware、binding、
    capability evidence、intent、usage 与 E1 均为 0。
  - r5 merge 只替换 HDC version/hash；absolute path、target/firmware/transport、
    clean discovery tool、binding revision、typed argv、window/maxRuns 与 Safety 边界不变。
  - TASK-RKFUI-001C 必须先原子更新 registry/probe/tests 并记录 r5 merge OID；001C done
    前不得重新 E0。done 后仍只有在真实 USB 环境无 pre-existing candidate 时才可生成
    逐设备 typed capability evidence acceptance PR。
- Platform:macos
- Requirements:`REQ-FLASH-002`、`REQ-FLASH-007`、`REQ-FLASH-010`、
  `REQ-DEV-001`、`REQ-DEV-002`、`REQ-DEV-003`、`REQ-DEV-006`、`REQ-DEV-008`、
  `POL-WORKFLOW-001`
- Acceptance:`AC-FLASH-002-01`、`AC-FLASH-007-01`、`AC-FLASH-010-01`、
  `AC-DEV-001-01`、`AC-DEV-002-01`、`AC-DEV-002-02`、`AC-DEV-003-01`、
  `AC-DEV-003-02`、`AC-DEV-006-01`、`AC-DEV-008-01`
- Depends on:CHG-2026-026 proposal r5 merged；TASK-RKFUI-001 contract
  implementation/hardening (#301/#305)、TASK-RKFUI-001B done、TASK-RKFUI-001C done。
  Fresh E0 另要求 pre-existing RockUSB candidate = 0；E1 dispatch 还要求逐设备 typed
  capability evidence acceptance merged。TASK-RKFUI-001 signed Sandbox E0 hardware result
  不再是前置，避免软件进态 Loader 来源的循环依赖
- Allowed paths:
  - `scripts/rockchip_loader_transition_probe/**`
  - `openspec/integrations/rockchip/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/**`
- Forbidden paths:
  - `Packages/**`
  - `ArkDeckApp/**`
  - `openspec/specs/**`
  - `openspec/contracts/**`
- Risk:medium（E1/deviceMutation reboot；flash/erase/format/unlock/update/destructive dispatch 0）
- Hardware required:yes（精确 DAYU200/HDC/firmware/rkdeveloptool/USB topology 窗口）

### Deliverables

- 只允许固定 typed intent：`hdc -t <durable-connect-key> shell reboot loader`；不得接受 caller
  shell/argv。运行前后记录 HDC identity、binding revision、tool hashes 和 mutation lane。
- 逐时捕获 command receipt/exit/stdout/stderr、HDC disconnect、USB VID:PID/topology、bounded
  `rkdeveloptool ld` observations，判定是否直达 `0x2207:0x350a Loader`。
- 对 already Loader（HDC dispatch 0）、HDC unsupported/offline、`0x5000`/wrong mode、timeout、
  多候选与 physical fallback 分别形成诚实结论；不得执行 `ppt/wlx/rd`。
- 给出 exact combination 的 capability verdict：`supported | unsupported | unknown`，以及
  normal→Loader evidence 是否满足 Core auto-rebind threshold；不满足时产品必须人工确认。

### Verification

- 软件进态成功面最多一次 E1 reboot dispatch，destructive dispatch 0；Loader observation
  必须是 semantic `0x350a + Loader`，不能只看 HDC exit 0。
- 取消影响确认、binding mismatch、错误 target、多设备/多候选任一项 → HDC mutation 0。
- transition 失败后按 CHG-2026-016 physical sequence 可进入只读 mode observation；fallback
  不得被记录为 App 自动进态。

### Notes / handoff

- 本任务仅 characterization，不修改产品代码、不扩大 hardware support；run 放在
  `evidence/runs/TASK-RKFUI-001A/`。若 exact combination 未证明 supported，后续产品默认
  physical fallback。

## TASK-RKFUI-001B — RockUSB `ld` homogeneous CRLF integration remediation

- Status:done（implementation/evidence PR #464 已由维护者 review/merge 至 `main`，
  merge OID `c61cc458d2c95545ac57ab5d02d23768635ea2cd`；required guard 与 Swift CI
  通过。本独立 D0 状态 PR 仅记录该确定性结果，不新增 scope、风险接受、授权或设备
  dispatch）
- Platform:macos
- Requirements:`REQ-FLASH-001`
- Acceptance:`AC-FLASH-001-01`
- Depends on:CHG-2026-026 proposal r4 merged；TASK-RKFUI-001 contract/hardening
  (#301/#305) 与 TASK-RKFUI-001A guarded probe (#460) merged
- Allowed paths:
  - `openspec/integrations/rockchip/rockusb-discovery/1.0.0/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipDeviceDiscovery.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipDeviceDiscoveryContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/Rockchip/Discovery/1.0.0/**`
  - `scripts/rockchip_loader_transition_probe/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipRockUSBFlashProvider.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashProfile.swift`
  - `ArkDeckApp/**`
- Risk:low（strict parser/fixture/registry/probe closure；host/device external command、
  mutation/destructive dispatch 0）
- Hardware required:no

### Deliverables

- 原子更新 canonical registry、test resource mirror、resource hash closure、binary fixtures、
  Swift parser/tests 与 Python probe/tests；任一面未同步即测试失败。
- 完整非空 stdout 只接受 homogeneous LF 或 homogeneous CRLF，且每条 record（含最后一条）
  必须有 terminator。raw-byte validation 后只移除 CRLF 自带的一个 CR，再复用既有
  `DevNo/Vid/Pid/LocationID/Mode` grammar。
- 为 single/multi record 的 LF 与 CRLF positive fixtures 建立同义结果；为 bare CR、
  mixed LF/CRLF、missing-final-terminator、empty record 建立 negative fixtures。
- 保持 Maskrom、non-`0x2207:0x350a`、unknown mode、duplicate、garbage、invalid UTF-8、
  stderr、output/device count 与 tool identity 全部门禁不变。

### Verification

- 定向 Swift contract tests 与 Python probe tests 覆盖 LF/CRLF parity 和所有新增 negative
  family；既有 RockUSB discovery/Provider tests 全部通过。
- registry/resource closure hash 与 SDD checker 通过；代码评审确认没有 `.splitlines()` 等
  会静默接受 bare/mixed terminator 的宽松路径。
- 以本次 sanitized 52-byte shape 构造的 CRLF Maskrom fixture 必须解析为一个显式
  wrong-mode observation，随后仍被 capability preflight blocked；不得变成 offline、
  expected Loader 或零 candidate。
- 本任务所有 HDC/`rkdeveloptool`/USB observation、E1/E2、usage reservation、
  `ppt/wlx/rd`、host privilege 与 system mutation 计数均为 0。

### Notes / handoff

- 本任务只修复注册输出 family，不产生逐设备 capability evidence。合入后由
  TASK-RKFUI-001A 在无 pre-existing RockUSB candidate 的明确环境重新运行 E0 preflight，
  evidence 另行通过维护者 PR 接受；在此之前 E1 继续为 0。

## TASK-RKFUI-001C — HDC `3.2.0f` loader-transition exact repin closure

- Status:ready（仅在 proposal r5 由维护者 review/merge 后生效；只允许 host-only
  registry/probe/test closure，所有 HDC/device/USB command 与 mutation dispatch 为 0）
- Platform:macos
- Requirements:`REQ-FLASH-002`、`REQ-DEV-001`、`REQ-DEV-002`
- Acceptance:`AC-FLASH-002-01`、`AC-DEV-001-01`、`AC-DEV-002-01`
- Depends on:CHG-2026-026 proposal r5 merged；TASK-RKFUI-001A guarded probe (#460) 与
  TASK-RKFUI-001B (#464/#465) merged
- Allowed paths:
  - `openspec/integrations/rockchip/loader-transition/1.0.0/registry.yaml`
  - `scripts/rockchip_loader_transition_probe/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/integrations/rockchip/rockusb-discovery/**`
  - `Packages/**`
  - `ArkDeckApp/**`
- Risk:low（exact registry/probe pin closure；host/device external command、E1/E2、
  mutation/destructive dispatch 0）
- Hardware required:no

### Deliverables

- Canonical loader-transition registry 只把 HDC `reportedVersion` 从 `Ver: 3.2.0d` 更新为
  `Ver: 3.2.0f`、SHA-256 从 `48395ba8…d260` 更新为 `05b2bf7a…f83`，并追加 r5 的 exact
  `PR#N@mergeOID` authorization ref；absolute path、ownership、server policy 与其他字段
  byte-for-byte 语义不变。
- Python probe registry closure、FakeRunner/version expectations、README/selftest 与 fixture
  assertions 原子同步；旧 HDC version/hash 必须变成显式 negative drift case，不接受双 pin。
- 记录 current base 与 registry/probe input blob；若 r5 merge OID、new HDC facts 或其他
  registry 字段任一漂移，implementation fail closed 并回到 readiness。

### Verification

- `python3 -m unittest scripts/rockchip_loader_transition_probe/test_probe.py -v` 与
  `selftest-host` 通过；新增 exact new-pin positive 与 old-pin negative。
- registry JSON/SDD checker、diff/allowed-path 与 secret scan 通过；代码评审确认没有
  HDC server lifecycle、device command 或 mutation runner。
- 本任务 HDC、`rkdeveloptool`、USB observation、binding/capability evidence、intent、
  usage reservation、E1/E2、`reboot loader` 与 destructive dispatch 全为 0。

### Notes / handoff

- 001C done 后以独立 D0 状态 PR 恢复 TASK-RKFUI-001A 的 E0 preparation；fresh E0 仍须
  在真实 USB 环境证明 candidate count 0。001C 不接受逐设备 capability evidence。

## TASK-RKFUI-002 — Flash application facade、plan-only UI 与全局 Job presentation

- Status:blocked（等待 CHG-2026-026 approval + TASK-RKFUI-001/001A/001B/001C done）
- Platform:macos
- Requirements:`REQ-FLASH-003`、`REQ-FLASH-004`、`REQ-FLASH-005`、
  `REQ-FLASH-011`、`REQ-UX-001`、`REQ-UX-005`、`REQ-UX-006`、`REQ-I18N-001`
- Acceptance:`AC-FLASH-003-01`、`AC-FLASH-004-01`、`AC-FLASH-005-01`、
  `AC-FLASH-005-02`、`AC-FLASH-011-01`、`AC-UX-001-01`、`AC-UX-005-01`、
  `AC-UX-006-01`、`AC-I18N-001-01`
- Depends on:TASK-RKFUI-001、TASK-RKFUI-001A、TASK-RKFUI-001B、TASK-RKFUI-001C
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashApplicationFacade.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipFlashApplicationFacadeContractTests.swift`
  - `ArkDeckApp/App/ArkDeckApp.swift`
  - `ArkDeckApp/Features/Flash/**`
  - `ArkDeckApp/Resources/Localizable.xcstrings`
  - `ArkDeckAppUITests/Flash/**`
  - `ArkDeck.xcodeproj/project.pbxproj`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipRockUSBFlashProvider.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashProfile.swift`
  - 任何真实 execute/process dispatch 文件
- Risk:medium（host-only archive read/write + plan-only；device mutation/destructive dispatch 0）
- Hardware required:no

### Deliverables

- production/fixture application facade 和不可变 presentation；App ViewModel 不持有 process/
  journal bypass。
- Flash 页面：工具/设备刷新与选择、本地镜像 importer、validation、exact plan、数据影响、
  plan-only Start、normal/切换中/Loader/歧义 mode badge、software-transition capability、物理
  按键 fallback、阶段日志、错误/恢复信息。
- AppShell 仅在 `.flash` 显示 Flash 页面；全局 Job card 跨导航保留状态。
- zh-Hans/en strings、accessibility identifiers、keyboard/screen-reader 可操作的风险信息。

### Verification

- plan-only integration → 真实 Provider validate/makePlan + owned plan Artifact → 全步骤可见、
  mutation/destructive runner 0、finalization success=`planned` / failure=`failed`。
- SwiftUI/XCUITest → Flash 导航、设备/镜像/计划、mode badge、跨页 Job 状态和无颜色危险
  信息可见。
- localization lint/pseudo smoke → 中英文完整且关键控件无字符串拼接。

### Notes / handoff

- 该任务不声称真机一键刷机完成；UI execute control 必须显示 locked/blocked reason。

## TASK-RKFUI-003 — Typed rkdeveloptool execute orchestration 与交互式确认接线

- Status:blocked（等待 CHG-2026-026 approval、TASK-RKFUI-001/001A/001B/001C/002 done、
  non-elevated USB access PASS、软件进态 capability verdict，以及维护者确认
  `REQ-FLASH-015` 解释）
- Platform:macos
- Requirements:`REQ-FLASH-002`、`REQ-FLASH-007`、`REQ-FLASH-008`、
  `REQ-FLASH-009`、`REQ-FLASH-010`、`REQ-FLASH-011`、`REQ-FLASH-012`、
  `REQ-FLASH-013`、`REQ-FLASH-015`、`REQ-DEV-001`、`REQ-DEV-002`、
  `REQ-DEV-003`、`REQ-DEV-006`、`REQ-DEV-008`、`POL-WORKFLOW-001`、
  `POL-RECOVERY-001`
- Acceptance:`AC-FLASH-002-01`、`AC-FLASH-007-01`、`AC-FLASH-008-01`、
  `AC-FLASH-009-01`、`AC-FLASH-010-01`、`AC-FLASH-011-01`、
  `AC-FLASH-012-01`、`AC-FLASH-013-01`、`AC-FLASH-015-01`、
  `AC-FLASH-015-02`、`AC-DEV-001-01`、`AC-DEV-002-01`、`AC-DEV-002-02`、
  `AC-DEV-003-01`、`AC-DEV-003-02`、`AC-DEV-006-01`、`AC-DEV-008-01`
- Depends on:TASK-RKFUI-001、TASK-RKFUI-001A、TASK-RKFUI-001B、TASK-RKFUI-001C、
  TASK-RKFUI-002
- Allowed paths:
  - `Packages/ArkDeckKit/Package.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionAdapter.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipLoaderTransitionAdapter.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipArchiveStaging.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipFlashApplicationFacadeContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipFlashExecutionAdapterContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipLoaderTransitionAdapterContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckFakeRockchipFixture/**`
  - `ArkDeckApp/Features/Flash/**`
  - `ArkDeckApp/Resources/Localizable.xcstrings`
  - `ArkDeckAppUITests/Flash/**`
  - `ArkDeck.xcodeproj/project.pbxproj`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashProfile.swift`
  - BlueTool/upgrade_tool 资源或任意 shell/sudo/helper 接线
- Risk:destructive（实现/fixture 测试必须零真实设备 dispatch）
- Hardware required:no（本任务只做 contract/fake；真机归 TASK-RKFUI-004）

### Deliverables

- safe archive staging（防 traversal/link/device/duplicate/trailing payload）与逐成员 hash 复核。
- typed step executor：固定 argv、executable identity receipt、device lane、storage/power、
  durable intent/outcome、critical safe cancellation、raw output Artifact、semantic parser、
  postflight/recovery。
- `enterUpdater` adapter：already Loader skip；supported combination 从 durable HDC binding
  materialize `reboot loader`；等待 disconnect + bounded `ld` polling + Core rebind；unsupported/
  unknown 转 physical fallback；新 binding revision 前 flash dispatch 0。
- UI exact-plan + 双强确认 + dispatch-time recheck；旧确认在任何 pin 漂移后失效。
- fake executable 覆盖九写成功、marker 错误、exit0 但语义失败、取消、crash window、sleep/
  wake、disconnect、postflight mismatch 和 outcomeUnknown。

### Verification

- 关联 AC → contract/fake/fault injection；真实 RockUSB/external tool launch count = 0。
- 无/错 authority、binding、prerequisite、plan、confirmation 任一项 → Job policyBlocked 或
  preflight blocked，mutation/destructive dispatch 0。
- transition cancel/command failure/no disconnect/wrong mode/timeout/multiple candidate/rebind
  ambiguity → `ppt/wlx/rd` dispatch 0；fixed sleep/unique-device auto-bind/default HDC target 0。
- critical write 期间 cancel/quit → 当前 process 不 force kill、下一 step 不启动、durable
  pending-cancel 可 replay。
- intent 无 outcome → outcomeUnknown，restart 自动 replay 0。

### Notes / handoff

- 若实现需要新 schema、helper、entitlement、Core 解释或 Provider command surface，立即
  blocked 并修订 change；不得在代码中暗扩范围。

## TASK-RKFUI-004 — macOS App 产品路径真机验收

- Status:blocked（等待 TASK-RKFUI-003 done + 独立 readiness/具名设备窗口/精确执行授权）
- Platform:macos
- Requirements:`REQ-FLASH-007`、`REQ-FLASH-008`、`REQ-FLASH-009`、
  `REQ-FLASH-010`、`REQ-FLASH-012`、`REQ-FLASH-013`、`REQ-FLASH-014`、
  `REQ-FLASH-015`、`REQ-UX-001`、`REQ-UX-005`
- Acceptance:`AC-FLASH-007-01`、`AC-FLASH-008-01`、`AC-FLASH-009-01`、
  `AC-FLASH-010-01`、`AC-FLASH-012-01`、`AC-FLASH-013-01`、
  `AC-FLASH-014-01`、`AC-FLASH-015-01`、`AC-FLASH-015-02`、
  `AC-UX-001-01`、`AC-UX-005-01`
- Depends on:TASK-RKFUI-003
- Allowed paths:
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/**`
  - `openspec/verification/hardware-matrix.md`（仅在全部 required hardware AC PASS 后追加
    精确 App build 组合）
- Forbidden paths:
  - `Packages/**`
  - `ArkDeckApp/**`
  - `openspec/specs/**`
  - `openspec/contracts/**`
- Risk:destructive（CORE-2.0.0 下由人类维护者亲自执行；若未来 baseline 改为 standing
  authorization，readiness 仍须逐项 pin 并遵守当时最高权威规则）
- Hardware required:yes（精确 DAYU200/固件/rkdeveloptool/App build/USB 窗口）

### Deliverables

- App UI 端到端 realHardware run：refresh → select → archive validation → exact plan →
  prerequisites/双确认 → software enter Loader（若 capability supported，否则 physical fallback）
  → durable rebind → 九分区 → safe reset → postflight。
- 同窗口负探针：取消确认、篡改一项 pin、postflight mismatch 均零错误推进。
- schema-compliant hardware evidence、脱敏 transcript、App build/tool/archive hashes 和恢复
  路径；只有全部 required AC PASS 才更新 hardware matrix。

### Verification

- 成功面必须由 semantic markers + device reconnect/版本 postflight 共同确认；exit 0 不够。
- 负面必须记录 dispatch count、Job state、certainty、RecoveryGuide；fake/simulation 不计入
  hardware support。

### Notes / handoff

- 发现实现缺陷回 TASK-RKFUI-003 的独立 remediation，不在 evidence PR 混入代码。
