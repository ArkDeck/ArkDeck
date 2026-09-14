# TASK-XPA-016 — M4 run record: the post-flash HDC observation

Change: CHG-2026-074-shared-rust-runtime-core@r11. Milestone M4 (GJ-4), lane B's "Rockchip
live-mode and post-flash binding" item, second slice: the HDC observation half of the post-flash
binding, after the live-mode probe (`m4-live-mode-probe-run.md`, #1934). Host measurement only —
not hardware, platform or conformance evidence (POL-VERIFY-001, POL-MODE-001). No device was
contacted and no HDC executable was launched: the only child process is the shared POSIX `sh`
fake HDC driver, answering a fragment written for this record.

Base: protected main `3d880989` (#1932). Branch `agent/xpa-016-post-flash-hdc-observation-20260914`,
stacked on #1934's `c0592dc4` (it extends that slice's `UsbProbe` port).

## What was missing

The flash flow of GJ-4 leaves the device on RockUSB and gets it back on HDC — possibly with a new
serial after a complete overwrite — and only an exact readback of the new build and model may
publish the post-flash HDC alias that keeps the adopted Target usable. Swift does this in the HDC
arms of `FoundationRockchipRuntimeActionExecutor`; Rust had the dispatch, the target-list parser
and (since #1934) the USB-identity port, but nothing that waits, proves the bound device and reads
it. The durable alias store (`RockchipPostFlashHDCBindingStore`), the Target lineage advance and
the executor's observation-reuse cache are other owners' (the alias store's crate is not yet
assigned by the design table; the Target owner is `arkdeck-hoststore`, lane A), so this slice
stops exactly where Swift's `verifyBoundBuild` calls `publish`.

## What Swift does

`RockchipRuntimeActionHost.swift`. `waitForHDC` (770–833): `list targets -v` (each read 15 s, 64
KiB, judged by `requireSemanticSuccess`) every second until the deadline (15 s for a disconnect,
120 s for a reconnect); the target is on HDC iff exactly one `Connected` row names the key, and
off it iff none does; an empty list is not a verdict and neither is one malformed read (a DAYU200
crossing a reboot briefly prints a line outside the registered family, 2026-08-04, #1068) — it is
remembered and the deadline names it ("…did not reconnect/disconnect before the deadline; last
malformed target list read: R"); an unsupported version, non-UTF-8 or a truncated list ends the
wait. `waitForBoundHDC` (841–928): the expectation's digest must be its key's and its topology
non-empty digits ("post-flash HDC binding expectation is malformed"); each read, exactly one
HDC-normal USB device at the recorded topology, or — the measured board re-enumerates its location
across the first boot (17956864 → 18087936, 2026-08-18) — the device whose serial digest is the
previous alias, at its current topology; a candidate whose digest is not its own key's or that
drifted on both axes is refused ("topology-bound HDC USB identity is internally inconsistent": a
replugged or swapped board is a rebind, not a reconnect); a candidate without exactly one matching
`Connected` row is not yet a reconnect; 600 s, because 120 s and 300 s both closed mid-first-boot.
`revalidateBoundHDC` (988–1015): a cached route passes only as the identical identity freshly
observed at its own topology (or re-resolved through its digest), self-consistent, and at the
recorded topology or the previous alias. `verifyBoundBuild` (657–744): the published model and
build must be configured; the cached route revalidated or a fresh bound wait; one
`-t <key> shell "param get const.ohos.fullname; param get const.product.model"` (15 s, 64 KiB);
`properties(_:orderedKeys:)` (1139–1173): exactly two non-empty lines, an echoed key only in the
command's order, each value non-empty and at most 400 characters; the model, then the build, must
equal the published profile exactly; then `publish`; summary `model`/`firmware`/`hdcIdentitySha256`/
`usbTopology`/`verification: exact-published-profile-and-bound-hdc`, receipts = the wait's lists
plus the property read. `requireSemanticSuccess` (1225–1267): exit 0, not truncated, empty stderr,
else "typed command lacked a clean, complete semantic receipt (exitStatus=N, stdoutTruncated,
stderrByteCount=N, stdoutCapturedBytes=N); last output: <excerpt>" — the output itself never
crosses; `outputExcerpt` keeps the tail as one printable line.

## What Rust now does

- `rust/crates/arkdeck-provider-hdc/src/rockchip_hdc.rs` (every host; no Swift file changes):
  `RockchipHdcObserver::new(&dyn HdcDispatch, &dyn UsbProbe, &dyn Clock)` with `wait_for_hdc`,
  `wait_for_bound_hdc`, `revalidate_bound_hdc`, `verify_bound_build` (up to, not including, the
  publication: it returns `VerifiedBuild { identity, readback, receipts }` for the alias-store owner)
  and `observe_hdc_normal_usb`; `WaitBudget::{DISCONNECT, RECONNECT, BOUND_RECONNECT}` (15 / 120 /
  600 s, 15 s reads, 1 s pause); `ReconnectExpectation` (Swift `RockchipHDCReconnectExpectation`);
  `RockchipHdcFailure::{Failed, OutcomeUnknown}` (Swift `.failed` / `.outcomeUnknown`; a refused
  dispatch is a failed step, an unobservable one parks); `parse_build_properties`, `output_excerpt`,
  `POST_FLASH_BUILD_PROPERTIES_COMMAND` (the one argv token of this surface with a shell
  metacharacter, fixed and never parameterised), and the receipt summaries (`hdc_state_summary`,
  `bound_reconnect_summary`, `hdc_normal_usb_summary`, `VerifiedBuild::summary`). Every reason
  string above is spelled as Swift spells it. The `Clock` port (`SystemClock` in production) is the
  one liberty taken: Swift hardcodes `ContinuousClock` and `Task.sleep`, which is why only its
  `enterLoader` readback deadline is testable.
- `src/live_mode.rs`: `HdcIdentity` (Swift `RockchipRuntimeHDCIdentity`) and
  `UsbProbe::single_hdc_normal_at(usb_topology)` with Swift's default refusal ("topology-bound HDC
  observation is unavailable"), which the callers swallow as Swift's `try?` does.
- `tests/common/mod.rs`: the shared fake HDC driver at its fixed root, with the observe fixture's
  recorded answers or a fragment of the test's own; `tests/live_mode.rs` now uses it.
- Not done here, on purpose: the alias publication and its three-way resolution, the Target
  lineage advance, the reuse cache keyed by the managed-control step id, and the Loader side of the
  transition (`enterLoader`'s `reboot loader` leg, the Loader readback, the evidence prose and
  `signalNumber`) — the next lane-B slice.

## Tests

`cargo test -p arkdeck-provider-hdc` — lib 37/37 (15 in `rockchip_hdc`), `tests/rockchip_hdc.rs`
4/4 and `tests/live_mode.rs` 3/3 (macOS, under the fake's lock), the other integration binaries
unchanged; `cargo clippy -p arkdeck-provider-hdc --all-targets -- -D warnings` clean on the host
and `--target x86_64-unknown-linux-gnu` / `x86_64-pc-windows-msvc` for the library; `cargo fmt
--all -- --check` clean. The unit tests use a scripted dispatch that records every plan, a USB port
scripted by topology and by digest (able to refuse its first lookups), and a clock that advances
only when the wait pauses — so a 600 s wait costs nothing and the number of reads is exact.

| Test | Proves |
| --- | --- |
| `a_reconnect_wait_survives_a_transient_malformed_list` | a 4-column line then the registered row: 2 receipts, 1 pause, every plan `list targets -v` 15 s / 64 KiB (Swift `testWaitForHDCReconnectSurvivesATransientMalformedTargetList`) |
| `a_disconnect_wait_is_proved_by_the_empty_sentinel_not_by_silence` | no output keeps polling, `[Empty]` proves the disconnect; silence until the deadline is "did not disconnect" after exactly the deadline's reads |
| `a_deadline_names_the_last_malformed_read_and_a_zero_deadline_reads_nothing` | the "; last malformed target list read: …" suffix with the parser's reason; a zero deadline dispatches nothing |
| `a_list_read_without_a_clean_receipt_fails_with_swift_s_reasons` | exit 1, stderr, a truncated list (tabs kept in the excerpt), an unobservable dispatch (`OutcomeUnknown`), a refused one (`Failed`), invalid UTF-8 — each with Swift's text, one read each |
| `output_excerpt_keeps_the_tail_as_one_printable_line` | CRLF/non-ASCII to spaces, runs collapsed, tab kept, the last 200 characters behind `…`, only the last 800 bytes looked at |
| `the_bound_reconnect_takes_the_recorded_topology_first` | a rotated serial at the recorded port, one read, the `wait-bound-reconnect` summary |
| `the_bound_reconnect_falls_back_to_the_known_alias_at_its_new_port` | the previous alias found by digest at a new port; neither route until the deadline |
| `a_route_that_drifted_on_both_axes_is_a_rebind_not_a_reconnect` | the alias's digest resolving to a port held by another serial, and a digest that is not its own key's: "internally inconsistent" after one read |
| `a_bound_route_without_its_connected_row_keeps_polling` | another key's row, an `Offline` row, two rows: not a reconnect, until the deadline |
| `a_malformed_expectation_reads_nothing` | a wrong digest, an empty topology, a non-digit topology dispatch nothing; revalidation checks the digest only |
| `revalidation_accepts_only_the_same_route_freshly_observed` | the identical identity passes; another key at the port, or the device moved, does not; a refused first lookup passes on the digest route's second look; the previous alias at a new port passes |
| `build_properties_are_two_ordered_values` | echoed keys, bare values, CRLF, a value with `=`, and the five refusals with Swift's text; 400 characters pass, 401 do not |
| `verify_bound_build_proves_the_device_then_the_model_then_the_build_and_publishes_nothing` | the full flow with the `rebind-and-verify-build` summary and both receipts; model judged before build; nothing read when unconfigured; a revalidated cached route costs one read; a stale one falls back to the wait |
| `the_hdc_normal_usb_observation_uses_the_exact_connect_key_digest` | `Device-1` hashed as its exact bytes; the `observe-hdc-normal` summary |
| `the_properties_command_is_the_two_allowlisted_reads_joined` | the command literal and the three budgets |
| `the_bound_reconnect_after_a_serial_rotation_reads_the_build_once` (subprocess) | one list, then — the cached route revalidated — only the property command on the new key, its single token intact in the driver's log; an inexact build refused after list + read |
| `a_transient_malformed_list_is_re_polled` (subprocess) | the driver's first answer outside the registered family, the second registered: two reads |
| `the_disconnect_wait_needs_the_empty_sentinel` (subprocess) | `[Empty]` in one read; a device still listed is not disconnected when a 600 ms deadline passes, with at least two reads |
| `an_unregistered_read_fails_with_its_reasons` (subprocess) | the driver's exit 23 + stderr as "(exitStatus=23, stderrByteCount=28, stdoutCapturedBytes=0)", the only read being the property command |

## Not run, and why

- No real HDC and no device: whether a DAYU200's first boot after a complete overwrite answers on
  its known key within 600 s is the runbook §5 fact this budget encodes, not something a fake
  proves.
- The USB port is a double: the ArkForge lane serves `single_hdc_normal_at` over `arkforged
  discoverDevices` (SPK-9's preconditions, `spk-9-run.md` §4, still stand).
- The alias publication is not exercised: `verify_bound_build` stops before it by design.

## Facts for the maintainer from the port (not blocking this slice)

1. `waitForBoundHDCReconnect` journals `deadlineMilliseconds: 120_000` (`RuntimeJobEngine.swift`
   9977–9980) while the executor waits 600 s, and `verifyBoundBuild` waits another 600 s under a
   `probeDevice` step that journals only `evidencePolicy`; the journal understates the window five
   times over. The Rust budgets follow the executor.
2. `waitForBoundHDC`'s "internally inconsistent" guard is a hard refusal inside the polling loop:
   one mid-enumeration readback whose topology already drifted and whose digest is not the previous
   alias ends the whole ten-minute wait. Ported as is.
3. `RockchipRuntimeUSBProbing.singleHDCNormal(usbTopology:)`'s default refusal is swallowed by both
   callers, so a probe that never implemented it is indistinguishable from "no board at that port"
   and burns the deadline. Ported as is (the port's default has the same effect).
4. `ParseError::Malformed` is a bare reason in Rust while Swift composes "target output line N:
   <reason>; saw C columns; preview …" (with a credential-redaction regex), so the deadline's
   "; last malformed target list read: …" suffix carries the reason only — T2 text, noted rather
   than reproduced.
5. The same "the store's I/O failure reads as a device verdict" seam the map flagged
   (`"verified post-flash HDC binding could not be persisted"` is `.failed` like an inexact
   readback) is now a boundary: the proof comes back before anything is written.
