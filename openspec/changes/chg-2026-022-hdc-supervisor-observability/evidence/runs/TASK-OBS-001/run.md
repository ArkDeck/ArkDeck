# TASK-OBS-001 implementation run

> Status: invalidated by review; do not use as acceptance evidence.
>
> The host-only commands below passed, but review found that the approved
> readiness/design cannot establish the production reachability required by
> OBS-FANOUT-001 or the non-forgeable spawn-boundary semantics required by
> OBS-COUNTER-001. Review also found an incomplete managed-ownership exclusion
> and non-exact readiness pins. This run is retained only as reproducible
> implementation-branch diagnostics pending a CHG-2026-022 revision.

- Executed at: 2026-07-21T13:15:34Z
- Environment: macOS 26.5.2 (25F84), arm64; Apple Swift 6.3.3;
  CPython 3.14.6 + PyYAML 6.0.3 for the SDD guard.
- Evidence class: contract / fake process control / host-only.
- Hardware: none. No real HDC, device, network, lifecycle mutation, subserver
  mutation, or destructive operation was used.
- Baseline: CORE-2.1.0; implementation started from main
  `f3c9685ea70b32099c20bf7fe022bbc9aa688709` after the readiness SHA-256 pins
  for the three named production files were rechecked and matched.

## Implemented surface

- Added mandatory closed process-dispatch origins and actor-isolated automatic
  lifecycle/subserver counters at the identity-bound process dispatch boundary.
  Production source contains only `readOnlyProbe` and `confirmedLifecycle`
  origins; fake mutation controls cross the process boundary with
  `automaticLifecycle` / `automaticSubserver` and make both counters increment.
- Added the approved three-item ownership basis. A bracketed pre-existing
  process/listener receipt + zero automatic lifecycle dispatches + an
  observation-minted generation classifies `.external`; every missing/negative
  matrix case remains `.unknown`. The basis is retained in supervisor state and
  diagnostics presentation.
- Retained endpoint source and child-only injected environment-key names in the
  in-memory toolchain snapshot and diagnostics presentation. No durable Core
  schema was changed.
- Added a commandless read-only device-snapshot feed, appeared/disappeared diff,
  host-wide fan-out event, existing-policy `redacted-device-<digest>` identifier
  shape, and a 32-event presentation ring buffer. The registered selected-device
  read-only probe supplies a snapshot only after its full existing authority
  gate succeeds; unknown output never becomes an absence claim.

## Verification

| Command / check | Result |
| --- | --- |
| `swift test --package-path Packages/ArkDeckKit --filter HDCSupervisorContractTests/testTEST_OBS_` | PASS: 5 tests, 0 failures. Covers `OBS-COUNTER-001`, `OBS-OWNERSHIP-001`, `OBS-ENDPOINT-001`, and `OBS-FANOUT-001`. |
| Counter mutation control | PASS: untouched presentation snapshot `0/0`; fake identity-bound `kill` / `spawn-sub` process calls produced lifecycle/subserver snapshot `1/1`; presentation equaled the actor snapshot. |
| Ownership evidence matrix | PASS: complete basis produced `.external`; missing pre-existing receipt, missing/nonzero lifecycle counter, or non-observation generation produced `.unknown`; external and unknown both reached the same explicit preview + confirmation gates and neither was dispatched. |
| Endpoint contract | PASS: presentation reported `explicit`, `inheritedEnvironment`, and `default`; child environment keys were exactly `OHOS_HDC_SERVER_PORT`; parent `ProcessInfo` environment was unchanged. |
| Device fan-out contract | PASS: appeared/unchanged/disappeared snapshots produced exactly appeared + disappeared fan-out, raw fixture identifier was absent from events, and presentation retained exactly the newest 32 events. |
| `swift test --package-path Packages/ArkDeckKit` | PASS: 307 tests, 1 existing opt-in skip, 0 failures (0 unexpected). Baseline was 302 tests / 1 skip / 0 failures; the delta is the five OBS contract tests. |
| `xcrun swift-format lint --strict <five changed Swift files>` | PASS: 0 diagnostics. |
| Unqualified `scripts/check-sdd.sh` | Environment-only failure before validation: PATH `python3` lacked `yaml`; no SDD conclusion was recorded from this attempt. |
| `env ARKDECK_PYTHON=/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python scripts/check-sdd.sh` | PASS with repository-supported override: 0 errors, 0 warnings, 111 acceptance IDs. |
| Production-origin audit (`rg` over `Packages/ArkDeckKit/Sources`) | PASS: zero `automaticLifecycle` / `automaticSubserver` call sites; four read-only probe origins and one confirmed lifecycle origin. |
| `git diff --check` | PASS. |

## AC conclusions after review

- `OBS-COUNTER-001`: BLOCKED. The package-level origin is forgeable and the
  counter is not attached to a uniquely defined production spawn boundary.
- `OBS-OWNERSHIP-001`: BLOCKED. The approved three-item matrix does not exclude
  active or previously established ArkDeck-managed ownership.
- `OBS-ENDPOINT-001`: PASS (contract evidence; parent environment unchanged).
- `OBS-FANOUT-001`: BLOCKED. The buffer accepts injected snapshots, but the
  approved macOS integration profile provides no production arbitrary-device
  snapshot source; therefore real-device appeared/disappeared events are not
  reachable.

## Deviations and residual risks

- This run is host-only contract evidence and does not claim real-device or
  hardware acceptance. TASK-M0B-002 remains responsible for human-operated
  real-device observation.
- A failed, timed-out, or unregistered device probe is deliberately not treated
  as an empty snapshot. A real disappearance event therefore requires a
  reliable read-only producer to submit an empty snapshot through the production
  feed; the later TASK-M0B-002 readiness review must pin that observation source.
- App rendering and signed XCUITest remain TASK-OBS-002. This run changes only
  the Kit/presentation contract surface authorized for TASK-OBS-001.
- The readiness file labels truncated file SHA-256 prefixes as blob pins. Exact
  full Git blob OIDs or full explicitly labelled SHA-256 values are required in
  the revision before implementation can resume.
- Per the approved flow, `tasks.md` remains `ready` in this implementation
  branch, but review invalidated that readiness conclusion. A separate
  CHG-2026-022 revision must return the task to `blocked`; this implementation
  PR must not be merged as task completion.
