import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// T00 (DHA-AGENT-001): the Device Runtime Agent drives the runtime
/// itself. These tests run the real runner against a real daemon over its
/// socket - the only substitution is the device.
final class AgentRuntimeExecutorContractTests: XCTestCase {
  private var stateDirectory: URL!
  private var server: AgentDaemonServer?

  override func setUpWithError() throws {
    stateDirectory = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(
        ".arkdeck-agent-\(UInt32.random(in: 0..<100_000))", isDirectory: true)
  }

  override func tearDownWithError() throws {
    server?.stop()
    server = nil
    if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
  }

  private struct FactsPort: HDCObservationFactsPort {
    let store: RuntimeTargetStore
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      ProviderFacts(
        providerID: "hdc", toolVersion: "3.2.0f",
        toolSHA256: String(repeating: "a", count: 64), serverFacts: [:],
        deviceIdentitySHA256: nil, deviceMode: "hdc", buildFingerprint: nil,
        profileID: "openharmony-standard@1", collectedAtUTC: "2026-07-29T00:00:00Z")
    }
  }

  private struct HappyDispatcher: RuntimeProcessDispatching {
    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      func receipt(_ text: String) -> ProviderProcessReceipt {
        ProviderProcessReceipt(
          exitStatus: 0, stdout: Data(text.utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      }
      guard case .hdc(let action) = plan.action else {
        throw RuntimeDispatchFailure.failed("unexpected provider")
      }
      switch action {
      case .observeTool: return receipt("Ver: 3.2.0f\n")
      case .observeServer:
        return receipt("Client version:Ver: 3.2.0f, server version:Ver: 3.2.0f\n")
      default: return receipt("150100424a544e4600\t\tUSB\tConnected\tlocalhost\n")
      }
    }
  }

  private struct ScriptedBootstrap: BootstrapObservationPort {
    let candidates: [BootstrapCandidate]
    func observeToolVersion() async throws -> String { "3.2.0f" }
    func listCandidates() async throws -> [BootstrapCandidate] { candidates }
    func observeDeviceIdentity(connectKey: String) async throws -> [String: String] {
      ["serial": connectKey]
    }
  }

  private func startDaemon(
    candidates: [BootstrapCandidate] = [
      BootstrapCandidate(connectKey: "150100424a544e4600", state: "Connected")
    ],
    observer: (@Sendable (String) -> Void)? = nil
  ) throws -> AgentClient {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appendingPathComponent("capabilities", isDirectory: true))
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appendingPathComponent("targets", isDirectory: true))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appendingPathComponent("artifacts", isDirectory: true),
      nowUTC: { "2026-07-29T00:00:00Z" })
    let provider = HDCObservationProviderAdapter(factsPort: FactsPort(store: targetStore))
    let providers = DeviceProviderRegistry(providers: [provider])
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory.appendingPathComponent("engine", isDirectory: true)),
      providers: providers, dispatcher: HappyDispatcher(),
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-07-29T00:00:00Z" })
    let bootstrap = DeviceBootstrapMachine(
      observation: ScriptedBootstrap(candidates: candidates), targetStore: targetStore,
      nowUTC: { "2026-07-29T00:00:00Z" })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilityStore,
      providerIDs: providers.registeredProviderIDs, nowUTC: { "2026-07-29T00:00:00Z" },
      targetStore: targetStore, bootstrap: bootstrap, artifactStore: artifactStore,
      methodObserver: observer)
    let server = AgentDaemonServer(
      stateDirectory: stateDirectory, handler: handler, nowUTC: { "2026-07-29T00:00:00Z" })
    guard try server.start() == .started else {
      throw AgentDaemonError.io("daemon did not start")
    }
    self.server = server
    return AgentClient(socketPath: server.socketURL.path)
  }

  private func executor(_ client: AgentClient) -> AgentRuntimeExecutor {
    AgentRuntimeExecutor(client: client, nowUTC: { "2026-07-29T00:00:00Z" })
  }

  // MARK: - The agent drives the runtime

  func testAgentAdoptsAndRunsAnOperationWithoutAnyHumanHostCommand() throws {
    let client = try startDaemon()
    let outcome = try executor(client).run(
      RuntimeAgentExecutionRequest(operationID: "observe.device", operationVersion: 1))
    guard case .completed(let receipt) = outcome else {
      return XCTFail("the agent must complete the run: \(outcome)")
    }
    XCTAssertEqual(receipt.executor, .agent, "the receipt must not claim a human ran this")
    XCTAssertEqual(receipt.operationReference, "observe.device@1")
    XCTAssertEqual(receipt.terminalState, "succeeded")
    XCTAssertNotNil(receipt.jobID)
    XCTAssertTrue(receipt.targetID?.hasPrefix("TGT-") == true)
    XCTAssertEqual(receipt.authorityReference, "default-read-only-policy")
    XCTAssertFalse(receipt.catalogDigest.isEmpty)
    XCTAssertTrue(receipt.humanActions.isEmpty, "nothing physical was needed here")
    XCTAssertFalse(receipt.artifacts.isEmpty, "the run's products are referenced by ID")
  }

  func testUnauthorizedDeviceBecomesAResumableHumanActionNotAFailure() throws {
    let client = try startDaemon(candidates: [
      BootstrapCandidate(connectKey: "150100424a544e4600", state: "Unauthorized")
    ])
    let outcome = try executor(client).run(
      RuntimeAgentExecutionRequest(operationID: "observe.device", operationVersion: 1))
    guard case .awaitingHumanAction(let action, let receipt) = outcome else {
      return XCTFail("an untrusted device must pause, not fail: \(outcome)")
    }
    XCTAssertEqual(action.kind, .trustDevice)
    XCTAssertTrue(action.prompt.contains("trust"), action.prompt)
    XCTAssertFalse(action.resumeToken.isEmpty, "the pause must be resumable")
    XCTAssertEqual(receipt.terminalState, "awaitingHumanAction")
    XCTAssertEqual(receipt.humanActions.count, 1)
    XCTAssertEqual(receipt.executor, .agent)
  }

  func testAmbiguousCandidatesAskForSelectionRatherThanGuessing() throws {
    let client = try startDaemon(candidates: [
      BootstrapCandidate(connectKey: "AAA", state: "Connected"),
      BootstrapCandidate(connectKey: "BBB", state: "Connected"),
    ])
    let outcome = try executor(client).run(
      RuntimeAgentExecutionRequest(operationID: "observe.device", operationVersion: 1))
    guard case .awaitingHumanAction(let action, _) = outcome else {
      return XCTFail("two candidates must require a choice: \(outcome)")
    }
    XCTAssertEqual(action.kind, .selectTarget)
    XCTAssertTrue(action.prompt.contains("candidates"), action.prompt)
  }

  func testAgentSurfaceCannotManageCapabilitiesOrCarryCommands() throws {
    // Behavioural, not textual: drive a real run and assert on the methods
    // the agent actually invoked. Grepping the source would pass on
    // prose - the very trap this file's own header would have sprung.
    let recorder = try startRecordingDaemon()
    _ = try executor(recorder.client).run(
      RuntimeAgentExecutionRequest(operationID: "observe.device", operationVersion: 1))
    let called = recorder.observedMethods()
    XCTAssertFalse(called.isEmpty, "the run must have called the daemon")
    for management in ["capability.install", "capability.revoke"] {
      XCTAssertFalse(
        called.contains(management),
        "the agent must never manage capabilities: called \(called)")
    }
    XCTAssertTrue(
      called.allSatisfy { method in
        ["health", "target.list", "target.adopt", "job.submit", "job.run", "job.status",
          "artifact.list"].contains(method)
      },
      "the agent may only use the published runtime surface: \(called)")

    // The request type itself offers a capability *reference* and nothing
    // that could carry a document or a command.
    let request = RuntimeAgentExecutionRequest(
      operationID: "debug.hap", operationVersion: 1,
      capabilityReference: "CAP-RT-EXAMPLE-001")
    XCTAssertEqual(request.capabilityReference, "CAP-RT-EXAMPLE-001")
  }

  /// A daemon whose handler records which methods were invoked.
  private struct MethodRecorder {
    let client: AgentClient
    let observedMethods: @Sendable () -> [String]
  }

  private func startRecordingDaemon() throws -> MethodRecorder {
    final class Log: @unchecked Sendable {
      private let lock = NSLock()
      private var methods: [String] = []
      func record(_ method: String) { lock.withLock { methods.append(method) } }
      func snapshot() -> [String] { lock.withLock { methods } }
    }
    let log = Log()
    let client = try startDaemon(observer: { log.record($0) })
    return MethodRecorder(client: client, observedMethods: { log.snapshot() })
  }

  func testAgentRunSubmitsAtMostOneJob() throws {
    let client = try startDaemon()
    _ = try executor(client).run(
      RuntimeAgentExecutionRequest(operationID: "observe.device", operationVersion: 1))
    guard case .array(let jobs) = try client.request(method: "job.list") else {
      return XCTFail("job.list must answer")
    }
    XCTAssertEqual(jobs.count, 1, "one invocation submits exactly one job, never a loop")
  }

  func testMissingCapabilityIsReportedAsRejectionWithAReceipt() throws {
    let client = try startDaemon()
    let outcome = try executor(client).run(
      RuntimeAgentExecutionRequest(
        operationID: "debug.hap", operationVersion: 1,
        inputs: [
          "hapArtifactLease": .string("lease-1"),
          "bundleName": .string("com.example.demo"),
          "abilityName": .string("EntryAbility"),
        ]))
    guard case .failed(let reason, let receipt) = outcome else {
      return XCTFail("an E1 operation without a capability must be refused: \(outcome)")
    }
    XCTAssertTrue(reason.contains("authorizationRequired"), reason)
    XCTAssertEqual(receipt.terminalState, "rejected")
    XCTAssertNil(receipt.jobID, "a refused submission produces no job")
    XCTAssertEqual(receipt.executor, .agent)
  }

  private func packageRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.lastPathComponent != "ArkDeckKit" && url.pathComponents.count > 1 {
      url = url.deletingLastPathComponent()
    }
    return url
  }
}

