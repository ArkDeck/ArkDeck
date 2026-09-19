# TASK-XPA-012 — `runtime.tool.select` on the Rust daemon without a tool-selection owner (macOS, 2026-09-19)

TASK-XPA-012 remains in progress. Base: protected main `7b5872f1` (#2029); no stack. The slice
was written on `74c3b2b1` and rebased onto `3828f2ed` once #2017 (C1, the HDC control-action owner
and impact source over the managed server) had merged, where the three files both changed were
merged by hand, then onto `7b5872f1` without conflict. Every answer
here is synthetic host data; nothing is device evidence (POL-VERIFY-001, POL-MODE-001). No Swift
source, control schema, corpus, Catalog, entitlement, `openspec/specs` or constitution change; the
one new fixture is a byte-identical copy of Swift's published argv sample.

This is the first slice of the remaining XPA-012 write paths (tool selection, trace database
preparation). It makes the Rust daemon and CLI answer `runtime.tool.select` as Swift's do while no
tool-selection owner can be composed, and records why the owner itself cannot be composed yet.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining |
| --- | --- | --- |
| The union control-action owner over no tool-selection owner, its routes for the five HDC control-action methods and Swift's handler without any owner (#2003); the managed HDC server of the isolated daemon (#2004); the HDC control-action owner, its impact source and the union owner over it once that server started (#2017); Swift's three `runtime.tool.select` frames in the corpus (an intent refusal, a fake-source success, the owner-absent refusal) and the method schema derived from them; the Rust registry decoder that already keeps `tools.json`'s `selection` intact | `runtime.tool.select` routed to `HostServices::control_action` and answered, by the isolated owner with or without its managed server and by the standalone macOS host alike, as Swift's handler answers without a tool-selection owner; the Rust CLI leaf `runtime tool select` with Swift's grammar, intent check and mutation error mapping; the corpus replay extended to the method | The tool-selection owner and its durable store (`tool-selection-control-actions`), the registry's selection writes to `tools.json`, and their composition, which waits for C1/C2 and one maintainer ruling (below); trace database preparation, which waits for a scope ruling (below) |

## What Swift does

`RuntimeControlPlaneHandler` routes `runtime.tool.select` with the HDC control-action methods to
`hdcControlActionRequest` (`AgentDaemon.swift`). For this method the handler checks for its
tool-selection owner before it reads any parameter:

```swift
case "runtime.tool.select":
  guard let toolSelectionActions else {
    throw HDCControlValue.failure(
      "operationUnavailable", "the Runtime tool-selection owner is unavailable")
  }
  result = try await toolSelectionActions.select(fields)
```

The refusal carries the handler's `{"newDispatchCount": 0}`. The corpus's third frame is exactly this
answer for `{}`. `ArkDeckAgentDaemonMain` composes the owner (`RuntimeToolSelectionCoordinator` over
`RuntimeToolSelectionControlActionStore` in `<state>/tool-selection-control-actions`) only once its
`HeadlessHDCServerHost` started, beside the HDC impact source and the Bootstrap registry adapter.

Swift's CLI (`CLICommandRegistry` select leaf, `CLIBootstrapTools.runBootstrapTool`):

- `--tool` (opaque), `--expected-active-generation` (`positiveInteger(1...Int.max)`) and
  `--action-request-id` (opaque) are required; `--timeout` is the wait option; a missing or malformed
  option is `invalidOption`, exit 64, as the published argv sample pins.
- Before any request it builds `RuntimeToolSelectionIntent`: an `HDCControlValue.identifier` request
  identity, `tool:sha256:` and 64 lowercase hexadecimal digits, and an `HDCControlValue.generation`.
  A failure is `invalidInput` "tool-selection intent failed validation", exit 65, and nothing is sent.
- The method is mutation-capable (`CLIControlMethodRegistry`), so a refusal without the pre-admission
  proof, or a lost reply, is `outcomeUnknown`.

## What changes

- **`arkdeck-control`.** The method joins the five control-action methods that reach
  `HostServices::control_action` unread. A host without that service keeps the foundation's
  `rejected`, so Linux and Windows answer as before.
- **`arkdeck-hoststore` (`control_action.rs`).** `ControlActionResources::answer`, whether or not it
  holds the HDC owner, and `control_action_without_owner` answer `operationUnavailable` "the Runtime
  tool-selection owner is unavailable" with `{"newDispatchCount": 0}`, before any parameter is read,
  as the restart does. Nothing is written.
- **`arkdeck-agentd`.** Doc comment only; the composition is unchanged and still makes no
  `tool-selection-control-actions` directory.
