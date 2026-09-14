# Rust Session publication for the crash-signature analyzer — macOS, 2026-09-14

TASK-XPA-014 remains in progress. Base: `f9281242`, the `job.result` slice (#1895, open), on
`d15aca87` (#1894), `24430fcb` (#1893) and `1733d375` (#1892), all open, on protected main
`7dabc3c3`. This slice publishes a Session for every terminal `analyzer.extract-crash-signature@1`
Job the isolated Rust development composition runs, as the standalone Swift daemon does. It removes
the one difference the `job.run` and `job.result` slices set aside. Nothing installed changes. Every
request, source and analyzer answer is synthetic host data; nothing here is device evidence.

## Already on main or in #1892–#1895 / this slice / still remaining

| Already on main or in #1892–#1895 | This slice | Still remaining for TASK-XPA-014 |
| --- | --- | --- |
| Rust reads the v1 Job index, records, events and Artifact routing and writes journals, the admission index and `job-record.json` (#1863, #1879, #1889, #1891); `job.plan` (#1892), `job.submit` (#1893), `job.run` (#1894) and `job.result`/`job.evidence` (#1895) for the analyzer | Session publication at the runner's terminal boundary: the claim, the Manifest composed from the Job's own facts, the proposal, the Journal's `finalized` record, the Session tree and Journal copy, the outcome audit, the write-once Manifest, the catalog registration and the ownership marker; a Swift-recorded publication oracle; the real-process harness comparing both owners' Sessions and handing the Rust-published ones to a Swift daemon | Execution of every other operation (device facts, Runtime capabilities, the executor hand-off); capability mint/reserve/consume; §G.4 preflight; recovery, `job.reconcile` and resumption (after the L.1 item 13 ruling), including the publication retry `job.reconcile` owns; cancellation of a running Job; GJ-1..5 |

## Behaviour

Swift composes `RuntimeSessionPublicationWriter` only in the standalone daemon, and its engine
publishes a terminal Job with a known outcome once, after the terminal record is durable
(`statusAndReleaseTerminalRuntime`). `JobRunner` now takes an optional `SessionPublisher`
(`arkdeck-hoststore/src/session_publication.rs`) and calls it at that boundary; `arkdeck-agentd`
composes one over the Session owner the isolated composition already holds, its claims and a statfs
probe. The writer follows Swift's `attempt`:

1. the storage status read first, waiting for the storage lock as Swift's does (the Rust status
   read, which initializes a missing catalog at generation 0), the Sessions root's device, inode and
   volume identity, and the Job's Session partition from its creation time
   (`yyyy/mm/session-<job>`);
2. a claim of `max(journal bytes, 1) + 64 KiB` metadata and 16 MiB finalization headroom on the
   Sessions volume, admitted as Swift's coordinator admits a light writer; a full or read-only volume
   leaves the marker in `awaitingStorage` (reported `pending`/`waitingForStorage`) and writes nothing;
3. the Manifest composed from the Job's record and Journal alone (Swift's host target, no toolchain,
   each typed step with the tuple its correlated outcome proves, compensations and bindings as
   recorded, no copied Artifacts, the failure block of a failed Job), canonical and checked against
   the locked Manifest reader; a Job whose facts cannot render it is refused and its claim released;
4. the checkpoint seal of the exact record and Journal it came from, then
   `session-manifest.proposal.json` beside the Job, then the Journal's `finalized` record naming the
   proposal's digest;
5. the Session created once — its root `mkdir`ed 0700 and refused if anything already holds it (Swift's
   `invalidRecord("Session already exists: …")`), `audit/`, `artifacts/{raw,derived,partial}`, the
   identity document created exclusively, every directory synchronized — then the Journal copied event
   by event and required to be byte-identical;
6. the outcome audit record, then `manifest.json` published write-once (`renameatx_np(RENAME_EXCL)`)
   under the Session's terminal lock and all sixteen Artifact publication shards, and read back;
7. the catalog entry registered under the storage lock and the catalog lock (retention deadline
   `completedAt + retentionDays`, generation advanced, entries sorted) and read back, then the
   receipt, and the claim released.

The Job record keeps Swift's ownership marker whatever happened, persisted at one more index
version: the receipt once the catalog holds the entry, `awaitingStorage` without a claim, or a
confirmed failure (`contractViolation`, `sourceIntegrityFailed` or `storageUnavailable`) with Swift's
detail. Every Job read reports the publication fact from it, as it already did for Swift-published
Jobs. A parked Job, whose outcome is unknown, publishes nothing. As in Swift, a restart never resumes
a publication, a claim lives only in the owner process, and nothing retries a publication; the retry
Swift allows through `job.reconcile` stays unported with recovery (L.1 item 13).

Deliberate differences from Swift:

- A publication error that Swift renders from an unnamed Foundation or POSIX error carries this
  Runtime's rendering (`writeFailed(path: …, errno: …)`). The one refusal the oracle pins, an existing
  Session path, is spelled as Swift spells it.
- A Job carrying a device observation or confirmed bindings is refused as a device Session; no Job
  this Runtime runs carries either.

Found on the way, not changed: Swift `RuntimeArtifactStore.totalBytesUsed()` caches the indexed total
in-process. After the oracle's `sourceRemoved` case deletes a published source payload, the Swift
daemon that ran the cases still answers `runtime.storage.status` from the cached total, while a
freshly started Swift daemon and the Rust owner refuse the census ("Runtime storage state is
unreadable", "Artifact inventory is unreadable"). The real-process harness puts that payload back
before its last phase reads the storage status.

## Shared oracle

`rust/tests/fixtures/job-publication-analyzer/` was recorded by Swift
`JobRunAnalyzerOracleContractTests.testSwiftPublishesTheSharedAnalyzerSessions` in record mode
(`ARKDECK_RUST_JOB_PUBLICATION_RECORD`, recorded at `/private/tmp/xpa014-job-publication-oracle-r1`),
under the analyzer oracles' fixed physical root and lock with the run oracle's clocks, quota, home and
timeout, through the standalone daemon's writer over a storage owner (`session-owner`) and Sessions
root (`Sessions`) of its own and a probe that can report the volume full. The same test then ran
again in compare mode in another process and matched every file: the fixture holds no fact of the
machine or run that recorded it.

| File | Content |
| --- | --- |
| `cases.json` | six Jobs run in order over one store with each one's submit request: a success and a failure published (catalog generations 1 and 2), a parked Job (no marker), a full volume (`awaitingStorage`), a Session path a directory already holds (`storageUnavailable` after the proposal and `finalized` record, the directory left in place), and a Job whose source disappears before it runs (published at generation 3) |
| `reads.json` | Swift's `job.status` and `job.show` of each Job: 12 reads |
| `store/index.json` | the Job index a reader observes, each record's digest taken over its machine-independent reading |
| `store/jobs/<jobID>/` | each Job's journal, record (volume, device, inode and claim generation as labels; a refused marker's blank values kept), lock and Manifest proposal |
| `sessions/`, `session-owner/` | every file of the Sessions root (the catalog and its sealed lock, each Session's identity, Journal, audit, Manifest, terminal lock and sixteen shard locks) and the storage owner's lock: 66 files |
| `tree.json` | the kind and mode of every entry below the Job directories, the Sessions root and the storage owner: 115 entries |
| `artifacts/` | the sources, the published products and every Artifact index |

The Sessions root's recorded path is `/tmp/arkdeck-job-plan-oracle/Sessions`: Swift canonicalizes the
configured root with `resolvingSymlinksInPath()`, which drops `/private`. The writer spells the path
the same way.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Rust publication | `cargo test -p arkdeck-hoststore --test job_publication` | 1 passed: the six runs, the 12 reads, the index rows, every Job file, Artifact and Session file, the catalog, the owner's lock and all 115 kinds and modes reproduced byte for byte, machine facts read as labels |
| Writer-less runs | `cargo test -p arkdeck-hoststore --test job_run` | 1 passed: the run oracle, recorded without a writer, still reproduced by the runner composed without one |
| Workspace | `cargo test -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd`, `-p arkdeck-contract -p arkdeck-cli -p arkdeck-control`; warnings-denied Clippy; `cargo fmt --check` | passed, among them a unit test that holds the storage lock and finds the publication's status read still waiting for it, then reading once it is released |
| Swift oracles | `run-swiftpm.sh test --filter JobRunAnalyzerOracleContractTests` | record run: 2 executed, 0 failures (the run oracle compared unchanged, the publication oracle recorded); compare run of the publication oracle in a new process: 1 executed, 0 failures |
| Real processes | `python3 rust/scripts/check-job-run.py --swift-bin-dir <run-swiftpm debug products>` | PASS, 120 checks. The standalone Swift daemon and the Rust owner, in turn over one state root, answer the 19 runs, every read and both CLIs' `job run`/`job result` identically, and leave the same index rows, Job files (proposals and `finalized` records included), Artifacts and Session trees with their modes, once each owner's clock, Manifest digests and seals, Sessions root path, inodes and claim generations are read as labels. Both publish the same 15 Sessions (the 13 terminal oracle Jobs and the two CLI Jobs; the parked Job publishes nothing) and advance the catalog to generation 15. A standalone Swift daemon given the Rust-run store reads all 14 Jobs and their results as the Rust owner answered them, keeps the parked one parked, lists and shows all 15 Rust-published Sessions, reports 15 Sessions and none unaccounted, and reads the 4 Rust-published products back. Summary of r3, on `8a6cadc9`'s binaries: `/private/tmp/xpa014-job-publication-harness-r3.json`, SHA-256 `13dde102759ba27dfdc12f5bc221559ad572311b636de352824e0c5f434f596c`. r2 found the same on the binaries before the storage-lock wait (`/private/tmp/xpa014-job-publication-harness-r2.json`, SHA-256 `45a9faf43cdc2a3f36b3ce1dfe803145ca658489a1ac82e60715adbef30946d9`); r1 passed every comparison and stopped at the storage status, for the removed payload above and a wrong key in the harness |
| Contract derivation | `generate-control-contract.py --derive-method-schemas` over the committed corpus of the eight Job methods and the oracle's frames pruned to the shapes the corpus lacked, then `generate-contract.py --write` and `--check` | the corpus gains two frames each of `job.run`, `job.status` and `job.show` with published, pending and failed publication facts; no schema needed widening, so every schema stayed as committed |

## Unified local gate

`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`,
with `ARKDECK_PYTHON` on the SDD venv and the planner started from a venv holding `PyYAML` and
`jsonschema`. Against merge base `7dabc3c3` the planner classified 281 changed files (the five commits
of this branch) and selected the common, design-system, Swift and Rust lanes (no App build).

- r1 on `b56ffe8f`, `/private/tmp/xpa014-session-publication-gate-20260914-r1.log`:
  - Common checks: planner and agent-PR workflow tests, SDD (0 errors, 0 warnings, 121 acceptance
    IDs), catalog generator tests and `--check`, design-system tests.
  - Swift full lane: `full-parallel` 2,654 tests exit 0 (both analyzer oracle tests of
    `JobRunAnalyzerOracleContractTests` among them), `full-process-identity-race` 1 test exit 0,
    `full-viewer-scale` 5 tests exit 0.
  - Rust lane: `generate-contract.py --check`, `cargo fmt --all --check`, warnings-denied Clippy,
    workspace tests, `test_contract_checks.py` (33 tests OK), `check-contracts.py` passing both views
    with every candidate process harness and `test-macos-facade.py` (7 tests OK), `cargo deny`
    (advisories, bans, licenses and sources ok) and `cargo vet` (36 fully audited).
  - Result: the log ends `gate exit=0`; SHA-256
    `c2db4b2138ecd5fb36961b1b6f019403b3c553e15946c32a7c0396c078b86eff`.
- After r1 the writer's first status read was changed to wait for the storage lock, as Swift's
  does, rather than refuse a request holding it (which would have left that Job with a refused
  marker). r2 on `8a6cadc9`, `/private/tmp/xpa014-session-publication-gate-20260914-r2.log`: the
  same 281 files, lanes and counts as r1 (`full-parallel` 2,654 tests exit 0, the Rust lane with both
  contract views, 33 contract-check tests, 7 façade tests, `cargo deny`, and `cargo vet` with 36 fully
  audited); the log ends `gate exit=0`; SHA-256
  `bc4f8e097a990aaa7accdee94de8c64eb4b71ef407b98743bcf856f913c14b43`.

## Not run, and why

- No publication retry, restart adoption of a partial Session, or reconciliation: Swift's only
  retry runs through `job.reconcile`, which waits with recovery for the L.1 item 13 ruling.
- No device Session and no Artifact copied into a Session: this Runtime runs no device Job, and Swift
  copies none.
- The oracle's full-volume case uses the probe's reported space; the harness's daemons measure the
  real volume, which had room.
- `check-job-run.py` needs the SwiftPM daemon and CLI products, so it runs by hand rather than inside
  `check-contracts.py` or CI.
- No device; DAYU200 is not attached to this host.
