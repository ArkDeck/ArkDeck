# Workspace patches on the Rust daemon (TASK-XPA-015, M3)

The Rust daemon now executes `workspace.apply-patch@1` and
`workspace.revert-patch@1`, the two mutations of the GJ-5 repair loop. A patch
is applied to a Runtime-owned isolated copy under the capability the Runtime
issues for that copy, and reverted exactly from the Runtime's own durable copy
of the patch; a patch against a person's primary tree is refused before
admission; a copy a patch changed is adopted again after a restart through its
durable patch lineage. A new Swift oracle of 30 frames replays byte for byte,
with the durable attempts, the capability store, the copy's tree, its adoption
at three points and the parked Job's record.

Base: protected `main` `642cac83` (#2145).

| Already on `main` | This change | Still remaining (M3) |
|---|---|---|
| The workspace project and preset owner and the DevEco pins (#1989, #2056, #2073, #2076); `workspace.prepare-isolated-copy@1`, copy adoption and the workspace-subject issuance rule (#2094, #2145) | The Swift patch oracle; plan, admission, run, reconcile and result of both patch operations; the pinned patch tool and its dispatch; the attempt store; patch lineage in adoption; the copy's capability issued and consumed; the primary tree refused; patch steps serialized in a mutation lane; a copy's uncertain Job mapped to its source in the Job census | build and sign (slice 12) and the other eight operations (slice 13); the project and operation availability projections; GJ-5 |

## The oracle

`WorkspacePatchOracleContractTests` drives one Runtime-owned copy and every
patch Job through Swift's production control plane
(`RuntimeControlPlaneHandler` over a `RuntimeJobEngine` whose only provider is
`WorkspaceOperationsProvider`, `EvolutionWorkspaceManager` reading
`WorkspacePatchAttemptStore` as its patch lineage, the daemon's own
composition order) and records, in `rust/tests/fixtures/workspace-patch-oracle/`:

- 30 frames in order: the copy made; a stale `expectedWorkspaceRevision`
  refused by name at plan and submit (`workspace.revisionConflict`, zero
  dispatch); a patch outside the copy's scope refused at plan
  (`workspace.patchScopeViolation`); a patch applied under a Runtime-issued
  capability; a hunk that does not apply (`workspace.patchFailed`, the Job
  fails); the exact attempt reverted, then refused a second time (no longer
  active); the primary tree planned but never admitted, without a capability
  and with one the Runtime never issued; a receipt lost before the child ran
  and one lost after it ran, each parked, reconciled without a readback and
  never run again, and the same mutation refused while its use is unsettled
  (`lineageBlocked`).
- What the Runtime keeps: the attempt store, the capability store's checkpoint
  and ledger, the copy's tree, what a restarted isolation manager adopts after
  the apply, after the revert and at the end (the copy the lost child patched
  is refused `:revision`), and the parked Job's durable record with its
  persisted typed action.

`patch.sh` in the fixture stands in for `/usr/bin/patch` with fixed bytes: the
plan digest and the capability identity name the executable's digest, which
differs between macOS builds, so the stand-in keeps every recorded identity the
same on every host; it runs the host's patch with the lowered argv. The
recording ran once and was then compared twice in verify mode, byte for byte;
every frame validates against the published method schemas, so no contract
input changes.

## Swift, as ported

**Plan.** The provider's shared preamble (the profile the request names, the
operation available for it, the stated revision enforced over the whole
profile scope), then per operation:

- *apply*: the patch lease resolved and bound to the request's own target (an
  Import lease included), the bytes re-read and checked against the lease
  (4 MiB), the unified diff's declared paths (Swift's parser, Character by
  Character: a CRLF diff is one line), every path inside the profile's and
  the request's scopes, relative, through no link and a regular file where it
  exists, the files' snapshots, and the attempt
  `patch-` + 32 hex digits of `sha256(<Job>\n<patch digest>\n<project>)`; a
  copy's apply must state its revision.
- *revert*: the exact durable attempt, still active in this profile, its
  durable bytes unchanged.

Both lower to one process: the patch preset's pinned executable with
`-f [-R] -p1 -d <root> -i <file>`, in the root the argv names. The plan
materializes for the authorization envelope's Job and binds the executable's
digest, the argv and the timeout, and an apply its patch Artifact's facts.

