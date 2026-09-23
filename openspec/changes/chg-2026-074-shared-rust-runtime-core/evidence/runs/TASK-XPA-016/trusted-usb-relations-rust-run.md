# TASK-XPA-016 — the Runtime's own trusted USB relations on Rust (M1, GJ-1)

Base: protected main `afde8a42ac753d199f4078e91aca56b788533589` (#2134). Branch:
`agent/xpa-016-trusted-usb-relations`. CHG-2026-074, M1 (GJ-1), G5 queue slice 5.

This is a host-only change. No device was attached, no HDC was run against a device, and the
installed Runtime (its `hdc` server and `com.arkdeck.agentd`) was not touched. Nothing here is
device evidence (POL-VERIFY-001, POL-MODE-001), and "GJ on Rust" stays 0/5. No Swift source,
control schema, corpus, Catalog, entitlement, `openspec/specs` or constitution change.

## The decision this implements

G5 queue Q1 asked where the trusted USB relation comes from. The coordinating session, under the
maintainer's delegation, ruled **Q1=B** on 2026-09-24. ArkDeck reads the I/O Registry itself,
read-only, inside `arkdeck-platform` (its one FFI crate). That is the same trusted source Swift reads
today. The ArkForge cross-repository patch (`arkforge-usb-observation.patch`) is not submitted; it was
read for reference only. Moving the read back into ArkForge is to be reconsidered after M4.

This departs from one row of the r11 design table in
`docs/design/cross-platform/rust-core-cross-platform-architecture.md`: `RockchipDeviceBinding`
(IOKit USB enumeration) is to be wrapped through `arkforged discoverDevices`. That row now carries an
interim note naming this ruling.

No OpenSpec or Constitution clause names the mechanism. POL-TARGET-001 and REQ-DEV-003 set the
evidence baseline, which is a physical relation observed independently of the connect key. Swift
already meets that baseline with this very read. So the ruling needs no change artifact, and this
slice does not stop for one.

## What a user sees

Before this change, `target adopt` on the isolated Rust daemon refused every candidate with
`admissionDenied` ("this observation has no independently proved physical relation"). That held even
beside the registered HDC the owner starts as its managed server
(`ARKDECK_DEVELOPMENT_HDC_SERVER=managed`), unless the caller named a relation file and acknowledged
it (#1988, #2023).

Now, in that composition and with no relation file:

- `device observations` proves a DAYU200 in its HDC-normal personality (`relationProven`) exactly as
  Swift's daemon does;
- `target adopt` adopts it;
- every uncertain case still fails closed (see "Fail-closed paths" below).

Some compositions are unchanged:

- Beside a fixture HDC, the owner still reads no relations, so the host's own devices can never prove
  a fixture's candidates.
- A named relation file (beside the fixture, or acknowledged beside the registered HDC) still stands
  in for any reader, and its startup refusals are unchanged.
- The standalone daemon and the facade compose no HDC. Queue slice 6 (the production composition)
  has to compose this same reader beside its managed registered HDC.

## Swift semantics (the oracle)

The oracle is Swift's source. The census input is the live registry, which no fixture can record, so
each rule is ported with its own synthetic-entry test instead.

1. **Composition.** `ArkDeckAgentDaemonMain/main.swift:1248` gives `TargetObservationCoordinator`
   `usbRelations: { try TargetUSBRelation.registeredDAYU200() }`, so every read is a fresh census.
   The coordinator reads relations before and after `list targets -v`, then once more before an
   adoption commits.
2. **Census.** `RockchipProductUSBProbe.systemIdentities()`, in
   `ArkDeckWorkflows/RockchipDeviceBinding.swift:1034-1072`:
   - The census is `IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"))`.
     If that is not `KERN_SUCCESS`, it throws `RockchipFlashExecutionError.admissionRejected("USB registry unavailable")`.
   - For each entry it reads `idVendor`, `idProduct` and `locationID` as `NSNumber`, and the serial
     as `String` from `USB Serial Number`, else `kUSBSerialNumberString`. An entry missing any of
     these is passed over.
   - `uint16Value` keeps the low sixteen bits of the vendor and product, and the topology is
     `String(location.uint64Value)`.
   - `USB Product Name` is optional.
   - The attachment is `IORegistryEntryGetRegistryEntryID`, kept only when that call succeeds and
     the ID is not zero.
   - There is no deduplication, no second read of an entry, no bound, and no check that the iterator
     stayed valid. Every object is released.
3. **Filter.** `TargetUSBRelation.registeredDAYU200()` (`Bootstrap/TargetObservationCoordinator.swift:13-20`)
   keeps each identity that has an attachment and passes `isHDCNormal`
   (`RockchipDeviceBinding.swift:902-908`): vendor `0x2207`, product `0x5000`, and a product name that
   is exactly `HDC Device` once `"` and spaces are trimmed from both ends. The board reports the name
   in quotes. Each kept identity becomes `TargetUSBRelation(serial, location: topology, attachmentID, vendorID, productID)`.
4. **Judgement.** The coordinator's rule has been in Rust since #1952/#1959 and is unchanged here.
   - `isUsable` requires 1–1024 printable ASCII bytes with no `:`, a canonical decimal location, a
     non-zero attachment, and `2207:5000`.
   - A candidate is proved only when exactly one usable relation names its serial (the connect key)
     in both reads, unchanged, and no other row shares its key.
   - A replug (new attachment), a moved port, a vanished board or a duplicate serial leaves the
     candidate unproved. `target.adopt` then answers `admissionDenied`, or `targetTrustPending` when
     the candidate is Unauthorized.
   - An adoption reads the bracket again, then the tool version and the identity readback, then the
     live relations once more. The live usable relations for the serial must be exactly the proved
     one; otherwise the answer is `factsDrifted`.
5. **Failure.** When the census throws, the reading fails and the coordinator drops its snapshot. That
   breaks continuity: the next reading mints new observation IDs, and a reference taken earlier no
   longer adopts. The daemon's catch-all (`AgentDaemon.swift` `targetObservationRequest`) answers
   `internalError` with `"\(error)"`, which is `admissionRejected("USB registry unavailable")`.
6. **Where the relation is used.**
   - It binds to HDC through serial == connect key.
   - Its serial gives the Target's `stablePhysicalIdentitySHA256`, the SHA-256 of the trimmed,
     lowercased serial, and the Target ID `TGT-` followed by the first 12 hex digits.
   - It gates adoption step 5 ("proved USB relation") and the final drift check.
   - `device.observations` reports `relationProven` and `adoptedTargetId` only for proved rows.

## Rust implementation

- **`arkdeck-platform` `usb_registry.rs` (new).**
  - `usb_host_devices()` is Swift's census.
  - `registry_census(class, read)` is the same read for any registry class. It matches the class,
    walks the iterator, and reads properties with `IORegistryEntryCreateCFProperty`. It opens no
    device or interface, sends no USB request, and claims, changes or writes nothing.
  - Every I/O Kit reference (`Held`) and every create-rule CF object (`Owned`) is released on every
    path, and each census opens its own autorelease pool.
  - `UsbHostDevice::from_entry` is the per-entry rule over a `RegistryEntry`. `CFNumber` values are
    read as a signed 64-bit integer and `CFBoolean` values as 1 or 0, which is what `as? NSNumber`
    accepts. `CFString` values are decoded from UTF-16 with U+FFFD for an unpaired surrogate, as a
    Swift `String` reads one.
  - A census that cannot be taken is `RegistryUnavailable`. With no entry of the class, the kernel
    answers `KERN_SUCCESS` with no iterator, and that is an empty census.
- **`arkdeck-platform` `autorelease_pool.rs` (new).** The per-call pool guard #2129 added to
  `host_calendar.rs` now lives here and is shared. The calendar keeps its behaviour, and its
  regression test passes.
- **`arkdeck-provider-hdc` `target_observation.rs`.**
  - `is_dayu200_hdc_normal` and `registered_dayu200_relations` are Swift's filter.
  - `UsbRegistryRelations` is the `UsbRelations` port over a census: `system()` reads the host's, and
    tests hand it their own.
  - A census that cannot be taken fails the read with Swift's words,
    `admissionRejected("USB registry unavailable")`.
- **`arkdeck-agentd`.**
  - `development_usb::relation_source(registered, managed, relations)` decides the source. A named
    file is the `File` source, as before. Beside a registered HDC this owner started as its managed
    server, the source is `Registry`. Otherwise it is `Nothing`.
  - `main.rs` composes that source. `DevelopmentHdc` now carries `registered`.
  - The `Host` default stays `NoUsbRelations`, so any composition that does not ask for the reader
    fails closed.
  - `development_usb::admit`, the acknowledgment and every startup refusal are unchanged.
- **Documentation.**
  - `rust/README.md`: a new "Trusted USB relations" section, and in-place sentences in "Target
    presentation owner", "HDC runtime status" and "Target observation port".
  - The design-table note.
  - The TASK-XPA-016 deliverable line in `tasks.md`.

## Fail-closed paths

| Condition | Swift | Rust |
| --- | --- | --- |
| No matching dictionary, or `IOServiceGetMatchingServices` refuses | throws: `internalError` `admissionRejected("USB registry unavailable")`, snapshot dropped | same answer (`RegistryUnavailable::Matching`/`Services`) |
| The iterator stops being valid during the census | not asked: a possibly short list | unavailable, as above (difference D1) |
| No `IOUSBHostDevice` at all (null iterator) | empty: every candidate `generationScoped`, `target.adopt` answers `admissionDenied` | same; this host's actual state |
| An entry without a numeric vendor, product or location, or without a string serial | passed over | same |
| A board with no attachment, not HDC-normal (Loader `0x350a`, another name, no name), or another vendor | no relation | same |
| An unusable relation (serial with `:` or a space, over 1024 bytes, location not canonical) | unproved | same (existing rule) |
| Two usable relations for one serial | unproved | same |
| A new attachment between the bracket reads, or a board gone | unproved | same |
| The census fails at the adoption's final read | `internalError`; nothing written; snapshot dropped | same |
| The relation changes between the proving snapshot and the final read | `factsDrifted` | same |
| A fixture HDC | (Swift's daemon always runs the registered HDC) | no relations: the host's devices never prove a fixture's candidates (D2) |
| A registered HDC the owner did not start | (n/a) | refused at startup, as before; `relation_source` answers `Nothing` for it anyway |

## Declared differences

- **D1: iterator validity.** After the walk, Rust asks `IOIteratorIsValid`. A census whose iterator
  did not stay valid, or whose I/O Kit calls failed partway, is unavailable rather than a shorter
  list. Swift never asks. The matching iterator is a private snapshot, so only an I/O Kit failure
  can trigger this. It can only turn a proof into an error, never the reverse. A shorter list can
  hide the second board that would have made a serial ambiguous.
- **D2: composition.** Rust composes the reader only beside the registered HDC the isolated owner
  starts as its managed server, and composes none beside a fixture. Swift's daemon always composes
  it, because its HDC is always the registered one. The production path is the same.
- **Wording.** The wire message is Swift's. `RegistryUnavailable`'s own `Display`, which names the
  `kern_return_t`, stays inside the process.

Swift has no defect here that needs a Rust fix. The number, boolean and string conversions are
ported bit for bit, including a 32-bit location with its high bit set, which both sides read as
`18446744071562067968`.

Considered from the ArkForge patch and not adopted:

- reading each node twice;
- `IORegistryEntryInPlane`;
- a bound of 1000 nodes;
- refusing a duplicate registry entry ID.

The bracket rule already refuses any change between reads and any duplicate serial. Failing the whole
census because of one odd, unrelated device would break observation for every board, where Swift only
passes that entry over.

## Tests

- **`arkdeck-platform` `usb_registry` unit tests** (6), over synthetic entries:
  - the identity as Swift builds it;
  - missing or wrongly typed vendor, product and location;
  - the serial fallback, used only when there is no string serial;
  - `NSNumber` conversions: a negative 16-bit vendor, a 17-bit product, a boolean, and a negative
    32-bit location;
  - the optional name and attachment, including zero;
  - `RegistryUnavailable` wording.
- **`arkdeck-platform` `tests/usb_registry.rs`** (one test, so nothing else allocates while it
  counts):
  - the USB device census answers on this host;
  - the census reads string, number and boolean properties from the host's USB host controllers;
  - two measured batches of 2,000 censuses each, after an unmeasured warm-up batch on a fresh thread,
    keep neither heap blocks nor Mach port names, for both censuses.

  The test does not require a DAYU200. Without one it reports the skip and never fails for its
  absence.
- **`arkdeck-provider-hdc` unit tests.**
  - `only_the_hdc_normal_dayu200_with_an_attachment_is_a_registered_relation` covers name trimming,
    exact comparison, Loader, vendor, attachment, and census order without deduplication.
  - `the_registry_reader_proves_only_an_unchanged_unique_board_and_fails_closed` covers, through the
    reading's bracket: proved; replug; gone; duplicate; no attachment; Loader; non-canonical
    location; another serial; empty; and each unavailability on the first and on the second read.
    It also checks the adoption's final check over the census.
- **`arkdeck-provider-hdc` `tests/target_observation.rs`.**
  - The shared fake HDC is bracketed by the reader over a census that lists the board beside other
    devices. A failing census stops the reading before any list is read.
  - `system()` answers on this host and skips without a board.
- **`arkdeck-agentd` `target_observation_control.rs`.**
  - `the_registry_reader_adopts_the_swift_fake_device_as_the_oracle_s_relations_do` replays all 21
    exchanges of the Swift Target adoption oracle through `Control`. Each exchange's relations reach
    the owner only as a census of their boards, listed among five entries the reader must pass over.
    Each of those entries carries the candidate's serial, so reading one by mistake would leave the
    candidate unproved. Every answer, the fake's calls, `targets.json` and the names file are the
    oracle's. The replay loop is shared with the existing oracle test, which is unchanged in what it
    asserts.
  - `an_uncertain_registry_fails_closed_through_the_control_layer`:
    1. an unavailable census gives `internalError` with Swift's words, and the earlier reference then
       answers `resourceConflict`;
    2. a census that fails only at the adoption's final read gives the same `internalError` and
       writes nothing;
    3. a board without an attachment is `generationScoped` and `admissionDenied`;
    4. only an unchanged board is adopted (`TGT-3ba3f5f43b92`).

    No `targets.json` exists until step 4.
- **`development_usb`**: `the_registry_is_read_beside_the_managed_registered_hdc_unless_a_file_is_named`
  covers seven compositions. No process test can reach the registered ones, since a test HDC never
  has a registered digest.
- **Mutations**, each caught and then restored by checksum:
  - a census that never releases I/O Kit references keeps 2,000 port names per batch;
  - never releasing the property key keeps 8,000 heap blocks per batch;
  - never releasing the property value keeps 4,000 heap blocks per batch;
  - dropping the product-name check fails both agentd tests and the provider unit test;
  - reading an unavailable census as no devices fails the agentd uncertainty test and the provider
    unit test.

## What the host smoke saw

- This host listed **no USB device at all**. `ioreg -p IOUSB` shows the two `AppleT8122USBXHCI`
  controllers with no children, and the census listed 0 `IOUSBHostDevice` entries. There is **no
  DAYU200**, so both DAYU200 checks reported their skip.
- The controller census read 2 `AppleUSBHostController` entries, with their class string, location
  number and sleep boolean.
- The leak batches kept 0 then 0 heap blocks and 0 then 0 port names per 2,000 censuses, for both
  censuses.
- The smoke found one thing before commit. With no entry of the class, the kernel answers
  `KERN_SUCCESS` and a null iterator. The first version asked that iterator's validity and answered
  `Invalidated`. It is now an empty census, as Swift's loop reads it.

This smoke is a host-only read of this Mac's registry. It is not device acceptance.

## Real-device acceptance still pending

- **A development-root window with the DAYU200 attached** (queue slice 9, Q2).
  - Setup: the isolated root with the registered HDC as its managed server and **no relation file**.
  - Runbook GJ-1 §2:
    1. `device candidates` should show `relationProven`;
    2. `target adopt` should adopt, with the Target ID of the 09-19 run (`TGT-958780b2ffb7`);
    3. then `target show`, `target availability` and an `agent run` of `observe.device@1`.
  - Unplug and replug: a new observation, and a stale reference refused.
  - The installed daemon has to be booted out for the window. It holds the board's HDC interface;
    the registry read does not need the interface.
  - Record: `gj1-rust-trusted-usb-development-root-<date>.md`. It is still development-root
    evidence.
- **Queue slice 6** must compose `UsbRegistryRelations::system()` beside its managed registered HDC.
- **A possible maintainer decision:** once the reader has run on the device, retire #2023's
  acknowledged relation file beside a registered HDC. This slice leaves it unchanged, as instructed.

## Local targeted checks

The checks ran on the final Rust tree: its last change, the `cargo fmt` write at 04:23, precedes
every log below. The target directory was `/private/tmp/arkdeck-1330-rust-target`, with
`CARGO_BUILD_JOBS=2`. Logs are `/private/tmp/arkdeck-s12-*.log`.

| Command | Exit | Log SHA-256 |
| --- | --- | --- |
| `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | `e3b0c442…` (empty) |
| `cargo clippy --locked -p arkdeck-platform -p arkdeck-provider-hdc -p arkdeck-provider-workspace -p arkdeck-hoststore -p arkdeck-client -p arkdeck-cli -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings` (the platform crate and every crate that depends on it directly) | 0 | `437be871…` |
| the same clippy for `--target x86_64-unknown-linux-gnu`, `-p arkdeck-platform -p arkdeck-provider-hdc -p arkdeck-agentd` | 0 | `6b5595b8…` |
| the same for `--target x86_64-pc-windows-msvc` | 0 | `cfa3e30e…` |
| `cargo build -p arkdeck-cli`, then `cargo test --locked --no-fail-fast` for the same eight crates: 154 targets, 1,182 passed, 0 failed, 18 ignored (all pre-existing) | 0 | `e21b3e2a…` |
| `cargo test -p arkdeck-platform --test usb_registry -- --nocapture` (smoke output above) | 0 | `3b14ca94…` |
| `cargo test -p arkdeck-provider-hdc --test target_observation -- --nocapture the_system_registry_reader_answers_on_this_host` | 0 | `2e7a899c…` |
| `check-corpus-replay.py --fixture rust/tests/fixtures/target-adoption` (real daemon; relation-file path): PASS, 18 exchanges, 26 checks | 0 | `0307dc29…` |
| `check-corpus-replay.py --fixture rust/tests/fixtures/observe-device` (real daemon; fixture path without relations): PASS, 28 exchanges, 64 checks | 0 | `c4f5e4f2…` |
| `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh`: 0 errors, 0 warnings | 0 | `77c17376…` |

After every run, no fake `hdc` process and no test root was left behind. The installed `hdc`
server kept running untouched.

## CI

Pending.

## Not run

- Any device, HDC operation against a device, installed Runtime, or Swift daemon.
- `generate-contract.py --check` and `check-contracts.py`: no contract input changed.
- `check-readonly.py`: no crate dependency or standalone behaviour changed.
- Swift and App lanes: no Swift file changed.
