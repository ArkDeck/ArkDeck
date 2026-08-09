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
    let fixture = try makeCurrentFixture()
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

  func testRuntimeActivatesOnlyTheExactSelectedRevisionOneTargetAcrossDAYU200Modes() throws {
    let identities: [(name: String, identity: RockchipProductUSBIdentity)] = [
      ("loader", loaderIdentity(serial: "selected-loader", topology: "17956864")),
      ("hdc", hdcIdentity(serial: "selected-hdc", topology: "18874368")),
    ]

    for fixture in identities {
      let targets = try RuntimeTargetStore(
        directoryURL: root
          .appendingPathComponent("targets-switch-\(fixture.name)", isDirectory: true))
      let bindings = RockchipProductBindingStore(
        rootURL: root
          .appendingPathComponent("binding-switch-\(fixture.name)", isDirectory: true))
      let previousIdentity = hdcIdentity(
        serial: "previous-hdc-\(fixture.name)", topology: "16777216")
      let previousTarget = try targets.adopt(
        stableIdentitySHA256: digest(previousIdentity.serial),
        connectKey: previousIdentity.serial,
        toolVersion: "3.2.0f",
        nowUTC: "2026-08-08T00:00:00Z").record
      _ = try bindings.install(
        RockchipProductBindingSnapshot(
          revision: 1,
          serial: previousIdentity.serial,
          usbTopology: previousIdentity.topology,
          evidence: [
            "product:e0-iokit-single-dayu200-readback",
            "identity:serial-sha256=\(digest(previousIdentity.serial))",
          ]))
      let selectedTarget = try targets.adopt(
        stableIdentitySHA256: digest(fixture.identity.serial),
        connectKey: fixture.identity.serial,
        toolVersion: "3.2.0f",
        nowUTC: "2026-08-08T00:01:00Z").record

      let statusBefore = try observer(
        targets: targets,
        bindings: bindings,
        identities: [fixture.identity]
      ).observeBootloaderStatus()
      XCTAssertEqual(statusBefore.disposition, .targetBindingUnprepared)
      XCTAssertEqual(statusBefore.targetID, selectedTarget.targetID)

      let coordinator = ProductRockchipLoaderBindingCoordinator(
        targetStore: targets,
        bindingStore: bindings,
        usbProbe: RockchipProductUSBProbe(identitySource: { [fixture.identity] }))
      let receipt = try coordinator.bindCurrentLoader(
        targetID: selectedTarget.targetID,
        expectedBindingRevision: selectedTarget.bindingRevision)
      let retry = try coordinator.bindCurrentLoader(
        targetID: selectedTarget.targetID,
        expectedBindingRevision: selectedTarget.bindingRevision)

      XCTAssertTrue(receipt.updated)
      XCTAssertFalse(retry.updated)
      XCTAssertEqual(receipt.previousRevision, 1)
      XCTAssertEqual(receipt.currentRevision, 1)
      XCTAssertEqual(retry.selectionEvidenceSHA256, receipt.selectionEvidenceSHA256)
      XCTAssertEqual(receipt.selectionEvidenceSHA256.count, 64)
      XCTAssertEqual(
        try targets.find(targetID: selectedTarget.targetID), selectedTarget)
      XCTAssertEqual(
        try targets.find(targetID: previousTarget.targetID), previousTarget)
      let stored = try bindings.loadExisting()
      XCTAssertEqual(stored.revision, 1)
      XCTAssertEqual(stored.serial, fixture.identity.serial)
      XCTAssertTrue(
        stored.evidence.contains("binding:selected-target-id=\(selectedTarget.targetID)"))
      XCTAssertEqual(
        try observer(
          targets: targets,
          bindings: bindings,
          identities: [fixture.identity]
        ).observeBootloaderStatus().disposition,
        .exactBoundTarget)
    }
  }

  func testRuntimeReactivatesExactAdvancedTargetFromCompleteTypedHistory() throws {
    let fixture = try makeDisplacedAdvancedFixture("reactivation")
    let proof = RockchipBindingReactivationProof(
      targetID: fixture.target.targetID,
      bindingRevision: fixture.target.bindingRevision,
      stableLoaderIdentitySHA256: fixture.target.stablePhysicalIdentitySHA256,
      hdcConnectKey: fixture.target.connectKey,
      hdcIdentitySHA256: digest(fixture.target.connectKey),
      hdcUSBTopology: "18874368",
      currentBindingIntentSHA256: String(repeating: "d", count: 64),
      hdcRouteReceiptSHA256: String(repeating: "e", count: 64))
    let coordinator = ProductRockchipLoaderBindingCoordinator(
      targetStore: fixture.targets,
      bindingStore: fixture.bindings,
      usbProbe: RockchipProductUSBProbe(identitySource: { [fixture.loader] }),
      reactivationProofSource: StaticReactivationProofSource(proof: proof))

    let receipt = try coordinator.bindCurrentLoader(
      targetID: fixture.target.targetID,
      expectedBindingRevision: fixture.target.bindingRevision)
    let retry = try coordinator.bindCurrentLoader(
      targetID: fixture.target.targetID,
      expectedBindingRevision: fixture.target.bindingRevision)

    XCTAssertTrue(receipt.updated)
    XCTAssertFalse(retry.updated)
    XCTAssertEqual(receipt.previousRevision, fixture.target.bindingRevision)
    XCTAssertEqual(receipt.currentRevision, fixture.target.bindingRevision)
    XCTAssertEqual(receipt.selectionEvidenceSHA256, retry.selectionEvidenceSHA256)
    XCTAssertEqual(
      try fixture.targets.find(targetID: fixture.target.targetID), fixture.target,
      "same-revision reactivation must not rewrite or advance the Runtime target")
    let stored = try fixture.bindings.loadExisting()
    XCTAssertEqual(try stored.reactivatedTargetID(), fixture.target.targetID)
    XCTAssertNil(try stored.runtimeTargetLineageAdvance())
    XCTAssertNil(try stored.loaderBindingRecoveryProof())
    XCTAssertEqual(
      try stored.confirmedHDCNormalAlias()?.identitySHA256,
      digest(fixture.target.connectKey))
    XCTAssertTrue(try stored.matchesConfirmedLiveIdentity(fixture.loader))
    XCTAssertTrue(
      try stored.matchesConfirmedLiveIdentity(
        hdcIdentity(serial: fixture.target.connectKey, topology: "18874368")))
    XCTAssertEqual(
      try observer(
        targets: fixture.targets,
        bindings: fixture.bindings,
        identities: [fixture.loader]
      ).observeBootloaderStatus().disposition,
      .exactBoundTarget)
  }

  func testAdvancedTargetReactivationRejectsMissingOrMismatchedProofWithoutRewrite() throws {
    for proof in [
      nil,
      RockchipBindingReactivationProof(
        targetID: "TGT-wrong",
        bindingRevision: 3,
        stableLoaderIdentitySHA256: String(repeating: "a", count: 64),
        hdcConnectKey: "wrong-connect-key",
        hdcIdentitySHA256: String(repeating: "b", count: 64),
        hdcUSBTopology: "18874368",
        currentBindingIntentSHA256: String(repeating: "d", count: 64),
        hdcRouteReceiptSHA256: String(repeating: "e", count: 64)),
    ] {
      let fixture = try makeDisplacedAdvancedFixture(
        proof == nil ? "missing-proof" : "mismatched-proof")
      let originalBinding = try fixture.bindings.loadExisting()
      let coordinator = ProductRockchipLoaderBindingCoordinator(
        targetStore: fixture.targets,
        bindingStore: fixture.bindings,
        usbProbe: RockchipProductUSBProbe(identitySource: { [fixture.loader] }),
        reactivationProofSource: StaticReactivationProofSource(proof: proof))

      XCTAssertThrowsError(
        try coordinator.bindCurrentLoader(
          targetID: fixture.target.targetID,
          expectedBindingRevision: fixture.target.bindingRevision))
      XCTAssertEqual(try fixture.bindings.loadExisting(), originalBinding)
      XCTAssertEqual(
        try fixture.targets.find(targetID: fixture.target.targetID), fixture.target)
    }
  }

  func testRuntimeReactivationProofSourceRequiresCorrelatedUniqueTopology() throws {
    let fixture = try makeDisplacedAdvancedFixture("durable-proof")
    let recordRoot = root.appendingPathComponent("runtime-proof", isDirectory: true)
    try writeCurrentRouteIntent(
      root: recordRoot,
      jobID: "job-current",
      target: fixture.target)
    try writeConfirmedHDCRoute(
      root: recordRoot,
      jobID: "job-previous",
      stepID: "reconcile-enter-loader-mode-proof",
      target: fixture.target,
      bindingRevision: fixture.target.bindingRevision - 1,
      stableIdentitySHA256: digest("prior-loader"),
      topology: "18874368")
    let source = RockchipRuntimeBindingReactivationProofSource(rootURL: recordRoot)

    let proof = try XCTUnwrap(source.proof(for: fixture.target))
    XCTAssertEqual(proof.targetID, fixture.target.targetID)
    XCTAssertEqual(proof.bindingRevision, fixture.target.bindingRevision)
    XCTAssertEqual(proof.hdcConnectKey, fixture.target.connectKey)
    XCTAssertEqual(proof.hdcIdentitySHA256, digest(fixture.target.connectKey))
    XCTAssertEqual(proof.hdcUSBTopology, "18874368")
    XCTAssertEqual(proof.currentBindingIntentSHA256.count, 64)
    XCTAssertEqual(proof.hdcRouteReceiptSHA256.count, 64)

    try writeConfirmedHDCRoute(
      root: recordRoot,
      jobID: "job-conflict",
      stepID: "reconcile-enter-loader-mode-conflict",
      target: fixture.target,
      bindingRevision: fixture.target.bindingRevision - 1,
      stableIdentitySHA256: digest("prior-loader"),
      topology: "19791872")
    XCTAssertNil(
      try source.proof(for: fixture.target),
      "two confirmed topologies must fail closed instead of selecting one")
  }

  func testRuntimeReactivationProofSourceScopesHistoryToCurrentProvider() throws {
    let fixture = try makeDisplacedAdvancedFixture("durable-proof-provider-history")
    let recordRoot = root.appendingPathComponent(
      "runtime-proof-provider-history", isDirectory: true)
    let currentProvider = String(repeating: "a", count: 64)
    try writeCurrentRouteIntent(
      root: recordRoot,
      jobID: "job-current",
      target: fixture.target,
      providerExecutableSHA256: currentProvider)
    try writeConfirmedHDCRoute(
      root: recordRoot,
      jobID: "job-current-provider-route",
      stepID: "reconcile-enter-loader-mode-current-provider",
      target: fixture.target,
      bindingRevision: fixture.target.bindingRevision - 1,
      stableIdentitySHA256: digest("prior-loader"),
      topology: "18874368",
      providerExecutableSHA256: currentProvider)
    try writeConfirmedHDCRoute(
      root: recordRoot,
      jobID: "job-stale-provider-route",
      stepID: "reconcile-enter-loader-mode-stale-provider",
      target: fixture.target,
      bindingRevision: fixture.target.bindingRevision - 1,
      stableIdentitySHA256: digest("older-loader"),
      topology: "19791872",
      providerExecutableSHA256: String(repeating: "b", count: 64))

    let proof = try XCTUnwrap(
      RockchipRuntimeBindingReactivationProofSource(rootURL: recordRoot)
        .proof(for: fixture.target))
    XCTAssertEqual(proof.hdcUSBTopology, "18874368")
  }

  func testRuntimeReactivationProofSourceRejectsHashAndOwnershipDrift() throws {
    let fixture = try makeDisplacedAdvancedFixture("durable-proof-negative")
    let hashRoot = root.appendingPathComponent("runtime-proof-hash", isDirectory: true)
    try writeCurrentRouteIntent(
      root: hashRoot,
      jobID: "job-current",
      target: fixture.target,
      actionSHA256Override: String(repeating: "f", count: 64))
    try writeConfirmedHDCRoute(
      root: hashRoot,
      jobID: "job-previous",
      stepID: "reconcile-enter-loader-mode-proof",
      target: fixture.target,
      bindingRevision: fixture.target.bindingRevision - 1,
      stableIdentitySHA256: digest("prior-loader"),
      topology: "18874368")
    XCTAssertNil(
      try RockchipRuntimeBindingReactivationProofSource(rootURL: hashRoot)
        .proof(for: fixture.target))

    let modeRoot = root.appendingPathComponent("runtime-proof-mode", isDirectory: true)
    try writeCurrentRouteIntent(
      root: modeRoot,
      jobID: "job-current",
      target: fixture.target)
    try writeConfirmedHDCRoute(
      root: modeRoot,
      jobID: "job-previous",
      stepID: "reconcile-enter-loader-mode-proof",
      target: fixture.target,
      bindingRevision: fixture.target.bindingRevision - 1,
      stableIdentitySHA256: digest("prior-loader"),
      topology: "18874368",
      receiptPermissions: 0o644)
    XCTAssertNil(
      try RockchipRuntimeBindingReactivationProofSource(rootURL: modeRoot)
        .proof(for: fixture.target))

    let oldRoot = root.appendingPathComponent("runtime-proof-old", isDirectory: true)
    try writeCurrentRouteIntent(
      root: oldRoot,
      jobID: "job-current",
      target: fixture.target)
    try writeConfirmedHDCRoute(
      root: oldRoot,
      jobID: "job-old",
      stepID: "reconcile-enter-loader-mode-proof",
      target: fixture.target,
      bindingRevision: fixture.target.bindingRevision - 2,
      stableIdentitySHA256: digest("old-loader"),
      topology: "18874368")
    XCTAssertNil(
      try RockchipRuntimeBindingReactivationProofSource(rootURL: oldRoot)
        .proof(for: fixture.target),
      "a non-adjacent historical route must not reactivate the current revision")

    let providerRoot = root.appendingPathComponent(
      "runtime-proof-provider", isDirectory: true)
    try writeCurrentRouteIntent(
      root: providerRoot,
      jobID: "job-current",
      target: fixture.target)
    try writeConfirmedHDCRoute(
      root: providerRoot,
      jobID: "job-previous",
      stepID: "reconcile-enter-loader-mode-proof",
      target: fixture.target,
      bindingRevision: fixture.target.bindingRevision - 1,
      stableIdentitySHA256: digest("prior-loader"),
      topology: "18874368",
      providerExecutableSHA256: String(repeating: "b", count: 64))
    XCTAssertNil(
      try RockchipRuntimeBindingReactivationProofSource(rootURL: providerRoot)
        .proof(for: fixture.target),
      "typed records produced by different provider executables must not be correlated")
  }

  func testSelectedInitialTargetActivationRejectsConnectKeyDriftWithoutChangingBinding() throws {
    let targets = try RuntimeTargetStore(
      directoryURL: root.appendingPathComponent("targets-switch-drift", isDirectory: true))
    let bindings = RockchipProductBindingStore(
      rootURL: root.appendingPathComponent("binding-switch-drift", isDirectory: true))
    let previous = hdcIdentity(serial: "previous-active", topology: "16777216")
    let current = hdcIdentity(serial: "current-live", topology: "18874368")
    _ = try bindings.install(
      RockchipProductBindingSnapshot(
        revision: 1,
        serial: previous.serial,
        usbTopology: previous.topology,
        evidence: [
          "product:e0-iokit-single-dayu200-readback",
          "identity:serial-sha256=\(digest(previous.serial))",
        ]))
    let selected = try targets.adopt(
      stableIdentitySHA256: digest(current.serial),
      connectKey: "different-connect-key",
      toolVersion: "3.2.0f",
      nowUTC: "2026-08-08T00:00:00Z").record
    let originalBinding = try bindings.loadExisting()
    let coordinator = ProductRockchipLoaderBindingCoordinator(
      targetStore: targets,
      bindingStore: bindings,
      usbProbe: RockchipProductUSBProbe(identitySource: { [current] }))

    XCTAssertThrowsError(
      try coordinator.bindCurrentLoader(
        targetID: selected.targetID,
        expectedBindingRevision: selected.bindingRevision))
    XCTAssertEqual(try bindings.loadExisting(), originalBinding)
    XCTAssertEqual(try targets.find(targetID: selected.targetID), selected)
  }

  func testLostBindingResponseCanRetryTheSameOldRevisionIdempotently() throws {
    let fixture = try makeCurrentFixture()
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

  func testVerifiedPostFlashHDCAliasResolvesToTheOriginalBoundTarget() throws {
    let fixture = try makeCurrentFixture()
    let coordinator = ProductRockchipLoaderBindingCoordinator(
      targetStore: fixture.targets,
      bindingStore: fixture.bindings,
      usbProbe: RockchipProductUSBProbe(identitySource: { [fixture.currentLoader] }))
    _ = try coordinator.bindCurrentLoader(
      targetID: fixture.target.targetID,
      expectedBindingRevision: fixture.target.bindingRevision)
    let original = try XCTUnwrap(
      fixture.targets.find(targetID: fixture.target.targetID))
    let binding = try fixture.bindings.loadExisting()
    let priorAlias = try XCTUnwrap(binding.confirmedHDCNormalAlias())
    let nextHDC = hdcIdentity(
      serial: "post-flash-hdc-connect-key", topology: priorAlias.usbTopology)
    let duplicate = try fixture.targets.adopt(
      stableIdentitySHA256: digest(nextHDC.serial),
      connectKey: nextHDC.serial,
      toolVersion: "3.2.0f",
      nowUTC: "2026-08-08T00:20:00Z").record
    XCTAssertNotEqual(duplicate.targetID, original.targetID)
    let routedStore = RockchipPostFlashHDCBindingStore(rootURL: fixture.bindings.rootURL)
    _ = try routedStore.publish(
      RockchipPostFlashHDCBinding(
        targetID: original.targetID,
        bindingRevision: original.bindingRevision,
        stableLoaderIdentitySHA256: original.stablePhysicalIdentitySHA256,
        previousHDCIdentitySHA256: priorAlias.identitySHA256,
        hdcIdentitySHA256: digest(nextHDC.serial),
        hdcConnectKey: nextHDC.serial,
        usbTopology: nextHDC.topology,
        productModel: RockchipFlashProfile.dayu200.runtimeProductModel,
        buildVersion: RockchipFlashProfile.dayu200.runtimeBuildVersion,
        jobID: "job-post-flash",
        establishedAtUTC: "2026-08-08T00:19:00Z"),
      expectedPreviousHDCIdentitySHA256: priorAlias.identitySHA256)

    let status = try observer(
      targets: fixture.targets,
      bindings: fixture.bindings,
      postFlashBindings: routedStore,
      identities: [nextHDC]
    ).observeBootloaderStatus()
    XCTAssertEqual(status.disposition, .exactBoundTarget)
    XCTAssertEqual(status.targetID, original.targetID)
    XCTAssertEqual(status.bindingRevision, original.bindingRevision)

    let wrongTopology = hdcIdentity(
      serial: nextHDC.serial, topology: "19791872")
    let rejected = try observer(
      targets: fixture.targets,
      bindings: fixture.bindings,
      postFlashBindings: routedStore,
      identities: [wrongTopology]
    ).observeBootloaderStatus()
    XCTAssertEqual(rejected.disposition, .targetBindingUnprepared)
    XCTAssertEqual(rejected.targetID, duplicate.targetID)
  }

  func testHistoricalSameRevisionBindingIsRejectedWithoutRewrite() throws {
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

    let originalBinding = try fixture.bindings.loadExisting()
    let coordinator = ProductRockchipLoaderBindingCoordinator(
      targetStore: fixture.targets,
      bindingStore: fixture.bindings,
      usbProbe: RockchipProductUSBProbe(identitySource: { [fixture.loader] }))
    XCTAssertThrowsError(
      try coordinator.bindCurrentLoader(
        targetID: fixture.target.targetID,
        expectedBindingRevision: fixture.target.bindingRevision))
    XCTAssertEqual(try fixture.bindings.loadExisting(), originalBinding)
    XCTAssertEqual(
      try fixture.targets.find(targetID: fixture.target.targetID), fixture.target)

    let statusAfter = try observer(
      targets: fixture.targets,
      bindings: fixture.bindings,
      identities: [fixture.loader]
    ).observeBootloaderStatus()
    XCTAssertEqual(statusAfter.disposition, .targetBindingUnprepared)
    XCTAssertEqual(statusAfter.targetID, fixture.target.targetID)
    XCTAssertEqual(statusAfter.bindingRevision, 2)
  }

  func testAmbiguousLoaderRefusesBeforeChangingBindingOrTarget() throws {
    let fixture = try makeCurrentFixture()
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
    postFlashBindings: RockchipPostFlashHDCBindingStore? = nil,
    identities: [RockchipProductUSBIdentity]
  ) -> ProductRockchipBootloaderStatusObserver {
    ProductRockchipBootloaderStatusObserver(
      targetStore: targets,
      bindingStore: bindings,
      postFlashHDCBindingStore: postFlashBindings,
      usbProbe: RockchipProductUSBProbe(identitySource: { identities }))
  }

  private func makeDisplacedAdvancedFixture(_ suffix: String) throws -> (
    targets: RuntimeTargetStore,
    bindings: RockchipProductBindingStore,
    target: RuntimeTargetRecord,
    loader: RockchipProductUSBIdentity
  ) {
    let targets = try RuntimeTargetStore(
      directoryURL: root.appendingPathComponent(
        "targets-displaced-\(suffix)", isDirectory: true))
    let bindings = RockchipProductBindingStore(
      rootURL: root.appendingPathComponent(
        "binding-displaced-\(suffix)", isDirectory: true))
    let hdcSerial = "selected-hdc-\(suffix)"
    let adopted = try targets.adopt(
      stableIdentitySHA256: digest(hdcSerial),
      connectKey: hdcSerial,
      toolVersion: "3.2.0f",
      nowUTC: "2026-08-08T00:00:00Z").record
    let revisionTwo = try targets.advanceBindingLineage(
      RuntimeTargetBindingLineageAdvance(
        previousStableIdentitySHA256: adopted.stablePhysicalIdentitySHA256,
        previousRevision: adopted.bindingRevision,
        currentStableIdentitySHA256: digest("prior-loader-\(suffix)"),
        currentRevision: adopted.bindingRevision + 1)).record
    let loader = loaderIdentity(
      serial: "current-loader-\(suffix)", topology: "17956864")
    let target = try targets.advanceBindingLineage(
      RuntimeTargetBindingLineageAdvance(
        previousStableIdentitySHA256: revisionTwo.stablePhysicalIdentitySHA256,
        previousRevision: revisionTwo.bindingRevision,
        currentStableIdentitySHA256: digest(loader.serial),
        currentRevision: revisionTwo.bindingRevision + 1)).record
    let active = hdcIdentity(
      serial: "other-active-\(suffix)", topology: "16777216")
    _ = try bindings.install(
      RockchipProductBindingSnapshot(
        revision: 1,
        serial: active.serial,
        usbTopology: active.topology,
        evidence: [
          "product:e0-iokit-single-dayu200-readback",
          "identity:serial-sha256=\(digest(active.serial))",
        ]))
    return (targets, bindings, target, loader)
  }

  private func writeCurrentRouteIntent(
    root: URL,
    jobID: String,
    target: RuntimeTargetRecord,
    actionSHA256Override: String? = nil,
    providerExecutableSHA256: String = String(repeating: "a", count: 64)
  ) throws {
    let stepID = "wait-for-hdc"
    let action = try persistedAction(
      .rockchip(.waitForHDCReconnect(connectKey: target.connectKey)))
    let directory = root
      .appendingPathComponent(jobID, isDirectory: true)
      .appendingPathComponent(stepID, isDirectory: true)
    try prepareRecordDirectory(directory, root: root)
    try writeRecord(
      [
        "schemaVersion": "1.0.0",
        "jobID": jobID,
        "stepID": stepID,
        "targetID": target.targetID,
        "bindingRevision": target.bindingRevision,
        "stableIdentitySHA256": target.stablePhysicalIdentitySHA256,
        "providerExecutableSHA256": providerExecutableSHA256,
        "actionSHA256": actionSHA256Override ?? action.sha256,
        "action": action.object,
      ],
      to: directory.appendingPathComponent("intent.json"))
  }

  private func writeConfirmedHDCRoute(
    root: URL,
    jobID: String,
    stepID: String,
    target: RuntimeTargetRecord,
    bindingRevision: Int,
    stableIdentitySHA256: String,
    topology: String,
    receiptPermissions: NSNumber = 0o600,
    providerExecutableSHA256: String = String(repeating: "a", count: 64)
  ) throws {
    let action = try persistedAction(
      .rockchip(.observeHDCNormalUSB(connectKey: target.connectKey)))
    let directory = root
      .appendingPathComponent(jobID, isDirectory: true)
      .appendingPathComponent(stepID, isDirectory: true)
    try prepareRecordDirectory(directory, root: root)
    let common: [String: Any] = [
      "schemaVersion": "1.0.0",
      "jobID": jobID,
      "stepID": stepID,
      "targetID": target.targetID,
      "bindingRevision": bindingRevision,
      "stableIdentitySHA256": stableIdentitySHA256,
      "providerExecutableSHA256": providerExecutableSHA256,
      "actionSHA256": action.sha256,
    ]
    var intent = common
    intent["action"] = action.object
    try writeRecord(intent, to: directory.appendingPathComponent("intent.json"))

    var receipt = common
    receipt["summary"] = [
      "hdcNormalIdentitySha256": digest(target.connectKey),
      "usbState": "hdc-normal",
      "usbTopology": topology,
    ]
    receipt["stdoutSHA256"] = digest(Data())
    receipt["stdoutByteCount"] = 0
    receipt["stderrSHA256"] = digest(Data())
    receipt["stderrByteCount"] = 0
    receipt["stdoutTruncated"] = false
    receipt["subprocessCount"] = 1
    try writeRecord(
      receipt,
      to: directory.appendingPathComponent("receipt.json"),
      permissions: receiptPermissions)
  }

  private func persistedAction(
    _ action: TypedProviderAction
  ) throws -> (object: Any, sha256: String) {
    let persisted = try PersistedTypedProviderAction(action)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(persisted)
    return (try JSONSerialization.jsonObject(with: data), digest(data))
  }

  private func prepareRecordDirectory(_ directory: URL, root: URL) throws {
    let job = directory.deletingLastPathComponent()
    for value in [root, job, directory] {
      try FileManager.default.createDirectory(
        at: value, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: value.path)
    }
  }

  private func writeRecord(
    _ object: [String: Any],
    to url: URL,
    permissions: NSNumber = 0o600
  ) throws {
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    XCTAssertTrue(
      FileManager.default.createFile(
        atPath: url.path,
        contents: data,
        attributes: [.posixPermissions: permissions]))
    try FileManager.default.setAttributes(
      [.posixPermissions: permissions], ofItemAtPath: url.path)
  }

  private func makeCurrentFixture() throws -> (
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
          "identity:previous-serial-sha256=\(digest(hdcSerial))",
          "binding:previous-revision=1",
          "binding:previous-usb-topology=16777216",
          "identity:hdc-normal-alias-sha256=\(digest(hdcSerial))",
          "binding:hdc-normal-alias-usb-topology=16777216",
          "rebind:user-selection-sha256=\(String(repeating: "c", count: 64))",
        ]))
    return (targets, bindings, advanced, currentLoader)
  }

  private func makeSameLoaderLegacyFixture() throws -> (
    targets: RuntimeTargetStore,
    bindings: RockchipProductBindingStore,
    target: RuntimeTargetRecord,
    loader: RockchipProductUSBIdentity
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
    return (targets, bindings, advanced, loader)
  }

  private func loaderIdentity(serial: String, topology: String) -> RockchipProductUSBIdentity {
    RockchipProductUSBIdentity(
      serial: serial,
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipProbeEvidence.dayu200LoaderProductID,
      topology: topology)
  }

  private func hdcIdentity(serial: String, topology: String) -> RockchipProductUSBIdentity {
    RockchipProductUSBIdentity(
      serial: serial,
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
      topology: topology,
      productName: "HDC Device")
  }

  private func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private struct StaticReactivationProofSource: RockchipBindingReactivationProving {
  let proof: RockchipBindingReactivationProof?

  func proof(
    for target: RuntimeTargetRecord
  ) throws -> RockchipBindingReactivationProof? {
    proof
  }
}
