# App transport: the silent-endpoint test raced the runner's wall clock — 2026-09-30

- Slice: CI2, a recurring Swift CI flake in `ArkDeckClientKitTests`. The test came in with TASK-XPA-019
  (#1976) and was migrated to Swift Testing in #2321.
- Base: protected `main` `40ab5a7d` (#2380).
- Author: Repo Agent on the maintainer's Windows 11 x64 reference host. Swift cannot build here,
  so macOS CI is the first run of the change.

## The flake

`RuntimeXPCRequestTransportTests.sharedTransportBoundsASilentEndpointWithoutClaimingRejection`
calls `RuntimeXPCRequestTransport.awaitReply(timeoutSeconds: 0.01)` with a start closure that
never replies. It then asserts `startedAt.duration(to: .now) < .seconds(1)` on `ContinuousClock`.

I scanned the 400 Swift CI push runs created from 2026-09-25 22:20 to 2026-09-30 10:13 UTC,
every attempt, and read the log of every failed `swift*` job (read-only `gh api`; nothing was
re-run, cancelled or dispatched). That assertion is this test's only failure, and it failed 4
times:

| run | attempt | job id | branch (PR) | failed after |
| --- | ---: | ---: | --- | ---: |
| 36699846265 | 1 | 109836518168 | `agent/xpa-018-nonconforming-replies-20260930` (#2382) | 1.213 s |
| 36698825228 | 1 | 109833238618 | `agent/xpa-018-windows-coverage-refresh-20260930` (#2378) | 1.595 s |
| 36688177971 | 1 | 109798887548 | `main` | 1.574 s |
| 36604367138 | 1 | 109529587736 | `agent/xpa-017-release-rc-speed-20260930` | 1.406 s |

Each time the expectation that failed was `startedAt.duration(to: .now) < .seconds(1)` at
`RuntimeXPCRequestTransportTests.swift:17`. The `.timedOut` result expectation held.

## Root cause

- **What the test means to prove:** a live endpoint that never answers is bounded by the
  caller's own deadline, and the wait ends as an outcome-neutral timeout. Nothing else may bound
  it; the ordinary deadline is 120 s. The one-second assertion stood in for "the transport used
  the 10 ms it was given, not some other deadline".
- **How the deadline is measured:** against wall time, with no injected clock.
  `awaitReply` arms `DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() +
  timeoutSeconds, …)`. Between that timer and the test's `ContinuousClock.now` lie:
  - the global queue's thread pool;
  - the checked continuation's resume;
  - the Swift Testing task's return to a cooperative-pool thread.

  On a loaded macOS runner (`swift-tests` runs `--num-workers 8`) that path took 1.2–1.6 s. The
  transport did nothing wrong; the runner was slow to deliver an on-time 10 ms timer.
- **Why this is not a budget:** no design names one second. The production bound is the
  caller's `timeoutSeconds` (120 s, or 4 h 5 min for `job.run`), and the transport promises only
  to arm it and to end a silent wait as `.timedOut`. So raising the number would keep the race
  and prove nothing more.

## The fix

The deadline is armed through a seam, and the test reads the bound instead of timing it.

- `awaitReply` gains `armTimeout: ArmTimeout = dispatchTimeout`:
  - `dispatchTimeout` is exactly the previous `DispatchQueue.global(qos: .userInitiated)
    .asyncAfter(deadline: .now() + seconds, …)`;
  - the timer now runs a closure that performs the same cancellable `DispatchWorkItem`;
  - a work item a reply cancelled returns at once when performed, and `finish` ignores every
    signal after the first anyway.

  Production callers pass nothing, so their behaviour is unchanged.
- The silent-endpoint test passes an `armTimeout` that records the seconds it is given and fires
  the deadline on another queue, after the silent endpoint has started. It asserts:
  - the result is `.failure(.timedOut)`;
  - the transport armed exactly `[0.01]`: one deadline, the caller's;
  - the timeout message claims no rejection, as before.

  If the transport ignored or replaced the caller's deadline (for example the 120 s default),
  `armed` would not be `[0.01]`. If the deadline did not end the wait, the result would not be
  `.timedOut`. No wall-clock comparison is left.
- A new test, `productionDeadlineEndsASilentEndpoint`, keeps the real dispatch timer covered: the
  default `armTimeout` ends a silent 10 ms wait as `.timedOut`. It has a one-minute
  `.timeLimit`, which only turns a timer that never fires into a failure instead of a hang; it
  bounds nothing the transport promises.

Not changed: `releaseMismatchedRuntimeIsReportedWithItsRemedyWithoutHanging` still asserts
`< .seconds(4)` against a real anonymous XPC listener. Its comment ties that bound to the 5 s
health bound, a real budget, and it did not fail in the 400 runs.

## Local targeted checks

None are possible: Swift and XPC need macOS, and this host is Windows. The change is two files in
`Packages/ArkDeckKit` (`RuntimeXPCRequestTransport.swift` and its test), so `plan.py` selects the
Swift lane on the PR. `sh scripts/check-sdd.sh` (for this record): exit 0, 0 errors, 0 warnings; `git diff --check`: exit 0.

## CI

To be recorded by the follow-up (PR number, run id, the `swift-tests` result).
