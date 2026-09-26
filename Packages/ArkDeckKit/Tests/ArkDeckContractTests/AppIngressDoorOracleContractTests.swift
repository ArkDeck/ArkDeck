import Foundation
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// What Swift's App transport answers at its door, as the oracle the Rust App
/// ingress replays (`rust/tests/fixtures/app-ingress-door-oracle`,
/// TASK-XPA-019): frames it cannot decode, the Job requests its typed gate
/// refuses, and the Runtime storage requests its closed-parameter checks
/// admit or refuse.
///
/// Each case goes through `AgentXPCEndpoint.responseFrame`, the frame the
/// App's raw XPC listener sends back, with a fresh App Job gate. A refusal at
/// the door is recorded byte for byte. A request the door lets through is
/// recorded as `forwarded` only: the Runtime's answer to it is not the door's.
///
/// With `ARKDECK_APP_INGRESS_DOOR_ORACLE_OUTPUT` set to a new path under
/// `/private/tmp/`, the answers are written there; without it they are
/// compared with the committed oracle byte for byte. Raw frames name the
/// current protocol version and contract identity as `$protocolVersion` and
/// `$contractIdentity`, which the replay substitutes. Host-only: no device,
/// no dispatch.
final class AppIngressDoorOracleContractTests: XCTestCase {
  private var root: URL!
  private var engine: RuntimeJobEngine!
  private var handler: RuntimeControlPlaneHandler!
  private var dispatcher: RuntimeAgentExecutionContractTests.Dispatcher!
  private var cases: [JSONValue] = []
  private enum OracleError: Error { case missing, undecodable }
  private static let refusalMessage = "Runtime transport refused this request"

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appending(path: "aido-\(UUID().uuidString.prefix(8))")
    let artifacts = try RuntimeArtifactStore(rootURL: root.appending(path: "artifacts"), nowUTC: { "2026-09-01T00:00:00Z" })
    let capabilities = try RuntimeCapabilityStore(directoryURL: root.appending(path: "capabilities"))
    dispatcher = RuntimeAgentExecutionContractTests.Dispatcher()
    engine = try RuntimeJobEngine(configuration: .init(stateDirectory: root.appending(path: "engine")),
      providers: DeviceProviderRegistry(providers: []), dispatcher: dispatcher, capabilityStore: capabilities,
      artifactStore: artifacts, nowUTC: { "2026-09-01T00:00:00Z" })
    // No storage, Target or Artifact owner: whatever the door forwards is
    // answered without touching a store.
    handler = RuntimeControlPlaneHandler(engine: engine, capabilityStore: capabilities, providerIDs: [],
      nowUTC: { "2026-09-01T00:00:00Z" })
  }

  override func tearDownWithError() throws {
    handler = nil; engine = nil; dispatcher = nil
    try? FileManager.default.removeItem(at: root)
  }

  /// One frame through the App's transport: the door's refusal, byte for
  /// byte, or `forwarded`.
  private func record(_ name: String, frame: Data, entry: [String: JSONValue]) async throws {
    let response = await AgentXPCEndpoint(handler: handler, appJobs: AgentXPCAppJobGate()).responseFrame(frame)
    guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
      throw OracleError.undecodable
    }
    let refused = (object["error"] as? [String: Any])?["message"] as? String == Self.refusalMessage
    var fields = entry
    fields["case"] = .string(name)
    fields["forwarded"] = .bool(!refused)
    if refused { fields["received"] = .string(String(decoding: response, as: UTF8.self)) }
    cases.append(.object(fields))
  }

  private func request(_ name: String, _ method: String, _ params: [String: JSONValue]?) async throws {
    let frame = try ArkDeckAgentXPC.requestFrame(method: method, params: params, requestID: "door-oracle")
    var entry: [String: JSONValue] = ["method": .string(method)]
    if let params { entry["params"] = .object(params) }
    // The door's own decision, where it has one without a Job gate.
    if !["job.run", "job.cancel"].contains(method) {
      let admitted = AgentXPCEndpoint.admission(of: frame) != nil
      try await record(name, frame: frame, entry: entry)
      guard case .object(let recorded)? = cases.last else { throw OracleError.missing }
      XCTAssertEqual(recorded["forwarded"], .bool(admitted), name)
    } else {
      try await record(name, frame: frame, entry: entry)
    }
  }

  private func raw(_ name: String, _ template: String) async throws {
    let text = template
      .replacingOccurrences(of: "$protocolVersion", with: ArkDeckControlProtocol.currentVersion)
      .replacingOccurrences(of: "$contractIdentity", with: ArkDeckControlProtocol.contractIdentity)
    try await record(name, frame: Data(text.utf8), entry: ["raw": .string(template)])
  }

  /// A Runtime operation request, as the App's typed Job requests carry one.
  private func document(client: String, operation: String, extra: [String: JSONValue] = [:]) throws -> JSONValue {
    var fields: [String: JSONValue] = [
      "documentType": .string("runtime-operation-request"), "schemaVersion": .string("1.0.0"),
      "requestId": .string("door-oracle-request"), "idempotencyKey": .string("door-oracle-request"),
      "target": .object(["targetId": .string("TGT-fixture"), "expectedBindingRevision": .integer(1)]),
      "operation": .object(["id": .string(operation), "version": .integer(1)]), "inputs": .object([:]),
      "requestedOutputs": .array([.string("rawArtifacts"), .string("derivedArtifacts")]),
      "clientContext": .object(["clientName": .string(client), "provenance": .object([:])]),
    ]
    fields.merge(extra) { $1 }
    return .string(String(decoding: try PortableCanonicalJSON.canonicalBytes(.object(fields)), as: UTF8.self))
  }

  func testTheAppTransportDoor() async throws {
    let envelope = #""contractIdentity":"$contractIdentity","#
    let version = #""protocolVersion":"$protocolVersion""#

    // Frames the door cannot decode, or whose method this Runtime does not publish.
    try await raw("frame.notJson", "not a frame")
    try await raw("frame.array", "[]")
    try await raw("frame.empty", "")
    try await raw("frame.missingId", "{\(envelope)\"method\":\"health\",\(version)}")
    try await raw("frame.emptyId", "{\(envelope)\"id\":\"\",\"method\":\"health\",\(version)}")
    try await raw("frame.unknownMember", "{\(envelope)\"extra\":true,\"id\":\"door-oracle\",\"method\":\"health\",\(version)}")
    try await raw("frame.paramsNotObject", "{\(envelope)\"id\":\"door-oracle\",\"method\":\"health\",\"params\":[],\(version)}")
    try await raw("frame.duplicateMember",
      "{\(envelope)\"id\":\"door-oracle\",\"id\":\"door-oracle\",\"method\":\"health\",\(version)}")
    try await raw("frame.trailingNewline", "{\(envelope)\"id\":\"door-oracle\",\"method\":\"health\",\(version)}\n")
    try await raw("frame.unsupportedVersion",
      "{\(envelope)\"id\":\"door-oracle\",\"method\":\"health\",\"protocolVersion\":\"0.9.0\"}")
    try await raw("frame.contractMismatch",
      "{\"contractIdentity\":\"\(String(repeating: "0", count: 64))\",\"id\":\"door-oracle\",\"method\":\"health\",\(version)}")
    try await raw("frame.unknownMethod", "{\(envelope)\"id\":\"door-oracle\",\"method\":\"no.such.method\",\(version)}")

    // The typed App Job gate: requests it does not type, and Jobs the App did not submit.
    let trace = "ArkDeckApp.TraceWorkspace"
    try await request("job.submit.cliClient", "job.submit",
      ["requestJson": try document(client: "arkdeck-cli", operation: "capture.diagnostics")])
    try await request("job.submit.otherOperation", "job.submit",
      ["requestJson": try document(client: trace, operation: "observe.device")])
    try await request("job.submit.authorization", "job.submit",
      ["requestJson": try document(client: trace, operation: "capture.diagnostics", extra: ["authorization": .null])])
    try await request("job.submit.extraParameter", "job.submit",
      ["requestJson": try document(client: trace, operation: "capture.diagnostics"), "priority": .string("high")])
    try await request("job.submit.requestNotString", "job.submit", ["requestJson": .object([:])])
    try await request("job.submit.noParameters", "job.submit", nil)
    try await request("job.plan.cliClient", "job.plan",
      ["requestJson": try document(client: "arkdeck-cli", operation: "capture.diagnostics")])
    try await request("job.run.notSubmitted", "job.run", ["jobId": .string("JOB-door-oracle")])
    try await request("job.cancel.notSubmitted", "job.cancel", ["jobId": .string("JOB-door-oracle")])
    try await request("job.run.emptyId", "job.run", ["jobId": .string("")])
    try await request("job.run.longId", "job.run", ["jobId": .string(String(repeating: "a", count: 129))])
    try await request("job.cancel.numberId", "job.cancel", ["jobId": .integer(7)])
    try await request("job.run.extraParameter", "job.run", ["jobId": .string("JOB-door-oracle"), "force": .bool(true)])
    try await request("job.cancel.noParameters", "job.cancel", nil)

    // Runtime storage: the closed parameters the door admits, and what it refuses.
    try await request("storage.status.noParameters", "runtime.storage.status", nil)
    try await request("storage.status.empty", "runtime.storage.status", [:])
    try await request("storage.status.parameter", "runtime.storage.status", ["verbose": .string("1")])
    let policy: [String: JSONValue] = ["expectedGeneration": .string("1"), "totalQuotaBytes": .string("1073741824"),
      "safetyMarginBytes": .string("1048576"), "retentionDays": .string("30")]
    func changed(_ key: String, _ value: JSONValue?) -> [String: JSONValue] {
      var fields = policy; fields[key] = value; return fields
    }
    try await request("storage.policy.valid", "runtime.storage.policy", policy)
    try await request("storage.policy.int64Max", "runtime.storage.policy",
      changed("totalQuotaBytes", .string("9223372036854775807")))
    try await request("storage.policy.beyondInt64", "runtime.storage.policy",
      changed("totalQuotaBytes", .string("9223372036854775808")))
    try await request("storage.policy.missingKey", "runtime.storage.policy", changed("retentionDays", nil))
    try await request("storage.policy.extraKey", "runtime.storage.policy", changed("mode", .string("1")))
    try await request("storage.policy.zero", "runtime.storage.policy", changed("retentionDays", .string("0")))
    try await request("storage.policy.leadingZero", "runtime.storage.policy", changed("retentionDays", .string("030")))
    try await request("storage.policy.negative", "runtime.storage.policy", changed("retentionDays", .string("-1")))
    try await request("storage.policy.plus", "runtime.storage.policy", changed("retentionDays", .string("+1")))
    try await request("storage.policy.space", "runtime.storage.policy", changed("retentionDays", .string(" 1")))
    try await request("storage.policy.emptyText", "runtime.storage.policy", changed("retentionDays", .string("")))
    try await request("storage.policy.integer", "runtime.storage.policy", changed("retentionDays", .integer(30)))
    try await request("storage.policy.generationZero", "runtime.storage.policy",
      changed("expectedGeneration", .string("0")))
    func rootPath(_ path: JSONValue) -> [String: JSONValue] {
      ["expectedGeneration": .string("1"), "rootPath": path]
    }
    try await request("storage.root.path", "runtime.storage.root", rootPath(.string("/private/tmp/arkdeck-door-oracle")))
    try await request("storage.root.innerSpace", "runtime.storage.root", rootPath(.string("/private/tmp/door oracle")))
    try await request("storage.root.maximumLength", "runtime.storage.root",
      rootPath(.string("/" + String(repeating: "a", count: 4095))))
    try await request("storage.root.tooLong", "runtime.storage.root",
      rootPath(.string("/" + String(repeating: "a", count: 4096))))
    try await request("storage.root.tooLongMultibyte", "runtime.storage.root",
      rootPath(.string("/" + String(repeating: "\u{e9}", count: 2048))))
    try await request("storage.root.controlCharacter", "runtime.storage.root",
      rootPath(.string("/private/tmp/door\u{1}oracle")))
    try await request("storage.root.emptyPath", "runtime.storage.root", rootPath(.string("")))
    try await request("storage.root.relative", "runtime.storage.root", rootPath(.string("private/tmp/door-oracle")))
    try await request("storage.root.leadingSpace", "runtime.storage.root", rootPath(.string(" /private/tmp/door-oracle")))
    try await request("storage.root.trailingSpace", "runtime.storage.root", rootPath(.string("/private/tmp/door-oracle ")))
    try await request("storage.root.trailingTab", "runtime.storage.root", rootPath(.string("/private/tmp/door-oracle\t")))
    try await request("storage.root.trailingNewline", "runtime.storage.root",
      rootPath(.string("/private/tmp/door-oracle\n")))
    try await request("storage.root.trailingNoBreakSpace", "runtime.storage.root",
      rootPath(.string("/private/tmp/door-oracle\u{a0}")))
    try await request("storage.root.trailingIdeographicSpace", "runtime.storage.root",
      rootPath(.string("/private/tmp/door-oracle\u{3000}")))
    try await request("storage.root.pathNotText", "runtime.storage.root", rootPath(.integer(1)))
    try await request("storage.root.reset", "runtime.storage.root",
      ["expectedGeneration": .string("1"), "resetToDefault": .bool(true)])
    try await request("storage.root.resetFalse", "runtime.storage.root",
      ["expectedGeneration": .string("1"), "resetToDefault": .bool(false)])
    try await request("storage.root.resetText", "runtime.storage.root",
      ["expectedGeneration": .string("1"), "resetToDefault": .string("true")])
    try await request("storage.root.pathAndReset", "runtime.storage.root",
      ["expectedGeneration": .string("1"), "rootPath": .string("/private/tmp/door-oracle"), "resetToDefault": .bool(true)])
    try await request("storage.root.generationOnly", "runtime.storage.root", ["expectedGeneration": .string("1")])
    try await request("storage.root.noGeneration", "runtime.storage.root",
      ["rootPath": .string("/private/tmp/door-oracle")])
    try await request("storage.root.generationZero", "runtime.storage.root",
      ["expectedGeneration": .string("0"), "rootPath": .string("/private/tmp/door-oracle")])

    XCTAssertEqual(dispatcher.dispatchCount, 0)
    let document = try PortableCanonicalJSON.canonicalBytes(.object([
      "schemaVersion": .string("arkdeck.app-ingress-door-oracle/1"), "requestId": .string("door-oracle"),
      "cases": .array(cases),
    ]))
    guard let output = ProcessInfo.processInfo.environment["ARKDECK_APP_INGRESS_DOOR_ORACLE_OUTPUT"] else {
      // Without the recording variable, Swift's answers are the committed oracle, byte for byte.
      XCTAssertEqual(try Data(contentsOf: Self.oracle), document)
      return
    }
    let destination = URL(fileURLWithPath: output)
    guard destination.path.hasPrefix("/private/tmp/"), !FileManager.default.fileExists(atPath: destination.path) else {
      throw OracleError.missing
    }
    try document.write(to: destination)
  }

  private static let oracle: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url.appending(path: "rust/tests/fixtures/app-ingress-door-oracle/cases.json")
  }()
}
