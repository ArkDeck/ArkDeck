# TASK-SVC-005 — final residual audit for CHG-2026-075

SVC-AC-10 asks for two things: `残留逐项归属`, and GJ-1..5 headless plus the affected App
presentation checks on current-Catalog real evidence. They are independent. This file delivers the
first. **It is not an acceptance record and claims no journey result** — no device leg has been
executed, `evidence/runs/TASK-SVC-005/run.md` does not exist yet, and TASK-SVC-005 stays `ready`.

Audited against `3fe7a6b1` (main after #1747). Every row below was read on that tree; nothing is
carried over from an earlier scan unverified. Rows inherited from
`evidence/runs/TASK-SVC-004/residual-audit.md` are marked and were re-read rather than copied.

## Repaired since the SVC-004 audit (both merged)

| Surface | Outcome |
| --- | --- |
| `PublishedOperationBundleManifest.schemaVersion = "2.0.0"` (`ArkDeckRuntime/RuntimeOperationModels.swift:432`) and the stale `"2.0.0"` comment on `RuntimeRequestEnvelope` (`ArkDeckWorkflows/RuntimeJobEngine.swift:73-75`) — SVC-004 audit row, "not re-verified on the delivered tree" | Re-verified as still present on `3fe7a6b1`, then repaired by #1749 (`9b71ed8b`, TASK-SVC-001), merged. `RuntimeOperationModels.swift:432` is now `1.0.0`; `init(from:)` requires `schemaVersion` exactly (`:471-476`, so an absent one also fails) and rejects a foreign `documentType` when present (`:477-483`). It was the last own-format `2.0.0` **constant** in the Swift sources. Two corrections to this row as first written: the repair commit is the merge `9b71ed8b`, not the branch tip; and the claim that the comment "no longer names a literal" is false — `RuntimeJobEngine.swift:76` still contains `"2.0.0"`, deliberately, as a note that it was the value the comment used to assert. What changed is that the comment no longer presents it as the envelope's current version; the code at `:78` forwards `RuntimeOperationRequest.schemaVersion` and never held a literal. |
| `doctor` findings emitting `details` keys `spec/control/methods/doctor.json` does not publish — `runtime.jobRecordUnreadable`, `runtime.durableRecordsUnreadable`, `hdc.identityUnavailable` | Repaired by #1748 (`719c172e`, TASK-SVC-002), merged. Re-verified by enumerating every `addFinding` call in `doctorReport`: exactly five now pass a non-empty `details`, carrying `availableOperationCount`, `unavailableOperationCount`, `providerCount`, `adoptedTargetCount`, `outstandingCleanupCount` — identical to the closed set `spec/control/methods/doctor.json` publishes. Found by recording a frame run, not by inspection; two of the three were introduced by this change's own follow-ups. |

## Open — needs a maintainer decision, not a follow-up PR

| Surface | Why it cannot be closed by a Task |
| --- | --- |
| `RuntimeHardwareEvidenceAuthorityKind` still declares `standingAuthorization` and `evolutionCampaignConfirmation` (`ArkDeckAgentClient/HardwareEvidenceProjector.swift:20-21`), refused by name at `:563-564` | The projector is in TASK-SVC-003's Allowed paths; the switch arm that must change with it, `HeadlessRuntimeVerifier.swift:544`, is not. The reason this is a maintainer decision is narrower than "no Task can reach the file", which is how this row first put it and which is wrong: TASK-SVC-001's Allowed paths carry the wildcard `Packages/ArkDeckKit/Sources/ArkDeckAgentClient/**`, which covers **both** files. What blocks it is TASK-SVC-004 Deliverable 5: `SVC001..003范围遗漏使用原Task ID和原Allowed paths提交必要的后续修复PR ... 不借本Task扩大Allowed paths`. This is an SVC-003 gap, so it must return under SVC-003's ID and SVC-003's paths — which do not include the verifier — and reaching for SVC-001's wider grant instead is exactly what that sentence forbids. The sanctioned route is a scope supplement to SVC-003 (the #1745 precedent) or an explicit waiver. `evidence/runs/TASK-SVC-003/scope-review.md` carries the exact diff. Both shapes fail closed — the difference is a named refusal versus a decode failure — so this is vocabulary, not a defect. |
| `BootstrapToolRegistry.swift:623` accepts `arkdeck.bootstrap-tools/1` beside the `/2` every writer emits (`:69`, `:687`), with a live adoption path at `ArkDeckAgentDaemonMain/main.swift:559-561` | The file is in TASK-SVC-001's Allowed paths, but SVC-001 Deliverable 6 (`tasks.md`) says in as many words that the Bootstrap registry `只迁移helper调用，不改变各自持久化格式或信任边界`. Granted by path, forbidden by the Task's own text. |
| `RuntimeWorkspaceProjectStore.swift:1292-1293` accepts `arkdeck.workspace-project-store/1|/2|/3` and `:1425` migrates to `/3` — inherited SVC-004 row, re-read | Still true, and still owned by no SVC Task in this change. Re-read on `371cd9d2`, and the row as first written understated it: the same `guard` carries a **second** generation gate at `:1302-1304`, which additionally admits `/1` only when `document.presets.isEmpty && document.pendingToolchainMutation == nil`. So `/1` is not merely accepted — it is accepted under a narrower shape than `/2` and `/3`, which is a live compatibility rule, not a version-string tolerance. |
| `OpenHarmonyLocalSigning.swift:1276` `supportedCertificateChainReadback` — inherited SVC-004 row, re-read | Still a durable-intent payload compatibility, in an allowlisted file. Unchanged for the reason SVC-004 gave: refusing it would change pending-intent semantics under POL-RECOVERY-001. |

## Open — in scope by the change's text, owned by no Task in this change

| Surface | Ownership |
| --- | --- |
| `WorkflowStepValidator.signingPresetReference` (`ArkDeckCore/WorkflowStep.swift:1159-1166`, its comment at `:1156`, its only caller at `:1044`) accepts `openharmony-release@1` — its own comment calls it "the legacy … credential preset" — or a registered `preset-` reference, while `openspec/contracts/workflow-step.schema.json` pins `"signingPresetRef": {"const": "openharmony-release@1"}` | Neither file is named by any TASK-SVC in this change; both are named in `chg-2026-025`, `chg-2026-049` and `chg-2026-054`. Note the divergence is not a duality on both sides: a JSON Schema `const` admits exactly one value, and the file contains no `preset-` anywhere, so **the published schema is strictly narrower than the Swift grammar** — a step carrying a registered preset passes the Swift validator and fails the published schema. That is the finding to hand on, not "both accept two shapes". |

| `WorkspaceOperationsProvider.swift:171` `allowsLegacySigningPresetFallback`, defaulted to `true` at `:197` and set to `registeredPresets == nil` at `:573`, and carried through `AgentComposition/EvolutionWorkspaceManager.swift:804` | The production half of the signing-preset row above, and missing from that row as first written: the grammar in `WorkflowStep.swift` is what a step may *say*, this switch is what the provider *does* when a workspace has registered no presets. `WorkspaceOperationsProvider.swift` and `EvolutionWorkspaceManager.swift` are in TASK-SVC-004's Allowed paths, `WorkflowStep.swift` and the contract are in no Task's — so the duality still cannot be retired by one PR, but the reason is that the halves are split across a grant boundary, not that all of it is unowned. |

## Present, in grant, and deliberately not removed

| Surface | Why it stays |
| --- | --- |
| `ArkDeckWorkflows/Bootstrap/DeviceObservationIdentity.swift` — its header describes "the legacy 1.x discovery surface" against "Target v2 observations", and the `DeviceObservationIdentity` struct has zero references anywhere in `Sources` or `ArkDeckApp` outside its own definition | Inside TASK-SVC-001's `ArkDeckWorkflows/Bootstrap/**` grant, so it could be removed. It is not a contract this change consolidates — it is dead code carrying two-generation prose — and removing dead code is not among this change's Deliverables. Recorded so the next dead-code sweep has the citation rather than rediscovering it. |

## What is deliberately absent from this file

No SVC-AC verdicts and no journey results. SVC-AC-01..09 are settled by the SVC-001..004 run
records; SVC-AC-10's second half needs the device window. On the host that would run it, measured
2026-09-06: `hdc list targets` returns `[Empty]` and `ioreg -r -c IOUSBHostDevice` reports no USB
device, so no leg of GJ-1..5 could be attempted, honestly or otherwise.
