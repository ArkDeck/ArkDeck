# TASK-M1-009 implementation review remediation — round 4

## Run identity

- Task: `TASK-M1-009`
- Change: `CHG-2026-002-macos-m1-infrastructure`
- Base revision: `3a4d45c9f027b26c5a97880150cc4c965d25859b`
- Branch: `agent/TASK-M1-009`
- Run time: `2026-07-18T03:54:01Z` (`2026-07-18T11:54:01+0800`, Asia/Shanghai)
- Evidence class: implementation review remediation; supplements the prior TASK-M1-009 run
  records.
- Safety classification: local macOS generated fixtures only; no real HDC, device, external
  network, destructive/device operation, upload, or hardware evidence.
- Governance state: this record does not change approval or completion state. `TASK-M1-009`
  remains `ready` pending human re-review.

## Review findings and remediation

1. The writer authority is now anchored to the already-opened log-directory inode. Store
   initialization acquires a non-blocking exclusive lock on that directory descriptor before it
   opens `.writer.lock`; this prevents a replacement lock file from admitting a second writer for
   the same directory inode.
2. The marker lock is also continuously bound to its path. Initialization and every later binding
   validation compare the opened `.writer.lock` descriptor with an `fstatat(...,
   AT_SYMLINK_NOFOLLOW)` lookup through the anchored directory descriptor, including type, owner,
   owner-only mode, link count, device, and inode. Appends validate these bindings before any
   rotation, pruning, or segment write.
3. A deterministic negative vector keeps store 1 alive, unlinks and recreates `.writer.lock`, and
   then attempts both writers. Store 2 is rejected with `activeWriterExists`; store 1 fails closed
   with `unsafeLogDirectory`; byte-for-byte snapshots prove that no existing segment changed.
4. Journal summaries now require a provable single identity. Every replay event must match the
   materialized manifest's Session ID and Job ID, the replay must be non-empty, and its derived
   execution mode must exactly match the manifest. Otherwise preview rejects the input as
   `invalidInput` rather than combining unrelated diagnostics.
5. The normal diagnostic fixture now uses `session-diagnostics` / `job-diagnostics` consistently.
   Negative tests independently vary Session ID, Job ID, and execution mode and require every
   mismatched request to fail without creating a destination.

## Verification results

| Command | Result |
| --- | --- |
| `swift format lint --strict <four TASK-M1-009 Swift files>` | passed, 0 diagnostics |
| `swift test --package-path Packages/ArkDeckKit --filter DiagnosticsContractTests` | 16 tests, 0 failures |
| `swift test --package-path Packages/ArkDeckKit` | 185 tests, 0 failures, 1 pre-existing opt-in skip |
| `scripts/check-sdd.sh` | 0 errors, 0 warnings, 111 acceptance IDs |
| `git diff --check` | passed |

## Acceptance conclusions

| Test ID | Added round-4 vector | Conclusion |
| --- | --- | --- |
| `TEST-AC-DIAG-002-01` | reject mismatched Session/Job/executionMode journal summaries | PASS (`platform`) |
| `TEST-AC-DIAG-001-01` | stable directory-inode writer authority and lock-path replacement fail-closed behavior | PASS (`platform`) |
| `TEST-AC-DIAG-001-02` | existing typed redaction and safe export semantics vectors re-run | PASS (`platform`) |
| `TEST-MAC-M1-DIAG-001` | replacement marker cannot create a second writer; existing platform vectors re-run | PASS (`platform`) |

## Deviations and residual risk

- No accepted Requirement, AC, contract/schema, platform/integration profile, conformance, release
  status, or other task state was changed.
- Directory locking is deliberately paired with marker-path identity validation: the directory
  lock provides the stable writer authority, while the marker remains an observable fail-closed
  integrity signal.
- Human review is still required before any later PR may propose `TASK-M1-009` as `done`.
