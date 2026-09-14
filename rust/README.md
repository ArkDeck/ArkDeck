# Rust runtime development

TASK-XPA-002 supplies a separate development daemon and the `doctor`,
`operation list` and `device candidates` CLI leaves. It consumes the Swift
contract of this checkout, described by the committed manifest
[`spec/baselines/swift-single-v1.json`](../spec/baselines/swift-single-v1.json)
and the generated bindings, both regenerated from the working tree. The
manifest is a development baseline. SVC release acceptance, Windows platform
acceptance and production Runtime migration remain separate requirements.

## Build and check

From `rust/`, rustup selects the committed toolchain, the `stable` channel in
`rust-toolchain.toml`:

```sh
cargo fmt --all --check
cargo fetch --locked
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
python scripts/generate-contract.py --check
python scripts/test_contract_checks.py
python scripts/check-contracts.py
```

Clippy and the workspace tests are the only checks that compile this checkout.
`generate-contract.py --check` regenerates the manifest and bindings from the
checkout and requires no difference; `check-contracts.py` builds its own
source views. A workspace that does not build, or whose tests fail, passes
those two.

The Python checks require Python 3.11+ with `PyYAML==6.0.3` and
`jsonschema==4.26.0`. The repository's unified planner also runs these checks,
`cargo deny` and `cargo vet`; see [dependency policy](supply-chain/README.md).
The committed policy combines imported source audits with fifteen bounded publisher
trust entries and no exemptions. Both dependency checks must pass.

The shared runner checks two independent temporary source views: current Rust
against the published inputs read from Git at the merge-base with `origin/main`,
and current Rust against this checkout's candidate inputs. Each runs clippy,
the full test suite, native process checks, binary builds and the same
black-box check. Candidate generation stays in its temporary view; it cannot
update the committed manifest. Both views replay every recorded shape and
verify their exact input hashes, directory membership and per-method counts.
The recorded shape count is in `spec/baselines/swift-single-v1.json`. A change
that edits a consumed input runs `python scripts/generate-contract.py --write`
in that same change; `--check` and the corpus parity tests refuse a checkout
whose inputs and manifest disagree. Nothing compares the manifest with
`origin/main`, so a merge elsewhere never invalidates a branch, and the
published view moves only when a branch rebases.

