# The ArkForge lane's execution authority: StepPermits signed as Swift signs them (TASK-XPA-017, F6 S1)

This slice ports Swift's `ArkForgeExecutionAuthority` to
`arkdeck-provider-arkforge`. It is ArkDeck's half of the ArkForge split:
`arkforged` asks before each step, and this authority either signs a
`StepPermit` or refuses with a reason.

- Every admission is checked against facts the authority holds itself: the
  plan it approved, the binding it confirmed and its own clock.
- A permit is stored before it is returned, and a retransmitted admission
  replays those exact bytes.
- The permit is ArkForge's own `StepPermit`, tagged with the pairing secret
  through ArkForge's own authority API. That API's vectors are the ones
  Swift's lane mints (`permit_vectors.rs`).

Nothing calls the authority yet. The Flash session (S3) will. The ArkForge pin
stays at `eee5787`.

Base: protected `main` `952e28604`, which is S2 (#2251), whose `Cargo.toml` and
read-only table this extends. It was developed and checked stacked on S2's
head `c626d4c61`, which carries the same tree. No contract input, Catalog or
`tasks.md` changes. No device, and nothing here is
device evidence.

## What is ported (`authority.rs`)

- **`ApprovedPlan`, `AuthorityBinding` and the 60 s permit lifetime** are
  Swift's.
- **`admit` checks in Swift's order:**
  1. Retransmission first: an already-issued permit id is answered with its
     stored bytes, with no re-verification.
  2. The step and attempt identity.
  3. The job. This is the daemon's job once adopted, otherwise ArkDeck's.
  4. The plan id and digest.
  5. For a live admission, whose raw device facts are present:
     - the transport session digest is 32 bytes;
     - the descriptor is well formed;
     - the recomputed admission facts digest equals the one the daemon sent;
     - the observed topology is the one approved for the observed mode's
       canonical lineage.

     Without raw facts, which is the recorded v1 fixtures' branch, the
     admitted facts digest must equal the plan's.
  6. The snapshot is not from the future, and has not outlived its lifetime.
     The lifetime is inclusive.
- **`adopt_daemon_job`** takes the daemon's job once and never moves it.
- **`record_managed_control_facts` and `record_materialized_observation_mode`**
  extend the approved mode→topology lineage, as Swift's do.
- **`canonical_mode`** folds the spellings into one lineage key:
  `normal`/`hdc-normal`, `loader`/`updater`/`rockusb-loader`, and
  `maskrom`/`rockusb-maskrom`. Anything else is kept trimmed.
- **Swift's refusal texts** are used word for word.
- **`device_facts_digest`** is SHA-256 of the domain and the canonical CBOR of
  the raw facts map, in Swift's shape. It is encoded with `arkdeck-contract`'s
  canonical CBOR, which the permit vectors already tie to Swift's encoder.

### Kept as Swift has it, pending a ruling

The two ArkForge digest domains stay as Swift spells them, as the coordinating
session asked on 2026-09-26 until the maintainer rules: `arkforge/v1/device-facts\0`. That covers the
topology digest (`loader.rs`) and the admission facts digest. ArkForge has
spelled both differently since `e437402` (F1/F2, reported for the maintainer's
ruling). A test pins that the map encodes exactly as ArkForge's own canonical
CBOR encodes it, so a ruling changes only the domain prefix.

### One declared difference: an unsignable admission is refused

Swift signs whatever strings and byte lengths an admission carries, and leaves
the rejection to the daemon's typed decoding. ArkForge's Rust `StepPermit`
cannot hold a malformed value, so this authority refuses before anything is
signed. The daemon then cancels safely. The refusal is
`Unsignable("<field>: …")`, whose text reads "the admission's identities
cannot form a permit (…); nothing was signed". The cases are:

- an identifier that ArkForge's typed ids refuse: empty, longer than 128
  bytes, or outside `[A-Za-z0-9._:-]`;
- a digest that is not 32 bytes.

A daemon never sends either; both come from its own typed values.

### Dependency edges

`arkdeck-provider-arkforge` now depends directly on two more ArkForge crates:
`arkforge-authority-api` for the `StepPermit` and its tag, and `arkforge-core`
for the typed ids and digests the permit is made of. `check-readonly.py`'s
ArkForge table records each with its purpose. It also records the boundary the
coordinating session set: ArkForge's protocol and pure crates only, never its
mechanics (transport, platform, the daemon). Both crates were already locked
and allowed, so `deny.toml` and cargo-vet need no change.

## Tests (`authority/tests.rs`)

- **All 15 of `ArkForgeExecutionAuthorityContractTests`,** case for case.
  - The happy path.
  - The Loader lineage learned from a control receipt, and seeded from the
    materialized mode.
  - Single use and the time bound, with Swift's byte check that `singleUse`
    is followed by CBOR `true`.
  - The seven refusals and the no-permit-on-refusal ledger.
  - Replay across moved time and past expiry.
  - A new attempt as a new permit.
  - The epoch beside the bytes.
- **Beyond Swift:**
  - A live admission is recomputed rather than believed: a wrong facts digest,
    a short session digest or a malformed descriptor is refused.
  - The daemon's job is adopted once and bound into the permit.
  - **ArkForge's own `verify_permit`**, the daemon's check, accepts the
    permit for the dispatch it was asked about, and refuses it under another
    secret.
  - The admission facts encode exactly as ArkForge's canonical CBOR encodes
    the daemon's own map, with serial evidence present and absent.
  - The canonical mode table.
  - The unsignable refusal.

## Mutations

`s1-mutations.py` applied each mutation to the tree, ran the authority's
tests, restored the source and checked it against its digest. The restored
tree exited 0.

| mutation | caught by |
|---|---|
| a retransmission derived again | the two replay cases |
| the plan digest not compared | the plan case and the ledger case |
| the admission facts believed | the recomputation case |
| the lineage not checked | both Loader lineage cases |
| the lifetime made exclusive | the expiry case, at its boundary |
| a future snapshot taken as fresh | the future-clock case |
| `loader` not in the Loader lineage | the recomputation, receipt-lineage and canonical-mode cases |
| the daemon's job adopted twice | the adoption case |
| a permit usable twice | the single-use case and ArkForge's `verify_permit` |

## Verification

**Local targeted checks.** Main worktree, target
`/private/tmp/arkdeck-m4-rust-target` (`-win` and `-linux` for the cross
checks), `CARGO_BUILD_JOBS=2`. Logs are under the session's scratchpad
`s1-logs/`.

| check | result |
|---|---|
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --all-targets -- -D warnings`, host: `arkdeck-provider-arkforge` and its dependents `-hoststore`, `-agentd`, `-cli`, `-soak` | exit 0 |
| the same for Windows and Linux: `arkdeck-provider-arkforge` | exit 0 each |
| `cargo test -p arkdeck-provider-arkforge` | exit 0: 51 unit tests (21 new), the lane, device access and permit vector binaries |
| `rust/scripts/check-readonly.py --bin-dir <target>/debug` (validation venv), after `cargo build -p arkdeck-cli -p arkdeck-agentd` | exit 0 |
| `cargo deny --locked check`, `cargo vet --locked --no-registry-suggestions` | exit 0 each |
| the nine mutations | each caught as above; the restored tree exit 0 (`mutations.log`) |
| `sh scripts/check-sdd.sh` | exit 0 |

Not run:

- Tests of the dependents: nothing of theirs changed or calls the new
  module. Their clippy above compiles them.
- Swift: nothing of it changed.
- `generate-contract.py --check`: no contract input changed.

**CI.** Pending.
