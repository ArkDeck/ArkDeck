# TASK-XPA-021 — Trace export and the Trace cache on Windows, local run on the reference host, 2026-09-30

Windows slice W1b (decision 5: capture/inspect/export parity is the supported
threshold). This slice covers Trace export and the Trace cache owner (status,
purge and the host store's trace removal) on Windows. It is a host-only
software run: no board, no `hdc`, no ArkTrace distribution (none exists for
Windows, see `windows-trace-offline-run.md`), no elevation. Nothing under
`%LOCALAPPDATA%\ArkDeck` was created; every daemon ran over a development root
below the temporary directory. It is not acceptance evidence.

Checkout: branch `agent/xpa-021-windows-trace-export-20260930`, **stacked on
#2356** (`agent/xpa-006-windows-artifact-export-20260930` at `bc42a792`, the
Windows Artifact read/export owners, still open). #2356 itself conflicts with
`origin/main` (#2357 in `arkdeck-platform`), so this branch does not merge
`main` yet; it will `git merge origin/main` once #2356 lands. Host: Windows 11
Pro 10.0.26200 x64, non-elevated, NTFS.

## Trace export

`trace export` is the CLI's `artifact export` of the one Trace a diagnostics
capture publishes. The CLI runs `artifact.inspect`, then
`validate_artifact_metadata` and `require_trace_artifact` (source
`capture.diagnostics@1`, name `trace.htrace`, `application/octet-stream`,
`sensitive`), then `artifact.export` and `validate_artifact_export`. Every
piece is already portable after #2356: the NTFS Artifact owner, and the CLI's
Windows destination spelling. Nothing Trace-specific needed porting, and none
of it is changed here.

What is measured (`crates/arkdeck-agentd/tests/windows_trace_export_process.rs`):

- **In process: the owner and the CLI.** The Swift capture oracle's Job
  `job-1c209bf5…` (`rust/tests/fixtures/capture-diagnostics-trace`) is laid down
  as the macOS Runtime published it: a private Artifact root, the index
  owner-only, and payloads sealed. The CLI's own `parse`, Trace rule and
  receipt rule are then run around the NTFS owner's `artifact.inspect` and
  `artifact.export`. Results:
  - The Trace `ART-148c3168…` is exported as `<dest>\ART-148c3168…-trace.htrace`.
  - The exported bytes are the recorded payload, and `artifactDigest` is the
    recorded index `sha256` (T0).
  - The receipt is exactly `arkdeck.artifact-export/1` with `privacy: sensitive`
    and `overwritten: false`.
  - A second export without `--overwrite` is refused and leaves the file as it
    was.
  - Every other Artifact the capture published is refused by the Trace rule
    (`invalidInput`) before anything is exported.
  - The Trace that capture `job-d87e…` recorded missing is refused.
  - Only the one file was exported, and the Artifact store is byte-identical
    afterwards.
- **Through the real CLI against a dev-signed daemon.** `trace export --job
  --artifact --destination --allow-sensitive` exits 69 with `operationUnavailable`
  "Artifact Job owner is unavailable". This is the daemon's Artifact owner
  refusing the inspection, because no Job owner is composed on Windows. Nothing
  is exported, and the store is unchanged.

So the whole Trace export path answers on Windows as on macOS. Through the
daemon it waits only for the Windows Job owner (H2).

## Trace cache owner and trace removal

| Piece | Windows now | Same as macOS |
| --- | --- | --- |
| `arkdeck_platform::PreparedTraceRemoval` (`windows/host_trace_removal.rs`) | new NTFS port | Same capture: bounded (8 levels, 4096 nodes), private, identity-bound to the owner evidence, every regular file digested. Validation compares `(volume, file id)`, and for files also size and write/change times. The quarantine is a POSIX rename that never replaces an entry (`renameatx_np(RENAME_EXCL)`). Removal is leaf-first and refuses a non-empty directory. |
| `trace`, `trace_maintenance`, `trace_owner` (`TraceCacheStore`, `trace_inventory`) | built on Windows (`cfg(any(macos, windows))`), unchanged | the same code |
| `Host::trace_cache`, `with_trace_cache`, `trace_cache_status` | built on Windows | one code path |
| `Host::trace_cache_purge` | Windows form: refused `rejected` "Trace cache owner is not configured" | The macOS answer without its Job owner. Only the Job owner proves that no Session still needs the derived data. |
| Composition | a development root only: `trace-cache` (a `StateRoot::private_child`) with private `traces` and `staging`, the macOS isolated owner's layout | the account's daemon composes none (below) |

Windows-specific behaviour, measured rather than assumed:

- **Rename with open handles.** NTFS refuses to rename a directory while any
  handle is open inside it (checked with a plain Python open as well). The
  quarantine therefore:
  1. releases the moved tree's held directory handles;
  2. renames through a DELETE handle whose identity was compared first;
  3. flushes the parent;
  4. opens every directory of the moved tree again, parents first, each
     required to be the captured directory, then validates the whole tree
     again.
  A failed rename reopens the tree the same way before it returns.
- **Removal.** Each entry is deleted through a handle opened relative to its
  held parent, without following a reparse point, and compared with the
  capture just before the POSIX delete. Unix unlinks by name after a
  comparison.
- **Ancestor rename.** Unix lets a prepared tree's ancestor be renamed away,
  and then the quarantine refuses. On NTFS the rename of the ancestor is itself
  refused while the prepared removal holds handles inside it, so that unit test
  asserts the refusal (`a_prepared_tree_s_ancestor_cannot_be_moved_away`).

Unit tests on NTFS:

- `arkdeck-platform` `windows::host_store::trace_removal`, 5 tests:
  - quarantine and removal keep a replacement at the original name, and keep
    the neighbour;
  - a junction, a hard link, a file anyone may read (`icacls /grant
    *S-1-1-0:R`), or a wrong identity refuses before quarantine;
  - changed bytes or membership refuse;
  - the ancestor case above;
  - a fault after the first unlink leaves an owned residual.
- `arkdeck-hoststore` `trace_maintenance::tests`: all 6 Unix tests, with
  fixtures ported to a private scratch root whose DACL every entry inherits:
  - ready purge;
  - retained Jobs or Artifacts;
  - each lock or lease protecting the entry;
  - unbound owner evidence;
  - the four fault boundaries with a replacement preserved;
  - private Session recovery.

Daemon (same test file):

- The start reports `arkdeck-agentd owners: targets, artifacts, traceCache`.
- `trace.cache.status` answers the empty cache (`entryCount 0`,
  `totalByteCount "0"`).
- After a stop and a derived entry laid down in the macOS layout (key lock,
  lease, owner record bound to the entry's identity), the restart counts it:
  `entryCount 1`, `inactiveEntryCount 1`.
- `trace.cache.purge` is refused `rejected`, and the cache is byte-identical
  afterwards.
- A parameter is `invalidParams`.
- A `trace-cache` created as an ordinary directory refuses the start (exit 69,
  "the Trace cache … nothing was started").
- Through the dev-signed CLI:
  - `trace cache status` exits 0.
  - `trace cache purge` exits 75 `outcomeUnknown` (`wireCode: rejected`). The
    CLI reads a mutation's `rejected` without a pre-admission proof as an
    unknown outcome, exactly as on macOS for the same answer. See open
    question 2.

## Left out

- **The account daemon's Trace cache.** On macOS the production daemon reads
  the App's cache in the App container
  (`~/Library/Containers/…/Caches/ArkDeck/Trace/traces`) and never creates it.
  The Windows App's cache location (MSIX package cache, or
  `%LOCALAPPDATA%\ArkDeck\…`) is not decided, so the account's daemon composes
  none, and `trace.cache.*` there keeps "Trace cache maintenance is not
  configured".
- **A real purge through the daemon.** It needs the Job owner's active-Session
  census (H2) and the Artifact owner's Trace retention census.
- **ArkTrace loader, `trace_streamer`, capture.** Unchanged: no Windows
  distribution exists, and capture needs a registered Windows HDC tuple.
- **CLI coverage.** Unchanged (Trace entries stay `partial`, ruling 9).

## Local targeted checks (Windows 11 x64)

| Command | Result |
| --- | --- |
| `cargo fmt --all --check` | pass |
| `cargo clippy --workspace --all-targets -- -D warnings` | pass (exit 0) |
| `ARKDECK_DEV_SIGNER_THUMBPRINT=<host signer> cargo test -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli` | pass (exit 0) |
| `cargo test -p arkdeck-agentd --test windows_trace_export_process` with the signer | 4 passed, 3 consecutive runs |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

New tests: platform `trace_removal` 5, hoststore `trace_maintenance` 6 (now on
NTFS), agentd `windows_trace_export_process` 4.
`windows_target_owners_process` was updated for the census line.

macOS and Linux were not built here; the `cfg` pairings were re-read by hand:

- The macOS bodies are untouched.
- The Windows purge is a separate `cfg(windows)` function.
- The trace maintenance test fixtures keep the Unix `mode` calls under
  `cfg(unix)`.
- Linux builds none of the widened modules.

CI decides.

## Open questions

1. **Merging `main` later.** When #2356 lands and this branch merges `main`,
   #2360's `windows_trace_offline_process.rs` expects `trace.cache.status` and
   `trace.cache.purge` to be refused `rejected` over a development root without
   the cache owner. It must be updated in that merge: status now answers, and
   purge keeps `rejected`.
2. **Purge through the CLI.** Without the Job owner, `trace cache purge` reaches
   the CLI as `outcomeUnknown` (exit 75) on both OSes, because the daemon
   answers `rejected` without details. A pre-admission refusal with zero
   dispatch would let the CLI report a refusal, as was done for `target.adopt`
   in #2350. That would change macOS too, so it is left to the lead.

## Merge with #2356 and main (conflict resolution)

The lead asked for every conflicting PR to be resolved now, so this branch no
longer waits for #2356 to land. It merged #2356's head `03cf3384`, which
already carries `main` up to #2366, and then `origin/main` `97793944`.

- The Windows daemon now composes, in the macOS census order: `targets`,
  `artifacts`, `workspaceProjects` (#2366) and `traceCache`. The Trace cache
  is composed in a development root only. The owner census line of the
  Target, workspace and trace tests follows.
- In `arkdeck-platform`, the import-upload (#2357) and trace-removal
  submodules are exported side by side.
- #2360's `windows_trace_offline_process.rs` now expects `trace.cache.status`
  to answer the empty cache in a development root. `trace.cache.purge` is
  still refused `rejected` with no details. This is open question 1 above,
  now done.
- **Still to do:** switch the Windows `trace_cache_purge` to
  `TraceCacheStore::purge_unavailable()` (ruling 18) once #2370 is on `main`.
  Until then the Windows purge keeps the pre-#2370 `rejected`, the same answer
  `main`'s macOS daemon gives today.

Checks after the merges, all on the Windows 11 x64 reference host:

- `cargo fmt --all --check`: pass.
- `cargo clippy --workspace --all-targets -- -D warnings`: exit 0.
- `cargo test -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli`,
  with the development signer: exit 0. The Windows process tests all pass:
  artifact 3, target 3, trace export 4, trace offline 2, workspace 3.
- `generate-contract.py --check` and `generate-clientkit.py --check`: pass.
  The contract is untouched.

## CI

To be recorded, not verified.
