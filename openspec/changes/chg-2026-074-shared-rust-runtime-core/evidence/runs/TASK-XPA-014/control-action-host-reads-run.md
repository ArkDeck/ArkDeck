# TASK-XPA-014 — the HDC control-action owner over the managed server: impact previews and the reads (macOS, 2026-09-19)

TASK-XPA-014 remains in progress. Base: protected main `9c58e484` (#2012, the with-host frames and
schemas this slice answers under); no stack. Every answer here is synthetic host data; nothing is
device evidence (POL-VERIFY-001, POL-MODE-001). No Swift source, control schema, corpus, Catalog,
entitlement, `openspec/specs` or constitution change.

This is C1 of the control-action work on the isolated daemon. With
`ARKDECK_DEVELOPMENT_HDC_SERVER=managed` the isolated owner now answers
`runtime.hdc.impact-preview` and the durable control-action reads (`control-action.list`, `.show`,
`.reconcile`) as Swift's daemon does once its HDC server host has started. Restart, the impact
approval human action and its console challenge, the Job admission interlock, the lifecycle
supervisor and executor, and the recovery of an interrupted lifecycle are C2.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining |
| --- | --- | --- |
| The union control-action owner over no HDC owner and the routes (#2003); the managed server, its status and the daemon's stop (#2004); the with-host frames and the four widened schemas (#2012) | `arkdeck-hoststore`: the HDC control-action owner (`hdc_control_action.rs`) and the managed server's impact source (`hdc_impact_source.rs`), the Job owner's current Jobs and the Target store's records for it; the union owner routing to the HDC owner; `arkdeck-agentd`: the composition beside the managed server and the source over the daemon's owners; every with-host corpus exchange replayed but the approval request | C2: `runtime.hdc.restart` and its impact approval, the console challenge, the Job interlock, the supervisor, executor and lifecycle audit; the recovery of an interrupted lifecycle (design §L.1 item 13, ruled on 2026-09-19 in #2016: port the named carriers unchanged); the tool-selection owner; device rows and a critical Job gate with a reason in the published schemas |

## What Swift does (the map this slice ports)

Line numbers are on the base.

- **Routes.** `AgentDaemon.swift:412-413` routes the five methods to `hdcControlActionRequest`
  (2990-3068): the HDC owner's presence first for the lifecycle methods, then
  `preview(fields)`; show and reconcile check one exact identity, then the union owner; the list
  checks its fields, page size and cursor bound, then the union owner. Any failure that is not an
  owner's refusal is `recordUnreadable` "control-action state cannot be read or persisted"; every
  refusal carries `newDispatchCount: 0`.
- **Composition.** `ArkDeckAgentDaemonMain/main.swift:1246-1281`: the host's impact source
  (`HeadlessHDCServerHost.controlImpactSource`, `HeadlessHDCServerHost.swift:305-310`), the HDC owner
  in `<state>/hdc-control-actions` with `RuntimeOperationCatalog.catalogDigest` and a fresh epoch per
  start, the union owner over it and the tool-selection owner in `control-action-snapshots`. Swift's
  production host refuses an unregistered HDC; `startTestFixture` (`HeadlessHDCServerHost.swift:162`)
  is the counterpart of the isolated owner's managed fake.
- **Preview** (`HDCControlActionCoordinator.swift:40-55, 275-303`). The exact intent
  (`HDCControlActionContract.swift:10-20`); an action of the same request identity wins (another
  intent is `idempotencyConflict`); another endpoint is `resourceNotFound`; `store.begin` persists
  an `observing` action (generation 1, expiring 300 s after creation); one reading of the impact
  source then either invalidates it (`previewDrifted`, `hdc.impactObservationUnavailable`, no
  preview) or publishes the immutable preview (`HDCControlActionRecord.swift:329-339`), `previewReady`
  or `blocked` in the blocker order: no proved generation, another endpoint or generation, critical
  Jobs, health, then the source's own reason.
- **Reads.** The union owner (`RuntimeControlActionResourceCoordinator.swift:23-92, 131-150`)
  refreshes every action's age before routing a show or reconcile and before paging a list
  (`refreshAge`, coordinator 316-338): expired after 300 s, invalidated for another Runtime start or
  catalog, written when read. Reconcile (74-88) observes an unobserved action, compares a preview not
  yet approved with a fresh reading and invalidates it when the reading is unavailable or differs.
- **Store** (`RuntimeHDCControlActionStore.swift`): one `action-<sha256(requestId)>.json` per request
  identity, canonical bytes, owner-only, under a per-transaction `.lock` (a held lock is
  `resourceConflict`), CAS transitions (85-96), 4096 records, 1 MiB each, 64 MiB in all.
- **Impact source** (`HeadlessHDCControlImpactSource.swift:28-113`, `HDCControlServerObservation.swift`,
  `HDCProduction.swift:884-970`): the pinned executable and its signature; the server — for the
  registered 3.2.0d digest `checkserver` between two identity observations, otherwise the
  commandless identity, which proves no health; the current Jobs and durable Targets read on both
  sides of a Target observation (`list targets -v` bracketed by USB relations); the identity again.
  Changed inventory or an unproved relation leaves the gate `unknown`
  (`hdc.participantInventoryUnproven`); a changed identity leaves no generation, health or version
  (`hdc.serverFactsDrifted`).

## What changes

- **`arkdeck-hoststore` `hdc_control_action.rs`**: the intent and its fingerprint, the impact (closed
  members, canonical collections, 512 KiB bound), the preview and its digest, the record for the
  states `observing`, `previewReady`, `blocked`, `expired` and `previewDrifted`, the store, and the
  coordinator's `preview`, `show`, `list_records`, `reconcile` and age refresh, with Swift's codes
  and messages. `OwnerContext` carries the epoch, catalog digest, clock and identity source; the
  daemon composes `OwnerContext::production()`.
- **`hdc_impact_source.rs`**: `ManagedServerImpact`, the impact source over seams — the commandless
  identity, the native signature, the managed-process verifier, the development HDC dispatch, the
  current Jobs, the Target records and the Target observation owner.
- **`JobStore::current_jobs`** (Swift `listCurrentJobs` from the durable rows) and
  **`TargetStore::records`** (Swift `RuntimeTargetStore.list()`).
- **`control_action.rs`**: `ControlActionResources::with_hdc`; `answer` takes the impact source and
  routes preview, show, reconcile and the list's records to the HDC owner.
- **`arkdeck-provider-hdc`**: `published_client_version`, Swift's `clientVersion(sha256:)`.
- **`arkdeck-agentd`**: with the managed opt-in, the composition makes `hdc-control-actions` and
  composes the HDC owner under the union owner, next to the existing union composition (away from
  the development HDC guard), and reserves the directory from Session roots; `Host::control_action`
  builds the impact source over the managed server's executable, endpoint and launch, the Job owner,
  the Target store and the Target observation owner over the development HDC.
- **`rust/README.md`**: the control-action paragraph the change made stale.

## Declared differences

- **One request at a time.** Swift's actors let a read run while a preview awaits its observation and
  join an observation in flight; the owner here serves one request at a time, so a concurrent read
  waits.
- **Restart stays unavailable**, before any parameter is read, with the no-host answer
  (`operationUnavailable`, "the Runtime HDC control-action owner is unavailable"). Swift's handler
  with a host checks the tuple first, whose `invalidInput` `runtime.hdc.restart` does not publish, and
  then mints the impact approval, which is C2.
- **What only an approval holds.** A record carrying a human action, a challenge, a receipt or a
  lifecycle audit is refused `recordUnreadable` with the handler's generic message; this owner never
  writes one. The age refresh's recovery of an interrupted lifecycle cannot be reached (such a record
  does not read); it is C2, porting its carrier (`recoverInterruptedLifecycle`) as design §L.1 item 13
  was ruled on 2026-09-19 (#2016, after this slice's base).
- **No supervisor.** Ownership rests on the managed launch alone (as the status observer's);
  Swift's host also consults its supervisor's record.
- **The registered `checkserver`** runs through the isolated owner's development HDC dispatch, so the
  managed server's gate applies and the child is given the inherited port; its identity bracket uses
  the commandless observer, which also checks the receipt's birth, path, digest and endpoint.
- **Current Jobs** come from the Job owner's durable rows. Swift overlays its in-memory active Jobs and
  lets an established recovery epoch or a Target alias resolution settle an unknown outcome; this
  owner holds neither index, so an outcome-unknown Job stays current — the gate fails closed, never
  clear.
- **Directory order.** `hdc-control-actions/{records,snapshots}` are made before the managed server
  starts, beside the union owner's; a failed start fails the daemon and leaves them empty. Swift makes
  them once its host has started.
- **Temporaries.** The scan also removes the shared Rust publisher's `.action-<digest>.json.<32
  hex>.part` orphan, beside Swift's `.tmp` spelling.
- **T2 messages.** A lock file that is not owner-only, a failed publication and an undecodable record
  keep Rust messages; the codes are Swift's.
- **No tool-selection owner** under the union owner (`runtime.tool.select` keeps the foundation's
  refusal); with no tool-selection action it changes no answer.

## Tests

- **`arkdeck-hoststore` `hdc_control_action.rs`, 11 tests.**
  - The intent's exactness and fingerprint: `32df6c7f…`, the request identity excluded, canonical
    generations only.
  - Canonical collections and every impact refusal, including the 512 KiB bound.
  - The committed preview digest (`93018d9e…`) and tamper refusals.
  - The blocker order.
  - The store: one record per request identity, CAS by generation only, the canonical bytes and
    0600 file beside `.lock`.
  - Another holder of the lock refused before anything is written.
  - Interrupted publications of both spellings removed, other content refused.
  - Refused records.
  - The coordinator: a preview observed once, read back and invalidated by a drifted
    reconciliation; unavailable and unproved impacts never ready; the age refresh (restart, expiry,
    catalog, clock behind).
- **`hdc_impact_source.rs`, 7 tests over seams.**
  - No identity family proves no server, and nothing is dispatched.
  - Ownership by the launch observed on both sides.
  - A changed identity leaves no server facts.
  - Inventory drift and unproved relations leave the gate unknown; rows and private relations are
    sorted.
  - Current Jobs block with their recovery.
  - Every failed leg leaves the impact unavailable.
  - The registered `checkserver` bracket: healthy only on the pinned output, and no command without
    a first identity.
- **`arkdeck-agentd` `control_action_host_control.rs`,
  `every_with_host_exchange_of_the_corpora_is_answered_as_swift_recorded_it`.** Through
  `Control::handle_frame`, every with-host line of the corpora is replayed in its Swift test's order,
  with that test's clock, starts, catalog and identities and the impact its source read. Answers
  compare whole; a page's snapshot revision and next cursor are set aside, and page two is asked
  through this owner's cursor.
  - **Coverage: 23 of the 24 with-host lines.** Of the fake source's 5 lines, 4 replay (preview,
    show, reconcile, one-item page). All 19 of #2012's lines replay (6 previews and refusals, 4 show,
    4 reconcile, 5 pages).
  - The one line not replayed is the fake source's approval request (`runtime.hdc.restart` line 1),
    which is C2.
  - The Rust preview digests over the Swift fixture's impacts equal Swift's.
- **`control_action_control.rs`**: the no-host replay is unchanged, its floors hold (44 lines, 19 by
  the owner, 10 without one, 20 with a host, 4 HDC-owner refusals).
- **`tests/control_action_host_process.rs`**, the actual daemon with its managed fake server:
  - the owner's private directories;
  - the with-host refusals;
  - a preview that is `previewDrifted` / `hdc.impactObservationUnavailable` (the fake answers
    `list targets -v` with nothing, exit 23), durable as one 0600 record;
  - idempotency and the conflict;
  - show, reconcile and the page;
  - restart unavailable while the server keeps listening;
  - after SIGTERM and a new start (a new epoch), the same final action, and no second record.

  Every answer passes its published schema.

## Local targeted checks

On `dcc30aef` (this commit before its evidence amend; the code is unchanged since), with
`CARGO_BUILD_JOBS=2` and the worktree's own `CARGO_TARGET_DIR`. The changed crates are
`arkdeck-hoststore`, `arkdeck-provider-hdc` and `arkdeck-agentd`; `arkdeck-soak` is their other
direct dependent. No contract input, Swift source or corpus changed, so neither
`generate-contract.py --check` nor a Swift test is required; `generate-contract.py --check` was run
anyway and passes (105 methods, 794 recorded shapes).

| Check | Command | Exit | Result | Log |
| --- | --- | --- | --- | --- |
| Format | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | clean | `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/host-reads-local-checks.log`, SHA-256 `6de4d74c5590192ff25e4a881b76fb19ef472a419eb22fe0aad7aa00da5e3fab` |
| Clippy (host) | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-provider-hdc -p arkdeck-agentd --all-targets --locked -- -D warnings` | 0 | clean | the same log |
| Tests | `cargo test --manifest-path rust/Cargo.toml --locked -p arkdeck-hoststore -p arkdeck-provider-hdc -p arkdeck-agentd -p arkdeck-soak --no-fail-fast` | 0 | 562 passed, 0 failed, 12 ignored; the new owner, impact-source, replay and process tests among them | `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/host-reads-local-tests.log`, SHA-256 `7afb6659ba7299ce30ccbdc8c288ad504723019318e6689d894e56ca2f5e33ce` |
| SDD | `python scripts/check_sdd.py` (the validation virtual environment) | 0 | 0 errors, 0 warnings, 121 acceptance IDs | `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/host-reads-check-sdd.log`, SHA-256 `3aee20107830134c5d8a4b1d46edc65b8c7da594dc23f4291a0873e59d4f9f3d` |

Before the verification policy moved the unified gate to CI, the same tree also passed:
- `cargo clippy --workspace --all-targets --locked -- -D warnings` for the host,
  `--target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc`;
- `cargo test --locked -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-control -p arkdeck-contract
  -p arkdeck-cli -p arkdeck-provider-hdc`: 779 passed, 0 failed, 12 ignored, unlogged.

No unified local gate ran: the one queued was stopped before it started.

## CI

Pending: the PR's `guard` and `swift` aggregate (PR number, run id and conclusion are filled in after
the PR runs).

## Not run, and why

- **C2.** Restart and its impact approval human action, the console challenge, the Job admission
  interlock, the supervisor, the lifecycle executor (`kill -r`) and audit, and the recovery of an
  interrupted lifecycle (design §L.1 item 13, ruled in #2016).
- **The registered 3.2.0d family on a real server.** Its bracket is proved over seams only; no real
  HDC runs.
- **A real device on the wire.** The published schemas (#2012) admit any device rows (the array is
  unconstrained) but only a null `criticalJobGate.reasonCode` and a null signature
  `teamIdentifier`. A device the isolated owner observes has no proved USB relation, so its gate is
  `unknown` with a reason, and the control layer would answer such a preview `internalError` until
  those shapes are recorded and published; so would a team-signed HDC's.
- No device, real HDC, installed Runtime or Swift daemon.
