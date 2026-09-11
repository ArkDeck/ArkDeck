# Rust runtime development

TASK-XPA-002 supplies a separate development daemon and the `doctor`,
`operation list` and `device candidates` CLI leaves. It consumes the current
protected-main Swift contract pinned in
[`spec/baselines/swift-single-v1.json`](../spec/baselines/swift-single-v1.json).
This pin is a development baseline. SVC release acceptance, Windows platform
acceptance and production Runtime migration remain separate requirements.

## Build and check

From `rust/`, rustup selects the committed Rust 1.98.0 toolchain:

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
Every other check reads Git objects at the pinned commit or regenerates its own
source view, so a workspace that does not build, or whose tests fail, passes
them all.

The Python checks require Python 3.11+ with `PyYAML==6.0.3` and
`jsonschema==4.26.0`. The repository's unified planner also runs these checks,
`cargo deny` and `cargo vet`; see [dependency policy](supply-chain/README.md).
The committed policy combines imported source audits with nine bounded publisher
trust entries and no exemptions. Both dependency checks must pass.

The shared runner checks two independent temporary source views: current Rust
against the published Git inputs, and current Rust against the candidate inputs.
Each runs clippy, the full test suite, native process checks, binary builds and
the same black-box check. Candidate generation stays in its temporary view;
it cannot update the published pin. Both views replay every recorded shape and
verify their exact input hashes, directory membership and per-method counts.
The current pin and recorded shape count are in
`spec/baselines/swift-single-v1.json`. Re-pin with
`python scripts/generate-contract.py --write --baseline-revision <commit>`
whenever a merged Swift change edits a consumed input; the corpus parity tests
refuse a stale pin.

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
Swift RPC producers supply actual recording-backed candidate contracts; the old
published pin remains unchanged until the reviewed contract merge is re-pinned.
Registration, selection, write ownership and installed activation remain pending.

`cargo build -p arkdeck-hoststore --example tool_registry_read` builds the local
comparison adapter. Set `ARKDECK_TOOL_OWNER_BINARY` to it when running
`BootstrapToolRustOwnerTests` to compare a real Swift registration with Rust.

The macOS `ArtifactReadStore` library lists, inspects and reads existing Job
Artifact publications with full-payload digest verification and bounded range
allocation. Typed inspect/read result conversion matches actual Swift producer
recordings, including missing content and observation windows. It preserves the
frozen index format and never writes verification caches. Runtime routing, Job
existence checks, import leases and Artifact write ownership remain pending.
`python3 rust/scripts/check-artifact-read-owner.py` runs its targeted host checks.

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

The published pin has 97 methods; the candidate registry adds two Bootstrap
inspection methods. Methods without a migrated host handler are structurally
understood and refused.
There is no Runtime capability owner, recovery, journal, durable target store,
device mutation, flash lowering, Swift replacement or production cutover here.
Unknown or incomplete outcomes never acquire invented zero-dispatch evidence.

Catalog generation preserves the same canonical source bytes and SHA-256 as
Swift. The CLI canonical encoder preserves the current Swift vectors, including
its existing binary64 spelling below `1e-4` and above the Int64 fast path. Swift
currently emits `1e-6` and `1e+20` where RFC 8785 would use decimal notation.
Native Swift boundary vectors pin that known difference; this phase does not
claim universal RFC 8785 conformity or change Swift semantics independently.
The generated baseline records every consumed schema, corpus, source and fixture
digest. `generate-contract.py --check` reconstructs that pin and its generated
bindings from immutable Git objects and verifies the commit is in `origin/main`
history. Candidate files can differ; `check-contracts.py` must also pass against
those current inputs. Unsupported schema vocabulary, stale Catalog output and
native Swift oracle source drift remain failures. A candidate manifest is always
marked `candidate` and names its source revision and input digest separately from
the published commit. No runtime protocol negotiation or version fallback is added.

Updating the pin uses `python scripts/generate-contract.py --write
--baseline-revision <published-commit>` after publication. Keep `origin/main`
available locally so publication ancestry can be checked. Generation and host
conformance remain separate from actual device acceptance.
