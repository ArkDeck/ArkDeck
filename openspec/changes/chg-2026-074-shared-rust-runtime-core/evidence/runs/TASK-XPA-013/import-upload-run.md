# Import upload owner — macOS, 2026-09-12

Historical validation record for the upload checkpoint before Target integration. Current PR base, scope and validation are recorded in `import-upload-current-main.md`; this old run is retained as evidence, not relabeled as a current-head pass.

TASK-XPA-013 remains in progress. This bounded slice preserves the interrupted
Import implementation as checkpoint `4bb8c79b`. It was first rebased to Artifact
export candidate `4d1c1cf9`, then the two Import-only commits were rebased to the
latest export candidate `cfbb2598` as `07521366` and `bded46c5`. The actual
protected-main base for this candidate is `0dad7599`; none of the pending export
or Import commits are treated as a published Runtime owner.

## Behavior and limits

The Rust upload owner implements existing begin/append/abort/inspect semantics on
the unchanged `arkdeck.runtime-import/1` records, identity map and private staging.
New begin requires an actual owner-resolved Target binding. The current daemon
returns `operationUnavailable` for new requests because that owner seam is not
composed. Existing Swift uploads can be rediscovered, resumed and aborted.

A stable owner lock, retained directory/file descriptors, closed record decoding,
exact request fingerprints, prior-byte checkpoint comparison, full file sync,
atomic checkpoint publication and directory sync protect upload lifetime changes.
After restart, only the durable chunk prefix is accepted; a partial or fully
synced but uncheckpointed suffix is truncated. Abort first persists its tombstone
and generation, then removes staging. It cannot resurrect the request.

Limits remain 2 MiB per chunk, 16,384 chunk records, 4 MiB per record, 4,096 Import
records and 8 GiB of declared active staging capacity. Capacity is a soft quota,
not allocated disk space; quota refusal never evicts another upload. Raw Artifact
payloads are never modified. App provenance is not inherited from local CLI
connections and cannot be injected through request fields.

The CLI keeps the existing typed import leaves. `artifact import inspect` invokes
`artifact.import.inspection`, the Job-reference inspection semantic, rather than
ordinary `artifact.inspect` or upload progress inspection. Upload recovery uses
`artifact.import.inspect` only internally with the same request identity. Lost
begin/append replies are reconciled against the durable prefix with at most two
append recoveries. Unknown commit replies are inspected once and never replayed;
if publication remains unconfirmed, the original unknown error is returned.
This conservative limit is explicit while the publication owner is unavailable.

Commit, release and Job-reference inspection return `operationUnavailable` without
altering the upload. No publication, Artifact lease, reference classification,
capability, device operation, installed-owner cutover or GJ acceptance is claimed.
The exact Target integration API and kind-specific binding requirements are in
`import-upload-target-integration.md`.

## Native producer provenance

The two `DurableImportContractTests.testRustImportUpload*` producer additions were
run previously in the native Swift validation worktree. Their source-created
upload/abort records and payload prefix are copied byte-for-byte into
`rust/tests/fixtures/import-upload-current`; the fixture manifest retains their
SHA-256 values. The raw source is
`/private/tmp/xpa-native-frames-20260912-r1/control-frames-1700.jsonl`.
`native-import-producer-macos-20260912/` records its hash, the producer log hash,
the original union source manifest and the six method frame supplements.

This continuation independently matched every copied fixture hash, raw frame hash,
union manifest hash and the actual Import producer test source hash. It did not
rerun Swift or infer a new Swift pass from those hashes. The six schemas retain
the published corpus and add actual native success/error shapes. The checkout
manifest was regenerated with `python3 rust/scripts/generate-contract.py --write`
(v2 checkout mode, no baseline revision); `--check` reports 105 methods and
597 recorded shapes. All 46 retained/native frames across the six Import schemas
also passed independent JSON Schema validation.

## Validation and outstanding checks

The final post-review targeted run on the `cfbb2598` export candidate passed:

- 13 Import owner tests, including current Swift durable-fixture parity and five
  actual SIGKILL windows: after begin checkpoint, partial chunk, chunk sync, append
  checkpoint and abort checkpoint. The one ignored helper is invoked by the parent
  test in each window, and signal 9 is explicitly asserted before owner reopening.
- 5 strict Import contract tests, 8 CLI tests (including 41 byte-identical current
  native argv cases, bounded lost-reply rediscovery and unknown-commit no replay),
  and all 15 control routing/refusal tests.
- `cargo clippy --offline --locked --workspace --all-targets -- -D warnings`,
  `cargo build --offline --locked --workspace --bins`, formatting check and the
  checkout generator check.
- The actual `rust/scripts/check-import-upload-owner.py` daemon/CLI process test.
  It restores private filesystem modes around byte-identical Swift snapshots,
  confirms initial read/begin parity without record rewrites and refuses a new
  request while Target resolution is absent. Its proxy drops exactly one real
  successful append reply after publication and asserts the sequence
  `inspect → append → inspect → commit` with the same request/Import identities.
  Only one append is sent; the committed prefix reaches 4,096 bytes. The pending
  commit owner refuses. Restart reads the same prefix, source modification refuses,
  and abort persists an irreversible generation-2 tombstone before staging removal.
  Commit/release/reference inspection leave records and payloads unchanged.

The full command output is retained as `import-upload-rust-targeted.log`, copied
from `/private/tmp/xpa013-import-main-targeted-r2.log`; SHA-256 is
`363c892aa1a38f47c7981c423a77f50d5031e1b8fb645158adbb1e1901b5f941`.
Only documentation changed after this test batch.

Swift, App, performance checks and the final unified repository gate are reserved
for the parent task's serialized validation. No push, PR or merge is performed by
this slice. These are local host fixtures, never real-device evidence.

## Scope against the actual base

Against protected-main `0dad7599`, the combined export-plus-Import candidate needs
exact declarations for `spec/control/methods/artifact.export.json`, the six
`spec/control/methods/artifact.import.{begin,append,abort,inspect,inspection,release}.json`
paths, and `spec/baselines/swift-single-v1.json`: eight bounded paths total.
Against export candidate `cfbb2598`, only the six Import schema declarations are
new. These declarations do not establish maintainer approval; the final parent
integration must recompute them against its actual base. Other changed Rust,
Swift test/fixture and change-evidence paths were already in TASK-XPA-013 scope.
