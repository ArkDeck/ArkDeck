# OpenHarmony Tool Integration Profile

> ID：OPENHARMONY-TOOLS  
> Version：0.3.0
> Status：in baseline CORE-1.0.0（ratification 状态见 `openspec/baselines/CORE-1.0.0.yaml`） / version-probed at runtime  
> Core baseline：CORE-1.0.0

本文件记录当前 OpenHarmony/HDC 工具语义和 Adapter 输入。它不是平台 Profile，也不得覆盖 Core；任何具体命令都必须经当前 tool/device probe 证实。每个执行 Task SHALL 固定本文件的 version 与 SHA-256；parser family、命令映射或 capability 判断变化必须走 integration change。

## HDC host topology

- HDC 是 client/server/daemon；默认 host server 端口通常为 8710；
- `OHOS_HDC_SERVER_PORT` 和显式 `-s` 影响 endpoint，显式参数优先级由当前 HDC 指南/探测确认；
- 设备命令使用当前 durable binding 的 `hdc -t <connectKey>`；
- 只读环境诊断候选包括 version、checkserver、`list targets -v` 及等价命令；
- API 26.0.0+ subserver 能力只探测，不在 MVP 自动管理；
- macOS/Linux 当前实现常见 key 位于 `~/.harmony/hdckey(.pub)`，但 Core 不硬编码，Adapter 只报告当前工具证据；
- Unauthorized parser 覆盖 E000002/E000003 等已验证输出 family，未知输出保留 raw；
- `OHOS_HDC_ENCRYPT_CHANNEL` 当前文档默认关闭；设置值不等于已成功协商，仍需 connection evidence。

## HiDumper

CHG-2026-008/TASK-UD-001 固定 WindowManagerService wrapper。下列均为 remote executable
`hidumper` 的 argv 数组，不是 host shell command；`-a` 后的 service argument 是单一 argv
元素，只能由固定 token 与通过 `validated-identifier` 规则的 window/component ID 组成：

| Operation | Fixed argv |
| --- | --- |
| window inventory | `["-s", "WindowManagerService", "-a", "-a"]` |
| `nodeSummary` | `["-s", "WindowManagerService", "-a", "-w <windowId> -default"]` |
| `elementTree` | `["-s", "WindowManagerService", "-a", "-w <windowId> -element -c"]` |
| `fullDefaultTree` | `["-s", "WindowManagerService", "-a", "-w <windowId> -default -all"]` |
| `componentDetail` | `["-s", "WindowManagerService", "-a", "-w <windowId> -element -lastpage <componentId>"]` |

M0B 登记的只读 service-list probe argv 为 `["-ls"]`，其 stdout success marker 仅为
`System ability list:`。`hidumper: option <token> missed...` 是显式 failure marker，即使 exit
code 为 0 也必须失败；缺少所选 family 的登记 marker 时为 `unknownOutput`。当前未登记四个
Recipe 的成功输出 family，因此 Recipe 输出不得借用 service-list marker 或凭 exit code/非空
输出判成功；增加 Recipe success family 仍须新的批准 integration change 与 byte-pinned golden。

Recipe 数据位于 `openspec/contracts/catalogs/dump-recipes.yaml`。Adapter 必须处理 stdout、sidecar、固定旧文件名和 unknown output family，禁止全局 `/data` cleanup。

## Trace tools

- 分别 probe hitrace/bytrace 的存在、help/list、duration、buffer、output、begin/finish 和 tag；
- logical preset 位于 `openspec/contracts/catalogs/trace-presets.yaml`；
- remote path 使用 Job UUID 隔离，推荐 `/data/local/tmp/arkdeck/<jobUUID>/`，但设备权限/Profile 可选择等价 owned path；
- raw ftrace 由 host 后处理；固定删除前两行被禁止，除非 parser 证明是 chatter。

## Parameters

附件 Debug Profile 位于 `openspec/contracts/catalogs/debug-parameters.yaml`。Adapter 逐项 probe、读写、read-back，并遵守 missing/unreadable/value 与恢复 contract。

## HiLog

- 以当前 `hilog --help` 和权限 probe 选择等级、domain/tag、PID、buffer 和 device-side logging options；
- `hilog -r` 等清 buffer 命令在常见版本中是全局破坏性操作，只能作为显式危险 action；
- 参数语义未知时只使用 host stream/rotation，不猜测 device buffer mutation。

