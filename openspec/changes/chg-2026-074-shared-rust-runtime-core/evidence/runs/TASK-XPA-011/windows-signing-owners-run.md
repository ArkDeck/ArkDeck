# TASK-XPA-011 — Windows signing owners (signer, SDK release, credential owner), 2026-09-30

- Task: TASK-XPA-011 prerequisite (XPA-015 signing layer), WM3 slice G2: the signing owners of
  `arkdeck-provider-workspace` that were still macOS-only — `signer`, `sdk_release` (+
  `sdk_release_profile`), `credential_owner` with `signing_install`, `signing_rekey` and
  `signing_removal`, and the scope-bound form of `keychain_secrets` — built and tested on
  Windows. Gate-inventory groups G13 (consumers), G36, G39
  (`../TASK-XPA-004/windows-gate-inventory-20260930.md`).
- Base: developed on protected `main` `f0d83f78` (#2358, ConPTY `spawn_attached`) with the then
  open heads of #2362 (D2, DevEco files and pinned-file measurement, `ad4d7a7a`) and #2354 (C1,
  Credential Manager store, `8a77d05b`) merged in; #2362 has since merged (`cb0c329c`) and
  `origin/main` `65c4ba33` was merged into the branch before push, every check below rerun on
  the merged head. **#2354 is still open: this branch carries it and must land after it** (or
  with it); its files are unchanged here except a union of the platform `Cargo.toml` test
  targets and `windows/mod.rs` module list.
- Host: the Windows 11 x64 reference host (Windows 11 Pro 10.0.26200), rustc/cargo 1.98.1,
  non-elevated. Nothing was installed, elevated or reconfigured; no board, `hdc`, DevEco
  installation, JDK, hap-sign-tool, keystore, certificate, profile or real password was used or
  read. The only credentials written were the flow test's own under a per-run
  `ArkDeck-fixture/test-<pid>-<random>/…` namespace; `cmdkey /list` shows no `ArkDeck`
  credential and the account's local application data holds no `arkdeck-test-*` tree after the
  runs.

This is host evidence for a Rust port, run with a fake Java. It is not GJ-5, not SPK-10 signing
evidence and not Windows platform acceptance: the CLI signing leaves and the daemon's signing
dispatch are still macOS-only (see "What stays gated").

## What changed

