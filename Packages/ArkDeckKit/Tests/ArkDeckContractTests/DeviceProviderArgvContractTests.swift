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

  func testComponentDetailLowersWindowAndComponentAsOneValidatedArgument() throws {
    let request = try HDCUIDumpRequest(
      scope: .componentDetail, windowID: "60", componentID: "841")
    let plan = try provider.lower(
      action: .hdc(.captureUIDump(request)), context: context)
    guard case .process(_, let arguments, let timeout) = plan.kind else {
      return XCTFail("expected a process plan")
    }
    XCTAssertEqual(
      arguments,
      [
        "-t", connectKey, "shell", "hidumper", "-s", "WindowManagerService", "-a",
        "-w 60 -element -lastpage 841",
      ])
    XCTAssertEqual(timeout, 30)
  }

  func testComponentDetailStepRequiresTypedIdentifiers() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    let step = try XCTUnwrap(
      descriptor.steps.first { $0.stepID == "capture-advanced-ui-dump" })
    let action = try provider.action(
      for: step, operation: descriptor,
      inputs: ["windowId": .string("60"), "componentId": .string("841")],
      context: context)
    XCTAssertEqual(
      action,
      .hdc(
        .captureUIDump(
          try HDCUIDumpRequest(
            scope: .componentDetail, windowID: "60", componentID: "841"))))
    XCTAssertThrowsError(
      try provider.action(
        for: step, operation: descriptor, inputs: ["windowId": .string("60")],
        context: context))
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
    guard
      case .hdc(.captureTrace(_, let tracePath)) = try provider.action(
        for: XCTUnwrap(descriptor.steps.first { $0.stepID == "capture-trace" }),
        operation: descriptor,
        inputs: ["traceCategories": .array([.string("ability")])], context: context)
    else {
      return XCTFail("trace action")
    }
    XCTAssertNotEqual(dumpPath.remotePath, tracePath.remotePath)
  }
}

// MARK: - CHG-2026-049 r4: multi-package install

extension DeviceProviderArgvContractTests {
  private func hapInputs(additional: [String] = []) -> [String: JSONValue] {
    var inputs: [String: JSONValue] = [
      "hapArtifactLease": .string("lease-v1:job-input:ART-aaaa"),
      "bundleName": .string("com.example.demo"),
      "abilityName": .string("EntryAbility"),
    ]
    if !additional.isEmpty {
      inputs["additionalHapArtifactLeases"] = .array(additional.map(JSONValue.string))
    }
    return inputs
  }

  private func hapContext(
    entry: ProviderResolvedInputArtifact, extras: [ProviderResolvedInputArtifact] = []
  ) -> ProviderExecutionContext {
    ProviderExecutionContext(
      jobID: "job-argv-1", stepID: "send-hap", targetID: "TGT-1",
      bindingRevision: 7, connectKey: connectKey, nowUTC: "2026-07-30T00:00:00Z",
      resolvedInputArtifact: entry, additionalInputArtifacts: extras)
  }

  private func artifact(_ id: String, _ path: String) -> ProviderResolvedInputArtifact {
    ProviderResolvedInputArtifact(
      artifactID: id, fileURL: URL(filePath: path),
      sha256: String(repeating: id.last.map(String.init) ?? "a", count: 64), byteCount: 128)
  }

