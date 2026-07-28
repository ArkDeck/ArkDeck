---
id: CHG-2026-043-hdc-320f-supervisor-observation
revision: 1
status: proposed
class: integration
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# Register and adopt exact HDC 3.2.0f commandless supervisor identity observation

## Why

CHG-2026-006 `TASK-M0B-002` 的 2026-07-28 fresh readiness 在 PR #736
（merge `193b19b2487952c7018e8bbcc77bc67b4197a92b`）继续保持 `blocked`：
production App 只选择一个 `HDCCandidate`，并把同一候选同时交给 server supervisor
观测与 device observation；但现有 server observation authority 只接受 hdc `3.2.0d`
（SHA-256 `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`），
device observation registry 只接受 hdc `3.2.0f`
（SHA-256 `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`）。
当前主机只有后者，故单一候选无法同时建立 server generation/ownership 与设备事件。

CHG-2026-024 已受理 exact 3.2.0f 的工具身份、`127.0.0.1:8710` endpoint 和稳定
process/start/listener bracket，并在 production device source 中实现同一类 commandless
OS identity observer；但该 authority 仅登记为 device-observation precondition，不能被
server supervisor 暗中复用。把两个版本结果拼接、把 device registry 当 supervisor
registry、或从相似补丁版本推断兼容，都会越过 registry 与 provenance boundary。

本 change 建立一个独立、版本化的 3.2.0f commandless supervisor identity authority，
并让 production App 对同一候选显式采用它。它不改变 M0B 验收语义，不执行 HDC/设备，
也不宣称 `checkserver`、client/server/daemon version 或 health 已在 3.2.0f 上登记。

## What changes

### In scope

- 新增独立 registry
  `OPENHARMONY-HDC-SUPERVISOR-OBSERVATION-PROBES@1.0.0`，只登记 exact macOS /
  hdc `3.2.0f` / executable SHA-256
  `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` /
  endpoint `127.0.0.1:8710`；
- 登记 `serverIdentityGeneration` family 为
  `probeKind: platformProcessObservation`、`exactArgv: []`、
  `invocationAllowed: false`：通过 selected executable、exactly-one existing listener、
  PID/start/executable/listener 的稳定 pre/post equality 生成 identity receipt 与
  generation，全路径零 HDC child；
- provenance 只引用已由维护者 review/merge 受理的 CHG-2026-024 controlled capture
  （#656 `af6d64d67af98c94e1f03581de6f52ecdb8a6bb2`、#658
  `6df25c25d0088238ce2700db07c4db6fbd92cc34`）。readiness 必须重新判断这些
  inputs 是否足以支撑 supervisor family；不足则任务保持 `blocked`，不得用合成数据
  或 Agent/CI 实机调用补齐；
- bump OpenHarmony integration profile/lock，并在 macOS profile 添加本 family mapping；
  当前 3.2.0d readonly registry 与 3.2.0f device registry 保持各自独立、byte-identical；
- production composition 继续只选一个 `HDCCandidate`：exact 3.2.0f 候选同时进入新
  commandless supervisor identity route 与既有 device observation route；任何一侧
  都不得再次 discovery 或替换候选；
- 只有新 observer 自身铸造的稳定 receipt/generation 能进入既有 four-evidence ownership
  判断。3.2.0f route 不运行 `checkserver`，server health、client/server/daemon version
  无独立 registered source 时保持 typed unknown；既有 3.2.0d registered
  `checkserver` 行为保持不变；
- 添加 registry/resource hash closure、negative/fail-closed contract，以及同一候选
  production reachability contract。现有 diagnostics 字段足以表达 unknown 与 external，
  本 change 不增加 UI surface。

### Out of scope

- 修改 CHG-2026-006 的 task/readiness/evidence、执行 M0B hardware matrix、把本 change
  的 host-only 结果记作真实设备验收；
- 修改 Core Requirement/Acceptance Scenario、contracts/schema、hardware matrix 或
  Core baseline；
- Agent/CI 执行 installed HDC、访问真实设备、读取 raw device identifiers、启动/停止/
  restart/adopt server，或执行 subserver/device/binding/destructive mutation；
