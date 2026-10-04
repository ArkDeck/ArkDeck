# TASK-XPA-009 — WM2: the HAP and native-deployment run lanes on Windows host code

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM2, GJ-2 and GJ-3. This follows #2422 and
#2407. The lead asked for it: port the fake HDC's `debug-hap` and `deploy-native-library` answers
to a test-only in-process `HdcDispatch` (as #2400 and #2408 did for theirs), then run
`debug_hap_run`, `native_library_run` and the rollback leg on Windows host code with host-path
relabelling, in hoststore and provider tests only. The daemon stays gated, and nothing in a
production binary changes its HDC admission.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## What

- **The in-process fake.** `arkdeck-provider-hdc/tests/common/oracle_fake.rs` ports the two
  shell fragments (`hdc-answers.sh` of `debug-hap` and `deploy-native-library`) case for case, in
  their order, with the same positional arguments. It keeps:
  - the same root;
  - the call log the driver appends to (`hdc-invocations.log`, U+001F after every argument);
  - the mode file it reads (`hdc-mode`);
  - the device state as marker files (`device-installed`, `device-running`, `device-published`,
    `device-path-*`).

  It reports its tool identity current, as the macOS dispatch over the fake's verified script
  does. The file is shared by provider-hdc's `common` and hoststore's `support` (by path) and is
  test-only.
- **Where the fake plugs in.** On Windows, `SharedFake.dispatch` (provider) and
  `hdc_oracle::Owners.dispatch` (hoststore) are that fake (`FakeDispatch`), over the same layout
  below the temporary directory. On macOS they stay the driver as a real subprocess, and nothing
  there changes.
- **Readings as the oracle recorded them** (Windows; identity on macOS):
  - Each host path below the replay's root is respelled in the oracle's spelling: the fake's fixed
    root with `/` between components, in plain text and in JSON. The Sessions root is spelled as
    Foundation spells it (`session_publication::foundation_path`: `/tmp/…`, without `/private`),
    in the document's own escaping.
  - The platform a Session was published on is read as the oracle's: `PLATFORM-WINDOWS@0.2.0` as
    `PLATFORM-MACOS@0.2.0`, as the Windows Session tests read it. The manifest's byte count follows
    it, two bytes apart.
  - Relabelled as #2422 does it, one-to-one and in whole JSON strings, so every other byte must
    be Swift's:
    - the plan digests and every value derived from them: capability IDs and references, query,
      scope and consumption fingerprints, receipts, outcome and record hashes;
    - the Journal checkpoint and journal seals (their Journals are compared relabelled);
    - Session manifest digests (their manifests are compared relabelled).
  - An entry's mode is read from its DACL: `700` for a directory the store opens as private, and
    `600` for a document it reads as exactly owner read/write. These are the only modes the two
    oracles record.
  - A request that names a capability (`capability.inspect`) names this host's, as learned from
    the store in install order.
- **`cleanup_debt_continue` on Windows.** A1's #2425 (on `main`) already builds it on Windows
  (its daemon side refuses a continuation without the tuple). The oracles' continuations run
  through `JobRunner::continue_cleanup_debt`, unchanged.

## Measured on Windows

| Test | Result |
| --- | --- |
| `hoststore/tests/debug_hap_run.rs` (8) | Pass. The whole replay: 63 exchanges answered as Swift answered them, the fake's 108 calls in order, and every file left below the root Swift's, relabelled. Also: a historical digest never authorizes, evidence a run did not consume is never continued, a compensation through an unproven tool is never dispatched, a failed compensation is owed under its own identity, an unobserved compensation parks, a refused optional cleanup stops the run, and no HAP is sent without the mutation authority. |
| `hoststore/tests/native_library_run.rs` (4) | Pass. The whole replay (225 calls, the cleanup-debt continuation included), plus: a rollback that fails fails its Job and removes nothing more, a compensation cleanup that fails is owed, and one whose outcome is lost parks its Job. |
| `provider-hdc/tests/debug_hap.rs` | Pass. Every oracle Job argv for argv (108 calls). |
| `provider-hdc/tests/native_library.rs` | Pass. Every oracle Job argv for argv (225 calls): staging, backup, the attested and unattested publish, the loader failure and its rollback, the missing target and the cleanup debt. |

## Left out

- **The daemon.** It still composes no HDC. `ARKDECK_DEVELOPMENT_HDC_PATH` stays refused, and no
  Job of these operations is admitted or dispatched by it, as ruled (the proposed
  "macOS is the standard" ruling is on hold).
- **Other oracles.** The other macOS-only oracle tests that use the shared fake (observe, capture,
  pointer input, port forward, reconcile, crash window, …) are not ported: their answers are other
  fragments, outside this slice.
- **Delegated minor decision, pending the next rulings batch.** Swift's derived digests over
  content that differs only by host paths, the platform profile or relabelled values are read as
  labels. The content itself is always compared byte for byte, relabelled.

## Local targeted checks

The environment set `CARGO_TARGET_DIR=D:/cargo-target/m1-gj23` and
`ARKDECK_DEV_SIGNER_THUMBPRINT`. The checks ran on `origin/main` `3efba88c` (Rust 1.99.0) with this change.

| Command | Exit |
| --- | --- |
| `cargo fmt --all --check` | 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 |
| `cargo test -p arkdeck-hoststore -p arkdeck-provider-hdc -p arkdeck-agentd -p arkdeck-cli -- --nocapture` | 0 |
| `cargo test -p arkdeck-hoststore -p arkdeck-provider-hdc` with `TEMP`/`TMP` set to an 8.3 short path on C: | 0 |
| `sh scripts/check-sdd.sh`, `git diff --check`, `scripts/check_union_merge.py` | 0 |
| macOS: `cargo check` and `cargo clippy -D warnings`, `--target aarch64-apple-darwin --workspace --all-targets`, with `xcrun`, `ar` and `cc` stubbed | 0 |
| Linux: the same for `--target x86_64-unknown-linux-gnu` | 0 |

- **SKIPPED.** None: no account daemon held this account's pipe on this run.
- **One transient.** The first four-crate run stopped at `job_store_corpus`
  (`recorded_job_indexes_are_rebuilt_by_the_owner_and_read_back_after_a_restart`), whose
  `persist` was refused with `PermissionDenied` (os error 5). That test and its fixtures are not
  in this diff. It passed in the 8.3 short-`TEMP` run and in a full `--no-fail-fast` rerun of the
  four crates (exit 0), so it is recorded here as a host-load transient, not fixed.
- **Firewall.** The worktree's base has #2396's gate (`wildcard_listeners_allowed`). No
  arkdeck-platform test ran in this slice.

## CI

This is recorded by the next slice.
