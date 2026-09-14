# TASK-XPA-016 — M1 run record: the target observation port

Change: CHG-2026-074-shared-rust-runtime-core@r11. Milestone M1 (GJ-1), lane B's platform
executor, at lane A's request (B1, 2026-09-14): the physical side of a target observation —
the USB relation port with its usable-relation rule and a fail-closed production stand-in, the
bracketed reading over `HdcDispatch`, the stamp's relation rule, and the bootstrap observation
reads (`-v`, `list targets -v`, the exact-row identity confirmation) — so that lane A's Target
observation owner (`target.adopt`/`availability`, the HAR path's untargeted runs) has a port to
build on and the fixture's shell fake can drive it. Host measurement only — not hardware,
platform or conformance evidence (POL-VERIFY-001, POL-MODE-001). No device, no HDC server, no
daemon, no IOKit.

Base: protected main `2c142be6` (#1948). Branch `agent/xpa-016-usb-relation-port-20260914`; no
stacking. Files: `arkdeck-provider-hdc/src/target_observation.rs` (new), its export block in
`lib.rs`, `tests/target_observation.rs` (new), this record, one README section. No
`arkdeck-hoststore`, `arkdeck-agentd`, `arkdeck-control`, Swift or contract change.

## What was missing

Swift's `TargetObservationCoordinator` (`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Bootstrap/
TargetObservationCoordinator.swift`) brackets every device list with two independent reads of
the USB relations (`TargetUSBRelation.registeredDAYU200()` over IOKit: serial, decimal location,
registry entry id, vendor 0x2207, product 0x5000) and lets a candidate be adopted only through a
relation proved that way; `ProviderBootstrapObservation` reads the tool version, the candidate
list and the identity confirmation through the provider's typed actions. Rust had no USB
enumeration at all (`UsbProbe` answers single-device questions for the Rockchip flash path and
carries no attachment identity, vendor or product), and its only candidate list
(`HdcReadOnlyProvider::list_candidates`) admits only the registered production digests, so the
fixture's shell fake cannot drive it.

## What Rust now has

`arkdeck_provider_hdc::target_observation`:

| Item | Swift | Rule |
| --- | --- | --- |
| `UsbRelation { serial, location, attachment_id, vendor_id, product_id }` | `TargetUSBRelation` | `is_usable`: a printable ASCII serial of 1–1024 bytes without `:`, a canonically spelled decimal location, a non-zero attachment, vendor `0x2207`, product `0x5000`; `from_value`/`to_value` in the oracles' shape `{attachmentId, location, productId, serial, vendorId}` |
| `UsbRelations` | the `usbRelations` closure | `relations() -> Result<Vec<UsbRelation>, String>`; any closure implements it; a failing read fails the reading (Swift: the observation loses continuity) |
| `NoUsbRelations` | — | the production stand-in until the ArkForge lane's `arkforged discoverDevices` client reads the registry (r11's design table keeps IOKit out of this crate): no relation is ever observed, so no candidate is proved and no adoption can pass; the device list stays readable |
| `Reading::take(dispatch, relations)` | `snapshot`'s in-flight task | the relations, `list targets -v`, the relations again — each failure ending the reading |
| `Reading::validate` | `stamp`'s guard | at most 1000 candidates, each connect key 1–1024 bytes, else "device snapshot exceeds its bounds" |
| `Reading::rows` | `stamp`'s rows | ordered by connect key then state (byte order); a relation only when the connect key is unique in the reading and exactly one usable relation names its serial before, the same after; `continuity` `relationProven`/`generationScoped` |
| `observe_tool_version` | `observeToolVersion` | `-v` judged by the client-version parser, "tool version could not be verified" otherwise |
| `list_candidates` | `listCandidates` | `list targets -v` parsed with the highest registered version; a failed verdict as `code: detail`, an unknown one as its reason, an unsupported one as "candidate list could not be verified" |
| `observe_device_identity` | `observeDeviceIdentity` | the exact `Connected` row for the connect key (and the adopted identity when given) confirmed by `Action::ObserveDevice`'s verdict, answering `{"serial": <connect key>}`; the refusals as Swift spells them |
| `usable_relations`, `adoption_holds` | `adopt`'s live filter and final guard | the live relations for the serial are exactly the proved one and the readback names its serial |
| `stable_identity_sha256_for_serial` | `DeviceBootstrapMachine.stableIdentitySHA256(serial:)` | SHA-256 of the serial trimmed and lowercased |

What stays with the Target owner: minting observation ids and generations over a reading
(unchanged facts keep the generation, a state change advances it, a proved relation keeps its
id), following a reference, the adoption's snapshot checks and the store write.

## Measurement

```
cargo test -p arkdeck-provider-hdc --lib target_observation        6 passed
cargo test -p arkdeck-provider-hdc --test target_observation       1 passed
cargo clippy -p arkdeck-provider-hdc --all-targets -- -D warnings  clean
cargo fmt --all --check                                            clean
```

The unit tests pin `is_usable` (each bound, the network key, the zero attachment, the
non-canonical location, the foreign vendor and product), the oracle shape round trip, the
bracket rule (a reconnect between the reads, no relation, a duplicate connect key, two usable
relations for one serial, an unusable one, other serials ignored, the state not being the
proof), the ordering and bounds, `adoption_holds`, the serial digest (equal to the
`DeviceObservationIdentityContractTests` vector for `150100424a544e4600`), and the port over a
scripted dispatch (the version, the list with and without relations, a failing reader, the
identity readback and its `targetConfirmationMismatch` refusal, the empty list, the empty
answer, the unsupported version and the non-UTF-8 answer). `tests/target_observation.rs`
drives the observe fixture's shared fake HDC driver through the real process dispatch: the
version `3.2.0d`, the one candidate unproved without a reader and proved with one, the
identity readback and the adoption check, the driver's log (`-v`, then `list targets -v`
three times, never with `-t`), and the fixture's `otherDevice` and `emptyVersion` modes.

## Declared differences from Swift (T1/T2)

- `list_candidates` returns the parser's rows (connect key, transport, state); Swift's port
  rebuilds `BootstrapCandidate`s from the verdict's `connectKeys` summary and drops the
  transport.
- The parser keeps the transport lowercased (`usb`), as the ported parser does.
- The production relation reader is the fail-closed stand-in; Swift reads IOKit. This is a
  declared gap of GJ-1 on the Rust daemon until the arkforged client lands, not a measurement.

## What stays with other owners

- The Target observation owner in `arkdeck-hoststore` (lane A, A2): stamping, following,
  generations, `target.adopt`/`target.availability`.
- The arkforged-backed `UsbRelations` implementation (lane D, SPK-9), or an interim IOKit
  reader in `arkdeck-platform` if the maintainer prefers one before that.
