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

  /// The lowering invents no trace category. `ohos` used to stand in as the
  /// default and the 2026-07-31 device window found it absent from `hitrace
  /// --list_categories` on OH 3.2 — a default that could only produce a
  /// command the device rejects. No categories is now a refusal.
  func testTraceLoweringRefusesRatherThanInventingACategory() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    let step = try XCTUnwrap(descriptor.steps.first { $0.stepID == "capture-trace" })
    for inputs in [[:], ["traceCategories": JSONValue.array([])]] as [[String: JSONValue]] {
      XCTAssertThrowsError(
        try provider.action(
          for: step, operation: descriptor, inputs: inputs, context: context),
        "empty categories must refuse, not fall back to an invented tag")
    }
    XCTAssertNoThrow(
      try provider.action(
        for: step, operation: descriptor,
        inputs: ["traceCategories": .array([.string("ability")])], context: context))
  }

  /// Stop and uninstall carry the readback that decides them, using the same
  /// probes the reconcile path uses. The mutation leg must continue after a
  /// non-zero exit or the readback would never run for the exact case D2 was
  /// filed for.
  func testStopAndUninstallLowerToMutationThenPresenceReadback() throws {
    let bundle = try HDCBundleReference(bundleName: "com.example.demo")
    let ability = try HDCAbilityReference(bundle: bundle, abilityName: "EntryAbility")

    let stop = try provider.lower(action: .hdc(.stopAbility(ability)), context: context)
    guard case .processSequence(_, let stopLegs) = stop.kind else {
      return XCTFail("stop must lower to a mutation + readback sequence")
    }
    XCTAssertEqual(
      stopLegs.map(\.arguments),
      [
        ["-t", connectKey, "shell", "aa", "force-stop", "com.example.demo"],
        ["-t", connectKey, "shell", "pidof", "com.example.demo"],
      ])
    XCTAssertTrue(stopLegs[0].continueAfterNonZero)

    let uninstall = try provider.lower(
      action: .hdc(.uninstallPackage(bundle)), context: context)
    guard case .processSequence(_, let uninstallLegs) = uninstall.kind else {
      return XCTFail("uninstall must lower to a mutation + readback sequence")
    }
    XCTAssertEqual(
      uninstallLegs.map(\.arguments),
      [
        ["-t", connectKey, "uninstall", "com.example.demo"],
        ["-t", connectKey, "shell", "bm", "dump", "-n", "com.example.demo"],
      ])
    XCTAssertTrue(uninstallLegs[0].continueAfterNonZero)
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

  // UDR-AC-5 (r2): the stdout action stays refused — a captureRemoteStdout
  // step cannot carry a file product no matter which flags it gets — and the
  // refusal must now point at the route that does work, or the next reader
  // re-derives it from hidumper flags all over again.
  func testComponentTreeStdoutActionStaysRefusedAndNamesTheRealRoute() throws {
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
      let reason = "\(error)"
      XCTAssertTrue(reason.contains("uiComponentTree"), "must name the input: \(reason)")
      XCTAssertTrue(reason.contains("capture-ui-tree"), "must name the steps: \(reason)")
      XCTAssertFalse(
        reason.contains("windowId"),
        "r1's reason was wrong and must not come back: \(reason)")
    }
  }

  /// UDR-AC-5: the exact form measured on DAYU200 (OH 3.2, 2026-07-31) —
  /// no `-w`, no `-d`, and a provider-owned remote path the caller cannot
  /// supply. The `ls -l` readback follows because `DumpLayout saved to:` is
  /// a status line from a device mutation, not evidence of the file.
  func testComponentTreeLowersToTheWindowIdFreeDumpLayoutForm() throws {
    let path = try HDCOwnedRemotePath(
      jobID: "job-argv-1", stepID: "capture-ui-tree", nonce: "n1")
    let plan = try provider.lower(
      action: .hdc(.captureComponentTree(into: path)), context: context)
    guard case .processSequence(_, let invocations) = plan.kind else {
      return XCTFail("expected a dump + readback sequence")
    }
    XCTAssertEqual(
      invocations.map(\.arguments),
      [
        ["-t", connectKey, "shell", "uitest", "dumpLayout", "-p", path.remotePath],
        ["-t", connectKey, "shell", "ls", "-l", path.remotePath],
      ])
    XCTAssertTrue(path.remotePath.hasSuffix(".json"))
    XCTAssertTrue(invocations[0].continueAfterNonZero)
  }

  /// The three file steps must all resolve to the *same* owned remote path:
  /// the dump writes it, the receive reads it, the cleanup removes it.
  func testComponentTreeStepsShareOneOwnedRemotePath() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    let inputs: [String: JSONValue] = ["uiComponentTree": .bool(true)]
    func action(_ stepID: String) throws -> TypedProviderAction {
      try provider.action(
        for: XCTUnwrap(descriptor.steps.first { $0.stepID == stepID }),
        operation: descriptor, inputs: inputs, context: context)
    }
    guard case .hdc(.captureComponentTree(let dumpPath)) = try action("capture-ui-tree"),
      case .hdc(.receiveOwnedArtifact(let received)) = try action("receive-ui-tree"),
      case .hdc(.cleanupOwnedRemotePath(let cleanupPath)) = try action("cleanup-ui-tree-temp")
    else {
      return XCTFail("the ui-tree steps must keep their typed path payloads")
    }
    XCTAssertEqual(dumpPath, received.path)
    XCTAssertEqual(dumpPath, cleanupPath)

    // And they must not collide with the trace leg's path in the same job.
    guard case .hdc(.captureTrace(_, let tracePath)) = try provider.action(
      for: XCTUnwrap(descriptor.steps.first { $0.stepID == "capture-trace" }),
      operation: descriptor,
      inputs: ["traceCategories": .array([.string("ability")])], context: context)
    else {
      return XCTFail("trace action")
    }
    XCTAssertNotEqual(dumpPath.remotePath, tracePath.remotePath)
  }
}
