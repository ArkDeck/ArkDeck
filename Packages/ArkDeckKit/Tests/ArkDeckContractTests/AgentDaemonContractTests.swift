import CryptoKit
import Darwin
import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Anti-hang bound for the daemon fixtures that hand real work to another
/// thread and wait for it to arrive somewhere. It is not a contract bound: the
/// assertions around each wait decide the outcome, and an expired wait reports
/// only that the host never got there.
///
/// The five seconds this replaced sat inside the noise of a saturated
/// `swift test --parallel --num-workers 4` run. The graceful-drain fixture
/// takes 0.98 s on an idle host and 2.4–7.1 s under host load, and it failed
/// on CI as well as in a full local parallel run while passing in isolation.
/// This is set far above any stall observed there and still fails a genuine
/// deadlock well inside one test.
private let daemonRendezvousTimeout: TimeInterval = 60

/// A one-shot gate an `async` dispatcher can park on until a fixture opens it.
/// Waiting suspends the calling task instead of blocking a cooperative-pool
/// thread, which an `async` function must never do.
private final class DispatchGate: @unchecked Sendable {
  private let mutex = NSLock()
  private var isOpen = false
  private var parked: [CheckedContinuation<Void, Never>] = []

  func open() {
    mutex.lock()
    guard !isOpen else { return mutex.unlock() }
    isOpen = true
    let resumed = parked
    parked = []
    mutex.unlock()
    for continuation in resumed { continuation.resume() }
  }

  func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      mutex.lock()
      if isOpen {
        mutex.unlock()
        continuation.resume()
      } else {
        parked.append(continuation)
        mutex.unlock()
      }
    }
  }
}

private func availableDaemonLoopbackPort() throws -> UInt16 {
  let descriptor = socket(AF_INET, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
  defer { close(descriptor) }
  var address = sockaddr_in(
    sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
    sin_family: sa_family_t(AF_INET), sin_port: 0,
    sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
    sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
  let bound = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  let named = withUnsafeMutablePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      getsockname(descriptor, $0, &length)
    }
  }
  guard named == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
  return UInt16(bigEndian: address.sin_port)
}

final class AgentDaemonContractTests: XCTestCase {
  private var stateDirectory: URL!
  private var server: AgentDaemonServer?

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-daemon-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
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

