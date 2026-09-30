# TASK-XPA-004 — Windows USB device census, local run on the reference host, 2026-09-30

WM1 slice S4: the Runtime's read-only Windows USB device census
(`arkdeck_platform::usb_host_devices` on Windows, `src/usb_device_nodes.rs`), the
counterpart of the macOS I/O Registry census, and `UsbRegistryRelations::system()`
over it. This is a host-only software run. It is not device evidence, not
acceptance and not the DAYU200 USB-properties sample: no board was attached
(no present node carries `VID_2207`), no `hdc` was run, nothing was elevated,
and no driver, device or policy was changed.

Checkout: branch `agent/xpa-004-windows-usb-census-20260930` on `origin/main`
`31c0ac28`. Host: Windows 11 Pro 10.0.26200 x64, a non-elevated Medium-integrity
account (the W0 host of `TASK-XPA-002/windows-host-w0-20260930-run.md`),
`rustc 1.98.1`.

## Census design (provisional property choice)

The census opens a SetupAPI device information set of the present nodes of the
`USB` enumerator (`SetupDiGetClassDevsW`, `DIGCF_PRESENT | DIGCF_ALLCLASSES`),
reads each node's instance ID (`CM_Get_Device_IDW`) and four properties
(`SetupDiGetDevicePropertyW`), and destroys the set on every path. The per-node
rule `UsbHostDevice::from_device_node` fails closed like the macOS per-entry rule.
The mapping below is the crib's candidate mapping, taken as it stands; it stays
provisional until the maintainer's sample
(`dayu200-usb-properties-crib-20260930.md`) confirms or refutes it.

| `UsbHostDevice` field | Windows source | A node is passed over when |
| --- | --- | --- |
| (entry) | device-level instance ID `USB\VID_hhhh&PID_hhhh\<suffix>` | another enumerator, an `&MI_xx` interface node, a malformed ID |
| `vendor_id`, `product_id` | first `USB\VID_…&PID_…` entry of `DEVPKEY_Device_HardwareIds` | missing, wrong type, or numbers other than the instance ID's |
| `serial` | instance ID suffix, as it is | empty, or holding `&` (a Windows-generated, port-derived ID) |
| `topology` | first `DEVPKEY_Device_LocationPaths` entry → decimal of the first 8 bytes (BE) of its SHA-256 | missing, wrong type, or empty |
| `product_name` | `DEVPKEY_Device_BusReportedDeviceDesc` | never (optional) |
| `registry_entry_id` (attachment) | `DEVPKEY_Device_LastArrivalDate` (`FILETIME`) | never (absent or zero → none, and then no relation is formed) |

Why a hashed topology: `UsbRelation::is_usable` accepts only a canonical decimal
location, and Windows has no packed `locationID`. The location path names the
port chain up to the host controller, so its digest is stable for one port and
differs between ports; it is never byte-equal to a macOS topology.

## Local targeted checks

| Command | Result |
| --- | --- |
| `cargo fmt --all -- --check` | pass |
| `cargo clippy --workspace --all-targets -- -D warnings` | pass (Windows only) |
| `cargo test -p arkdeck-platform` | pass; lib 27 tests, including 8 new `usb_device_nodes` tests and the extended `unavailability_names_its_cause` |
| `cargo test -p arkdeck-provider-hdc` | pass; new `tests/windows_usb_census.rs` 2 tests |
| `git diff --check` | clean |

macOS and Linux were not built here (no other target installed); the `cfg`
pairings were re-read by hand: the rule and its unit tests compile everywhere,
the SetupAPI module, `usb_host_devices` export and live tests are `cfg(windows)`,
and `UsbRegistryRelations::system()` is `cfg(any(target_os = "macos", windows))`.
CI decides.

## Live census on this host (shape only)

`usb_device_nodes::tests::the_host_census_answers_with_well_formed_entries`: the
census answered. It listed 2 device-level identities with a serial, both with an
attachment; every entry had a non-empty serial without `&` or `\`, a canonical
decimal topology, and no zero attachment. A read-only PowerShell cross-check
(`Get-PnpDevice -PresentOnly`, instance IDs matched against
`^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}\\[^&\\]+$`, count only) also found 2. The
serials, instance IDs, location paths and arrival times of these devices were
not printed and are not recorded; they are not DAYU200s.

`windows_usb_census::the_system_census_reader_answers_on_this_host`:
`UsbRegistryRelations::system()` answered 0 DAYU200 relations (no board attached).

## GJ-1 hop with a fake census entry

`windows_usb_census::a_windows_census_node_proves_the_candidate_and_holds_the_adoption`
runs the `device candidates` / `target adopt` relation proof over the Windows rule
in-process: a synthetic HDC-normal DAYU200 node (placeholder serial) beside an
other-vendor device, the board's interface node, a generated-suffix node and the
Loader personality; a scripted HDC answering `-v` and `list targets -v`.

- `NoUsbRelations` (what Windows composes today): `generationScoped`.
- The census through `UsbRegistryRelations::new`: the interface and generated
  suffix are passed over; the candidate is `relationProven`, the relation is
  usable, and `adoption_holds` over the census and the identity readback.
- A new arrival between the brackets: `generationScoped`; a new arrival before
  adoption: the final check fails.
- No bus-reported name, a zero arrival, or no serial: `generationScoped`.

## What is composed on Windows now, and what is missing

`UsbRegistryRelations` needs no macOS-only piece, so `system()` now reads the
Windows census. The Windows daemon still composes no relation reader: the
owners it would feed (`Host::with_usb_registry_relations`, the registered/managed
HDC, the Target observation and adoption owners, `development_usb`) are
compiled on macOS only (`arkdeck-agentd/src/host.rs`, `main.rs`), and the Windows
`serve` refuses the development and production compositions. Composing it waits
for those owners' Windows port (GJ-1 hop 1/4: G17a HDC registry, G06/G07 managed
server). Nothing in agentd changed.

## Open questions for the DAYU200 sample

1. Is the DAYU200's instance-ID suffix its iSerialNumber, byte-equal (letter
   case included) to the HDC connect key? If Windows changes the case, relations
   would never match the candidate and would fail closed.
2. Does the board report `BusReportedDeviceDesc` as `HDC Device`? Without it the
   board is never the registered HDC-normal DAYU200.
3. Does `LastArrivalDate` change on every attachment (`removed`/`replugged`
   phases) and stay fixed within one?
4. Does the first location path survive a replug into the same port?
