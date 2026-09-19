# SPK-10 — signing and credentials in Rust (TASK-XPA-015, M3)

**Verdict: go.** Every step of the OpenHarmony signing path runs in Rust
without Swift, Objective-C or an executor sidecar: the Keychain through
`SecItem*`, the DevEco password decoder, hap-sign-tool under a pinned Java
launcher, and Hvigor through a registered DevEco toolchain. No step needs a path
Rust cannot take. `LAContext` is used, as Swift uses it, and Rust creates it
through the Objective-C runtime's C entry points. The first pass criterion,
zero secret under `ArkDeckFakeHapSignerFixture`, holds. The second, a real
signed product's digest equal to Swift's, cannot be met as worded by any caller,
Swift included: hap-sign-tool's output differs from run to run. The
signer-independent identities it stands for were compared instead, and all of
them equal Swift's. That restatement is the one item for the maintainer.

With SPK-6 already passed, the executor sidecar decision of TASK-XPA-014 now
waits only on SPK-9.

Base: protected `main` `9c58e484`. Host: macOS 27.0 (26A428), arm64, no
Rosetta; DevEco Studio at `/Applications/DevEco-Studio.app` with JBR
`21.0.8+9-b1038.71`, Node `v18.20.1`, Hvigor `5.14.2-td-rc.2851`. No device
was used or needed. Readiness pins: the task's pins of 2026-09-14 are
unchanged; the spike adds none.

| Already on `main` | This spike delivers | Still remaining (M3) |
|---|---|---|
| Rust `workspace.project.register/list/show`; DevEco toolchain `runtime tool register/list/remove`; SPK-6's verified tool runner, PTY exchange and `/.vol` launch | `arkdeck_platform::KeychainItems` (`SecItem*`, three-way presence, non-interactive `LAContext`), `trusted_daemon_fingerprint`, `Secret`, `process_argument_record`; new crate `arkdeck-provider-workspace` — DevEco decoder, preset receipt (T0 keys, re-measurement), Keychain envelope, signing action and argv, `sign_hap` / `verify_and_record` / `read_verified_result`; `ArkDeckFakeHapSignerFixture` end to end; host probes | the other project and preset methods; the credential owner ledger (`credential-owner-v1.json`); the Job composition of the 13 `workspace.*` operations; the maintenance CLI writers (`runtime signing install/migrate-deveco/remove`); the three analyzers; GJ-5 |

## Pass criterion 1: zero secret in argv, environment or receipts

`cargo test -p arkdeck-provider-workspace --test fake_hap_signer`: exit 0, 10
tests, repeated six times green. The Swift fixture's source is compiled with
`swiftc` from a byte-identical copy in
`rust/tests/fixtures/fake-hap-signer/main.swift`; a test compares the copy with
`Packages/ArkDeckKit/Tests/ArkDeckFakeHapSignerFixture/main.swift`. Both
passwords are random per test and sit in a Keychain envelope in a keychain made
by `security create-keychain`.

- **The live signer's argv and environment.** While the fixture waits in its
  `unknown-prompt` mode, the test finds it by its attempt directory, stops it
  with `SIGSTOP` and reads the kernel's `KERN_PROCARGS2` record: the executable
  path, every argument and the whole environment. Neither password is in it.
  The argv holds `sign-app`, `-pwdInputMode 1` and the JAR's `/.vol` inode
  alias, and no `-keystorePwd` or `-keyPwd`.
- **Every file the run leaves** under the fixture root holds neither password:
  the keychain file, the preset, the attempt directory, the signed HAP and the
  record.
- **The receipt and every failure text** hold neither password. A signer that
  echoes a password ends as `outcomeUnknown` privacy failure with no product. A
  rejected password reports only Swift's closed diagnostics:
  `termination=exit:74`, `completedPrompts=2`, `keystorePasswordRejected`.
  Repeated or unknown prompts are `promptProtocolViolation`. A failed
  `verify-app` leaves no record.
- **Refusals before the spawn leave nothing.** A drifted input, a receipt bound
  to another daemon, a drifted JAR and an absent envelope each refuse with no
  attempt directory.

`cargo test -p arkdeck-platform --test keychain`: exit 0, 5 tests. Add, value-only
update, read, three-way presence and delete work against a fixture keychain,
and the user's keychain search list is unchanged before and after. From this
unentitled binary the real Data Protection Keychain answers `-34018`
(`errSecMissingEntitlement`), which is `Unreadable`, never `Absent`, as Swift's
`presence(of:)` requires. Only read-only questions reach the real Keychain.

## Pass criterion 2: a real signed product against Swift's

**Fact: the digest is not reproducible by any caller.** The real hap-sign-tool
was run on one unsigned HAP (`e3e485a7…`, 2 743 431 bytes) with one key,
certificate and profile:

