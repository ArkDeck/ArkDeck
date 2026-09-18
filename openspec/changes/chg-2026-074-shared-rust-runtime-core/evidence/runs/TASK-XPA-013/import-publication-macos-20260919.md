# Rust Import commit and immutable publication — macOS

Initial base: protected `origin/main` `1ee1d73ddeffcae6cda7ca49bf57ff22bf89d3d7`.
Final validation includes merged protected main `98cb3b96`.
This is host implementation/test evidence, not device acceptance.

## Delivered behavior

- The daemon connects `artifact.import.commit` to the single durable Import owner and the shared Artifact retention/quota lock. It accepts only Import identity and generation; no publication descriptor, validation facts, local path, or capability arrives from the caller.
- HAP checks the published ZIP header rule. Native libraries use the existing Rust ELF/GNU build-ID/OH code-sign-block validator with the signature structure required. Workspace patches use the Swift safe-path, UTF-8, file-count and unsupported-patch-form rules.
- The retained source descriptor is size/digest/identity checked; fresh Target binding is rechecked before a first committing checkpoint. A retry resumes its persisted validation and exact publication only. It does not execute a device operation or rerun uncertain device work.
- Streaming exclusive publication preserves the exact source bytes, seals the destination, syncs it before index publication, and converges on the deterministic immutable Artifact identity after interruption. Incomplete temporary copies are reclaimed only within that same derived publication namespace; linked copies fail closed. Quota refusal leaves the Import discoverable.
- The committed receipt is durable before staging cleanup. Idempotent commit and inspect recover a receipt-after-checkpoint interruption. Receipt identity, digest, size, generation, binding, media/privacy, lease, and validation consistency are checked on reopen.
- Import-owned Artifact inspect/read/list/export require that receipt and matching immutable metadata while holding the Import lifetime lock. A published index without a completed receipt cannot supply content. Sensitive patch reads/exports retain explicit opt-in. Job handlers cannot masquerade as Import ownership.
- Import list matches current Swift `RuntimeArtifactStore.listImports`: closed target/state/pageSize/cursor options and immutable `createdAtDescImportIdAsc` snapshots. Original bytes and receipt can also be rediscovered by the existing request-ID inspect/begin paths.

## Verification

- `cargo check --manifest-path rust/Cargo.toml -p arkdeck-agentd`: pass.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd --all-targets -- -D warnings`: pass; repeated by the final unified gate.
- `import_upload`: 22 passing tests; `artifact_read_owner`: 26 passing tests; dedicated patch-validator boundary matrix: pass. These cover HAP/native/patch positive publication, unchanged exact bytes, sensitive opt-in, native valid ELF without required OH block refusal, partial/digest/binding/quota/format refusals, four commit durability windows, partial-copy recovery and linked-copy refusal, receipt/metadata poisoning, explicit export, restart, snapshot filtering/pagination, and existing Job Artifact behavior.
- Initial owner implementation unified gate: **PASS**, exit 0, 2026-09-19, before the later process test exposed incomplete recorded schemas and the missing CLI/Control list dispatch. The final expanded-slice gate remains pending. Command:

  ```sh
  ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python /private/tmp/arkdeck-validation-venv/bin/python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local
  ```

  Public checks, complete Rust workspace tests, published/candidate contract checks, cargo-deny (advisories/bans/licenses/sources), and cargo-vet (36 fully audited) passed. Local full log: `/private/tmp/arkdeck-import-gate.log`; contract recordings: `rust/target/readonly-check/87a6b378cb7d4cbda76995161492b0f5`.
- Expanded-slice verification passed the full Swift suite (2,685 parallel tests plus 1 serialized process-identity test and 5 viewer-scale tests) and Rust workspace tests. Two stale test assertions still classified the newly routed `artifact.import.list` as unimplemented; the owner-route test, read-only method set and its harness expectation now agree with the production route. Targeted reruns pass (16 control tests; 35 contract-harness tests). A complete final rerun remains pending.
- Earlier attempts encountered sandbox Unix-socket denial and a system Python missing jsonschema; final verification used authorized local test execution and the existing pinned validation environment (`jsonschema==4.26.0`, `PyYAML==6.0.3`). No check or fixture was weakened.
- Independent review confirmed existing-index retries validate immutable payloads through `load_index`; an additional deletion/corruption test proves failure leaves the Import committing, receipt absent, and original staging retained. Patch validator negative matrix covers absolute/backslash/.git/dot/empty paths, binary/rename/copy, NUL, invalid UTF-8, and the 128-file bound. No confirmed implementation defect remained in that review.

## Full host process path and recorded schema coverage

The actual `arkdeck` binary now runs against the independently launched `arkdeck-agentd` with an isolated development root and a copied, explicit fixture Target. No HDC tool, Swift façade, installed state, capability, or physical device is configured. `real_cli_daemon_three_kinds_restart_and_lost_commit_reply` passes: all three kinds upload and commit; daemon process restart preserves exact readback; patch read requires explicit opt-in; a proxy discards the real daemon commit reply and observes the CLI recover through request-ID inspect without replaying commit; another restart preserves the same receipt and the CLI lists all four Imports. The closed Rust `artifact import list` leaf and response checks have 10 passing Import CLI tests in total.

That process test exposed previously unrecorded existing Swift shapes: nullable patch binding in Artifact list, native/patch validation in committed Import inspect/inspection/list, and Import list pagination/options. They are sampled from a real Swift daemon through the new `DurableImportContractTests` producer, then merged with existing frames by the existing generator. `import-publication-native-recording/provenance.json` identifies the exact SDK-compatible producer commit, added-test diff/hash, actual frames/hash and command; the producer used original PR #1976 commit `b710252d`, subsequently merged into protected main as `ad0ef755`. Its SDK compatibility dependency is now satisfied. This branch merged protected main `98cb3b96` before final validation; these isolated host fixtures are not real-device acceptance. No frame, binding revision, or validator facts are fabricated.

## Remaining boundaries

Import lease consumption, materialization/Job-reference inspection (`artifact.import.inspection`), serialized release/unpin, and deployed HAP/native-library workflows are separate pending work. Import leases still fail closed in the planner; no incomplete receipt can become an input. Flash-bundle commit is unavailable until its registered bundle validator/policy is integrated. HAP ZIP-header validation and native OH signature-block structural validation do not attest certificate validity, signer trust, or device-install acceptance. This slice neither changes device authority nor claims real-device GJ evidence, signing-tool execution, App installation cutover, or Swift retirement.
