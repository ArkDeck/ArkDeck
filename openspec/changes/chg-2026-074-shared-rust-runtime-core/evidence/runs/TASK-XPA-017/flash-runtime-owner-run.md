# Flash Runtime owner execution wiring

Task: TASK-XPA-017; Change: CHG-2026-074; Date: 2026-09-27.

## Behavior and boundary

The macOS Host connects its existing Flash admission, execution and passive
reconciliation engines to the ArkForge lane owned by this daemon generation.
The production and isolated compositions share the Host's descriptor-bound
HDC and one durable Rockchip action host between the dispatcher and ArkForge
managed control. Preparation imports immutable bytes, compares public and
controller assessments, seals exact mechanics/authority evidence and starts
one daemon job without signing a permit. The Runtime persists that correlation
before its admitted run drives it. An unknown result never starts a replacement.

Per-job lane synchronization prevents duplicate starts and drives. The Host's
existing running/reconciling slots and the Runtime's mutation locks, fresh
facts, exact materialized plan and capability consumption remain in force.
The public assessment sends no controller binding or authority fields. All
wire messages use ArkForge's typed clients; there is no private codec fork.

This work does not install a candidate Runtime, operate a device, establish
hardware coverage, retire Swift, or settle retained unknown Session effects.
The Flash invocation broker and generic Agent admission are separate callers;
their remaining restrictions are not proof of an executable Flash UI journey.

## Local targeted checks

Initial incremental checks used `CARGO_BUILD_JOBS=2` and
`CARGO_TARGET_DIR=/private/tmp/arkdeck-takeover-d79c-target`, one local build lane
at a time:

- Provider `cargo test --manifest-path rust/Cargo.toml -p arkdeck-provider-arkforge --lib lane_host`:
  exit 0, 6 tests; `/private/tmp/arkdeck-flash-lane-host-tests.log`.
- Initial Host subprocess test under the binary target: exit 0, 1 parent test
  plus its child fixture; `/private/tmp/arkdeck-flash-owner-tests.log`.
  The first attempt mistakenly selected `--lib` for the binary-only agentd
  crate and exited 101 before compiling. Subsequent fixture failures exposed
  missing binding identity evidence and inconsistent Job/planner/capability
  roots; only the fixture was corrected, with no relaxed production checks.
- Code review then moved these spawning tests into `tests/spawning`, under
  its serial turn lock, to preserve the repository's macOS descriptor
  inheritance isolation. Unknown-outcome and concurrent lane-entry cases
  were added after the initial checks and need their own final results.

