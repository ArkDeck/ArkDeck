# TASK-SVC-005 run record

Status: `done` (2026-09-09). GJ-4 passed on the published `6e8c3ed5` build at
10:23Z, after two refusals that day and the maintainer's DEC-016 (#1821,
implemented by #1822) letting the DEC-014 campaign admit the complete-overwrite
recovery; GJ-5 passed on the published Runtime. Every Journey has a current
record on Catalog digest `508783ac…`, and SVC-AC-01..10 each have a reviewable
result — SVC-AC-04 and SVC-AC-08 rest on SVC-001's and SVC-003's contract tests
and run records, stated as such and not as device results.

Session publication, read and export all complete on the published Runtime — see
the 2026-09-09 window. `session list` still refuses while one preserved
incomplete 2026-08-02 Session is unaccounted, which is the correct answer for a
question about the whole root.

GJ-3's rollback leg **did** pass — this record originally said otherwise and is
corrected below. The defects found during these windows were reviewed, merged
and re-verified on this host.

## Windows

| Date | Build | Outcome |
| --- | --- | --- |
| 2026-09-08 | protected `main` `6ba5a0b9` → `31142a78` → `16fe9617`, daemons `c1d313a0…` → `609b706f…` → `5bb46f59…` | Real DAYU200 window and the post-merge re-verification. Full per-command results, SVC-AC-01..10, Journey states, App presentation and the single-v1 baseline: [`docs/design/references/single-v1/svc-acceptance-2026-09-08-published-main.md`](../../../../../../docs/design/references/single-v1/svc-acceptance-2026-09-08-published-main.md) |
| 2026-09-08 (earlier) | `6a8a06fc` then `0b35d535` | Host import/Artifact export and published readbacks: [`host-import-export-20260908.md`](host-import-export-20260908.md) |
| 2026-09-09 | protected `main` `5933ba84` then `c3a19631`, daemons `811cad2e…` then `bd274fde…` | Host-only window, no device connected. **`session export apply` passes on the published Runtime**; the exported manifest redacts the device identifier to a schema-valid form and the source Session is unchanged. Journey Jobs re-read through `job evidence` on this build. Full record: [`docs/design/references/single-v1/svc-acceptance-2026-09-09-published-main.md`](../../../../../../docs/design/references/single-v1/svc-acceptance-2026-09-09-published-main.md) |
| 2026-09-09 (device window) | `main` `8c6a376c` + PR #1810 (`5e1702f4`), local helper build, daemon `6e6c4df2…`, CLI `42c7b992…` | **GJ-5 `REAL_DEVICE_PASS`** through published leaves only, after the signing credential was rebound to the registered project — which needed #1810 first, because a credential owner no preset record carried blocked `runtime signing remove`/`install` with no product path out. Record: [`docs/design/references/single-v1/gj-headless-rerun-2026-09-09.json`](../../../../../../docs/design/references/single-v1/gj-headless-rerun-2026-09-09.json), narrative in the 2026-09-09 acceptance record. |
| 2026-09-09 (device window, continued) | GJ-4: `main` `8c6a376c` + #1810 build, daemon `6e6c4df2…`; GJ-5 repeat: protected `main` `8a28f182`, daemon `6035adcb…`, CLI `494e2a35…` | **GJ-4 `BLOCKED_BY_PRODUCT_DEFECT`**: window opened under DEC-014 (`gj4-headless-20260909`, 30/30 available), archive imported, lane plan previewed, `agent run flash.full-restore@1` refused `admissionDenied` before Job creation — the destructive lineage is closed by `job-bf0b748e…` and `job-c9274a31…` (2026-09-07, `outcomeUnknown`, `flash.recoveryProofMissing`); the refusal reason is published nowhere; window closed, ledger 32 → 32, device not written. **GJ-5 `REAL_DEVICE_PASS` on the published Runtime** (`gj5-20260909b-*`, 9 Jobs, ledger 41). Record: the 2026-09-09 acceptance record and `gj-headless-rerun-2026-09-09.json` (three journeys). |
| 2026-09-09 (device window, GJ-4) | protected `main` `6e8c3ed5` (DEC-016 #1821 + #1822), local helper build, daemon `02d685a0…`, CLI `6216ec38…` | **GJ-4 `REAL_DEVICE_PASS`**: campaign `gj4-headless-20260909b` 10:19:40Z–10:25:21Z (30/30 open, 28/30 after), lane plan `PLAN-76e77b4b…`, `agent run flash.full-restore@1` admitted as a complete-overwrite recovery epoch, `job-6d1e329e…` terminal `recovered`, evidence `verified`, no blockers, readback `OpenHarmony-7.0.0.37`, epoch `recovery-epoch-a985dcca…` superseding `job-c9274a31…` on `bindingRevision 2`; postflight `observe.device@1` `job-9b2b7535…` succeeded, binding still r2; ledger 41 → 43. Record: the 2026-09-09 acceptance record §GJ-4 pass and `gj-headless-rerun-2026-09-09.json` (GJ-4 run 2). |

The 2026-09-08 window used only `arkdeck agent run` and published typed resource
commands. No raw HDC, shell or flash command was submitted, no capability was
created or edited, no durable record was hand-modified, no unknown intent was
replayed and no state directory was swapped or cleared. The three pre-existing
`waitingForRecovery` Jobs were read and left exactly as they were.

## Commands

Argument-for-argument captures with exit codes and output hashes are local at
`/private/tmp/arkdeck-gj-headless-20260908b/` (`before/`, `after/`, `gj1/`,
`gj1cap/`, `gj2/`, `gj2c/`, `gj3/`, `gj4/`, `restart/`, `session/`, `export/`).
They are not committed; the acceptance record carries the identities, states and
digests needed to re-check them.

## Residual, and who owns each item

| Item | Owner |
| --- | --- |
| `agent.run` reported a failed Job's evidence as `verified` | TASK-SVC-002, #1777 merged and re-verified on `31142a78` |
| Session refusal named nothing, and a readable-name/unreadable-content directory was reported as a malformed name | TASK-SVC-002, #1780 merged and re-verified on `16fe9617` against the real 2026-08-02 directory |
| Post-flash alias revision counter is reissued when the daemon state directory is retired; GJ-4 blocked | TASK-AFA-001, #1779 merged; the named refusal is live on the host, **the reconciliation still has no entry point** — it needs `openspec/contracts/cli-command-registry.yaml` and `cli-feature-coverage.json` added to that Task |
| ~~`deploy.native-library.app-owned@1` publishes no rollback attestation~~ | **Withdrawn.** It does, in the Job Journal: `verified rollback-native-library ["processIds", "restored", "restoredSha256"]` then `verified cleanup-native-library-compensation ["backupRetained", "cleaned"]`. The original finding was made from the Artifact inventory and a deduplicated step-kind list, neither of which can show a compensation. GJ-3's rollback leg is `REAL_DEVICE_PASS`. |
| ~~No production caller publishes a Session; SVC-AC-05 and SVC-AC-10 cannot pass~~ | **Superseded.** A production caller publishes a Session (`job-71f00adafcce67d0de4eed11ebb4b5c3`, `manifestSha256 270bd40d…`), and on 2026-09-09 `session export apply` completed on the published Runtime after #1799 fixed the export redaction. `session list`/`session show` remain refused by the preserved incomplete 2026-08-02 Session. |
| Session export produced a manifest its own validator refused | TASK-SVC-002, #1799 merged and verified on the published Runtime on 2026-09-09 |
| A pre-publication export refusal reports `outcomeUnknown` and consumes the preview; three previews on this host are stranded in `applying` | TASK-SVC-002, #1800 merged. **Not exercised on the published Runtime** — every refusal reachable from the published surface is raised before the preview is claimed, so the fix rests on its contract tests and the gate. The three stranded previews are not released retroactively. |
| ~~`session list`/`session show` refuse on a catalog the export path completes against~~ | **Resolved.** The distinction was deliberate: a whole-root answer cannot be partial, an exact answer about one named Session can. `show` was on the wrong side of it — repaired by #1805 and verified on the published Runtime. `list` still refuses, correctly, and names the leaf. |
| ~~`flash.full-restore@1` is Catalog-`unavailable` on this host (no named hardware acceptance campaign)~~ | **By design, DEC-014.** The operator-named campaign window (`runtime service update --arkforge-campaign`) opened it to 30 of 30 on 2026-09-09 and closed it again afterwards. |
| ~~GJ-1 §2.1 HAR crash-resume still not demonstrated~~ | **`REAL_DEVICE_PASS` 2026-09-09.** Executed on the published Runtime with the real DAYU200: `agent run` with no target parked a `physicalConnection` HAR at exit 75 with `newDispatchCount 0`, the receipt was discarded unread, and recovery from the execution id alone produced the identical `resumeReference` through `agent status` and `human-action show`. After resume the action reads `resolvedByFreshProbe`, `job-49720bb2a6c389007eb44e1998f7160f` is `succeeded` with no blockers, and all three Artifacts stay on `TGT-958780b2ffb7` at `bindingRevision 2` — no rebind. |
| ~~GJ-5 not started; `workspace.sign-openharmony-hap@1` unavailable~~ | **`REAL_DEVICE_PASS` on the published Runtime `8a28f182`** (08:30Z), after passing on the `main` + #1810 candidate build (07:56Z) that cleared the credential blocker. |
| ~~A new destructive execution on `TGT-958780b2ffb7` is refused at admission while the two 2026-09-07 flash Jobs stay `outcomeUnknown`; GJ-4 blocked~~ | **Resolved 2026-09-09 10:23Z.** Diagnosed through the recovery invocation path (`debug-070a56fb…`, `refusedBeforeDispatch`) to `completeOverwriteRecovery.sharedFourHourBudgetExpired`; the maintainer ruled DEC-016 (#1821), `TASK-AFA-001` implemented it (#1822), and on the published `6e8c3ed5` build the same request was admitted as a complete-overwrite recovery epoch and reached `recovered`. GJ-4 `REAL_DEVICE_PASS`; the 2026-09-07 outcomes stay unknown by design and `job-bf0b748e…` (binding revision 1) stays parked outside the r2 lineage. |
| `agent run` reports `admissionDenied` / `execution stopped before Job creation` with the engine's reason dropped; `agent status`, the execution record and `agentd.log` carry none either | TASK-SVC-002 (`AgentExecutionCoordinator.swift`): publish the refusal reason; needs the `agent.run`/`agent.status` schemas re-derived because `arkdeck.runtime-agent-execution/1` is closed |
| `runtime service update` restarts fail transiently on the orphaned managed HDC server (`managed HDC launch could not be bound to its live process identity`) until launchd's retry succeeds — twice today | Observation; the restart race the 2026-09-02 record describes, recovered without intervention both times |
| A credential owner no preset record carries blocks `runtime signing remove` and `install` for good (the 2026-09-02 `demo-app` signing preset survived the state-directory retirement in the owner ledger) | TASK-OHS-001, #1810 merged: startup release of owners the store no longer carries; verified on this host before GJ-5 ran |
| The preset resolution failure is discarded and shown as `runtimeRestartRequired`; `runtime signing status` reports `ready: true` for a credential no registered project can use | **Decided 2026-09-09.** #1802/#1803 already project such a preset as `unresolved` (no restart promised). A reason field on `workspace.preset.list/show` needs `spec/control/methods/**` plus `RuntimeWorkspaceProjectStore.swift`, which no single Task in this or the signing change covers, so the reason stays unpublished for now and the operator's diagnosis path is documented instead (`runtime signing status` → `projectRef` against `workspace project list`; `agent/preset-lifecycle-unresolved-doc-20260909`). `runtime signing status` keeps `ready: true` — it is a CLI-local material probe and does not claim a project binding — and the join stays with the operator. |
| `session.export.apply` can answer `outcomeUnknown` after the destination is replaced, a code `spec/control/methods/session.export.apply.json` does not publish | TASK-SVC-002, #1815 merged: a control-plane test drives the post-publication fault, the frame is recorded and the schema re-derived |
| Export redaction has no rule for 21 character-constrained arguments; host-scope targets contribute `providerId` and the catalog digest to the device-identity set | **Decided 2026-09-09, DEC-015:** the pre-publication refusal is the correct end state for closed enumerations and constants, and the identity set is not narrowed (a privacy-policy change, not a cleanup). Not an open item. |

## Completion

Nothing further is required. Where each SVC-AC result is:

| AC | Result | Where |
| --- | --- | --- |
| SVC-AC-01, 02, 03 | met on the published Runtime | 2026-09-08 record |
| SVC-AC-04 | contract tests and SVC-001's run record; not a device result | 2026-09-08 record, unchanged |
| SVC-AC-05 | publication, read and export met on the published Runtime | 2026-09-09 record |
| SVC-AC-06 | zero replay and zero new dispatch on 2026-09-08; the recovery leg met on the published Runtime by GJ-4 (complete-overwrite epoch, intents not replayed); fault matrix with the contract tests | 2026-09-08 and 2026-09-09 records |
| SVC-AC-07 | met after #1777, re-read on the published Runtime | 2026-09-08 and 2026-09-09 records |
| SVC-AC-08 | contract tests and SVC-003's run record; not a device result | 2026-09-08 record, unchanged |
| SVC-AC-09 | met on the published Runtime | 2026-09-09 record |
| SVC-AC-10 | GJ-1..5 all `REAL_DEVICE_PASS` on digest `508783ac…` | 2026-09-08 record, 2026-09-09 record, `gj-headless-rerun-2026-09-09.json` |

The open rows above (the dropped `agent run` refusal reason, the alias
reconciliation entry point) belong to `TASK-SVC-002` and `TASK-AFA-001`. The
change-level verify and archive steps for CHG-2026-075 are the maintainer's.
Local captures for 2026-09-09 are under `/private/tmp/arkdeck-gj-headless-20260909/`
(`gj5/`, `gj5b/`, `gj4/`, `gj4-recovery/`, `gj4b/`) and are not committed.

Each Journey result stays attached to the build it was taken on and is not
carried forward to a later digest.
