# TASK-M1-009 implementation review remediation — round 2

## Run identity

- Task: `TASK-M1-009`
- Change: `CHG-2026-002-macos-m1-infrastructure`
- Base revision: `3a4d45c9f027b26c5a97880150cc4c965d25859b`
- Branch: `agent/TASK-M1-009`
- Run time: `2026-07-18T03:19:19Z` (`2026-07-18T11:19:19+0800`, Asia/Shanghai)
- Evidence class: implementation review remediation; supplements `run.md` and supersedes the
  round-1 behavior that anonymized all exported diagnostic identifiers/values.
- Environment and safety classification: local macOS generated fixtures only; no real HDC,
  device, external network, destructive/device operation, upload, or hardware evidence.
- Governance state: this record does not change task approval or completion state. The task remains
  `ready` pending human re-review and must not be represented as `done` from this local run.

## Review findings and remediation

1. The write boundary no longer accepts arbitrary strings for event names, field keys, or
   correlation IDs. `SystemLogEventName` and `SystemLogFieldKey` are closed enums, each field key
   requires its declared privacy class, public values are a closed `DiagnosticPublicCode` enum,
   and `DiagnosticCorrelationID` has only a generated initializer. `RedactedDiagnosticRecord` is
   encode-only with a module-private initializer, and the structured store append method is
   file-private, so callers cannot bypass `SystemLogger` with a decoded/constructed record. The
   negative vector attempted to put `fixture-device-serial-009` in a public field and verified that
   both the structured and captured Unified Logging sinks remained empty.
2. The storage-side JSONL boundary now validates the same closed event/field/public-code vocabulary,
   writer-generated correlation shape and privacy placeholders. It rejects
   attacker-selected event/correlation/key/value content instead of replacing all diagnostic
   meaning. Writer-produced records preserve the exact canonical category, event name, correlation
   ID, field key, and safe `publicValue`; byte assertions prove `privacy.contract`, every generated
   correlation ID, and `publicCode=diagnostics.test` survive export while the three sensitive
   fixture values remain absent.
3. Preview scope now includes the opened and path-verified export parent's `st_dev` and `st_ino`.
   Export recomputes that scope and passes the approved identity into staging construction. A
   vector replaced the parent after preview but before export; export returned
   `previewScopeMismatch`, did not publish into either directory, and preserved the replacement
   marker. The existing after-staging-open replacement vector also continues to fail closed.
4. `estimatedBytes` now converges over the exact canonical `bundle.json` containing the preview,
   tool placeholder, and generated timestamp. Export uses that same prepared timestamp and asserts
   exact equality between staged bytes and the approved estimate. A quota one byte below the
   estimate failed during preview; a quota exactly equal to the estimate previewed and exported
   successfully, and the resulting file-byte sum equaled `estimatedBytes`.
5. Publication now distinguishes `renamed` from `committed`. Post-rename identity/hash validation
   and parent durability must complete before commit; any intervening error invokes descriptor-
   anchored cleanup using the destination name. A deterministic post-rename fault left no
   destination or staging residue, and retry with the same approved preview succeeded. If cleanup
   itself cannot establish a known result, the API returns the explicit `exportOutcomeUnknown`
   error instead of reporting an ordinary pre-publication failure.

## Verification results

| Command | Result |
| --- | --- |
| `swift build --package-path Packages/ArkDeckKit` | passed |
| `swift format lint --strict <four TASK-M1-009 Swift files>` | passed, 0 diagnostics |
| `swift test --package-path Packages/ArkDeckKit --filter DiagnosticsContractTests` | 12 tests, 0 failures |
| `swift test --package-path Packages/ArkDeckKit` | 181 tests, 0 failures, 1 pre-existing opt-in skip |
| `scripts/check-sdd.sh` | 0 errors, 0 warnings, 111 acceptance IDs |
| `git diff --check` | passed |

## Acceptance conclusions

| Test ID | Added round-2 vector | Conclusion |
| --- | --- | --- |
| `TEST-AC-DIAG-001-01` | closed rotation event/field records remain accepted at the export seam | PASS (`platform`) |
| `TEST-AC-DIAG-001-02` | typed write boundary, two-sink leak rejection, forged JSONL rejection, and safe diagnostic semantics preservation | PASS (`platform`) |
| `TEST-AC-DIAG-002-01` | preview parent identity replacement, exact quota boundary, and post-rename cleanup/retry | PASS (`platform`) |
| `TEST-MAC-M1-DIAG-001` | existing Unified Logging, bounded store, permission, and raw-exclusion vectors re-run | PASS (`platform`) |

## Deviations and residual risk

- No accepted Requirement, AC, contract/schema, platform/integration profile, conformance, release
  status, or other task state was changed.
- Extending production diagnostic events or fields requires an intentional addition to both the
  runtime catalog and storage export validator, with a corresponding contract test; unknown values
  fail closed.
- Unified Logging persistence remains controlled by macOS; this run verifies ArkDeck's redacted
  sink input and export bytes, not the OS log database retention policy.
- Human review is still required before any later PR may propose `TASK-M1-009` as `done`.
