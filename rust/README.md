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

`cargo fetch --locked` needs read access to ArkForge's private repository: its
crates are taken from it at the revision `Packages/ArkDeckKit/Package.swift`
pins. Locally, `CARGO_NET_GIT_FETCH_WITH_CLI=true` lets Cargo fetch with your
Git credentials; CI fetches with the read-only deploy key the Swift lanes use,
present for that step alone (`scripts/ci/arkforge-cargo-fetch.sh`).
`python scripts/check-arkforge-pin.py --run-vectors` checks that the two pins
agree and reruns ArkForge's own wire and StepPermit vectors at that revision.

`arkdeck-agentd` is a binary; its unit tests (declared by `src/main.rs`) run in
parallel and start no child process. macOS has no `SOCK_CLOEXEC`, so a child
that `std::process::Command` spawns while another test is still making a socket
keeps it, bound and listening once it is, for as long as the child lives: a
released port or dropped listener stays held. A test whose path starts a child
— a compiler, a fake `hdc` run directly or through the daemon's HDC dispatch —
belongs in `tests/spawning`, which compiles the daemon's modules from their
sources and runs one test at a time (`turn()`), as do the integration tests
that listen or take a lock in their own process while spawning.

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

`doctor` also names what start-up recovery could not read, as Swift's report
does (TASK-XPA-014): one `runtime.jobRecordUnreadable` blocker per Job recovery
set aside, with the reason it gave, and, for a deep report,
`runtime.durableRecordsUnreadable` counting every undecodable record in the
index with a bounded sample of their identities
(`JobStore::unreadable_records`, Swift's `unreadableDurableRecords`, whose
sample stops at sixteen). Both come before the Catalog's findings, as in Swift;
recovery already answered the first, and only the deep report reads the ledger.
`tests/doctor_report.rs` reproduces every recorded report of Swift's `doctor`
corpus, the one naming an undecodable record included.

`arkdeck commands --output json` needs no daemon (TASK-XPA-018): it answers Swift's
registry projection (`CLIRegistryProjection`, published as
`openspec/contracts/cli-command-registry.yaml`) for exactly the leaves this CLI
serves, from `crates/arkdeck-cli/src/command_registry.json`, which
`CLIRustCommandRegistryCopyContractTests` holds to Swift's projection.
`crates/arkdeck-cli/tests/argv_fixtures.rs` replays the Swift argv fixture of every
served leaf, copied unchanged into `tests/fixtures/current-cli-argv`, and pins the
cases this parser still answers otherwise; TASK-XPA-018's `cli-parity-audit.py`
classifies the 256 coverage entries from these.

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
On macOS, `ARKDECK_RUNTIME_COMPOSITION=production` selects the
[production composition](#macos-production-composition-task-xpa-017-not-activated)
instead, which refuses `ARKDECK_ENDPOINT` and `ARKDECK_HDC_SHA256`; nothing sets
it before the M5 cutover.

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
`runtime tool select` is parsed and checked as Swift's CLI does and answered as
Swift's daemon answers it without a tool-selection owner (below); the selection
writes themselves and installed activation remain pending.

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
the Swift consumer. These checks do not activate the installed Runtime. Every
isolated host check (`check-*-register.py`, `check-*-list.py`,
`check-*-retirement.py`) works in one fresh `/private/tmp` run directory of
daemon logs, frames and reports (`rust/scripts/run-directory.py`): a passing run
removes it, a failed run keeps it and names it on stderr, and `--keep-run-dir`
keeps a passing run's directory too, for example to read its registry back
natively.

For an explicit native macOS check, build the candidate binaries in release mode
and run `python3 rust/scripts/check-deveco-register.py --bin-dir <release-dir>
--source-root /Applications/DevEco-Studio.app/Contents`. The harness works in a
fresh temporary registry, kept only after a failure or with `--keep-run-dir`,
checks restart/idempotence and verifies that installed
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

Before it serves, the isolated daemon sweeps its Artifact root once, as Swift's
daemon runs `collectGarbage` at startup (`collect_expired_artifacts`,
`artifact_retention.rs`). Outside the Jobs it keeps, a row whose deadline has
passed (`deadline <= now`, parsed as Swift parses it) and that is not pinned is
removed from its index first, then its payload is unlinked; a pinned or
undated row never goes, and nothing is evicted for quota. The sweep keeps more
than Swift does, never less: every Job the Job owner's census cannot prove
settled (`job_retention_census.rs`: not terminal, of unknown outcome, or a
terminal record or journal that does not verify), every Job the cleanup ledger
says still owes a cleanup, and each exact Artifact an active Job names as an
input lease. It prints `reclaimed N expired artifact(s)` when it reclaims
anything, and a failure (an unexpected root entry, a payload that no longer
verifies, an unreadable census or ledger) is printed and never stops the
daemon. `tests/artifact_retention.rs` and `agentd/tests/artifact_retention_process.rs`
check it over real Job owners and a real daemon.

A Job product is published in three steps: its payload under the derived name,
the payload sealed owner read-only, then the whole index rewritten. A process
killed after any of them leaves a consistent index, naming the product with its
sealed, verified bytes or not at all, and a quota that counts only what the
index names (`tests/artifact_publication_process_death.rs`, a real analyzer Job
run in a child process and SIGKILLed at each step through
`ArtifactReadStore::open_with_fault`). A retried publication recovers a payload
left before its index, sealing it first as Swift's `validateStoredPayload` does.

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
maintenance before any deletion. The Artifact census reads the whole store,
each directory listing bounded at 100 000 entries and the store as a whole not
at all. Artifact writers take only the census's lock, so a large store slows a
purge and never refuses a publication.
An inactive census permits only inode-bound
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
and digest functions. It also compiles in the shared Job-state preflight table
(design §G.4; `spec/recovery/job-state-preflight.json`, whose copy Swift's
`JobStatePreflightTableContractTests` records under
`rust/tests/fixtures/job-state-preflight/`) and its two classifiers:
`classify_restart`, `runtime service restart`'s carry-over of current Jobs as
Swift's `RuntimeCLI.classifyAgentdRestartCurrentJobs` decides it (replayed on that
oracle), and `cutover_preflight`, the M5 preflight over a state root's Jobs, agent
executions and capability uses. The Rust CLI's `runtime service restart` calls
the first; `arkdeck-agentd --cutover-preflight` decides with the second.
`arkdeck-control` has transport-free observation and local-resource handlers.
`arkdeck-platform` owns the unsafe OS boundary; all other crates forbid unsafe
code. `arkdeck-provider-hdc` lowers one fixed observation argv through that
boundary and holds the HDC typed actions of the device operations, which the
Job engine in `arkdeck-hoststore` lowers its device steps through. Its closed
Debug template lowering reads the template definitions from `arkdeck-contract`,
their single source, which `arkdeck debug template list` also discloses.
`arkdeck-client` owns same-connection health and refusal handling;
`arkdeck-cli` presents the current CLI envelope; `arkdeck-agentd` composes them.
`arkdeck-provider-workspace` is the workspace provider's signing and credential
layer and depends only on `arkdeck-platform`. `arkdeck-provider-arkforge` is the
ArkForge lane: it launches and pairs `arkforged` through the platform crate,
reads its release bundle through `arkdeck-contract`, and reaches it only
through ArkForge's own `arkforge-client`; no other crate depends on an ArkForge
crate.
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