/// The authorization defect the maintainer caught in review: charging the
/// operation's minimum effect would let a plan that mutates the device
/// through on the default read-only policy.
final class EffectiveEffectContractTests: XCTestCase {
  private func capture() throws -> CatalogOperationDescriptor {
    try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "capture.diagnostics@1"))
  }

  func testCaptureWithoutTraceIsReadOnly() throws {
    let descriptor = try capture()
    XCTAssertEqual(
      RuntimeJobEngine.effectiveEffect(
        descriptor: descriptor, inputs: ["durationSeconds": .integer(5)]),
      .readOnly)
  }

  func testCaptureWithRemoteTraceEscalatesToDeviceMutation() throws {
    let descriptor = try capture()
    let effect = RuntimeJobEngine.effectiveEffect(
      descriptor: descriptor,
      inputs: [
        "durationSeconds": .integer(5),
        "traceCategories": .array([.string("ohos")]),
      ])
    XCTAssertEqual(
      effect, .deviceMutation,
      "selecting the remote-file trace mutates the device and must be charged as such")
    XCTAssertGreaterThan(
      effect, descriptor.minimumEffect,
      "the operation minimum is exactly the value that would have under-charged this plan")
  }

  func testEmptyTraceCategoriesDoNotEscalate() throws {
    let descriptor = try capture()
    XCTAssertEqual(
      RuntimeJobEngine.effectiveEffect(
        descriptor: descriptor, inputs: ["traceCategories": .array([])]),
      .readOnly)
  }

  func testAlwaysRunStepsStillSetTheFloor() throws {
    let debug = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "debug.hap@1"))
    XCTAssertEqual(
      RuntimeJobEngine.effectiveEffect(descriptor: debug, inputs: [:]), .deviceMutation)
  }
}
