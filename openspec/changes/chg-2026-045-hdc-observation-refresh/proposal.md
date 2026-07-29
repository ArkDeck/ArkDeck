---
id: CHG-2026-045-hdc-observation-refresh
revision: 1
status: verified # 2026-07-29 本 verification closure；仅在维护者 review/merge 本 PR 后生效
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# Expose an explicit in-session HDC observation refresh in the macOS App

## Why

CHG-2026-006 `TASK-M0B-002` fresh readiness r3 was accepted by PR #764
(exact head `5407d8878c60e199599ec52e3c40e01991adfcac`, protected-main merge
`1227ea8c156f4814cf42278fb1a806bba632a406`). It confirmed that
CHG-2026-043 has removed the earlier HDC 3.2.0d/3.2.0f single-candidate
conflict, but found a new production-reachability blocker:

- `ArkDeckApp.swift` calls diagnostics `refresh()` once from the window
  startup `.task`;
- `HDCStatusView` has no user-reachable diagnostics refresh action;
- executable selection and lifecycle preview/confirmation paths only overlay
  the current device-event buffer and do not poll the existing device
  observation session again.

The registered 3.2.0f device observation computes `appeared` and
`disappeared` by differencing successive snapshots in one bounded session.
One startup poll can establish only one side of that transition. Restarting
the App, recreating the window, reselecting the executable, using the UI
fixture, or stitching two sessions would reset or replace the session and
cannot serve as the production real-hardware observation method required by
`HW-M0B-DAYU200-SUPERVISOR-001`.

This change adds the missing macOS App route to the already-existing
`HDCApplicationDiagnosticsProviding.refresh()` operation. It does not add a
new HDC command, registry entry, authority, polling policy, lifecycle action,
or Core acceptance interpretation.

## What changes

### In scope

- add a visible, keyboard- and accessibility-reachable “refresh HDC
  diagnostics” action to the production `HDCStatusView`;
- localize the new control in English and Simplified Chinese and give it a
  stable accessibility identifier;
- wire that action through the existing App-owned `HDCStatusViewModel` to
  exactly one call of the existing diagnostics provider `refresh()`;
- make refresh admission explicit at the App boundary: startup and user
  refreshes use the same method, an accepted refresh marks itself in flight
  synchronously, the refresh control is disabled while it is in flight, and
  duplicate requests during that interval dispatch no second provider call;
- retain the current production candidate, endpoint, execution identity and
  `HDCDeviceObservationApplicationSession`; refresh must not clear, replace or
  rediscover them;
- preserve the existing registered 3.2.0f source contract: at most one
  `list targets -v` child per accepted refresh, one bounded event buffer and
  one session-scoped pseudonym key;
- add a narrowly flagged presentation-only UI fixture sequence plus signed
  macOS UI tests to prove that the visible button reaches the provider;
- add source/composition and session contract tests proving that two
  sequential accepted actions can expose `appeared` then `disappeared` in
  one session, while in-flight duplicates and all forbidden effect classes
  remain closed.

### Out of scope

- modifying CHG-2026-006 tasks, acceptance, hardware matrix or evidence;
- executing `TASK-M0B-002`, scheduling/consuming a D2 device window, or
  claiming real-hardware/support/release evidence;
- changing any Core Requirement/Acceptance Scenario, baseline, contract,
  schema, integration/platform profile, HDC registry/resource or registered
  argv;
- adding timers, background polling, automatic retry, refresh-on-navigation,
  refresh-on-lifecycle-action or any other non-user-triggered device poll;
- a second discovery, candidate, endpoint or observation session; clearing
  the current buffer/HMAC key as part of refresh; cross-session event
  stitching;
- starting/stopping/restarting/adopting an HDC server, subserver operations,
  authorization retry, binding/device mutation, destructive dispatch or a
  new process runner exposed to the App;
- exposing raw connect keys, raw device identifiers, PID/process/socket
  facts, command argv or fixture values through the production App;
- changing existing HDC UI text beyond the new localized refresh control.

### Observable behavior before/after

- **Before:**the App performs one diagnostics/device observation at startup.
  A user cannot request a second snapshot in the same session.
- **After:**once the startup refresh completes, the user can explicitly
  request another refresh from the HDC diagnostics panel. Each accepted
  action updates the same bounded presentation and may execute only the one
  already-registered read-only device snapshot. While a refresh is active,
  duplicate requests are unavailable and produce no additional poll.

## Scope