Catalog patterns are evaluated as Swift's `text.range(of: pattern, options:
.regularExpression)` evaluates them (`catalog_pattern.rs`), for the syntax every
published catalog pattern uses. A string input outside its pattern is
`invalidInput` `input <key> does not match its catalog pattern`, an array item
outside it `input <key> contains an item outside its catalog pattern`; a pattern
outside that syntax is still refused as unevaluated. `input.tap@1`,
`input.long-press@1` and `input.swipe@1` are planned as Swift plans them (M2):
the evidence preflight's three steps, the gesture step, then the session's
finalization. The gesture's typed action is named from the inputs and the
provider context's clock (`HdcComposition::now`, Swift
`ProviderExecutionContext.nowUTC`), journaled with Swift's arguments and
lowered to the provider's `uinput` process. A frame older than the 1000 ms
freshness bound, or a point outside the frame, is refused before authorization
in Swift's words. `tests/pointer_input_plan.rs` replays every `job.plan` of
`rust/tests/fixtures/pointer-input/` against the planner, message included.
Submitting a gesture is still refused, because no Runtime capability is issued
yet.

## Job admission (TASK-XPA-014)

The isolated development composition answers `job.submit` as Swift
`RuntimeJobEngine.submitOwned` does under target control, for the operation it
plans. `JobAdmitter` decides a retry or a conflict from the idempotency index
before anything is materialized, checks a reviewed plan against the existing Job
or against the fresh materialized plan, and admits a read-only Job under the
catalog's default read-only policy and a device mutation as below. It then writes the admission
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

A device mutation that the catalog authorizes with a standing capability is
admitted under a Runtime capability, as Swift's `preauthorize` admits it (M2):
- **The device hold.** A session-scoped request (a gesture, or a
  screenshot-only capture) takes or refreshes this daemon's hold on its device
  for its client (`DeviceHolds`). While a hold is live, another client's
  mutation is `resourceConflict`.
- **The capability.** A capability the caller names is used as named. Otherwise
  the Runtime issues its own (`capability_policy.rs`):
  1. it checks every capability's uses on the Target binding for one without a
     settled outcome;
  2. it finds or installs the first live generation of
     `CAP-RT-POLICY-<fingerprint>-G<n>`, as the envelope Swift issues (a
     gesture's subject is its frame, for an hour and 2000 uses).

  The capability then passes `validateNewExecution`, or the submission is
  `admissionDenied` in Swift's words.
- **The Job.** It runs the request naming the capability and keeps the caller's
  as its original submission. It carries no admission evidence until a use is
  consumed, and nothing is consumed yet.
- **The storage state.** The admission proves that this owner's Job root and the
  Session root it publishes into are the account-fixed ones
  (`MutationAuthority::require_state`, through the Session owner's
  `runtime.storage.status`). Reading that status takes the storage owner's lock
  and the retention catalog's, so an admission leaves
  `session-owner/.session-storage.lock`,
  `sessions/.arkdeck-retention-catalog.json` and its lock where Swift's
  admission leaves none: Swift reads the Session root without them and writes
  exactly these bytes when it first publishes. A declared difference from
  Swift, in when the files appear and in nothing else (r11 §3, incidental
  side-effect files); the crash-window replay, whose Jobs never publish a
  Session, is where it shows.
- **Not served.** A descriptor without `defaultPolicyIssuance` counts as enabled,
  as Swift's generated catalog reads it. Destructive effects, the
  `runtimeCapability` policy and workspace subjects are still refused.

`tests/pointer_input_submit.rs` replays the pointer-input oracle's submissions:
the answers, the capabilities installed, each Job's request and original
submission, and the refusal after an unknown outcome.
`tests/debug_hap_submit.rs` does the same for `debug.hap@1`, whose capability is
also named by the entry package's owner-validated facts. An admitted HAP waits in
`preflight` for `job.run` (below); `agent.run` admits the HAP it starts at once.
`deploy.native-library.app-owned@1` is planned and admitted as Swift does
(`native_library_plan.rs`). Its HDC composition must carry the verified
code-sign helper the deployment stages (`HdcComposition::code_sign_helper`);
without one the operation is runtime unavailable. The daemon composes it as
Swift's `HDCNativeCodeSignHelperArtifact.bundled()` does (`code_sign_helper.rs`):
`arkdeck-code-sign-enable` from ArkDeckWorkflows' resource bundle beside this
executable, verified as an arm64 ELF the library validator accepts, carrying no
mutable input signature, and a static executable (`ET_EXEC`, a loadable segment,
no interpreter). An isolated development root may name one with
`ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER`, an absolute path whose bytes are
verified the same way, so the facts a deployment carries are that file's; the
standalone daemon and the facade refuse that variable at startup, as they refuse
every other development one, and a named helper that does not verify fails
startup. With no helper anywhere the operation stays unavailable with
`provider_tool_unavailable`, as before. Once the Target's facts hold, the library's lease (a Job Artifact or an
Import) is resolved and bound to them, its bytes are read, and each step's
action is named from them (`StepAction::Native`, claimed by the operation before
any step kind): the provider verifies them as the expected ABI's code-signed ELF,
still the byte count the lease records. Every provider step is lowered to its
process sequence with Swift's journal arguments, and the plan also holds the
rollback a failure past the publish applies. The library's facts name its
capability. `tests/native_library_plan.rs` and `tests/native_library_submit.rs`
replay the native-library oracle's plans and submissions; `job.run` runs the
admitted Job (below), and `agent.run` admits the deployment it starts at once.

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
is ported as the maintainer ruled on 2026-09-19 (design §L.1 item 13): the
carriers the ADR-0009 decision package names, unchanged. Before it serves, the
isolated daemon recovers its active Jobs (`job_recovery.rs`, Swift
`recoverActiveJobs` and `recover(records:)` over `RuntimeRecoveryService.replay`;
`recover_jobs` recovers named Jobs, a terminal one included, for its other
callers): each journal is replayed, every unresolved intent or unknown outcome is
parked (journaled `recovery-t-<n>` when the Job had left no recovery state),
only decisions the journal already holds are completed, the record gains its
`recovered: …` marker once and is persisted again (record, then index row), and
a runtime capability's use outcome is re-asserted; nothing is dispatched or
published. A record it cannot read is quarantined; an ArkForge execution and a
complete-overwrite recovery Job are refused untouched. `job.reconcile`
(`job_reconcile.rs`) reconciles a Job whose outcome is unknown against its
durable intent and never resends the original. An analyzer Job's source is
resolved again, and the provider confirms the intent not executed only for the
source it named. A device-bound Job's Target facts are resolved fresh and
validated, and its parked action is materialized again from its record
(`job_reconcile_device.rs`): an action below `deviceMutation` is confirmed not
executed, a pointer gesture has no dedicated readback and stays unknown, and a
mutation Swift reads back is read back once, lowered under the reconcile's own
step identity, and concluded completed, not executed or unknown — a port
rule's create or remove by `fport ls`, a debug HAP's staging, package and
ability by the owned path or directory, `bm dump` and `pidof`, a diagnostic
capture's owned file by `ls -ld`, and a native deployment's steps by its own
inspection, whose verdict table never calls a publish (`publish state is not
safe to replay`) or a rollback not executed. Two declared differences fix
Swift defects (the maintainer's rule of 2026-09-20: a Swift defect is fixed in
Rust and declared). Swift's materialization does not know the screen
sequence's capture and cleanup, so there a reconcile of either, once begun,
fails and the Job can never be concluded; here each is read back as a capture
file leg is, by `ls -ld` of what it owns (`ParkedScreenSequence`): the capture
completed when its archive is there, not executed when neither the archive nor
its frames directory is, and unknown — still parked, never resent — when its
frames remain without their archive; the cleanup completed when the frames
directory is gone and not executed when it is not. And a receive or cleanup of
a JPEG still is rebuilt with the still's own suffix, where Swift rebuilds the
`.png` the device never wrote and refuses the record. The decision is
journaled as Swift journals it, the correlated step outcome carrying
`confirmedNotExecuted` for a non-execution; the Job then fails and is
published as a Session, its capability use resolved `safeToReflash`; or waits
at its confirmed safe boundary, its use still `outcomeUnknown` until it
resumes; or stays parked. A debug HAP's record is durable before its decision,
and one confirmed not executed stays `finalizing` for its failure
finalization, which runs at once through the runner (`finalizeDebugHAPFailure`:
the compensations its succeeded steps declared, under the use it consumed), as
it does for a debug HAP a restart left `finalizing`, on `job.run` or
`job.reconcile`. As in Swift, the Session of a device-bound Job
reconciled before any of its steps confirmed a binding is refused
(`SessionManifestJournalValidator`: the decision's binding revision is not in
the Manifest's binding history). A terminal Job's capability outcome that a
crash lost is repaired from its journal's proof, on reconcile and before the
next device mutation's submission materializes (`job_lineage_repair.rs`), with
nothing dispatched; what a failed reconcile journaled stays resident in memory,
as Swift's engine keeps it. A terminal debug HAP whose lineage a repair would
write, a debug HAP parked on a declared compensation, on its compensation
identity proof or on a failure decision its journal already holds, and a Job
parked on a read-only action Swift's provider has no reconcile source for (a
presence readback, a crash index or log) are answered only where Swift writes
nothing, and refused otherwise, with nothing written or dispatched.
`tests/job_reconcile.rs`,
`tests/device_reconcile.rs` and `tests/readback_reconcile.rs` replay
`rust/tests/fixtures/job-reconcile-analyzer/`, `device-reconcile/` and
`readback-reconcile/` (Swift `testSwiftRecoversAndReconcilesTheParkedAnalyzerJobs`,
`DeviceReconcileOracleContractTests` and `ReadbackReconcileOracleContractTests`,
re-recorded with `ARKDECK_RUST_JOB_RECONCILE_RECORD`,
`ARKDECK_RUST_DEVICE_RECONCILE_RECORD` and
`ARKDECK_RUST_READBACK_RECONCILE_RECORD=/private/tmp/<new>`): every start,
reconcile, answer, read and store snapshot byte for byte, the capability store
and the fake's calls included; `tests/job_recovery.rs` and the other tests of
`tests/readback_reconcile.rs` cover the branches they do not reach.
`tests/crash_window.rs` replays `crash-window/` (Swift
`CrashWindowOracleContractTests`, `ARKDECK_RUST_CRASH_WINDOW_RECORD`) with this
runner killed at the four quadrants XPA-AC-7 names — before the consume, after
a read-only intent, after the consume, after the mutation intent — each in a
child of the test binary that exits where the window falls: the store the dead
run leaves is Swift's, and so are the two starts over it, the two reconciles,
the next admission and every read. The one leftover Swift does not share is the
Session owner's lock and an empty retention catalog, which this Runtime's
admission creates when its storage-state check reads the Session root and Swift's writes
only when it first publishes. `job.run` resumes a device-bound Job as Swift's
`runOwned` does (`job_run.rs`, `device_run.rs`): at the confirmed safe
boundary a reconcile reached (`resumeAtConfirmedSafeBoundary`), from `running`
once a restart found nothing outstanding, and a debug HAP's failure
finalization from `finalizing`. The journal must stand exactly at that
boundary — no torn tail, no outstanding intent, no unknown outcome, a confirmed
decision — or nothing is dispatched; every step the journal confirmed
succeeded is skipped (`resume skipped journal-confirmed step …`), host steps
run again, and a resumed Job continues under the capability use it already
holds, which the capability store must still hold unsettled for it
(`mutation_execution.rs`, stricter than Swift, which reads the record alone),
consuming no second one; a Job resumed before it consumed one consumes it as
a first run does. An analyzer Job is still run from `preflight` only. In the
daemon a `job.run` of a Job whose reconcile is under way waits it out, so a run
and a reconcile never drive one Job at once.
`tests/device_mutation_reconcile.rs` replays
`rust/tests/fixtures/device-mutation-reconcile/` (Swift
`DeviceMutationReconcileOracleContractTests`,
`ARKDECK_RUST_DEVICE_MUTATION_RECONCILE_RECORD=/private/tmp/<new>`): five
scenarios over the shared fake whose HDC calls die on SIGKILL before or after
the device changed — a port rule, three debug HAPs, two native deployments,
two screen sequences and three component tree captures, reconciled and
resumed, a cleanup debt continued — and three whose daemon died mid-run,
reproduced by a child of the test binary exiting at the same window: a tap
before and after its consume, resumed from `running`, and a debug HAP whose
failure finalization a restart left for `job.run` to continue; every answer,
store snapshot and leftover byte for byte, but the frames of the parked screen
sequence capture, which the test marks as declared differences (Swift's
reconcile fails `internalError` and leaves the Job `reconciling`; the Rust one
reads it back and keeps it `waitingForRecovery`). Rust-only scenarios there
conclude a screen sequence capture and cleanup the probes do settle, and a
JPEG still's receive, cleanup and cleanup debt, which Swift refuses. Also landed: `recovery_manifest.rs`, Swift's
`RecoveryManifestCodec` (the Session manifest's `recovery` member, which the
Session reader now decodes through it before checking its relations to the
Session's steps); its unit tests replay `rust/tests/fixtures/recovery-manifest/`
(Swift `RecoveryManifestOracleContractTests`, re-recorded with
`ARKDECK_RUST_RECOVERY_MANIFEST_RECORD=/private/tmp/<new>`): every decision and
canonical byte, and one member more or less written by Rust at each level as the
document Swift refused. Nothing writes a non-null member, in Swift or here.
Concurrent runs of one Job join its one run, as Swift's callers do.

A device-bound Job whose exact inputs select a step at or above
`deviceMutation` runs in its Target's mutation lane (`device_lane.rs`, Swift
`DeviceMutationLaneCoordinator.withMutationLane`), which the Target owner keeps
in memory for every composition over it: one such Job per Target at a time, the
others waiting in arrival order with no deadline; other Targets are not held
up, and read-only and host-only Jobs take no lane. The lane is keyed by the
request's Target, a proven post-Flash alias folded into its canonical Target
(Swift keys by the name alone). A Job enters it before its running transition,
so nothing is written while it waits, and holds it through its step loop, a
debug HAP's failure finalization, finalization, its terminal state and the
settling of its capability use (Swift enters after the transition, lets go
after the step loop and enters again for the failure finalization). A debug
HAP finalizing on `job.run` or `job.reconcile` holds it for its compensations
(a reconcile's read-only readback takes none), and a cleanup debt's
continuation holds it for its readback and retry (Swift's takes none). A
request to cancel a waiting Job closes it at its first step boundary with
nothing dispatched and nothing consumed; the lane's guard lets go of it on
every exit, a panic included. `tests/device_mutation_lane.rs` runs gestures on
the shared fake with two adopted Targets (one after another on one Target, at
once on two, cancelled while waiting, the lane let go of after a failure, a
park and a panic), and `tests/device_mutation_reconcile.rs` replays its
scenarios with the Target's lane held around a reconcile, two resumed runs and
a cleanup debt continuation, every answer and snapshot still Swift's.

`arkdeck job run --job <id>` prints the Job's status and exits as Swift's CLI
does: 1 for a failed, cancelled or interrupted Job and 75 for an unknown outcome.
A connect failure stays `runtimeUnavailable`; a reply that cannot prove zero
dispatch is `outcomeUnknown`.

`debug.hap@1` runs through the HDC composition as Swift's `executeSteps` and
`dispatchWithWAL` run it. Its packages are resolved from their leases again
before each step given them (every package for the send, the entry package for
the install and each approved remote read), each still bound to the Target,
binding revision and identity the plan bound; a step dispatches its whole plan, a
process sequence included; an install and a start succeed as dispatches that
only the required readback after each may believe; and the send, install and
start intents declare the compensation that undoes each. The Job consumes one
capability use before its first mutation's intent. Each later mutation, and
each compensation, continues under that use once the mutation state, the fresh
plan and the Target facts are proven again; a compensation also proves the use
is still the Job's own, unsettled and authorized (`validateContinuation`). A run
continues only a use it consumed itself, and settles only that one. A required
failure is compensated as Swift's `performDebugHAPFailureFinalization` does: the
compensations the succeeded steps declared run latest first, a cleanup already
attempted is never sent again, a failed cleanup is owed in the Artifact root's
`cleanup-debt.json` with the exact action that failed (an optional one is owed
and skipped on the normal path), and the Job fails with its original failure; a
lane that cannot conclude parks the Job. `job.result` and `job.evidence` read
these Jobs, their step kinds those the journal proves (Swift
`durableActualStepKinds`). `tests/debug_hap_run.rs` replays the whole
debug-hap oracle, its debt lists and continuations included: every answer, the
fake's 108 calls and every file byte for byte. Continuing a parked or
`finalizing` HAP follows the recovery port (L.1 item 13, ruled 2026-09-19).

`deploy.native-library.app-owned@1` runs as Swift runs it (`device_native.rs`).
`verify-elf-locally` and `hash-library` verify the leased library on the host
(`verifyHostInputArtifact`): resolved again, the expected ABI's code-signed ELF,
still the digest and size its lease records. Each device step resolves the lease
again and reads the library before its Target facts, and runs only against facts
that still name the identity and binding the plan was materialized for
(`validateMaterializedTargetFacts`). The send succeeds as a dispatch that only
the staging readback after it may believe (the readback pairs are Swift's whole
table), and the publish and the loader readback publish `publish-report.json`
and `verification-report.json`. The Job consumes its one use before the send;
every later mutation continues under it. A required step's confirmed failure is
compensated inside the step loop (`compensateNativeLibrary`): with the Target's
facts proven again, `rollback-native-library` restores the backup once the
publish was attempted, then `cleanup-native-library-compensation` removes what
the deployment staged. Both are ordinary steps of the Job that consume nothing;
a failed rollback is the Job's failure, a failed cleanup is owed, and otherwise
the Job fails with its original failure. An optional cleanup that fails is
skipped and owed with the exact action that failed (`recordCleanupDebt`: a
plain append, not deduplicated), the Job's residue is counted again, and the
Job succeeds. `job.result` and `job.evidence` read these Jobs.
`tests/native_library_run.rs` replays the whole native-library oracle through
`tests/support/hdc_oracle.rs`, which the debug HAP replay shares: every answer,
the debt's list and continuation included, the fake's 225 calls and every file
byte for byte; three faulted runs cover a failed rollback, a failed
compensation cleanup and one whose outcome is lost. The daemon composes no
code-sign helper, so the isolated daemon lists the operation as unavailable
and plans none.
`tests/native_library_run.rs` replays the native-library oracle but its debt
continuation and the list after it through `tests/support/hdc_oracle.rs`, which
the debug HAP replay shares: every answer, the fake's first 210 calls, the four
Jobs the continuation leaves alone byte for byte and the continued one and the
ledger as they stood before it; three faulted runs cover a failed rollback, a
failed compensation cleanup and one whose outcome is lost.

`cleanupDebt.list` reads the ledger as Swift's daemon lists it
(`listCleanupDebt`, `encodeCleanupDebt`): every record not settled, ordered by
Job, remote path and when it was owed, each with its residue's identity and
whether a retry of it ever started; a ledger that cannot be read or decoded
fails the whole list with Swift's store error, and nothing is written.
`cleanupDebt.continue` (`cleanup_debt_continue.rs`) continues one debt as
`continueCleanupDebt` does. A terminal Job, which Swift's engine no longer
holds, is loaded through `recover_jobs` (its record marked `recovered: journal
clean`); a Job whose outcome is unknown is answered without a write. The debt's
persisted action is materialized again (`HapAction::from_persisted`,
`NativeAction::from_persisted`; a JPEG still's cleanup with the still's own
suffix, a declared difference) and must name its residue; a refusal is answered
`internalError` with Swift's interpolation of the provider error, its detail
alone. A read-only readback
judges the residue first: gone settles the debt, inconclusive leaves it owed.
Only a residue still present is retried, once: the retry is made durable in the
ledger before it is sent, dispatches under the use the Job consumed (the
persisted-evidence arm, `continue_held_use`; nothing new is consumed), and
settles the debt, leaves it owed, or keeps its outcome unknown so that it is
never resent. A settled debt refreshes the Job's residue count; the Job's
journal is not written. The daemon answers both methods from its Artifact and
Job owners. The device oracles' lists and continuations and the committed
corpus are replayed through them, and `tests/cleanup_debt_continue.rs` covers
what no oracle records.

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
proof). The superseding recovery epochs are read as Swift reads them for every
snapshot, through `recovery_epoch.rs` (Swift `RuntimeSupersedingRecoveryStore`,
ported unchanged as design §L.1 item 13 was ruled on 2026-09-19): an unreadable
document, and an epoch that names the Job as the Job that recovered (a
`recoveryEpoch` the published schema still pins to null), degrade the evidence to
`recordUnreadable`; any other store leaves it whole. `tests/recovery_epoch.rs`
replays `rust/tests/fixtures/recovery-epoch/` (Swift
`RecoveryEpochOracleContractTests`, re-recorded with
`ARKDECK_RUST_RECOVERY_EPOCH_RECORD=/private/tmp/<new>`): 32 appends, lists and
refusals, each root's files byte for byte. Nothing in Rust appends an epoch yet;
the writers are on the M4 flash path.

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
`job.reconcile` publishes a Job's Session once it confirms the parked intent not
executed (see Job run).

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

`arkdeck job cancel --job <id>` and `arkdeck job reconcile --job <id>` send the
opaque identity as Swift's CLI does, print the answer and exit 0. A reconcile's
answer is the Job's status, and an outcome it leaves unknown is that answer, not
a failed request. Swift classifies both methods as mutation-capable, so without
the zero-dispatch proof `notFound` is `resourceNotFound`, `invalidParams` is
`invalidInput`, `rejected` and `internalError` are `outcomeUnknown` (75), and so is
a reply lost after the request went out, which is never resent; a connect failure
stays `runtimeUnavailable`.

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
unknown one. A read writes nothing but the lock file.

`CapabilityStore` also writes the store as Swift's does, for the M2 admission
the Rust owner has yet to serve; nothing in the daemon calls these writes yet.
`install` appends a capability with its whole budget and writes the checkpoint
atomically in Swift's `canonicalPretty` spelling, then empties an existing
ledger, only once the checkpoint holding its events is durable. `consume`
reserves one use after `validateNewExecution`: a device or workspace subject, a
materialized plan digest, no earlier use left unsettled, the scope of the
lineage's first use, then `authorizes`'s denials in Swift's order.
`recordOutcome` settles a pending use. Each receipt and outcome is digested
into one hash-linked lineage per capability and appended to the ledger as one
event, fully synchronized; the event after 128 is folded into a new checkpoint
instead. Retrying a reservation answers its receipt and writes nothing. A
drifted retry, a second pending use and a change to a recorded outcome are
refused, except the one change Swift permits (`resolvesUnknown`, ported as
design §L.1 item 13 was ruled on 2026-09-19): an `outcomeUnknown` use settled
`confirmed` or `safeToReflash` by a later readback, appended after it.
`tests/capability_write.rs` replays the stores the M2 oracles leave
(`pointer-input`, `port-forward`, `debug-hap`, `deploy-native-library`,
`screen-sequence`) and Swift's `capability-resolve` store (two uses left
unknown, then resolved) through these writes, checkpoint and ledger byte for
byte, and checks the refusals over synthetic capabilities and the resolved
store.

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

## Device observation (TASK-XPA-014, SPK-7)

The isolated development composition plans, admits, runs and reads
`observe.device@1` as the Swift engine does, when it is given a development
HDC: `ARKDECK_DEVELOPMENT_HDC_PATH` names a fixture executable, pinned by its
digest at startup, and is accepted only beside
`ARKDECK_DEVELOPMENT_STATE_ROOT`. A registered HDC executable is refused there,
because it would address a real server and device, unless the owner also
starts it as its managed server (`ARKDECK_DEVELOPMENT_HDC_SERVER=managed`,
below). Facts come from the Target
owner's adopted record (`<root>/targets-state/targets.json`): the connect key,
the identity it names, the revision and the tool version. `job.plan` binds that
identity and revision into the plan digest; `job.run` dispatches each step
through `arkdeck-provider-hdc`'s `ProcessDispatch`, the `HdcDispatch` every HDC
plan takes on the verified tool runner, with its typed action persisted and its
write-ahead intent durable first, proves the evidence preflight
(target, model, firmware), publishes `tool-facts.json`, `device-facts.json` and
`binding-snapshot.json`, and publishes a device Session; `job.result` and
`job.evidence` carry the evidence observation. A step whose outcome cannot be
observed parks the Job with its intent outstanding.

`rust/tests/fixtures/observe-device/` is the oracle Swift
`ObserveDeviceOracleContractTests` records over the fake HDC every HDC oracle
shares (`HDCOracleFake`: one driver at `/private/tmp/arkdeck-hdc-oracle/hdc`,
answering from the oracle's `hdc-answers.sh` in the mode `hdc-mode` names).
`tests/observe_device.rs` replays it in-process on the oracle's clock and
compares every answer and every file the Jobs leave. Re-record from Swift with
`ARKDECK_RUST_OBSERVE_DEVICE_RECORD=/private/tmp/<new>`.

`scripts/check-corpus-replay.py` replays any oracle in this format against the
real daemon: it installs the fake under its lock, seeds a fresh isolated root
from the oracle, replays every exchange the daemon serves over its socket at T1
(times and Swift's wording as labels), checks the fake's calls, restarts the
daemon and reads every Job again, and reads through the Rust CLI:

```bash
cargo build -p arkdeck-agentd -p arkdeck-cli
python3 scripts/check-corpus-replay.py --fixture tests/fixtures/observe-device
python3 scripts/check-corpus-replay.py --fixture tests/fixtures/capture-diagnostics
python3 scripts/check-corpus-replay.py --fixture tests/fixtures/capture-diagnostics-read-legs
python3 scripts/check-corpus-replay.py --fixture tests/fixtures/agent-execution
python3 scripts/check-corpus-replay.py --fixture tests/fixtures/agent-lifecycle
python3 scripts/check-corpus-replay.py --fixture tests/fixtures/trace-probe
```

## Diagnostic capture (TASK-XPA-014, M1)

`capture.diagnostics@1` runs through the same composition, for the legs Swift's
default selects. The host storage preflight asks the Artifact store for the
room the capture may take (the request's `totalArtifactByteBudget`, else the
operation's 512 MiB), then come the evidence preflight, the device's free space
(`shell df -k /data/local/tmp` against the job byte budget, 128 MiB unless the
request sets one), the HiLog drain (`shell hilog -x`; the window bounds only
its timeout, the budget is 16 MiB) and the window inventory (`shell hidumper -s
WindowManagerService -a -a`), each with Swift's typed action and verdict; their
raw bytes become `hilog.txt` and `ui-dump.json`, within the job byte budget. An
optional step the request did not select, or whose upstream did not run, is
recorded as skipped, and every product it owned as missing, with the reason; an
optional step that fails is skipped with its failure and the Job goes on; an
empty HiLog drain is an unknown outcome and parks the Job, optional or not.
Finalization publishes `capture.log` (the timeline), `markers.json`,
`artifact-index.json` and `capture-summary.json`, which states every declared
product's status, so a partial capture never reads as a whole one.
`job.result` and `job.evidence` accept as missing only the products the request
left out.

Every other leg runs too, with the provider's `FileAction` (below): the
component detail dump, the Faultlogger index and one entry of it, and the
application liveness readback, whose facts become `application-liveness.json`;
the component tree and the screenshot, each written to an owned path, read back,
received under the composition's host receive root and removed, a refused
removal owing a cleanup debt; and the Trace legs, blocking or as an armed ring
whose held coverage anchor the record keeps (`ringCoverage`) and `markers.json`
reports. A Trace capture's steps are bracketed by two snapshots of the trace
tool and its parameters (`device_trace.rs` over `trace_probe`): the first must
name the Target, a capture-eligible `hitrace` offering every requested tag and
the whole parameter catalog before any step runs, the second is taken whatever
the steps ended with, and the index and summary report what both read. A
composition without a receive root plans every leg but a receive.

`rust/tests/fixtures/capture-diagnostics/` is Swift
`CaptureDiagnosticsOracleContractTests`' oracle over the shared fake: a capture
that succeeds, one the device's free space refuses, one on another device and
one whose HiLog drain comes back empty. `capture-diagnostics-read-legs/`,
`capture-diagnostics-file-legs/` and `capture-diagnostics-trace/` are the
`CaptureDiagnostics{ReadLegs,FileLegs,Trace}OracleContractTests` oracles of the
other legs, with their failures, unknown outcomes and refusals.
`tests/capture_diagnostics.rs` replays all four in-process and compares every
answer and every file the Jobs leave; the harness above replays the default and
read-leg oracles against the real daemon (a file leg needs the development
mutation authority and names the daemon's own receive root).

## Agent executions and Artifact lists (TASK-XPA-014, M1)

The isolated development composition answers `agent.run`, `agent.status`,
`agent.list` and `agent.abandon` as the Swift daemon's
`RuntimeAgentExecutionCoordinator` does for an explicit target, and
`artifact.list` for a Job owner. `AgentExecutionStore`
(`agent_execution.rs`) keeps each execution as Swift's record,
`<root>/agent-executions/execution-<sha256(executionId)>.json` (owner-only,
canonical JSON, one more generation per durable step), beside the
`snapshots/` directory where its pager keeps the list's pages. A run parses the closed intent with
Swift's messages and fingerprint, validates a new execution's inputs against
the Catalog and creates it with its orchestration deadline; the same identity
under another intent is `idempotencyConflict`. The execution then resolves its
target (a target never adopted is `resourceNotFound` and a stale revision
`bindingRevisionStale`, both leaving the execution orchestrating), prepares the
exact typed Job request (`agent-request-<seed>` and `agent-execution-<seed>`,
the seed being `sha256(executionId)`), submits it through the Job admitter and
answers once it owns the Job. The Job runs in the background as Swift's
`startJob` runs it, registered with the daemon's runs before the answer, and
the execution records the Job's end when the run returns (Swift `finishJob`).
A status read, like a run of an execution that already owns its Job, answers
from the record and the Job without a write; once the Job is terminal the
answer carries its evidence and verified Artifacts. Refusals before a Job carry
the zero-dispatch proof.

`agent.list` pages every execution's stored projection without its physical
action (`createdAtDescExecutionIdAsc`, 1 to 1,000 per page, 100 by default),
filtered by state, operation or resolved target, through Swift's
`RuntimeSnapshotPager`: a first page stores the whole listing under a random
revision in `agent-executions/snapshots/`, and a cursor names one of its pages,
never a new scan. The owner serializes every request, so, as in Swift, the pager
keeps no lock file there. `agent.abandon` takes the execution and the
generation its caller read. An execution that owns a Job, or whose accepted
submission the Job owner holds, is `resourceConflict` with its `jobId`, since
abandonment never cancels a Job, and so is a changed generation; an execution
still orchestrating becomes `abandoned` in one more generation, and a terminal
one is answered as it is, without a write.

An execution that waits for a person, as the runbook's §2.1 path leaves one, is
read, listed, run again and abandoned as Swift's owner does. Its record keeps
Swift's physical-assistance actions (`connectDevice`, `trustDevice` or
`selectDevice`, each `waiting`, `resolvedByFreshProbe` or `expired`), checked as
Swift's `validate` checks them: at most one waits, the last, exactly while the
execution does, and only a device selection offers choices. Its answer carries
the waiting action (`arkdeck.human-action/1`) and a `nextAction` naming it with
its resume reference; a list item leaves the action out. Running it again only
reads its budget, and an abandonment, like a budget that runs out, expires the
action in the same write.

`artifact.list` pages a Job's Artifacts as Swift's `RuntimeSnapshotPager` does
(`createdAtDescArtifactIdAsc`, cursors `<revision>.<token>`, 1 to 1,000 per
page, 100 by default); the snapshots live with the Job owner
(`jobs-state/cli-job-snapshots`), not in the Artifact root.

An execution that names no target, for an operation that binds a device, takes
one observation through the Target observation owner and, when a person must
act, raises Swift's action: `connectDevice` for no device, `selectDevice` for
several, and `trustDevice` or `connectDevice` naming the one observed device
that is not authorized and connected. A connected device whose physical identity
is unproved is refused with `admissionDenied`; one whose identity is proved is
adopted through the observation owner before the Job is made.
`human-action.list` and `human-action.show` are the combined human-action
owner's (`human_action.rs`, paged in `human-action-snapshots`), over the
executions' actions and the control actions' impact approvals. `agent.resume`
and `human-action.resume` continue an execution's action through fresh
observations and guarded adoption; a control action's approval is looked up
first and answered as Swift's daemon answers a request outside a foreground
console (the control-action section below). A restart leaves an owned Job as it
is: nothing resumes a run (L.1 item 13).

`rust/tests/fixtures/agent-execution/` is the oracle Swift
`AgentExecutionOracleContractTests` records over the shared fake HDC with the
daemon's coordinator: Golden Journey 1's two runs, their reads and Artifact
pages, and the refusals. `tests/agent_execution.rs` replays it in-process and
compares every answer and every file the executions and Jobs leave; re-record
from Swift with `ARKDECK_RUST_AGENT_EXECUTION_RECORD=/private/tmp/<new>`. The harness above
replays it against the real daemon: it holds and releases the owned Job's first
call as the oracle does, compares a listing's pages without the order of their
items, which follows the daemon's clock, and reads every execution again after
the restart.

`rust/tests/fixtures/agent-lifecycle/` is Swift
`AgentLifecycleOracleContractTests`' oracle for the list and abandonment: three
executions as `agent run` leaves them, their list page by page and by filter,
the refused list requests, the abandonments and their refusals, and the
abandoned execution read, run again and listed. `tests/agent_lifecycle.rs`
replays it in-process and compares every answer and every file, the list's
snapshots by their existence and mode; the harness replays it against the real
daemon.

`rust/tests/fixtures/agent-human-action/` is Swift
`AgentHumanActionOracleContractTests`' oracle for the §2.1 path: executions
that name no target, the actions they raise, their resumes and the human-action
routes. `tests/agent_human_action_records.rs` seeds its execution records, the
identities the oracle labelled (`<har-1>`) read as valid ones of their kind, and
answers them as the oracle recorded: the waiting execution read, listed, run
again and abandoned, and the abandoned one run again.
`tests/agent_human_action_raise.rs` replays, in recorded order over the shared
fake, the 19 exchanges that need no adoption, resume or Job: the raises, the
reads, and the list and show refusals. Replaying the rest waits for the resume
path.

The Rust CLI runs them as the Swift CLI does. `arkdeck agent run --operation
<reference> --target <id> [--expected-binding-revision <n>] [--inputs-file
<path>] [--execution-id <id>] [--maximum-wait <duration>] [--timeout <duration>]`
(or `--request-file <path>`) builds the execution intent and checks it before
anything is sent, sends `agent.run`, and reads `agent.status` at 100 ms doubling
to 2 s until the execution settles; `--timeout` bounds only its own wait. A
completed run prints its execution and exits 0, 1 for a failed, cancelled or
interrupted Job, 2 for evidence that could not be verified and 75 for an unknown
outcome; a run that stops before its Job exits with the execution's failure
code. `arkdeck agent status --execution-id <id>` reads one execution; `arkdeck
agent list [--state <state>] [--operation <reference>] [--target <id>]
[--page-size <n>] [--cursor <cursor>]` pages the executions; `arkdeck agent
abandon --execution-id <id> --expected-generation <n>` abandons one that owns no
Job; and `arkdeck artifact list --job <id> [--page-size <n>] [--cursor
<cursor>]` pages a Job's Artifacts. An execution identity is checked before
anything is sent. Every execution answered and every Artifact page is checked
as the Swift CLI checks it, and an execution page is passed on as the Runtime
answers it. A page is a bounded read; an abandonment is a mutation, so a refusal
without the zero-dispatch proof, or a lost reply, is an unknown outcome (75).

`arkdeck runtime hdc status` reads `runtime.hdc.status` as the Swift CLI does:
no parameters and no options of its own, a bounded read emitted as the Runtime
answered it, exiting 0 whatever availability the status reports.
`crates/arkdeck-cli/tests/runtime_hdc_status.rs` replays Swift's argv fixture and
serves every answer of Swift's frame corpus to the actual CLI through the fake
Runtime in `tests/support`, which the later HDC control-action CLI tests share.

`arkdeck runtime hdc impact-preview --action restart --server-endpoint-ref <ref>
--expected-server-generation <n> --action-request-id <id>` and `arkdeck runtime
hdc restart --control-action <id> --preview-id <id> --preview-digest <sha256>`
follow Swift's registry grammar, then its handler's checks before any
connection (an exact restart intent, or one exact preview tuple, else
`invalidInput`), and emit the Runtime's answer as it gave it. Both are
mutations: a refusal without the zero-dispatch proof, or a lost reply, is an
unknown outcome (75), and both methods' published details admit no proof. A
restart answers `awaitingImpactApproval`; the approval is `human-action
resume`'s at Swift's interactive console, which this CLI answers
`humanActionRequired`. `crates/arkdeck-cli/tests/hdc_control_actions.rs`
replays Swift's argv fixtures and serves the recorded preview, restart and
refusals to the actual CLI.

`arkdeck control-action list [--kind hdcLifecycle] [--state <state>]
[--page-size <n>] [--cursor <cursor>]`, `arkdeck control-action show
--control-action <id>` and `arkdeck control-action reconcile --control-action
<id>` read and reconcile the control action a restart creates, as the Swift CLI
does: Swift's registry grammar, an exact identity checked before any
connection, and the answer emitted as the Runtime gave it. Swift classes all
three as mutation-capable, so a refusal without the zero-dispatch proof, or a
lost reply, is an unknown outcome (75). `crates/arkdeck-cli/tests/control_actions.rs`
replays Swift's argv fixtures and serves the recorded show, list, reconciliation
and refusals to the actual CLI.

## Target presentation owner (TASK-XPA-012)

The explicitly isolated development composition owns `targets-state/` and serves
`target list`, `target show`, `target display-name set|clear`, and
`device display-name set|clear`. Target bindings and alias history are validated
and read. Only an adoption of a new Target (below) writes `targets.json`. Local
names use the current Swift `target-display-names.json` format, private
descriptor-anchored locks and atomic publication. Every transaction waits for
both locks, as Swift's blocking `flock` does, so a concurrent one (another
thread, owner or process) delays it rather than refusing it. Target names
survive restart; candidate names require the current Runtime observation
reference and expire on refresh or restart. A lost or invalid name-write reply
is `outcomeUnknown`; the CLI never replays it.

With the development HDC, the daemon answers `device.observations` (following a
reference too) and `target.adopt` through the owner below. Beside the registered
HDC the isolated owner starts as its managed server, its USB relations are the
Runtime's own (`UsbRegistryRelations`, "Trusted USB relations" below); beside a
fixture it reads none, so a fixture's candidates are proved and adopted only
when the isolated development owner names a development source:
`ARKDECK_DEVELOPMENT_USB_RELATIONS`, an absolute path beside the development
HDC's fixture (beside a registered one, in place of the Runtime's own and only
as the HDC runtime status section below says), read on every call
(`{"relations": [...]}`, with `"after": {"reads": n, "relations": [...]}` for a
replug the oracle times by its reads). A host composed with relations
(`Host::with_usb_relations`) proves and adopts as Swift does. Candidate display
names stay on the provider snapshot's path until Swift's coordinator is recorded
for them, so with the development HDC they find no current snapshot
(`resourceConflict`). Without the development HDC, observations keep the
read-only provider's path. The daemon writes no alias history, but routes a
Target with a proven post-Flash alias as Swift's `hdcExecutionRoute` does
(`TargetDocument::hdc_route`, `TargetStore::hdc_route`, TASK-XPA-013): every
completed reading is kept for five seconds as the live candidate list; while it
is fresh the Target's HDC commands, and the identity an HAP or native-library
Import binds, use the sole Connected key of the Target's own and its alias's,
refusing none or both, and otherwise the alias's key.
`target.show` leaves the absent Bootstrap warm presentation and confirmed
Job-observation sources as `null`. Existing adopted names can be projected onto
actually observed provider addresses.

`TargetObservations` (`target_observation.rs`, TASK-XPA-014) is Swift's
`TargetObservationCoordinator`. Every device list is bracketed by two reads of
independently observed USB relations: lane B's `Reading`, over an `HdcDispatch`
and a `UsbRelations` port. An observation keeps its identity only while an
unchanged proved relation carries it. The fact generation advances only when the
facts change, and that expires the candidate names. A reference is followed only
while it still belongs to the snapshot. `adopt` adopts the device of one exact
current observation whose relation still holds through the tool version, the
identity readback and a final relation read. Its refusals carry Swift's codes:
`targetTrustPending`, `admissionDenied`, `factsDrifted`, `resourceConflict` and
`operationUnavailable`.

`TargetStore::adopt_observed_candidate` writes the adoption in one transaction:
1. It materializes the Target: an alias's canonical Target, the Target with the
   same identity, or `TGT-` and twelve digits at revision 1.
2. It stages the candidate's name onto the Target.
3. For a new Target only, it writes `targets.json` in Swift's encoding.
4. It finishes the candidate names.

The snapshot, the generations and the receipts live in memory, as in Swift.
`tests/target_adoption.rs` replays Swift's `TargetAdoptionOracleContractTests`
(`rust/tests/fixtures/target-adoption`) byte for byte: its answers, the fake's
calls, `targets.json` and the display names. `target_observation_control.rs`, in
agentd's `tests/spawning`, replays the same fixture through `Control` with the
daemon's own host, on the host's clock, so every time there reads as `<time>`.

`rust/scripts/check-target-resources.py --swift-target-store <fixture-directory>`
checks actual Rust endpoint/CLI behavior from bytes exported by the Swift contract
producer; `--cli-path` selects a current Swift consumer. The fixture is explicitly
simulated host-test data. Run it after current Swift producer recording and schema
generation; it checks typed refusals as well as CAS, restart and binding-byte
preservation. No hardware acceptance is claimed by this harness.

The Rust CLI's `target adopt --candidate <key> --observation <id>
--observation-generation <n>` and `target availability --target <id>` are
Swift's leaves (TASK-XPA-014). An adoption is a mutation: its answer must be
exactly the receipt of that observation (`adopted`, a Target, a positive binding
revision, and the request's observation and generation), or it is
`outcomeUnknown` (75) and never replayed. A Runtime refusal keeps its code
(`resourceConflict`, `targetTrustPending`, `admissionDenied`, `factsDrifted`,
`operationUnavailable`) only with the pre-admission zero-dispatch proof. The
generation follows Swift's positive-integer grammar, so a leading zero is a usage
error that is never sent. Availability is one bounded read of the Runtime's
aggregate, emitted as it answered. `crates/arkdeck-cli/tests/target_adoption.rs`
replays Swift's argv fixtures and serves every answer of the Target adoption
oracle to the actual CLI.

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

## HDC process dispatch (TASK-XPA-016, SPK-6)

`arkdeck_provider_hdc::ProcessDispatch` implements lane A's `HdcDispatch` over
`VerifiedTool::run_tool` as Swift's `DescriptorBoundProcessDispatcher.hdc(resolver:)`
dispatches: a plan's arguments and budget, no working directory, the runner's
clean base plus `OHOS_HDC_SERVER_PORT` only when the daemon inherited a valid
port. An exited child is a receipt with its real exit status, both streams and
whether either went past the capture; a timeout or a signal death leaves the
outcome unobservable (Swift's wording); a refused budget, environment or
identity means nothing ran. It never gates a dispatch on the server lease.
`tests/process_dispatch.rs` drives it with shell scripts and the shared fake HDC
driver. The isolated development owner dispatches its fixture HDC through it
(TASK-XPA-014), and so do the `observe.device@1` and agent execution replays.

## Managed HDC server (TASK-XPA-016, SPK-6)

`arkdeck_platform::ManagedServer` launches a verified tool through its retained
inode in its own group with no budget, records its launch from the kernel
while the child is still suspended (PID, birth, canonical path, digest, argv —
read before the child can run, so a server that ends at once is reported as
its exit, never as a launch that could not be recorded), captures both
streams up to a limit, says how it ended and stops it. `arkdeck_provider_hdc::ManagedHdcServer`
owns an HDC server with it as Swift's `HeadlessHDCServerHost` does: `hdc -s
<endpoint> -m` with the server port named, the loopback listener reachable
first (never `checkserver` first), `checkserver` exit 0 with agreeing versions,
then the listener's owner proved to be the launched process by
`LoopbackServerLease` and the same birth; a reachable listener of another
process, however exact, is `Unbound`. `tests/managed_server.rs` in both crates
drive it with shell scripts and a fake `hdc` compiled from C at test time; no
real HDC is launched.

## HDC lifecycle executor (TASK-XPA-016, SPK-6)

`arkdeck_provider_hdc::{LifecycleAction, LifecycleCommand, PreparedLifecycle}`
is the process part of Swift's `HDCProcessLifecycleExecutor`: the exact
`hdc -s <endpoint> kill -r` / `kill` argv as the actual command an audit
records before anything is prepared, `VerifiedTool::launch_identity()`
(`/.vol/<dev>/<ino>`, device, inode, size, mode, digest) as the launch-window
entry it records before the launch, one launch per preparation through the
verified tool runner (15 s), and the post-dispatch re-observation through
`LoopbackServerLease` (12 s, every 100 ms) that alone decides the outcome — a
restart is `Succeeded` only with a strictly newer server generation, a stop is
`Stopped` only with nothing at the endpoint, and a nonzero exit, a registered
failure, stderr or an unprovable state is `OutcomeUnknown` with Swift's
reason. `tests/lifecycle.rs` drives it with a fake `hdc` compiled from C whose
`kill -r` client starts a new server of the same executable.

## HDC runtime status (TASK-XPA-016, M1)

`arkdeck_provider_hdc::HdcStatusObserver` is Swift's
`HeadlessHDCStatusObserver`, the object `runtime.hdc.status` answers with
(`arkdeck.runtime-hdc-status/1`, twenty-three members, `unconfigured_status`
for a daemon without a tool): the configured facts — the tool's path and
digest, the selected endpoint with its source and `serverEndpointRef`
(`hdc-endpoint:` + SHA-256 of the endpoint), the startup versions kept as
history — then what one commandless observation proves. The tool is pinned
(`VerifiedTool`, now with a public `revalidate`), its signature read, the
identity observed once, and the tool re-proved on both sides of every step;
an observed receipt must be the selected tool at the selected endpoint with
the observed generation, else `hdc.identityMismatch` claims nothing. Managed
ownership needs the daemon's own launch record read three times unchanged,
matching the receipt by PID, birth, path and digest, and the live process
verified — or the supervisor's unchanged, healthy, managed record of this
generation; else `hdc.ownershipUnproven`. The five non-observed
classifications map to their reason codes; any failure of the tool itself
withdraws every tool fact (`hdc.toolIdentityOrSignatureInvalid`).
`serverHealth` is always `unknown`, `serverVersion` null and
`newDispatchCount` 0: the status launches nothing. The production pieces
beside it: `CommandlessIdentity` (Swift `HDCCommandlessServerIdentity
.observe`: the 3.2.0f family only at `127.0.0.1:8710`, the 3.2.0d family at
the selected loopback endpoint, `LoopbackServerLease::acquire` raced against
the 1000 ms deadline, the receipt checked against the selected tool),
`NativeSignature` (the signing facts plus `platformTrust: unverified` and
`executionAssessment: notPerformed`) and `SystemManagedProcess`
(`arkdeck_platform::verifies_managed_process`: the observed birth on both
sides of Swift's inspector — the process alive, running the receipt's
executable, its complete argv after argv[0] equal to the launch's through
`process_arguments` (`KERN_PROCARGS2`), declaring `-s <endpoint>`, and owning
a TCP listener on the port bound to the loopback or a wildcard). Beyond
Swift: a server another user owns is `hdc.identityUnknown` rather than an
observed identity, and the deadline abandons the scan rather than
cancelling it. `tests/hdc_status.rs` replays the Swift oracle
(`rust/tests/fixtures/hdc-status`, twenty-two cases at a fixed root under
the oracle's lock) byte for byte.

The published schema admits these live values. It was re-derived (TASK-XPA-014)
from the frames Swift's daemon answers through its handler for these cases and
for a registered tool. `arkdeck-control` serves `runtime.hdc.status` through
`HostServices::runtime_hdc_status`. A request that names any parameter is
refused with `invalidParams` ("live HDC status does not accept caller facts or
paths") before the host is asked. The macOS host of `arkdeck-agentd` answers
`unconfigured_status(None)` without a managed HDC server, as Swift's daemon does
without its HDC host. On other platforms the method keeps the foundation's
refusal. `hdc_status_control.rs` in agentd sends every oracle case through
`Control`, behind a host that composes the observer per request, and each
answer is the oracle's snapshot byte for byte.

With `ARKDECK_DEVELOPMENT_HDC_SERVER=managed` (TASK-XPA-016) the isolated owner
starts its development HDC as Swift's `HeadlessHDCServerHost` does before it
serves: `hdc -s <endpoint> -m` on the inherited `OHOS_HDC_SERVER_PORT` or
`127.0.0.1:8710` (a set port outside 1...65535 fails startup), ready once the
listener answers and `checkserver` agrees, and bound to its own launch by the
commandless identity proof (`ManagedHdcServer`); a registered HDC is then
accepted, and development USB relations beside it only with
`ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC=acknowledged` (the
maintainer's option A of 2026-09-19: what the owner proves about the real device
is development-root evidence, never `REAL_DEVICE_PASS`), which startup refuses in
any other composition and outside an isolated root. Without such a file the owner
reads the Runtime's own USB relations beside that server ("Trusted USB
relations"), so `target adopt` needs no relation file there; what it proves is
development-root evidence all the same.
Beside that server, `ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY=acknowledged` lets
the isolated owner prove a device mutation's state continuity against its own
Job state instead of the installed Runtime's root, which it can never be, so
M2's real-device acceptance can run there (the maintainer's decision of
2026-09-20, handled as that option A: development-root evidence again, and the
dashboard's Golden Journey count does not move). Startup refuses the
acknowledgment without the managed server, outside an isolated root, and in the
standalone daemon and the facade. Nothing else about the proof changes: recorded
authorization usage beside the root, a Job history that is not read-only, and an
unsafe or foreign Session root still refuse it, and a mutation still needs its
capability and its device hold.
`runtime.hdc.status` answers the observer over that launch, and
`target.availability`'s tool leg is `ready` with the startup facts. Swift exits
70 when the server ends unexpectedly, for launchd to restart it (design §L.1
item 13); here no HDC plan is dispatched once the server is not the one
launched. SIGTERM and SIGINT stop the Rust-serving daemon as Swift's
`drainAndStop` does: the socket is closed and its name removed, the frames being
answered finish, every connection is ended within 20 s, the managed server is
stopped, `arkdeck-agentd stopped` is printed and the daemon exits 0; its locks
go only with the process. `tests/managed_hdc_process.rs` drives this with a fake
HDC compiled from `tests/fixtures/managed-hdc/fake-hdc.c`.

`runtime.hdc.impact-preview`, `runtime.hdc.restart`, `runtime.tool.select` and
`control-action.list`, `.show` and `.reconcile` reach `HostServices::control_action`
unread, since Swift's `hdcControlActionRequest` reads its own parameters; a host
without it keeps the foundation's refusal. Without a managed HDC server the macOS
host answers them as Swift's daemon does (`arkdeck_hoststore::ControlActionResources`):
the lifecycle methods are `operationUnavailable` before any parameter is read.
A tool selection is `operationUnavailable` before any parameter is read in every
composition, with or without a managed server (TASK-XPA-012): Swift composes its
tool-selection owner only beside a started HDC server host, the HDC impact
source and the registry adapter, no Rust composition has one yet, and no
selection writes anything.
`arkdeck_hoststore::ToolSelectionRecords` is Swift's
`RuntimeToolSelectionControlActionStore` over its records (`ToolSelectionRecord`):
one `action-<sha256(requestId)>.json` per request identity as canonical JSON,
changed under a non-blocking `.lock` transaction and replaced only by the exact
next generation on Swift's conditions (the transition table, an immutable intent,
lifetime, epoch, catalog and published preview, an approval that only changes its
status, a receipt bound to the challenge it answers, an audit that grows one row at
a time). Every record transition of Swift's owner is here, taking its instant and
the identities Swift draws from the caller: the preview, the impact approval
(`ImpactApproval`), its console challenge (`InteractionChallenge`) and receipt
(`InteractionReceipt`), the prepared dispatch, lifecycle audit rows, the settled or
failed selection and invalidation. The store's mechanics are shared with the HDC
control-action owner's records (`control_action_store.rs`), and the approval values
are ready for the HDC restart. `tool_selection_tests.rs` reads the 17 records Swift's
production store wrote (`rust/tests/fixtures/tool-selection-store`, recorded by
`ToolSelectionStoreOracleContractTests`) as their own canonical bytes and Swift's
projections, and plays 16 of their timelines again to Swift's bytes; the records it
writes itself (`rust/tests/fixtures/tool-selection-store-rust`) are read back and
carried further by Swift (`ToolSelectionStoreRustReadbackContractTests`). No owner
composes the store yet: observing the impact and the restart it approves wait for
the HDC lifecycle restart and a maintainer ruling on the isolated daemon's selection.
`arkdeck_hoststore::ToolRegistryStore` keeps Swift `BootstrapToolRegistry`'s HDC
selection ledger in `tools.json` (TASK-XPA-012): `initialize_service_selection`,
`adopt_installed_hdc`, `selection_candidate`, `prepare_selection`,
`startup_selection`, `publish_pending_selection`, `fail_pending_selection`,
`selection_outcome` and `acknowledge_selection_outcome`, each under the bootstrap
owner's non-blocking `.lock` over the strictly read bundle and tool indexes (either
created empty only beside nothing it would describe), measuring the tools it names
against their retained content, and publishing the index only where Swift does, as
Swift's bytes. The published HDC identities a store's rows and admissions match are
Swift's `knownIdentity`: the daemon's two unless `with_published_identities` gives
others. `tool_selection_ledger_tests.rs` plays the seven timelines of Swift's oracle
(`rust/tests/fixtures/tool-selection-registry`, recorded by
`ToolSelectionRegistryOracleContractTests` over synthetic unsigned executables, the
same bytes on every host) and leaves Swift's index, answer or refusal and
publication after each of its 111 steps. No daemon composes the ledger yet.
The isolated owner composes Swift's union control-action owner over no
tool-selection owner, paging in `control-action-snapshots`. Without a managed
server it holds no HDC owner and never makes `hdc-control-actions`: an exact
identity is `resourceNotFound`, and a listing is one empty snapshot page kept as
Swift's pager keeps it. With `ARKDECK_DEVELOPMENT_HDC_SERVER=managed` it also
composes the HDC control-action owner (`arkdeck_hoststore::HdcControlActions`)
in `hdc-control-actions/{records,snapshots}`: `runtime.hdc.impact-preview`
checks the exact restart intent, returns an existing action of the request
identity, refuses another endpoint, then writes one owner-only
`action-<sha256(requestId)>.json` under a per-transaction `.lock` and observes it
once through the managed server's impact source (`ManagedServerImpact`: the
pinned executable and its signature, the server identity — `checkserver`
between two observations for the registered 3.2.0d executable — the Job
owner's current Jobs, the durable Targets and a Target observation through the
development HDC). The preview is `previewReady` or `blocked` in Swift's blocker
order, or the action `previewDrifted` when the impact is unavailable. Show,
list and reconcile read the actions, invalidating an expired one, one of an
earlier daemon start or of another catalog when they read it, and the
approval an invalidated action awaited with it. `runtime.hdc.restart` checks
the exact preview tuple, then, as Swift's `requestRestart`: the action and
its age, its exact preview (`reviewedPlanMismatch`), an action already
awaiting its approval answered as it is, any other but a ready one
`admissionDenied`, a fresh impact reading that must be the reviewed one
(otherwise `factsDrifted`, the invalidated action in the details), then the
impact approval by CAS (`awaitingImpactApproval`, a waiting `har-` action
with its `resume-` reference, bound to the preview and the new generation,
closing with the action). Restart dispatches nothing. The approval is
listed and shown by the combined human-action owner (`human-action.list`,
`.show`); `human-action.resume` of it answers the approval unchanged and
`agent.resume` refuses it, as Swift's daemon answers any request outside a
foreground console. The console challenge, the receipt of a person's answer,
the lifecycle it starts (`kill -r`), the Job interlock and the recovery of an
interrupted lifecycle are not here, and a record holding any of them is
unreadable. Over the fake server, whose digest proves no server as the
fixture HDC's proves none to Swift, a preview is blocked and its restart
`admissionDenied`; a ready preview needs the registered 3.2.0d server's
health proof. A daemon outside an isolated root keeps no state
and answers as Swift's handler with no owner at all, except that show and
reconcile of an exact identity keep the foundation's refusal, since their
schemas do not publish Swift's `operationUnavailable`. In agentd
`control_action_control.rs` replays every no-host exchange of the corpora
through `Control`, `control_action_host_control.rs` every exchange of a daemon
with an HDC server host but the console's challenge and the lifecycle after
it, and `tests/control_action_host_process.rs` drives the managed fake server
(compiled to record its invocations, and to list no target).

## Capture file legs (TASK-XPA-016, M1)

`arkdeck_provider_hdc::FileAction` is Swift's HDC provider for the legs of
`capture.diagnostics@1` beyond its default request: the file products — a
trace (`hitrace -t … -o`, or an armed ring: `--trace_begin`, the coverage
anchor echoed into `trace_marker` and read back with `grep -c`, `sleep`,
`--trace_dump`, `--trace_finish_nodump`), the component tree (`uitest
dumpLayout -p`), a screenshot (`snapshot_display -t <type> -f`) and a screen
sequence (`mkdir -p`, one `snapshot_display` per frame, `tar -c -f`) — each
written to a provider-owned path (`OwnedRemotePath`: the job/step/nonce
tuple under `/data/local/tmp` with the producer's suffix) and judged by its
`ls -l` readback, never by the client's exit status (`remote_regular_file_
byte_count`, the size column of one listing line); their receive (`file
recv <remote> <host>`, the host file named by the remote basename, judged
by the bytes that landed — `HostLanding::inspect`: no file, a symlink or a
changed file is unknown, empty and over-budget fail without a digest, a
pinned hash and a pinned magic are checked) and their cleanup (`rm -f` by
name; for a sequence the frames, the archive, `rmdir`, proved by `ls -ld`'s
not-found grammar — `path_presence`); and the stdout legs the default
request leaves unselected — the crash ledger (`hidumper -s 1201 -a "-p
Faultlogger -l"` / `-f <name>`), the component detail dump and the
application liveness readback (`pidof`, always a verified fact naming
running, stopped, unreadable or ambiguous). `FileAction::for_step` is
Swift's step-to-action mapping from the request's inputs, minting one path
for a product's capture, receive and cleanup; `lower` the exact argv,
timeouts and continue-after-non-zero of each invocation; `run` Swift's
sequence rule over any `HdcDispatch` (stop at the first non-zero exit an
invocation does not continue past; a landing prepared before the transfer
and inspected after it whatever the exit); `verify` Swift's verdicts and
summaries; `persisted` the journal forms. The default legs, the storage
preflight and the observe steps stay with `Action`; the Job's products,
index and summary with the store owner. `tests/capture_files.rs` drives
every leg through the real process dispatch over the shared fake HDC
driver with its own answers fragment, reading the argv back from the
driver's log and the received bytes back from the host.

