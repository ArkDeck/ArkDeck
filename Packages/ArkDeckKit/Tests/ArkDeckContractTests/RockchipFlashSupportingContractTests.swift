import ArkDeckCore
import ArkDeckProcess
import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// Binding, preflight and public request coverage retained after the vendor
/// selection/trust/execution stack was removed. ArkForge owns RockUSB facts
/// and effects; these tests protect the remaining cross-mode identity boundary.
final class RockchipFlashSupportingContractTests: XCTestCase {
  private final class ProbeCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func increment() { lock.withLock { calls += 1 } }
    var value: Int { lock.withLock { calls } }
  }

  func testTheBindingVersionAndTheTargetEdgeAreSeparateNumbers() throws {
    // One `revision` field used to answer two questions. The store's
    // compare-and-swap requires the document's version to be one past the
    // document it replaces; `runtimeTargetLineageAdvance` requires it to be
    // one past the *target's* revision. Those coincide only while a lineage
    // has never been interrupted, and on a first cross-mode bind they diverge,
    // so no single value satisfies both — measured on the bench as
    // "durable binding changed before Loader rebind" against one choice and
    // "previous identity lineage is invalid" against the other.
    let previousIdentity = String(repeating: "a", count: 64)
    let currentIdentity = SHA256Hex.string(of: Data("loader-serial".utf8))
    let snapshot = RockchipProductBindingSnapshot(
      // The binding's own version: one past the document it replaced.
      revision: 2,
      serial: "loader-serial",
      usbTopology: "17956864",
      evidence: [
        "product:e0-iokit-single-loader-readback",
        "usb:vendor=\(RockchipProbeEvidence.rockUSBVendorID),profile=dayu200-cross-mode",
        "identity:serial-sha256=\(currentIdentity)",
        "identity:previous-serial-sha256=\(previousIdentity)",
        "binding:previous-revision=1",
        "binding:previous-usb-topology=18874368",
        // The target's edge, which is numbered independently.
        "binding:target-previous-revision=3",
        "binding:target-current-revision=4",
        "identity:hdc-normal-alias-sha256=\(String(repeating: "b", count: 64))",
        "binding:hdc-normal-alias-usb-topology=17956864",
        "rebind:user-selection-sha256=\(String(repeating: "c", count: 64))",
      ])

    let advance = try XCTUnwrap(try snapshot.runtimeTargetLineageAdvance())
    XCTAssertEqual(
      advance.previousRevision, 3, "the advance carries the target's numbering")
    XCTAssertEqual(advance.currentRevision, 4)
    XCTAssertEqual(advance.previousStableIdentitySHA256, previousIdentity)
    XCTAssertEqual(advance.currentStableIdentitySHA256, currentIdentity)
  }

  func testWithoutATargetEdgeTheBindingNumberingStillApplies() throws {
    // The unchanged case: a migration whose two numbers agree records no
    // separate edge, and the advance keeps reading the binding's own.
    let previousIdentity = String(repeating: "a", count: 64)
    let currentIdentity = SHA256Hex.string(of: Data("loader-serial".utf8))
    let snapshot = RockchipProductBindingSnapshot(
      revision: 2, serial: "loader-serial", usbTopology: "17956864",
      evidence: [
        "product:e0-iokit-single-loader-readback",
        "usb:vendor=\(RockchipProbeEvidence.rockUSBVendorID),profile=dayu200-cross-mode",
        "identity:serial-sha256=\(currentIdentity)",
        "identity:previous-serial-sha256=\(previousIdentity)",
        "binding:previous-revision=1",
        "binding:previous-usb-topology=18874368",
        "identity:hdc-normal-alias-sha256=\(String(repeating: "b", count: 64))",
        "binding:hdc-normal-alias-usb-topology=17956864",
        "rebind:user-selection-sha256=\(String(repeating: "c", count: 64))",
      ])
    let advance = try XCTUnwrap(try snapshot.runtimeTargetLineageAdvance())
    XCTAssertEqual(advance.previousRevision, 1)
    XCTAssertEqual(advance.currentRevision, 2)
  }

  func testARebindContinuesTheLineageRatherThanRestartingIt() throws {
    // A rebind that wrote a fresh revision-1 snapshot would publish a binding
    // the recovery machinery cannot follow: `runtimeTargetLineageAdvance`
    // returns nil at revision 1, so the adjacent edge from the old identity to
    // the new one would not exist, and a job that bound the old one could
    // never be settled against the new. This is what that regression looked
    // like — it shipped once and had to be corrected.
    let root = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-rebind-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RockchipProductBindingStore(rootURL: root)

    let original = RockchipProductUSBIdentity(
      serial: "board-on-first-port",
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
      topology: "18874368", productName: "HDC Device")
    let first = try RockchipProductBindingBootstrap(probe: { original }, store: store)
      .installCurrentTarget()
    XCTAssertEqual(first.revision, 1)

    // The same board after a replug: a different port, and a connect identity
    // that changed with it.
    let moved = RockchipProductUSBIdentity(
      serial: "board-on-second-port",
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
      topology: "17956864", productName: "HDC Device")

    // Without the flag the drift is still refused — the default is what stops
    // a flash authorized for one device from landing on another.
    XCTAssertThrowsError(
      try RockchipProductBindingBootstrap(probe: { moved }, store: store)
        .installCurrentTarget())

    let second = try RockchipProductBindingBootstrap(probe: { moved }, store: store)
      .installCurrentTarget(rebind: true)
    XCTAssertEqual(second.revision, 2, "a rebind continues the lineage")
    XCTAssertEqual(second.usbTopology, moved.topology)

    let snapshot = try JSONDecoder().decode(
      RockchipProductBindingSnapshot.self,
      from: Data(contentsOf: root.appending(path: RockchipProductBindingStore.bindingFileName)))
    // The four keys `runtimeTargetLineageAdvance` reads. Asserted by name
    // because the machinery requires exactly one of each and silently returns
    // nil otherwise, which is how a missing edge hides.
    let previousSerialDigest = SHA256Hex.string(of: Data(original.serial.utf8))
    XCTAssertTrue(
      snapshot.evidence.contains("identity:previous-serial-sha256=\(previousSerialDigest)"))
    XCTAssertTrue(snapshot.evidence.contains("binding:previous-revision=1"))
    XCTAssertTrue(
      snapshot.evidence.contains("binding:previous-usb-topology=\(original.topology)"))
    XCTAssertTrue(
      snapshot.evidence.contains { $0.hasPrefix("rebind:user-selection-sha256=") },
      "the operator's selection is recorded as what was selected, not as a bare yes")
    // The serials themselves never reach the document.
    XCTAssertFalse(snapshot.evidence.contains { $0.contains(original.serial) })
    XCTAssertFalse(snapshot.evidence.contains { $0.contains(moved.serial) })
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

    let first = try bootstrap.installCurrentTarget()
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
    ).installCurrentTarget()
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
    XCTAssertThrowsError(try drifted.installCurrentTarget())
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
    XCTAssertThrowsError(try spoofedNormal.installCurrentTarget())
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
        "rebind:user-selection-sha256=\(confirmation)",
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
        "rebind:user-selection-sha256=\(String(repeating: "b", count: 64))",
        "identity:previous-serial-sha256=\(normalIdentity)",
        "binding:previous-revision=1",
        "binding:previous-usb-topology=18874368",
        "identity:hdc-normal-alias-sha256=\(normalIdentity)",
        "binding:hdc-normal-alias-usb-topology=18874368",
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
    XCTAssertTrue(
      try snapshot.coversRuntimeTarget(
        RuntimeTargetRecord(
          targetID: "TGT-BOUND", stablePhysicalIdentitySHA256: loaderIdentity,
          bindingRevision: 2, connectKey: normalSerial, toolVersion: "3.2.0f",
          adoptedAtUTC: "2026-08-08T00:00:00Z")))
    XCTAssertFalse(
      try snapshot.coversRuntimeTarget(
        RuntimeTargetRecord(
          targetID: "TGT-OTHER", stablePhysicalIdentitySHA256: normalIdentity,
          bindingRevision: 1, connectKey: normalSerial, toolVersion: "3.2.0f",
          adoptedAtUTC: "2026-08-08T00:00:00Z")))
    XCTAssertEqual(try snapshot.confirmedHDCConnectKey(for: normal), normalSerial)
    XCTAssertEqual(
      RockchipHDCIntegrationProfile.enterLoaderArguments(connectKey: normalSerial),
      ["-t", normalSerial, "target", "boot", "loader"])

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
      "rebind:user-selection-sha256=\(String(repeating: "b", count: 64))",
      "identity:previous-serial-sha256=\(normalIdentity)",
      "binding:previous-revision=1",
      "binding:previous-usb-topology=18874368",
      "identity:hdc-normal-alias-sha256=\(normalIdentity)",
      "binding:hdc-normal-alias-usb-topology=18874368",
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
      "rebind:user-selection-sha256=\(confirmation)",
      "identity:previous-serial-sha256=\(previousIdentity)",
      "binding:previous-revision=1",
      "binding:previous-usb-topology=18874368",
    ]

    for invalid in [
      Array(validEvidence.dropFirst()),
      validEvidence + ["identity:previous-serial-sha256=\(String(repeating: "c", count: 64))"],
      validEvidence.map {
        $0.hasPrefix("rebind:user-selection-sha256=")
          ? "rebind:user-selection-sha256=not-a-digest" : $0
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
        authorizationID: "../AUTH", archiveURL: URL(filePath: "/tmp/a"),
        targetLocationSelector: "42"))
    XCTAssertThrowsError(
      try RockchipFlashExecutionRequest(
        authorizationID: "AUTH-TEST", archiveURL: URL(string: "https://example.invalid/a")!,
        targetLocationSelector: "42"))
    for selector in ["", "042", "42 --tool /tmp/fake", "-1", "４２"] {
      XCTAssertThrowsError(
        try RockchipFlashExecutionRequest(
          authorizationID: "AUTH-TEST", archiveURL: URL(filePath: "/tmp/a"),
          targetLocationSelector: selector))
    }
  }

  // MARK: preflight (TASK-AIN-019)

  private static let publishedArchive = [RockchipFlashProfile.dayu200][0]
  private static let boundIdentity = String(repeating: "a", count: 64)

  private func preflightProbes(
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
      hdcAliveness: { hdc },
      // Reading the archive is one probe like every other observation here,
      // so these tests prove every branch with zero spawn, zero device and no
      // 730 MB file. The fixture describes a build that fits the board.
      archiveSnapshot: { _, board in
        RockchipFlashArchiveSnapshot(
          identity: resolvedArchive,
          build: RockchipImageBuildDescriptor(
            archiveSizeBytes: resolvedArchive.byteCount == 0
              ? board.archiveSizeBytes : Int64(resolvedArchive.byteCount),
            archiveSHA256: resolvedArchive.sha256,
            members: board.members,
            declaredPartitions: board.mappedPartitions.map {
              RockchipDeclaredPartition(
                name: $0.partitionName, sizeSectors: 1, offsetSectors: $0.offsetSectors)
            }
              + board.membershiplessPartitionsWriteForbidden.map {
                RockchipDeclaredPartition(name: $0, sizeSectors: 1, offsetSectors: 0)
              },
            runtimeBuildVersion: board.runtimeBuildVersion))
      },
      boundTargetIdentitySHA256: { boundIdentity },
      boundTargetHDCNormalAlias: { hdcNormalAlias },
      targetReadback: { resolvedReadback })
  }

  func testPreflightPassesWhenAllThreeReadOnlyChecksAnswer() async throws {
    var probes = preflightProbes()
    let counter = ProbeCallCounter()
    let snapshot = probes.archiveSnapshot
    probes.archiveSnapshot = { url, board in
      counter.increment()
      return try snapshot(url, board)
    }
    let receipt = await RockchipFlashPreflight(probes: probes)
      .run(archiveURL: URL(filePath: "/tmp/images.tar.gz"))
    XCTAssertTrue(receipt.isGreen, receipt.renderedLines().joined(separator: "\n"))
    XCTAssertEqual(counter.value, 1, "preflight must stream one archive snapshot only once")
    XCTAssertEqual(receipt.deviceMutationDispatchCount, 0)
    XCTAssertEqual(
      receipt.findings.map(\.check), RockchipFlashPreflightCheck.allCases)
  }

  func testPreflightRefusesSnapshotWhoseBuildDriftsFromItsMeasuredIdentity() async throws {
    let identity = RockchipFlashArchiveIdentity(
      sha256: String(repeating: "a", count: 64), byteCount: 1_234)
    var probes = preflightProbes(archive: identity)
    probes.archiveSnapshot = { _, board in
      RockchipFlashArchiveSnapshot(
        identity: identity,
        build: RockchipImageBuildDescriptor(
          archiveSizeBytes: 1_234,
          archiveSHA256: String(repeating: "b", count: 64),
          members: board.members,
          declaredPartitions: board.mappedPartitions.map {
            RockchipDeclaredPartition(
              name: $0.partitionName, sizeSectors: 1, offsetSectors: $0.offsetSectors)
          }
            + board.membershiplessPartitionsWriteForbidden.map {
              RockchipDeclaredPartition(name: $0, sizeSectors: 1, offsetSectors: 0)
            },
          runtimeBuildVersion: board.runtimeBuildVersion))
    }

    let receipt = await RockchipFlashPreflight(probes: probes)
      .run(archiveURL: URL(filePath: "/tmp/images.tar.gz"))

    XCTAssertEqual(receipt.failedChecks, [.archiveIntegrity])
    let finding = try XCTUnwrap(
      receipt.findings.first { $0.check == .archiveIntegrity })
    XCTAssertTrue(finding.summary.contains("changed while they were being measured"))
  }

  func testPreflightTreatsADeviceAbsentNonZeroExitAsAliveButASignalDeathAsRed() async throws {
    // An HDC read with no board attached may exit non-zero. That is an answer,
    // not a dead tool, and refusing it would make the gate unusable.
    let alive = await RockchipFlashPreflight(
      probes: preflightProbes(hdc: .survivedSpawn(exitStatus: 1))
    ).run(archiveURL: URL(filePath: "/tmp/images.tar.gz"))
    XCTAssertTrue(alive.isGreen, alive.renderedLines().joined(separator: "\n"))

    // A child killed before `main` is the 2026-08-04 host fault, and the
    // finding must hand the operator the two things it took a day to find.
    let dead = await RockchipFlashPreflight(
      probes: preflightProbes(hdc: .diedOnSignal(6))
    ).run(archiveURL: URL(filePath: "/tmp/images.tar.gz"))
    XCTAssertFalse(dead.isGreen)
    XCTAssertEqual(dead.failedChecks, [.hdcToolAliveness])
    let rendered = dead.renderedLines().joined(separator: "\n")
    XCTAssertTrue(rendered.contains("signal 6"), rendered)
    XCTAssertTrue(rendered.contains("DiagnosticReports"), rendered)
    XCTAssertTrue(rendered.contains("configured hdc path and digest"), rendered)
  }

  func testPreflightRefusesAnUnavailableHDCWithAnActionableFinding() async throws {
    let receipt = await RockchipFlashPreflight(
      probes: preflightProbes(hdc: .unavailable("ARKDECK_HDC_PATH is unset"))
    ).run(archiveURL: URL(filePath: "/tmp/images.tar.gz"))
    XCTAssertEqual(receipt.failedChecks, [.hdcToolAliveness])
    XCTAssertFalse(
      try XCTUnwrap(receipt.findings.first { $0.check == .hdcToolAliveness }).remediation
        .isEmpty)
  }

  /// Preflight refuses an archive that does not fit the board — not one whose
  /// digest it has never seen.
  ///
  /// It used to look the digest up among the builds compiled into the product,
  /// which refused a firmware daily published after the last release while it
  /// fitted the board perfectly. A build nobody enumerated now passes, and the
  /// finding names the version it declares.
  func testPreflightRefusesAnArchiveThatDoesNotFitTheBoardAndAdmitsOneItHasNeverSeen()
    async throws
  {
    let board = RockchipFlashProfile.dayu200
    let unknownDigest = String(repeating: "f", count: 64)

    // Never seen, fits the board: admitted, and the finding says which build.
    let admitted = await RockchipFlashPreflight(
      probes: preflightProbes(
        archive: RockchipFlashArchiveIdentity(sha256: unknownDigest, byteCount: 1_234))
    ).run(archiveURL: URL(filePath: "/tmp/images.tar.gz"))
    XCTAssertEqual(admitted.failedChecks, [])
    XCTAssertTrue(
      admitted.findings.contains {
        $0.check == .archiveIntegrity && $0.summary.contains(board.runtimeBuildVersion)
      }, admitted.findings.map(\.summary).joined(separator: " | "))

    // Structurally wrong: an image the board maps is absent.
    var probes = preflightProbes(
      archive: RockchipFlashArchiveIdentity(sha256: unknownDigest, byteCount: 1_234))
    probes.archiveSnapshot = { _, board in
      RockchipFlashArchiveSnapshot(
        identity: RockchipFlashArchiveIdentity(
          sha256: unknownDigest, byteCount: 1_234),
        build: RockchipImageBuildDescriptor(
          archiveSizeBytes: 1_234, archiveSHA256: unknownDigest,
          members: board.members.filter { $0.name != "system.img" },
          declaredPartitions: board.mappedPartitions.map {
            RockchipDeclaredPartition(name: $0.partitionName, sizeSectors: 1, offsetSectors: 0)
          }
            + board.membershiplessPartitionsWriteForbidden.map {
              RockchipDeclaredPartition(name: $0, sizeSectors: 1, offsetSectors: 0)
            },
          runtimeBuildVersion: board.runtimeBuildVersion))
    }
    let refused = await RockchipFlashPreflight(probes: probes)
      .run(archiveURL: URL(filePath: "/tmp/images.tar.gz"))
    XCTAssertEqual(refused.failedChecks, [.archiveIntegrity])

    // Unreadable as an images archive at all: also refused.
    struct Unreadable: Error {}
    var broken = preflightProbes(
      archive: RockchipFlashArchiveIdentity(sha256: unknownDigest, byteCount: 1_234))
    broken.archiveSnapshot = { _, _ in throw Unreadable() }
    let unreadable = await RockchipFlashPreflight(probes: broken)
      .run(archiveURL: URL(filePath: "/tmp/images.tar.gz"))
    XCTAssertEqual(unreadable.failedChecks, [.archiveIntegrity])
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
      ).run(archiveURL: URL(filePath: "/tmp/images.tar.gz"))
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
    ).run(archiveURL: URL(filePath: "/tmp/images.tar.gz"))
    XCTAssertTrue(receipt.isGreen, receipt.renderedLines().joined(separator: "\n"))
    let summary = try XCTUnwrap(
      receipt.findings.first { $0.check == .targetPresence }
    ).summary
    XCTAssertTrue(summary.contains("confirmed hdc-normal alias"), summary)
  }

  func testPreflightRefusesAliasShapedReadbacksThatDoNotMatchTheConfirmedEdge() async throws {
    let aliasIdentity = String(repeating: "d", count: 64)
    let cases:
      [(
        String, (identitySHA256: String, usbTopology: String)?,
        RockchipEvolutionTargetReadback
      )] = [
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
      ).run(archiveURL: URL(filePath: "/tmp/images.tar.gz"))
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
