# TASK-SVC-005 run record

Status stays `ready`. This Task is not done: GJ-4 is still blocked, GJ-5 was not
started, GJ-1's HAR leg and GJ-3's rollback leg did not pass, and Session export
has no producer. The four defects found during the window were reviewed, merged
and re-verified on this host the same day.

## Windows

| Date | Build | Outcome |
| --- | --- | --- |
| 2026-09-08 | protected `main` `6ba5a0b9` → `31142a78` → `16fe9617`, daemons `c1d313a0…` → `609b706f…` → `5bb46f59…` | Real DAYU200 window and the post-merge re-verification. Full per-command results, SVC-AC-01..10, Journey states, App presentation and the single-v1 baseline: [`docs/design/references/single-v1/svc-acceptance-2026-09-08-published-main.md`](../../../../../../docs/design/references/single-v1/svc-acceptance-2026-09-08-published-main.md) |
| 2026-09-08 (earlier) | `6a8a06fc` then `0b35d535` | Host import/Artifact export and published readbacks: [`host-import-export-20260908.md`](host-import-export-20260908.md) |

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
| `deploy.native-library.app-owned@1` publishes no rollback attestation, so the rollback leg cannot be shown to have restored anything | unassigned; recorded unverified rather than repaired |
| No production caller publishes a Session; SVC-AC-05 and SVC-AC-10 cannot pass | the reviewed Session publication slice, not delivered |
| `flash.full-restore@1` is Catalog-`unavailable` on this host (no named hardware acceptance campaign) | maintainer window, independent of the alias blocker |
| GJ-1 §2.1 HAR crash-resume not executed | needs a physical USB detach and reattach |
| GJ-5 not started | next window |

## Still required before this Task can be done

1. Wire the alias reconciliation entry point (needs the two contract paths
   above), then clear GJ-4's second gate — `flash.full-restore@1` is separately
   Catalog-`unavailable` for want of a named hardware acceptance campaign.
2. Give `deploy.native-library.app-owned@1` a rollback attestation, then re-run
   GJ-3's rollback leg.
3. Run GJ-1 §2.1 HAR crash-resume (physical detach and reattach).
4. Deliver the reviewed Session publication slice, then SVC-AC-05 and the
   Session half of SVC-AC-10.
5. Run GJ-5.

Each Journey result stays attached to the build it was taken on and is not
carried forward to a later digest.