| Run | Signed digest | Bytes |
|---|---|---|
| `java -jar hap-sign-tool.jar sign-app` directly, first | `3b2dfd31…` | 2 808 565 |
| the same command again | `03ce26bd…` | 2 808 565 |
| Rust `sign_hap`, SDK release key, run 1 | `1f5d7230…` | 2 808 563 |
| Rust `sign_hap`, SDK release key, run 2 | `54a30a56…` | 2 808 564 |
| Rust `sign_hap`, the DevEco debug key, run 1 | `b1fd4d69…` | 2 811 337 |
| Rust `sign_hap`, the DevEco debug key, run 2 | `69d04d8b…` | 2 811 334 |
| DevEco's own signed product of the same input | `ee083149…` | 2 811 342 |

The two direct runs differ in 669 bytes spread over 14 short runs. The ECDSA
signatures change on every run, and in the Rust runs their DER length moves the
file size by a few bytes. So neither Swift nor Rust can match another run's
digest. `sign-profile` behaves the same.

**What does equal Swift's, measured on real data:**

- **Pinned files.** Rust's `measure` of the installed preset's five files gives
  the SHA-256 values Swift recorded in the installed `preset-v1.json`: Java
  `dab75514…`, JAR `a434b674…`, keystore `ae0afa23…`, certificate `123d785d…`
  and profile `e609b612…`. The receipt was only read.
- **Daemon identity.** `trusted_daemon_fingerprint` of the installed
  `ArkDeckAgent.app/Contents/MacOS/arkdeck-agentd` equals the receipt's
  `trustedDaemonApplicationSHA256`, `edac247f…`. Strict all-architecture
  validation of the 79 MB helper took 9.4 s.
- **Verified identity of the product.** `verify-app`'s certificate-chain and
  profile readbacks of both Rust-signed DevEco products equal those of DevEco's
  own product: chain `7857be2c…`, profile `e609b612…`, which is also the pinned
  profile's digest. With the SDK release material, both runs read back chain
  `5358faac…` and profile `ddec2a15…`.
- **The DevEco decoder on real material.** Rust decoded the real DevEco
  ciphertext of the demo project's build profile through `~/.ohos/config/material`.
  The real signer accepted both passwords, and both products passed `verify-app`.
  Nothing decoded was printed or stored.
- **Swift-produced vectors.** `tests/deveco_password.rs` replays three vectors
  printed by `spk-10/deveco-vectors.swift`, which is Swift's contract-test
  fixture generator with CryptoKit and fixed nonces. One vector makes the XORed
  key material ill-formed UTF-8 of every kind, so a re-encoding different from
  Swift's `String(decoding:as:)` would fail. It also replays Swift's lossy-decoding
  outputs and RFC 7914's PBKDF2 vector. `spk-10/deveco-vectors.txt` is the
  output.
- **The record format.** `signing-result.json` is written in Foundation's
  canonical pretty spelling, checked against Foundation's own output, with
  Swift's 15 summary keys; the reader refuses a sixteenth.

