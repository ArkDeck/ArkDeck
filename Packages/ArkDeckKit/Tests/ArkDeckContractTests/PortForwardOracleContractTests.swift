// Shared Swift oracle for the Rust `port-forward.create@1` and
// `port-forward.remove@1` engine (CHG-2026-074, TASK-XPA-014).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift's port rules over the shared fake HDC (`HDCOracleFake`), the
/// developer-loop operations of Golden Journey 2 and the fourth M2 oracle.
/// One device is adopted; each case plans a request for it, and a case with
/// a mode also admits it under the runtime's default policy capability and
/// runs its Job while the fake answers in that mode, so the Jobs run in
/// order over one device whose rule table the fake keeps between Jobs: a
/// forward rule created and read back, then removed and read back absent; a
/// reverse rule the same way; a rule the device refuses to create; a removal
/// of a rule the device never had; a rule the device reports created but
/// never lists, so the readback fails and the engine compensates by
/// removing it and reads that back; and, last of the runs, a rule whose
/// readback the device cannot answer, left unknown — the Job waits for
/// recovery, and the next rule admitted under the same capability is
/// refused because the lineage holds an unknown outcome. The other cases
/// are refused before admission: a privileged port, a direction the Catalog
/// does not know and a rule without its device port. Every Job's result,
/// evidence and Artifact list (the readback document among them) are read,
/// and the capability store is read last. What the oracle keeps and how it
/// is composed is `HDCOracleHarness`.
///
/// Record a new oracle with
/// `ARKDECK_RUST_PORT_FORWARD_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class PortForwardOracleContractTests: XCTestCase {
  private struct Case {
    let name: String
    let operation: String
    let inputs: [String: JSONValue]
    /// The fake's mode while this case's Job runs; a case without one only
    /// plans its request.
    var mode: String?
    /// The state the run ends in.
    var ends: String?
    /// The code the admission is refused with, for a case that is submitted
    /// but never runs.
    var admission: String?
  }

  private static func rule(
    _ direction: String, _ localPort: Int64?, _ remotePort: Int64?
  ) -> [String: JSONValue] {
    var inputs: [String: JSONValue] = ["direction": .string(direction)]
    if let localPort { inputs["localPort"] = .integer(localPort) }
    if let remotePort { inputs["remotePort"] = .integer(remotePort) }
    return inputs
  }

  private static let cases: [Case] = [
    Case(
      name: "createForward", operation: "port-forward.create",
      inputs: rule("forward", 23451, 34561), mode: "normal", ends: "succeeded"),
    Case(
      name: "removeForward", operation: "port-forward.remove",
      inputs: rule("forward", 23451, 34561), mode: "normal", ends: "succeeded"),
    Case(
      name: "createReverse", operation: "port-forward.create",
      inputs: rule("reverse", 23452, 34562), mode: "normal", ends: "succeeded"),
    Case(
      name: "removeReverse", operation: "port-forward.remove",
      inputs: rule("reverse", 23452, 34562), mode: "normal", ends: "succeeded"),
    Case(
      name: "createRefused", operation: "port-forward.create",
      inputs: rule("forward", 23453, 34563), mode: "createRefused", ends: "failed"),
    Case(
      name: "removeMissing", operation: "port-forward.remove",
      inputs: rule("forward", 23454, 34564), mode: "normal", ends: "failed"),
    Case(
      name: "ruleUnlisted", operation: "port-forward.create",
      inputs: rule("forward", 23455, 34565), mode: "ruleUnlisted", ends: "failed"),
    Case(
      name: "readbackUnanswered", operation: "port-forward.create",
      inputs: rule("forward", 23456, 34566), mode: "readbackUnanswered", ends: "waitingForRecovery"),
    Case(
      name: "afterUnknown", operation: "port-forward.create",
      inputs: rule("forward", 23459, 34569), admission: "admissionDenied"),
    Case(name: "privilegedPort", operation: "port-forward.create", inputs: rule("forward", 80, 34567)),
    Case(name: "unknownDirection", operation: "port-forward.create", inputs: rule("sideways", 23457, 34567)),
    Case(name: "withoutDevicePort", operation: "port-forward.remove", inputs: rule("forward", 23458, nil)),
  ]

  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/port-forward", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)

  /// What the two operations ask, answered as `hdc` answers them: the
  /// preflight reads of the adopted device; `fport`/`rport` adding a rule to
  /// the table the fake keeps in marker files beside its log and answering
  /// `Forwardport result:OK`; `fport rm` removing one it has, or failing for
  /// one it has not; `fport ls` listing the table one rule per line with the
  /// connect key and the direction tag — by mode: `createRefused` refuses to
  /// add a rule, `ruleUnlisted` adds it but lists nothing, and
  /// `readbackUnanswered` cannot list at all.
  private static let answers = #"""
    # port-forward.create@1 and port-forward.remove@1 answers of the shared fake HDC, by mode.
    key=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    marker() { printf '%s/device-rule-%s' "$root" "$(printf '%s' "$*" | tr ': ' '__')"; }
    case "$*" in
    "list targets -v")
      printf '%s\t\tUSB\tConnected\tlocalhost\n' "$key" ;;
    "-t $key shell param get const.product.name")
      printf 'OpenHarmony Reference Device\n' ;;
    "-t $key shell param get const.ohos.fullname")
      printf 'OpenHarmony-4.1-release\n' ;;
    "-t $key fport ls")
      [ "$mode" = readbackUnanswered ] && exit 1
      [ "$mode" = ruleUnlisted ] && exit 0
      for rule in "$root"/device-rule-*; do
        [ -e "$rule" ] || continue
        IFS= read -r row < "$rule"
        printf '%s    %s\n' "$key" "$row"
      done ;;
    "-t $key fport rm "*)
      rule=$(marker "$5" "$6")
      if [ ! -e "$rule" ]; then
        printf '[Fail]Remove forward ruler failed, ruler is not exist\n'
        exit 1
      fi
      rm -f "$rule"
      printf 'Remove forward ruler success, ruler:%s %s\n' "$5" "$6" ;;
    "-t $key fport tcp:"*)
      if [ "$mode" = createRefused ]; then
        printf '[Fail]Forwardport result failed\n'
        exit 1
      fi
      printf '%s %s    [Forward]\n' "$4" "$5" > "$(marker "$4" "$5")"
      printf 'Forwardport result:OK\n' ;;
    "-t $key rport tcp:"*)
      printf '%s %s    [Reverse]\n' "$4" "$5" > "$(marker "$4" "$5")"
      printf 'Forwardport result:OK\n' ;;
    *)
      printf 'unregistered fixture output\n' >&2
      exit 23 ;;
    esac

    """#

  func testSwiftCreatesAndRemovesPortRulesOnTheSharedFakeDevice() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_PORT_FORWARD_RECORD",
      oracle: Self.oracle)
  }

  private static func requestJSON(_ item: Case, target: String) throws -> String {
    let document = JSONValue.object([
      "documentType": .string("runtime-operation-request"),
      "schemaVersion": .string("1.0.0"),
      "requestId": .string("req-port-\(item.name)"),
      "idempotencyKey": .string("idem-port-\(item.name)"),
      "target": .object([
        "targetId": .string(target), "expectedBindingRevision": .integer(1),
      ]),
      "operation": .object(["id": .string(item.operation), "version": .integer(1)]),
      "inputs": .object(item.inputs),
    ])
    return String(decoding: try CanonicalJSONEncoders.canonical().encode(document), as: UTF8.self)
  }

  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    try await HDCOracleHarness.send(handler, method, params, frameID: "port-forward-oracle")
  }

  private static func described(_ item: Case) -> JSONValue {
    var fields: [String: JSONValue] = [
      "operation": .string(item.operation), "inputs": .object(item.inputs),
    ]
    if let mode = item.mode { fields["mode"] = .string(mode) }
    if let ends = item.ends { fields["ends"] = .string(ends) }
    if let admission = item.admission { fields["admission"] = .string(admission) }
    return .object(fields)
  }

  private func oracleFiles() async throws -> [String: Data] {
    let manager = FileManager.default
    let hdc = try HDCOracleFake.install(answers: Self.answers)
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

    var exchanges: [JSONValue] = []
    var jobs: [(name: String, job: String)] = []
    for item in Self.cases {
      let params: [String: JSONValue] = [
        "requestJson": .string(try Self.requestJSON(item, target: adopted.targetID))
      ]
      let plan = try await Self.send(composition.handler, "job.plan", params)
      exchanges.append(HDCOracleHarness.exchange("\(item.name).plan", "job.plan", params, plan))
      guard item.mode != nil || item.admission != nil else { continue }
      let submitted = try await Self.send(composition.handler, "job.submit", params)
      exchanges.append(
        HDCOracleHarness.exchange("\(item.name).submit", "job.submit", params, submitted))
      if let admission = item.admission {
        guard case .object(let fields) = submitted, case .object(let error)? = fields["error"]
        else {
          XCTFail("\(item.name): the admission was not refused: \(submitted)")
          continue
        }
        XCTAssertEqual(error["code"], .string(admission), item.name)
        continue
      }
      guard let mode = item.mode,
        case .object(let fields) = submitted, case .object(let result)? = fields["result"],
        case .string(let job)? = result["jobId"]
      else {
        XCTFail("\(item.name): the admission was refused: \(submitted)")
        continue
      }
      jobs.append((item.name, job))
      try HDCOracleFake.setMode(mode)
      let run = try await Self.send(composition.handler, "job.run", ["jobId": .string(job)])
      exchanges.append(
        HDCOracleHarness.exchange(
          "\(item.name).run", "job.run", ["jobId": .string(job)], run, mode: mode))
      guard case .object(let answer) = run, case .object(let status)? = answer["result"] else {
        XCTFail("\(item.name): the run was refused: \(run)")
        continue
      }
      XCTAssertEqual(status["state"], item.ends.map(JSONValue.string), item.name)
    }
    for (name, job) in jobs {
      let reads: [(String, String, [String: JSONValue])] = [
        ("result", "job.result", ["jobId": .string(job)]),
        ("evidence", "job.evidence", ["jobId": .string(job)]),
        (
          "artifacts", "artifact.list",
          [
            "owner": .object(["kind": .string("job"), "id": .string(job)]),
            "pageSize": .integer(1000),
          ]
        ),
      ]
      for (read, method, params) in reads {
        let answer = try await Self.send(composition.handler, method, params)
        exchanges.append(HDCOracleHarness.exchange("\(name).\(read)", method, params, answer))
      }
    }
    let capabilities = try await Self.send(composition.handler, "capability.list", [:])
    exchanges.append(
      HDCOracleHarness.exchange("capabilities.list", "capability.list", [:], capabilities))
    guard case .object(let listed) = capabilities, case .array(let items)? = listed["result"]
    else { throw CocoaError(.coderInvalidValue) }
    for (index, item) in items.enumerated() {
      guard case .object(let fields) = item, case .string(let id)? = fields["capabilityId"]
      else { throw CocoaError(.coderInvalidValue) }
      let params: [String: JSONValue] = ["capabilityId": .string(id)]
      exchanges.append(
        HDCOracleHarness.exchange(
          "capabilities.inspect\(index)", "capability.inspect", params,
          try await Self.send(composition.handler, "capability.inspect", params)))
    }
    return try HDCOracleHarness.files(
      composition, target: adopted,
      cases: .object([
        "target": .object([
          "targetId": .string(adopted.targetID),
          "bindingRevision": .integer(Int64(adopted.bindingRevision)),
          "connectKey": .string(adopted.connectKey),
          "toolVersion": .string(adopted.toolVersion),
        ]),
        "cases": .object(
          Dictionary(uniqueKeysWithValues: Self.cases.map { ($0.name, Self.described($0)) })),
        "jobs": .object(
          Dictionary(uniqueKeysWithValues: jobs.map { ($0.name, JSONValue.string($0.job)) })),
        "exchanges": .array(exchanges),
      ]),
      answers: Self.answers,
      producer: "PortForwardOracleContractTests.testSwiftCreatesAndRemovesPortRulesOnTheSharedFakeDevice",
      settings: Self.settings)
  }
}
