# TASK-XPA-004 — the Windows USB census opens with the stable identity of CHG-2026-078 §4

Change: CHG-2026-074-shared-rust-runtime-core. Consumes CHG-2026-078 r2 (approved), design §4
and maintainer ruling 2026-10-04, items 4 and 5; the field registration is TASK-WHR-003 (the
Windows profile's USB census row). Base: protected `main` `4f5d238c` (#2466). Host: the
Windows 11 x64 reference host, non-elevated, NTFS. No board was attached, no `hdc` ran, no
driver, device or policy changed, and nothing identifying was printed. Host tests are not
Windows acceptance or device evidence.

## Before this change

`arkdeck_platform::usb_device_nodes` (#2334) read the Plug and Play device tree by the USB
crib's candidate mapping, and `CENSUS_MAPPING` (#2402) held every row `Tbd`, so
`usb_host_devices()` answered `RegistryUnavailable::MappingUnconfirmed` and
`UsbRegistryRelations::system()` refused on Windows (`windows-usb-mapping-gate-run.md`). The
2026-10-04 DAYU200 sample (`dayu200-usb-properties-20261004-run.md` and its sanitized
`usb-*.json`) then showed that the rule as built would never relate the board: the instance ID
spells the serial in upper-case hex, the HDC connect key is lower-case hex, and the relation
compares bytes.

## The change

- **Serial fold (ruling item 4).** The instance-ID suffix is ASCII-lowercase folded
  (`to_ascii_lowercase`) before it becomes `UsbHostDevice::serial`, the value the relation
  compares with the connect key. The connect key is not rewritten. Non-ASCII characters are
  left as they are.
- **Device identity (ruling item 5).** The long-term identity is the folded serial. It agrees
  with `stable_identity_sha256_for_serial`, which already lower-cases.
- **Present only (ruling item 5).** The per-node rule now also reads `DEVPKEY_Device_IsPresent`
  (`NodeProperty::IsPresent`, `NodeValue::Boolean`, decoded from `DEVPROP_TYPE_BOOLEAN`:
  `DEVPROP_TRUE`/`DEVPROP_FALSE`, any other byte `Other`). A node that does not answer `true`
  is passed over. This holds besides the census's `DIGCF_PRESENT`, so the rule itself refuses a
  phantom, which keeps its last attachment's location, container and arrival.
- **Attachment (ruling item 5).** One attachment is (instance ID, `LastArrivalDate`).
  `registry_entry_id` stays the arrival `FILETIME`. A relation carries the instance ID as its
  vendor, product and folded serial, so two reads agree only when the whole pair does.
- **Topology per attachment (ruling item 5).** The hashed first location path (ruling 11) is
  unchanged in spelling but documented as valid only within one attachment. It is never part of
  the long-term identity. A replug into the same connector that enumerates on another root-hub
  port (`USB(10)`/`HS10` to `USB(26)`/`SS10` in the sample) is the same identity in a new
  attachment. A location that moves under one arrival between the two brackets of a reading is
  not an unchanged relation and proves nothing.
- **Port-derived suffix.** A suffix holding `&` gives no serial and no identity, in either case
  (unchanged rule, now tested in upper case as well).
- **The gate opens.** Every `CENSUS_MAPPING` row is `Confirmed`, with its source text updated.
  `usb_host_devices()` and therefore `UsbRegistryRelations::system()`, the development
  composition's registry reader, and the Windows Flash facts, Loader binding and alias consumers
  now read the census on Windows. The gate itself stays: a row set back to `Tbd` closes it.
- **macOS unchanged.** `usb_registry` (the I/O Registry census), its `usb_host_devices` and the
  macOS bytes are untouched. `NodeProperty`/`NodeValue` are compiled on every platform but used
  only by the Windows census and its tests.

## Measured

- `arkdeck-platform` unit tests (`usb_device_nodes`):
  - an upper-case suffix folds to the lower-case connect key and reads as the same device as the
    lower-case spelling; a non-ASCII letter is not folded;
  - a phantom (`IsPresent` false, absent, of another type) is never an entry, including the
    sample's remembered `PID_350A` loader node; the same node present is;
  - a new arrival of the same instance on another location path is the same serial and numbers
    with another attachment and topology;
  - port-derived suffixes, lower and upper case, are no serial;
  - every mapping row is confirmed, and a `Tbd` row closes the gate;
  - on this host, `usb_host_devices()` answers, and every serial it reads is free of ASCII
    upper case (shape only).
- `arkdeck-provider-hdc/tests/windows_usb_census.rs`:
  - a node whose instance ID spells the serial in upper case proves the scripted HDC's
    lower-case candidate (`relationProven`) and holds the adoption's final check; a phantom
    loader beside it is passed over;
  - a phantom board node proves nothing (`generationScoped`);
  - a USB 2 then USB 3 attachment each prove a relation with one stable identity, a new
    attachment ID and a new location; the first attachment's adoption does not hold over the
    second;
  - a topology moving within one attachment proves nothing;
  - a port-derived suffix, either case, proves nothing;
  - `UsbRegistryRelations::system()` answers on this host, every relation usable and lower
    case (0 DAYU200 relations: no board attached).
- `arkdeck-hoststore/tests/windows_target_owners.rs`: the oracle board, now spelt in upper case
  in its instance ID, is adopted once as on macOS.
- `arkdeck-agentd/tests/windows_flash_lane_process.rs`: `flash.bootloader-status` now answers
  (`ok`), `absent` with no observation on a host without a Rockchip board, instead of
  `USB registry unavailable`.

## Delegated minor decisions, pending the next rulings batch

1. **Presence is read on the node as well.** `DEVPKEY_Device_IsPresent` must be `true`. This is
   a second check besides `DIGCF_PRESENT`, so that the per-node rule (and its tests) state
   ruling item 5 directly. The 2026-10-04 sample shows the property on every node, `true` when
   present and `false` on phantoms.
2. **The fold is ASCII only.** Ruling item 4 says ASCII lowercase. A non-ASCII suffix is kept
   as it is, and the relation's own rule (printable ASCII serial) then refuses it.
3. **`MappingUnconfirmed` stays.** It is now unreachable in production, but it keeps the one
   place that can close the census again.

## Not in this change

- No Windows HDC tuple is registered by this change (CHG-2026-078 TASK-WHR-002). The Windows
  Target observation reads relations only beside a registered managed HDC, so the HDC
  provider's consumer adoption on Windows waits for that registration.
- No device acceptance: the census was exercised over synthetic nodes and this host's tree
  without a board.

## Local targeted checks

With `CARGO_TARGET_DIR=D:/cargo-target/xpa004-usb`, `CARGO_BUILD_JOBS=2` and
`ARKDECK_DEV_SIGNER_THUMBPRINT` exported:

| command | exit |
| --- | ---: |
| `cargo fmt --all --check` | 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 |
| `cargo clippy --target aarch64-apple-darwin --workspace --all-targets -- -D warnings` (build-script tools stubbed; type and lint only) | 0 |
| `cargo clippy --target x86_64-unknown-linux-gnu --workspace --all-targets -- -D warnings` (same) | 0 |
| `cargo test -p arkdeck-platform -p arkdeck-provider-hdc -p arkdeck-hoststore` | 0 (881 passed, 0 failed, 10 ignored) |
| `cargo test -p arkdeck-agentd -p arkdeck-cli` | 0 (356 passed, 0 failed, 0 ignored) |
| the census tests (`usb_device_nodes`, `windows_usb_census`, `windows_target_owners`, `windows_flash_lane_process`) with `TEMP`/`TMP` on an 8.3 short path on C: | 0 (19 + 6 + 4 + 3 passed) |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 (0 errors, 0 warnings) |
| `git diff --check` | 0 |

The only skips are the known wildcard-listener cases outside GitHub Actions. The ignored tests
are the existing measurements and fixtures.

## CI

The PR's run, recorded by a follow-up.
