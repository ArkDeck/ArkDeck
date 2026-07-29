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
    // A mutation kind has no HDC action in MU-2: fail closed, never guess.
    let debug = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "debug.hap@1"))
    let install = debug.steps.first { $0.kind == .installPackage }!
    XCTAssertThrowsError(try hdc.action(for: install, operation: debug, inputs: [:])) { error in
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
      stdout: Data("150100424a544e4600\tConnected\n".utf8), profile: profile,
      toolVersion: "3.2.0f", truncated: false)
    guard case .parsed(let list) = listed, list.targets.count == 1 else {
      return XCTFail("one target line must parse, got \(listed)")
    }
    XCTAssertEqual(list.targets[0].state, "Connected")
    XCTAssertEqual(
      HDCObservationSemanticParser.parseTargetList(
        stdout: Data("[Empty]\n".utf8), profile: profile, toolVersion: "9.9.9z",
        truncated: false),
      .unsupportedVersion("9.9.9z"))
  }
}
