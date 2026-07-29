import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// T12 + T13: capture.diagnostics@1 partial-success honesty and
/// debug.hap@1 readback-only success judgement.
final class DiagnosticsAndHAPContractTests: XCTestCase {
  private var stateDirectory: URL!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-mu4-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  override func tearDownWithError() throws {
    if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
  }

  private struct FactsPort: HDCObservationFactsPort {
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "hdc", toolVersion: "3.2.0f",
        toolSHA256: String(repeating: "a", count: 64), serverFacts: [:],
        deviceIdentitySHA256: nil, deviceMode: nil, buildFingerprint: nil,
        profileID: "openharmony-standard@1", collectedAtUTC: "2026-07-29T00:00:00Z")
    }
  }

  /// Scriptable dispatcher: each action family can be told to succeed, to
  /// fail, or - the case that matters most - to exit cleanly while the
  /// readback shows nothing happened.
  private final class ScriptedDispatcher: RuntimeProcessDispatching, @unchecked Sendable {
    struct Script: Sendable {
      var traceFails = false
      var packageInstalled = true
      var processRunning = true
      var hilogEmpty = false
    }

    let script: Script
    private let lock = NSLock()
    private(set) var dispatchedActions: [String] = []

    init(script: Script = Script()) {
      self.script = script
    }

    private func note(_ label: String) {
      lock.withLock { dispatchedActions.append(label) }
    }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      func receipt(_ stdout: String, exit: Int32 = 0) -> ProviderProcessReceipt {
        ProviderProcessReceipt(
          exitStatus: exit, stdout: Data(stdout.utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      }
      guard case .hdc(let action) = plan.action else {
        throw RuntimeDispatchFailure.failed("unexpected provider")
      }
      switch action {
      case .observeTool:
        note("observeTool")
        return receipt("Ver: 3.2.0f\n")
      case .observeServer:
        note("observeServer")
        return receipt("Client version:Ver: 3.2.0f, server version:Ver: 3.2.0f\n")
      case .observeDevice, .listDeviceCandidates:
        note("observeDevice")
        return receipt("150100424a544e4600\t\tUSB\tConnected\tlocalhost\n")
      case .captureHilog:
        note("captureHilog")
        return receipt(script.hilogEmpty ? "" : "01-01 00:00:00 I app: hello\n")
      case .captureUIDump:
        note("captureUIDump")
        return receipt("{\"windows\":[]}\n")
      case .captureTrace:
        note("captureTrace")
        if script.traceFails {
          throw RuntimeDispatchFailure.failed("trace category unsupported on this build")
        }
        return receipt("")
      case .receiveOwnedArtifact:
        note("receiveArtifact")
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data("trace-bytes".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01, hostManagedRecordID: "local-trace")
      case .cleanupOwnedRemotePath:
        note("cleanup")
        return receipt("")
      case .sendArtifactToStaging:
        note("sendArtifact")
        return receipt("FileTransfer finish")
      case .installPackage:
        note("installPackage")
        // Clean exit either way: the readback is what decides.
        return receipt("install bundle successfully")
      case .queryPackageReadback(let bundle):
        note("packageReadback")
        return receipt(script.packageInstalled ? "bundleName: \(bundle.bundleName)\n" : "")
      case .startAbility:
        note("startAbility")
        return receipt("start ability successfully")
      case .verifyProcessState:
        note("processReadback")
        return receipt(script.processRunning ? "3421\n" : "")
      case .stopAbility:
        note("stopAbility")
        return receipt("")
      case .uninstallPackage:
        note("uninstallPackage")
        return receipt("")
      case .queryProperty:
        note("queryProperty")
        return receipt("DAYU200\n")
      case .createPortForward, .removePortForward:
        note("portForward")
        return receipt("")
      }
    }
  }

  private func makeEngine(
    dispatcher: ScriptedDispatcher
  ) throws -> (RuntimeJobEngine, RuntimeCapabilityStore, RuntimeArtifactStore) {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appendingPathComponent("capabilities", isDirectory: true))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appendingPathComponent("artifacts", isDirectory: true),
      nowUTC: { "2026-07-29T00:00:00Z" })
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: stateDirectory),
      providers: DeviceProviderRegistry(providers: [
        HDCObservationProviderAdapter(factsPort: FactsPort())
      ]),
      dispatcher: dispatcher,
      capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      nowUTC: { "2026-07-29T00:00:00Z" })
    return (engine, capabilityStore, artifactStore)
  }

  private func captureRequest(
    withTrace: Bool, key: String = "idem-capture-01", capability: String? = nil
  ) -> Data {
    let trace = withTrace ? "\"traceCategories\": [\"ohos\"]," : ""
    let auth = capability.map { "\"authorization\": { \"capabilityId\": \"\($0)\" }," } ?? ""
    return Data(
      """
      {
        "documentType": "runtime-operation-request",
        "schemaVersion": "2.0.0",
        "requestId": "req-capture",
        "idempotencyKey": "\(key)",
        "target": { "targetId": "TGT-1" },
        "operation": { "id": "capture.diagnostics", "version": 1 },
        \(auth)
        "inputs": { \(trace) "durationSeconds": 5 }
      }
      """.utf8)
  }

  private func hapRequest(key: String = "idem-hap-01", capability: String? = "CAP-RT-HAP-001")
    -> Data
  {
    let auth = capability.map { "\"authorization\": { \"capabilityId\": \"\($0)\" }," } ?? ""
    return Data(
      """
      {
        "documentType": "runtime-operation-request",
        "schemaVersion": "2.0.0",
        "requestId": "req-hap",
        "idempotencyKey": "\(key)",
        "target": { "targetId": "TGT-1" },
        "operation": { "id": "debug.hap", "version": 1 },
        \(auth)
        "inputs": {
          "hapArtifactLease": "lease-1",
          "bundleName": "com.example.demo",
          "abilityName": "EntryAbility"
        }
      }
      """.utf8)
  }

  private func installE1Capability(_ store: RuntimeCapabilityStore) async throws {
    try await store.install(
      try RuntimeCapability(
        capabilityID: "CAP-RT-HAP-001",
        targetScope: .anyTarget,
        operationScope: [.init(operationID: "debug.hap", version: 1)],
        effectCeiling: .deviceMutation,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-12-31T00:00:00Z",
        maximumUses: 5,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#test")))
  }

  // MARK: - DHA-CAP-001

  func testCaptureWithoutTraceRecordsTheTraceAsMissingNotAsSuccess() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(captureRequest(withTrace: false))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded")
    XCTAssertFalse(dispatcher.dispatchedActions.contains("captureTrace"))

    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    let byName = Dictionary(uniqueKeysWithValues: recorded.map { ($0.name, $0) })
    XCTAssertEqual(byName["hilog.txt"]?.status, .published)
    // The absent trace is present in the index WITH a reason: this is the
    // whole point - a partial capture cannot look complete.
    guard case .missing(let reason)? = byName["trace.htrace"]?.status else {
      return XCTFail("the trace must be recorded as missing, got \(String(describing: byName["trace.htrace"]))")
    }
    XCTAssertFalse(reason.isEmpty)

    // And the summary says so in one place a caller can read.
    let summaryID = try XCTUnwrap(byName["capture-summary.json"]?.artifactID)
    let summaryText = String(
      data: try await artifacts.read(jobID: acceptance.jobID, artifactID: summaryID),
      encoding: .utf8) ?? ""
    XCTAssertTrue(summaryText.contains("trace.htrace"), summaryText)
    XCTAssertTrue(summaryText.contains("missing"), summaryText)
    // trace.htrace is an optional product, so overall completeness holds.
    XCTAssertTrue(summaryText.contains("\"completeness\" : \"complete\""), summaryText)
  }

  func testFailingOptionalTraceDegradesInsteadOfFailingTheJob() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(traceFails: true))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    // Selecting the remote-file trace makes this plan mutate the device,
    // so it needs an E1 capability - see the escalation test below.
    try await installCaptureCapability(capabilities)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: true, capability: "CAP-RT-CAPTURE-001"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(status.timeline.contains { $0.hasPrefix("skipped capture-trace") })

    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    let trace = recorded.first { $0.name == "trace.htrace" }
    guard case .missing(let reason)? = trace?.status else {
      return XCTFail(
        "a failed optional capture must be recorded as missing; index: "
          + recorded.map { "\($0.name)=\($0.status)" }.joined(separator: ", ")
          + " | timeline: " + status.timeline.joined(separator: " | "))
    }
    XCTAssertTrue(reason.contains("unsupported"), reason)
    // The required products still published.
    XCTAssertEqual(recorded.first { $0.name == "hilog.txt" }?.status, .published)
  }

  func testRequiredCaptureFailureFailsTheJob() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(hilogEmpty: true))
    let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(captureRequest(withTrace: false))
    let status = try await engine.run(jobID: acceptance.jobID)
    // hilog is required; an empty capture is unknown, which halts.
    XCTAssertNotEqual(status.state, "succeeded")
    XCTAssertTrue(status.outcomeUnknown || status.state == "failed", status.state)
  }

  /// The defect maintainer review caught: charging the operation's minimum
  /// effect would have let a device-mutating plan through on the default
  /// read-only policy. Selecting the remote trace must demand E1.
  func testCaptureWithRemoteTraceRequiresE1AndDispatchesNothingWithout() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
    do {
      _ = try await engine.submit(captureRequest(withTrace: true, key: "idem-trace-nocap"))
      XCTFail("a trace-selecting capture mutates the device and must require a capability")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(.authorizationRequired, let message) = error else {
        return XCTFail("expected authorizationRequired, got \(error)")
      }
      XCTAssertTrue(message.contains("deviceMutation"), message)
    }
    XCTAssertTrue(dispatcher.dispatchedActions.isEmpty, "zero dispatch on refusal")
  }

  /// ...while the same operation without the trace stays E0 and needs no
  /// capability at all. The pair is what makes the rule meaningful.
  func testCaptureWithoutTraceStaysE0AndNeedsNoCapability() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-trace-e0"))
    XCTAssertFalse(acceptance.deduplicated)
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded")
  }

  private func installCaptureCapability(_ store: RuntimeCapabilityStore) async throws {
    try await store.install(
      try RuntimeCapability(
        capabilityID: "CAP-RT-CAPTURE-001",
        targetScope: .anyTarget,
        operationScope: [.init(operationID: "capture.diagnostics", version: 1)],
        effectCeiling: .deviceMutation,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-12-31T00:00:00Z",
        maximumUses: 5,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#test")))
  }

  /// Regression for the blocker maintainer review raised: an earlier
  /// version of the journal argument table labelled the HiLog step with a
  /// UI-dump action because that was the only thing the old schema
  /// allowed. The durable intent would then have recorded an action the
  /// step never performed - fabricated evidence, not a naming slip. The
  /// identity must come from the catalog's own actionRef.
  func testJournalIntentRecordsTheCatalogsOwnActionIdentity() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-identity-01"))
    _ = try await engine.run(jobID: acceptance.jobID)

    let journalURL = stateDirectory
      .appendingPathComponent("jobs/\(acceptance.jobID)/journal.jsonl")
    let journal = try String(contentsOf: journalURL, encoding: .utf8)

    // The HiLog step must carry the diagnostics action, and no step may
    // carry a UI-dump action it does not have.
    XCTAssertTrue(journal.contains("\"boundedHilog\""), "HiLog intent must name its own action")
    XCTAssertTrue(journal.contains("\"arkdeck-diagnostics\""))
    XCTAssertFalse(
      journal.contains("\"nodeSummary\""),
      "no step may borrow a UI-dump action id: \(journal.prefix(400))")

    // And the catalog is where that identity comes from.
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    let hilog = try XCTUnwrap(descriptor.steps.first { $0.stepID == "capture-hilog" })
    XCTAssertEqual(hilog.actionReference?.actionID, "boundedHilog")
    XCTAssertEqual(hilog.actionReference?.catalogID, "arkdeck-diagnostics")
  }

  /// A stdout-capturing step with no declared action must stop the run
  /// rather than have one invented for its durable intent.
  func testStdoutStepWithoutADeclaredActionIsRefused() throws {
    let undeclared = CatalogStepDescriptor(
      stepID: "capture-mystery", kind: .captureRemoteStdout, effect: .readOnly,
      cancellation: .immediate, binding: .confirmedDevice, isOptional: false,
      compensation: .none, actionReference: nil)
    XCTAssertThrowsError(
      try RuntimeJobEngine.journalStep(for: undeclared, jobID: "job-1", inputs: [:])
    ) { error in
      guard case RuntimeJobEngineError.internalFailure(let detail) = error else {
        return XCTFail("expected internalFailure, got \(error)")
      }
      XCTAssertTrue(detail.contains("refusing to invent"), detail)
    }
  }

  // MARK: - DHA-HAP-001

  func testHAPSuccessRequiresBothReadbacks() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(hapRequest())
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("packageReadback"))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("processReadback"))
    // The mutating steps are recorded as dispatched-awaiting-readback,
    // never as verified on their own.
    XCTAssertTrue(status.timeline.contains { $0.contains("awaiting readback") })
    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    XCTAssertTrue(recorded.contains { $0.name == "install-readback.json" })
  }

  func testCleanInstallExitWithEmptyReadbackFailsTheJob() async throws {
    // The exact hardware-observed hazard: `hdc install` exits zero without
    // having installed. Success must not follow from the exit code.
    let dispatcher = ScriptedDispatcher(script: .init(packageInstalled: false))
    let (engine, capabilities, _) = try makeEngine(dispatcher: dispatcher)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(hapRequest(key: "idem-hap-noinstall"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertNotEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("packageReadback"))
    // Having failed the readback, the run must not have started anything.
    XCTAssertFalse(dispatcher.dispatchedActions.contains("startAbility"))
  }

  func testCleanStartExitWithNoProcessFailsTheJob() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(processRunning: false))
    let (engine, capabilities, _) = try makeEngine(dispatcher: dispatcher)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(hapRequest(key: "idem-hap-nostart"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertNotEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("processReadback"))
  }

  func testHAPWithoutCapabilityDispatchesNothing() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
    do {
      _ = try await engine.submit(hapRequest(key: "idem-hap-nocap", capability: nil))
      XCTFail("an E1 operation without a capability must be rejected")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(.authorizationRequired, _) = error else {
        return XCTFail("expected authorizationRequired, got \(error)")
      }
    }
    XCTAssertTrue(dispatcher.dispatchedActions.isEmpty, "zero dispatch on refusal")
  }

  func testCapabilityScopedToAnotherOperationIsRejected() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, _) = try makeEngine(dispatcher: dispatcher)
    try await capabilities.install(
      try RuntimeCapability(
        capabilityID: "CAP-RT-HAP-001",
        targetScope: .anyTarget,
        // Scoped to a different operation than the one being run.
        operationScope: [.init(operationID: "deploy.native-library.app-owned", version: 1)],
        effectCeiling: .deviceMutation,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-12-31T00:00:00Z",
        maximumUses: 5,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#test")))
    do {
      _ = try await engine.submit(hapRequest(key: "idem-hap-scope"))
      XCTFail("an out-of-scope capability must be rejected")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(.authorizationRequired, let message) = error else {
        return XCTFail("expected authorizationRequired, got \(error)")
      }
      XCTAssertTrue(message.contains("operationScopeMismatch"), message)
    }
    XCTAssertTrue(dispatcher.dispatchedActions.isEmpty)
  }

  func testCapabilityIsConsumedOncePerRecipeNotPerStep() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, _) = try makeEngine(dispatcher: dispatcher)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(hapRequest(key: "idem-hap-once"))
    _ = try await engine.run(jobID: acceptance.jobID)
    let status = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(
      status?.remainingUses, 4,
      "one recipe consumes exactly one use, however many mutating steps it has")
    XCTAssertEqual(status?.consumptionCount, 1)
  }
}
