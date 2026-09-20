# TASK-XPA-014 — `runtime.hdc.restart` requests its impact approval on the Rust daemon (macOS, 2026-09-20)

TASK-XPA-014 remains in progress. Base: protected main `28d2016c`; no stack. It carries the
with-host restart frames and the five widened schemas this slice answers under (#2052). Every
answer here is synthetic host data over a fake HDC; nothing is device evidence (POL-VERIFY-001,
POL-MODE-001). No Swift source, control schema, corpus, Catalog, entitlement, `openspec/specs` or
constitution change.

This is C2a of the control-action work on the isolated daemon. With
`ARKDECK_DEVELOPMENT_HDC_SERVER=managed` the isolated owner now answers `runtime.hdc.restart` as
Swift's daemon does up to and including the impact approval it records, and serves that approval
through the control-action reads and the combined human-action owner. **Restart dispatches
nothing**, here as in Swift: it records the request for a person's approval, and only a person's
answer to the console challenge of `human-action.resume` could lead to a lifecycle command. That
challenge, its receipt, the lifecycle executor (`kill -r`), the supervisor, the Job admission
interlock and the recovery of an interrupted lifecycle are C2b.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (C2b) |
| --- | --- | --- |
| The union control-action owner and the routes (#2003); the managed server (#2004); the with-host frames and schemas (#2012, #2037, #2052); the HDC control-action owner with its previews and reads, C1 (#2017); the agent executions' human actions and the combined owner (#1953, #1969) | `runtime.hdc.restart` in the HDC owner (`hdc_control_action.rs`): the tuple check, Swift's refusals in its order, the fresh reading and the approval by CAS; the record's waiting and expired approval, its expiry with every invalidation, and the CAS rule that keeps it; the approvals in the combined human-action owner (`human_action.rs`) for `human-action.list`, `.show` and the two resume routes; `control_action.rs` routing restart and handing the rows over; agentd wiring; the replay of every with-host corpus line but the console's two | The console challenge and its receipt, `human-action.resume` advancing an approval, the lifecycle executor and audit, the supervisor, the Job admission interlock while an action runs, and the recovery of an interrupted lifecycle (design §L.1 item 13) |

## What Swift does (the map this slice ports)

Line numbers are on the base.

- **The route.** `AgentDaemon.swift:3001-3013`: the HDC owner's presence (`operationUnavailable`)
  before any parameter, then exactly the tuple — `Set(fields.keys) == ["controlAction",
  "previewId", "previewDigest"]`, two exact identities and a lowercase digest, else `invalidInput`
  "restart requires one exact control-action preview tuple" — then `requestRestart`. Every refusal
  of these routes carries `newDispatchCount: 0`, merged over the failure's own details
  (`3061-3067`).
- **`requestRestart`** (`HDCControlActionCoordinator.swift:93-124`), in this order:
  1. the action, its age refreshed (`refreshAge`, 316-338): `resourceNotFound` for none;
     `orchestrationClockUntrusted` for a clock behind its last observation; expiry, another
     Runtime start or another catalog invalidate it — and now expire the approval with it;
  2. its exact preview, else `reviewedPlanMismatch` "restart does not name the exact immutable
     preview";
  3. an action already `awaitingImpactApproval` answers as it is (a lost receipt), observing
     nothing;
  4. any other but `previewReady` is `admissionDenied` "the control action is not eligible for
     impact approval";
  5. one fresh reading of the impact source. A failure invalidates the action
     (`hdc.impactObservationUnavailable`) and refuses `factsDrifted` "fresh HDC impact could not be
     proven"; a reading that is not the reviewed impact, relations or blocker
     (`blocker(for:intent:)`, 296-303) invalidates it (`hdc.previewDrifted`) and refuses
     `factsDrifted` "fresh HDC impact differs from the reviewed preview". Both carry the
     invalidated action in `details.controlAction`;
  6. `requestingImpactApproval` (`HDCControlActionRecord.swift:372-387`) by CAS: the next
     generation, observed now, `awaitingImpactApproval` and the approval
     (`HDCControlHumanAction`, 6-90) — `har-<uuid>`, `resume-<uuid>`, bound to the preview's
     identity and digest and to that next generation, created now, expiring with the action,
     `waiting`.
- **The record** (`HDCControlActionRecord.swift:241-259`): an awaiting action's approval is
  waiting, its own, bound to its exact preview and to a generation it reached, expires with it and
  is read only inside the action's window; any other state keeps an approval only as an
  invalidated action's (`expired`, or `resolved` with its receipt). `invalidated` (341-349) expires
  a waiting approval; `projection` (447-467) answers the approval and, while awaited, a
  `nextAction` naming it (`policy.impactApprovalRequired`).
- **The store** (`RuntimeHDCControlActionStore.swift:63-83`, `sameHumanAction` 98-114): an update
  keeps the approval it found, except that `waiting` may become `expired` or `resolved`.
- **The human-action owners**: the HDC owner's rows
  (`HDCControlActionCoordinator.swift:259-273`) are every record's approval, read as stored — no
  age refresh — the union's (`RuntimeControlActionResourceCoordinator.swift:94-101`) are its
  owners', and the combined owner (`RuntimeHumanActionResourceCoordinator.swift:41-98`) shows,
  lists and looks one up beside the executions' actions, newest first then by identity.
- **The resumes.** `human-action.resume` of an approval (`AgentDaemon.swift:3114-3166`): a
  `selection` is `invalidInput` "impact approval accepts no selection"; over a Unix socket with a
  foreground console the daemon issues or consumes the console challenge (C2b); **every other
  request gets the same approval back and cannot advance the owner** (`3159`). `agent.resume`
  naming an approval's reference (`3201-3211`) is `admissionDenied` "agent resume cannot consume an
  impact approval", the approval in `details.humanAction`. A reference two owners hold is
  `recordUnreadable` "human action reference has multiple owners".
- **The composition** (`ArkDeckAgentDaemonMain/main.swift:1256-1284`): the HDC owner beside the
  started host, the union owner over it, and the human-action union over that and the
  AgentExecution owner.

## What changes

- **`arkdeck-hoststore` `hdc_control_action.rs`**: the record holds an `ImpactApproval`
  (`control_action_approval.rs`, already Swift's `HDCControlHumanAction` from TASK-XPA-012) and
  reads it back only as Swift binds it; `invalidated` expires it; `requesting_impact_approval`
  records it; the projection answers it and its `nextAction`; `replaces` keeps it; the coordinator
  gains `restart` (Swift's `requestRestart`, above) and `human_action_rows`.
- **`control_action.rs`**: `runtime.hdc.restart` is the handler's tuple check and then the HDC
  owner's, and the union hands its approvals to the human-action owner.
- **`human_action.rs`**: the combined owner answers over the agent executions **and** the union
  control-action owner, and `resume_control_action` is Swift's lookup for both resume routes,
  answering an approval's `human-action.resume` with the approval and `agent.resume` with its
  refusal.
- **`arkdeck-agentd`**: `Host::human_action` passes the union owner; `Host::agent_execution` looks
  a resume up there first, as Swift's handlers do.
- **`rust/tests/fixtures/managed-hdc/fake-hdc.c`**: two compile-time options, both off by default —
  `RECORD_CALLS` appends every invocation's arguments to a file, `LIST_EMPTY` answers `list targets
  -v` with no target.
- **`rust/README.md`**, `arkdeck-control`'s trait doc and the agentd composition comment: the
  paragraphs this makes stale.

## Declared differences

- **No console, so no challenge.** The Rust control layer takes a frame, not Swift's request
  context, so it cannot tell a foreground console from any other caller. Every
  `human-action.resume` of an approval is therefore answered as Swift answers one outside that
  console: the approval itself, unchanged, advancing nothing. Swift would answer a foreground
  console's with a challenge (C2b). Nothing here can record an approval or dispatch, in any
  composition.
- **A resolved approval is unreadable.** Only a person's answer resolves one, and its receipt
  comes with it; a record carrying a challenge, a receipt, a lifecycle audit or a resolved
  approval is refused `recordUnreadable` with the handler's generic message, as C1 refused every
  approval. Swift reads an invalidated record whose approval is `resolved` without a receipt; no
  owner writes one.
- **No recovery of an interrupted lifecycle.** As C1: a record in `approvalRecorded`,
  `dispatchPrepared` or `dispatching` does not read here, so the age refresh's recovery branch
  cannot be reached (C2b, design §L.1 item 13).
- **One request at a time** (C1): Swift's actors let a read run beside an observation; this owner
  serves one request, and the restart's fresh reading holds the union owner's gate.
- **A racing generation** is answered as Swift answers it (the action as it became), which no
  frame publishes: one request at a time makes it unreachable here.
- **No tool-selection owner** under the union owner, so its approvals are not in the human-action
  union either (TASK-XPA-012).
- **A ready preview needs the registered 3.2.0d server.** As in Swift, only that executable's
  `checkserver` between two identity observations proves health, so over this host's fixture and
  fake HDCs every restart is `admissionDenied`. The ready previews here come from the impacts
  Swift's `RegisteredHealthyServer` seam recorded, and from an equivalent Rust test seam (below).

## Tests

- **`hdc_control_action_tests.rs`, 6 new tests** (32 in the crate's two HDC modules):
  - a ready preview's restart: each refusal before it observes anything, then the approval — its
    exact members, the record's bytes, the `nextAction` naming it, the lost receipt answered
    without observing, the reads over it, the rows the human-action owner takes, and the clock
    behind its observation;
  - every refusal in Swift's order without an approval: no action, no preview, a blocked preview
    not eligible, then an unavailable reading, a differing impact, differing relations and the
    source's own reason — each invalidating the action into the refusal's details and leaving it
    ineligible;
  - the age refresh before the tuple: a clock behind, then an expiry;
  - an awaited approval expiring with its action, one way each (a drifted reconciliation, another
    Runtime start, another catalog, the action's 300 s), and listed as stored until the action is
    read;
  - the approval read back only bound to its awaiting or invalidated action (13 changes refused);
  - the store keeping the approval it found (another one, or none, is `resourceConflict`).
- **`hdc_impact_source_tests.rs`**: `RegisteredHealthyServer`, Swift's seam, over the production
  `ManagedServerImpact` — **a test seam only; no composition reads through it**. Over the same
  legs the production reading gives a blocked preview whose restart is `admissionDenied`, and the
  seam's gives a ready one whose restart requests the approval; the legs' dispatch stays empty, so
  nothing ran the executable.
- **`tests/control_action_approval.rs`** (new): the combined owner over an approval and the
  physical-assistance oracle's abandoned execution — shown, listed (whole and by either owner
  filter), and each resume: the approval back for `human-action.resume` with and without a
  preseeded challenge response, `invalidInput` for a selection, `admissionDenied` for
  `agent.resume` with the approval in its details, nothing for the requests Swift's handler
  refuses before its lookup or that name another action, and `recordUnreadable` for a reference —
  or an identity — two owners hold, with each handler's proof. Nothing advanced the action.
- **`arkdeck-agentd` `control_action_host_control.rs`**,
  `every_with_host_exchange_of_the_corpora_is_answered_as_swift_recorded_it`: now over
  `human-action.show`, `.list`, `.resume` and `agent.resume` as well, with the combined
  human-action owner beside the union owner.
  - **Coverage: 67 of the 69 with-host lines**, all of them through `Control::handle_frame` and
    compared whole. The 29 lines C1 could not replay are: every `runtime.hdc.restart` answer and
    refusal (14), every record and page carrying an approval (10), and the approval's
    `human-action.show`, `.list`, two `.resume` answers and the `agent.resume` refusal (5).
  - The 2 lines left are what only a foreground console receives: the challenge
    (`arkdeck.impact-approval-challenge/1`) and the control action a person's answer advanced. The
    partition check is exact: every unreplayed line is one of those two, and no console line was
    replayed.
  - The scenarios follow the Swift tests: the fake source's action and its approval; the with-host
    refusals, previews, reads and pages; the restart tests' approvals, refusals, drifts and
    expiries; the unsigned and team-signed tools' approvals. A reading that names a Target adopted
    after the review is made here, since no frame holds it.
- **`control_action_control.rs`** (the no-host replay) is unchanged and still passes: without a
  managed server the restart is `operationUnavailable` before any parameter, as Swift's handler
  answers with no owner.
- **`tests/control_action_host_process.rs`**, the actual daemon over its socket with the managed
  fake server:
  - the existing test (the fake's device list is empty output) now sees the restart answer
    `reviewedPlanMismatch`: the action's observation failed, so it has no preview to name;
  - a new test over a fake that lists no target: the impact is read, the fake's digest proves no
    server (`hdc.serverIdentityUnproven`), the preview is blocked, and the restart is refused in
    Swift's order — the tuple, the action, its preview, then `admissionDenied` twice — with no
    approval to show or list and the action unchanged;
  - the fake records every invocation: `-s 127.0.0.1:<port> -m`, `-s 127.0.0.1:<port> checkserver`
    and the preview's one `list targets -v`. **No `kill`**, before or after the daemon stopped the
    server.

## Local targeted checks

No unified local gate (the verification policy of #2015: the PR's CI is the gate). On the rebased
tree, with `CARGO_BUILD_JOBS=2` and this worktree's own `CARGO_TARGET_DIR`. Logs are under the
session scratchpad `…/scratchpad/approval/logs/`.

| Check | Command | Exit | Result |
| --- | --- | --- | --- |
| Format | `cargo fmt --all --check` | 0 | clean |
| Clippy | `cargo clippy --locked -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-control --all-targets -- -D warnings` | 0 | clean |
| CLI build | `cargo build --locked -p arkdeck-cli` | 0 | — |
| Tests | `cargo test --locked -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-control -p arkdeck-cli --no-fail-fast` | 0 | 669 passed, 0 failed, 13 ignored; the new owner units, `control_action_approval`, both control-action replays and both real-process tests among them |
| The fake's other consumers | `cargo test --locked -p arkdeck-provider-hdc --test managed_server --test lifecycle` | 0 | 14 passed, 0 failed: its compile-time options are off by default |
| Contract | `python rust/scripts/generate-contract.py --check` (the validation environment) | 0 | unchanged: 105 methods, 901 recorded shapes, contract identity `1d7d101e83fe` |
| SDD | `python scripts/check_sdd.py`; `python scripts/check_union_merge.py` | 0 | 0 errors, 0 warnings, 121 acceptance IDs; ok |

The same checks passed before the rebase onto `28d2016c`, on base `a3310b20` (644 passed there;
the difference is upstream's new tests).

## CI

Pending: the PR's `guard` and `swift` aggregate (PR number, run id and conclusion are filled in
after the PR runs).

## Not run, and why

- **C2b**: `human-action.resume` advancing an approval, the console challenge and its receipt, the
  lifecycle executor (`kill -r`) and its audit, the supervisor, the Job admission interlock and the
  recovery of an interrupted lifecycle.
- **A health proof.** It would run the registered 3.2.0d hdc and its server; the ready previews
  come from Swift's recorded impacts and the equivalent test seam.
- **A real device, a real HDC, the installed Runtime, a Swift daemon, the full unified gate.**
