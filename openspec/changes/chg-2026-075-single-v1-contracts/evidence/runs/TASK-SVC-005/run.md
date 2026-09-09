# TASK-SVC-005 run record

Status stays `ready`. This Task is not done: GJ-4's second gate is still blocked
on a maintainer decision and GJ-5 was not started.

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
| `flash.full-restore@1` is Catalog-`unavailable` on this host (no named hardware acceptance campaign) | maintainer window, independent of the alias blocker |
| GJ-1 §2.1 HAR crash-resume still not demonstrated | needs a physical USB detach and reattach. The execution named `gj1-har-20260908` completed with `humanAction: null` and a straight `queued→preflight→running→finalizing→succeeded` timeline, so it did not exercise the path its name claims. |
| GJ-5 not started; `workspace.sign-openharmony-hap@1` unavailable | **Blocker diagnosed 2026-09-09.** The signing credential `credential:sha256-562430f169…` is bound to `projectRef: demo-app`, which is not a registered project, so the signing preset fails its startup binding check and is projected as `runtimeRestartRequired` — a remedy no restart can satisfy. Remedy is `runtime signing install --project-ref project-fd677365f7bdefabda66a3c1`, a maintainer action requiring the credential material. |
| The preset resolution failure is discarded and shown as `runtimeRestartRequired`; `runtime signing status` reports `ready: true` for a credential no registered project can use | needs a scope revision — `RuntimeWorkspaceProjectStore.swift` and `ArkDeckAgentDaemonMain/main.swift` are in no SVC Task's Allowed paths in this change |

## Still required before this Task can be done

1. Wire the alias reconciliation entry point, then clear GJ-4's second gate —
   `flash.full-restore@1` is separately Catalog-`unavailable` for want of a
   named hardware acceptance campaign.
3. Run GJ-1 §2.1 HAR crash-resume (physical detach and reattach), which
   `gj1-har-20260908` did not exercise.
4. Run GJ-5.
5. Nothing further on the preserved incomplete Session: it blocks only
   `session list`, which is the correct whole-root contract.

Each Journey result stays attached to the build it was taken on and is not
carried forward to a later digest.