  private struct FailingDispatcher: RuntimeProcessDispatching {
    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      throw RuntimeDispatchFailure.failed("fixture detail that clients must not classify")
    }
  }

  /// Holds every dispatch until the fixture releases it, and announces each
  /// arrival. This replaced a fixed 150 ms sleep per dispatch: the sleep both
  /// left the "is the request still in flight?" question to a wall-clock bet
  /// and charged the drain budget ~750 ms of invented latency, one sleep per
  /// dispatch `observe.device` makes.
  private final class GatedDispatcher: RuntimeProcessDispatching, @unchecked Sendable {
    let dispatchArrived = DispatchSemaphore(value: 0)
    private let gate = DispatchGate()

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      dispatchArrived.signal()
      await gate.wait()
      return try await HappyDispatcher().dispatch(plan)
    }

    /// Let the parked dispatch — and every later one — through.
    func release() { gate.open() }
  }

  private final class ProgressGatedDispatcher: RuntimeProcessDispatching, @unchecked Sendable {
    let dispatchArrived = DispatchSemaphore(value: 0)
    private let gate = DispatchGate()

    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      dispatchArrived.signal()
      await gate.wait()
      return try await HappyDispatcher().dispatch(plan)
    }

    func dispatch(
      _ plan: TypedProcessPlan,
      progress: @escaping RuntimeProcessProgressHandler
    ) async throws -> ProviderProcessReceipt {
      await progress(
        RuntimeProcessProgress(
          phase: .writing,
          unitName: "system",
          completedUnitCount: 4,
          totalUnitCount: 9,
          currentUnitPercent: 35))
      return try await dispatch(plan)
    }

    func release() { gate.open() }
  }

  /// Wait for `semaphore` without blocking a cooperative-pool thread: the
  /// block happens on a Dispatch worker while the test task suspends.
  private func waitForSemaphore(
    _ semaphore: DispatchSemaphore, timeout: TimeInterval
  ) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: semaphore.wait(timeout: .now() + timeout))
      }
    }
  }

  private func makeStack(
    targetStore: RuntimeTargetStore? = nil,
    artifactStore: RuntimeArtifactStore? = nil,
    includeDefaultArtifactStore: Bool = true,
    flashBundleImportPolicy: FlashBundleImportPolicy = .production,
    flashPrerequisiteObserver: (any RockchipFlashPrerequisiteObserving)? = nil,
    flashLanePlanPreviewer: (any FlashLanePlanPreviewing)? = nil,
    rockchipBootloaderStatusObserver: (any RockchipBootloaderStatusObserving)? = nil,
    rockchipLoaderBindingCoordinator: (any RockchipLoaderBindingCoordinating)? = nil,
    hdcRuntimeDiagnostics: HDCManagedRuntimeDiagnostics? = nil,
    dispatcher: any RuntimeProcessDispatching = HappyDispatcher()
  ) throws -> (RuntimeControlPlaneHandler, RuntimeJobEngine) {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appending(path: "capabilities", directoryHint: .isDirectory))
    let resolvedArtifactStore: RuntimeArtifactStore?
    if let artifactStore {
      resolvedArtifactStore = artifactStore
    } else if includeDefaultArtifactStore {
      resolvedArtifactStore = try RuntimeArtifactStore(
        rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
        nowUTC: { "2026-07-29T00:00:00Z" })
    } else {
      resolvedArtifactStore = nil
    }
    let providers = DeviceProviderRegistry(providers: [
      HDCObservationProviderAdapter(factsPort: FactsPort())
    ])
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory.appending(path: "engine", directoryHint: .isDirectory)),
      providers: providers,
      dispatcher: dispatcher,
      capabilityStore: capabilityStore,
      artifactStore: resolvedArtifactStore,
      nowUTC: { "2026-07-29T00:00:00Z" })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilityStore,
      providerIDs: providers.registeredProviderIDs,
      nowUTC: { "2026-07-29T00:00:00Z" },
      targetStore: targetStore,
      bootstrap: nil,
      hdcRuntimeDiagnostics: hdcRuntimeDiagnostics,
      artifactStore: resolvedArtifactStore,
      flashBundleImportDirectory: stateDirectory.appending(
        path:
          "flash-bundle-imports-\(UUID().uuidString)", directoryHint: .isDirectory),
      flashBundleImportPolicy: flashBundleImportPolicy,
      flashPrerequisiteObserver: flashPrerequisiteObserver,
      flashLanePlanPreviewer: flashLanePlanPreviewer,
      rockchipBootloaderStatusObserver: rockchipBootloaderStatusObserver,
      rockchipLoaderBindingCoordinator: rockchipLoaderBindingCoordinator,
      methodObserver: nil)
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

  // MARK: - Doctor publishes what the first request needs

  /// A caller with no prior context starts at `doctor`, and the envelope
  /// contract was the one thing it was about to need and could not ask for.
  ///
  /// The assertion is deliberately not "equals 2.0.0" and not "equals the
  /// constant the handler read" — either would pass while admission enforced
  /// something else entirely. Instead a request built with exactly the
  /// advertised version has to survive the real decode path, and the adjacent
  /// major has to be refused by it. That is what makes the advertised string a
  /// fact about admission rather than a number the report happens to carry.
  func testDoctorPublishesTheRequestEnvelopeAdmissionActuallyEnforces() async throws {
    let (handler, _) = try makeStack()
    let doctor = try await request(handler, method: "doctor")
    XCTAssertTrue(doctor.ok, doctor.error?.message ?? "-")
    guard case .object(let report)? = doctor.result,
      case .string(let advertised)? = report["runtimeRequestSchemaVersion"],
      case .integer(let operationCount)? = report["operationCount"]
    else {
      return XCTFail("doctor must publish the request envelope and the catalog size")
    }

    let accepted = try RuntimeOperationCodec.decodeRequest(
      envelopeProbe(schemaVersion: advertised))
    XCTAssertEqual(accepted.operation.reference, "observe.device@1")

    let advertisedMajor = Int(advertised.split(separator: ".").first.map(String.init) ?? "")
    let neighbouringMajor = "\((try XCTUnwrap(advertisedMajor)) + 1).0.0"
    XCTAssertThrowsError(
      try RuntimeOperationCodec.decodeRequest(
        envelopeProbe(schemaVersion: neighbouringMajor))
    ) { error in
      XCTAssertEqual(
        (error as? RuntimeOperationRequestRejection)?.code, .unsupportedVersion,
        "doctor would be advertising a version admission does not gate on")
    }

    // Counted from the catalog rather than restated, so a published operation
    // cannot appear or disappear without this number following it.
    XCTAssertEqual(operationCount, Int64(RuntimeOperationCatalog.operations.count))
    XCTAssertGreaterThan(operationCount, 0)
  }

  private func envelopeProbe(schemaVersion: String) -> Data {
    Data(
      """
      {
        "documentType": "runtime-operation-request",
        "schemaVersion": "\(schemaVersion)",
        "requestId": "req-doctor-probe",
        "idempotencyKey": "idem-doctor-probe",
        "target": { "targetId": "TGT-DAYU200-01" },
        "operation": { "id": "observe.device", "version": 1 }
      }
      """.utf8)
  }

  // MARK: - describe publishes the input contract

  /// `operation.describe` existed and answered with title, provider, effect,
  /// binding and availability — everything except what a caller needs to build
  /// a request. Field names were discoverable only by being refused for
  /// omitting one, and meanings only by reading the catalog source.
  ///
  /// The example is the load-bearing part and the assertion is behavioural:
  /// every published operation's example must survive the real decode path. A
  /// hand-kept example would be a second statement of the contract; one that
  /// silently stopped being valid is worse than none, because a caller copies
  /// it.
  func testDescribePublishesEveryOperationsInputContractAndAUsableExample() async throws {
    let (handler, _) = try makeStack()
    for descriptor in RuntimeOperationCatalog.operations {
      let described = try await request(
        handler, method: "operation.describe",
        params: ["reference": .string(descriptor.reference)])
      XCTAssertTrue(described.ok, "\(descriptor.reference): \(described.error?.message ?? "-")")
      guard case .object(let fields)? = described.result,
        case .array(let inputs)? = fields["inputs"],
        case .array(let outputs)? = fields["outputs"]
      else {
        return XCTFail("\(descriptor.reference): describe must project the input contract")
      }

      // Same source, not a parallel transcription.
      XCTAssertEqual(
        inputs.count, descriptor.inputs.count, descriptor.reference)
      XCTAssertEqual(
        outputs.count, descriptor.outputs.count, descriptor.reference)
      for (projected, field) in zip(inputs, descriptor.inputs) {
        guard case .object(let row) = projected else {
          return XCTFail("\(descriptor.reference): a field must project as an object")
        }
        XCTAssertEqual(row["name"], .string(field.name))
        XCTAssertEqual(row["type"], .string(field.type.rawValue))
        XCTAssertEqual(row["required"], .bool(field.isRequired))
        XCTAssertEqual(row["default"], field.defaultValue, "\(field.name) default")
        XCTAssertEqual(
          row["description"], field.summary.map(JSONValue.string), "\(field.name) description")
      }

      guard let example = fields["exampleRequest"], example != .null else {
        return XCTFail("\(descriptor.reference): describe must carry an example request")
      }
      let encoded = try CanonicalJSONEncoders.canonical().encode(example)
      let decoded = try RuntimeOperationCodec.decodeRequest(encoded)
      XCTAssertEqual(
        decoded.operation.reference, descriptor.reference,
        "the example must be a request for the operation it describes")
      // Every required input is present, so a caller who fills in the
      // placeholders is not still missing a field.
      for field in descriptor.inputs where field.isRequired {
        XCTAssertNotNil(
          decoded.inputs[field.name],
          "\(descriptor.reference): the example omits required input \(field.name)")
      }
    }
  }

  func testDescribeFailsClosedOnAnOperationThatDoesNotExist() async throws {
    let (handler, _) = try makeStack()
    let described = try await request(
      handler, method: "operation.describe",
      params: ["reference": .string("observe.galaxy@9")])
    XCTAssertFalse(described.ok)
    XCTAssertEqual(described.error?.code, AgentDaemonErrorCode.notFound.rawValue)
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

  func testPagedJobListReturnsNewestSummariesAndOldCurrentJobsWithoutTimelines() async throws {
    let (handler, engine) = try makeStack()
    var accepted: [RuntimeJobAcceptance] = []
    for index in 1...3 {
      let operation = Data(
        """
        {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
        "requestId":"req-paged-wire-\(index)",\
        "idempotencyKey":"idem-paged-wire-\(index)",\
        "target":{"targetId":"TGT-PAGED-WIRE","expectedBindingRevision":7},\
        "operation":{"id":"observe.device","version":1}}
        """.utf8)
      accepted.append(try await engine.submit(operation))
    }
    try await engine.requestCancel(jobID: accepted[2].jobID)

    let response = try await request(
      handler, method: "job.list-page",
      params: [
        "pageSize": .integer(1),
        "order": .string("newestFirst"),
        "includeTimeline": .bool(false),
        "includeCurrent": .bool(true),
      ])
    XCTAssertTrue(response.ok, response.error?.message ?? "-")
    guard case .object(let result)? = response.result,
      case .array(let page)? = result["jobs"],
      case .array(let current)? = result["currentJobs"]
    else {
      return XCTFail("job.list-page must return page and current summary arrays")
    }
    XCTAssertEqual(page.count, 1)
    guard case .object(let newest) = page[0] else {
      return XCTFail("newest summary must be an object")
    }
    XCTAssertEqual(newest["jobId"], .string(accepted[2].jobID))
    XCTAssertEqual(newest["timeline"], .null)
    XCTAssertEqual(
      Set(
        current.compactMap { value -> String? in
          guard case .object(let fields) = value,
            case .string(let jobID)? = fields["jobId"]
          else { return nil }
          XCTAssertEqual(fields["timeline"], .null)
          return jobID
        }),
      Set(accepted.prefix(2).map(\.jobID)))
    XCTAssertNotEqual(result["nextCursor"], .null)

    for params in [
      ["pageSize": JSONValue.string("1")],
      ["order": JSONValue.string("latest")],
      ["includeTimeline": .string("false")],
      ["includeCurrent": .string("true")],
    ] {
      let invalid = try await request(handler, method: "job.list-page", params: params)
      XCTAssertFalse(invalid.ok)
      XCTAssertEqual(invalid.error?.code, AgentDaemonErrorCode.invalidParams.rawValue)
    }
  }

  func testJobStatusPublishesTypedProgressWhileTheProcessStepIsActive() async throws {
    let dispatcher = ProgressGatedDispatcher()
    let (handler, engine) = try makeStack(dispatcher: dispatcher)
    let operation = Data(
      """
      {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
      "requestId":"req-typed-progress","idempotencyKey":"idem-typed-progress",\
      "target":{"targetId":"TGT-TYPED-PROGRESS","expectedBindingRevision":7},\
      "operation":{"id":"observe.device","version":1}}
      """.utf8)
    let accepted = try await engine.submit(operation)
    let running = Task { try await engine.run(jobID: accepted.jobID) }

    let arrived = await waitForSemaphore(
      dispatcher.dispatchArrived, timeout: daemonRendezvousTimeout)
    XCTAssertEqual(arrived, .success)
    let response = try await request(
      handler, method: "job.status",
      params: ["jobId": .string(accepted.jobID)])
    guard case .object(let fields)? = response.result,
      case .object(let progress)? = fields["processProgress"]
    else {
      dispatcher.release()
      _ = try await running.value
      return XCTFail("active Runtime progress must keep its typed wire shape")
    }
    XCTAssertNotEqual(progress["stepId"], .string(""))
    XCTAssertEqual(progress["phase"], .string("writing"))
    XCTAssertEqual(progress["unitName"], .string("system"))
    XCTAssertEqual(progress["completedUnitCount"], .integer(4))
    XCTAssertEqual(progress["totalUnitCount"], .integer(9))
    XCTAssertEqual(progress["currentUnitPercent"], .integer(35))

    dispatcher.release()
    _ = try await running.value
    let terminal = try await request(
      handler, method: "job.status",
      params: ["jobId": .string(accepted.jobID)])
    guard case .object(let terminalFields)? = terminal.result else {
      return XCTFail("terminal Runtime status must remain available")
    }
    XCTAssertEqual(terminalFields["processProgress"], .null)
  }

  func testFailedJobPublishesStableTypedFailureWithoutUsingTimelineAsProtocol() async throws {
    let (handler, engine) = try makeStack(dispatcher: FailingDispatcher())
    let operation = Data(
      """
      {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
      "requestId":"req-typed-failure","idempotencyKey":"idem-typed-failure",\
      "target":{"targetId":"TGT-TYPED-FAILURE","expectedBindingRevision":7},\
      "operation":{"id":"observe.device","version":1}}
      """.utf8)
    let accepted = try await engine.submit(operation)
    let terminal = try await engine.run(jobID: accepted.jobID)
    XCTAssertEqual(terminal.state, JobState.failed.rawValue)

    let response = try await request(
      handler, method: "job.status", params: ["jobId": .string(accepted.jobID)])
    guard case .object(let fields)? = response.result,
      case .object(let failure)? = fields["failure"]
    else { return XCTFail("failed Runtime status must carry typed failure facts") }
    XCTAssertEqual(failure["schemaVersion"], .string("1.0.0"))
    XCTAssertEqual(failure["code"], .string("executionFailed"))
    XCTAssertEqual(failure["category"], .string("execution"))
    XCTAssertEqual(failure["retryability"], .string("runtimeDecisionRequired"))
    XCTAssertEqual(failure["recovery"], .string("inspectJob"))
    XCTAssertNil(failure["summary"])
    XCTAssertNil(failure["diagnostic"])
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
    let flash = rows.first { $0["reference"] == .string("flash.dayu200") }
    XCTAssertEqual(flash?["availability"], .string("unavailable"))
    guard case .array(let flashReasons)? = flash?["reasons"] else {
      return XCTFail("unavailable operation must explain why")
    }
    let flashReasonStrings = flashReasons.compactMap { value -> String? in
      guard case .string(let reason) = value else { return nil }
      return reason
    }
    XCTAssertEqual(flashReasonStrings.count, flashReasons.count)
    XCTAssertEqual(
      Set(flashReasonStrings).count, flashReasonStrings.count,
      "operation.list must not repeat an identical availability reason")
    XCTAssertTrue(
      flashReasons.contains { value in
        guard case .string(let reason) = value else { return false }
        return reason.contains("arkforge") && reason.contains("not registered")
      })
    let describe = await handler.handleFrame(
      Data(
        """
        {"protocolVersion":"1.0.0","id":"d","method":"operation.describe",
         "params":{"reference":"flash.dayu200"}}
        """.utf8))
    guard case .object(let fields)? = describe.result else {
      return XCTFail("describe must return an object")
    }
    XCTAssertEqual(fields["minimumEffect"], .string("destructive"))
    XCTAssertEqual(fields["provider"], .string("arkforge"))
    XCTAssertEqual(fields["availability"], .string("unavailable"))
    guard case .array(let reasons)? = fields["availabilityReasons"] else {
      return XCTFail("describe must include availability reasons")
    }
    XCTAssertFalse(reasons.isEmpty)
  }

  func testManagedHDCRuntimeStatusIsPathFreeReadOnlyAndClosed() async throws {
    let diagnostics = HDCManagedRuntimeDiagnostics(
      executableSHA256: String(repeating: "a", count: 64),
      clientVersion: "3.2.0f",
      serverVersion: "3.2.0f",
      endpoint: "127.0.0.1:8710",
      endpointSource: "default")
    let (handler, _) = try makeStack(hdcRuntimeDiagnostics: diagnostics)

    let response = try await request(handler, method: "runtime.hdc-status")
    guard case .object(let result)? = response.result else {
      return XCTFail("runtime.hdc-status must return an object")
    }
    XCTAssertTrue(response.ok)
    XCTAssertEqual(result["availability"], .string("ready"))
    XCTAssertEqual(result["source"], .string("runtimeManaged"))
    XCTAssertEqual(result["toolSha256"], .string(String(repeating: "a", count: 64)))
    XCTAssertEqual(result["clientVersion"], .string("3.2.0f"))
    XCTAssertEqual(result["serverVersion"], .string("3.2.0f"))
    XCTAssertEqual(result["endpoint"], .string("127.0.0.1:8710"))
    XCTAssertEqual(result["serverHealth"], .string("healthy"))
    XCTAssertEqual(result["ownership"], .string("arkDeckManaged"))
    XCTAssertNil(result["path"])
    XCTAssertNil(result["executable"])
    XCTAssertNil(result["arguments"])
    XCTAssertNil(result["argv"])

    let invalid = try await request(
      handler, method: "runtime.hdc-status", params: ["path": .string("/tmp/hdc")])
    XCTAssertFalse(invalid.ok)
    XCTAssertEqual(invalid.error?.code, "invalidParams")

    let (unconfigured, _) = try makeStack()
    let unavailable = try await request(unconfigured, method: "runtime.hdc-status")
    guard case .object(let unavailableResult)? = unavailable.result else {
      return XCTFail("unconfigured runtime status must still be structured")
    }
    XCTAssertEqual(unavailableResult["availability"], .string("unavailable"))
  }

  func testFlashPrerequisitesAreReadOnlyTargetBoundRuntimeFacts() async throws {
    struct Observer: RockchipFlashPrerequisiteObserving {
      func observePrerequisites(
        targetID _: String
      ) async throws -> [RockchipPrerequisiteObservation] {
        RockchipPrerequisiteIdentifier.allCases.map {
          RockchipPrerequisiteObservation(
            identifier: $0,
            status: $0 == .stablePower ? .unknown : .satisfied)
        }
      }
    }
    let targets = try RuntimeTargetStore(
      directoryURL: stateDirectory.appending(
        path:
          "targets-prerequisites", directoryHint: .isDirectory))
    let target = try targets.adopt(
      stableIdentitySHA256: String(repeating: "a", count: 64),
      connectKey: "150100424a544e4600", toolVersion: "3.2.0f",
      nowUTC: "2026-08-08T00:00:00Z"
    ).record
    let (handler, _) = try makeStack(
      targetStore: targets, flashPrerequisiteObserver: Observer())

    let response = try await request(
      handler, method: "flash.prerequisites",
      params: [
        "targetId": .string(target.targetID),
        "profileReference": .string("dayu200"),
      ])
    guard case .object(let result)? = response.result,
      case .array(let observations)? = result["observations"]
    else { return XCTFail("prerequisite read must return a bound result") }
    XCTAssertTrue(response.ok)
    XCTAssertEqual(result["targetId"], .string(target.targetID))
    XCTAssertEqual(result["bindingRevision"], .integer(Int64(target.bindingRevision)))
    XCTAssertEqual(observations.count, RockchipPrerequisiteIdentifier.allCases.count)

    let missing = try await request(
      handler, method: "flash.prerequisites",
      params: [
        "targetId": .string("target-missing"),
        "profileReference": .string("dayu200"),
      ])
    XCTAssertFalse(missing.ok)
    XCTAssertEqual(missing.error?.code, "notFound")
  }

  /// CHG-2026-068 LPP-AC-2/5: every preview state crosses the wire as itself,
  /// a runtime without a composed lane answers with an honest state rather
  /// than an error, and the parameter gate fails closed.
  func testLanePlanPreviewIsHonestPerStateAndFailsClosedOnParams() async throws {
    struct ScriptedPreviewer: FlashLanePlanPreviewing {
      let outcome: ArkForgeLanePlanPreviewOutcome
      func preview(
        targetID _: String, profileReference _: String, archiveSHA256: String
      ) async -> ArkForgeLanePlanPreviewOutcome {
        XCTAssertEqual(
          archiveSHA256, archiveSHA256.lowercased(),
          "the handler normalizes the digest before it reaches the lane")
        return outcome
      }
    }
    let targets = try RuntimeTargetStore(
      directoryURL: stateDirectory.appending(
        path: "targets-lane-preview", directoryHint: .isDirectory))
    let target = try targets.adopt(
      stableIdentitySHA256: String(repeating: "a", count: 64),
      connectKey: "150100424a544e4600", toolVersion: "3.2.0f",
      nowUTC: "2026-08-08T00:00:00Z"
    ).record
    let digest = String(repeating: "E", count: 64)

    let (available, _) = try makeStack(
      targetStore: targets,
      flashLanePlanPreviewer: ScriptedPreviewer(
        outcome: .available(
          planID: "PLAN-preview", planSHA256: String(repeating: "d", count: 64),
          observationMode: "hdc-normal")))
    let response = try await request(
      available, method: "flash.lanePlanPreview",
      params: [
        "targetId": .string(target.targetID),
        "profileReference": .string("dayu200"),
        "archiveSha256": .string(digest),
      ])
    guard case .object(let result)? = response.result else {
      return XCTFail("an available preview must return a structured result")
    }
    XCTAssertTrue(response.ok)
    XCTAssertEqual(result["state"], .string("available"))
    XCTAssertEqual(result["planId"], .string("PLAN-preview"))
    XCTAssertEqual(result["planSha256"], .string(String(repeating: "d", count: 64)))
    XCTAssertEqual(result["observationMode"], .string("hdc-normal"))
    XCTAssertEqual(result["targetId"], .string(target.targetID))
    XCTAssertEqual(result["bindingRevision"], .integer(Int64(target.bindingRevision)))

    let (assessment, _) = try makeStack(
      targetStore: targets,
      flashLanePlanPreviewer: ScriptedPreviewer(
        outcome: .planNotExecutable(
          availability: "unavailable", reason: "maturity is hardwareGated",
          unknowns: ["RK-M02": "combination is hardwareGated"])))
    let gated = try await request(
      assessment, method: "flash.lanePlanPreview",
      params: [
        "targetId": .string(target.targetID),
        "profileReference": .string("dayu200"),
        "archiveSha256": .string(digest),
      ])
    guard case .object(let gatedResult)? = gated.result else {
      return XCTFail("an assessment preview must return a structured result")
    }
    XCTAssertEqual(gatedResult["state"], .string("planNotExecutable"))
    XCTAssertEqual(gatedResult["reason"], .string("maturity is hardwareGated"))
    XCTAssertEqual(
      gatedResult["unknowns"],
      .array([.string("RK-M02: combination is hardwareGated")]))

    let (bare, _) = try makeStack(targetStore: targets)
    let notComposed = try await request(
      bare, method: "flash.lanePlanPreview",
      params: [
        "targetId": .string(target.targetID),
        "profileReference": .string("dayu200"),
        "archiveSha256": .string(digest),
      ])
    guard case .object(let bareResult)? = notComposed.result else {
      return XCTFail("a runtime without a lane must still answer with a state")
    }
    XCTAssertTrue(notComposed.ok)
    XCTAssertEqual(bareResult["state"], .string("laneNotComposed"))

    let invalid = try await request(
      available, method: "flash.lanePlanPreview",
      params: [
        "targetId": .string(target.targetID),
        "profileReference": .string("dayu200"),
        "archiveSha256": .string("not-a-digest"),
      ])
    XCTAssertFalse(invalid.ok)
    XCTAssertEqual(invalid.error?.code, "invalidParams")

    let unknownTarget = try await request(
      available, method: "flash.lanePlanPreview",
      params: [
        "targetId": .string("target-missing"),
        "profileReference": .string("dayu200"),
        "archiveSha256": .string(digest),
      ])
    XCTAssertFalse(unknownTarget.ok)
    XCTAssertEqual(unknownTarget.error?.code, "notFound")
  }

  func testBootloaderStatusAndClosedLoaderBindingHaveRedactedWireShapes() async throws {
    struct StatusObserver: RockchipBootloaderStatusObserving {
      func observeBootloaderStatus() throws -> RockchipBootloaderStatus {
        RockchipBootloaderStatus(
          disposition: .unbound,
          observationCount: 1,
          mode: "loader",
          targetID: nil,
          bindingRevision: nil)
      }
    }
    struct BindingCoordinator: RockchipLoaderBindingCoordinating {
      func bindCurrentLoader(
        targetID: String,
        expectedBindingRevision: Int
      ) throws -> RockchipLoaderBindingReceipt {
        RockchipLoaderBindingReceipt(
          targetID: targetID,
          previousRevision: expectedBindingRevision,
          currentRevision: expectedBindingRevision,
          updated: true,
          selectionEvidenceSHA256: String(repeating: "c", count: 64))
      }
    }
    let (handler, _) = try makeStack(
      rockchipBootloaderStatusObserver: StatusObserver(),
      rockchipLoaderBindingCoordinator: BindingCoordinator())

    let observed = try await request(handler, method: "flash.bootloader-status")
    guard case .object(let status)? = observed.result else {
      return XCTFail("bootloader status must be an object")
    }
    XCTAssertTrue(observed.ok)
    XCTAssertEqual(status["disposition"], .string("unbound"))
    XCTAssertEqual(status["observationCount"], .integer(1))
    XCTAssertEqual(status["mode"], .string("loader"))
    XCTAssertEqual(status["targetId"], .null)
    XCTAssertEqual(
      Set(status.keys),
      ["disposition", "observationCount", "mode", "targetId", "bindingRevision"])

    let bound = try await request(
      handler,
      method: "flash.bind-current-loader",
      params: [
        "targetId": .string("TGT-SELECTED"),
        "expectedBindingRevision": .integer(2),
      ])
    guard case .object(let receipt)? = bound.result else {
      return XCTFail("Loader binding must return a receipt")
    }
    XCTAssertTrue(bound.ok, bound.error?.message ?? "-")
    XCTAssertEqual(receipt["targetId"], .string("TGT-SELECTED"))
    XCTAssertEqual(receipt["previousBindingRevision"], .integer(2))
    XCTAssertEqual(receipt["bindingRevision"], .integer(2))
    XCTAssertEqual(receipt["settledJobId"], .null)
    XCTAssertNil(receipt["serial"])
    XCTAssertNil(receipt["usbTopology"])
  }

  func testPlanPreviewRemainsReadOnlyAndCapabilityAdministrationIsNotAgentFacing() async throws {
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
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
    let planned = try await request(
      handler, method: "job.plan",
      params: ["requestJson": .string(operationJSON)])
    XCTAssertTrue(planned.ok, planned.error?.message ?? "-")
    guard case .object(let plan)? = planned.result else {
      return XCTFail("job.plan must return a Runtime plan-only preview")
    }
    XCTAssertEqual(plan["executionMode"], .string("planOnly"))
    XCTAssertEqual(plan["jobAdmitted"], .bool(false))
    XCTAssertEqual(plan["dispatchDisposition"], .string("notDispatched"))
    XCTAssertNil(plan["capability"])
    let jobsAfterPlan = try await engine.listJobs()
    XCTAssertTrue(jobsAfterPlan.isEmpty)

    let drafted = try await request(
      handler, method: "capability.draft",
      params: [
        "requestJson": .string(operationJSON),
        "validitySeconds": .integer(3_600),
        "maximumUses": .integer(3),
      ])
    XCTAssertFalse(drafted.ok)
    XCTAssertEqual(drafted.error?.code, "rejected")
    XCTAssertTrue((drafted.error?.message ?? "").contains("not an Agent-facing API"))

    for method in ["capability.install", "capability.revoke"] {
      let rejected = try await request(handler, method: method, params: [:])
      XCTAssertFalse(rejected.ok, method)
      XCTAssertEqual(rejected.error?.code, "rejected", method)
      XCTAssertTrue(
        (rejected.error?.message ?? "").contains("not an Agent-facing API"), method)
    }
    let statuses = try await request(handler, method: "capability.list")
    XCTAssertEqual(statuses.result, .array([]))
    let jobsAfterRejections = try await engine.listJobs()
    XCTAssertTrue(jobsAfterRejections.isEmpty)
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

  // MARK: - Line framing (AIN-FRAMING-001)

  /// Connects, writes `payload` in `pieceBytes` slices, then reads until
  /// `expectedResponses` newline-terminated frames have arrived. Driving the
  /// socket by hand is the point: it pins the daemon's reassembly behaviour for
  /// frames that span many reads, which `AgentClient` alone cannot express.
  private func exchangeRawFrames(
    socketPath: String, payload: Data, pieceBytes: Int, expectedResponses: Int
  ) throws -> [String] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw AgentDaemonError.io("cannot create socket") }
    defer { close(fd) }
    // The daemon closes the connection on an oversize frame, so writing into a
    // closed peer must surface as EPIPE rather than killing the test process.
    var noSignal: Int32 = 1
    guard
      setsockopt(
        fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
        socklen_t(MemoryLayout<Int32>.size)) == 0
    else { throw AgentDaemonError.io("cannot suppress SIGPIPE") }
    // A frame the daemon never answers must fail the test rather than hang it.
    var receiveTimeout = timeval(tv_sec: 20, tv_usec: 0)
    guard
      setsockopt(
        fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout,
        socklen_t(MemoryLayout<timeval>.size)) == 0
    else { throw AgentDaemonError.io("cannot bound the receive timeout") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      socketPath.utf8CString.withUnsafeBytes { source in
        buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(buffer.count)))
      }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw AgentDaemonError.io("connect errno \(errno)") }

    try payload.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var sent = 0
      while sent < raw.count {
        let piece = min(pieceBytes, raw.count - sent)
        var written = 0
        while written < piece {
          let result = write(fd, base + sent + written, piece - written)
          guard result > 0 else { throw AgentDaemonError.io("short write") }
          written += result
        }
        sent += piece
      }
    }

    guard expectedResponses > 0 else { return [] }
    var received = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while received.filter({ $0 == 0x0A }).count < expectedResponses {
      let count = read(fd, &chunk, chunk.count)
      guard count > 0 else { throw AgentDaemonError.io("closed before response") }
      received.append(contentsOf: chunk[0..<count])
    }
    return String(decoding: received, as: UTF8.self)
      .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
  }

  /// A production-shaped flash-bundle chunk is a full 2 MiB, which encodes to a
  /// ~2.8 MB frame and reaches the daemon in ~8 KiB socket reads — the frame
  /// that made reassembly quadratic. Driving a real begin/append/commit round
  /// trip proves byte-exactness rather than mere parseability: the staged file
  /// must hash to the digest pinned before the upload started, so a single
  /// dropped, duplicated or reordered byte fails the commit.
  func testLargeFrameSurvivesManySmallSocketReads() async throws {
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appending(
        path:
          "targets-framing", directoryHint: .isDirectory))
    let target = try targetStore.adopt(
      stableIdentitySHA256: String(repeating: "a", count: 64),
      connectKey: "150100424a544e4600",
      toolVersion: "3.2.0f",
      nowUTC: "2026-07-30T00:00:00Z"
    ).record
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(
        path:
          "artifacts-framing", directoryHint: .isDirectory),
      nowUTC: { "2026-07-30T00:00:00Z" })

    var scratch = [UInt8](repeating: 0, count: 2 * 1024 * 1024)
    var seed: UInt64 = 0x2545_F491_4F6C_DD1D
    for index in scratch.indices {
      seed ^= seed << 13
      seed ^= seed >> 7
      seed ^= seed << 17
      scratch[index] = UInt8(truncatingIfNeeded: seed)
    }
    let bytes = Data(scratch)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let policy = FlashBundleImportPolicy(
      expectedByteCount: bytes.count, expectedSHA256: digest
    ) { url in
      guard try Data(contentsOf: url) == bytes else {
        throw FlashBundleArtifactImportError.invalidBundle("framing fixture bytes")
      }
      return FlashBundleImportValidation(byteCount: bytes.count, sha256: digest)
    }
    let (handler, _) = try makeStack(
      targetStore: targetStore, artifactStore: artifactStore,
      flashBundleImportPolicy: policy)
    let server = try startServer(handler)
    let client = AgentClient(socketPath: server.socketURL.path)

    let begin = try client.request(
      method: "artifact.importFlashBundle.begin",
      params: [
        "targetId": .string(target.targetID),
        "name": .string("images.tar.gz"),
        "byteCount": .integer(Int64(bytes.count)),
        "sha256": .string(digest),
      ])
    guard case .object(let beginFields) = begin,
      case .string(let uploadID)? = beginFields["uploadId"]
    else {
      return XCTFail("flash begin must return a bounded upload identity")
    }

    let identifier = UUID().uuidString
    var payload = try JSONEncoder().encode(
      AgentWireProtocol.Request(
        id: identifier, method: "artifact.importFlashBundle.append",
        params: [
          "uploadId": .string(uploadID),
          "offset": .integer(0),
          "base64": .string(bytes.base64EncodedString()),
        ]))
    XCTAssertGreaterThan(payload.count, 2_700_000)
    payload.append(0x0A)

    let responses = try exchangeRawFrames(
      socketPath: server.socketURL.path, payload: payload,
      pieceBytes: 8 * 1024, expectedResponses: 1)
    XCTAssertEqual(responses.count, 1)
    let appended = try JSONDecoder().decode(
      AgentWireProtocol.Response.self, from: Data(responses[0].utf8))
    XCTAssertEqual(appended.id, identifier)
    XCTAssertTrue(appended.ok, appended.error?.message ?? "-")
    XCTAssertEqual(appended.result, .object(["nextOffset": .integer(Int64(bytes.count))]))

    let commit = try client.request(
      method: "artifact.importFlashBundle.commit",
      params: ["uploadId": .string(uploadID)])
    guard case .object(let fields) = commit else {
      return XCTFail("flash commit must return the published artifact facts")
    }
    XCTAssertEqual(fields["sha256"], .string(digest))
    XCTAssertEqual(fields["byteCount"], .integer(Int64(bytes.count)))
  }

  /// Frame boundaries, not read boundaries, delimit requests: several frames in
  /// one write are answered in order, and bare terminators are skipped rather
  /// than answered or treated as corruption.
  func testPipelinedAndEmptyFramesKeepFrameSemantics() throws {
    let (handler, _) = try makeStack()
    let server = try startServer(handler)

    let firstID = UUID().uuidString
    let secondID = UUID().uuidString
    var payload = Data("\n".utf8)
    for identifier in [firstID, secondID] {
      payload.append(
        try JSONEncoder().encode(
          AgentWireProtocol.Request(id: identifier, method: "health", params: nil)))
      payload.append(contentsOf: [0x0A, 0x0A])
    }

    let responses = try exchangeRawFrames(
      socketPath: server.socketURL.path, payload: payload,
      pieceBytes: payload.count, expectedResponses: 2)
    XCTAssertEqual(responses.count, 2)
    let decoded = try responses.map {
      try JSONDecoder().decode(AgentWireProtocol.Response.self, from: Data($0.utf8))
    }
    XCTAssertEqual(decoded.map(\.id), [firstID, secondID])
    XCTAssertTrue(decoded.allSatisfy(\.ok))
  }

  /// The bytes already searched belong to the frame just consumed, so the next
  /// frame must be searched from the start of what is left. This is the case
  /// that catches a stale search offset: a long frame is followed by a much
  /// shorter one, so after the long frame is consumed the remaining frame ends
  /// well before the offset reached while accumulating its predecessor. A
  /// scanner that resumed from that offset would leave the short frame
  /// unanswered forever.
  func testShortFrameTrailingALongOneIsNotSkipped() throws {
    let (handler, _) = try makeStack()
    let server = try startServer(handler)

    let longID = UUID().uuidString
    let shortID = UUID().uuidString
    var payload = try JSONEncoder().encode(
      AgentWireProtocol.Request(
        id: longID, method: "health",
        params: ["padding": .string(String(repeating: "p", count: 512 * 1024))]))
    payload.append(0x0A)
    payload.append(
      try JSONEncoder().encode(
        AgentWireProtocol.Request(id: shortID, method: "health", params: nil)))
    payload.append(0x0A)

    let responses = try exchangeRawFrames(
      socketPath: server.socketURL.path, payload: payload,
      pieceBytes: 8 * 1024, expectedResponses: 2)
    XCTAssertEqual(responses.count, 2)
    let decoded = try responses.map {
      try JSONDecoder().decode(AgentWireProtocol.Response.self, from: Data($0.utf8))
    }
    XCTAssertEqual(decoded.map(\.id), [longID, shortID])
    XCTAssertTrue(decoded.allSatisfy(\.ok))
  }

  /// The frame-bomb guard still ends the connection before an unterminated
  /// frame can grow without bound.
  func testUnterminatedOversizeFrameStillDisconnects() throws {
    let (handler, _) = try makeStack()
    let server = try startServer(handler)
    let payload = Data(repeating: 0x41, count: 5 * 1024 * 1024)  // no terminator
    XCTAssertThrowsError(
      try exchangeRawFrames(
        socketPath: server.socketURL.path, payload: payload,
        pieceBytes: 64 * 1024, expectedResponses: 1))
  }

  /// Sends one framed request and hangs up hard without reading the response.
  /// `SO_LINGER 0` forces a reset rather than a graceful close, so the daemon's
  /// write finds a peer that is already gone.
  private func sendFrameAndHangUp(socketPath: String, identifier: String) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw AgentDaemonError.io("cannot create socket") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      socketPath.utf8CString.withUnsafeBytes { source in
        buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(buffer.count)))
      }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      close(fd)
      throw AgentDaemonError.io("connect errno \(errno)")
    }
    var frame = try JSONEncoder().encode(
      AgentWireProtocol.Request(id: identifier, method: "health", params: nil))
    frame.append(0x0A)
    _ = frame.withUnsafeBytes { raw -> Int in
      write(fd, raw.baseAddress!, raw.count)
    }
    var reset = linger(l_onoff: 1, l_linger: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
    close(fd)
  }

  /// A client that hangs up before reading its response must cost the daemon
  /// that one connection and nothing else. The daemon is long-lived and shared
  /// - it holds every job, session, capability and in-flight upload - so an
  /// interrupted CLI must not be able to take it down. Without suppression the
  /// response write raises SIGPIPE and kills this test process outright, which
  /// is exactly the failure being pinned.
  func testAClientHangingUpCostsOnlyItsOwnConnection() throws {
    let (handler, _) = try makeStack()
    let server = try startServer(handler)

    for round in 1...5 {
      try sendFrameAndHangUp(
        socketPath: server.socketURL.path, identifier: "hangup-\(round)")
      Thread.sleep(forTimeInterval: 0.1)
    }

    let client = AgentClient(socketPath: server.socketURL.path)
    let health = try client.request(method: "health")
    guard case .object(let fields) = health,
      case .string(let status)? = fields["status"]
    else {
      return XCTFail("daemon must still answer after clients hang up")
    }
    XCTAssertEqual(status, "ok")
  }

  // MARK: - Client transport

  /// The daemon drops the connection on an oversize frame, so a request larger
  /// than the frame bomb guard finds the peer gone mid-write. That must reach
  /// the caller as a transport error: under the default SIGPIPE disposition the
  /// write instead kills the whole process, taking down a CLI invocation or a
  /// campaign attempt in a way no `catch` can observe.
  func testWriteIntoAClosedPeerFailsAsTransportNotSignal() throws {
    let (handler, _) = try makeStack()
    let server = try startServer(handler)
    let client = AgentClient(socketPath: server.socketURL.path)

    // Comfortably past the daemon's 4 MiB guard, so it closes before the last
    // byte is written.
    let oversize = String(repeating: "p", count: 6 * 1024 * 1024)
    XCTAssertThrowsError(
      try client.request(method: "health", params: ["padding": .string(oversize)])
    ) { error in
      guard case AgentClientError.transport = error else {
        return XCTFail("expected a transport error, got \(error)")
      }
    }
    // The connection is per-request, so the client must still work afterwards.
    XCTAssertNoThrow(try client.request(method: "health"))
  }

  /// A response larger than one socket read must be reassembled from its own
  /// frame terminator, not from read boundaries. The stand-in server writes in
  /// small pieces so the client is forced through many partial reads.
  func testLargeResponseIsReassembledAcrossManyReads() throws {
    let socketURL = stateDirectory.appending(path: "stub.sock")
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true)
    let payloadBytes = 4 * 1024 * 1024
    let identifier = "stub-response-id"
    var encodedResponse = try JSONEncoder().encode(
      StubResponse(
        id: identifier, ok: true,
        result: .object(["padding": .string(String(repeating: "q", count: payloadBytes))]),
        error: nil))
    encodedResponse.append(0x0A)
    let response = encodedResponse

    let listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(listenerFD, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      socketURL.path.utf8CString.withUnsafeBytes { source in
        buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(buffer.count)))
      }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(bound, 0)
    XCTAssertEqual(listen(listenerFD, 4), 0)

    let served = expectation(description: "stub server answered")
    DispatchQueue.global().async {
      defer { close(listenerFD) }
      let connectionFD = accept(listenerFD, nil, nil)
      guard connectionFD >= 0 else { return served.fulfill() }
      defer { close(connectionFD) }
      var suppressSignal: Int32 = 1
      _ = setsockopt(
        connectionFD, SOL_SOCKET, SO_NOSIGPIPE, &suppressSignal,
        socklen_t(MemoryLayout<Int32>.size))
      var request = [UInt8](repeating: 0, count: 64 * 1024)
      _ = read(connectionFD, &request, request.count)
      response.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var sent = 0
        while sent < raw.count {
          let piece = min(8 * 1024, raw.count - sent)
          var written = 0
          while written < piece {
            let result = write(connectionFD, base + sent + written, piece - written)
            if result <= 0 { return served.fulfill() }
            written += result
          }
          sent += piece
        }
      }
      served.fulfill()
    }

    let client = AgentClient(socketPath: socketURL.path)
    let result = try client.request(method: "health", id: identifier)
    wait(for: [served], timeout: 30)
    guard case .object(let fields) = result,
      case .string(let padding)? = fields["padding"]
    else {
      return XCTFail("stub result must survive reassembly")
    }
    XCTAssertEqual(padding.utf8.count, payloadBytes)
    XCTAssertTrue(padding.allSatisfy { $0 == "q" })
  }

  private struct StubResponse: Codable {
    let id: String
    let ok: Bool
    let result: JSONValue?
    let error: AgentWireProtocol.WireError?
  }

  private final class LockedAgentResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [JSONValue?] = [nil, nil]

    func store(_ value: JSONValue?, at index: Int) {
      lock.withLock { storage[index] = value }
    }

    var values: [JSONValue?] {
      lock.withLock { storage }
    }
  }

  // MARK: - UDS integration

  func testTwoConcurrentClientsShareOneDaemon() throws {
    let (handler, _) = try makeStack()
    let server = try startServer(handler)
    let clientA = AgentClient(socketPath: server.socketURL.path)
    let clientB = AgentClient(socketPath: server.socketURL.path)

    let group = DispatchGroup()
    let results = LockedAgentResponses()
    for (index, client) in [clientA, clientB].enumerated() {
      group.enter()
      DispatchQueue.global().async {
        let value = try? client.request(method: "health")
        results.store(value, at: index)
        group.leave()
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
    for value in results.values {
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
    let deep = stateDirectory.appending(
      path:
        String(repeating: "d", count: 120), directoryHint: .isDirectory)
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
    let client = AgentClient(socketPath: deep.appending(path: "agentd.sock").path)
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
  ///
  /// The daemon runs here with no ARKDECK_* configuration at all - see
  /// `launchProductionDaemon`, which declares that instead of inheriting it -
  /// so the operation availability asserted below is the unconfigured
  /// composition's.
  /// `testConfiguredHDCDoesNotPublishFlashWhenTheArkForgeLaneIsAbsent` covers
  /// the HDC-configured but lane-absent one.
  func testDaemonBinaryStaysAliveAndServesRequests() throws {
    let binary = productsDirectory.appending(path: "arkdeck-agentd")
    guard FileManager.default.fileExists(atPath: binary.path) else {
      throw XCTSkip("arkdeck-agentd binary not built")
    }
    // Short path: sun_path is 104 bytes, and the default temp directory
    // plus a UUID already crowds it.
    let shortState = URL(filePath: NSHomeDirectory())
      .appending(
        path: ".arkdeck-test-\(UInt32.random(in: 0..<100_000))", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: shortState) }

    let process = try launchProductionDaemon(binary: binary, stateDirectory: shortState)
    defer {
      if process.isRunning { process.terminate() }
    }

    let socketURL = shortState.appending(path: "agentd.sock")
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
    let operations = try listOperations(socketPath: socketURL.path)
    for reference in ["flash.full-restore@1", "flash.dayu200"] {
      guard let flash = operations[reference] else {
        return XCTFail("production daemon must publish \(reference) availability")
      }
      XCTAssertEqual(flash.availability, "unavailable", reference)
      XCTAssertTrue(
        flash.reasons.contains { $0.contains("ARKDECK_ARKFORGE_BUNDLE_PATH is unset") },
        "the provider must publish its absent lane: \(flash.reasons)")
      XCTAssertTrue(
        flash.reasons.contains { text in
          Self.unconfiguredRockchipBlockers.contains { text.contains($0) }
        },
        "the Rockchip route must also refuse through its own composition: \(flash.reasons)")
      // A composition that forgot to register the provider reports a generic
      // blocker and still looks unavailable for the right-looking reason.
      XCTAssertFalse(
        flash.reasons.contains { $0.contains("is not registered") },
        "the production daemon must register the ArkForge provider: \(flash.reasons)")
    }
    let expectedAliasFlash = try XCTUnwrap(operations["flash.dayu200"])

    // Every operation the production registry can answer for carries a
    // machine-readable code beside its prose (PRODUCT-LOOP §8).
    //
    // The prose alone had four naming conventions at once — English sentences,
    // dotted camelCase and snake_case in a single array — so the only way to
    // branch on it was to substring-match English, and rewording a sentence
    // silently changed what a caller did. The assertion just above is the
    // living example: it has to match the engine's own wording because the
    // `provider_not_registered` spelling it wanted never existed on this path.
    //
    // Stated over the whole registry rather than one reference, so a provider
    // or dispatcher that starts contributing a reason without a code fails
    // here rather than reaching an agent as an uncategorised string.
    let vocabulary = Set(RuntimeAvailabilityReasonCode.allCases.map(\.rawValue))
    for (reference, operation) in try listOperations(socketPath: socketURL.path) {
      XCTAssertEqual(
        operation.reasonCodes.count, operation.reasons.count,
        "\(reference) answers with \(operation.reasons.count) reasons and "
          + "\(operation.reasonCodes.count) codes; they are positionally paired")
      XCTAssertTrue(
        operation.reasonCodes.allSatisfy(vocabulary.contains),
        "\(reference) answered outside the closed vocabulary: \(operation.reasonCodes)")
      // The origin travels with every code, over the wire, positionally
      // paired the same way. An operator branches on this before the code.
      XCTAssertEqual(
        operation.reasonOrigins.count, operation.reasonCodes.count,
        "\(reference) pairs \(operation.reasonCodes.count) codes with "
          + "\(operation.reasonOrigins.count) origins")
      XCTAssertEqual(
        operation.reasonOrigins,
        operation.reasonCodes.compactMap {
          RuntimeAvailabilityReasonCode(rawValue: $0)?.origin.rawValue
        },
        "\(reference) origins must be the ones its own codes classify to")
      if operation.availability == "unavailable" {
        XCTAssertFalse(
          operation.reasonCodes.isEmpty,
          "\(reference) is unavailable and says nothing a caller can branch on")
      } else {
        XCTAssertTrue(
          operation.reasonCodes.isEmpty,
          "\(reference) is available and still carries \(operation.reasonCodes)")
      }
    }

    let cliURL = productsDirectory.appending(path: "arkdeck")
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: cliURL.path),
      "the production CLI must be built beside the daemon")
    let cli = Process()
    cli.executableURL = cliURL
    cli.arguments = [
      "operation", "list", "--socket", socketURL.path, "--json",
    ]
    let cliOutput = Pipe()
    let cliError = Pipe()
    cli.standardOutput = cliOutput
    cli.standardError = cliError
    try cli.run()
    cli.waitUntilExit()
    let cliOutputData = cliOutput.fileHandleForReading.readDataToEndOfFile()
    let cliErrorData = cliError.fileHandleForReading.readDataToEndOfFile()
    XCTAssertEqual(
      cli.terminationStatus, 0,
      String(decoding: cliErrorData, as: UTF8.self))
    guard
      case .array(let listedOperations) = try JSONDecoder().decode(
        JSONValue.self, from: cliOutputData),
      case .object(let listedFlash)? = listedOperations.first(where: { item in
        guard case .object(let fields) = item else { return false }
        return fields["reference"] == .string("flash.dayu200")
      })
    else {
      return XCTFail("arkdeck operation list must expose daemon availability")
    }
    XCTAssertEqual(
      listedOperations.count, RuntimeOperationCatalog.operations.count,
      "the production CLI must expose exactly the executable catalog roster")
    XCTAssertEqual(listedFlash["availability"], .string("unavailable"))
    XCTAssertEqual(
      listedFlash["reasons"], .array(expectedAliasFlash.reasons.map(JSONValue.string)))

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

  func testProductionDaemonAdvancesRuntimeTargetFromOwnerOnlyRockchipLineage() throws {
    let binary = productsDirectory.appending(path: "arkdeck-agentd")
    guard FileManager.default.fileExists(atPath: binary.path) else {
      throw XCTSkip("arkdeck-agentd binary not built")
    }
    let shortRoot = URL(filePath: NSHomeDirectory())
      .appending(
        path:
          ".arkdeck-lineage-\(UInt32.random(in: 0..<100_000))", directoryHint: .isDirectory)
    let rockchipRoot = shortRoot.appending(path: "ArkDeck", directoryHint: .isDirectory)
    let daemonState = rockchipRoot.appending(path: "Agentd", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: shortRoot) }

    let previousIdentity = String(repeating: "a", count: 64)
    let serial = "loader-mode-serial"
    let currentIdentity = SHA256.hash(data: Data(serial.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let targets = try RuntimeTargetStore(
      directoryURL: daemonState.appending(path: "targets", directoryHint: .isDirectory))
    let adopted = try targets.adopt(
      stableIdentitySHA256: previousIdentity,
      connectKey: "normal-mode-connect-key",
      toolVersion: "3.2.0f",
      nowUTC: "2026-08-03T00:00:00Z"
    ).record
    _ = try RockchipProductBindingStore(rootURL: rockchipRoot).install(
      RockchipProductBindingSnapshot(
        revision: 2,
        serial: serial,
        usbTopology: "17956864",
        evidence: [
          "identity:serial-sha256=\(currentIdentity)",
          "rebind:user-selection-sha256=\(String(repeating: "b", count: 64))",
          "identity:previous-serial-sha256=\(previousIdentity)",
          "binding:previous-revision=1",
          "binding:previous-usb-topology=18874368",
        ]))

    let process = try launchProductionDaemon(binary: binary, stateDirectory: daemonState)
    defer {
      if process.isRunning { process.terminate() }
    }
    let socketURL = daemonState.appending(path: "agentd.sock")
    let client = AgentClient(socketPath: socketURL.path)
    guard case .object(let health) = try client.request(method: "health") else {
      return XCTFail("the reconciled production daemon must answer health")
    }
    XCTAssertEqual(health["status"], .string("ok"))

    let reconciled = try XCTUnwrap(
      RuntimeTargetStore(
        directoryURL: daemonState.appending(path: "targets", directoryHint: .isDirectory)
      ).find(targetID: adopted.targetID))
    XCTAssertEqual(reconciled.targetID, adopted.targetID)
    XCTAssertEqual(reconciled.connectKey, adopted.connectKey)
    XCTAssertEqual(reconciled.stablePhysicalIdentitySHA256, currentIdentity)
    XCTAssertEqual(reconciled.bindingRevision, 2)
  }

  /// The companion case. An "unavailable, and here is the blocker" assertion
  /// is only worth anything if configuring the missing piece removes that
  /// blocker; otherwise the test passes on a daemon that is permanently
  /// refusing for some unrelated reason. Same binary, one declared
  /// environment difference.
  func testConfiguredHDCDoesNotPublishFlashWhenTheArkForgeLaneIsAbsent() throws {
    let binary = productsDirectory.appending(path: "arkdeck-agentd")
    guard FileManager.default.fileExists(atPath: binary.path) else {
      throw XCTSkip("arkdeck-agentd binary not built")
    }
    let shortState = URL(filePath: NSHomeDirectory())
      .appending(
        path: ".arkdeck-test-\(UInt32.random(in: 0..<100_000))", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: shortState) }
    // The production composition now establishes a real foreground server
    // before opening UDS. Use the executable fixture so startup exercises the
    // exact descriptor-bound `-s 127.0.0.1:8710 -m` plus typed checkserver
    // readiness path instead of relying on a path-presence placeholder.
    let hdcFixture = productsDirectory.appending(path: "ArkDeckFakeHDCFixture")
    guard FileManager.default.isExecutableFile(atPath: hdcFixture.path) else {
      throw XCTSkip("ArkDeckFakeHDCFixture binary not built")
    }

    let hdcPort = try availableDaemonLoopbackPort()
    let process = try launchProductionDaemon(
      binary: binary, stateDirectory: shortState, hdcPath: hdcFixture.path,
      extraEnvironment: ["OHOS_HDC_SERVER_PORT": String(hdcPort)])
    defer {
      if process.isRunning { process.terminate() }
    }
    let socketURL = shortState.appending(path: "agentd.sock")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: socketURL.path), "daemon never created its socket")
    let operations = try listOperations(socketPath: socketURL.path)

    // Depends on nothing but the variable this case sets: the HDC provider's
    // own availability is unconditional, so the refusing dispatcher is the
    // only thing that can block observation.
    guard let observe = operations["observe.device@1"] else {
      return XCTFail("production daemon must publish observe.device@1 availability")
    }
    XCTAssertEqual(
      observe.availability, "available",
      "a configured ARKDECK_HDC_PATH must admit observation: \(observe.reasons)")

    // The Rockchip half. HDC alone is not a Flash lane: both the generic
    // operation and the compatibility alias must publish the same startup
    // composition failure instead of claiming that a dispatcher which has no
    // live controller can execute them.
    for reference in ["flash.full-restore@1", "flash.dayu200"] {
      guard let flash = operations[reference] else {
        return XCTFail("production daemon must publish \(reference) availability")
      }
      XCTAssertEqual(flash.availability, "unavailable", reference)
      XCTAssertTrue(
        flash.reasons.contains {
          $0.contains("ARKDECK_ARKFORGE_BUNDLE_PATH is unset")
        },
        "\(reference) must name the absent lane configuration: \(flash.reasons)")
      XCTAssertTrue(
        flash.reasonCodes.contains("provider_tool_unavailable"),
        "\(reference) must classify the missing lane as host configuration")
      XCTAssertTrue(flash.reasonOrigins.contains("host_configuration"), reference)
      XCTAssertFalse(
        flash.reasons.contains { $0.contains("requires descriptor-bound HDC") },
        "configured HDC must retire its own blocker: \(flash.reasons)")
    }

    process.terminate()
    let stopDeadline = Date().addingTimeInterval(10)
    while process.isRunning && Date() < stopDeadline { usleep(50_000) }
    XCTAssertFalse(process.isRunning, "SIGTERM must stop the daemon")
  }

  func testWaterFlowProductionProfilePublishesTheClosedWorkspaceOperations() throws {
    let binary = productsDirectory.appending(path: "arkdeck-agentd")
    guard FileManager.default.fileExists(atPath: binary.path) else {
      throw XCTSkip("arkdeck-agentd binary not built")
    }
    let shortState = URL(filePath: NSHomeDirectory())
      .appending(
        path: ".arkdeck-test-\(UInt32.random(in: 0..<100_000))", directoryHint: .isDirectory)
    let project = URL(filePath: NSHomeDirectory())
      .appending(
        path: ".arkdeck-waterflow-\(UInt32.random(in: 0..<100_000))", directoryHint: .isDirectory)
    let module = project.appending(path: "entry/src/main", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: project.appending(path: "build-profile.json5"))
    try Data("{}".utf8).write(to: module.appending(path: "module.json5"))
    let hvigor = project.appending(path: "hvigorw.js")
    try Data("// fixture".utf8).write(to: hvigor)
    let sdk = project.appending(path: "sdk/default/openharmony", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: shortState)
      try? FileManager.default.removeItem(at: project)
    }

    let process = try launchProductionDaemon(
      binary: binary, stateDirectory: shortState,
      extraEnvironment: [
        "ARKDECK_WORKSPACE_PROJECTS": "demo-app=\(project.path)",
        "ARKDECK_WORKSPACE_ACTIVE_PROJECT": "demo-app",
        "ARKDECK_DEVECO_NODE_PATH": "/usr/bin/true",
        "ARKDECK_DEVECO_HVIGOR_PATH": hvigor.path,
        "ARKDECK_DEVECO_SDK_HOME": project.appending(path: "sdk").path,
      ])
    defer { if process.isRunning { process.terminate() } }
    let socketURL = shortState.appending(path: "agentd.sock")
    XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
    let operations = try listOperations(socketPath: socketURL.path)
    for reference in [
      "workspace.apply-patch@1", "workspace.build-openharmony@1",
      "workspace.run-tests@1", "workspace.revert-patch@1",
      "workspace.read-source-range@1",
    ] {
      XCTAssertEqual(
        operations[reference]?.availability, "available",
        "\(reference): \(operations[reference]?.reasons ?? [])")
    }
  }

  func testWaterFlowProductionProfileFailsClosedWhenItsSDKIsAbsent() throws {
    let binary = productsDirectory.appending(path: "arkdeck-agentd")
    guard FileManager.default.fileExists(atPath: binary.path) else {
      throw XCTSkip("arkdeck-agentd binary not built")
    }
    let shortState = URL(filePath: NSHomeDirectory())
      .appending(
        path: ".arkdeck-test-\(UInt32.random(in: 0..<100_000))", directoryHint: .isDirectory)
    let project = URL(filePath: NSHomeDirectory())
      .appending(
        path:
          ".arkdeck-waterflow-\(UInt32.random(in: 0..<100_000))", directoryHint: .isDirectory)
    let module = project.appending(path: "entry/src/main", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: project.appending(path: "build-profile.json5"))
    try Data("{}".utf8).write(to: module.appending(path: "module.json5"))
    let hvigor = project.appending(path: "hvigorw.js")
    try Data("// fixture".utf8).write(to: hvigor)
    defer {
      try? FileManager.default.removeItem(at: shortState)
      try? FileManager.default.removeItem(at: project)
    }

    let process = try launchProductionDaemon(
      binary: binary, stateDirectory: shortState,
      extraEnvironment: [
        "ARKDECK_WORKSPACE_PROJECTS": "demo-app=\(project.path)",
        "ARKDECK_WORKSPACE_ACTIVE_PROJECT": "demo-app",
        "ARKDECK_DEVECO_NODE_PATH": "/usr/bin/true",
        "ARKDECK_DEVECO_HVIGOR_PATH": hvigor.path,
        "ARKDECK_DEVECO_SDK_HOME": project.appending(path: "missing-sdk").path,
      ])
    defer { if process.isRunning { process.terminate() } }
    let operations = try listOperations(
      socketPath: shortState.appending(path: "agentd.sock").path)
    let build = try XCTUnwrap(operations["workspace.build-openharmony@1"])

    XCTAssertEqual(build.availability, "unavailable")
    XCTAssertTrue(
      build.reasons.contains { $0.contains("DevEco OpenHarmony SDK is absent") },
      "missing SDK must be a startup availability blocker: \(build.reasons)")
  }

  /// The two blockers the production Rockchip composition can publish with no
  /// HDC configured. Which one answers depends on whether the native ArkForge
  /// lane environment is complete: the resolver refuses first when it is not;
  /// otherwise the per-action host names its missing descriptor-bound HDC.
  /// Both prove the route is installed and fails closed.
  private static let unconfiguredRockchipBlockers = [
    "ArkForge native RockUSB identity is unavailable",
    "the per-action RockUSB host requires descriptor-bound HDC and a product state directory",
  ]

  private struct DaemonOperation {
    let availability: String
    let reasons: [String]
    let reasonCodes: [String]
    let reasonOrigins: [String]
  }

  private func listOperations(socketPath: String) throws -> [String: DaemonOperation] {
    let client = AgentClient(socketPath: socketPath)
    guard case .array(let operations) = try client.request(method: "operation.list") else {
      return [:]
    }
    return operations.reduce(into: [:]) { table, item in
      guard case .object(let fields) = item,
        case .string(let reference)? = fields["reference"],
        case .string(let availability)? = fields["availability"],
        case .array(let reasons)? = fields["reasons"],
        case .array(let reasonCodes)? = fields["reasonCodes"],
        case .array(let reasonOrigins)? = fields["reasonOrigins"]
      else { return }
      table[reference] = DaemonOperation(
        availability: availability,
        reasons: reasons.compactMap { reason in
          guard case .string(let text) = reason else { return nil }
          return text
        },
        reasonCodes: reasonCodes.compactMap { code in
          guard case .string(let text) = code else { return nil }
          return text
        },
        reasonOrigins: reasonOrigins.compactMap { origin in
          guard case .string(let text) = origin else { return nil }
          return text
        })
    }
  }

  /// Spawns the real daemon with a *declared* environment. `Process` inherits
  /// the caller's environment, and the composition root branches on
  /// ARKDECK_* keys to decide which dispatcher, host and provider it builds -
  /// so a daemon spawned bare answers according to whatever the developer
  /// happened to export, and the test states none of it. Every ARKDECK_ key
  /// is stripped; a case that needs one puts it back by name. The child also
  /// receives a private Foundation home under its explicit test state root:
  /// real daemon tests run in parallel, and their Application Support or
  /// UserDefaults state must not share the ambient runner account.
  private func launchProductionDaemon(
    binary: URL, stateDirectory: URL, hdcPath: String? = nil,
    extraEnvironment: [String: String] = [:]
  ) throws -> Process {
    let process = Process()
    process.executableURL = binary
    process.arguments = ["--state-dir", stateDirectory.path]
    var environment = ProcessInfo.processInfo.environment.filter {
      !$0.key.hasPrefix("ARKDECK_")
    }
    let processHome =
      stateDirectory
      .appending(path: "process-home", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: processHome, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    environment["HOME"] = processHome.path
    environment["CFFIXED_USER_HOME"] = processHome.path
    if let hdcPath { environment["ARKDECK_HDC_PATH"] = hdcPath }
    environment.merge(extraEnvironment) { _, configured in configured }
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()

    let socketURL = stateDirectory.appending(path: "agentd.sock")
    let deadline = Date().addingTimeInterval(20)
    while !FileManager.default.fileExists(atPath: socketURL.path) {
      guard Date() < deadline, process.isRunning else { break }
      usleep(50_000)
    }
    return process
  }

  private var productsDirectory: URL {
    #if os(macOS)
      for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        return bundle.bundleURL.deletingLastPathComponent()
      }
    #endif
    return Bundle.main.bundleURL
  }

  /// `job.cancel` used to answer every failure with `notFound: unknown job`.
  /// Cancelling persists a decision, so it can fail long after the job was
  /// found — and claiming the job does not exist, while its steps may still be
  /// running, is the worst available answer: the caller cannot tell which gate
  /// refused and has no reason to retry. `job.reconcile` was corrected for
  /// exactly this; `job.cancel` was not.
  func testCancelReportsARefusalRatherThanClaimingTheJobIsMissing() async throws {
    let (handler, _) = try makeStack()
    let submitJSON = """
      {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
      "requestId":"req-cancel-map","idempotencyKey":"idem-cancel-map-01",\
      "target":{"targetId":"TGT-CANCEL-01","expectedBindingRevision":7},\
      "operation":{"id":"observe.device","version":1}}
      """
    let submitted = try await request(
      handler, method: "job.submit", params: ["requestJson": .string(submitJSON)])
    guard case .object(let submitFields)? = submitted.result,
      case .string(let jobID)? = submitFields["jobId"]
    else {
      return XCTFail("submit must return a job id")
    }

    // The correct half must not regress: a genuinely absent job is notFound.
    let absent = try await request(
      handler, method: "job.cancel", params: ["jobId": .string("JOB-DOES-NOT-EXIST")])
    XCTAssertFalse(absent.ok)
    XCTAssertEqual(absent.error?.code, "notFound")

    // The job exists, but its durable record can no longer be written: the
    // atomic record write needs to create a temporary file in the job's own
    // directory. This is a real failure of the persistence `requestCancel`
    // performs, not a stubbed error.
    let jobDirectory = stateDirectory
      .appending(path: "engine", directoryHint: .isDirectory)
      .appending(path: "jobs", directoryHint: .isDirectory)
      .appending(path: jobID, directoryHint: .isDirectory)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: jobDirectory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: jobDirectory.path)
    }

    let refused = try await request(
      handler, method: "job.cancel", params: ["jobId": .string(jobID)])
    XCTAssertFalse(refused.ok)
    // The property under test is that the job is not reported as missing. The
    // exact code follows the failure kind, matching `job.reconcile`: an engine
    // gate refusal is `rejected`, and a persistence failure like this one —
    // which surfaces as a Foundation file error, not a `RuntimeJobEngineError`
    // — is `internalError`. Either is actionable; `notFound` is not.
    XCTAssertNotEqual(
      refused.error?.code, "notFound",
      "a cancel that failed after the job was found must not be reported as a missing job")
    XCTAssertEqual(refused.error?.code, "internalError")
    XCTAssertTrue(
      (refused.error?.message ?? "").isEmpty == false,
      "the refusal must name the failure so the caller can see which gate refused")
  }

  /// The other half of the same property. A job whose outcome is known and
  /// terminal is released from the engine's in-memory table and served from
  /// SQLite afterwards, so `requestCancel` reading residency as existence made
  /// the answer depend on how long ago the job finished: cancelling it was a
  /// silent no-op while still resident, then `notFound: unknown job` once
  /// released. Two RPCs on one daemon then disagreed about whether the job
  /// existed, and the caller was told its effects never happened.
  func testCancellingAFinishedJobDoesNotClaimItNeverExisted() async throws {
    let (handler, _) = try makeStack()
    let submitJSON = """
      {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
      "requestId":"req-cancel-terminal","idempotencyKey":"idem-cancel-terminal-01",\
      "target":{"targetId":"TGT-CANCEL-02","expectedBindingRevision":7},\
      "operation":{"id":"observe.device","version":1}}
      """
    let submitted = try await request(
      handler, method: "job.submit", params: ["requestJson": .string(submitJSON)])
    guard case .object(let submitFields)? = submitted.result,
      case .string(let jobID)? = submitFields["jobId"]
    else {
      return XCTFail("submit must return a job id")
    }
    let ran = try await request(handler, method: "job.run", params: ["jobId": .string(jobID)])
    guard case .object(let runFields)? = ran.result,
      case .string("succeeded")? = runFields["state"]
    else {
      return XCTFail("the job must reach a terminal state before it can be released")
    }

    // Reading the status is what releases a known-outcome terminal runtime,
    // and the released state is the one this test is about. `jobs` is private,
    // so the release is not asserted directly; the coverage evidence is that
    // this test fails with `notFound` against the engine before the fix.
    _ = try await request(handler, method: "job.status", params: ["jobId": .string(jobID)])

    let cancelled = try await request(
      handler, method: "job.cancel", params: ["jobId": .string(jobID)])
    XCTAssertTrue(
      cancelled.ok,
      "cancelling a finished job is a no-op, and must stay one after it leaves memory")
    XCTAssertNotEqual(
      cancelled.error?.code, "notFound",
      "the job is still in SQLite; reporting it as missing contradicts job.status")

    // And the record still agrees it succeeded: the no-op cancel rewrote
    // nothing.
    let after = try await request(handler, method: "job.status", params: ["jobId": .string(jobID)])
    guard case .object(let afterFields)? = after.result else {
      return XCTFail("status must still answer after the no-op cancel")
    }
    XCTAssertEqual(afterFields["state"], .string("succeeded"))
  }

  /// `job.list-page` answered every unexpected failure with `invalidParams`.
  /// That was right for one case and wrong for the rest: a malformed cursor is
  /// the caller's mistake, but a daemon that cannot read its own history is
  /// not, and telling that caller to fix its parameters sends it to correct a
  /// request that was already correct. The cursor is now checked with the
  /// other parameters, so it stays the caller's error by name rather than by
  /// arriving as a storage failure.
  func testAMalformedCursorIsTheCallersErrorAndSaysSo() async throws {
    let (handler, _) = try makeStack()
    for bad in ["abc", "-1", "", "12x", "9999999999999999999999"] {
      let response = try await request(
        handler, method: "job.list-page",
        params: ["cursor": .string(bad), "pageSize": .integer(10)])
      XCTAssertFalse(response.ok, "cursor \(bad) must not be accepted")
      XCTAssertEqual(
        response.error?.code, "invalidParams",
        "a bad cursor is the request's fault, not the store's: \(bad)")
    }

    // A well-formed cursor still reaches the store and is answered normally.
    let good = try await request(
      handler, method: "job.list-page",
      params: ["cursor": .string("0"), "pageSize": .integer(10)])
    XCTAssertTrue(good.ok, "a valid cursor must still be served")
  }

  /// An operator reading `operation.list` could not tell "install something
  /// and this works" from "no installation will ever make this work". Both
  /// arrive as `unavailable` with a short reason, so both get investigated the
  /// same way and the second search is wasted. Every code now states which
  /// side it falls on.
  func testEveryReasonCodeSaysWhoCanChangeTheAnswer() {
    // Installing, registering or repinning something on this host reaches all
    // of these.
    for code: RuntimeAvailabilityReasonCode in [
      .providerToolUnavailable, .toolIdentityDrift, .workspacePresetUnavailable,
      .artifactStoreUnavailable,
    ] {
      XCTAssertEqual(code.origin, .hostConfiguration, code.rawValue)
    }
    // Nothing local reaches these: the shipped build has no implementation, or
    // declines to offer one.
    for code: RuntimeAvailabilityReasonCode in [
      .providerNotRegistered, .operationNotSupported, .workspacePresetNotOffered,
    ] {
      XCTAssertEqual(code.origin, .productBuild, code.rawValue)
    }
    // Stated over the whole vocabulary so a new code cannot default into
    // either side by being forgotten here.
    XCTAssertEqual(
      RuntimeAvailabilityReasonCode.allCases.count, 7,
      "a new reason code must be classified in this test as well as in `origin`")
  }

  /// The two workspace situations that used to share one code. Registering a
  /// project or installing the signing preset is an operator's job; a profile
  /// that ships no symbolizer is not, and no amount of local setup reaches it.
  func testAWorkspacePresetTheBuildDoesNotOfferIsNotAnOperatorsToInstall() {
    XCTAssertEqual(
      RuntimeAvailabilityReasonCode.workspacePresetUnavailable.origin, .hostConfiguration)
    XCTAssertEqual(
      RuntimeAvailabilityReasonCode.workspacePresetNotOffered.origin, .productBuild)
    XCTAssertNotEqual(
      RuntimeAvailabilityReasonCode.workspacePresetUnavailable,
      RuntimeAvailabilityReasonCode.workspacePresetNotOffered,
      "the whole point is that these two are no longer the same answer")
  }

  // MARK: damage is not absence

  /// `notFound` is the one reply a caller cannot act on except by concluding
  /// the thing was never produced. For an Artifact that conclusion is
  /// expensive: the recovery is to re-run the operation that produced it,
  /// which for a device operation is a repeated real effect — in response to
  /// what may be a local disk problem. So only a genuinely missing Artifact
  /// may be `notFound`.
  func testOnlyAMissingArtifactIsReportedAsAbsent() {
    XCTAssertEqual(
      RuntimeControlPlaneHandler.artifactErrorCode(.artifactNotFound("ART-1")), .notFound)

    // A damaged store is unreadable, not empty.
    XCTAssertEqual(
      RuntimeControlPlaneHandler.artifactErrorCode(.indexCorrupted("bad json")),
      .recordUnreadable)
    XCTAssertEqual(
      RuntimeControlPlaneHandler.artifactErrorCode(.ioFailure("EIO")), .internalError)

    // Gates that refused a request about an Artifact that exists.
    for refusal: RuntimeArtifactError in [
      .sensitiveAccessRequiresOptIn("trace"), .exportDestinationRejected("/etc"),
      .quotaExceeded(requestedBytes: 2, remainingBytes: 1),
      .evidenceVerificationFailed("digest"),
    ] {
      XCTAssertEqual(
        RuntimeControlPlaneHandler.artifactErrorCode(refusal), .rejected, "\(refusal)")
    }
    XCTAssertEqual(
      RuntimeControlPlaneHandler.artifactErrorCode(.artifactConflict("ART-1")), .conflict)
  }

  /// The same rule for a debug invocation. `load` throws
  /// `persistenceFailure("invalid invocation document")` for a document it
  /// cannot decode, and reporting that as a missing invocation hides the
  /// damage behind a routine-looking answer.
  func testOnlyAMissingInvocationIsReportedAsAbsent() {
    XCTAssertEqual(
      RuntimeControlPlaneHandler.debugInvocationErrorCode(.invocationNotFound("INV-1")),
      .notFound)
    XCTAssertEqual(
      RuntimeControlPlaneHandler.debugInvocationErrorCode(.persistenceFailure("invalid")),
      .recordUnreadable)
    for refusal: RuntimeDebugInvocationError in [
      .invalidSeedRequest("x"), .invalidCandidate("x"), .invalidProvenance("x"),
      .invocationNotActive("expired"), .invocationExpired, .epochBudgetExhausted,
      .evaluationAlreadyRunning, .predecessorBlocksContinuation("INV-0"),
    ] {
      XCTAssertEqual(
        RuntimeControlPlaneHandler.debugInvocationErrorCode(refusal), .rejected, "\(refusal)")
    }
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
    XCTAssertEqual(statusFields["executionMode"], .string("execute"))
    XCTAssertEqual(statusFields["sessionId"], .string("session-\(jobID)"))
    XCTAssertEqual(statusFields["actualEffect"], .string("readOnly"))
    XCTAssertNotEqual(statusFields["createdAtUtc"], .null)
    XCTAssertNotEqual(statusFields["startedAtUtc"], .null)
    XCTAssertNotEqual(statusFields["finishedAtUtc"], .null)
  }

  func testUnreadableJobRecordHasDistinctWireErrorFromMissingJob() async throws {
    let jobID: String
    do {
      let (handler, _) = try makeStack()
      let activeServer = try startServer(handler)
      let client = AgentClient(socketPath: activeServer.socketURL.path)
      let request = """
        {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
        "requestId":"req-unreadable-wire","idempotencyKey":"idem-unreadable-wire-01",\
        "target":{"targetId":"TGT-UNREADABLE-01","expectedBindingRevision":7},\
        "operation":{"id":"observe.device","version":1}}
        """
      guard
        case .object(let submitFields) = try client.request(
          method: "job.submit", params: ["requestJson": .string(request)]),
        case .string(let acceptedJobID)? = submitFields["jobId"]
      else {
        return XCTFail("submit must return a job id")
      }
      jobID = acceptedJobID
      _ = try client.request(method: "job.run", params: ["jobId": .string(jobID)])
      activeServer.stop()
      self.server = nil
    }
    try RuntimeJobSQLiteTestSupport.replaceInitialRecord(
      stateDirectory: stateDirectory.appending(path: "engine", directoryHint: .isDirectory),
      jobID: jobID, data: Data("not-json".utf8))

    let (freshHandler, _) = try makeStack()
    let freshServer = try startServer(freshHandler)
    let client = AgentClient(socketPath: freshServer.socketURL.path)
    for (method, params) in [
      ("job.status", ["jobId": JSONValue.string(jobID)]),
      ("job.list", nil),
      ("job.list-page", ["pageSize": JSONValue.integer(100)]),
    ] as [(String, [String: JSONValue]?)] {
      do {
        _ = try client.request(method: method, params: params)
        XCTFail("\(method) must fail loudly on a corrupt Runtime job record")
      } catch AgentClientError.daemonError(let code, let message) {
        XCTAssertEqual(code, AgentDaemonErrorCode.recordUnreadable.rawValue)
        XCTAssertTrue(message.contains(jobID))
      }
    }

    do {
      _ = try client.request(
        method: "job.status", params: ["jobId": .string("job-that-never-existed")])
      XCTFail("a genuinely missing job must remain notFound")
    } catch AgentClientError.daemonError(let code, _) {
      XCTAssertEqual(code, AgentDaemonErrorCode.notFound.rawValue)
    }
  }

  func testGracefulDrainCompletesInFlightJobBeforeReleasingTheDaemonLock() async throws {
    let dispatcher = GatedDispatcher()
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { "2026-07-29T00:00:00Z" })
    let (handler, _) = try makeStack(
      artifactStore: artifactStore, dispatcher: dispatcher)
    let server = try startServer(handler)
    let client = AgentClient(socketPath: server.socketURL.path)
    let request = """
      {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
      "requestId":"req-drain","idempotencyKey":"idem-drain-01",\
      "target":{"targetId":"TGT-DRAIN-01","expectedBindingRevision":7},\
      "operation":{"id":"observe.device","version":1}}
      """
    guard
      case .object(let submitFields) = try client.request(
        method: "job.submit", params: ["requestJson": .string(request)]),
      case .string(let jobID)? = submitFields["jobId"]
    else {
      return XCTFail("submit must return a job id")
    }

    let waitingClient = Task.detached { () -> JSONValue? in
      try? client.request(method: "job.run", params: ["jobId": .string(jobID)])
    }
    // Anti-hang bound, not a contract bound. What this buys is not elapsed
    // time but a known position: the request is now in flight and parked
    // inside the dispatcher, and it stays parked until this test releases it,
    // so the drain below cannot race the job to completion.
    let arrived = await waitForSemaphore(
      dispatcher.dispatchArrived, timeout: daemonRendezvousTimeout)
    XCTAssertEqual(
      arrived, .success,
      "the daemon must observe the in-flight Runtime request before draining")

    // Drain from another thread so the fixture can observe that it blocks.
    let drainReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      server.drainAndStop(deadline: daemonRendezvousTimeout)
      drainReturned.signal()
    }
    // Deliberately short, and deliberately not the anti-hang bound: this is
    // the invariant. The job cannot reach its terminal state while it is
    // parked, so a drain that has already returned here released the daemon
    // lock with an accepted request still in flight. Host load only delays
    // the drain further, so it can only reinforce this assertion — which is
    // why the load that broke the old wall-clock budget cannot break this one.
    let drainedEarly = await waitForSemaphore(drainReturned, timeout: 0.1)
    XCTAssertEqual(
      drainedEarly, .timedOut,
      "the daemon released its lock while the accepted request was still in flight")

    // Release the parked work: from here the drain must return on its own,
    // and it returns because the request drained, not because a clock expired.
    dispatcher.release()
    let drained = await waitForSemaphore(drainReturned, timeout: daemonRendezvousTimeout)
    XCTAssertEqual(
      drained, .success,
      "the drain must return once the in-flight request has crossed its durable boundaries")
    self.server = nil
    guard case .object(let result)? = await waitingClient.value,
      case .string(let state)? = result["state"]
    else {
      return XCTFail("the waiting client must receive the completed Runtime status")
    }
    XCTAssertEqual(state, "succeeded")
    XCTAssertFalse(FileManager.default.fileExists(atPath: server.socketURL.path))

    // The accepted request must drain through the durable state layers before
    // the daemon releases its lock: its journal is replayable and its
    // published evidence remains addressable after the client socket closes.
    let journalURL =
      stateDirectory
      .appending(path: "engine/jobs/\(jobID)/journal.jsonl")
    let journal = try DurableJournalRecovery.inspect(url: journalURL)
    XCTAssertFalse(journal.hasTornTail)
    XCTAssertTrue(journal.outstandingIntents.isEmpty)
    let artifacts = try await artifactStore.list(jobID: jobID)
    XCTAssertFalse(artifacts.isEmpty)

    let (_, reopened) = try makeStack()
    let recovered = try await reopened.recoverPersistedJobs()
    XCTAssertEqual(recovered.map(\.jobID), [jobID])
    XCTAssertEqual(recovered.map(\.state), ["succeeded"])
  }

  /// Artifact identity is ID-only by construction. Export accepts only a
  /// destination directory; no caller path can substitute the stored source.
  /// A store-less composition
  /// refuses rather than answering with an empty list (which would read as
  /// "this job produced nothing").
  func testArtifactMethodsAreIDOnlyAndFailClosedWithoutAStore() async throws {
    let (handler, _) = try makeStack(includeDefaultArtifactStore: false)
    for method in [
      "artifact.importHap.begin", "artifact.importHap.append",
      "artifact.importHap.commit", "artifact.importNativeLibrary.begin",
      "artifact.importNativeLibrary.append",
      "artifact.importNativeLibrary.commit", "artifact.importFlashBundle.begin",
      "artifact.importFlashBundle.append", "artifact.importFlashBundle.commit",
      "artifact.importWorkspacePatch.begin", "artifact.importWorkspacePatch.append",
      "artifact.importWorkspacePatch.commit",
      "artifact.list", "artifact.inspect",
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

  func testWorkspacePatchImportPublishesBoundedTargetCorrelatedLease() async throws {
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appending(path: "targets", directoryHint: .isDirectory))
    let target = try targetStore.adopt(
      stableIdentitySHA256: String(repeating: "a", count: 64),
      connectKey: "150100424a544e4600",
      toolVersion: "3.2.0f",
      nowUTC: "2026-08-15T00:00:00Z"
    ).record
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { "2026-08-15T00:00:00Z" })
    let (handler, _) = try makeStack(
      targetStore: targetStore, artifactStore: artifactStore)
    let patch = Data(
      """
      diff --git a/entry/src/main/ets/pages/Index.ets b/entry/src/main/ets/pages/Index.ets
      --- a/entry/src/main/ets/pages/Index.ets
      +++ b/entry/src/main/ets/pages/Index.ets
      @@ -1,2 +1 @@
      -console.info('diagnostic')
       keep()
      """.utf8)
    let digest = SHA256.hash(data: patch)
      .map { String(format: "%02x", $0) }.joined()

    let begin = try await request(
      handler,
      method: "artifact.importWorkspacePatch.begin",
      params: [
        "targetId": .string(target.targetID),
        "name": .string("remove-diagnostic.patch"),
        "byteCount": .integer(Int64(patch.count)),
        "sha256": .string(digest),
      ])
    XCTAssertTrue(begin.ok, begin.error?.message ?? "-")
    guard case .object(let beginFields)? = begin.result,
      case .string(let uploadID)? = beginFields["uploadId"]
    else {
      return XCTFail("begin must return an upload identity")
    }
    let append = try await request(
      handler,
      method: "artifact.importWorkspacePatch.append",
      params: [
        "uploadId": .string(uploadID),
        "offset": .integer(0),
        "base64": .string(patch.base64EncodedString()),
      ])
    XCTAssertTrue(append.ok, append.error?.message ?? "-")

    let commit = try await request(
      handler,
      method: "artifact.importWorkspacePatch.commit",
      params: ["uploadId": .string(uploadID)])
    XCTAssertTrue(commit.ok, commit.error?.message ?? "-")
    guard case .object(let fields)? = commit.result,
      case .string(let jobID)? = fields["jobId"],
      case .string(let artifactID)? = fields["artifactId"],
      case .string(let lease)? = fields["lease"],
      case .array(let touchedFiles)? = fields["touchedFiles"]
    else {
      return XCTFail("commit must return the immutable patch identity")
    }
    XCTAssertEqual(fields["sha256"], .string(digest))
    XCTAssertEqual(fields["targetId"], .string(target.targetID))
    XCTAssertEqual(touchedFiles, [.string("entry/src/main/ets/pages/Index.ets")])
    XCTAssertEqual(lease, "lease-v1:\(jobID):\(artifactID)")
    XCTAssertFalse(lease.contains(stateDirectory.path))

    let metadata = try await artifactStore.inspect(jobID: jobID, artifactID: artifactID)
    XCTAssertEqual(metadata.mediaType, "text/x-diff")
    XCTAssertEqual(metadata.sourceOperation, "artifact.import-workspace-patch")
    XCTAssertEqual(metadata.bindingSnapshot.targetID, target.targetID)
    XCTAssertNil(metadata.bindingSnapshot.bindingRevision)
    XCTAssertNil(metadata.bindingSnapshot.stableIdentitySHA256)
    let resolution = try await artifactStore.resolveLease(lease)
    XCTAssertEqual(resolution.sha256, digest)
    XCTAssertEqual(try Data(contentsOf: resolution.fileURL), patch)
  }

  func testWorkspacePatchImportRejectsUnknownTargetAndUnsafeDiffWithoutPublication() async throws {
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appending(path: "targets", directoryHint: .isDirectory))
    let target = try targetStore.adopt(
      stableIdentitySHA256: String(repeating: "b", count: 64),
      connectKey: "150100424a544e4600",
      toolVersion: "3.2.0f",
      nowUTC: "2026-08-15T00:00:00Z"
    ).record
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { "2026-08-15T00:00:00Z" })
    let (handler, _) = try makeStack(
      targetStore: targetStore, artifactStore: artifactStore)
    let unsafe = Data(
      """
      diff --git a/entry.bin b/entry.bin
      GIT binary patch
      literal 1
      A
      """.utf8)
    let digest = SHA256.hash(data: unsafe)
      .map { String(format: "%02x", $0) }.joined()

    let unknown = try await request(
      handler,
      method: "artifact.importWorkspacePatch.begin",
      params: [
        "targetId": .string("TGT-unknown"),
        "name": .string("unsafe.patch"),
        "byteCount": .integer(Int64(unsafe.count)),
        "sha256": .string(digest),
      ])
    XCTAssertFalse(unknown.ok)
    XCTAssertEqual(unknown.error?.code, "notFound")

    let begin = try await request(
      handler,
      method: "artifact.importWorkspacePatch.begin",
      params: [
        "targetId": .string(target.targetID),
        "name": .string("unsafe.patch"),
        "byteCount": .integer(Int64(unsafe.count)),
        "sha256": .string(digest),
      ])
    guard case .object(let beginFields)? = begin.result,
      case .string(let uploadID)? = beginFields["uploadId"]
    else {
      return XCTFail("begin must return an upload identity")
    }
    let append = try await request(
      handler,
      method: "artifact.importWorkspacePatch.append",
      params: [
        "uploadId": .string(uploadID),
        "offset": .integer(0),
        "base64": .string(unsafe.base64EncodedString()),
      ])
    XCTAssertTrue(append.ok)
    let commit = try await request(
      handler,
      method: "artifact.importWorkspacePatch.commit",
      params: ["uploadId": .string(uploadID)])
    XCTAssertFalse(commit.ok)
    XCTAssertEqual(commit.error?.code, "rejected")
    XCTAssertTrue((commit.error?.message ?? "").contains("unified diff"))

    let expectedJob =
      "input-workspace-patch-\(target.targetID)-\(digest.prefix(16))"
    let artifacts = try await artifactStore.list(jobID: expectedJob)
    XCTAssertTrue(artifacts.isEmpty)
  }

  func testChunkedHAPImportPublishesATargetBoundIDOnlyLease() async throws {
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appending(path: "targets", directoryHint: .isDirectory))
    let stableIdentity = String(repeating: "a", count: 64)
    let target = try targetStore.adopt(
      stableIdentitySHA256: stableIdentity,
      connectKey: "150100424a544e4600",
      toolVersion: "3.2.0f",
      nowUTC: "2026-07-29T00:00:00Z"
    ).record
    let aliasConnectKey = "150100424a544e4600-post-flash"
    let aliasIdentity = HDCObservationProviderAdapter.stableIdentitySHA256(
      connectKey: aliasConnectKey)
    let alias = try targetStore.adopt(
      stableIdentitySHA256: aliasIdentity,
      connectKey: aliasConnectKey,
      toolVersion: "3.2.0f",
      nowUTC: "2026-07-29T00:01:00Z"
    ).record
    _ = try targetStore.appendAliasResolution(
      RuntimeTargetAliasResolutionDraft(
        aliasTargetID: alias.targetID,
        aliasStableIdentitySHA256: alias.stablePhysicalIdentitySHA256,
        aliasBindingRevision: alias.bindingRevision,
        canonicalTargetID: target.targetID,
        canonicalStableIdentitySHA256: target.stablePhysicalIdentitySHA256,
        canonicalBindingRevision: target.bindingRevision,
        routedHDCIdentitySHA256: aliasIdentity,
        routedUSBTopology: "42",
        establishingFlashJobID: "job-hap-alias-0123456789abcdef",
        establishingFlashPlanDigestSHA256: String(repeating: "f", count: 64),
        confirmedStepIDs: [
          "enter-loader-mode", "flash-partitions", "verify-flash-readback",
          "reboot-device", "wait-for-hdc", "rebind-and-verify-build",
        ],
        coveredUnknownIntents: [],
        establishedAtUTC: "2026-07-29T00:02:00Z"))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
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
      case .integer(let returnedRevision)? = fields["bindingRevision"],
      case .string(let returnedIdentity)? = fields["stableIdentitySha256"]
    else {
      return XCTFail("commit must return the Artifact identity and lease")
    }
    XCTAssertEqual(returnedDigest, digest)
    XCTAssertEqual(returnedTarget, target.targetID)
    XCTAssertEqual(returnedRevision, Int64(target.bindingRevision))
    XCTAssertEqual(returnedIdentity, aliasIdentity)
    XCTAssertTrue(jobID.contains(String(aliasIdentity.prefix(16))))
    XCTAssertEqual(lease, "lease-v1:\(jobID):\(artifactID)")
    XCTAssertFalse(lease.contains(stateDirectory.path))

    let metadata = try await artifactStore.inspect(
      jobID: jobID, artifactID: artifactID)
    XCTAssertEqual(metadata.bindingSnapshot.targetID, target.targetID)
    XCTAssertEqual(metadata.bindingSnapshot.bindingRevision, target.bindingRevision)
    // The lease binds the HDC provider's proven post-Flash route, not the
    // canonical target's historical connect key or store identity.
    XCTAssertEqual(
      metadata.bindingSnapshot.stableIdentitySHA256,
      aliasIdentity)
    XCTAssertNotEqual(
      metadata.bindingSnapshot.stableIdentitySHA256, stableIdentity,
      "the store identity must not leak into an HDC-consumed lease")
    XCTAssertNotEqual(
      metadata.bindingSnapshot.stableIdentitySHA256,
      HDCObservationProviderAdapter.stableIdentitySHA256(connectKey: target.connectKey),
      "the canonical target's historical address must not override a proven alias route")
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
    XCTAssertEqual(
      inspectFields["stableIdentitySha256"],
      .string(aliasIdentity))

    // The import reply has always carried the lease; discovery did not, so an
    // Artifact found through `artifact.list`/`inspect` rather than imported in
    // this session could not be passed to any `artifactLease` input without
    // the caller reconstructing the grammar itself. Both projections now
    // answer the same way, and the answer is the one `resolveLease` accepts.
    XCTAssertEqual(inspectFields["lease"], .string(lease))

    let listed = try await request(
      handler, method: "artifact.list", params: ["jobId": .string(jobID)])
    guard case .array(let rows)? = listed.result,
      case .object(let row)? = rows.first(where: { value in
        guard case .object(let fields) = value else { return false }
        return fields["artifactId"] == .string(artifactID)
      })
    else {
      return XCTFail("artifact.list must project the imported Artifact")
    }
    XCTAssertEqual(row["lease"], .string(lease))
    // Discovery must not hand out a reference the store would refuse; a lease
    // taken straight from the listing has to resolve to the same bytes.
    let listedResolution = try await artifactStore.resolveLease(
      { if case .string(let value)? = row["lease"] { return value } else { return "" } }())
    XCTAssertEqual(listedResolution.sha256, digest)
  }

  func testHAPImportRejectsUnknownTargetAndInvalidContainerWithoutPublication() async throws {
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appending(path: "targets", directoryHint: .isDirectory))
    let target = try targetStore.adopt(
      stableIdentitySHA256: String(repeating: "b", count: 64),
      connectKey: "150100424a544e4600",
      toolVersion: "3.2.0f",
      nowUTC: "2026-07-29T00:00:00Z"
    ).record
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
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
      + String(
        HDCObservationProviderAdapter.stableIdentitySHA256(
          connectKey: target.connectKey
        ).prefix(16)) + "-"
      + String(digest.prefix(16))
    let artifacts = try await artifactStore.list(jobID: expectedJob)
    XCTAssertTrue(artifacts.isEmpty)
  }

  /// The production policy recognises no build in advance.
  ///
  /// It used to hold one candidate per published archive, matched by digest
  /// *before the file was read*. A firmware daily published after the last
  /// release therefore could not be imported at all — measured on 2026-08-05
  /// with `7.0.0.37`, which fitted the board with no structural violation and
  /// was refused by nineteen hash mismatches against a build eight days older.
  ///
  /// What replaced it is not "no checking": the archive is decompressed,
  /// hashed, its partition table parsed and its runtime version read, and it
  /// must fit the board. That work happens on commit, against the bytes, which
  /// is why nothing is pinned here.
  func testProductionFlashImportPolicyRecognisesNoBuildInAdvance() throws {
    let candidates = FlashBundleImportPolicy.production.candidates
    XCTAssertEqual(candidates.count, 1)
    XCTAssertNil(candidates[0].expectedByteCount)
    XCTAssertNil(candidates[0].expectedSHA256)

    // Any well-formed declaration is admissible, including the two builds that
    // used to be the only ones, and including one nobody has seen.
    for profile in [RockchipFlashProfile.dayu200] {
      XCTAssertNotNil(
        FlashBundleImportPolicy.production.candidate(
          byteCount: Int(profile.archiveSizeBytes), sha256: profile.archiveSHA256))
    }
    XCTAssertNotNil(
      FlashBundleImportPolicy.production.candidate(
        byteCount: 730_766_386,
        sha256: "8aad39a0c35c4513b28cbbf21e0c863f9670ed93c7602a59d1b44fdd0bf1da7a"))

    // And the judgement really is deferred to reading: a file that is not an
    // images archive is refused by the candidate's own validation.
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true)
    let notAnArchive = stateDirectory.appending(path: "not-an-archive.tar.gz")
    try Data(repeating: 0x41, count: 4_096).write(to: notAnArchive)
    XCTAssertThrowsError(try candidates[0].validate(notAnArchive))
  }

  func testChunkedFlashBundleImportAcceptsDailyFilenameAndPublishesCanonicalLease() async throws {
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appending(
        path:
          "targets-flash", directoryHint: .isDirectory))
    let stableIdentity = String(repeating: "e", count: 64)
    let target = try targetStore.adopt(
      stableIdentitySHA256: stableIdentity,
      connectKey: "150100424a544e4600",
      toolVersion: "3.2.0f",
      nowUTC: "2026-07-30T00:00:00Z"
    ).record
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(
        path:
          "artifacts-flash", directoryHint: .isDirectory),
      nowUTC: { "2026-07-30T00:00:00Z" })
    let bytes = Data("fixture-flash-bundle".utf8)
    let digest =
      SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let policy = FlashBundleImportPolicy(
      expectedByteCount: bytes.count,
      expectedSHA256: digest
    ) { url in
      guard try Data(contentsOf: url) == bytes else {
        throw FlashBundleArtifactImportError.invalidBundle("fixture bytes")
      }
      return FlashBundleImportValidation(
        byteCount: bytes.count, sha256: digest)
    }
    let (handler, _) = try makeStack(
      targetStore: targetStore, artifactStore: artifactStore,
      flashBundleImportPolicy: policy)

    let begin = try await request(
      handler, method: "artifact.importFlashBundle.begin",
      params: [
        "targetId": .string(target.targetID),
        "name": .string(
          "version-Daily_Version-OpenHarmony_7.0.0.35-20260728_180253-dayu200_img.tar.gz"),
        "byteCount": .integer(Int64(bytes.count)),
        "sha256": .string(digest),
      ])
    XCTAssertTrue(begin.ok, begin.error?.message ?? "-")
    guard case .object(let beginFields)? = begin.result,
      case .string(let uploadID)? = beginFields["uploadId"],
      case .integer(let maximumChunk)? = beginFields["maximumChunkBytes"]
    else {
      return XCTFail("flash begin must return a bounded upload identity")
    }
    XCTAssertEqual(
      maximumChunk,
      Int64(FlashBundleArtifactImportCoordinator.maximumChunkBytes))

    let wrongOffset = try await request(
      handler, method: "artifact.importFlashBundle.append",
      params: [
        "uploadId": .string(uploadID),
        "offset": .integer(1),
        "base64": .string(bytes.prefix(4).base64EncodedString()),
      ])
    XCTAssertFalse(wrongOffset.ok)
    XCTAssertTrue((wrongOffset.error?.message ?? "").contains("offset mismatch"))

    let split = 7
    for (offset, chunk) in [
      (0, bytes.subdata(in: 0..<split)),
      (split, bytes.subdata(in: split..<bytes.count)),
    ] {
      let appended = try await request(
        handler, method: "artifact.importFlashBundle.append",
        params: [
          "uploadId": .string(uploadID),
          "offset": .integer(Int64(offset)),
          "base64": .string(chunk.base64EncodedString()),
        ])
      XCTAssertTrue(appended.ok, appended.error?.message ?? "-")
    }
    let commit = try await request(
      handler, method: "artifact.importFlashBundle.commit",
      params: ["uploadId": .string(uploadID)])
    XCTAssertTrue(commit.ok, commit.error?.message ?? "-")
    guard case .object(let fields)? = commit.result,
      case .string(let jobID)? = fields["jobId"],
      case .string(let artifactID)? = fields["artifactId"],
      case .string(let lease)? = fields["lease"]
    else {
      return XCTFail("flash commit must return an ID-only Artifact lease")
    }
    XCTAssertEqual(fields["sha256"], .string(digest))
    XCTAssertEqual(fields["byteCount"], .integer(Int64(bytes.count)))
    XCTAssertEqual(fields["targetId"], .string(target.targetID))
    XCTAssertEqual(
      fields["bindingRevision"], .integer(Int64(target.bindingRevision)))
    XCTAssertFalse(lease.contains(stateDirectory.path))
    let metadata = try await artifactStore.inspect(
      jobID: jobID, artifactID: artifactID)
    XCTAssertEqual(
      metadata.name, "images.tar.gz",
      "caller filenames must neither gate import nor control the artifact namespace")
    XCTAssertEqual(metadata.mediaType, "application/gzip")
    XCTAssertEqual(metadata.bindingSnapshot.targetID, target.targetID)
    XCTAssertEqual(metadata.bindingSnapshot.bindingRevision, target.bindingRevision)
    XCTAssertEqual(metadata.bindingSnapshot.stableIdentitySHA256, stableIdentity)
    let resolved = try await artifactStore.resolveLease(lease)
    XCTAssertEqual(try Data(contentsOf: resolved.fileURL), bytes)
  }

  /// Where the judgement moved to.
  ///
  /// A declaration used to be matched against the archives the product
  /// enumerated, so an unrecognised build was refused before a byte was
  /// uploaded. Now a *malformed* declaration is still refused there — it can
  /// be judged without reading anything — while a well-formed one for a build
  /// nobody has seen is accepted and judged on commit, against its bytes.
  func testProductionFlashBundleImportRejectsMalformedFactsButNotUnknownBuilds()
    async throws
  {
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appending(
        path:
          "targets-flash-negative", directoryHint: .isDirectory))
    let target = try targetStore.adopt(
      stableIdentitySHA256: String(repeating: "f", count: 64),
      connectKey: "150100424a544e4600",
      toolVersion: "3.2.0f",
      nowUTC: "2026-07-30T00:00:00Z"
    ).record
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(
        path:
          "artifacts-flash-negative", directoryHint: .isDirectory),
      nowUTC: { "2026-07-30T00:00:00Z" })
    let (handler, _) = try makeStack(
      targetStore: targetStore, artifactStore: artifactStore)

    func begin(byteCount: Int64, sha256: String, name: String = "images.tar.gz") async throws
      -> AgentWireProtocol.Response
    {
      try await request(
        handler, method: "artifact.importFlashBundle.begin",
        params: [
          "targetId": .string(target.targetID),
          "name": .string(name),
          "byteCount": .integer(byteCount),
          "sha256": .string(sha256),
        ])
    }
    let digest = String(repeating: "0", count: 64)

    // Refused before the upload, on facts alone.
    for malformed in [Int64(0), Int64(-1)] {
      let response = try await begin(byteCount: malformed, sha256: digest)
      XCTAssertFalse(response.ok, "byteCount \(malformed)")
      XCTAssertEqual(response.error?.code, "invalidParams")
    }
    let oversized = try await begin(byteCount: 64 * 1_024 * 1_024 * 1_024, sha256: digest)
    XCTAssertFalse(oversized.ok)
    XCTAssertEqual(oversized.error?.code, "invalidParams")

    let malformedDigest = try await begin(byteCount: 730_766_386, sha256: "not-a-digest")
    XCTAssertFalse(malformedDigest.ok)
    XCTAssertEqual(malformedDigest.error?.code, "invalidParams")

    // A build the product has never seen is not malformed. It is admitted to
    // upload and judged when its bytes arrive — the 7.0.0.37 daily's own
    // declared facts, which no published profile enumerates.
    let unknownBuild = try await begin(
      byteCount: 730_766_386,
      sha256: "8aad39a0c35c4513b28cbbf21e0c863f9670ed93c7602a59d1b44fdd0bf1da7a")
    XCTAssertTrue(unknownBuild.ok, unknownBuild.error?.message ?? "-")

    let nameless = try await request(
      handler, method: "artifact.importFlashBundle.begin",
      params: [
        "targetId": .string(target.targetID),
        "byteCount": .integer(730_766_386),
        "sha256": .string(
          "8aad39a0c35c4513b28cbbf21e0c863f9670ed93c7602a59d1b44fdd0bf1da7a"),
      ])
    XCTAssertTrue(
      nameless.ok,
      "source name is optional metadata; archive bytes are judged on commit")
  }

  func testNativeLibraryImportValidatesELFAndPublishesBoundLease() async throws {
    let targetStore = try RuntimeTargetStore(
      directoryURL: stateDirectory.appending(
        path:
          "targets-native", directoryHint: .isDirectory))
    let stableIdentity = String(repeating: "d", count: 64)
    let target = try targetStore.adopt(
      stableIdentitySHA256: stableIdentity,
      connectKey: "150100424a544e4600",
      toolVersion: "3.2.0f",
      nowUTC: "2026-07-30T00:00:00Z"
    ).record
    let aliasConnectKey = "150100424a544e4600-post-flash-native"
    let aliasIdentity = HDCObservationProviderAdapter.stableIdentitySHA256(
      connectKey: aliasConnectKey)
    let alias = try targetStore.adopt(
      stableIdentitySHA256: aliasIdentity,
      connectKey: aliasConnectKey,
      toolVersion: "3.2.0f",
      nowUTC: "2026-07-30T00:01:00Z"
    ).record
    _ = try targetStore.appendAliasResolution(
      RuntimeTargetAliasResolutionDraft(
        aliasTargetID: alias.targetID,
        aliasStableIdentitySHA256: alias.stablePhysicalIdentitySHA256,
        aliasBindingRevision: alias.bindingRevision,
        canonicalTargetID: target.targetID,
        canonicalStableIdentitySHA256: target.stablePhysicalIdentitySHA256,
        canonicalBindingRevision: target.bindingRevision,
        routedHDCIdentitySHA256: aliasIdentity,
        routedUSBTopology: "43",
        establishingFlashJobID: "job-native-alias-0123456789abcdef",
        establishingFlashPlanDigestSHA256: String(repeating: "e", count: 64),
        confirmedStepIDs: [
          "enter-loader-mode", "flash-partitions", "verify-flash-readback",
          "reboot-device", "wait-for-hdc", "rebind-and-verify-build",
        ],
        coveredUnknownIntents: [],
        establishedAtUTC: "2026-07-30T00:02:00Z"))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(
        path:
          "artifacts-native", directoryHint: .isDirectory),
      nowUTC: { "2026-07-30T00:00:00Z" })
    let (handler, _) = try makeStack(
      targetStore: targetStore, artifactStore: artifactStore)
    let library = NativeLibraryTestFixture.arm64ELF()
    let digest = NativeLibraryTestFixture.sha256(library)

    let begin = try await request(
      handler, method: "artifact.importNativeLibrary.begin",
      params: [
        "targetId": .string(target.targetID),
        "name": .string("libarkdeck_gj.so"),
        "byteCount": .integer(Int64(library.count)),
        "sha256": .string(digest),
      ])
    XCTAssertTrue(begin.ok, begin.error?.message ?? "-")
    guard case .object(let beginFields)? = begin.result,
      case .string(let uploadID)? = beginFields["uploadId"]
    else {
      return XCTFail("native begin must return an upload identity")
    }
    let append = try await request(
      handler, method: "artifact.importNativeLibrary.append",
      params: [
        "uploadId": .string(uploadID),
        "offset": .integer(0),
        "base64": .string(library.base64EncodedString()),
      ])
    XCTAssertTrue(append.ok, append.error?.message ?? "-")
    let commit = try await request(
      handler, method: "artifact.importNativeLibrary.commit",
      params: ["uploadId": .string(uploadID)])
    XCTAssertTrue(commit.ok, commit.error?.message ?? "-")
    guard case .object(let fields)? = commit.result,
      case .string(let jobID)? = fields["jobId"],
      case .string(let artifactID)? = fields["artifactId"],
      case .string(let lease)? = fields["lease"]
    else {
      return XCTFail("native commit must return an ID-only lease")
    }
    XCTAssertEqual(fields["abi"], .string("arm64-v8a"))
    XCTAssertEqual(fields["buildId"], .string(NativeLibraryTestFixture.buildID))
    XCTAssertEqual(fields["sha256"], .string(digest))
    XCTAssertEqual(fields["stableIdentitySha256"], .string(aliasIdentity))
    XCTAssertTrue(jobID.contains(String(aliasIdentity.prefix(16))))
    XCTAssertEqual(lease, "lease-v1:\(jobID):\(artifactID)")
    XCTAssertFalse(lease.contains(stateDirectory.path))
    let metadata = try await artifactStore.inspect(
      jobID: jobID, artifactID: artifactID)
    XCTAssertEqual(metadata.mediaType, "application/x-elf")
    XCTAssertEqual(metadata.bindingSnapshot.targetID, target.targetID)
    XCTAssertEqual(metadata.bindingSnapshot.bindingRevision, target.bindingRevision)
    // Consumed by the HDC provider: the lease binds the same proven route as
    // plan materialization, like the HAP import above.
    XCTAssertEqual(
      metadata.bindingSnapshot.stableIdentitySHA256,
      aliasIdentity)

    let invalid = Data(repeating: 0x41, count: 128)
    let invalidDigest = NativeLibraryTestFixture.sha256(invalid)
    let invalidBegin = try await request(
      handler, method: "artifact.importNativeLibrary.begin",
      params: [
        "targetId": .string(target.targetID),
        "name": .string("libinvalid.so"),
        "byteCount": .integer(Int64(invalid.count)),
        "sha256": .string(invalidDigest),
      ])
    guard case .object(let invalidFields)? = invalidBegin.result,
      case .string(let invalidUploadID)? = invalidFields["uploadId"]
    else {
      return XCTFail("bounded invalid bytes should reach commit validation")
    }
    _ = try await request(
      handler, method: "artifact.importNativeLibrary.append",
      params: [
        "uploadId": .string(invalidUploadID),
        "offset": .integer(0),
        "base64": .string(invalid.base64EncodedString()),
      ])
    let invalidCommit = try await request(
      handler, method: "artifact.importNativeLibrary.commit",
      params: ["uploadId": .string(invalidUploadID)])
    XCTAssertFalse(invalidCommit.ok)
    XCTAssertEqual(invalidCommit.error?.code, "rejected")
    XCTAssertTrue(
      (invalidCommit.error?.message ?? "").contains("ELF validation"))
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

