// Shared Swift oracle for the Rust Target observation owner's adoption and availability (CHG-2026-074, TASK-XPA-014).

import Darwin
import XCTest

@testable import ArkDeckAgentDaemon
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// The daemon's Target observation owner over the shared fake HDC
/// (`HDCOracleFake`), with the independent USB observation it brackets every
/// device list with under the oracle's control, and `target.availability`
/// over the adopted target with the managed HDC server's diagnostics: the
/// runbook §2 path a Golden Journey takes from a device it has never adopted.
///
/// - The device observed with a proved USB relation and adopted from that
///   exact observation; the same reference adopted again (the receipt); the
///   device observed again, now naming its target; the target's availability;
///   the device adopted again from a later observation (the same target, no
///   new binding).
/// - What adoption refuses: parameters that are not exactly a reference, a
///   leading zero, an observation the snapshot never held, a generation the
///   snapshot left behind, a trust prompt (`targetTrustPending`), a device
///   without a proved relation (`admissionDenied`), a relation that changes
///   during the adoption readback (`factsDrifted`), and a device list past its
///   bounds (`operationUnavailable`), which the observation read refuses too.
/// - What availability refuses: no target, and a target never adopted.
///
/// The owners run on the oracle's clock (`HDCOracleHarness`); no Target is
/// adopted before the first exchange. The fake answers the device list in the
/// state its mode names (`unauthorized`, `tooMany`, else connected). An
/// exchange names the USB relations the oracle set before it
/// (`usbRelations`), and the adoption whose relation changes names when it
/// changes (`usbRelationsAfter`: after that many reads, these relations). The
/// observation identities the owner mints at random read as labels
/// (`HDCOracleHarness.RandomIdentities`). Record a new oracle with
/// `ARKDECK_RUST_TARGET_ADOPTION_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class TargetAdoptionOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/target-adoption", directoryHint: .isDirectory)
  private static let settings = HDCOracleHarness.Settings(
    root: HDCOracleFake.root,
    nowUTC: "2026-09-14T00:00:00Z",
    nowPreciseUTC: "2026-09-14T00:00:00.000Z",
    home: "/private/tmp/arkdeck-hdc-oracle/home",
    quotaBytes: 8 * 1024 * 1024 * 1024)
  private static let connectKey = String(repeating: "a", count: 32)
  /// What the daemon's managed HDC server reported at startup.
  private static let diagnostics = HDCManagedRuntimeDiagnostics(
    executableSHA256: SHA256Hex.string(of: HDCOracleFake.driver), clientVersion: "3.2.0d",
    serverVersion: "3.2.0d", endpoint: "127.0.0.1:8710", endpointSource: "default")

  /// The device list in the state the mode names, before the capture
  /// oracle's answers (a connected device, `-v`).
  static let answers =
    #"""
    # Target adoption: the device list in the state the mode names.
    if [ "$*" = "list targets -v" ]; then
      case "$mode" in
      unauthorized)
        printf '%s\t\tUSB\tUnauthorized\tlocalhost\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        exit 0 ;;
      tooMany)
        i=0
        while [ "$i" -lt 1001 ]; do
          printf 'k%04d\t\tUSB\tConnected\tlocalhost\n' "$i"
          i=$((i + 1))
        done
        exit 0 ;;
      esac
    fi

    """# + CaptureDiagnosticsOracleContractTests.answers

  func testSwiftAdoptsTheSharedFakeDeviceAndAnswersItsAvailability() async throws {
    let lock = try HDCOracleFake.lock()
    defer { close(lock) }
    try HDCOracleHarness.recordOrCompare(
      try await oracleFiles(), variable: "ARKDECK_RUST_TARGET_ADOPTION_RECORD",
      oracle: Self.oracle)
  }

  /// The independent USB observation, as the oracle plugs, replugs and
  /// changes it under a read.
  private final class USBRelations: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [TargetUSBRelation] = []
    private var later: (reads: Int, relations: [TargetUSBRelation])?
    private var reads = 0
    func set(
      _ value: [TargetUSBRelation], after: (reads: Int, relations: [TargetUSBRelation])? = nil
    ) {
      lock.withLock {
        current = value
        later = after
        reads = 0
      }
    }
    func read() -> [TargetUSBRelation] {
      lock.withLock {
        reads += 1
        if let later, reads > later.reads { return later.relations }
        return current
      }
    }
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

  private static func send(
    _ handler: RuntimeControlPlaneHandler, _ method: String, _ params: [String: JSONValue]
  ) async throws -> JSONValue {
    try await HDCOracleHarness.send(handler, method, params, frameID: "target-adoption-oracle")
  }

  private static func code(_ answer: JSONValue) -> JSONValue? {
    guard case .object(let fields) = answer, case .object(let error)? = fields["error"] else {
      return nil
    }
    return error["code"]
  }

  /// A member of an answer's result, by its path.
  private static func value(_ answer: JSONValue, _ path: String...) -> JSONValue? {
    var value = answer
    for key in ["result"] + path {
      guard case .object(let fields) = value, let next = fields[key] else { return nil }
      value = next
    }
    return value
  }

  /// The device's row of an observation answer: its observation identity and
  /// the snapshot generation, as `target adopt` names them.
  private static func reference(_ answer: JSONValue) throws -> [String: JSONValue] {
    guard case .array(let rows)? = value(answer, "observations"),
      let row = rows.first(where: {
        if case .object(let fields) = $0 { return fields["candidateKey"] == .string(connectKey) }
        return false
      }),
      case .object(let fields) = row, let observation = fields["observationId"],
      let generation = value(answer, "snapshotGeneration")
    else { throw CocoaError(.coderValueNotFound) }
    return [
      "candidate": .string(connectKey), "observationId": observation,
      "observationGeneration": generation,
    ]
  }

  private func oracleFiles() async throws -> [String: Data] {
    let manager = FileManager.default
    let hdc = try HDCOracleFake.install(answers: Self.answers)
    defer { try? manager.removeItem(at: Self.settings.root) }
    let targets = Self.settings.root.appending(path: "targets-state", directoryHint: .isDirectory)
    let targetStore = try RuntimeTargetStore(directoryURL: targets)
    let usb = USBRelations()
    let composition = try HDCOracleHarness.composition(
      hdc: hdc, targetStore: targetStore, targets: targets, settings: Self.settings,
      agentExecutions: true, usbRelations: { usb.read() },
      hdcRuntimeDiagnostics: Self.diagnostics)
    let handler = composition.handler
    let identities = HDCOracleHarness.RandomIdentities()

    var exchanges: [JSONValue] = []
    var plugged: [String: JSONValue] = [:]
    /// The USB relations the next exchange runs under.
    func plug(
      _ relations: [TargetUSBRelation],
      after: (reads: Int, relations: [TargetUSBRelation])? = nil
    ) {
      usb.set(relations, after: after)
      plugged = ["usbRelations": Self.recorded(relations)]
      if let after {
        plugged["usbRelationsAfter"] = .object([
          "reads": .integer(Int64(after.reads)), "relations": Self.recorded(after.relations),
        ])
      }
    }
    /// One exchange: the fake's mode set first when it names one, the
    /// request sent, and both recorded with their random identities labelled.
    func exchange(
      _ name: String, _ method: String, _ params: [String: JSONValue], mode: String? = nil
    ) async throws -> JSONValue {
      if let mode { try HDCOracleFake.setMode(mode) }
      let answer = try await Self.send(handler, method, params)
      guard case .object(let sent) = try identities.label(.object(params)) else {
        throw CocoaError(.coderInvalidValue)
      }
      var entry = HDCOracleHarness.exchange(
        name, method, sent, try identities.label(answer), mode: mode)
      if case .object(var fields) = entry {
        fields.merge(plugged) { _, new in new }
        entry = .object(fields)
      }
      plugged = [:]
      exchanges.append(entry)
      return answer
    }

    // The device observed with a proved relation, and adopted from it.
    plug([Self.relation(Self.connectKey, attachment: 30)])
    let first = try await exchange("observe", "device.observations", [:], mode: "normal")
    XCTAssertEqual(Self.value(first, "snapshotGeneration"), .string("1"))
    let observed = try Self.reference(first)
    var zero = observed
    zero["observationGeneration"] = .string("01")
    var unknown = observed
    unknown["observationId"] = .string("obs-unknown")
    for (name, params, expected) in [
      ("adopt.invalid", [String: JSONValue](), "invalidInput"),
      ("adopt.leadingZero", zero, "invalidInput"),
      ("adopt.unknown", unknown, "resourceConflict"),
    ] {
      let answer = try await exchange(name, "target.adopt", params)
      XCTAssertEqual(Self.code(answer), .string(expected), name)
    }
    let adoptedAnswer = try await exchange("adopt", "target.adopt", observed)
    XCTAssertEqual(Self.value(adoptedAnswer, "outcome"), .string("adopted"))
    guard case .string(let targetID)? = Self.value(adoptedAnswer, "targetId") else {
      throw CocoaError(.coderValueNotFound)
    }
    let again = try await exchange("adopt.again", "target.adopt", observed)
    XCTAssertEqual(Self.value(again, "targetId"), .string(targetID))
    let named = try await exchange("observe.adopted", "device.observations", [:])
    let later = try Self.reference(named)

    // The target's availability, with the managed server's diagnostics.
    let available = try await exchange(
      "availability", "target.availability", ["targetId": .string(targetID)])
    XCTAssertEqual(Self.value(available, "tool", "state"), .string("ready"))
    for (name, params, expected) in [
      ("availability.missing", [String: JSONValue](), "invalidParams"),
      ("availability.unknown", ["targetId": .string("TGT-000000000000")], "notFound"),
    ] {
      let answer = try await exchange(name, "target.availability", params)
      XCTAssertEqual(Self.code(answer), .string(expected), name)
    }

    // Adopted again from the later observation: the same target.
    let readopted = try await exchange("adopt.readopt", "target.adopt", later)
    XCTAssertEqual(Self.value(readopted, "targetId"), .string(targetID))

    // A trust prompt: the snapshot moves on, the earlier generation is left
    // behind, and the current one waits for the person.
    let prompting = try await exchange(
      "observe.unauthorized", "device.observations", [:], mode: "unauthorized")
    let stale = later.merging(
      ["observationGeneration": .string(String((Int(Self.string(later)) ?? 0) + 1))]
    ) { _, new in new }
    let staleAnswer = try await exchange("adopt.stale", "target.adopt", stale)
    XCTAssertEqual(Self.code(staleAnswer), .string("resourceConflict"))
    let trust = try await exchange(
      "adopt.unauthorized", "target.adopt", try Self.reference(prompting))
    XCTAssertEqual(Self.code(trust), .string("targetTrustPending"))

    // Connected, but nothing proves the device's physical identity.
    plug([])
    let unrelated = try await exchange(
      "observe.unrelated", "device.observations", [:], mode: "normal")
    let denied = try await exchange(
      "adopt.unrelated", "target.adopt", try Self.reference(unrelated))
    XCTAssertEqual(Self.code(denied), .string("admissionDenied"))

    // Replugged, then replugged again during the adoption readback.
    plug([Self.relation(Self.connectKey, attachment: 31)])
    let replugged = try await exchange("observe.replugged", "device.observations", [:])
    let moving = try Self.reference(replugged)
    plug(
      [Self.relation(Self.connectKey, attachment: 31)],
      after: (reads: 2, relations: [Self.relation(Self.connectKey, attachment: 32)]))
    let drifted = try await exchange("adopt.drift", "target.adopt", moving)
    XCTAssertEqual(Self.code(drifted), .string("factsDrifted"))

    // A device list past its bounds, during an adoption and on its own.
    plug([Self.relation(Self.connectKey, attachment: 32)])
    let bounded = try Self.reference(
      try await exchange("observe.bounded", "device.observations", [:]))
    let overflow = try await exchange(
      "adopt.tooMany", "target.adopt", bounded, mode: "tooMany")
    XCTAssertEqual(Self.code(overflow), .string("operationUnavailable"))
    let refused = try await exchange("observe.tooMany", "device.observations", [:])
    XCTAssertEqual(Self.code(refused), .string("operationUnavailable"))

    guard let adopted = try targetStore.find(targetID: targetID) else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    var files = try HDCOracleHarness.files(
      composition, target: adopted,
      cases: .object([
        "target": .object([
          "targetId": .string(adopted.targetID),
          "bindingRevision": .integer(Int64(adopted.bindingRevision)),
          "connectKey": .string(adopted.connectKey),
          "toolVersion": .string(adopted.toolVersion),
        ]),
        "hdcRuntimeDiagnostics": .object([
          "executableSHA256": .string(Self.diagnostics.executableSHA256),
          "clientVersion": .string(Self.diagnostics.clientVersion),
          "serverVersion": .string(Self.diagnostics.serverVersion),
          "endpoint": .string(Self.diagnostics.endpoint),
          "endpointSource": .string(Self.diagnostics.endpointSource),
        ]),
        "exchanges": .array(exchanges),
      ]),
      answers: Self.answers,
      producer:
        "TargetAdoptionOracleContractTests.testSwiftAdoptsTheSharedFakeDeviceAndAnswersItsAvailability",
      settings: Self.settings, identities: identities)
    // The display names the adoption hands the target, beside its binding.
    let names = targets.appending(path: "target-display-names.json")
    if manager.fileExists(atPath: names.path) {
      files["targets-state/target-display-names.json"] = identities.label(
        try Data(contentsOf: names))
    }
    return files
  }

  private static func string(_ reference: [String: JSONValue]) -> String {
    guard case .string(let text)? = reference["observationGeneration"] else { return "" }
    return text
  }
}
