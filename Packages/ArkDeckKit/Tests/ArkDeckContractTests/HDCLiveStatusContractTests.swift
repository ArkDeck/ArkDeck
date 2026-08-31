import Darwin
import Foundation
import XCTest
@testable import ArkDeckAgentClient
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony
@testable import ArkDeckProcess
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Read-only host fixtures. No test result here declares device support.
final class HDCLiveStatusContractTests: XCTestCase {
  private var root: URL!
  private var server: AgentDaemonServer?
  private let epoch: UInt64 = 100
  private enum Failure: Error { case missing }
  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/hdcs-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }
  override func tearDownWithError() throws { server?.stop(); server = nil; try? FileManager.default.removeItem(at: root) }
  private func fixture() throws -> ResolvedExecutable {
    let path = root.appending(path: "hdc")
    try FileManager.default.copyItem(at: Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "ArkDeckFakeHDCFixture"), to: path)
    return ResolvedExecutable(path: path.path, sha256: SHA256Hex.string(of: try Data(contentsOf: path)))
  }
  private func startup(_ executable: ResolvedExecutable) -> HDCManagedRuntimeDiagnostics {
    .init(executableSHA256: executable.sha256, clientVersion: "cached-client", serverVersion: "cached-server",
      endpoint: "127.0.0.1:8710", endpointSource: "default")
  }
  private func receipt(_ executable: ResolvedExecutable, pid: Int32 = 42, start: UInt64 = 100) -> HDCServerProcessIdentityReceipt {
    .init(pid: pid, startSeconds: start, startMicroseconds: 23, executablePath: URL(filePath: executable.path),
      executableSHA256: executable.sha256, endpoint: HDCServerEndpoint("127.0.0.1:8710"))
  }
  private func launch(_ executable: ResolvedExecutable) -> HDCManagedProcessLaunch {
    .init(pid: 42, startSeconds: epoch, startMicroseconds: 23, executablePath: executable.path, executableSHA256: executable.sha256,
      arguments: ["-s", "127.0.0.1:8710", "-m"])
  }
  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else { throw Failure.missing }; return fields
  }
  private func observer(_ executable: ResolvedExecutable, launch: HDCManagedProcessLaunch?,
    result: HDCSupervisorObservationResult,
    managedProcessMatches: Bool = true,
    duringManagedCheck: (@Sendable () throws -> Void)? = nil,
    duringRead: (@Sendable () throws -> Void)? = nil) -> HeadlessHDCStatusObserver {
    HeadlessHDCStatusObserver(executable: executable, startup: startup(executable), daemonVersion: "test-daemon",
      managedLaunch: { launch }, observeIdentity: { _, _ in
        try? duringRead?(); return result
      }, inspectSignature: { _ in .object(["state": .string("testOnly")]) },
      validateManagedProcess: { _, arguments in
        try? duringManagedCheck?()
        return managedProcessMatches && arguments == ["-s", "127.0.0.1:8710", "-m"]
      },
      nowUTC: { "2026-09-01T00:00:00Z" })
  }

  func testFreshIdentityNeverPromotesCachedHealthOrVersionsAndOwnershipNeedsBirthProof() async throws {
    let executable = try fixture(), observed = receipt(executable)
    let result = HDCSupervisorObservationResult(classification: .observed(generation: try XCTUnwrap(observed.stableGeneration)), identity: observed)
    let managed = try object(await observer(executable, launch: launch(executable), result: result).snapshot())
    XCTAssertEqual(managed["availability"], .string("available")); XCTAssertEqual(managed["ownership"], .string("arkDeckManaged"))
    XCTAssertEqual(managed["generation"], .string("100000023")); XCTAssertEqual(managed["executablePath"], .string(executable.path))
    XCTAssertEqual(managed["executableSHA256"], .string(executable.sha256)); XCTAssertEqual(managed["daemonVersion"], .string("test-daemon"))
    XCTAssertEqual(managed["serverHealth"], .string("unknown")); XCTAssertEqual(managed["serverVersion"], .null)
    XCTAssertEqual(managed["clientVersion"], .null, "fixture bytes cannot acquire the cached client's HDC version")
    XCTAssertEqual(managed["newDispatchCount"], .integer(0))
    let unowned = try object(await observer(executable, launch: nil, result: result).snapshot())
    XCTAssertEqual(unowned["ownership"], .string("unknown")); XCTAssertEqual(unowned["generation"], managed["generation"])
    let changedArguments = try object(await observer(executable, launch: launch(executable), result: result, managedProcessMatches: false).snapshot())
    XCTAssertEqual(changedArguments["ownership"], .string("unknown"))
    let reused = receipt(executable, start: 101)
    let reuseResult = HDCSupervisorObservationResult(classification: .observed(generation: try XCTUnwrap(reused.stableGeneration)), identity: reused)
    let reusedStatus = try object(await observer(executable, launch: launch(executable), result: reuseResult).snapshot())
    XCTAssertEqual(reusedStatus["ownership"], .string("unknown"))
  }

  func testLostOrUnknownServerCannotReturnTheStartupReadyProjection() async throws {
    let executable = try fixture()
    for classification in [HDCSupervisorObservationClassification.unavailable(reason: "gone"), .unknown(reason: "uncertain"), .timedOut, .cancelled, .unsupported(reason: "not registered")] {
      let row = try object(await observer(executable, launch: launch(executable), result: .init(classification: classification)).snapshot())
      XCTAssertNotEqual(row["availability"], .string("ready")); XCTAssertNotEqual(row["availability"], .string("available"))
      XCTAssertEqual(row["generation"], .null); XCTAssertEqual(row["ownership"], .string("unknown"))
      XCTAssertEqual(row["serverHealth"], .string("unknown")); XCTAssertEqual(row["serverVersion"], .null)
      XCTAssertEqual(row["newDispatchCount"], .integer(0))
    }
  }

  func testFileChangedDuringObservationFailsClosedEvenWhenBytesAndModeAreRestored() async throws {
    let executable = try fixture(), observed = receipt(executable)
    let change: @Sendable () throws -> Void = {
      guard chmod(executable.path, 0o600) == 0, chmod(executable.path, 0o700) == 0 else { throw Failure.missing }
    }
    for duringOwnership in [false, true] {
      let status = observer(executable, launch: launch(executable), result: .init(classification: .observed(generation: 100000023), identity: observed),
        duringManagedCheck: duringOwnership ? change : nil, duringRead: duringOwnership ? nil : change)
      let row = try object(await status.snapshot())
      XCTAssertEqual(row["availability"], .string("unavailable")); XCTAssertEqual(row["executableSHA256"], .null)
      XCTAssertEqual(row["signature"], .null); XCTAssertEqual(row["generation"], .null)
      XCTAssertEqual(row["reasonCode"], .string("hdc.toolIdentityOrSignatureInvalid"))
    }
  }

  func testProductionStaticSignatureInspectionDoesNotExecuteUnknownNativeCandidates() async throws {
    let executable = try fixture()
    let status = HeadlessHDCStatusObserver(executable: executable, startup: startup(executable), daemonVersion: nil, managedLaunch: { nil })
    let row = try object(await status.snapshot())
    XCTAssertEqual(row["reasonCode"], .string("hdc.identityFamilyUnavailable")); XCTAssertEqual(row["executableSHA256"], .string(executable.sha256))
    let signature = try object(XCTUnwrap(row["signature"]))
    XCTAssertTrue([JSONValue.string("adHoc"), .string("verified")].contains(try XCTUnwrap(signature["state"])))
    XCTAssertEqual(signature["executionAssessment"], .string("notPerformed")); XCTAssertEqual(row["daemonVersion"], .null)
    try FileManager.default.removeItem(atPath: executable.path)
    let missing = try object(await status.snapshot())
    XCTAssertEqual(missing["reasonCode"], .string("hdc.toolIdentityOrSignatureInvalid"))
  }

  func testInstalledSDKStaticCopyHasKnownVersionButNoInventedServer() async throws {
    let sdk = URL(filePath: "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc")
    guard FileManager.default.fileExists(atPath: sdk.path) else { throw XCTSkip("DevEco is not installed; static host integration not run") }
    let copy = root.appending(path: "hdc")
    try FileManager.default.copyItem(at: sdk, to: copy)
    let executable = ResolvedExecutable(path: copy.path, sha256: SHA256Hex.string(of: try Data(contentsOf: copy)))
    let row = try object(await HeadlessHDCStatusObserver(executable: executable, startup: startup(executable), daemonVersion: nil, managedLaunch: { nil }).snapshot())
    XCTAssertEqual(row["executableSHA256"], .string(executable.sha256))
    XCTAssertEqual(row["clientVersion"], HDCCommandlessServerIdentity.clientVersion(sha256: executable.sha256).map(JSONValue.string) ?? .null)
    XCTAssertEqual(row["generation"], .null); XCTAssertEqual(row["ownership"], .string("unknown"))
    XCTAssertNotEqual(row["availability"], .string("available")); XCTAssertEqual(row["newDispatchCount"], .integer(0))
  }

  func testCLIAndDaemonUseTargetMethodByDefaultAndKeepExplicitLegacyRead() async throws {
    let executable = try fixture()
    let capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "caps"))
    let dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    let engine = try RuntimeJobEngine(configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher, capabilityStore: capabilities, nowUTC: { "2026-09-01T00:00:00Z" })
    let handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities, providerIDs: [], nowUTC: { "2026-09-01T00:00:00Z" },
      hdcRuntimeDiagnostics: startup(executable),
      hdcStatusObserver: observer(executable, launch: nil, result: .init(classification: .unavailable(reason: "gone"))))
    server = AgentDaemonServer(stateDirectory: root.appending(path: "control"), handler: handler, nowUTC: { "2026-09-01T00:00:00Z" })
    _ = try server?.start()
    let process = Process()
    process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "arkdeck")
    func cli(_ arguments: [String]) throws -> [String: JSONValue] {
      let output = root.appending(path: "stdout-\(UUID()).json")
      FileManager.default.createFile(atPath: output.path, contents: nil)
      let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
      let child = Process(); child.executableURL = process.executableURL
      child.arguments = ["runtime", "hdc", "status", "--socket", try XCTUnwrap(server).socketURL.path, "--output", "json"] + arguments
      child.standardOutput = handle; child.standardError = FileHandle.nullDevice
      try child.run()
      let deadline = Date().addingTimeInterval(20)
      while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
      if child.isRunning { child.terminate(); throw Failure.missing }
      child.waitUntilExit(); XCTAssertEqual(child.terminationStatus, 0)
      return try object(CLIStrictJSON.decode(Data(contentsOf: output)))
    }
    let fresh = try object(XCTUnwrap(cli([])["result"]))
    XCTAssertEqual(fresh["schemaVersion"], .string("arkdeck.runtime-hdc-status/1")); XCTAssertEqual(fresh["generation"], .null)
    XCTAssertEqual(fresh["serverHealth"], .string("unknown")); XCTAssertEqual(fresh["availability"], .string("unavailable"))
    let legacy = try object(XCTUnwrap(cli(["--require-protocol", "1"])["result"]))
    XCTAssertEqual(legacy["serverVersion"], .string("cached-server")); XCTAssertEqual(legacy["availability"], .string("ready"))
    let withoutObserver = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { "2026-09-01T00:00:00Z" }, hdcRuntimeDiagnostics: startup(executable))
    let freshRequest = try PortableCanonicalJSON.canonicalBytes(.object(["protocolVersion": .string("2.0.0"), "id": .string("unconfigured"), "method": .string("runtime.hdc.status")]))
    let absent = try JSONDecoder().decode(AgentWireProtocol.Response.self, from: await withoutObserver.handleLine(freshRequest))
    let absentFields = try object(XCTUnwrap(absent.result))
    XCTAssertEqual(absentFields["availability"], .string("unavailable")); XCTAssertEqual(absentFields["serverVersion"], .null)
    XCTAssertEqual(absentFields["generation"], .null, "missing live observation must not fall back to the startup cache")
    for (version, params, code) in [("2.0.0", ["path": JSONValue.string(executable.path)], "invalidParams"), ("1.0.0", [:], "unsupportedProtocolVersion")] {
      let data = try PortableCanonicalJSON.canonicalBytes(.object(["protocolVersion": .string(version), "id": .string("status-fixture"),
        "method": .string("runtime.hdc.status"), "params": .object(params)]))
      let response = try JSONDecoder().decode(AgentWireProtocol.Response.self, from: await handler.handleLine(data))
      XCTAssertEqual(response.error?.code, code)
    }
    let jobs = try await engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }
}