- **`arkdeck-cli`.** `runtime tool select` with Swift's grammar (`hdc_control::configure`), the
  intent check before any connection (`hdc_control_action_params`), the bounded connection of the
  other control-action leaves, and the mutation mapping (`job_plan::mutation_error`, with its own
  lost-reply message). `rust/tests/fixtures/current-cli-argv/runtime.tool.select.json` is Swift's
  argv sample, byte for byte; `check-contracts.py` keeps the two copies identical.
- **`check-readonly.py`**, **`rust/README.md`** (the Bootstrap tool paragraph and the HDC runtime
  status section).

| Request | Swift daemon without the owner | Rust isolated owner (with or without the managed server), before → after | Rust standalone macOS, before → after |
| --- | --- | --- | --- |
| `{}` | `operationUnavailable`, tool-selection owner unavailable | `rejected` → the same as Swift | `rejected` → the same as Swift |
| an exact intent | the same | `rejected` → the same as Swift | `rejected` → the same as Swift |
| an intent naming a caller's `executablePath` | the same (the owner is checked first) | `rejected` → the same as Swift | `rejected` → the same as Swift |

## Tests

- `arkdeck-control` `read_only.rs`: the routed set is six methods; the owner-absent refusal passes
  the method's schema.
- `arkdeck-agentd` `control_action_control.rs`: the corpus replay now includes the method. The
  owner-absent frame is answered by the isolated owner and by the standalone host as Swift recorded
  it; the intent refusal and the fake-source success need a tool-selection owner and are counted,
  not replayed. The floors rise to 47 lines, 20 answered by the owner and 11 without one. The union
  owner test adds three selections refused before their intent is read, and the fixture still holds
  only the owner's snapshot directory. `control_action_host_control.rs` asks the same of the union
  owner over the HDC owner (#2017's replay scenario): refused, and no `tool-selection-control-actions`
  directory.
- `arkdeck-cli` `tool_select.rs`: the argv sample replays; the grammar refuses zero, a leading
  zero, a sign, `Int64.max + 1`, a timeout over a day, a missing option and a foreign option; against
  a fake Runtime the recorded success is emitted as answered (exit 0), the recorded owner-absent
  refusal and the foundation's `rejected` are `outcomeUnknown` (exit 75), `unknownMethod` is
  `controlMethodUnavailable` (69), `invalidParams` is `invalidInput` (65), and five malformed
  intents are refused with Swift's message before any connection (65).

## Why the owner is not in this slice

1. **C2 comes first.** A selection publishes a durable control action, an immutable preview and an
   impact-approval human action; it dispatches nothing itself. The preview carries the running
   managed server's impact (`HDCControlImpact`, whose `tool.sha256` must equal the active
   selection's executable), read twice through the HDC impact source, which #2017 (C1) now provides
   (`hdc_impact_source.rs`, with the impact, human-action, challenge and receipt values in
   `hdc_control_action.rs`). The restart with the new tool (`actualCommand` `-s <endpoint> kill -r`
   from the new executable, `launchWindowEntered`, then the daemon's exit 70 and the registry's
   startup publication) happens only when a person consumes the console challenge through
   `human-action.resume`. That is C2 (restart, approval, console challenge, the lifecycle
   interlock), which no branch had started at this base.
2. **The schema must be widened first.** The published `runtime.tool.select` schema was derived from
   the fake source's frames: `blockerReasonCode` must be null and neither `resourceConflict`,
   `idempotencyConflict` nor `resourceNotFound` is published. The control layer rewrites anything
   else to `internalError`, so, as #2002 and #2012 did for the HDC methods, a Swift-only slice must
   record the production owner's answers before a Rust owner can answer them.
3. **Maintainer ruling needed.** The isolated daemon's managed server runs the executable named by
   `ARKDECK_DEVELOPMENT_HDC_PATH`, pinned by digest at startup; Swift's runs the registry's
   `startupSelection()` and a successful selection restarts it with the newly selected registered
   tool, which `tools.json`'s `activeToolRef` then names. Whether a selection on the isolated daemon
   must switch the managed server to the selected tool (so the selection write drives an HDC
   lifecycle restart there), or only record the selection, is not decided here.

Found while mapping the Swift owner, for the owner slices to port or for a ruling:

- **A stale approved record breaks discovery.** Refreshing a record past its expiry, or after a
  daemon restart, invalidates it (`expired`, `previewDrifted`) but keeps an `approvalRecorded` or
  `dispatchPrepared` record's interaction receipt, which the record's own validation then refuses
  (`recordUnreadable`, "tool-selection owner bindings contradict its state"). Since the owner
  refreshes every record it lists, one such record makes every `control-action.list`, `.show` and
  `.reconcile` through the union owner fail.
- **A failure before launch never clears the registry.** It records `failed` in the action and a
  failed `lastOutcome` in `tools.json`, but only the `outcomeUnknown` path acknowledges an outcome.
  Every later selection is then refused ("a prior tool selection requires reconciliation") and ends
  as `previewDrifted` with `tool.selectionFactsUnavailable`.
- **The record bound is not symmetric.** A record of exactly 1 MiB can be written but not read back
  (`ControlFrameJSON.decodeObject` needs the bytes plus one newline within 1 MiB).

The durable parts that need neither C2 nor the ruling can go first, over #2017's HDC control-action values: the store
(`RuntimeToolSelectionControlActionStore`: `action-<sha256(actionRequestId)>.json` records of
`arkdeck.runtime-tool-selection-control-action/1`, the 20-key record, the transition table, the
non-blocking `.lock` transaction, orphan temporary-file removal and the record, byte and count
bounds) with Swift reading back what Rust writes, and the registry's selection writes to
`tools.json` (`prepareSelection`, `publishPendingSelection`, `failPendingSelection`,
`acknowledgeSelectionOutcome`, `startupSelection`, `initializeServiceSelection`) under the
invariants the Rust decoder already enforces.

## Trace database preparation: scope ruling needed

No Swift daemon path turns an Artifact into a cached database under `trace-cache/traces`, and the
plan (`tasks.md` XPA-012 status, `trace-cache-owner-run.md`, `rust/README.md`) names the item without
defining it. Two different things carry the name:

- **(A) The content-addressed Ready entry** (`traces/<traceSHA256>/<parserKey>/{database.sqlite,metadata.json}`)
  that `trace.cache.status` and `.purge` count and purge. Only the sandboxed App writes it, in its own
  process, through ArkTrace's `TraceContentAddressedCache` and the pinned `trace_streamer`. No control
  method asks the daemon for it, so there is no Swift daemon oracle, and a Rust producer would need a
  new contract and either a port of ArkTrace's preparer and schema adapter or an ArkTrace change (its
  CLI's cache root is fixed to its own container).
- **(B) `trace.inspect`**, the only preparation the Swift daemon does: an ephemeral session under
  `<state>/trace-inspection/staging`, removed on close, never touching `traces/`; composed only when
  the `trace-summary@1` analyzer profile loads from `ARKDECK_ARKTRACE_DESCRIPTOR`, which XPA-015
  schedules after M4. `docs/design/cli-trace-inspection.md` fixes it to ephemeral storage.

Which of these TASK-XPA-012 means, or whether the App keeps preparing in its own process and the item
closes by ruling, is a maintainer decision. No trace code changes here.

## Local targeted checks

Run 2026-09-19 21:20:48–21:23:11 CST on the tree based on `3828f2ed`, `CARGO_BUILD_JOBS=2`, in
this worktree's own fresh `rust/target`; each command's exit code was read directly. After the
rebase onto `7b5872f1` (#2025–#2029 changed `arkdeck-agentd` and `rust/README.md`, not these routes)
format, the four crates' lint, the daemon's control-action tests, `read_only.rs` and `tool_select.rs`
ran again, 21:24:23–21:25:02, all passing.

| Check | Command | Result |
| --- | --- | --- |
| Format | `cargo fmt --all --check` | exit 0 |
| Lint | `cargo clippy -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd -p arkdeck-cli --all-targets -- -D warnings` | exit 0 |
| Control | `cargo test -p arkdeck-control` | exit 0; `read_only.rs` 19 passed, including the routed set and the unimplemented-method table |
| Owner | `cargo test -p arkdeck-hoststore --lib control_action` | exit 0; 13 passed |
| Daemon | `cargo test -p arkdeck-agentd control_action` | exit 0; 5 passed (the no-host corpus replay, the union owner, retention, the standalone host, the with-host replay) |
| CLI | `cargo test -p arkdeck-cli --test tool_select --test hdc_control_actions --test control_actions --test current_surface` | exit 0; 4, 4, 4 and 11 passed |
| Real daemon | `cargo build --workspace --bins`, then `rust/scripts/check-readonly.py --bin-dir rust/target/debug --output-dir <scratch>` | `PASS`; the standalone daemon answered `runtime.tool.select` with the owner-unavailable refusal |
| Argv sample | `cmp` of the Swift sample and the Rust copy | identical |
| SDD | `sh scripts/check-sdd.sh` | `check_sdd: 0 error(s), 0 warning(s)` |

The unified local gate was not run: since 2026-09-19 the PR's CI is the gate and local checks are
targeted (`AGENTS.md`, #2015).

## CI

Recorded once the PR's CI finishes.
