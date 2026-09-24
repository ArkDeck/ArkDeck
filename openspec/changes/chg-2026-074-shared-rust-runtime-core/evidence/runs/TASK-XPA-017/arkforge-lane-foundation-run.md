# ArkForge lane foundation on the Rust daemon (TASK-XPA-017, M4-2a)

The Rust workspace now builds against ArkForge's own Rust crates, at the
revision `Packages/ArkDeckKit/Package.swift` pins for the Swift SDK. The first
thing the Rust daemon reads through them is `flash.device-access`: which
Rockchip flashing modes the ArkForge lane's daemon sees attached. The App's
Flash workspace may ask it through the App ingress, and the Rust CLI serves
`arkdeck flash device-access`.

Spawning and pairing `arkforged`, and the controller surface that plans and
permits, are the next slice (M4-2b). Until then no Rust composition starts a
lane daemon, so the method answers as Swift's daemon without a lane: `rejected`,
`Rockchip device access observation failed`.

Base: protected `main` `a5902947` (#2150, M4-1b). Routed methods: **100/105**
(99 after M4-1b). The five still
unrouted are `flash.lanePlanPreview` (M4-3), `flash.bind-current-loader`,
`debug.start`, `debug.evaluate` (M4-4) and `trace.inspect` (M3). Executable
operations are unchanged at 15/30.

| Already on `main` | This change | Still remaining (M4) |
|---|---|---|
| The facts' ports for the measured `arkforged` and the Loader observation (#2150); the published StepPermit vectors reproduced by `arkdeck-contract`'s own codec (`canonical_parity.rs`) | The ArkForge git dependency, pinned and checked against Package.swift; the `arkdeck-provider-arkforge` crate; `flash.device-access` over ArkForge's public `discoverDevices`, composed in the isolated owner and the production composition; the App allowance and the CLI leaf; the deploy key for the Rust lanes' locked fetch alone | Spawning, pairing and owning `arkforged`, and `runtime_info` against Swift's `HelloAck` (M4-2b); the upstream ArkForge client API and `flash.lanePlanPreview`, closing SPK-9 (M4-3); execution and recovery (M4-4) |

## The maintainer's ruling Q4, as applied

- **A git dependency, not a vendored copy.** `rust/Cargo.toml` takes
  `arkforge-client` (and, for tests, `arkforge-authority-api`, `arkforge-core`
  and `arkforge-ipc`) from `https://github.com/ArkDeck/ArkForge.git` at
  `rev = "eee578720c5bae76b2574a6aaf25b536bc491c86"`, the revision Package.swift
  pins. `arkforge-platform` comes in through the client. None of them has a
  third-party dependency.
- **First-party exceptions.**
  - `deny.toml`: the repository is the one `allow-git` entry, and each of the
    five crates is named in `[bans] allow`. `cargo deny --locked check`:
    advisories, bans, licenses and sources ok. The crates declare `Apache-2.0`
    in their metadata, which the licence policy allows.
  - cargo-vet: nothing was added. It treats a crate from a non-registry source
    as first-party, so `cargo vet --locked` passes with the committed policy
    (36 crates fully audited). SPK-9 §4.2 expected a first-party audit or
    policy entry; none is needed. A crates.io crate published under one of
    these names would make cargo-vet ask for an explicit decision.
- **One revision, two pins.** `rust/scripts/check-arkforge-pin.py` refuses:
  - an ArkForge dependency in `rust/Cargo.toml` that is not the ArkForge
    repository at exactly the Package.swift revision;
  - a branch or tag in place of that revision;
  - a crate naming an ArkForge crate other than through the workspace;
  - a locked package from another source or revision.

  With `--run-vectors` it also reruns, at the pinned revision and from the
  checkout Cargo fetched, ArkForge's own `swift_sdk_vectors` (the wire bytes
  the Swift SDK is held to) and `permit_vectors` (the StepPermit bytes both
  authorities mint). The policy job runs it on every Rust run, so a pin bump
  cannot land without them.
- **The deploy key for the Rust lanes.** See CI below.
- **No LICENSE file** exists at the pinned revision. The maintainer chooses and
  adds it upstream; this change does not write one.

## The crate boundary

- `arkdeck-provider-arkforge` depends on no ArkDeck crate and on `arkforge-client`
  alone. Its tests also use ArkForge's IPC codec and authority API.
- `arkdeck-agentd` depends on it for the macOS composition.
- `check-readonly.py`'s boundary table now also checks ArkForge edges: only the
  lane's provider may depend on an ArkForge crate, and only on the client.
- The facts owner of M4-1b stays in `arkdeck-hoststore`. The lane serves it
  through its ports from M4-2b on.

## `flash.device-access`, as ported

Swift: `AgentDaemon.swift` handler, `ProductRockchipDeviceAccessObserver`
(`RockchipDeviceAccessObservation.swift`), composed in `main.swift` over the
state directory's `arkforge/` whether or not a lane is.

