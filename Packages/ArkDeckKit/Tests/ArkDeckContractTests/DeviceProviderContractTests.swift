import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckWorkflows

final class DeviceProviderContractTests: XCTestCase {
  private struct FactsPort: HDCObservationFactsPort {
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "hdc", toolVersion: "3.2.0f",
        toolSHA256: String(repeating: "a", count: 64),
        serverFacts: ["endpoint": "127.0.0.1:8710"],
        deviceIdentitySHA256: String(repeating: "b", count: 64),
        deviceMode: "hdc", buildFingerprint: "fixture-build",
        profileID: "openharmony-standard@1", collectedAtUTC: "2026-07-29T00:00:00Z")
    }
  }

  private struct FlashPort: RockchipFlashExecutionPort {
    func executeFlash(authorizationID: String) async throws -> (
      manifestID: String, succeeded: Bool, waitingForRecovery: Bool
    ) {
      ("manifest-1", true, false)
    }
  }

  private var hdc: HDCObservationProviderAdapter {
    HDCObservationProviderAdapter(factsPort: FactsPort())
  }

  private var context: ProviderExecutionContext {
    ProviderExecutionContext(
      jobID: "job-1", stepID: "step-1", targetID: "TGT-1", bindingRevision: 1,
      connectKey: "150100424a544e4600",
      expectedIdentitySHA256:
        "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1",
      toolVersion: "3.2.0f", toolSHA256: String(repeating: "a", count: 64),
      nowUTC: "2026-07-29T00:00:00Z")
  }

  func testRegistryHoldsBothProviders() {
    let registry = DeviceProviderRegistry(providers: [
      hdc, RockchipFlashProviderAdapter(executionPort: FlashPort()),
    ])
    XCTAssertEqual(registry.registeredProviderIDs, ["hdc", "rockchip"])
    XCTAssertNotNil(registry.provider(id: "hdc"))
    XCTAssertNotNil(registry.provider(id: "rockchip"))
    XCTAssertNil(registry.provider(id: "adb"))
  }

  func testHDCActionMappingIsClosedAndFailClosed() throws {
    let observe = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "observe.device@1"))
    let probeTool = observe.steps.first { $0.kind == .probeHostTool }!
    XCTAssertEqual(
      try hdc.action(for: probeTool, operation: observe, inputs: [:]), .hdc(.observeTool))
    let probeDevice = observe.steps.first { $0.kind == .probeDevice }!
    if case .hdc(.observeDevice) = try hdc.action(for: probeDevice, operation: observe, inputs: [:])
    {
    } else {
      XCTFail("probeDevice must map to observeDevice")
    }
    // T13 (CHG-2026-049) implemented the mutation family, so the failure
    // mode moved rather than disappeared: an install without its declared
    // inputs is still refused, never guessed at.
    let debug = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "debug.hap@1"))
    let install = debug.steps.first { $0.kind == .installPackage }!
    XCTAssertThrowsError(try hdc.action(for: install, operation: debug, inputs: [:])) { error in
      guard case DeviceProviderError.unsupportedAction(let detail) = error else {
        return XCTFail("expected unsupportedAction, got \(error)")
      }
      XCTAssertTrue(detail.contains("bundleName"), detail)
    }
    // A kind with no registered action at all still fails closed.
    let flash = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "flash.dayu200@1"))
    let flashStep = flash.steps.first { $0.kind == .flashPartition }!
    XCTAssertThrowsError(try hdc.action(for: flashStep, operation: flash, inputs: [:])) { error in
      guard case DeviceProviderError.unsupportedStepKind = error else {
        return XCTFail("expected unsupportedStepKind, got \(error)")
      }
    }
  }

  func testVerifyIsSemanticNeverExitCode() throws {
    // Exit 0 with unparseable stdout must NOT verify.
    let garbage = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data("something else entirely".utf8), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.1)
    let outcome = try hdc.verify(receipt: garbage, action: .hdc(.observeTool), context: context)
    guard case .unknown = outcome else {
      return XCTFail("exit 0 + garbage must be unknown, got \(outcome)")
    }
    // A parsed registered version verifies.
    let good = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data("Ver: 3.2.0f\n".utf8), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.1)
    guard case .verified(let summary) = try hdc.verify(
      receipt: good, action: .hdc(.observeTool), context: context)
    else {
      return XCTFail("registered version must verify")
    }
    XCTAssertEqual(summary["toolVersion"], "3.2.0f")
    // Unregistered version: unsupported, fail closed.
    let unknownVersion = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data("Ver: 9.9.9x\n".utf8), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.1)
    guard case .unsupported = try hdc.verify(
      receipt: unknownVersion, action: .hdc(.observeTool), context: context)
    else {
      return XCTFail("unregistered version must be unsupported")
    }
  }

  func testObserveServerUsesItsOwnShapeNotTheVersionShape() throws {
    // The `-v` output must NOT verify a server check: that conflation is
    // exactly what reached hardware and produced outcomeUnknown.
    let versionShape = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data("Ver: 3.2.0f\n".utf8), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.1)
    guard case .unknown = try hdc.verify(
      receipt: versionShape, action: .hdc(.observeServer), context: context)
    else {
      return XCTFail("the -v shape must not satisfy a server check")
    }
    let serverShape = ProviderProcessReceipt(
      exitStatus: 0,
      stdout: Data("Client version:Ver: 3.2.0f, server version:Ver: 3.2.0f\n".utf8),
      stderr: Data(), stdoutTruncated: false, durationSeconds: 0.1)
    guard case .verified(let summary) = try hdc.verify(
      receipt: serverShape, action: .hdc(.observeServer), context: context)
    else {
      return XCTFail("the real checkserver shape must verify")
    }
    XCTAssertEqual(summary["clientVersion"], "3.2.0f")
    XCTAssertEqual(summary["serverVersion"], "3.2.0f")

    // Client/server disagreement is a named failure, never success.
    let mismatch = ProviderProcessReceipt(
      exitStatus: 0,
      stdout: Data("Client version:Ver: 3.2.0f, server version:Ver: 3.2.0d\n".utf8),
      stderr: Data(), stdoutTruncated: false, durationSeconds: 0.1)
    guard case .failed(let code, _) = try hdc.verify(
      receipt: mismatch, action: .hdc(.observeServer), context: context)
    else {
      return XCTFail("a version mismatch must fail, not pass")
    }
    XCTAssertEqual(code, "serverVersionMismatch")
  }

  func testRockchipVerifyRequiresDurableRecordReference() throws {
    let rockchip = RockchipFlashProviderAdapter(executionPort: FlashPort())
    let action = TypedProviderAction.rockchip(.executeFlashPlan(authorizationID: "AUTH-1"))
    let withoutRecord = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(), stderr: Data(), stdoutTruncated: false, durationSeconds: 1)
    guard case .unknown = try rockchip.verify(
      receipt: withoutRecord, action: action, context: context)
    else {
      return XCTFail("flash without a durable manifest reference can never verify")
    }
    let withRecord = ProviderProcessReceipt(
      exitStatus: 0, stdout: Data(), stderr: Data(), stdoutTruncated: false, durationSeconds: 1,
      hostManagedRecordID: "manifest-1")
    guard case .verified(let summary) = try rockchip.verify(
      receipt: withRecord, action: action, context: context)
    else {
      return XCTFail("host-managed record must verify")
    }
    XCTAssertEqual(summary["manifestId"], "manifest-1")
  }

  func testReconcileSemantics() async throws {
    let reference = ProviderDurableIntentReference(
      jobID: "job-1", stepID: "s", intentEventID: "i", action: .hdc(.observeTool))
    let outcome = try await hdc.reconcile(intent: reference, context: context)
    XCTAssertEqual(outcome, .confirmedNotExecuted, "read-only re-observation is always safe")

    let rockchip = RockchipFlashProviderAdapter(executionPort: FlashPort())
    let flashIntent = ProviderDurableIntentReference(
      jobID: "job-1", stepID: "s", intentEventID: "i",
      action: .rockchip(.executeFlashPlan(authorizationID: "AUTH-1")))
    let flashOutcome = try await rockchip.reconcile(intent: flashIntent, context: context)
    guard case .stillUnknown = flashOutcome else {
      return XCTFail("destructive reconcile without host evidence must stay unknown")
    }
  }

  func testLoweredPlansCarryNoRawCommandSurface() throws {
    let plan = try hdc.lower(action: .hdc(.observeTool), context: context)
    guard case .process(_, let summary, let timeout) = plan.kind else {
      return XCTFail("observation lowers to a process plan")
    }
    XCTAssertEqual(summary, ["-v"])
    XCTAssertNotNil(timeout)
    // Mismatched provider/action pairs fail closed.
    XCTAssertThrowsError(
      try hdc.lower(
        action: .rockchip(.executeFlashPlan(authorizationID: "A")), context: context))
  }

  func testEvidencePropertyReadsUseExactDescriptorBoundTarget() throws {
    let model = try hdc.lower(
      action: .hdc(.queryProperty(.productModel)), context: context)
    let firmware = try hdc.lower(
      action: .hdc(.queryProperty(.fullBuildVersion)), context: context)
    guard case .process(_, let modelArgv, _) = model.kind,
      case .process(_, let firmwareArgv, _) = firmware.kind
    else {
      return XCTFail("property reads must lower to descriptor-bound process plans")
    }
    XCTAssertEqual(
      modelArgv,
      ["-t", "150100424a544e4600", "shell", "param", "get", "const.product.model"])
    XCTAssertEqual(
      firmwareArgv,
      ["-t", "150100424a544e4600", "shell", "param", "get", "const.ohos.fullname"])
    let missingTarget = ProviderExecutionContext(
      jobID: "job-1", stepID: "read-evidence-model", targetID: "TGT-1",
      bindingRevision: 1, nowUTC: "2026-07-29T00:00:00Z")
    XCTAssertThrowsError(
      try hdc.lower(action: .hdc(.queryProperty(.productModel)), context: missingTarget))
  }

  func testEveryDeviceScopedHDCPlanUsesDescriptorBoundTarget() throws {
    let artifactID = "ART-0123456789abcdef0123456789abcdef"
    let artifact = ProviderResolvedInputArtifact(
      artifactID: artifactID,
      fileURL: URL(fileURLWithPath: "/private/tmp/input.hap"),
      sha256: String(repeating: "c", count: 64),
      byteCount: 128)
    let boundContext = ProviderExecutionContext(
      jobID: "job-1", stepID: "device-step", targetID: "TGT-1",
      bindingRevision: 1, connectKey: "150100424a544e4600",
      expectedIdentitySHA256: String(repeating: "b", count: 64),
      toolVersion: "3.2.0f", toolSHA256: String(repeating: "a", count: 64),
      nowUTC: "2026-07-29T00:00:00Z", resolvedInputArtifact: artifact)
    let missingBinding = ProviderExecutionContext(
      jobID: "job-1", stepID: "device-step", targetID: "TGT-1",
      bindingRevision: 1, nowUTC: "2026-07-29T00:00:00Z",
      resolvedInputArtifact: artifact)
    let ownedPath = try hdc.mintOwnedRemotePath(jobID: "job-1", stepID: "device-step")
    let ownedArtifact = HDCOwnedRemoteArtifact(
      path: ownedPath, expectedSHA256: nil, maximumBytes: 1024)
    let staged = try hdc.mintStagedArtifact(
      jobID: "job-1", stepID: "send-hap",
      artifactLeaseID: "lease-v1:job-input:\(artifactID)",
      expectedSHA256: artifact.sha256)
    let bundle = try HDCBundleReference(bundleName: "com.example.demo")
    let ability = try HDCAbilityReference(bundle: bundle, abilityName: "EntryAbility")
    let port = try HDCPortForwardSpec(localPort: 2345, remotePort: 3456)
    let actions: [TypedProviderAction] = [
      .hdc(.queryProperty(.productModel)),
      .hdc(.observeStorage(try HDCStoragePreflightRequest(requiredBytes: 1024))),
      .hdc(.captureHilog(try HDCHilogCaptureRequest(durationSeconds: 1))),
      // windowList is the only scope with a published honest lowering
      // (CHG-2026-053); componentTree's fail-closed path is pinned in
      // DeviceProviderArgvContractTests.
      .hdc(.captureUIDump(try HDCUIDumpRequest(scope: .windowList))),
      .hdc(
        .captureTrace(
          try HDCTraceCaptureRequest(durationSeconds: 1, categories: ["ohos"]),
          into: ownedPath)),
      .hdc(.receiveOwnedArtifact(ownedArtifact)),
      .hdc(.cleanupOwnedRemotePath(ownedPath)),
      .hdc(.sendArtifactToStaging(staged)),
      .hdc(.installPackage(staged, bundle: bundle)),
      .hdc(.queryPackageReadback(bundle)),
      .hdc(.startAbility(ability)),
      .hdc(.verifyProcessState(bundle)),
      .hdc(.stopAbility(ability)),
      .hdc(.uninstallPackage(bundle)),
      .hdc(.createPortForward(port)),
      .hdc(.removePortForward(port)),
      .hdc(.readPackagePresence(bundle)),
      .hdc(.readProcessPresence(bundle)),
      .hdc(.readOwnedPathPresence(ownedPath)),
      .hdc(.readPortForwardPresence(port)),
    ]

    for action in actions {
      let plan = try hdc.lower(action: action, context: boundContext)
      guard case .process(_, let argv, _) = plan.kind else {
        return XCTFail("\(action) must lower to a process plan")
      }
      XCTAssertEqual(
        Array(argv.prefix(2)), ["-t", "150100424a544e4600"],
        "\(action) must not depend on HDC's default device")
      XCTAssertThrowsError(
        try hdc.lower(action: action, context: missingBinding),
        "\(action) must fail before process launch when no descriptor-bound connect key exists")
    }
  }

  func testExactTargetConfirmationRejectsZeroMultipleAndUnknownRows() throws {
    func receipt(_ rows: String) -> ProviderProcessReceipt {
      ProviderProcessReceipt(
        exitStatus: 0, stdout: Data(rows.utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.1)
    }
    let action = TypedProviderAction.hdc(.observeDevice(connectKey: "resolved-by-binding"))
    guard case .verified(let summary) = try hdc.verify(
      receipt: receipt("150100424a544e4600\t\tUSB\tConnected\tlocalhost\n"),
      action: action, context: context)
    else {
      return XCTFail("the one exact registered target row must verify")
    }
    XCTAssertEqual(summary["transport"], "usb")
    XCTAssertEqual(
      summary["deviceIdentitySHA256"],
      "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1")
    XCTAssertNil(summary["connectKeys"], "runtime target confirmation must not expose raw keys")

    guard case .failed(let zeroCode, _) = try hdc.verify(
      receipt: receipt("different\t\tUSB\tConnected\tlocalhost\n"),
      action: action, context: context)
    else { return XCTFail("zero exact matches must fail") }
    XCTAssertEqual(zeroCode, "targetConfirmationMismatch")

    let duplicate =
      "150100424a544e4600\t\tUSB\tConnected\tlocalhost\n"
      + "150100424a544e4600\t\tUSB\tConnected\tlocalhost\n"
    guard case .failed(let duplicateCode, _) = try hdc.verify(
      receipt: receipt(duplicate), action: action, context: context)
    else { return XCTFail("multiple exact matches must fail") }
    XCTAssertEqual(duplicateCode, "targetConfirmationMismatch")

    guard case .unknown = try hdc.verify(
      receipt: receipt("150100424a544e4600\t\tBLUETOOTH\tConnected\tlocalhost\n"),
      action: action, context: context)
    else { return XCTFail("an unregistered transport row must fail closed") }
  }
}