- 为 3.2.0f 登记或推断 `checkserver`、`hdc -v`、health、client/server/daemon version；
- 用两个候选、两个 endpoint、两个 session、caller-supplied receipt/generation、
  patch-version similarity 或 fallback 拼接 server 与 device 事实；
- 改写既有 `OPENHARMONY-HDC-READONLY-PROBES@1.0.0`、
  `OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES@1.0.0` 或其 resource pack；
- 改变 lifecycle、ownership、Job/journal/recovery、device binding 或 event
  disappearance 语义。

## Observable behavior before/after

- Before：exact 3.2.0f 候选可以执行已登记的显式 device refresh，但 server
  observation 返回 unsupported，generation/ownership 保持 unknown；App 不能用同一
  候选形成 CHG-2026-022 所需的完整诊断视图。
- After：在 exact tool/endpoint/existing-listener/stability 全部命中时，同一 3.2.0f
  候选可通过零 HDC child 的 OS observation 铸造 generation；既有 four-evidence
  判断可把真正 pre-existing 且无 managed provenance 的 server 分类为 external，
  同时 device refresh 仍只执行既有注册的单次 `list targets -v`。任一 mismatch/
  ambiguity/drift 都 fail closed，且不会触发 HDC child 或 lifecycle effect。

## Scope

- Canonical Core Requirements claimed:none（兼容实现既有 `REQ-HDC-002`、
  `REQ-HDC-003`、`REQ-HDC-004`、`REQ-UX-002`）
- Canonical Acceptance claimed:none
- Candidate integration profile:`OPENHARMONY-TOOLS@0.6.0`
- Candidate registry:`OPENHARMONY-HDC-SUPERVISOR-OBSERVATION-PROBES@1.0.0`
- Candidate lock:`INTEGRATION-PROFILES-0.7.0`
- Change-local acceptance:`HSO-REGISTRY-001`、`HSO-SEPARATION-001`、
  `HSO-SINGLE-CANDIDATE-001`、`HSO-NODISPATCH-001`
- Core baseline bump:no

Candidate version numbers are the next unused values at proposal base `193b19b…`; readiness
must re-audit main and re-pin them. A collision is a blocker, not permission to silently reuse
or overwrite a concurrent version.

## Platform impact

| Platform | Disposition | Reason |
| --- | --- | --- |
| macOS | integration mapping candidate; no conformance transition | 只增加 exact 3.2.0f commandless identity authority 与 consumer wiring |
| Windows | deferred / unchanged | port 未启动；无对应 process/listener observer 或 provenance |
| Linux | deferred / unchanged | port 未启动；无对应 process/listener observer 或 provenance |

## Safety, privacy, and compatibility

- 入口默认 unavailable/unknown；路径、hash、endpoint、listener count、PID/start 或
  pre/post equality 任一不匹配都不能产生 receipt/generation；
- receipt 必须由不可注入的 platform observer 从 OS process/socket state 生成；调用方不能
  同时构造事实和证明。caller-supplied PID/start/path/hash/endpoint 不具 authority；
- identity route 的 HDC child、server lifecycle/adoption、subserver、device/binding/
  destructive dispatch counter 必须全部为 0；显式 device refresh 仍至多执行既有
  registry 允许的一个 read-only child；
- process identity 只用于本机 session 内的 ownership/generation 判断，不引入 raw device
  identifier，也不新增持久敏感字段；
- rollback 先回退 production consumer，再回退新 registry/profile/lock；既有 3.2.0d
  supervisor 与 3.2.0f device observation authority 保持完整，3.2.0f server ownership
  安全退回 unknown。

## Approval and flow

本 proposal PR 只创建 change package，零 integration/production 实现、零 task 状态推进、
零 HDC/设备调用。批准须由后续独立 approval-only PR 完成；两个 task 初始均
`blocked`。批准合入后先对 `TASK-HSO-001` 走独立 readiness（D1），其
implementation/evidence 与 `ready→done` 各自独立；然后才能对依赖它的
`TASK-HSO-002` 走独立 readiness（D1）。本 change 全部 AC 通过后的 `verified`
翻转，以及 CHG-2026-006 `TASK-M0B-002` 的新一轮 readiness，也都必须使用独立 PR。
