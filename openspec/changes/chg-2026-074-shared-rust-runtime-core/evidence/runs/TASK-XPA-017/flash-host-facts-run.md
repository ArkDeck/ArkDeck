# Flash host facts on the Rust daemon (TASK-XPA-017, M4-1b)

The Rust daemon now answers two more of M4's methods. Both read what the
Runtime knows about an attached Rockchip board and write nothing:

- `flash.bootloader-status`: the attached board's disposition (absent,
  ambiguous, unbound, bound to one Target, or bound but not prepared);
- `flash.prerequisites`: for one adopted Target and the published `dayu200`
  profile, which restore prerequisites hold, fail or are unknown.

The App's Flash workspace may ask both through the App ingress, and the Rust
CLI serves `arkdeck flash bootloader-status` and `arkdeck flash prerequisites`.

A new Swift oracle records 40 exchanges with the HDC calls each made. The Rust
daemon replays all of it byte for byte, call for call.

Base: protected `main` `7f8e3d71` (#2148, M4-1a), after the device mutation
lane (#2149). Routed methods: **99/105** (97 after M4-1a). The six
still unrouted are `flash.device-access` (M4-2), `flash.lanePlanPreview`
(M4-3), `flash.bind-current-loader`, `debug.start`, `debug.evaluate` (M4-4)
and `trace.inspect` (M3). Executable operations are unchanged at 15/30.

| Already on `main` | This change | Still remaining (M4) |
|---|---|---|
| The post-flash alias record and store (#1939–#1941); the live mode probe with its HDC, Loader and USB ports (`arkdeck-provider-hdc` `live_mode.rs`); the Runtime's I/O Registry census (#2135, #2137); the registered DAYU200 filter (#2148) | The Swift oracle `flash-host-facts`; the Rockchip binding store and its evidence rules; the Target store's HDC alias ownership query; the facts owner (`FlashHostFacts`: bootloader status, current facts, prerequisites); both routes; composition in the isolated owner and the production composition; two App ingress allowances; two CLI leaves; a widened `flash.bootloader-status` result | `flash.device-access` and the ArkForge lane that configures the measured `arkforged` and the Loader observation (M4-2); `flash.lanePlanPreview` (M4-3); `flash.bind-current-loader`, `debug.start`, `debug.evaluate` and the two flash operations, which use the binding's lineage advance (M4-4) |

## The oracle

`FlashHostFactsOracleContractTests` drives Swift's `RuntimeControlPlaneHandler`
with the owners `main.swift` composes for these methods:

- `ProductRockchipBootloaderStatusObserver`, over `RuntimeTargetStore`, the
  `RockchipProductBindingStore` and the `RockchipPostFlashHDCBindingStore` of
  an Application Support root;
- `TargetStoreRockchipRuntimeFactsPort` over the same three, with the
  measured native RockUSB identity and `FoundationRockchipLiveModeProbe`.

It injects only what a host cannot fix:

- the USB census, in place of the I/O Registry;
- which `arkforged` the identity measures: none, a relative path, a changed
  digest, or the fixture's own stand-in (a shell script that is never run);
- the Loader observation the probe asks ArkForge for;
- the HDC the probe reads: the shared fake (`HDCOracleFake`), with its
  answers recorded beside it;
- a second facts port without a probe, standing for a daemon without HDC.

No device, ArkForge daemon or daemon process is involved. It records
`rust/tests/fixtures/flash-host-facts/`: the exchanges in order over one root,
each with the setup it names and the HDC calls it made.

**`flash.bootloader-status`: 15 exchanges.**

- nothing attached, an unrelated device, two boards, a registry that cannot
  be read;
- one Loader, one HDC-normal board (its product name padded), each unbound;
- a Target without the binding, the exact bound Loader, the Loader at another
  port, two Targets of one Loader, a binding whose lineage is incomplete;
- the flashed board at its post-flash alias, that alias owned by another
  adopted Target, an alias route over an incomplete lineage, and a binding in
  a shared mode.

**`flash.prerequisites`: 25 exchanges.**

- each parameter refusal, and a Target that was never adopted;
- the native RockUSB identity: not configured, a relative path, a changed
  digest;
- a daemon without HDC;
- HDC-normal with and without the binding; the Loader confirmed by ArkForge;
  the board absent, a malformed and a failing target list;
- four unreadable bindings: a shared mode, another schema, evidence naming
  the serial, an incomplete lineage;
- five post-flash aliases refused: another Target's, a reissued revision, a
  newer revision, another Loader, owned by another Target;
- the alias as this revision's route, and an older alias that is not.

The recording ran once, and was compared twice in verify mode and once with
`--parallel --num-workers 2`, byte for byte.

## Swift, as ported

**The binding store** (`RockchipBindingStore`, `rockchip_binding.rs`)

- *File.* `rockchip-binding.json` in the Application Support root, at most
  64 KiB. The root must be absolute and not a link; it is created or kept
  owner-only, as every Swift read does. The file is read owner-only, and the
  refusals name Swift's four details (cannot be opened, not an owner-only
  regular file, size is invalid, was truncated).
- *Decoding.* Not JSON, or not decodable, is `cannot be decoded`. Any keys but
  `evidence`, `revision`, `serial` and `usbTopology` is `schema is invalid`.
  A snapshot that fails validation is `snapshot is invalid`. Each refusal is
  `productionConfigurationUnavailable("durable binding …")`.
- *Evidence rules.* The runtime lineage advance, the reactivation evidence,
  the confirmed HDC-normal alias, whether it covers a Runtime Target, and
  whether it matches a confirmed live identity follow Swift's guards and
  messages.

**The Target store's alias ownership query**
(`TargetStore::has_conflicting_hdc_alias_owner`)

- One read transaction; nothing is nested in it. It answers whether another
  adopted Target owns the alias's connect key or identity.
- An invalid query or a missing or ambiguous canonical Target is
  `storeFailure`, in Swift's words.
- Only functions were added to `target_owner.rs` and `target_document.rs`.

**`flash.bootloader-status`** (`FlashHostFacts::bootloader_status`)

- *Census.* The registered DAYU200 devices in the census: none is `absent`,
  more than one `ambiguous`. A registry that cannot be read is `rejected`
  with `admissionRejected("USB registry unavailable")`.
- *Alias route first.* An HDC-normal board whose serial and port are the
  stored post-flash alias of a Target it covers is that Target's
  `exactBoundTarget`, or `ambiguous` when another Target owns the alias.
- *Otherwise by identity.* The Targets whose stable identity is the board's
  serial digest: none is `unbound`, two `ambiguous`, one is
  `exactBoundTarget` when the binding covers it and matches the live board,
  else `targetBindingUnprepared`.
- Every refusal is `rejected`, prefixed `Rockchip bootloader status could not
  be observed:`.

**`flash.prerequisites`** (`FlashHostFacts::prerequisites`, `current_facts`)

- *Parameters.* The route reads them before the owner, as Swift's handler
  does: a string `targetId`, and `profileReference` exactly `dayu200`.
  Anything else is `invalidParams`. Extra members are ignored.
- *Target.* A Target that is not adopted is `notFound`.
- *Identity.* The measured `arkforged` must be configured, absolute, a
  regular executable, and still have its declared digest. A failure is
  `rejected` with Swift's interpolation.
- *Binding and alias route.* A covering binding makes the cross-mode binding
  `satisfied`. A stored alias is refused when it belongs to another Target,
  is newer (reissued when it names this Target and Loader), names another
  Loader at this revision, or is owned by another adopted Target; at this
  revision it is the probe's connect key, and an older one is not.
- *Live probe.* HDC first (`list targets -v`, then one allowlisted
  `param get` when the board is connected), then the Loader observation. A
  probe that cannot see the board reports it absent. A daemon without HDC
  reports the mode unknown.
- *Statuses.* Swift's table over the mode and the cross-mode binding, for
  `loader`, `recoveryPath`, `unlocked` and `stablePower`.

**Compositions**

- *Isolated development owner.* The facts read the owner's root, the census
  of the Target observations' own source (the host's I/O Registry, the
  harness's relation file, or no device), and the managed registered HDC.
- *Production composition.* Written, not activated. The facts read
  `…/Application Support/ArkDeck` and the host's I/O Registry (Q1=B).
- *Until M4-2.* Neither composition configures the ArkForge lane yet. For an
  adopted Target, `flash.prerequisites` therefore answers as Swift's daemon
  without a configured lane: `rejected`, `ArkForge native RockUSB lane is not
  configured`. No Loader observation is composed; `NoArkForgeLane` refuses
  every one, which the probe reports as the board being absent.

The owner census names `flashHostFacts`. A host without it answers as Swift's
daemon without its observers (`internalError`, "… is not configured").

**Where the owner lives.** The 09-14 live-mode probe note placed the facts
port in lane D's `arkdeck-provider-arkforge`, which does not exist before
M4-2. It lives in `arkdeck-hoststore`, beside the three stores it reads. The
flash operations of M4-4 run in the host store and will call the ArkForge
lane, so the lane's crate cannot depend on the host store. M4-2 serves the
facts' two ports from that crate: the measured `arkforged` and the Loader
observation over `arkforged discoverDevices`. The census stays the Runtime's
read-only I/O Registry (Q1=B).

**App ingress.** `flash.bootloader-status` with no parameters, and
`flash.prerequisites` with exactly `targetId` and `profileReference`, each
checked against the request schema. Nothing else crosses: no serial, path,
connect key or command. A peer that is not the App is refused, as for every
method.

## Declared differences

Each is either fail-closed or T2 prose:

- **Unreadable Target store.** Rust answers
  `storeFailure("undecodable target store: <Rust's reason>")`, as in M4-1a.
  Swift's inner text is Foundation's decoding description (T2).
- **The live probe's USB port.** The oracle composed its probe without one.
  Swift's daemon reads the I/O Registry, and the Rust owner reads the census.
  The port only names an HDC-normal alias's current port among the server
  facts. `flash.prerequisites` does not project them, so no answer changes.
- **Census invalidated mid-enumeration.** Rust refuses with `USB registry
  unavailable`, where Swift would use the partial list (fail closed), as in
  M4-1a.
- **The CLI's legacy `--json`.** It stays refused for both leaves, as for
  every served leaf except `debug probe` and the service leaves.

## Contract

Only append-only corpus lines and one widened schema. The contract identity
is unchanged.

**Corpora.** They grow by 4 lines, one per shape they lacked. Every committed
line is kept verbatim:

- `flash.bootloader-status`: +3 (a bound Target, the absent board with a null
  mode, the unreadable registry);
- `flash.prerequisites`: +1 (a refusal for an adopted Target).

**Schemas.** The derivation used the final corpus of these two methods:

- `flash.bootloader-status`: `mode` may be null, `targetId` a string and
  `bindingRevision` an integer. Swift answers all three.
- `flash.prerequisites`: `$defs` are unchanged, so the file is left as it
  was. Only its sample counts would have moved.

All 40 recorded frames and both corpora validate against the committed
schemas (jsonschema 4.26.0). `rust/scripts/generate-contract.py --write`,
then `--check`: 105 methods, 980 recorded shapes.

## CLI

Both leaves are one request each (Swift `runFlashObservation`):

- `flash bootloader-status`: no parameters;
- `flash prerequisites --target <id> --device-profile <profile>`: the profile
  is sent as the Runtime's `profileReference`. Which profiles are supported
  is the Runtime's to judge. A missing option is `invalidOption` before any
  request, naming the leaf.

The two leaves' Swift argv fixtures are copied unchanged into
`rust/tests/fixtures/current-cli-argv/`, and replay with no deviation.
The registry already published both leaves as current.

The CLI audit (`TASK-XPA-018/cli-parity-audit.py` over this build) now counts
the 256 feature entries as follows:

| Category | Entries |
|---|---|
| implemented | 160 |
| leaf missing, daemon routed | 56 |
| daemon or host owner missing | 25 |
| tombstone per §12 | 15 |

`flash.bootloader-status`, `flash.prerequisites` and `app.flash.main` joined
the implemented ones. The Rust CLI serves 119 leaves.

## Verification

**Local targeted checks.** `CARGO_BUILD_JOBS=2`, own target
`/private/tmp/arkdeck-m4-rust-target`, logs `/private/tmp/arkdeck-m4-fhf-*.log`.

| Check | Command | Result |
|---|---|---|
| Swift recording | `ARKDECK_RUST_FLASH_HOST_FACTS_RECORD=… ARKDECK_CONTROL_FRAME_LOG=… run-swiftpm.sh test --jobs 2 --filter FlashHostFactsOracleContractTests` | exit 0; 40 frames (`fhf-swift-record.log`) |
| Swift verify | the same filter twice without the record variable, then `--parallel --num-workers 2` | exit 0 each (`fhf-swift-verify-{1,2,parallel}.log`) |
| Rust replay | `cargo test -p arkdeck-agentd --bin arkdeck-agentd flash_host_facts` | 3 passed: the 40 exchanges with their HDC calls, a host without the owner, members Swift ignores |
| fmt | `cargo fmt --all --check` | exit 0 |
| clippy | `cargo clippy -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd -p arkdeck-cli -p arkdeck-contract --all-targets -- -D warnings` | exit 0 (`fhf-rebased-clippy.log`) |
| Crate tests | `cargo test --no-fail-fast` of `arkdeck-contract`, `arkdeck-control`, `arkdeck-hoststore`, `arkdeck-cli`, `arkdeck-agentd`, after rebasing onto `7f8e3d71` | exit 0 each: 50, 29, 555, 250 and 141 tests (`fhf-rebased-test-<crate>.log`). Before the rebase the replay's last assertion was wrong: the oracle's removals after its last exchange are never recorded, so the root keeps the last writes; it now compares them byte for byte and by mode |
| Mutations | the replay with each of six mutations: a changed `arkforged` digest accepted, two Targets of one Loader taken as the first, an alias owned by another Target accepted, the probe reading the adoption key instead of the routed alias, an older alias taken as this revision's route, a shared binding's refusal collapsed | 6/6 caught (the fourth by the HDC calls); every source restored by digest (`fhf-mutations.log`) |
| Schemas | the 40 recorded frames and both corpora against the committed schemas, jsonschema 4.26.0 | 0 refusals |
| Swift schema contract | `ARKDECK_CONTROL_FRAME_LOG=<the 40 frames> run-swiftpm.sh test --filter 'ControlMethodSchemaContractTests\|FlashHostFactsOracleContractTests'` | exit 0; 6 tests (`fhf-swift-schema.log`) |
| Contract | `python3 rust/scripts/generate-contract.py --write`, then `--check` | exit 0; 980 shapes |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv), with the prerequisites' missing owner added | PASS on macOS; 133 control responses (`fhf-readonly.log`) |
| Published view | main's `flash.bootloader-status` schema compiled in and `published_view()` forced; the agentd `flash_` tests and the CLI leaf tests run; the sources restored by digest | 8 and 3 passed (`fhf-pubsim.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0; 0 errors, 0 warnings (`fhf-sdd.log`) |
| CLI audit | `cli-parity-audit.py <this build's arkdeck>` | exit 0 (`fhf-cli-audit.log`) |

**CI.** PR #2150 (recorded in the next slice, M4-2a), head `c7e00256`: SDD
Guard run 36040299101 success; Swift CI run 36040299340 success — the `swift`
aggregate, `swift-tests`, `ds-interactions`, the Rust host-independent checks
and the Rust workspace on ubuntu-latest, macos-26 and windows-latest; `app-build`
skipped by the plan. Squash-merged by the coordinating session as `main`
`a5902947` (2026-09-24T18:49:55Z).

No device, installed service, ArkForge daemon or App was used, and nothing
here is device evidence.
