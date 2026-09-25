# The Swift Flash run oracle, and Flash admission refused before issuance on the Rust Runtime (TASK-XPA-017, M4-F0/F1)

No Swift oracle recorded a Flash `job.submit` or `job.run` before this
change. The Rust Runtime therefore had nothing to replay its Flash admission
and execution against. The ArkForge lane cannot be exercised with a real
`arkforged` without a device: the daemon always binds the native USB write
port, and a transcript replaces only discovery. So the oracle fakes the lane
at its trait, as Swift's own contract tests do
(`CompleteOverwriteRecoveryContractTests`).

| Already on `main` | This change | Still remaining (M4) |
|---|---|---|
| Flash `job.plan` and its oracle (#2158–#2162), the lane preview up to the lane (#2170), the Rockchip start-up and Loader binding (#2154/#2155) | The Swift oracle for every Flash story; on the Rust Runtime, Flash `job.submit` over the Flash composition up to capability issuance, every refusal replayed; the lane seam and its fakes | Issuance, the run, restart parking and reconcile (the next change); DEC-016 recovery with the contract fields it needs; the production lane, which waits for the ArkForge client change |

## The oracle

`FlashRunOracleContractTests` sends each request through the daemon's
control-plane handler (`RuntimeControlPlaneHandler`) as Swift composes it for
a Flash:

- the ArkForge provider with a scripted facts port;
- a scripted `RuntimeJobEngine.ArkForgeLane`: its archive prewarm, the
  daemon job it prepares, the one drive of that job, the terminal it
  observes and the completed plan it keeps;
- a scripted Rockchip dispatcher: the one host-managed action a delegated
  Flash still runs itself, the post-flash HiLog capture;
- the Artifact store, with its quota and redaction; the capability store
  inside the Job root; the Session writer.

Each exchange records the script the fakes answered with, the answer, and
the calls the lane and the dispatcher received, in Swift's own words. A
`<restart>` exchange drops the composition and composes the daemon again
over the same root, recovering its active Jobs as the daemon does before it
serves. The lane's completed-plan cache is its own, so a restart loses it.

Every story starts from the same root (`/private/tmp/arkdeck-flash-run-oracle`,
serialized with the Rust replay by one `flock`):

- the Artifact root and Target store the Flash `job.plan` oracle left after
  importing its bundle, laid down as recorded (`inputs/`);
- empty Job, Session and Session owner roots.

What a story leaves is recorded after its last exchange:

- the Job index as a reader observes it;
- every entry's kind and mode;
- every regular file's bytes, each Job record's machine facts labelled.

Three things vary from run to run, and are labelled rather than recorded:

- the timeline line that measures how long the run waited for the prewarm
  (`consume wait <ms> ms`);
- a payload's verification cache, which pins its inode (kind and mode only);
- the Artifact pager's snapshots, named by a random revision
  (`snapshot-<revision>.json`, kind and mode only).

The eight stories, 118 exchanges:

| Story | Exchanges | What it holds |
| --- | --- | --- |
| `admission` | 11 | The plan, then every refusal before issuance: a caller-supplied capability, a reviewed digest that differs and one that is malformed, an unprepared cross-mode binding, no post-flash alias, a stale revision, a short alias partition plan, the alias's retired `@1`, a lease bound to another Target; nothing issued |
| `canonical` | 19 | Two Flashes of the canonical operation: reviewed, deduplicated, run twice (the second refused), read (status, result, evidence, Artifacts); the second with an imported prewarm and a failed HiLog capture |
| `alias` | 7 | The compatibility alias with basic verification, whose diagnostics are not selected |
| `failures` | 33 | One Job each: the prewarm refused, or answered for another archive, before consumption; the daemon job refused, not created, or bound to another attempt; the plan confirmed failed or confirmed not executed; and a completion receipt that fails canonical validation |
| `reconcile` | 21 | A lost controller; restart; passive reconciliation of the exact daemon job (no terminal, then the completed plan) and the run resumed from that proof; a daemon job cancelled safely; an unreachable daemon, then a failure without proof |
| `recovery` | 13 | DEC-016: an unknown Flash, a basic request refused, a full one admitted and run as the distinct recovery, its epoch established; the same ordinary request after it |
| `recoveryAlias` | 6 | The alias asked for the complete overwrite after an unknown canonical Flash |
| `cancel` | 8 | A Flash cancelled before it runs, then the next one under the same unspent capability |

Every way Swift proves a delegated Flash did not execute has its exchange,
since each one fails the Job and, once the capability was consumed, settles
its use safe to reflash: the daemon job not created, bound to another
attempt, or confirmed not executed by its drive (`failures`), and the daemon
job cancelled safely (`reconcile`). Before consumption, the prewarm refused
or answered for another archive fails the Job and settles no use.

Two Swift behaviours are recorded as Swift answers them:

- After the recovery epoch, the same ordinary request is refused
  (`lineageBlocked`). The ordinary policy's last generation still holds the
  unknown use, the generation walk returns it, and new execution is denied.
  Reported to the hub for the maintainer.
- Eight answers do not conform to the published schemas, and this Runtime's
  Control would answer each as `internalError` "the result does not conform
  to the current contract":
  - `job.submit` for the short alias partition plan answers `internalError`
    with empty details, where `errorDetails` requires `phase` and
    `newDispatchCount`. Every post-admission internal failure has this shape;
    this oracle is the first to record one.
  - Seven answers of the recovery stories carry the epoch fields the schemas
    pin to `null`: `recoveryEpochId` and `supersededByRecoveryEpochId` in the
    Job status, and `recoveryEpoch` in the evidence.

  Widening those schemas is a contract-input change, which goes with the
  DEC-016 slice.

## The Rust Runtime

`FlashAdmitter` (`flash_admission.rs`) admits a Flash request over the Flash
composition in Swift's order, and every other request through the admitter
as before:

1. the typed request, its catalog operation and inputs;
2. idempotency, before anything is materialized;
3. the Target binding's provably settled capability outcomes repaired;
4. the Import holds, then the complete plan materialized as `job.plan`
   materializes it; a fresh digest that differs from a reviewed one is
   refused;
5. `preauthorize`: the Job state, another client's device session, the
   catalog's Runtime-owned policy, the provider's execution blocker, the
   stable identity and binding, then — reading the superseding recovery
   epochs under their lock, as Swift's complete-overwrite admission does —
   a capability a caller named.

A request that passes them all is refused as well, before any capability is
issued: the Runtime's one-use destructive capability and DEC-016 belong to
the slice that runs a Flash, and a Flash is admitted only together with the
run that consumes it. Nothing is written to the Job index, and nothing is
issued, reserved or dispatched.

The lane seam (`arkdeck-provider-arkforge` `flash_lane.rs`) is Swift's
`ArkForgeLane` as a trait, with the receipt validation the Runtime applies
(`canonical_facts_digest`, `validate_completion`). Its fakes
(`tests/support/flash_lane.rs`) answer as the oracle's script says and log
what they were asked in the oracle's own words.

The replay (`tests/flash_run.rs`) lays the same root down, composes the
owners the daemon composes, sends each exchange while the fakes answer as
recorded, and compares every answer, both call logs, the Job index, the
tree and every file.

## Declared differences

- **What either daemon leaves that no story made**, left out of the tree
  and file comparison only where that daemon alone has it:
  - Swift's engine creates the Job directory when it starts.
  - Every Swift status read opens a Target store below the state root, which
    creates `store/targets/` and its display-name files
    (`recoveryEpochIndexes`).
  - Swift's Artifact reads create a Job's empty Artifact directory and write
    a payload's verification cache.
  - This Runtime's owners each keep a lock, and its Session owner writes the
    empty retention catalog when it opens (Swift writes it at its first
    publication).
  - The Artifact pagers keep their snapshots in different roots: Swift's in
    the Artifact root, this Runtime's in the Job root. The replay checks that
    both kept as many.
- **The short alias partition plan's refusal** is Swift's at the handler.
  The Control answers it as a contract failure until the schema admits empty
  details (above).

## Tests

| Test | What it holds |
| --- | --- |
| `flash_run.rs` `the_oracle_records_every_story` | The provenance names the eight stories, and each has its cases |
| `flash_run.rs` `every_admission_refusal_is_swifts` | The admission story byte for byte: 11 answers, both call logs (empty), the Job index, the tree and the files |
| `flash_lane.rs` (provider) `the_facts_digest_is_swifts`, `only_a_canonical_postflight_receipt_completes_a_plan` | The receipt digest and validation as Swift's |
| agentd `flash_plan_control` | A daemon without a lane still answers a Flash submit before admission, and makes no Job directory |

## Local targeted checks

Run on this branch, whose tree is `main` `3315a9cba` plus this change. Logs
are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| Swift oracle, recorded | `ARKDECK_RUST_FLASH_RUN_RECORD=<fresh> run-swiftpm.sh test --filter FlashRunOracleContractTests` | exit 0, the test 6.3 s (`arkdeck-m4-pr1-swift-record.log`). An earlier recording (110 exchanges) could not be replayed: the Artifact pager's snapshots are named by a random revision, now labelled (`…-swift-compare-first.log`); two failure cases were added before this one |
| Swift oracle, replayed | the same without the record variable | exit 0, 4.8 s (`arkdeck-m4-pr1-swift-compare.log`) |
| Rust replay | `cargo test -p arkdeck-hoststore --test flash_run` | 2 passed |
| fmt | `cargo fmt --all --check` | exit 0 (`arkdeck-m4-pr1-fmt.log`) |
| clippy | `cargo clippy -p <crate> --all-targets -- -D warnings` for `arkdeck-provider-arkforge`, `arkdeck-hoststore`, `arkdeck-agentd`, `arkdeck-soak`; the four again for `x86_64-pc-windows-msvc` and `x86_64-unknown-linux-gnu` | exit 0 each (`arkdeck-m4-pr1-clippy-<crate>.log`, `…-clippy-{windows,linux}.log`) |
| Crate tests | `cargo test --no-fail-fast -p <crate>` for the same four | provider-arkforge 21, hoststore 627, soak 4 passed. agentd: three process tests could not find the CLI beside the daemon in the fresh target directory; after `cargo build -p arkdeck-cli`, 178 passed (`arkdeck-m4-pr1-test-<crate>.log`, `…-test-arkdeck-agentd-rerun.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0 (`arkdeck-m4-pr1-sdd.log`) |

No contract input changed, so `generate-contract.py --check` is not
required.

## CI

- This change: pending.

Host-process evidence only:

- The ArkForge lane and the Rockchip dispatcher are scripted; no `arkforged`
  runs.
- No device was used, and no installed service was touched.
