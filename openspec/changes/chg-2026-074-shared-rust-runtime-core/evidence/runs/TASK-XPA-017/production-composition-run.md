# TASK-XPA-017 — Standalone production composition, written and not activated

Base: protected main `afde8a42a` (#2134). G5 queue slice 6 (M5 prerequisite, M1
counting condition): `main.rs`'s third mode, the one M5's cutover points the
LaunchAgent at (design §G.1 r11, §G.4; tasks.md r11 note under TASK-XPA-017),
now composes the Runtime over the account's own state. Nothing activates it: no
LaunchAgent, plist, receipt, installed binary or service changes, and only a
process started with `ARKDECK_RUNTIME_COMPOSITION=production` reaches it.
Without that variable the standalone daemon is the read-only foundation it was
(`rust/scripts/check-readonly.py` passes unchanged). No Catalog operation,
contract input, schema, capability or trusted-fact rule, evidence format or
completion status changes. Everything below is host-process evidence under
temporary homes, never REAL_DEVICE_PASS; the Golden Journey count stays 0/5.

## The gap this slice closes

Before it, with no development root and no facade, `Host::from_environment()`
set every owner to `None` (jobs, targets, artifacts, imports, capabilities,
history, storage, …), bound a private socket under `$TMPDIR`, composed no HDC
beyond the foundation's read-only provider, and the App Mach ingress refused
any root but an isolated one (`app_ingress::Configuration::isolated`). The
binary M5 switches to could carry no Golden Journey.

