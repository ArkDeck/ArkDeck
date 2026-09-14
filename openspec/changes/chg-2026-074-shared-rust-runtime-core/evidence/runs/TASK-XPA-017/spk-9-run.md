# TASK-XPA-017 — SPK-9 run record: ArkForge Rust-to-Rust, the preconditions found

Change: CHG-2026-074-shared-rust-runtime-core@r11. Spike recorded here: SPK-9 (design §J.3, r11):
"the Rust daemon drives `arkforged` through `arkforge-client` for `flash.prerequisites` and
`flash.lanePlanPreview` without a device; the StepPermit CBOR vectors reused". Recorded under the
task it unlocks (the ArkForge lane of TASK-XPA-017, milestone M4). Host reading only — no code was
written, no daemon was run, no device was contacted (POL-VERIFY-001, POL-MODE-001). `TASK-XPA-017`
stays `blocked`.

Read on 2026-09-14 against protected main `1a47ac67` and the ArkForge repository at the revision
`Packages/ArkDeckKit/Package.swift` pins (`eee578720c5bae76b2574a6aaf25b536bc491c86`; ArkForge's
head differs from it only in two workflow files).

## Verdict

**Not a go yet.** The spike as defined cannot be run inside an ArkDeck PR: three preconditions lie
outside this repository or need a maintainer ruling, and one of its two named methods never
touches ArkForge. None of the preconditions is hard; all of them are decisions or small upstream
changes, listed in §4 for the maintainer. Until they are made, the r11 sidecar decision ("if SPK-6,
SPK-9 and SPK-10 pass, the executor sidecar is never built") rests on SPK-6 (passed: #1914, #1915,
#1917, #1919) and SPK-10 (lane D, not started); nothing here argues for a sidecar.

## 1. How the Swift daemon uses ArkForge today

- Transport: two Unix sockets, `controller.sock` and `public.sock`, under `<stateDir>/arkforge`
  (0700); 4-byte big-endian length-prefixed protobuf frames with a `Hello`/`HelloAck` handshake at
  protocol 1.0 on both sides (`ArkForgeLaneComposition.swift:408-409, 469, 621`; ArkForge
  `crates/arkforge-ipc/src/framing.rs:15-52`, `lib.rs:25-26`).
- Ownership: the Swift daemon spawns and owns `arkforged` itself
  (`IdentityBoundDaemonLauncher`, argv `--runtime-dir <dir> --profile <file> --pair-from-stdin
  <epoch>` plus `--hardware-campaign <id>` when a campaign is set; `ArkForgeLaneComposition.swift:
  246-263, 342-517, 550`), unlinks stale sockets before launching (`:400-410`) and stops exactly one
  process generation. `arkforged` exits with status 11 when the stdin that carried its pairing
  secret closes (`crates/arkforged/src/main.rs:147-150, 219-227`).
- Configuration: `ARKDECK_ARKFORGE_BUNDLE_PATH` names an `ArkForge.bundle` whose manifest
  (`arkforge.release-bundle/v1`) carries the cli, daemon and profile; the daemon's SHA-256 is
  re-measured and checked against `HelloAck` (`:128-132, 163-168, 437-438`). The campaign comes from
  `ARKDECK_ARKFORGE_CAMPAIGN`; without it the lane is assessment-only (`:453-461`).
- The Swift side consumes ArkForge through a hand-written Swift SDK inside the ArkForge repository
  (`swift/ArkForgeSDK`, products `ArkForgeProtocol` and `ArkForgeClient`), not through the Rust
  crates; ArkDeck narrows it to `ArkForgeAssessmentSource` and `ArkForgePlanSource`
  (`ArkForgeLaneHost.swift:36-55`) over three connections (controller session, materializer,
  public assessment source).
- StepPermit CBOR vectors: generated and pinned by `crates/arkforge-authority-api/tests/
  permit_vectors.rs` (three vectors, body SHA-256 and HMAC tag), published in both repositories
  (`openspec/changes/chg-2026-059-arkdeck-arkforge-authority/permit-vectors.md`), and asserted by
  `ArkForgeStepPermitContractTests.swift:22-80` against `ArkDeckCore/ArkForgeStepPermit.swift` and
  `CanonicalCBOR.swift`. These are the T0 bytes a Rust lane must reproduce.

## 2. What the two named methods actually do

- `flash.prerequisites` (`AgentDaemon.swift:537-575`) makes **no ArkForge call**: it projects the
  Target store and HDC binding facts into four observations (`loader`, `recoveryPath`, `unlocked`,
  `stablePower`, the last always `unknown`) through `TargetStoreRockchipRuntimeFactsPort`
  (`RockchipRuntimeComposition.swift:83-110, 288-340`, `RockchipFlashProfile.swift:64-69`). A Rust
  port needs the Target owner and the binding facts, not `arkforge-client`.
- `flash.lanePlanPreview` (`AgentDaemon.swift:471-535`, `ArkForgeLaneHost.swift:265-301, 746-880`)
  runs the five-stage evidence chain: controller `inspectArtifact` (miss →
  `bundleNotInLaneStore`), public `inspectArtifact` + `discoverDevices` + assessment
  `materializePlan`, controller `discoverDevices` with the same-evidence check, controller
  `materializePlan` with the fixed `hardwareGated` pending seal, ArkDeck's own
  `authoritySupport.seal`, and a final controller `materializePlan`. Its synthetic binding is
  `PREVIEW-<sha[0..12]>`, revision 1, `stableIdentitySHA256 = sha256(usbTopology)`, intent
  `fullRestore`, toolchain `arkforged-native-rockusb`, namespace `arkdeck` (`:270-278, 888-897`).
  Device-free it reaches only its refusal states (`bundleNotInLaneStore`, `deviceNotObserved`,
  `planNotExecutable` without a campaign); `available{planId, planSha256}` needs a stored ~731 MB
  artifact and an observed device. ArkForge's transcript replay transport runs discovery without a
  device but is `ToolchainKind::Replay`, which never permits an executable plan
  (`crates/arkforge-transport/src/replay.rs:1-10`), so `available` is not reachable device-free.

## 3. What `arkforge-client` offers at the pinned revision

- `ControllerClient::connect(runtime_dir)` reaches `MaterializePlan`, `StartExecution`,
  `WatchJob`, `CancelJob`, `ReconcileJob`, `PlanSupersedingRecovery`, `SubmitStepPermit`,
  `SubmitManagedControlReceipt`; `PublicClient::connect(runtime_dir)` reaches `DiscoverDevices`,
  `ProbeDevice`, `InspectArtifact`, `MaterializePlan`, `WatchJob`, `GetJob`, `ListJobs`,
  `GetRecoveryGuide` (`crates/arkforge-client/src/{controller,public}.rs`). **The controller
  client exposes neither `inspect_artifact` nor `discover_devices`, and `Api::ImportArtifact` is
  reachable from neither client**, although the daemon serves them on the controller socket
  (`arkforge-ipc/src/lib.rs:58-75`). The preview chain therefore cannot be driven from the crate as
  it stands — the spike's stated fail condition ("the Swift SDK carries semantics the crate does not
  expose"). The addition is small and additive, but it is an ArkForge pull request.
- `MaterializeInput` carries the thirteen fields the Swift request uses with `intent = "fullRestore"`
  fixed, matching Swift (`controller.rs:26-58`).
- The crates have no third-party dependencies (SHA-256, CBOR, DEFLATE, tar and the protobuf codec
  are vendored), are edition 2024 on `stable`, declare `license = "Apache-2.0"` in workspace
  metadata, and are in-repo only (no registry, no vendored copy in ArkDeck). **No `LICENSE` file
  exists at the pinned revision.**

## 4. What the maintainer has to decide before SPK-9 can run

1. **ArkForge crate API.** Add controller-side `inspect_artifact` and `discover_devices` (and
   `import_artifact`) to `arkforge-client`, or accept that the Rust lane composes its own client over
   `arkforge-ipc`. Either way an ArkForge revision bump follows.
2. **A git dependency in the Rust workspace.** `rust/deny.toml` denies unknown git sources and
   carries no `allow-git`; `[bans] allow` is an exhaustive `name@version` list; `rust/supply-chain/
   audits.toml` holds only bounded crates.io publisher windows and its README forbids exemptions
   added to make the check green. A git dependency has no crates.io publisher, so it needs the
   workspace's first first-party `[[audits.*]]` (or `policy`) entry, an `allow-git` for
   `https://github.com/ArkDeck/ArkForge`, one bans entry per ArkForge crate consumed
   (`arkforge-client`, `arkforge-ipc`, `arkforge-core`, `arkforge-platform`, plus
   `arkforge-authority-api` and `arkforge-arkdeck-adapter` if used) and the lockfile's first
   non-registry source. Alternative: vendor the crates into `rust/vendor/` under the same review.
3. **Licence file.** ArkForge's metadata says Apache-2.0 (allowed by `deny.toml`) but the pinned
   revision ships no `LICENSE`; add it upstream before `cargo deny check licenses` is relied on.
4. **One ArkForge revision, two pins.** A Rust dependency adds a second pin beside
   `Package.swift`'s; during the transition both the Swift lane and the Rust lane talk to the same
   `arkforged`, and protocol negotiation checks only the major version
   (`arkforge-ipc/src/lib.rs:222-231`), so a field-level drift between pins would not be caught.
   Assert one revision across both manifests in CI and re-run `swift_sdk_vectors` and
   `permit_vectors` on every bump.
5. **The spike's evidence shape.** With `flash.prerequisites` ArkForge-free and `available`
   device-gated, the device-free spike can prove: `PublicClient::runtime_info` against Swift's
   `HelloAck` fields, the four refusal states of `flash.lanePlanPreview` (T1), and the StepPermit
   vectors (T0). Whether that is enough to close SPK-9, or whether it should be folded into the M4
   milestone with a device window, is the maintainer's call.

## 5. Facts a Rust lane will need regardless

- The Rust daemon must own the `arkforged` spawn: only the process that fed the pairing secret can
  mint a valid StepPermit (the secret is per-launch and never written; `ArkForgeLaneComposition.swift:
  265-274`), and it must hold the child's stdin open for its life. An attached second client is
  preview-only.
- The plan digest's inputs are T0 (the synthetic binding, `executionPurpose "primaryFlash"`, the
  toolchain and namespace literals, and ArkDeck's `authoritySupport.seal` key, state and detail —
  `ArkForgeAuthoritySupport.swift`, not yet read line by line); the result object of
  `flash.lanePlanPreview` is T1 against `spec/control/methods/flash.lanePlanPreview.json`; its
  `reason` prose is T2.
- Unverified: whether `arkforged` accepts a second concurrent controller session while the Swift one
  is open, and its socket permission and peer checks (`arkforged/src/main.rs` past line 205 not read).
