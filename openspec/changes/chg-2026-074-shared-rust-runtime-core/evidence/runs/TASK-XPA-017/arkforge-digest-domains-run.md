# ArkForge digest domains follow the pinned ArkForge (TASK-XPA-017, S1: F1/F2)

The final-lane prompt (2026-09-28, §3) settles F1/F2: ArkDeck follows the
protocol of the ArkForge revision it pins,
`c1dc0553b42627581583abfba3fec34d13343282`. The retired
`arkforge/v1/device-facts\0` domain is dropped, with no dual-domain
compatibility.

| digest | before | after |
|---|---|---|
| USB topology (Loader join, F1) | `arkforge/v1/device-facts\0` | `arkforge/v1/usb-topology\0` |
| admission device facts (execution authority, F2) | `arkforge/v1/device-facts\0` | `arkforge/v1/admission-device-facts\0` |

Base: protected `main` `2e687ca82`. No contract input, Catalog, OpenSpec or
`tasks.md` change. No device, and nothing here is device evidence.

**Review needed:** this changes the facts a destructive admission is checked
against (the admission facts digest the authority recomputes before it signs a
`StepPermit`), so the PR waits for maintainer review.

## What changed

- **Rust, `arkdeck-provider-arkforge`.**
  - `loader.rs` `topology_digest` and `authority.rs` `device_facts_digest` no
    longer carry a hand-written domain constant. They hash with the pinned
    `arkforge_core::digest::digest_in_domain` under `Domain::UsbTopology` and
    `Domain::AdmissionDeviceFacts`. A pin move therefore carries the domain
    with it.
  - No `arkforge-transport` dependency is added (the 09-25 boundary: the
    provider depends only on ArkForge's protocol and pure-computation crates).
  - The two existing literal tests (`the_topology_digest_is_the_daemons_rule`,
    `the_admission_facts_encode_as_arkforges_canonical_cbor`) now state the new
    domains.
  - New `tests/digest_domain_vectors.rs`: fixed vectors produced by ArkForge's
    own producers (below). Four topology vectors (18874368, 19922944, 0,
    `u32::MAX`) and two admission-facts vectors (serial absent and well-formed;
    descriptor serial with a malformed descriptor).
- **Swift, `ArkDeckWorkflows`.** `ArkForgeObservationSelection.swift` and
  `ArkForgeExecutionAuthority.swift` switch to the same two domains (constant
  renamed to say which domain it is). The existing tests call the production
  functions and hold no literal.

Not changed, per §3:

- No oracle is re-recorded and no state is migrated. Persistent state and the
  recorded oracles carry the raw `usbTopology` number, never a digest. A
  repository-wide search for the old- and new-domain digest of 18874368
  (`a5c146cf…`, `3ec01c30…`) finds only the new vector file.
- Historical run records that quote the old domain
  (`arkforge-execution-authority-run.md`, `arkforge-lane-daemon-run.md`) are
  left as the record of their time. The cutover runbook's P7 row belongs to
  S0.

## How the vectors were computed

A scratch crate outside the repository, depending on the pinned revision only:

```toml
[dependencies]
arkforge-core = { git = "https://github.com/ArkDeck/ArkForge.git", rev = "c1dc0553b42627581583abfba3fec34d13343282" }
arkforge-transport = { git = "https://github.com/ArkDeck/ArkForge.git", rev = "c1dc0553b42627581583abfba3fec34d13343282" }
```

`main.rs` builds `arkforge_transport::usb::UsbDeviceRecord { vendor_id: 0x2207,
product_id: 0x350a, location_id, .. None }` and prints
`record.topology_digest().to_hex()` for each location. It then builds a
`DeviceObservation` with:

- mode `rockusb-loader`;
- the topology digest of 18874368;
- descriptor digest `[0x11; 32]`;
- one protocol identity fact `usb.identity = 0x2207:0x350a`;
- identity strength `serialAndTopology`.

It prints `admission_facts_digest().to_hex()` twice: once for
`SerialEvidence::Absent` with a well-formed descriptor, and once for
`SerialEvidence::Descriptor { digest: sha256(b"serial") }` with
`malformed_descriptor: true`.

Run with `cargo run --offline` (target `/private/tmp/arkdeck-lane1-target/vectors`):

```text
topology 18874368 3ec01c30971df27e26543c63b3856452cbae569f060278e2d10d021a68cfc1be
topology 19922944 6ea4b7679e672a207f517e4b80a7905df75d2dd4c5237a5db36a65524d39f1e5
topology 0 6504f357f2ff8c756ebee2ba8c0bb732b690da6b30cb2596872e9f6f90ae1da1
topology 4294967295 af09e7143f827c0a6838acb78d003b4a0487b6566c8c108769d146f70a33130c
admission absent fb58048e33a273065af0a76aadfa9d7670f8799eb6052874197a73becbb9efcd
serial digest 0144b1defcf7561087015f8d830d65b16f024ad7eb9245fcd4e437a1552b138a
admission descriptor ebdc218f4514782fa6e2d69726b6a12eadbe7fdbcb8ef04ded4d49ec7966076a
```

The ArkDeck-side test reproduces each value from ArkDeck's own functions and
`StepAdmissionSnapshot` fields, so the ArkDeck encoder and the ArkForge
producer agree byte for byte.

## Local targeted checks

Worktree `agent-adc7ba94d908e1c5c`, `CARGO_TARGET_DIR=/private/tmp/arkdeck-lane1-target`,
`CARGO_BUILD_JOBS=2`. Logs are under `/private/tmp/arkdeck-lane1-logs/`.

| check | result |
|---|---|
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --all-targets -- -D warnings` for `arkdeck-provider-arkforge` and its direct dependents `-hoststore` and `-agentd` (`s1-clippy.log`) | exit 0 |
| `cargo test` for `-p arkdeck-provider-arkforge -p arkdeck-hoststore -p arkdeck-agentd` (`s1-test.log`) | exit 0 with `--no-fail-fast`: 123 test binaries, 1048 passed, 0 failed, 20 ignored. The first run had 1 failure because `agent_run_cli_process` needs the `arkdeck` binary beside the daemon. After `cargo build -p arkdeck-cli`, the rerun passed. |
| `python3 rust/scripts/check-arkforge-pin.py --run-vectors` (`s1-pin.log`) | exit 0 |
| `sh scripts/check-sdd.sh` (`s1-sdd.log`) | exit 0 |
| `run-swiftpm.sh test --filter` on `ArkForgeExecutionAuthorityContractTests`, `ArkForgeLoaderObservationContractTests`, `ArkForgeFlashSessionContractTests`, `LanePlanPreviewContractTests` and `ArkForgeLiveDaemonContractTests` (`s1-swift.log`) | exit 0: 50 tests, 0 failures, 6 skipped. The skipped six are the `ArkForgeLiveDaemonContractTests` cases that need a live `arkforged`. |

Not run:

- `generate-contract.py --check`: no contract input changed.
- The live-daemon Swift cases: they need a running `arkforged` built from the
  pin. That is phase A, and the bundle shipped in the RC.

## CI

PR #2303, first head `13e50929c`, Swift CI run `36416418998`.

- **Passed:** `guard`, `plan`, all four Rust lanes, `app-build`,
  `ds-interactions`, `ds-tokens`.
- **Failed:** `swift-tests`, and with it the `swift` aggregate. The failure
  is `CaptureDiagnosticsTraceOracleContractTests.testSwiftCapturesTheTraceLegsOfTheSharedFakeDevice`.
  Its recorded `hdc-calls.log` differs in the order of two trace
  `param get` calls. On CI the case took 92.5 s.

Recorded as an invalid run, by all four criteria:

1. The failure is outside this diff. The diff touches only the two ArkForge
   domain constants, and nothing in trace capture.
2. It is a known kind: an HDC call-order race under load.
3. It passes when run alone: the class passed locally in 5.7 s
   (`/private/tmp/arkdeck-lane1-logs/s1-trace-oracle.log`).
4. It is unrelated to the change.

A record-only commit re-ran CI.

**Second head `d5379e1fb`, run `36419963381`.**

- **Passed:** every Rust lane and the other lanes.
- **Failed:** `swift-tests`, on a different case,
  `FlashRunOracleContractTests.testSwiftSubmitsAndRunsEveryFlashStoryAsTheRustRuntimeReplays`.
  - The canonical story's `job-record.json` and `index.json` differ in the
    journal's recorded byte count, last sequence and hashes. This is a
    journal-length difference, not a digest-domain one.
  - The case took 32.9 s on CI.
  - The same case passed in the first run (`36416418998`), on identical Swift
    sources.
  - On this branch it passes locally: 2 tests in 4.1 s
    (`/private/tmp/arkdeck-lane1-logs/s1-flashrun-oracle.log`).

Also recorded as an invalid run under the four criteria:

1. The two changed Swift constants feed digests that neither the recorded
   job record nor the index carries.
2. It is a load-sensitive timing difference.
3. It passes when run alone, and it passed in the prior run.
4. It is unrelated to the diff.

A second record-only commit re-runs CI.

**Final head `cab7606bc`, run `36423512334`.** Every lane green: `guard`, `plan`, `swift-tests`,
`app-build`, the four Rust lanes, `ds-tokens`, `ds-interactions` and the `swift` aggregate. Merged as
`e2f96a29b`. (Recorded by the RC-readiness slice, `rc-readiness-run.md`.)