- **Parameters.** Any parameter is `invalidParams` (`Device access discovery
  does not accept parameters`), checked before the observer. Absent and empty
  parameters are the same request.
- **No observer.** `internalError`, `Rockchip device access observation is not
  configured`.
- **Session.** `DeviceAccessObserver::observe` opens one fresh public session per
  read: the handshake, then `discoverDevices` with an empty request. The whole
  session is bounded at 15 s, as Swift's `ArkForgePublicClient` bounds it.
- **Modes.** `rockusb-loader` and `loader` are `Loader`; `rockusb-maskrom` and
  `maskrom` are `Maskrom`. Every other mode (the HDC-normal personality, any
  later profile's) is left out. ArkForge's order and repeats are kept. The
  answer is `{observationCount, observedModes}`.
- **Failures.** Any failure is `rejected`, `Rockchip device access observation
  failed`, with no details: no socket path, provider diagnostic or USB identity
  leaves the Runtime. The cases are an unreachable daemon, a refused session, a
  failed or malformed discovery, and the bound running out.
- **Compositions.**
  - *Isolated development owner:* the observer reads `root/jobs-state/arkforge`,
    beside the Job state.
  - *Production composition:* written, not activated; it reads
    `…/ArkDeck/Agentd/arkforge`.
  - Both create the directory owner-only when it is missing, best effort, as
    Swift's daemon does. The owner census names `deviceAccess`.
- **App ingress.** `flash.device-access` with no parameters, or an empty
  object. A socket path, a runtime directory or a serial is refused. A peer
  that is not the App is refused, as for every method.
- **CLI.** `flash device-access`: one request, no parameters. The Swift argv
  fixture is copied unchanged into `rust/tests/fixtures/current-cli-argv/` and
  replays with no deviation.

The committed corpus already holds Swift's three answers (a refused parameter,
the refusal without a daemon, and two modes). The Rust answers are those frames
(see Verification). The request and result schemas are unchanged, so no contract
input changes.

## Declared differences

Each is either fail-closed or T2 prose:

- **The session bound.** ArkForge's Rust `PublicClient` bounds only its
  handshake (10 s). The Rust observer therefore runs the session on its own
  thread and bounds the answer at 15 s. A daemon that never answers keeps that
  thread until it answers or closes; no caller waits for it. Swift's SDK bounds
  the socket itself. M4-3's upstream client change is to bound the session.
- **A nameless observation.** ArkForge's Rust client refuses an observation
  without an identity, where Swift's SDK counts it. It is fail-closed: the
  answer is the refusal.
- **The acknowledged session kind.** The Rust client refuses a handshake
  acknowledged for another session kind; the Swift SDK does not check it
  (fail closed).
- **Request identities.** Swift names its request
  `runtime-device-access-<uuid>`, ArkForge's Rust client `arkforge-<pid>-<n>`.
  Callers never see either (T2).

## CI

**The Rust lane's secret.**
- `swift-ci.yml` passes `rust-ci.yml` exactly one secret, the read-only
  ArkForge deploy key, by name (never `inherit`).
- `rust-ci.yml` declares it required and hands it to each job's locked fetch and
  to no other step.
- The fetch runs `scripts/ci/arkforge-cargo-fetch.sh`:
  - `arkforge-package-auth.sh` writes the key and its Git transport into a
    private file instead of `GITHUB_ENV`. The transport is exported to that
    process alone, so no later step inherits the key path or the SSH rewrite of
    `github.com`.
  - `CARGO_NET_GIT_FETCH_WITH_CLI=true cargo fetch --locked` runs with it.
  - The key is removed on exit, before any step builds or runs checked-out code.
  - `cargo fetch` itself builds nothing; every later step reads Cargo's cache.
  - On Windows (Git Bash) the auth script cannot run: it sets modes with
    `install -d -m 0700` and `chmod`, and NTFS refuses them there (the first CI
    run of this PR failed so). The wrapper then writes the key itself, under
    `umask 077`, into a directory `mktemp -d` creates for the runner's user. It
    checks the key with `ssh-keygen -y`, pins the same GitHub host key and
    exports the same transport, and removes both files and the directory on
    exit. The contract test pins that the two host keys are equal.

**The perf lane.** `rust-perf.yml`'s nightly and soak jobs, which build the
daemon on schedule or dispatch, fetch the same way.

**The contract tests** (`scripts/test_agent_pr_workflow.py`) pin all of it:
- The Swift CI count of the secret goes from two to three, the third in the
  Rust lane's `secrets:` block.
- The Rust CI allows the secret only in the two fetch steps, which must use the
  wrapper and precede every step that runs checked-out code.
- The wrapper must hand the auth script a private `GITHUB_ENV`, arm its cleanup
  before setup, and build, test or run nothing.
