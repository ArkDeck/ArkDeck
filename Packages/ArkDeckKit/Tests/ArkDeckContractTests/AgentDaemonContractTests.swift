import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class AgentDaemonContractTests: XCTestCase {
  private var stateDirectory: URL!
  private var server: AgentDaemonServer?

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-daemon-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
  }

  override func tearDownWithError() throws {
    server?.stop()
    server = nil
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

  private struct HappyDispatcher: RuntimeProcessDispatching {
    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      switch plan.action {
      case .hdc(.observeTool), .hdc(.observeServer):
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data("Ver: 3.2.0f\n".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      default:
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data("[Empty]\n".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      }
    }
  }

  private func makeStack() throws -> (RuntimeControlPlaneHandler, RuntimeJobEngine) {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appendingPathComponent("capabilities", isDirectory: true))
    let providers = DeviceProviderRegistry(providers: [
      HDCObservationProviderAdapter(factsPort: FactsPort())
    ])
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory.appendingPathComponent("engine", isDirectory: true)),
      providers: providers,
      dispatcher: HappyDispatcher(),
      capabilityStore: capabilityStore,
      nowUTC: { "2026-07-29T00:00:00Z" })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilityStore,
      providerIDs: providers.registeredProviderIDs,
      nowUTC: { "2026-07-29T00:00:00Z" })
    return (handler, engine)
  }

  private func startServer(_ handler: RuntimeControlPlaneHandler) throws -> AgentDaemonServer {
    let server = AgentDaemonServer(
      stateDirectory: stateDirectory, handler: handler, nowUTC: { "2026-07-29T00:00:00Z" })
    let result = try server.start()
    guard result == .started else {
      throw AgentDaemonError.io("expected fresh start, got \(result)")
    }
    self.server = server
    return server
  }

  // MARK: - Transport-free protocol negatives

  func testProtocolNegativesAreStructural() async throws {
    let (handler, _) = try makeStack()
    // Unknown major version.
    let wrongMajor = Data(
      """
      {"protocolVersion":"2.0.0","id":"1","method":"health"}
      """.utf8)
    let rejected = await handler.handleFrame(wrongMajor)
    XCTAssertFalse(rejected.ok)
    XCTAssertEqual(rejected.error?.code, "unsupportedProtocolVersion")
    // Unknown method.
    let unknownMethod = Data(
      """
      {"protocolVersion":"1.0.0","id":"2","method":"shell.exec"}
      """.utf8)
    let unknown = await handler.handleFrame(unknownMethod)
    XCTAssertFalse(unknown.ok)
    XCTAssertEqual(unknown.error?.code, "unknownMethod")
    // Malformed frame answers structurally instead of crashing.
    let malformed = await handler.handleFrame(Data("{not json".utf8))
    XCTAssertFalse(malformed.ok)
    XCTAssertEqual(malformed.error?.code, "malformedFrame")
    // Minor version drift is forward-compatible.
    let minor = Data(
      """
      {"protocolVersion":"1.7.3","id":"3","method":"health"}
      """.utf8)
    let ok = await handler.handleFrame(minor)
    XCTAssertTrue(ok.ok)
  }

  func testOperationSurfaceComesFromCatalog() async throws {
    let (handler, _) = try makeStack()
    let list = await handler.handleFrame(
      Data("{\"protocolVersion\":\"1.0.0\",\"id\":\"l\",\"method\":\"operation.list\"}".utf8))
    guard case .array(let values)? = list.result else {
      return XCTFail("operation.list must return an array")
    }
    XCTAssertEqual(values.count, RuntimeOperationCatalog.operations.count)
    let describe = await handler.handleFrame(
      Data(
        """
        {"protocolVersion":"1.0.0","id":"d","method":"operation.describe",
         "params":{"reference":"flash.dayu200@1"}}
        """.utf8))
    guard case .object(let fields)? = describe.result else {
      return XCTFail("describe must return an object")
    }
    XCTAssertEqual(fields["minimumEffect"], .string("destructive"))
    XCTAssertEqual(fields["provider"], .string("rockchip"))
  }

  func testTargetAdoptIsExplicitlyDeferredToMU3() async throws {
    let (handler, _) = try makeStack()
    let adopt = await handler.handleFrame(
      Data("{\"protocolVersion\":\"1.0.0\",\"id\":\"a\",\"method\":\"target.adopt\"}".utf8))
    XCTAssertFalse(adopt.ok)
    XCTAssertEqual(adopt.error?.code, "notImplementedUntilMU3")
  }

  // MARK: - UDS integration

  func testTwoConcurrentClientsShareOneDaemon() throws {
    let (handler, _) = try makeStack()
    let server = try startServer(handler)
    let clientA = AgentClient(socketPath: server.socketURL.path)
    let clientB = AgentClient(socketPath: server.socketURL.path)

    let group = DispatchGroup()
    var results: [JSONValue?] = [nil, nil]
    let lock = NSLock()
    for (index, client) in [clientA, clientB].enumerated() {
      group.enter()
      DispatchQueue.global().async {
        let value = try? client.request(method: "health")
        lock.lock()
        results[index] = value
        lock.unlock()
        group.leave()
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
    for value in results {
      guard case .object(let fields)? = value else {
        return XCTFail("both clients must get a health object")
      }
      XCTAssertEqual(fields["status"], .string("ok"))
      XCTAssertEqual(
        fields["catalogDigest"], .string(RuntimeOperationCatalog.catalogDigest))
    }
  }

  func testSocketIsUserPrivateAndZeroNetwork() throws {
    let (handler, _) = try makeStack()
    let server = try startServer(handler)
    var directoryStat = stat()
    XCTAssertEqual(stat(stateDirectory.path, &directoryStat), 0)
    XCTAssertEqual(directoryStat.st_mode & 0o777, 0o700, "state directory must be 0700")
    var socketStat = stat()
    XCTAssertEqual(stat(server.socketURL.path, &socketStat), 0)
    XCTAssertEqual(socketStat.st_mode & 0o777, 0o600, "socket must be 0600")
    XCTAssertEqual(socketStat.st_mode & S_IFMT, S_IFSOCK)
  }

  func testSecondInstanceReturnsExistingInfo() throws {
    let (handler, _) = try makeStack()
    let first = try startServer(handler)
    let second = AgentDaemonServer(
      stateDirectory: stateDirectory, handler: handler, nowUTC: { "2026-07-29T00:01:00Z" })
    let result = try second.start()
    guard case .alreadyRunning(let instance) = result else {
      return XCTFail("second start must report the existing instance, got \(result)")
    }
    XCTAssertEqual(instance.pid, getpid())
    XCTAssertEqual(instance.socketPath, first.socketURL.path)
    XCTAssertEqual(instance.protocolVersion, AgentWireProtocol.version)
  }

  func testJobHistorySurvivesDaemonRestart() async throws {
    let (handler, _) = try makeStack()
    let server = try startServer(handler)
    let client = AgentClient(socketPath: server.socketURL.path)
    let request = """
      {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
      "requestId":"req-restart","idempotencyKey":"idem-restart-01",\
      "target":{"targetId":"TGT-RESTART-01"},\
      "operation":{"id":"observe.device","version":1}}
      """
    guard
      case .object(let submitFields) = try client.request(
        method: "job.submit", params: ["requestJson": .string(request)]),
      case .string(let jobID)? = submitFields["jobId"]
    else {
      return XCTFail("submit must return a job id")
    }
    guard
      case .object(let runFields) = try client.request(
        method: "job.run", params: ["jobId": .string(jobID)]),
      case .string(let state)? = runFields["state"]
    else {
      return XCTFail("run must return a status")
    }
    XCTAssertEqual(state, "succeeded")
    server.stop()
    self.server = nil

    // A fresh daemon over the same state directory recovers the history.
    let (freshHandler, freshEngine) = try makeStack()
    let recovered = try await freshEngine.recoverPersistedJobs()
    XCTAssertEqual(recovered.map(\.jobID), [jobID])
    XCTAssertEqual(recovered[0].state, "succeeded")
    let freshServer = try startServer(freshHandler)
    let freshClient = AgentClient(socketPath: freshServer.socketURL.path)
    guard
      case .object(let statusFields) = try freshClient.request(
        method: "job.status", params: ["jobId": .string(jobID)]),
      case .string(let recoveredState)? = statusFields["state"]
    else {
      return XCTFail("status must survive restart")
    }
    XCTAssertEqual(recoveredState, "succeeded")
  }

  func testWireProtocolCarriesNoArgvSurface() async throws {
    // The strongest injection defense is structural: the entire protocol
    // vocabulary is JSON strings routed to closed methods; assert the
    // daemon rejects a hypothetical raw-command method rather than
    // executing anything.
    let (handler, _) = try makeStack()
    for method in ["shell", "exec", "runHDC", "process.spawn"] {
      let response = await handler.handleFrame(
        Data("{\"protocolVersion\":\"1.0.0\",\"id\":\"x\",\"method\":\"\(method)\"}".utf8))
      XCTAssertFalse(response.ok, method)
      XCTAssertEqual(response.error?.code, "unknownMethod", method)
    }
  }


}
