# Job list filter producer oracle — 2026-09-11

The current Swift `RuntimeJobListQuery` accepts the `state`, `operation`,
`target` and `thread` filters, but the published `job.list` request schema
omitted them. This bounded supplement records the actual Swift control-plane
handler and adds those four string fields to that method alone. The five
existing request fields retain their base schemas unchanged. No Rust source,
pins, protocol identity, other method schema or production Swift code changes.

Base: `4a1124388ecd4502ed9625f6a839ff97d8efbaf6`.
Producer test:
`JobReadResourcesContractTests.testJobListFilterProducerFramesAndBoundedRefusals`.
The test uses the existing host-only ledger fixture and
`RuntimeJobRepository.admit` / `updateJobState`, then calls the actual
`RuntimeControlPlaneHandler.handleFrame`. It does not construct successful
response frames. Its dispatcher count remains zero. This is a Swift producer
contract oracle, not real-device acceptance or evidence of executed Jobs.

## Raw recording and typed corpus

The untouched recorder output is
[`control-frames-10835.jsonl`](job-list-producer-frames-macos-20260911/control-frames-10835.jsonl):
48 frames, 10 successful responses and 38 refusals. SHA-256:
`a226d3bf77812d65268ec5b1896ca98e434e3e103d2c4ad07ce33b6235fb9a90`.

The committed `Fixtures/ControlFrames/job.list.jsonl` contains all 17 base
corpus lines, byte-for-byte and in their original order, followed by 40 new
recorded frames: 57 total, with 20 successful responses and 37 refusals. No
shape-based sampling removes previous responses or error vocabulary.

Eight new raw frames pass integer or null values to the four filters. The
producer rejects each with `invalidInput`; these are not valid typed request
shapes. They remain in the unmodified raw evidence and in the test assertions,
but are excluded from schema inference and the typed corpus. The current
generator and schema tests infer/validate every frame's request parameters
without distinguishing successful requests from `invalidInput` refusals.
Including those eight frames would incorrectly widen each new string filter
to an integer/null/string union. Neither that generic tooling nor the five
existing parameter schemas is changed in this supplement.

The schema is derived from the typed corpus. Its request keys are exactly
`cursor`, `includeCurrent`, `includeTimeline`, `order`, `pageSize`, `state`,
`operation`, `target`, and `thread`. Each new filter is `type: string`, with no
sample-derived enum or const. All base error codes remain present.

## Actual behavior exercised

- Each filter selects actual fixture rows; operation, target and thread also
  exercise no-match empty pages. All four filters work together across a
  two-page snapshot, and changing any one invalidates the existing cursor.
- Empty, over-256-byte, control-character and wrong-type filters are refused;
  an unpublished state is refused. Order, page-size, boolean and cursor
  failure paths are also recorded, as is an unreadable ledger record.
- Thread provenance produces a string `threadId`. A client context without a
  workspace annotation produces null `workspaceKind`; both previously absent
  result alternatives now come from successful actual producer frames.
- A 270,000-byte fixture timeline produces the actual
  `{kind: snapshotPages, jobId, method: job.timeline}` list result. Existing
  inline and null timeline alternatives remain in the retained base corpus.

## Verification and reproduction

Results: the new producer test passed (1 test), the final schema suite passed
(4 tests, including all 57 typed input frames), and the existing immutable
snapshot/restart and filter-bound cursor regressions passed (2 tests).
`generate-control-contract.py --check` and `git diff --check` also passed.
No full repository gate or device acceptance was run for this isolated
contract-recording supplement.

The recording command was:

```sh
ARKDECK_CONTROL_FRAME_LOG=/private/tmp/xpa018-job-list-frames \
  swift test --package-path Packages/ArkDeckKit \
  --filter JobReadResourcesContractTests/testJobListFilterProducerFramesAndBoundedRefusals
```

To derive, concatenate the base corpus with the recorded lines except the
eight refusals whose `state`/`operation`/`target`/`thread` value is not a JSON
string. Feed that exact file to:

```sh
python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py \
  --derive-method-schemas /private/tmp/xpa018-job-list-derivation.jsonl
```

Replace only the generated `job.list` corpus with the entire same derivation
input, preserving all base lines and new typed frames rather than the
generator's shape selection. The raw recording remains unchanged. Validate
`ControlMethodSchemaContractTests` with `ARKDECK_CONTROL_FRAME_LOG` pointing
to a directory containing this typed input; raw wrong-type refusals are
validated by the producer test, not as accepted request shapes.

The initial sandboxed compiler invocation could not write its standard
module cache. The focused runs used the same local Swift toolchain with
permission to access that cache; no production checks were relaxed.