**Not done: a Swift-side run of the real signer.** No Swift-signed product
exists outside installed state. Building the Swift package fresh in this
worktree resolves and compiles its remote dependencies. A Job on the installed
daemon would change installed Runtime state. **For the maintainer:** accept the
restated criterion (identical argv and prompt protocol, pinned-file and daemon
identities equal to Swift's, verified-identity readbacks equal to the reference
product's, the record format), or ask for a Swift-only oracle PR that records a
real-signer run's readbacks for comparison.

## Fail criterion: a step needs `LAContext` or a path Rust cannot take

- **`LAContext`.** Swift passes an `LAContext` with `interactionNotAllowed` as
  `kSecUseAuthenticationContext` on every read and presence probe, and asserts
  that the deprecated `kSecUseAuthenticationUI` is absent. Rust builds the same
  object with `objc_getClass`, `sel_registerName` and `objc_msgSend`, with
  LocalAuthentication linked, and passes it the same way. A unit test reads
  `interactionNotAllowed` back as true, and every fixture read uses it. No
  Swift or Objective-C code is needed.
- **The Data Protection Keychain.** Only a binary signed with the helpers'
  provisioning profile and the access-group entitlement can read the real
  envelope, as for Swift's daemon and CLI. The Rust daemon meets this once it
  runs inside the signed `ArkDeckAgent.app`. A positive read of the installed
  envelope from Rust was not attempted: it needs a probe signed with the
  daemon's profile. That is left to M3's packaged run.
- **Hvigor through a registered toolchain.** The hoststore `spk10_hvigor`
  example registers the installed DevEco Studio into a scratch registry root
  with the Rust owner, reading DevEco read-only. It launches
  `node <hvigorw.js> --version` from the record: Node by its retained inode
  and pinned SHA-256 (`b98965e9…`), the script held open and re-hashed
  (`aa1f2431…`), `DEVECO_SDK_HOME` set, and a project directory as the working
  directory. It exits 0 with `5.14.2-td-rc.2851`, with or without `HOME` and
  `TMPDIR` (`spk-10/hvigor-registered-toolchain.json`). With the runner's
  default working directory `/`, Hvigor recurses in `mkdirSync` and fails, so a
  build must run in the project root as Swift's does.
- **A real `assembleHap` cannot run on this host.** It fails for a Swift-like
  shell environment and for the Rust runner alike: the SDK's bundled `ninja` is
  x86_64-only and this macOS 27.0 host has no Rosetta ("Bad CPU type in
  executable"). This is a host condition for GJ-5's build leg when the project
  has native modules, as the WaterFlow demo does. It is not a Rust limitation.

## Findings for the M3 workspace build and sign slices

1. **Child environment.** Swift's `FoundationProcessExecutor` and
   `IdentityBoundPTYExecutor` pass on the daemon's `PATH`, `HOME`, `TMPDIR` and
   `LANG`. The Rust runner (`run_tool`, `run_pty_exchange`) uses a fixed
   `PATH=/usr/bin:/bin`, `LANG=C`, `LC_ALL=C`. Signing works either way, since
   Java finds its home and temporary directory itself. Hvigor and ohpm builds
   probably need `HOME` and `TMPDIR`. The build slice should settle this, in
   the platform base or as an explicit overlay by the provider.
2. **Two canonical spellings.** The runner needs a physical working directory;
   Swift's `measure` needs Foundation's spelling. They differ only under
   `/private`, never under the daemon's state or `~/Library`.
3. **Cost of the daemon fingerprint.** It takes about 9 s cold. Port Swift's
   file-identity memo (`RuntimeFileDerivedCaches.daemonIdentity`) before
   availability or `operation.list` consults it.
4. **Suggested interface.** The Job engine lowers
   `workspace.sign-openharmony-hap@1` to a `SigningAction`, which is serde with
   Swift's keys. It calls `sign_hap(action,
   &SigningPresetStore::new(default_root), &KeychainSigningSecrets::installed(
   default_daemon_executable), cancelled)`. `SigningFailure::Refused` is a
   zero-dispatch failure. `OutcomeUnknown` parks the Job for readback through
   `read_verified_result`; recovery itself waits for design §L.1 item 13. The
   Job publishes `signed.hap` and the summary as `signing-report.json`, and
   removes the attempt directory at a known terminal. A workspace `signing`
   preset still needs the credential owner ledger ported: `resolve(reference,
   owner, requireSecrets)`, `acquire` and `release`.
5. **A PTY refusal before the spawn** is reported as
   `outcomeUnknown(launchFailed)`, as Swift reports it. Classifying it as zero
   dispatch would change the T1 answer, so it is left as is.
6. **The maintenance writers** (`runtime signing install`, `migrate-deveco`,
   `remove`) stay Swift. `KeychainItems::set/remove`, `encode_envelope` and the
   decoder are their pieces when lane C ports those CLI leaves.

## Local targeted checks

After rebasing onto `main` `5b70cebd`, with `CARGO_BUILD_JOBS=2`. `AGENTS.md` on
that `main` makes the PR's CI the unified gate and runs no full local gate.

| Check | Exit | Result |
|---|---|---|
| `cargo fmt --all --check` | 0 | |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | every crate depends on `arkdeck-platform` |
| `cargo clippy -p arkdeck-provider-workspace -p arkdeck-platform -p arkdeck-hoststore --all-targets --target {x86_64-unknown-linux-gnu,x86_64-pc-windows-msvc} -- -D warnings` | 0 | run before the rebase |
| `cargo test --no-fail-fast -p arkdeck-platform -p arkdeck-provider-workspace -p arkdeck-provider-hdc` | 0 | 338 passed, 0 failed; `arkdeck-provider-hdc` is the other caller of the argv reader split here |
| `assert_boundaries()` of `rust/scripts/check-readonly.py` | 0 | the new edge is declared |
| `cargo deny --locked check`; `cargo vet --locked --no-registry-suggestions` | 0 | no new crate or version |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |
| `spk10_probe fingerprint`, `spk10_probe sign` (SDK release ×2, DevEco ×2), `spk10_probe verify`, `spk10_hvigor` | 0 | results above; `spk-10/real-signer-sdk-release.json` holds the SDK run |

One pre-rebase run of the platform tests failed once in
`loopback_server_lease.rs`, in
`listeners_of_the_executable_that_come_and_go_on_other_ports_do_not_disturb_the_verdict`.
It passed 10 of 10 alone and 8 of 8 as a whole binary, and every later run was
green. The lease scan it exercises does not call the argv reader this change
splits, whose only other caller is `managed_process_matches`. This is the
listener-churn flake family, not a regression.

## CI

The PR's `guard` and `swift` aggregate are the unified gate. Their result is
added here once the PR is green.

## Residue and privacy

No secret is in this record, the probes' output or the repository. The DevEco
run's raw output is not kept, only the digest prefixes above. The scratch
keychains, preset roots, attempt directories and project copies lived in the
session scratchpad and Cargo's target temporary directory; the tests delete
theirs. Installed state was only read: the receipt, the daemon executable, and
the Data Protection Keychain, which refused.