## Target observation port (TASK-XPA-016, M1)

`arkdeck_provider_hdc::target_observation` is the physical side of a target
observation as Swift's `TargetObservationCoordinator` proves it. `UsbRelation`
is Swift's `TargetUSBRelation` (the serial that is the connect key, the
decimal location, one IOKit attachment identity, the vendor and product) with
its `is_usable` rule and the JSON shape the oracles record; `UsbRelations` is
the port that reads them, implemented by any closure for tests, by
`NoUsbRelations` — no relations, so no candidate is proved and no adoption can
pass, while the device list stays readable — and by the Runtime's own
`UsbRegistryRelations` (next section). `Reading::take` is Swift's
bracketed read over any `HdcDispatch`: the relations, `list targets -v`
(parsed with the highest registered version, as Swift's bootstrap port
parses it), the relations again; `Reading::rows` is the stamp's rule — a
candidate carries a proved relation only when exactly one usable relation
names its serial in both reads, unchanged, and no other row shares its
connect key — and `validate` its bounds. `observe_tool_version` (`-v`) and
`observe_device_identity` (the exact-row confirmation, answering the serial)
are Swift's `ProviderBootstrapObservation`; `adoption_holds` is the
adoption's final check over the live relations and the readback;
`stable_identity_sha256_for_serial` Swift's normalized serial digest. Minting
observation identities and generations over a reading, following a
reference, and the adoption itself are the Target owner's.
`tests/target_observation.rs` reads the observe fixture's shared fake with
injected relations and checks the argv the driver logged.

