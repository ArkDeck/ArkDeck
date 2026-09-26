# TASK-XPA-018 — Explicit signing removal on the Rust CLI

`runtime signing remove` and the deprecated `signing remove` spelling now reach
Rust's existing credential owner. The leaf was in the published registry but
unimplemented in the Rust parser. This ports Swift's maintenance behavior; it
adds no operation, Provider, transport, capability or secret input.

## Behavior and failure boundaries

- Removal holds the same owner lock as workspace preset registration. It
  validates the owner ledger independently of the receipt and refuses any
  active preset reference or invalid mutation record before deleting anything.
- A durable `removing` marker precedes the first Keychain deletion. The fixed
  keystore/key accounts, current envelope and superseded envelopes are removed
  from both current Data Protection and legacy scopes. A successful deletion in
  one scope never short-circuits the other. Secret values are never read.
- The receipt and its directly contained managed material are removed; private
  user source keystore/certificate/profile files are preserved. An escaped
  managed path refuses before the secret-removal calls.
- Extra receipt keys are ignored only by the explicit cleanup decoder, as Swift's
  uninstall decoder ignores them; Runtime admission keeps its strict decoder.
  The receipt is read through the bounded, descriptor-relative private-store
  reader. If the tracking file is unsafe/unreadable, removal refuses before
  deleting secrets rather than unlinking the only record of their account names.
- A malformed JSON receipt remains explicitly uninstallable. Failed deletion adopts
  only a receipt the existing recovery reader can validate; otherwise the
  durable `removing` record stays for a later explicit retry.
- The success document matches Swift's `arkdeck.signing-credential-removal/1`.
  Swift's generic `SigningError` catch remains plain stderr with exit 1, including
  when JSON success rendering was selected. Existing `status` behavior is kept.

The internal removal interface is separate from Runtime `SigningSecrets`.
Actual deletion is reachable through the explicit maintenance CLI only. Tests
inject recording removers; the real CLI process tests use pinned credentials
that refuse before any Keychain deletion. No installed credential or service
was changed during development.

This does not complete signing cutover: install, install-sdk-release,
migrate-deveco and update-time daemon identity refresh remain unported. The
existing service-update refusal for installed signing presets remains in force.
Removing a user's preset is not an automatic workaround for that gate.

## Local targeted checks

Worktree-private `CARGO_TARGET_DIR=/private/tmp/arkdeck-takeover-d79c-target`,
`CARGO_BUILD_JOBS=2`.

- Initial targeted `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli
  --test signing_remove --test signing_status`: exit 0 (six new tests plus the
  existing seven-case Swift status replay); `/private/tmp/arkdeck-signing-remove-tests.log`.
  An additional absent-preset/intent-ordering case is covered by the full check below.
- Changed crates and direct dependents: `cargo test --manifest-path rust/Cargo.toml
  -p arkdeck-provider-workspace -p arkdeck-hoststore -p arkdeck-cli`: exit 0,
  1,156 pass / 18 ignored; `/private/tmp/arkdeck-signing-remove-all-tests.log`.
- After refining the bounded receipt reader and adding the actual Swift refusal
  fixtures, the affected signing tests were rerun: exit 0, eight removal tests
  and one status replay test; `/private/tmp/arkdeck-signing-remove-final-tests.log`.
- Swift CLI: `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh build --product arkdeck`,
  exit 0; `/private/tmp/arkdeck-signing-remove-swift-build.log`. Then
  `python3 rust/scripts/record-signing-remove-oracle.py --swift-cli
  <shared-cache>/build/out/Products/Debug/arkdeck --out <new-temporary-directory>`:
  exit 0. The six human/JSON/legacy-JSON refusal cases in
  `rust/tests/fixtures/signing-remove/` replay byte-for-byte through Rust; their
  provenance records the measured Swift binary digest. Every recording refuses
  on its owner pin before any Keychain deletion; no success case uses a real Keychain.
- Final Clippy over the same three crates with `--all-targets -- -D warnings`:
  exit 0; `/private/tmp/arkdeck-signing-remove-clippy.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`, `git diff --check`
  and `sh scripts/check-sdd.sh`: exit 0. SDD: 121 acceptance IDs;
  `/private/tmp/arkdeck-signing-remove-sdd.log`.

## CI

PR and run pending publication. Required CI and maintainer review precede merge;
this fixture evidence is not GJ-5 or installed Keychain acceptance.
