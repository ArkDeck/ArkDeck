import ArkDeckCore
import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// Cross-mode identity coverage retained after the historical Flash campaign,
/// preflight and vendor execution stacks were removed.
final class RockchipFlashSupportingContractTests: XCTestCase {
  func testTheBindingVersionAndTheTargetEdgeAreSeparateNumbers() throws {
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
        "binding:target-previous-revision=3",
        "binding:target-current-revision=4",
        "identity:hdc-normal-alias-sha256=\(String(repeating: "b", count: 64))",
        "binding:hdc-normal-alias-usb-topology=17956864",
        "rebind:user-selection-sha256=\(String(repeating: "c", count: 64))",
      ])

    let advance = try XCTUnwrap(try snapshot.runtimeTargetLineageAdvance())
    XCTAssertEqual(advance.previousRevision, 3)
    XCTAssertEqual(advance.currentRevision, 4)
    XCTAssertEqual(advance.previousStableIdentitySHA256, previousIdentity)
    XCTAssertEqual(advance.currentStableIdentitySHA256, currentIdentity)
  }

  func testWithoutATargetEdgeTheBindingNumberingStillApplies() throws {
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
    let root = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-rebind-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RockchipProductBindingStore(rootURL: root)
    let original = RockchipProductUSBIdentity(
      serial: "board-on-first-port",
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
      topology: "18874368", productName: "HDC Device")
    XCTAssertEqual(
      try RockchipProductBindingBootstrap(probe: { original }, store: store)
        .installCurrentTarget().revision,
      1)

    let moved = RockchipProductUSBIdentity(
      serial: "board-on-second-port",
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
      topology: "17956864", productName: "HDC Device")
    XCTAssertThrowsError(
      try RockchipProductBindingBootstrap(probe: { moved }, store: store)
        .installCurrentTarget())
    XCTAssertEqual(
      try RockchipProductBindingBootstrap(probe: { moved }, store: store)
        .installCurrentTarget(rebind: true).revision,
      2)

    let snapshot = try JSONDecoder().decode(
      RockchipProductBindingSnapshot.self,
      from: Data(contentsOf: root.appending(path: RockchipProductBindingStore.bindingFileName)))
    XCTAssertNotNil(try snapshot.runtimeTargetLineageAdvance())
    XCTAssertTrue(snapshot.evidence.contains { $0.hasPrefix("rebind:user-selection-sha256=") })
    XCTAssertFalse(snapshot.evidence.contains { $0.contains(original.serial) || $0.contains(moved.serial) })
  }

  func testTypedE0BootstrapPublishesOwnerOnlyBindingAndRejectsDrift() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-binding-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = RockchipProductUSBIdentity(
      serial: "sensitive-loader-serial",
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
      topology: "336592896", productName: "HDC Device")
    let store = RockchipProductBindingStore(rootURL: root)
    let first = try RockchipProductBindingBootstrap(probe: { identity }, store: store)
      .installCurrentTarget()
    XCTAssertEqual(first.revision, 1)

    let bindingURL = root.appending(path: RockchipProductBindingStore.bindingFileName)
    var metadata = stat()
    XCTAssertEqual(lstat(bindingURL.path, &metadata), 0)
    XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
    let snapshot = try JSONDecoder().decode(
      RockchipProductBindingSnapshot.self, from: Data(contentsOf: bindingURL))
    XCTAssertFalse(snapshot.evidence.contains { $0.contains(identity.serial) })

    let drifted = RockchipProductUSBIdentity(
      serial: identity.serial, vendorID: identity.vendorID,
      productID: identity.productID, topology: "336592897",
      productName: identity.productName)
    XCTAssertThrowsError(
      try RockchipProductBindingBootstrap(probe: { drifted }, store: store)
        .installCurrentTarget())
    XCTAssertEqual(try store.loadExisting(), snapshot)
  }

  func testConfirmedLineageAcceptsOnlyExactLoaderAndPreviousNormalPersonality() throws {
    let loaderSerial = "loader-mode-serial"
    let normalSerial = "normal-mode-connect-key"
    let loaderIdentity = SHA256Hex.string(of: Data(loaderSerial.utf8))
    let normalIdentity = SHA256Hex.string(of: Data(normalSerial.utf8))
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
    let loader = RockchipProductUSBIdentity(
      serial: loaderSerial, vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipProbeEvidence.dayu200LoaderProductID,
      topology: "17956864")
    let normal = RockchipProductUSBIdentity(
      serial: normalSerial, vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
      topology: "18874368", productName: "HDC Device")
    XCTAssertTrue(try snapshot.matchesConfirmedLiveIdentity(loader))
    XCTAssertTrue(try snapshot.matchesConfirmedLiveIdentity(normal))
    XCTAssertEqual(try snapshot.confirmedHDCConnectKey(for: normal), normalSerial)
    XCTAssertTrue(
      try snapshot.coversRuntimeTarget(
        RuntimeTargetRecord(
          targetID: "TGT-BOUND", stablePhysicalIdentitySHA256: loaderIdentity,
          bindingRevision: 2, connectKey: normalSerial, toolVersion: "3.2.0f",
          adoptedAtUTC: "2026-08-08T00:00:00Z")))

    let wrongTopology = RockchipProductUSBIdentity(
      serial: normalSerial, vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
      topology: "17956864", productName: "HDC Device")
    XCTAssertFalse(try snapshot.matchesConfirmedLiveIdentity(wrongTopology))
  }

  func testRebindEvidenceRejectsMissingAmbiguousOrSkippedLineage() throws {
    let serial = "loader-mode-serial"
    let currentIdentity = SHA256Hex.string(of: Data(serial.utf8))
    let validEvidence = [
      "identity:serial-sha256=\(currentIdentity)",
      "rebind:user-selection-sha256=\(String(repeating: "b", count: 64))",
      "identity:previous-serial-sha256=\(String(repeating: "a", count: 64))",
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
}