final class HDCCompatibilityProfileTests: XCTestCase {
  private let profile = HDCCompatibilityProfile.openHarmony320Family

  func testWhitespaceAndDiagnosticNoiseDoNotChangeParsing() {
    let clean = Data("Ver: 3.2.0f\n".utf8)
    let noisy = Data("[I] server starting\n\n   Ver: 3.2.0f   \n[W] something benign\n".utf8)
    let parsedClean = HDCObservationSemanticParser.parseClientVersion(
      stdout: clean, profile: profile, truncated: false)
    let parsedNoisy = HDCObservationSemanticParser.parseClientVersion(
      stdout: noisy, profile: profile, truncated: false)
    XCTAssertEqual(parsedClean, parsedNoisy)
    XCTAssertEqual(parsedClean, .parsed(HDCParsedClientVersion(version: "3.2.0f")))
  }

  func testBothRegisteredVersionsParse() {
    for version in ["3.2.0d", "3.2.0f"] {
      let outcome = HDCObservationSemanticParser.parseClientVersion(
        stdout: Data("Ver: \(version)\n".utf8), profile: profile, truncated: false)
      XCTAssertEqual(outcome, .parsed(HDCParsedClientVersion(version: version)))
    }
  }

  func testExplicitOutcomesForDegenerateInputs() {
    XCTAssertEqual(
      HDCObservationSemanticParser.parseClientVersion(
        stdout: Data("Ver: 1.0.0a\n".utf8), profile: profile, truncated: false),
      .unsupportedVersion("1.0.0a"))
    XCTAssertEqual(
      HDCObservationSemanticParser.parseClientVersion(
        stdout: Data(), profile: profile, truncated: false),
      .empty)
    XCTAssertEqual(
      HDCObservationSemanticParser.parseClientVersion(
        stdout: Data("Ver: 3.2.0f\n".utf8), profile: profile, truncated: true),
      .truncated)
    XCTAssertEqual(
      HDCObservationSemanticParser.parseClientVersion(
        stdout: Data([0xFF, 0xFE, 0x00]), profile: profile, truncated: false),
      .invalidEncoding)
    if case .malformed = HDCObservationSemanticParser.parseClientVersion(
      stdout: Data("Ver: 3.2.0f\nVer: 3.2.0d\n".utf8), profile: profile, truncated: false)
    {
    } else {
      XCTFail("two Ver: lines must be malformed")
    }
  }

