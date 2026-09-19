// Shared Swift oracle for the Rust recovery-manifest codec (TASK-XPA-014).
//
// `RecoveryManifestContract.swift` is the last carrier row of ADR-0009
// decision 4 in the CHG-2026-074 decision package
// (`evidence/adr-0009-decision-package-20260914.md` §2): a hazard's certainty
// is `confirmed` or `outcomeUnknown` and nothing else, a `known` device mode
// without its evidence refuses to decode, and every level of the record
// refuses a member it does not name. The maintainer ruled on 2026-09-19 that
// Rust ports that carrier unchanged.
//
// This oracle feeds `RecoveryManifestCodec.decode` one document per case and
// records what it decides: accepted, with the bytes `RecoveryManifestCodec
// .encode` writes back, or refused, with the refusal's kind. The Rust codec
// replays every document, must reach the same decision, and must write the
// same canonical bytes for every accepted one. Because every document except
// the textual ones is the canonical encoding of a JSON object, a Rust writer
// that adds one member to an accepted record writes exactly the refused
// document recorded here.
//
// Production never writes a non-null recovery manifest: the Session composer
// (`RuntimeSessionPublication.swift`) seals `recovery: null` and refuses an
// unresolved Job. The codec is read by Session manifest validation
// (`SessionManifest.swift` `validateRecovery`) and rewritten only by the
// export redaction's argument re-hash (`RetentionAndExport.swift`).
//
// Everything here is host-local: no device, no daemon, no store. Record a new
// oracle with `ARKDECK_RUST_RECOVERY_MANIFEST_RECORD=/private/tmp/<new
// directory>`; otherwise the checked-in oracle must match byte for byte.
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage

