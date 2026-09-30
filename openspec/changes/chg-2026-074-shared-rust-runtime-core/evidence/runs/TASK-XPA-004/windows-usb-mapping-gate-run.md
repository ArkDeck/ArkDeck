# TASK-XPA-004 — the Windows trusted USB relation census behind CHG-2026-078 §4, closed until the sample

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase WM1, slice CI2-B (part 2 of the
remaining XPA-004 work). Base: protected `main` `86d2f2b8` (#2398). Host: the Windows 11 x64
reference host, non-elevated, NTFS. No board was attached, no `hdc` ran, no driver, device or
policy changed, and nothing identifying was printed. Host tests are not Windows acceptance or
device evidence.

## Before this change

The Windows census (#2334, `arkdeck_platform::usb_device_nodes`) read the Plug and Play device
tree by the USB crib's candidate mapping. Its module documentation called that mapping
provisional, but nothing held it: `usb_host_devices()`, which feeds
`UsbRegistryRelations::system()` and the development composition's registry relation reader,
answered from the unconfirmed rule. A board's relation could therefore have been proved from
properties the DAYU200 sample (CHG-2026-078 WHR-003) has not yet confirmed. The field mapping
itself is CHG-2026-078 design §4, where every sample fact is `TBD(sample)`.

## The change

- **The mapping in one place.** `CENSUS_MAPPING` holds CHG-2026-078 §4, one row per census
  field:
  - device-level node;
  - vendor/product id;
  - serial;
  - topology (ruling 11's hash);
  - product name;
  - attachment.

  Each row has its Windows source and a `CensusSample` verdict, and every row is `Tbd`. When the
  processed sample confirms a row, it is set `Confirmed`, and the rule changes if the sample
  refutes the source. `unconfirmed_census_fields()` names what is left.
- **Fails closed until filled.** `usb_host_devices()` (Windows), the census a USB relation is
  proved from:
  - answers `RegistryUnavailable::MappingUnconfirmed`, reading nothing, while any row is `Tbd`;
  - displays "USB registry unavailable: the Windows census field mapping awaits the DAYU200 USB
    sample (CHG-2026-078 WHR-003); TBD(sample): device, vendorId/productId, serial, topology,
    productName, attachment".

  So `UsbRegistryRelations::system()` refuses: its relation read is
  `admissionRejected("USB registry unavailable")`, and an observation over it is refused before
  any device list is read. The development composition's registry reader is refused the same
  way. macOS is unchanged: its `usb_host_devices` is the I/O Registry census, and the new
  variant never occurs there.
- **Diagnostics and tests keep the unconfirmed rule.** `usb_device_node_census()` reads the same
  nodes by the same provisional rule, and is never a relation source.
- **When the sample lands.** Setting every row `Confirmed` is the one edit that opens the
  trusted census; the gate needs no other change.

## Measured

- `arkdeck-platform` unit tests:
  - all six fields are unconfirmed, and a mapping with none left opens the gate;
  - the refusal names every `TBD(sample)` field;
  - `usb_host_devices()` answers `MappingUnconfirmed` on Windows;
  - the host census through `usb_device_node_census()` still answers well-formed entries.
- `arkdeck-provider-hdc/tests/windows_usb_census.rs`:
  - `UsbRegistryRelations::system()` refuses;
  - a `Reading` over it is `admissionRejected("USB registry unavailable")`, and the scripted HDC
    is asked for nothing;
  - this host's nodes through `usb_device_node_census()` still form only usable HDC-normal
    DAYU200 relations (0 on this host, since no board is attached);
  - the synthetic-node relation proof (`UsbRegistryRelations::new` over the rule) is unchanged.

## Local targeted checks

With `CARGO_TARGET_DIR=D:\cargo-target\ci2-usb`, `CARGO_BUILD_JOBS=4` and
`ARKDECK_DEV_SIGNER_THUMBPRINT` exported:

| command | exit |
| --- | ---: |
| `cargo fmt --all --check` | 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 |
| `cargo test -p arkdeck-platform -p arkdeck-provider-hdc -p arkdeck-agentd --no-fail-fast` (after `cargo build -p arkdeck-cli`) | 0 (408 passed, 0 failed, 2 ignored) |
| the census tests (`windows_usb_census`, `usb_device_nodes`) with `TEMP`/`TMP` set to an 8.3 short path on C: | 0 |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 (0 errors, 0 warnings) |
| `git diff --check` | 0 |

## CI

To be recorded by the follow-up.
