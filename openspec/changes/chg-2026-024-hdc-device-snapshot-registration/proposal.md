---
id: CHG-2026-024-hdc-device-snapshot-registration
revision: 1
status: approved # 2026-07-21 本 approval-only PR；r1 proposal 经 #272 合入 main `cdfc181`；批准由维护者 review/merge 本 PR 构成
class: integration
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# Register a parameterized HDC device-observation snapshot family

## Why

CHG-2026-022 r2 已由维护者合并（PR #268，merge
`35a8aee2026daaa12ce2c7de91eb5d3fd77277cc`），并把 TASK-OBS-001 恢复为
`blocked`。其首项解除前置要求一个独立 approved/done integration change，注册
parameterized zero-to-many 只读设备 snapshot family 并同步 macOS mapping。

当前 `OPENHARMONY-HDC-READONLY-PROBES@1.0.0` 的
`selectedDeviceAuthorizationBinding` 只允许 exact `list targets -v` capture 与一个
既有 durable binding identity/revision 精确匹配。它不能表示任意设备集合、成功的
empty snapshot、周期 observation 或 disappearance；不同 row 即使匹配另一个 binding
也必须返回 unknown。把该 family 直接当设备枚举会绕过 CHG-2026-015 的 registry、
provenance 和 authority boundary。

本 change 只注册一个独立、版本化的 device-observation integration input。它不接入
production App、不实现 fan-out、不改变 binding/authorization，也不执行 Agent/CI
真实 HDC 或设备命令。

## What changes

### In scope

- 新增独立 registry `OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES@1.0.0`，目标
  integration profile 为 `OPENHARMONY-TOOLS@0.4.0`；现有
  `OPENHARMONY-HDC-READONLY-PROBES@1.0.0` 保持 byte-identical；
- 登记 `deviceObservationSnapshot` family：exact argv、selected executable identity、
  exact endpoint、valid bracketed existing-server identity、bounded stdout/stderr/exit、
  parameterized zero/one/many row grammar、typed empty/snapshot/unknown、timeout、
  cancellation、effect 与 provenance；
- authoritative inputs 必须覆盖成功 empty、single-row、multi-row、稳定重复、出现和
  消失序列。raw connect key/serial/用户路径不入仓；受控 raw 留在维护者位置，仓库只
  保存 hash、长度、row count、脱敏结构 receipt 和 accepted-by；
- whole-output fail closed：任一未登记 column/state/transport、duplicate identity、
  mixed failure marker、stderr、nonzero exit、truncation、identity/endpoint drift、timeout
  或 cancellation 使整份 snapshot 为 unknown，不能把 unknown 当 empty；
- snapshot 只建立“本次 registered observation 中出现的设备 pseudonym set”。它不能
  选择 default target、创建/修改 durable binding、证明 authorization/channel
  protection、推断物理拔出原因，或授权任何 device/lifecycle/subserver mutation；
- bump Integration profile/lock，并同步 macOS profile 的 family mapping；新增 versioned
  redacted receipt/control resource 与 contract tests，固定 registry/profile/lock/resource
  hash closure；
- 完成后只为 CHG-2026-022 后续独立 readiness 提供 integration input。production
  producer、轮询 cadence、fan-out、presentation 与 App UI 仍归 CHG-2026-022。

### Out of scope

- 修改 `Packages/ArkDeckKit/Sources/**`、`ArkDeckApp/**`、Core specs/contracts/schema、
  CHG-2026-022 状态或其 implementation；
- 改写/替换既有 read-only registry、CHG-015 evidence、CORE-2.1.0 conformance pins；
- Agent/CI 执行 installed HDC、访问真实设备、启动/停止/restart/adopt HDC server、执行
  subserver/device/destructive mutation 或非 loopback 网络；
- 把 plug/unplug capture 当硬件支持、release、authorization 或 binding evidence；
- 用 agent-authored fake bytes、宽松正则、exit 0、connect-key shape 或 caller assertion
  将 family 提升为 supported。

## Observable behavior before/after

- Before：没有 production-authoritative arbitrary-device snapshot family；任意集合与
  empty/disappearance 只能 unknown。
