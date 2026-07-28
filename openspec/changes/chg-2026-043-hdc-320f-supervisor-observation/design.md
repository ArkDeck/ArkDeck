# CHG-2026-043 design — exact 3.2.0f commandless supervisor observation

> Status:candidate；仅在 change 获维护者批准后成为设计输入，task 仍须独立 readiness。
> Core baseline:CORE-2.1.0（零 Core 变更）

## 0. Hard boundaries

- One production bootstrap selects one `HDCCandidate`; server and device facts never come from
  different candidates, endpoints or sessions.
- A versioned registry entry is authority, not discovery. Exact 3.2.0f support does not broaden
  or reinterpret the 3.2.0d readonly registry.
- The supervisor identity family is commandless. It never launches HDC and never claims health
  or a version string.
- Only a platform observer can mint the identity receipt and derived generation. Caller fields,
  persisted snapshots and device-observation success cannot mint either.
- No result authorizes server lifecycle/adoption, subserver, device/binding or destructive
  mutation. External ownership remains governed by the existing four-evidence judgment.

## 1. Version and artifact boundary

- Candidate profile:`OPENHARMONY-TOOLS@0.6.0`.
- New registry:`OPENHARMONY-HDC-SUPERVISOR-OBSERVATION-PROBES@1.0.0` at
  `openspec/integrations/openharmony/supervisor-observation-probes.yaml`.
