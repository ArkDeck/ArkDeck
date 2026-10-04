# TASK-WHR-001/002 — Windows HDC registration, run record, 2026-10-04

This PR registers `OPENHARMONY-HDC-WINDOWS-PROBES@1.0.0`, as CHG-2026-078 r2 (#2459) approved it.
It also carries TASK-WHR-001's one remaining deliverable, the c2 fixtures, because that is too
small for a PR of its own. Base: protected `main` at the time of the branch, which includes #2457
(the corrected processing script) and #2459 (r2).

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No `hdc` ran, and no board was
attached. This is not Windows acceptance, not device evidence, and it wires no consumer.

## What is registered

- **The c2 fixtures (TASK-WHR-001).** The c2 fixtures are under
  `rust/tests/fixtures/hdc-windows/c2/`. They were generated from the raw 2026-10-04 root by
  `python rust/scripts/windows_sample_process.py hdc --root <raw c2> --label c2 --tool-dir
  <DevEco install> --out rust/tests/fixtures/hdc-windows/c2`.
  - The five fixtures of `design.md` §3 reproduce its SHA-256s exactly.
  - Every file equals the #2456 evidence copy, except `tool.json`'s `hdcOnPath`. The script leaves
    candidate 1's directory (a tools directory on D:, not a user path) as it is, and #2456
    redacted it by hand.
  - `resources.json` lists every file with its byte count and SHA-256, maps each family to its
    fixtures and their expected outcomes, and pins the canonical registry.
  - `.gitattributes` keeps `*.bin` binary.
- **The registry.** It is `openspec/integrations/openharmony/windows-probes.yaml`, which is
  `drafts/windows-probes.yaml` without its draft notice and with `integrationProfile`
  `OPENHARMONY-TOOLS@0.7.0`. SHA-256 `205c4977cd07ce7e4ad1d3ad84d5cbdee3130b4cd77fb6ac53144d79a6d059cb`.
- **The resource manifest.** It is `rust/tests/fixtures/hdc-windows/resources.json`, SHA-256
  `c4b9f81e924f34e374f4a38acc27ba4c4ffc5254cd3ec32c054a5b6660ad8f77`.
- **The profile.** `openspec/integrations/openharmony/profile.md` moves to `OPENHARMONY-TOOLS@0.7.0`
  and gains the "Windows HDC registry" section, from `drafts/profile-windows-section.md` with the
  hashes filled in.
- **The lock.** It becomes `INTEGRATION-PROFILES-0.8.0`, with the profile at 0.7.0, a
  `windows_probe_registries` entry (tool 3.2.0g, executable SHA-256, endpoint, registry SHA-256),
  and `windows_probe_resources` pinning every fixture file and the manifest. `adoption_boundary`
  moves `previous_lock` to 0.7.0, adds the `windows_probe_rule`, and keeps the supervisor
  registration's previous lock as `historic_*`. No macOS registry, resource or fixture pack
  changes.
- **Rust (`arkdeck-provider-hdc`):**
  - `WINDOWS_HDC_TUPLES` holds the c2 tuple: `3.2.0g`, `Ver: 3.2.0g` CR LF, `127.0.0.1:8710`.
  - `parse_registered_windows_presence` is the registered `deviceObservationSnapshot` grammar:
    - six columns, the sixth `hdc`;
    - only `USB` rows are devices;
    - the sampled UART row form is excluded;
    - `[Empty]`, zero bytes and every other form are `unknown`.
- **One Swift contract test.** `HDCSupervisorObservationRegistryContractTests` pinned "the
  current profile is 0.6.0 and the current lock is 0.7.0". It now pins the current 0.7.0 / 0.8.0,
  and still pins the supervisor registration's own `OPENHARMONY-TOOLS@0.6.0` /
  `INTEGRATION-PROFILES-0.7.0`, which now appears as `previous_lock`. This was not run here (no
  macOS host); CI's Swift lane runs it.
- **Docs.** Doc comments and `rust/README.md` that said the table is empty now name the
  registered tuple.

## Contract tests (`tests/windows_hdc_registration.rs`, every host)

- **The table is the registry.** Only c2 is registered; c1 is recorded with
  `registered: false`. Every entry names c2's SHA-256, the `-3.2.0g-windows-c7951849` id suffix and
  `127.0.0.1:8710`.
- **Hash closure.** The registry and manifest SHA-256s appear in the profile and the lock. The
  profile is 0.7.0 and the lock is 0.8.0. Every manifest entry matches its file, every file is
  listed, and the lock pins every fixture file and the manifest by their bytes.
- **Fixture classification.**
  - `version` equals the tuple's `-v` bytes and the registry's observed SHA-256.
  - The `checkserver` bytes are recorded only.
  - Under the Windows grammar, the UART-only and removed-board fixtures are `observedEmpty`, and
    the connected fixture is one pseudonymous device. Under the macOS grammar every one of them
    is `unknown`.
  - The supervisor brackets show one `127.0.0.1:8710` listener owned by c2, and the same process
    in every phase.
- **Negative vectors**, each giving `unknown`:
  - zero bytes and `[Empty]` (CR LF and LF);
  - a macOS 5-column row; a sixth column other than `hdc`; seven columns;
  - UART rows in another state, with a device key, with a name, or with another hostTag;
  - an unknown state, transport or hostTag;
  - a residual CR, a duplicate key, an unterminated row;
  - non-empty stderr, a non-zero exit, truncation, a signal.

  Timeout and cancellation give `unavailable`. Accepted: UART-only and LF rows, and `Offline` USB
  rows beside UART rows (all no device).
- **Separation.**
  - c1's hash, the macOS 3.2.0d and 3.2.0f hashes, an upper-cased hash, a 63-character prefix and
    zeros select no Windows tuple.
  - On Windows the commandless family answers `3.2.0g` only at `127.0.0.1:8710`. On other hosts
    no Windows tuple selects one.
  - No macOS registry names c1 or c2, and the Windows registry names no macOS executable in full.
- **`checkserver`.** The `healthyCheckserver` entry is `unsupported` with `invocationAllowed:
  false`, and no invocable entry runs `checkserver`. Server health (`serverIdentityGeneration`) is
  commandless: no argv, `invocationAllowed: false`, `serverStart` forbidden.

## What stays closed after this registration (for the consumers)

- **`observe.device` still lowers `probeHDCServer` to `checkserver`.** Catalog lowering was left
  unchanged here, deliberately. A first cut made `Action::ObserveServer` lower to
  `unsupported(...)` on Windows. That refused `observe.device` (the only Catalog operation with
  the step) at preflight on Windows, and turned 4 Windows hoststore tests red
  (`windows_agent_human_action_resume.rs`, which drive Jobs through it against a fake HDC). The
  cut was dropped for three reasons:
  - Consumer behaviour belongs to CHG-2026-074 TASK-XPA-005, which adopts this registry.
  - On Windows a plan reaches HDC only through the managed development HDC, whose dispatch first
    proves that its own launched server is current. So the step never meets an absent server
    except in the gap after that proof, which every HDC client command shares.
  - Any HDC client command, `list targets` included, can bootstrap a server when none runs, so
    singling out `checkserver` adds nothing.

  Porting `probeHDCServer` to the commandless observation on Windows is recorded as an open point
  for TASK-XPA-005 and the maintainer.
- **Managed start still dispatches `checkserver`.** The Windows daemon's managed HDC
  (`ARKDECK_DEVELOPMENT_HDC_PATH` naming the DevEco executable, `ARKDECK_DEVELOPMENT_HDC_SERVER=managed`)
  is now admitted by the gate and starts as the Runtime's own server. `ManagedHdcServer::start`
  still runs `-s 127.0.0.1:8710 checkserver` as a readiness step:
  - it runs only after its own launched server's listener answers;
  - the commandless lease proof decides the binding.

  This is the owned-lifecycle start, not a read-only probe, and this PR leaves it as macOS has
  it. Whether the Windows start should rely on the commandless proof alone is recorded as an open
  point for the maintainer.
- **Device listings are still read by the macOS grammars.** Device candidates, observations and
  Rockchip reads use the 5-column grammars, so a Windows listing is `unknown` there until
  TASK-XPA-004/005 adopt `parse_registered_windows_presence`.
- **USB relations stay refused.** The Windows USB census answers `MappingUnconfirmed` until
  TASK-WHR-003/XPA-004, so every relation and adoption is refused before a device list is read.

## Local targeted checks

The environment was `CARGO_BUILD_JOBS=2` and `ARKDECK_DEV_SIGNER_THUMBPRINT` set. The target
directory was separate from every other worktree.

| Command | Result |
| --- | --- |
| `cargo fmt --all --check` | 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` (Windows) | 0 |
| `cargo clippy --target aarch64-apple-darwin --workspace --all-targets -- -D warnings` (stub `xcrun`/`ar`/`cc`, type/lint only) | 0 |
| `cargo clippy --target x86_64-unknown-linux-gnu --workspace --all-targets -- -D warnings` (same) | 0. The first run caught `CommandlessIdentity` imported on Linux, where it is not built; the import is now `cfg`-gated |
| `cargo test -p arkdeck-provider-hdc` | 0; 22 binaries ok, including `windows_hdc_registration` (6 tests); 0 skipped |
| `cargo test -p arkdeck-provider-hdc` with `TEMP`/`TMP` an 8.3 short path on C: | 0 |
| `cargo test -p arkdeck-hoststore` | every binary ok except `windows_agent_human_action_resume`, which failed 4 tests against the dropped first cut (above) |
| `cargo test -p arkdeck-hoststore --test windows_agent_human_action_resume`, after the cut was dropped | 0 (1 ignored, as on `main`) |
| `cargo test -p arkdeck-agentd --no-fail-fast` (after `cargo build -p arkdeck-cli`, which the account-locations process test needs) | 0; 52 binaries ok |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 |
| `git diff --check` | clean |

Not run here:

- The Swift test change (no macOS host); CI's Swift lane runs it.
- The `arkdeck-hoststore` binaries that passed in the first run were not rerun, because the
  only later source change (dropping the lowering cut) restores `main`'s `operation.rs`.
- The other crates that depend on `arkdeck-provider-hdc` (CLI, soak); their clippy is clean, and
  they see only an added table entry and an added function.
