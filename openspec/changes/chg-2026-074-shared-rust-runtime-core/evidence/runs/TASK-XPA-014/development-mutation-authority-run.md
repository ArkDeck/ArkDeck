# TASK-XPA-014 — the isolated owner's development mutation authority (macOS, 2026-09-20)

TASK-XPA-014 remains in progress. Base: protected main `5205b3ec` (#2075). Host-only change to
`arkdeck-agentd`: no Swift source, control schema, corpus, Catalog, entitlement, `openspec/specs`
or constitution change, and no change to `arkdeck-hoststore`. No device, real HDC or installed
state was used in this slice, and nothing here is device evidence (POL-VERIFY-001, POL-MODE-001).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (TASK-XPA-014) |
| --- | --- | --- |
| The isolated development owner with its managed development HDC (TASK-XPA-016) and the GJ-1 opt-in for development USB relations beside a registered HDC (#2023, #2024) | The isolated owner proves a device mutation's state continuity against its own Job state, acknowledged and only beside its managed development HDC | GJ-2 on the real device (runbook §3), GJ-3 (runbook §4), both first over the fake HDC; debug.hap slice F; M5 activation |

## Why

A device mutation is admitted only where `RuntimeStateContinuity` can be proved
(`arkdeck-hoststore` `mutation_state_continuity::require_mutation_state`), and that proof is
anchored at the Runtime's own state root: the installed
`Library/Application Support/ArkDeck/Agentd`. The isolated development root is not that root, so
the gate's first comparison refuses, and every device mutation there was refused whatever the
caller held. The GJ-1 preflight recorded it as its own blocker (#1994), and M2's real-device
acceptance, GJ-2 and GJ-3, cannot run without it.

The maintainer decided on 2026-09-20 (relayed by the coordinating session at 15:05) that the M2
real-device acceptance root is handled as the GJ-1 opt-in of 2026-09-19 was, option A: the isolated
owner may take a development mutation authority through an explicit acknowledgment, what it then
proves about the real device is development-root evidence, never `REAL_DEVICE_PASS`, and the
dashboard's Golden Journey count does not move.

## What changes

- `development_mutation.rs`, new in `arkdeck-agentd`: `ACKNOWLEDGMENT`
  (`ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY`, whose one value is `acknowledged`) and `admit`, which
  takes the authority only with an isolated development state root and the development HDC started
  as this owner's managed server, and refuses the acknowledgment in every other composition so
  that it never stands unused in a configuration.
- `main.rs`: the standalone daemon and the facade refuse the acknowledgment before anything is
  served, as they refuse the GJ-1 one. In the development composition, an admitted authority
  anchors the proof at `<development root>/jobs-state`.
- `host.rs`: `Host::with_development_mutation_root`, which sets the root the authority carries.
- `rust/README.md`: a paragraph after the managed development HDC's.

## Declared difference from the instruction's wording

The instruction named `mutation_state_continuity::require_mutation_state` as the place to carry the
development authority. It is carried in the composition instead, and the gate is untouched, because

- `arkdeck-hoststore` reads no environment and knows no mode; a development opt-in inside it would
  be the first, and the GJ-1 opt-in (#2023) is composed the same way, in `arkdeck-agentd`;
- every existing case of the gate, negative or not, is then unchanged by construction, and so is
  the refusal a development root without the acknowledgment still gets;
- what the ruling grants is exactly the anchor: which root the proof is made against. Everything
  the proof itself refuses, it still refuses.

If the coordinator wants the decision inside the gate instead, it is a small move and this slice's
tests carry over.

## What stays refused

- The acknowledgment without the managed development HDC server, outside an isolated development
  root, in the standalone daemon and in the facade: startup fails, exit 69, before any server
  starts.
- Any value of the acknowledgment other than `acknowledged`.
- Anchored at the development root, the proof still refuses recorded authorization usage beside
  that root, a Job history that is not read-only, and an unsafe, foreign or unreadable Session
  root.
- A device mutation still needs its capability and this daemon's device hold; nothing here grants
  either.

## Tests

| Test | What it proves |
| --- | --- |
| `development_mutation::tests::the_development_authority_is_taken_only_as_the_acknowledgment_names_it` | The seven compositions of (development root, managed server, acknowledgment): without the acknowledgment nothing changes; with it only the isolated root beside the managed server takes the authority, and every other composition refuses startup |
| `development_mutation::tests::the_acknowledgment_has_one_value` | `acknowledged` and nothing else, unset included |
| `host::tests::the_development_mutation_root_is_the_root_the_isolated_owner_proves` | Over a real Job owner in a temporary root: the authority's root is the installed Runtime's and the proof refuses (`recordUnreadable`); with the development root taken, the same proof passes; recorded authorization usage beside the root and a Session root that is a link out of it still refuse it, and it passes again once they are gone |
| `tests/managed_hdc_process.rs::the_development_mutation_authority_is_acknowledged_only_as_named` | Real `arkdeck-agentd` processes: a wrong value, the acknowledgment without the managed server, and the standalone daemon each exit 69 with their own message and start no server; the one composition the acknowledgment names serves `health` with its managed server and stops with exit 0 |

## Local targeted checks

| Command | Exit | Log SHA-256 |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | `e3b0c442…` (empty) |
| `CARGO_BUILD_JOBS=2 cargo clippy -p arkdeck-agentd --all-targets --locked -- -D warnings` | 0 | `b09ac141…` |
| `CARGO_BUILD_JOBS=2 cargo test -p arkdeck-agentd --locked`: 7 test binaries, 51 passed, 0 failed | 0 | `e0eaf8a6…` |
| `ARKDECK_PYTHON=<repo>/.venv-sdd/bin/python sh scripts/check-sdd.sh`: 0 errors, 0 warnings | 0 | `77c17376…` |

`arkdeck-agentd` is the only crate this slice changes and nothing depends on it.

## CI

The PR's CI (`guard` + `swift`) is the unified gate; its run ids and conclusion are recorded by the
next slice or a documentation follow-up.

## Not run

Any device, real HDC or installed Runtime: GJ-2 and GJ-3 follow in their own slices, each first
over the fake HDC and then on the real DAYU200, and each records development-root evidence.
