# TASK-XPA-018 — Explicit signing preset installation

`runtime signing install` and deprecated `signing install` now use the Rust
credential owner. This ports the published Swift maintenance leaf; no operation,
secret argv option, new Provider or Runtime authority is added.

## Behavior and failure boundaries

- The owner refuses active preset pins before replacement, writes `replacing`
  durably before any Keychain write, and publishes a stable credential reference
  only after revalidating the receipt, public files and envelope presence.
- The installer measures canonical, bounded signing files, requiring a private
  keystore and executable Java. Symlinks are refused rather than normalized into
  accepted input. The closed alias, algorithm, file extensions and managed-root
  constraints remain the Runtime's constraints.
- Both passwords enter through two bounded, no-echo terminal prompts, or the
  existing `--build-profile` path. The latter reads a bounded profile
  snapshot, requires exactly one matching ciphertext field and canonical
  storeFile, binds it to the requested keystore, then uses the existing DevEco
  decoder. Secret buffers are wiped; no password enters argv or result JSON.
- One envelope is reused only if its account and storage form match and the
  Keychain reports it present. Otherwise a fresh random account is used; old
  valid account names remain in superseded tracking for explicit removal.
- As Swift does, a failed Keychain or receipt write attempts to restore the old
  envelope, or removes the newly created item. The owner recovers only from the
  receipt that actually exists; an unreadable receipt leaves its durable marker
  and refuses current-credential resolution. No signing operation is dispatched.
- Runtime Keychain reads remain non-interactive. Only the explicit maintenance
  constructor enables Swift's interactive CLI read policy; service/access-group
  scope is unchanged. Native Keychain construction in refusal recordings does
  not read or write an item.

Maintenance tracking shares the tolerant decoder already used by removal.
Only account/material tracking is taken from it; admission and new installation
validate every new public identity with the strict Runtime validator. Unsafe or
unreadable old tracking files refuse replacement before secret writes, retaining
the conservative bounded-reader boundary introduced by #2270.

## Evidence limits

Successful installation tests inject an in-memory secret store over temporary
public files. They cover reuse, replacement, pins, material rejection, restoring
an old envelope after a failed write, publication failure, retained recovery
markers and explicit retry. CLI library tests exercise terminal/profile input
selection; a real pseudo-terminal checks echo restoration after successful,
empty and overlong input.

`rust/scripts/record-signing-install-oracle.py` records eighteen real Swift CLI
refusals: current/legacy spelling, human/JSON/raw JSON, and relative-path/no-TTY
cases, plus duplicate/odd-length/mismatched-keystore profile cases. Rust replays
stdout, stderr and exit byte-for-byte. All cases terminate
before any Keychain item access and leave the temporary home unchanged; HOME
is never treated as Keychain isolation. Provenance records the Swift binary
SHA-256. No installed helper, credential, launchd service or device was changed.

`install-sdk-release` and `migrate-deveco` remain unported. This is not GJ-5,
real Keychain acceptance or TASK-XPA-017 completion.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-takeover-d79c-target`,
`CARGO_BUILD_JOBS=2`.

- Initial changed/direct-dependent test command included platform,
  provider-workspace, hoststore, client, bootstrap, rockchip-binding,
  provider-hdc, soak, CLI, provider-arkforge and agentd. Agentd/bootstrap
  completed with 226 pass / 1 ignored before the new install argv fixture
  found a missing-required-option difference in the CLI. Log:
  `/private/tmp/arkdeck-signing-install-dependents-tests.log` (exit 101).
  The fix uses the existing registry validator and restricts new option
  spellings to their declared leaves; no fixture expectation was relaxed.
- After the fix, `cargo test --manifest-path rust/Cargo.toml` on the other
  nine listed crates completed exit 0: 1,662 pass / 22 ignored. Log:
  `/private/tmp/arkdeck-signing-install-remaining-tests.log`. The first two
  crates' passing tests were not needlessly repeated.
- Final provider test run after making envelope encoding keep its temporary
  Base64 bytes in wiped buffers: exit 0, 33 pass. Log:
  `/private/tmp/arkdeck-signing-install-final-provider.log`.
- Final `cargo test -p arkdeck-cli --test argv_fixtures --test signing_install
  --test signing_remove --test signing_refresh --test signing_status` (with
  the same manifest): exit 0, 25 pass including all 18 Swift refusal replays.
  Log: `/private/tmp/arkdeck-signing-install-final-cli.log`.
- Bootstrap doc tests: exit 0; `/private/tmp/arkdeck-signing-install-bootstrap-doc.log`.
- Final `cargo clippy` on all eleven changed/direct-dependent crates with
  `--all-targets -- -D warnings`: exit 0;
  `/private/tmp/arkdeck-signing-install-final-clippy.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`, `git diff --check`
  and `sh scripts/check-sdd.sh`: exit 0; SDD 121 acceptance IDs.
  Log: `/private/tmp/arkdeck-signing-install-sdd.log`.
- The new TTY tests passed on real private pseudo-terminals. Existing platform
  Keychain tests use disposable file-based fixture keychains; they verify the
  user's search list stays unchanged and never write login/Data Protection items.
- `python3 rust/scripts/generate-contract.py --check`: exit 0 (105 methods,
  1,043 shapes); `/private/tmp/arkdeck-signing-install-contract.log`.
- No full local unified gate, App build, performance capture or actual
  installed-service/Keychain acceptance was run.

## CI

Local implementation only. Remote publication awaits direct authorization in
this thread after automatic approval rejected the cross-thread authorization
record. No alternate push or delegated workaround is used. CI and maintainer
review still precede merge.
