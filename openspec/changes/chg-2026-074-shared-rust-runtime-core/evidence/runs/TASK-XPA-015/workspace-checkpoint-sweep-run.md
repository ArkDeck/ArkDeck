# Workspace checkpoints and sweeps on the Rust daemon (TASK-XPA-015, M3)

The Rust daemon now plans, admits, runs, reconciles and publishes two more
workspace operations as Swift does:

- `workspace.create-checkpoint@1`: a rollback checkpoint of a project's
  declared source — a git object (`git -C <root> stash create`) when the
  project's profile pins a source-control tool, otherwise a sealed archive of
  the files the request names, written by the pinned archive writer into the
  Runtime-owned attempt store — under the Runtime's own one-use capability
  for the exact plan;
- `workspace.sweep-isolated-copies@1`: the Runtime-owned isolated copies whose
  Jobs are all terminal, measured (dry run) or destroyed under the retention
  the request chose, with their audit records kept.

A new Swift oracle of 58 frames replays byte for byte, with the capability
store, the published products, the sealed archive, the copies' audit records
and the durable records of the two Jobs whose receipt was lost.

Base: protected `main` `10aede724` (#2190, the four reads); written on #2190's
branch before it was merged, and rebased onto its squash without conflict.

| Already on `main` | This change | Still remaining (M3) |
|---|---|---|
| `prepare-isolated-copy`, `apply-patch`, `revert-patch`, `build-openharmony`, `sign-openharmony-hap` (#2145, #2146, #2153); the four reads (#2190) | The Swift checkpoint and sweep oracle; plan, admission (the Runtime-owned policy), run, reconcile and result of both operations; the isolation manager's inventory and sweep; the Job store as the sweep's reference ledger | `run-tests`, `symbolize-crash`; the `operation.list`, project and preset availability projections; GJ-5 |

## The oracle

`WorkspaceCheckpointOracleContractTests` composes Swift's daemon composition
over two fabricated projects under
`/private/tmp/arkdeck-workspace-checkpoint-oracle` —
`CheckpointOracleProject`, a project inside a larger committed git checkout
(as the WaterFlow demo ships), with source control, a reader and an archive
writer, and `ArchiveOracleProject`, a plain project with an archive writer
only — and drives every Job through the production control plane:
`RuntimeControlPlaneHandler` over a `RuntimeJobEngine` whose provider is
`WorkspaceProvider` over `WorkspaceOperationsProvider`, with
`EvolutionWorkspaceManager` as its isolation manager and sweeper,
`WorkspacePatchAttemptStore` as its patch lineage, `RuntimeOwnedWorkspaceDispatcher`
over `DescriptorBoundProcessDispatcher`, and the engine itself installed as the
sweep's reference ledger. It records, in
`rust/tests/fixtures/workspace-checkpoint-oracle/`:

- 58 frames in order. The checkpoints: a git checkpoint of a clean working
  copy (no object: the Job fails `workspace.checkpointEmpty`, and the
  Runtime's own one-use capability for that plan is spent); one after an
  edit (the capability's next generation, `-G2`); a capability the caller
  names (refused: the policy is the Runtime's own); a stale revision (refused
  by name at plan and submit); an archive checkpoint sealing two files; the
  archive refusals (no files named, a missing file, a file outside the
  scope); a receipt lost after the child ran (parked, reconciled without a
  readback, never run again). The sweeps, over two Runtime-owned copies — one
  read, one named by a Job admitted but not yet run — and two strangers in the
  copies' root: a dry run, the age bound and the latest-count bound (nothing
  destroyed); the sweep that destroys the quiescent copy (its reference then
  refused at plan); a sweep whose receipt is lost after it ran (it destroyed
  the other copy all the same; parked, reconciled as still unknown, never run
  again); a fresh sweep, for which a destroyed copy no longer vouches (both
  copies and the stranger kept as unknown).
- The capability store's checkpoint and ledger; the products of the
  checkpoint and sweep Jobs (two envelopes and five findings documents — the
  failed checkpoint and the two Jobs whose receipt was lost publish nothing);
  the sealed archive; each copy's manifest and teardown record, and what every
  entry of the copies' root still holds; the durable records of the two parked
  Jobs.

`grep.sh`, `sed.sh`, `git.sh` and `bsdtar.sh` stand in for the tools the
profiles pin, with fixed bytes, so the plans and capabilities name the same
executables on every host. The git stand-in fixes the author, the committer
and their dates, and the bsdtar stand-in writes a portable ustar archive with
fixed ownership and no Mac metadata (`--format ustar --uid 0 --gid 0 --uname
root --gname wheel --no-mac-metadata --no-xattrs --no-acls --no-fflags`), so
the checkpoint objects repeat; the sources are written 0644 with a fixed
modification time. Two recordings were identical and the checked-in fixture was
then verified. Every answer the Rust replay gives (Swift's) is admitted by the
published method schemas, which the replay asserts, so no contract input
changes.

## Swift, as ported

**The checkpoint action** goes through `WorkspaceOperationsProvider`'s
preamble (the profile the request names, the operation available in it —
every pinned tool of the profile re-measured — and a stated revision
enforced). With a source-control tool it is `-C <root> stash create` in the
root: `stash create` writes one commit object and moves no ref, index entry or
working file. Otherwise, with an archive writer, it is
`-c -f <destination> -C <root> -- <files, sorted>`: the files the request
names (`workspace input checkpointFilePaths is missing` without them), each
inside the profile's scope (`workspace.patchScopeViolation:<path>`) and
present (`workspace checkpoint cannot seal a missing source file`), 60 MiB
together at most; the destination `checkpoint-<sha256(job)>.tar` in the
attempt store, which only that Job derives, must be absent. The step is
lowered only while the executable is one the acting profile pinned, the
destination still the Job's own and absent, and the declared files still as
materialized.

**The checkpoint verdict.** A truncated output fails
`workspace.outputTruncated`; a non-zero exit `workspace.checkpointFailed`. A
git checkpoint is its object id — 40 lowercase hexadecimal characters on
stdout — or `workspace.checkpointEmpty` ("git produced no checkpoint object
for this workspace": a clean tree has nothing to stash, and calling that
success would let a repair believe it can roll back). An archive is
synchronized and read back: a regular, non-link file of 1 KiB to 64 MiB in
whole 512-byte records ending in two zero records
(`workspace.checkpointReadbackFailed` otherwise), with the declared files
still as they were (`workspace.checkpointSourceDrift`). The verified summary
adds `checkpointObject`, `checkpointKind` (`gitObject` or `sealedArchive`) and,
for an archive, `checkpointByteCount`.

**The checkpoint product** `checkpoint.txt` is, as Swift's store publishes
it, the default envelope (the product, operation, Job, Catalog digest and
the verified facts, canonical pretty JSON) under the catalog's media type
`text/plain`, through the redacting text path.

**The checkpoint's authority.** The catalog authorizes the mutation with the
Runtime's own policy (`runtimeCapability`, issuance enabled). Admission
measures the tree the request names, refuses any capability a caller names
("caller-supplied capabilities cannot admit a Runtime-owned policy",
`admissionDenied`) — for a primary tree and a copy alike — and otherwise
issues the Runtime's own: the policy identity is the one Swift fingerprints
(operation, effect, no target, plan digest, inputs), the envelope scoped to
the tree (`workspaceIdentity`: identity, revision now, scopes digest), 30
days, **one use, pinned to the exact plan** (`maximumUses: 1`,
`exactPlanDigest`: Swift's `pinsExactPlan` for a Runtime-owned policy). A
spent generation rolls to the next (`-G2`, `-G3`), a revoked one does not.
The run materializes the plan again, measures the tree again, consumes the
use before the write-ahead intent and settles it with the Job's state
(confirmed, or unknown while parked), in the host target's mutation lane.

**The checkpoint reconcile.** As for every workspace mutation, Swift's engine
has no dedicated readback: the persisted action is materialized, and the
decision is "mutation has no dedicated readback; original not resent"; the
Job stays `waitingForRecovery` and is never run again.

**The sweep action** is routed before the per-project preamble — it names no
project: the provider's own profile must be a primary one with an isolation
manager beside it (`workspace.isolationManagerUnavailable`), the retention
inside its bounds (`retainLatestCount` 0…64, `minimumQuiescentSeconds`
0…7,776,000: `workspace.sweepInputsOutOfBounds`) and `dryRun` a boolean
(`workspace.sweepInputsIncomplete:dryRun`). The typed intent records the Job
that owns it and the engine's clock as its retention clock; the plan is a
host workspace action pinned by the intent's digest
(`workspace.sweep-isolated-copies/v1#action-sha256:<digest>`), running no
process.

**The sweep** is Swift's `dispatchSweep` over `sweepTerminalWorkspaces`. The
testimony comes only from the Runtime's own stores: the isolation manager's
inventory of its copies (at most 4,096 entries; a manifest naming a
`runtime-` owner), each vouched for as adoption vouches — its scopes' digest,
its primary source, a tree whose revision is its base or what the durable
patch lineage derives — and the Job store's durable rows: a Job references a
copy when it made it or its request names the copy's reference; the copy is
quiescent when every referencing Job is terminal (the repository's own active
set), dated by the newest terminal transition. An unvouched or unreferenced
copy is not attested. Every `evo-` directory of the store is then judged: one
with no reference, two references or a manifest that disagrees is kept as
unknown; one with a Job still active is kept as active; of the quiescent ones
still holding a tree, the newest `retainLatestCount` and those younger than
`minimumQuiescentSeconds` at the retention clock are kept by policy (an
unreadable clock keeps); every other one is destroyed — its tree renamed to
`.workspace.doomed` then removed, its derived profile unregistered, its
teardown recorded once — or, in a dry run, measured. The manifest and the
attempt manifests always survive. The findings (every `evo-` entry, by name:
disposition, reclaimed bytes and, when attested, the referencing Jobs,
whether all are terminal and the newest transition) are one canonical
document; the receipt pins its digest, the dry-run flag and the counts, the
provider verifies them against the intent, and the document is published as
`sweep-findings.json`.

**The sweep's admission and reconcile.** `hostOnly` under the default
read-only policy: no capability. What a sweep destroyed is derivable only from
its findings, so Swift's provider neither confirms nor denies a sweep whose
receipt was lost: "sweep outcome is derivable only from its findings; submit a
fresh sweep"; the Job stays `waitingForRecovery`, never runs again, and a
fresh sweep resumes whatever it left.

## The tools

- `/usr/bin/git` and `/usr/bin/bsdtar` follow the `/usr/bin/patch` precedent
  the coordinator ruled on (2026-09-25, C3), as the reads' tools do: absolute
  paths, hashed when the profile is composed, the whole profile re-measured at
  every plan and run (`workspace.toolIdentityDrift` before any intent), opened
  by the pinned digest at dispatch; argv only, no shell.
- Child environment: the Rust runner's clean base
  (`PATH=/usr/bin:/bin LANG=C LC_ALL=C`), where Swift's children inherit the
  daemon's `PATH`, `HOME`, `TMPDIR` and `LANG` (declared, as for the reads, the
  patches and the builds). For a git checkpoint this means git reads no user
  configuration and takes the commit identity from the system account (on
  this host it does: `stash create` succeeds in the clean base), so the
  object id differs from the one Swift's child would write for the same tree.
  Both are valid, content-addressed checkpoints of the same tree; the id is
  never compared across Runtimes.

## Choices on the refusing side

- **An archive destination is refused when anything is at it**, a dangling
  link included; Swift's `fileExists` follows the link. The archive is opened
  for its synchronization without following a link.
- **The sweep's ledger reads the Job rows in one snapshot**; Swift reads the
  Jobs and the active set in two queries.
- **Copy manifests are read without following a link**, as the Rust adoption
  already reads them.
- **A provider refusal at run time fails the Job** before any intent, as for
  every workspace operation on this Runtime.
- Failure details that only Foundation can spell (a file that cannot be
  synchronized, an unreadable archive) carry the Rust description instead;
  none of them is in the oracle.

## One seam: a host action's receipt

Swift routes every workspace plan — a process or a Runtime-owned host action —
through one workspace dispatcher, so the oracle's receipt-losing dispatcher
loses the sweep's receipt too. `WorkspaceToolDispatch` gains
`host_receipt(step)`, called after the sweep ran; the production dispatch
always hands the receipt back. Only the sweep uses it
(`prepare-isolated-copy` is unchanged).

## Production composition

A daemon test (`workspace_checkpoint_process`) runs both operations through
the production composition's socket: the capability it issues, the host's
own git and bsdtar, the Job store as the ledger. There a destroyed copy's
reference is refused before materialization by the registered-project owner
(`workspace project is not registered`, `invalidInput`), as any reference no
project registers; the oracle composition, which has no project owner, names
the missing profile (`workspace.projectProfileUnavailable:<reference>`).

## `operation.list` and project answers

Not changed by this PR.

## Tests

- `workspace_checkpoint_oracle` (hoststore, 7):
  - the 58 frames replayed in order over the same fixed root, profiles, tools
    and clock, every answer Swift's (the plan's additive review digest aside);
    the capability store, the products, the archive, the copies' manifests,
    teardowns and root, and the two parked records byte for byte; six
    children and six sweeps in all;
  - a checkpoint tool whose bytes changed after its pin — git for the
    checkout, bsdtar for the plain project — refuses the fresh action before
    any intent with nothing started, and plans name the drift;
  - a git tool swapped between the lowering and the spawn is refused at its
    dispatch and never runs;
  - no capability a caller names admits a checkpoint — neither one the store
    does not hold nor a person's grant the store holds for that tree,
    operation and plan — for either project; nothing is admitted; the
    Runtime's own is one use of the exact plan for that tree;
  - a copy whose tree moved from its base (no lineage vouching) is kept as
    unknown with its tree and without a teardown, and still resolves, while
    the quiescent copy beside it is destroyed and no longer resolves;
  - an archive never writes over what is at its destination: the fresh
    action refuses, the writer never starts, the file is left as it was;
  - the host's own `/usr/bin/git` and `/usr/bin/bsdtar` in the clean base: a
    commit object, the stash list, index and status as they were; an archive
    listing the declared files, its digest and size the verified facts.
- `workspace_checkpoint_process` (agentd, 1): the production daemon over a
  temporary home, a git-backed and a plain registered project, restarted to
  compose them: the git checkpoint plans `runtimeCapability`/`deviceMutation`,
  runs under `-G1` and publishes its object (a commit; the working copy as it
  was); the next runs under `-G2`; a named capability is refused; the plain
  project is sealed; a copy is measured by a dry sweep and destroyed by a wet
  one, its teardown recorded, its reference then refused.
- Unit tests: the git verdict, the persisted actions' round trips, the sealed
  archive's footer and bounds, the sweep intent's canonical encoding and the
  receipt checks.

Mutations (`scratchpad/s28/mutate_b.py`), each caught by a failing test and
restored by checksum:

| Mutation | Caught by |
|---|---|
| A capability the caller names admits a checkpoint | the recorded sequence; the named-capability test |
| The Runtime's checkpoint capability not pinned to one use of its plan | the recorded sequence (the capability store); the named-capability test |
| A checkpoint skips the profile's availability and revision | the recorded sequence; the drift test; the vouching test |
| The git checkpoint's argv without `-C <root>` | the recorded sequence (the plan digest) |
| The archive's argv without its option terminator | the recorded sequence (the plan digest) |
| An archive writes over what is at its destination | the destination test |
| An empty stash accepted as a checkpoint | the recorded sequence |
| A sweep attests a copy nobody vouches for | the recorded sequence; the vouching test |
| A sweep destroys a copy an active Job names | the recorded sequence |
| A sweep judges entries that are not copies | the recorded sequence (the findings) |
| A dry run destroys | the recorded sequence |
| The teardown is not recorded | the recorded sequence (the copies' records); the vouching test |
| The ledger counts only the Job that made the copy | the recorded sequence; the vouching test |
| A lost sweep reconciled as not executed | the recorded sequence |

14/14 caught, every source restored by checksum (the script asserts it).

## Local targeted checks

With `CARGO_BUILD_JOBS=2` and this tree's own target; logs are
`/private/tmp/arkdeck-s28-*.log`.

| Check | Command | Exit | Log |
|---|---|---|---|
| Format | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | `arkdeck-s28-b-fmt.log` |
| Lints | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings` | 0 | `arkdeck-s28-b-clippy.log` |
| Lints, cross | the same with `--target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc` | 0, 0 | `arkdeck-s28-b-clippy-<target>.log` |
| Tests | `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --no-fail-fast`: 103 targets, 797 passed, 0 failed, the 14 existing ignored | 0 | `arkdeck-s28-b-test.log` |
| The oracle | `cargo test -p arkdeck-hoststore --test workspace_checkpoint_oracle`, again after the destination test and the schema assertion were added: 7 passed | 0 | — |
| The daemon | `cargo test -p arkdeck-agentd --test workspace_checkpoint_process`: 1 passed (also in the tests log) | 0 | `arkdeck-s28-b-test.log` |
| Swift recording | `ARKDECK_RUST_WORKSPACE_CHECKPOINT_RECORD=<dir> sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter WorkspaceCheckpointOracleContractTests`, twice (identical), then in verify mode over the checked-in fixture | 0, 0, 0 | `arkdeck-s28-checkpoint-{rec1,rec2,verify}.log` |
| Read-only surface | `check-readonly.py --bin-dir <target>/debug --output-dir <new dir>` (validation venv) over the freshly built `arkdeck` and `arkdeck-agentd`: PASS, 136 control responses | 0 | `arkdeck-s28-b-check-readonly.log` |
| Mutations | `scratchpad/s28/mutate_b.py` | 14/14 caught | `arkdeck-s28-b-mutations.log` |
| SDD | `sh scripts/check-sdd.sh` (validation venv) | 0 | `arkdeck-s28-b-check-sdd.log` |

No daemon, child or temporary root of these tests was left running or
behind. Not run: `generate-contract.py --check` and `check-contracts.py`, as
no contract input changed; the App, signing, the installed service and real
devices, none of which this change touches.

## CI

PR #2192, merged as `5959a3194`: Agent PR 36141439476 (`open-pr`), SDD Guard
36141439593 (`guard`, `ds-tokens`) and Swift CI 36141439587 (`plan`,
`swift-tests`, `ds-interactions`, the Rust host-independent checks, the Rust
workspace on ubuntu-latest, macos-26 and windows-latest, and the `swift`
aggregate; `app-build` skipped by the plan) all succeeded at `7a8ca04ce`.
