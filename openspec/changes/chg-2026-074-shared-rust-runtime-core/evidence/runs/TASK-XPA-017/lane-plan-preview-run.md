# `flash.lanePlanPreview` on the Rust Runtime, up to the lane (TASK-XPA-017, M4-3b)

Swift answers `flash.lanePlanPreview` in two parts:

- **The handler** (`AgentDaemon.swift` 472-535):
  - It checks three string parameters: the one supported profile, and 64
    hexadecimal characters as Swift's `Character` reads them.
  - It needs a Target store, and finds the Target in it.
  - Without a lane it answers `laneNotComposed`.
- **The previewer** (`main.swift` 1377-1409), which Swift composes only with
  an ArkForge lane:
  - It resolves the Target's facts through the ArkForge provider.
  - It requires a confirmed HDC-normal USB topology among those facts.
  - Only then does it ask the lane: `arkforged` is asked, over its
    controller session, whether its store holds the archive and what plan
    it would materialize.

Until now the Rust daemon routed none of this and refused the method as
unavailable.

The Rust daemon now answers every state Swift reaches before the lane, as
Swift answers it. Both Rust compositions compose the previewer only with a
lane; the production composition is written but not activated. The states:

- `invalidParams`.
- The missing Target store (`internalError`).
- An unadopted Target (`notFound`).
- `laneNotComposed`.
- `deviceNotObserved`: facts that cannot be resolved, including an ArkForge
  provider composed without its facts port, or no confirmed topology.

The facts come from the same port as `flash.prerequisites` (M4-1b). They are
measured over the same HDC, with the same calls.

Where Swift asks the lane, this Runtime stops. Its ArkForge client has
neither controller call yet: this is the upstream change that awaits the
maintainer. It answers `previewFailed` with the reason. Nothing is sent to
`arkforged`, and the answer never reads as an available plan.

The App ingress admits the method with its three closed parameters, as
Swift's App transport forwards it (`AgentXPCContract.forwardableReadOnlyMethods`).
Every published method is now routed: 105/105.