Method schema definitions are checked recursively before values are evaluated,
including alternatives and absent properties. Unknown keywords, unsupported
patterns and malformed constraints remain failures even under `oneOf` or `not`.
The closed vocabulary includes `oneOf`, `const`, `not`, `minLength` and `pattern`:
`oneOf` requires exactly one match; constants use structural JSON equality;
`minLength` counts Unicode scalar values and accepts a nonnegative JSON integer
bound through `u64::MAX`. These follow the relevant
[JSON Schema assertions](https://json-schema.org/draft/2020-12/json-schema-validation)
and [applicators](https://json-schema.org/draft/2020-12/json-schema-core#section-10.2.1).
The only supported patterns are the two exact definitions in
[`schema_patterns.json`](crates/arkdeck-contract/src/schema_patterns.json):
lowercase SHA-256 and canonical ASCII decimal from zero through `i64::MAX`.
They match the whole string, including its end; no general regex engine is used.

The black-box check starts only its own daemon with a unique endpoint and HDC
configuration removed. It saves the actual outputs, input manifests and provenance
under `target/readonly-check/<run>/{published,candidate}/`
and validates schemas after all commands finish and the daemon exits. When the
checkout's inputs are byte-identical to the published pin, the published view
is recorded as covered by the candidate view (`publishedView` in
`summary.json`) and the native checks run once; any drift runs both views. On Unix it
records every current method, malformed frames and the three CLI leaves. On
Windows an unsigned build must refuse the actual daemon identity before sending
frames. Positive installed-daemon authentication and DAYU200 acceptance require
the [Windows SPK-3 harness](scripts/windows-spk3.ps1) and its real host conditions.

## Try the current host path

Run `cargo run -p arkdeck-agentd` from `rust/`, then in a second terminal:

```sh
cargo run -p arkdeck-cli -- --output json doctor
cargo run -p arkdeck-cli -- --output json operation list
cargo run -p arkdeck-cli -- --output json device candidates
```

The CLI verifies health on the authenticated connection before the business
request. It never starts a daemon or reconnects/replays a lost request. A normal
`doctor` returns its report even when readiness is false; `--require-healthy`
returns exit 69 for that report. All 30 Catalog operations are unavailable
because this phase has no operation execution provider. Without a usable HDC
observation provider, candidates returns a structured refusal, not an empty
successful snapshot. The wire method is `device.observations`.

The Unix default endpoint is a private development socket under the temporary
directory, separate from the published Swift socket. Windows uses a local
logon-scoped named pipe and requires an installed daemon identity. Development
composition accepts these process-environment inputs:

| Input | Meaning |
| --- | --- |
| `ARKDECK_ENDPOINT` | Absolute physical Unix socket path in a `0700` parent, or local `\\.\pipe\arkdeck-*` name. |
| `ARKDECK_DAEMON_PATH` | Expected installed daemon executable; defaults to the CLI's sibling daemon. |
| `ARKDECK_DAEMON_SIGNER_SHA256` | Windows trusted signing-certificate SHA-256, configured from installation evidence. |
| `ARKDECK_DAEMON_PACKAGE_FAMILY` | Alternative exact Windows installed MSIX package family. |
| `ARKDECK_HDC_PATH` / `ARKDECK_HDC_SHA256` | Exact existing tool selection; both are required and the platform tuple must already be registered. |

These are local host configuration, never control request fields or capability
authority. An arbitrary configured hash cannot register a Windows HDC tool.
The current published HDC tuples are macOS-only. The macOS commandless server
lease is also unavailable in this phase, so both paths refuse HDC dispatch.
Registering Windows requires actual Windows tool/output provenance and a
separately scoped integration change; see the
[delivery record](../openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/xpa-002-readonly-foundation.md).

## Isolated macOS History owner

The Rust daemon directly serves `history.filter.list/save/delete` when
`ARKDECK_DEVELOPMENT_STATE_ROOT` names an existing physical `0700` directory and
`ARKDECK_ENDPOINT` is directly inside it. The root must be separate from installed
ArkDeck state. This mode refuses Swift pairing and HDC configuration, and a kernel
directory lock prevents a second daemon. An interrupted daemon can restart on the
same endpoint; saved generations persist. Installed Runtime ownership is unchanged.

Use the existing CLI leaves against that endpoint:

```sh
cargo run -p arkdeck-cli -- --output json history filter list
cargo run -p arkdeck-cli -- --output json history filter save --expected-generation 1 --search build
cargo run -p arkdeck-cli -- --output json history filter delete --expected-generation 2
```

The same development Runtime serves `runtime storage status`, `runtime storage
policy --expected-generation <n> --total-quota-bytes <bytes>
--safety-margin-bytes <bytes> --retention-days <days>`, and `runtime storage root
--expected-generation <n> --root <existing-private-directory>` (or `--default`).
It owns `session-state/session-storage.json` and the `sessions` retention catalog.
Custom Session roots must stay inside the development root and disjoint from
state and immutable Artifacts. Artifact indexed usage is verified before Session
configuration mutation, including retained payload identity and SHA-256. Unknown Session bytes
remain visible as incomplete measurement; corrupt or lost initialized catalogs
are preserved for inspection. Artifact publication and installed activation
are still pending migration.

Run `python3 rust/scripts/check-session-owner.py` after building the binaries for
actual socket/CLI, nonempty Session census, restart/CAS, pin retention, damaged
catalog, isolated-root refusal and corrupt-payload-before-mutation checks. Its
fixtures are explicitly simulated host data and provide no device evidence.

The isolated owner also serves `session list [--page-size <n>] [--cursor <cursor>]`,
`session show --session <id>`, and `session pin|unpin --session <id>
--expected-generation <catalog-generation>`. Catalog generations can start at
zero; they are distinct from the storage configuration generation. Repeating an
already satisfied pin state does not advance the catalog. A stale generation or
an incomplete whole-root measurement prevents pin publication.

Pages are immutable private snapshots with query-bound cursors and bounded
retention (32 snapshots, 64 MiB total, 16 MiB per snapshot, 1 MiB per page). They
survive restart and active-root changes. A reclaimed cursor fails explicitly;
it never rescans. Ordering uses the published completion timestamp, with Session
ID ordering for ties, so hidden fractional seconds cannot create an invalid page.
`python3 rust/scripts/check-session-resources.py` verifies the actual owner and CLI;
`--cli-path Packages/ArkDeckKit/.build/debug/arkdeck` checks the current Swift CLI
against the same Rust owner.

The same isolated daemon also serves these existing commands:

```sh
arkdeck session cleanup preview
arkdeck session cleanup apply --preview-id <id> --preview-digest <sha256>
arkdeck session export preview --session <id> --destination <new-directory>
arkdeck session export apply --preview-id <id> --preview-digest <sha256>
```

Export preview excludes raw/partial Artifacts by default; add `--allow-sensitive`
only to the preview when those bytes are intended for export. Apply binds that
choice to the exact preview tuple, revalidates source and destination, and
publishes into a new directory without replacing an existing destination.
Completed retries return the stored result. An uncertain publication remains
non-replayable across restart. Source Sessions are preserved.

Cleanup preview shows the quota plan, including pinned/active protection, and
refuses incomplete inventories. Preview and apply require the Job owner's activity
guard directly through the configured `JobStore`. An absent or unreadable Job
inventory never means an empty active set. Both manifest Session identities and
`session-{jobId}` associations are protected. An unindexed or unsafe Job directory
refuses cleanup; indexed durable history is retained until its outcome can be
interpreted by the migrated Job owner.
The guard remains held through exact preview comparison, applying-intent publication,
descriptor-relative deletion, catalog reconciliation and durable result publication.
A stale preview refuses before deletion. An interrupted applying record returns
`outcomeUnknown` across restart and never replays; completed retries return the stored
receipt. The process harnesses
`rust/scripts/check-session-export.py` and `rust/scripts/check-session-cleanup.py`
exercise the real daemon/control/CLI paths with newly created host fixtures;
both accept `--cli-path` to check the current Swift CLI consumer.

Use the generation actually returned by `list`. Conflicts require a fresh read;
lost mutation replies report `outcomeUnknown` and are never automatically replayed.
No old state is imported, rewritten or removed. Current response schemas include
saved filters, tombstones, nullable identities and the existing owner error codes.
From the repository root, `python3 rust/scripts/check-history-owner.py` checks the
real daemon/CLI, restart, concurrent CAS, cross-process lock contention and unsafe
records in disposable host roots. Candidate contract CI includes this check.

The isolated macOS Runtime also serves `runtime tool inspect --tool <reference>`
and `runtime bundle inspect --bundle <reference>`. Tool references include the
existing HDC and DevEco toolchain families. The host opens existing Bootstrap
indexes below its fixed `bootstrap` directory and rechecks native content under
the shared registry lock. Reads preserve indexes, retained bytes, quarantine and
selection; execution assessment remains `notPerformed`. Session root selection
excludes the Bootstrap directory.

The CLI uses the authenticated client boundary and validates the exact requested
identity and returned projection. It cannot pass registry paths. The additive
Swift RPC producers supply actual recording-backed contracts, regenerated into
the manifest by the same change.
The isolated Rust owner also accepts `runtime tool register --kind deveco --root
<installed-app-Contents>`. It verifies native signed content without executing it,
then publishes the existing Swift registry format under the shared Bootstrap
lock. Re-registration preserves the reference and metadata; uncertain publication
returns `outcomeUnknown` without replay. The current Swift registration CLI uses
the typed RPC for DevEco. Rust HDC registration through the same typed method
merged in PR #1860 (`d00e4ec`); the Swift HDC registration path remains in process.
Selection and installed activation remain pending.

The existing `runtime tool list` and `runtime tool remove` leaves now use typed
Runtime calls in both CLI consumers. The Rust owner merges HDC and DevEco
inventory into immutable `toolRef:asc` pages, validates current native content
before continuation, and preserves restart/cursor behavior. Retirement accepts
an exact reference and expected generation `1`, rejects retained references,
keeps content unchanged, and returns the same generation `2` receipt on repeat.
A missing or inconsistent publication receipt is `outcomeUnknown`, with no replay.
Run `rust/scripts/check-tool-list.py` and `rust/scripts/check-tool-retirement.py`
with the configured Python interpreter against candidate binaries. Both use
fresh temporary registries; `--native-registry` copies an explicit temporary
Swift-produced registry to cover DevEco alongside HDC, and `--cli-path` selects
the Swift consumer. These checks do not activate the installed Runtime.

For an explicit native macOS check, build the candidate binaries in release mode
and run `python3 rust/scripts/check-deveco-register.py --bin-dir <release-dir>
--source-root /Applications/DevEco-Studio.app/Contents`. The harness retains a
fresh temporary registry, checks restart/idempotence and verifies that installed
Bootstrap metadata and source content remain unchanged. `--cli-path <swift-cli>`
checks the Swift registration consumer against the Rust owner. Missing native
content is reported as SKIP; this is separate from portable contract CI and is
not device acceptance.

`cargo build -p arkdeck-hoststore --example tool_registry_read` builds the local
comparison adapter. Set `ARKDECK_TOOL_OWNER_BINARY` to it when running
`BootstrapToolRustOwnerTests` to compare a real Swift registration with Rust.

The macOS `ArtifactReadStore` library lists, inspects and reads existing Job
Artifact publications with full-payload digest verification and bounded range
allocation. Typed inspect/read result conversion matches actual Swift producer
recordings, including missing content and observation windows. It preserves the
frozen index format and never writes verification caches. The current
`artifact.inspect` and `artifact.read` RPC handler requires a successful Job-owner
snapshot callback before touching content. The Rust CLI uses the existing
`artifact inspect|read --job <id> --artifact <id>` commands; reads first inspect
metadata, then bind one bounded range to its owner, digest, length and offset.
`--allow-sensitive`, `--raw` and a bounded `--timeout` preserve the current CLI
behavior. The development Host composes the Job read owner and refuses requests
when it is unavailable; import leases, Artifact writes and installed owner cutover remain
pending. `python3 rust/scripts/check-artifact-read-owner.py` runs the read-library
checks; `cargo test -p arkdeck-cli --test artifact_resources` checks current
producer metadata, argv, raw encoding and failure classifications.

The isolated development composition also answers `artifact.quota` (TASK-XPA-013)
as a Swift daemon answers it before it has cached a total: `artifact_quota.rs`
classifies every Artifact root entry first (the Import owner's directory and a
regular cleanup ledger are skipped, any other directory is a Job, anything else
refuses), reads each Job's index as Swift `loadIndex` does (an absent or dangling
index has no rows), decodes it as Swift's synthesized `Codable` does (unknown
members ignored, Swift's `DecodingError` descriptions), and checks each row's
identity and each published payload's type, size and digest in order. Every
refusal is `internalError` with Swift's rendering of the store error. Unlike
Swift, which reseals a payload that is not `0400` and writes its verification
caches while it hashes, the Rust read writes nothing, and it keeps no total
between reads. `arkdeck artifact quota` sends the method without parameters, as
Swift's CLI does. `rust/tests/fixtures/artifact-quota/` is the oracle Swift
`ArtifactQuotaOracleContractTests` records over 27 roots its store writes in
temporary directories (re-record with
`ARKDECK_RUST_ARTIFACT_QUOTA_RECORD=/private/tmp/<new>`); `tests/artifact_quota.rs`
reproduces every answer and leaves every root untouched, and
`scripts/check-artifact-quota.py` compares a fresh Swift daemon and a fresh Rust
owner, and both CLIs, over each root.

## Contract and ownership boundaries

The isolated macOS host serves `trace cache status` and `trace cache purge` from
its fixed `trace-cache/traces` directory, with private staging in the sibling
`trace-cache/staging`. Inventory reports actual byte counts and respects the
existing key locks and entry leases; unaccounted entries remain active.
Purge also requires existing owner evidence and a complete guarded Job and
Artifact census. Unreconciled Job history, any retained Artifact namespace or
file, and any upload record, identity or payload in the Import namespace
preserve all cache entries and private residuals; the Import owner's idle
`.imports-v1` skeleton alone does not. Unsafe or unreadable owners refuse
maintenance before any deletion. An inactive census permits only inode-bound
derived cache quarantine/removal under the existing leases. Original Trace
Artifacts remain untouched. Callers cannot pass a cache path, Session root
selection excludes the entire cache parent, and uncertain CLI results never
replay purge. Database preparation and installed cache ownership remain pending.
The paired native receipt requires ArkTrace with the directory-hinted owner
target fix (ArkTrace PR #25); the previously pinned `e6e3133d` skips every
Ready entry, so parity checks against it record that mismatch rather than pass.

Run `python3 rust/scripts/check-trace-cache-owner.py` after building the binaries
to check real RPC/CLI status and purge, retention, lease contention, restart,
namespace refusals and original Artifact preservation.
Use `--cli-path Packages/ArkDeckKit/.build/debug/arkdeck` for the current Swift
CLI consumer. The harness uses only temporary host fixtures. For a current
native owner/metadata fixture, run `produce-trace-maintenance-fixture.py` against
the pinned SwiftPM objects during the coordinated native build window, then
pass its new directory using `--native-fixture`. The producer uses synthetic
database bytes, retains provenance, and compares the complete Rust purge receipt
with the paired native ArkTrace receipt; it does not establish parser or device
acceptance.

`arkdeck-contract` contains generated schemas, strict framing, canonical encoders
and digest functions. `arkdeck-control` has transport-free observation and local-resource handlers.
`arkdeck-platform` owns the unsafe OS boundary; all other crates forbid unsafe
code. `arkdeck-provider-hdc` lowers one fixed observation argv through that
boundary. `arkdeck-client` owns same-connection health and refusal handling;
`arkdeck-cli` presents the current CLI envelope; `arkdeck-agentd` composes them.
The black-box check also verifies these dependency edges.

The macOS cleanup path retains each signal error and the owned child PID while
waiting for the existing terminal-child and complete process-group proof. It
resolves a transient `EPERM` only within the cleanup budget and before reaping;
unproven groups, other signal errors and lost child ownership remain failures.

The manifest lists every registry method. Methods without a migrated host
handler are structurally understood and refused.
There is no Runtime capability owner, recovery, journal writer, durable target store,
device mutation, flash lowering, Swift replacement or production cutover here.
Unknown or incomplete outcomes never acquire invented zero-dispatch evidence.

Catalog generation preserves the same canonical source bytes and SHA-256 as
Swift. The CLI canonical encoder preserves the current Swift vectors, including
its existing binary64 spelling below `1e-4` and above the Int64 fast path. Swift
currently emits `1e-6` and `1e+20` where RFC 8785 would use decimal notation.
Native Swift boundary vectors pin that known difference; this phase does not
claim universal RFC 8785 conformity or change Swift semantics independently.
The generated manifest records every consumed schema, corpus, source and fixture
digest of this checkout. `generate-contract.py --check` regenerates the manifest
and bindings from the working tree and verifies both are byte-identical; it
consults no other commit. `check-contracts.py` reads the published inputs from
Git at the merge-base with `origin/main` and must pass against them and against
the checkout's current inputs. Unsupported schema vocabulary, stale Catalog
output and native Swift oracle source drift remain failures. A candidate
manifest is always marked `candidate` and names its source revision, input
digest and published base commit; the committed checkout manifest names no
commit, because it cannot name the one it is part of. No runtime protocol
negotiation or version fallback is added.

Updating the manifest is `python scripts/generate-contract.py --write` in the
change that edits an input. Keep `origin/main` available locally so
`check-contracts.py` can find the merge-base. Generation and host conformance
remain separate from actual device acceptance.

The Rust read-only CLI also accepts `operation describe|example --operation <reference>`
and `job status|show|evidence|timeline --job <id> [--timeout <duration>]`,
plus `job list` with current pagination and string filters. It consumes current Runtime
facts, validates the returned identity/publication/nextAction relationships and
preserves uncertain outcomes. The Rust control owner serves descriptors from the
compiled Catalog while retaining actual Provider availability. Job reads share one total
deadline; timeline returns one validated page and evidence retains the Runtime
verification status and its 0/75/2 exit code. These additions do not retire
the Swift CLI.

The macOS development daemon reads the frozen v1 SQLite Job index through a
serialized, bounded connection. `job list`, `job status`, `job show`, and
`job timeline` use immutable paged snapshots. Artifact inspect/read first resolves
the Job from this owner; orphan artifact directories do not establish ownership.
Session cleanup preview/apply hold the complete Job activity census and retain
parked unknown outcomes and uninterpreted durable history. This read phase refuses unsupported optional authority and
recovery fields until their validators are ported. It does not admit or execute
Jobs, alter existing SQLite records, or recover journals.

`rust/scripts/check-job-read-owner.py` compares actual Rust daemon and CLI results
with explicitly generated temporary Swift Job/Artifact fixtures and verifies
restart persistence and a second owner refusal. The fixture-producing contract
tests are `testRustJobOwnerCurrentSQLiteFixture` and
`testRustArtifactOwnerCurrentFixture`; set `ARKDECK_RUST_JOB_FIXTURE_OUTPUT` or
`ARKDECK_RUST_ARTIFACT_FIXTURE_OUTPUT` to a new temporary output path.

## Job event metadata reader

The isolated macOS Job owner serves `job.events`; the Rust CLI accepts
`job events --job <id> [--page-size <n>] [--after-cursor <cursor>]` with a bounded
optional timeout. It validates the current nineteen closed Journal event kinds
and returns metadata only. Unknown fields, corrupt complete lines, replaced
inodes, malformed sequences and forged cursors are refused. An interrupted final
append becomes visible only after its complete line is published.

The existing `jec1` AES-256-GCM cursor format binds the Job, inode and generation,
origin, predecessor and high-water offsets. Swift and Rust can resume each
other's actual cursors on the same source-created journal; cursors survive daemon
restart without rewriting Journal or SQLite records. A private 32-byte cursor
key is created durably only for a first page; resuming without it refuses. These
cursors confer no Runtime execution or recovery authority. Reads are bounded to
16 MiB per record, 64 KiB buffers, 1 MiB per page and at most 1,000 events.

`rust/scripts/check-job-events.py` accepts an explicit private temporary Swift
fixture and verifies actual daemon/CLI paging, cursor forgery refusal, restart
and unchanged Journal, SQLite and key bytes. The six additional publisher-trust
entries use only the user-authorized fixed releases and their publication days;
see `supply-chain/README.md`. Journal writes, watch/wait CLI behavior, full stored
Job authority validators and installed owner cutover remain pending.

## Job journal writer (TASK-XPA-014)

`arkdeck_hoststore::JournalWriter` appends to a Job directory's current
`journal.jsonl` with the Swift journal's discipline: every append holds the
directory's `.manifest.lock`, refuses after terminal `manifest.json`
publication, stays bound to the journal inode it opened, validates the record
with the closed per-event decoder and the Swift replay/append rules
(`JournalReplay.validate` and `JournalAppendValidationState`, ported as one state
machine for all 19 kinds), and returns only after fsync + `F_FULLFSYNC` of the
file and fsync of the directory. An unchanged file rechecks only its last record;
any external change forces a full replay first. A torn tail is cut back only
behind a durable `jobCreated` and before terminal publication. A failure after
the write began is `OutcomeUnknown` and poisons the writer until it is reopened.
`job_journal_events` spells the engine's eight record kinds exactly as Swift's
factories do. The writer records whatever its caller decides; it holds no Job
authority, and no daemon path uses it yet.

`rust/tests/fixtures/journal-writer/` is the shared oracle: four scenarios
(succeeded, outcome unknown with reconcile, confirmed compensation, plan-only)
as Swift `FileDurableJournal` writes them, with the facts
`DurableJournalRecovery.inspect` derives. `cargo test -p arkdeck-hoststore
job_journal_writer` must reproduce both from the same records, and
`JournalRustWriterParityContractTests` holds Swift to the same bytes. Re-record
from Swift with `ARKDECK_RUST_JOURNAL_WRITER_RECORD=/private/tmp/<new>`.

## Job index and record writers (TASK-XPA-014)

`arkdeck_hoststore::JobStore::open_owner` opens a state root for the Rust Job
owner. `admit` commits an idempotent admission to the unchanged v1 `runtime_job`
index: a known idempotency key answers with its Job or a conflict, and a new key
takes the next admission sequence at version 1 with the exact initial record
bytes. `persist` checks that the index row describes the record, publishes
`jobs/<jobID>/job-record.json` atomically and then advances the row's state,
update time, version and record bytes. `JobRecord::durable_bytes` spells a
record as Swift's `JSONEncoder([.sortedKeys, .prettyPrinted])`. The owner and the
reader inspect a store read-only only when its shared-memory index exists, as
Swift does. No daemon path admits Jobs yet.

`rust/tests/fixtures/job-store-writer/` is the oracle Swift
`JobStoreRustWriterParityContractTests` records: records, a Foundation
pretty-print probe, an admission scenario and the index facts it leaves.
`tests/job_store_writer.rs` reproduces it. Re-record from Swift with
`ARKDECK_RUST_JOB_STORE_RECORD=/private/tmp/<new>`.

## Job plan (TASK-XPA-014)

The isolated development composition answers `job.plan` as Swift
`RuntimeJobEngine.planOnly` does for `analyzer.extract-crash-signature@1`, the one
operation this Runtime materializes so far. `OperationRequest::decode` reads the
current request as Swift's codec does: closed members, governance and
retired-authority refusals, then the typed members in Swift's order with Swift's
own messages, Foundation's `DecodingError` descriptions included. Its canonical
bytes give Swift's request fingerprint. After the catalog's typed input rules the
planner checks the pinned analyzer (named by `ARKDECK_ANALYZER_PATH`, as for the
Swift daemon), resolves the source Artifact lease as
`RuntimeArtifactStore.resolveLease` does (the payload opened through no link and
hashed, refusals spelled as Swift interpolates them), re-reads its bytes as the
analyzer action does, and digests the materialized plan document. Nothing is
admitted, journaled or dispatched, and every refusal carries
`{"phase": "preAdmission", "newDispatchCount": 0}`. Unlike Swift, planning writes
nothing: no Job directory for a missing lease, no payload-verification cache, no
resealed payload. Every other operation, an imported Artifact lease and a Runtime
debug attempt permit are refused with `rejected` before anything is materialized.

`arkdeck job plan` sends `--request-file` verbatim or builds the current request
from `--target`, `--operation` and `--inputs-file`, applies the catalog's binding
rule to `--expected-binding-revision` as the Swift CLI does, and accepts only a
complete `arkdeck.job-plan/1` projection of an unadmitted plan.

`rust/tests/fixtures/job-plan-analyzer/` is the oracle Swift
`JobPlanAnalyzerOracleContractTests` records under the fixed physical root
`/private/tmp/arkdeck-job-plan-oracle`, because the plan digest covers the source
Artifact's absolute path: 71 requests, four of them planned. `tests/job_plan.rs`
rebuilds the recorded store at that root and reproduces every answer. Re-record
from Swift with `ARKDECK_RUST_JOB_PLAN_RECORD=/private/tmp/<new>`.
`scripts/check-job-plan.py` runs the standalone Swift daemon and the Rust owner in
turn over one state root and compares every answer over the socket and through
both CLIs.

## Job admission (TASK-XPA-014)

The isolated development composition answers `job.submit` as Swift
`RuntimeJobEngine.submitOwned` does under target control, for the operation it
plans. `JobAdmitter` decides a retry or a conflict from the idempotency index
before anything is materialized, checks a reviewed plan against the existing Job
or against the fresh materialized plan, and admits under the catalog's default
read-only policy; no capability is read or written. It then writes the admission
row, the Job's journal (`jobCreated`, `queued -> preflight`) and `job-record.json`
at the index's next version, each as Swift writes them. A refusal before the
admission point carries `{"phase": "preAdmission", "newDispatchCount": 0}`; a
failure after it carries empty details, as Swift's does. The isolated owner opens
its Job store with the owner connection. Nothing is dispatched: an admitted Job
waits in `preflight` for an executor, and a standalone Swift daemon given the
same store recovers it and can run it.

`arkdeck job submit` builds requests as `job plan` does, prints Swift's note when
it generates the idempotency key, accepts only an acceptance that dispatched
nothing, and reports a reply that cannot prove zero dispatch as an unknown
outcome. It has no `--wait`: this Runtime cannot run the Job it admits yet.

`rust/tests/fixtures/job-submit-analyzer/` is the oracle Swift
`JobSubmitAnalyzerOracleContractTests` records under the `job.plan` oracle's fixed
root: 18 requests in order over one store (four admissions), how `job.status` and
`job.show` read each admitted Job, and the store left behind.
`tests/job_admission.rs` reproduces the answers, the reads, the index and every
Job file byte for byte. Re-record from Swift with
`ARKDECK_RUST_JOB_SUBMIT_RECORD=/private/tmp/<new>`. `scripts/check-job-submit.py`
runs the standalone Swift daemon and the Rust owner in turn over one state root,
then hands the Rust-written store to a Swift daemon that recovers the Jobs and
runs one.

## Job run (TASK-XPA-014)

The isolated development composition answers `job.run` for the analyzer Jobs it
admits as Swift `RuntimeJobEngine.runForTargetControl` does, composed like a
Swift engine without a Session publication writer. `JobRunner` refuses absent,
terminal and parked Jobs before any dispatch, with Swift's messages and the
zero-dispatch proof, and runs only a Job at its admitted `preflight` boundary:
the `preflight -> running` transition, the source lease resolved again, the exact
typed action persisted in `job-record.json` before the write-ahead `stepIntent`
is synchronized, and only then the pinned analyzer, spawned through its retained
inode in its own process group and handed the source as the `/.vol` alias of a
descriptor bound to its digest, with a clean environment, `/` as its directory
and `/dev/null` as stdin. Each output stream keeps its first 8 MiB and drains the
rest; a timeout terminates the group (TERM, then KILL after 0.25 s). Swift's
semantic checks judge the receipt, the correlated `stepOutcome` follows, and a
verified answer is published as `crash-signature.json`: Swift's provenance
envelope, redacted by Swift's default policy (the home directory and
secret-looking values, with ICU's matching), under an Artifact quota that refuses
a new product and never evicts one, the payload sealed `0400` before the index
names it. Terminal transitions and records are spelled as Swift writes them. A
timeout, a signal death or an unobservable child leaves the intent outstanding
and parks the Job in `waitingForRecovery`; nothing is dispatched twice. Recovery
is not ported (ADR-0009 decisions 2/4, L.1 item 13): a Job in any resumable
state, or whose journal has left `preflight`, is refused. Concurrent runs of one
Job join its one run, as Swift's callers do.

`arkdeck job run --job <id>` prints the Job's status and exits as Swift's CLI
does: 1 for a failed, cancelled or interrupted Job and 75 for an unknown outcome.
A connect failure stays `runtimeUnavailable`; a reply that cannot prove zero
dispatch is `outcomeUnknown`.

`rust/tests/fixtures/job-run-analyzer/` is the oracle Swift
`JobRunAnalyzerOracleContractTests` records with the real descriptor-bound
dispatcher and an analyzer that answers by the first line of its source: 20
ordered runs over one store (three published products, eight semantic refusals,
a timeout, a signal death, a quota refusal, a removed source and five refused
runs), Swift's reads of each Job and the store they leave. Every Job but the
timeout case's runs under the daemon's 30 s analyzer budget; the timeout case's
entries name the 2 s budget of the composition that holds its Job. Its source
answers `hold`, which ends only once a release file exists under the oracle
root, and nothing creates one in this oracle, so only that budget ends it.
`tests/job_run.rs` reproduces every answer, read, index row, Job file, Artifact
index and payload byte for byte. Re-record from Swift with
`ARKDECK_RUST_JOB_RUN_RECORD=/private/tmp/<new>`. `scripts/check-job-run.py` runs
the standalone Swift daemon and the Rust owner in turn over one state root, then
hands the Rust-run store to a Swift daemon that reads every Job and Artifact.

## Job result and evidence (TASK-XPA-014)

The isolated development composition answers `job.result` and `job.evidence` for
the analyzer Jobs it runs as Swift `RuntimeJobResourceReader` does. `JobResultReader`
reads the Job from its durable index — an absent Job is `notFound` without
details, as Swift answers every Job read — and refuses `job.result` for a Job
that is not terminal with `resultNotReady` and the status's next action. The
evidence is derived once for both reads: the catalog descriptor while the Job's
catalog digest is current, every Artifact index row of the Job checked against
its owner, every published payload rehashed (all or nothing), and each required
product the index lacks named in `missingRequiredArtifacts`; the status follows
Swift's precedence. `job.result` adds the status with its outstanding cleanup
count, the inventory sorted as Swift sorts it, the Job's outstanding rows of the
cleanup ledger and the one next action they leave. A read that races a change
of the Job is refused (`resourceConflict`), and a result over 4 MiB is
`inputTooLarge`. Rust reads write nothing, where Swift may create a Job's empty
Artifact directory, reseal a payload or refresh its verification cache while it
reads. Until their owners join, a Job of another operation or one carrying
device observations or Trace probes is refused (`rejected`, with the zero-dispatch
proof), and a store holding recovery epochs degrades the evidence to
`recordUnreadable` (L.1 item 13).

`arkdeck job result --job <id> [--timeout <duration>]` checks the whole result
as Swift's CLI does — the status, the evidence, every inventory and cleanup row
and the next action they imply — and exits 75 for an unknown outcome, then 2
while the evidence needs attention, then 1 for a failed, cancelled or interrupted
Job. A failed analyzer Job never publishes its required product, so its result
exits 2. `resultNotReady` exits 75 and the request may be retried.

The run oracle also records Swift's `job.result` and `job.evidence` of every Job,
the six Job reads of an absent Job and the two reads of open options
(`refused-reads.json`); `tests/job_run.rs` answers each through the Rust readers
byte for byte. `scripts/check-job-run.py` compares both reads and both CLIs'
`job result`, and has the Swift daemon read the result of every Rust-run Job.

## Session publication (TASK-XPA-014)

The isolated development composition publishes a Session for every terminal
Job it runs, as the standalone Swift daemon's `RuntimeSessionPublicationWriter`
does, through the Session owner it already holds. Once a Job's terminal record
is durable, `SessionPublisher` reads the storage status (which initializes a
missing catalog), claims metadata and finalization headroom on the Sessions
volume, and composes the Manifest from the Job's record and Journal alone: a
host target, no toolchain, the typed steps with the tuples their outcomes
prove, and no copied Artifacts. It then writes the proposal beside the Job,
appends the Journal's `finalized` record, creates the Session once
(`yyyy/mm/session-<job>`, its identity document created exclusively), copies
the Journal byte for byte, appends the outcome audit, publishes `manifest.json`
write-once (`RENAME_EXCL`) under the Session's terminal lock and every Artifact
publication shard, and registers the catalog entry before it releases the
claim. The Job record keeps Swift's ownership marker at one more index version:
the receipt once the catalog holds the entry, `awaitingStorage` when the volume
has no room, a confirmed failure otherwise; reads report the publication fact
from it. A parked Job, whose outcome is unknown, publishes nothing. As in
Swift, a restart never resumes a publication and nothing retries one;
reconciliation stays unported (L.1 item 13).

`rust/tests/fixtures/job-publication-analyzer/` is the oracle Swift
`JobRunAnalyzerOracleContractTests.testSwiftPublishesTheSharedAnalyzerSessions`
records with the standalone daemon's writer over a Sessions root and storage
owner of its own: six Jobs (a success and a failure published, a parked Job, a
full volume, a Session path something else already holds, a source removed
before its run), each Job record's volume, device, inode and claim generation
kept as labels. `tests/job_publication.rs` reproduces every answer, read, index
row, Job file, Artifact, Session file and catalog, and every entry's mode, byte
for byte. Re-record from Swift with
`ARKDECK_RUST_JOB_PUBLICATION_RECORD=/private/tmp/<new>`. `scripts/check-job-run.py`
compares both owners' publications and has a Swift daemon list and show every
Rust-published Session.

## Job cancellation (TASK-XPA-014)

The isolated development composition answers `job.cancel` for the analyzer Jobs
it admits as Swift `RuntimeJobEngine.requestCancel` does behind the daemon's
handler. `JobCanceller` requires a string `jobId` (`invalidParams` "jobId is
required"), answers an absent Job `notFound` "unknown job <id>", and otherwise
answers `{"cancelRequested": true}` once the request is carried out or needs
nothing; like Swift it attaches no details to a refusal. A Job at its admitted
`preflight` boundary closes with zero dispatch at once: the three journaled
transitions `preflight -> cancelRequested -> cancellingAtSafeBoundary ->
cancelled` with Swift's reasons, the cancelled failure (`notAutomatic`, `none`),
its finish time and record, and then the publication every terminal Job gets, a
cancelled Session without steps. A Job that ended or is finalizing is left as it
is, and so is one that waits for recovery or already carries the request; Swift
also remembers such a request in memory for the Job's recovery, which is not
ported (L.1 item 13).

A Job this owner is running is cancelled by its run, which alone writes the
Job's Journal: the request waits in the run's `RunCancellation` until the run
has written and persisted Swift's `running -> cancelRequested` ("durable client
cancellation intent"). At its last boundary before the analyzer intent the run
then closes the Job with zero dispatch. While the child runs, the run
terminates the child's process group as Swift's executor does (TERM, then KILL
after 0.25 s, then a second for the group to disappear) and, once no member is
left, records the step's confirmed `failed` outcome with semantic code
`cancelled` and closes the Job through `cancellingAtSafeBoundary` to
`cancelled`, which is published as a Session. A group that cannot be drained,
or a child that finished before the request reached the run, parks the Job in
`waitingForRecovery` without replay; once the child has finished, a request
changes nothing. Swift answers as soon as the intent is durable; the Rust
canceller answers once the run has acted, which for a running child is after
the drain. A Job left active without a run here is refused as Swift refuses a
Job it holds no runtime for (`rejected`, `internalFailure("job <id> is <state>
but is not resident, …")`). A run of a Job no run holds waits a cancellation
out and then meets the cancelled Job (`resourceConflict` with the zero-dispatch
proof), and concurrent cancellations of one Job join.

`arkdeck job cancel --job <id>` sends the opaque identity as Swift's CLI does,
prints the answer and exits 0. As for any mutation-capable method without the
zero-dispatch proof, `notFound` is `resourceNotFound`, `invalidParams` is
`invalidInput`, `rejected` and `internalError` are `outcomeUnknown` (75), and so is
a reply lost after the request went out; a connect failure stays
`runtimeUnavailable`.

`rust/tests/fixtures/job-cancel-analyzer/` is the oracle Swift
`JobRunAnalyzerOracleContractTests.testSwiftCancelsTheSharedAnalyzerJobs` records
in the publication oracle's composition: four Jobs and twelve ordered requests (a
Job cancelled before it runs, cancelled again and then run; Jobs cancelled once
they succeeded, failed or parked; an absent Job; parameters without a string Job
identity), Swift's four reads of each Job and everything the requests leave.
`tests/job_cancel.rs` reproduces every answer, read, index row, Job file,
Artifact and Session file and every entry's mode byte for byte. Re-record from
Swift with `ARKDECK_RUST_JOB_CANCEL_RECORD=/private/tmp/<new>`.
`rust/tests/fixtures/job-cancel-running-analyzer/` is the oracle
`testSwiftCancelsRunningAnalyzerJobs` records with the engine's two
cancellation hooks: a Job cancelled once its intent is durable and its `hold`
child runs, one cancelled at the last boundary before the intent, and one
cancelled after its success commit. The oracle and `tests/job_cancel_running.rs`
create the child's release file only once its run has answered, so no stall
between the intent and the cancellation lets the child finish first.
`tests/job_cancel_running.rs` reproduces every answer, read and file byte for
byte; re-record it with `ARKDECK_RUST_JOB_CANCEL_RUNNING_RECORD=/private/tmp/<new>`.
`scripts/check-job-run.py` compares both owners' cancellations, one of a Job
whose `hold` child is running included (the harness holds the oracles' lock and
never releases that child), and both CLIs' `job cancel`, and has a Swift daemon
answer a cancellation and a run of the Rust-cancelled Job.

## Capability reads (TASK-XPA-014)

The isolated development composition answers `capability.list` and
`capability.inspect` from a capability store beside its Job state,
`<root>/jobs-state/capabilities`, as the Swift daemon answers them from
`<state>/capabilities`. `CapabilityStore` (`arkdeck-hoststore`) reads Swift's
`RuntimeCapabilityStore` format under the store's blocking exclusive lock: the
checkpoint `runtime-capabilities.json` and every event appended to
`runtime-capabilities.ledger` since it, a torn final append dropped. It refuses
what Swift refuses, in Swift's words: a checkpoint or ledger that is a symbolic
link, a ledger without its checkpoint, duplicate or malformed JSON (a port of
Swift's `StrictJSONDuplicateValidator`, `strict_json.rs`), a document outside
the current shape or a capability breaking its model invariants (with Swift's
`DecodingError` descriptions), an event that cannot be replayed, and
inconsistent use accounting, lineage order or receipt and outcome digests.
Every refusal is `internalError` with Swift's rendering of the store error, the
store's directory included. A list row carries the capability's identity,
effect ceiling, uses and lineage blocker (a use without a settled outcome, else
an exhausted budget); an inspection carries the whole capability and its
lineage, `invalidParams` without a string `capabilityId` and `notFound` for an
unknown one. A read writes nothing but the lock file; nothing here installs,
mints, reserves or consumes a use.

`arkdeck capability list` and `arkdeck capability inspect --capability <id>`
send what Swift's CLI sends and print the answer.

`rust/tests/fixtures/capability-read/` is the oracle Swift
`CapabilityReadOracleContractTests` records: synthetic capability stores the
Swift store writes through its public API in temporary directories (every use
outcome, a revocation, a device, workspace and destructive Runtime-issued
capability, more appended events than the periodic checkpoint allows) and such
stores with one defect each, with every answer the daemon's control plane gives
over them and the kind and mode of every entry before and after the reads.
`tests/capability_read.rs` reproduces every answer and leaves every store as
Swift's reads left it. Re-record from Swift with
`ARKDECK_RUST_CAPABILITY_READ_RECORD=/private/tmp/<new>`.
`scripts/check-capability-read.py` places every oracle store where each daemon
keeps its own and compares the standalone Swift daemon and the Rust owner, and
both CLIs, over the oracle's reads.

## Target presentation owner (TASK-XPA-012)

The explicitly isolated development composition owns `targets-state/` and serves
`target list`, `target show`, `target display-name set|clear`, and
`device display-name set|clear`. Target bindings and alias history are validated
and read without rewriting `targets.json`; local names use the current Swift
`target-display-names.json` format, private descriptor-anchored locks and atomic
publication. Target names survive restart; candidate names require the current
Runtime observation reference and expire on refresh or restart. A lost or invalid
name-write reply is `outcomeUnknown`; the CLI never replays it.

Candidate observations come from the configured HDC read-only provider. This
phase cannot produce independent USB attachment proof, adopt a target, select an
execution route, or write binding/alias history. `target.show` leaves the absent
Bootstrap warm presentation and confirmed Job-observation sources as `null`.
Existing adopted names can be projected onto actually observed provider addresses.

`rust/scripts/check-target-resources.py --swift-target-store <fixture-directory>`
checks actual Rust endpoint/CLI behavior from bytes exported by the Swift contract
producer; `--cli-path` selects a current Swift consumer. The fixture is explicitly
simulated host-test data. Run it after current Swift producer recording and schema
generation; it checks typed refusals as well as CAS, restart and binding-byte
preservation. No hardware acceptance is claimed by this harness.

## macOS HDC server identity (TASK-XPA-016, SPK-6)

`LoopbackServerLease::acquire(tool, 127.0.0.1:<port>)` proves that an HDC server
already exists on macOS the way Swift's `HDCExact320FSystemIdentityObserver`
does: it reads libproc, never connects to the endpoint and never launches a
client (not even `checkserver`, which may bootstrap a server). The one process
running the verified executable that owns exactly one TCP listener on the exact
registered loopback spelling — `127.0.0.1` or its IPv4-mapped IPv6 form as the
kernel labels it, never a wildcard — is named by its birth identity; two scans
must agree, and `revalidate()` fails once that process exits or a PID is
recycled. `NotFound` is Swift's `unavailable`, `PermissionDenied` its `unknown`.
The owner must also be the calling user, as on Windows. `HdcReadOnlyProvider`
acquires this lease before its only argv and revalidates it after the process,
so `device.observations` can now reach a spawn on macOS when a published HDC
identity is registered and its server is up. A candidate process that exits
between being listed and having its sockets read owns nothing and is skipped
(a server restarting under a scan is caught by the two scans having to agree);
a process the kernel will not describe stays `unknown`, since it may own the
endpoint. `tests/loopback_server_lease.rs` drives it with listener processes
of the test binary itself (re-executed with `listener_process` selected) and
with `/usr/bin/nc` in place as another executable; no real HDC is launched by
the tests.
## Verified tool runner (TASK-XPA-016, SPK-6)

`VerifiedTool::run_tool(&ToolRequest { arguments, environment, working_directory,
limits }, cancelled)` runs any pinned executable the way Swift's
`FoundationProcessExecutor` runs a descriptor-bound provider dispatch: spawned
through its retained inode in a new process group; a caller-named environment
overlaid on the clean base (`PATH`, `LANG`, `LC_ALL`; the daemon's own
environment is never inherited, and `PATH`, `LC_ALL` and dynamic-loader
variables cannot be overlaid); a child-only working directory that must be an
absolute, canonical, existing directory; `/dev/null` as stdin; each stream kept
to its first `capture_bytes` while the rest drains; a timeout that terminates
the process group (TERM, then KILL after 0.25 s); and a cancellation probe asked
before the spawn (no child) and while the child runs (the group drained). The
result carries both streams, whether either was truncated, the termination
(`Exited`, `Signalled`, `TimedOut`, `Cancelled { drained }`) and the monotonic
duration Swift's receipt reports; `Refused` errors ran no tool code,
`Unobservable` ones cannot say what the child did. `run_analyzer` is this runner
with the source Artifact retained. `tests/tool_process.rs` drives it with shell
scripts; the HDC provider's `run_read_only_*` path is unchanged until lane A's
dispatch seam moves onto it.

## Persistent device shell channel (TASK-XPA-016, SPK-6)

`DeviceShellChannel::open(tool, ["-t", <key>, "shell"], env, settle)` keeps one
`hdc shell` open on a pseudo-terminal, as Swift's `PersistentDeviceShellChannel`
does for pointer injection: echo and newline translation off, the client in its
own process group on the retained inode, opening proved by a framed `true`.
`run(tokens, timeout, budget)` carries bare tokens only and brackets each
command with a fresh nonce, so the device shell reports the command's own exit
status and a late answer can never be read as the next command's. An answer
past the budget is trimmed and marked; one past the budget plus 4 MiB, the
timeout or the client's death closes the channel as an unknown outcome, never
a failure. `tests/shell_channel.rs` drives it with `/bin/sh -i`; no HDC is
launched by the tests.

## PTY prompt/secret exchange (TASK-XPA-016, SPK-6)

`VerifiedTool::run_pty_exchange(&PtyRequest { arguments, environment,
working_directory, timeout }, interactions, output_byte_budget, cancelled)`
runs a signer on a pseudo-terminal as Swift's `IdentityBoundPTYExecutor` does:
echo disabled by the parent before the child runs, each exact prompt answered
in order with its secret, the secret never in argv, environment or result, a
secret seen in the output or a prompt out of protocol ending the exchange, the
budget, the deadline and a cancellation terminating the child's group. What
comes back is the termination, how many prompts were answered, how many bytes
were seen and Swift's closed failure category classified from the diagnostic
after the last prompt; the transcript is wiped. `tests/pty_exchange.rs` drives
it with shell scripts that print the signer's prompts; no signer is launched.

## macOS facade host owners (TASK-XPA-012)

The installed facade pair now serves `history.filter.list/save/delete` itself.
`arkdeck-facade` opens the History filter document in the paired authority's
state directory (the public socket's directory: `--state-dir` in development,
`~/Library/Application Support/ArkDeck/Agentd` when installed) and never
forwards those frames; the Swift daemon composed behind a facade
(`AgentFacadeHostOwnership`) no longer opens that store, so one process owns
its lock. A standalone Swift daemon keeps its own owner over the same file and
format. Requests inside the facade queue on one in-process guard, as the Swift
owner's blocking lock did; another process holding the lock is refused with
`resourceConflict`. Every Rust owner lock is unlocked before its descriptor
closes, so a child that another thread is spawning never keeps a released lock.
Every other method is still forwarded unchanged.

`ARKDECK_DAEMON_UNDER_TEST=target/debug/arkdeck-agentd python3
scripts/test-macos-facade.py` checks the transport against a fixture authority,
including that History filter frames never reach it.
`python3 rust/scripts/check-facade-host-owners.py` (from the repository root,
after building both Rust binaries and the SwiftPM `arkdeck-agentd` and `arkdeck`
debug products) runs the real pair: both CLIs, restart, a foreign lock holder,
concurrent reads, the Swift daemon's own control-frame log, and a standalone
Swift daemon over the same directory in between as the positive control.
Swift children get a disposable `CFFIXED_USER_HOME`, so nothing installed is
opened. Installed activation follows the normal helper update.
