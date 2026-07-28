# CHG-2026-043 Verification Plan

> Change:CHG-2026-043-hdc-320f-supervisor-observation@r1
> Status:planned
> Core baseline:CORE-2.1.0（canonical Core AC 零认领）

## Environment

- macOS host；registration 和 consumer tests 只读取 reviewed repository inputs、合成
  controls 与可注入 fake OS observations。
- Agent/CI 禁止执行 installed HDC、访问真实设备、读取 raw device identifier、改变
  server/device 状态或访问 non-loopback network。
- TASK-HSO-001 readiness 必须 pin exact protected-main inputs、CHG-2026-024 accepted
  provenance 及其限制、candidate profile/lock versions 与全部 allowed-path blobs。
- TASK-HSO-002 readiness 只能在 TASK-HSO-001 独立 `done` 合入后进行，并 pin merged
  registry/resource/profile/lock closure 与 production composition root。

## Acceptance matrix

| AC ID | Verification method | Expected result | Minimum evidence |
| --- | --- | --- | --- |
| `HSO-REGISTRY-001` | new registry/resource/profile/lock/macOS closure, exact-entry parser and provenance review | exact 3.2.0f/hash/endpoint family is supported only as commandless platform observation; versions, paths, hashes and accepted evidence references agree | platform + contract |
| `HSO-SEPARATION-001` | old-registry/resource byte identity, cross-version substitution and fallback mutation matrix | 3.2.0d readonly and 3.2.0f device registries remain unchanged; no family, receipt, candidate or semantic fact crosses tool versions | contract |
| `HSO-SINGLE-CANDIDATE-001` | production-root reachability test with candidate/endpoint identity spies and four-evidence ownership matrix | one selected exact 3.2.0f candidate drives commandless server generation and the existing device session; external is possible only from all four existing evidence items; health/version stay unknown | contract |
| `HSO-NODISPATCH-001` | static command-surface audit, failure injection and instrumented effect counters | identity bootstrap launches zero HDC child and all lifecycle/adoption/subserver/device/binding/destructive counters remain zero; explicit refresh can launch only the one existing registered read-only device child | contract |

## `HSO-REGISTRY-001`

- Registry entry must fix platform, reported tool version, executable SHA-256, endpoint, family,
  `platformProcessObservation`, empty argv and `invocationAllowed: false`.
- Registry/resource/profile/lock/macOS mapping IDs, versions and SHA-256 closure must agree.
- Provenance must reference the exact accepted CHG-2026-024 evidence merges and disclose `DEV-1`;
  synthetic controls never establish support.

## `HSO-SEPARATION-001`

- Existing readonly registry, device-observation registry and both resource packs remain
  byte-identical to readiness pins.
- Substituting 3.2.0d for 3.2.0f or vice versa, using only matching paths/versions, or falling
  through after mismatch must return unsupported/unknown before any command dispatch.
- No 3.2.0f entry claims `checkserver`, `hdc -v`, health or version semantics.

## `HSO-SINGLE-CANDIDATE-001`

- Production bootstrap discovers exactly one candidate and selects one endpoint.
- The exact same candidate identity/path/hash and endpoint instance feed the internally
  constructed supervisor observer and device session; neither may rediscover or replace them.
- A stable commandless receipt mints generation. External ownership appears only when all
  existing four evidence items are true; every missing item leaves ownership unknown.
- 3.2.0f health and client/server/daemon versions remain typed unknown without a registered
  source; existing 3.2.0d results remain unchanged.

## `HSO-NODISPATCH-001`

- Bootstrap identity observation dispatches no HDC child on success, mismatch, zero/multiple
  listeners, drift, timeout, cancellation or OS scan failure.
- Server lifecycle/adoption, subserver, device/binding mutation and destructive counters remain
  zero in every vector.
- Only an explicit device refresh may execute the existing exact registered
  `list targets -v`, at most once per accepted refresh; its result grants no ownership authority.

## Negative, cancellation and recovery gates

- candidate path/hash/bytes or endpoint mismatch => unsupported/unavailable before observer claim;
- no listener => unavailable; multiple/ambiguous listener => unknown; no generation minted;
- PID/start/path/hash/listener drift across scans => unknown and no new/retained external claim;
- caller-provided receipt/generation/process/socket list/runner or second discovery surface =>
  contract failure;
- missing provenance, version/hash collision or old-registry blob drift => TASK-HSO-001 blocked;
- failed consumer observation cannot fall through to 3.2.0d, retain a newly minted external claim,
  or change the device event snapshot;
- cancellation terminates only observation work; no HDC server process is killed.

## Regression gates

- `swift test --package-path Packages/ArkDeckKit` passes with zero unexpected failures;
- `scripts/check-sdd.sh` and the repository guard suite pass with zero error/warning;
- existing HDC supervisor, observability and device presentation contract suites pass;
- signed UI regression may exercise only existing fake/support fixtures; it is not hardware or
  HDC support evidence.

## Deviations

任何 provenance、observer 行为、allowed path、version、production reachability 或 effect
deviation 必须在独立 readiness/implementation PR 中显式记录并由维护者 review。需要
扩大 UI、Core、contract、hardware 或 capture scope 时，本任务保持 blocked 并先修订
change；不得隐式豁免。

## Result gate

- [ ] 四条 change-local AC 均有 same-revision、可复查 evidence。
- [ ] 两个 task 的 implementation/evidence 与 `ready→done` 均为独立 PR。
- [ ] 3.2.0d readonly 与 3.2.0f device registry/resource invariant pins 未漂移。
- [ ] Simulation/fake/system-observer contract 未记为真实 HDC、设备、hardware 或 release
      支持。
- [ ] change `verified` 由独立状态 PR 引用具体 run 记录；不自动推进
      CHG-2026-006 `TASK-M0B-002`。
