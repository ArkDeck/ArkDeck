// Shared Swift oracle for the Rust Trace inspection owner (CHG-2026-074,
// TASK-XPA-015).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckWorkflows

/// Swift `trace.inspect` through the daemon's control-plane handler composed
/// without a Trace inspector, as the daemon composes it when no ArkTrace
/// distribution loaded a `trace-summary@1` profile
/// (`ProductTraceOfflineInspector` exists only beside one). The owner
/// (`RuntimeTraceInspectionResourceHandler`) asks for its Artifact owner and
/// its inspector before it reads a parameter, so every request is refused
/// `operationUnavailable` with the owner's details — zero dispatch, no device
/// evidence — whatever it names: no parameters, the exact Job/Artifact
/// request the CLI sends, and each refusal the owner would otherwise answer
/// `invalidInput` (no sensitive opt-in, a timeout out of range, an owner that
/// is not a Job, a lone Artifact identity).
///
/// Every request here is one a caller may send: the method's own request
/// schema refuses a member it does not declare or a value of another type,
/// so recording such a request would put a line in the corpus that its schema
/// refuses.
///
/// Record a new oracle with
/// `ARKDECK_RUST_TRACE_INSPECT_RECORD=/private/tmp/<new directory>`; otherwise
/// the checked-in oracle must match byte for byte.
final class TraceInspectOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/trace-inspect-unavailable", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)

  func testSwiftRefusesTraceInspectionWithoutAnInspector() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_TRACE_INSPECT_RECORD",
      oracle: Self.oracle)
  }

  private func oracleFiles() async throws -> [String: Data] {
    let manager = FileManager.default
    let hdc = try HDCOracleFake.install(answers: "")
    defer { try? manager.removeItem(at: Self.settings.root) }
    let targets = Self.settings.root.appending(path: "targets-state", directoryHint: .isDirectory)
    let targetStore = try RuntimeTargetStore(directoryURL: targets)
    let adopted = try targetStore.adopt(
      stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
        connectKey: Self.connectKey),
      connectKey: Self.connectKey, toolVersion: "3.2.0d", nowUTC: Self.settings.nowUTC
    ).record
    let composition = try HDCOracleHarness.composition(
      hdc: hdc, targetStore: targetStore, targets: targets, settings: Self.settings)
    let owner: JSONValue = .object([
      "kind": .string("job"), "id": .string("job-trace-inspect"),
    ])
    let artifact: JSONValue = .string("ART-9c914630ca801dc5e25b24667d40e4fe")
    let exact: [String: JSONValue] = [
      "owner": owner, "artifactId": artifact, "allowSensitive": .bool(true),
      "timeoutMs": .integer(1_000),
    ]
    func replacing(_ key: String, _ value: JSONValue) -> [String: JSONValue] {
      var params = exact
      params[key] = value
      return params
    }
    let cases: [(String, [String: JSONValue])] = [
      ("inspect.empty", [:]),
      ("inspect.exact", exact),
      ("inspect.notSensitive", replacing("allowSensitive", .bool(false))),
      ("inspect.timeoutZero", replacing("timeoutMs", .integer(0))),
      ("inspect.timeoutPastBound", replacing("timeoutMs", .integer(600_001))),
      (
        "inspect.sessionOwner",
        replacing(
          "owner", .object(["kind": .string("session"), "id": .string("job-trace-inspect")]))
      ),
      ("inspect.artifactOnly", ["artifactId": artifact]),
    ]
    var exchanges: [JSONValue] = []
    for (name, params) in cases {
      let answer = try await HDCOracleHarness.send(
        composition.handler, "trace.inspect", params, frameID: "trace-inspect-oracle")
      guard case .object(let fields) = answer, case .object(let error)? = fields["error"] else {
        throw CocoaError(.coderInvalidValue)
      }
      XCTAssertEqual(error["code"], .string("operationUnavailable"), name)
      exchanges.append(HDCOracleHarness.exchange(name, "trace.inspect", params, answer))
    }
    // No Job runs and nothing is dispatched, so the oracle keeps only what
    // the requests touch: the fake and the calls it received (none), the
    // Target document, and the cases.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [
      "hdc": HDCOracleFake.driver,
      "hdc-answers.sh": Data(),
      "hdc-invocations.log": try HDCOracleFake.invocations(),
      "targets-state/targets.json": try Data(
        contentsOf: composition.targets.appending(path: "targets.json")),
      "cases.json": try encoder.encode(
        JSONValue.object([
          "target": .object([
            "targetId": .string(adopted.targetID),
            "bindingRevision": .integer(Int64(adopted.bindingRevision)),
            "connectKey": .string(adopted.connectKey),
            "toolVersion": .string(adopted.toolVersion),
          ]),
          "exchanges": .array(exchanges),
        ])) + Data("\n".utf8),
    ]
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(SHA256Hex.string(of: data)) }
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string(
            "TraceInspectOracleContractTests.testSwiftRefusesTraceInspectionWithoutAnInspector"),
          "root": .string(Self.settings.root.path),
          "nowUTC": .string(Self.settings.nowUTC),
          "home": .string(Self.settings.home),
          "hdcSHA256": .string(SHA256Hex.string(of: HDCOracleFake.driver)),
          "targetId": .string(adopted.targetID),
          "files": .object(digests),
        ])) + Data("\n".utf8)
    return files
  }
}
