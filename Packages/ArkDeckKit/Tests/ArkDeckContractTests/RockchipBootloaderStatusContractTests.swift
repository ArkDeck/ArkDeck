import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class RockchipBootloaderStatusContractTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-loader-onboarding", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testReadOnlyObserverDistinguishesAbsentAmbiguousAndUnboundLoader() throws {
    let targets = try RuntimeTargetStore(
      directoryURL: root.appendingPathComponent("targets", isDirectory: true))
    let bindings = RockchipProductBindingStore(
      rootURL: root.appendingPathComponent("binding", isDirectory: true))
    let loader = loaderIdentity(serial: "loader-current", topology: "17956864")

    XCTAssertEqual(
      try observer(targets: targets, bindings: bindings, identities: [])
        .observeBootloaderStatus(),
      RockchipBootloaderStatus(
        disposition: .absent, observationCount: 0, mode: nil,
        targetID: nil, bindingRevision: nil))
    XCTAssertEqual(
      try observer(targets: targets, bindings: bindings, identities: [loader, loader])
        .observeBootloaderStatus().disposition,
      .ambiguous)
    XCTAssertEqual(
      try observer(targets: targets, bindings: bindings, identities: [loader])
        .observeBootloaderStatus(),
      RockchipBootloaderStatus(
        disposition: .unbound, observationCount: 1, mode: "loader",
        targetID: nil, bindingRevision: nil))
  }

  func testRuntimeOnboardsUniqueLoaderAndAdvancesOnlySelectedAdjacentTarget() throws {
    let fixture = try makeLegacyFixture()
    let coordinator = ProductRockchipLoaderBindingCoordinator(
      targetStore: fixture.targets,
      bindingStore: fixture.bindings,
      usbProbe: RockchipProductUSBProbe(identitySource: { [fixture.currentLoader] }))

    let receipt = try coordinator.bindCurrentLoader(
      targetID: fixture.target.targetID,
      expectedBindingRevision: fixture.target.bindingRevision)

    XCTAssertTrue(receipt.updated)
    XCTAssertEqual(receipt.previousRevision, 2)
    XCTAssertEqual(receipt.currentRevision, 3)
    XCTAssertEqual(receipt.selectionEvidenceSHA256.count, 64)
    let advanced = try XCTUnwrap(fixture.targets.find(targetID: fixture.target.targetID))
    XCTAssertEqual(advanced.bindingRevision, 3)
    XCTAssertEqual(advanced.stablePhysicalIdentitySHA256, digest(fixture.currentLoader.serial))
    XCTAssertEqual(advanced.connectKey, fixture.target.connectKey)

    let stored = try fixture.bindings.loadExisting()
    XCTAssertEqual(stored.revision, 3)
    XCTAssertEqual(stored.serial, fixture.currentLoader.serial)
    XCTAssertFalse(stored.evidence.contains { $0.hasPrefix("rebind:chat-confirmation-sha256=") })
    XCTAssertTrue(
      stored.evidence.contains(
        "rebind:user-selection-sha256=\(receipt.selectionEvidenceSHA256)"))
    XCTAssertEqual(
      try stored.confirmedHDCNormalAlias()?.identitySHA256,
      digest(fixture.target.connectKey))

    let status = try observer(
      targets: fixture.targets,
      bindings: fixture.bindings,
      identities: [fixture.currentLoader]
    ).observeBootloaderStatus()
    XCTAssertEqual(status.disposition, .exactBoundTarget)
    XCTAssertEqual(status.targetID, fixture.target.targetID)
    XCTAssertEqual(status.bindingRevision, 3)
  }

  func testLostBindingResponseCanRetryTheSameOldRevisionIdempotently() throws {
    let fixture = try makeLegacyFixture()
    let coordinator = ProductRockchipLoaderBindingCoordinator(
      targetStore: fixture.targets,
      bindingStore: fixture.bindings,
      usbProbe: RockchipProductUSBProbe(identitySource: { [fixture.currentLoader] }))
    let first = try coordinator.bindCurrentLoader(
      targetID: fixture.target.targetID, expectedBindingRevision: 2)
    let retry = try coordinator.bindCurrentLoader(
      targetID: fixture.target.targetID, expectedBindingRevision: 2)

    XCTAssertTrue(first.updated)
    XCTAssertFalse(retry.updated)
    XCTAssertEqual(retry.previousRevision, 2)
    XCTAssertEqual(retry.currentRevision, 3)
    XCTAssertEqual(retry.selectionEvidenceSHA256, first.selectionEvidenceSHA256)
  }

  func testRuntimeReattestsHistoricalBindingWhenSelectedTargetIsAlreadyTheLiveLoader() throws {
    let fixture = try makeSameLoaderLegacyFixture()
    let statusBefore = try observer(
      targets: fixture.targets,
      bindings: fixture.bindings,
      identities: [fixture.loader]
    ).observeBootloaderStatus()
    XCTAssertEqual(
      statusBefore,
      RockchipBootloaderStatus(
        disposition: .targetBindingUnprepared,
        observationCount: 1,
        mode: "loader",
        targetID: fixture.target.targetID,
        bindingRevision: 2))

    let coordinator = ProductRockchipLoaderBindingCoordinator(
      targetStore: fixture.targets,
      bindingStore: fixture.bindings,
      usbProbe: RockchipProductUSBProbe(identitySource: { [fixture.loader] }))
    let receipt = try coordinator.bindCurrentLoader(
      targetID: fixture.target.targetID,
      expectedBindingRevision: fixture.target.bindingRevision)

    XCTAssertTrue(receipt.updated)
    XCTAssertEqual(receipt.previousRevision, 2)
    XCTAssertEqual(receipt.currentRevision, 2)
    XCTAssertEqual(receipt.selectionEvidenceSHA256.count, 64)
    let unchangedTarget = try XCTUnwrap(
      fixture.targets.find(targetID: fixture.target.targetID))
    XCTAssertEqual(unchangedTarget, fixture.target)

    let stored = try fixture.bindings.loadExisting()
    XCTAssertEqual(stored.revision, 2)
    XCTAssertEqual(stored.serial, fixture.loader.serial)
    XCTAssertFalse(
      stored.evidence.contains { $0.hasPrefix("rebind:chat-confirmation-sha256=") })
    XCTAssertTrue(
      stored.evidence.contains(
        "rebind:user-selection-sha256=\(receipt.selectionEvidenceSHA256)"))
    XCTAssertEqual(
      try stored.confirmedHDCNormalAlias()?.identitySHA256,
      digest(fixture.hdcSerial))
    let lineage = try XCTUnwrap(stored.runtimeTargetLineageAdvance())
    XCTAssertEqual(lineage.previousRevision, 1)
    XCTAssertEqual(lineage.currentRevision, 2)
    XCTAssertEqual(
      lineage.currentStableIdentitySHA256,
      digest(fixture.loader.serial))

    let statusAfter = try observer(
      targets: fixture.targets,
      bindings: fixture.bindings,
      identities: [fixture.loader]
    ).observeBootloaderStatus()
    XCTAssertEqual(statusAfter.disposition, .exactBoundTarget)
    XCTAssertEqual(statusAfter.targetID, fixture.target.targetID)
    XCTAssertEqual(statusAfter.bindingRevision, 2)

    let retry = try coordinator.bindCurrentLoader(
      targetID: fixture.target.targetID,
      expectedBindingRevision: fixture.target.bindingRevision)
    XCTAssertFalse(retry.updated)
    XCTAssertEqual(retry.previousRevision, 2)
    XCTAssertEqual(retry.currentRevision, 2)
    XCTAssertEqual(retry.selectionEvidenceSHA256, receipt.selectionEvidenceSHA256)
  }

  func testAmbiguousLoaderRefusesBeforeChangingBindingOrTarget() throws {
    let fixture = try makeLegacyFixture()
    let another = loaderIdentity(serial: "loader-another", topology: "19791872")
    let coordinator = ProductRockchipLoaderBindingCoordinator(
      targetStore: fixture.targets,
      bindingStore: fixture.bindings,
      usbProbe: RockchipProductUSBProbe(
        identitySource: { [fixture.currentLoader, another] }))

    XCTAssertThrowsError(
      try coordinator.bindCurrentLoader(
        targetID: fixture.target.targetID,
        expectedBindingRevision: fixture.target.bindingRevision))
    XCTAssertEqual(try fixture.bindings.loadExisting().revision, 2)
    XCTAssertEqual(
      try fixture.targets.find(targetID: fixture.target.targetID)?.bindingRevision,
      2)
  }

  private func observer(
    targets: RuntimeTargetStore,
    bindings: RockchipProductBindingStore,
    identities: [RockchipProductUSBIdentity]
  ) -> ProductRockchipBootloaderStatusObserver {
    ProductRockchipBootloaderStatusObserver(
      targetStore: targets,
      bindingStore: bindings,
      usbProbe: RockchipProductUSBProbe(identitySource: { identities }))
  }

  private func makeLegacyFixture() throws -> (
    targets: RuntimeTargetStore,
    bindings: RockchipProductBindingStore,
    target: RuntimeTargetRecord,
    currentLoader: RockchipProductUSBIdentity
  ) {
    let targets = try RuntimeTargetStore(
      directoryURL: root.appendingPathComponent("targets", isDirectory: true))
    let bindings = RockchipProductBindingStore(
      rootURL: root.appendingPathComponent("binding", isDirectory: true))
    let hdcSerial = "hdc-normal-connect-key"
    let oldLoaderSerial = "loader-previous-session"
    let currentLoader = loaderIdentity(serial: "loader-current-session", topology: "17956864")
    let adopted = try targets.adopt(
      stableIdentitySHA256: digest(hdcSerial),
      connectKey: hdcSerial,
      toolVersion: "3.2.0f",
      nowUTC: "2026-08-08T00:00:00Z").record
    let oldLoaderDigest = digest(oldLoaderSerial)
    let advanced = try targets.advanceBindingLineage(
      RuntimeTargetBindingLineageAdvance(
        previousStableIdentitySHA256: adopted.stablePhysicalIdentitySHA256,
        previousRevision: adopted.bindingRevision,
        currentStableIdentitySHA256: oldLoaderDigest,
        currentRevision: adopted.bindingRevision + 1)).record
    _ = try bindings.install(
      RockchipProductBindingSnapshot(
        revision: 2,
        serial: oldLoaderSerial,
        usbTopology: "18874368",
        evidence: [
          "product:e0-iokit-single-loader-readback",
          "identity:serial-sha256=\(oldLoaderDigest)",
          "rebind:chat-confirmation-sha256=\(String(repeating: "b", count: 64))",
          "identity:previous-serial-sha256=\(digest(hdcSerial))",
          "binding:previous-revision=1",
          "binding:previous-usb-topology=16777216",
        ]))
    return (targets, bindings, advanced, currentLoader)
  }

  private func makeSameLoaderLegacyFixture() throws -> (
    targets: RuntimeTargetStore,
    bindings: RockchipProductBindingStore,
    target: RuntimeTargetRecord,
    loader: RockchipProductUSBIdentity,
    hdcSerial: String
  ) {
    let targets = try RuntimeTargetStore(
      directoryURL: root.appendingPathComponent("targets-same-loader", isDirectory: true))
    let bindings = RockchipProductBindingStore(
      rootURL: root.appendingPathComponent("binding-same-loader", isDirectory: true))
    let hdcSerial = "hdc-normal-connect-key"
    let loader = loaderIdentity(serial: "loader-current-session", topology: "17956864")
    let adopted = try targets.adopt(
      stableIdentitySHA256: digest(hdcSerial),
      connectKey: hdcSerial,
      toolVersion: "3.2.0f",
      nowUTC: "2026-08-08T00:00:00Z").record
    let loaderDigest = digest(loader.serial)
    let advanced = try targets.advanceBindingLineage(
      RuntimeTargetBindingLineageAdvance(
        previousStableIdentitySHA256: adopted.stablePhysicalIdentitySHA256,
        previousRevision: adopted.bindingRevision,
        currentStableIdentitySHA256: loaderDigest,
        currentRevision: adopted.bindingRevision + 1)).record
    _ = try bindings.install(
      RockchipProductBindingSnapshot(
        revision: 2,
        serial: loader.serial,
        usbTopology: loader.topology,
        evidence: [
          "product:e0-iokit-single-loader-readback",
          "identity:serial-sha256=\(loaderDigest)",
          "rebind:chat-confirmation-sha256=\(String(repeating: "b", count: 64))",
          "identity:previous-serial-sha256=\(digest(hdcSerial))",
          "binding:previous-revision=1",
          "binding:previous-usb-topology=16777216",
        ]))
    return (targets, bindings, advanced, loader, hdcSerial)
  }

  private func loaderIdentity(serial: String, topology: String) -> RockchipProductUSBIdentity {
    RockchipProductUSBIdentity(
      serial: serial,
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipProbeEvidence.dayu200LoaderProductID,
      topology: topology)
  }

  private func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
