# TASK-XPA-018 — DevEco maintenance and uncertain signing publication

The Rust CLI serves `runtime signing migrate-deveco` and legacy `signing
migrate-deveco`. It validates the canonical installed daemon before opening
maintenance Keychain access, authenticates the profile's keystore against the
installed receipt, and decodes using that source's adjacent DevEco material.
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

In progress: final corrected-source checks and Swift compatibility regression.
The earlier migration-only baseline is not evidence for the publication fix.
Log paths and exact exits will be recorded after completion. All successful
maintenance tests use temporary files and fake secret storage. No installed
Runtime, live credential, launchd service or device has changed.

## CI

Not published: direct current-thread remote authorization is still pending
following automatic approval rejection. No delegated push or alternate path is
used. Existing local install and identity-refresh commits remain unpushed.
