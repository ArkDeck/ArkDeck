import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// `TASK-XPA-001` (XPA-AC-3): every method of the single v1 control table is
/// dispatched by the handler and answers one closed envelope — a success or a
/// registered error code with a message — even on the thinnest composition.
/// Besides pinning that no published method is dead, this is what guarantees
/// the recorded corpus holds at least one frame per method: a method no other
/// contract test reaches still publishes its request and error shapes here.
final class ControlMethodReachabilityContractTests: XCTestCase {
  private var stateDirectory: URL!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-reachability-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    if let stateDirectory { try? FileManager.default.removeItem(at: stateDirectory) }
  }

  // MARK: - Fixtures

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
        profileID: "openharmony-standard@1", collectedAtUTC: "2026-09-05T00:00:00Z")
    }
  }

  /// No method below may reach a process; a dispatch is a test failure.
  private struct RefusingDispatcher: RuntimeProcessDispatching {
    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      throw RuntimeDispatchFailure.failed("reachability tests never dispatch")
    }
  }

  private final class MethodLog: @unchecked Sendable {
    private let lock = NSLock()
    private var methods: [String] = []
    func record(_ method: String) { lock.withLock { methods.append(method) } }
    func drain() -> [String] {
      lock.withLock {
        defer { methods = [] }
        return methods
      }
    }
  }

  private func makeStack() throws -> (RuntimeControlPlaneHandler, MethodLog) {
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateDirectory.appending(path: "capabilities", directoryHint: .isDirectory))
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateDirectory.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { "2026-09-05T00:00:00Z" })
    let providers = DeviceProviderRegistry(providers: [
      HDCObservationProviderAdapter(factsPort: FactsPort())
    ])
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: stateDirectory.appending(path: "engine", directoryHint: .isDirectory)),
      providers: providers,
      dispatcher: RefusingDispatcher(),
      capabilityStore: capabilityStore,
      artifactStore: artifactStore,
      workspaceProjectStore: nil,
      nowUTC: { "2026-09-05T00:00:00Z" })
    let targets = try RuntimeTargetStore(
      directoryURL: stateDirectory.appending(path: "targets", directoryHint: .isDirectory))
    let log = MethodLog()
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilityStore,
      providerIDs: providers.registeredProviderIDs,
      nowUTC: { "2026-09-05T00:00:00Z" },
      targetStore: targets,
      artifactStore: artifactStore,
      methodObserver: { log.record($0) })
    return (handler, log)
  }

  /// Sends one current-contract frame through the line entry point and
  /// returns the decoded response.
  private func exchange(
    _ handler: RuntimeControlPlaneHandler, method: String,
    params: [String: JSONValue]? = nil, id: String = "reachability"
  ) async throws -> AgentWireProtocol.Response {
    let frame = try CanonicalJSONEncoders.canonical().encode(
      AgentWireProtocol.Request(id: id, method: method, params: params))
    let line = await handler.handleLine(frame)
    XCTAssertEqual(line.last, 0x0A, "\(method) must answer one LF-terminated line")
    let response = try JSONDecoder().decode(AgentWireProtocol.Response.self, from: Data(line.dropLast()))
    XCTAssertEqual(response.id, id)
    return response
  }

  // MARK: - Tests

  func testEveryPublishedMethodIsDispatchedAndAnswersAClosedEnvelope() async throws {
    let (handler, log) = try makeStack()
    // Error codes are a wider vocabulary than the handler's own refusals: the
    // engine and the resource coordinators answer with their registered codes
    // (`invalidInput`, `operationUnavailable`, `resourceConflict`, ...). The
    // per-method schemas enumerate what each method really answered; here the
    // envelope only has to be closed and the code an identifier.
    let identifier = try NSRegularExpression(pattern: "^[a-z][A-Za-z0-9]*$")
    for method in ArkDeckControlProtocol.methods.sorted() {
      let response = try await exchange(handler, method: method, params: [:])
      XCTAssertEqual(log.drain(), [method], "\(method) must be dispatched")
      if let error = response.error {
        XCTAssertFalse(response.ok, method)
        XCTAssertNil(response.result, method)
        XCTAssertNotNil(
          identifier.firstMatch(in: error.code, range: NSRange(error.code.startIndex..., in: error.code)),
          "\(method) answered a code that is not an identifier: \(error.code)")
        XCTAssertNotEqual(
          error.code, AgentDaemonErrorCode.unsupportedProtocolVersion.rawValue,
          "\(method) refused the current contract")
        XCTAssertNotEqual(
          error.code, AgentDaemonErrorCode.malformedFrame.rawValue,
          "\(method) called a well-formed current frame malformed")
        XCTAssertFalse(error.message.isEmpty, method)
      } else {
        XCTAssertTrue(response.ok, method)
        XCTAssertNotNil(response.result, "\(method) succeeded without a result")
      }
    }
  }

  /// A method outside the table is refused before dispatch with the
  /// registered code; the observer sees nothing.
  func testAnUnpublishedMethodIsRefusedBeforeDispatch() async throws {
    let (handler, log) = try makeStack()
    let response = try await exchange(handler, method: "control.method.that.does.not.exist", params: [:])
    XCTAssertEqual(log.drain(), [])
    XCTAssertFalse(response.ok)
    XCTAssertEqual(response.error?.code, AgentDaemonErrorCode.unknownMethod.rawValue)
  }
}
