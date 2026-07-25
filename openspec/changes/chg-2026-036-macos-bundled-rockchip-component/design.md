# CHG-2026-036 Change Design

## Context and constraints

- Proposal revision：r1；本 PR 仅 proposed，未批准、未 ready。
- Core baseline：`CORE-2.1.0`，零 Core delta。
- Architecture source：
  `docs/adr/0003-macos-rockchip-tool-execution.md` 与 archived
  `openspec/changes/archive/2026-07-25-chg-2026-035-macos-rockchip-tool-architecture/`。
- Platform constraints：ADR-0002、DEC-004、DEC-007 与 macOS profile 继续固定
  Sandboxed 单一 DMG、现行六个 App entitlement、HDC external-first。
- Upstream starting pin：
  `rockchip-linux/rkdeveloptool@304f073752fd25c854e1bcf05d8e7f925b1f4e14`；
  该 pin 只是 ADR handoff input，不构成 license/distribution 接受或 artifact identity。
- Current code：`RockchipFlashExecutionHost` 仍从
  `ArkDeck.Rockchip.ToolBookmark` 建立 user-selected external tool；Xcode target
  尚无 nested component/copy/sign phase，Release shape 尚无本 change 所需的
  Developer ID/Hardened Runtime/notarized DMG evidence。
- Current product：没有 Flash UI production reachability；CHG-2026-026
  `TASK-RKFUI-001G` 的 fail-closed blocked receipt 保持历史事实。

## Requirement mapping

| Requirement / AC | Design component | Verification |
| --- | --- | --- |
| `REQ-FLASH-001` / `AC-FLASH-001-01` | product-owned descriptor + strict `ld` parser | contract faults + signed E0 |
| `REQ-FLASH-004/008` / `AC-FLASH-008-01` | typed image/key/output leases and bounded stream handling | contract/fault matrix |
| `REQ-FLASH-005` / `AC-FLASH-005-01` | execute-disabled/plan-only remains distinct until later UI change | reachability audit |
| `REQ-FLASH-012/013` / `AC-FLASH-012-01` / `AC-FLASH-013-01` | semantic child result, diagnostics, rollback guidance | contract + signed platform evidence |
| `REQ-FLASH-015` / `AC-FLASH-015-01` | no E2 authority in this change; exact binding before future dispatch | zero-effect audit |
| `REQ-JOB-002/003` / `AC-JOB-002-01` / `AC-JOB-003-01` | durable intent-before-effect and durable outcome | crash/fault contract |
| `REQ-JOB-005/006` / `AC-JOB-005-01` / `AC-JOB-006-01` | exact executable/argv, no shell/PATH, unknown→reconcile | contract + source audit |
| `REQ-UX-007` / `AC-UX-007-01` | no silent elevation/install/rule/ACL; actionable permission state | signed Sandbox negative evidence |
| `BRC-SUPPLY-001` | accepted source/license/dependency/distribution envelope | document review |
| `BRC-REPRO-001` | hermetic unsigned build, registry, SBOM | two clean builders + diffoscope/hash receipts |
| `BRC-PACKAGE-001` | fixed nested location/identifier/entitlements/sign/notarize | codesign/notary/package inspection |
| `BRC-COMPOSITION-001` | product-owned identity and typed file leases | contract/fake/source reachability |
| `BRC-SANDBOX-E0-001` | signed E0 process/file/RockUSB stages | signed Sandbox platform/realHardware runs |
| `BRC-DISTRIBUTION-001` | clean-host DMG/install/update/rollback | clean-host/VM receipts |
| `BRC-HANDOFF-001` | fail-closed state and CHG-2026-026 separation | cross-file/diff audit |

## Architecture and data flow

```text
source pin + dependency lock + accepted distribution envelope
  -> hermetic unsigned build + SBOM + reproducibility receipts
  -> fixed nested bundle location + exact child entitlements
  -> inside-out Developer ID signing + notarization/stapling
  -> product-owned BundledRockchipComponentDescriptor
  -> RockchipFlashApplicationFacade / RockchipFlashExecutionHost
  -> typed plan + device binding + RockchipFlashAuthorizationGate
  -> typed image/key/output leases + exact closed argv
  -> FoundationRockchipExecutionProcessPort
  -> FoundationProcessExecutor
  -> RockUSB effect
  -> durable outcome / waitingForRecovery
```

This change stops before the future destructive-effect branch is made reachable from
the App UI. Tasks may prove the shared production components with contract/fake and
E0-only signed runs, but cannot mint or consume E2 authority.

