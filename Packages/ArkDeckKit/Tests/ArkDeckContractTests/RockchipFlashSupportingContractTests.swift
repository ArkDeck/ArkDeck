import ArkDeckCore
import ArkDeckProcess
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// What survived the in-process flash executor's retirement (T25).
///
/// The executor's own contract suite went with it: every test that drove the
/// stack-B host, its process port, persistence, lifecycle, postflight or
/// lowering was protecting code that no longer exists, and the engine lane
/// carries its own equivalents (RockchipRuntimeCompositionContractTests for
/// the per-action host and its semantics, RuntimeCampaignWire /
/// RuntimeE2CapabilityConsume for admission, consumption and terminal
/// closing, EngineLaneCampaignDispatch/Daemon for the campaign lane).
///
/// These three protect surfaces the retirement did *not* touch, so they move
/// here rather than being deleted with the executor:
///   - typed tool trust, still reached by `arkdeck flash trust-tool`
///   - E0 binding bootstrap, still reached by `arkdeck flash install-binding`
///   - the public execution request's own validation, still the type the
///     engine lane's campaign dispatcher is handed
final class RockchipFlashSupportingContractTests: XCTestCase {
  private enum ToolPreferenceFailure: Error { case injected }


  private final class ToolPreferenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var failingSetKey: String?

    func preferences() -> RockchipToolBookmarkPreferences {
      RockchipToolBookmarkPreferences(
        object: { [self] key in lock.withLock { values[key] } },
        setObject: { [self] value, key in
          try lock.withLock {
            if failingSetKey == key {
              failingSetKey = nil
              throw ToolPreferenceFailure.injected
            }
            values[key] = value
          }
        },
        removeObject: { [self] key in lock.withLock { values.removeValue(forKey: key) } })
    }

    func value(_ key: String) -> Any? {
      lock.withLock { values[key] }
    }

    func seed(_ value: Any, key: String) {
      lock.withLock { values[key] = value }
    }

