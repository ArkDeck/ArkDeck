# TASK-XPA-014 — the HDC control-action routes on the Rust daemon without a managed HDC server (macOS, 2026-09-19)

TASK-XPA-014 remains in progress. Base: protected main `40a1fe3c`; no stack. That main carries
#2002, the no-host frames and the widened schemas this slice's replays need (record
`control-action-no-host-frames-run.md`). The slice was built and first gated stacked on that PR's
commit, then replayed onto `40a1fe3c` once #2002 merged (below). Every answer here is synthetic
host data; nothing is device evidence (POL-VERIFY-001, POL-MODE-001). No Swift source, control
schema, corpus, Catalog, entitlement, `openspec/specs` or constitution change.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| The Rust snapshot pager (`arkdeck-hoststore` `snapshot_pager.rs`); the isolated composition in `arkdeck-agentd`; the five methods answered `rejected` by the control foundation; Swift's no-host answers recorded (`ControlActionNoHostContractTests`, 20 frames, 14 of them added to the corpora) and the `control-action.list`, `.show` and `.reconcile` schemas widened to publish them (#2002); the Rust CLI leaves `runtime hdc impact-preview` and `restart` (#1995) and `control-action list`, `show` and `reconcile` (#1996) | `HostServices::control_action` and the control-layer route for `runtime.hdc.impact-preview`, `runtime.hdc.restart` and `control-action.list`, `.show` and `.reconcile`; `ControlActionResources` (Swift's union control-action owner over no HDC and no tool-selection owner) composed by the isolated daemon in `control-action-snapshots`; Swift's handler without any owner for the standalone macOS daemon; every no-host corpus exchange replayed through `Control`; a real-process check of the composition | A managed HDC server in the Rust daemon, and over it the HDC control-action owner (`hdc-control-actions`), its impact source, previews, restarts, human actions and console challenge; the tool-selection owner and `runtime.tool.select`; recovery of control actions (design §L.1 item 13) |

## What changes

Swift's `RuntimeControlPlaneHandler.hdcControlActionRequest` (`AgentDaemon.swift`) reads these
methods' parameters itself. It checks for the HDC control-action owner before it reads anything for
`runtime.hdc.impact-preview` and `runtime.hdc.restart`. For show and reconcile it requires exactly
one exact `controlAction` identity (`HDCControlValue.identifier`). For a list it requires known
fields, an integer `pageSize` from 1 to 1000 and a string `cursor` of at most 256 bytes. Only then
does it ask its owner. `ArkDeckAgentDaemonMain` composes no HDC control-action owner and no
tool-selection owner without an HDC server host. It still builds the union owner
(`RuntimeControlActionResourceCoordinator`) over neither, paging in `<state>/control-action-snapshots`.

- **`arkdeck-control`.** `HostServices::control_action(method, params)` is a host's answer; a host
  without it keeps the foundation's `rejected`, so `read_only.rs`'s unimplemented-method table is
  unchanged. The five methods reach it unread, and the answer then passes the method's schema like
  any other.