**Admission.** A workspace subject's capability is matched against the tree's
identity, its revision now and the profile's writable scopes. A Runtime-owned
copy with no capability named is issued the Runtime's own
(`CAP-RT-POLICY-…-G<n>`, the tree's revision pinned, 10,000 uses, 30 days)
and validated; a named one is validated as named.

**Run.** The patch lease resolved again; the typed action materialized for
the Job and lowered against the tree as it is now (the pre-image for an apply,
the attempt's post-image for a revert); the use consumed — the whole plan
materialized again and equal to the admitted one, the tree measured again,
the capability's policy identity recomputed — and its evidence durable; the
typed action persisted before the write-ahead intent; only then the tool. Its
receipt and the declared files read back decide the outcome: an apply's patch
bytes copied into `workspace-patch-attempts/` and its attempt written (with
the copy's revision before and after), a revert's attempt closed. The product
(`applied-patch.json`, `revert-report.json`) is Swift's default envelope,
published after the correlated outcome, and the use is settled with the Job.

**Lane.** As Swift's engine runs a mutation Job's steps inside
`DeviceMutationLaneCoordinator` for its target, a patch Job's step runs
inside the workspace composition's lane, taken after its running transition
and held to its last step. A patch that waited for another one plans again
against the tree that one left, so a second patch admitted against the same
revision fails `workspace.revisionConflict` before its intent instead of
running beside the first. The Rust device runner has no such lane yet (M2);
this slice does not change it.

**Reconcile.** As Swift's engine: the patch lease resolved again and the
persisted typed action materialized, then — the workspace provider having no
dedicated readback for a mutation — `mutation has no dedicated readback;
original not resent`. The Job stays `waitingForRecovery`, its use unknown,
and nothing is read from the tree or resent. The provider's own
snapshot-comparing `reconcile` is not reached by Swift's engine for a
mutation, so it is not ported.

**Adoption.** A copy whose tree measures its base revision is adopted as
before; one that moved is adopted only where the durable lineage (every
attempt of the copy, by `appliedAtUTC`, each `before` extending the current
revision, an applied one advancing it, a reverted one not) derives exactly the
revision it measures. A lineage the store cannot read vouches for nothing.

## The patch tool

`/usr/bin/patch` stays an absolute path, as the coordinator ruled on
2026-09-20: every composed profile hashes it when the daemon composes it (its
first use), every plan re-measures it (a changed file makes the operation
unavailable, `workspace.toolIdentityDrift`), and the dispatch opens it by the
pinned digest and runs its retained inode, so bytes that changed after the
plan are refused, never run. Argv only, no shell, the clean base environment,
`/dev/null` as stdin, each stream bounded to 8 MiB. This is this slice's
reading of the XPA-015 line "`/usr/bin/git` replaced by a registered toolchain
reference" for the one tool the patch operations run; no registered reference
is added for it.

## Capability admission

- A Runtime-owned isolated copy is issued, reserved and consumed only by the
  Runtime: its capability is derived from the plan, the tree and the scopes,
  and a caller can neither create nor widen it.
- A person's primary tree needs a standing capability a person issued. This
  Runtime has no path that issues one and honours none: a request naming no
  capability is refused with Swift's `effect deviceMutation requires an
  explicit runtime capability`, and one naming any is refused with Swift's
  answer for a capability its store does not hold (`capability denied
  [denial:capabilityNotFound]`), even when the store holds a grant a person
  issued for that exact request. Both are `admissionDenied` with zero
  dispatch. No issuance path is added.

## Choices on the refusing side

- **A primary tree is never admitted**, as above; Swift would validate and
  could admit a person-issued standing grant.
- **A provider refusal at run time fails the Job** before any intent (the tree
  moved since admission, the attempt is no longer active), as #2145 does for a
  copy; Swift's run escapes and leaves the Job `running`.
- **A child whose effect cannot be read back parks the Job**: when the
  declared files, the durable patch or the attempt cannot be read or written
  after the child ran, the intent stays outstanding; Swift's verify throws
  there and leaves the Job to a later start's recovery.
- **Attempt records and durable patches are written owner-only**; an attempt
  that cannot be read is answered as not active, never with a Foundation error
  naming a host path.
- **Patch steps are serialized per workspace composition**, not per target
  name: two patch Jobs never overlap, whatever host target they name.
- **Session publication** of a patch Job is refused as Swift's writer refuses
  it: an intent above host-only makes it a device Session, which a Job without
  a device observation cannot substantiate (`sourceIntegrityFailed`). The Job
  itself stands. Ported unchanged.

## The Job census

A Runtime-owned copy's Jobs belong to the project it was copied from. #2145
mapped a copy's reference to its source through the provider's profiles, so a
copy this Runtime could not adopt — a patched tree no lineage vouches for,
exactly the copy an interrupted patch leaves — mapped to nothing and was
compared literally: its uncertain Job no longer kept its source project from
being removed. The census now also reads the copy's manifest
(`census_registration`), so such a Job still names its source. Only a
reference nothing maps is compared literally, as Swift compares one.

## Tests

- `workspace_patch_oracle` (hoststore, 6):
  - the 30 frames replayed in order over the same fixed root, profile, tool
    and clock, every answer Swift's (the plan's additive review digest aside);
    the attempts, the capability store, the copy's tree, the three adoptions
    and the parked record byte for byte;
  - a primary tree refused without a capability and under a person-issued
    grant the store holds, nothing admitted or started;
  - a tool swapped between lowering and dispatch never runs (the Job fails,
    the copy unchanged), and a drifted tool leaves the operation unavailable;
  - a patch interrupted while its child runs (the process gone before any
    outcome): the restarted Runtime parks it, refuses another run, reconciles
    it without a readback, keeps its use unknown, does not adopt the copy it
    changed, and still refuses the source project's removal;
  - the real `/usr/bin/patch` applies to a copy and reverts it, the copy
    adopted after each;
  - two patch Jobs admitted against one revision: the second waits in the
    lane while the first's child runs, then fails `workspace.revisionConflict`
    before its intent; the tool starts once and the copy is patched once.
- `workspace_patch_process` (agentd, 1): the production composition over a
  temporary home, through its socket — a registered project, a patch imported
  for the host target, the copy made, the patch planned, admitted under a
  Runtime capability, run with the real `/usr/bin/patch` and published, the
  primary tree refused, a restart adopting the patched copy, and the exact
  attempt reverted.
- Unit tests: the diff parser (Character semantics, BOM, CRLF, refusals), the
  snapshot revision, the lineage, the persisted action's round trip.

Mutations (`scratchpad/s21/mutate.py`), each caught by a failing test and
restored by checksum:

| Mutation | Caught by |
|---|---|
| Automatic issuance permitted for a primary tree as for a copy | the recorded sequence; the primary-tree test; the production process |
| A person's grant is honoured for a primary tree | the primary-tree test |
| A stale `expectedWorkspaceRevision` is let through | the recorded sequence; the lane test |
| The dispatch opens the tool by its current digest, not the pinned one | the drift test |
| A drifted tool stays available at plan time | the drift test |
| Reconcile confirms an interrupted patch not executed | the recorded sequence; the interruption test |
| An unobservable child fails the Job instead of parking it | the recorded sequence |
| Adoption ignores the patch lineage | the recorded sequence; the real-patch test; the production process |
| The census compares an unadopted copy's reference literally | the interruption test |
| An applied patch leaves no durable attempt | the recorded sequence; the real-patch test |
| Patch steps are not serialized (the lane taken by nothing) | the lane test |

## Local targeted checks

With `CARGO_BUILD_JOBS=2` and this tree's own target; logs are
`/private/tmp/arkdeck-s21-*.log`.

| Check | Command | Exit | Log |
|---|---|---|---|
| Format | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | `arkdeck-s21-fmt.log` |
| Lints | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings` | 0 | `arkdeck-s21-clippy.log` |
| Tests | `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --no-fail-fast`: 79 targets, 678 passed, 0 failed, the 14 existing ignored | 0 | `arkdeck-s21-tests-final.log` |
| The oracle | `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore --test workspace_patch_oracle`: 6 passed | 0 | `arkdeck-s21-lane-test.log` |
| Corpus replay | `check-corpus-replay.py --bin-dir <target>/debug` over the freshly built `arkdeck` and `arkdeck-agentd`: `observe-device`, 28 exchanges, 64 checks | 0 | `arkdeck-s21-corpus-replay.log` |
| Swift recording | `run-swiftpm.sh test --filter WorkspacePatchOracleContractTests` with `ARKDECK_RUST_WORKSPACE_PATCH_RECORD` set, copied into the fixture, then twice in verify mode, then with `--parallel --num-workers 2` | 0, 0, 0, 0 | `arkdeck-s21-swift-{record-1,verify-1,verify-2,parallel}.log` |
| Mutations | `scratchpad/s21/mutate.py`, every source restored by checksum | 11/11 caught | `arkdeck-s21-mutations-final.log` |
| SDD | `sh scripts/check-sdd.sh` | 0 | `arkdeck-s21-check-sdd.log` |

No fake HDC, daemon or temporary root of these tests was left running or
behind. Not run: `generate-contract.py --check` and `check-contracts.py`, as
no contract input changed (no `control-protocol.json`,
`spec/control/methods/**`, ControlFrames or CLI argv corpus: the new frames
live under `rust/tests/fixtures/` and validate against the published
schemas); the App, signing, the installed service and real devices, none of
which this change touches.

## CI

Pending.