    func failNextSet(for key: String) {
      lock.withLock { failingSetKey = key }
    }
  }

  private final class ToolTrustState: @unchecked Sendable {
    private let lock = NSLock()
    private var assessment = RockchipPlatformTrustReceipt(
      codeTrust: .adHoc, quarantinePresent: true)
    private var clears = 0

    func current() -> RockchipPlatformTrustReceipt {
      lock.withLock { assessment }
    }

    func clear() {
      lock.withLock {
        clears += 1
        assessment = RockchipPlatformTrustReceipt(
          codeTrust: .adHoc, quarantinePresent: false)
      }
    }

    var clearCount: Int { lock.withLock { clears } }
  }

  func testTypedToolTrustRequiresExactPinAndNeverClearsQuarantineImplicitly() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-tool-trust-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appending(path: "rkdeveloptool")
    try Data("pinned tool fixture".utf8).write(to: executable)
    XCTAssertEqual(chmod(executable.path, 0o755), 0)

    let preferences = ToolPreferenceBox()
    let state = ToolTrustState()
    let installer = RockchipProductToolInstaller(
      bookmarks: RockchipProductToolBookmarkStore(
        preferences: preferences.preferences(),
        codec: RockchipOrdinaryBookmarkCodec(
          create: { _ in Data([0x62, 0x6d]) },
          resolve: { _ in RockchipBookmarkResolution(url: executable, isStale: false) }),
        verifier: RockchipPinnedExecutableVerifier { _ in }),
      trustInspector: RockchipProductToolTrustInspector(
        assess: { _ in state.current() },
        clearQuarantine: { _ in state.clear() }),
      trustFacts: RockchipToolTrustFactStore(preferences: preferences.preferences()))

    XCTAssertThrowsError(try installer.install(executableURL: executable))
    XCTAssertEqual(state.clearCount, 0)
    XCTAssertNil(preferences.value(RockchipToolTrustFactStore.codeTrustKey))
    XCTAssertNil(preferences.value(RockchipToolTrustFactStore.quarantineKey))

    XCTAssertThrowsError(
      try installer.trustAndInstall(
        executableURL: executable,
        expectedSHA256: String(repeating: "0", count: 64)))
    XCTAssertEqual(state.clearCount, 0)

    let receipt = try installer.trustAndInstall(
      executableURL: executable,
      expectedSHA256: RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256)
    XCTAssertEqual(state.clearCount, 1)
    XCTAssertEqual(receipt.codeTrust, .adHoc)
    XCTAssertFalse(receipt.quarantinePresent)
    XCTAssertEqual(
      preferences.value(RockchipToolTrustFactStore.codeTrustKey) as? String,
      RockchipPlatformCodeTrust.adHoc.rawValue)
    XCTAssertEqual(
      preferences.value(RockchipToolTrustFactStore.quarantineKey) as? Bool,
      false)

    let rollbackPreferences = ToolPreferenceBox()
    rollbackPreferences.seed(
      RockchipPlatformCodeTrust.developerID.rawValue,
      key: RockchipToolTrustFactStore.codeTrustKey)
    rollbackPreferences.seed(true, key: RockchipToolTrustFactStore.quarantineKey)
    rollbackPreferences.failNextSet(for: RockchipToolTrustFactStore.quarantineKey)
    XCTAssertThrowsError(
      try RockchipToolTrustFactStore(preferences: rollbackPreferences.preferences()).persist(
        RockchipPlatformTrustReceipt(codeTrust: .adHoc, quarantinePresent: false)))
    XCTAssertEqual(
      rollbackPreferences.value(RockchipToolTrustFactStore.codeTrustKey) as? String,
      RockchipPlatformCodeTrust.developerID.rawValue)
    XCTAssertEqual(
      rollbackPreferences.value(RockchipToolTrustFactStore.quarantineKey) as? Bool,
      true)
  }

  func testTypedE0CrossModeBootstrapPublishesOwnerOnlyBindingAndRejectsDrift() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-binding-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = RockchipProductUSBIdentity(
      serial: "sensitive-loader-serial",
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
      topology: "336592896", productName: "HDC Device")
    let store = RockchipProductBindingStore(rootURL: root)
    let bootstrap = RockchipProductBindingBootstrap(probe: { identity }, store: store)

    let first = try bootstrap.installCurrentLoader()
    XCTAssertTrue(first.created)
    XCTAssertEqual(first.revision, 1)
    XCTAssertEqual(first.usbTopology, identity.topology)
    XCTAssertEqual(first.serialDigestSHA256.count, 64)
    let bindingURL = root.appending(path: RockchipProductBindingStore.bindingFileName)
    var metadata = stat()
    XCTAssertEqual(lstat(bindingURL.path, &metadata), 0)
    XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG)
    XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
    let snapshot = try JSONDecoder().decode(
      RockchipProductBindingSnapshot.self, from: Data(contentsOf: bindingURL))
    XCTAssertEqual(snapshot.serial, identity.serial)
    XCTAssertFalse(snapshot.evidence.contains { $0.contains(identity.serial) })

    let loaderIdentity = RockchipProductUSBIdentity(
      serial: identity.serial,
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipProbeEvidence.dayu200LoaderProductID,
      topology: identity.topology)
    let second = try RockchipProductBindingBootstrap(
      probe: { loaderIdentity }, store: store
    ).installCurrentLoader()
    XCTAssertFalse(second.created)
    XCTAssertEqual(second.serialDigestSHA256, first.serialDigestSHA256)

    let drifted = RockchipProductBindingBootstrap(
      probe: {
        RockchipProductUSBIdentity(
          serial: identity.serial,
          vendorID: identity.vendorID,
          productID: identity.productID,
          topology: "336592897", productName: identity.productName)
      },
      store: store)
    XCTAssertThrowsError(try drifted.installCurrentLoader())
    XCTAssertEqual(try store.loadExisting(), snapshot)

    let spoofedNormal = RockchipProductBindingBootstrap(
      probe: {
        RockchipProductUSBIdentity(
          serial: identity.serial,
          vendorID: identity.vendorID,
          productID: identity.productID,
          topology: identity.topology, productName: "Maskrom Device")
      },
      store: store)
    XCTAssertThrowsError(try spoofedNormal.installCurrentLoader())
  }

  func testRebindEvidenceProducesOneAdjacentRuntimeTargetLineageEdge() throws {
    let serial = "loader-mode-serial"
    let currentIdentity = SHA256.hash(data: Data(serial.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let previousIdentity = String(repeating: "a", count: 64)
    let confirmation = String(repeating: "b", count: 64)
    let snapshot = RockchipProductBindingSnapshot(
      revision: 2,
      serial: serial,
      usbTopology: "17956864",
      evidence: [
        "product:e0-iokit-single-loader-readback",
        "identity:serial-sha256=\(currentIdentity)",
        "rebind:chat-confirmation-sha256=\(confirmation)",
        "identity:previous-serial-sha256=\(previousIdentity)",
        "binding:previous-revision=1",
        "binding:previous-usb-topology=18874368",
      ])

    let advance = try XCTUnwrap(snapshot.runtimeTargetLineageAdvance())
    XCTAssertEqual(advance.previousStableIdentitySHA256, previousIdentity)
    XCTAssertEqual(advance.previousRevision, 1)
    XCTAssertEqual(advance.currentStableIdentitySHA256, currentIdentity)
    XCTAssertEqual(advance.currentRevision, 2)

    let initial = RockchipProductBindingSnapshot(
      revision: 1,
      serial: serial,
      usbTopology: "17956864",
      evidence: ["identity:serial-sha256=\(currentIdentity)"])
    XCTAssertNil(try initial.runtimeTargetLineageAdvance())
  }

  func testConfirmedLineageAcceptsExactLoaderAndPreviousHDCNormalPersonalities() throws {
    let loaderSerial = "loader-mode-serial"
    let normalSerial = "normal-mode-connect-key"
    let loaderIdentity = SHA256.hash(data: Data(loaderSerial.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let normalIdentity = SHA256.hash(data: Data(normalSerial.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let snapshot = RockchipProductBindingSnapshot(
      revision: 2, serial: loaderSerial, usbTopology: "17956864",
      evidence: [
        "product:e0-iokit-single-loader-readback",
        "identity:serial-sha256=\(loaderIdentity)",
        "rebind:chat-confirmation-sha256=\(String(repeating: "b", count: 64))",
        "identity:previous-serial-sha256=\(normalIdentity)",
        "binding:previous-revision=1",
        "binding:previous-usb-topology=18874368",
      ])

    XCTAssertTrue(
      try snapshot.matchesConfirmedLiveIdentity(
        RockchipProductUSBIdentity(
          serial: loaderSerial,
          vendorID: RockchipProbeEvidence.rockUSBVendorID,
          productID: RockchipProbeEvidence.dayu200LoaderProductID,
          topology: "17956864")))
    let normal = RockchipProductUSBIdentity(
      serial: normalSerial,
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
      topology: "18874368", productName: "HDC Device")
    XCTAssertTrue(try snapshot.matchesConfirmedLiveIdentity(normal))
    XCTAssertEqual(try snapshot.confirmedHDCConnectKey(for: normal), normalSerial)
    XCTAssertEqual(
      RockchipHDCIntegrationProfile.enterLoaderArguments(connectKey: normalSerial),
      ["-t", normalSerial, "target", "boot", "-bootloader"])

    let loader = RockchipProductUSBIdentity(
      serial: loaderSerial,
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipProbeEvidence.dayu200LoaderProductID,
      topology: "17956864")
    let unrelated = RockchipProductUSBIdentity(
      serial: "unrelated-normal",
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
      topology: "19791872", productName: "HDC Device")
    let probe = RockchipProductUSBProbe(identitySource: { [loader, normal, unrelated] })
    XCTAssertEqual(
      try probe.singleDAYU200(selector: "17956864", binding: snapshot), loader)
    XCTAssertEqual(
      try probe.singleDAYU200(selector: "18874368", binding: snapshot), normal)
    XCTAssertThrowsError(
      try probe.singleDAYU200(selector: "19791872", binding: snapshot))
    XCTAssertThrowsError(
      try RockchipProductUSBProbe(identitySource: { [normal, normal] })
        .singleDAYU200(selector: "18874368", binding: snapshot))
  }

  func testConfirmedLineageRejectsTopologyIdentityAndModeCrossWiring() throws {
    let loaderSerial = "loader-mode-serial"
    let normalSerial = "normal-mode-connect-key"
    let loaderIdentity = SHA256.hash(data: Data(loaderSerial.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let normalIdentity = SHA256.hash(data: Data(normalSerial.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let evidence = [
      "product:e0-iokit-single-loader-readback",
      "identity:serial-sha256=\(loaderIdentity)",
      "rebind:chat-confirmation-sha256=\(String(repeating: "b", count: 64))",
      "identity:previous-serial-sha256=\(normalIdentity)",
      "binding:previous-revision=1",
      "binding:previous-usb-topology=18874368",
    ]
    let snapshot = RockchipProductBindingSnapshot(
      revision: 2, serial: loaderSerial, usbTopology: "17956864", evidence: evidence)

    for rejected in [
      RockchipProductUSBIdentity(
        serial: normalSerial,
        vendorID: RockchipProbeEvidence.rockUSBVendorID,
        productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
        topology: "17956864", productName: "HDC Device"),
      RockchipProductUSBIdentity(
        serial: normalSerial,
        vendorID: RockchipProbeEvidence.rockUSBVendorID,
        productID: RockchipProbeEvidence.dayu200LoaderProductID,
        topology: "18874368"),
      RockchipProductUSBIdentity(
        serial: "another-normal-device",
        vendorID: RockchipProbeEvidence.rockUSBVendorID,
        productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
        topology: "18874368", productName: "HDC Device"),
    ] {
      XCTAssertFalse(try snapshot.matchesConfirmedLiveIdentity(rejected))
    }

    let malformed = RockchipProductBindingSnapshot(
      revision: 2, serial: loaderSerial, usbTopology: "17956864",
      evidence: evidence.filter { !$0.hasPrefix("binding:previous-usb-topology=") })
    XCTAssertThrowsError(
      try malformed.matchesConfirmedLiveIdentity(
        RockchipProductUSBIdentity(
          serial: loaderSerial,
          vendorID: RockchipProbeEvidence.rockUSBVendorID,
          productID: RockchipProbeEvidence.dayu200LoaderProductID,
          topology: "17956864")))
  }

  func testRebindEvidenceRejectsMissingAmbiguousOrSkippedLineage() throws {
    let serial = "loader-mode-serial"
    let currentIdentity = SHA256.hash(data: Data(serial.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let previousIdentity = String(repeating: "a", count: 64)
    let confirmation = String(repeating: "b", count: 64)
    let validEvidence = [
      "identity:serial-sha256=\(currentIdentity)",
      "rebind:chat-confirmation-sha256=\(confirmation)",
      "identity:previous-serial-sha256=\(previousIdentity)",
      "binding:previous-revision=1",
      "binding:previous-usb-topology=18874368",
    ]

    for invalid in [
      Array(validEvidence.dropFirst()),
      validEvidence + ["identity:previous-serial-sha256=\(String(repeating: "c", count: 64))"],
      validEvidence.map {
        $0.hasPrefix("rebind:chat-confirmation-sha256=")
          ? "rebind:chat-confirmation-sha256=not-a-digest" : $0
      },
    ] {
      XCTAssertThrowsError(
        try RockchipProductBindingSnapshot(
          revision: 2, serial: serial, usbTopology: "17956864", evidence: invalid
        ).runtimeTargetLineageAdvance())
    }
    XCTAssertThrowsError(
      try RockchipProductBindingSnapshot(
        revision: 3, serial: serial, usbTopology: "17956864", evidence: validEvidence
      ).runtimeTargetLineageAdvance())
  }

  func testPublicRequestRejectsAuthorityAndSelectorInjection() throws {
    XCTAssertThrowsError(
      try RockchipFlashExecutionRequest(
        authorizationID: "../AUTH", archiveURL: URL(fileURLWithPath: "/tmp/a"),
        targetLocationSelector: "42"))
    XCTAssertThrowsError(
      try RockchipFlashExecutionRequest(
        authorizationID: "AUTH-TEST", archiveURL: URL(string: "https://example.invalid/a")!,
        targetLocationSelector: "42"))
    for selector in ["", "042", "42 --tool /tmp/fake", "-1", "４２"] {
      XCTAssertThrowsError(
        try RockchipFlashExecutionRequest(
          authorizationID: "AUTH-TEST", archiveURL: URL(fileURLWithPath: "/tmp/a"),
          targetLocationSelector: selector))
    }
  }

  // MARK: preflight (TASK-AIN-019)

  private static let publishedArchive = RockchipFlashProfile.supportedDAYU200Profiles[0]
  private static let boundIdentity = String(repeating: "a", count: 64)

  private func preflightProbes(
    rockUSB: RockchipFlashToolAliveness = .survivedSpawn(exitStatus: 0),
    hdc: RockchipFlashToolAliveness = .survivedSpawn(exitStatus: 0),
    archive: RockchipFlashArchiveIdentity? = nil,
    boundIdentity: String = RockchipFlashSupportingContractTests.boundIdentity,
    hdcNormalAlias: (identitySHA256: String, usbTopology: String)? = nil,
    readback: RockchipEvolutionTargetReadback? = nil
  ) -> RockchipFlashPreflightProbes {
    let profile = Self.publishedArchive
    let resolvedArchive =
      archive
      ?? RockchipFlashArchiveIdentity(
        sha256: profile.archiveSHA256, byteCount: Int(profile.archiveSizeBytes))
    let resolvedReadback =
      readback
      ?? RockchipEvolutionTargetReadback(
        stableIdentitySHA256: boundIdentity, registeredMode: .loader, usbTopology: "42")
    return RockchipFlashPreflightProbes(
      rockUSBAliveness: { rockUSB },
      hdcAliveness: { hdc },
      archiveIdentity: { _ in resolvedArchive },
      boundTargetIdentitySHA256: { boundIdentity },
      boundTargetHDCNormalAlias: { hdcNormalAlias },
      targetReadback: { resolvedReadback })
  }

  func testPreflightPassesWhenAllFourReadOnlyChecksAnswer() async throws {
    let receipt = await RockchipFlashPreflight(probes: preflightProbes())
      .run(archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"))
    XCTAssertTrue(receipt.isGreen, receipt.renderedLines().joined(separator: "\n"))
    XCTAssertEqual(receipt.deviceMutationDispatchCount, 0)
    XCTAssertEqual(
      receipt.findings.map(\.check), RockchipFlashPreflightCheck.allCases)
  }

  func testPreflightTreatsADeviceAbsentNonZeroExitAsAliveButASignalDeathAsRed() async throws {
    // `rkdeveloptool ld` with no board attached exits non-zero. That is an
    // answer, not a dead tool, and refusing it would make the gate unusable.
    let alive = await RockchipFlashPreflight(
      probes: preflightProbes(rockUSB: .survivedSpawn(exitStatus: 1))
    ).run(archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"))
    XCTAssertTrue(alive.isGreen, alive.renderedLines().joined(separator: "\n"))

    // A child killed before `main` is the 2026-08-04 host fault, and the
    // finding must hand the operator the two things it took a day to find.
    let dead = await RockchipFlashPreflight(
      probes: preflightProbes(rockUSB: .diedOnSignal(6))
    ).run(archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"))
    XCTAssertFalse(dead.isGreen)
    XCTAssertEqual(dead.failedChecks, [.rockUSBToolAliveness])
    let rendered = dead.renderedLines().joined(separator: "\n")
    XCTAssertTrue(rendered.contains("signal 6"), rendered)
    XCTAssertTrue(rendered.contains("DiagnosticReports"), rendered)
    XCTAssertTrue(rendered.contains("entitlement"), rendered)
    XCTAssertTrue(rendered.contains("rockchip-component-packaging.md"), rendered)
  }

  func testPreflightRefusesAnUnavailableHDCWithAnActionableFinding() async throws {
    let receipt = await RockchipFlashPreflight(
      probes: preflightProbes(hdc: .unavailable("ARKDECK_HDC_PATH is unset"))
    ).run(archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"))
    XCTAssertEqual(receipt.failedChecks, [.hdcToolAliveness])
    XCTAssertFalse(
      try XCTUnwrap(receipt.findings.first { $0.check == .hdcToolAliveness }).remediation
        .isEmpty)
  }

  func testPreflightRefusesAnArchiveThatMatchesNoPublishedProfilePin() async throws {
    let receipt = await RockchipFlashPreflight(
      probes: preflightProbes(
        archive: RockchipFlashArchiveIdentity(
          sha256: String(repeating: "f", count: 64), byteCount: 1_234))
    ).run(archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"))
    XCTAssertEqual(receipt.failedChecks, [.archiveIntegrity])
  }

  func testPreflightRefusesEveryTargetReadbackThatIsNotTheBoundRegisteredTarget() async throws {
    let cases: [(String, RockchipEvolutionTargetReadback)] = [
      ("absent", .absent),
      (
        "identity drift",
        RockchipEvolutionTargetReadback(
          stableIdentitySHA256: String(repeating: "b", count: 64),
          registeredMode: .loader, usbTopology: "42")
      ),
      (
        "unregistered mode",
        RockchipEvolutionTargetReadback(
          stableIdentitySHA256: Self.boundIdentity, registeredMode: nil,
          usbTopology: "42")
      ),
    ]
    for (label, readback) in cases {
      let receipt = await RockchipFlashPreflight(
        probes: preflightProbes(readback: readback)
      ).run(archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"))
      XCTAssertEqual(receipt.failedChecks, [.targetPresence], label)
      XCTAssertFalse(
        try XCTUnwrap(receipt.findings.first { $0.check == .targetPresence }).remediation
          .isEmpty, label)
    }
  }

  func testPreflightAcceptsTheBoundTargetThroughItsConfirmedHDCNormalAlias() async throws {
    // The 2026-08-04 shape: revision 2 binds the Loader identity, the board
    // sits in HDC-normal (its previous personality), and hdcNormal is an
    // allowed starting mode. The confirmed lineage alias — same identity,
    // same recorded topology, hdcNormal mode — is the bound target.
    let aliasIdentity = String(repeating: "d", count: 64)
    let receipt = await RockchipFlashPreflight(
      probes: preflightProbes(
        hdcNormalAlias: (identitySHA256: aliasIdentity, usbTopology: "18874368"),
        readback: RockchipEvolutionTargetReadback(
          stableIdentitySHA256: aliasIdentity, registeredMode: .hdcNormal,
          usbTopology: "18874368"))
    ).run(archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"))
    XCTAssertTrue(receipt.isGreen, receipt.renderedLines().joined(separator: "\n"))
    let summary = try XCTUnwrap(
      receipt.findings.first { $0.check == .targetPresence }).summary
    XCTAssertTrue(summary.contains("confirmed hdc-normal alias"), summary)
  }

  func testPreflightRefusesAliasShapedReadbacksThatDoNotMatchTheConfirmedEdge() async throws {
    let aliasIdentity = String(repeating: "d", count: 64)
    let cases: [(String, (identitySHA256: String, usbTopology: String)?,
      RockchipEvolutionTargetReadback)] = [
      (
        "no alias in the binding",
        nil,
        RockchipEvolutionTargetReadback(
          stableIdentitySHA256: aliasIdentity, registeredMode: .hdcNormal,
          usbTopology: "18874368")
      ),
      (
        "alias identity at the wrong topology",
        (identitySHA256: aliasIdentity, usbTopology: "18874368"),
        RockchipEvolutionTargetReadback(
          stableIdentitySHA256: aliasIdentity, registeredMode: .hdcNormal,
          usbTopology: "999")
      ),
      (
        "alias identity claiming loader mode",
        (identitySHA256: aliasIdentity, usbTopology: "18874368"),
        RockchipEvolutionTargetReadback(
          stableIdentitySHA256: aliasIdentity, registeredMode: .loader,
          usbTopology: "18874368")
      ),
    ]
    for (label, alias, readback) in cases {
      let receipt = await RockchipFlashPreflight(
        probes: preflightProbes(hdcNormalAlias: alias, readback: readback)
      ).run(archiveURL: URL(fileURLWithPath: "/tmp/images.tar.gz"))
      XCTAssertEqual(receipt.failedChecks, [.targetPresence], label)
    }
  }

  func testProductTargetReadbackDistinguishesAbsenceAmbiguityAndUnregisteredModes() throws {
    let loader = RockchipProductUSBIdentity(
      serial: "DAYU-1", vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipProbeEvidence.dayu200LoaderProductID, topology: "42",
      productName: nil)
    let maskrom = RockchipProductUSBIdentity(
      serial: "DAYU-1", vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: 0x330C, topology: "42", productName: nil)
    let unrelated = RockchipProductUSBIdentity(
      serial: "OTHER", vendorID: 0x05AC, productID: 0x1234, topology: "1",
      productName: nil)
    let expectedDigest = SHA256.hash(data: Data("DAYU-1".utf8))
      .map { String(format: "%02x", $0) }.joined()

    XCTAssertEqual(
      try ProductRockchipEvolutionTargetReadback(identitySource: { [loader, unrelated] })
        .readDurableTarget(),
      RockchipEvolutionTargetReadback(
        stableIdentitySHA256: expectedDigest, registeredMode: .loader, usbTopology: "42"))
    // A Rockchip device in a personality this product has not registered is
    // reported as present-but-unregistered, never as a registered mode and
    // never as plain absence.
    XCTAssertEqual(
      try ProductRockchipEvolutionTargetReadback(identitySource: { [maskrom] })
        .readDurableTarget(),
      RockchipEvolutionTargetReadback(
        stableIdentitySHA256: expectedDigest, registeredMode: nil, usbTopology: "42"))
    XCTAssertEqual(
      try ProductRockchipEvolutionTargetReadback(identitySource: { [unrelated] })
        .readDurableTarget(), .absent)
    // Two Rockchip devices: nothing observed can be attributed to the bound
    // target, so the answer is absence rather than a coin flip.
    XCTAssertEqual(
      try ProductRockchipEvolutionTargetReadback(identitySource: { [loader, maskrom] })
        .readDurableTarget(), .absent)
  }
}
