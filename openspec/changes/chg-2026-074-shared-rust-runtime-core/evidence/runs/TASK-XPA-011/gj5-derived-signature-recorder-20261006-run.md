# GJ-5 derived crash-signature recorder

A successful `analyzer.extract-crash-signature@1` Job publishes its answer in
`crash-signature.json.result`, beside the source and analyzer-output provenance.
The recorder previously read top-level `status`, so a genuine wrapped
`result.status=answered` failed the existing answered criterion. Its synthetic
positive fixture concealed this by inventing a flat Artifact.

The GJ-5 consumer now reads the published wrapper, verifies schema/analyzer
identity, decoded entry types and output provenance shape, and binds its source
Artifact ID, SHA-256 and integer byte count to the whole repro crash-index
Artifact already verified by the recorder. The status must still be `answered`.
Output SHA/count are declared analyzer receipt facts, not recomputed from a
re-encoding of the decoded result. Rust's producer normalizes that result, so
such re-encoding would not necessarily reproduce the original analyzer stdout.
The existing execution IDs, negative refusal, complete adjacent Job ledgers and
whole-Artifact predicates are unchanged. No Catalog or Runtime behavior changes.

The positive fixture uses the actual Rust producer's derived-envelope shape.
Negative fixtures cover absent/invalid/flat wrappers, wrong schema and decoded
entry types, `unreadable`, another source Artifact, changed source digest and
boolean byte count. Synthetic tests are not hardware evidence. The quarantined
historical journal remains unusable for assembly and is not read or repaired.

## Local targeted checks

From `scripts`, a `unittest.TestLoader` suite selects only the `gj5` methods in
`gj_record.test_gj_record.LaterJourneyTests`: 11 passed, exit 0, 13.823 seconds.
Log: `tools/logs/gj5-derived-signature-targeted-20261006.log` in the external
local tools directory. The subsequently added flat-wrapper refusal is checked
separately with
`python -m unittest gj_record.test_gj_record.LaterJourneyTests.test_gj5_rejects_an_invented_flat_signature_artifact -v`.
The flat-wrapper check passed, exit 0, 1.474 seconds; log:
`tools/logs/gj5-derived-signature-flat-20261006.log`. Combined, all 12 affected
GJ5 checks passed.

`sh scripts/check-sdd.sh`, using the already installed Git Bash and a child-only
explicit Python selection: exit 0, 0 errors, 0 warnings, 121 acceptance IDs;
log `tools/logs/gj5-derived-signature-sdd-20261006-2.log`. The first launch was
unavailable because `sh` was absent from PATH; no dependencies or trust settings
were changed. `git diff --check`: exit 0.

No Cargo, Swift, SDK, Runtime, transport or real-device invocation is needed for
this Python consumer change.

## CI

Not run yet. This unpublished increment awaits the frozen Native parent before
commit/publication so the stack stays linear. CI does not constitute hardware
acceptance or turn the existing independent nine-check summary into formal PASS.
