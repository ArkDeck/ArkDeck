import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// CHG-2026-053 TASK-UDR-001: the lowered argv is the real contract with the
/// device. Typed-action equality alone let a fake hidumper service name ship
/// while every suite stayed green, so these tests pin the exact token
/// sequence of the one device-validated UI dump form and the fail-closed
/// path of the form that has no honest lowering. The `-t <connectKey>`
/// sweep across all device-scoped actions lives in
/// DeviceProviderContractTests.testEveryDeviceScopedHDCPlanUsesDescriptorBoundTarget.
final class DeviceProviderArgvContractTests: XCTestCase {
  private struct FactsPort: HDCObservationFactsPort {
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "hdc", toolVersion: "3.2.0f",
        toolSHA256: String(repeating: "a", count: 64), serverFacts: [:],
        targetID: targetID, bindingRevision: 7,
        deviceIdentitySHA256:
          "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1",
        executionConnectKey: "150100424a544e4600",
        deviceMode: nil, buildFingerprint: nil,
        profileID: "openharmony-standard@1", collectedAtUTC: "2026-07-30T00:00:00Z")
    }
  }

  private let connectKey = "150100424a544e4600"
  private let provider = HDCObservationProviderAdapter(factsPort: FactsPort())

  private var context: ProviderExecutionContext {
    ProviderExecutionContext(
      jobID: "job-argv-1", stepID: "argv-test", targetID: "TGT-1",
      bindingRevision: 7, connectKey: connectKey,
      nowUTC: "2026-07-30T00:00:00Z")
  }

  // UDR-AC-1: the only window-family invocation with a device-validated
  // windowId-free form (CHG-2026-008 INV-1), token for token.
  func testWindowInventoryLowersToTheDeviceValidatedInventoryForm() throws {
    let plan = try provider.lower(
      action: .hdc(.captureUIDump(try HDCUIDumpRequest(scope: .windowList))),
      context: context)
    guard case .process(_, let arguments, let timeout) = plan.kind else {
      return XCTFail("expected a process plan")
    }
    XCTAssertEqual(
      arguments,
      ["-t", connectKey, "shell", "hidumper", "-s", "WindowManagerService", "-a", "-a"])
    XCTAssertEqual(timeout, 30)
  }

  /// The trace capture carries its own device-side readback: `hitrace` then
  /// `ls -l` on the file it was told to write. The readback must run even
  /// when hitrace reports non-zero, or a partial trace would be judged by
  /// the exit status the whole design refuses to trust.
  func testTraceCaptureLowersToCaptureThenListingReadback() throws {
    let path = try HDCOwnedRemotePath(
      jobID: "job-argv-1", stepID: "capture-trace", nonce: "n1")
    let plan = try provider.lower(
      action: .hdc(
        .captureTrace(
          try HDCTraceCaptureRequest(
            durationSeconds: 5, categories: ["ohos", "ability"], bufferKB: 8192),
          into: path)),
      context: context)
    guard case .processSequence(_, let invocations) = plan.kind else {
      return XCTFail("expected a capture + readback sequence")
    }
    XCTAssertEqual(
      invocations.map(\.arguments),
      [
        [
          "-t", connectKey, "shell", "hitrace", "-t", "5", "-b", "8192",
          "ohos", "ability", "-o", path.remotePath,
        ],
        ["-t", connectKey, "shell", "ls", "-l", path.remotePath],
      ])
    XCTAssertTrue(invocations[0].continueAfterNonZero)
    XCTAssertFalse(invocations[1].continueAfterNonZero)
  }

  func testCaptureUIDumpStepMapsToWindowInventoryAction() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    let step = try XCTUnwrap(descriptor.steps.first { $0.stepID == "capture-ui-dump" })
    XCTAssertEqual(
      step.actionReference,
      CatalogActionReference(catalogID: "arkdeck-diagnostics", actionID: "windowInventory"))
    let action = try provider.action(
      for: step, operation: descriptor, inputs: [:], context: context)
    guard case .hdc(.captureUIDump(let request)) = action else {
      return XCTFail("expected a UI dump action, got \(action)")
    }
    XCTAssertEqual(request.scope, .windowList)
  }

  // UDR-AC-2: componentTree's real forms are window-scoped and the published
  // contract carries no windowId, so both the action mapping and the
  // lowering refuse instead of inventing a command.
  func testComponentTreeActionRefIsRejectedBeforeAnyIntentExists() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    let synthetic = CatalogStepDescriptor(
      stepID: "capture-ui-dump", kind: .captureRemoteStdout, effect: .readOnly,
      cancellation: .immediate, binding: .confirmedDevice, isOptional: true,
      compensation: .none,
      actionReference: CatalogActionReference(
        catalogID: "arkdeck-diagnostics", actionID: "componentTree"))
    XCTAssertThrowsError(
      try provider.action(for: synthetic, operation: descriptor, inputs: [:], context: context)
    ) { error in
      XCTAssertTrue("\(error)".contains("windowId"), "unexpected reason: \(error)")
    }
  }

  func testComponentTreeScopeHasNoHonestLoweringAndFailsClosed() throws {
    XCTAssertThrowsError(
      try provider.lower(
        action: .hdc(.captureUIDump(try HDCUIDumpRequest(scope: .componentTree))),
        context: context)
    ) { error in
      XCTAssertTrue("\(error)".contains("windowId"), "unexpected reason: \(error)")
    }
  }

  // The refusal is permanent only for the stdout step shape. Naming the
  // file-producing dumpLayout route in the reason is what stops the next
  // reader from re-deriving it from hidumper flags (DEVICE-COMMAND-FACTS.md
  // §7); losing that pointer is a silent regression, so pin it.
  func testComponentTreeRefusalNamesTheFileProducingRoute() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    let synthetic = CatalogStepDescriptor(
      stepID: "capture-ui-dump", kind: .captureRemoteStdout, effect: .readOnly,
      cancellation: .immediate, binding: .confirmedDevice, isOptional: true,
      compensation: .none,
      actionReference: CatalogActionReference(
        catalogID: "arkdeck-diagnostics", actionID: "componentTree"))
    for refusal in [
      { _ = try self.provider.action(
        for: synthetic, operation: descriptor, inputs: [:], context: self.context) },
      { _ = try self.provider.lower(
        action: .hdc(.captureUIDump(try HDCUIDumpRequest(scope: .componentTree))),
        context: self.context) },
    ] as [() throws -> Void] {
      XCTAssertThrowsError(try refusal()) { error in
        let reason = "\(error)"
        XCTAssertTrue(
          reason.contains("dumpLayout"),
          "refusal must name the known route: \(reason)")
        XCTAssertTrue(
          reason.lowercased().contains("stdout"),
          "refusal must name the product-shape blocker: \(reason)")
      }
    }
  }
}
