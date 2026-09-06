# TASK-SVC-005 — final residual audit for CHG-2026-075

SVC-AC-10 asks for two things: `残留逐项归属`, and GJ-1..5 headless plus the affected App
presentation checks on current-Catalog real evidence. They are independent. This file delivers the
first. **It is not an acceptance record and claims no journey result** — no device leg has been
executed, `evidence/runs/TASK-SVC-005/run.md` does not exist yet, and TASK-SVC-005 stays `ready`.

Audited against `3fe7a6b1` (main after #1747). Every row below was read on that tree; nothing is
carried over from an earlier scan unverified. Rows inherited from
`evidence/runs/TASK-SVC-004/residual-audit.md` are marked and were re-read rather than copied.

## Repaired since the SVC-004 audit (both still open as PRs)

| Surface | Outcome |
| --- | --- |
| `PublishedOperationBundleManifest.schemaVersion = "2.0.0"` (`ArkDeckRuntime/RuntimeOperationModels.swift:432`) and the stale `"2.0.0"` comment on `RuntimeRequestEnvelope` (`ArkDeckWorkflows/RuntimeJobEngine.swift:73-75`) — SVC-004 audit row, "not re-verified on the delivered tree" | Re-verified as still present on `3fe7a6b1`, then repaired on branch `agent/task-svc-001-last-own-format-2-0-0-20260906` (`8ca1b0fb`, declaring TASK-SVC-001), **open, not yet merged**. There the constant is `1.0.0`, the reader enforces both identity fields, and the comment no longer names a literal. It was the last own-format `2.0.0` in the Swift sources. |
| `doctor` findings emitting `details` keys `spec/control/methods/doctor.json` does not publish — `runtime.jobRecordUnreadable`, `runtime.durableRecordsUnreadable`, `hdc.identityUnavailable` | Repaired in PR #1748 (declaring TASK-SVC-002), **open, not yet merged**. Found by recording a frame run, not by inspection; two of the three were introduced by this change's own follow-ups. |

## Open — needs a maintainer decision, not a follow-up PR

| Surface | Why it cannot be closed by a Task |
| --- | --- |
| `RuntimeHardwareEvidenceAuthorityKind` still declares `standingAuthorization` and `evolutionCampaignConfirmation` (`ArkDeckAgentClient/HardwareEvidenceProjector.swift:20-21`), refused by name at `:563-564` | The projector is in TASK-SVC-003's Allowed paths; the switch arm that must change with it, `HeadlessRuntimeVerifier.swift:544`, is not. `evidence/runs/TASK-SVC-003/scope-review.md` carries the exact diff and states the decision is the maintainer's. Both shapes fail closed — the difference is a named refusal versus a decode failure — so this is vocabulary, not a defect. |
| `BootstrapToolRegistry.swift:623` accepts `arkdeck.bootstrap-tools/1` beside the `/2` every writer emits (`:69`, `:687`), with a live adoption path at `ArkDeckAgentDaemonMain/main.swift:559-561` | The file is in TASK-SVC-001's Allowed paths, but SVC-001 Deliverable 6 (`tasks.md`) says in as many words that the Bootstrap registry `只迁移helper调用，不改变各自持久化格式或信任边界`. Granted by path, forbidden by the Task's own text. |
| `RuntimeWorkspaceProjectStore.swift:1292-1293` accepts `arkdeck.workspace-project-store/1|/2|/3` and `:1425` migrates to `/3` — inherited SVC-004 row, re-read | Still true, and still owned by no SVC Task in this change. |
| `OpenHarmonyLocalSigning.swift:1276` `supportedCertificateChainReadback` — inherited SVC-004 row, re-read | Still a durable-intent payload compatibility, in an allowlisted file. Unchanged for the reason SVC-004 gave: refusing it would change pending-intent semantics under POL-RECOVERY-001. |

## Open — in scope by the change's text, owned by no Task in this change

| Surface | Ownership |
| --- | --- |
| `WorkflowStepValidator.signingPresetReference` (`ArkDeckCore/WorkflowStep.swift:1159-1166`, its comment at `:1156`, its only caller at `:1044`) accepts `openharmony-release@1` — its own comment calls it "the legacy … credential preset" — or a registered `preset-` reference, while `openspec/contracts/workflow-step.schema.json` pins `"signingPresetRef": {"const": "openharmony-release@1"}` | Neither file is named by any TASK-SVC in this change; both are named in `chg-2026-025`, `chg-2026-049` and `chg-2026-054`. Note the divergence is not a duality on both sides: a JSON Schema `const` admits exactly one value, and the file contains no `preset-` anywhere, so **the published schema is strictly narrower than the Swift grammar** — a step carrying a registered preset passes the Swift validator and fails the published schema. That is the finding to hand on, not "both accept two shapes". |

## Present, in grant, and deliberately not removed

| Surface | Why it stays |
| --- | --- |
| `ArkDeckWorkflows/Bootstrap/DeviceObservationIdentity.swift` — its header describes "the legacy 1.x discovery surface" against "Target v2 observations", and the `DeviceObservationIdentity` struct has zero references anywhere in `Sources` or `ArkDeckApp` outside its own definition | Inside TASK-SVC-001's `ArkDeckWorkflows/Bootstrap/**` grant, so it could be removed. It is not a contract this change consolidates — it is dead code carrying two-generation prose — and removing dead code is not among this change's Deliverables. Recorded so the next dead-code sweep has the citation rather than rediscovering it. |

## What is deliberately absent from this file

No SVC-AC verdicts and no journey results. SVC-AC-01..09 are settled by the SVC-001..004 run
records; SVC-AC-10's second half needs the device window. On the host that would run it, measured
2026-09-06: `hdc list targets` returns `[Empty]` and `ioreg -r -c IOUSBHostDevice` reports no USB
device, so no leg of GJ-1..5 could be attempted, honestly or otherwise.