final class RecoveryManifestOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/recovery-manifest", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_RECOVERY_MANIFEST_RECORD"
  private static let contractSource = "Packages/ArkDeckKit/Sources/ArkDeckStorage/RecoveryManifestContract.swift"

  private var cases: [JSONValue] = []
  private var files: [String: Data] = [:]

  private typealias Document = [String: JSONValue]

  private static func hazard(
    code: String = "fixture.hazard", severity: String = "possibleBrick",
    certainty: String = "outcomeUnknown"
  ) -> JSONValue {
    .object([
      "code": .string(code), "summary": .string("fixture hazard"),
      "severity": .string(severity), "outcomeCertainty": .string(certainty),
    ])
  }

  /// Every member present and non-null: the shape an archived interrupted
  /// Session carries.
  private static func base() -> Document {
    [
      "needsAttention": .bool(true),
      "interruptedReason": .string("fixture interruption"),
      "deviceHazards": .array([hazard()]),
      "abandonAuditEventIds": .array([.string("event-abandon")]),
      "lastConfirmedStepId": .string("step-probe"),
      "lastDeviceMode": .object([
        "state": .string("known"), "value": .string("loader"),
        "evidence": .string("fixture observation"),
      ]),
      "managedHostProcessState": .string("notRunning"),
      "recoveryGuide": .object([
        "providerIdentity": .string("fixture-provider"),
        "automaticRecoveryAvailable": .bool(false),
        "summary": .string("fixture recovery"),
        "steps": .array([.string("fixture guidance")]),
      ]),
      "unexecutedCompensations": .array([]),
      "userConfirmation": .object([
        "confirmationId": .string("confirmation-abandon"), "actor": .string("user"),
        "decision": .string("archiveInterrupted"),
        "confirmedAt": .string("2026-01-01T00:00:00Z"),
      ]),
      "recoveryOfSessionId": .null,
      "recoveryOfJobId": .null,
    ]
  }

  /// A declared `restoreParameter` compensation, encoded by the typed
  /// descriptor itself so its policy is exactly the kind's minimum.
  private static func compensation() throws -> Document {
    let arguments: [String: JSONValue] = [
      "name": .string("persist.fixture"), "snapshotStepId": .string("step-probe"),
      "restorePolicy": .string("restoreKnownValue"),
    ]
    let hash = SHA256Hex.string(
      of: try CanonicalJSONEncoders.canonical().encode(JSONValue.object(arguments)))
    let descriptor = try CompensationDescriptor(
      id: "comp-restore", kind: .restoreParameter, declaredEffect: .hostOnly,
      declaredCancellation: .immediate, declaredBindingRequirement: .none,
      trigger: .onAnyTerminal, arguments: arguments, argumentsHash: hash)
    guard
      case .object(let object) = try JSONDecoder().decode(
        JSONValue.self, from: JSONEncoder().encode(descriptor))
    else { throw CocoaError(.coderInvalidValue) }
    return object
  }

  private static func edit(
    _ document: inout Document, _ key: String, _ body: (inout Document) -> Void
  ) {
    guard case .object(var nested) = document[key] else { return }
    body(&nested)
    document[key] = .object(nested)
  }

  private static func editHazard(_ document: inout Document, _ body: (inout Document) -> Void) {
    guard case .array(let hazards) = document["deviceHazards"],
      case .object(var hazard) = hazards.first
    else { return }
    body(&hazard)
    document["deviceHazards"] = .array([.object(hazard)])
  }

  private static func withCompensation(
    _ document: inout Document, _ body: (inout Document) -> Void
  ) throws {
    var descriptor = try compensation()
    body(&descriptor)
    document["unexecutedCompensations"] = .array([.object(descriptor)])
  }

  private static func canonical(_ document: Document) throws -> Data {
    try CanonicalJSONEncoders.canonical().encode(JSONValue.object(document))
  }

  /// What `RecoveryManifestCodec.decode` decides about these bytes. An
  /// accepted record must also survive its own canonical round trip.
  private static func verdict(_ data: Data) throws -> (outcome: String, canonical: Data?) {
    do {
      let record = try RecoveryManifestCodec.decode(data)
      let canonical = try RecoveryManifestCodec.encode(record)
      XCTAssertEqual(try RecoveryManifestCodec.decode(canonical), record)
      XCTAssertEqual(
        try RecoveryManifestCodec.encode(RecoveryManifestCodec.decode(canonical)), canonical)
      return ("accepted", canonical)
    } catch RecoveryManifestContractError.unknownOrMissingFields {
      return ("unknownOrMissingFields", nil)
    } catch RecoveryManifestContractError.invalidField(let field) {
      return ("invalidField(\(field))", nil)
    } catch is ArkDeckStorage.StrictJSONError {
      return ("strictJSON", nil)
    } catch is DecodingError {
      return ("decoding", nil)
    } catch is WorkflowStepValidationError {
      return ("compensation", nil)
    }
  }

  private func add(_ name: String, bytes: Data, expected: String) throws {
    let stem = String(format: "%02d-%@", cases.count + 1, name)
    let documentPath = "documents/\(stem).json"
    let (outcome, canonical) = try Self.verdict(bytes)
    XCTAssertEqual(outcome, expected, name)
    files[documentPath] = bytes
    var entry: [String: JSONValue] = [
      "name": .string(name), "document": .string(documentPath), "outcome": .string(outcome),
    ]
    if let canonical {
      let canonicalPath = "canonical/\(stem).json"
      files[canonicalPath] = canonical
      entry["canonical"] = .string(canonicalPath)
    }
    cases.append(.object(entry))
  }

  private func add(
    _ name: String, expected: String, _ body: (inout Document) throws -> Void = { _ in }
  ) throws {
    var document = Self.base()
    try body(&document)
    try add(name, bytes: try Self.canonical(document), expected: expected)
  }

  func testSwiftRecoveryManifestCodecDecisionsAndCanonicalBytes() throws {
    let accepted = "accepted"
    let unknownOrMissing = "unknownOrMissingFields"

    // Accepted shapes.
    try add("base", expected: accepted)
    try add("minimal", expected: accepted) { document in
      document["needsAttention"] = .bool(false)
      document["interruptedReason"] = .null
      document["deviceHazards"] = .array([])
      document["abandonAuditEventIds"] = .array([])
      document["lastConfirmedStepId"] = .null
      document["lastDeviceMode"] = .object(["state": .string("unknown")])
      document["managedHostProcessState"] = .string("notApplicable")
      document["userConfirmation"] = .null
    }
    for state in ["notStarted", "stoppedAtSafeBoundary", "stillRunningUnknown", "notApplicable"] {
      try add("process-\(state)", expected: accepted) { document in
        document["managedHostProcessState"] = .string(state)
      }
    }
    try add("hazard-vocabulary", expected: accepted) { document in
      document["deviceHazards"] = .array([
        Self.hazard(code: "hazard.warning", severity: "warning", certainty: "confirmed"),
        Self.hazard(code: "hazard.blocking", severity: "blocking", certainty: "outcomeUnknown"),
        Self.hazard(code: "hazard.brick", severity: "possibleBrick", certainty: "confirmed"),
      ])
    }
    try add("hazard-duplicate", expected: accepted) { document in
      document["deviceHazards"] = .array([Self.hazard(), Self.hazard()])
    }
    try add("guide-automatic", expected: accepted) { document in
      Self.edit(&document, "recoveryGuide") { $0["automaticRecoveryAvailable"] = .bool(true) }
    }
    try add("recovery-of-pair", expected: accepted) { document in
      document["recoveryOfSessionId"] = .string("session-prior")
      document["recoveryOfJobId"] = .string("job-prior")
    }
    try add("confirmation-offset-fraction", expected: accepted) { document in
      Self.edit(&document, "userConfirmation") {
        $0["confirmedAt"] = .string("2026-01-01T08:00:00.5+08:00")
      }
    }
    try add("identifier-bounds", expected: accepted) { document in
      document["abandonAuditEventIds"] = .array([
        .string("a" + String(repeating: "9", count: 127)), .string("A._:-z"),
      ])
    }
    try add("unicode-and-solidus", expected: accepted) { document in
      document["interruptedReason"] = .string("设备停在 loader/maskrom 模式")
      Self.edit(&document, "recoveryGuide") {
        $0["steps"] = .array([.string("重新接入 USB/OTG 后读回"), .string("\u{1F50C} step two")])
      }
    }
    try add("compensation", expected: accepted) { document in
      try Self.withCompensation(&document) { _ in }
    }
    try add("compensation-uppercase-hash", expected: accepted) { document in
      try Self.withCompensation(&document) { descriptor in
        if case .string(let hash) = descriptor["argumentsHash"] {
          descriptor["argumentsHash"] = .string(hash.uppercased())
        }
      }
    }
    try add("compensation-unverified-hash", expected: accepted) { document in
      try Self.withCompensation(&document) {
        $0["argumentsHash"] = .string(String(repeating: "0", count: 64))
      }
    }
    let pretty = JSONEncoder()
    pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
    try add(
      "pretty-printed", bytes: try pretty.encode(JSONValue.object(Self.base())),
      expected: accepted)

    // The record itself.
    try add("extra-member", expected: unknownOrMissing) { $0["extra"] = .bool(true) }
    try add("missing-member", expected: unknownOrMissing) {
      $0.removeValue(forKey: "recoveryOfJobId")
    }
    try add("attention-not-bool", expected: "decoding") {
      $0["needsAttention"] = .string("true")
    }
    try add("reason-empty", expected: "invalidField(recovery)") {
      $0["interruptedReason"] = .string("")
    }
    try add("audit-duplicate", expected: "invalidField(recovery)") {
      $0["abandonAuditEventIds"] = .array([.string("event-abandon"), .string("event-abandon")])
    }
    try add("audit-leading-space", expected: "invalidField(recovery)") {
      $0["abandonAuditEventIds"] = .array([.string(" event")])
    }
    try add("audit-leading-dot", expected: "invalidField(recovery)") {
      $0["abandonAuditEventIds"] = .array([.string(".event")])
    }
    try add("audit-too-long", expected: "invalidField(recovery)") {
      $0["abandonAuditEventIds"] = .array([.string(String(repeating: "a", count: 129))])
    }
    try add("audit-without-confirmation", expected: "invalidField(recovery)") {
      $0["userConfirmation"] = .null
    }
    try add("last-step-invalid", expected: "invalidField(recovery)") {
      $0["lastConfirmedStepId"] = .string("step probe")
    }
    try add("process-unknown", expected: "invalidField(recovery)") {
      $0["managedHostProcessState"] = .string("running")
    }
    try add("recovery-of-session-invalid", expected: "invalidField(recovery)") {
      $0["recoveryOfSessionId"] = .string("-session")
    }
    try add("recovery-of-job-invalid", expected: "invalidField(recovery)") {
      $0["recoveryOfJobId"] = .string("")
    }
    let canonicalBase = String(decoding: try Self.canonical(Self.base()), as: UTF8.self)
    try add(
      "duplicate-member",
      bytes: Data(
        canonicalBase.replacingOccurrences(
          of: #"{"abandonAuditEventIds":"#, with: #"{"abandonAuditEventIds":[],"abandonAuditEventIds":"#
        ).utf8), expected: "strictJSON")
    try add("trailing-bytes", bytes: Data((canonicalBase + "{}").utf8), expected: "strictJSON")
    try add("not-an-object", bytes: Data("[]".utf8), expected: "decoding")

    // Hazards: a certainty other than confirmed or outcomeUnknown is refused.
    try add("hazard-extra-member", expected: unknownOrMissing) {
      Self.editHazard(&$0) { $0["extra"] = .bool(true) }
    }
    try add("hazard-missing-member", expected: unknownOrMissing) {
      Self.editHazard(&$0) { $0.removeValue(forKey: "summary") }
    }
    try add("hazard-certainty-mixed", expected: "invalidField(hazard)") {
      Self.editHazard(&$0) { $0["outcomeCertainty"] = .string("mixed") }
    }
    try add("hazard-certainty-not-applicable", expected: "invalidField(hazard)") {
      Self.editHazard(&$0) { $0["outcomeCertainty"] = .string("notApplicable") }
    }
    try add("hazard-severity-unknown", expected: "invalidField(hazard)") {
      Self.editHazard(&$0) { $0["severity"] = .string("fatal") }
    }
    try add("hazard-summary-empty", expected: "invalidField(hazard)") {
      Self.editHazard(&$0) { $0["summary"] = .string("") }
    }
    try add("hazard-code-invalid", expected: "invalidField(hazard)") {
      Self.editHazard(&$0) { $0["code"] = .string("fixture hazard") }
    }
    try add("hazard-not-object", expected: "decoding") {
      $0["deviceHazards"] = .array([.string("fixture.hazard")])
    }

    // The device mode: `known` is never guessed.
    try add("mode-unknown-extra-member", expected: unknownOrMissing) {
      $0["lastDeviceMode"] = .object(["state": .string("unknown"), "value": .string("loader")])
    }
    try add("mode-known-without-evidence", expected: "invalidField(lastDeviceMode)") {
      $0["lastDeviceMode"] = .object(["state": .string("known"), "value": .string("loader")])
    }
    try add("mode-known-empty-evidence", expected: "invalidField(lastDeviceMode)") {
      Self.edit(&$0, "lastDeviceMode") { $0["evidence"] = .string("") }
    }
    try add("mode-known-empty-value", expected: "invalidField(lastDeviceMode)") {
      Self.edit(&$0, "lastDeviceMode") { $0["value"] = .string("") }
    }
    try add("mode-known-value-not-string", expected: "invalidField(lastDeviceMode)") {
      Self.edit(&$0, "lastDeviceMode") { $0["value"] = .integer(1) }
    }
    try add("mode-known-extra-member", expected: "invalidField(lastDeviceMode)") {
      Self.edit(&$0, "lastDeviceMode") { $0["extra"] = .bool(true) }
    }
    try add("mode-state-unknown-word", expected: "invalidField(lastDeviceMode.state)") {
      $0["lastDeviceMode"] = .object(["state": .string("guessed")])
    }
    try add("mode-state-missing", expected: "decoding") {
      $0["lastDeviceMode"] = .object([:])
    }

    // The recovery guide.
    try add("guide-extra-member", expected: unknownOrMissing) {
      Self.edit(&$0, "recoveryGuide") { $0["extra"] = .bool(true) }
    }
    try add("guide-steps-empty", expected: "invalidField(recoveryGuide)") {
      Self.edit(&$0, "recoveryGuide") { $0["steps"] = .array([]) }
    }
    try add("guide-step-empty", expected: "invalidField(recoveryGuide)") {
      Self.edit(&$0, "recoveryGuide") { $0["steps"] = .array([.string("")]) }
    }
    try add("guide-provider-empty", expected: "invalidField(recoveryGuide)") {
      Self.edit(&$0, "recoveryGuide") { $0["providerIdentity"] = .string("") }
    }
    try add("guide-summary-empty", expected: "invalidField(recoveryGuide)") {
      Self.edit(&$0, "recoveryGuide") { $0["summary"] = .string("") }
    }
    try add("guide-automatic-not-bool", expected: "decoding") {
      Self.edit(&$0, "recoveryGuide") { $0["automaticRecoveryAvailable"] = .string("false") }
    }

    // The abandon confirmation: only the user archives an interrupted Session.
    try add("confirmation-extra-member", expected: unknownOrMissing) {
      Self.edit(&$0, "userConfirmation") { $0["extra"] = .bool(true) }
    }
    try add("confirmation-missing-member", expected: unknownOrMissing) {
      Self.edit(&$0, "userConfirmation") { $0.removeValue(forKey: "actor") }
    }
    try add("confirmation-actor-agent", expected: "invalidField(userConfirmation)") {
      Self.edit(&$0, "userConfirmation") { $0["actor"] = .string("standardAgent") }
    }
    try add("confirmation-decision-other", expected: "invalidField(userConfirmation)") {
      Self.edit(&$0, "userConfirmation") { $0["decision"] = .string("resume") }
    }
    try add("confirmation-date-invalid", expected: "invalidField(userConfirmation)") {
      Self.edit(&$0, "userConfirmation") { $0["confirmedAt"] = .string("2026-02-30T00:00:00Z") }
    }
    try add("confirmation-id-invalid", expected: "invalidField(userConfirmation)") {
      Self.edit(&$0, "userConfirmation") { $0["confirmationId"] = .string("confirmation abandon") }
    }

    // Unexecuted compensations: the typed descriptor, then its raw policy.
    try add("compensation-extra-member", expected: "compensation") { document in
      try Self.withCompensation(&document) { $0["extra"] = .bool(true) }
    }
    try add("compensation-kind-not-compensating", expected: "compensation") { document in
      try Self.withCompensation(&document) { $0["kind"] = .string("setParameter") }
    }
    try add("compensation-hash-short", expected: "compensation") { document in
      try Self.withCompensation(&document) {
        $0["argumentsHash"] = .string(String(repeating: "a", count: 63))
      }
    }
    try add("compensation-argument-missing", expected: "compensation") { document in
      try Self.withCompensation(&document) { descriptor in
        guard case .object(var arguments) = descriptor["arguments"] else { return }
        arguments.removeValue(forKey: "restorePolicy")
        descriptor["arguments"] = .object(arguments)
      }
    }
    let understatedPolicy = "invalidField(unexecutedCompensations.policy)"
    try add("compensation-effect-understated", expected: understatedPolicy) { document in
      try Self.withCompensation(&document) { $0["effect"] = .string("hostOnly") }
    }
    try add("compensation-binding-understated", expected: understatedPolicy) { document in
      try Self.withCompensation(&document) { $0["bindingRequirement"] = .string("none") }
    }
    try add("compensation-trigger-unknown", expected: "decoding") { document in
      try Self.withCompensation(&document) { $0["trigger"] = .string("onRecovery") }
    }
    try add("compensation-not-object", expected: "decoding") {
      $0["unexecutedCompensations"] = .array([.string("comp-restore")])
    }

    try record()
  }

  private func record() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    files["cases.json"] = try encoder.encode(JSONValue.array(cases)) + Data("\n".utf8)
    var digests: [String: JSONValue] = [:]
    for (path, data) in files { digests[path] = .string(SHA256Hex.string(of: data)) }
    let source = try Data(contentsOf: Self.repository.appending(path: Self.contractSource))
    let provenance: [String: JSONValue] = [
      "producer": .string(
        "RecoveryManifestOracleContractTests.testSwiftRecoveryManifestCodecDecisionsAndCanonicalBytes"
      ),
      "codec": .object([
        "source": .string(Self.contractSource),
        "sourceSHA256": .string(SHA256Hex.string(of: source)),
        "decode": .string("RecoveryManifestCodec.decode"),
        "encode": .string("RecoveryManifestCodec.encode (CanonicalJSONEncoders.canonical)"),
      ]),
      "outcomes": .array(
        [
          "accepted", "unknownOrMissingFields", "invalidField(<field>)", "strictJSON", "decoding",
          "compensation",
        ].map(JSONValue.string)),
      "files": .object(digests),
    ]
    files["provenance.json"] =
      try encoder.encode(JSONValue.object(provenance)) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}
