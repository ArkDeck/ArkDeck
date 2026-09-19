# DevEco toolchain pin oracle (TASK-XPA-015, M3)

This change is Swift-only. One Swift contract test records the index
`BootstrapDevEcoToolchainRegistry` keeps after each acquire, release, resolve
and removal a workspace preset's toolchain pin goes through, with each answer
and refusal. The Rust registry owner then ports acquire and release by
replaying it, without touching Swift, as tasks.md r11 (7) asks. With them the
isolated Rust daemon can pin a build or test preset's toolchain, which #2056
refuses today because no toolchain owner is composed.

Base: protected `main` `655c8199`, which carries #2056. The oracle was
recorded on `293ff532`; nothing in `ArkDeckBootstrap` changed between the two.

| Already on `main` | This oracle delivers | Still remaining (M3) |
|---|---|---|
| The seven workspace methods on the Rust owner, with the dependency transaction and its pinning interfaces (#2056); DevEco registration, listing and retirement on the Rust registry owner | `DevEcoToolchainPinOracleContractTests`; the recorded timelines, answers and index states in `rust/tests/fixtures/deveco-toolchain-pins/` | Rust DevEco acquire and release and their composition into the isolated daemon; the signing credential owner; the 13 `workspace.*` operations; GJ-5 |

## What the test records

The test runs the production registry over a fabricated DevEco root with the
injected trust `BootstrapToolRegistryContractTests.devecoRegistry` uses, under
the fixed root `/private/tmp/arkdeck-deveco-pin-oracle`. After every step it
keeps the step's inputs, its answer or refusal, and the index it left.

| Timeline | Steps and answers |
|---|---|
| `life` | Registration. Acquire for a preset, again for the same preset, for a second preset and for a Job owner: the references stay sorted by kind, then identity. Refusals: a stale generation (`resourceConflict`), an unknown reference (`resourceNotFound`), a malformed one (`invalidInput`), retirement while pinned (`resourceConflict`). Resolution for a pinned preset, and its refusal for an unpinned one. Releases, including one that holds nothing. Retirement once released, then acquire (`resourceConflict`) and release after it. |
| `drift` | Registration and a pin; the hvigor script changes; acquire and release are then both refused as `recordUnreadable`, because the content is verified before the index is touched. |
| `bound` | Registration; 1,023 pins written into the index; the 1,024th acquire succeeds, the 1,025th is `quotaExceeded`, and a held pin is still acquired at the bound. |

The 1,023 pins are written straight into the index in its own canonical form.
Publishing each through the registry syncs the file every time, and the first
recording, which acquired all 1,024, took 181 seconds; this one takes 0.6.

## How the oracle is held

The fabricated root's file identities (device, inode, times) change on every
run, so a new recording never repeats the old index bytes. The references do
not change: the toolchain reference is the digest of the content, the same on
every run. The checked-in oracle is held two ways:

- `provenance.json` pins the SHA-256 of every other file, and each index state
  is its own canonical bytes.
- The same timelines, played again through the production registry, give the
  same answers and the same index states once the root's and children's file
  identities are set aside.

The states are named by their SHA-256, so a step that changes nothing names
the same file as the step before it. `cases.json` holds 28 steps and 11
distinct states.

## Local targeted checks

| Check | Exit | Result |
|---|---|---|
| `run-swiftpm.sh test --filter DevEcoToolchainPinOracleContractTests` with `ARKDECK_RUST_DEVECO_PIN_RECORD` | 0 | 1 test, 0 failures (0.63 s); the recording |
| The same without the variable, against the checked-in oracle | 0 | 1 test, 0 failures (1.84 s) |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |

## CI

The PR's `guard` and `swift` aggregate are the unified gate. The Swift lane
runs because a Swift test changed. Their result is added by the Rust port.

The first run, on `293ff532` (Swift CI 35453383350), was red in `swift-tests`
only, in `JobPlanAnalyzerOracleContractTests`, which #2062 fixed on `main`; this
oracle's test ran and passed there. The change was rebased on `655c8199`.
