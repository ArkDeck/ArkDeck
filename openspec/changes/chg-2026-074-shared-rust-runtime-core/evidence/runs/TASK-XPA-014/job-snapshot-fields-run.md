# Current Job snapshot field reader — 2026-09-12

Task: TASK-XPA-014. Current base: protected main `4e2a615e`.

Current Swift Jobs can carry private evidence, Trace, recovery and Session publication fields. The earlier Rust reader refused these entire snapshots and reported every supported Job as having no publication marker. This change preserves the current closed nested field shapes and historical admission correlation while projecting the producer's actual Session publication fact. Receipt precedes failure; an invalid receipt or uncertain failure stays outcomeUnknown. Private root paths and stored action arguments do not escape the public Job response.

These are read-only historical records. The reader does not create or consume a capability, establish fresh facts, reconstruct a provider action, replay a Job, write a journal or activate the installed Runtime. The existing format/version and source bytes stay unchanged. Complete executable authority validation and owner cutover remain pending; this slice does not complete TASK-XPA-014.

## Verification

- Nine Rust Job owner tests pass after rebase. They cover nested unknown-field refusal, original request/capability correlation tampering, private-field round trip and non-disclosure, publication receipt precedence, UInt64 generation bounds, refusal without SQLite rewrites and current paging/restart behavior.
- `RuntimeDeviceSessionPublicationContractTests/testRustJobPublicationSnapshotsCurrentFixture` passed. It runs the existing actual Swift Job and Session owners with the suite's simulated provider and obtains published and confirmed-failure snapshots. The unchanged raw bytes and native public projections are retained under `rust/tests/fixtures/job-publication-current/`, with source-file SHA-256 in `provenance.json`.
- The two native cases include actual admission evidence, preflight/observation and Session publication markers. They are synthetic host tests, not device evidence. Other historical nested shapes are covered by strict source-model comparison and targeted refusal tests; no fresh recovery or execution proof is claimed.
- The actual Rust daemon and CLI consumed each original Swift SQLite family copied into a private disposable root: two RPC samples and four CLI processes per case, actual restart, second-owner refusal and unchanged database bytes. Both passed.
- Targeted warnings-denied Rust Clippy passed. The public query harness now derives Job IDs from producer responses so runtime-minted IDs can be checked without synthetic replacements.

Logs: `/private/tmp/xpa014-job-publication-native-r1.log`, `/private/tmp/xpa014-job-records-native-owner-r1.log`, `/private/tmp/xpa014-job-records-process-published-r1.log`, `/private/tmp/xpa014-job-records-process-failed-r1.log`, `/private/tmp/xpa014-job-records-clippy-r1.log`.

The complete local unified repository gate passed with exit 0 on the final combined candidate based on `4e2a615e` (`/private/tmp/xpa014-job-records-unified-r2.log`), including selected Swift, design-system and Rust lanes, published/candidate contract checks, dependency deny and vet. App build was not selected. The earlier gate on base `1fd85b93` also passed (`/private/tmp/xpa014-job-records-unified-r1.log`). The current candidate retains published Artifact export and the updated CI configuration; native producer sources and fixtures are unchanged. Final commit scope preflight runs before push. No Swift production or contract schema change belongs to this read-only compatibility repair.

Before push, the candidate also integrates main `d71ab48f` (#1878). That upstream delta changes only `rust/README.md`, `rust/scripts/check-contracts.py` and `rust/scripts/test_contract_checks.py`; product sources, schemas and fixtures are byte-identical to the full-gate-tested candidate above. The updated contract harness passed all 32 regression tests, and contract generation check passed (`/private/tmp/xpa-job-contract-harness-d71.log`). The complete product gate is retained from base `4e2a615e`; it was not redundantly rebuilt for this script-only integration.
