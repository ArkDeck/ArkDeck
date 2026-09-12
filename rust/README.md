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
and validates schemas after all commands finish and the daemon exits. On Unix it
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
refuses incomplete inventories. This development daemon has no active jobs;
installed integration must supply the actual Job owner's active-session set.
Cleanup apply remains unavailable. The process harnesses
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

## Contract and ownership boundaries

The isolated macOS host also serves `trace cache status` from its fixed
`trace-cache` directory. It reports actual byte counts and respects the existing
key locks and entry leases; unaccounted entries remain active. Callers cannot
pass a cache path, and Session root selection excludes this cache directory.
Unsafe entries or a replaced root refuse the read. `trace cache purge`, database
preparation and installed cache ownership remain pending.

Run `python3 rust/scripts/check-trace-cache-owner.py` after building the binaries
to check real RPC/CLI status, lease contention, restart and namespace refusals.
Use `--cli-path Packages/ArkDeckKit/.build/debug/arkdeck` for the current Swift
CLI consumer. The harness uses temporary host fixtures and performs no purge.

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
Session cleanup preview holds a complete Job activity census and retains parked
unknown outcomes. This read phase refuses unsupported optional authority and
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
