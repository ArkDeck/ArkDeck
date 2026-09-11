# Job timeline continuation producer oracle — 2026-09-11

The existing `job.timeline` schema already describes every current request
and result field, including `cursor`, `partIndex`, `lastPart` and a non-null
`nextCursor`. Its selected corpus, however, contained only one successful
single-page response. This supplement records the existing continuation and
long-entry branches from the actual Swift producer rather than changing their
implementation or inventing successful responses.

`JobReadResourcesContractTests.testTimelineProducerFramesPreserveSegmentsAndBoundCursors`
uses the existing local ledger fixture, `RuntimeJobRepository.admit` and
`updateJobState`, the real `RuntimeControlPlaneHandler` /
`RuntimeJobResourceReader`, and one invocation of the actual Swift CLI through
the fixture daemon socket. No operation is submitted or run, and the test
asserts a dispatcher count of zero. These host-only fixture reads are not
hardware acceptance or provider coverage evidence.

## Raw and committed corpus

The unchanged recorder output is
[`control-frames-44344.jsonl`](job-timeline-producer-frames-macos-20260911/control-frames-44344.jsonl).
Its SHA-256 is
`6309ad689f8dcc6aeca642e361e524c6b18326a3a99b83d78292a7e693073b5f`.
It contains 17 actual frames: 16 `job.timeline` frames and the CLI's one
preliminary `health` request. The health frame stays in raw evidence only;
the published health corpus is not changed by this supplement.

The timeline frames comprise six successes and ten refusals. All 16 are
appended verbatim to the two existing timeline corpus lines, which remain
byte-for-byte unchanged and in their original order. No shape compression
discards continuation rows or error vocabulary. In particular, a full
65,536-byte text segment plus its envelope exceeds the generator's 65,536-byte
sample-selection limit but remains a valid actual wire frame; it is retained
whole so consumers exercise the producer's real segment bound.

## Branches exercised

- A 120,000-byte string containing combining marks, CJK and emoji is split
  on Unicode scalar boundaries into 65,536-byte and 54,464-byte parts. With
  `pageSize: 1`, the complete timeline occupies four pages: two parts of the
  long entry, an empty entry, and a final short entry. Byte-for-byte
  reconstruction, stable snapshot revision, continuation tokens, part order
  and last-part flags are asserted.
- Updating the underlying durable timeline after page one does not rewrite
  the captured snapshot. The real Swift CLI subsequently starts on the old
  snapshot's second page, whose first row has `partIndex: "1"`, and succeeds.
- A Job with no timeline entries produces an actual empty page.
- Five actual `invalidCursor` responses cover a different Job, changed page
  size, a cursor from `job.list`, an empty cursor and a malformed cursor.
  Other actual refusals cover invalid page sizes and Job identity, a missing
  Job, and an unreadable retained Job while continuing its old snapshot.

## Schema boundary and validation

The only schema edit appends the actually recorded `invalidCursor` error code.
Removing that one enum member makes the entire JSON schema equal to its
pre-supplement version. Request/result/error-detail definitions, required
fields, the existing error vocabulary, protocol identity and metadata are
unchanged. No rejected request type is promoted into the typed request
schema. No Rust, pins, tasks, other schema or main evidence file is changed
by this supplement.

After the integrating task released the shared SwiftPM cache, recording used:

```sh
ARKDECK_CONTROL_FRAME_LOG=/private/tmp/xpa018-timeline-producer-frames \
  sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test \
  --filter JobReadResourcesContractTests/testTimelineProducerFramesPreserveSegmentsAndBoundCursors
```

The producer test passed (1 test, 0 failures). Schema verification uses the
same wrapper and recording directory with
`--filter ControlMethodSchemaContractTests` and passed all 4 tests, including
the complete recorded frames. `generate-control-contract.py --check` and
`git diff --check` also passed. The full repository gate and
Rust CLI integration are owned by the integrating task; no device run is
claimed here.
