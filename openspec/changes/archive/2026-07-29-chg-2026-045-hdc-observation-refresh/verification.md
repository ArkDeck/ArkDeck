# CHG-2026-045 Verification Plan

> Change:CHG-2026-045-hdc-observation-refresh@r1
> Status:passed # 2026-07-29; concrete run/closure references in proposal.md; only effective after maintainer review/merge
> Core baseline:CORE-2.1.0 (canonical Core AC not claimed)

## Environment

- protected-main checkout on macOS; exact OS, Xcode, Swift and signed App
  build identity are pinned by the future readiness/run;
- ArkDeckKit contract tests use synthetic observation sources and effect
  counters;
- signed App UI tests use only the exact presentation-only fixture argument;
- installed HDC, real devices, raw identifiers, non-loopback product network,
  server/device mutation and D2 windows are forbidden for this change.

## Acceptance matrix

| AC ID | Verification method | Expected result | Minimum evidence |
| --- | --- | --- | --- |
| `HOR-UI-001` | signed localized macOS UI test plus accessibility lookup and callback mutation | a visible refresh action reaches the provider from the production App wiring; removing the callback/action turns the test red | platform + contract |
| `HOR-SESSION-001` | sequential snapshot session contract plus production-root identity/source audit | successive accepted refreshes reuse one candidate/endpoint/session/buffer and expose appeared then disappeared without cross-session stitching | contract |
| `HOR-BOUNDED-001` | delayed fixture, invocation counters, duplicate-action and timer/retry mutations | one accepted action issues one provider refresh and at most one registered snapshot; an in-flight duplicate issues zero additional calls | platform + contract |
| `HOR-SAFETY-001` | forbidden-effect counters, fixture/production separation, source/blob audit and HDC regression suites | no second discovery/source, lifecycle/subserver/device mutation/destructive effect, raw identifier or production fixture value is introduced | contract |

## `HOR-UI-001`

- the HDC diagnostics group contains one refresh button with a stable
  accessibility identifier;
- the control has English and Simplified Chinese localized values and remains
  keyboard/assistive-technology reachable;
- App composition passes only `HDCStatusViewModel.refresh` and its in-flight
  state to the view;
- an exact signed UI fixture starts with the first deterministic presentation;
  one button activation reaches fixture `refresh()` and renders the second;
- removing the callback, disconnecting the button, or omitting a locale makes
  a test fail.

## `HOR-SESSION-001`

- the production provider public interface remains unchanged;
- after initial attachment, manual refresh performs no second discovery and
  does not clear or replace the equal-key device observation session;
- candidate canonical identity, endpoint and execution session identity
  remain the existing session-key inputs;
- two sequential contract snapshots, Connected then all Offline, produce
  ordered `appeared` then `disappeared` events in one capacity-64 buffer with
  the same session pseudonym;
- App restart, executable reselection, two fixtures or two session actors are
  negative controls and cannot satisfy this AC.

## `HOR-BOUNDED-001`

- App admission state is set synchronously before asynchronous provider work;
- while active, the refresh button is disabled and a duplicate request calls
  the provider zero additional times;
- each accepted action contains exactly one provider `refresh()` call;
- the retained session contains the existing one-poll in-flight guard and at
  most one registered source invocation per accepted refresh;
- no timer, `Task.sleep` in the production section, background loop,
  automatic retry, unbounded task queue or navigation-triggered poll exists;
- fixture-only delay/sequencing stays below the fixture boundary.

## `HOR-SAFETY-001`

- the App has no candidate, endpoint, session, runner, argv, process/socket
  fact, receipt or generation construction surface;
- production still internally constructs exactly one registered 3.2.0f
  device source and uses the fixed `list targets -v` argv;
- wrong candidate/hash/path/endpoint, missing listener, identity drift,
  process failure and cancellation remain unavailable/unknown with no
  fallback or mutation;
- automatic lifecycle/adoption, server start/stop/restart, subserver,
  authorization, binding/device mutation and destructive counters remain 0;
- production source contains no fixture flag/value/delay/counter and public
  presentation contains no raw connect key/device identifier;
- all OpenHarmony production, registry/profile/contract/baseline files remain
  byte-identical to readiness pins.

## Negative and recovery tests

- callback absent or view action disconnected → signed UI/contract failure;
- duplicate activation during delayed refresh → no second provider call and
  no third fixture transition;
- candidate/session clear or replacement added to refresh → source/session
  contract failure;
- second discovery, direct source construction in App, extra registered
  snapshot, timer or retry → static/mutation failure;
- unsupported tuple, identity drift, process error or cancellation → bounded
  unavailable result and zero forbidden effects;
- App crash/restart → new session; old/new events cannot be joined as one
  proof;
- fixture flag/value moved above the fixture boundary → separation test
  failure.

## Regression gates

- `swift test --package-path Packages/ArkDeckKit` passes with zero unexpected
  failures;
- focused device-presentation, supervisor, observability and registry suites
  pass;
- signed Debug App build, strict codesign verification and HDC UI tests pass;
- localization catalog parses and both new locale values are asserted;
- `scripts/check-sdd.sh`, checker/path contract suites and
  `git diff --check` pass;
- implementation diff modifies only readiness-approved paths and records no
  installed-HDC/device/product-network dispatch.

## Deviations

Any need for a new provider API, OpenHarmony source/registry/profile change,
new HDC argv, background polling, second candidate/session, Core/AC/schema
change, extra entitlement, real device execution or additional production
file keeps `TASK-HOR-001` blocked and requires an approved proposal revision.
No deviation may be hidden in the implementation PR.

## Result gate

- [x] all four change-local AC have same-revision, reproducible evidence;
- [x] signed fixture/platform evidence is not reported as hardware evidence;
- [x] CHG-045 App/UI/fixture and registry/profile inputs remain
      byte-identical; #777's HDC production file split has a fresh
      current-main contract + signed-platform replay;
- [x] #772 implementation/evidence predates enforcement 2.2.0; the
      implementation-free verification closure reconciles task `done`
      without creating the now-forbidden done-only carrier;
- [x] change `verified` is confirmed in a separate status/evidence-reference
      PR citing the concrete implementation and closure records.

Closure receipt:`proposal.md#verification-closure2026-07-29`; original
verification base =
`c2dd6412d42be259623d5922e82eb43b4b36af74`; implementation evidence =
`evidence/runs/TASK-HOR-001/implementation-r1.md`; closure replay =
`evidence/runs/TASK-HOR-001/verification-r1.md`. Maintainer-approved PR #778
merged as `eb24e6625a345578108781649ed19b2598024ade`, making `passed`, task
`done` and proposal `verified` effective. Because #777 merged immediately
before #778 and changed the pinned HDC production file identity, the required
post-merge current-main replay is
`evidence/runs/TASK-HOR-001/verification-r2.md`; archive remains held until
that D0 evidence rerun is reviewed and merged.
