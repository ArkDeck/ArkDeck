# Binding the current Loader on the Rust Runtime (TASK-XPA-017, M4-4a)

The Rust daemon now answers `flash.bind-current-loader` as Swift's daemon
does. The caller names only an adopted Target and the revision it saw. The
Runtime then:

- reads every identity and port afresh from its USB census, and for a Loader
  has ArkForge's own enumeration confirm it;
- applies the manual USB rebind policy;
- makes exactly one of the binding owner's writes.

A new Swift oracle of 33 exchanges records the answers and every file each
exchange leaves. The Rust daemon replays it byte for byte, on its first run.

Base: protected `main` `4b89780f` (#2153, after #2152, M4-2b). Routed methods
**101/105** (was 100). Executable operations stay 15/30. One contract input changes: the
`flash.bind-current-loader` corpus gains three lines, and the Swift baseline
now counts 983 shapes. Its schema is unchanged.

| Already on `main` | This change | Still remaining (M4) |
|---|---|---|
| The binding's read side and evidence rules, the Target store's reads, the census, and ArkForge's half of the dual-source Loader observation (#2150–#2152) | The Swift oracle `loader-binding`; the binding owner's three compare-and-swap writes; the Target's lineage advance with its alias resolutions carried along; the Runtime reactivation proof; the coordinator; the route, both compositions, the App ingress allowance and `flash bind-loader` | Settling a Job's enter-Loader transition after a bind, with the Flash runner; `flash.lanePlanPreview` and SPK-9 (M4-3, after the upstream ArkForge client change); `debug.start` and `debug.evaluate`; the two Flash operations, recovery and the post-flash alias publish (M4-4b) |

## The oracle

`LoaderBindingOracleContractTests` drives Swift's `RuntimeControlPlaneHandler`
with `ProductRockchipLoaderBindingCoordinator`. The coordinator runs over:

- the Target store;
- the product binding store of an Application Support root;
- the Runtime's typed action records under its `Agentd/rockchip-runtime`,
  read by Swift's own `RockchipRuntimeBindingReactivationProofSource`.

It injects only what a host cannot fix:

- the USB census, in place of the I/O Registry;
- ArkForge's half of the Loader observation: confirmed, at another port, or
  refused with a text.

The engine holds no Job, so no transition is settled. No device, ArkForge
daemon, HDC or daemon process is involved.

It records `rust/tests/fixtures/loader-binding/`. Each exchange carries the
setup it names, its answer, and afterwards every file of the root outside the
engine, the state directory and the records, plus the Target document.

**33 exchanges.**

- *Before anything is read.* Parameters absent or zero, a Target never adopted,
  a stale revision, an empty Target.
- *The census.* Nothing attached, two boards, a registry that cannot be read,
  an unrelated device only.
- *ArkForge's half.* Refused, or seeing the Loader at another port.
- *The binding.* Absent, or shared.
- *The first cross-mode bind.* The bind, its retry at the old revision, and its
  retry at the new one. The board in its normal personality has no cross-mode
  binding.
- *A second board.* Ambiguous with a twin Target, then selected at revision 1,
  then retried.
- *A historical Target.* Refused without Runtime records, then reactivated from
  them, then retried.
- *A drifted Loader serial.* The binding migrates along its confirmed alias,
  and the Target's proven alias resolution follows it. Then a retry.
- *Refusals.*
  - A first cross-mode bind with no hdc-normal readback.
  - An ambiguous lineage.
  - A lineage that collides with a Target adopted from the Loader. The binding
    is written before the Target refuses.
  - A connect key that is not the alias.
  - A migration that is not adjacent.
  - A binding without attestation.
  - A serial the new evidence would name, refused before anything is written.

The recording ran once. It was then compared twice, byte for byte: once plainly,
and once with `--parallel --num-workers 2`.

**Found while recording.**

- *The reactivation records' root.* Swift requires the root to be its own
  `standardizedFileURL.path`. Foundation standardizes `/private/tmp/…` to
  `/tmp/…`, so Swift's source refuses every root below `/private/tmp` with "is
  not owner-only". The production root under `~/Library` is unaffected. The
  oracle's root is `/tmp/arkdeck-loader-binding-oracle`, and the port keeps the
  rule (`arkdeck_contract::foundation_path::standardized`).
- *The vendor.* Swift writes the RockUSB vendor into the binding's evidence as
  the decimal `UInt16` it interpolates: `usb:vendor=8711`.

## Swift, as ported

**The coordinator** (`arkdeck_hoststore::LoaderBinding`; Swift
`ProductRockchipLoaderBindingCoordinator.bindCurrentLoader`). Its branches, in
Swift's order:

- *The stale check.* The Target must sit at the expected revision or one
  past it.
- *The census.* Exactly one registered DAYU200. A Loader must also be confirmed
  by ArkForge at the same serial digest and port.
- *An initial selection.* An adopted revision-1 Target of another board takes
  the singleton binding over (`activate_selected_initial_target`).
- *A retry at the same revision.* It answers the attestation the binding
  carries: the revision-1 selection, the Loader recovery proof, or the
  reactivation selection. Anything else is refused.
- *A historical reactivation.* An advanced Target displaced from the binding
  comes back only with a complete Runtime proof (`activate_selected_target`).
- *The adjacent edge already drawn.* It is answered without writing.
- *The lineage move* (`replace`). It takes the prior confirmed alias, or on a
  first cross-mode bind the Target's connect key at the port the replaced
  binding saw in hdc-normal. The Target advances along the published edge.
- *The rebind policy* (`authorizeSelectedTarget`). For this one fresh
  candidate, the only refusal is an empty port (`emptyField`).

Every refusal is the error Swift's daemon interpolates, under `rejected` with
"Rockchip Loader binding was refused: ".

**The binding store's writes** (`RockchipBindingStore::{replace,
activate_selected_initial_target, activate_selected_target}`)

- *The lock.* `.rockchip-binding.lock`, owner-only, waited for, and unlocked
  explicitly.
- *Compare-and-swap.* The expected revision and serial, and the candidate's
  required revision.
- *The bytes.* `JSONEncoder` `.sortedKeys` with every slash escaped, and a
  newline (`BindingSnapshot::encode`).
- *Publication and readback.* Owner-only publication, then a readback.

**The Target's lineage advance** (`TargetDocument::advance_binding_lineage`,
`TargetStore::advance_binding_lineage`; Swift `advanceBindingLineage` and
`carryAliasResolutionsForward`)

- *The edge.* Strictly adjacent, idempotent for the exact edge. A collision or
  an ambiguity refuses with Swift's `storeFailure`.
- *The alias resolutions.* Each resolution naming the advanced Target moves to
  its new identity and revision. The whole chain is digested again, as Swift's
  `load` re-validates it.

**The reactivation proof** (`arkdeck_hoststore::ReactivationProofSource`)

- *The two facts.* A current-revision `wait-for-hdc` intent, and a confirmed
  `observeHDCNormalUSB` receipt of the previous revision.
- *Its checks.* Owner-only, single-link, bounded records with exact key sets.
  Their action digests are recomputed canonically. Their provider must match
  the current intent's. The earliest digests are taken.

**Compositions**

- *Isolated development owner.* Over its root and its flash census.
- *Production composition* (`main.swift` 1549). Written, not activated.
- *Both.* ArkForge's half of the observation reads the lane's directory.

**Clients**

- *The App ingress.* It admits `flash.bind-current-loader` with exactly
  `targetId` and `expectedBindingRevision`, as ClientKit's
  `FlashApplicationFacade.bindCurrentLoader` sends them.
- *The Rust CLI.* It serves `flash bind-loader`, which sends the revision as an
  integer. Swift's argv fixture is copied byte for byte.

## Declared differences

Each is fail-closed or T2:

- **A Job awaiting the binding refuses it.** Swift's handler first asks its
  engine for a DAYU200 flash Job parked in `waitingForRecovery`, with its
  outcome unknown at its `enter-loader-mode` intent, for this Target and
  revision. It settles that Job after binding. This Runtime does not settle it
  yet: such a Job refuses the bind before anything is written, with
  `jobNotRunnable("Job … awaits this Loader binding …; nothing was
  written")`, and its intent stays unresolved for the Runtime that can. Two
  such Jobs are Swift's own `multiple unresolved Loader transitions`
  refusal (`JobStore::loader_transitions_awaiting_binding`; tested in
  `tests/loader_binding_jobs.rs`).
- **Foundation's error texts.** Three I/O failures refuse in the same case as
  Swift's but with this Runtime's detail:
  - a Target document that cannot be read (`storeFailure("undecodable target
    store: …")`) or published (`storeFailure("cannot persist target store:
    …")`);
  - a reactivation directory that cannot be listed;
  - a binding publication that failed before its rename ("cannot be
    committed") or after it ("directory cannot be synchronized").
- **The binding lock's failures.** A lock that is not owner-only refuses as
  Swift's does. Every other failure to take it refuses as "binding lock cannot
  be acquired", where Swift may say it "cannot be opened".
- **The owner check.** The records must belong to the effective user, where
  Swift compares with the real one. For the daemon the two are the same.

**Kept as Swift has it.** A lineage move writes the binding before it advances
the Target. When the advance collides with a Target adopted from the Loader,
the binding stays moved and the Target does not, and the retry refuses as not
adjacent. The oracle records this, and the port reproduces it.

## Verification

**Local targeted checks.** `CARGO_BUILD_JOBS=2`, own target
`/private/tmp/arkdeck-m4-rust-target`, logs `/private/tmp/arkdeck-m4-lb-*.log`.

| Check | Command | Result |
|---|---|---|
| Swift recording | `ARKDECK_RUST_LOADER_BINDING_RECORD=… run-swiftpm.sh test --jobs 2 --filter LoaderBindingOracleContractTests` | exit 0; 33 exchanges (`lb-swift-record.log`) |
| Swift verify | the same without the record variable, with `ARKDECK_CONTROL_FRAME_LOG`; then `--parallel --num-workers 2` | exit 0 both; byte for byte; 33 frames (`lb-swift-verify1.log`, `lb-swift-verify2.log`) |
| Frames | the 33 frames against the committed schema, jsonschema (validation venv) | 0 refusals |
| Corpus | committed lines kept, the three new shapes appended (`append-corpus.py`) | 2 → 5 lines |
| Schema derivation | `generate-control-contract.py --derive-method-schemas` over the corpus and the frames, as a check | only the sample counts differ; the committed schema kept |
| Contract | `generate-contract.py --write`, then `--check` | exit 0; 105 methods, 983 shapes |
| Swift schema contract | `ARKDECK_CONTROL_FRAME_LOG=<frames> run-swiftpm.sh test --filter 'ControlMethodSchemaContractTests\|LoaderBindingOracleContractTests'` | exit 0; 6 tests (`lb-swift-schema.log`) |
| Replay | `cargo test -p arkdeck-agentd --bin arkdeck-agentd loader_binding_control` | 3 passed: all 33 exchanges, answers and files; the owner absent; parameters refused or ignored by name (`lb-replay1.log`) |
| Jobs | `cargo test -p arkdeck-hoststore --test loader_binding_jobs` | 2 passed (`lb-jobs.log`) |
| App ingress, CLI | `cargo test -p arkdeck-agentd --bin arkdeck-agentd app_ingress`; `cargo test -p arkdeck-cli --test loader_binding --test argv_fixtures` | 34 and 6 passed (`lb-ingress.log`, `lb-cli.log`) |
| Mutations | ten, each against its own tests: the vendor in hexadecimal, ArkForge's port not compared, a retry's revision-1 selection not answered, a broken lineage thrown instead of uncovered, the binding written without its lock, a colliding Target advanced over, alias resolutions left behind, a reconciliation of the wrong revision taken, the selection digest's identities swapped, a Job awaiting the binding ignored | 10/10 caught; every source restored by digest (`lb-mutations.log`) |
| fmt, clippy | `cargo fmt --all --check`; `cargo clippy --locked -p arkdeck-contract -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`lb-r2-fmt.log`, `lb-r2-clippy.log`) |
| Crate tests | `cargo test --locked --no-fail-fast -p <crate>`, on `4b89780f` | exit 0 each: `arkdeck-contract` 52, `arkdeck-control` 29, `arkdeck-hoststore` 570, `arkdeck-agentd` 148, `arkdeck-cli` 252 (`lb-r2-test-<crate>.log`); the same on `c588ccd7` before the rebase |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv) | PASS on macOS; 135 control responses (134 before, and the binding's missing owner) (`lb-r2-readonly.log`) |
| CLI audit | `cli-parity-audit.py <this build's arkdeck>` | 162 implemented (161 before); 121 leaves served; the daemon routes 101 of 105 methods (`lb-r2-cli-audit.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0 (`lb-r2-sdd.log`) |

**CI.** Pending.

**#2152 (M4-2b), recorded here.**

- *Head `3c1aa4d3`, the third push.* Every check green: SDD Guard run
  36054888329; Swift CI run 36054888908, whose `swift` aggregate job and Rust
  lanes passed on ubuntu, macos-26 and windows. Merged as `c588ccd7`.
- *The first two pushes.* Red on macOS, each in a test's timing. Their
  diagnoses and fixes are in `arkforge-lane-daemon-run.md`.

No device, installed service, real `arkforged` or App was used, and nothing
here is device evidence.
