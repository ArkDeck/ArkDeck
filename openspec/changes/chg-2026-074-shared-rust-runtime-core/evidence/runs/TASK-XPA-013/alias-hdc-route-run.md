# TASK-XPA-013 — the canonical alias HDC route (macOS, 2026-09-19)

TASK-XPA-013 remains in progress. Base: protected main `3e95ac6d` (#2041); written on `2af5c806`,
rebased without conflict onto `28605092` (#2039, the retention sweep, where the checks below ran)
and then onto `3e95ac6d`. The last two main commits (#2041, #2042) change only Swift test
fixtures and `agentd/tests/managed_hdc_process.rs`, which this slice does not touch. No stack. Host-only change: no device, real HDC, installed state or Swift
daemon was used, and nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No Swift
source, control schema, corpus, Catalog, entitlement, `openspec/specs` or constitution change.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (TASK-XPA-013) |
| --- | --- | --- |
| Import upload with the Target owner's binding for Targets without an alias (#1881, #1969); Target alias history decoded and validated (TASK-XPA-012); Target observation and adoption (#1959, #1966); Import commit, leases and release (#1983, #1987) | Swift's `hdcExecutionRoute` for a Target with a proven post-Flash alias: the live candidate list each reading publishes, the route it selects, and the HAP and native-library Import binding that follows it | The publish crash-window matrix; owner activation at M5; GJ-1/2/3 re-pass |

## Why

A Flash can leave a device answering HDC under a new address. Swift then records an alias
resolution: the new address's Target is proven to be the canonical Target (`appendAliasResolution`).
From then on Swift addresses the canonical Target through `RuntimeTargetStore.hdcExecutionRoute`.
The Rust owners refused every such Target: an HAP or native-library Import was
`operationUnavailable`, and every HDC Job on it failed planning ("not resolved by the Rust Runtime
yet"). The installed Runtime's DAYU200 has been flashed repeatedly (GJ-4), so at the M5 cutover its
Target document can carry exactly such a resolution. GJ-2 and GJ-3 on it would then be refused.

## What changes

- **The route** (`TargetDocument::hdc_route`, `arkdeck-hoststore` `target_document.rs`), as Swift's
  `hdcExecutionRoute` in `DeviceBootstrap.swift`:
  - no Target: none; two with the ID: `storeFailure("HDC execution target is ambiguous")`;
  - no resolution names the Target canonical: its adopted key;
  - two do: `storeFailure("HDC execution route is ambiguous")`;
  - one does: the alias Target must be the one the resolution proved (its identity, its revision,
    and the SHA-256 of its connect key as the routed identity), else
    `storeFailure("HDC execution route lacks its proven alias target")`;
  - with a fresh live candidate list, the sole `Connected` key among the Target's own and its
    alias's. None, or both, is `observationFailed("fresh HDC observation found no Connected proven
    route…")` or `…multiple Connected proven routes…`;
  - without one, the alias's key, as Swift does before its first observation and for host-only
    Artifact binding.

  The route keeps the canonical Target's ID, revision and tool version.
- **The live candidate list** (`TargetStore::record_live_candidates`, `hdc_route`): memory-only,
  fresh for five seconds (Swift `routeObservationFreshnessSeconds`). It holds every candidate's key
  and state from the last completed reading, which `TargetObservations::stamp` now publishes, as
  Swift's `TargetObservationCoordinator` calls `recordLiveHDCCandidates`. It cannot create,
  rewrite or widen a Target or an alias.
- **Import binding** (`TargetStore::resolve_import_binding`), as Swift's
  `RuntimeImportControlHandler.binding`: an HAP or native-library Import binds the canonical
  Target's revision and the identity the route's key names (the SHA-256 of the key lowercased,
  `HDCObservationProviderAdapter.stableIdentitySHA256`). A route Swift cannot resolve lands in its
  handler's generic refusal, `recordUnreadable` ("Import state or immutable content is
  unreadable"). Commit recomputes the binding as Swift's does, so an Import whose route changed
  between begin and commit keeps Swift's `resourceConflict`. Workspace-patch and flash-bundle
  bindings are unchanged.
- **HDC Jobs** read the same route through `TargetStore::hdc_route` (device facts, agent runs):
  a Target with a proven alias is planned and dispatched through it, no longer refused.
- `rust/README.md`: the Target section's route sentence, in place.

## Declared differences from Swift

1. **Where readings come from.** Swift's daemon also publishes the live list from its continuous
   Bootstrap candidate monitor, so its list is almost always fresh. The isolated Rust daemon has no
   monitor: only a completed `device.observations` or adoption reading publishes it. Between
   readings, a proven-alias Target is therefore routed through its alias's key, as Swift routes it
   before its monitor's first reading.
2. **Clock.** Freshness is measured on the monotonic clock; Swift compares wall-clock dates and
   also refuses an observation from the future. Only a wall-clock jump separates them.
3. **T2.** Error texts follow Swift's interpolation of `BootstrapError`.

## Tests

| Test | What it proves |
| --- | --- |
| `target_document::tests::a_proven_alias_routes_the_canonical_target_as_swift_does` | The vectors of Swift's `testProvenAliasResolutionUsesOnlyFreshConnectedOwnedRouteAndPreservesHistory`: the alias's key without a reading. A fresh reading's sole Connected key wins, whichever of the two it is, ignoring other devices. Both Offline, only foreign devices, or none is Swift's "no Connected proven route"; both Connected is "multiple". An alias Target keeps its own key; an unknown Target has no route |
| `…::an_alias_target_the_resolution_did_not_prove_fails_closed` | An alias Target whose key, identity or revision drifted, or that is gone, lacks its proven alias. Two resolutions make the route ambiguous; two Targets with one ID make the Target ambiguous |
| `target_owner::tests::the_route_follows_a_fresh_live_observation_and_falls_back_once_it_is_stale` | Over Swift's own alias document (`import-target-current/alias`): the alias's key, then the canonical key once a reading shows it Connected, the alias's again once the reading is older than five seconds, a refusal when both are Offline, and no reading after a reopen |
| `target_owner::tests::hdc_imports_bind_the_identity_the_route_names` | HAP and native-library bind the canonical Target, revision 2 and the alias key's identity; after a reading, the canonical key's. With both Connected they are `recordUnreadable` in phase `importOwner`. Workspace-patch keeps its null binding |
| `tests/import_target.rs::native_alias_routes_hdc_imports_through_the_proven_alias_and_keeps_other_kind_semantics` (replaces the test that pinned the refusal) | On the same Swift document, every kind binds the canonical Target. HAP and native-library carry the resolution's routed identity |
| `tests/target_adoption.rs::a_reading_routes_a_proven_alias_target_to_its_connected_key` | Through the real observation owner over the shared fake HDC: before a reading an HAP Import binds the alias's identity. Once a reading lists the canonical key Connected, it binds that key's |

## Local targeted checks

Run again on the head rebased onto `28605092`, which brings #2039's changes to both crates. The
same checks passed on `2af5c806` before the rebase (435 tests). Logs are under this session's
scratchpad `logs/`. `arkdeck-soak` is the one other crate that depends on `arkdeck-hoststore`.

| Command | Exit | Log SHA-256 |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | `e3b0c442…` (empty) |
| `CARGO_BUILD_JOBS=2 cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets --locked -- -D warnings` | 0 | `93e438e6…` |
| `CARGO_BUILD_JOBS=2 cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --locked`: 58 test binaries, 445 passed, 0 failed, 12 ignored | 0 | `df824f14…` |
| `ARKDECK_PYTHON=<repo>/.venv-sdd/bin/python sh scripts/check-sdd.sh`: 0 errors, 0 warnings | 0 | `77c17376…` |

A first clippy run refused the live list's type as too complex. It is now a type alias; nothing
else changed.

## CI

The PR's CI (`guard` + `swift`) is the unified gate; its run ids and conclusion are recorded by the
next slice or a documentation follow-up.

## Not run

Any device, real HDC, installed Runtime or Swift daemon. No Rust owner writes alias resolutions;
they come from Swift's Flash lane (M4).
