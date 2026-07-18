# TASK-M1-009 implementation review remediation — round 3

## Run identity

- Task: `TASK-M1-009`
- Change: `CHG-2026-002-macos-m1-infrastructure`
- Base revision: `3a4d45c9f027b26c5a97880150cc4c965d25859b`
- Branch: `agent/TASK-M1-009`
- Run time: `2026-07-18T03:37:45Z` (`2026-07-18T11:37:45+0800`, Asia/Shanghai)
- Evidence class: implementation review remediation; supplements the prior TASK-M1-009 run
  records.
- Safety classification: local macOS generated fixtures only; no real HDC, device, external
  network, destructive/device operation, upload, or hardware evidence.
- Governance state: this record does not change approval or completion state. `TASK-M1-009`
  remains `ready` pending human re-review.

## Review findings and remediation

1. Cleanup no longer treats a missing post-rename name as proof that the exported bytes are gone.
   When `fstatat` returns `ENOENT`, cleanup now verifies through the retained staging descriptor
   that the directory is the expected device/inode and has `st_nlink == 0`. A still-linked inode,
   including one moved to another name, makes cleanup fail; the exporter maps that failure to
   `exportOutcomeUnknown`.
2. A deterministic `afterRenameBeforeCommit` vector moved the destination directory to
   `moved-diagnostic-bundle` and then injected an error. The original destination name was absent,
   the moved directory remained observable, and export returned exactly `exportOutcomeUnknown`
   rather than the injected ordinary error.
3. Pre-publication expected-file validation now opens every candidate with
   `O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW` before applying the existing owner, link-count,
   regular-file, device, size, and SHA-256 checks. A deterministic `beforePublish` vector replaced
   `metadata.json` with an owner-only FIFO. Validation returned immediately, rejected the FIFO as a
   changed/non-regular entry, removed the anchored staging tree, and left no destination or staging
   residue.

## Verification results

| Command | Result |
| --- | --- |
| `swift format lint --strict <four TASK-M1-009 Swift files>` | passed, 0 diagnostics |
| `swift test --package-path Packages/ArkDeckKit --filter DiagnosticsContractTests` | 14 tests, 0 failures |
| `swift test --package-path Packages/ArkDeckKit` | 183 tests, 0 failures, 1 pre-existing opt-in skip |
| `scripts/check-sdd.sh` | 0 errors, 0 warnings, 111 acceptance IDs |
| `git diff --check` | passed |

## Acceptance conclusions

| Test ID | Added round-3 vector | Conclusion |
| --- | --- | --- |
| `TEST-AC-DIAG-002-01` | post-rename move-away/unknown-outcome and non-blocking FIFO substitution/cleanup | PASS (`platform`) |
| `TEST-AC-DIAG-001-01` | existing bounded rotation vectors re-run | PASS (`platform`) |
| `TEST-AC-DIAG-001-02` | existing typed redaction and safe export semantics vectors re-run | PASS (`platform`) |
| `TEST-MAC-M1-DIAG-001` | existing Unified Logging, permission, and raw-exclusion vectors re-run | PASS (`platform`) |

## Deviations and residual risk

- No accepted Requirement, AC, contract/schema, platform/integration profile, conformance, release
  status, or other task state was changed.
- A moved, still-linked diagnostic directory is intentionally not deleted by searching unrelated
  paths: the API reports `exportOutcomeUnknown` so the caller cannot mistake it for a clean failure.
- Human review is still required before any later PR may propose `TASK-M1-009` as `done`.