  /// Regression for the first device window: `hdc checkserver` answers
  /// `Client version:Ver: X, server version:Ver: Y`, which the `-v` parser
  /// read as zero "Ver:" lines and turned into outcomeUnknown on real
  /// hardware. These are the exact shapes the fixture and the device emit.
  func testServerCheckParsing() {
    let healthy = HDCObservationSemanticParser.parseServerCheck(
      stdout: Data("Client version:Ver: 3.2.0f, server version:Ver: 3.2.0f\n".utf8),
      profile: profile, truncated: false)
    XCTAssertEqual(
      healthy,
      .parsed(HDCParsedServerCheck(clientVersion: "3.2.0f", serverVersion: "3.2.0f")))
    if case .parsed(let check) = healthy { XCTAssertTrue(check.versionsAgree) }

    // Both registered versions, and the disagreement the probe exists for.
    let mismatch = HDCObservationSemanticParser.parseServerCheck(
      stdout: Data("Client version:Ver: 3.2.0f, server version:Ver: 3.2.0d\n".utf8),
      profile: profile, truncated: false)
    guard case .parsed(let mismatched) = mismatch else {
      return XCTFail("a version disagreement still parses, then fails semantically")
    }
    XCTAssertFalse(mismatched.versionsAgree)

    // An unregistered version on either side is unsupported, not a pass.
    XCTAssertEqual(
      HDCObservationSemanticParser.parseServerCheck(
        stdout: Data("Client version:Ver: 3.2.0f, server version:Ver: 9.9.9z\n".utf8),
        profile: profile, truncated: false),
      .unsupportedVersion("9.9.9z"))

    // Degenerate shapes stay explicit.
    XCTAssertEqual(
      HDCObservationSemanticParser.parseServerCheck(
        stdout: Data(), profile: profile, truncated: false),
      .empty)
    XCTAssertEqual(
      HDCObservationSemanticParser.parseServerCheck(
        stdout: Data("Ver: 3.2.0f\n".utf8), profile: profile, truncated: false),
      .malformed(reason: "no client/server version line in checkserver output"))
    if case .malformed(let reason) = HDCObservationSemanticParser.parseServerCheck(
      stdout: Data("[Fail] Offline after transfer\n".utf8), profile: profile, truncated: false)
    {
      XCTAssertTrue(reason.contains("Offline"), "a device-side failure must be legible: \(reason)")
    } else {
      XCTFail("a [Fail] line must surface as a named malformed outcome")
    }
  }

