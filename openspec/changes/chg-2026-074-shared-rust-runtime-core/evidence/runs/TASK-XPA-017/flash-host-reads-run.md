# Flash host reads on the Rust daemon (TASK-XPA-017, M4-1a)

The Rust daemon now answers three of M4's methods, which read or repair what the
Runtime keeps about a Rockchip board without contacting the board:

- `flash.reconcile-alias`: repairs a post-flash alias whose revision counter
  was reissued;
- `debug.status`: reads one protected Flash recovery invocation;
- `recovery.flash-invocation.list`: pages through those invocations.

The Rust CLI serves the matching leaves:

- `arkdeck flash reconcile-alias`;
- `arkdeck recovery flash-invocation list|status`;
- the legacy `arkdeck debug status`.

A new Swift oracle records 61 exchanges, the files the reconciler leaves, and
the invocation documents Swift's broker wrote. The Rust daemon replays all of
it byte for byte.

Base: protected `main` `0e833256` (#2147). Routed methods: **97/105** (94
before). The eight still unrouted are the seven other M4 methods and
`trace.inspect` (M3). Executable operations are unchanged at 15/30.

| Already on `main` | This change | Still remaining (M4) |
|---|---|---|
| The post-flash alias record, its store and its reissued-lineage reconcile, replaying `post-flash-alias` (#1939–#1941, #2045); the snapshot pager; the Runtime's own I/O Registry census (#2135, #2137) | The Swift oracle `flash-host-reads`; the method-level reconciler (Target CAS, the one HDC-normal board from the census, the store's reconcile, Swift's refusals); the invocation reads (document validation as `CurrentDurableJSON`, status projection, paged list); both composed in the isolated and the production compositions; the three routes; four CLI leaves; widened `debug.status` and list schemas | `flash.bootloader-status` and `flash.prerequisites` with the Rockchip binding store (M4-1b); `flash.device-access` and the ArkForge lane (M4-2); `flash.lanePlanPreview` (M4-3); `flash.bind-current-loader`, `debug.start`, `debug.evaluate` and the two flash operations (M4-4) |

## The oracle

`FlashHostReadsOracleContractTests` drives Swift's `RuntimeControlPlaneHandler`
through the owners the daemon composes for these methods:

- `ProductRockchipPostFlashAliasReconciler`, over `RuntimeTargetStore` and the
  `RockchipPostFlashHDCBindingStore` of an Application Support root (the parent
  of the state directory, as `main.swift` composes it);
- `RuntimeDebugInvocationController`, over the state directory.

The oracle injects three things, and nothing else:

- the USB census, in place of the I/O Registry;
- the reconciler's clock;
- the attempt driver behind the controller: a plan-only preview with one
  destructive step, and scripted execution outcomes. This is mechanical
  contract evidence, never device evidence.

It records `rust/tests/fixtures/flash-host-reads/`.

**`flash.reconcile-alias`: 21 exchanges in order over one root.** After each
step it records every file of the Application Support root, with its mode and
size (`steps/`). The exchanges:

- each parameter refusal;
- a Target that was never adopted, a stale revision, and an empty identity;
- a census with nothing attached, a Loader only, two boards, and a registry
  that cannot be read;
- no stored alias, an alias that is not ahead, and one naming another
  topology or another Loader identity;
- an archive name already holding a different entry;
- the reconciliation itself: the archived epoch, and the alias republished at
  the live revision naming itself as its previous alias;
- the repeat;
- four unreadable alias documents: a shared mode, not JSON, another schema,
  and an empty file.

**`debug.status` and `recovery.flash-invocation.list`: 40 exchanges.**

With the record variable set, the oracle starts nine invocations through the
controller and drives their evaluations. The nine are:

- active;
- observed;
- stopped;
- a destructive epoch that was safe to reflash, followed by one whose outcome
  is unknown;
- succeeded;
- blocked;
- refused before dispatch;
- `flash.full-restore@1`, created in the same second as another invocation;
- expired.

It keeps the documents as the oracle's inputs, because the controller mints a
random identity. In compare mode the oracle installs the recorded documents,
re-answers every exchange, and compares byte for byte.

The exchanges cover:

- empty and full lists, three pages, and a cursor from another query;
- every page-size and cursor refusal;
- the status of each document;
- identities that are unknown, invalid, or over the bound;
- documents derived byte for byte from the recorded ones, which the reads
  refuse:
  - an unknown key, a duplicate member, or an explicit null: answered as
    absent, as Swift answers them;
  - another schema, another identity, or an epoch count over the budget;
  - a shared mode, an empty file, or a link;
- an unknown entry and an invalid identity in the directory;
- a shared directory.

The pager's random revision is recorded as `<snapshotRevision>` and each next
cursor as `<nextCursor-N>`, where N is the exchange that returned it; the
replay sends its own cursor in its place. The recording ran once. It was then
compared twice in verify mode and once with `--parallel --num-workers 2`,
byte for byte.

## Swift, as ported

**`flash.reconcile-alias`** (`FlashAliasReconciler`, `flash_alias_reconcile.rs`)

- *Parameters.* The route checks both parameters before the owner, as Swift's
  handler does. `targetId` must be a string, and `expectedBindingRevision` a
  positive integer as Foundation reads it (`2.0` counts; a string or a
  fraction does not). Extra parameters are ignored.
- *Target check.* The owner then compares the caller's revision with the
  Target record, aliases included, read from this host's Target store.
- *Census.* It reads the census and keeps the registered DAYU200 devices: a
  Loader (`0x2207:0x350a`), or HDC-normal (`0x2207:0x5000` named `HDC Device`
  once quotes and spaces are trimmed). It requires exactly one, not a Loader.
- *Store.* It calls the store's reissued-lineage reconcile under its lock.
- *Refusals.* Each refusal is `rejected`, with Swift's interpolation of its
  error:
  - `admissionRejected("…")`;
  - `productionConfigurationUnavailable("…")`;
  - `storeFailure("…")`.
- *Store error details.* The store's read refusals now name Swift's four
  details instead of one: cannot be opened, not an owner-only regular file,
  size is invalid, is truncated. `HostDirectory::read_owner_only_detailed`
  names which check refused.

**`debug.status` and `recovery.flash-invocation.list`** (`FlashInvocations`,
`flash_invocations.rs`)

- *Parameters.* Both routes reach the owner before any parameter is judged,
  and the owner checks them in Swift's order.
- *Identity and directory.* An identity outside `^[a-z][A-Za-z0-9.-]*$` or over
  128 bytes is `notFound` without touching the disk. The directory must be the
  effective user's, not a link, and closed to group and others.
- *Document file.* The document is opened through no link. It must be a
  private, single-link regular file of 1 byte to 16 MiB.
- *Decoding.* The bytes are decoded as `CurrentDurableJSON`: no duplicate
  member, then each typed field, then the JSON must equal what the typed
  document encodes back to. The seed request is re-encoded through
  `OperationRequest`. A failure at any of these steps is `notFound`, as in
  Swift.
- *Content checks.* Another schema, another identity, or an epoch count
  outside 0…16 is `recordUnreadable` (`persistenceFailure("invalid invocation
  document")`).
- *Status.* Status projects Swift's `RuntimeDebugInvocationStatus`, including
  the evaluations as stored.
- *List.* The list builds a fixed snapshot of compact rows: newest first, ties
  by identity, 100 per page unless a page size is given.
- *Errors.* The broker's refusals carry no details. The pager's carry empty
  details, and an invalid cursor uses Swift's words. The owner serializes its
  requests, as Swift's actor does, so the pager keeps no lock document.

**Compositions**

- *Isolated development owner.*
  - Invocation documents live beside its Job state (`root/jobs-state`). Its
    root stands for the Application Support root, as Swift's is the state
    directory's parent.
  - The reconciler reads the board from the Target observations' own source:
    - the host's I/O Registry, beside the managed registered HDC;
    - the harness's relation file, where one is named. A relation of the
      normal product is the HDC-normal personality, and one of the Loader
      product is the Loader;
    - otherwise no device.
- *Production composition.* It is written, not activated:
  - the documents live in `…/ArkDeck/Agentd`;
  - the alias lives in `…/ArkDeck` (`Layout::application_support`);
  - the census is the host's I/O Registry, as Swift's `RockchipProductUSBProbe`
    reads it (Q1=B);
  - both invocation directories are created owner-only at the start, as
    Swift's controller creates them.

The owner census names `flashAliasReconciler` and `flashInvocations`. A host
without the owners answers as Swift's daemon without them (`internalError`,
"… is not configured").