  /// DHA-MULTI-001: without additional leases nothing about the single
  /// package plan moves. This is the promise r4 makes to existing callers.
  func testSinglePackageArgvIsUnchangedWithoutAdditionalLeases() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "debug.hap@1"))
    let entry = artifact("ART-aaaa", "/private/tmp/entry.hap")
    let context = hapContext(entry: entry)
    func plan(_ stepID: String) throws -> TypedProcessPlan {
      let step = try XCTUnwrap(descriptor.steps.first { $0.stepID == stepID })
      let action = try provider.action(
        for: step, operation: descriptor, inputs: hapInputs(), context: context)
      return try provider.lower(action: action, context: context)
    }
    guard case .process(_, let send, _) = try plan("send-hap").kind,
      case .process(_, let install, _) = try plan("install-hap").kind,
      case .process(_, let cleanup, _) = try plan("cleanup-remote-staging").kind
    else {
      return XCTFail("the single-package legs must stay single-process plans")
    }
    let owned = "/data/local/tmp/arkdeck-job-argv-1-send-hap-owned.hap"
    XCTAssertEqual(send, ["-t", connectKey, "file", "send", "/private/tmp/entry.hap", owned])
    XCTAssertEqual(
      install, ["-t", connectKey, "shell", "bm", "install", "-p", owned, "-r"])
    XCTAssertEqual(cleanup, ["-t", connectKey, "shell", "rm", "-f", owned])
  }

  /// DHA-MULTI-001: with them, one directory carries every package and one
  /// install covers the set. Cleanup removes each package by name and then
  /// `rmdir`s — never `rm -rf`.
  func testMultiPackageLowersToOneDirectoryAndOneInstall() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "debug.hap@1"))
    let entry = artifact("ART-aaaa", "/private/tmp/entry.hap")
    let feature = artifact("ART-bbbb", "/private/tmp/feature1.hap")
    let context = hapContext(entry: entry, extras: [feature])
    let inputs = hapInputs(additional: ["lease-v1:job-input:ART-bbbb"])
    func plan(_ stepID: String) throws -> TypedProcessPlan {
      let step = try XCTUnwrap(descriptor.steps.first { $0.stepID == stepID })
      let action = try provider.action(
        for: step, operation: descriptor, inputs: inputs, context: context)
      return try provider.lower(action: action, context: context)
    }
    let dir = "/data/local/tmp/arkdeck-job-argv-1-send-hap-owned-packages"

    guard case .processSequence(_, let send) = try plan("send-hap").kind else {
      return XCTFail("multi-package send must be a sequence")
    }
    XCTAssertEqual(
      send.map(\.arguments),
      [
        ["-t", connectKey, "shell", "mkdir", "-p", dir],
        ["-t", connectKey, "file", "send", "/private/tmp/entry.hap", "\(dir)/ART-aaaa.hap"],
        ["-t", connectKey, "file", "send", "/private/tmp/feature1.hap", "\(dir)/ART-bbbb.hap"],
      ])

    guard case .process(_, let install, _) = try plan("install-hap").kind else {
      return XCTFail("install must stay a single process")
    }
    XCTAssertEqual(install, ["-t", connectKey, "shell", "bm", "install", "-p", dir, "-r"])

    guard case .processSequence(_, let cleanup) = try plan("cleanup-remote-staging").kind else {
      return XCTFail("multi-package cleanup must be a sequence")
    }
    XCTAssertEqual(
      cleanup.map(\.arguments),
      [
        ["-t", connectKey, "shell", "rm", "-f", "\(dir)/ART-aaaa.hap"],
        ["-t", connectKey, "shell", "rm", "-f", "\(dir)/ART-bbbb.hap"],
        ["-t", connectKey, "shell", "rmdir", dir],
        ["-t", connectKey, "shell", "ls", "-ld", dir],
      ])
    for invocation in cleanup {
      XCTAssertFalse(
        invocation.arguments.contains("-rf"),
        "cleanup must never recurse: \(invocation.arguments)")
    }
  }

  /// A staged package's remote name comes from the artifact ID, so a lease
  /// string cannot contribute a path component.
  func testStagedPackagePathsRejectCallerShapedNames() throws {
    let directory = try HDCOwnedRemoteDirectory(
      jobID: "job-argv-1", stepID: "send-hap", nonce: "owned")
    XCTAssertThrowsError(
      try HDCStagedPackage(
        directory: directory, artifactID: "../../etc/passwd",
        artifactLeaseID: "lease-v1:x:y", expectedSHA256: String(repeating: "a", count: 64)))
    let good = try HDCStagedPackage(
      directory: directory, artifactID: "ART-aaaa",
      artifactLeaseID: "lease-v1:x:y", expectedSHA256: String(repeating: "a", count: 64))
    XCTAssertTrue(good.remotePath.hasPrefix(directory.remotePath + "/"))
  }
}

