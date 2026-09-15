# TASK-XPA-014 — a device Import is bound to the identity its Target's connect key names, lowercased as Swift and the Target's device facts hash it (macOS, 2026-09-15)

TASK-XPA-014 remains in progress. Base: protected main `0be358d9`; no stack. The Import uploads
(TASK-XPA-013, #1881) bind a `hap` or `native-library` Import to the Target it is uploaded for.
This slice corrects the identity that binding names. The Import chain's lease slice needs it
(`artifact.import.commit`, then Import leases in plan, submit and run). It ships on its own
because the binding is wrong today, whatever that chain does. None of it is device evidence
(POL-VERIFY-001, POL-MODE-001).

## Why

- **Swift** binds a `hap` or `native-library` Import to the identity its execution route's connect
  key names: `HDCObservationProviderAdapter.stableIdentitySHA256(connectKey:)`
  (`RuntimeImportControlHandler.swift`), the SHA-256 of the key lowercased.
- **The Rust Target owner** hashed the key as written (`resolve_import_binding`).
- **The Target's device facts**, and so every Job's plan, name the lowercased digest
  (`arkdeck_provider_hdc::stable_identity_sha256`).

For a connect key with capitals, as a device serial may have, the two digests differ. An imported
Artifact would then name an identity no plan binds, and every Job given it would be refused:
`Artifact lease target/binding/identity does not match the materialized request`. For an
all-lowercase key they agree, which is why no oracle has shown it.

## What changes

- **The binding** (`target_owner.rs`): a `hap` or `native-library` Import's
  `stableIdentitySHA256` is the provider's `stable_identity_sha256` of the adopted connect key:
  the digest of the key lowercased. A `flash-bundle` Import keeps the Target's physical identity,
  and a `workspace-patch` Import names no identity, as before.
- **The tests** (`tests/import_target.rs`): a Target adopted with its connect key in capitals binds
  both kinds to the lowercased key's identity. The existing test of every kind spells its
  expectation the same way.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| The Import bindings | `cargo test --locked -p arkdeck-hoststore --test import_target` | 5 tests pass. A capitalized connect key binds a `hap` and a `native-library` Import to the lowercased key's digest, and the other kinds keep theirs |
| The whole crate | `cargo test --locked -p arkdeck-hoststore` | 256 tests pass and 10 are ignored, in 33 suites |
| Lints | `cargo clippy --locked --workspace --all-targets -- -D warnings` | Clean |
| Formatting | `cargo fmt --all --check` | Clean |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local`, with `ARKDECK_PYTHON` naming `.venv-sdd` and the
planner run from a virtual environment carrying PyYAML 6.0.3 and jsonschema 4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `b3063809` | `gate exit=0`: the common checks and SDD, the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 803 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-import-binding-identity-gate-20260915-a.log`, SHA-256 `35163bd7808026d1fabf86fab5e3ea0bc6defbf18e728ee4c1c1a8c0d802aeeb` |

The amend after r1 only fills in this row.

## Not run, and why

- **The Import chain itself** is still to come: `artifact.import.commit`, inspection, release, and
  Import leases in plan, submit and run. It waits for its Swift oracle.
- **An alias Target** is unchanged. A `hap` or `native-library` Import through a proven alias still
  needs the live alias route owner. The alias proof itself hashes the alias's connect key as
  written, in Swift (`DeviceBootstrap.swift`) and in the Rust document check alike.
- No device, no real HDC.