The next incremental pass pinned both lanes to the pushed upstream candidate
`a2fc7f3c18dcdfd2bf7a6af39451f1c6278fb9eb` (ArkForge PR #1). The native adapter
and production/isolated composition were compiled in this pass:

- `python3 rust/scripts/check-arkforge-pin.py`: exit 0; Swift manifest,
  Rust manifest and lock all name that exact revision.
- `cargo test --locked --manifest-path rust/Cargo.toml -p arkdeck-provider-arkforge --lib lane_host`:
  exit 0, 7 tests, including concurrent prepare/perform with one start and
  one poll; `/private/tmp/arkdeck-flash-lane-host-native-candidate.log`.
- `cargo test --locked --manifest-path rust/Cargo.toml -p arkdeck-agentd --test spawning flash_execution_control -- --nocapture`:
  exit 0, 2 parent tests and 1 deliberately ignored subprocess fixture
  (invoked by both parents); `/private/tmp/arkdeck-flash-owner-native-candidate.log`.
  The unknown case retains `waitingForRecovery` and `outcomeUnknown`, refuses
  repeated runs without a new lane/host call, and reconciles by observation
  alone. The completed case does not redispatch its terminal record.

The first candidate fetch failed on sandbox DNS; fetching the same fixed
remote revision with controlled network permissions succeeded. No local path
override was used. These are local candidate results, not upstream approval
or hardware evidence. No full local unified gate or real-device acceptance ran.

ArkForge PR #1 subsequently merged as
`c1dc0553b42627581583abfba3fec34d13343282`. The merged commit and the tested
candidate both name tree `cfdcb9dbe048b20d690a0f5406b14e79ef4a21b2` (checked
against the GitHub commit API and the candidate checkout). Both Swift
resolution files, `Package.swift`, `rust/Cargo.toml` and `rust/Cargo.lock` now
pin the merged revision; the pin consistency check exits 0. The first-party
source/license policy and cargo-vet trust configuration require no changes.

Final merged-pin Rust checks on the Flash diff over ArkDeck base `5825e91fb`,
with the same private target and two build jobs, all exited 0:

| Crate | `clippy --all-targets -- -D warnings` | `cargo test` |
| --- | --- | --- |
| `arkdeck-provider-arkforge` | 0 | 95 passed |
| `arkdeck-hoststore` | 0 | 718 passed, 18 existing conditional tests ignored |
| `arkdeck-agentd` | 0 | 196 passed, 1 subprocess worker ignored by the harness and invoked by its two parent tests |
| `arkdeck-soak` (direct dependent) | 0 | 7 passed |

Commands use `--locked --manifest-path rust/Cargo.toml -p <crate>`. Logs are
`/private/tmp/arkdeck-flash-final-<crate>-clippy.log` and
`/private/tmp/arkdeck-flash-final-<crate>-test.log`. `cargo fmt --all --check
--manifest-path rust/Cargo.toml` also exited 0
(`/private/tmp/arkdeck-flash-final-fmt.log`). The first Clippy pass identified
constant-size `chunks_exact`; the decoder now uses the fixed-size slice API.
The first provider integration test attempt could not bind its fixture Unix
sockets inside the sandbox (EPERM). The same tests passed with controlled
local permissions; that failed attempt is preserved in
`/private/tmp/arkdeck-flash-provider-sandbox-failure.log`. There was no assertion
relaxation or CI-flake classification. Cold dependency builds and existing
integration cases exceeded the ten-minute local target; only the affected
crates and their direct dependents were run, one lane at a time.

After the independent journal-measurement change merged, this branch fast-forwarded
to `c8c9f9b02e4ca14eeba41994ddffb21f8546068f` without conflicts. No Flash source
changed in that integration. Only the changed direct dependent, Soak, was
checked again: all-target Clippy exit 0 and 8 tests passed, in
`/private/tmp/arkdeck-flash-final-soak-main-{clippy,test}.log`.

The remaining checks on the merged pin and integrated base all exited 0:

- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter FlashRunOracleContractTests`:
  2 tests passed; `/private/tmp/arkdeck-flash-final-swift.log`. The wrapper's
  resolved ArkForge revision was independently read back as `c1dc0553…`.
- `python3 rust/scripts/check-arkforge-pin.py --run-vectors`: consistent pins,
  5 Swift SDK wire vectors and 1 StepPermit vector passed;
  `/private/tmp/arkdeck-flash-final-pin-vectors.log`.
- `sh scripts/check-sdd.sh`: zero errors and warnings;
  `/private/tmp/arkdeck-flash-final-sdd.log`.

Contract generation was not run because no contract input changed. No local
App build ran because this diff changes no App source; selected App/Swift/Rust
lanes remain the PR CI's responsibility. The installed Runtime was untouched.

## CI

PR #2282 run `36297499647` failed its Swift lane on head `a9b575cf`:
`ArchitectureBoundaryContractTests` and `AutoUpdateContractTests` still asserted
the previous ArkForge revision. All Rust lanes and the App build passed. The
original failed-step log is `/private/tmp/arkdeck-pr2282-ci-failed.log`.
Both tests now assert the reviewed merged revision `c1dc0553b42627581583abfba3fec34d13343282`;
their exact dependency, identity, entitlement and disclosure checks remain intact.
Main `56c321be` was integrated without conflicts, retaining the already-reviewed
CI execution improvements and Artifact measurement dependency edge. This was a
code failure, not an invalid-run rerun.

### Local targeted checks for the pin assertion correction

`python3 rust/scripts/check-arkforge-pin.py`, `sh scripts/check-sdd.sh` and
`git diff --check` exited 0. Logs are
`/private/tmp/arkdeck-pr2282-pin-fix-{pins,sdd}.log`.
The two affected Swift test classes have not yet run locally: the shared host's
single test window is occupied by an active HDC regression. Under the product
loop's delivery priority, this assertion-only correction is pushed for CI while
that valid run continues. The earlier production checks above remain evidence
for the earlier head; the corrected exact head must pass CI before merge.
No preview implementation is included.

Pending the corrected head's checks. Results will be recorded in the PR body
without amending an already-green head. Protected main still requires both
`guard` and `swift` (read back through the GitHub branch-protection API).
Local checks do not constitute maintainer approval or hardware acceptance.