## Declared differences

Each is either fail-closed or T2 prose:

- **Unreadable Target store.** Rust answers
  `storeFailure("undecodable target store: <Rust's reason>")`. Swift's inner
  text is Foundation's own decoding description (T2). Rust's Target document
  validation, already on `main`, is stricter than Swift's decoder.
- **Census invalidated mid-enumeration.** Rust refuses with `USB registry
  unavailable`, where Swift would use the partial list (fail closed).
- **Pager storage faults.** The pager's own storage refusals keep Rust's
  generic words ("Session snapshot storage is unreadable or unsafe") with
  Swift's code and empty details. Swift names each fault (T2). Its per-row
  bound is two bytes stricter than Swift's; the pager is unchanged here.
- **Two faulty directory entries.** Rust reads the invocation directory
  sorted, where Swift's order is the file system's. With one faulty entry the
  answer is identical. With two, which one is named may differ (the same
  refusal family).
- **Directory listing failure.** It answers `internalError` with Rust's
  I/O text (T2).
- **Two post-flash store differences already on `main` (#1941).** A symlinked
  Application Support root is resolved rather than refused. The lock file
  needs only to be closed to group and others.
- **The CLI's legacy `--json`.** It stays refused for these leaves, as for
  every served leaf except `debug probe` and the service leaves. The registry
  lists it for 189 of its 209 leaves.

## Contract

Only append-only corpus lines and widened schemas. Contract identity is
unchanged.

**Corpora.** They grow by 18 lines, one per shape they lacked. Every committed
line is kept verbatim:

- `debug.status`: +7;
- `recovery.flash-invocation.list`: +10;
- `flash.reconcile-alias`: +1.

**Schemas.** The derivation used the committed corpus plus the 61 recorded
frames, for these three methods only. A second derivation from the final
corpus alone produced the same `$defs`:

- `debug.status`: an evaluation no longer requires `observation`, and may
  carry `destructiveEpoch`, `requestID`, `idempotencyKey`, `jobID` and
  `outcome`. The execute evaluations have them.
- `recovery.flash-invocation.list`: the request may carry `cursor`,
  `nextCursor` may be a string, and `invalidCursor` joins the codes.
- `flash.reconcile-alias`: `$defs` are unchanged, so the file is left as it
  was. Only its sample counts would have moved.

`rust/scripts/generate-contract.py --write`, then `--check`: 105 methods,
976 recorded shapes.

## CLI

The four leaves are one request each (Swift `runFlashObservation`,
`emitFlashInvocation`):

- `flash reconcile-alias --target <id> --expected-binding-revision <n>`: the
  revision is sent as an integer;
- `recovery flash-invocation list [--page-size <n>] [--cursor <c>]`: the page
  size defaults to 100, as Swift sends it;
- `recovery flash-invocation status --invocation <id>`;
- `debug status --invocation <id>`.

The last two both send `debug.status`.

The legacy `debug status` gets Swift's §12 lifecycle:

- every machine answer carries `meta.lifecycle` (`legacy`, its replacement
  pattern, `removalVersion` null);
- parse failures included;
- in the human rendering, a warning on stderr.

The four leaves' Swift argv fixtures are copied unchanged into
`rust/tests/fixtures/current-cli-argv/`, and replay with no deviation.

The CLI audit (`TASK-XPA-018/cli-parity-audit.py` over this build) now counts
the 256 feature entries as follows:

| Category | Entries |
|---|---|
| implemented | 157 |
| leaf missing, daemon routed | 56 |
| daemon or host owner missing | 28 |
| tombstone per §12 | 15 |

`debug.status`, `flash.reconcile-alias` and
`recovery.flash-invocation.list` are among the implemented ones.

## Verification

**Local targeted checks.** `CARGO_BUILD_JOBS=2`, own target
`/private/tmp/arkdeck-m4-rust-target`, logs `/private/tmp/arkdeck-m4-fhr-*.log`.

| Check | Command | Result |
|---|---|---|
| Swift recording | `ARKDECK_RUST_FLASH_HOST_READS_RECORD=… ARKDECK_CONTROL_FRAME_LOG=… run-swiftpm.sh test --jobs 2 --filter FlashHostReadsOracleContractTests` | exit 0; 61 frames (`fhr-swift-record.log`) |
| Swift verify | the same filter twice without the record variable, then `--parallel --num-workers 2` | exit 0 each (`fhr-swift-verify-{1,2,parallel}.log`) |
| Rust replay | `cargo test -p arkdeck-agentd --bin arkdeck-agentd flash_host_reads` | exit 0; 3 passed (`fhr-rust-2.log`) |
| CLI | `cargo test -p arkdeck-cli` | exit 0 (`fhr-cli-1.log`, `fhr-cli-4.log`) |
| fmt | `cargo fmt --all --check` | exit 0 |
| clippy | `cargo clippy -p arkdeck-platform -p arkdeck-provider-hdc -p arkdeck-hoststore -p arkdeck-control -p arkdeck-contract -p arkdeck-agentd -p arkdeck-cli -p arkdeck-soak -p arkdeck-provider-workspace -p arkdeck-client --all-targets -- -D warnings` | exit 0 (`fhr-clippy.log`) |
| Crate tests | `cargo build -p arkdeck-cli -p arkdeck-agentd`, then `cargo test -p arkdeck-platform -p arkdeck-provider-hdc -p arkdeck-hoststore -p arkdeck-control -p arkdeck-contract -p arkdeck-agentd -p arkdeck-cli -p arkdeck-soak --no-fail-fast` | 164 suites passed, 3 failed (`fhr-tests.log`): the production owner census asserted in two process tests, and the control test listing unrouted methods, each expecting the owners this change adds; corrected, the two targets pass (`fhr-tests-fix{1,2}.log`: 9 and 25 passed) |
| Mutations | the replay with each of six mutations: the durable round trip skipped, a Loader taken for the HDC-normal board, the Target revision compare-and-swap skipped, a shared invocation directory read, ties ordered against Swift, the store's refusals collapsed | 6/6 caught; every source restored by digest (`fhr-mutations.log`) |
| Schemas | every one of the 61 recorded frames and the three corpora against the committed schemas, jsonschema 4.26.0 | 177 values, 0 refusals |
| Swift schema contract | `ARKDECK_CONTROL_FRAME_LOG=<the 61 frames> run-swiftpm.sh test --filter 'ControlMethodSchemaContractTests\|FlashHostReadsOracleContractTests'` | exit 0; 6 tests (`fhr-swift-schema.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0; 0 errors, 0 warnings (`fhr-sdd.log`) |
| Contract | `python3 rust/scripts/generate-contract.py --write`, then `--check` | exit 0 |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv): every method against the standalone daemon without the new owners, plus the reconciler's missing owner | PASS on macOS (`fhr-readonly.log`); the first push of this PR was red here, the three routes' answers not yet registered |
| Published view | main's `debug.status` and list schemas compiled in and `published_view()` forced, the agentd replay and the CLI leaf tests run, the sources restored by digest | 3 and 4 passed (`fhr-pubsim.log`) |
| Check scripts | `rust/scripts/test_contract_checks.py` | 42 tests OK |

**CI.** PR #2148 (recorded in the next slice, M4-1b):

- head `5036b734`: Swift CI run 36033785541 was cancelled by the next push
  after its Rust host-independent checks went red (`check-readonly.py`
  expected the three routes' old answers); SDD Guard 36033784910 green;
- head `71d37ded`: SDD Guard run 36035407500 `guard` success; Swift CI run
  36035407790 success — the `swift` aggregate, `swift-tests`,
  `ds-interactions`, the Rust host-independent checks and the Rust
  workspace on ubuntu-latest, macos-26 and windows-latest; `app-build`
  skipped by the plan;
- squash-merged by the coordinating session as `main` `7f8e3d71`
  (2026-09-24T18:06:02Z).

No device, installed service, ArkForge daemon or App was used, and nothing
here is device evidence.
