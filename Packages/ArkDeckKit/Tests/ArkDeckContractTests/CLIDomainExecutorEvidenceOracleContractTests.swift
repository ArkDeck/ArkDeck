import Foundation
import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckCore

/// How Swift's client-side executor reads a Job's evidence
/// (`CurrentRuntimeResourceReads.evidence`), recorded for the Rust port
/// (`rust/crates/arkdeck-cli/tests/domain_executor.rs`) to replay.
///
/// The cases are every evidence answer Swift's daemon recorded
/// (`ControlFrames/job.evidence.jsonl`), and variants of two of them. Each
/// records the trusted facts Swift decodes, as Swift encodes them again, or
/// its refusal. A refusal is the executor's own words, or `decoding` for a
/// `DecodingError`, whose text is Swift's own.
///
/// Record a new oracle with
/// `ARKDECK_RUST_DOMAIN_EXECUTOR_EVIDENCE_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class CLIDomainExecutorEvidenceOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/domain-executor-evidence", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_DOMAIN_EXECUTOR_EVIDENCE_RECORD"

  private static func recorded() throws -> [JSONValue] {
    let text = try String(
      contentsOf: repository.appending(
        path:
          "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/job.evidence.jsonl"
      ), encoding: .utf8)
    return try text.split(separator: "\n").compactMap { line in
      let frame = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
      guard case .object(let fields) = frame, fields["ok"] == .bool(true) else { return nil }
      return fields["result"]
    }
  }

  private static func member(_ value: JSONValue?, _ key: String) -> JSONValue? {
    guard case .object(let fields)? = value else { return nil }
    return fields[key]
  }

  /// `value` with the member at `path` replaced, or removed for `nil`.
  private static func with(_ value: JSONValue, _ path: [String], _ replacement: JSONValue?)
    -> JSONValue
  {
    guard case .object(var fields) = value, let key = path.first else { return value }
    if path.count == 1 {
      fields[key] = replacement
    } else {
      fields[key] = with(fields[key] ?? .object([:]), Array(path.dropFirst()), replacement)
    }
    return .object(fields)
  }

  /// `value` with its first Artifact's member `key` replaced, or removed.
  private static func withArtifact(_ value: JSONValue, _ key: String, _ replacement: JSONValue?)
    -> JSONValue
  {
    guard case .array(var artifacts)? = member(value, "artifacts"), let first = artifacts.first
    else { return value }
    artifacts[0] = with(first, [key], replacement)
    return with(value, ["artifacts"], .array(artifacts))
  }

  private static let sha = String(repeating: "a", count: 64)
  private static let epoch: JSONValue = .object([
    "epochId": .string("epoch-1"), "source": .string("completeOverwrite"),
    "stableTargetIdentitySha256": .string(sha), "bindingRevision": .integer(2),
    "coveredIntents": .array([
      .object([
        "jobId": .string("job-1"), "intentEventId": .string("event-1"),
        "operationReference": .string("flash.full-restore@1"),
        "profileReference": .string("dayu200"), "observedAtUtc": .string("2026-07-29T00:00:00Z"),
        "possibleEffects": .array([.string("partitionWrite")]),
      ])
    ]),
    "uncertainEffectSetSha256": .string(sha), "coverageContractVersion": .string("1"),
    "coveredEffectSetSha256": .string(sha), "recoveryJobId": .string("job-2"),
    "recoveryIntentEventId": .string("event-2"),
    "operationReference": .string("flash.full-restore@1"),
    "profileReference": .string("dayu200"), "materializedPlanDigestSha256": .string(sha),
    "artifactSha256": .string(sha), "providerExecutableSha256": .string(sha),
    "confirmedStepIds": .array([.string("step-1")]),
    "resultingTargetEpochSha256": .string(sha),
    "establishedAtUtc": .string("2026-07-29T00:00:00Z"), "epochSha256": .string(sha),
  ])

  private static func variants(base: JSONValue, withArtifacts: JSONValue) -> [(String, JSONValue)] {
    var cases: [(String, JSONValue)] = [
      ("schemaVersion2", with(base, ["schemaVersion"], .string("arkdeck.job-evidence/2"))),
      ("schemaVersionMissing", with(base, ["schemaVersion"], nil)),
      ("artifactsMissing", with(base, ["artifacts"], nil)),
      ("artifactsNotAnArray", with(base, ["artifacts"], .object([:]))),
      ("notAnObject", .array([])),
      ("unknownMember", with(base, ["futureMember"], .string("x"))),
      ("jobIdMissing", with(base, ["jobId"], nil)),
      ("jobIdNull", with(base, ["jobId"], .null)),
      ("operationReferenceNumber", with(base, ["operationReference"], .integer(1))),
      ("outcomeUnknownMissing", with(base, ["outcomeUnknown"], nil)),
      ("outcomeUnknownString", with(base, ["outcomeUnknown"], .string("false"))),
      ("blockersMissing", with(base, ["blockers"], nil)),
      ("blockersNumbers", with(base, ["blockers"], .array([.integer(1)]))),
      ("executionModeMissing", with(base, ["executionMode"], nil)),
      ("bindingRevisionNull", with(base, ["bindingRevision"], .null)),
      ("bindingRevisionMissing", with(base, ["bindingRevision"], nil)),
      ("bindingRevisionString", with(base, ["bindingRevision"], .string("1"))),
      ("bindingRevisionInt64Max", with(base, ["bindingRevision"], .integer(Int64.max))),
      ("bindingRevisionBeyondInt64", with(base, ["bindingRevision"], .unsignedInteger(UInt64.max))),
      ("actualEffectUnknown", with(base, ["actualEffect"], .string("sideEffect"))),
      ("actualEffectNull", with(base, ["actualEffect"], .null)),
      ("actualStepKindsNull", with(base, ["actualStepKinds"], .null)),
      ("actualStepKindsNumbers", with(base, ["actualStepKinds"], .array([.integer(1)]))),
      ("startedAtNull", with(base, ["startedAtUtc"], .null)),
      ("finishedAtMissing", with(base, ["finishedAtUtc"], nil)),
      ("authorityNull", with(base, ["authority"], .null)),
      ("authorityRetiredKind", with(base, ["authority", "kind"], .string("standingAuthorization"))),
      ("authorityUnknownKind", with(base, ["authority", "kind"], .string("adminGrant"))),
      ("authorityReferenceMissing", with(base, ["authority", "reference"], nil)),
      ("authorityUnknownMember", with(base, ["authority", "futureMember"], .integer(1))),
      ("authorityUseOrdinalString", with(base, ["authority", "useOrdinal"], .string("1"))),
      ("authorityUseOrdinalFraction", with(base, ["authority", "useOrdinal"], .number(1.5))),
      ("authorityValidUntilNull", with(base, ["authority", "validUntilUtc"], .null)),
      ("authorityRecoveryEpoch", with(base, ["authority", "recoveryEpoch"], epoch)),
      (
        "authorityRecoveryEpochPartial",
        with(base, ["authority", "recoveryEpoch"], .object(["epochId": .string("epoch-1")]))
      ),
      ("observationNull", with(base, ["observation"], .null)),
      ("observationTransportUnknown", with(base, ["observation", "transport"], .string("bluetooth"))),
      ("observationTransportNull", with(base, ["observation", "transport"], .null)),
      ("observationStepsMissing", with(base, ["observation", "preflightSteps"], nil)),
      ("observationProviderMissing", with(base, ["observation", "providerId"], nil)),
      ("observationModelNull", with(base, ["observation", "model"], .null)),
      ("recoveryEpoch", with(base, ["recoveryEpoch"], epoch)),
      ("recoveryEpochNull", with(base, ["recoveryEpoch"], .null)),
      (
        "recoveryEpochIntentsMissing",
        with(base, ["recoveryEpoch"], with(epoch, ["coveredIntents"], nil))
      ),
    ]
    cases += [
      ("artifactCountLeadingZero", withArtifact(withArtifacts, "byteCount", .string("0240"))),
      ("artifactCountNegative", withArtifact(withArtifacts, "byteCount", .string("-1"))),
      ("artifactCountPlus", withArtifact(withArtifacts, "byteCount", .string("+240"))),
      ("artifactCountInteger", withArtifact(withArtifacts, "byteCount", .integer(240))),
      ("artifactCountZero", withArtifact(withArtifacts, "byteCount", .string("0"))),
      ("artifactBytesVerifiedMissing", withArtifact(withArtifacts, "bytesVerified", nil)),
      ("artifactBindingRevisionNull", withArtifact(withArtifacts, "bindingRevision", .null)),
      ("artifactUnknownMember", withArtifact(withArtifacts, "futureMember", .bool(true))),
      ("artifactNotAnObject", with(withArtifacts, ["artifacts"], .array([.string("ART-1")]))),
    ]
    return cases
  }

  func testSwiftEvidenceDecisionsTheRustPortReplays() throws {
    let recorded = try Self.recorded()
    guard
      let base = recorded.first(where: {
        Self.member($0, "jobId") == .string("job-4c6693b5208a9a64998bb2c199676fa7")
      }),
      let withArtifacts = recorded.first(where: {
        if case .array(let artifacts)? = Self.member($0, "artifacts") { return !artifacts.isEmpty }
        return false
      })
    else { throw XCTSkip("Swift recorded no evidence to vary") }
    let cases =
      recorded.enumerated().map { ("recorded\($0.offset)", $0.element) }
      + Self.variants(base: base, withArtifacts: withArtifacts)
    let records: [JSONValue] = try cases.map { name, value in
      var fields: [String: JSONValue] = ["name": .string(name), "value": value]
      do {
        let facts = try CurrentRuntimeResourceReads.evidence(value)
        fields["facts"] = try JSONDecoder().decode(
          JSONValue.self, from: JSONEncoder().encode(facts))
      } catch let error as RuntimeAgentExecutorError {
        fields["refusal"] = .string(String(describing: error))
      } catch is DecodingError {
        fields["refusal"] = .string("decoding")
      }
      return .object(fields)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [:]
    files["cases.json"] = try encoder.encode(JSONValue.array(records)) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("CLIDomainExecutorEvidenceOracleContractTests"),
          "owners": .array([
            .string("CurrentRuntimeResourceReads.evidence"),
            .string("RuntimeHardwareEvidenceTrustedFacts"),
          ]),
          "answers": .string("Fixtures/ControlFrames/job.evidence.jsonl"),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}