| Already on `main` | This change | Still remaining (M4) |
|---|---|---|
| The CLI leaf `flash lane-preview` (#2168). The facts port and `flash.prerequisites` (M4-1b), the lane's composition (M4-2b) | The handler and the previewer up to the lane; the App ingress; the oracle's preview exchanges | The lane's preview itself, and SPK-9: both wait for the upstream ArkForge client change (controller-side inspect and materialize), as do the Flash admission and run |

## The oracle

`FlashHostFactsOracleContractTests` (M4-1b) already walks the facts through
some twenty states for `flash.prerequisites`. It now asks
`flash.lanePlanPreview` in each of those states, right after
`flash.prerequisites`. Before any Target is adopted, it also asks with each
refused parameter and with each composition. That adds 34 exchanges, for 74
in all. The 40 exchanges already recorded are unchanged apart from their
index. `inputs/`, `hdc`, `hdc-answers.sh` and `provenance.json` are
byte-identical.

- **The previewer.** The daemon declares it inside its composition, so the
  test cannot reach it. The test copies it (`ComposedLanePlanPreviewer`) over
  the ArkForge provider adapter and the same switching facts port as the
  prerequisite observer. So the probed and unprobed states apply to both.
- **The lane.** An `ArkForgeLaneHost` over a scripted daemon whose store
  never holds the archive. Swift's preview therefore stops at its first
  call. Each preview exchange records the calls the lane received
  (`laneCalls`) and the composition that answered it:
  - `lane`, the one every other exchange uses;
  - `noLane`;
  - `noTargetStore`;
  - `noFactsPort`: an ArkForge provider composed without its facts port.
- **The requests** are ones the published request schema admits, as the
  oracle's rule has it:
  - no parameters;
  - an unsupported profile;
  - 63 digits;
  - a non-hex character;
  - uppercase digits, and fullwidth digits (both taken by Swift's handler);
  - the digest uppercase through the lane. This pins that Swift lowercases
    it before asking.

What Swift answered:

| Exchanges | Answer |
| --- | --- |
| 4 | `invalidParams` |
| 1 | `internalError` "lane plan preview is not configured" |
| 2 | `notFound` |
| 3 | `laneNotComposed`, for a lowercase, an uppercase and a fullwidth digest |
| 16 | `deviceNotObserved`: every facts refusal of the prerequisites' states, with its reason (the RockUSB identity, the binding's mode, schema, snapshot and lineage, and each post-flash alias conflict); the provider without its facts port; and the states with no confirmed topology |
| 8 | Swift asked the lane: `bundleNotInLaneStore`, after one `inspectArtifact` call with the digest in lowercase |

The Rust replay (`arkdeck-agentd` `tests/spawning/flash_host_facts_control.rs`)
composes each exchange's Host as named and compares every answer.

- The 26 exchanges that stop before the lane match Swift's byte for byte,
  with the HDC calls each made.
- The 8 that reach the lane are the declared difference (below): they have
  the same Target, the same revision and the same HDC calls.

## Declared differences

- **The lane's preview.** Swift asks `arkforged` in these 8 exchanges. This
  Runtime answers `previewFailed` with "this Runtime cannot ask arkforged for
  the lane plan yet: its ArkForge client has no controller-side archive
  inspection or plan materialization; nothing was sent to arkforged". It
  fails closed: no preview reads as available, and nothing reaches
  `arkforged`. The upstream client change (branch
  `client-controller-inspect-discover-import`, awaiting the maintainer)
  replaces this with the lane's own answer.
- **An unreadable Target store.** Swift answers `rejected` "lane plan preview
  could not resolve the target: \(error)". Rust answers Swift's
  `storeFailure("undecodable target store: …")`, as `flash.prerequisites`
  already does (M4-1b). Inside the parentheses is this Runtime's decoding
  message, not Foundation's. Neither oracle records such a store.

## Tests

| Test | What it holds |
| --- | --- |
| `flash_host_facts_control.rs` `the_rust_daemon_replays_the_swift_flash_host_facts_oracle` | All 74 exchanges, and the files the reads left. The 26 previews that stop before the lane match Swift's byte for byte, with Swift's HDC calls. The 8 that reach the lane answer the declared `previewFailed` with Swift's Target and revision, and there are exactly 8 |
| `flash_host_facts_control.rs` `a_host_without_the_facts_answers_as_swifts_daemon_without_its_observers` | A host without a Target store answers "lane plan preview is not configured" for any digest Swift takes (fullwidth, uppercase). Seven parameter sets are refused before any owner: a missing digest, a wrong profile spelling, non-string values, 65 characters, a fullwidth `g`, a combining mark |
| `flash_host_facts_control.rs` `members_swift_ignores_change_neither_the_reads_nor_the_answers` | A preview with members Swift ignores (`planId`, `usbTopology`) answers as without them and calls no HDC |
| `app_ingress/flash_facts_tests.rs` `the_app_previews_one_archive_for_one_target_and_names_nothing_else` | The App's request reaches the shared Control, and the local socket answers the same bytes. It is refused when any of the three parameters is missing or not a string, or when a topology or bundle path is added. A digest Swift's handler refuses is refused by the shared Control. Other users, other processes and the console are refused |
| `flash_lane_preview.rs` (hoststore) `the_preview_stops_where_swift_asks_the_lane` | A facts error, a missing or an empty topology, and the declared stop |
| `read_only.rs` (control), `check-readonly.py` | The standalone daemon: `invalidParams` without parameters, and `internalError` "not configured" with them |
| `app_ingress/tests.rs` `rejected_origins_methods_frames_and_parameters_never_enter_control` | `flash.lanePlanPreview` is among the methods the App may call. Every method outside that list is still refused before Control |

## Local targeted checks

Run on this branch, whose tree is `main` `6a838403` plus this change. Logs
are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| Swift oracle, recorded | `ARKDECK_RUST_FLASH_HOST_FACTS_RECORD=<fresh> run-swiftpm.sh test --filter FlashHostFactsOracleContractTests` | exit 0 (`arkdeck-m4-lpp-swift-record2.log`); the first attempt lacked two ArkForge imports (`…-record1.log`) |
| Swift oracle, replayed | the same without the record variable, twice | exit 0 each (`arkdeck-m4-lpp-swift-compare{1,2}.log`) |
| Rust replay | `cargo test -p arkdeck-agentd --test spawning flash_host_facts` | 3 passed |
| fmt | `cargo fmt --all --check` | exit 0 (`arkdeck-m4-lpp-fmt.log`) |
| clippy | `cargo clippy -p <crate> --all-targets -- -D warnings` for `arkdeck-hoststore`, `arkdeck-control`, `arkdeck-agentd`, `arkdeck-soak` | exit 0 each (`arkdeck-m4-lpp-clippy-<crate>.log`; agentd again after the fix below, `…-clippy-agentd-rerun.log`) |
| Crate tests | `cargo test --no-fail-fast -p <crate>` for the same four | hoststore 601, control 30 and soak 4 passed. In agentd, 164 passed and one failed: the ingress refusal test still listed `flash.lanePlanPreview` among the methods the App may not call. After adding it, the agentd bin tests rerun green, 90 passed (`arkdeck-m4-lpp-test-<crate>.log`, `…-test-agentd-bin-rerun.log`) |
| Mutations | five, one at a time: the fullwidth digits dropped from the Control's digest check; the topology check skipped; a previewer composed without a lane; the refusal without facts reworded; the ingress's three keys dropped | each fails its test. The sources were restored by digest and rebuilt, and the replay and the agentd bin tests rerun green (`arkdeck-m4-lpp-mutations.log`, `…-rerun-after-mutations.log`) |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv) | PASS on macOS; 136 control responses (`arkdeck-m4-lpp-readonly.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0 (`arkdeck-m4-lpp-sdd.log`) |

No contract input changed. Every new answer conforms to the published
`flash.lanePlanPreview` schema, and the Control validates each one before
sending it. `generate-contract.py --check` is therefore not required;
`arkdeck-cli` and `arkdeck-contract` did not change.

## CI

- This change: pending.
- #2168 (M4-3a, head `ecd73959`): guard run 36092731152 and swift run
  36092731370, both succeeded. Merged as `6a838403`.

Host-process evidence only:

- The Swift lane is scripted and never runs `arkforged`.
- The HDC is the shared fake.
- No device was used, and no installed service was touched.
