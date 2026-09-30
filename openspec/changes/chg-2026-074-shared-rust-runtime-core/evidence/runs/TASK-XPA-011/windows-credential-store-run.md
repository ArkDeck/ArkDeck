# TASK-XPA-011 — Windows credential store and console secret entry, 2026-09-30

- Task: TASK-XPA-011 prerequisite, WM3 slice C1: gate-inventory group G13 ("Credential storage
  and secret entry", `../TASK-XPA-004/windows-gate-inventory-20260930.md`), the platform layer
  only.
- Base: protected `main` (developed on `544cc934`, rebased onto the current `origin/main` before
  push; every check below was rerun on the rebased head `84a44be1`).
- Host: the Windows 11 x64 reference host (Windows 11 Pro 10.0.26200), rustc/cargo 1.98.1,
  non-elevated. Nothing was installed, elevated or reconfigured. The only credentials written
  were the tests' own, under a per-run fixture namespace; every one was deleted by the test that
  wrote it, and `cmdkey /list` showed no `ArkDeck` credential after the runs.

This is host evidence for a Rust port. It is not GJ-5 and not Windows platform acceptance:
no signing leaf is composed on Windows (see "What stays gated").

## What changed

| Area | macOS (unchanged) | Windows (new) |
| --- | --- | --- |
| Credential store | `keychain.rs`: `SecItem*` generic passwords in the Data Protection Keychain, access group `DAEMON_KEYCHAIN_ACCESS_GROUP`, non-interactive `LAContext` | `src/windows/credential.rs`: one `CRED_TYPE_GENERIC` credential per item through `CredWriteW` / `CredReadW` / `CredDeleteW`; the blob is DPAPI-protected by Credential Manager under the user's logon key |
| Public surface | `KeychainItems` (`data_protection`, `data_protection_for_maintenance`, `outside_data_protection`, `file_keychain`, `set`, `read`, `presence`, `contains`, `remove`), `KeychainError`, `KeychainPresence`, `DAEMON_KEYCHAIN_ACCESS_GROUP` | the same names and signatures; `file_keychain` (a macOS keychain file) is replaced by the fixture scope `fixture_namespace(service, namespace)`; added `target_name(account)` and `CREDENTIAL_NOT_FOUND` |
| Secret entry | `terminal_secret.rs`: `read_terminal_secret` with `tcsetattr` echo off | `src/windows/console_secret.rs`: the same function, `TerminalSecretError`, messages, exit codes and 1024-byte bound, over `GetConsoleMode` / `SetConsoleMode` / `ReadConsoleW` |
| `lib.rs` | — | `#[cfg(windows)]` re-exports of the above; `windows-sys` feature `Win32_Security_Credentials` |

`trusted_daemon_fingerprint` stays macOS-only (see below). The macOS sources and their gates are
untouched; no `cfg(target_os = "macos")` gate was removed, because every one still guards a
macOS-only implementation (the macOS `keychain.rs` and `terminal_secret.rs` remain the macOS
implementations; Windows gets its own modules beside them).

## Decisions (proposals for the maintainer's review)

1. **Persistence `CRED_PERSIST_LOCAL_MACHINE`.** Credential Manager credentials always belong to
   one Windows user; the persist value only chooses lifetime and roaming. `LOCAL_MACHINE`
   survives logoff and does not roam to other computers with a roaming profile —
   the counterpart of `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. `ENTERPRISE` would
   roam the signing passwords to every computer of a domain profile; `SESSION` would lose them
   at logoff. A read refuses a credential persisted any other way, since ArkDeck never writes one.
2. **Target name = the macOS item identity.** Credential Manager keys a generic credential by
   its target name alone, so the macOS triple (access group, service, account) becomes
   `ArkDeck/<access group>/<service>/<account>`, e.g.
   `ArkDeck/8AQTYW5FKR.com.arkdeck.shared/dev.arkdeck.openharmony-local-signing/<preset>|secret-envelope-<id>`.
   The access group and service may not contain `/`, so the name has one parse; the account is
   also written as the credential's user name and every read compares it, so a credential at the
   same target written for another account is refused. `DAEMON_KEYCHAIN_ACCESS_GROUP` is
   exported on Windows with the macOS value so both platforms name one item alike.
3. **Not found.** An absent credential is `KeychainError::Status(ERROR_NOT_FOUND)` (1168, exported
   as `CREDENTIAL_NOT_FOUND`) from `read`, `KeychainPresence::Absent` from `presence` and
   `Ok(false)` from `remove` — the same variants macOS answers for `errSecItemNotFound`; every
   other failure is `Status(<Win32 error>)` or `Refused(<fixed text>)`, never a value.
4. **Presence reads the blob.** Credential Manager has no attribute-only query (`CredReadW` and
   `CredEnumerateW` both return the decrypted blob). `presence` therefore reads but never copies
   the blob, and overwrites it in the API's own buffer before `CredFree`; `read` copies it once
   into a `Secret` and wipes the API buffer the same way. WM3's console challenge remains the
   interactive existence check above this layer.
5. **Value bound 2560 bytes.** `CRED_MAX_CREDENTIAL_BLOB_SIZE` is 2560; a larger value is refused
   before any call (macOS: 64 KiB). The signing envelope (about 100 bytes of JSON around two
   base64 passwords, each `/` escaped) always fits two passwords of up to 450 bytes each, and
   typically up to about 900; two passwords near the 1024-byte entry bound would not, and
   installation then fails with "value is empty or unbounded" rather than splitting the envelope
   across credentials. Recorded as the one semantic difference.
6. **No interaction on read.** `CredReadW` never prompts, so the Runtime policy "never ask the
   user" holds by construction; `data_protection_for_maintenance` keeps its flag for parity.
7. **Legacy scope.** `outside_data_protection` exists on macOS only to delete what an earlier
   build left outside the Data Protection Keychain. No Windows build ever wrote such an item, so
   on Windows it makes no OS call: presence `Absent`, removal `Ok(false)`, `set`/`read` refused as
   on macOS.
8. **Console entry.** Standard input must be a console input buffer (`GetConsoleMode` succeeds),
   else exit code 64 "signing passwords require an interactive TTY" before any prompt, as macOS
   refuses without a TTY. The reader clears `ENABLE_ECHO_INPUT` **and** `ENABLE_LINE_INPUT`
   (echo cannot be off in line mode without the line going through conhost's cooked read, and
   raw input keeps the line out of the console's command history), reads UTF-16 with
   `ReadConsoleW` and converts to UTF-8 into a fixed wiped buffer; Backspace erases one
   character, as the macOS canonical line discipline does. The prompt is written after echo is
   off (macOS writes it before), so it marks the moment input is hidden. A refused entry
   (control character, unpaired surrogate, more than 1024 bytes) is read to its Enter before the
   error returns, so the rest of the typed text never reaches the shell.
9. **Ctrl-C.** A console control handler registered for the entry restores the original mode on
   Ctrl-C, Ctrl-Break, close, logoff and shutdown, then returns `FALSE` so the default handler
   still ends the process; if the process survives the event, the entry ends as interrupted
   (exit code 1) and nothing read is used. Every ordinary return restores the mode through a
   guard. One entry at a time per process (a second concurrent entry is refused).

## Tests (Windows)

| Target | What it proves |
| --- | --- |
| `src/windows/credential.rs` unit tests | target name = macOS identity; `/`, empty, NUL and over-long names refused; account longer than a credential user name refused; legacy scope makes no call; only maintenance sets the interaction flag |
| `src/windows/console_secret.rs` unit tests | redirected (`NUL`), null and invalid stdin refused with 64 and no prompt; Backspace erases one whole UTF-8 character and wipes it; the bound counts UTF-8 bytes |
| `tests/windows_credential_store.rs` (real Credential Manager) | round trip, replacement, absent → `Status(1168)`/`Absent`/`Ok(false)`, remove twice; 2560-byte value round-trips, 2561 and empty refused without touching the stored value; invalid names refused; a credential at the exact target with another user name, or `CRED_PERSIST_SESSION`, is refused by `read` and `Unreadable(0)` by `presence`; `Secret` Debug and every error text carry no value. Each test uses `ArkDeck-fixture/test-<pid>-<random>/…` and a drop guard deletes every target it registered on every path |
| `tests/windows_console_secret.rs` (`harness = false`, ConPTY) | the test binary runs itself as a child on a pseudo console (`CreatePseudoConsole`), the parent types into the console input pipe once the prompt is rendered and reads everything the console renders: plain, non-ASCII with a surrogate pair, Backspace/DEL erasing, empty (64), 1025 bytes (64), a control character (64), Ctrl-C (the child's own handler, registered first and so run after the reader's, sees the original mode restored and exits 70). The child checks it received exactly the typed secret and that the console mode after the entry equals the mode before; the parent checks no typed text was rendered |

Negative controls, run once and reverted: with the reader leaving the mode unchanged (echo on),
six of seven console cases fail with the typed text rendered; with the control handler not
restoring the mode, the Ctrl-C case fails with exit 71. No test uses a sleep for
synchronisation: the parent waits on a condition variable fed by the console output reader,
bounded by a 60-second deadline.

## Checks

Run from `rust/` with `CARGO_TARGET_DIR=D:/cargo-target/c1-cred CARGO_BUILD_JOBS=2`:

| Command | Result |
| --- | --- |
| `cargo fmt --all --check` | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | clean |
| `cargo test -p arkdeck-platform` | pass (lib 63 passed and 1 ignored, incl. 7 new; `windows_credential_store` 5; `windows_console_secret` 7; every other target unchanged) |
| `sh scripts/check-sdd.sh` (`PYTHONUTF8=1`) | pass |
| `git diff --check` | clean |

No consumer crate was changed, so no other crate's tests were rerun beyond the workspace clippy.

## What stays gated

The signing leaves stay `cfg(target_os = "macos")`; the credential store and console entry
were the G13 platform prerequisites, and the leaves need more than they provide:

- `arkdeck-provider-workspace::keychain_secrets` — `trusted_daemon_fingerprint` (the receipt is
  bound to the daemon's code identity; Windows needs the Authenticode identity of G12) and
  `default_daemon_executable` (the macOS helper bundle path; the Windows install shape is the
  WM3 crib).
- `signing_install`, `signing_rekey`, `signing_removal`, `credential_owner`, `sdk_release` —
  `canonical_json` and `file_identity` (`measure`/`remeasure`/`foundation_resolved_path`,
  inode-based, `cfg(unix)`), DevEco resources and property lists (G15).
- `signer` — the PTY exchange for `hap-sign-tool` (G19, ConPTY) and the registered Java and
  `hap-sign-tool` identities.
- `arkdeck-cli::signing_leaves` / `signing_inputs` — all of the above.
