# TASK-XPA-008 — WM2: `debug.hap@1` plan and admission on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM2, GJ-2. This slice also carries
XPA-009's native-library plan and admission. See
`../TASK-XPA-009/windows-native-library-admission-run.md`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device was contacted, no HDC or board was used, and no `hdc` was run.
- Nothing installed was read or written, and no system setting was changed.
- Host tests are not Windows acceptance.

It builds on the Import owner of #2397 (H3), which the debug-hap oracle's Import holds need.

## What

The planner and admitter for `debug.hap@1` already built on Windows. What was macOS-only was the
proof: the Swift debug-hap oracle's replays (`hoststore/tests/debug_hap_plan.rs`,
`debug_hap_submit.rs`). They now run on Windows.

- **The oracle root.** `support/debug_hap.rs` roots the fake's layout below the temporary
  directory on Windows. Its directories are owner-only as the store makes them
  (`fixture_fs::private_dir`), its index documents owner-only, and each published payload is
  created and sealed by the store (`create_document`, `seal_document`), which is what Swift's
  `0400` is.
- **POSIX-only support.** `support/mod.rs` gates to Unix the analyzer oracles' fixed root, the
  mode walker and the assertions built on them. `reconcile` stays macOS-only, and in `hdc_oracle`
  only `assert_replays` does (it dispatches to the shared fake HDC, a POSIX shell script, and
  continues cleanup debt).
- **Plan digests (T0).** A HAP plan's digest covers each send's arguments, and a send names the
  package's host path. Swift recorded its plans at `/private/tmp/arkdeck-hdc-oracle`.
  - `hap_plan_digest`, the plan document split out of `materialize_hap` with no change in
    behavior, reproduces all 10 recorded plan digests from Swift's requests over the paths Swift
    named. This is a unit test that runs on every host: a path keeps the spelling it is given,
    and the send names it verbatim.
  - A Windows root digests the same document with its own paths.
- **Relabelling in the replays.** On Windows the replays read the plan digests and what they
  derive as Swift's through a one-to-one relabelling (`support::debug_hap::HostLabels`, whole JSON
  strings only, in one pass). The derived values are:
  - the Runtime capability's ID;
  - a use's query and authorization-scope fingerprints;
  - the receipt, and the outcome record hashes.

  Every other byte must be Swift's, and on macOS nothing is relabelled. The capability store's
  hashes over Swift's inputs are already proved on Windows by `tests/capability_write.rs`.

## Oracle measurements on Windows

- **`debug_hap_plan.rs`** (2 tests):
  - All 15 plans, 10 positive, match with only the digest relabelled. The four malformed
    package-set variants are refused. Nothing is admitted or dispatched.
  - The entry and additional Imports are held for the whole plan, and released on success or a
    preflight refusal (target, revision and identity mismatch; duplicate).
- **`debug_hap_submit.rs`** (7 tests):
  - Every plan and all 8 submissions are answered as Swift answered them. Swift's capabilities
    are installed, with no use consumed at admission.
  - Each Job's `request`, original submission, members, the first two Journal events and the
    admission rows are Swift's.
  - With each recorded use written between the submissions through the store's own writes, the
    checkpoint and ledger are Swift's byte for byte, and their files are exactly owner
    read/write (the `600` Swift recorded, read through `owner_only_document`).
  - After the last use's unknown outcome, no HAP is admitted on the binding (`lineageBlocked`,
    zero dispatch), whatever its inputs.
  - A named capability is used as named, and an unknown one is denied `capabilityNotFound`.
  - An imported package set is admitted and keeps both Imports from release.
  - `agent.run` admits the HAP it will run.
  - A cancellation at `preflight` spends no use.
  - New: without an HDC composition (the Windows daemon's), an admitted HAP is refused before
    its first step (`rejected`, zero dispatch). It stays in `preflight` with the same Journal and
    no use consumed, beside the mutation owner.
- **`hap_plan_digest` unit test.** All 10 Swift digests, on Windows and macOS.
- **`arkdeck-agentd/tests/windows_job_admission_process.rs`.** New: the real daemon refuses
  every recorded `debug.hap@1` submission, planned and submitted, before admission with
  `provider hdc is not registered` and zero dispatch. It admits nothing and issues no
  capability, and the Job and capability store stay byte for byte, across a restart.

## Left out, and why

- **The HAP run (`debug_hap_run.rs`).** It dispatches to the shared fake HDC, a POSIX shell script
  at a fixed macOS root, so it stays macOS-only. The Windows daemon cannot reach it anyway until
  the tuple is registered, and that refusal is proved above.
- **No new CLI leaf.** `job plan` and `job submit` were already measured on Windows (#2376).
  `debug.hap@1` goes through them and is refused at the tuple gate.
- **Delegated minor decision, pending the next rulings batch.** The Windows oracle replays
  compare plan digests and the capability values derived from them through a one-to-one
  relabelling. The digests' T0 equality is proved separately, over Swift's own paths.

## Local targeted checks

The environment set `CARGO_TARGET_DIR=D:/cargo-target/m1-gj23` and
`ARKDECK_DEV_SIGNER_THUMBPRINT`.

| Command | Exit |
| --- | --- |
| `cargo fmt --all --check` | 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 |
| `cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli -- --nocapture` | 0 |
| The same tests with `TEMP`/`TMP` set to an 8.3 short path on C: | 0 |
| `sh scripts/check-sdd.sh` | 0 |
| `git diff --check` | 0 |
| `scripts/check_union_merge.py` | 0 |
| macOS cross-check: `cargo check` and `cargo clippy -D warnings --target aarch64-apple-darwin --workspace --all-targets`, with `xcrun`, `ar` and `cc` stubbed | 0 |

- **SKIPPED.** Only the account-location tests printed it. An account daemon the user started
  holds this account's pipe on this host, and it was not stopped.
- **Where it ran.** Every check ran on `origin/main` `5c65d383`, which includes #2397, with this
  change on top.
- **macOS cross-check.** A development run over #2397 at `1b8016be` had found that its
  `tests/import_upload.rs` lacked `PermissionsExt` for three `from_mode` calls. H3 was told, and
  #2397 landed with the fix.

## CI

This is recorded by the next slice.
