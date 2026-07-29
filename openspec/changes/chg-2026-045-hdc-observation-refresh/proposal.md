---
id: CHG-2026-045-hdc-observation-refresh
revision: 1
status: approved # only after maintainer review/merge of this approval-only PR
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

- The r1 proposal was added to protected main by PR #766: exact reviewed head
  `4e898ce54b37fafbef776da7c0722a8b728046d5`, squash merge
  `7938cf67a2749a8d7ddb3c86b44fd244705d3974`. Maintainer `lvye` recorded an
  `APPROVED` review on that exact proposal head.
- Formal approval takes effect only when the maintainer reviews and merges
  this approval-only PR. That D1 decision accepts the following closed scope:
  - **User and App boundary:**macOS adds one localized, keyboard/AX-reachable
    HDC diagnostics refresh action. Startup and manual requests enter the
    same App-owned method; one request is admitted at a time and an in-flight
    duplicate causes no second provider call.
  - **Session and effect boundary:**the action calls the existing diagnostics
    provider `refresh()` exactly once and retains the current candidate,
    endpoint, execution identity, `HDCDeviceObservationApplicationSession`,
    capacity-64 buffer and session pseudonym. Each accepted action may invoke
    at most the existing exact registered 3.2.0f `list targets -v` source
    once.
  - **Authority and safety boundary:**the App gains no candidate, endpoint,
    runner, argv, receipt, generation or lifecycle authority. No timer,
    background/automatic retry, second discovery/candidate/session,
    cross-session stitching, server lifecycle/adoption, subserver,
    authorization, binding/device mutation or destructive path is added.
    Core, canonical AC, contracts/schema, baseline, integration/platform
    profile, registry/resource and OpenHarmony production bytes remain
    unchanged.
  - **Verification boundary:**`HOR-UI-001`, `HOR-SESSION-001`,
    `HOR-BOUNDED-001` and `HOR-SAFETY-001` require the layered signed UI,
    session/composition, mutation and forbidden-effect evidence defined in
    `verification.md`. Presentation-only fixture results are
    `platform/contract`, never real-HDC or hardware evidence.
- This approval does not execute the task, accept source/environment pins,
  prove fixture design or tests sufficient, or authorize installed HDC,
  production App, real device or D2-window execution. `TASK-HOR-001` remains
  `blocked` and must receive a fresh independent D1 readiness on then-current
  protected main before any implementation/evidence PR. Its subsequent
  `ready→done`, change `verified`, and CHG-2026-006 fresh D2 readiness remain
  separate decisions.
