# CHG-2026-045 design — explicit in-session HDC observation refresh

> Status:candidate; it becomes design input only after maintainer approval,
> and the task still requires an independent readiness decision.
> Core baseline:CORE-2.1.0 (no Core change)

## 1. Context and constraints

Proposal base is protected main
`1227ea8c156f4814cf42278fb1a806bba632a406`. The accepted CHG-2026-006
readiness record is blob `8eb3de8576565229685848770836217770cb1ea3`.
At that base:

- App composition root `ArkDeckApp.swift` blob
  `1ec424df02550cc9f79780b7a4b61af28d7faf30` performs one startup
  `hdcDiagnostics.refresh()`;
- `HDCStatusView.swift` blob
  `476769d4b5b242a91b2bb4d0661cdb0fb7359d44` exposes no refresh callback;
- Workflows facade blob
  `fa0bc651382c9b5d1a36a46c59a11af65bc84249` has exactly one production
  `deviceObservationSession.refresh()` call, and retains the session while
  candidate/endpoint/execution identity are unchanged;
- OpenHarmony production blob
  `c7f71e5af90bc3d468d5f0817734d297f0c339a2` already provides a one-poll
  in-flight guard, bounded buffer and exact registered source.

The design closes only the missing App reachability edge. It does not
reimplement any source, observer, parser, differencer, pseudonymizer or HDC
authority.

## 2. Requirement mapping

| Requirement / AC | Design component | Verification |
| --- | --- | --- |
| compatible `REQ-UX-002`, `HOR-UI-001` | localized accessible SwiftUI refresh button and App callback | signed UI test + source/composition contract |
| `HOR-SESSION-001` | existing provider refresh and retained device-observation session | sequential snapshot contract + production source audit |
| `HOR-BOUNDED-001` | synchronous App admission flag plus existing actor in-flight guard | delayed fixture UI test + invocation counters/mutations |
| compatible `REQ-HDC-003/004`, `HOR-SAFETY-001` | unchanged Workflows/OpenHarmony authority and registered effect boundary | forbidden-effect counters + static diff/source audit |
| compatible `REQ-I18N-001` | English and Simplified Chinese catalog entries | signed locale/accessibility assertions |

## 3. Architecture and data flow

```text
macOS HDCStatusView refresh button
  → HDCStatusViewModel.refresh()
    → HDCApplicationDiagnosticsProviding.refresh()
      → HDCProductionApplicationDiagnostics.attachSessionIfConfigured()
        (no-op after the current session has been attached)
      → existing diagnostics provider refresh
      → existing HDCDeviceObservationApplicationSession.refresh()
        → existing exact 3.2.0f registered snapshot source
          → at most one list targets -v child
      → overlay the same bounded device-event buffer
      → publish the new presentation back to the same window
```

The view receives only a zero-argument callback and an in-flight Boolean. It
does not receive a candidate, endpoint, session, runner or argv.

## 4. Refresh admission and session identity

`HDCStatusViewModel.refresh()` is the single App entry for both startup and
manual refresh:

1. on the main actor, reject the request when refresh is already in flight;
2. set the in-flight state before creating the asynchronous task;
3. call provider `refresh()` exactly once;
4. publish the returned presentation and clear the in-flight state on normal
   completion or cancellation while the model still exists.

The view disables the refresh control while this state is true. Executable
selection is also unavailable during an active refresh so a user action
cannot deliberately replace the candidate/session in that interval.

No App code constructs or caches session identity. The existing Workflows
actor remains authoritative:

- `attemptedSessionBootstrap` prevents rediscovery after attachment;
- `HDCDeviceObservationSessionKey` binds canonical candidate identity,
  endpoint and durable execution session identity;
- `replaceDeviceObservationSessionIfNeeded` retains the actor for an equal
  key and replaces it only for the already-defined configuration/session
  transition;
- a manual refresh never invokes the clear/replace path.

## 5. UI fixture and production boundary

The signed UI test needs an observable callback result, but a fixture must
not masquerade as hardware:

