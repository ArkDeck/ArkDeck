import Darwin
import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Host-only control-plane fixtures. They dispatch no device command and do
/// not count as real-device acceptance.
final class CLIDebugProbeContractTests: XCTestCase {
  private enum FixtureError: Error { case unexpectedTemplate, timeout }

  private actor Probe: DebugRuntimeProbing {
    private var targets: [String] = []
    private var corruptNext = false

    func probeDebugRuntime(targetID: String) async throws -> DebugRuntimeProbeSnapshot {
      targets.append(targetID)
      let returnedTargetID = corruptNext ? "another-target" : targetID
      corruptNext = false
      return DebugRuntimeProbeSnapshot(
        targetID: returnedTargetID,
        bindingRevision: 7,
        packages: ["com.example.zeta", "com.example.alpha"],
        portRules: [
          DebugRuntimePortRule(direction: .reverse, localPort: 9_100, remotePort: 9_101),
          DebugRuntimePortRule(direction: .forward, localPort: 9_000, remotePort: 9_001),
        ],
        warnings: ["reverseRulesUnavailable", "packageInventoryUnavailable"])
    }

    func runDebugTemplate(
      targetID: String, template: DebugRuntimeCommandTemplate
    ) async throws -> DebugRuntimeCommandResult {
      throw FixtureError.unexpectedTemplate
    }

    func observedTargets() -> [String] { targets }
    func corruptNextSnapshot() { corruptNext = true }
  }

  /// A probe that answers one closed template with a bounded result, so the
  /// success path of `debug.template.run` can be recorded without a device.
  private actor TemplateProbe: DebugRuntimeProbing {
    func probeDebugRuntime(targetID: String) async throws -> DebugRuntimeProbeSnapshot {
      throw FixtureError.unexpectedTemplate
    }

    func runDebugTemplate(
      targetID: String, template: DebugRuntimeCommandTemplate
    ) async throws -> DebugRuntimeCommandResult {
      DebugRuntimeCommandResult(
        targetID: targetID, bindingRevision: 7, templateID: template.rawValue,
        effect: "readOnly", executable: "/opt/hdc/hdc",
        executableSHA256: String(repeating: "a", count: 64),
        argumentDisclosure: ["shell", "uptime"],
        loweringSHA256: String(repeating: "b", count: 64),
        exitCode: 0, durationMilliseconds: 12,
        stdout: "up 1 day\n", stderr: "", outputTruncated: false)
    }
  }

