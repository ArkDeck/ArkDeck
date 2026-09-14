// Shared Swift oracle for the Rust agent execution owner's physical assistance (CHG-2026-074, TASK-XPA-014).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Swift's agent execution owner and the daemon's human-action owner over the
/// shared fake HDC (`HDCOracleFake`), with the independent USB observation the
/// Target observation owner brackets every device list with under the oracle's
/// control: executions that name no target, the physical-assistance actions
/// they raise, and how `agent.resume`, `human-action.*` and `agent.abandon`
/// answer them. The oracle the Rust owners replay.
///
/// - The runbook §2.1 reconnect: the device offline, an execution that names
///   no target waits for a person to connect it (`connectDevice`); it is run
///   again, read and listed while it waits; the device is replugged (a new USB
///   attachment) and the execution resumed, which adopts the device, owns its
///   Job and completes; the resolved action is read, and resumed again as it
///   was and with a selection it never offered.
/// - A trust prompt (`trustDevice`) abandoned: at a stale generation, then at
///   the current one, which expires its action; both resumes are
///   `humanActionExpired`, and the execution run again answers as abandoned.
/// - Two devices (`selectDevice`) resumed without a selection and with one the
///   action never offered.
/// - A connected device without a USB relation, which the owner refuses
///   (`admissionDenied`), and the requests the human-action owner refuses.
///
/// The engine and the owners run on the oracle's clock (`HDCOracleHarness`),
/// the daemon's human-action owner composed over the executions as in the
/// daemon. The resumed execution's Job is held at its server check (mode
/// `heldServer`) until the oracle releases it and waits for the execution's
/// durable completion. The fake answers the device list in the state its mode
/// names (`offline`, `unauthorized`, `twoDevices`, else connected). An
/// exchange names the USB relations the oracle set before it
/// (`usbRelations`). The identities the owners mint at random read as labels
/// (`HDCOracleHarness.RandomIdentities`): a request naming one sends the
/// identity the label stands for, and a page's revision is labelled as
/// before. Record a new oracle with
/// `ARKDECK_RUST_AGENT_HUMAN_ACTION_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class AgentHumanActionOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/agent-human-action", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)
  private static let otherKey = String(repeating: "b", count: 32)
  /// The runbook's `--maximum-wait 5m`.
  private static let budget = "300000"
  /// What the oracle creates to release a held call.
  private static let released = HDCOracleFake.root.appending(path: "released")

  /// The device list in the state the mode names and a Job held at its
  /// server check, before the capture oracle's answers.
  static let answers =
    #"""
    # Physical assistance: the device list in the state the mode names, and a
    # Job held at its server check until the oracle releases it.
    if [ "$*" = "list targets -v" ]; then
      case "$mode" in
      offline)
        printf '%s\t\tUSB\tOffline\tlocalhost\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        exit 0 ;;
      unauthorized)
        printf '%s\t\tUSB\tUnauthorized\tlocalhost\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        exit 0 ;;
      twoDevices)
        printf '%s\t\tUSB\tConnected\tlocalhost\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        printf '%s\t\tUSB\tConnected\tlocalhost\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        exit 0 ;;
      esac
    fi
    if [ "$mode" = heldServer ] && [ "$*" = checkserver ]; then
      while [ ! -e /private/tmp/arkdeck-hdc-oracle/released ]; do /bin/sleep 0.01; done
    fi

    """# + CaptureDiagnosticsOracleContractTests.answers

  func testSwiftResumesAndAbandonsPhysicalAssistanceOverTheSharedFakeDevice() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_AGENT_HUMAN_ACTION_RECORD",
      oracle: Self.oracle)
  }

  /// The independent USB observation, as the oracle plugs and replugs.
  private final class USBRelations: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [TargetUSBRelation] = []
    func set(_ value: [TargetUSBRelation]) { lock.withLock { current = value } }
    func read() -> [TargetUSBRelation] { lock.withLock { current } }
  }

  /// A DAYU200 in HDC-normal mode on one USB attachment.
  private static func relation(_ key: String, attachment: UInt64) -> TargetUSBRelation {
    TargetUSBRelation(
      serial: key, location: "100", attachmentID: attachment,
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID)
  }

  /// The relations as a replay sets its own USB observation to them.
  private static func recorded(_ relations: [TargetUSBRelation]) -> JSONValue {
    .array(
      relations.map {
        .object([
          "serial": .string($0.serial), "location": .string($0.location),
          "attachmentId": .integer(Int64($0.attachmentID)),
          "vendorId": .integer(Int64($0.vendorID)), "productId": .integer(Int64($0.productID)),
        ])
      })
  }

  /// The intent `arkdeck agent run --execution-id <id> --operation
  /// observe.device@1 --maximum-wait 5m` sends: no target.
  private static func intent(_ executionID: String) -> [String: JSONValue] {
    [
      "schemaVersion": .string(AgentExecutionIntent.schemaVersion),
      "executionId": .string(executionID), "operation": .string("observe.device@1"),
      "inputs": .object([:]), "maximumWaitMilliseconds": .string(budget),
    ]
  }

  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    try await HDCOracleHarness.send(handler, method, params, frameID: "agent-human-action-oracle")
  }

  private static func code(_ answer: JSONValue) -> JSONValue? {
    guard case .object(let fields) = answer, case .object(let error)? = fields["error"] else {
      return nil
    }
    return error["code"]
  }

  /// A string member of an answer's result, by its path.
  private static func string(_ answer: JSONValue, _ path: String...) -> String? {
    var value = answer
    for key in ["result"] + path {
      guard case .object(let fields) = value, let next = fields[key] else { return nil }
      value = next
    }
    guard case .string(let text) = value else { return nil }
    return text
  }

  /// The resumed execution reads its Job while the Job starts in the
  /// background, so the state it reads is any state before the held call.
  private static func startIndependent(_ answer: JSONValue) -> JSONValue {
    guard case .object(var fields) = answer, case .object(var result)? = fields["result"] else {
      return answer
    }
    result["jobState"] = .string("<jobState>")
    if case .object(var job)? = result["job"] {
      job["state"] = .string("<jobState>")
      job["outcome"] = .string("<jobState>")
      result["job"] = .object(job)
    }
    fields["result"] = .object(result)
    return .object(fields)
  }

  /// Releases the held call and waits until the execution's durable record
  /// says the Job it owns completed: the owner's last write for the run.
  private static func release(awaiting executionID: String, in directory: URL) async throws {
    try Data().write(to: released)
    let record = directory.appending(
      path: "execution-\(RuntimeAgentExecutionStore.fingerprint(Data(executionID.utf8))).json")
    let deadline = Date().addingTimeInterval(60)
    while true {
      if let data = try? Data(contentsOf: record),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["state"] as? String == "completed"
      {
        return
      }
      guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func oracleFiles() async throws -> [String: Data] {
    let manager = FileManager.default
    let hdc = try HDCOracleFake.install(answers: Self.answers)
    defer { try? manager.removeItem(at: Self.settings.root) }
    let targets = Self.settings.root.appending(path: "targets-state", directoryHint: .isDirectory)
    let targetStore = try RuntimeTargetStore(directoryURL: targets)
    // The device was adopted before, as in the runbook: a replug must not
    // advance its lineage.
    let adopted = try targetStore.adopt(
      stableIdentitySHA256: HDCObservationProviderAdapter.stableIdentitySHA256(
        connectKey: Self.connectKey),
      connectKey: Self.connectKey, toolVersion: "3.2.0d", nowUTC: Self.settings.nowUTC
    ).record
    let usb = USBRelations()
    let composition = try HDCOracleHarness.composition(
      hdc: hdc, targetStore: targetStore, targets: targets, settings: Self.settings,
      agentExecutions: true, humanActions: true, usbRelations: { usb.read() })
    guard let executions = composition.agentExecutions else {
      throw CocoaError(.featureUnsupported)
    }
    let handler = composition.handler
    let identities = HDCOracleHarness.RandomIdentities()

    var exchanges: [JSONValue] = []
    var plugged: JSONValue?
    /// The USB relations the next exchange runs under.
    func plug(_ relations: [TargetUSBRelation]) {
      usb.set(relations)
      plugged = Self.recorded(relations)
    }
    /// One exchange: the fake's mode set first when it names one, the
    /// request sent, and both recorded with their random identities labelled.
    func exchange(
      _ name: String, _ method: String, _ params: [String: JSONValue], mode: String? = nil,
      before: String? = nil, independent: (JSONValue) -> JSONValue = { $0 }
    ) async throws -> JSONValue {
      if let mode { try HDCOracleFake.setMode(mode) }
      let answer = try await Self.send(handler, method, params)
      guard case .object(let sent) = try identities.label(.object(params)) else {
        throw CocoaError(.coderInvalidValue)
      }
      var entry = HDCOracleHarness.exchange(
        name, method, sent, try identities.label(independent(answer)), mode: mode)
      if case .object(var fields) = entry {
        if let before { fields["before"] = .string(before) }
        if let relations = plugged { fields["usbRelations"] = relations }
        entry = .object(fields)
      }
      plugged = nil
      exchanges.append(entry)
      return answer
    }

    // The runbook §2.1 reconnect.
    let connect = Self.intent("har-connect")
    let connectIdentity: [String: JSONValue] = ["executionId": .string("har-connect")]
    let waiting = try await exchange("connect.run", "agent.run", connect, mode: "offline")
    XCTAssertEqual(Self.string(waiting, "state"), "waitingForHuman")
    XCTAssertEqual(Self.string(waiting, "humanAction", "category"), "physicalConnection")
    let action = try XCTUnwrap(Self.string(waiting, "humanAction", "actionId"))
    let reference = try XCTUnwrap(Self.string(waiting, "humanAction", "resumeReference"))
    _ = try await exchange("connect.rerun", "agent.run", connect)
    _ = try await exchange("connect.status", "agent.status", connectIdentity)
    _ = try await exchange(
      "connect.list", "human-action.list",
      ["ownerKind": .string("agentExecution"), "owner": .string("har-connect")])
    _ = try await exchange("connect.show", "human-action.show", ["humanAction": .string(action)])
    _ = try await exchange("connect.waiting", "agent.list", ["state": .string("waitingForHuman")])
    // Replugged: a new USB attachment, the device connected.
    try? manager.removeItem(at: Self.released)
    plug([Self.relation(Self.connectKey, attachment: 18)])
    let resumed = try await exchange(
      "connect.resume", "agent.resume", ["resumeReference": .string(reference)],
      mode: "heldServer", independent: Self.startIndependent)
    XCTAssertEqual(Self.string(resumed, "state"), "jobOwned")
    let job = try XCTUnwrap(Self.string(resumed, "jobId"))
    try await Self.release(awaiting: "har-connect", in: executions.directory)
    let completed = try await exchange(
      "connect.completed", "agent.status", connectIdentity, before: "release")
    XCTAssertEqual(Self.string(completed, "state"), "completed")
    XCTAssertEqual(Self.string(completed, "targetId"), adopted.targetID)
    _ = try await exchange("connect.resolved", "human-action.show", ["humanAction": .string(action)])
    _ = try await exchange("connect.again", "agent.resume", ["resumeReference": .string(reference)])
    _ = try await exchange(
      "connect.againByAction", "human-action.resume",
      ["resumeReference": .string(reference), "humanAction": .string(action)])
    let offered = try await exchange(
      "connect.selection", "human-action.resume",
      [
        "resumeReference": .string(reference), "humanAction": .string(action),
        "selection": .string("any"),
      ])
    XCTAssertEqual(Self.code(offered), .string("invalidInput"))

    // A trust prompt, abandoned.
    plug([Self.relation(Self.connectKey, attachment: 19)])
    let trust = Self.intent("har-trust")
    let prompted = try await exchange("trust.run", "agent.run", trust, mode: "unauthorized")
    XCTAssertEqual(Self.string(prompted, "humanAction", "category"), "deviceTrustPrompt")
    let trustAction = try XCTUnwrap(Self.string(prompted, "humanAction", "actionId"))
    let trustReference = try XCTUnwrap(Self.string(prompted, "humanAction", "resumeReference"))
    let generation = try XCTUnwrap(Self.string(prompted, "generation"))
    let stale = try await exchange(
      "trust.abandonStale", "agent.abandon",
      ["executionId": .string("har-trust"), "expectedGeneration": .string("1")])
    XCTAssertEqual(Self.code(stale), .string("resourceConflict"))
    let abandoned = try await exchange(
      "trust.abandon", "agent.abandon",
      ["executionId": .string("har-trust"), "expectedGeneration": .string(generation)])
    XCTAssertEqual(Self.string(abandoned, "state"), "abandoned")
    _ = try await exchange("trust.expired", "human-action.show", ["humanAction": .string(trustAction)])
    let late = try await exchange(
      "trust.resume", "agent.resume", ["resumeReference": .string(trustReference)])
    XCTAssertEqual(Self.code(late), .string("humanActionExpired"))
    let lateByAction = try await exchange(
      "trust.resumeByAction", "human-action.resume",
      ["resumeReference": .string(trustReference), "humanAction": .string(trustAction)])
    XCTAssertEqual(Self.code(lateByAction), .string("humanActionExpired"))
    _ = try await exchange("trust.rerun", "agent.run", trust)

    // Two devices: which one is a person's to say.
    plug([
      Self.relation(Self.connectKey, attachment: 20), Self.relation(Self.otherKey, attachment: 21),
    ])
    let choosing = try await exchange(
      "ambiguous.run", "agent.run", Self.intent("har-ambiguous"), mode: "twoDevices")
    XCTAssertEqual(Self.string(choosing, "humanAction", "category"), "ambiguousIdentity")
    let ambiguous = try XCTUnwrap(Self.string(choosing, "humanAction", "resumeReference"))
    let missing = try await exchange(
      "ambiguous.missing", "agent.resume", ["resumeReference": .string(ambiguous)])
    XCTAssertEqual(Self.code(missing), .string("invalidInput"))
    let foreign = try await exchange(
      "ambiguous.foreign", "agent.resume",
      ["resumeReference": .string(ambiguous), "selection": .string("candidate-unknown")])
    XCTAssertEqual(Self.code(foreign), .string("invalidInput"))

    // A connected device whose physical identity nothing proves.
    plug([])
    let unproven = try await exchange(
      "unproven.run", "agent.run", Self.intent("har-unproven"), mode: "normal")
    XCTAssertEqual(Self.code(unproven), .string("admissionDenied"))

    // What the human-action owner refuses. Refused requests send only
    // published parameter names with a wrong value, since a frame's
    // parameters enter the derived request schema.
    let refusals: [(String, String, [String: JSONValue], String)] = [
      ("refuse.listHalfFilter", "human-action.list", ["ownerKind": .string("agentExecution")], "invalidInput"),
      (
        "refuse.listKind", "human-action.list",
        ["ownerKind": .string("job"), "owner": .string("har-connect")], "invalidInput"
      ),
      ("refuse.listPageSize", "human-action.list", ["pageSize": .integer(0)], "invalidInput"),
      (
        "refuse.listCursor", "human-action.list",
        ["cursor": .string(String(repeating: "c", count: 257))], "invalidCursor"
      ),
      ("refuse.showUnknown", "human-action.show", ["humanAction": .string("har-unknown")], "resourceNotFound"),
      ("refuse.showInvalid", "human-action.show", ["humanAction": .string("-bad")], "invalidInput"),
      (
        "refuse.resumeUnknown", "human-action.resume",
        ["resumeReference": .string("resume-unknown"), "humanAction": .string("har-unknown")],
        "resourceNotFound"
      ),
      (
        "refuse.resumeWithoutAction", "human-action.resume",
        ["resumeReference": .string(reference)], "invalidInput"
      ),
      ("refuse.agentResumeUnknown", "agent.resume", ["resumeReference": .string("resume-unknown")], "resourceNotFound"),
      ("refuse.agentResumeInvalid", "agent.resume", ["resumeReference": .string("-bad")], "invalidInput"),
    ]
    for (name, method, params, expected) in refusals {
      let answer = try await exchange(name, method, params)
      XCTAssertEqual(Self.code(answer), .string(expected), name)
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
        "jobs": .object(["connect": .string(job)]),
        "executions": .object([
          "connect": .string("har-connect"), "trust": .string("har-trust"),
          "ambiguous": .string("har-ambiguous"), "unproven": .string("har-unproven"),
        ]),
        "exchanges": .array(exchanges),
      ]),
      answers: Self.answers,
      producer:
        "AgentHumanActionOracleContractTests.testSwiftResumesAndAbandonsPhysicalAssistanceOverTheSharedFakeDevice",
      settings: Self.settings, identities: identities)
  }
}