## Trusted USB relations (TASK-XPA-016, M1)

The Runtime reads the USB relations that prove a target observation from the
host's I/O Registry itself, as Swift's daemon does (the maintainer's decision
Q1=B of 2026-09-24; r11's design table had the ArkForge lane's `arkforged
discoverDevices` serve them, which is re-evaluated after M4). The census is
`arkdeck_platform::usb_host_devices`, Swift's
`RockchipProductUSBProbe.systemIdentities()`: every `IOUSBHostDevice` entry with
a numeric `idVendor`, `idProduct` and `locationID` and a string
`USB Serial Number` (else `kUSBSerialNumberString`), read as `NSNumber` reads
them (the low sixteen bits; the location's bits in decimal), with its optional
`USB Product Name` and its registry entry ID (none when the registry answers
none or zero), in registry order and never deduplicated. It only matches and
reads properties: it opens no device or interface and sends no USB request,
releases every object it obtains, and drains its own autorelease pool. With no
entry of the class the kernel answers no iterator, an empty census; a census it
cannot take, or whose iterator did not stay valid (a check Swift never makes),
is unavailable (`RegistryUnavailable`). `registry_census` is the same read for
any class.

`arkdeck_provider_hdc::UsbRegistryRelations` is Swift's
`TargetUSBRelation.registeredDAYU200()` over that census on every read: the
HDC-normal DAYU200 (`is_dayu200_hdc_normal`: vendor `0x2207`, product `0x5000`,
a product name that is `HDC Device` once quotes and spaces are trimmed) with an
attachment, as relations (`registered_dayu200_relations`); whether one is usable,
unique and unchanged stays the reading's rule. A census that cannot be taken
fails the read with Swift's `admissionRejected("USB registry unavailable")`,
which fails the observation (`internalError`) and breaks its continuity; it is
never read as no devices. The isolated owner composes it only beside the
registered HDC it starts as its managed server and without a relation file
(`development_usb::relation_source`); beside a fixture it reads none, so the
host's devices never prove a fixture's candidates. The production composition
composes it by the same rule beside the registered HDC it starts as its
managed server, and reads no relation file ("macOS production composition"
below). A host with it names `usbRegistryRelations` in its owner census.

Tests: `usb_registry` unit tests (the per-entry rule over synthetic entries);
`tests/usb_registry.rs` (the host's census answers with or without a board, the
census reads strings, numbers and booleans from the host's USB controllers, and
batches of censuses keep no heap block or port name); the provider's reader
units and `tests/target_observation.rs` (the shared fake bracketed by the reader
over a census, and this host's registry through `system()`, which skips without
a board); in agentd, the Target adoption oracle replayed through `Control` with
the reader over a census listing each relation's board among entries it must
pass over, and an uncertain census failing closed. None of it is device
evidence.

## Trace Runtime probe (TASK-XPA-016, M1)

`arkdeck_provider_hdc::trace_probe` is Swift's `FoundationTraceRuntimeProbe`
on an adopted route, and `evaluate_help`/`evaluate_tag_list` its
`TraceProbeAdapter`: only the registered `OPENHARMONY-TRACE-PROBES@1.0.0`
help and tag-list bytes (their SHA-256 after the leading capture time) select
`hitrace` for capture, `bytrace` stays probe-only, and a tool's name, exit
status or a familiar marker never selects anything. The help reads and the
nine catalog `param get` reads run together (15 s each, 64 KiB or 4 KiB kept);
the tag list follows only a registered hitrace help, and failing it fails the
probe. A help read that cannot complete is `probeFailed`, a parameter read
`unreadable` with Swift's reason — never a value or an answer. The Host serves
it as `trace.probe` beside the Debug reads, and the standalone App ingress
admits it with `targetId` alone. `tests/trace_probe.rs` covers the adapter on
the registered resources and the reads over scripted dispatch;
`arkdeck-agentd`'s `tests/spawning/trace_probe_control.rs` replays the Swift oracle
(`tests/fixtures/trace-probe`, recorded by `TraceProbeOracleContractTests`,
re-recorded with `ARKDECK_RUST_TRACE_PROBE_RECORD=/private/tmp/<new>`) through
the production Host, answer by answer and call by call.

## Debug HAP provider (TASK-XPA-016, M2)

`arkdeck_provider_hdc::HapAction` is Swift's HDC provider for `debug.hap@1`
(`debugHAPAction`): a package staged to a provider-owned path (`file send
<host> <staged>`) or a set of packages to a provider-owned directory
(`mkdir -p`, one `file send` per package), installed (`shell bm install -p
<staged|dir> -r`) and believed only through its readback (`shell bm dump -n
<bundle>`: the bundle on its own boundaries, the deployed Artifact's digest,
the native-library facts the device reports), the ability started (`shell
aa start -b <bundle> -a <ability>`) and believed only through its process
readback (`shell pidof`), stopped (`shell aa force-stop` + `pidof`) and
uninstalled (`uninstall` + `bm dump`), each judged by its paired readback
rather than by the mutation's own exit, and the staging cleaned by name
(`rm -f`; for a set the packages, `rmdir` and the `ls -ld` that proves it).
An install's failures are named as Swift names them (`installFailed`,
`installOutputTruncated`, `deviceUDIDUnauthorized` on `bm` code 9568423,
`installRejected`, each with the bounded hex diagnostic of both streams).
`for_step` is Swift's step-to-action mapping from the request's inputs, the
staged set appearing only with additional leases; `lower` sends nothing
unless the Artifacts it stages are the resolved ones (`ResolvedArtifact`,
handed in by the Job owner — identity through the lease's suffix, bytes
through the pinned hash); `verify` Swift's verdicts; `persisted` the journal
forms; `readback`/`desired_presence`/`presence` the recovery table that
concludes a mutation whose outcome was never observed through its
read-only probe (`readPackagePresence`, `readProcessPresence`,
`readOwnedPathPresence`, `readOwnedDirectoryPresence`) without resending
it. `tests/debug_hap.rs` replays the Swift oracle
(`rust/tests/fixtures/debug-hap`: eight Jobs and two cleanup-debt
continuations over the shared fake HDC driver with the oracle's own answers
and modes) step by step through the real process dispatch, checking every
verdict and comparing the argv the driver logged with the oracle's recorded
log line for line. The Job's planner and runner, the lease resolution and
the products (`install-readback.json`, `process-readback.json`,
`debug-hilog.txt`) are the store owner's.