- an exact UI-test-only argument enables a presentation sequence;
- startup refresh returns a deterministic first presentation and one manual
  refresh returns a deterministic second presentation;
- the sequence may contain synthetic `appeared`/`disappeared` events and an
  optional bounded delay used to assert the disabled state;
- the flag is handled only inside the existing
  `HDCFixtureApplicationDiagnostics`, whose
  `lifecycleDispatchIsProductionComposed` remains false;
- the production section contains none of the fixture timestamps,
  identifiers, delay, counters or sequencing values.

The signed test proves the visible control reaches the provider. The
OpenHarmony session contract separately proves sequential snapshots produce
the event difference in one actor. A production-root source audit proves the
same retained actor is the consumer. These evidence layers are complementary;
the fixture is never reported as real-HDC or hardware evidence.

## 6. Data and contract changes

- Core specs/contracts/schema:unchanged.
- Integration/platform profiles and registries:unchanged.
- Workflows public protocol:unchanged; it already exposes `refresh()`.
- Persistent data/journal/manifest:unchanged.
- Diagnostics presentation shape:unchanged.
- Localization:add only the refresh control key in English and Simplified
  Chinese.
- Accessibility:add one stable button identifier; no raw device data.

## 7. Authority and production reachability

- **Production composition root:**`ArkDeckApp` constructs
  `HDCApplicationDiagnosticsFacade.make()` and passes the App-owned model
  callback to `HDCStatusView`.
- **Authority origin:**the existing Workflows discovery/session composition
  selects the candidate and endpoint; exact supervisor/device registries and
  system identity observation remain authoritative. The App creates no
  authority.
- **Effect dispatch point:**the existing registered device source invokes
  `HDCProcessCommandRunner` with the fixed `list targets -v` argument array.
  This E0 read-only observation has no durable mutation intent/outcome
  because it is not a device mutation Step.
- **Fake versus production:**the fixture returns presentation values and has
  no production dispatcher. The production actor internally constructs the
  registered source and exposes no runner/source injection.
- **Facts/provenance:**candidate bytes, endpoint and process/listener identity
  come from the existing discovery/verifier/system observer. The App caller
  cannot construct those facts or their receipt.

## 8. Failure, cancellation and recovery

- refresh already active:reject the duplicate at the App boundary; zero
  second provider call;
- missing/unsupported candidate or endpoint:return the existing explicit
  unavailable presentation; no fallback or retry;
- identity change/process error:the registered source returns unavailable and
  dispatches no mutation/lifecycle action;
- cancellation:release App in-flight presentation state when applicable;
  the observation actor keeps its existing safe cancellation behavior and
  never kills the HDC server;
- App crash/restart:no new durable state; a new App session starts a new
  bounded buffer and cannot be stitched to the old one;
- event overflow:retain the existing capacity-64 eviction behavior;
- rollback:remove the UI reachability edge and test fixture additions,
  returning CHG-2026-006 to the explicitly recorded blocker.

## 9. Security and privacy

- no shell command construction, dynamic argv or App-visible process runner;
- no raw connect key/device identifier in UI, logs or fixture assertions;
- no non-loopback product network, upload, telemetry or new entitlement;
- no server lifecycle, subserver, binding/device mutation or destructive
  authority;
- exact fixture arguments and synthetic values are confined to UI-test
  composition and labeled `contract/platform`, not `realHardware`.

## 10. Alternatives rejected

- **Timer/background refresh:**changes effect frequency and can interfere with
  shared HDC infrastructure; outside the accepted user-triggered boundary.
- **Restart/reopen/reselect as refresh:**replaces session identity and buffer,
  so it cannot prove appeared/disappeared in one session.
- **Call the observation actor directly from SwiftUI:**leaks integration
  authority across the Workflows boundary and duplicates composition.
- **Add a second provider API or HDC command:**the existing `refresh()` and
  registered source are sufficient; a new API/command creates unnecessary
  authority.
- **Use only static source assertions:**does not prove a human-visible signed
  control reaches its provider.
- **Treat the fixture sequence as hardware evidence:**violates execution-mode
  and verification-layer separation.
