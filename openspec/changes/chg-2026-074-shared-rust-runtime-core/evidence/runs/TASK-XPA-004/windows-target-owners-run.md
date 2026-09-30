# TASK-XPA-004 — Windows Target owners on the daemon, local run on the reference host, 2026-09-30

WM1 slice B1: the Windows daemon composes the Target store and the Target
observation owner (Swift's `DeviceBootstrapMachine` / `TargetObservationCoordinator`
counterpart, the `target.adopt` path) over its state root, so that GJ-1's Target
hops run on Windows up to the point where a registered Windows HDC tuple is
needed. This is a host-only software run. It is not device evidence, not
acceptance and not an HDC registration: no board, no `hdc`, no elevation, and
nothing under `%LOCALAPPDATA%\ArkDeck` was created (every daemon ran over an
isolated development root below the temporary directory).

Checkout: branch `agent/xpa-004-windows-target-owners-20260930`, written on
`origin/main` `d05c9ee3` (#2343), rebased onto `5a880439` (#2348, which brings
#2341's Windows tool dispatch and managed server; nothing here composes them) and
every check below rerun there. Host: Windows 11 Pro 10.0.26200 x64, non-elevated, NTFS;
`rustc 1.98.1`. Inputs: the gate inventory
(`windows-gate-inventory-20260930.md`, G30 over G01/G03/G05, GJ-1 hops 3–4), the
USB census run (`windows-usb-census-run.md`), the NTFS host store
(`../TASK-XPA-005/ntfs-host-store-run.md`), the daemon lifecycle
(`../TASK-XPA-002/windows-daemon-lifecycle-run.md`) and the maintainer rulings
of 2026-09-30 (ruling 11: the hashed USB topology).

## What is composed on Windows now

| Owner | Windows composition | Same as macOS |
| --- | --- | --- |
| Target store (`TargetStore`) | `windows_lifecycle::Authority::compose`: `targets-state` below a development root (the isolated owner's name), `targets` below `%LOCALAPPDATA%\ArkDeck\Agentd` (Swift's production name) | `targets.json` and `target-display-names.json` under `.targets.lock` / `.target-display-names.lock` on the NTFS host store; same bytes (a board adopted in process writes the Swift oracle's `targets.json` byte for byte) |
| `target.list`, `target.show`, `target.availability`, `target.display-name.set\|clear`, `doctor`'s Target check | answered from that store | `Host::target_resource` / `target_store_facts`, one code path |
| Target observation owner (`TargetObservations`), `device.display-name.set\|clear`, `device.observations` following, `target.adopt` | composed; its HDC is none (`Host::hdc_dispatch` answers `None` on Windows) | the same owner and wire answers |
| USB relation reader | chosen by the macOS rule, `development_usb::relation_source(registered, managed, file)`: `UsbRegistryRelations::system()` (the Windows SetupAPI census) only beside a registered HDC the composition started as its managed server | the production composition's `with_trusted_usb` rule; with no Windows HDC registered it reads nothing |

The owner directory is created by a new platform primitive,
`StateRoot::private_child` (Windows): relative to the held root handle, with the
host store's owner-only descriptor (owner and sole grantee the user SID,
protected), flushed; an existing one is never re-permissioned. It is needed
because the account root's DACL (#2337) also grants SYSTEM, which the host
store's private rule (#2338, `others == 0`) refuses, so `HostDirectory::open`
cannot open `Agentd` itself; the Target directory is private on its own. A
Target directory that is not owner-only refuses the start (exit 69, `the Target
store … is unusable …; nothing was started`), never rewritten (ruling 5's rule
for the root, applied to the owner's directory).

## Zero-dispatch refusal without a registered HDC

No Windows HDC tuple is registered (its integration change waits for the
maintainer's samples; `openspec/integrations/**` untouched), so nothing is
observed or dispatched:

- `device.observations`: `rejected`, `hdc.notConfigured` (unchanged, as macOS
  without an HDC).
- `device.display-name.set|clear`: no retained snapshot, `resourceConflict`,
  details `{"phase": "candidateDisplayNameOwner", "newDispatchCount": 0}`
  (unchanged code path, as macOS).
- `target.adopt`: a malformed reference is `invalidInput` (`preAdmission`, 0) as
  before; any other is refused by the Target owner before admission as Swift's
  owner refuses a snapshot it cannot take (the oracle's `adopt.tooMany`):
  `operationUnavailable`, "no registered HDC is selected: nothing was observed or
  dispatched, and no Target was adopted", details `{"phase": "preAdmission",
  "newDispatchCount": 0}`. The CLI reads it as a refusal (exit 69,
  `operationUnavailable`), not as an unknown outcome.

This last answer is **shared with macOS**: `Host::target_adopt` gives it
whenever a Target owner is composed without an HDC (the production composition
without `ARKDECK_HDC_PATH`), where it answered `rejected` "this method is
unavailable in the read-only Rust foundation" without details — which the CLI
could only report as `outcomeUnknown` (exit 75) for a mutation. A composition
without a Target owner (the read-only foundation, the Windows private-endpoint
daemon) keeps `rejected`. `tests/production_composition.rs` (macOS) is updated
to the new answer; it was not run here.

## Gates removed, and gates left

Counted by `cfg` line in the diff: 37 `cfg(target_os = "macos")` lines widened
to `cfg(any(target_os = "macos", windows))` (plus the two Cargo dependency
tables), their 4 `not(target_os = "macos")` fallbacks narrowed to
`not(any(target_os = "macos", windows))` (Linux only), and 6 macOS-only gates
added on members whose one consumer is macOS-only.

Removed on Windows, each after reading why it was there:

| Gate | Why it was macOS-only | Why it can come down |
| --- | --- | --- |
| hoststore `target_document`, `target_owner`, `target_observation`, `device_lane` (+ their exports) | G30 over G01 (host store), G03 (display-name text), G05 (census), G06 (dispatch) | G01 NTFS (#2338), G03 portable text (#2336), G05 census (#2334); dispatch is abstract (`HdcDispatch`) and none is composed |
| hoststore `strict_json`, `session_json::{encode_pretty, pretty}` | only consumed by macOS owners | pure Rust over `canonical_host_text` (portable since #2336) and `foundation_json` |
| hoststore → `arkdeck-provider-hdc` dependency | only macOS owners used it | `target_observation` and `DeviceCandidate` are portable in the provider |
| agentd → `arkdeck-hoststore` dependency | no hoststore owner was composed off macOS | the Target owners are |
| agentd `Host` fields `targets`, `target_observations`, `usb`, `usb_registry`; `with_targets`, `with_usb_registry_relations`, `observe`, `typed_observations`, `target_resource`, `candidate_display_name`, `observations_following`, `target_adopt`, the presentation/expiry parts of `observations`, `doctor`'s Target facts | the owners behind them | composed on Windows; the HDC half is `hdc_dispatch`, `None` on Windows |
| agentd `development_usb` | the isolated owner's relation rule | the rule (`relation_source`) is what the Windows composition decides by; its file reader stays unused on Windows (`allow(dead_code)`) |
| hoststore `target_owner` unit tests | Unix-only fixtures (`mode`, `symlink`) | the fixtures now create the root with `HostDirectory::open_or_create_private` on Windows and use a hard link (NTFS refuses a second name) where Unix uses a symlink; all run on NTFS |

Left, with the reason:

| Still macOS-only | Reason |
| --- | --- |
| `TargetDocument/TargetStore::advance_binding_lineage`, `AdvancedTarget` (new gates) | Rockchip binding lineage (`rockchip_binding`), GJ-4 |
| `TargetStore::resolve_import_binding` and its unit test (new gates) | its one consumer, the Import owner, is macOS-only (G31/G32) |
| `Host::hdc_dispatch` (macOS body) and the `hdc` field, `managed_hdc`, `DevelopmentHdc`, `MeasuredHdc`, `observing` | G06/G07/G17a: no Windows HDC tuple, dispatch or managed server yet (T1 #2341 in flight) |
| `Host::with_usb_relations` | the development relation file, which the Windows development root refuses (`NOT_COMPOSED`) |
| `reconcile_rockchip_startup` over the Target store at start | Rockchip, GJ-4 |
| `owner_census` (macOS form), Job/Artifact/Session/bootstrap-registry owners, `recover_active_jobs` | G31/G32/G17: other slices (H1 journal owners, S3 SQLite) |
| the macOS agentd and hoststore test targets (`tests/target_adoption.rs`, `spawning/target_observation_control.rs`, …) | they drive the shell fake HDC at `/private/tmp`; the Windows counterparts are the two new test files |

## GJ-1 hops observed on Windows

`crates/arkdeck-agentd/tests/windows_target_owners_process.rs`, the real daemon
over a fresh development root seeded with the Swift adoption oracle's
`targets.json` (TGT-3ba3f5f43b92, connect key `aaaa…`), every `ARKDECK_*` and
`OHOS_HDC_*` input removed:

1. start → `arkdeck-agentd owners: targets`; over the pipe `target.list` is the
   oracle's row, `target.show` names `stablePhysicalIdentitySha256` =
   SHA-256(`aaaa…`), `target.availability` the durable binding (presence
   `unresolved`); `target.display-name.set` → generation 2; a stale clear →
   `resourceConflict`;
2. `device.observations` → `rejected` `hdc.notConfigured`;
   `device.display-name.set` → `resourceConflict` / `candidateDisplayNameOwner`
   / 0; `target.adopt` → `operationUnavailable` with exactly
   `{"phase":"preAdmission","newDispatchCount":0}`; `target.adopt {}` →
   `invalidInput`; `targets.json` byte-identical;
3. stop (stop event) → restart: the name is read back (generation 2); clear →
   generation 3; stop → restart: `target.show` has no name at generation 3;
   `doctor`'s `checks.target` = `{"adoptedTargetCount":1,"bootstrapConfigured":false,"configured":true}`;
   `targets.json` still the oracle's bytes (names never touch the binding);
4. a `targets-state` created as an ordinary directory (inherited grants) →
   exit 69, `the Target store … nothing was started`, nothing served or written;
5. **through the real CLI and named pipe against a dev-signed daemon**: a copy
   of the daemon signed with `rust/scripts/windows-dev-identity.ps1 sign` and
   the host-trusted development signer (`ARKDECK_DEV_SIGNER_THUMBPRINT`, read
   from `HKCU\Environment`), the CLI given `ARKDECK_DAEMON_PATH` and
   `ARKDECK_DAEMON_SIGNER_SHA256` as `check-readonly.py`'s signed matrix gives
   them: `target list` (exit 0, the oracle's Target), `target display-name set`
   (generation 2), `target adopt --candidate … --observation … --observation-generation 1`
   → exit 69 `operationUnavailable`, no write; stop, restart: `target show`
   reads the name back, `target display-name clear` (generation 3); stop,
   restart: `target list` has no name at generation 3. Without the variable (or
   with it empty) the test prints `SKIPPED: …` and checks nothing.

The whole file passed 5 consecutive runs with the signer (and the skip path twice
without it). No test sleeps: each waits for the daemon's own lines on a
channel with a 60 s deadline, and each daemon ends by its stop request.

`crates/arkdeck-hoststore/tests/windows_target_owners.rs`, in process over a
private NTFS root, the oracle's device through a scripted HDC (`-v`,
`list targets -v`) and a synthetic node read by the Windows census rule
(XPA-AC-1/2):

- the board is `relationProven` and adopted as TGT-3ba3f5f43b92, revision 1;
  `stable_identity_sha256_for_serial` = SHA-256 of the serial and of
  ` AAAA…\n` alike (trimmed, lowercased); **`targets.json` equals the Swift
  owner's `targets-state/targets.json` byte for byte**; a repeated adoption
  answers the same receipt and writes nothing; a reopened store lists and shows
  it;
- `Unauthorized` → `targetTrustPending` (the trust stop), nothing written;
- a Windows-generated suffix (no serial) → `generationScoped`, adoption
  `admissionDenied`; two boards with the candidate's serial on two ports →
  `generationScoped`, adoption `admissionDenied` with no dispatch; nothing
  written — more than one candidate relation is never selected;
- a byte-prefix `targets.json` → `target.list` and `target.display-name.set`
  `recordUnreadable`, `TargetStore::open` fails, nothing repaired or
  rewritten; `.targets.lock` replaced by a directory → `recordUnreadable`,
  nothing written.

Lock contention on NTFS: the store's own unit tests, now run on Windows —
`concurrent_target_writers_have_one_cas_winner` (one CAS winner, the other
`resourceConflict`) and `overlapping_transactions_wait_for_each_other` (two
owners of one directory wait out each other's `LockFileEx` locks, never
refused, never interleaved) — pass on NTFS.

## Local targeted checks (Windows 11 x64)

| Command | Result |
| --- | --- |
| `cargo fmt --all --check` | pass |
| `cargo clippy --workspace --all-targets -- -D warnings` | pass (Windows build of every crate) |
| `cargo test -p arkdeck-agentd -p arkdeck-hoststore -p arkdeck-provider-hdc -p arkdeck-bootstrap -p arkdeck-cli` | pass; new: hoststore lib 32 (the 9 `target_owner` tests and `device_lane`/`strict_json`/`target_document` now on Windows), `windows_target_owners` 4, agentd `windows_target_owners_process` 3 (the CLI hop skipped without the variable in this run), `development_usb` unit tests now on Windows; `windows_lifecycle_process` 3 still pass with the Target store composed |
| `ARKDECK_DEV_SIGNER_THUMBPRINT=<host signer> cargo test -p arkdeck-agentd --test windows_target_owners_process` | pass, 5 consecutive runs |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 errors, 0 warnings |
| `git diff --check` | clean |

macOS and Linux were not built here. The `cfg` pairings were re-read by hand:
every widened gate is `any(target_os = "macos", windows)` with its fallback
`not(any(…))`; on Linux the hoststore Target modules, the agentd dependency and
every widened `Host` member stay out as before; on macOS the only behaviour
change is the `target.adopt` answer above (and `hdc_dispatch` replacing a direct
`self.hdc` read in `observe`). CI decides.

CLI coverage: unchanged, so `cli-feature-coverage.json` and its oracle hashes
were not regenerated. The Target leaves stay `partial` on Windows (ruling 9):
the owners answer and were measured end to end, but the target contract is not
closed while adoption cannot run without a registered Windows HDC tuple.

## CI

To be recorded, not verified.

## Open questions

1. The `target.adopt` refusal without an HDC changed on macOS too (from
   `rejected` without details to `operationUnavailable` / `preAdmission` / 0).
   It is the Swift owner's own vocabulary and lets the CLI report a refusal
   instead of `outcomeUnknown`; the lead should confirm it rather than a
   Windows-only answer, which would fork the semantics.
2. The account composition now creates `%LOCALAPPDATA%\ArkDeck\Agentd\targets`
   on its first start. It was not exercised on this host (to keep the
   account's product directory untouched); the development root exercises the
   same `private_child` path.
3. `StateRoot` (user + SYSTEM) and the host store's private rule (user only)
   disagree on the account root itself; every Windows host-store owner needs a
   private child of its own (`StateRoot::private_child`) — worth telling the
   H1 (journal owners) and S3 (SQLite) slices.
4. The Target leaves' Windows coverage status stays `partial` until adoption
   runs with a registered Windows HDC tuple; the lead may prefer a finer status
   for `target.list/show/display-name.*` now that their owner is measured.
