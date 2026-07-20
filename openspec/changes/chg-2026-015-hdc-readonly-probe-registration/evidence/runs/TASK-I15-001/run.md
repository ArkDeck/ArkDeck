# TASK-I15-001 registration implementation run

- Change:`CHG-2026-015-hdc-readonly-probe-registration@r2`
- Task:`TASK-I15-001`
- Classification:`contract + platform receipt review`; no real-hardware acceptance claim
- Executed:2026-07-20 15:35–15:43 CST by Codex Agent
- Base revision:`5751f5ffc9379819a2a58f9ea370694f3e469048`
  (`main`, readiness PR #157 merged)
- Branch:`agent/i15-001-readonly-probe-registration`
- Core baseline:`CORE-2.0.0`(unchanged)

## Readiness and input provenance

The approved change, readiness state and all four maintainer-accepted inputs were present at the
base revision. The implementation independently recalculated these inputs before use:

| Input | Evidence class / acceptance | SHA-256 |
| --- | --- | --- |
| `evidence/provenance/subserver-capability-doc.md` | document review; PR #141 | `6bb63426ecee6e0e86f4027bd7d9b6034db56e116663494885fd69aa89618013` |
| `evidence/provenance/host-only-capture-2026-07-20.md` | controlled-human capture record; PR #155 | `7949d8a2f813b7f2f6b7d8ba45d37cca84d57167f0e319e4761b5f50e53493d8` |
| `evidence/provenance/device-window-capture-2026-07-20.md` | controlled-human capture record; PR #156 | `a06cc98999adb1067448ab879870c77e88740988cbc3905dff933a98fb7ae887` |
| `evidence/provenance/harness-checkserver.redacted-manifest.json` | redacted controlled receipt; PR #155 | `8d6d63177f59d784ccd071fd054a27873db8a8779481ac83a3110a5cda4787b4` |
| `evidence/provenance/harness-list-targets.redacted-manifest.json` | redacted controlled receipt; PR #156 | `80b3c9d62f7aa5262bc647c7097067e0428d0f1c4975851480285b6c6365d417` |
| `scripts/m0b_capture/capture.py` | capture instrument, read-only input | `be66c30e7db6839196f095724d9ee75a59d938a7e1e4ffa1f139e8f3df3760f8` |

Raw identity-bearing streams and host observations remain in the operator-controlled location
outside the repository. This run copied no raw device identifier, user path or key material.

## Registration result

`OPENHARMONY-TOOLS` advanced from `0.2.0` to `0.3.0` and the Integration lock from
`INTEGRATION-PROFILES-0.3.0` to `INTEGRATION-PROFILES-0.4.0`. The structured JSON-compatible YAML
registry is `OPENHARMONY-HDC-READONLY-PROBES@1.0.0`. Its SwiftPM resource snapshot is byte-identical
to the integration registry.

| Family | Binary conclusion | Registered boundary |
| --- | --- | --- |
| `serverIdentityGeneration` | `supported` | Commandless macOS process/start identity + pinned executable + exact listener observation. It requires exactly one already-existing server and supports the same post-dispatch observation. `checkserver`, PID shape, endpoint reuse and caller generation grant no authority. |
| `selectedDeviceAuthorizationBinding` | `supported` | Exact argv `list targets -v`, only after a valid existing-server receipt and with an already durable binding identity/revision. Only the captured 3.2.0d Connected row family is registered; denied/unknown output, stale or mismatched binding, timeout and cancellation fail closed. It cannot select a default target, mint/revise a binding or infer channel protection. |
| `keyAccessDiagnostics` | `unsupported` | The accepted capture proves key-material absence but identifies no configured/user-approved HDC key locator. A conventional path cannot create production authority, so file-access dispatch and all private-key read/hash/copy/delete/chmod/upload/path-log operations remain prohibited. |
| `subserverCapability` | `unsupported` | The reviewed source is 3.2.0b rather than the exact 3.2.0d target and proves no client-local zero-lifecycle/device-migration probe. No argv is registered; version, mutation names and unknown output cannot imply support. |

Key output hashes:

| Artifact | SHA-256 |
| --- | --- |
| `openspec/integrations/openharmony/profile.md` | `03893f36c62e738b34a2e2aef6b0c0cd8fdd1bf3f386bcef7179686d4af4007d` |
| `openspec/integrations/openharmony/readonly-probes.yaml` | `3c0a252b20e96d2ad3b92436725391e7bd1119588db684f42bbe26dbcb7ebcde` |
| `openspec/integrations/INTEGRATION-PROFILES.lock.yaml` | `4de73676f1ad735a73ce9b69a304290e9a8a161003d4180a0c1a99ebeaefe6cd` |
| `Fixtures/HDC/Probes/1.0.0/resources.json` | `6f09b841237bb36e1a6a72bbf55a714a61622c60508446d0ee6d6295cd89bf22` |
| `HDCProbeRegistryContractTests.swift` | `bd63f83d3e1da59b47ca1493bf5c527488a71480cd998a6213b480d3acd9ca3d` |
| `Packages/ArkDeckKit/Package.swift` | `ccdcc3861b02dfe2c4e6c184d7ade5d0820c70a0011a8c5003038f44cb27f821` |

The resource manifest pins its registry snapshot, four derived receipts, control-only vector pack
and `.gitattributes`; the Integration lock pins that manifest plus the same seven resources.

## Verification commands and results

| Command | Result |
| --- | --- |
| `swift build --package-path Packages/ArkDeckKit --build-tests` | passed. The first sandboxed attempt could not write the user Clang module cache (`Operation not permitted`); the required command was rerun with controlled filesystem permission and completed successfully. This was an environment-only failure, not a build/test failure. |
| `swift test --package-path Packages/ArkDeckKit --filter HDCProbeRegistryContractTests` | passed:7 tests,0 failures. Exact Bundle.module resource set/hash, closed registry, receipt/provenance agreement, supported/unsupported authority, partial/duplicate/unknown rejection, control vectors and privacy all passed. |
| `swift test --package-path Packages/ArkDeckKit` | passed:268 tests,0 failures,1 existing opt-in manual sleep/wake skip. |
| `env ARKDECK_PYTHON=<main-repo>/.venv-sdd/bin/python scripts/check-sdd.sh` | passed with Python 3.14.6/PyYAML 6.0.3:0 errors,0 warnings,111 acceptance IDs. |
| independent Python/YAML/JSON SHA-256 closure check | passed:`4 families, 8 pinned probe resources, profile 0.3.0, lock 0.4.0`; registry snapshot byte-equal; every receipt/source/resource hash matched. |
| privacy/secret scan over registry, profile, lock and resource pack | passed:11 files,0 matches for user-path, private-key header and common secret-token patterns. |
| `swift format lint --strict HDCProbeRegistryContractTests.swift` | passed. |
| `git diff --check` | passed. |
| allowed-path audit | passed:all changed paths are within TASK-I15-001 Allowed paths; production sources, existing Golden resources and forbidden spec/contract/baseline/platform/verification paths are unchanged. |

## Acceptance conclusions

| Test ID | Result | Reviewable evidence |
| --- | --- | --- |
| `TEST-I15-HDC-SERVER-IDENTITY-001` | passed | supported entry safety invariants, controlled receipt hash, absent/substitution/caller-generation control vectors and zero dispatch counters |
| `TEST-I15-HDC-AUTH-BINDING-001` | passed | exact argv + existing-server/durable-binding gates; stale/mismatch/denied-unregistered/unknown/timeout/cancellation vectors fail closed |
| `TEST-I15-HDC-KEY-ACCESS-001` | passed with `unsupported` production conclusion | missing/denied/public-readable-private-denied controls remain unsupported; receipt and privacy test prove private-key/path operations are zero and no locator authority was inferred |
| `TEST-I15-HDC-SUBSERVER-001` | passed with `unsupported` production conclusion | exact-version uncertainty is explicit; version-only and mutation-name vectors remain unsupported with all mutation counters zero |
| `TEST-I15-HDC-PROVENANCE-001` | passed | every production entry points to a maintainer-merged input and immutable source/derived receipt hash; fake inputs are labelled control-only |
| `TEST-I15-HDC-REGISTRY-001` | passed | four-entry closure, profile/registry/resource/lock version+hash agreement, exact resource set and partial/duplicate/unknown rejection |
| `TEST-I15-HDC-NODISPATCH-001` | passed | command log and control counters show installed HDC/device/non-loopback network/server lifecycle/subserver/device migration/destructive dispatch all zero |

## Dispatch accounting

| Counter | Value |
| --- | ---: |
| installed real HDC | 0 |
| real device access | 0 |
| non-loopback network | 0 |
| server start/stop/restart/adoption | 0 / 0 / 0 / 0 |
| subserver lifecycle | 0 |
| device migration/mutation | 0 / 0 |
| destructive action | 0 |
| private-key read/hash/copy/delete/chmod/upload | 0 / 0 / 0 / 0 / 0 / 0 |

No pre-existing HDC server was stopped, restarted, adopted or reconfigured by this run. No
installed `hdc` command was executed.

## Deviations, status and residual risk

- The initial sandboxed `swift build` cache-permission failure is recorded above; the unchanged
  mandatory command passed after the minimum filesystem escalation.
- Only the exact controlled 3.2.0d Connected verbose row is registered for authorization. Denied
  or other unproven raw shapes remain unknown instead of borrowing M0A candidate constants.
- Key diagnostics and subserver capability are explicitly unsupported. A later supported entry
  requires a new approved integration version with a configured/user-approved key-locator receipt
  or an exact-target, zero-effect subserver observation family respectively.
- This evidence proves only that versioned integration inputs are registered and fail closed. It
  does not change `TASK-M1-006`, any `AC-HDC-*`, macOS conformance, hardware support or release
  state. Per the approved PR boundary, TASK-I15-001 remains `ready`; after maintainer review/merge
  of the implementation PR, a separate status-only PR may propose `ready→done`.
