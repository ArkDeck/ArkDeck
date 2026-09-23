# TASK-XPA-017 — The production composition reads trusted USB relations, not activated

Base: protected main `d5f9f6f22` (#2135). This is the follow-up that #2136's record
([production-composition-run.md](production-composition-run.md)) named for when #2135's reader
([trusted-usb-relations-rust-run.md](../TASK-XPA-016/trusted-usb-relations-rust-run.md)) merged: the
production composition (`ARKDECK_RUNTIME_COMPOSITION=production`) now reads the Runtime's own USB
relations beside the registered HDC it starts as its managed server. Nothing activates that
composition: no LaunchAgent, plist, receipt, installed binary or service changes. No Catalog
operation, contract input, schema, capability or trusted-fact rule, evidence format or completion
status changes. Everything below is host-process evidence, never REAL_DEVICE_PASS; the Golden
Journey count stays 0/5.

## What changes for a user

- With `ARKDECK_HDC_PATH` (a registered HDC, started as the managed server) the start no longer
  prints `composes no trusted USB relations: no reader is composed; …`, and its owners line names
  `hdc, managedHdc, usbRegistryRelations`. Its Target observations read a fresh census of the
  host's I/O Registry, the path the isolated owner has taken beside its managed registered HDC since
  #2135, so a DAYU200 in HDC-normal mode can be proved (`relationProven`) and adopted. This slice
  did not run it against a device.
- Without `ARKDECK_HDC_PATH` nothing changes: no HDC and no reader, nothing is read, and
  `device.observations` and `target.adopt` answer `rejected`.

## Swift semantics

Swift's daemon composes `TargetObservationCoordinator(…, usbRelations: { try
TargetUSBRelation.registeredDAYU200() }, …)` (`main.swift:1246-1248`) in every standalone daemon,
beside its `HeadlessHDCServerHost`. Each snapshot reads the relations before and after
`list targets -v` (`TargetObservationCoordinator.swift:113-115`), and an adoption reads them once
more.

## What this slice changes

- `production::with_trusted_usb(host, managed, registry)` applies the isolated owner's rule,
  `development_usb::relation_source(registered, managed, relations)`, with `registered = managed`
  and no relation file. Its registry selects only a published HDC and its managed server runs that
  selection, so a managed HDC is a registered one. `main.rs` refuses
  `ARKDECK_DEVELOPMENT_USB_RELATIONS` without a development HDC, and a development HDC without a
  development root. `Registry` composes the reader; otherwise the host keeps `NoUsbRelations`.
- `production::compose` applies it after the HDC step with `UsbRegistryRelations::system()` and no
  longer adds the omitted line. Composing reads nothing; every observation takes its own census.
- `Host::with_usb_registry_relations` composes the Runtime's own reader, and the owner census names
  it `usbRegistryRelations` (after `managedHdc`). `with_usb_relations` (a development file, a test's
  source) clears that name. The isolated owner's `Registry` arm in `main.rs` uses the same builder:
  the same reader and the same behaviour, now named in its census too.
- README ("Trusted USB relations", "macOS production composition"), a tasks.md note under
  TASK-XPA-017, and #2136's record: its USB row, its fail-closed row and "Not composed, and why".

## Fail-closed paths

| Condition | Answer |
| --- | --- |
| no `ARKDECK_HDC_PATH` | no reader composed and nothing read; `device.observations` and `target.adopt` answer `rejected` |
| an HDC the registry cannot select, a pending selection, an occupied endpoint | the start ends (exit 69) before any reader is composed |
| beside the managed HDC: a census that cannot be taken, a board without an attachment or not in HDC-normal mode, a duplicate serial, a replug between reads | #2135's paths, unchanged: `internalError` in Swift's words with the continuity broken, or the candidate unproved; adoption refused |

## Declared differences from Swift

- Without an HDC, Swift still composes its coordinator, and a snapshot takes a census before its
  refusing dispatcher fails the device list. Rust composes no reader and no observation owner there
  and answers `rejected` without reading the registry, as since #2136. Neither observes or adopts
  anything.
- #2135's D1 (the census answers unavailable when its iterator did not stay valid) applies
  unchanged.

## Tests

- `production::tests::the_runtimes_own_usb_relations_are_read_only_beside_the_managed_registered_hdc`
  (new) hands the reader a census in place of the host's I/O Registry: a DAYU200 in HDC-normal mode
  and another vendor's device. Beside the managed HDC, `with_trusted_usb` composes the reader and the
  census names `usbRegistryRelations`; composing reads nothing, and each read takes one census and
  proves only the board. Replaced by another source, the reader is no longer named. Without the
  managed HDC nothing is composed or read, and no relation is answered. Nothing depends on this
  host's USB devices; a test-only accessor reads the Host's reader.
- `production::tests::compose_opens_every_owner_in_swifts_layout_below_the_home`: without an HDC
  the owner census is exactly as before (no `usbRegistryRelations`), and the omitted lines are
  exactly the three expected ones.
- `tests/production_composition.rs`: the real daemon without an HDC names no reader among its
  owners, prints no line about USB, and answers `target.adopt` `rejected` as it answers
  `device.observations`. The composition beside a managed registered HDC cannot run here: only a
  published HDC executable is selected, and no test starts one.
- Mutants, each caught and restored by checksum:
  1. the reader composed whatever the HDC: 2 unit tests (the new test, the owner census) and 2
     process tests (the owners line) fail;
  2. the reader never composed: the new test fails;
  3. the builder not naming the reader in the census: the new test fails.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-1330-rust-target`, `CARGO_BUILD_JOBS=2`; logs
`/private/tmp/arkdeck-s14-*.log`.

- `cargo fmt --all --check`: 0.
- `cargo clippy --locked -p arkdeck-agentd --all-targets -- -D warnings` (agentd has no direct
  dependents): 0; again for `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc`: 0.
- `cargo build -p arkdeck-cli`, then `cargo test --locked -p arkdeck-agentd --no-fail-fast`: 0 —
  9 result lines, 116 passed, 0 failed, 0 ignored, among them `production::tests` (8) and
  `tests/production_composition.rs` (8).
- `sh scripts/check-sdd.sh`: 0, 0 errors and 0 warnings.
- After every run: no fake HDC server and no temporary home was left; the installed Swift daemon and
  its HDC were not touched.
- Not run: `generate-contract.py --check` and `check-contracts.py` (no contract input changed),
  `check-readonly.py` (the default standalone and the crate edges are unchanged), Swift/App (no
  Swift change), any device.

## CI

Pending.
