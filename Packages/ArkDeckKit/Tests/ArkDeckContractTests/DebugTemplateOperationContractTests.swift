import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// `debug.template@1`: the closed read-only Debug templates run through the
/// Runtime Job path. Process receipts are scripted; nothing here is
/// real-device evidence.
final class DebugTemplateOperationContractTests: XCTestCase {
  private var stateDirectory: URL!
  private var artifactStore: RuntimeArtifactStore!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-debug-template-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
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
        deviceIdentitySHA256: "3ba3f5f43b92602683c19aee62a20342b084dd5971ddd33808d81a328879a547",
        executionConnectKey: String(repeating: "a", count: 32),
        deviceModel: nil, deviceMode: "hdc",
        buildFingerprint: nil, transport: nil,
        profileID: "openharmony-standard@1", collectedAtUTC: "2026-09-02T00:00:00Z",
        sourceObservedAtUTC: "2026-09-02T00:00:00Z")
    }
  }

  /// Records every lowered plan and answers each action with a fixed receipt.
  private final class RecordingDispatcher: RuntimeProcessDispatching, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TypedProcessPlan] = []
    private let templateReceipt: ProviderProcessReceipt

    init(
      templateReceipt: ProviderProcessReceipt = ProviderProcessReceipt(
        exitStatus: 0, stdout: Data("up 1 day\n".utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.02)
    ) {
      self.templateReceipt = templateReceipt
    }

    var plans: [TypedProcessPlan] { lock.withLock { recorded } }

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      lock.withLock { recorded.append(plan) }
      switch plan.action {
      case .hdc(.observeDevice):
        return receipt("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t\tUSB\tConnected\tlocalhost\n")
      case .hdc(.runDebugTemplate):
        return templateReceipt
      default:
        throw RuntimeDispatchFailure.failed("unscripted action \(plan.action)")
      }
    }

    private func receipt(_ text: String) -> ProviderProcessReceipt {
      ProviderProcessReceipt(
        exitStatus: 0, stdout: Data(text.utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.01)
    }
  }

  func testTemplateRunsThroughTheJobPathAndPublishesBoundedOutput() async throws {
    let dispatcher = RecordingDispatcher()
    let engine = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(try request(templateID: "device.uptime"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded")
    XCTAssertFalse(status.outcomeUnknown)
    XCTAssertEqual(status.actualEffect, "readOnly")

    let plans = dispatcher.plans
    XCTAssertEqual(plans.count, 2, "one binding confirmation and one template, nothing else")
    guard case .hdc(.observeDevice)? = plans.first?.action else {
      return XCTFail("the template must not run before the binding identity is confirmed")
    }
    guard let templatePlan = plans.last,
      case .hdc(.runDebugTemplate(.uptime)) = templatePlan.action,
      case .process(_, let argv, let timeout) = templatePlan.kind
    else { return XCTFail("the template step must lower to one typed process plan") }
    XCTAssertEqual(argv, ["-t", String(repeating: "a", count: 32), "shell", "uptime"])
    XCTAssertEqual(timeout, 30)
    XCTAssertEqual(templatePlan.outputByteBudget, 16 * 1024)

    let artifacts = try await artifactStore.list(jobID: acceptance.jobID)
    let output = try XCTUnwrap(artifacts.first { $0.name == "template-output.txt" })
    let report = try XCTUnwrap(artifacts.first { $0.name == "template-report.json" })
    XCTAssertTrue(output.status.isPublished)
    XCTAssertTrue(report.status.isPublished)
    XCTAssertEqual(output.privacy, .sensitive)
    XCTAssertEqual(report.privacy, .standard)
    do {
      _ = try await artifactStore.read(jobID: acceptance.jobID, artifactID: output.artifactID)
      XCTFail("device output stays behind the sensitive opt-in")
    } catch {}
    let outputBytes = try await artifactStore.read(
      jobID: acceptance.jobID, artifactID: output.artifactID, allowSensitive: true)
    XCTAssertEqual(outputBytes, Data("up 1 day\n".utf8))
    let reportBytes = try await artifactStore.read(
      jobID: acceptance.jobID, artifactID: report.artifactID)
    guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: reportBytes)
    else { return XCTFail("the report must be a JSON object") }
    XCTAssertEqual(fields["operation"], .string("debug.template@1"))
    XCTAssertEqual(fields["templateId"], .string("device.uptime"))
    XCTAssertEqual(fields["remoteCommand"], .string("shell uptime"))
    XCTAssertEqual(fields["exitStatus"], .string("0"))
    XCTAssertEqual(fields["stdoutByteCount"], .string("9"))
    XCTAssertEqual(fields["catalogDigest"], .string(RuntimeOperationCatalog.catalogDigest))
    XCTAssertNil(fields["connectKey"], "the report never carries the connect key")
    XCTAssertFalse(
      reportBytes.contains(Data(String(repeating: "a", count: 32).utf8)),
      "the report never carries the connect key")

    let evidence = try await engine.evidenceSnapshot(jobID: acceptance.jobID)
    XCTAssertEqual(evidence.actualEffect, "readOnly")
    XCTAssertTrue(evidence.actualStepKinds.contains("probeDevice"))
  }

  func testAnIdentityOutsideTheClosedSetIsRefusedBeforeAnyDispatch() async throws {
    let dispatcher = RecordingDispatcher()
    let engine = try makeEngine(dispatcher: dispatcher)
    do {
      _ = try await engine.submit(try request(templateID: "device.reboot"))
      XCTFail("an identity outside the descriptor enum must be refused at admission")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected = error else { return XCTFail("\(error)") }
    }
    XCTAssertTrue(dispatcher.plans.isEmpty)
  }

  func testANonZeroTemplateExitFailsTheJobWithoutPublishingOutput() async throws {
    let dispatcher = RecordingDispatcher(
      templateReceipt: ProviderProcessReceipt(
        exitStatus: 1, stdout: Data("uptime: not permitted\n".utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0.02))
    let engine = try makeEngine(dispatcher: dispatcher)
    let acceptance = try await engine.submit(try request(templateID: "device.uptime"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "failed")
    XCTAssertFalse(status.outcomeUnknown)
    let artifacts = try await artifactStore.list(jobID: acceptance.jobID)
    XCTAssertFalse(
      artifacts.contains { $0.name == "template-output.txt" && $0.status.isPublished },
      "a failed read publishes no device output under the template's name")
  }

  func testTemplateActionsPersistExactlyAndStayReadOnly() throws {
    let descriptor = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "debug.template@1"))
    let field = try XCTUnwrap(descriptor.inputs.first { $0.name == "templateId" })
    XCTAssertEqual(field.enumValues, DebugRuntimeCommandTemplate.allCases.map(\.rawValue))
    for template in DebugRuntimeCommandTemplate.allCases {
      let action = TypedProviderAction.hdc(.runDebugTemplate(template))
      XCTAssertEqual(action.effect, .readOnly)
      let persisted = try PersistedTypedProviderAction(action)
      XCTAssertEqual(persisted.kind, "hdc.runDebugTemplate")
      XCTAssertEqual(try persisted.materialize(), action)
      XCTAssertEqual(template.remoteCommand.first, "shell")
      XCTAssertFalse(template.remoteCommand.contains("-t"))
      XCTAssertGreaterThan(template.outputByteBudget, 0)
    }
  }

  private func makeEngine(dispatcher: any RuntimeProcessDispatching) throws -> RuntimeJobEngine {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appending(path: "capabilities", directoryHint: .isDirectory))
    let store = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { "2026-09-02T00:00:00Z" })
    artifactStore = store
    return try RuntimeJobEngine(
      configuration: .init(stateDirectory: stateDirectory),
      providers: DeviceProviderRegistry(providers: [
        HDCObservationProviderAdapter(factsPort: FactsPort())
      ]),
      dispatcher: dispatcher,
      capabilityStore: capabilityStore,
      artifactStore: store,
      nowUTC: { "2026-09-02T00:00:00Z" })
  }

  private func request(templateID: String) throws -> Data {
    let request = try RuntimeOperationRequest(
      requestID: "req-\(UUID().uuidString.prefix(8).lowercased())",
      idempotencyKey: "idem-\(UUID().uuidString.lowercased())",
      target: DurableTargetReference(targetID: "TGT-DAYU200-01", expectedBindingRevision: 7),
      operation: RuntimeOperationReference(id: "debug.template", version: 1),
      inputs: ["templateId": .string(templateID)])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(request)
  }
}
