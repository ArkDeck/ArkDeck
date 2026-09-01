import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Host-only process coverage. The fixture has no provider or target and
/// dispatches no device command, so it is not real-device acceptance.
final class CLIDoctorContractTests: XCTestCase {
  private enum FixtureError: Error { case timeout }

  private struct Run {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
  }

  func testRealCLIProcessReturnsTheReportAndTheExplicitHealthGate() async throws {
    let root = URL(filePath: "/private/tmp/doctor-\(UUID().uuidString.prefix(8).lowercased())")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }

    let capabilities = try RuntimeCapabilityStore(
      directoryURL: root.appending(path: "capabilities"))
    let dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher,
      capabilityStore: capabilities, nowUTC: { "2026-09-01T00:00:00Z" })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { "2026-09-01T00:00:00Z" })
    let server = AgentDaemonServer(
      stateDirectory: root.appending(path: "control"), handler: handler,
      nowUTC: { "2026-09-01T00:00:00Z" })
    _ = try server.start()
    defer { server.stop() }

    let report = try await run([
      "doctor", "--socket", server.socketURL.path, "--output", "json",
    ])
    XCTAssertEqual(report.exitCode, 0, String(decoding: report.stderr, as: UTF8.self))
    XCTAssertTrue(report.stderr.isEmpty)
    guard case .object(let envelope) = try CLIStrictJSON.decode(report.stdout),
      case .object(let result)? = envelope["result"],
      case .object(let meta)? = envelope["meta"]
    else { return XCTFail("doctor success envelope is malformed") }
    XCTAssertEqual(envelope["ok"], .bool(true))
    XCTAssertEqual(envelope["command"], .string("doctor"))
    XCTAssertEqual(meta["controlProtocolVersion"], .string("2.0.0"))
    XCTAssertEqual(result["schemaVersion"], .string("arkdeck.doctor-report/1"))
    XCTAssertEqual(result["ready"], .bool(false))

    let gate = try await run([
      "doctor", "--require-healthy", "--socket", server.socketURL.path,
      "--output", "json",
    ])
    XCTAssertEqual(gate.exitCode, 69, String(decoding: gate.stderr, as: UTF8.self))
    XCTAssertTrue(gate.stderr.isEmpty)
    guard case .object(let failed) = try CLIStrictJSON.decode(gate.stdout),
      case .object(let error)? = failed["error"],
      case .object(let details)? = error["details"],
      case .object(let retainedReport)? = details["report"]
    else { return XCTFail("doctor gate envelope is malformed") }
    XCTAssertEqual(failed["ok"], .bool(false))
    XCTAssertEqual(error["code"], .string("healthRequirementFailed"))
    XCTAssertEqual(retainedReport["schemaVersion"], .string("arkdeck.doctor-report/1"))
    XCTAssertEqual(retainedReport["ready"], .bool(false))

    XCTAssertEqual(dispatcher.dispatchCount, 0)
    let jobs = try await engine.listJobs()
    XCTAssertTrue(jobs.isEmpty)
  }

  private func run(_ argv: [String]) async throws -> Run {
    let process = Process()
    process.executableURL = Bundle(for: Self.self).bundleURL
      .deletingLastPathComponent().appending(path: "arkdeck")
    process.arguments = argv
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let deadline = Date().addingTimeInterval(25)
    while process.isRunning, Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
      throw FixtureError.timeout
    }
    return Run(
      exitCode: process.terminationStatus,
      stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
      stderr: stderr.fileHandleForReading.readDataToEndOfFile())
  }
}
