import XCTest
import CryptoKit

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
        targetID: targetID, bindingRevision: 7,
        deviceIdentitySHA256:
          "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1",
        executionConnectKey: "150100424a544e4600",
        deviceMode: nil, buildFingerprint: nil,
        profileID: "openharmony-standard@1", collectedAtUTC: "2026-07-29T00:00:00Z")
    }
  }

  private struct HappyDispatcher: RuntimeProcessDispatching {
    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      switch plan.action {
      case .hdc(.observeTool):
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data("Ver: 3.2.0f\n".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      case .hdc(.observeServer):
        // checkserver has its own shape; a fake that returned the `-v`
        // shape here is what let the real defect through to hardware.
        return ProviderProcessReceipt(
          exitStatus: 0,
          stdout: Data("Client version:Ver: 3.2.0f, server version:Ver: 3.2.0f\n".utf8),
          stderr: Data(), stdoutTruncated: false, durationSeconds: 0.01)
      case .hdc(.observeDevice), .hdc(.listDeviceCandidates):
        return ProviderProcessReceipt(
          exitStatus: 0,
          stdout: Data("150100424a544e4600\t\tUSB\tConnected\tlocalhost\n".utf8),
          stderr: Data(), stdoutTruncated: false, durationSeconds: 0.01)
      case .hdc(.queryProperty(.productModel)):
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data("DAYU200\n".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      case .hdc(.queryProperty(.fullBuildVersion)):
        return ProviderProcessReceipt(
          exitStatus: 0, stdout: Data("OpenHarmony-4.1-release\n".utf8), stderr: Data(),
          stdoutTruncated: false, durationSeconds: 0.01)
      default:
        throw RuntimeDispatchFailure.failed("unexpected action")
      }
    }
  }

  private func makeStack(
    targetStore: RuntimeTargetStore? = nil,
    artifactStore: RuntimeArtifactStore? = nil
  ) throws -> (RuntimeControlPlaneHandler, RuntimeJobEngine) {
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
      artifactStore: artifactStore,
      nowUTC: { "2026-07-29T00:00:00Z" })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilityStore,
      providerIDs: providers.registeredProviderIDs,
      nowUTC: { "2026-07-29T00:00:00Z" },
      targetStore: targetStore,
      artifactStore: artifactStore)
    return (handler, engine)
  }

  private func request(
    _ handler: RuntimeControlPlaneHandler,
    method: String,
    params: [String: JSONValue]? = nil
  ) async throws -> AgentWireProtocol.Response {
    let frame = try JSONEncoder().encode(
      AgentWireProtocol.Request(id: UUID().uuidString, method: method, params: params))
    return await handler.handleFrame(frame)
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
    let rows = values.compactMap { value -> [String: JSONValue]? in
      guard case .object(let row) = value else { return nil }
      return row
    }
    XCTAssertEqual(rows.count, values.count, "every operation must carry runtime availability")
    let observe = rows.first { $0["reference"] == .string("observe.device@1") }
    XCTAssertEqual(observe?["availability"], .string("available"))
    XCTAssertEqual(observe?["reasons"], .array([]))
    let flash = rows.first { $0["reference"] == .string("flash.dayu200@1") }
    XCTAssertEqual(flash?["availability"], .string("unavailable"))
    guard case .array(let flashReasons)? = flash?["reasons"] else {
      return XCTFail("unavailable operation must explain why")
    }
    XCTAssertTrue(
      flashReasons.contains { value in
        guard case .string(let reason) = value else { return false }
        return reason.contains("rockchip") && reason.contains("not registered")
      })
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
    XCTAssertEqual(fields["availability"], .string("unavailable"))
    guard case .array(let reasons)? = fields["availabilityReasons"] else {
      return XCTFail("describe must include availability reasons")
    }
    XCTAssertFalse(reasons.isEmpty)
  }

  func testCapabilityDraftMaterializesExactPlanButCannotInstallBeforeMergedPR() async throws {
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appendingPathComponent("artifacts", isDirectory: true),
      nowUTC: { "2026-07-29T00:00:00Z" })
    let artifact = try await artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "input-hap-target-001", sessionID: "session-input-hap-target-001",
        stepID: "import-hap", name: "demo.hap",
        mediaType: "application/vnd.openharmony.hap",
        privacy: .standard, retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-hap", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-001", bindingRevision: 7,
          stableIdentitySHA256:
            "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1"),
        contents: Data("PK\u{03}\u{04}signed-hap".utf8)))
    let lease = try await artifactStore.leaseReference(
      jobID: artifact.jobID, artifactID: artifact.artifactID)
    let (handler, engine) = try makeStack(artifactStore: artifactStore)
    let operationRequest = try RuntimeOperationRequest(
      requestID: "agent-request-capability-draft-001",
      idempotencyKey: "agent-execution-capability-draft-001",
      target: DurableTargetReference(targetID: "TGT-001", expectedBindingRevision: 7),
      operation: RuntimeOperationReference(id: "debug.hap", version: 1),
      inputs: [
        "hapArtifactLease": .string(lease),
        "bundleName": .string("com.example.demo"),
        "abilityName": .string("EntryAbility"),
        "installPolicy": .string("installOrReplace"),
        "cleanupPolicy": .string("uninstall"),
        "captureDiagnostics": .bool(true),
        "diagnosticsDurationSeconds": .integer(5),
        "portForwardProfile": .string("none"),
      ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let operationData = try encoder.encode(operationRequest)
    let operationJSON = try XCTUnwrap(String(data: operationData, encoding: .utf8))
    let drafted = try await request(
      handler, method: "capability.draft",
      params: [
        "requestJson": .string(operationJSON),
        "validitySeconds": .integer(3_600),
        "maximumUses": .integer(3),
      ])
    XCTAssertTrue(drafted.ok, drafted.error?.message ?? "-")
    guard case .object(let draft)? = drafted.result,
      case .object(let capabilityFields)? = draft["capability"],
      case .string(let capabilityID)? = capabilityFields["capabilityID"],
      case .string(let planDigest)? = draft["materializedPlanDigest"],
      case .string(let requestFingerprint)? = draft["requestFingerprintSHA256"]
    else {
      return XCTFail("capability.draft must return the exact review payload")
    }
    XCTAssertTrue(capabilityID.hasPrefix("CAP-RT-AUTO-"))
    XCTAssertEqual(planDigest.count, 64)
    XCTAssertEqual(requestFingerprint.count, 64)
    XCTAssertEqual(draft["bindingRevision"], .integer(7))
    XCTAssertEqual(capabilityFields["exactPlanDigest"], .string(planDigest))
    XCTAssertEqual(capabilityFields["exactBindingRevision"], .integer(7))
    XCTAssertEqual(capabilityFields["maximumUses"], .integer(3))
    XCTAssertEqual(
      draft["stableIdentitySHA256"],
      .string("83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1"))
    let jobsAfterDraft = await engine.listJobs()
    XCTAssertTrue(jobsAfterDraft.isEmpty, "drafting must not admit a Job")

    let capabilityData = try encoder.encode(JSONValue.object(capabilityFields))
    let capabilityJSON = try XCTUnwrap(String(data: capabilityData, encoding: .utf8))
    let pendingInstall = try await request(
      handler, method: "capability.install",
      params: ["capabilityJson": .string(capabilityJSON)])
    XCTAssertFalse(pendingInstall.ok)
    XCTAssertEqual(pendingInstall.error?.code, "invalidParams")
    XCTAssertTrue(
      (pendingInstall.error?.message ?? "").contains("maintainer-merged PR"))

    let pending = try JSONDecoder().decode(RuntimeCapability.self, from: capabilityData)
    let approved = try RuntimeCapability(
      capabilityID: pending.capabilityID,
      targetScope: pending.targetScope,
      operationScope: pending.operationScope,
      effectCeiling: pending.effectCeiling,
      inputConstraints: pending.inputConstraints,
      issuedAtUTC: pending.issuedAtUTC,
      expiresAtUTC: pending.expiresAtUTC,
      maximumUses: pending.maximumUses,
      issuer: RuntimeCapabilityIssuer(kind: .maintainerMergedPR, reference: "PR#830"),
      exactPlanDigest: pending.exactPlanDigest,
      exactBindingRevision: pending.exactBindingRevision,
      revocation: pending.revocation)
    let approvedData = try encoder.encode(approved)
    let approvedJSON = try XCTUnwrap(String(data: approvedData, encoding: .utf8))
    let installed = try await request(
      handler, method: "capability.install",
      params: ["capabilityJson": .string(approvedJSON)])
    XCTAssertTrue(installed.ok, installed.error?.message ?? "-")
    let statuses = try await request(handler, method: "capability.list")
    guard case .array(let values)? = statuses.result,
      case .object(let status)? = values.first
    else {
      return XCTFail("approved capability must become listable")
    }
    XCTAssertEqual(status["capabilityId"], .string(capabilityID))
    XCTAssertEqual(status["maximumUses"], .integer(3))
    XCTAssertEqual(status["remainingUses"], .integer(3))
    XCTAssertEqual(status["lineageAllowsNewExecution"], .bool(true))
    let inspected = try await request(
      handler, method: "capability.inspect",
      params: ["capabilityId": .string(capabilityID)])
    guard case .object(let inspectedFields)? = inspected.result,
      case .array(let inspectedLineage)? = inspectedFields["lineage"]
    else {
      return XCTFail("capability.inspect must return the durable envelope and lineage")
    }
    XCTAssertEqual(inspectedFields["remainingUses"], .integer(3))
    XCTAssertTrue(inspectedLineage.isEmpty)

    // The Agent surface intentionally omits fields that decode to request
    // defaults. Its semantically identical request must still derive the
    // exact plan that the draft showed to the maintainer.
    let agentShapedRequest = JSONValue.object([
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("2.0.0"),
      "requestId": .string(operationRequest.requestID),
      "idempotencyKey": .string(operationRequest.idempotencyKey),
      "target": .object([
        "targetId": .string("TGT-001"),
        "expectedBindingRevision": .integer(7),
      ]),
      "operation": .object([
        "id": .string("debug.hap"),
        "version": .integer(1),
      ]),
      "inputs": .object(operationRequest.inputs),
      "authorization": .object(["capabilityId": .string(capabilityID)]),
    ])
    let accepted = try await engine.submit(encoder.encode(agentShapedRequest))
    let recordData = try Data(
      contentsOf: stateDirectory.appendingPathComponent(
        "engine/jobs/\(accepted.jobID)/job-record.json"))
    let record = try JSONDecoder().decode(RuntimeJobRecord.self, from: recordData)
    XCTAssertEqual(record.materializedPlanDigest, planDigest)
    XCTAssertEqual(record.materializedBindingRevision, 7)
  }

  /// MU-3 (CHG-2026-048) implemented adoption; this composition still
  /// omits the bootstrap machine, so adoption must fail closed rather than
  /// silently succeed with no target store behind it.
  func testTargetAdoptFailsClosedWithoutBootstrapComposition() async throws {
    let (handler, _) = try makeStack()
    let adopt = await handler.handleFrame(
      Data("{\"protocolVersion\":\"1.0.0\",\"id\":\"a\",\"method\":\"target.adopt\"}".utf8))
    XCTAssertFalse(adopt.ok)
    XCTAssertEqual(adopt.error?.code, "internalError")
    XCTAssertTrue(
      (adopt.error?.message ?? "").contains("bootstrap"),
      "the refusal must name the missing composition: \(adopt.error?.message ?? "-")")
    // target.list is equally unavailable without a store - never an empty
    // list, which would read as "no devices adopted".
    let list = await handler.handleFrame(
      Data("{\"protocolVersion\":\"1.0.0\",\"id\":\"l\",\"method\":\"target.list\"}".utf8))
    XCTAssertFalse(list.ok)
    XCTAssertEqual(list.error?.code, "internalError")
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

  /// Found by self-testing the device-window plan: a deep state directory
  /// pushed the socket past Darwin's 104-byte sun_path limit and the error
  /// said only "too long". The limit is a platform fact; the actionable
  /// message is the contract.
  func testOverlongSocketPathFailsWithAnActionableMessage() throws {
    let (handler, _) = try makeStack()
    let deep = stateDirectory.appendingPathComponent(
      String(repeating: "d", count: 120), isDirectory: true)
    let server = AgentDaemonServer(
      stateDirectory: deep, handler: handler, nowUTC: { "2026-07-29T00:00:00Z" })
    do {
      _ = try server.start()
      XCTFail("an overlong socket path must fail closed")
    } catch let error as AgentDaemonError {
      guard case .io(let message) = error else { return XCTFail("unexpected \(error)") }
      XCTAssertTrue(message.contains("platform limit"), message)
      XCTAssertTrue(message.contains("--state-dir"), "the fix must be named: \(message)")
    }
    let client = AgentClient(socketPath: deep.appendingPathComponent("agentd.sock").path)
    do {
      _ = try client.request(method: "health")
      XCTFail("client must refuse an overlong socket path too")
    } catch let error as AgentClientError {
      guard case .connectFailed(let message) = error else {
        return XCTFail("unexpected \(error)")
      }
      XCTAssertTrue(message.contains("platform limit"), message)
    }
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

  /// Process-level: the in-process server tests all passed while the real
  /// arkdeck-agentd binary died the instant it printed "listening" -
  /// `dispatchMain()` pthread_exits the main thread out from under an
  /// async top level. Only running the actual binary catches that class of
  /// defect, so this test spawns it and talks to it over the socket.
  func testDaemonBinaryStaysAliveAndServesRequests() throws {
    let binary = productsDirectory.appendingPathComponent("arkdeck-agentd")
    guard FileManager.default.fileExists(atPath: binary.path) else {
      throw XCTSkip("arkdeck-agentd binary not built")
    }
    // Short path: sun_path is 104 bytes, and the default temp directory
    // plus a UUID already crowds it.
    let shortState = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".arkdeck-test-\(UInt32.random(in: 0..<100_000))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: shortState) }

    let process = Process()
    process.executableURL = binary
    process.arguments = ["--state-dir", shortState.path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    defer {
      if process.isRunning { process.terminate() }
    }

    let socketURL = shortState.appendingPathComponent("agentd.sock")
    let deadline = Date().addingTimeInterval(20)
    while !FileManager.default.fileExists(atPath: socketURL.path) {
      guard Date() < deadline, process.isRunning else { break }
      usleep(50_000)
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: socketURL.path), "daemon never created its socket")

    // The defect signature: alive at socket creation, dead a moment later.
    usleep(500_000)
    XCTAssertTrue(process.isRunning, "daemon exited right after announcing itself")

    let client = AgentClient(socketPath: socketURL.path)
    guard case .object(let health) = try client.request(method: "health") else {
      return XCTFail("health must answer from the real binary")
    }
    XCTAssertEqual(health["status"], .string("ok"))

    process.terminate()
    let stopDeadline = Date().addingTimeInterval(10)
    while process.isRunning && Date() < stopDeadline { usleep(50_000) }
    XCTAssertFalse(process.isRunning, "SIGTERM must stop the daemon")
    // "It stopped" was too weak an assertion: the first device window
    // showed the daemon dying on SIGTRAP (exit 133) because a signal
    // arriving while the async main task was suspended trapped the
    // concurrency runtime before any handler ran. Shutdown must be a
    // clean exit(0), not a crash.
    XCTAssertEqual(
      process.terminationReason, .exit,
      "SIGTERM must be a clean shutdown, not a signal death")
    XCTAssertEqual(process.terminationStatus, 0, "clean shutdown exits zero")
  }

  private var productsDirectory: URL {
    #if os(macOS)
      for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        return bundle.bundleURL.deletingLastPathComponent()
      }
    #endif
    return Bundle.main.bundleURL
  }

  func testJobHistorySurvivesDaemonRestart() async throws {
    let (handler, _) = try makeStack()
    let server = try startServer(handler)
    let client = AgentClient(socketPath: server.socketURL.path)
    let request = """
      {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
      "requestId":"req-restart","idempotencyKey":"idem-restart-01",\
      "target":{"targetId":"TGT-RESTART-01","expectedBindingRevision":7},\
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

  /// Artifact identity is ID-only by construction. Export accepts only a
  /// destination directory; no caller path can substitute the stored source.
  /// A store-less composition
  /// refuses rather than answering with an empty list (which would read as
  /// "this job produced nothing").
  func testArtifactMethodsAreIDOnlyAndFailClosedWithoutAStore() async throws {
    let (handler, _) = try makeStack()
    for method in [
      "artifact.importHap.begin", "artifact.importHap.append",
      "artifact.importHap.commit", "artifact.list", "artifact.inspect",
      "artifact.read", "artifact.export",
    ] {
      let response = await handler.handleFrame(
        Data(
          """
          {"protocolVersion":"1.0.0","id":"a","method":"\(method)",          "params":{"jobId":"job-1","artifactId":"ART-1"}}
          """.utf8))
      XCTAssertFalse(response.ok, method)
      XCTAssertEqual(response.error?.code, "internalError", method)
      XCTAssertTrue(
        (response.error?.message ?? "").contains("artifact store"),
        response.error?.message ?? "-")
    }
    // Missing identifiers are refused rather than defaulted.
    let noJob = await handler.handleFrame(
      Data("{\"protocolVersion\":\"1.0.0\",\"id\":\"b\",\"method\":\"artifact.list\"}".utf8))
    XCTAssertFalse(noJob.ok)
  }

  func testChunkedHAPImportPublishesATargetBoundIDOnlyLease() async throws {
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appendingPathComponent("targets", isDirectory: true))
    let stableIdentity = String(repeating: "a", count: 64)
    let target = try targetStore.adopt(
      stableIdentitySHA256: stableIdentity,
      connectKey: "150100424a544e4600",
      toolVersion: "3.2.0f",
      nowUTC: "2026-07-29T00:00:00Z").record
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appendingPathComponent("artifacts", isDirectory: true),
      nowUTC: { "2026-07-29T00:00:00Z" })
    let (handler, _) = try makeStack(
      targetStore: targetStore, artifactStore: artifactStore)
    let hap = Data([0x50, 0x4b, 0x03, 0x04]) + Data(repeating: 0x41, count: 700_000)
    let digest = SHA256.hash(data: hap)
      .map { String(format: "%02x", $0) }.joined()

    let begin = try await request(
      handler,
      method: "artifact.importHap.begin",
      params: [
        "targetId": .string(target.targetID),
        "name": .string("entry-default-signed.hap"),
        "byteCount": .integer(Int64(hap.count)),
        "sha256": .string(digest),
      ])
    XCTAssertTrue(begin.ok, begin.error?.message ?? "-")
    guard case .object(let beginFields)? = begin.result,
      case .string(let uploadID)? = beginFields["uploadId"]
    else {
      return XCTFail("begin must return an upload identity")
    }

    let boundary = 400_000
    for (offset, bytes) in [
      (0, hap.subdata(in: 0..<boundary)),
      (boundary, hap.subdata(in: boundary..<hap.count)),
    ] {
      let append = try await request(
        handler,
        method: "artifact.importHap.append",
        params: [
          "uploadId": .string(uploadID),
          "offset": .integer(Int64(offset)),
          "base64": .string(bytes.base64EncodedString()),
        ])
      XCTAssertTrue(append.ok, append.error?.message ?? "-")
    }

    let commit = try await request(
      handler,
      method: "artifact.importHap.commit",
      params: ["uploadId": .string(uploadID)])
    XCTAssertTrue(commit.ok, commit.error?.message ?? "-")
    guard case .object(let fields)? = commit.result,
      case .string(let jobID)? = fields["jobId"],
      case .string(let artifactID)? = fields["artifactId"],
      case .string(let lease)? = fields["lease"],
      case .string(let returnedDigest)? = fields["sha256"],
      case .string(let returnedTarget)? = fields["targetId"],
      case .integer(let returnedRevision)? = fields["bindingRevision"]
    else {
      return XCTFail("commit must return the Artifact identity and lease")
    }
    XCTAssertEqual(returnedDigest, digest)
    XCTAssertEqual(returnedTarget, target.targetID)
    XCTAssertEqual(returnedRevision, Int64(target.bindingRevision))
    XCTAssertEqual(lease, "lease-v1:\(jobID):\(artifactID)")
    XCTAssertFalse(lease.contains(stateDirectory.path))

    let metadata = try await artifactStore.inspect(
      jobID: jobID, artifactID: artifactID)
    XCTAssertEqual(metadata.bindingSnapshot.targetID, target.targetID)
    XCTAssertEqual(metadata.bindingSnapshot.bindingRevision, target.bindingRevision)
    XCTAssertEqual(metadata.bindingSnapshot.stableIdentitySHA256, stableIdentity)
    XCTAssertEqual(metadata.mediaType, "application/vnd.openharmony.hap")
    let resolution = try await artifactStore.resolveLease(lease)
    XCTAssertEqual(resolution.sha256, digest)
    XCTAssertEqual(resolution.byteCount, hap.count)
    XCTAssertEqual(try Data(contentsOf: resolution.fileURL), hap)

    let inspect = try await request(
      handler,
      method: "artifact.inspect",
      params: ["jobId": .string(jobID), "artifactId": .string(artifactID)])
    guard case .object(let inspectFields)? = inspect.result else {
      return XCTFail("Artifact inspection must return durable binding metadata")
    }
    XCTAssertEqual(inspectFields["jobId"], .string(jobID))
    XCTAssertEqual(inspectFields["targetId"], .string(target.targetID))
    XCTAssertEqual(
      inspectFields["bindingRevision"], .integer(Int64(target.bindingRevision)))
    XCTAssertEqual(inspectFields["stableIdentitySha256"], .string(stableIdentity))
  }

  func testHAPImportRejectsUnknownTargetAndInvalidContainerWithoutPublication() async throws {
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appendingPathComponent("targets", isDirectory: true))
    let target = try targetStore.adopt(
      stableIdentitySHA256: String(repeating: "b", count: 64),
      connectKey: "150100424a544e4600",
      toolVersion: "3.2.0f",
      nowUTC: "2026-07-29T00:00:00Z").record
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appendingPathComponent("artifacts", isDirectory: true),
      nowUTC: { "2026-07-29T00:00:00Z" })
    let (handler, _) = try makeStack(
      targetStore: targetStore, artifactStore: artifactStore)
    let bytes = Data("not-a-hap".utf8)
    let digest = SHA256.hash(data: bytes)
      .map { String(format: "%02x", $0) }.joined()

    let unknown = try await request(
      handler,
      method: "artifact.importHap.begin",
      params: [
        "targetId": .string("TGT-unknown"),
        "name": .string("bad.hap"),
        "byteCount": .integer(Int64(bytes.count)),
        "sha256": .string(digest),
      ])
    XCTAssertFalse(unknown.ok)
    XCTAssertEqual(unknown.error?.code, "notFound")

    let begin = try await request(
      handler,
      method: "artifact.importHap.begin",
      params: [
        "targetId": .string(target.targetID),
        "name": .string("bad.hap"),
        "byteCount": .integer(Int64(bytes.count)),
        "sha256": .string(digest),
      ])
    guard case .object(let beginFields)? = begin.result,
      case .string(let uploadID)? = beginFields["uploadId"]
    else {
      return XCTFail("begin must return an upload identity")
    }
    let append = try await request(
      handler,
      method: "artifact.importHap.append",
      params: [
        "uploadId": .string(uploadID),
        "offset": .integer(0),
        "base64": .string(bytes.base64EncodedString()),
      ])
    XCTAssertTrue(append.ok)
    let commit = try await request(
      handler,
      method: "artifact.importHap.commit",
      params: ["uploadId": .string(uploadID)])
    XCTAssertFalse(commit.ok)
    XCTAssertEqual(commit.error?.code, "rejected")
    XCTAssertTrue((commit.error?.message ?? "").contains("ZIP-based"))

    let expectedJob =
      "input-hap-\(target.targetID)-r\(target.bindingRevision)-"
      + String(digest.prefix(16))
    let artifacts = try await artifactStore.list(jobID: expectedJob)
    XCTAssertTrue(artifacts.isEmpty)
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