## Native library provider (TASK-XPA-016, M2)

`arkdeck_provider_hdc::NativeAction` is Swift's HDC provider for
`deploy.native-library.app-owned@1` (`nativeLibraryAction`): a leased native
library staged into the target application's own data directory with the
bundled code-sign helper (`mkdir -p`, two `file send`, `chmod 700`,
`sha256sum`), the current library backed up by a hard link (`ls -ld`, `ls
-l`, `sha256sum`, `rm -f`, `ln`, `sha256sum`, `ls -l`, `ls -la`), the
replacement published atomically by the helper (`ls -ln`, `<helper> verify
<backup>`, `<helper> publish <staging> <target> <rollback>`, `sha256sum`,
`<helper> verify <target>`, `ls -ln` — the published library must be at
least as attested as the one it replaced, read off the helper's
`ARKDECK_CODE_SIGN_*` lines), the target stopped and started (`aa
force-stop`/`aa start … EntryAbility` with `sleep 2` and `pidof`), the
loaded library proved through `grep -F <loader path> /proc/*/maps`, the
staging cleaned by name and proved absent by `ls -ld`, and the rollback (13
steps) that restores the backup. `Deployment` derives the whole
provider-owned namespace from the bundle, the ABI and the Job
(`/data/app/el1/bundle/public/<bundle>/libs/<arm|x86_64>/…`, the job-owned
staging directory under the application's `el2` data, the loader-visible
path under `/data/storage/el1/bundle/libs`), accepting persisted paths only
when they are exactly what it would have produced; `Deployment::from_inputs`
is Swift's admission over the request's inputs, the engine-resolved
Artifact, the library's bytes and the helper. `native_elf::validate_elf` is
the host-side verifier (Swift `NativeLibraryArtifactValidator`): the closed
ELF fields, the ABI by class and machine, the GNU build id from the note
sections, and the OpenHarmony V1 code-sign block appended to the file;
`is_static_executable` the shape the bundled helper must have. `lower`,
`verify`, `persisted`, `readback` (each mutation's read-only inspection —
`Inspection`, eight of them) and `reconcile` (a failed readback is "not
executed" for the idempotent mutations, never for a publish or a rollback)
follow Swift line for line, with its codes (`nativeSendFailed`,
`nativeAppOwnedDirectoryMissing`, `nativeBackupMismatch`,
`nativePublishMismatch`, `nativeTargetStillRunning`,
`nativeTargetNotRunning`, `cleanupDebt`, `nativeRollbackVerificationFailed`,
`nativeStagingMismatch`, `nativeTargetHashMismatch`, `nativeLibraryNotLoaded`,
`nativeCleanupIncomplete`) and summaries (`loaderVerified` stated as
`notObserved` under a profile that never read the maps).
`tests/native_library.rs` replays the Swift oracle
(`rust/tests/fixtures/deploy-native-library`: five Jobs and the debt
continuation over the shared fake HDC driver with the oracle's own answers
and modes) step by step through the real process dispatch, comparing the
argv the driver logged with the oracle's 225 recorded lines. The Job's
planner, the rollback/compensation sequencing, the lease resolution, the
bundled helper's discovery and the published reports are the store
owner's.

## Pointer input and port rules (TASK-XPA-016, M2)

`arkdeck_provider_hdc::pointer_input` and `port_forward` are Swift's device actions for the
interactive operations of Golden Journey 2 — `input.tap@1`, `input.long-press@1`,
`input.swipe@1`, `port-forward.create@1` and `port-forward.remove@1` — as
`HDCObservationProviderAdapter` handles them, with T1 argv parity proved by replaying the
Swift oracles `rust/tests/fixtures/pointer-input` and `rust/tests/fixtures/port-forward` over
the shared fake HDC driver (`tests/pointer_input.rs`, `tests/port_forward.rs`).

- `PointerInput` is `HDCPointerInputSpec`: one gesture (`Gesture::{Tap, LongPress, Swipe}`)
  at exact device coordinates with the frame it was mapped against, `new` holding Swift's
  closed bounds in Swift's order of refusal (coordinates `0...32767`, a swipe's end point and
  `80...2000` ms duration, a display `0...64`, a positive frame, every point strictly inside
  it), `from_inputs` Swift's `pointerInputSpec` over the request's inputs (the operation names
  the gesture), `frame_age_ms`/`refuse_if_stale` the freshness gate at dispatch (`inputExpired`
  beyond 1000 ms, no claim without an epoch), `lowered_hold_ms` the hold the device command
  is given, `persisted`/`from_persisted` the `hdc.injectPointerInput` intent.