// MARK: - CHG-2026-049 r5: screenshot

extension DeviceProviderArgvContractTests {
  /// DHA-SHOT-001: `-t png` is mandatory and the `.png` suffix is
  /// load-bearing. Measured on OH 3.2: this build defaults to jpeg and
  /// rejects `-f <x>.png` outright unless the type is requested.
  func testScreenshotLowersToTheTypedPNGFormAndItsReadback() throws {
    let path = try HDCOwnedRemotePath(
      jobID: "job-argv-1", stepID: "capture-screenshot", nonce: "n1")
    XCTAssertTrue(path.remotePath.hasSuffix(".png"), "the device validates the suffix")
    let plan = try provider.lower(
      action: .hdc(.captureScreenshot(into: path)), context: context)
    guard case .processSequence(_, let invocations) = plan.kind else {
      return XCTFail("expected a capture + readback sequence")
    }
    XCTAssertEqual(
      invocations.map(\.arguments),
      [
        ["-t", connectKey, "shell", "snapshot_display", "-t", "png", "-f", path.remotePath],
        ["-t", connectKey, "shell", "ls", "-l", path.remotePath],
      ])
    XCTAssertTrue(invocations[0].continueAfterNonZero)
  }

  /// The receive leg for a screenshot carries the PNG magic; the other file
  /// legs carry none, because their formats have nothing cheap to check.
  func testOnlyTheScreenshotReceivePinsAMagic() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    func receiveAction(_ stepID: String, inputs: [String: JSONValue]) throws
      -> HDCOwnedRemoteArtifact
    {
      let step = try XCTUnwrap(descriptor.steps.first { $0.stepID == stepID })
      let action = try provider.action(
        for: step, operation: descriptor, inputs: inputs, context: context)
      guard case .hdc(.receiveOwnedArtifact(let artifact)) = action else {
        // A descriptor drifting away from a receive action is a catalog
        // defect, never a reason to skip the assertion.
        XCTFail("expected a receive action for \(stepID), got \(action)")
        struct UnexpectedProviderAction: Error {}
        throw UnexpectedProviderAction()
      }
      return artifact
    }
    let shot = try receiveAction("receive-screenshot", inputs: ["uiScreenshot": .bool(true)])
    XCTAssertEqual(shot.expectedLeadingBytes, HDCFileMagic.png)
    XCTAssertTrue(shot.path.remotePath.hasSuffix(".png"))

    let tree = try receiveAction("receive-ui-tree", inputs: ["uiComponentTree": .bool(true)])
    XCTAssertNil(tree.expectedLeadingBytes)
  }

  /// DHA-SHOT-003 (contract half): the magic decides, and a file that is
  /// not a PNG fails rather than publishing.
  func testReceivedScreenshotMustBeginWithThePNGMagic() throws {
    let path = try HDCOwnedRemotePath(
      jobID: "job-argv-1", stepID: "capture-screenshot", nonce: "n1")
    let artifact = HDCOwnedRemoteArtifact(
      path: path, expectedSHA256: nil, maximumBytes: 64 * 1024 * 1024,
      expectedLeadingBytes: HDCFileMagic.png)
    func verdict(leading: Data) throws -> ProviderSemanticOutcome {
      try provider.verify(
        receipt: ProviderProcessReceipt(
          exitStatus: 0, stdout: Data("FileTransfer finish".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01,
          landedArtifact: ProviderLandedArtifact(
            localURL: URL(filePath: "/private/tmp/shot.png"),
            byteCount: 1024, sha256: String(repeating: "a", count: 64),
            leadingBytes: leading)),
        action: .hdc(.receiveOwnedArtifact(artifact)), context: context)
    }
    guard case .verified = try verdict(leading: HDCFileMagic.png) else {
      return XCTFail("a real PNG must verify")
    }
    // An HTML error page, a JPEG, a truncated write: all the same answer.
    for wrong in [Data("<html".utf8), Data([0xFF, 0xD8, 0xFF, 0xE0]), Data([0x89, 0x50])] {
      guard case .failed(let code, _) = try verdict(leading: wrong) else {
        return XCTFail("bytes that are not a PNG must fail")
      }
      XCTAssertEqual(code, "unexpectedFormat")
    }
  }
}

