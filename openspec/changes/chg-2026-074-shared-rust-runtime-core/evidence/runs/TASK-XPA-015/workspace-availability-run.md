# Workspace availability, projects and presets as the Rust daemon composed them (TASK-XPA-015, M3)

The Rust daemon now publishes what its workspace composition can do the way
Swift's daemon publishes it, closing four defects S23 found:

- `operation.list` (and `operation.describe`, `target.availability`) answered
  every `workspace.*` operation `provider_not_registered`; it now answers each
  as Swift's registered workspace provider, its dispatcher and the Artifact
  store do;
- `debug.template@1` was `tool_identity_drift` whatever the HDC tool measured:
  the host asked after the tool's identity only for a hand-kept list of
  operations that had not caught up with it;
- a workspace project stayed `runtimeRestartRequired` after the start that
  composed it, with none of what that start published;
- a registered preset was `runtimeRestartRequired` forever.

Base: protected `main` `f7a3b73f7` (#2195, run-tests and symbolize-crash).
Independent of the `workspace.project.show` widening (#2197). Also fills the CI
sections of #2190's and #2192's run records.

| Already on `main` | This change | Still remaining (M3) |
|---|---|---|
| All 13 workspace operations executed by the Rust daemon (#2190, #2192, #2195); the registration owner and the applied generations it keeps | One Swift oracle over three starts of the daemon's composition, replayed; the workspace rows; the HDC tool check for every operation the executor runs; project and preset statuses and publications | `show`'s operation reasons as text (after #2197 lands); an idempotent `register` replay of an applied project; GJ-5 |

## What `operation.list` and the project answers now say (for the M4 CLI leaves)

Changed answers, all within the published schemas:

- **`operation.list`, `operation.describe`, `target.availability`** — the 13
  `workspace.*` rows. When the daemon composed a workspace provider (it has a
  registration owner): each row is Swift's `operationAvailability` —
  `WorkspaceProvider` for `workspace.inspect-source@1` (an inspector
  configured, some registered root), otherwise the operations provider over
  the start-up profiles (available when one profile serves it, otherwise the
  first profile's reason, or the resolution failure when none resolved); then
  the workspace dispatcher's reason unless it repeats one (no profile and no
  inspector: `no workspace ProjectProfile is configured`; profiles whose every
  pinned executable drifted: `provider executable is unavailable:
  failed("workspace registry has no available executable preset")`); then
  `runtime.artifactStoreUnavailable`. The Rust owners' reasons stay where they
  are for device operations: `runtime.mutationOwnerUnavailable` first for the
  five tree mutations (apply-patch, revert-patch, build-openharmony,
  create-checkpoint, run-tests), which consume a Runtime capability through
  that owner, and `runtime.jobOwnerUnavailable`. Codes and origins are Swift's
  (`workspace_preset_unavailable`, `tool_identity_drift`,
  `provider_tool_unavailable` are `host_configuration`). Without a
  registration owner the rows stay `provider_not_registered`.
- **`debug.template@1`** is `available` when the HDC tool is current, and
  `tool_identity_drift` only when it drifted, as for every other HDC
  operation this executor runs.
- **`workspace.project.list`** — a project whose registered generation this
  Runtime composed at start-up is `configurationStatus: active` and carries
  that start's publication: `availability` (available when any operation is),
  `reasonCode`/`reason` (`workspace_project_has_no_available_operation`, or
  `workspace_project_profile_unavailable` with the resolution failure for a
  project that did not resolve), sorted `allowedFileGlobs`, `presetRefs`
  (build, test, symbol, signing, by kind then reference, with timeouts) and
  all 13 `operations` in reference order with Swift's code and reason. The
  publication is the start's, as Swift's is: a tool that drifts later shows in
  `operation.list`, not here. A registration the start did not compose (new,
  or updated since) is still `runtimeRestartRequired` with empty members.
- **`workspace.project.show`** — the same, except each operation's `reason`
  and `reasonCode` stay `null`, as the published schema has them (declared;
  #2197 widens it).
- **`workspace.preset.list/show/register/update/remove`** —
  `configurationStatus` is `active` for a preset whose generation the start
  composed, `unresolved` for one the start tried to compose and could not (a
  Hvigor or signing preset whose toolchain or credential did not resolve),
  `removed`, and otherwise `runtimeRestartRequired`.

Unchanged: `workspace.project.register` answers the restart-required
projection even when an idempotent replay names an applied registration
(declared: Swift merges the publication, whose `null` reason the published
register result does not admit); `update` answers a new generation, so it
awaits a restart in both; `remove` now forgets the removed project's applied
generation, as Swift does, so a later registration of the same reference
awaits a restart.

## The oracle

`WorkspaceAvailabilityOracleContractTests` composes, three times over one
state directory, what `ArkDeckAgentDaemonMain` composes from the registration
owner — the start-up records, the registered presets (a symbol preset
through the configured symbolizer; a Hvigor preset through the DevEco
registry, which holds no toolchain here, so it fails as a daemon's does), the
OpenHarmony profiles, the isolation manager, the per-project publications,
the dispatcher chain and the applied generations — under the production
handler (only the signing dispatcher wrapper is left out: it forwards
`unavailableReason`). It records 33 frames:

1. No project: `operation.list` (the unavailable provider and the refusing
   dispatcher), an empty list; two OpenHarmony projects registered, a symbol
   preset each and a Hvigor test preset on the first; list, show and the
   presets, all awaiting a restart.
2. Both composed, an inspector configured: `operation.list`; both projects
   active with their publications; the symbol presets active, the test preset
   unresolved. The symbolizer drifts: `operation.list` names the drift for
   every operation with a preset, the publications keep what the start
   published. Restored; a second symbol preset, a removed one and an updated
   project await a restart.
3. The second project's root removed, no inspector: `operation.list`; the
   first project active with the new preset, the second active but unresolved
   (`workspace.projectRootUnavailable:…`); its preset removed.

Three recordings were identical, and the checked-in fixture was then verified
(the runner returned 1 for the first two recording runs although their one
test passed; the third recording and the verification returned 0).

**Not recorded, reported instead: a store no removal can read.** Removing a
project after removing its presets leaves the presets' tombstones naming a
project the document no longer holds, and both owners then refuse every read
of the store (`recordUnreadable`: Swift "workspace preset store record is
inconsistent", Rust "workspace project document or storage is
inconsistent"). The oracle stops before that removal; the defect, shared by
both implementations, is left for a ruling (it changes what the durable
document keeps).

## Swift, as ported

**Rows.** `WorkspaceComposition::provider_unavailability` (already ported with
the operations) is now asked; `dispatcher_unavailability` is Swift's
dispatcher chain: `CombinedWorkspaceExecutableResolver`'s generic resolution
over the start-up profiles' pinned executables (any one, in path order, that
still measures as pinned), the inspector's fixed route when no profile
resolved and an inspector is configured, and otherwise the refusing
dispatcher.

**Publications** are computed once, at start-up, by the composition — Swift's
`WorkspaceProjectPublication.make` asks a provider over each resolved profile
alone (`runtimeAvailability(for:profile:)`, signing included) — and handed to
the registration owner with the applied generations and the preset
resolution failures. `list` and `show` merge them as the handler's
`encodeRegisteredWorkspaceProject` does.

## Tests

- `workspace_availability_oracle` (hoststore, 1): the 33 frames replayed
  in order over the same fixed root, stand-ins and clock, with the registration
  owner and the composition restarted where Swift's were: every workspace row's
  availability, reasons, codes and origins, and every project and preset
  answer, Swift's (show's operation reasons aside), each answer admitted by the
  published method schemas.
- `operation_availability_control` (agentd, in-process daemon composition):
  `debug.template@1` available beside `observe.device@1` and drifting with it;
  a registered project composed at start: its rows (the mutation owner first
  for a tree mutation, which this development composition cannot acquire),
  `operation.describe`, and the project list and show active with the start's
  publication.

Mutations (`scratchpad/s28/mutate_d.py`), each caught by a failing test and
restored by checksum:

| Mutation | Caught by |
|---|---|
| workspace rows left unregistered | the oracle replay |
| the dispatcher's reason dropped | the oracle replay |
| a tree mutation needs no mutation owner | `workspace_rows_and_projects_follow_the_composed_provider` |
| `debug.template@1` left out of the HDC tool check | `live_discovery_and_describe_follow_actual_executors_and_executable_drift_without_dispatch` |
| an applied project publishes nothing | the oracle replay |
| any applied generation is active | the oracle replay |
| `show` publishes its operations' reasons | the oracle replay (and the published schema) |
| an unresolved preset awaits a restart | the oracle replay |
| a removed project stays applied | `a_removed_registration_is_composed_again_only_by_a_restart` |
| the publication asked of every start-up profile | the oracle replay |
| drift in one profile hides another's executables | the oracle replay |

11/11 caught (`/private/tmp/arkdeck-s28-d-mutations.log`).

## Local targeted checks

With `CARGO_BUILD_JOBS=2` and this tree's own target; logs are
`/private/tmp/arkdeck-s28-d-*.log`.

- `cargo fmt --all --check`: exit 0.
- `cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak
  --all-targets -- -D warnings`: exit 0; the same with `--target
  x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc`: exit 0, 0.
- `cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak
  --no-fail-fast`: exit 0; 108 targets, 815 passed, 0 failed, 14 ignored
  (existing).
- Swift: `ARKDECK_RUST_WORKSPACE_AVAILABILITY_RECORD=<dir> sh
  Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter
  WorkspaceAvailabilityOracleContractTests` three times (identical frames;
  the runner returned 1, 1 and 0, the one test passing each time), then in
  verify mode over the checked-in fixture: exit 0
  (`/private/tmp/arkdeck-s28-d-rec{1,2,3}.log`, `-verify.log`).
- `cargo build -p arkdeck-cli -p arkdeck-agentd`, then `check-readonly.py
  --bin-dir <target>/debug` (validation venv): exit 0, PASS.
- Mutations: 11/11 caught.
- `sh scripts/check-sdd.sh`: exit 0.
- Not run: `generate-contract.py --check` and `check-contracts.py` (no
  contract input changed), the App, devices, the installed service.

## CI

Pending.
