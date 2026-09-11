# Isolated Rust Session export owner

`session.export.preview` and `session.export.apply` now run through the isolated
Rust daemon and CLI. The current Swift CLI consumes both replies, and its
existing record store reads the actual Rust ready and applied records.
Installed activation, maintainer approval and remaining TASK-XPA-012 work are
incomplete. Cleanup apply is a separate unfinished path.

## Implemented behavior

The preview reads the exact selected Session under the configuration/catalog
locks and binds canonical Manifest and optional Journal digests, root/leaf
filesystem identity, the sensitive-content choice, destination-parent identity
and catalog accounting. Located unrelated unknown Sessions are disclosed;
selected corruption, duplicate identity and unplaced content refuse.

Apply requires the exact preview tuple. An applied record returns its saved
result without re-entering export; an applying record reports `outcomeUnknown`.
Ready records require an unexpired preview and fresh matching source,
destination and catalog facts. Applying is durably written before staging.
Only mechanically known prepublication failures restore ready. Publication or
postpublication uncertainty preserves applying and blocks replay across restart.
The complete snapshot is compared before and after publication.

The content plan excludes raw/partial Artifacts by default and preserves source
bytes. It discovers device identities, scrubs manifest references, preserves
schema/digest fields, creates valid identifier/path pseudonyms and rehashes
workflow/compensation/recovery arguments. Missing derived dependencies produce
diagnostic records; retained dependencies get typed provenance based on the
exported source hashes. Final Artifact records and the complete manifest are
revalidated before publication.

Redaction uses bounded 64 MiB buffers; identity-free files can exceed that limit
and stream through a fixed 64 KiB buffer. Original size, digest, inode/link and
timestamps are checked. The growth bound is 16 MiB plus max(source bytes, 64 MiB)
per included Artifact, with 64 KiB metadata and 64 KiB finalization headroom.
Capacity comes from the held destination-parent descriptor.

Staging uses new private directories and exclusive file creation. Inventory,
inodes, hashes, volume and parent binding are rechecked, and publication uses
`renameatx_np(RENAME_EXCL)` plus synchronization. A failed write poisons the stage.
Failed-attempt cleanup only removes entries created by that staging instance;
substituted or untracked entries are preserved. It cannot reopen existing
Sessions as cleanup targets.

## Verification

- All 55 host-store tests and all 15 CLI unit/integration tests passed.
- Twelve platform export tests and the capacity-boundary test passed, including
  a source larger than 64 MiB, checksum failure, unsafe links, late destination
  creation, parent/file replacement, untracked content and growth exhaustion.
- Owner tests verify durable idempotency after restart/source-result movement,
  exact retry after known prepublication refusal, and no replay after actual
  publication followed by a clock failure. Stale digest, expiry and existing
  destination refusals leave ready records unspent.
- Three complete Rust manifest outputs match actual Swift exports byte-for-byte:
  default sensitive exclusion and both derived-source privacy choices.
- `check-session-export.py` passed against the rebuilt Rust daemon with the Rust
  CLI and current Swift CLI: 15 actual control exchanges plus CLI calls per run,
  including incomplete-catalog disclosure, apply, restart, repeat apply,
  sensitive inclusion and preservation of source bytes.
- `check-session-cleanup.py` passed again after the shared lock-helper change:
  ten control exchanges plus CLI, without invoking cleanup apply.
- `SessionCleanupContractTests.testCurrentSwiftOwnerReadsActualRustExportAppliedRecord`
  passed. The actual applied record decodes and canonically re-encodes to the
  identical bytes in the existing Swift record store; the ready record was
  verified by the corresponding preview-record test.
- Rust daemon/CLI builds, Clippy for daemon/CLI/host-store, protocol generator
  checks and diff checks passed.

The candidate contract runner includes the process checks. The export apply
schema/corpus combines the existing Swift frames with actual Rust exchanges.
This product slice leaves the published input pin unchanged; its dedicated
baseline update was merged separately as PR #1846.

## Fixture provenance

The `swift-export-*` fixtures were captured from the existing Swift
`testTEST_AC_ART_006_01_defaultDiagnosticExportExcludesDeviceRaw` test. The
`swift-derived-*` fixtures were captured from
`testDefaultDiagnosticExportClosesExcludedRawDerivedLineage`, including an
additional sensitive-inclusion export with identifier redaction. Both tests
passed, and temporary capture code was removed. The `rust-export-*` records
were copied directly by the actual process harness, without re-encoding.

All inputs are newly created simulated host Sessions, never device acceptance
or installed-owner evidence. Fixture SHA-256 values:

- `swift-export-source.json`: `7bacb701ec48f180e69dbaab4f81145bd38eeaa9eafcd7f5d6b189fd10d7a554`.

- `swift-export-result.json`: `89da785482d787c009af4a7ba8f8b7e1fa5b53efec3ab1249d5fb6c6f89fc325`.

- `swift-derived-source.json`: `9ce9f8f336753f8eb774e4a094d32ef228f9109b7b839674b07f4079a49868c2`.

- `swift-derived-default.json`: `dc09c2732854a159a3f908c268b9521b393cb0a382b827ca85964f3c10e5af43`.

- `swift-derived-sensitive.json`: `3f40a3539a53162c9b342d7d50fea02453c2a6be57b86e167296b4e770d823e8`.

- `rust-export-ready.json`: `d069c44c42fb6363103aa9284f2876cb57b2fe2fbdf291fe0b86009abe193211`.

- `rust-export-applied.json`: `7c88da5a3223ad3f5fbef5094a5e1b8508f356eee6cd55cc96fb2dce4a4443cd`.

## Mainline integration — 2026-09-11

The existing implementation was rebased without conflicts onto approved main
`f9f38a2473308195978fc536f5b83efc9d47f5b3` after PR #1844. The host-store and
CLI tests passed again, and the rebuilt Rust daemon passed export preview/apply
and cleanup preview with both Rust and current Swift CLI consumers. These runs
exercise actual processes and newly created host data. No installed state or
existing Session was changed.

PR #1846 merged as `b3fe9a7bfbfb9a4ef211f4c642bd6f96b3553da5`; this slice was
rebased onto it. The final unified CI plan passed: common checks, all Swift lanes,
Rust formatting/Clippy/tests, published and candidate contract checks, actual
owner/CLI exchanges, cargo deny and cargo vet (26 fully audited).

The first full run exposed missing SessionStorage fixtures in isolated contract
builds. Rust tests now carry exact copies under `rust/tests/fixtures/session-export`;
the source-checkout process check compares them byte-for-byte with the Swift
captures. This fixes packaging without changing fixtures or test expectations.
Both isolated contract views subsequently compiled and passed.

Final command:

```sh
python3 scripts/ci/plan.py --repo-root . --base-revision origin/main \
  --head-revision HEAD --merge-base --include-worktree --run-local
```

The local invocation used Python with CI-pinned PyYAML/jsonschema installed.
No installed activation, cleanup apply or hardware acceptance is claimed.

Reproduce the process checks after building the Rust binaries:

```sh
python3 rust/scripts/check-session-export.py
python3 rust/scripts/check-session-export.py --cli-path /absolute/path/to/current/swift/arkdeck
```
