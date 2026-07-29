import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Walking-skeleton integration over a real child process: the descriptor-
/// bound dispatcher launches a fixture binary through the identity-verifying
/// executor, so the whole chain (client -> daemon -> engine -> provider ->
/// process -> semantic verify -> durable journal) runs for real. Only the
/// device itself is substituted; the hardware legs (BER-HW-001/002) remain
/// a maintainer device window.
final class ObserveDeviceSkeletonContractTests: XCTestCase {
  private var stateDirectory: URL!
  private var toolURL: URL!
  private var server: AgentDaemonServer?

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-skeleton-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    let fixture = productsDirectory.appendingPathComponent("ArkDeckFakeHDCFixture")
    guard FileManager.default.fileExists(atPath: fixture.path) else {
      throw XCTSkip("ArkDeckFakeHDCFixture binary not built")
    }
    toolURL = fixture
  }

  override func tearDownWithError() throws {
    server?.stop()
    server = nil
    if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
  }

  private struct StoreFactsPort: HDCObservationFactsPort {
    let store: RuntimeTargetStore
    func currentFacts(targetID: String) async throws -> ProviderFacts {
      guard let record = try store.find(targetID: targetID) else {
        throw DeviceProviderError.factsUnavailable("target \(targetID) not adopted")
      }
      return ProviderFacts(
        providerID: "hdc", toolVersion: record.toolVersion,
        toolSHA256: String(repeating: "a", count: 64), serverFacts: [:],
        targetID: record.targetID, bindingRevision: record.bindingRevision,
        deviceIdentitySHA256: record.stablePhysicalIdentitySHA256,
        executionConnectKey: record.connectKey, deviceMode: "hdc",
        buildFingerprint: nil, profileID: "openharmony-standard@1",
        collectedAtUTC: "2026-07-29T00:00:00Z")
    }
  }

  private func makeStack() throws -> (
    RuntimeControlPlaneHandler, RuntimeJobEngine, RuntimeTargetStore
  ) {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appendingPathComponent("capabilities", isDirectory: true))
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appendingPathComponent("targets", isDirectory: true))
    let resolver = try FixedExecutableResolver.hashing(
      path: toolURL.path, providerID: "hdc")
    let dispatcher = DescriptorBoundProcessDispatcher(resolver: resolver)
    let provider = HDCObservationProviderAdapter(
      factsPort: StoreFactsPort(store: targetStore))
    let providers = DeviceProviderRegistry(providers: [provider])
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory.appendingPathComponent("engine", isDirectory: true)),
      providers: providers, dispatcher: dispatcher, capabilityStore: capabilityStore,
      nowUTC: { "2026-07-29T00:00:00Z" })
    let bootstrap = DeviceBootstrapMachine(
      observation: ScriptedBootstrap(), targetStore: targetStore,
      nowUTC: { "2026-07-29T00:00:00Z" })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilityStore,
      providerIDs: providers.registeredProviderIDs, nowUTC: { "2026-07-29T00:00:00Z" },
      targetStore: targetStore, bootstrap: bootstrap)
    return (handler, engine, targetStore)
  }

  private struct ScriptedBootstrap: BootstrapObservationPort {
    func observeToolVersion() async throws -> String { "3.2.0f" }
    func listCandidates() async throws -> [BootstrapCandidate] {
      [BootstrapCandidate(connectKey: String(repeating: "a", count: 32), state: "Connected")]
    }
    func observeDeviceIdentity(connectKey: String) async throws -> [String: String] {
      ["serial": connectKey]
    }
  }

  private func observeRequestJSON(targetID: String, key: String = "idem-skeleton-01") -> String {
    """
    {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
    "requestId":"req-skeleton","idempotencyKey":"\(key)",\
    "target":{"targetId":"\(targetID)","expectedBindingRevision":1},\
    "operation":{"id":"observe.device","version":1}}
    """
  }

  // MARK: - BER-SKEL-001

  func testAdoptThenObserveRunsThroughRealProcessDispatch() async throws {
    let (handler, engine, targetStore) = try makeStack()
    // adopt via the control plane (bootstrap path)
    let adopt = await handler.handleFrame(
      Data("{\"protocolVersion\":\"1.0.0\",\"id\":\"a\",\"method\":\"target.adopt\"}".utf8))
    guard adopt.ok, case .object(let adoptFields)? = adopt.result,
      case .string(let outcome)? = adoptFields["outcome"], outcome == "adopted",
      case .string(let targetID)? = adoptFields["targetId"]
    else {
      return XCTFail("adopt must succeed: \(String(describing: adopt.error))")
    }
    XCTAssertEqual(try targetStore.list().count, 1)

    // submit + run observe.device@1 against the real fixture process
    let submit = await handler.handleFrame(
      Data(
        """
        {"protocolVersion":"1.0.0","id":"s","method":"job.submit","params":\
        {"requestJson":\(quoted(observeRequestJSON(targetID: targetID)))}}
        """.utf8))
    guard submit.ok, case .object(let submitFields)? = submit.result,
      case .string(let jobID)? = submitFields["jobId"]
    else {
      return XCTFail("submit must succeed: \(String(describing: submit.error))")
    }
    let status = try await engine.run(jobID: jobID)
    XCTAssertEqual(status.state, "succeeded", status.timeline.joined(separator: " | "))
    XCTAssertFalse(status.outcomeUnknown)
    XCTAssertTrue(status.timeline.contains("intent probe-host-tool"))
    XCTAssertTrue(
      status.timeline.contains { $0.hasPrefix("verified confirm-evidence-target") })

    // durable history survives a fresh engine over the same state
    let (_, reopened, _) = try makeStack()
    let recovered = try await reopened.recoverPersistedJobs()
    XCTAssertEqual(recovered.map(\.jobID), [jobID])
    XCTAssertEqual(recovered[0].state, "succeeded")
  }

  func testGovernanceFieldsAreRejectedAtTheDaemonBoundary() async throws {
    let (handler, _, targetStore) = try makeStack()
    _ = await handler.handleFrame(
      Data("{\"protocolVersion\":\"1.0.0\",\"id\":\"a\",\"method\":\"target.adopt\"}".utf8))
    let targetID = try XCTUnwrap(try targetStore.list().first?.targetID)
    let withGovernance = """
      {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
      "requestId":"req-gov","idempotencyKey":"idem-gov-0001","changeId":"CHG-2026-048",\
      "target":{"targetId":"\(targetID)"},\
      "operation":{"id":"observe.device","version":1}}
      """
    let response = await handler.handleFrame(
      Data(
        """
        {"protocolVersion":"1.0.0","id":"g","method":"job.submit","params":\
        {"requestJson":\(quoted(withGovernance))}}
        """.utf8))
    XCTAssertFalse(response.ok, "a runtime request carrying changeId must be rejected")
    XCTAssertTrue(
      (response.error?.message ?? "").contains("governance"),
      response.error?.message ?? "no message")
  }

  func testDescriptorDriftRefusesDispatch() async throws {
    let (_, _, targetStore) = try makeStack()
    // A resolver pinned to the wrong hash must make dispatch fail closed:
    // the executor rehashes the file itself, so a stale pin cannot launch.
    let wrongResolver = FixedExecutableResolver(
      table: [
        "hdc": ResolvedExecutable(path: toolURL.path, sha256: String(repeating: "0", count: 64))
      ])
    let dispatcher = DescriptorBoundProcessDispatcher(resolver: wrongResolver)
    let provider = HDCObservationProviderAdapter(factsPort: StoreFactsPort(store: targetStore))
    let plan = try provider.lower(
      action: .hdc(.observeTool),
      context: ProviderExecutionContext(
        jobID: "j", stepID: "s", targetID: "t", bindingRevision: nil,
        nowUTC: "2026-07-29T00:00:00Z"))
    do {
      _ = try await dispatcher.dispatch(plan)
      XCTFail("hash mismatch must refuse dispatch")
    } catch let failure as RuntimeDispatchFailure {
      guard case .failed(let reason) = failure else {
        return XCTFail("identity refusal is a definite failure, not unknown: \(failure)")
      }
      XCTAssertTrue(reason.contains("refused"), reason)
    }
  }

  func testHostManagedPlansAreRefusedByThisDispatcher() async throws {
    let resolver = try FixedExecutableResolver.hashing(path: toolURL.path, providerID: "rockchip")
    let dispatcher = DescriptorBoundProcessDispatcher(resolver: resolver)
    let rockchip = RockchipFlashProviderAdapter(executionPort: RefusingFlashPort())
    let plan = try rockchip.lower(
      action: .rockchip(.executeFlashPlan(authorizationID: "AUTH-1")),
      context: ProviderExecutionContext(
        jobID: "j", stepID: "s", targetID: "t", bindingRevision: nil,
        nowUTC: "2026-07-29T00:00:00Z"))
    do {
      _ = try await dispatcher.dispatch(plan)
      XCTFail("hostManaged plans must not run through the process dispatcher")
    } catch let failure as RuntimeDispatchFailure {
      guard case .failed = failure else {
        return XCTFail("expected a definite refusal, got \(failure)")
      }
    }
  }

  private struct RefusingFlashPort: RockchipFlashExecutionPort {
    func executeFlash(authorizationID: String) async throws -> (
      manifestID: String, succeeded: Bool, waitingForRecovery: Bool
    ) {
      throw RuntimeDispatchFailure.failed("tests never flash")
    }
  }

  private func quoted(_ value: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = (try? encoder.encode(value)) ?? Data("\"\"".utf8)
    return String(data: data, encoding: .utf8) ?? "\"\""
  }

  private var productsDirectory: URL {
    #if os(macOS)
      for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        return bundle.bundleURL.deletingLastPathComponent()
      }
    #endif
    return Bundle.main.bundleURL
  }
}
