# One refusal that covered nine reads, narrowed to the eight it belongs to — 2026-09-08

- Task: TASK-SVC-002
- Base: protected `main` `2ae759f3` (#1787).
- Design: [session-publication-scope-review.md](session-publication-scope-review.md),
  section **"Exact export with visible global incomplete content"** — the
  reviewed and merged specification for exactly this work.
- Preceding record: [session-publication-run-2026-09-08.md](session-publication-run-2026-09-08.md),
  which delivered the producer and listed export `source`/`catalogStatus` as
  item 5 of what it explicitly did not deliver. This is that item.

## The measured state this starts from

The producer works. A real host-only Job published a real Session, and both
`job status` and `agent status` report `sessionPublication` `published` with a
`manifestSha256` that matches the bytes on disk. Every read still refused:

```
$ session show           --session session-job-71f00ada…  → exit 69
$ session export preview --session session-job-71f00ada…  → exit 69
operationUnavailable / phase sessionOwner / newDispatchCount 0
"Session catalog contains unaccounted content:
 2026/08/rockchip-session-42f8e86d-8cbf-4aa0-a411-5e1624e9f291 (unreadable)"
```

One directory from 2026-08 has no manifest, so `RuntimeSessionStorageStore`'s
single blanket guard — `sessionRows`, which refuses whenever
`snapshot.unknownPressure` or `snapshot.unknownSessionIDs` is non-empty —
refused all nine call sites that go through it.

## What changed

**Exactly two of those nine.** `session export preview` and
`session export apply` now answer for one exact, known, complete, registered
Session and disclose the global state, instead of refusing because unrelated
content elsewhere under the root is unaccounted.

`session list`, `session show`, `session pin`, `session unpin`,
`session cleanup preview` and `session cleanup apply` still call `sessionRows`
and still refuse with the message they already produced, naming each leaf and
its reason. Each of them answers *about the whole root*, so a partial answer
would be a lie; an export names one Session, so it can publish that Session and
say what it is not accounting for.

### The two new required closed objects

`source` and `catalogStatus` are on both the preview and the result:

| `source` | |
| --- | --- |
| `jobId` | the Job the Session came from |
| `manifestSha256` | digest of the canonical Manifest bytes, re-read under the same lock and re-proved to decode canonically with a matching session/job identity |
| `journalSha256` | digest of `journal.jsonl`, or explicit `null` when there is none |
| `rootDevice`, `rootInode`, `volumeIdentity` | filesystem identity of the Sessions root the scan measured |
| `sessionDevice`, `sessionInode` | filesystem identity of this leaf, proved to be an owner-held directory on the root's device |

| `catalogStatus` | |
| --- | --- |
| `complete` | whether the scan accounted for everything under the root |
| `unaccountedSessionCount` | canonical decimal string |
| `measurementIncomplete` | the exact complement of `complete` |
| `usedBytes` | measured **known** content — the sum over the registered, measured Sessions, never the scan's total, which folds in the bytes it measured for unknown leaves |
| `blocker` | `null`, or `"unaccountedSessionContent"` |

Exactly two tuples succeed, and the strict CLI enforces exactly those two:
`complete=true / count=0 / measurementIncomplete=false / blocker=null`, or
`complete=false / count>=1 / measurementIncomplete=true /
blocker="unaccountedSessionContent"`.

### What still refuses, and why

Disclosure is only honest when the scan mechanically located every unknown byte
in a named leaf that is not the selected Session. So the export path admits
three unaccounted reasons — `notRegistered`, `unreadable`, `invalidIdentifier`,
each of which names a leaf at `yyyy/mm/<name>` — and refuses on:

- `outsideSessionLayout` — content the scan could not place in the layout at all;
- `catalogMetadataCorrupt` — nothing under the root can be attributed, and the
  catalog generation is `nil` anyway;
- `duplicateIdentity` — an identity under this root resolves to two directories;
- `unknownPressure` with no named leaf — the measurement itself is incomplete
  and cannot say where;
- an unaccounted reference that names the selected Session, in either spelling
  the scan uses (bare identifier, or `yyyy/mm/<id>`);
- a root or volume identity that `SessionRetentionCatalog.requireCurrentRoot`
  cannot confirm against the snapshot the export was measured from;
- an incomplete or unregistered selected Session — the export path now proves,
  for the one Session it is about to publish, exactly what `sessionRows` proved
  for all of them: one measured entry, one catalog row, agreeing completion,
  expiry and pin state.

All of those answer `operationUnavailable` or `resourceNotFound` with no
preview record and no output.

`journalSha256` is three-state on purpose: a Journal that is definitively
absent is `null`, a Journal that exists but is not an owner-held readable
regular file refuses. An optional that carried both "no Journal" and "could not
read the Journal" would be the same defect this repository has hit before.

`previewDigest` is still SHA-256 over the JCS encoding of the whole preview
minus only `previewDigest`, and now covers both new objects — the new suite
asserts that removing either one changes it. `apply` recomputes the entire
projection under the catalog lock and compares it to the durable preview, so
drift in any source or catalog fact is `resourceConflict` before any output.
The result carries the same two objects the applied preview carried.

## What was not touched

The historical manifest-less directory is not adopted, repaired, registered,
moved or rewritten, and no manifest is invented for it. Exporting *it* is still
refused. Two existing assertions that hold this line —
`SessionResourceContractTests.testUnaccountedContentCannotBeHiddenByAPartialSessionList`
and `…testUnaccountedContentIsNamedWithItsReasonInsteadOfACount` — are unchanged
and still pass.

`spec/baselines/**` and `rust/**` are outside this Task's Allowed paths and are
untouched; the corpus pin realignment after merge remains TASK-XPA-002's, exactly
as the preceding record's handoff says.

## Verification

All commands from the worktree root. `uptime` was read before each run on this
8-core machine: the targeted suites ran at one-minute loads of 2.4–5.5, the
unified planner started at 7.4. No failure below was believed without being
re-run on its own.

| Command | Result |
| --- | --- |
| `swift build --package-path Packages/ArkDeckKit` | exit 0 |
| `swift test … --filter 'SessionExportContractTests\|SessionResourceContractTests\|SessionCleanupContractTests\|RuntimeSessionPublicationContractTests\|RuntimeStorageResourceContractTests'` | **exit 0**, 32 tests, 0 failures |
| `swift test … --filter 'ControlMethodSchemaContractTests\|ControlMethodReachabilityContractTests\|CLIMachineContractTests'` | 28 tests, 1 skipped, 0 failures |
| `python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --check` | exit 0 |
| `ARKDECK_CONTROL_FRAME_LOG=<dir> swift test … --filter 'SessionResourceContractTests\|SessionCleanupContractTests\|JobReadResourcesContractTests'` then `--filter ControlMethodSchemaContractTests` over that directory | 35 tests then 4 tests, 0 failures — `testFramesRecordedByThisRunValidate` validates the frames this change produces against the newly derived schemas |
| `plan.py … --merge-base --include-worktree --run-local` | exit 1 on one pre-existing rust step; every other lane green — see below |
| `rust/scripts/check-contracts.py` (published **and** candidate views) | exit 0 |
| `python3 scripts/check_pr_paths.py --repo-root . --preflight --base-revision origin/main --head-revision HEAD` | exit 0, `TASK-SVC-002` |

### The reference host, reproduced

`RuntimeSessionPublicationContractTests.testAnExactExportSucceedsWhileTheHistoricalUnknownIsDisclosedAndStillRefused`
builds the measured state exactly: the production Engine runs one real host-only
Job through the real writer and the configured owner, publishing a Session under
`2026/07/`, while a 2026-08 directory with an identity file and a Journal but no
manifest sits beside it. It asserts

- `session list` and `session show` still refuse `operationUnavailable`, still
  naming `2026/08/session-historical`;
- the exact export previews and applies, with `blocker`
  `unaccountedSessionContent`, `complete` false, `unaccountedSessionCount` `1`,
  and `usedBytes` strictly below the scan's total — the property that makes it
  known content rather than a total;
- `source.jobId` and `source.manifestSha256` equal the Job's own published
  receipt, and `source.journalSha256` equals the digest of the Session's Journal;
- `previewDigest` covers both new objects;
- exporting `session-historical` itself is refused;
- the historical files are byte- and timestamp-identical afterwards and still
  have no manifest, and the owner still reports `unaccountedSessionCount: 1`.

`SessionResourceContractTests.testRealCLIProcessExportsAnExactSessionWhileGlobalListStaysRefused`
proves the same thing through a real `arkdeck` subprocess and the strict client:
`session list` exits 69 naming the leaf, `session export preview`/`apply` exit 0
with the disclosed objects accepted by the strict validator, and previewing the
stranded leaf exits 69.

`SessionExportContractTests.testUnplaceableAndAmbiguousContentStillRefuseAnExactExport`
covers the two refusals the review names that are not the reference host's
shape: content outside the layout, and one identity under two months. Removing
the unplaceable content restores the export, so the refusal is the content's
property and not a latch.

### Schemas and corpus

`session.export.preview` and `session.export.apply` are the two changed method
shapes. Both were re-derived from frames a real contract-test run recorded over
the whole `ArkDeckContractTests` target (1 377 frames):

```
ARKDECK_CONTROL_FRAME_LOG=<dir> swift test --package-path Packages/ArkDeckKit --filter ArkDeckContractTests
python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --derive-method-schemas <dir>
```

Every other method's schema and corpus was restored: their only diff was
`x-arkdeck-sampleCounts`, which this recording moved but no shape did. The two
derived schemas publish both new objects with every member required,
`blocker` and `journalSha256` as `["null","string"]`. The committed corpus
carries four shapes per method — complete and incomplete, Journal present and
absent — plus the refusals, so a future recording that only ever exercises one
branch cannot silently narrow the published contract.

The strict CLI reader (`CLISessionResources`) closes both objects with the same
rules the Runtime writes them under. The App does not read the export shape;
`RuntimeHistoryApplicationFacade` and the daemon handler pass the result through
unchanged, and no other consumer decodes it.

### The unified local planner

```
python3 scripts/ci/plan.py --repo-root . --base-revision origin/main \
  --head-revision HEAD --merge-base --include-worktree --run-local
```

selected the common, swift, app, design-system and rust lanes from the eleven
changed files, and exited non-zero on one pre-existing rust step.

- **Common**: `scripts/ci/test_plan.py` 31 tests OK, `scripts/test_agent_pr_workflow.py`
  11 tests OK, `check-sdd.sh` `0 error(s), 0 warning(s), 121 acceptance IDs`,
  `catalog_gen` 49 tests OK and `catalog_gen/generate.py --check` clean.
- **Swift**, `run-test-lane.sh full`: `full-parallel exitCode=0; testCount=2506;
  durationSeconds=88`, `full-process-identity-race exitCode=0; testCount=1`,
  `full-viewer-scale exitCode=0; testCount=5`.
- **App**, `run-xcodebuild.sh`: `** TEST BUILD SUCCEEDED **`.
- **Design system**: `npm --prefix docs/design/arkdeck-ds test` — 83 tests, 0 fail.
- **Rust**: `generate-contract.py --check`, `cargo fmt --all --check`,
  `cargo fetch --locked` and `cargo clippy --workspace --all-targets -- -D warnings`
  all passed. `rust/scripts/workspace-tests.py` then failed, and the planner
  stops on first failure, so the lane's remaining members did not run in that
  invocation.

The log is local at
`…/scratchpad/unified-gate.log`.

### The rust failure is `origin/main`'s, not this branch's

`workspace-tests.py` compares the digests pinned in
`spec/baselines/swift-single-v1.json` (pinned at `50dd15e9`) against the
content of `origin/main` — a comparison that does not involve this branch's
working tree at all. It reports 20 stale files:

```
$ python3 - <<'PY'   # digest each pinned path as it exists in origin/main
…
files stale against origin/main (independent of this branch): 20
overlap with files this branch changed: []
PY
```

They are the ten methods #1787 changed, corpus and schema. Zero of them is a
file this branch touches. `spec/baselines/**` and `rust/**` are outside
TASK-SVC-002's Allowed paths and the pin is not written from a branch, so this
change touches neither; re-pinning after merge is the handoff the preceding
record already filed with TASK-XPA-002.

The substance was verified instead through the sanctioned candidate view:

```
$ /private/tmp/arkdeck-gate-venv/bin/python rust/scripts/check-contracts.py
…
Published and candidate contract checks passed
CHECK_CONTRACTS_EXIT=0
```

The **candidate** view is this branch's schemas and corpus. It passed
`cargo clippy --workspace --all-targets --locked -- -D warnings`,
`cargo test --workspace --locked` — including every `corpus_parity` test and
`current_schema_closure_rejects_unpublished_fields_in_every_method` —
`cargo build --workspace --bins --locked`, and `check-readonly.py`
(`"result": "PASS"`, 111 control responses, `inputKind: candidate`). So the
Rust reader generated from the two re-derived schemas replays the re-derived
corpus. (The previous record's `check-readonly.py`/`jsonschema` environment gap
is closed by the prepared venv; this run needed no other change.)

### One pre-existing ad-hoc failure

`AgentDaemonContractTests.testHilogAnalyzerRunsMultipleJobsInOneDaemonSession`
fails with `analyzer.toolIdentityDrift` under a plain `swift test --filter` in
this worktree — the whole-target ad-hoc recording run above reports it as its
one unexpected failure — and passes in the planner's own
`run-test-lane.sh full` group of 2 506 tests in the same worktree, minutes
apart. That is the same invocation-scoped failure the preceding run recorded,
with the same cause (the ad-hoc products directory), and it is unrelated to
this change: nothing here touches the analyzer, the dispatcher or tool
identity.

## What of the reviewed spec is not here

1. **Cached applied receipts from before this change.** The review says old
   missing-field receipts are not backfilled or reapplied, and they are not: a
   stored `applied` record is returned verbatim, so a receipt minted by an
   older daemon comes back without the two objects and the strict client
   refuses it with `recordUnreadable` rather than accepting a shape no current
   producer can emit. Nothing republishes and nothing is rewritten. The window
   is bounded — a preview record expires in ten minutes and the store's own
   retention removes expired non-applying records — and a new preview gets the
   new shape. Writing a migration for one would be exactly the backfill the
   review forbids, so there is none.
2. **`RetentionAndExport`'s Manifest scrubber over authority/epoch fields.**
   The review's last paragraph of this section covers "the new authority/epoch
   fields in this slice" — those fields do not exist yet (item 1 of the
   preceding record), so there is nothing for the scrubber to cover.
3. Items 1–4 and 6–9 of the preceding record's "What is not delivered" list are
   still not delivered; this change is item 5 only.

## SVC acceptance

**SVC-AC-05**'s exact-export half is now met on a host contract fixture for a
root that is not fully accounted for — which is the state the reference host is
actually in. It is still not a `REAL_DEVICE_PASS`: no hardware was involved, and
the reference host's own Sessions root has not been re-measured with a daemon
built from this branch. **SVC-AC-10**'s Session half stays partial for the
reasons the preceding record gives.
