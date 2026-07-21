# TASK-M1-009 implementation review remediation

## Run identity

- Task: `TASK-M1-009`
- Change: `CHG-2026-002-macos-m1-infrastructure`
- Base revision: `3a4d45c9f027b26c5a97880150cc4c965d25859b`
- Branch: `agent/TASK-M1-009`
- Run time: `2026-07-18T02:56:42Z` (`2026-07-18T10:56:42+0800`, Asia/Shanghai)
- Evidence class: implementation review remediation; supplements `run.md`
- Environment and safety classification: local macOS generated fixtures only; no real HDC,
  device, external network, destructive/device operation, upload, or hardware evidence.
- Governance state: this record does not change task approval or completion state. The task remains
  `ready` pending human re-review and must not be represented as `done` from this local run.

## Review findings and remediation

1. Untrusted diagnostic JSONL no longer crosses the export boundary verbatim.
   `RedactedDiagnosticLogFile` accepts only the controlled rotating-segment filename shape, applies
   strict duplicate-key and closed-shape JSON validation to every record, validates bounded values,
   replaces all non-placeholder field values, and deterministically anonymizes event names,
   correlation IDs, and field names. The malicious vector placed the synthetic device identifier in
   all three identifier positions and placed the user path and business string in field values;
   none of those source bytes remained. Unknown root members and an attacker-chosen filename were
   rejected.
2. `export` now prepares the request once. The preview comparison and all staged writes use the
   same immutable `PreparedBundle`. A deterministic fault hook replaced the URL-backed recent
   Session manifest after preparation; the published manifest summary retained the SHA-256 of the
   prepared/approved source and did not contain the replacement SHA-256.
3. Diagnostic publication now opens and binds the approved parent directory descriptor and
   device/inode, creates and traverses staging content with `mkdirat`/`openat`, writes owner-only
   files, validates staged size/hash bytes, revalidates the parent and staging identities before
   an exclusive `renameatx_np`, and performs failure cleanup through anchored descriptors. The
   replacement vector moved the approved parent after staging opened and installed a new directory
   at the approved path. Publication failed closed; neither parent received a final bundle, the
   replacement marker survived, and the original parent had no staging residue.
4. The structured store now requires `S_IRWXG | S_IRWXO == 0` for its directory, writer lock, and
   every existing/open segment. Dedicated vectors rejected a `0755` directory and a `0644`
   segment. The successful platform export additionally checked every bundle directory and file
   for owner-only permissions.

## Verification results

| Command | Result |
| --- | --- |
| `swift build --package-path Packages/ArkDeckKit` | passed |
| `swift format lint --strict <four TASK-M1-009 Swift files>` | passed, 0 diagnostics |
| `swift test --package-path Packages/ArkDeckKit --filter DiagnosticsContractTests` | 8 tests, 0 failures |
| `swift test --package-path Packages/ArkDeckKit` | 177 tests, 0 failures, 1 pre-existing opt-in skip |
| `scripts/check-sdd.sh` | 0 errors, 0 warnings, 111 acceptance IDs |
| `git diff --check` | passed |
| static no-network/process/device scan of the two production files | passed; only typed category, privacy, raw-exclusion, and placeholder references |

## Acceptance conclusions

| Test ID | Added review vector | Conclusion |
| --- | --- | --- |
| `TEST-AC-DIAG-001-01` | existing quota, rotation, cleanup, and torn-tail vectors re-run | PASS (`platform`) |
| `TEST-AC-DIAG-001-02` | forged JSONL strict parsing, identifier anonymization, field re-redaction, closed-shape rejection | PASS (`platform`) |
| `TEST-AC-DIAG-002-01` | prepared-byte mutation and parent path replacement/failure-cleanup vectors | PASS (`platform`) |
| `TEST-MAC-M1-DIAG-001` | `0755` directory/`0644` segment rejection and full bundle permission walk | PASS (`platform`) |

## Deviations and residual risk

- No accepted Requirement, AC, contract/schema, platform/integration profile, conformance, release
  status, or other task state was changed.
- The fault vectors use same-user local filesystem mutation in temporary directories and are
  simulation evidence, not evidence of hostile multi-process behavior on every filesystem.
- Unified Logging persistence remains controlled by macOS; this run verifies ArkDeck's redacted
  sink input, structured store, and export boundary, not the OS log database retention policy.
- Human review is still required before any later PR may propose `TASK-M1-009` as `done`.