| Area | macOS (unchanged behaviour) | Windows (new) |
| --- | --- | --- |
| Module gates (`arkdeck-provider-workspace/src/lib.rs`) | `signer`, `sdk_release`, `sdk_release_profile`, `signing_install`, `signing_rekey`, `signing_removal`, `credential_owner`, `keychain_secrets`: `cfg(target_os = "macos")` | `cfg(any(target_os = "macos", windows))`; Linux builds what it built before |
| Host path spelling (`signing_action`) | `/`-joined attempt paths; managed material `<managed>/OpenHarmony.p12`…, JAR rule `…/toolchains/lib/hap-sign-tool.jar` | `HOST_SEPARATOR` (`\`), `host_join`, `host_parent`: the same names joined with `\`; the managed-directory, SDK-root and removal checks use D2's `is_standard_host_path` (`X:\a\b`) |
| `VerifiedSource` (`arkdeck-platform`) | the retained descriptor, named to the child by its `/.vol/<dev>/<ino>` alias | `src/windows/verified_source.rs`: the file held without write/delete sharing, every ancestor held without delete sharing and refused if a reparse point (as `VerifiedTool` holds its executable), length + SHA-256 + `FileIdInfo` unchanged across the hash; `inode_path()` is the canonical `X:\…` path the held namespace keeps naming it |
| Private entries | `DirBuilder::mode(0o700)`, `OpenOptions::mode(0o600)`, `set_permissions(0o600)` | `create_private_directory` / `create_private_file`: the host store's private descriptor (owner the token user, protected DACL granting that user alone; inheritable on a directory) |
| `signer` | stage by `fs::copy` + `chmod 0600`; record temp file `create_new` + `chmod 0600`, then hard link | stage by a private create + copy; record temp file created private, then hard link; `java.exe` on a pseudo console (#2358) |
| `sdk_release` | library `sdk/toolchains/lib`; signed profile re-opened by its inode, `nlink == 1`, `uid == euid`, `chmod 0600`, fsync | library `sdk\toolchains\lib`; the signed profile inherits the private directory's owner-only DACL; checked single-link, owned by the user and the measured bytes, flushed; privacy then proved by the owner-private re-measurement (never granted) |
| `SigningPresetStore::default_root` | `~/Library/Application Support/ArkDeck/Signing/OpenHarmony` | `<LocalAppData>\ArkDeck\Signing\OpenHarmony` (proposal 1) |
| `keychain_secrets` | `installed`, `for_maintenance`, `over`, daemon fingerprint | `over` only (Credential Manager scope, no daemon binding); `installed`/`for_maintenance`/`default_daemon_executable` stay macOS-only (proposal 5) |
| Unit tests of `signing_install` and `sdk_release` | fixtures under `/private/tmp` | `src/test_fixture.rs`: the same fixtures on macOS, and on Windows under the account's local application data; the tests now also run on Windows |

Durable formats: the receipt (`preset-v1.json`), the credential ledger, the signing action and
`signing-result.json` keep their exact key sets and canonical encoders; only their path values
are this host's spelling. No byte of a macOS path, record or argv changes.

## Decisions (proposals for the maintainer's review)

1. **Preset root.** `SigningPresetStore::default_root()` on Windows is
   `<LocalAppData>\ArkDeck\Signing\OpenHarmony` (`FOLDERID_LocalAppData` of the process token,
   as the daemon's `ArkDeck\Agentd` state), under the same relative names as macOS. The
   credential owner creates it owner-only on first use.
2. **The `/.vol` alias becomes a held namespace.** Windows has no path that names a file by
   its identity for another process. A `VerifiedSource` keeps the file open without
   `FILE_SHARE_WRITE`/`FILE_SHARE_DELETE` and every ancestor directory open without
   `FILE_SHARE_DELETE`, so for as long as it is held nobody can write, rename or delete the
   file or rename or delete any level above it, and its canonical path (the spelling on disk,
   no link, junction, `\\?\`, `.` or `..`) names exactly the hashed bytes. That path replaces
   the alias at `argv[1]` of `sign-app`/`verify-app`/`sign-profile`/`verify-profile`.
   (NTFS itself also refuses to rename a directory while a file below it is open; the held
   levels do not rely on it.)
3. **Private = the store's private descriptor.** Every directory and file the signing layer
   creates (attempt directory, staged HAP, result record, managed SDK directory and its
   material) is created with an explicit owner-only DACL, not left to inheritance. Files a
   signer writes into such a directory inherit its owner-only access; they are measured
   owner-private before use (the macOS `chmod 0600` of the signed profile becomes a check).
4. **Host paths in durable records.** Paths inside the action, receipt and ledger are the
   host's standard spelling: on Windows `X:\a\b` with `\`. A record is read on the host that
   wrote it; a record with the other host's spelling fails the standard-path checks (fail
   closed).
5. **No daemon binding on Windows yet.** A macOS receipt records the installed daemon's code
   identity (`trustedDaemonApplicationSHA256`) and signing refuses a different daemon. The
   Windows counterpart (the daemon's Authenticode signer, G12; publisher pin #2352 in flight)
   is a separate design decision, so only `KeychainSigningSecrets::over` exists on Windows and
   binds to no daemon (`None`, as a fixture keychain does on macOS). The production
   composition (`installed`) waits for that decision.

## Tests (Windows)

| Target | What it proves |
| --- | --- |
| `arkdeck-platform/tests/windows_verified_source.rs` (3) | a held source reads by its path, cannot be opened for write, deleted or renamed, its directory and the scratch root cannot be renamed, an entry beside it can be added, and after drop all of it works again; wrong length, wrong digest, no pin, another case, `\\?\`, relative, a `.` component, a directory and a path through a junction are refused; `create_private_directory`/`create_private_file` refuse an existing entry and give owner-private, trusted-write-only entries inside a parent that grants `Everyone` full control by inheritance, and a file created by other code inside the private directory is owner-private |
| `arkdeck-provider-workspace/tests/windows_signing_flow.rs` (6, `harness = false`; the fake Java is this binary copied into the private fixture tree as `java.exe`) | **sign**: install through the credential owner (receipt with Windows paths, no daemon fingerprint, receipt private), `sign_hap` on the pseudo console → `sign-app` then `verify-app`, signed bytes, digest, summary and record as expected, record and staged copy private, no password in the record; `read_verified_result` and `recovered_receipt` read it back without running anything; a moved product is drift; removal empties the store. **Credential Manager**: the envelope lives at `ArkDeck-fixture/<ns>/dev.arkdeck.openharmony-local-signing/…`, a HAP is signed with it, `replace_secret_envelope` re-keys in place (same account) and the next signing uses the new (rejected) password, removal leaves the account `Absent`. **Rejected password**: `OutcomeUnknown` with `termination=exit:1`, `completedPrompts=2`, no secret in the text, only `sign-app` ran, no record or product. **Drifted JAR**: `Refused` before dispatch, the attempt directory absent, the fake never ran. **SDK release**: `install_sdk_release` generates the profile, the fake signs it with the published password and `verify-profile` reads it back; the receipt is the managed SDK preset, its material private, the verification file removed; the managed preset signs a HAP; removal removes the managed directory. **Default root** as proposal 1. Inside the fake, each run proves the JAR it was named by is the fixture JAR and cannot be deleted or renamed, nor its directory, and for `sign-app`/`sign-profile` the same of the staged input; both passwords are read with echo cleared through `read_terminal_secret` and are in no argv or environment |
| `arkdeck-provider-workspace` unit tests (20, now all on Windows) | incl. `signing_install::publication_tests` (unknown publication quarantines envelopes, pre-publication failure restores, unknown re-key blocks resolution) and `sdk_release::publication_tests` (published material survives an unknown receipt and a failed final ledger; pending cleanup refuses an outside directory) |

Negative controls, run once and reverted:

- `VerifiedSource` opening its file with every sharing mode: the held-source platform test
  fails (the file opens for write), and four of the six flow tests fail — the fake deletes the
  JAR it was named by and exits with its "not held" code.
- `VerifiedSource` dropping its ancestor handles: every test still passes, because NTFS refuses
  the directory renames by itself while the file is held (recorded in proposal 2 rather than
  claimed as tested).

No test uses a sleep for synchronisation (the credential owner's existing lock retry is
unchanged). The flow test was run three times in a row, all green.

## Checks

Run from `rust/` with `CARGO_TARGET_DIR=D:/cargo-target/g2-signing` on the merged head:

| Command | Result |
| --- | --- |
| `cargo fmt --all --check` | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | clean |
| `cargo test -p arkdeck-platform -p arkdeck-provider-workspace -p arkdeck-hoststore -p arkdeck-cli` | pass (201 test binaries ok; platform lib 81 + 1 ignored, `windows_verified_source` 3, `windows_credential_store` 6, `windows_console_secret` 7, `windows_pty_exchange` 9, `windows_shell_channel` 8, `windows_deveco_files` 3 + 1 ignored; provider-workspace lib 20, `windows_file_identity` 2, `windows_signing_flow` 6) |
| `sh scripts/check-sdd.sh` (`PYTHONUTF8=1`) | pass |
| `git diff --check` | clean |

macOS and Linux cannot be built on this host. The macOS code paths were kept textually
(`DirBuilder`/`OpenOptions` modes, `chmod`, the inode re-open of the signed profile, the
fingerprint call) behind `cfg(target_os = "macos")`; the only macOS-visible edits are
`is_absolute()`/`len()` for the equivalent `starts_with('/')`/`size()`, `host_join` for the
`/`-joined `format!`s, and the test fixtures moved to `src/test_fixture.rs`. The macOS and
ubuntu CI legs are the check for those.

## What stays gated

- `arkdeck-cli::signing_leaves` / `signing_inputs` (`runtime signing install|rekey|remove|
  status`): they compose `KeychainSigningSecrets::installed`/`for_maintenance` and the DevEco
  password material layout (`deveco_password::material_layout`, not measured on Windows) —
  next slice, after proposal 5 is decided.
- The daemon's signing dispatch and credential resolution (`arkdeck-agentd`,
  `arkdeck-hoststore` composition of `workspace.sign-openharmony-hap@1`): needs the production
  secret source and the Windows attempt root.
- `trusted_daemon_fingerprint` on Windows (G12 Authenticode identity as a receipt input).
- A Windows installation's real layout (JDK/`jbr\bin\java.exe`, SDK
  `sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar`) is recorded by D2; the signer
  accepts it by construction, but nothing here ran a real hap-sign-tool (SPK-10 on Windows,
  phase A).