  func testTargetListParsing() {
    XCTAssertEqual(
      HDCObservationSemanticParser.parseTargetList(
        stdout: Data("[Empty]\n".utf8), profile: profile, toolVersion: "3.2.0f",
        truncated: false),
      .parsed(HDCParsedTargetList(targets: [])))
    let listed = HDCObservationSemanticParser.parseTargetList(
      stdout: Data("150100424a544e4600\t\tUSB\tConnected\tlocalhost\n".utf8), profile: profile,
      toolVersion: "3.2.0f", truncated: false)
    guard case .parsed(let list) = listed, list.targets.count == 1 else {
      return XCTFail("one target line must parse, got \(listed)")
    }
    XCTAssertEqual(list.targets[0].state, "Connected")
    XCTAssertEqual(list.targets[0].transport, "usb")
    if case .malformed = HDCObservationSemanticParser.parseTargetList(
      stdout: Data("150100424a544e4600\tConnected\n".utf8), profile: profile,
      toolVersion: "3.2.0f", truncated: false)
    {
    } else {
      XCTFail("the legacy two-column guess must no longer parse")
    }
    XCTAssertEqual(
      HDCObservationSemanticParser.parseTargetList(
        stdout: Data("[Empty]\n".utf8), profile: profile, toolVersion: "9.9.9z",
        truncated: false),
      .unsupportedVersion("9.9.9z"))
  }
}