- New mutations cover:
  - a plain fetch;
  - the key handed to the lint step;
  - the auth script called directly;
  - an optional secret;
  - the pin check without its vectors;
  - a fetch after checked-out code;
  - `secrets: inherit`, a missing secret or a second secret;
  - a wrapper that writes the real `GITHUB_ENV`, lacks or delays its cleanup,
    builds, or fetches unlocked.

## Verification

**Local targeted checks.** `CARGO_BUILD_JOBS=2`, own target
`/private/tmp/arkdeck-m4-rust-target`, logs `/private/tmp/arkdeck-m4-afl-*.log`.

| Check | Command | Result |
|---|---|---|
| Dependency policy | `cargo deny --locked check` in `rust/` | exit 0: advisories, bans, licenses, sources ok (`afl-deny.log`); before the `allow-git` and bans entries it refused each ArkForge crate (`source-not-allowed`) |
| Audits | `cargo vet --locked --no-registry-suggestions` | exit 0; 36 fully audited, no entry added (`afl-vet.log`) |
| Pin | `python3 rust/scripts/check-arkforge-pin.py --run-vectors` | exit 0: the three pins agree; ArkForge's `swift_sdk_vectors` (4 tests) and `permit_vectors` (1) pass at the pinned checkout (`afl-pin.log`) |
| Pin refusals | the check over a copy of the manifests with each of six drifts: the Swift pin moved, one crate's rev moved, a branch, a fork, a crate pinning on its own, a lock from another revision | 6/6 refused; the unchanged copy accepted (`afl-pin-refusals.log`) |
| fmt | `cargo fmt --all --check` | exit 0 |
| clippy | `cargo clippy -p arkdeck-provider-arkforge -p arkdeck-control -p arkdeck-agentd -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`afl-clippy.log`, `afl-clippy-agentd.log`) |
| Crate tests | `cargo test --no-fail-fast -p <crate>` | exit 0: `arkdeck-provider-arkforge` 7 (five against a stand-in public socket, the mode mapping, the permit vectors through ArkForge's authority API), `arkdeck-control` 29, `arkdeck-cli` 251, `arkdeck-agentd` 142; then the agentd corpus replay, 1 (`afl-test-<crate>.log`) |
| Workflow contract | `python3 scripts/test_agent_pr_workflow.py` | exit 0; 13 tests, one of them new (`afl-workflow-tests.log`) |
| Fetch wrapper | `scripts/ci/arkforge-cargo-fetch.sh` with a throwaway key: once over Cargo's cache, once with an empty `CARGO_HOME` | exit 0 over the cache; the cold fetch went over SSH with the throwaway key, was refused, and exited non-zero. Both runs removed the key and the transport file. The real deploy key is used only in CI |
| Fetch wrapper, Windows path | the same over Cargo's cache with a stand-in `uname` answering `MINGW64_NT-10.0-20348`, then with an empty key | exit 0; the key and host key were written to a `mktemp -d` directory, and files and directory were removed on exit; the empty key was refused with the auth script's error. Real Git Bash is exercised only in CI |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv), with the refused-parameter exchange added | PASS on macOS; 134 control responses (`afl-readonly.log`) |
| Contract | `python3 rust/scripts/generate-contract.py --check` | exit 0; 105 methods, 980 shapes, unchanged |
| Contract check scripts | `rust/scripts/test_contract_checks.py` | 42 tests OK (`afl-contract-checks.log`) |
| CLI audit | `cli-parity-audit.py <this build's arkdeck>` | 161 implemented, 56 leaf missing but routed, 24 owner missing, 15 tombstones; 120 leaves served (`afl-cli-audit.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0 (`afl-sdd.log`) |

Not run locally: `check-contracts.py`'s two full source views, and the
Linux and Windows workspace jobs. CI runs them, and they are the first runs of
the deploy-key fetch on hosted runners. The wrapper has never run on Windows'
Git Bash.

**CI.** PR #2151 (recorded in the next slice, M4-2b):

- head `d00111de`: SDD Guard run 36044539871 success; Performance lanes run
  36044539656 success (the harness tests; the nightly and soak jobs are not
  push-triggered); Swift CI run 36044540324 failed in one job, the Rust
  workspace on windows-latest, at the locked fetch: Git Bash could not set the
  mode of the key's directory (`install: cannot change permissions of
  'D:\\a/_temp/arkforge-ssh': Permission denied`). The policy job's fetch with
  the deploy key, the pin check with ArkForge's vectors, deny and vet, and the
  ubuntu-latest and macos-26 workspace jobs (their contract views included)
  were green on that first run;
- head `5c37914d`, with the Windows path above: SDD Guard run 36046415910
  success; Swift CI run 36046416500 success — the `swift` aggregate,
  `swift-tests`, `app-build`, the Rust host-independent checks and the Rust
  workspace on all three hosts;
- squash-merged by the coordinating session as `main` `cc5b5670`
  (2026-09-24T19:23:16Z).

No device, installed service, ArkForge daemon or App was used, and nothing
here is device evidence.
