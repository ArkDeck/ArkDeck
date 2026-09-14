# TASK-XPA-016 — M4 run record: the post-flash alias oracle (Swift-only)

Change: CHG-2026-074-shared-rust-runtime-core@r11. Milestone M4 (GJ-4), lane B's "Rockchip
live-mode and post-flash binding" item, fifth slice: the T0 byte oracle of Swift's post-flash HDC
alias store, recorded once in a Swift-only slice as the M1/M2 oracles were, so that the Rust
store that follows changes no Swift file and replays bytes. Host measurement only — not
hardware, platform or conformance evidence (POL-VERIFY-001, POL-MODE-001). No device, no HDC, no
daemon: the store is driven in-process against a fixed root under `/private/tmp`.

Base: protected main `47d6f020` (#1933). Branch `agent/xpa-016-post-flash-alias-oracle-20260914`;
no stacking. No Rust file changes.

## What was missing

The repository held no recorded bytes of `rockchip-post-flash-hdc-binding.json` or of a
`post-flash-superseded-*.json` archive (only two evidence notes under `chg-2026-059` describe
field values from a real host), so a Rust port of `RockchipPostFlashHDCBindingStore` had nothing
to be byte-equal to. The store's decisions — which publication is idempotent, which opens an
epoch and archives, which is refused, what a reissued lineage becomes — were pinned only by
in-process Swift tests over temporary directories.

## What the oracle records

`Packages/ArkDeckKit/Tests/ArkDeckContractTests/PostFlashAliasOracleContractTests.swift` drives
one `RockchipPostFlashHDCBindingStore` at the fixed root `/private/tmp/arkdeck-post-flash-alias-oracle`
(nothing in the store's bytes depends on the root; provenance names it) through fifteen steps at
fixed keys and clocks, and after each step records its input, its outcome (the published or
loaded record, the reconciliation, or the refusal's exact detail), the root's listing with each
entry's kind, mode and size, and every file's bytes under `steps/NN-<name>/`:

| Step | Input | Outcome | Files afterwards |
| --- | --- | --- | --- |
| 00 `load-empty` | `loadIfPresent` on an empty root | `null` (the root is prepared, nothing is written) | none |
| 01 `publish-revision-3` | revision 3, Loader `a`×64, key `old-key`, 2026-08-14T08:09:51Z | published | the document, the lock |
| 02 `retry-same-proof` | the same proof at 09:00:00Z | published — the stored record, 08:09:51Z kept | unchanged |
| 03 `advance-revision-4` | revision 4, Loader `b`×64, key `new-key`, 2026-08-18T04:30:00Z | published | `post-flash-superseded-20260814T080951Z.json` = step 01's bytes |
| 04 `stale-revision-refused` | step 02's candidate again | "post-flash binding changed before verified alias publication" | unchanged |
| 05 `other-loader-refused` | revision 4, Loader `c`×64 | the same refusal | unchanged |
| 06 `rotate-serial-same-revision` | revision 4, Loader `b`, previous `new-key` → key `newer-key`, 2026-08-19T00:00:00Z | published (the chain rule holds; no archive) | the document rotated |
| 07 `reissue-reconciled` | live target at revision 2 (`newer-key`, Loader `b`), observed `newer-key`/`42`, now 2026-09-08T08:05:00Z | `{archivedRevision: 4, publishedRevision: 2, …}` | `post-flash-superseded-20260819T000000Z.json`; the document at revision 2, its previous alias its own |
| 08 `reissue-repeat-declined` | the same at 09:00:00Z | `null` | unchanged |
| 09 `reissue-disagreement-declined` | live revision 1, topology `43` | `null` | unchanged |
| 10 `archive-collision-refused` | a different entry planted at `post-flash-superseded-20260908T080500Z.json`; then revision 3 (`next-key`) | "superseded post-flash binding archive post-flash-superseded-20260908T080500Z.json already holds a different entry" | unchanged, the occupant kept |
| 11 `archive-collision-identical` | the occupant replaced by the exact bytes the store would archive; the same candidate | published | the document at revision 3 |
| 12 `invalid-document-refused` | topology `4a` | "post-flash binding document is invalid" | unchanged |
| 13 `invalid-previous-alias-refused` | expected previous alias `not-a-digest` | "post-flash binding previous alias is invalid" | unchanged |
| 14 `load-final` | `loadIfPresent` | the revision-3 record | unchanged |

Every temporary file is asserted gone after each step. The recorded document at step 01 (one
line, 12 sorted keys, one trailing newline):

```
{"bindingRevision":3,"buildVersion":"OpenHarmony-7.0.0.36","establishedAtUTC":"2026-08-14T08:09:51Z","hdcConnectKey":"old-key","hdcIdentitySHA256":"762c08fc17a1cc5f00d248f8b50f2f2f4d17ff2934ac31e64deacb3f5bb3f2ec","jobID":"job-host","previousHDCIdentitySHA256":"762c08fc17a1cc5f00d248f8b50f2f2f4d17ff2934ac31e64deacb3f5bb3f2ec","productModel":"ohos","schemaVersion":"1.0.0","stableLoaderIdentitySHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","targetID":"TGT-HOST","usbTopology":"42"}
```

Recorded with `ARKDECK_RUST_POST_FLASH_ALIAS_RECORD=/private/tmp/xpa016-alias-oracle-r1`
(`oracle-alias-record.log`: 1 test, 0 failures) and installed as `rust/tests/fixtures/post-flash-alias/`
— 55 files: `cases.json` (the fifteen steps), `provenance.json` (the producer, the root, the
store's file name, lock name, 64 KiB limit and schema version, every file's SHA-256, and
`productionRoot`: where production keeps the store — the parent of the daemon state directory
`ArkDeck/Agentd`, i.e. `<Application Support>/ArkDeck`, pinned from
`ArkDeckAgentFilesystemLayout.applicationSupportRelativeStateDirectory` because the M4 map had
seen the file described under both roots), and the per-step files. A second run in compare mode reproduced every file byte for byte
(`oracle-alias-compare.log`: 1 test, 0 failures). Every fixture path is Windows-safe and no file
names this host, its user or its home.

## What the oracle pins for the Rust store

- The canonical bytes: sorted keys, no whitespace, `/` unescaped, one `0x0A`; the archive's bytes
  are the superseded document's bytes exactly (step 03's archive digest equals step 01's
  document digest).
- The archive name: the alphanumerics of the superseded record's `establishedAtUTC`.
- The lock file exists from the first publication, empty, mode 0600; the document and every
  archive are mode 0600; a same-proof retry and every refusal leave every byte unchanged.
- The three-way publication, the reissue's republished record (`bindingRevision` = the live
  target's, `previousHDCIdentitySHA256` = the stored alias, `establishedAtUTC` = `nowUTC`), and
  the exact refusal details.

## Not run, and why

- No Rust replay yet: the Rust store does not exist; its slice (over the #1939 primitives and
  `arkdeck-contract`'s canonical JSON) replays `cases.json` step by step against these files.
- No production root: the oracle's root is fixed under `/private/tmp` and nothing touches the
  installed `~/Library/Application Support/ArkDeck`; the production root is the parent of the
  daemon state directory (`main.swift` 415–417, recorded as `productionRoot`), which the Rust
  side derives with `arkdeck_application_support_root()` (#1939).
- `covers(target:binding:)` and the facts port's routing refusals (`flash.postFlashHDCBindingConflict`,
  `flash.postFlashHDCAliasLineageReissued`) are not oracled: they are the ArkForge lane's facts
  port, not the store.
