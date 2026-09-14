// The Swift daemon's control handler answering `runtime.hdc.status` over the
// shared HDC status oracle (`rust/tests/fixtures/hdc-status`, recorded by
// `HDCStatusOracleContractTests`). Each case's observer is rebuilt from the
// inputs the oracle recorded and composed into `RuntimeControlPlaneHandler` as
// the daemon composes its own, and the handler's answer must be the oracle's
// snapshot byte for byte: what a client reads is the observer's object. A run
// with `ARKDECK_CONTROL_FRAME_LOG` records these frames, the live values among
// them, and `spec/control/methods/runtime.hdc.status.json` is derived from
// them, so the Rust daemon's live answers are admitted (TASK-XPA-014, M1).
//
// A second test answers through the handler for a copy of the installed
// DevEco hdc when its digest is a registered one, the only way the status
// carries a client version; a host without it skips that test.
import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckProcess
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class HDCStatusControlFramesContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/hdc-status", directoryHint: .isDirectory)
  /// The oracle's fixed root: the tool's path is part of every answer.
  private static let root = URL(
    filePath: "/private/tmp/arkdeck-hdc-status-oracle", directoryHint: .isDirectory)
  private static let nowUTC = "2026-09-14T00:00:00Z"
  private enum Failure: Error { case malformed(String) }

  /// One case as the oracle recorded its inputs.
  private struct Recorded: Decodable {
    struct Executable: Decodable {
      let path: String
      let sha256: String
    }
    struct Startup: Decodable {
      let executableSHA256: String
      let clientVersion: String
      let serverVersion: String
      let endpoint: String
      let endpointSource: String
    }
    struct Process: Decodable {
      let pid: Int32
      let startSeconds: UInt64
      let startMicroseconds: UInt64
      let executablePath: String
      let executableSHA256: String
      let endpoint: String?
      let arguments: [String]?
    }
    struct Observation: Decodable {
      let classification: String
      let generation: Int?
      let reason: String?
      let identity: Process?
    }
    let name: String
    let executable: Executable?
    let startup: Startup
    let daemonVersion: String?
    let launch: Process?
    let observation: Observation
    let managedProcessVerified: Bool
    let disturbance: String

    var diagnostics: HDCManagedRuntimeDiagnostics {
      HDCManagedRuntimeDiagnostics(
        executableSHA256: startup.executableSHA256, clientVersion: startup.clientVersion,
        serverVersion: startup.serverVersion, endpoint: startup.endpoint,
        endpointSource: startup.endpointSource)
    }

    func result() throws -> HDCSupervisorObservationResult {
      let classification: HDCSupervisorObservationClassification
      switch observation.classification {
      case "observed":
        classification = .observed(generation: try XCTUnwrap(observation.generation))
      case "unavailable": classification = .unavailable(reason: try XCTUnwrap(observation.reason))
      case "unknown": classification = .unknown(reason: try XCTUnwrap(observation.reason))
      case "unsupported": classification = .unsupported(reason: try XCTUnwrap(observation.reason))
      case "timedOut": classification = .timedOut
      case "cancelled": classification = .cancelled
      default: throw Failure.malformed(observation.classification)
      }
      let identity = try observation.identity.map {
        HDCServerProcessIdentityReceipt(
          pid: $0.pid, startSeconds: $0.startSeconds, startMicroseconds: $0.startMicroseconds,
          executablePath: URL(filePath: $0.executablePath),
          executableSHA256: $0.executableSHA256,
          endpoint: HDCServerEndpoint(try XCTUnwrap($0.endpoint)))
      }
      return HDCSupervisorObservationResult(classification: classification, identity: identity)
    }

    func managedLaunch() throws -> HDCManagedProcessLaunch? {
      try launch.map {
        HDCManagedProcessLaunch(
          pid: $0.pid, startSeconds: $0.startSeconds, startMicroseconds: $0.startMicroseconds,
          executablePath: $0.executablePath, executableSHA256: $0.executableSHA256,
          arguments: try XCTUnwrap($0.arguments))
      }
    }
  }

  private var state: URL!
  private var dispatcher: RuntimeAgentExecutionContractTests.Dispatcher!
  private var capabilities: RuntimeCapabilityStore!
  private var engine: RuntimeJobEngine!

  override func setUpWithError() throws {
    state = URL(filePath: "/private/tmp/hdcsf-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
      at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    capabilities = try RuntimeCapabilityStore(directoryURL: state.appending(path: "caps"))
    engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: state.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher,
      capabilityStore: capabilities, nowUTC: { Self.nowUTC })
  }

  override func tearDownWithError() throws {
    engine = nil
    capabilities = nil
    dispatcher = nil
    try? FileManager.default.removeItem(at: state)
  }

  /// The daemon's handler with the startup facts and the live observer its
  /// HDC host would give it; without an observer it has no configured tool.
  private func handler(
    startup: HDCManagedRuntimeDiagnostics?, observer: (any HDCStatusObserving)?
  ) -> RuntimeControlPlaneHandler {
    RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [], nowUTC: { Self.nowUTC },
      hdcRuntimeDiagnostics: startup, hdcStatusObserver: observer)
  }

  /// One `runtime.hdc.status` request through the handler's line entry, as a
  /// client's frame reaches it.
  private func status(_ handler: RuntimeControlPlaneHandler, id: String) async throws -> JSONValue {
    let request = try PortableCanonicalJSON.canonicalBytes(
      .object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
        "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string(id), "method": .string("runtime.hdc.status"),
      ]))
    let response = try JSONDecoder().decode(
      AgentWireProtocol.Response.self, from: await handler.handleLine(request))
    XCTAssertTrue(response.ok, id)
    XCTAssertNil(response.error, id)
    return try XCTUnwrap(response.result, id)
  }

  private static func fields(_ value: JSONValue?) throws -> [String: JSONValue] {
    guard case .object(let fields)? = value else { throw Failure.malformed("not an object") }
    return fields
  }

  /// The production observer over the seams the case recorded, with the
  /// production signature inspection, as `HDCStatusOracleContractTests`
  /// composes it; `nil` is the daemon without a configured tool.
  private static func observer(_ recorded: Recorded) throws -> HeadlessHDCStatusObserver? {
    guard let executable = recorded.executable else { return nil }
    let path = executable.path
    let disturb: @Sendable () -> Void = {
      _ = chmod(path, 0o600)
      _ = chmod(path, 0o700)
    }
    let result = try recorded.result()
    let launch = try recorded.managedLaunch()
    let disturbance = recorded.disturbance
    let verified = recorded.managedProcessVerified
    return HeadlessHDCStatusObserver(
      executable: ResolvedExecutable(path: executable.path, sha256: executable.sha256),
      startup: recorded.diagnostics, daemonVersion: recorded.daemonVersion,
      managedLaunch: { launch },
      observeIdentity: { _, _ in
        if disturbance == "duringObservation" { disturb() }
        return result
      },
      inspectSignature: HeadlessHDCStatusObserver.signature,
      validateManagedProcess: { _, _ in
        if disturbance == "duringOwnership" { disturb() }
        return verified
      },
      nowUTC: { nowUTC })
  }

  /// Serializes every user of the oracle's fixed root: its recorder, its Rust
  /// replay and this test.
  private static func lock() throws -> Int32 {
    let lock = open(root.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw POSIXError(.EACCES) }
    guard flock(lock, LOCK_EX) == 0 else {
      close(lock)
      throw POSIXError(.EBUSY)
    }
    return lock
  }

  func testTheHandlerAnswersEveryCaseOfTheStatusOracleAsItsSnapshot() async throws {
    let manager = FileManager.default
    let lock = try Self.lock()
    defer { close(lock) }
    try? manager.removeItem(at: Self.root)
    defer { try? manager.removeItem(at: Self.root) }
    try manager.createDirectory(
      at: Self.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let hdc = Self.root.appending(path: "hdc")
    try HDCOracleFake.driver.write(to: hdc)
    guard chmod(hdc.path, 0o700) == 0 else { throw POSIXError(.EPERM) }

    let cases = try JSONDecoder().decode(
      [Recorded].self, from: Data(contentsOf: Self.oracle.appending(path: "cases.json")))
    XCTAssertEqual(cases.count, 22)
    XCTAssertEqual(
      cases[1].executable?.sha256, SHA256Hex.string(of: HDCOracleFake.driver),
      "the oracle's tool is the shared fake driver")
    for (index, recorded) in cases.enumerated() {
      let observer = try Self.observer(recorded)
      let answer = try await status(
        handler(startup: observer == nil ? nil : recorded.diagnostics, observer: observer),
        id: "status-\(recorded.name)")
      let snapshot = Self.oracle.appending(
        path: String(format: "snapshots/%02d-%@.json", index, recorded.name))
      XCTAssertEqual(
        String(decoding: try PortableCanonicalJSON.canonicalBytes(answer), as: UTF8.self) + "\n",
        String(decoding: try Data(contentsOf: snapshot), as: UTF8.self), recorded.name)
    }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testTheHandlerAnswersTheClientVersionOfARegisteredTool() async throws {
    let installed = URL(
      filePath: "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc")
    guard FileManager.default.fileExists(atPath: installed.path) else {
      throw XCTSkip("DevEco is not installed; no registered hdc to answer for")
    }
    let copy = state.appending(path: "hdc")
    try FileManager.default.copyItem(at: installed, to: copy)
    let sha256 = SHA256Hex.string(of: try Data(contentsOf: copy))
    guard let version = HDCCommandlessServerIdentity.clientVersion(sha256: sha256) else {
      throw XCTSkip("the installed hdc is not a registered one")
    }
    let endpoint = "127.0.0.1:8710"
    let receipt = HDCServerProcessIdentityReceipt(
      pid: 42, startSeconds: 100, startMicroseconds: 23, executablePath: copy,
      executableSHA256: sha256, endpoint: HDCServerEndpoint(endpoint))
    let launch = HDCManagedProcessLaunch(
      pid: 42, startSeconds: 100, startMicroseconds: 23, executablePath: copy.path,
      executableSHA256: sha256, arguments: ["-s", endpoint, "-m"])
    let result = HDCSupervisorObservationResult(
      classification: .observed(generation: try XCTUnwrap(receipt.stableGeneration)),
      identity: receipt)
    let startup = HDCManagedRuntimeDiagnostics(
      executableSHA256: sha256, clientVersion: "cached-client", serverVersion: "cached-server",
      endpoint: endpoint, endpointSource: "default")
    let observer = HeadlessHDCStatusObserver(
      executable: ResolvedExecutable(path: copy.path, sha256: sha256), startup: startup,
      daemonVersion: "0.0.0-oracle", managedLaunch: { launch },
      observeIdentity: { _, _ in result },
      inspectSignature: HeadlessHDCStatusObserver.signature,
      validateManagedProcess: { _, _ in true }, nowUTC: { Self.nowUTC })

    let answer = try Self.fields(
      try await status(handler(startup: startup, observer: observer), id: "status-registered"))
    XCTAssertEqual(answer["clientVersion"], .string(version))
    XCTAssertEqual(answer["clientVersionSource"], .string("publishedExecutableDigest"))
    XCTAssertEqual(answer["availability"], .string("available"))
    XCTAssertEqual(answer["ownership"], .string("arkDeckManaged"))
    XCTAssertEqual(answer["reasonCode"], .string("hdc.identityObserved"))
    XCTAssertEqual(answer["generation"], .string("100000023"))
    XCTAssertEqual(answer["processId"], .integer(42))
    XCTAssertEqual(answer["serverVersion"], .null, "never promoted from the startup cache")
    let signature = try Self.fields(answer["signature"])
    XCTAssertTrue(
      [JSONValue.string("adHoc"), .string("verified")].contains(try XCTUnwrap(signature["state"])))
    XCTAssertEqual(signature["executionAssessment"], .string("notPerformed"))
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }
}
