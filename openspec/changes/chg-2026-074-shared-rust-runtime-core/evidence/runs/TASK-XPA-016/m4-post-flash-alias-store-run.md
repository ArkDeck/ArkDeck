# TASK-XPA-016 — M4 run record: the post-flash HDC alias store

Change: CHG-2026-074-shared-rust-runtime-core@r11. Milestone M4 (GJ-4), lane B's "Rockchip
live-mode and post-flash binding" item, sixth slice: the Rust store behind the post-flash HDC
alias, replaying the Swift oracle recorded beside it. Host measurement only — not hardware,
platform or conformance evidence (POL-VERIFY-001, POL-MODE-001). No device, no HDC, no daemon,
no installed root: every test runs against a scratch directory.

Base: protected main `47d6f020` (#1933). Branch `agent/xpa-016-post-flash-alias-store-20260914`,
stacked on #1939 (the host primitives, `0e5d72bc`) and on the Swift-only oracle slice
(`agent/xpa-016-post-flash-alias-oracle-20260914`, `d33cbd01`, carried as `f0229f1c`); it
re-parents after each of those squashes.

## What was missing

`RockchipHdcObserver::verify_bound_build` (#1936) returns the proof — the bound HDC identity and
the exact build and model readback — and stops where Swift's `verifyBoundBuild` publishes the
post-flash alias; nothing in Rust could hold that alias. Swift keeps it in
`RockchipPostFlashHDCBindingStore` (`RockchipPostFlashHDCBinding.swift`): the record, its bytes,
its lock, its three-way publication, its archived epochs and its reissue repair. Lane A agreed
(2026-09-14) that lane B ports the store as additive `arkdeck-hoststore` files, the Target owner's
lineage advance staying theirs.

## What Swift does

`RockchipPostFlashHDCBinding` (10–64): twelve fields, `schemaVersion` forced to `1.0.0`;
`sameProof` (480–494) compares all but `establishedAtUTC`. The store (69–478): `prepareRoot`
(429–439), `validateFile` (441–449, exactly 0600, one link, the owner's), `loadIfPresent`/`load`
(80–86, 374–405: `ENOENT` → nil, a bare `JSONDecoder`, then `validate`), `validate` (407–427:
sixteen conjuncts, one message), `publish` (99–154: `validate`, the expected previous alias a
digest the candidate names, the root, the lock — blocking `LOCK_EX`, `LOCK_UN` before close —
then the same proof returned unwritten, a revision advance archiving the existing record, else the
four-conjunct chain rule or "post-flash binding changed before verified alias publication"),
`commit` (156–192: canonical bytes plus `0x0A` within 64 KiB, a fresh 0600 temporary, `fsync`,
`F_FULLFSYNC`, rename, directory `fsync`, readback compared), `archiveSuperseded` (311–343:
`post-flash-superseded-<alphanumerics of establishedAtUTC>.json`, `O_EXCL`, a taken name compared
byte for byte — "…already holds a different entry"), `reconcileReissuedLineage` (241–303: under
the lock, a stored alias ahead of the live Target agreeing on target, Loader identity, HDC
identity, connect key and topology, with a well-formed observation and time, is archived and
republished at the live revision naming itself as its previous alias; every disagreement is nil).

## What Rust now does

- `rust/crates/arkdeck-hoststore/src/post_flash_alias.rs` (macOS, pure): `PostFlashBinding`
  (`value()` the sorted object, `encode()` = `arkdeck_contract::canonical_json` + `0x0A`,
  `decode()` as Foundation decodes — unknown members ignored, a duplicate's last value, an integer
  spelled `3.0` accepted — `validate()` with Swift's sixteen conjuncts and one message,
  `same_proof`, `archive_name`), `is_sha256`, `admit` (the two checks before the root),
  `resolve` → `Publication::{Idempotent, ArchiveThenCommit, Commit}` or the chain refusal,
  `reissue` → the republished record or `None`, `LiveTarget`, `ObservedHdc`, `Reconciliation`,
  `PostFlashAliasError` (Swift's `productionConfigurationUnavailable`, displayed as its
  `errorDescription`).
- `src/post_flash_alias_store.rs` (macOS, I/O): `PostFlashAliasStore::new(root)`,
  `load_if_present` (no lock), `publish`, `reconcile_reissued_lineage`; `prepare_root` =
  `HostDirectory::open_or_create_private`; the lock = `wait_lock(".rockchip-post-flash-hdc-binding.lock",
  false)`; `load` = `read_owner_only` + decode + validate; `commit` = the limit, `publish_document`
  (temporary, `F_FULLFSYNC`, rename, directory sync), readback compared; `archive_superseded` =
  `create_exclusive_or_match` with `Created`/`Matched` accepted and `Different` refused with
  Swift's message. Refusal details are Swift's where the oracle pins them; the host-error details
  (`cannot be opened`, `lock cannot be acquired`, `temporary file cannot be synchronized`, `cannot
  be committed`, `archive cannot be created`) map the primitives' opaque errors to the nearest
  Swift sentence.
- Not done here, on purpose: `covers(target:binding:)` (needs the Rockchip binding store) and the
  facts port's `flash.postFlashHDCBindingConflict` / `flash.postFlashHDCAliasLineageReissued`
  routing — the ArkForge lane's; the `flash.reconcile-alias` method and CLI leaf (lanes A/C); the
  Target owner's `advanceBindingLineage` (lane A); the production composition that points the
  store at `arkdeck_application_support_root()`.

## Tests

`cargo test -p arkdeck-hoststore` — lib +5 (`post_flash_alias`), `tests/post_flash_alias.rs` 2/2,
every other test binary of the crate unchanged and passing; `cargo clippy -p arkdeck-hoststore
--all-targets -- -D warnings` clean on the host and for `--target x86_64-unknown-linux-gnu` /
`x86_64-pc-windows-msvc`; `cargo fmt --all -- --check` clean.

| Test | Proves |
| --- | --- |
| `the_rust_store_replays_the_swift_oracle_byte_for_byte` | the oracle's fifteen steps applied in order to one store at a scratch root — loads, publications, planted archive occupants, reconciliations — with every outcome equal to Swift's (published/loaded records, reconciliations, refusal details) and, after every step, the root holding exactly Swift's files: the same names (lock included), modes (0600; the root 0700), sizes and bytes. The first run matched. |
| `the_root_is_prepared_owner_only_and_a_relative_root_is_refused` | a nested root created 0700 by the first load, empty; a relative root refused with Swift's detail and `errorDescription` |
| `the_bytes_are_sorted_compact_and_newline_terminated` | the encoding's shape and a decode round trip |
| `decoding_is_as_lenient_as_foundation_and_validation_is_not` | `3.0` and an unknown member accepted, `3.5`, an array and a string revision refused; seven invalid records each refused with the one message |
| `the_archive_name_is_the_time_s_alphanumerics` | three spellings incl. `unknown` |
| `publication_is_idempotent_advances_or_follows_the_chain` | `admit`'s two refusals; `Commit` on an empty store; `Idempotent` for the same proof; `ArchiveThenCommit` for an advance; the chain refusal for a stale lower revision; `Commit` for a same-revision rotation; the refusal for another Loader identity |
| `a_reissued_lineage_is_republished_at_the_live_revision_or_declined` | the republished record's revision, previous alias and time; declined when not ahead, when the device moved, for another target, and for a malformed time |

## Not run, and why

- No production root and no installed tree: the composition that points the store at
  `arkdeck_application_support_root()` (the parent of the daemon state directory, as the oracle's
  `productionRoot` records) is the daemon's, and no test touches `~/Library/Application Support`.
- No concurrent publishers: the waited-for lock is the crate's existing `wait_lock`, exercised
  by its own tests; the oracle is single-process.
- The host-error details are not oracled (Swift's tests do not pin them either); the decision
  and byte details are.

## Facts for the maintainer (carried from the map, unchanged by this port)

1. Swift's `commit` reports a directory-sync failure after a successful rename as "post-flash
   binding cannot be committed"; Rust keeps that sentence for `publish_document`'s
   `OutcomeUnknown`, so the two agree, and both under-report a published alias in that case.
2. `archiveSuperseded` stays less durable than `commit` (no rename, no `F_FULLFSYNC`); a torn
   archive becomes a permanent "different entry" refusal. Ported as is.
3. Two roots, two counters: the alias under Application Support copies the state directory's
   revision; the reissue repair exists because retiring a state directory restarts one and not
   the other. Unifying them would change a T0 layout and needs a ruling.