| Swift production (`main.swift`, `AgentDaemon.swift`) | Rust standalone before | Rust production composition now |
| --- | --- | --- |
| State `~/Library/Application Support/ArkDeck/Agentd` (`AgentXPCContract.swift:18-27`) | none | the same, from the same home (`CFFIXED_USER_HOME` else the account's) |
| Job index `Agentd/runtime-jobs.sqlite3`, `jobs/`, `cli-job-snapshots/` (`RuntimeJobRepository.swift:52,71-139`) | none | the same, in place (`JobStore::open_state_root_owner`) |
| capabilities, targets, artifacts, agent executions, human/control action snapshots, HDC control actions, workspace projects under `Agentd/` (`main.swift:398-403,1115,1249-1284`) | none | the same paths |
| Session storage `Agentd/session-storage.json`, default root `ArkDeck/Sessions` (`main.swift:1205-1208`) | none | the same |
| History `Agentd/history-filter.json` (standalone only, `AgentFacadeHostOwnership.swift:17-21`) | none | the same |
| Bootstrap registries `ArkDeck/Bootstrap/v1` (`BootstrapBundleRegistry.swift:51-67`, passwd home) | none | the same path, from the one account home |
| Trace cache in the App container (`main.swift:1419-1423`, `ArkDeckTraceConfiguration.swift:30-48`) | none | read where the App created it, never created |
| Single instance: `Agentd/instance.lock` + `instance.json`, taken last (`AgentDaemon.swift:3844-3910`, `main.swift:1561`) | none | both locks taken first (below) |
| UDS `Agentd/agentd.sock` | `$TMPDIR/arkdeck-rust-<uid>/control.sock` | `Agentd/agentd.sock` |
| HDC: `ARKDECK_HDC_PATH` → `BootstrapToolRegistry` adoption → startup selection → `HeadlessHDCServerHost` (`main.swift:462-584`) | read-only provider from `ARKDECK_HDC_PATH`+`ARKDECK_HDC_SHA256` | registry adoption and startup selection → `ManagedHdc` (#2131 semantics) |
| USB: `TargetUSBRelation.registeredDAYU200()` (`main.swift:1246-1248`) | none | none yet (#2135 open); adoption refused, stated at start |
| Code-sign helper `HDCNativeCodeSignHelperArtifact.bundled()` | bundled | bundled |
| `recoverActiveJobs`, Artifact GC (`main.swift:1289,1326`) | none (no Job owner) | the shared startup recovery and sweep |
| App Mach service `com.arkdeck.agentd`, `appCodeRequirement`, euid (`AgentXPCListener.swift:20-40`) | refused (isolated root only) | served over the account's own home |

## Swift semantics that decide the design

- Swift's daemon flocks the file `Agentd/instance.lock` (`O_WRONLY|O_CREAT|O_NOFOLLOW`,
  0600, `LOCK_EX|LOCK_NB`); the Rust facade flocks the `Agentd` directory itself
  (`LocalListener::bind_facade`). Neither lock blocks the other: a facade is kept
  off a standalone Swift daemon only by its live-socket probe.
- Swift takes its lock last, inside `server.start()`, after it has opened every
  store, started its HDC server and `arkforged`, recovered Jobs and swept
  Artifacts (`main.swift:1289,1326,1561`); holding the lock it `unlink`s whatever
  is at `agentd.sock` without a probe (`AgentDaemon.swift:3875`). A second
  instance prints `arkdeck-agentd already running: pid <p>, socket <s>, protocol
  <v>` from the holder's `instance.json` and exits 0 (`main.swift:1581-1592,1652-1655`);
  a lock held without a readable document throws, exit 1. `instance.json` is
  `{pid, protocolVersion, socketPath, startedAtUTC}`, sorted keys, never removed.
- Behind the facade the Swift child takes the same `instance.lock` in the default
  state directory and registers no Mach service (`main.swift:1570`).
- Only `ARKDECK_HDC_PATH` configures HDC; once the registry holds a selection the
  path is not read again. Without it the daemon starts with a refusing
  dispatcher. Every composition failure exits 1.

## What this slice changes

`rust/crates/arkdeck-agentd/src/production.rs` (new), wired into `main.rs`:

1. **Selection.** `ARKDECK_RUNTIME_COMPOSITION` accepts only `production`. With it,
   `ARKDECK_DEVELOPMENT_STATE_ROOT`, `ARKDECK_ENDPOINT`, `ARKDECK_SWIFT_DAEMON`,
   `ARKDECK_SWIFT_SHA256`, `ARKDECK_PRIVATE_SOCKET`, `ARKDECK_HDC_SHA256`,
   `ARKDECK_APP_INGRESS` and the facade executable name refuse the start; every
   development HDC/USB/code-sign/mutation input stays refused by `main.rs` as for
   any composition without a development root. A relative `ARKDECK_HDC_PATH` or
   `ARKDECK_ANALYZER_PATH` is refused before anything is created. Off macOS the
   variable refuses the start.
2. **Layout.** `Layout::account()` derives every root from `runtime_home()` — the
   home Swift's Foundation resolves — as in the table above.
3. **One authority (`claim`).** Before any store is created or probed:
   (a) `Agentd` is created owner-only as Swift's server creates it;
   (b) Swift's `instance.lock` is taken with Swift's flags (`HostDirectory::lock_document`);
   (c) the facade's directory lock is taken and the installed socket bound
   (`LocalListener::bind_facade`: a socket that answers is refused, one that
   refuses connections is reclaimed);
   (d) `instance.json` is written naming this process. Both locks are held until
   exit. Outcomes:
   - instance lock held and its document decodes → Swift's `already running` line,
     exit 0, nothing composed (the second instance only opened the lock file);
   - instance lock held without a document → exit 69, "left no instance document";
   - the facade's lock held, or a live listener on the socket → exit 69 naming it,
     the instance lock let go of;
   - otherwise owned.

   **Choice when Swift runs: refuse, never stand by.** A standby would have to
   read another authority's stores — Swift's reads are not side-effect free (it
   reseals payloads, writes verification files) — could not serve the socket that
   authority holds, and would widen the authority set this change must narrow.
   The start is refused before anything is composed, as Swift's own second
   instance refuses, and more strictly than Swift, which composes, starts HDC and
   recovers Jobs before it learns it is second. A lock is released only by the
   holder's exit, so a M5 cutover must stop the old service before it starts this
   one (§G.4), and a rollback the reverse.
4. **Owners (`compose`).** The owners the isolated owner composes, at Swift's paths:
   Targets, History, workspace projects (DevEco pinning in the bootstrap
   registry, no credential owner), Imports, Artifacts, Session storage and
   Artifact usage (quota 8 GiB), bootstrap readers, Jobs (in place at the state
   root), agent executions, human actions, control actions (with the HDC
   control-action owner beside a managed server), capabilities, planning (the
   state root's debug attempt permits, `ARKDECK_ANALYZER_PATH`), the Trace cache
   when the App created it, and the mutation-continuity root = `Agentd` (the Job
   owner's root, as `require_mutation_state` requires). `code_sign_helper::bundled()`
   is composed as in every mode.
5. **Job owner in place (hoststore).** `JobStore::open_state_root_owner` /
   `JobRepository::open_state_root_owner`: an existing index opens exactly as
   `open_owner` opens one; a first index is created beside the other owners'
   entries where Swift creates one (no Job history in `jobs/`, no retired
   `idempotency.json`), and beyond Swift only while the Rust owner's lock is
   unmarked and no WAL, shared-memory index or rollback journal of a lost index
   remains. `open_owner` keeps its dedicated-directory rule.
6. **HDC.** With `ARKDECK_HDC_PATH`: `registered_hdc` adopts the file into
   `Bootstrap/v1` while no selection exists (`adopt_installed_hdc`), then starts
   the registry's startup selection — its retained copy, never the configured
   path once selected — as the managed server on Swift's endpoint
   (`OHOS_HDC_SERVER_PORT`, else 127.0.0.1:8710) through `ManagedHdc` (#2131: a
   held endpoint refuses before any launch; a normal stop ends a proved
   replacement), with the exit-70 monitor, `hdc-control-actions` and the
   process dispatch every plan takes. A pending tool selection refuses the start
   and is left as it is (no tool-selection owner is ported to settle it).
7. **App ingress.** `app_ingress::Configuration::production(state)`: the fixed
   `com.arkdeck.agentd`, the unchanged `APP_REQUIREMENT` and the owner's euid,
   over the account's private physical state root; only the isolated-root rule is
   dropped. It is not composed when `CFFIXED_USER_HOME` overrides the home: that
   home's Mach service is not the account's, so no test ever registers it.
8. **Start-up output** (stdout, flushed): `production composition over <state>`,
   one `composes no …` line per omission with its reason, `owners: …` (the
   `Host::owner_census`), Swift's `recovered N active job(s)…` when any,
   `App ingress: com.arkdeck.agentd` when served, then Swift's
   `listening on <socket>`. Each Swift LaunchAgent input for an unported owner
   (`ARKDECK_ARKFORGE_*`, `ARKDECK_ARKTRACE_DESCRIPTOR`,
   `ARKDECK_WORKSPACE_*`, `ARKDECK_DEVECO_SDK_HOME`) is named, not ignored.

### Fail-closed paths

| Precondition | Answer |
| --- | --- |
| another Runtime holds `instance.lock` (its document names it) | `already running`, exit 0, nothing composed |
| `instance.lock` held, no document | exit 69, nothing composed |
| the facade's transport lock held / a live listener on `agentd.sock` | exit 69, nothing composed, instance lock let go of |
| `Agentd` not a private physical owner-only directory | exit 69 (`HostDirectory`/`bind_facade`) |
| `ARKDECK_HDC_PATH` without a published identity, a broken selection or a pending one | exit 69 before any server is launched |
| the endpoint already held | exit 69 (#2131 `StartFailure::Occupied`), nothing launched |
| a store unreadable, a Job index that would hide lost history | exit 69 |
| startup recovery fails | exit 69, as Swift's start fails |
| no `ARKDECK_HDC_PATH` | serves; dispatch refused, `device.observations` refused, `runtime.hdc.status` unconfigured |
| no USB relation reader (beside a managed HDC) | serves; every observation stays generation-scoped, so the Target observation owner refuses adoption |
| no App Trace cache | serves; `trace.cache.status` and `.purge` refused (`rejected`, not configured, zero dispatch) |
| overridden home | serves; no Mach service |

### Declared differences from Swift

- Both locks are taken before anything else; Swift composes first and locks last.
  The facade's directory lock is taken too, which Swift's daemon never takes.
- A live listener on `agentd.sock` refuses the start; Swift unlinks it unprobed.
- Exit 69 where Swift exits 1 for a failed start (the Rust daemon's startup code).
- `instance.json` is published atomically, owner-only, with unescaped slashes;
  Swift writes it in place with Foundation's `\/`. Both decode it.
- Bootstrap resolves from the same home as every other root; Swift's registry
  uses the passwd home even under `CFFIXED_USER_HOME`. Identical for the account
  itself; an overridden home never reaches the account's registry here.
- `Agentd` must be a canonical owner-only 0700 directory (`HostDirectory`,
  `bind_facade`); Swift re-checks nothing in standalone mode.
- The registered HDC's retained dependencies are verified by the registry at
  start (`startup_selection` → `verify`), and its executable before each
  dispatch; Swift's resolver re-hashes the dependencies before each launch too.
- A fresh Job index is also refused beside a WAL, shared-memory index or
  rollback journal of a lost one.

## Not composed, and why

- **Trusted USB relations**: `UsbRegistryRelations::system()` is #2135 (open at this
  base). Until it merges, target adoption stays refused and the start says so;
  the follow-up is one line beside the managed registered HDC.
- **Tool-selection control actions** (`runtime.tool.select`): no Rust owner in any
  mode; a pending selection refuses the start.
- **ArkForge lane, `flash.*`, Rockchip binding lineage and post-flash alias
  reconciliation at start** (M4), **workspace operations provider, signing
  credential owner** (M3/Q8), **debug invocation controller**
  (`debug.start/status/evaluate`), **Trace inspection / ArkTrace loader**:
  unported; their LaunchAgent inputs are named at start.
- **Analyzer**: `ARKDECK_ANALYZER_PATH` names an executable run as
  `--analyze-crash-ledger`; today's plist names the Swift daemon, and the Rust
  binary has no analyzer mode, so M5 must decide the analyzer executable.

## Tests

- `tests/production_composition.rs` (8, the real binary, environment cleared,
  `CFFIXED_USER_HOME` under `/private/tmp`, serialized): every owner composed and
  answering over `Agentd/agentd.sock` (`job.list`, `target.list`,
  `artifact.quota`, `capability.list`, `agent.list`, `human-action.list`,
  `control-action.list`, `workspace.project.list`, `artifact.import.list`,
  `history.filter.*`, `runtime.storage.status` naming the home's `Sessions`,
  `runtime.hdc.status`, `operation.list`, `doctor`), every created entry
  owner-only below the home, the App container untouched, state kept across a
  SIGTERM stop and restart; the Trace cache composed where the App created it and
  nothing added there; a second daemon answers `already running` and changes
  nothing; Swift's held lock refuses before anything is created (and without its
  document, exit 69); the facade's lock refuses the start, and the serving daemon
  refuses the facade and Swift's lock; a live listener refuses, a stale socket is
  reclaimed; 15 other-composition or malformed inputs refused with nothing created;
  an unpublished HDC refused without ever being executed; a Job parked at the
  state root before the start is carried over by startup recovery, reconciled and
  its Session published in the home's `Sessions`, the analyzer never re-run.
- `production::tests` (7): Swift's exact relative paths below any home; the mode
  and refused inputs; the claim's lock, transport, document and release; the
  refusals; a Swift-shaped document with escaped slashes; registry adoption of
  the Swift-recorded published executables (`tool-selection-registry` oracle),
  the configured path ignored once selected, an unpublished one and a pending
  selection refused; `compose`'s owner census, mutation root and omissions, and
  the ingress composed only over the account's own home.
- `app_ingress::tests::production_tests` (2): the fixed service and requirement
  through a recording listener seam, the euid/PID/console refusals before
  Control, a private physical state root required.
- hoststore `tests/job_owner.rs`: the state-root placement creates its index
  beside other owners while the dedicated one refuses, and refuses lost history
  (marker, Job directory, WAL/SHM/journal, retired ledger) leaving it unchanged.
- Mutations, each caught and restored by checksum: no Swift instance lock (3
  process tests), `bind` instead of `bind_facade` (2), dedicated Job placement (6),
  pending selection ignored (1 unit), `ARKDECK_ENDPOINT` accepted (1), state root
  treated as dedicated (1 hoststore), companion check removed (1 hoststore).

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`, `CARGO_BUILD_JOBS=2`;
logs `/private/tmp/arkdeck-s13-*.log`.

- `cargo fmt --all --check`: 0.
- `cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings`
  (hoststore's direct dependents are agentd and soak; agentd has none): 0;
  again for `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` on hoststore and agentd: 0.
- `cargo build -p arkdeck-cli` then `cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --no-fail-fast`:
  0 — 72 result lines, 606 passed, 0 failed, 14 pre-existing ignored.
- `cargo test -p arkdeck-agentd --test production_composition`: 0 (8 passed).
- `check-readonly.py --bin-dir …/debug` (validation venv): 0 — the default
  standalone answers every method as before; crate boundaries unchanged.
- After every run: no orphaned fake HDC server, no temporary home left; the
  installed Swift daemon and HDC were not touched.
- Not run: `generate-contract.py --check` and `check-contracts.py` (no contract
  input changed), Swift/App (no Swift change), signed-App Mach acceptance and
  any device.

## CI

Pending.