The component is a direct App child, not a general command runner. It accepts only
commands lowered from the existing typed Rockchip Provider/Profile. There is no
shell, PATH resolution, caller environment, arbitrary argument array, caller-supplied
executable, helper/XPC/broker or download/copy fallback.

## Data and contract changes

- Core specs, locked contracts, canonical acceptance registry/index and Job/Artifact
  schemas do not change.
- A new versioned integration registry will describe the bundled component:
  upstream/source digests, build recipe/blob, builder/toolchain, minimum OS,
  architectures, dependency locks/licenses, unsigned artifact digest(s), component
  identifier/location, expected version output and release-policy references.
- A reviewable SBOM and corresponding-source/distribution manifest are release inputs,
  not authority tokens. Runtime callers cannot forge component trust by constructing
  registry fields.
- Existing user-selected RockUSB discovery registry and bookmark are not silently
  reinterpreted. Production composition removes their reachability only in
  `TASK-BRC-004`; historical evidence remains readable.
- Any registry schema or Core-contract need discovered during implementation requires
  a proposal revision/new change before that task can become ready.

## Authority and production reachability

- Production composition root：ArkDeckApp composition root creates
  `RockchipFlashApplicationFacade`/`RockchipFlashExecutionHost` with a
  product-owned bundled descriptor loaded from reviewed bundle/registry facts.
- Authority 产生点：existing `RockchipFlashAuthorizationGate` remains the only
  product authority minting point. This change does not create an E2 permit source
  and its tasks cannot obtain destructive standing authorization.
- Effect dispatch point：future typed RockUSB effect passes through
  `FoundationRockchipExecutionProcessPort`/`FoundationProcessExecutor`; durable
  intent must precede dispatch and durable outcome/reconcile follows it. E0 tasks
  use a separately bounded read-only route and counters.
- Fake/simulation 与 production 的结构差异：fakes never contain a signed nested
  artifact or real USB endpoint. They prove lowering, identity rejection, file
  lease, state and fault semantics only; `BRC-SANDBOX-E0-001` and
  `BRC-DISTRIBUTION-001` require separate signed/runtime evidence.
- Facts/provenance：source/build facts come from reviewed registry, reproducible
  builders and artifact digests; package facts from `codesign`, Gatekeeper/notary
  and bundle inspection; runtime facts from product-owned descriptor plus
  independently observed signature/hash/version. The application caller cannot
  supply the executable URL/hash/receipt/authority, and the child cannot mint its
  own trusted identity or success.

## Failure, cancellation, and recovery

- Source/license/dependency ambiguity blocks before build; no provisional release
  artifact is treated as accepted.
- Non-reproducible build, host dependency leakage, unsupported architecture/minimum
  OS, missing SBOM/source offer or vulnerability ownership blocks packaging.
- Missing/wrong nested signature, identifier, location, entitlement, Hardened Runtime,
  notarization or staple blocks launch and distribution.
- Missing image/key/output lease, symlink/TOCTOU/identity drift, partial output,
  deadline, cancellation or child crash produces a typed non-success result.
- Crash after intent but before trusted outcome enters `waitingForRecovery`; restart
  reconciles and never guesses/replays.
- E0 sees malformed/multi-device/unsupported `ld`, permission denial, USB disconnect
  or identity drift as explicit failure; zero mutation remains independently audited.
- Rollback disables bundled production reachability and returns an actionable
  execute-disabled state. It never selects an external binary.

## Security and privacy

- App entitlement set remains the existing six. Child candidate entitlement set is
  exactly App Sandbox + inherit; `get-task-allow`, library validation/JIT/unsigned
  memory exceptions and added USB/file entitlement are forbidden unless a new
  approved architecture change reopens ADR-0003.
- Build input and release artifact are separate trust domains. Release builders may
  access only pinned sources/dependencies; runtime App has no update/download code
  for this component.
- File leases are capability-minimal, target-bound and lifetime-bounded. Raw bookmark,
  path, secret, key/image content and child environment are not journaled.
- Developer ID/notary credentials remain human/release-environment controlled; PR
  evidence contains sanitized receipts/digests only.

## Alternatives and ADRs

ADR-0003 already rejected selected external executable, helper/XPC/broker,
plan-only-only product shape and distribution reopen for this path. This change does
not reevaluate them. If any mandatory gate cannot be satisfied, outcome is
execute-disabled/blocked and a new architecture change is required; no alternative
is activated inside an implementation task.