  /// `TASK-XPA-001`: `debug.template.run` answers through the control plane so
  /// its result shape enters the recorded corpus.
  func testDebugTemplateRunPublishesItsResultShapeThroughTheControlPlane() async throws {
    let root = URL(filePath: "/private/tmp/dbgt-\(UUID().uuidString.prefix(8).lowercased())")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "capabilities"))
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []),
      dispatcher: RuntimeAgentExecutionContractTests.Dispatcher(),
      capabilityStore: capabilities, nowUTC: { "2026-09-01T00:00:00Z" })
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { "2026-09-01T00:00:00Z" }, debugRuntimeProbe: TemplateProbe())
    let frame = try JSONEncoder().encode(
      AgentWireProtocol.Request(
        id: "template", method: "debug.template.run",
        params: ["targetId": .string("target-one"), "templateId": .string("device.uptime")]))
    let response = await handler.handleFrame(frame)
    XCTAssertTrue(response.ok, response.error?.message ?? "-")
    guard case .object(let result)? = response.result else {
      return XCTFail("debug.template.run must answer the command result")
    }
    XCTAssertEqual(result["targetId"], .string("target-one"))
    XCTAssertEqual(result["templateId"], .string("device.uptime"))
    XCTAssertEqual(result["exitCode"], .integer(0))
    XCTAssertEqual(result["arguments"], .array([.string("shell"), .string("uptime")]))
  }

  func testRealCLIProcessUsesTheBoundedTargetProtocolProbe() async throws {
    let root = URL(filePath: "/private/tmp/dbgp-\(UUID().uuidString.prefix(8).lowercased())")
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
    let probe = Probe()
    let handler = RuntimeControlPlaneHandler(
      engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { "2026-09-01T00:00:00Z" }, debugRuntimeProbe: probe)
    let server = AgentDaemonServer(
      stateDirectory: root.appending(path: "control"), handler: handler,
      nowUTC: { "2026-09-01T00:00:00Z" })
    _ = try server.start()
    defer { server.stop() }

    let outputURL = root.appending(path: "cli-output.json")
    XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
    let output = try FileHandle(forWritingTo: outputURL)
    let process = Process()
    process.executableURL = Bundle(for: Self.self).bundleURL
      .deletingLastPathComponent().appending(path: "arkdeck")
    process.arguments = [
      "debug", "probe", "--target", "target-one",
      "--socket", server.socketURL.path, "--output", "json",
    ]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = Date().addingTimeInterval(25)
    while process.isRunning && Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
      throw FixtureError.timeout
    }
    try output.close()
    let bytes = try Data(contentsOf: outputURL)
    XCTAssertEqual(process.terminationStatus, 0, String(decoding: bytes, as: UTF8.self))
    guard case .object(let envelope) = try CLIStrictJSON.decode(bytes),
      case .object(let result)? = envelope["result"],
      case .object(let meta)? = envelope["meta"]
    else { return XCTFail("Debug probe CLI envelope is malformed") }
    XCTAssertEqual(envelope["command"], .string("debug.probe"))
    XCTAssertEqual(meta["controlProtocolVersion"], .string(ArkDeckControlProtocol.currentVersion))
    XCTAssertEqual(result["schemaVersion"], .string("arkdeck.debug-probe/1"))
    XCTAssertEqual(result["targetId"], .string("target-one"))
    XCTAssertEqual(result["bindingRevision"], .integer(7))
    XCTAssertEqual(
      result["packages"],
      .array([.string("com.example.alpha"), .string("com.example.zeta")]))
    XCTAssertEqual(
      result["warnings"],
      .array([.string("packageInventoryUnavailable"), .string("reverseRulesUnavailable")]))
    XCTAssertEqual(
      result["portRules"],
      .array([
        .object([
          "direction": .string("forward"),
          "localPort": .integer(9_000),
          "remotePort": .integer(9_001),
        ]),
        .object([
          "direction": .string("reverse"),
          "localPort": .integer(9_100),
          "remotePort": .integer(9_101),
        ]),
      ]))
    let observedAfterCLI = await probe.observedTargets()
    let jobsAfterCLI = try await engine.listJobs()
    XCTAssertEqual(observedAfterCLI, ["target-one"])
    XCTAssertTrue(jobsAfterCLI.isEmpty)
    XCTAssertEqual(dispatcher.dispatchCount, 0)

    let extra = try PortableCanonicalJSON.canonicalBytes(
      .object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion), "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string("extra-field"),
        "method": .string("debug.probe"),
        "params": .object([
          "targetId": .string("target-one"),
          "rawCommand": .string("hdc shell id"),
        ]),
      ]))
    let refused = try JSONDecoder().decode(
      AgentWireProtocol.Response.self, from: await handler.handleLine(extra))
    XCTAssertEqual(refused.error?.code, "invalidParams")
    let observedAfterRefusal = await probe.observedTargets()
    XCTAssertEqual(observedAfterRefusal, ["target-one"])
    XCTAssertEqual(dispatcher.dispatchCount, 0)

    await probe.corruptNextSnapshot()
    let mismatched = try PortableCanonicalJSON.canonicalBytes(
      .object([
        "protocolVersion": .string(ArkDeckControlProtocol.currentVersion), "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
        "id": .string("mismatched-projection"),
        "method": .string("debug.probe"),
        "params": .object(["targetId": .string("target-one")]),
      ]))
    let mismatchedResponse = try JSONDecoder().decode(
      AgentWireProtocol.Response.self, from: await handler.handleLine(mismatched))
    XCTAssertEqual(mismatchedResponse.error?.code, "internalError")
    let observedAfterMismatch = await probe.observedTargets()
    XCTAssertEqual(observedAfterMismatch, ["target-one", "target-one"])
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }
}
