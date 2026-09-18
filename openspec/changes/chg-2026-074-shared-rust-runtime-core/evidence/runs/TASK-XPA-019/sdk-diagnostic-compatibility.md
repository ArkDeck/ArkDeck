# Swift SDK diagnostic compatibility — 2026-09-19

The ClientKit gate exposed three existing oracle byte mismatches on Apple Swift
6.4 (swiftlang-6.4.0.34.1, arm64-apple-macosx27.0.0). Diagnostic recordings were
written only to new `/private/tmp/clientkit-{quota,capability,plan}-audit-20260919`
directories. A field-level comparison found no code, details, successful result,
request, stored document or clock drift:

- ArtifactQuota: three `response.error.message` fields changed `typeMismatch:
  expected value of type` to `typeMismatch: Expected value of type`.
- CapabilityRead: four occurrences of the same capitalization, plus two
  `valueNotFound` messages dropping ` but found null instead` (23 bytes each).
- JobPlanAnalyzer: fifteen capitalization changes and four null-phrase changes.
  Its provenance difference is solely the SHA of the changed `cases.json`.

The production producers interpolate Foundation/Swift `DecodingError`; their
source and these oracle producers were unchanged by ClientKit. Oracle clocks
remain fixed at 2026-09-14. The differing bytes are the debug/message rendering
that design §G.1 r11 explicitly classifies T2; this is not a T0 or acceptance
criterion change.

A test-only `OracleSDKDiagnosticCompatibility` helper is used only by these three
compare paths. It normalizes the two observed spellings in the exact error-message
locations (including capability's exchange rows), limited to the recorded
expected type names. The null normalization requires the SDK's remaining
`found null value instead` clause. Record branches, production messages and
committed raw fixtures are unchanged.

Before normalizing, the helper checks that the original JSON round-trips to
exactly the original bytes using that oracle's encoder and trailing-newline
rule. Formatting, key/number spelling and duplicate-key drift therefore cannot
be silently hidden by parsing. All other files retain raw byte comparison.
For JobPlan, each side's original provenance hashes must first match its own
original raw file bytes. Only the comparison copy's cases SHA is then derived
from its normalized cases; all other provenance bytes remain compared.

Validation:

```
sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'OracleSDKDiagnosticCompatibilityTests|ArtifactQuotaOracleContractTests|CapabilityReadOracleContractTests|JobPlanAnalyzerOracleContractTests'
```

PASS: eight tests, zero failures. Five new tests cover the two compatible
spellings plus refusal of changed error codes, proof details, result values,
unknown diagnostic text/types, message text outside the exact error location,
changed durable bytes, formatting/trailing-newline differences, corrupt raw
provenance SHA, and changes to other provenance fields. The three original
oracles now pass against unchanged committed fixtures. `git diff --check` passes.
Full repository verification is recorded by the integrating ClientKit slice.
