# TASK-XPA-014 — the Rust capability store writes as Swift's does: install, consume and recordOutcome, replaying the four M2 oracles' stores byte for byte (macOS, 2026-09-15)

TASK-XPA-014 remains in progress. Base: protected main `438434ef`; no stack. This slice adds the
write side of the Rust `CapabilityStore`. Nothing in the daemon calls it yet, and every answer the
daemon gives is unchanged. The stores replayed here were written by Swift contract tests over the
shared fake HDC; nothing is device evidence (POL-VERIFY-001, POL-MODE-001).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M2 |
| --- | --- | --- |
| The capability reader (`capability.list`, `capability.inspect`) and its oracle; the four M2 oracles and the stores they leave; the Rust providers that replay their argv | The store's writes: install, `validateNewExecution` with `authorizes`, consume and first-time `recordOutcome`, over the checkpoint, the ledger and the hash chain, with the 128-event fold; two platform writes they need | Automatic issuance at submit (the capability's identity and envelope, lineage blocking across capabilities, `defaultPolicyIssuance`); `admissionDenied` at submit; consuming a use before the first mutation intent, and the Job's terminal outcome; the M2 operations' plans and runs; replay of the M2 oracles' exchanges |

## Why

Swift admits every M2 operation under a Runtime-issued capability: pointer input, port rules, the
debug HAP and the app-owned native library. It spends one use of that capability before the first
mutation and records the Job's outcome against it. The Rust owner could read Swift's capability
store but not write it. No Rust M2 admission could therefore issue a capability, or reserve or
settle a use. The writes are also where the store's safety lives: a use needs a named subject and a
complete plan, and no earlier use may be left unsettled. The scope must match the lineage's first
use, and the envelope itself must authorize the query.

## What changes

- **`CapabilityStore` writes as Swift `RuntimeCapabilityStore` does** (`capability_store.rs`). Every
  write loads the document as a read does, under the same blocking exclusive lock.
  - `install` appends a capability with its whole budget and writes the checkpoint atomically in
    Swift's `canonicalPretty` spelling. Only once that checkpoint is durable does it empty an
    existing ledger. Installing the same capability again writes nothing; a different one under an
    installed identity is `capabilityAlreadyInstalled`.
  - `validate_new_execution` checks, in Swift's order:
    1. a device subject (stable identity and binding revision) or a workspace one;
    2. a materialized plan digest;
    3. no earlier use left unsettled (`lineageBlocked`);
    4. the authorization scope of the lineage's first use, except under a workspace standing grant;
    5. `authorizes`, whose denials come in Swift's order with Swift's details.
  - `consume` reserves one use. It is linked to the tip of the use before it, and its receipt is
    digested as Swift digests it. A retry of the same reservation answers the stored receipt and
    writes nothing; a retry whose query or Job drifted is `reservationConflict`.
  - `record_outcome` settles a pending use for the Job that owns it. The same outcome again writes
    nothing. Swift refuses any other change of a recorded outcome, and so does this.
  - Each use and each outcome is one ledger event, compact canonical JSON and a newline, fully
    synchronized. Once 128 events follow the checkpoint, the next is folded into a new checkpoint
    instead.
  - The two fingerprints are Swift's: the authorization scope, and the query with its plan.
- **Settling an unknown outcome is not served.** It is recovery, and ADR-0009's decisions 2 and 4
  have not been placed (L.1 item 13). `record_outcome` refuses it as it refuses any other change,
  in Swift's words: `cannot change outcomeUnknown to confirmed`.
- **Public model.** `RuntimeCapability` (`from_value`, `authorizes`), `CapabilityQuery`,
  `ConsumptionReceipt`, `CapabilityDenial`, `WorkflowEffect` and `CapabilityUseOutcome`.
- **Two platform writes** (`arkdeck-platform`):
  - `HostDirectory::replace_document` is `publish_document` for a document that may be empty, which
    the emptied ledger is. `publish_document` still refuses an empty one.
  - `HostDirectory::append_synchronized` is Swift's ledger append: `O_APPEND`, created 0600 through
    no link, then fully synchronized, with no directory synchronization.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| The M2 oracles' stores | `cargo test --locked -p arkdeck-hoststore --test capability_write` | 4 tests pass. The pointer-input, port-forward, debug-hap and deploy-native-library stores take 66 writes: 13, 24, 18 and 11. The checkpoint and ledger are byte for byte Swift's, and the entries and their modes are the ones Swift left. The refusals, the denials and the 128-event fold pass over synthetic capabilities |
| The reader's oracle | `cargo test --locked -p arkdeck-hoststore --test capability_read` | Passes, unchanged |
| The whole crate | `cargo test --locked -p arkdeck-hoststore` | 250 tests pass and 10 are ignored, in 32 suites |
| The platform's host store | `cargo test --locked -p arkdeck-platform --lib host_store` | 20 tests pass, 1 ignored |
| Lints | `cargo clippy --locked -p arkdeck-hoststore -p arkdeck-platform --all-targets -- -D warnings` | Clean |
| Formatting | `cargo fmt --check -p arkdeck-hoststore -p arkdeck-platform` | Clean |
| Union-merged records | `python3 scripts/check_union_merge.py` | `check_union_merge: ok` |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, with `ARKDECK_PYTHON` naming `.venv-sdd` and the
planner run from a virtual environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `e7266aad` | `gate exit=0`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 797 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-m2-capability-store-writes-gate-20260915-a.log`, SHA-256 `80ced799ffc0f0ea99bad44c6811b2721421dea9d7d45c54f5015024db88e911` |

The amend after r1 only fills in this row.

## Not run, and why

- **The daemon's admission.** Issuance at submit, consumption before dispatch and the Job's
  terminal outcome are the next slices; nothing calls these writes yet.
- **Swift reading a store Rust wrote.** Each Rust store here is byte for byte the store Swift wrote
  for the same history, which is what Swift reads.
- No device, no real HDC.
