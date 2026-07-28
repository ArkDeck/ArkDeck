# TASK-AIN-010 readiness audit r1 — blocked on authority contract/scope

## Classification

- Date:2026-07-28.
- Audit base:`e5a4267a062f97d50e0583ff7df1551e27420863` (PR #741 merge;
  TASK-AIN-009 done).
- Proposal submission base:`7d2e0b82febe38d1316db19907b575a541d73625`
  (PR #742 merge); its CHG-2026-044-only bytes do not overlap this audit.
- Method:host-only source/contract/scope audit plus existing full regression.
- Result:**blocked**. This record does not make TASK-AIN-010 ready and is not
  implementation, capability evidence, authorization or hardware evidence.
- Child process use was limited to the existing Swift contract test suite and
  SDD guard. Installed-HDC/server-lifecycle/device/mutation/destructive/network
  dispatch:`0 / 0 / 0 / 0 / 0 / 0`.

## Dependency and collision audit

- TASK-AIN-009 implementation PR #739 merged as
  `1b886869a40b730584330b97d8af7ffa54e99415`; its independent done PR #741
  merged as the audit base. The declared dependency is therefore satisfied.
- The only open PR observed at audit time was #742,
  `agent/chg-2026-044-openharmony-profile-version-reconciliation`. It later
  merged as the proposal submission base, changes only CHG-2026-044, and does
  not supply TASK-AIN-010 authority contracts or scope.
- The proposed `AgentDeviceOperations/**`, `HumanActionRequired.swift` and two
  TASK-AIN-010 test files do not exist at the audit base. New-file collision is
  not the blocker.

## Pinned observations

| Input | Git blob OID | Observation |
| --- | --- | --- |
| `contracts/agent-device-operation.schema.v1-draft.json` | `b2f41f6d14f18621561acbe93dbfccc3621405f4` | E1 result ref contains only `capabilityId/mainCommitOID/capabilityBlobOID/approvalPRNumber` |
| `contracts/agent-device-operation-registry.v1-draft.json` | `f101619358b08ffb818ccc8eac72b06c7b2062fe` | maps deviceMutation to `deviceCapability`; it is not a capability carrier |
| `contracts/journal-event.schema.v2.1-draft.json` | `ef71f22c45a7bc06bcde35b0606e94fb6bb79037` | persists only the legacy E2-shaped authorization reference |
| `contracts/manifest.schema.v2.1-draft.json` | `1fdb14da2ea8c0b45f88c3d5eef277b37e540976` | persists only the legacy E2-shaped authorization reference |
| `AuthorizationUsageLedger.swift` | `d87d93caf9fba52e34bdfbaa9a5eb6e16c7cc1b9` | reference and reservation model is the r2 standing-authorization model |
| `JournalEvent.swift` | `48103ee11ac7dd343518718df66a65ad987eddb6` | encodes/decodes the persisted authority, but was outside TASK-AIN-010 Allowed paths |
| `JournalEventValidation.swift` | `a038703f88cff61ad5ed23c8dbc02bf6bf79db72` | validates the legacy persisted shape and was the only journal source allowed |
| `JournalReplay.swift` | `9ea0b4aea122937cc206922a32b13170859e092c` | replays/correlates the persisted authority, but was outside Allowed paths |
| `SessionManifest.swift` | `22e5010f47a654557f84d1514421a71a792147de` | validates legacy authorization/usage correlation |
| `AuthorizationProvenance.swift` | `3f6c18fcece43b5754ec9e4ea4a2149481c1b228` | concrete provenance resolver is Rockchip E2-specific |
| `AuthorizationAdmission.swift` | `69fec8990c7cb68c989460ee883bbe358900cc96` | one-shot admission and consumption are Rockchip E2-specific |
| `HDCDeviceCommand.swift` | `9cf4014a475d21f77670bfe0b000898795e99dcf` | typed argv/durable-intent gate exists and remains a valid downstream seam |
| `Package.swift` | `292135a2c80c63ddf7182f58e2f81ff7c7d6104d` | no target/resource change is required for the proposed contract-only remediation |

## Blocking findings

### B1 — no machine-readable E1 capability carrier

The approved design requires the trusted host to dereference maintainer-accepted
per-device typed capability evidence and validate target/binding, transport,
tool/profile/version/hash, operation/namespace, impact, duration, concurrency,
uses, validity, compensation, resume probes, privilege facts and prohibited
destructive adjacency. At the audit base there is no closed schema, registry
path, duplicate/unknown-field policy, provenance envelope, usage model or
compatibility rule for those bytes.

The AIN-009 result reference proves only how a host-generated result names an
already resolved capability. It cannot tell TASK-AIN-010 how to parse or accept
one. Choosing those fields and rules during source implementation would make
the implementing Agent create a new Safety contract, violating Definition of
Ready.

### B2 — durable authority cannot close within the declared paths

Journal/Manifest 2.1 and `AuthorizationReference` model only the r2 E2 standing
authorization correlation. E0 ready-task and E1 capability references have
different discriminated shapes. TASK-AIN-010 originally allowed changes to
`JournalEventValidation.swift` and `SessionManifest.swift`, but not the
`JournalEvent.swift` encoder or `JournalReplay.swift` correlation state, and
forbade all contract changes.

Changing only validators would either reject the new authority kinds or accept
bytes that the encoder/replay model cannot preserve. Mapping E0/E1 into the E2
field names would lose the authority kind and source identity across restart.
Neither option can prove intent-before-effect, crash recovery or no-replay ACs.

### B3 — stated production reachability belonged to a later task

TASK-AIN-010 originally claimed
`ArkDeckCLI/App composition → TrustedDeviceOperationHost`, while `ArkDeckApp/**`
was forbidden and the CLI path was not allowed. TASK-AIN-015 already owns the
local submit/status/cancel/reconcile/result control-surface composition.
TASK-AIN-010 can close a product-consumable host seam; TASK-AIN-015 must close
the actual CLI/App entrypoint.

## Proposed remediation

The r4 proposal:

1. adds TASK-AIN-009R, a host-only D1 contract freeze for the per-device
   capability carrier/provenance/usage and E0/E1/E2 durable authority union;
2. preserves Journal/Manifest 2.1 historical Rockchip bytes and introduces
   separately versioned 2.2 drafts instead of rewriting history;
3. adds the exact storage encoder/replay/usage files and their existing
   regression tests to TASK-AIN-010 Allowed paths;
4. assigns CLI/App production control-surface wiring exclusively to
   TASK-AIN-015.

Merge of the r4 proposal does not make either task ready. TASK-AIN-009R must
complete independent readiness/implementation/done PRs, followed by a fresh
TASK-AIN-010 readiness audit on then-current main.

## Baseline

- macOS 26.6 (25G72), Xcode 26.6 (17F113), Apple Swift 6.3.3.
- `CI=true swift test --package-path Packages/ArkDeckKit`:
  **470 tests / 1 skipped / 0 failures**.
- `./scripts/check-sdd.sh`:
  **0 errors / 0 warnings / 111 acceptance IDs**.
- No source, current spec/contract, authorization/capability instance or device
  state was changed.