- Canonical Core Requirements claimed:none; compatible macOS implementation
  of `REQ-UX-002`, `REQ-HDC-002`, `REQ-HDC-003`, `REQ-HDC-004` and
  `REQ-I18N-001`
- Canonical Acceptance claimed:none
- Change-local acceptance:`HOR-UI-001`, `HOR-SESSION-001`,
  `HOR-BOUNDED-001`, `HOR-SAFETY-001`
- Contracts/schemas:none
- Core baseline bump:no; remains `CORE-2.1.0`

## Platform impact

| Platform | Disposition | Reason |
| --- | --- | --- |
| macOS | platform implementation candidate; no conformance transition | adds a SwiftUI route to the existing diagnostics provider |
| Windows | deferred / unchanged | port not started; no support claim or Core exemption |
| Linux | deferred / unchanged | port not started; no support claim or Core exemption |

## Safety, privacy, and compatibility

- The App control carries no candidate, endpoint, argv, process runner or
  lifecycle authority. Existing Workflows/OpenHarmony production factories
  remain the only authority and effect boundaries.
- Missing candidate/session, unsupported tuple, identity drift, process
  failure or cancellation remains fail closed. The action cannot fall back
  to another tool/endpoint or start a server.
- Refresh admission is bounded at both layers: the App accepts one request at
  a time and the existing observation actor permits at most one poll in
  flight. There is no timer or unbounded queue.
- The event buffer stays capped at 64 and stores only timestamp, closed event
  kind and session-HMAC redacted identifier. No new persistence or schema is
  introduced.
- The exact UI fixture is presentation-only and structurally cannot construct
  a production lifecycle dispatcher or HDC runner. Its results are test
  evidence only, never hardware evidence.
- Rollback removes the App callback/control/localizations and its tests as
  one unit. The existing startup refresh and registered observation source
  remain intact, while TASK-M0B-002 safely returns to its current blocker.

## Approval and flow

This proposal PR creates only the change package. It contains no App,
Workflows, test or localization implementation, advances no task status and
executes no HDC/device/App production path.

Formal approval requires a separate approval-only PR. `TASK-HOR-001` starts
`blocked`; after approval it still requires an independent D1 readiness PR
that re-pins current protected-main sources, exact signed-App test
environment, complete allowed paths and the mutation/negative matrix.
Implementation/evidence, `ready→done`, change `verified`, and the subsequent
CHG-2026-006 `TASK-M0B-002` fresh D2 readiness each remain separate PRs.

## Approval

- The r1 proposal was merged to protected main by PR #766 (squash
  `7938cf67a2749a8d7ddb3c86b44fd244705d3974`, `status: proposed`);
  maintainer `lvye` approved exact head
  `4e898ce54b37fafbef776da7c0722a8b728046d5`.
- Formal approval takes effect only when the maintainer reviews and merges
  this approval-only PR. That D1 decision accepts only the following closed
  scope:
  - **route:**one visible, localized and accessible user action may call the
    existing diagnostics provider `refresh()`; startup and manual requests
    share one synchronous App admission gate;
  - **identity and bounds:**an accepted refresh retains the production-selected
    candidate, endpoint, execution identity, observation actor, capacity-64
    buffer and session pseudonym key, and permits at most the one existing
    registered read-only `list targets -v` snapshot;
  - **forbidden effects:**no timer, retry, background polling, second
    discovery/session/source, new provider API or HDC argv, server lifecycle
    or adoption, subserver, authorization, binding/device mutation,
    destructive effect, raw identifier exposure or Core/profile/registry
    change;
  - **evidence boundary:**`HOR-UI-001`, `HOR-SESSION-001`,
    `HOR-BOUNDED-001` and `HOR-SAFETY-001` are change-local only; signed UI
    fixture evidence remains `platform`, contract evidence remains
    `contract`, and neither is hardware evidence or a CHG-2026-006
    acceptance result.
- This approval does not execute a task, accept readiness pins or validate an
  implementation. `TASK-HOR-001` remains `blocked` until a separate D1
  readiness PR is merged; implementation/evidence, `ready→done`, change
  verification and later CHG-2026-006 hardware readiness remain separate
  decisions.

## Verification closure（2026-07-29）

`TASK-HOR-001` 的实现与 same-revision evidence 已由 PR #772 合入 protected
main。四条 change-local AC 均有可复查的 `contract` / signed macOS
`platform` evidence。本 PR 只翻转 task/change/verification 状态、更新 evidence
索引并引用已合入 run 与本次复验记录；零产品实现、零 scope、零 acceptance
定义或 authority 变化。