// MARK: - CHG-2026-049 r6: crash ledger

extension DeviceProviderArgvContractTests {
  /// DHA-CRASH-001: both invocations, token for token. The `-p …` payload
  /// is one argv element after `-a`, which is what §6 records and what the
  /// device parses.
  func testCrashLedgerLowersToTheTwoFaultloggerForms() throws {
    guard
      case .process(_, let index, _) = try provider.lower(
        action: .hdc(.captureCrashIndex(byteBudget: 8 * 1024 * 1024)), context: context
      ).kind
    else {
      return XCTFail("expected a process plan")
    }
    XCTAssertEqual(
      index,
      ["-t", connectKey, "shell", "hidumper", "-s", "1201", "-a", "-p Faultlogger -l"])

    let name = try HDCFaultLogName("jscrash-com.example.demo-20010056-20260731161809")
    guard
      case .process(_, let entry, _) = try provider.lower(
        action: .hdc(.captureCrashLog(name, byteBudget: 8 * 1024 * 1024)), context: context
      ).kind
    else {
      return XCTFail("expected a process plan")
    }
    XCTAssertEqual(
      entry,
      [
        "-t", connectKey, "shell", "hidumper", "-s", "1201", "-a",
        "-p Faultlogger -f jscrash-com.example.demo-20010056-20260731161809",
      ])
  }

  /// DHA-CRASH-001: this is the only collection leg that never leaves
  /// readOnly, because both commands only read.
  func testCrashLedgerStaysReadOnly() throws {
    XCTAssertEqual(
      TypedProviderAction.hdc(.captureCrashIndex(byteBudget: 1024)).effect, .readOnly)
    let name = try HDCFaultLogName("cppcrash-com.example.demo-20010056-20260731161809")
    XCTAssertEqual(
      TypedProviderAction.hdc(.captureCrashLog(name, byteBudget: 1024)).effect, .readOnly)
  }

  /// DHA-CRASH-002: the one caller-supplied string in this family can only
  /// ever be an entry name.
  func testFaultLogNameRejectsAnythingPathShaped() throws {
    for bad in [
      "../../etc/passwd", "jscrash-a/b", "/data/log/faultlog/x", "no separator",
      "", "jscrash-" + String(repeating: "a", count: 200), "JSCRASH-upper",
    ] {
      XCTAssertThrowsError(try HDCFaultLogName(bad), "must reject \(bad.prefix(24))")
    }
    // The exact shape measured on the device.
    XCTAssertNoThrow(
      try HDCFaultLogName("jscrash-com.example.waterflowdemo-20010056-20260731161809"))
    XCTAssertNoThrow(
      try HDCFaultLogName("cppcrash-com.example.waterflowdemo-20010056-20260731161809014.log"))
    // Faultlogger holds more than crashes; the shape must not exclude them.
    XCTAssertNoThrow(
      try HDCFaultLogName("appfreeze-com.example.waterflowdemo-20010056-20260731161809"))
  }

  /// DHA-CRASH-003 (parser half): the index's entries sit between the two
  /// marker lines, and an empty ledger yields none.
  func testFaultLogIndexParsesEntriesBetweenTheMarkers() {
    let populated = """

      -------------------------------[ability]-------------------------------

      ----------------------------------HiviewService----------------------------------
      Fault log list:
      ******
      jscrash-com.example.waterflowdemo-20010056-20260731161809
      ******
      """
    XCTAssertEqual(
      HDCObservationProviderAdapter.faultLogEntries(in: populated),
      ["jscrash-com.example.waterflowdemo-20010056-20260731161809"])

    let empty = """
      No fault log exist.
      Fault log list:
      ******
      ******
      """
    XCTAssertTrue(HDCObservationProviderAdapter.faultLogEntries(in: empty).isEmpty)
  }
}