- `PointerAction::for_step` is the `injectPointerInput` step's action at dispatch time;
  `lower` the positional `uinput -T` argv (`-D <display>` before `-T`; `-c x y`,
  `-d x y -i hold -u x y`, `-m x y toX toY ms`) on one 30 s process; `verify` Swift's verdict
  from the injector's own acknowledgement — `parameter error` fails as `pointerInputRejected`,
  the gesture's lines verify, anything else is unknown, the exit status never consulted;
  `readback` is none and `reconcile` stays unknown: an injected gesture leaves nothing to
  read back.
- `PortRule` is `HDCPortForwardSpec` (`Direction::{Forward, Reverse}`, both ports
  `1024...65535`), `from_inputs` Swift's `portForwardSpec` with its one refusal,
  `endpoints` the full-task tuple whose order flips with the direction, `presence` Swift's
  reading of `fport ls` (trusted only clean, untruncated and UTF-8; a row with the direction's
  tag and the exact tuple in order).
- `PortAction::{Create, Remove, ReadPresence}` with `for_step` for `createPortForward`,
  `removePortForward` and the two operations' `verifyRemoteState`; `lower` `fport`/`rport
  <tuple>`, `fport rm <tuple>` and `fport ls` on one 30 s process; `verify` the mutation by
  exit status alone (`portForwardFailed` with the host port) and the readback as `present`;
  `readback`, `desired_presence`, `conclude` and `reconcile_without_readback` Swift's
  reconciliation table; `persisted` the three `hdc.*PortForward*` intents.
- Both reuse the native-library provider's `Reconcile` (Swift's `ProviderReconcileOutcome`)
  for what a readback concludes.

The engine half — the typed plan's preflight at `job.plan`/`job.submit`, the port-rule
readback gate (`portForwardReadbackMismatch`) and `compensate-port-rule`, the lineage block
after an unknown outcome, the persistent shell channel routing of pointer injection — stays
with the Job owner.

## Rockchip live-mode probe (TASK-XPA-016, M4)

`arkdeck_provider_hdc::LiveModeProbe` is Swift's `FoundationRockchipLiveModeProbe`,
the read-only observation of a bound Rockchip target's current mode and build
that stands behind the flash facts: `hdc list targets -v` through an
`HdcDispatch` (15 s, 64 KiB) names the mode `hdc` only for exactly one
`Connected` row with the bound connect key; then the allowlisted
`param get const.ohos.fullname` is the build (a failed readback is a known
mode with an unknown build, never a guess) and the exact HDC-normal identity's
current port comes from the `UsbProbe` port. Anything else is decided by the
`LoaderObserver` port — ArkForge's dual-source Loader observation for the
exact bound identity — as `loader` with the observed topology, or the target
is not observable with Swift's reason. A target list the registered parser
cannot read is never downgraded to absence. Both ports are the ArkForge
lane's to serve over `arkforged discoverDevices` (ArkDeck no longer owns the
USB enumeration), as is the facts port that encodes "not observable" as
`deviceMode: "absent"`. `tests/live_mode.rs` drives the probe over the shared
fake HDC driver as real subprocesses and asserts the argv from the fake's log.
## Post-flash HDC alias store (TASK-XPA-016, M4)

Swift's post-flash HDC alias store (`RockchipPostFlashHDCBindingStore`, the
owner-only document under `~/Library/Application Support/ArkDeck` that keeps
an adopted Target usable after a flash rotates its HDC serial) needs three
host-store rules the crate did not have; they are now `arkdeck_platform`
primitives, with no store logic behind them (its waited-for lock is the
existing `HostDirectory::wait_lock`): `HostDirectory::open_or_create_private`
(Swift `prepareRoot`: create every missing level owner-only, make the root
owner-only whether or not it existed, open it by its canonical path),
`HostDirectory::create_exclusive_or_match` (Swift `archiveSuperseded`: a
document created exactly once at its name, synced in place, and when the
name is taken compared byte for byte — `Created` / `Matched` / `Different` —
never replaced or removed), and `HostDirectory::read_owner_only` (Swift
`load` + `validateFile`: `None` for absence, otherwise the owner's
single-link regular file of exactly mode 0600 and 1..=maximum bytes).
`arkdeck_platform::{application_support_directory, arkdeck_application_support_root}`
derive Swift's Application Support root from `runtime_home()`
(`CFFIXED_USER_HOME`, never `HOME`). The store itself — the record, its
canonical bytes, the three-way publication and the reissue reconciliation —
is the store below, over these.

`arkdeck_hoststore::PostFlashAliasStore` is Swift's
`RockchipPostFlashHDCBindingStore`: the owner-only document
`rockchip-post-flash-hdc-binding.json` under the product's Application
Support root that keeps an adopted Target usable after a flash rotates its
HDC serial. `PostFlashBinding` is the record (twelve fields, the canonical
sorted compact bytes plus one trailing newline; decoded as Foundation
decodes, validated as Swift validates with one message); `publish` admits
the candidate and its expected previous alias before anything is touched,
then under the waited-for lock reads the stored record and resolves three
ways — the same proof returned unchanged and unwritten, a revision advance
archiving the superseded epoch as `post-flash-superseded-<alphanumerics of
its time>.json` (a taken name compared byte for byte, never replaced) before
the commit, or the chain rule (same target, revision and Loader identity,
the stored alias being the one expected) letting a same-revision rotation
commit; `reconcile_reissued_lineage` republishes a stored alias ahead of the
live Target at the live revision when it agrees with the Target and the
observed device on every identity fact, else declines without a write. The
decisions are pure functions (`admit_post_flash_alias`,
`resolve_post_flash_alias`, `reissue_post_flash_alias`); the I/O is the
`arkdeck_platform` primitives (`open_or_create_private`, `wait_lock`,
`read_owner_only`, `publish_document`, `create_exclusive_or_match`).
`tests/post_flash_alias.rs` replays the Swift oracle
(`rust/tests/fixtures/post-flash-alias`) step by step, comparing every
outcome and every file the root holds — names, modes, sizes, bytes.

## Rockchip post-flash HDC observation (TASK-XPA-016, M4)

`arkdeck_provider_hdc::RockchipHdcObserver` is the HDC side of Swift's
Rockchip flash executor (`FoundationRockchipRuntimeActionExecutor`): the
waits for the bound target to leave and re-join HDC (`wait_for_hdc`, 15 s /
120 s, a `list targets -v` every second, an empty list and a malformed read
tolerated until the deadline, which names the last malformed read), the
bound reconnect after a complete overwrite (`wait_for_bound_hdc`, 600 s: the
exact HDC-normal device at the recorded topology, or the previous alias at
its new port, self-consistent and with exactly one `Connected` row — a
board that drifted on both axes is a rebind, not a reconnect), the fresh
re-proof of a cached route (`revalidate_bound_hdc`), and `verify_bound_build`
up to the alias publication: prove the device, read
`param get const.ohos.fullname; param get const.product.model` once
(`parse_build_properties`: exactly two ordered values, at most 400
characters each), require the model and then the build to equal the
published profile exactly, and return the proof for the alias-store owner
to publish. Every read is judged as Swift's `requireSemanticSuccess` judges
it (`output_excerpt` is its last-output line). The `UsbProbe` port gains
`single_hdc_normal_at(usb_topology)`; the receipt summaries are the
functions beside the observer. The durable alias store, the Target lineage
advance and the executor's observation-reuse cache are other owners'.
`tests/rockchip_hdc.rs` drives the shared fake HDC driver with its own
answers fragment and asserts the argv from the driver's log.
## Rockchip Loader transition (TASK-XPA-016, M4)

`arkdeck_provider_hdc::RockchipLoaderTransition` is the Loader side of
Swift's Rockchip flash executor: `enter_loader` sends the one mutating HDC
command of the flash flow (`hdc -t <key> shell reboot loader`, 20 s, 64 KiB)
unless the exact bound Loader is already there (confirmed by ArkForge, no
command sent), and believes the command only when the exact bound Loader
appears within the readback budget (45 s, one readback a second) — even exit
0 is not the semantic boundary of a command whose success disconnects its
own transport. When it does not: the exact HDC-normal readback proves the
transition did not complete (`ConfirmedNotExecuted` with one of Swift's two
closed diagnostics), else a command that did not return cleanly stays as it
was, else the mutation is unknown; both failure exits carry the command's
evidence clause (`transition_evidence_summary`: exit status, a bounded
single-line stderr, the runner failure — which names a terminating signal
through `signal_death`, readable back with `signal_number`). `wait_for_loader`
and `rebind_loader` are the same readback for the Loader and rebind arms.
The `UsbProbe` port gains `single_loader`; `LoaderObserver` gains
`confirm_loader` (defaulting to a fresh observation). The observation-reuse
cache keyed by the managed-control step id stays with the executor.
`tests/rockchip_loader.rs` drives the shared fake HDC driver and asserts the
command's argv and the refusal it prints.

## Workspace provider (TASK-XPA-015)

`arkdeck-provider-workspace` is the Rust side of Swift's `WorkspaceProvider`.
Its first layer, from SPK-10, signs a HAP without Swift. `signing_preset` reads
`preset-v1.json` (`arkdeck-openharmony-signing/v1`) with Swift's exact keys and
refuses one more. It re-measures the pinned Java launcher, hap-sign-tool JAR,
keystore, certificate and profile the way Swift's `measure` does, including
Foundation's `/private` spelling. It also checks the installed daemon's code
identity. `secret_envelope` reads the Keychain value Swift writes.
`deveco_password` opens DevEco Studio's password ciphertext with PBKDF2 and
AES-128-GCM. `signer::sign_hap` runs `sign-app` and `verify-app` through the
registered identities. The JAR and the staged input are bound by inode, and
both passwords go only through `run_pty_exchange`. The run ends in Swift's
`signing-result.json`, with Swift's refused-before-spawn and outcome-unknown
failure classes.

The registration owner is `arkdeck_hoststore::WorkspaceProjectStore`. It
serves `workspace.project.*` and `workspace.preset.*` over Swift's
`projects.json`, with the key sets frozen and a record with one key more
refused. A project or preset update or removal first asks the durable Job
census, `JobStore::require_no_active_workspace_project_reference` or
`require_no_active_workspace_preset_reference`, whether an active or uncertain
workspace Job names it. A preset that pins a DevEco toolchain or a signing
credential goes through Swift's crash-recovered dependency transaction: the
intent is written first, completed by the next access if the process dies, and
abandoned if a pin is refused. The pins go through the
`WorkspaceToolchainPinning` and `WorkspaceCredentialPinning` owners the
composition root passes to `with_dependency_pinning`. Both compositions pass
the toolchain owner: `DevEcoRegistryStore::acquire/release`
(`tool_retirement::pins`) hold a preset's pin in its own bootstrap registry,
as Swift's `BootstrapDevEcoToolchainRegistry` holds it, and retirement refuses
a pinned toolchain. The production composition also passes the credential
owner (`arkdeck_hoststore::keychain_credential_pinning` over
`arkdeck_provider_workspace::credential_owner`, Swift's
`OpenHarmonySigningCredentialOwner` and its `credential-owner-v1.json`
ledger): the credential's project binding is checked without secrets before
the store writes its intent, and again at the pin. The isolated daemon passes
none, so a signing preset is refused there as Swift refuses it without one.
`AgentDaemonContractTests.testWorkspacePresetAndProjectMutationControlFramesRecordTheirRefusals`
is the Swift oracle, and `tests/workspace_mutation_oracle.rs` replays its 78
frames in order.

`arkdeck_platform::KeychainItems` is the `SecItem*` store under it. Production
reads use the Data Protection Keychain in the helpers' access group, with
Swift's non-interactive `LAContext` created through the Objective-C runtime. A
file-based keychain at an exact path is the test scope.
`trusted_daemon_fingerprint` reproduces the receipt's
`trustedDaemonApplicationSHA256`.

`tests/fake_hap_signer.rs` compiles `ArkDeckFakeHapSignerFixture` with
`swiftc` from its byte-identical copy in `tests/fixtures/fake-hap-signer/`. It
keeps the envelope in a keychain made by `security create-keychain`. It reads
the running signer's argv and environment from the kernel to show no password
reaches them. `tests/deveco_password.rs` replays vectors Swift produced. The
`spk10_probe` and hoststore `spk10_hvigor` examples are the by-hand probes of
the real signer, the real DevEco material and Hvigor through a registered
DevEco toolchain.

Five of the 13 `workspace.*` operations run as Jobs on the Rust daemon
(`workspace_run.rs`): `prepare-isolated-copy`, `apply-patch`, `revert-patch`,
`build-openharmony` and `sign-openharmony-hap`; the other eight are M3 work. A
build (`workspace_build.rs`) runs a registered Hvigor preset, composed at
start-up through its exact DevEco pin (`DevEcoRegistryStore::resolve`), with
every pinned file held open by digest while the child runs, and lands a
Runtime-owned copy's unsigned HAP. Signing (`workspace_signing.rs`,
`workspace_composition.rs`) signs with a registered signing preset through
`signer::sign_hap`, reconciles a parked Job from its own attempt directory and
never signs it again; the production composition reads the account's preset
store and the Data Protection Keychain and releases, at start-up, the
credential pins no preset record carries, while the isolated daemon signs
nothing. `tests/workspace_build_oracle.rs` and `tests/workspace_sign_oracle.rs`
replay the Swift oracles (`WorkspaceBuildOracleContractTests`,
`WorkspaceSignOracleContractTests`).

## Crash-ledger analyzer mode (TASK-XPA-015)

`arkdeck-agentd --analyze-crash-ledger <absolute path>` is Swift's one-shot
analyzer mode (`ArkDeckAgentDaemonMain`): the executable a service's plist names
as `ARKDECK_ANALYZER_PATH`, which the Runtime runs as the analyzer child of
`analyzer.extract-crash-signature@1` (no environment, the source Artifact's
`/.vol` alias). It is answered before anything else the daemon does, under any
executable name: no environment is read and no store, socket or device is
touched. It reads the one file it is named and prints the canonical
`HarnessCrashLedgerAnalysis` (`arkdeck_hoststore::analyze_crash_ledger`): the
Faultlogger listing's entries, or `unreadable` with Swift's reason
(`invalidEncoding`, `ledgerHeaderAbsent`, `ledgerFenceAbsent`,
`entryNameUnparseable`), never an empty ledger for bytes that are no listing.
Other arguments get Swift's line and exit 64 before anything is read; a file that
cannot be read, or an answer that cannot be written, is exit 1 and one line
naming the error, never the path or the bytes.

The listing is read over Swift Characters: grapheme clusters as the pinned Swift
runtime draws them, each judged by its first scalar, with Swift's `Numeric_Type`
and `Alphabetic` where they hold scalars the standard library's tables do not.
`rust/tests/fixtures/crash-ledger-analyzer/oracle.json` is what the Swift daemon
answered to 78 cases and the four Character properties the parser reads, for
every scalar (recorded by `CrashLedgerAnalyzerOracleContractTests`).
`cargo test -p arkdeck-hoststore --lib crash_ledger` compares the analysis and
the properties; `cargo test -p arkdeck-agentd --test crash_ledger_analyzer`
replays every case through the built daemon, byte for byte, and runs the daemon
as its own analyzer through an isolated Runtime
([run record](../openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-015/rust-crash-ledger-analyzer-run.md)).

## HiLog summary analyzer (TASK-XPA-015)

`arkdeck-agentd --summarize-hilog <absolute path>` is Swift's other one-shot
analyzer mode: the Runtime runs the daemon as the analyzer child of
`analyzer.summarize-hilog@1` when `ARKDECK_ANALYZER_PATH` names the daemon's
own bytes (`hilog_summary_analyzer::composed`, Swift
`HilogSummaryDerivedAnalyzer.profile`); an analyzer executable that is not this
daemon leaves the operation unavailable as
`analyzer.hilogRequiresCurrentDaemon`. Like the crash-ledger mode it is
answered before anything a daemon does. It reads the one file it is named as
Swift's bounded reader reads it (`arkdeck_platform::read_profile_file`: a
regular file through its physical path or its `/.vol` alias, no link followed,
unchanged while read, at most 512 MiB) and prints the canonical
`HilogSummaryAnalysis` (`arkdeck_hoststore::analyze_hilog`): line, blank and
unrecognized counts and a count per severity of OpenHarmony's default header,
matched as ICU matches Swift's pattern. A usage refusal is
`analyzer.hilogInvalidArguments` and exit 64; any failure is
`analyzer.hilogReadFailed` and exit 1.

`rust/tests/fixtures/hilog-summary-analyzer/oracle.json` is what the Swift
daemon answered to 62 cases (`HilogSummaryAnalyzerOracleContractTests`), and
`rust/tests/fixtures/job-run-hilog/` Swift's plans, admissions, runs, reads and
store for eleven Jobs of the operation
(`JobRunAnalyzerOracleContractTests/testSwiftRunsTheSharedHilogSummaryJobs`).
`cargo test -p arkdeck-agentd --test hilog_summary_analyzer` replays every
case through the built daemon and runs the daemon as its own analyzer through
an isolated Runtime, by `job.run` and by `agent.run`;
`cargo test -p arkdeck-hoststore --test job_run_hilog` replays the Jobs byte
for byte
([run record](../openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-015/analyzers-trace-inspect-run.md)).

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

The facade pairs with its authority over a socket in a directory it creates
for that one process, `/private/tmp/arkdeck-facade-<nonce>`. It removes exactly
that directory, with the authority's socket in it, on every exit it can
observe: a startup failure, its authority's exit, and a stop by SIGTERM or
SIGINT, which its accept loop takes as the isolated Rust daemon and the Swift
daemon do (`arkdeck_platform::StopSignal`) and answers by returning, so the
process ends with status 0. After SIGKILL the paired Swift daemon unlinks its
socket and removes the directory when the pairing pipe closes. The harness's
fixture authority does the same, so the facade tests leave nothing under
`/private/tmp`.

## macOS production composition (TASK-XPA-017, not activated)

The third mode of `arkdeck-agentd` — neither an isolated development root nor
a facade — is the one M5's cutover points the LaunchAgent at. Without
`ARKDECK_RUNTIME_COMPOSITION` it stays the read-only foundation described
above; with `ARKDECK_RUNTIME_COMPOSITION=production` (its one value) the daemon
composes every owner over the account's own state, as Swift's daemon lays it
out. Nothing sets that variable before the cutover: no LaunchAgent, plist,
receipt or installed service changes here (`src/production.rs`).

Every root comes from one account home, the one Swift's Foundation resolves
(`CFFIXED_USER_HOME`, else the account's), so a caller cannot split them:

| Root | Owner |
| --- | --- |
| `~/Library/Application Support/ArkDeck/Agentd` | Swift's state directory: the Job owner (`runtime-jobs.sqlite3`, `jobs/`, `cli-job-snapshots/`, recovery epochs), Session storage, History, planning, `instance.lock`, `instance.json`, `agentd.sock` |
| `…/Agentd/{capabilities,targets,artifacts,agent-executions,human-action-snapshots,control-action-snapshots,workspace-projects}` | the owner of the same name; `hdc-control-actions` only beside a managed HDC server |
| `…/ArkDeck/Sessions`, `…/ArkDeck/Bootstrap/v1` | the default Session root; the tool, bundle and DevEco registries |
| `~/Library/Containers/com.arkdeck.desktop/Data/Library/Caches/ArkDeck/Trace/traces` | the Trace cache, read only where the App created it |

The Job owner opens Swift's index in place (`JobStore::open_state_root_owner`):
a first index is created beside the other owners' entries, as Swift's
`RuntimeJobRepository` creates one, and still never replaces lost history. The
device-mutation continuity proof is anchored at the same `Agentd` root.

One authority: before any store is created or probed, the daemon takes Swift's
single-instance lock (`Agentd/instance.lock`, `LOCK_EX|LOCK_NB`), then the
facade's lock on the `Agentd` directory with the installed socket
(`LocalListener::bind_facade`, which reclaims only a socket nobody answers on),
and writes Swift's `instance.json` naming itself. Swift's daemon holds only the
first lock and the facade only the second; holding both excludes each, and each
refuses to start beside it. When the instance lock is held and its document
names the holder, the daemon prints Swift's `arkdeck-agentd already running:
pid <p>, socket <s>, protocol <v>` and exits 0 having composed nothing; a lock
held without that document, the facade's lock or a live listener on the socket
ends the start with exit 69. It never stands by.

With `ARKDECK_HDC_PATH` (Swift's only HDC input) the account's bootstrap
registry adopts that file while it holds no selection, and its startup
selection is started as the managed server on Swift's endpoint
(`OHOS_HDC_SERVER_PORT`, else 127.0.0.1:8710), with the HDC control actions,
Trace and Debug probes and the exit-70 boundary of the isolated owner. Beside
that managed server its Target observations read the Runtime's own trusted USB
relations (`UsbRegistryRelations::system()`, "Trusted USB relations" above),
as Swift's daemon reads `registeredDAYU200()`. An unpublished HDC, a pending
tool selection or an occupied endpoint ends the start; without the variable,
dispatch stays refused as Swift's does, nothing is observed and nothing is
adopted. `ARKDECK_ANALYZER_PATH` names the analyzer. The composition prints
what it composed (`arkdeck-agentd owners: …`, with `hdc, managedHdc,
usbRegistryRelations` beside a managed server) and one line per owner it
composes without and why: no HDC, a Trace cache the App has not created, no App
ingress over an overridden home, and every input Swift's LaunchAgent sets for
an owner not ported yet. Over the account's own home the App ingress is served
on `com.arkdeck.agentd` with Swift's code-signing requirement and the owner's
effective UID (`app_ingress::Configuration::production`). Startup recovery and
the Artifact sweep run as they do for the isolated owner; then it prints
`arkdeck-agentd listening on <socket>`.

`cargo test -p arkdeck-agentd --test production_composition` runs the real
daemon in this mode under temporary homes only (environment cleared,
`CFFIXED_USER_HOME` below `/private/tmp`, so no Mach service is registered);
see [the run record](../openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-017/production-composition-run.md).
Its deep `doctor` answers from these owners as they are: over a composition
without an HDC the HDC check is the `hdc.notConfigured` blocker, never a live
identity it cannot prove, and `doctor --deep --require-healthy` exits 69.

## LaunchAgent service leaves (TASK-XPA-018)

`arkdeck runtime service status|verify|restart|update|uninstall` manage the one
user-domain LaunchAgent `com.arkdeck.agentd` in `gui/<uid>` as Swift's
`LaunchAgentService` and `RuntimeCLI.runAgentDaemon` do
(`arkdeck-cli/src/runtime_service.rs`, `runtime_service_install.rs`). `status` validates the plist (read by
CoreFoundation, `arkdeck_platform::read_property_list`), the installed helper
bundle (`validate_production_daemon_bundle`), a signed sibling facade when the
bundle carries one, the daemon and HDC digests against the install receipt, the
ArkForge release bundle (its manifest members re-measured) and the ArkTrace
descriptor (one `openat(O_NOFOLLOW)` walk), then asks launchd whether the
service is loaded and the daemon for `health`. `verify --job` reopens one
profiled Job (`observe.device@1`, `flash.full-restore@1`) through `health`,
`job.status`, `job.evidence` and `artifact.list` only. `restart` refuses unless
the service is ready and every current Job is a closed unknown-outcome recovery
lane (`classify_restart`), boots it out and back in (EIO retried, `enable` once
after three), and proves a new PID speaking the same catalog digest with the same
closed Jobs. `verify` without `--job` runs `observe.device@1` as a Runtime-owned
`agent run` through the daemon and reopens the Job it produced the same way
(where Swift ran it through its client-side executor), answering Swift's members
plus the settled `agentExecution`. `update` installs a helper bundle as Swift's
`install` does — options, validations, a staged copy exchanged into place with
`renamex_np(RENAME_SWAP)`, the plist rendered from Swift's template by
CoreFoundation's writer (`arkdeck_platform::write_property_list_xml`), the
receipt as Swift's `JSONEncoder` writes it, bootout and bootstrap — and keeps the
helper it replaced one generation in `Helpers/.rollback/ArkDeckAgent.app`. It is
refused before anything changes while an OpenHarmony signing preset is installed,
since the replacement daemon's identity would have to be re-recorded in its
receipt and there is no Rust signing owner yet. `uninstall` removes the plist,
helper and receipt as Swift does, and is refused while the bootstrap bundle
registry still pins a bundle for the service installation, which this CLI cannot
release; the typed zero-Runtime `install` (bundle and tool generations pinned
through the bootstrap registries) is refused by name. The documents are Swift's;
a refusal is a stderr line and Swift's exit status with an empty stdout.

launchd is reached only through `arkdeck_platform::launchd`: fixed argument
arrays (`print`, `bootout`, `bootstrap`, `enable`) run by one fixed executable,
`/bin/launchctl`, never a shell. A home relocated with `CFFIXED_USER_HOME` never
drives the account's launchd domain: its launchd calls go only to the absolute
executable `ARKDECK_LAUNCHCTL_FOR_RELOCATED_HOME` names (never `/bin/launchctl`),
and without one they are refused before anything runs; that variable is refused
for the account's own home. Tests use injected runners or that relocated-home
executable, so no test reaches the account's service
([run record](../openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-018/runtime-service-cli-run.md),
[install and update](../openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-018/runtime-service-install-run.md)).

The M5 cutover preflight (design §G.4) is `arkdeck-agentd --cutover-preflight
[--hold-instance-lock]` with `ARKDECK_RUNTIME_COMPOSITION=production`
(`arkdeck-agentd/src/cutover_preflight.rs`): a one-shot read of the production
layout that composes nothing, refused under the facade's name and beside another
composition's input. Without any owner it reads every Job the index or `jobs/`
names (index row, record and journal), the agent executions, the capability uses
and the bootstrap tool index (`arkdeck_hoststore::cutover_facts`), decides with
`cutover_preflight`, and prints one `arkdeck.cutover-preflight/1` document: the
blocks (a blocking or unlisted Job state, the unresolved journal of a Job that is
not parked, an active agent execution, an unsettled capability use, a pending
tool selection, a source it could not read), what is carried over as it is
(parked and terminal Jobs, outcome-unknown uses) and, with
`--hold-instance-lock`, the snapshot of the old state directory (relative path,
byte count and SHA-256 of every file, and a root digest), taken under the
Runtime's instance lock before the facts are read; a Runtime still holding that
lock refuses the held pass
([run record](../openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-018/runtime-service-cutover-preflight-run.md)).

`runtime service update` asks the new helper's daemon for it: Swift's daemon
refuses the argument as unknown (exit 64) and is installed as above; the Rust
daemon answers, and installing it is the cutover. Its plist names the Rust daemon
as `ARKDECK_ANALYZER_PATH`, so that daemon is first asked to analyze a probe
listing as the Runtime runs its analyzer child (the Runtime's own runner, no
environment, the listing's `/.vol` alias) and must print Swift's recorded answer
byte for byte ("Crash-ledger analyzer mode" above, the oracle's
`runtime-service-probe` case); a daemon that does not is refused by name before
anything changes. Past that gate the lock-free pass must be clear, the old
service is booted out, the held pass must be clear too — else the old plist is
bootstrapped back unchanged — its snapshot summary is written to
`LaunchAgent/cutover-snapshots/`, and the plist asks for
`ARKDECK_RUNTIME_COMPOSITION=production`.

## macOS owner lifecycle soak

`arkdeck-soak` runs a simulated-provider workload through production Rust owners
without child processes or device access. Use a new private state directory:

```sh
cargo run --release --locked -p arkdeck-soak -- \
  --state-directory /private/tmp/arkdeck-rust-soak \
  --duration-seconds 60 --restart-interval-seconds 5 --jobs-per-cycle 10
```

It atomically writes `runtime-soak-metrics.json`, reopens owners between cycles,
verifies published Artifact evidence and journals, and fails on unresolved
intents, cleanup debt or excessive RSS/FD growth. Every cycle prints its
resident set, its growth against the first cycle, the descriptor count and the
state size, so a failed resource gate leaves a series rather than one number. The default duration is 24
hours. Unlike the Swift fixture it calls the owners directly instead of going
through the daemon's socket, so it exercises no IPC itself;
`scripts/bench capture --runtime-kind rust` uses it to seed each run's store and
then measures the isolated release `arkdeck-agentd` over its socket (SPK-11).
Neither the soak nor a capture approves a budget, commits a reference baseline
or provides hardware acceptance evidence. See
[the soak record](../openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-025/rust-soak-run.md)
and [the SPK-11 record](../openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-025/spk-11-run.md)
for validation, the three-run Rust numbers and the remaining scope.
