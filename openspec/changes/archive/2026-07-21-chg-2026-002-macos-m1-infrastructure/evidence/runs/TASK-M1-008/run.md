# TASK-M1-008 implementation and simulated-platform run

## Run identity

- Date: 2026-07-20 (Asia/Shanghai)
- Branch: `agent/m1-008-implementation`
- Base OID: `5ce615513c6ee5d6ee619168de4b4aeabf2d8d97`
- Pinned TASK-M1-007 implementation OID:
  `8998d9ba43d6daab16f1ac5d1e1ecc884a69e887`
- Pinned TASK-M1-007 done-state OID:
  `c541f4f261abb63b8aecdabbb9c79e1048537bf9`
- Implementation revision binding: the base OID above plus the two output SHA-256 values below.
  Every acceptance and platform command in this run used those exact bytes.
- Evidence classification: `contract` for `TEST-AC-FLASH-006-01`; local macOS
  `platform` for `TEST-MAC-M1-SIM-001`; all provider results are `simulated`.
- Hardware requirement: none. No real/fake HDC child, real device, GUI, network, signing,
  system authorization, or external process was used by the dedicated run.

## Environment

| Item | Value |
| --- | --- |
| Host | macOS 26.5.2 (25F84), arm64 |
| Swift | Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`, `clang-2100.1.1.101`) |
| swift-format | 6.3.0 |
| SDD runtime | existing `/opt/homebrew/anaconda3/bin/python3`, Python 3.10.9, PyYAML 6.0 |
| Session environment | owner-only local temporary directories; deterministic synthetic fixture and timestamp |

No dependency was downloaded or installed. The first unqualified `scripts/check-sdd.sh` attempt
stopped before validation because PATH `python3` did not contain PyYAML. The repository-supported
`ARKDECK_PYTHON` override was then pointed at the already-installed runtime above, and the guard
passed. This was an environment precondition failure, not an SDD or product-test failure.

## Locked/read-only input hashes

| Input | SHA-256 |
| --- | --- |
| `openspec/constitution.md` | `394d86762e498bcc499301092d7537c93d53751577c0baffa102298eb3ded5c9` |
| `openspec/baselines/CORE-2.0.0.yaml` | `07227da529608f26dcbbc8843f1623278b51cb3036cd93e1e9ed4af6f8880aa6` |
| `openspec/specs/flashing/spec.md` | `77c669807714c10e3bcbe53005992875f9d251aee13ebbfc915241fc5bd7aed3` |
| `openspec/contracts/provider-contracts.md` | `1ac15e297cdc7cf520ed58e7c65ce7dec8c759b336f9f8fd20e4b5ac7404a02d` |
| `openspec/contracts/manifest.schema.json` | `52be768697e75fc98a00a386345162af2e1a8ca3607b86f755adb766cf0ad489` |
| `openspec/contracts/journal-event.schema.json` | `21df4c44b704d249c2228384b075a331346a4731d3f0b90f66ec8092dded8b19` |
| `openspec/verification/acceptance-cases.yaml` | `a8b4e9c0e9fd0bdeb369db18261a8be31324151a68fa710a30e29183b50a476d` |
| `openspec/platforms/macos/profile.md` | `fb777f05156cc261784bd08219c2fe64a981a85dddfb8e01dc2d33bfd63b5b0c` |
| change `proposal.md` | `5111a5867110c72601aae018cd4cf335977c69f48028a1df0ad2d467c3ee7752` |
| readiness `tasks.md` | `c7c08fc03fcb8ac848c5a963d987397cd95d64525f79a63af5073423138057e8` |
| change `verification.md` | `710abd3dc0b6ee18cd278ba1f226eccd3670127b629aa730a58aa3e2eb1fa23d` |
| M1-007 `DeviceTargeting.swift` | `9f56a0b937acaba1950100cb6275ecf5a002065faf3c58ee5e19a675790d6759` |
| M1-007 `DeviceBindingJournalAdapter.swift` | `a2c9e151a4ec9bcb34c49e304fa3c50ad2bc9828fe2d5b6fed7d7f8027e6f8cf` |

## Output hashes

| Output | SHA-256 |
| --- | --- |
| `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/SimulatedFlashProvider.swift` | `4c57fdf1e82bd32aeb6040ef7ed6232ac466f80f7602fb1b8e3e5201c6b1b102` |
| `Packages/ArkDeckKit/Tests/ArkDeckContractTests/SimulatedFlashProviderContractTests.swift` | `ffefc53ee4871b01e2b1c9ec18c7d1d12775343ec8b1a76ce0138c49c06aa33e` |

## Implementation result

- The production API accepts only `SimulatedFlashFixtureIdentity`, a closed
  `SimulatedFlashScenario`, an existing `SessionLayout`, and an audit timestamp. It has no
  `CurrentDeviceBinding`, connect-key, executable, argv, ProcessExecutor, OpenHarmony/HDC,
  device, network, or hardware-matrix writer input.
- `makePlan` produces the closed typed Flash plan (`enterUpdater`, `flashPartition`,
  `verifyRemoteState`) in memory. The provider executes no typed device/destructive runner;
  the durable orchestration envelope is host-only and remains under `standardAgent` authority.
- Job creation, synthetic binding evidence, host-only intent/outcome, cancellation transitions,
  `outcomeUnknown`, deterministic reconciliation, terminal finalization, write-once Manifest,
  durable Session audit receipt, and reopen all use the existing locked Core/Storage seams.
- Receipt and fixture JSON use raw-byte strict entry points and are intentionally Encodable-only,
  so Foundation's last-member-wins decoder cannot bypass duplicate-member validation. Receipt
  validation covers `evidenceClass:simulated`, `executionMode:simulated`, synthetic target, null
  connect key, toolchain `none`, nonempty fixture/scenario identity, hardware-support eligibility
  `false`, and terminal/hash consistency. Exact `{valid-object},"junk":null` vectors are rejected
  because the strict Session audit envelope refuses unknown sibling keys; regression tests lock this
  single-value boundary for both fixture and receipt entry points.
- Reopen requires exactly the expected intent/outcome records and detail keys, then binds schema,
  fixture/scenario identity, journal fixture identity, replay terminal state, Manifest identity/hash,
  planned step kinds, and every persisted isolation counter. Missing, extra, cross-record-mismatched,
  or nonzero isolation evidence fails closed.
- The production source imports only `ArkDeckCore`, `ArkDeckStorage`, `CryptoKit`, and
  `Foundation`; it imports no Process/OpenHarmony/HDC/network module and exposes no such call
  target.

## Fault, cancellation, reconcile, and reopen matrix

| Vector | Executed cases | Durable result |
| --- | ---: | --- |
| success | 1 | `succeeded`; Manifest and audit receipt remain simulated |
| virtual delay | 3 phase delays | injected values `[37,37,37]`; no wall-clock or external wait dependency |
| failure | 3/3 phases | current phase `failed`, later phases `notRun`, terminal Manifest `failed`/simulated |
| disconnect | 3 phases x before/after = 6 | one `waitingForDevice→running` cycle per case; terminal `succeeded`/simulated |
| outcomeUnknown | 3/3 phases | durable unknown, reconcile returns `waitingForRecovery`, reopen preserves unknown, no Manifest published |
| cancellation | pre-first-phase + suspended virtual delay = 2 | both use a blocking virtual-delay gate before cancellation; terminal `cancelled`; checked continuation count returns to 0 |
| repeated run | 2 independent Session roots | journal, Session audit, Manifest, receipt, phase outcomes, and counters byte/value identical |
| receipt tamper | 9 vectors | execute/real/non-null-connect-key/HDC/hardware-eligible/empty identity/invalid state/hash/extra authority rejected |
| strict JSON member boundary | duplicate + trailing-sibling vectors for fixture identity and receipt | raw duplicate member names, including `simulated` then `execute`, and exact `{valid-object},"junk":null` bytes are rejected before typed decode |
| reopen receipt tamper | schema/fixture/scenario/terminal/nonzero and incomplete isolation + reported combined vector | all rejected against exact receipt shape and journal/intent/Manifest/replay bindings |
| Manifest tamper | 4 vectors | execute mode, real target, non-null connect key, and HDC toolchain rejected before publication |
| invalid input/reuse | identity decode, control character, timestamp, oversized delay, completed Session reuse | all fail closed before unsafe publication or dispatch |

All dedicated cases observed these instrumented forbidden-operation counters:

| Counter | Result |
| --- | ---: |
| hardware-support verified-record writer | 0 |
| real connect-key accepted | 0 |
| external process dispatch | 0 |
| network dispatch | 0 |
| HDC dispatch | 0 |
| device dispatch | 0 |
| destructive dispatch | 0 |
| outcomeUnknown destructive replay | 0 |
| outcomeUnknown guess compensation | 0 |

The forbidden counters are intentionally structural canaries and persisted attestation fields: the
current provider has no production call site that can increment them. Their zero values therefore
do not stand alone as dispatch-isolation proof. The independent structural evidence is the static
import/call-target audit below; the counters are retained to detect future wiring regressions.

## Review remediation

- The reported trailing-sibling JSON vector was reproduced byte-for-byte and was already rejected
  by the exact-key Session audit envelope. Dedicated tests now lock this behavior for fixture and
  receipt inputs rather than claiming a production bypass.
- The pre-first-phase cancellation test now waits on `BlockingVirtualDelayer` before cancelling, so
  scheduling delay cannot allow the run to finish before the cancellation assertion.
- Both `waitingForRecovery` and terminal branches now record the receipt audit attempt before taking
  the isolation snapshot supplied to the durable receipt.
- A future approved storage task may replace the private envelope adapter with a public
  ArkDeckStorage strict-object decode seam; that API expansion is outside TASK-M1-008 allowed paths.

## Commands and results

| Command | Result |
| --- | --- |
| `swift test --package-path Packages/ArkDeckKit --filter SimulatedFlashProviderContractTests` | PASS: 12 tests, 0 failures; both canonical Test IDs and the matrix above execute in this suite |
| `swift test --package-path Packages/ArkDeckKit` | PASS: 261 tests, 1 existing opt-in manual sleep/wake skip, 0 failures/unexpected failures |
| `xcrun swift-format lint --strict <two TASK-M1-008 Swift files>` | PASS: 0 diagnostics |
| `ARKDECK_PYTHON=/opt/homebrew/anaconda3/bin/python3 scripts/check-sdd.sh` | PASS: 0 errors, 0 warnings, 111 acceptance IDs |
| `git diff --check` | PASS |
| allowed-path audit (`git status --short` / untracked-file listing) | PASS before this run/task reference: exactly the two declared Swift deliverables |
| production import/call-target audit | PASS: only Core/Storage/CryptoKit/Foundation; zero ProcessExecutor/Foundation Process/HDC/network/spawn/socket call targets |
| static mode/counter audit | PASS: no non-null connect-key construction, no `hardwareSupportEligible = true`, and no call recording any forbidden dispatch/writer operation |

The full suite may run pre-existing, repository-path-bound fake-HDC child-process regressions owned
by earlier tasks. Those results are classified only as full-suite regression coverage and are not
used as TASK-M1-008 acceptance or platform evidence. The dedicated M1-008 tests launch no child.

## Acceptance conclusions

| Test ID | Class | Result | Conclusion |
| --- | --- | --- | --- |
| `TEST-AC-FLASH-006-01` | contract | PASS | successful synthetic evidence and locked Manifest remain simulated; tamper fails closed; hardware-support writer count is 0 |
| `TEST-MAC-M1-SIM-001` | macOS platform (local simulated orchestration) | PASS | same implementation bytes cover journal intent/outcome, delay, failure, disconnect, cancel, unknown/reconcile/finalize/reopen with all forbidden counters 0 |

## Deviations and residual risk

- No Core Requirement, AC, contract/schema, platform profile, integration lock, Package.swift,
  existing production/test source, or other task evidence was modified.
- No real hardware/support/compatibility/conformance/release conclusion is made. This run does not
  change TASK-M1-006, platform conformance, the hardware matrix, or change verification status.
- `outcomeUnknown` intentionally has no terminal Manifest: locked publication rejects a nonterminal
  journal. Its durable job-created event, unknown outcome, reconciliation events, and Session audit
  receipt retain simulated classification and reopen to `waitingForRecovery`.
- The ordinary full-suite manual sleep/wake skip is pre-existing and unrelated to M1-008.
- No task-owned TODO remains. `TASK-M1-008` stays `ready` in this implementation PR; a separate
  maintainer-reviewed status PR is required to change it to `done`.