- After registration done：版本感知 consumer MAY 读取封闭
  `deviceObservationSnapshot` entry；仅完整 precondition/provenance/grammar 满足时得到
  typed empty 或 pseudonym set，其他结果继续 unknown。registration 本身不产生事件，
  不让 CHG-2026-022 自动 ready。

## Scope

- Canonical Core Requirements/AC claimed:none
- Integration input:`OPENHARMONY-TOOLS@0.3.0` +
  `OPENHARMONY-HDC-READONLY-PROBES@1.0.0`（只读基线）；candidate
  `OPENHARMONY-TOOLS@0.4.0` +
  `OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES@1.0.0`
- Change-local acceptance:`I24-HDC-DEVICE-SNAPSHOT-001`、
  `I24-HDC-DEVICE-EMPTY-001`、`I24-HDC-DEVICE-PROVENANCE-001`、
  `I24-HDC-DEVICE-REGISTRY-001`、`I24-HDC-DEVICE-NODISPATCH-001`
- Core baseline bump:no

## Platform impact

| Platform | Disposition | Reason |
| --- | --- | --- |
| macOS | integration mapping candidate; no conformance transition | 需要 exact 3.2.0d controlled capture 与后续 consumer readiness |
| Windows | deferred / unchanged | port 未启动，无 capture/support 声明 |
| Linux | deferred / unchanged | port 未启动，无 capture/support 声明 |

## Safety, privacy, and compatibility

- 新 registry 是独立 allowlist，不修改已被 M1-006/Core conformance pin 的 1.0.0
  registry；旧 consumer 保持 0.3.0 行为；
- command entry 必须要求 independent existing-server receipt；server absent 或 identity
  drift 时不得通过执行 command 探测安全性；
- raw identifiers 只在 observation process 内短暂存在。consumer adoption 必须用
  session-scoped keyed pseudonym；持久日志、presentation、receipt 和 repository 禁止
  raw connect key/serial；
- successful empty 是 authoritative registered output，unknown/failure 永不等价 empty；
- rollback 是独立 revert registration implementation PR；不删除旧 registry/evidence，
  CHG-2026-022 保持 blocked。

## Approval and flow

本 proposal PR 只创建 change package，零实现、零 capture、零 evidence、零设备命令。
批准须独立 approval-only PR；TASK-I24-001 初始 blocked。维护者提供并 review 受控
capture/provenance 后，另起 readiness PR；implementation+evidence、`ready→done`、
change `verified` 与 CHG-2026-022 adoption/readiness 均使用独立 PR。

## Approval

- r1 proposal 经 PR #272 合入 main（squash `cdfc181`，`status: proposed`）。
- 正式批准：2026-07-21 由本 approval-only PR（先例 #55/#89/#171/#195/#226/
  #253/#254/#266）将本 change 置为 `approved`；批准由维护者 review/merge 本 PR
  构成。merge 即批准：
  - **单任务 scope 与边界**：TASK-I24-001 只登记独立、版本化的
    `deviceObservationSnapshot` integration input、同步 profile/lock/macOS mapping 并
    提供 contract/evidence closure；production producer、轮询 cadence、fan-out、
    presentation 与 App UI 仍归 CHG-2026-022，既有 readonly registry、Core 与
    production Sources 保持在 forbidden scope；
  - **design 硬边界**：existing-server-only 与稳定 pre/post identity/endpoint bracket，
    whole-output fail closed，successful empty/snapshot/unknown 严格区分且不发 partial
    set；session-scoped keyed pseudonym、raw identifiers/streams 留仓库外；零 server
    lifecycle/adoption、subserver/device/binding mutation 与 destructive effect；
  - **验收面**：五条 change-local AC（I24-HDC-DEVICE-SNAPSHOT/EMPTY/PROVENANCE/
    REGISTRY/NODISPATCH-001）；canonical Core AC 零认领、Core baseline 不升版，macOS
    mapping 不产生 platform conformance transition。
- 本批准不产生任务执行：TASK-I24-001 保持 `blocked`，仍须维护者受控 capture/
  provenance 经独立 PR review/merge，并由独立 readiness PR 完整重钉 inputs、hashes、
  scope 与 test matrix 后才可转 `ready`。本批准不构成 HDC/设备支持、authorization、
  binding、hardware/release evidence，也不会使 CHG-2026-022 自动 ready。