- **`arkdeck-hoststore` (`control_action.rs`, macOS).**
  - The handler's checks, in its order and with its messages.
  - `ControlActionResources`: the union owner over no HDC and no tool-selection owner. The lifecycle
    methods are `operationUnavailable` ("the Runtime HDC control-action owner is unavailable").
    Show and reconcile of an exact identity are `resourceNotFound` ("control action does not
    exist"). A list checks its `kind` and `state` filters as Swift's owner does ("unsupported
    control-action discovery filter"), then pages the owners' actions (none) in
    `createdAtThenControlActionId` order through `SnapshotPager::open_serialized`. The owner, like
    Swift's actor, serves one request at a time, so the directory holds no lock document, as Swift's
    pager keeps none. The pager's stale-cursor refusal carries Swift's pager message.
  - `control_action_without_owner`: Swift's handler with no control-action owner at all (below).
  - Every refusal carries exactly `{"newDispatchCount": 0}`.
- **`arkdeck-agentd` (macOS).** The isolated composition makes the private `control-action-snapshots`
  beside its other owners, reserves it from Session roots and composes `ControlActionResources`
  there. It never makes `hdc-control-actions`. The host answers through the owner when composed,
  else through `control_action_without_owner`.
- **`check-readonly.py`**, **`rust/README.md`** (a paragraph inside the existing HDC runtime status
  section).

## The standalone composition

Before this slice the standalone daemon (no development root, no Swift daemon to pair) answered all
five methods `rejected`. Swift's production handler without a control-action owner answers
differently, so on macOS the standalone host now answers as that handler does. This follows the precedent of the
agent and human-action routes. The corpus's `control-action.list` `operationUnavailable` frame was
recorded from exactly that handler.

| Request | Swift, no owner | Standalone Rust daemon (macOS) |
| --- | --- | --- |
| `runtime.hdc.impact-preview`, `runtime.hdc.restart`, any parameters | `operationUnavailable`, HDC owner unavailable | the same |
| show or reconcile, not one exact identity | `invalidInput` "an exact control-action identity is required" | the same |
| show or reconcile, one exact identity | `operationUnavailable` "the Runtime control-action owner is unavailable" | `rejected` (the foundation's): the published show and reconcile schemas do not admit `operationUnavailable`, and the control layer would answer it `internalError` |
| list, an unknown field, a bad page size, a cursor over 256 bytes | the handler's `invalidInput` / `invalidCursor` | the same |
| list, otherwise (filters unchecked) | `operationUnavailable` "the Runtime control-action owner is unavailable" | the same |

On other platforms the five methods keep the foundation's `rejected`, as the agent routes do.

## Parity with Swift's no-host daemon

T0/T1 as design §L.1 item 19 defines them. Refusals compare whole (code, message, details), and a
page compares whole once its random `snapshotRevision` is checked (a lowercase UUID) and set aside.

| Method | Isolated Rust daemon (union owner) | Evidence |
| --- | --- | --- |
| `runtime.hdc.impact-preview`, `runtime.hdc.restart` | `operationUnavailable` before any parameter is read | corpus frames; `{}` and a well-formed intent or tuple |
| `control-action.show`, `.reconcile` | `resourceNotFound` for an exact identity; `invalidInput` for a malformed one or another field | corpus frames (4 and 3) |
| `control-action.list` | an empty `arkdeck.cli.page/1` snapshot page for `{}`, `pageSize` 1000, `kind` `hdcLifecycle`, `state` `awaitingImpactApproval`, and `kind` `runtimeToolSelection` with `state` `succeeded` and `pageSize` 1; `invalidInput` for filter `adbLifecycle`, `running` or a non-string, and for `pageSize` 0; `invalidCursor` for a stale cursor (pager message) and a 257-byte one (handler message) | corpus frames (10) and the Swift no-host test's cases |
| the snapshot | one owner-only (0600) `snapshot-<revision>.json` per page, holding `schemaVersion` `arkdeck.runtime-snapshot/1`, the revision, the order, `pages` `[[]]`, one token `<revision>.<uuid>` and `queryDigest` = SHA-256 of the canonical `{method, filters, order, pageSize}` (the default 100 filled in), checked against the canonical bytes spelled out in the test | in-process and real-process tests |

The corpora have 25 lines for the five methods. In the checkout and the candidate view:

- 19 are answered by the union owner as recorded.
- 10 by the standalone host: the corpus's no-owner list frame and every handler refusal.
- 5 success frames of an impact source are counted and not replayed, because they need a managed
  server: a preview, an approval request, a record read by show and by reconcile, and a listed
  action.

Retention matches Swift's pager:

- At most 32 snapshots: a 33rd page reclaims the oldest, and that page's cursor is then stale.
- At most 64 MiB: four older 16 MiB snapshots and a new page reclaim exactly the oldest.
- A store holding more than 32 snapshots is refused `recordUnreadable` with only the zero-dispatch
  proof, and nothing is removed.

Declared differences:

- **T2 messages.** A snapshot-store failure other than a stale cursor keeps the shared Rust pager's
  message, as `agent.list` and `human-action.list` do. Swift names each case, and the code and
  details are the same.
- **Number spellings.** A `pageSize` written `1.0` or `1e2` is refused as the Rust owners of the
  other lists refuse it. No frame records Swift's answer for such a spelling.

## Tests

- `crates/arkdeck-agentd/src/control_action_control.rs` (in process, macOS), four tests:
  - `every_no_host_exchange_of_the_corpora_is_answered_as_swift_recorded_it`: the replay above,
    through `Control::handle_frame`. Only the list pages write, one snapshot each.
  - `the_union_owner_pages_an_empty_listing_in_private_snapshots`: the Swift no-host test's
    requests and snapshot checks. Also: a stored page read again through its token after the owner
    is recomposed, with no new snapshot; that token refused for another query; and no write by any
    refusal or other method.
  - `retention_keeps_the_latest_32_snapshots_within_64_mib`: the retention above.
  - `without_the_owner_the_host_answers_as_swifts_handler_with_none`: the standalone table.
  - The composed development HDC is a sentinel script that records any launch, and it is never
    launched. The fixture root holds only the owner's directory afterwards, so no
    `hdc-control-actions`.
- `crates/arkdeck-agentd/tests/control_action_process.rs` (real process, macOS),
  `the_isolated_daemon_answers_without_a_managed_hdc_server_and_keeps_its_pages`. The actual
  `arkdeck-agentd` with a fresh development root and a sentinel `ARKDECK_DEVELOPMENT_HDC_PATH`:
  - it makes `control-action-snapshots` (0700, empty) and not `hdc-control-actions`;
  - it answers the lifecycle methods and an exact identity over its socket as above;
  - it stores one 0600 snapshot for a page, and after a restart reads that page through its token
    without a new snapshot;
  - `job.list` is empty, the sentinel was never launched, and still no `hdc-control-actions`.
- `crates/arkdeck-hoststore/src/control_action.rs`: the identity grammar, and the handler's checks
  in Swift's order.
- `crates/arkdeck-control/tests/read_only.rs`,
  `the_control_action_methods_reach_their_host_service_unread`. Exactly the five methods reach the
  host's service, each with its parameters verbatim. A host's `operationUnavailable` passes for the
  three methods that publish it and becomes `internalError` for show and reconcile.
- Views. The unified gate's published view compiles this Rust against the merge base's contract.
  While #2002 was open, that was main `521c8fad`, whose show and reconcile did not publish
  `resourceNotFound` and whose list published neither `invalidInput` nor `invalidCursor`. The tests
  therefore expect the control layer's `internalError` for whatever a view that names its commit
  does not publish. The checkout and candidate views must publish every answer and carry the full
  corpora (the 25/19/10/5 counts). On `40a1fe3c` every view carries #2002.
- Mutations. Each of these, applied alone, made the new tests fail, and each was reverted:
  - a locked pager (a lock document beside the snapshots): 3 in-process tests and the
    real-process one;
  - no 256-byte cursor bound in the handler: 3 in-process tests and the hoststore order test;
  - show and reconcile without an owner answering Swift's unpublished `operationUnavailable`: the
    standalone test (the control layer answers it `internalError`).

## Checks

On the rebased head (`40a1fe3c` plus this commit) unless a row says otherwise.

| Check | Command | Exit | Result |
| --- | --- | --- | --- |
| Format | `cargo fmt --all --check` | 0 | clean |
| New and touched tests | `cargo test --locked -p arkdeck-agentd --bin arkdeck-agentd control_action`; `cargo test --locked -p arkdeck-agentd --test control_action_process`; `cargo test --locked -p arkdeck-hoststore --lib control_action`; `cargo test --locked -p arkdeck-control` | 0 | 4, 1, 2 passed; control 19 of 19 in `read_only` plus its unit test |
| Workspace | `cargo test --workspace --locked --no-fail-fast` | 0 | 892 passed, 0 failed, 16 ignored (121 test binaries and doc-test groups). On the stacked head: 875 passed, 0 failed, 16 ignored |
| Clippy | `cargo clippy --workspace --all-targets --locked -- -D warnings` for the host (`aarch64-apple-darwin`), `--target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc` | 0, 0, 0 | clean |
| Published view of `521c8fad`, locally (stacked head) | `check-contracts.py`'s `materialize` for merge base `521c8fad`'s contract inputs and this `rust/` (a scratch script, no source change), then `cargo test --locked -p arkdeck-control -p arkdeck-agentd -p arkdeck-hoststore --no-fail-fast` in it with its own build directory | 0 | 374 passed, 0 failed; there the replay covers that view's 11 corpus lines (5 by the owner, 6 without it, 5 counted) |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir rust/target/debug` (the validation virtual environment, jsonschema 4.26) | 0 | PASS: 125 control responses, 12 CLI envelopes, 116 valid requests; the standalone daemon answers the five methods as the table above, each validated against its schema |
| The actual CLI against the actual isolated daemon | a scratch script: `arkdeck-agentd` over a fresh development root, then `arkdeck <leaf> --output json --socket <endpoint>` with `ARKDECK_DAEMON_PATH` naming that daemon (binaries SHA-256 `3aef4438…` CLI, `909b430b…` daemon) | see result | `control-action list`, and `list --kind hdcLifecycle --state awaitingImpactApproval --page-size 1`: exit 0, the empty page; `control-action show` and `reconcile` of an exact identity: exit 75 `outcomeUnknown`, wire code `resourceNotFound`; `runtime hdc impact-preview` and `restart`: exit 75 `outcomeUnknown`, wire code `operationUnavailable`. The CLI keeps a refusal's code only with the pre-admission proof, which these methods' published details do not admit. Two snapshots were written and no `hdc-control-actions` |
| Contract manifest | `python3 rust/scripts/generate-contract.py --check` | 0 | 105 methods, 775 recorded shapes, identity `1d7d101e83fe…` |
| Union merge | `python3 scripts/check_union_merge.py` | 0 | ok |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, through the host's serialized gate queue, with
`ARKDECK_PYTHON` and the planner both from a virtual environment carrying PyYAML 6.0.3 and
jsonschema 4.26.0.

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `f02bbcc2`, stacked on #2002's `ac99b973`, merge base `521c8fad`; 16:53:47–17:05:23 CST | `gate exit=0`. The common checks and SDD (`check_sdd`: 0 errors, 0 warnings); the design-system lane (83 of 83); the Swift lane (2,694 tests, then the process-identity-race and viewer-scale lanes); the Rust lane: `generate-contract.py --check`, format, Clippy, the workspace tests and both contract views, `check-readonly.py` in each. Cargo counted 2,625 passed, 0 failed and 48 ignored over the workspace run and both views, the new tests among them in each. Also `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` (36 fully audited). The published view built this Rust against `521c8fad`'s contract, without #2002 | `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/control-action-routes-gate.log`, SHA-256 `90e3ef6bb8d7c3aed2ef0b184eb50429598b462aacd9048eca89115a6f802f67` |
| r2 | `440fd2a8`, merge base `40a1fe3c`; 17:14:27–17:17:25 CST | `gate exit=0`. The planner selected the common checks and the Rust lane only: 11 changed files, no Swift or design-system input. The common checks and SDD (`check_sdd`: 0 errors, 0 warnings); in the Rust lane `generate-contract.py --check`, format, Clippy, the workspace tests, `test_contract_checks.py`, and the contract checks. The published view is covered by the candidate one, since this slice changes no contract input; the candidate view ran `arkdeck-contract`'s tests, the bins, `check-readonly.py` and the owner scripts. Cargo counted 938 passed, 0 failed and 16 ignored, the new tests among them. Also `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` (36 fully audited) | `/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-macos-agent-branches-20260919-7896b5/e4ca8ae5-02b3-4669-8ede-6d7975251bb2/scratchpad/logs/control-action-routes-gate-r2.log`, SHA-256 `35b63ef9be022665866c87c6ac251af388ef33401f3e423a06ab1da947be04be` |

After r1, #2002 merged as `40a1fe3c`. The slice was replayed onto it: `git rebase --onto origin/main`
dropped the frames commit, whose content #2002 carries unchanged, and nothing conflicted. The
rebased tree differs from r1's only by main's commits since `521c8fad` (#1995, #1996, #1998, #1999,
#2000, #2001 and #2002's frames-record evidence). The amend after r2 only fills in its row.

## Not run, and why

- **A managed HDC server and everything over it.** That is the HDC control-action owner and its
  durable records (`hdc-control-actions`), the impact source, previews, restart requests, the
  impact-approval human action and the console challenge. The Rust daemon starts no managed
  server. The committed success frames of `HDCControlActionContractTests` stand for it and are
  counted, not replayed.
- **The tool-selection owner and `runtime.tool.select`.** It is the same Swift handler, but not
  this slice's; the method keeps the foundation's `rejected`.
- **Recovery** of control actions at startup: design §L.1 item 13 is undecided.
- **A listing with more than one page.** No control action exists without a managed server, so no
  page has a next cursor.
- No device, no real HDC, no Swift daemon and no installed Runtime.