- Candidate lock:`INTEGRATION-PROFILES-0.7.0`.
- Resource pack:
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/Probes/SupervisorObservation/1.0.0/**`.
- Tool tuple:
  - platform:`macos`
  - reported version:`3.2.0f`
  - executable SHA-256:
    `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`
  - endpoint:`127.0.0.1:8710`
- The registry/resource closure carries explicit provenance to CHG-2026-024 accepted capture
  merges #656/#658. It contains redacted structured receipts and synthetic negative controls,
  never raw process output or device identifiers.

These candidate shared versions are rechecked at readiness. No implementation may reuse a
version already changed by another main commit.

## 2. Closed commandless entry

The registry has one supported family, `serverIdentityGeneration`:

- `probeKind = platformProcessObservation`;
- `exactArgv = []`;
- `invocationAllowed = false`;
- exact tool tuple and endpoint above;
- exactly one existing process whose resolved executable path equals the selected candidate and
  whose executable bytes still match the selected candidate SHA-256;
- that process owns the exact normalized loopback listener;
- PID, start seconds/microseconds, resolved executable path/hash and normalized endpoint are equal
  across bounded pre/post scans;
- timeout/cancellation/scan error, zero or multiple matches, endpoint ambiguity, path/hash drift
  or pre/post inequality returns typed unavailable/unknown and mints no generation.

Wildcard or IPv4-mapped listener spelling may be normalized only under the already-tested macOS
socket rule; matching a port without selected-process ownership is insufficient. The registry
must not add `checkserver`, `-v` or any other argv.

## 3. Authority and anti-forgery

The production factory constructs the registry and platform observer internally. Its public
entry accepts only the selected `HDCCandidate` and endpoint selection; it has no receipt,
generation, PID, process list, socket list, command runner or registry injection surface.

The observer re-verifies candidate bytes before and after the bounded OS scans. A stable receipt
is converted to generation by the existing deterministic adapter and passed directly to
`HDCServerSupervisor.observeRegisteredServerIdentity` with:

- health = typed unknown (`no registered 3.2.0f health source`);
- client/server/daemon version = typed unknown;
- reason naming the exact supervisor-observation registry/profile.

The supervisor—not the caller—applies the existing evidence basis:

1. pre-existing server receipt;
2. zero automatic lifecycle dispatch;
3. generation minted from observation;
4. no active or unreconciled ArkDeck-managed provenance.

Only all four can yield `.external`; otherwise ownership remains `.unknown`. A device snapshot,
exit code, remembered receipt or UI state cannot substitute for any item.

## 4. Production composition

```text
HDCApplicationDiagnosticsFacade.attachSessionIfConfigured
  └─ discover exactly one HDCCandidate + select one endpoint
      ├─ exact 3.2.0d → existing readonly/checkserver route (unchanged)
      └─ exact 3.2.0f
          ├─ new commandless supervisor identity registry
          │   └─ platform process/listener observer
          │       └─ observation-minted generation
          │           └─ existing four-evidence ownership classifier
          └─ existing device-observation production session
              └─ explicit refresh → at most one registered `list targets -v`
```

The 3.2.0f branch receives the exact candidate already selected by the facade. Neither branch may
discover a replacement or accept a path/hash independently. The identity observer implementation
used by device observation and supervisor observation must share one production implementation
or be proven behaviorally identical by mutation tests; divergent listener/path rules are a
readiness blocker.

The commandless supervisor result attaches the registered identity to the same application
session. Existing presentation fields expose generation/ownership and typed unknown health/
versions; no App or App UI edit is expected. If readiness proves a UI edit is necessary, scope
must be revised and approved before implementation.

## 5. Failure and dispatch matrix

| Condition | Supervisor result | Ownership effect | HDC child / mutation |
| --- | --- | --- | --- |
| exact tuple + endpoint + one stable existing listener | generation observed; health/version unknown | existing four-evidence classifier decides | 0 |
| no listener | unavailable | unknown/no new claim | 0 |
| multiple listeners or ambiguous owner | unknown | unknown/no new claim | 0 |
| path/hash/endpoint mismatch | unsupported or unavailable | unknown/no new claim | 0 |
| candidate bytes or identity drift pre/post | unknown | unknown/no new claim | 0 |
| timeout/cancellation/OS scan failure | typed timeout/cancel/unknown | unknown/no new claim | 0 |
| explicit device refresh after successful bootstrap | independent registered device snapshot | no ownership authority | at most one read-only child; all mutation 0 |

Failure cannot fall through to the 3.2.0d registry, invoke `checkserver`, select another candidate,
or retain a newly minted external claim from the failed observation.

## 6. Provenance plan

`TASK-HSO-001` readiness must pin and review:

- CHG-2026-024 capture run exact blob and accepted merge OIDs #656/#658;
- the exact 3.2.0f tool tuple and four stable process/start/executable/endpoint observations;
- current device-observation registry/resource hashes and its production identity observer tests;
- current readonly registry bytes as a do-not-change invariant;
- evidence limitations, including CHG-2026-024 `DEV-1` (four brackets across the window rather
  than per-command brackets).

This proposal does not decide that reused evidence is sufficient. If the independent readiness
review does not accept it for commandless supervisor registration, `TASK-HSO-001` stays blocked
and a separately approved maintainer-controlled capture plan is required. Agent/CI must not close
the gap by invoking installed HDC or a real device.

## 7. Alternatives rejected

- **Join 3.2.0d server facts to 3.2.0f device facts:** violates the one-candidate/session boundary
  and makes the hardware matrix ambiguous.
- **Add 3.2.0f to the existing readonly registry:** silently changes an immutable 3.2.0d
  provenance tuple and implies unsupported `checkserver`/version compatibility.
- **Treat the device registry precondition as supervisor authority:** its accepted scope only
  gates a device command; registry purpose cannot be upgraded by consumer code.
- **Infer d→f patch compatibility:** executable hash and reported version are authority inputs,
  not hints.
- **Register 3.2.0f `checkserver` without capture:** would manufacture health/version semantics.
- **Change M0B acceptance or use two production candidates:** changes the problem rather than
  closing the missing authority.

## 8. Rollback

Rollback consumer adoption first so no production path refers to the new registry, then revert
the new registry/profile/lock/resources. The existing 3.2.0d server route and 3.2.0f device
registry remain intact. A rolled-back 3.2.0f selection returns server generation/ownership to
unknown and performs no lifecycle action.