## HDC/flashd

首个 Provider 的研究路径包括：进入 updater/flashd、`hdc flash <partition> <image>`、`hdc update <package>` 以及显式选择的 erase/format。所有命令都必须由目标 toolchain/device probe 和 Profile 验证；它们不适用于 fastboot/厂商协议，也不证明 production user build 可 root/unlock。

## Golden fixture families（pack 1.0.0，registered by CHG-2026-005/TASK-I5-001）

Fixture pack：`Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Golden/1.0.0/`
（registry：`registry.json`；逐 fixture ID/stream/exit/classification/lineage/SHA-256 与
`INTEGRATION-PROFILES.lock.yaml`、`core-conformance.yaml` 三方一致登记）。观测来源：
hdc client/server `Ver: 3.2.0d`（binary SHA-256
`48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`，macOS 26.5.2 受控人工
capture 2026-07-18；failure 字节为 M0A 候选原样提取）。

| Family | Fixture ID | Probe/来源命令 | 真实输出形态（3.2.0d） | Semantic mapping |
| --- | --- | --- | --- | --- |
| failure（unauthorized） | `hdc-golden-failure-unauthorized` | 命令结果（M0A 候选） | `[Fail] ErrorCode: E000003 Unauthorized device` | `failure.unauthorized` |
| failure（offline） | `hdc-golden-failure-offline` | 命令结果（M0A 候选） | `[Fail] Offline after transfer` | `failure.offline` |
| success | `hdc-golden-success-uninstall` | `hdc uninstall <bundle>`（exit 0） | `[Info]... msg:uninstall bundle successfully.` + `AppMod finish`（CRLF） | `success` |
| healthy | `hdc-golden-healthy-checkserver` | `hdc checkserver`（exit 0） | `Client version:Ver: X, server version:Ver: X` | `healthy` |
| version | `hdc-golden-version` | `hdc -v`（exit 0） | `Ver: X` | `version` |

**Success-marker 实测披露**：3.2.0d 的 install/uninstall 成功输出**不含** M0A parser 假设的
`[success]` 标记；真实成功语义由 `msg:... successfully.` + `AppMod finish` 承载。当前 parser
对该 fixture 判 `unknownOutput`（由 `HDCGoldenResourceContractTests` 钉死）。按登记形态接线
parser 属于 TASK-M1-006，不得以放宽正则或静默改标记的方式提前采用；未登记 output family
一律维持 unknown/unsupported，exit 0 单独不构成 success。

## HiDumper golden fixture families（pack 1.0.0，registered by CHG-2026-008/TASK-UD-001）

Fixture pack：`Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HiDumper/Golden/1.0.0/`
（registry：`registry.json`；通过 SwiftPM `.copy("Fixtures/HiDumper")` 以
`Bundle.module/HiDumper/Golden/1.0.0/` 暴露）。来源为维护者在 2026-07-18 以只读白名单命令
完成的 M0B controlled human capture `EVD-M0B-DAYU200-20260718-001`；redacted manifest
self-check 通过。登记保持 observed-only，不构成 Recipe、兼容性、conformance、hardware
support 或 release claim。

| Fixture ID | Command/stream | Bytes | SHA-256 | Registered semantic role |
| --- | --- | ---: | --- | --- |
| `hidumper-golden-help-stdout` | `hidumper --help` / stdout | 34 | `a4904901becfb1a15517c14c51f6fa26524162008578bab3dc64f1c7baa006e5` | exit-0 `failure.explicitFailureMarker` |
| `hidumper-golden-help-stderr` | `hidumper --help` / stderr | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | empty |
| `hidumper-golden-services-stdout` | `hidumper -ls` / stdout | 3121 | `351fc59ea33de263a6123c6030624e1a1fcd17ae0eb5dab6d67ffba09ec07a4b` | `success.systemAbilityList` |
| `hidumper-golden-services-stderr` | `hidumper -ls` / stderr | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | empty |

## Supported family rule

Parser/Adapter 只支持声明并有 golden fixture 或真实 evidence 的 output family。未知 family 显示 unsupported/raw detail。增加 family 属于 integration change，不得通过宽松正则把未知错误判为成功。