Verification base = protected main
`c2dd6412d42be259623d5922e82eb43b4b36af74`。改前 proposal、tasks、
verification、acceptance cases 与 implementation run blobs 分别为
`695d4317b6e017da77b17ac6984ad0fc422a0ab9`、
`bf346551b508bab815303f4ffbcee72adf8ebeff`、
`69aa73e0eac697e9c0f71a1492a946f56b128925`、
`b99e627b2bce9166cc9fd8abaae9e4ce5c30a141` 与
`c8e104d809d6bcc9813b9ea5977ae64592a27680`。

### Protected-main delivery chain

| Stage | Exact reviewed head | Protected-main merge |
| --- | --- | --- |
| proposal #766 | `4e898ce54b37fafbef776da7c0722a8b728046d5` | `7938cf67a2749a8d7ddb3c86b44fd244705d3974` |
| approval #768 | `7441fd4075830f3169e35715da459f01a2d2dede` | `f1214137bd80c2544209dcd95ac32a869982ec06` |
| readiness #770 | `7a1c4222a241bb1d3b25f57b549d2e5820df614f` | `333eec928cbbd7f273abffeebb3970f15ed33554` |
| implementation/evidence #772 | `25a0d4a3789fdda985f9f13057e7e0dd8f217bde` | `7125cda045cb45ccb992997bcbe43fa5da90bdb3` |

四个 exact heads 均由维护者 `lvye` review/approve；#772 的 Agent PR
open-pr/allowed-paths、SDD Guard 与 Swift CI 均为 `SUCCESS`。AC 真值源是
`evidence/runs/TASK-HOR-001/implementation-r1.md`，不是实现 PR 被 review
这一事实本身。

### Four binary AC conclusions

- **`HOR-UI-001` = PASS (`platform` + `contract`)**：#772 run 的 signed
  macOS HDC UI suite 16/16，覆盖 English / Simplified Chinese、稳定 AX
  identifier、mouse 与 Command-R，以及 production App callback reachability。
- **`HOR-SESSION-001` = PASS (`contract`)**：同一 actor 的 sequential
  snapshots 产生 ordered `appeared` → `disappeared`；candidate canonical
  identity、endpoint、execution-session identity、pseudonym 与 capacity-64
  buffer 保持不变，零跨 session stitching。
- **`HOR-BOUNDED-001` = PASS (`platform` + `contract`)**：App admission
  同步置位，每个 accepted action 恰一次 provider call；十秒 delayed fixture
  中 duplicate action 零额外 call/transition，refresh 与 executable selection
  在途禁用；production 无 timer/retry/queue。
- **`HOR-SAFETY-001` = PASS (`contract`)**：六个实现 blobs 与
  `HDCProduction.swift`、OpenHarmony registries/profile/lock、macOS profile
  自 #772 后零漂移；provider protocol 与 production section 零变化。run
  记录 installed HDC、真实设备、server lifecycle、subserver、authorization/
  adoption、binding/device mutation、destructive 与 non-loopback product
  network dispatch 全为 0。

### Closure-base replay and boundary

复验记录见
`evidence/runs/TASK-HOR-001/verification-r1.md`：五个聚焦 HDC suites
132/132；ArkDeckKit 全量 557 tests、一个既有 opt-in manual sleep/wake skip、
零失败；check-sdd 0 errors / 0 warnings / 111 IDs；checker 62/62、
allowed-paths 50/50、localization parse/compile 与 `git diff --check` 均通过。
当前重建 App/runner 的 strict codesign 通过。

额外 signed UI replay 因主机处于锁屏状态，被 macOS LocalAuthentication 在
0 tests 执行前拒绝；该尝试不计为 PASS，也未请求或授予任何系统权限。Closure
的 UI 结论只引用 protected-main 上 exact implementation revision 的 16/16
signed evidence；六个相关实现/test blobs 与 production authority inputs 均保持
字节一致。

PR #772 于 enforcement 2.2.0 / CHG-2026-046 生效前合入，按当时规则未携带
`ready→done`。现行 2.2.0 已废止 done-only PR；因此本 verification-only
closure 在不夹带实现的前提下同时对齐 task `done`，内容仍仅为状态与 evidence
引用。

本 closure 不产生 installed-HDC、real-device 或 hardware evidence，不改变
Core/platform conformance/support/release。只有维护者 review/merge 本 PR 后，
`verified` / `passed` / `done` 才生效。CHG-2026-006 `TASK-M0B-002` 仍须另走
fresh D2 readiness，不能由本 closure 自动推进。
