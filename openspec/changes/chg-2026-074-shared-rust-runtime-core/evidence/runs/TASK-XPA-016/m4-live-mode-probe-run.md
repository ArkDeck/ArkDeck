# TASK-XPA-016 — M4 run record: the Rockchip live-mode probe

Change: CHG-2026-074-shared-rust-runtime-core@r11. Milestone M4 (GJ-4), lane B's last r11 item
"Rockchip live-mode and post-flash binding" (tasks.md, TASK-XPA-016 deliverables), first slice: the
live-mode probe. Host measurement only — not hardware, platform or conformance evidence
(POL-VERIFY-001, POL-MODE-001). No device was contacted and no HDC executable was launched: the
only child process is the shared POSIX `sh` fake HDC driver the Swift oracles record with.

Base: protected main `3d880989` (#1932). Branch `agent/xpa-016-rockchip-live-mode-20260914`; no
stacking.

## What was missing

Nothing Rockchip-specific existed in Rust. `arkdeck-hoststore/src/target_document.rs` decodes
Swift's `targets.json` read-only (it never creates a binding, a proof or an alias); the SPK-6
slices gave `arkdeck-provider-hdc` a dispatch, a managed server and a lifecycle executor; but the
flash facts of M4 — `flash.prerequisites` (which, per `spk-9-run.md` §2, makes no ArkForge call
and needs only the Target owner and the binding facts) and the binding facts every ArkForge
`materializePlan` carries — start from the live mode and build that Swift's
`TargetStoreRockchipRuntimeFactsPort` measures through `FoundationRockchipLiveModeProbe`. That
probe is the design table's "Rockchip live-mode probe → migrate → `arkdeck-provider-hdc`"
(`rust-core-cross-platform-architecture.md` §migration row for `DeviceProviders/*`), i.e. lane B.

## What Swift does

`FoundationRockchipLiveModeProbe` (`RockchipLiveModeProbe.swift` 107–241). HDC first, because it
names the target by its connect key: `hdc list targets -v` (`read`: 15 s, 64 KiB,
`criticalNonInterruptible: false`; a non-zero exit is "read-only probe command exited N", a runner
error "read-only probe command did not complete: …"), parsed with the registered
`openHarmony320Family`/`3.2.0f` parser; the target is on HDC iff exactly one row has its connect
key and state `Connected`; an empty list is "not on HDC"; a list the parser cannot read is never
downgraded to absence ("HDC target parser does not support V", "HDC target list is not UTF-8",
"HDC target list exceeded its byte budget", "HDC target list is malformed: R"). On HDC: the mode
is `hdc`, the HDC-normal identity is `SHA256Hex(Data(connectKey.utf8))` (the exact bytes, unlike
the lowercased adoption identity), the current port is `usbProbe.singleHDCNormal(identity)` under
`try?` (a different identity lends no port), and the build is
`-t <key> shell param get const.ohos.fullname` under `try?` — non-UTF-8, empty or longer than 400
characters is no build — so a failed readback is a known mode with an unknown build, never a
guess. Not on HDC: `loaderObserver.observeLoader(stableIdentitySHA256:, expectedUSBTopology: nil,
requestID: "live-mode-<uuid>")` names `loader` with the observed topology and no build, or the
target is not observable ("ArkForge dual-source Loader observation failed: E"). The consumer,
`TargetStoreRockchipRuntimeFactsPort.liveFacts` (`RockchipRuntimeComposition.swift` 250–279),
turns a throw into `deviceMode: "absent"` (never rethrown, so device-absent planOnly and draft
keep working), and names the `dayu200` profile only when the build equals the profile's
`firmwareVersion` exactly. Pinned by `RockchipRuntimeCompositionContractTests`
`testLiveProbeReadsModeAndBuildFromReadOnlyCommandsOnly` (1587) and
`testLiveProbeRefusesToAttributeAnAmbiguousOrMissingObservation` (1655).

## What Rust now does

- `rust/crates/arkdeck-provider-hdc/src/live_mode.rs` (every host; no Swift file changes):
  `LiveModeProbe::new(&dyn HdcDispatch, &dyn LoaderObserver, Option<&dyn UsbProbe>)` and
  `observe(connect_key, stable_identity_sha256) -> Result<LiveModeObservation, LiveModeFailure>`
  with Swift's decision order, argv, budget (15 s / 64 KiB) and every reason above;
  `LiveModeObservation { device_mode: DeviceMode::{Hdc, Loader}, build_fingerprint,
  usb_topology }`; `LiveModeFailure::NotObservable` displayed as "the bound Rockchip target is
  not observable: …", plus `unavailable_tool(provider_id, detail)` for the composer that
  resolves `hdc` before an `HdcDispatch` exists (Swift resolves inside the probe: "hdc executable
  is unavailable to the facts probe: …"). The build is judged by lane A's `property_value` and the
  400-grapheme rule; the list by lane A's `parse_target_list`; the request id is a version-4 UUID
  from `arkdeck_platform::random_bytes` (entropy that cannot be read leaves the device
  unobserved rather than correlating under a fabricated id).
- Two ports, declared here and served elsewhere: `LoaderObserver::observe_loader` (Swift
  `ArkForgeLoaderObserving`: the host's USB identity and ArkForge's `discoverDevices` agreeing on
  a settled DAYU200 Loader at the exact bound identity) and `UsbProbe::single_hdc_normal` (Swift
  `RockchipRuntimeUSBProbing.singleHDCNormal(stableIdentitySHA256:)`). The design retires
  ArkDeck's own IOKit enumeration in favour of `arkforged discoverDevices`, so both are the
  ArkForge lane's (`arkdeck-provider-arkforge`, TASK-XPA-017) to implement; their refusal reasons
  are free text (T2) that the probe quotes.
- Not done here, on purpose: the facts port (`TargetStoreRockchipRuntimeFactsPort`, its server
  fact keys, the `unknown`/`absent` distinction, the exact-firmware `profileID`, the ephemeral
  topology override and the two `flash.postFlash*` refusals) is `arkdeck-provider-arkforge`'s;
  the post-flash alias store, `advanceBindingLineage` and its alias carry-forward are the Target
  owner's (`arkdeck-hoststore`, lane A) — lane B will announce the surface before touching them;
  the `enterLoader`/`verifyBoundBuild` executors need a device window (runbook §5).

## Tests

`cargo test -p arkdeck-provider-hdc --lib live_mode` — 10/10; `cargo test -p arkdeck-provider-hdc
--test live_mode` — 3/3 (macOS; the fake's lock serialises them with the Swift oracles and
`tests/process_dispatch.rs`); `cargo clippy -p arkdeck-provider-hdc --all-targets -- -D warnings`
clean on the host and `--target x86_64-unknown-linux-gnu` / `x86_64-pc-windows-msvc` for the
library. The unit tests use Swift's own doubles, ported: a scripted dispatch that records every
plan, a fixed Loader observer that also records its request ids, a refusing one, and a USB probe
that knows exactly one HDC-normal device by the digest of its connect key.

| Test | Proves |
| --- | --- |
| `connected_over_hdc_names_the_mode_the_build_and_the_current_port` | `hdc`, build `OpenHarmony-7.0.0.35-20260728_180253`, port `44`; exactly `["list","targets","-v"]` then `["-t","device-1","shell","param","get","const.ohos.fullname"]`, each with 15 s / 64 KiB |
| `without_a_usb_probe_the_hdc_observation_carries_no_port` | `usb_probe: None` → topology `None`, build kept |
| `a_failed_build_readback_is_a_known_mode_with_an_unknown_build` | exit 1, non-UTF-8, empty, 401 graphemes, unobservable dispatch → `hdc` with no build; exactly 400 graphemes is a build |
| `a_mismatched_hdc_identity_lends_no_port_to_the_target` | another device's identity on the port → `hdc`, topology `None` |
| `not_on_hdc_the_loader_observer_names_loader_for_the_bound_identity` | `[Empty]` → `loader`, topology `42`, no build, one command; no expected topology; request id `live-mode-<lowercase v4 uuid>` |
| `a_loader_that_is_not_the_bound_target_is_not_observable` | identity mismatch, an ambiguous Loader set, nothing on either surface → not observable with the observer's reason; the build is never read |
| `only_exactly_one_connected_row_with_the_key_is_on_hdc` | two rows with the key, an `Offline` row, another device's row, no output → "not on HDC" |
| `a_target_list_the_parser_cannot_read_is_never_absence` | a 3-column line, a truncated list, invalid UTF-8, exit 2, a refused and an unobservable dispatch → Swift's six reasons |
| `the_failure_reads_as_swift_s` | the `Display` text and `unavailable_tool` |
| `the_hdc_identity_is_the_digest_of_the_exact_connect_key` | `Device-1` hashes as its exact bytes, not as the lowercased adoption identity |
| `the_shared_fake_in_hdc_normal_names_the_mode_the_build_and_the_port` (subprocess) | the observe fixture's driver answers `hdc` / `OpenHarmony-4.1-release` / `44`; its log is exactly the two argv lines |
| `the_shared_fake_listing_another_device_leaves_the_mode_to_the_loader_observer` (subprocess) | `otherDevice` mode → `loader` `42` after one list; a refusing observer → not observable, the list read once per probe |
| `a_list_the_fake_refuses_is_not_observable` (subprocess) | exit 23 → "read-only probe command exited 23", the observer never consulted |

## Not run, and why

- No real HDC and no device: the fake answers the oracle's bytes; whether a real `hdc` prints the
  registered 5-column family for a DAYU200 in normal mode is the observe oracle's fact, not this
  probe's.
- The two ports are doubles: the dual-source Loader proof (`ProductArkForgeLoaderObserver`) and
  the USB enumeration (`RockchipProductUSBProbe`) are the ArkForge lane's to serve over
  `arkforged`; SPK-9's preconditions (`spk-9-run.md` §4) still stand.
- `maskrom` is never produced: Swift's `RockchipLiveModeObservation` doc names it, but its probe
  emits only `hdc` and `loader`, and the facts port's `case "maskrom"` prerequisite row
  (`RockchipRuntimeComposition.swift` 321) is unreachable through it; the Rust enum has two
  variants, so a port of the facts port must decide that row deliberately.
- `unavailable_tool` is a constructor for the composer, not exercised through a resolver here.

## Facts for the maintainer from the M4 map (not blocking this slice)

1. Two revision counters in two roots: the post-flash HDC alias (Application Support) copies the
   Target store's `bindingRevision` (daemon state directory); retiring a state directory restarts
   one counter and not the other, which is the whole reason `reconcileReissuedLineage` and
   `arkdeck flash reconcile-alias` exist. A Rust port that unified the roots would delete that
   failure mode but change a durable layout (T0 per tasks.md §"tiers"); it needs a ruling before
   the binding store is ported.
2. The registered macOS `hdc` digest `05b2bf7a…` is spelled in Swift
   (`RockchipDeviceBinding.swift` 57–58) and in Rust (`provider.rs` 51–53) with no shared source.
