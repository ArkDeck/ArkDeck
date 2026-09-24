# The Rockchip start-up reconciliation on the Rust Runtime (TASK-XPA-017, M4-4a2)

Before its engine starts, Swift's daemon reconciles the Rockchip state it
finds (`main.swift` 404–460). The Rust daemon now does the same, in both of
its compositions:

- **The binding's lineage.** In the production layout (a state directory
  `Agentd` below `ArkDeck`), the adopted Target moves along the adjacent edge
  its Loader binding records. The binding's Loader recovery proof is kept for
  after Job recovery.
- **The post-flash alias.** In every layout, an HDC address adopted as a
  second Target is proved, from terminal Flash history alone, to be the
  post-flash face of the Loader-bound Target. That relation is appended to
  the Target document.

A new Swift oracle records 20 starts over 18 roots. The Rust port replays it
byte for byte.

Base: protected `main` `333023ae` (#2154, M4-4a). Routed methods stay
**101/105** and executable operations 15/30. No contract input changes.

| Already on `main` | This change | Still remaining (M4) |
|---|---|---|
| The binding's reads, its lineage evidence and recovery proof; the Target store's lineage advance with its alias resolutions carried along; the post-flash route store; `flash.bind-current-loader` (#2150–#2154) | The Swift oracle `rockchip-startup`; Swift's alias reconciler ported whole, with the Target store's append of a proven relation; both compositions running the two steps; the check, after Job recovery, for a transition awaiting the binding; the Job record decoder reading `flash.dayu200` records | Settling a Job's enter-Loader transition, with the Flash runner; `flash.lanePlanPreview` and SPK-9 (M4-3, after the upstream ArkForge client change); `debug.start` and `debug.evaluate`; the two Flash operations, recovery and the post-flash alias publish (M4-4b) |

## The oracle

`RockchipStartupReconcileOracleContractTests` builds each root with Swift's
own stores and Job writers. It then runs `main.swift`'s steps over that root,
as written, and records:

- every file of the root, with its mode (`inputs/<scenario>/…`);
- for each start, the lines printed, the recovery proof, and the error that
  stops the start;
- the Target document each start leaves (`outputs/<scenario>/run-N/…`).

No device, daemon or engine is involved. It records
`rust/tests/fixtures/rockchip-startup/` (216 files).

**The binding's lineage** (7 roots, 8 starts):

- no binding;
- a revision-1 binding;
- an advanced binding, started twice (the second start moves nothing and
  prints nothing);
- a custom state directory, where the binding is never consulted;
- a lineage without its previous revision, printed as needing Loader
  onboarding;
- a lineage colliding with a Target adopted from the Loader;
- a binding that is not owner-only, which stops the start.

**The post-flash alias** (11 roots, 12 starts), over Swift's own alias
fixture:

- the complete proof, started twice;
- no route;
- no alias;
- a destructive unknown outcome on the alias;
- an unreadable Job record in the history;
- the establishing Flash with mismatched facts, without its capability, with
  an unfinished journal, or without its readback;
- the alias adopted after the Flash started;
- a later Flash's route receipt for the very same identities, under a Job
  this state never recorded. The relation is reused rather than proved again.

The last root was added after mutation M5 below survived the first 17. The
recording ran once. It was compared again, byte for byte, without the record
variable.

## Swift, as ported

**The start-up steps** (`arkdeck_hoststore::reconcile_rockchip_startup`), in
Swift's order:

- *The production layout only.* The binding is read. A binding that cannot
  be read stops the start, with the error Swift's start fails with.
- *The lineage.* The Target moves along the edge
  (`TargetStore::advance_binding_lineage`), and the recovery proof is kept.
  The line is printed only when the Target moved. A failure prints "Rockchip
  binding requires Runtime Loader onboarding: …".
- *The alias.* The reconciler runs, and its relation or its refusal is
  printed.

**The alias reconciler** (Swift `ProductRockchipTargetAliasReconciler`). Its
checks, in Swift's order, each refused in Swift's words:

- *The route.* The route, the binding and the canonical Target, and the
  route covering them.
- *The alias.* Exactly one other Target at the route's address and identity,
  at revision 1, behind the canonical one, with a Job-shaped route Job.
- *An existing relation.* A relation already there whose identities all match
  is reused.
- *The establishing Flash.* Its record and journal are read, then:
  - its operation, provider, Target, materialized identity and revision,
    profile, verification and partition plan (the canonical operation's
    DAYU200 recovery profile);
  - its capability correlation;
  - a clean terminal journal;
  - the six confirmed steps, with their declared effects;
  - the chronology.
- *Unknown outcomes.* Every unresolved device-affecting intent of a Job on the
  alias, each only an enter-Loader mode change observed before the Flash
  started.

The relation is appended by `TargetStore::append_alias_resolution` (Swift
`appendAliasResolution`):

- *The draft.* Validated as Swift validates it.
- *An existing relation.* The same relation is answered; a different one
  refuses.
- *Refusals.* A chain, or a reused Flash or intent proof, refuses.
- *The digest.* The new relation is digested onto the chain.

A journal is read as Swift's `DurableJournalRecovery.inspect(url:)` reads it:

- through no link (`O_NOFOLLOW`), as one regular file;
- refused if it changed while it was read;
- every completed record decoded before the replay.

Each refusal is Swift's `DurableFileError` as the daemon prints it
(`openFailed(path:errno:)`, `malformedCompletedRecord(line:)`,
`sequenceViolation(…)`).

**Compositions.**

- *Production* (written, not activated). It runs the steps right after it
  opens the Target store. Its lines go to stdout.
- *Isolated development owner.* It runs them over its Target store with its
  Job state as the state directory. That is a custom directory, as Swift's
  `--state-dir` daemon has, so only the alias is reconciled.

**After Job recovery** (`main.swift` 1342–1356): a DAYU200 Flash Job whose
enter-Loader transition awaits the binding the start carried its Target to
(`RockchipStartup::awaiting_transition`). Two or more stop the start with
Swift's `jobNotRunnable("multiple unresolved Loader transitions cover target
…")`.

**Found while porting: the Job record decoder refused every `flash.dayu200`
record.** The Rust decoder compared the record's `operationReference` with
the request's operation, but spelled an unversioned operation as `id@1`.
Swift writes the catalog descriptor's reference, and `flash.dayu200` is the
catalog's one unversioned (singleton) operation, named by its bare id. Every
Swift record of it therefore read as unreadable. That record would have been
quarantined at recovery, and it made the oracle's alias fixture read as an
unreadable Job. The decoder now derives the reference as Swift's
`RuntimeOperationReference.reference` does. A versioned operation is still
`id@version`, and a record whose reference disagrees with its request is
still refused.

## Declared differences

Each is fail-closed or T2:

- **An awaiting transition is named, not settled.** Swift's engine settles
  that Job without replay and prints "settled recovered Loader transition …".
  This Runtime does not settle it yet. It prints "Loader transition … awaits
  settlement at Rockchip binding revision N, which this Runtime does not
  settle yet; its outcome stays unknown", and the Job stays in
  `waitingForRecovery` for a Runtime that can. Jobs this owner cannot read
  there are reported in a line and do not stop the start.
- **Foundation's error texts.**
  - *An unreadable record.* An establishing Flash record that cannot be read
    or decoded, and a Job history that cannot be listed, keep the gate closed
    as in Swift, with the path and this Runtime's reason. Swift prints
    Foundation's own description, which carries object addresses.
  - *Replay violations.* A violation whose Swift text interpolates an event
    value (such as a duplicate event id) is printed with the replay's fixed
    reason.
- **The snapshot check.** The generation number is left out of the
  changed-while-read comparison, since only the superuser can read it.

**Found in the Rust Job owner, kept.** A state root holding Job directories
but no index is refused, rather than hidden behind a fresh one. Swift's
engine indexes every Job it writes. The oracle wrote only the Job
directories, so the production test creates the index before laying out the
oracle's root.

## Verification

**Local targeted checks.** `CARGO_BUILD_JOBS=2`, `CARGO_INCREMENTAL=0`, own
target `/private/tmp/arkdeck-m4-rust-target`, logs
`/private/tmp/arkdeck-m4-rockchip-startup-*.log`.

| Check | Command | Result |
|---|---|---|
| Swift recording | `ARKDECK_RUST_ROCKCHIP_STARTUP_RECORD=… run-swiftpm.sh test --filter RockchipStartupReconcileOracleContractTests` | exit 0; 18 roots, 20 starts (`swift-record.log`) |
| Swift verify | the same without the record variable | exit 0; byte for byte (`swift.log`) |
| Replay | `cargo test -p arkdeck-hoststore --test rockchip_startup` | 2 passed. Every start's lines, recovery proof, stopping error and Target document. A journal that is a link, a directory or malformed keeps the gate closed and appends nothing |
| Production | `cargo test -p arkdeck-agentd --test production_composition` (the three new tests) | 3 passed, over a temporary home below `/private/tmp`. The lineage's and the alias's lines before serving, and Swift's Target documents. An unreadable binding refuses the start with exit 69. One awaiting Job is named and stays `waitingForRecovery`; two refuse the start |
| Mutations | nine, each against its own tests (`mutations.log`) | 7 caught. Two survived: an effect comparison that no valid journal can reach, and a reuse ignoring the USB topology alone, which no recordable root drifts. M5 was caught only after the republished-route root was added. Every source was restored by digest |
| fmt, clippy | `cargo fmt --all --check`; `cargo clippy -p <crate> --all-targets -- -D warnings` for `arkdeck-hoststore`, `arkdeck-agentd`, `arkdeck-soak` | exit 0 (`fmt.log`, `clippy-<crate>.log`) |
| Crate tests | `cargo test -p <crate>` | exit 0 each: `arkdeck-hoststore` 571 passed and 14 ignored; `arkdeck-agentd` 151; `arkdeck-soak` 4 (`test-<crate>.log`) |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv) | PASS on macOS; 135 control responses, as before (`readonly.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0 (`sdd.log`) |

**CI.** Pending.

**#2154 (M4-4a), recorded here.**

- *Head `6c876182`.* SDD Guard run 36060675863 passed.
- *Swift CI run 36060676331, attempt 1.* Red in `rust-checks / Rust workspace
  (macos-26)`. The failure was
  `managed_hdc::tests::host_never_claims_zero_dispatch_after_lifecycle_audit_failure`:
  its loopback endpoint, chosen by `free_port()`, was held by another
  listener before the launch.
- *Why the run is invalid.*
  - The failure lies outside the change: `managed_hdc.rs` was not touched.
  - It is the known loopback port race.
  - The coordinator's rerun, attempt 2, passed every lane and the `swift`
    aggregate.
  - It is unrelated to the diff.
- *Merged* as `333023ae`, with content identical to the head.

No device, installed service, real `arkforged` or App was used, and nothing
here is device evidence.
