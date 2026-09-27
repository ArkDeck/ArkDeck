# TASK-XPA-018 — DevEco maintenance and uncertain signing publication

The Rust CLI serves `runtime signing migrate-deveco` and legacy `signing
migrate-deveco`. It validates the canonical installed daemon before opening
maintenance Keychain access, authenticates the profile's keystore against the
installed receipt, and decodes using that source's adjacent DevEco material.
The owner revalidates the exact receipt authenticated by the CLI after taking
its lock and before any ledger/secret mutation; a concurrently replaced
credential is refused as identity drift. A deterministic A-authenticated,
B-installed, A-migration fixture checks B receipt/ledger/secret byte stability.
The owner refuses pinned credentials. Rekeying preserves installation time and
file identities; alias changes produce the corresponding new credential ref.

An existing envelope requires its old value to be readable before replacement.
The receipt remains byte-identical when alias/fingerprint need no change.
Missing envelopes get a new account; old accounts remain tracked for removal.
Twelve actual Swift pre-Keychain refusals replay byte-for-byte across both
spellings and three output modes. Success/failure transactions use injected
secret storage only, never the login or Data Protection Keychain.

## Independent review correction to installation

Review of local install commit `4721cc348fdd42cda6003be0efbbdd3d374b7b8f`
found a material difference from Swift's write API: Rust publication distinguishes
`BeforePublication` from `OutcomeUnknown`, including rename errors and directory
sync errors after rename. Restoring an old secret after unknown publication can
pair a new receipt with the wrong password; deleting a new account can remove
the only envelope a visible receipt names. The prior install run's unconditional
rollback description is superseded by this correction.

Both installation and DevEco replacement now preserve that distinction:

- `replacingSecrets` is durable before any secret write. The ledger also
  durably tracks fixed-scope pending envelope account names before writes, so
  even a new account whose receipt never lands can be explicitly removed.
- `OutcomeUnknown` retains the secret and guarded ledger. Neither current,
  resolve nor a restarted owner adopts a public receipt as proof of consistency.
- Publication-before errors can settle only after secret restoration succeeds
  and the old receipt bytes (or prior absence) are proved unchanged. A failed
  rollback or unreadable/mismatched receipt keeps the guard.
- An explicit Rust install/rekey can repair the guarded state with supplied
  material; pending accounts move into superseded receipt tracking. Explicit
  removal cleans pending accounts, retaining `removingSecrets` until complete.
  Existing ledger validation and active preset pins still apply.
- A reused envelope is read successfully before initial installation may
  overwrite it; an unreadable value is no longer silently treated as absence.

These are private maintenance states under the existing ledger schema. Current
Swift rejects their unknown state before current/resolve/replacement, which is
intentional fail-closed compatibility. Recovery from such an interrupted Rust
transaction requires these Rust maintenance commands; do not delete the ledger
or fall back to Swift to force adoption. Successful transactions still write the
original stable schema with no pending fields. Maintainer review remains required;
this record does not approve a cutover or certify device/Keychain acceptance.

## Local targeted checks

Corrected code head: `87f2b6d9480a3ca543316a8938fca7a5d2bc0c7e`.
`CARGO_TARGET_DIR=/private/tmp/arkdeck-takeover-d79c-target`,
`CARGO_BUILD_JOBS=2` for every Rust command below.

- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-provider-workspace`:
  exit 0, 43 pass. Log:
  `/private/tmp/arkdeck-signing-migrate-fixed-provider-unsandboxed.log`.
  The initial sandbox attempt exited 101 at the existing fake HAP signer's
  disposable file-Keychain creation (`SecKeychainCreate`), after the new unit
  tests passed. That log is `/private/tmp/arkdeck-signing-migrate-fixed-provider.log`.
  A controlled rerun passed; the failure was not repaired by changing tests.
  Contrary to the escalation's initial shorthand about compiler-cache access,
  the actual observed refusal was file-Keychain creation. These fixtures never
  write login/Data Protection items or change the user's search list.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli --test argv_fixtures
  --test signing_install --test signing_remove --test signing_refresh
  --test signing_status`: exit 0, 27 pass, including the 12 new Swift migration
  refusal recordings. Log: `/private/tmp/arkdeck-signing-migrate-fixed-cli.log`.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-provider-workspace
  -p arkdeck-hoststore -p arkdeck-cli --all-targets -- -D warnings`: exit 0.
  Log: `/private/tmp/arkdeck-signing-migrate-fixed-clippy.log`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter
  OpenHarmonyLocalSigningContractTests/testRustSecretTransactionStatesCannotBeRecoveredBySwift`:
  exit 0, one actual XCTest pass, 0 failures. This uses Swift's existing owner
  implementation and injected secret fixture; both guarded states refuse
  current/resolve/restarted-owner/replacement and preserve ledger bytes.
  Log: `/private/tmp/arkdeck-signing-migrate-swift-compat.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`, `git diff --check`,
  `sh scripts/check-sdd.sh`: exit 0; SDD 121 acceptance IDs. Log:
  `/private/tmp/arkdeck-signing-migrate-sdd.log`.
- `python3 rust/scripts/generate-contract.py --check`: exit 0; 105 methods,
  1,043 shapes. Log: `/private/tmp/arkdeck-signing-migrate-contract.log`.
- Earlier migration-only three-crate baseline: exit 0, 1,184 pass / 18 ignored,
  `/private/tmp/arkdeck-signing-migrate-all-tests.log`. It predates the publication
  and concurrency corrections and is not evidence for those corrections.
  The corrected source's full hoststore/CLI suites were not rerun in this
  short coordinated window; their changed behavior is covered by provider and
  CLI signing tests, with all three crates' targets compiled by Clippy.

Two independent static reviews found the publication and concurrent-input P2s;
review of the corrected code head found neither remaining and no new blocker.
No full local unified gate, App build, performance capture or actual installed
Keychain/Runtime/device acceptance ran. Successful maintenance tests use fake
secret storage; the pre-existing signer tests use disposable file Keychains.
This is not `REAL_DEVICE_PASS`, GJ-5 or TASK-XPA-017 completion.

## CI

Not published: direct current-thread remote authorization is still pending
following automatic approval rejection. No delegated push or alternate path is
used. Existing local install and identity-refresh commits remain unpushed.
