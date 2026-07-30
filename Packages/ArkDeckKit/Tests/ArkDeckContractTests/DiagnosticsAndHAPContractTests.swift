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
        targetID: targetID, bindingRevision: 7,
        deviceIdentitySHA256:
          "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1",
        executionConnectKey: "150100424a544e4600",
        deviceMode: nil, buildFingerprint: nil,
        profileID: "openharmony-standard@1", collectedAtUTC: "2026-07-29T00:00:00Z")
    }
  }

  /// Scriptable dispatcher: each action family can be told to succeed, to
  /// fail, or - the case that matters most - to exit cleanly while the
  /// readback shows nothing happened.
  private final class ScriptedDispatcher: RuntimeProcessDispatching, @unchecked Sendable {
    struct Script: Sendable {
      var packageInstalled = true
      var processRunning = true
      var hilogEmpty = false
      var sendOutcomeUnknown = false
      var availableStorageKB = 1_047_552
      var installExit: Int32 = 0
      var startExit: Int32 = 0
      var hilogPayloadBytes: Int?
      var hilogPayload: Data?
      var packageReadbackText: String?
      var processReadbackText: String?
      var ownedPathPresent = true
      var portForwardPresent = false
      var cleanupExit: Int32 = 0
      var cleanupOutcomeUnknown = false
      var targetRows = "150100424a544e4600\t\tUSB\tConnected\tlocalhost\n"
      var modelValue = "DAYU200\n"
      var firmwareValue = "OpenHarmony-4.1-release\n"
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
        return receipt(script.targetRows)
      case .observeStorage:
        note("observeStorage")
        return receipt(
          "Filesystem 1K-blocks Used Available Use% Mounted on\n"
            + "/dev/block/data 1048576 1024 \(script.availableStorageKB) 1% /data\n")
      case .captureHilog:
        note("captureHilog")
        if let payload = script.hilogPayload {
          return ProviderProcessReceipt(
            exitStatus: 0, stdout: payload, stderr: Data(),
            stdoutTruncated: false, durationSeconds: 0.01)
        }
        if let bytes = script.hilogPayloadBytes {
          return receipt(String(repeating: "I", count: bytes))
        }
        return receipt(script.hilogEmpty ? "" : "01-01 00:00:00 I app: hello\n")
      case .captureUIDump:
        note("captureUIDump")
        return receipt("{\"windows\":[]}\n")
      case .captureTrace:
        note("captureTrace")
        return receipt("")
      case .receiveOwnedArtifact:
        note("receiveArtifact")
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data("trace-bytes".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01, hostManagedRecordID: "local-trace")
      case .cleanupOwnedRemotePath:
        note("cleanup")
        if script.cleanupOutcomeUnknown {
          throw RuntimeDispatchFailure.outcomeUnknown("cleanup completion is unobservable")
        }
        return receipt("", exit: script.cleanupExit)
      case .sendArtifactToStaging:
        note("sendArtifact")
        if script.sendOutcomeUnknown {
          throw RuntimeDispatchFailure.outcomeUnknown("send completion is unobservable")
        }
        return receipt("FileTransfer finish")
      case .installPackage:
        note("installPackage")
        // Clean exit either way: the readback is what decides.
        return receipt("install bundle", exit: script.installExit)
      case .queryPackageReadback(let bundle):
        note("packageReadback")
        return receipt(
          script.packageReadbackText
            ?? (script.packageInstalled ? "bundleName: \(bundle.bundleName)\n" : ""))
      case .startAbility:
        note("startAbility")
        return receipt("start ability successfully", exit: script.startExit)
      case .verifyProcessState:
        note("processReadback")
        return receipt(
          script.processReadbackText ?? (script.processRunning ? "3421\n" : ""))
      case .stopAbility:
        note("stopAbility")
        return receipt("")
      case .uninstallPackage:
        note("uninstallPackage")
        return receipt("")
      case .queryProperty(.productModel):
        note("evidenceModel")
        return receipt(script.modelValue)
      case .queryProperty(.fullBuildVersion):
        note("evidenceFirmware")
        return receipt(script.firmwareValue)
      case .queryProperty:
        note("queryProperty")
        return receipt("provider-property\n")
      case .createPortForward, .removePortForward:
        note("portForward")
        return receipt("")
      case .readPackagePresence(let bundle):
        note("reconcilePackagePresence")
        return receipt(
          script.packageReadbackText
            ?? (script.packageInstalled ? "bundleName: \(bundle.bundleName)\n" : ""))
      case .readProcessPresence:
        note("reconcileProcessPresence")
        return receipt(
          script.processReadbackText ?? (script.processRunning ? "3421\n" : ""),
          exit: script.processRunning ? 0 : 1)
      case .readOwnedPathPresence:
        note("reconcileOwnedPathPresence")
        return receipt(
          script.ownedPathPresent
            ? "-rw------- owned\n"
            : "ls: owned: No such file or directory\n")
      case .readPortForwardPresence(let spec):
        note("reconcilePortForwardPresence")
        return receipt(
          script.portForwardPresent
            ? "tcp:\(spec.localPort) tcp:\(spec.remotePort)\n" : "")
      case .sendNativeLibraryToStaging, .backupNativeLibrary,
        .publishNativeLibrary, .stopNativeTarget, .startNativeTarget,
        .cleanupNativeLibrary, .rollbackNativeLibrary, .inspectNativeLibrary:
        throw RuntimeDispatchFailure.failed(
          "native deployment is outside the diagnostics/HAP fixture")
      }
    }
  }

  private func makeEngine(
    dispatcher: ScriptedDispatcher,
    artifactQuota: ArtifactQuota = ArtifactQuota()
  ) throws -> (RuntimeJobEngine, RuntimeCapabilityStore, RuntimeArtifactStore) {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appendingPathComponent("capabilities", isDirectory: true))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appendingPathComponent("artifacts", isDirectory: true),
      quota: artifactQuota,
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
    withTrace: Bool,
    key: String = "idem-capture-01",
    capability: String? = nil,
    totalArtifactByteBudget: Int? = nil,
    redactionProfile: String? = nil
  ) -> Data {
    let trace = withTrace ? "\"traceCategories\": [\"ohos\"]," : ""
    let auth = capability.map { "\"authorization\": { \"capabilityId\": \"\($0)\" }," } ?? ""
    let budget =
      totalArtifactByteBudget.map { "\"totalArtifactByteBudget\": \($0)," } ?? ""
    let redaction =
      redactionProfile.map { "\"redactionProfile\": \"\($0)\"," } ?? ""
    return Data(
      """
      {
        "documentType": "runtime-operation-request",
        "schemaVersion": "2.0.0",
        "requestId": "req-capture",
        "idempotencyKey": "\(key)",
        "target": { "targetId": "TGT-1", "expectedBindingRevision": 7 },
        "operation": { "id": "capture.diagnostics", "version": 1 },
        \(auth)
        "inputs": { \(trace) \(budget) \(redaction) "durationSeconds": 5 }
      }
      """.utf8)
  }

  private func hapRequest(
    lease: String,
    key: String = "idem-hap-01",
    capability: String? = "CAP-RT-HAP-001",
    bundleName: String = "com.example.demo",
    extraInputs: String = ""
  )
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
        "target": { "targetId": "TGT-1", "expectedBindingRevision": 7 },
        "operation": { "id": "debug.hap", "version": 1 },
        \(auth)
        "inputs": {
          "hapArtifactLease": "\(lease)",
          "bundleName": "\(bundleName)",
          "abilityName": "EntryAbility"
          \(extraInputs)
        }
      }
      """.utf8)
  }

  private func publishHAPLease(_ store: RuntimeArtifactStore) async throws -> String {
    let metadata = try await store.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-input-hap", sessionID: "session-input-hap",
        stepID: "publish-hap", name: "demo.hap",
        mediaType: "application/octet-stream", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "build.hap@1", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-1", bindingRevision: 7,
          stableIdentitySHA256:
            "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1"),
        contents: Data("signed-hap-fixture".utf8)))
    return try await store.leaseReference(
      jobID: metadata.jobID, artifactID: metadata.artifactID)
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
    let hilogID = try XCTUnwrap(byName["hilog.txt"]?.artifactID)
    let hilog = try await artifacts.read(
      jobID: acceptance.jobID, artifactID: hilogID, allowSensitive: true)
    XCTAssertEqual(
      String(data: hilog, encoding: .utf8),
      "01-01 00:00:00 I app: hello\n",
      "the Artifact must contain the captured log, not a byte-count summary")
    // The absent trace is present in the index WITH a reason: this is the
    // whole point - a partial capture cannot look complete.
    guard case .missing(let reason)? = byName["trace.htrace"]?.status else {
      return XCTFail(
        "the trace must be recorded as missing, got \(String(describing: byName["trace.htrace"]))")
    }
    XCTAssertFalse(reason.isEmpty)

    // And the summary says so in one place a caller can read.
    let summaryID = try XCTUnwrap(byName["capture-summary.json"]?.artifactID)
    let summaryText =
      String(
        data: try await artifacts.read(jobID: acceptance.jobID, artifactID: summaryID),
        encoding: .utf8) ?? ""
    XCTAssertTrue(summaryText.contains("trace.htrace"), summaryText)
    XCTAssertTrue(summaryText.contains("missing"), summaryText)
    // trace.htrace is an optional product, so overall completeness holds.
    XCTAssertTrue(summaryText.contains("\"completeness\" : \"complete\""), summaryText)
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

  func testRemoteTraceFailsClosedBeforeCapabilityConsumptionOrDispatch() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, _) = try makeEngine(dispatcher: dispatcher)
    try await installCaptureCapability(capabilities)
    do {
      _ = try await engine.submit(
        captureRequest(
          withTrace: true, key: "idem-trace-unimplemented",
          capability: "CAP-RT-CAPTURE-001"))
      XCTFail("trace cannot run without a verified host-managed receive path")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(.invalidInput, let message) = error else {
        return XCTFail("expected invalidInput, got \(error)")
      }
      XCTAssertTrue(message.contains("host-managed receive"), message)
    }
    let capability = try await capabilities.inspect(capabilityID: "CAP-RT-CAPTURE-001")
    XCTAssertEqual(capability?.consumptionCount, 0)
    XCTAssertTrue(dispatcher.dispatchedActions.isEmpty, "zero dispatch on refusal")
  }

  func testUnimplementedStrictRedactionFailsClosedBeforeDispatch() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
    do {
      _ = try await engine.submit(
        captureRequest(
          withTrace: false, key: "idem-strict-redaction",
          redactionProfile: "strict"))
      XCTFail("strict cannot be silently treated as standard redaction")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(.invalidInput, let message) = error else {
        return XCTFail("expected invalidInput, got \(error)")
      }
      XCTAssertTrue(message.contains("strict redaction"), message)
    }
    XCTAssertTrue(dispatcher.dispatchedActions.isEmpty)
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

  func testDeviceStoragePreflightIsRealAndBlocksCaptureWhenInsufficient() async throws {
    let dispatcher = ScriptedDispatcher(
      script: .init(availableStorageKB: 512))
    let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-storage-preflight"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    XCTAssertEqual(
      dispatcher.dispatchedActions,
      ["observeDevice", "evidenceModel", "evidenceFirmware", "observeStorage"])
  }

  func testJobArtifactBudgetStopsPublicationWithoutFillingTheStore() async throws {
    let budget = 1_048_576
    let dispatcher = ScriptedDispatcher(
      script: .init(hilogPayloadBytes: budget + 1))
    let (engine, _, artifacts) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(
        withTrace: false, key: "idem-artifact-budget",
        totalArtifactByteBudget: budget))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    XCTAssertFalse(recorded.contains { $0.name == "hilog.txt" && $0.status.isPublished })
    XCTAssertLessThanOrEqual(
      recorded.filter { $0.status.isPublished }.reduce(0) { $0 + $1.byteCount },
      budget)
    XCTAssertFalse(dispatcher.dispatchedActions.contains("captureUIDump"))
  }

  func testHostStoragePreflightRefusesCollectionBeforeDeviceDispatch() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, _, _) = try makeEngine(
      dispatcher: dispatcher,
      artifactQuota: ArtifactQuota(totalBytes: 512 * 1024))
    let acceptance = try await engine.submit(
      captureRequest(
        withTrace: false, key: "idem-capture-host-preflight",
        totalArtifactByteBudget: 1_048_576))

    let status = try await engine.run(jobID: acceptance.jobID)

    XCTAssertEqual(status.state, "failed")
    XCTAssertTrue(dispatcher.dispatchedActions.isEmpty)
    XCTAssertTrue(
      status.timeline.contains { $0.contains("host storage preflight refused") },
      status.timeline.joined(separator: " | "))
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

    let journalURL =
      stateDirectory
      .appendingPathComponent("jobs/\(acceptance.jobID)/journal.jsonl")
    let journal = try String(contentsOf: journalURL, encoding: .utf8)

    // The HiLog step must carry the diagnostics action, and no step may
    // carry a UI-dump action it does not have.
    XCTAssertTrue(journal.contains("\"boundedHilog\""), "HiLog intent must name its own action")
    XCTAssertTrue(journal.contains("\"arkdeck-diagnostics\""))
    XCTAssertTrue(journal.contains("\"deviceModel\""))
    XCTAssertTrue(journal.contains("\"firmwareBuild\""))
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

  func testIncompleteEvidencePreflightDispatchesNoHAPMutation() async throws {
    let vectors: [ScriptedDispatcher.Script] = [
      .init(targetRows: "different\t\tUSB\tConnected\tlocalhost\n"),
      .init(
        targetRows:
          "150100424a544e4600\t\tUSB\tConnected\tlocalhost\n"
          + "150100424a544e4600\t\tUSB\tConnected\tlocalhost\n"),
      .init(targetRows: "150100424a544e4600\t\tBLUETOOTH\tConnected\tlocalhost\n"),
      .init(modelValue: "\n"),
      .init(firmwareValue: "\n"),
    ]
    for (index, script) in vectors.enumerated() {
      let dispatcher = ScriptedDispatcher(script: script)
      let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
      try await installE1Capability(capabilities)
      let lease = try await publishHAPLease(artifacts)
      let acceptance = try await engine.submit(
        hapRequest(lease: lease, key: "idem-hap-preflight-\(index)"))
      let status = try await engine.run(jobID: acceptance.jobID)
      XCTAssertNotEqual(status.state, "succeeded", "vector \(index)")
      XCTAssertFalse(
        dispatcher.dispatchedActions.contains("sendArtifact"),
        "no E1 dispatch is allowed before complete preflight: vector \(index)")
      XCTAssertFalse(dispatcher.dispatchedActions.contains("installPackage"), "vector \(index)")
      let capability = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
      XCTAssertEqual(
        capability?.consumptionCount, 0,
        "incomplete target/model/firmware preflight must not consume E1: vector \(index)")
    }
  }

  /// The readiness requires the constructed WorkflowStep to carry the
  /// diagnostics contract's exact typed parameters and bounds - not merely
  /// the right action name. These drive the real validator, so a parameter
  /// the contract rejects cannot reach a durable intent.
  func testConstructedIntentCarriesContractExactParameters() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    let hilog = try XCTUnwrap(descriptor.steps.first { $0.stepID == "capture-hilog" })

    // Out-of-range inputs are clamped into the declared bounds rather than
    // passed through: the step still validates.
    let clamped = try RuntimeJobEngine.journalStep(
      for: hilog, jobID: "job-1",
      inputs: [
        "durationSeconds": .integer(99_999),
        "hilogFilters": .array((0..<40).map { .string("tag\($0):E") }),
        "totalArtifactByteBudget": .integer(1),
      ])
    guard case .object(let parameters)? = clamped.arguments["parameters"] else {
      return XCTFail("the intent must carry typed parameters")
    }
    XCTAssertEqual(parameters["durationSeconds"], .integer(600), "clamped to the contract maximum")
    XCTAssertEqual(parameters["byteBudget"], .integer(1024), "clamped to the contract minimum")
    guard case .array(let filters)? = parameters["filters"] else {
      return XCTFail("filters must be present")
    }
    XCTAssertEqual(filters.count, 16, "trimmed to the contract's 16-filter ceiling")
    XCTAssertEqual(clamped.arguments["catalogId"], .string("arkdeck-diagnostics"))
    XCTAssertEqual(clamped.arguments["actionId"], .string("boundedHilog"))

    // The UI-dump step carries its own action's parameter set, not HiLog's.
    let uiDump = try XCTUnwrap(descriptor.steps.first { $0.stepID == "capture-ui-dump" })
    let uiStep = try RuntimeJobEngine.journalStep(for: uiDump, jobID: "job-1", inputs: [:])
    XCTAssertEqual(uiStep.arguments["actionId"], .string("windowInventory"))
    guard case .object(let uiParameters)? = uiStep.arguments["parameters"] else {
      return XCTFail("the ui-dump intent must carry typed parameters")
    }
    XCTAssertEqual(Set(uiParameters.keys), ["byteBudget"], "windowInventory declares only a budget")
  }

  func testPairedRemoteActionsShareTheRealJobBoundProviderPath() throws {
    let provider = HDCObservationProviderAdapter(factsPort: FactsPort())
    let context = ProviderExecutionContext(
      jobID: "job-runtime-123", stepID: "test", targetID: "TGT-1",
      bindingRevision: 7, connectKey: "150100424a544e4600",
      nowUTC: "2026-07-29T00:00:00Z")

    let capture = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
    let trace = try provider.action(
      for: XCTUnwrap(capture.steps.first { $0.stepID == "capture-trace" }),
      operation: capture, inputs: [:], context: context)
    let receive = try provider.action(
      for: XCTUnwrap(capture.steps.first { $0.stepID == "receive-trace-artifact" }),
      operation: capture, inputs: [:], context: context)
    let captureCleanup = try provider.action(
      for: XCTUnwrap(capture.steps.first { $0.stepID == "cleanup-remote-temp" }),
      operation: capture, inputs: [:], context: context)

    guard case .hdc(.captureTrace(_, let tracePath)) = trace,
      case .hdc(.receiveOwnedArtifact(let remoteArtifact)) = receive,
      case .hdc(.cleanupOwnedRemotePath(let cleanupPath)) = captureCleanup
    else {
      return XCTFail("capture actions must retain their typed path payloads")
    }
    XCTAssertEqual(tracePath, remoteArtifact.path)
    XCTAssertEqual(tracePath, cleanupPath)
    XCTAssertEqual(tracePath.jobID, "job-runtime-123")

    let debug = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "debug.hap@1"))
    let inputs: [String: JSONValue] = [
      "hapArtifactLease": .string("lease-v1:job-input:ART-0123456789abcdef0123456789abcdef"),
      "bundleName": .string("com.example.demo"),
      "abilityName": .string("EntryAbility"),
    ]
    let send = try provider.action(
      for: XCTUnwrap(debug.steps.first { $0.stepID == "send-hap" }),
      operation: debug, inputs: inputs, context: context)
    let install = try provider.action(
      for: XCTUnwrap(debug.steps.first { $0.stepID == "install-hap" }),
      operation: debug, inputs: inputs, context: context)
    let stagingCleanup = try provider.action(
      for: XCTUnwrap(debug.steps.first { $0.stepID == "cleanup-remote-staging" }),
      operation: debug, inputs: inputs, context: context)

    guard case .hdc(.sendArtifactToStaging(let staged)) = send,
      case .hdc(.installPackage(let installed, _)) = install,
      case .hdc(.cleanupOwnedRemotePath(let stagingPath)) = stagingCleanup
    else {
      return XCTFail("debug actions must retain their typed staging payloads")
    }
    XCTAssertEqual(staged.path, installed.path)
    XCTAssertEqual(staged.path, stagingPath)
    XCTAssertEqual(staged.path.jobID, "job-runtime-123")
    let installPlan = try provider.lower(action: install, context: context)
    guard case .process(_, let installArguments, _) = installPlan.kind else {
      return XCTFail("install must lower to a process plan")
    }
    XCTAssertEqual(
      installArguments,
      [
        "-t", "150100424a544e4600", "shell", "bm", "install", "-p",
        staged.path.remotePath, "-r",
      ],
      "installOrReplace must use the staged remote path and replacement mode")
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
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(hapRequest(lease: lease))
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

  func testHAPPreservesNonUTF8HilogAsSensitiveRawArtifact() async throws {
    let raw = Data([0x49, 0x20, 0xff, 0xfe, 0x0a])
    let dispatcher = ScriptedDispatcher(script: .init(hilogPayload: raw))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-non-utf8-hilog"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    let recorded = try await artifacts.list(jobID: acceptance.jobID)
    let hilog = try XCTUnwrap(recorded.first { $0.name == "debug-hilog.txt" })
    XCTAssertEqual(hilog.status, .published)
    XCTAssertEqual(hilog.privacy, .sensitive)
    XCTAssertFalse(hilog.redactionApplied)
    let stored = try await artifacts.read(
      jobID: acceptance.jobID, artifactID: hilog.artifactID,
      allowSensitive: true)
    XCTAssertEqual(stored, raw)
  }

  func testHAPDurableIntentUsesTheResolvedArtifactAndExactOwnedPath() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    let resolved = try await artifacts.resolveLease(lease)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-exact-intent"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded")

    let journal = try String(
      contentsOf: stateDirectory.appendingPathComponent(
        "jobs/\(acceptance.jobID)/journal.jsonl"),
      encoding: .utf8)
    let ownedPath =
      "/data/local/tmp/arkdeck-\(acceptance.jobID)-send-hap-owned.hap"
    XCTAssertTrue(journal.contains(resolved.artifactID), journal)
    XCTAssertTrue(journal.contains(resolved.sha256), journal)
    XCTAssertTrue(journal.contains(ownedPath), journal)
    XCTAssertFalse(journal.contains("<artifact-lease>"), journal)
  }

  func testCleanInstallExitWithEmptyReadbackFailsTheJob() async throws {
    // The exact hardware-observed hazard: `hdc install` exits zero without
    // having installed. Success must not follow from the exit code.
    let dispatcher = ScriptedDispatcher(script: .init(packageInstalled: false))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-noinstall"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertNotEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("packageReadback"))
    // Having failed the readback, the run must not have started anything.
    XCTAssertFalse(dispatcher.dispatchedActions.contains("startAbility"))
  }

  func testNonzeroInstallFailsBeforeAnExistingPackageCanFakeTheReadback() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(installExit: 1))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-install-failed"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    XCTAssertFalse(
      dispatcher.dispatchedActions.contains("packageReadback"),
      "an already-installed old package must not turn a failed install into success")
  }

  func testNonzeroStartFailsBeforeAnExistingProcessCanFakeTheReadback() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(processRunning: true, startExit: 1))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-start-failed"))

    let status = try await engine.run(jobID: acceptance.jobID)

    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    XCTAssertFalse(
      dispatcher.dispatchedActions.contains("processReadback"),
      "an old live process must not turn a failed start into success")
    XCTAssertTrue(dispatcher.dispatchedActions.contains("uninstallPackage"))
  }

  func testCleanStartExitWithNoProcessFailsTheJob() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(processRunning: false))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-nostart"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertNotEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("processReadback"))
  }

  func testPackageReadbackRejectsBundleNameSubstrings() async throws {
    let packageDispatcher = ScriptedDispatcher(
      script: .init(packageReadbackText: "bundleName: com.example.demo.other\n"))
    let (packageEngine, packageCapabilities, packageArtifacts) =
      try makeEngine(dispatcher: packageDispatcher)
    let packageLease = try await publishHAPLease(packageArtifacts)
    try await installE1Capability(packageCapabilities)
    let packageJob = try await packageEngine.submit(
      hapRequest(lease: packageLease, key: "idem-hap-package-substring"))
    let packageStatus = try await packageEngine.run(jobID: packageJob.jobID)
    XCTAssertEqual(packageStatus.state, "failed")
    XCTAssertFalse(packageDispatcher.dispatchedActions.contains("startAbility"))
  }

  func testProcessReadbackRejectsNonnumericPidNoise() async throws {
    let processDispatcher = ScriptedDispatcher(
      script: .init(processReadbackText: "error 404\n"))
    let (processEngine, processCapabilities, processArtifacts) =
      try makeEngine(dispatcher: processDispatcher)
    let processLease = try await publishHAPLease(processArtifacts)
    try await installE1Capability(processCapabilities)
    let processJob = try await processEngine.submit(
      hapRequest(lease: processLease, key: "idem-hap-pid-noise"))
    let processStatus = try await processEngine.run(jobID: processJob.jobID)
    XCTAssertEqual(processStatus.state, "failed")
  }

  func testHAPWithoutCapabilityUsesAutomaticE1Policy() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-auto-policy", capability: nil))
    XCTAssertTrue(
      dispatcher.dispatchedActions.isEmpty,
      "automatic issuance happens after materialization but before any dispatch")

    let automaticStatuses = try await capabilities.list()
    let automatic = try XCTUnwrap(automaticStatuses.first)
    XCTAssertEqual(automatic.capability.issuer.kind, .runtimeDefaultPolicy)
    XCTAssertEqual(automatic.consumptionCount, 0)
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("sendArtifact"))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("installPackage"))

    let consumed = try await capabilities.inspect(
      capabilityID: automatic.capability.capabilityID)
    XCTAssertEqual(consumed?.consumptionCount, 1)
    XCTAssertEqual(consumed?.remainingUses, 9_999)
    XCTAssertEqual(consumed?.lineage.first?.outcome, .confirmed)
    let evidence = try await engine.evidenceSnapshot(jobID: acceptance.jobID)
    XCTAssertEqual(evidence.authority?.kind, .runtimeCapability)
    XCTAssertEqual(evidence.authority?.reference, automatic.capability.capabilityID)
  }

  func testOfflineTargetFailsDurablyBeforeCapabilityConsumptionOrMutation() async throws {
    let dispatcher = ScriptedDispatcher(
      script: .init(
        targetRows: "150100424a544e4600\t\tUSB\tOffline\tlocalhost\n"))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)

    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-offline-before-consume"))

    let beforeRun = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(beforeRun?.consumptionCount, 0)
    XCTAssertTrue(
      dispatcher.dispatchedActions.isEmpty,
      "submit may materialize and preauthorize, but every external probe needs a durable job intent")
    let status = try await engine.run(jobID: acceptance.jobID)

    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    XCTAssertTrue(
      status.timeline.contains { $0.contains("targetNotConnected") },
      status.timeline.joined(separator: " | "))
    XCTAssertFalse(
      status.timeline.contains { $0.contains("three-step typed preflight is incomplete") },
      "a no-mutation target failure must not be overwritten by compensation preflight")
    let capability = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(capability?.consumptionCount, 0)
    XCTAssertEqual(capability?.remainingUses, 5)
    XCTAssertEqual(
      dispatcher.dispatchedActions, ["observeDevice"],
      "only the journaled descriptor-bound target confirmation may dispatch")
    let jobs = await engine.listJobs()
    XCTAssertEqual(jobs.map(\.jobID), [acceptance.jobID])
  }

  func testRuntimeTargetFailurePreservesPrimaryReasonWithoutFalseCompensation() async throws {
    let dispatcher = ScriptedDispatcher(
      script: .init(targetRows: "different\t\tUSB\tConnected\tlocalhost\n"))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-offline-after-consume"))

    let status = try await engine.run(jobID: acceptance.jobID)

    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    XCTAssertTrue(
      status.timeline.contains { $0.contains("targetConfirmationMismatch") },
      status.timeline.joined(separator: " | "))
    XCTAssertFalse(
      status.timeline.contains { $0.contains("three-step typed preflight is incomplete") },
      "a no-mutation target failure must not be overwritten by compensation preflight")
    XCTAssertFalse(dispatcher.dispatchedActions.contains("sendArtifact"))
    XCTAssertFalse(dispatcher.dispatchedActions.contains("installPackage"))
    XCTAssertFalse(dispatcher.dispatchedActions.contains("uninstallPackage"))
    let capability = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(capability?.consumptionCount, 0)
  }

  func testHAPLeaseDriftBeforeSendFailsWithoutDispatchOrStuckRunningState() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-lease-drift"))
    let resolved = try await artifacts.resolveLease(lease)
    try FileManager.default.removeItem(at: resolved.fileURL)

    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    XCTAssertFalse(
      dispatcher.dispatchedActions.contains("sendArtifact"),
      "no mutation may use drifted Artifact bytes")
    XCTAssertFalse(dispatcher.dispatchedActions.contains("installPackage"))
  }

  func testCapabilityScopedToAnotherOperationIsRejected() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
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
      _ = try await engine.submit(hapRequest(lease: lease, key: "idem-hap-scope"))
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
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-once"))
    _ = try await engine.run(jobID: acceptance.jobID)
    let status = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(
      status?.remainingUses, 4,
      "one recipe consumes exactly one use, however many mutating steps it has")
    XCTAssertEqual(status?.consumptionCount, 1)
  }

  func testDeferredCapabilityConsumptionSurvivesRestartBeforeRun() async throws {
    let submitDispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: submitDispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-deferred-restart"))
    let beforeRestart = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(beforeRestart?.consumptionCount, 0)
    XCTAssertTrue(submitDispatcher.dispatchedActions.isEmpty)

    let recoveredDispatcher = ScriptedDispatcher()
    let (recovered, recoveredCapabilities, _) = try makeEngine(
      dispatcher: recoveredDispatcher)
    _ = try await recovered.recoverPersistedJobs()
    let status = try await recovered.run(jobID: acceptance.jobID)

    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    let afterRun = try await recoveredCapabilities.inspect(
      capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(afterRun?.consumptionCount, 1)
    XCTAssertTrue(
      status.timeline.contains { $0 == "capability consumed before first mutation" })
    XCTAssertTrue(recoveredDispatcher.dispatchedActions.contains("sendArtifact"))
  }

  func testIdempotencyConflictCannotConsumeASecondCapability() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    try await capabilities.install(
      try RuntimeCapability(
        capabilityID: "CAP-RT-HAP-002",
        targetScope: .anyTarget,
        operationScope: [.init(operationID: "debug.hap", version: 1)],
        effectCeiling: .deviceMutation,
        issuedAtUTC: "2026-07-01T00:00:00Z",
        expiresAtUTC: "2026-12-31T00:00:00Z",
        maximumUses: 5,
        issuer: .init(kind: .maintainerMergedPR, reference: "PR#test")))

    let firstAcceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-conflict"))
    do {
      _ = try await engine.submit(
        hapRequest(
          lease: lease, key: "idem-hap-conflict",
          capability: "CAP-RT-HAP-002", bundleName: "com.example.other"))
      XCTFail("drifted request must conflict")
    } catch let error as RuntimeJobEngineError {
      guard case .idempotencyConflict = error else {
        return XCTFail("expected idempotencyConflict, got \(error)")
      }
    }
    let firstCapability = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    let secondCapability = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-002")
    XCTAssertEqual(
      firstCapability?.consumptionCount, 0,
      "submit preauthorizes but does not consume before journaled target preflight")
    XCTAssertEqual(secondCapability?.consumptionCount, 0)
    _ = try await engine.run(jobID: firstAcceptance.jobID)
    let consumedFirst = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(consumedFirst?.consumptionCount, 1)
  }

  func testRetainAndDisabledDiagnosticsDoNotDispatchThoseOptionalSteps() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(
        lease: lease, key: "idem-hap-retain",
        extraInputs: """
          ,
          "cleanupPolicy": "retain",
          "captureDiagnostics": false
          """))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertFalse(dispatcher.dispatchedActions.contains("captureHilog"))
    XCTAssertFalse(dispatcher.dispatchedActions.contains("uninstallPackage"))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("cleanup"))
  }

  func testUnsupportedHAPModesFailBeforeCapabilityConsumption() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)

    let unsupported: [(String, String, String)] = [
      (
        "restore", "\"cleanupPolicy\": \"restorePrevious\"",
        "snapshot/restore"
      ),
      (
        "forward", "\"portForwardProfile\": \"debugger-default\"",
        "port-forward"
      ),
      (
        "fresh", "\"installPolicy\": \"installFresh\"",
        "pre-install absence"
      ),
    ]
    for (suffix, input, expectedDetail) in unsupported {
      do {
        _ = try await engine.submit(
          hapRequest(
            lease: lease, key: "idem-hap-\(suffix)",
            extraInputs: ",\n\(input)"))
        XCTFail("\(suffix) cannot be silently downgraded")
      } catch let error as RuntimeJobEngineError {
        guard case .rejected(.invalidInput, let detail) = error else {
          return XCTFail("expected invalidInput, got \(error)")
        }
        XCTAssertTrue(detail.contains(expectedDetail), detail)
      }
    }
    let capability = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(capability?.consumptionCount, 0)
    XCTAssertTrue(dispatcher.dispatchedActions.isEmpty)
  }

  func testInvalidCatalogBoundFailsBeforeCapabilityConsumption() async throws {
    let dispatcher = ScriptedDispatcher()
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    do {
      _ = try await engine.submit(
        hapRequest(
          lease: lease, key: "idem-hap-duration",
          extraInputs: """
            ,
            "diagnosticsDurationSeconds": 999
            """))
      XCTFail("out-of-range catalog input must be rejected")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(.invalidInput, _) = error else {
        return XCTFail("expected invalidInput, got \(error)")
      }
    }
    let capability = try await capabilities.inspect(capabilityID: "CAP-RT-HAP-001")
    XCTAssertEqual(capability?.consumptionCount, 0)
  }

  func testReadbackFailureRunsTypedCompensation() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(processRunning: false))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-compensate"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "failed", status.timeline.joined(separator: " | "))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("stopAbility"))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("uninstallPackage"))
    XCTAssertTrue(dispatcher.dispatchedActions.contains("cleanup"))
    XCTAssertTrue(status.timeline.contains { $0.contains("compensated cleanup-uninstall") })
  }

  func testReconcileUsesTheOriginalUnknownMutationAction() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(sendOutcomeUnknown: true))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-hap-reconcile"))
    let parked = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(parked.state, "waitingForRecovery")
    XCTAssertTrue(parked.outcomeUnknown)
    let parkedReplay = try DurableJournalRecovery.inspect(
      url:
        stateDirectory
        .appendingPathComponent("jobs/\(acceptance.jobID)/journal.jsonl"))
    XCTAssertEqual(
      parkedReplay.outstandingIntents.map(\.stepID), ["send-hap"],
      "an unknown dispatch must retain the original durable intent")
    XCTAssertTrue(
      parkedReplay.unknownOutcomes.isEmpty,
      "recovery must not manufacture an outcomeUnknown step outcome")

    let recoveryDispatcher = ScriptedDispatcher()
    let (recoveredEngine, _, _) = try makeEngine(dispatcher: recoveryDispatcher)
    _ = try await recoveredEngine.recoverPersistedJobs()
    let reconciled = try await recoveredEngine.reconcile(jobID: acceptance.jobID)
    XCTAssertFalse(
      reconciled.outcomeUnknown,
      "the persisted send action must reconcile through its job-owned path readback")
    XCTAssertTrue(
      reconciled.timeline.contains { $0.contains("reconciled") },
      reconciled.timeline.joined(separator: " | "))
    XCTAssertEqual(
      recoveryDispatcher.dispatchedActions, ["reconcileOwnedPathPresence"],
      "restart recovery must dispatch only the dedicated readback, never resend the mutation")
    let resumed = try await recoveredEngine.run(jobID: acceptance.jobID)
    XCTAssertEqual(resumed.state, "succeeded", resumed.timeline.joined(separator: " | "))
    XCTAssertFalse(
      recoveryDispatcher.dispatchedActions.contains("sendArtifact"),
      "the reconciled mutation must be skipped from durable journal progress")
    let completedReplay = try DurableJournalRecovery.inspect(
      url:
        stateDirectory
        .appendingPathComponent("jobs/\(acceptance.jobID)/journal.jsonl"))
    XCTAssertTrue(completedReplay.outstandingIntents.isEmpty)
    XCTAssertTrue(completedReplay.unknownOutcomes.isEmpty)
  }

  func testSemanticUnknownPersistsItsOriginalStepForReconcile() async throws {
    let dispatcher = ScriptedDispatcher(script: .init(hilogEmpty: true))
    let (engine, _, _) = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(
      captureRequest(withTrace: false, key: "idem-capture-semantic-unknown"))
    let parked = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(parked.state, "waitingForRecovery")
    XCTAssertTrue(parked.outcomeUnknown)

    let reconciled = try await engine.reconcile(jobID: acceptance.jobID)
    XCTAssertFalse(reconciled.outcomeUnknown)
    XCTAssertEqual(
      reconciled.state, "failed",
      "confirmed non-execution is terminal and must not auto-resend even a read-only action")
    XCTAssertTrue(
      reconciled.timeline.contains { $0.contains("reconciled") },
      reconciled.timeline.joined(separator: " | "))
  }

  func testCleanupDebtCanBeQueriedAndExplicitlyContinued() async throws {
    let dispatcher = ScriptedDispatcher(
      script: .init(processRunning: false, cleanupExit: 1))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-cleanup-debt-continue"))
    _ = try await engine.run(jobID: acceptance.jobID)
    let debts = try await engine.listCleanupDebt()
    let debt = try XCTUnwrap(debts.first)
    XCTAssertEqual(debt.jobID, acceptance.jobID)

    let continuationDispatcher = ScriptedDispatcher()
    let (recovered, _, _) = try makeEngine(dispatcher: continuationDispatcher)
    _ = try await recovered.recoverPersistedJobs()
    let result = try await recovered.continueCleanupDebt(
      jobID: debt.jobID, remotePath: debt.remotePath)
    XCTAssertEqual(result.state, .settled)
    XCTAssertEqual(
      continuationDispatcher.dispatchedActions,
      ["reconcileOwnedPathPresence", "cleanup"])
    let remainingDebt = try await recovered.listCleanupDebt()
    XCTAssertTrue(remainingDebt.isEmpty)
  }

  func testUnknownCleanupContinuationNeverResendsMutation() async throws {
    let dispatcher = ScriptedDispatcher(
      script: .init(processRunning: false, cleanupExit: 1))
    let (engine, capabilities, artifacts) = try makeEngine(dispatcher: dispatcher)
    let lease = try await publishHAPLease(artifacts)
    try await installE1Capability(capabilities)
    let acceptance = try await engine.submit(
      hapRequest(lease: lease, key: "idem-cleanup-debt-unknown"))
    _ = try await engine.run(jobID: acceptance.jobID)
    let recordedDebt = try await engine.listCleanupDebt()
    let debt = try XCTUnwrap(recordedDebt.first)

    let unknownDispatcher = ScriptedDispatcher(script: .init(cleanupOutcomeUnknown: true))
    let (firstRecovery, _, _) = try makeEngine(dispatcher: unknownDispatcher)
    _ = try await firstRecovery.recoverPersistedJobs()
    let unknown = try await firstRecovery.continueCleanupDebt(
      jobID: debt.jobID, remotePath: debt.remotePath)
    XCTAssertEqual(unknown.state, .outcomeUnknown)
    XCTAssertEqual(
      unknownDispatcher.dispatchedActions,
      ["reconcileOwnedPathPresence", "cleanup"])

    let noResendDispatcher = ScriptedDispatcher()
    let (secondRecovery, _, _) = try makeEngine(dispatcher: noResendDispatcher)
    _ = try await secondRecovery.recoverPersistedJobs()
    let refused = try await secondRecovery.continueCleanupDebt(
      jobID: debt.jobID, remotePath: debt.remotePath)
    XCTAssertEqual(refused.state, .outcomeUnknown)
    XCTAssertEqual(
      noResendDispatcher.dispatchedActions, ["reconcileOwnedPathPresence"],
      "an outcomeUnknown cleanup retry may only be read back, never resent")
  }
}