final class ManualUIFlashBridgeContractTests: XCTestCase {
  private static let moduleCache = FileManager.default.temporaryDirectory
    .appending(
      path: "manual-ui-xpc-modules-\(UUID().uuidString)", directoryHint: .isDirectory)

  private var repositoryRoot: URL {
    var root = URL(filePath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return root
  }

  func testBridgeAOTCompilesBeforeConstructingTheClangBackedXPCInterface() throws {
    let driverURL = repositoryRoot.appending(
      path: "scripts/manual_ui_flash/manual_ui_flash.swift")
    let source = try String(contentsOf: driverURL, encoding: .utf8)
    XCTAssertTrue(source.contains("manualUIAOTCompilerPath = \"/usr/bin/swiftc\""))
    XCTAssertTrue(source.contains("--manual-ui-aot-child"))
    XCTAssertTrue(source.contains("arkdeck-manual-ui-flash-aot"))
    XCTAssertTrue(source.contains("lstat($0, &value)"))
    XCTAssertTrue(source.contains("try reexecManualUIAOT(arguments: arguments)"))

    let dispatchStart = try XCTUnwrap(
      source.range(of: #"} else if arguments.first == "--xpc-flash-bridge" {"#)?.lowerBound)
    let dispatchEnd = try XCTUnwrap(
      source.range(
        of: #"} else if arguments == ["--validate-xpc-interface"] {"#,
        range: dispatchStart..<source.endIndex)?.lowerBound)
    let dispatch = source[dispatchStart..<dispatchEnd]
    let protectedMain = try XCTUnwrap(dispatch.range(of: "protectedMainActuatorCommit()"))
    let reexec = try XCTUnwrap(dispatch.range(of: "reexecManualUIAOT(arguments: arguments)"))
    XCTAssertLessThan(protectedMain.lowerBound, reexec.lowerBound)

    let bridgeStart = try XCTUnwrap(source.range(of: "func runFlashBridge(")?.lowerBound)
    let bridgeEnd = try XCTUnwrap(
      source.range(of: "func validateCandidate(", range: bridgeStart..<source.endIndex)?.lowerBound)
    XCTAssertTrue(
      source[bridgeStart..<bridgeEnd].contains(
        "let protectedMainCommitOID = try protectedMainActuatorCommit()"))

    try FileManager.default.createDirectory(
      at: Self.moduleCache, withIntermediateDirectories: true)
    let output = Pipe()
    let errors = Pipe()
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/xcrun")
    process.arguments = [
      "swift", "-module-cache-path", Self.moduleCache.path,
      driverURL.path, "--validate-xpc-interface",
    ]
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    let stderr = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let errorText = String(decoding: stderr, as: UTF8.self)
    XCTAssertEqual(process.terminationStatus, 0, errorText)
    XCTAssertTrue(String(decoding: stdout, as: UTF8.self).contains("XPC_INTERFACE_VALID: aot"))
    XCTAssertFalse(errorText.contains("NSInvalidArgumentException"))
  }
}

final class HeadlessHDCServerHostContractTests: XCTestCase {
  func testForegroundHostUsesExactLoopbackEndpointAndClosedEnvironment() throws {
    let executable = ResolvedExecutable(
      path: "/Applications/DevEco-Studio.app/Contents/sdk/hdc",
      sha256: String(repeating: "a", count: 64))
    let endpoint = try HDCServerEndpointSelector.select(inheritedEnvironment: [:])

    let request = HeadlessHDCServerHost.foregroundRequest(
      executable: executable, endpoint: endpoint)
    XCTAssertEqual(request.process.executable.path, executable.path)
    XCTAssertEqual(request.expectedSHA256, executable.sha256)
    XCTAssertEqual(request.process.arguments, ["-s", "127.0.0.1:8710", "-m"])
    XCTAssertEqual(request.process.environment, ["OHOS_HDC_SERVER_PORT": "8710"])
    XCTAssertNil(request.process.timeout, "the daemon owns this child until service shutdown")
    XCTAssertFalse(request.process.arguments.contains { $0.contains("sh -c") })

    let readiness = HeadlessHDCServerHost.readinessPlan(endpoint: endpoint)
    guard case .process(_, let arguments, let timeout) = readiness.kind else {
      return XCTFail("readiness must remain an exact descriptor-bound process")
    }
    XCTAssertEqual(arguments, ["-s", "127.0.0.1:8710", "checkserver"])
    XCTAssertEqual(timeout, 2)
    XCTAssertEqual(readiness.action, .hdc(.observeServer))
  }

  func testColdStartReturnsOnlyAfterTheForegroundListenerIsReachable() async throws {
    let fixture = productsDirectory.appending(path: "ArkDeckFakeHDCFixture")
    guard FileManager.default.isExecutableFile(atPath: fixture.path) else {
      throw XCTSkip("ArkDeckFakeHDCFixture binary not built")
    }
    let port = try availableDaemonLoopbackPort()
    let endpoint = HDCServerEndpointSelection(
      endpoint: HDCServerEndpoint("127.0.0.1:\(port)"),
      source: .inheritedEnvironment,
      childEnvironment: ["OHOS_HDC_SERVER_PORT": String(port)])
    let executable = try resolvedExecutable(at: fixture)

    let host = try await HeadlessHDCServerHost.start(
      executable: executable, endpoint: endpoint)
    XCTAssertTrue(
      HeadlessHDCServerHost.loopbackListenerIsReachable(endpoint: endpoint.endpoint),
      "semantic checkserver output must not make startup ready before the managed listener")
    XCTAssertEqual(host.diagnostics.endpoint, "127.0.0.1:\(port)")
    XCTAssertEqual(host.diagnostics.endpointSource, "inheritedEnvironment")
    XCTAssertEqual(host.diagnostics.clientVersion, "3.2.0d")
    XCTAssertEqual(host.diagnostics.serverVersion, "3.2.0d")

    await host.stop()
    let deadline = Date().addingTimeInterval(2)
    while HeadlessHDCServerHost.loopbackListenerIsReachable(endpoint: endpoint.endpoint),
      Date() < deadline
    {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertFalse(
      HeadlessHDCServerHost.loopbackListenerIsReachable(endpoint: endpoint.endpoint),
      "stopping the host must drain the foreground listener")
  }

  func testForegroundExitFailsReadinessWithTheClosedProcessOutcome() async throws {
    let falseExecutable = URL(filePath: "/usr/bin/false")
    guard FileManager.default.isExecutableFile(atPath: falseExecutable.path) else {
      throw XCTSkip("/usr/bin/false is unavailable")
    }
    let port = try availableDaemonLoopbackPort()
    let endpoint = HDCServerEndpointSelection(
      endpoint: HDCServerEndpoint("127.0.0.1:\(port)"), source: .inheritedEnvironment,
      childEnvironment: ["OHOS_HDC_SERVER_PORT": String(port)])

    do {
      _ = try await HeadlessHDCServerHost.start(
        executable: resolvedExecutable(at: falseExecutable), endpoint: endpoint)
      XCTFail("an exited foreground server must not wait out the startup deadline")
    } catch let error as HeadlessHDCServerHostError {
      XCTAssertEqual(
        error, .serverDidNotBecomeReady("foreground HDC server exited with status 1"))
    }
  }

  private func resolvedExecutable(at url: URL) throws -> ResolvedExecutable {
    let digest = SHA256.hash(data: try Data(contentsOf: url))
      .map { String(format: "%02x", $0) }.joined()
    return ResolvedExecutable(path: url.path, sha256: digest)
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
