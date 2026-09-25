import Foundation
import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// What Swift's `trace inspect` leaf decides, recorded for the Rust CLI to
/// replay (`rust/crates/arkdeck-cli/tests/trace_inspect.rs`).
///
/// - `projections.json`: `RuntimeTraceInspectionProjection` over the Trace
///   inspection Swift's daemon answered (`ControlFrames/trace.inspect.jsonl`)
///   and variants of it. Each is accepted with the owner and Artifact it names,
///   or refused with Swift's reason.
/// - `scopes.json`: the machine quality scopes a data-quality issue may name.
/// - `failures.json`: what `CLIRuntimeSession.mapped` makes of each daemon
///   refusal of `trace.inspect`: its code, words and `details`, with and without
///   the Trace inspection owner's zero-dispatch proof.
/// - `argv.json`: what `RuntimeCLI.runTrace` decides for an argv Swift's
///   registry accepts. It is a refusal with its code, words and `details`, or
///   the request reaching for a Runtime that is not there.
///
/// Record a new oracle with
/// `ARKDECK_RUST_TRACE_INSPECT_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class CLITraceInspectOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/trace-inspect", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_TRACE_INSPECT_RECORD"
  private static let absentSocket = "/tmp/arkdeck-trace-inspect-no-daemon"

  /// The Trace inspection Swift's daemon answered.
  private static func recorded() throws -> JSONValue {
    let frames = try String(
      contentsOf: repository.appending(
        path:
          "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/trace.inspect.jsonl"
      ), encoding: .utf8)
    for line in frames.split(separator: "\n") {
      let frame = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
      if case .object(let fields) = frame, fields["ok"] == .bool(true),
        let result = fields["result"]
      {
        return result
      }
    }
    throw XCTSkip("Swift recorded no Trace inspection")
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

  private static func issue(_ category: String, _ scope: JSONValue, _ count: JSONValue)
    -> JSONValue
  {
    .object(["category": .string(category), "scope": scope, "count": count])
  }

  private static func quality(_ status: String, _ issues: [JSONValue]) -> JSONValue {
    .object(["status": .string(status), "issues": .array(issues)])
  }

  private static func projections(_ base: JSONValue) -> [(String, JSONValue)] {
    let hex40 = String(repeating: "a", count: 40)
    let sha = String(repeating: "e", count: 64)
    var cases: [(String, JSONValue)] = [
      ("base", base),
      ("notAnObject", .array([])),
      ("null", .null),
      ("rootExtraMember", with(base, ["extra"], .integer(1))),
      ("rootMissingStorageMode", with(base, ["storageMode"], nil)),
      ("schemaVersion2", with(base, ["schemaVersion"], .string("arkdeck.trace-inspection/2"))),
      (
        "ownerImport",
        with(
          base, ["owner"],
          .object([
            "kind": .string("import"),
            "id": .string("imp-123e4567-e89b-42d3-a456-426614174000"),
          ]))
      ),
      ("ownerJobWithImportIdentity", with(base, ["owner", "id"], .string("imp-x"))),
      ("ownerBadIdentity", with(base, ["owner", "id"], .string("bad:id"))),
      ("ownerExtraMember", with(base, ["owner", "extra"], .string("x"))),
      ("ownerOtherJob", with(base, ["owner", "id"], .string("job-other"))),
      ("storageModeDurable", with(base, ["storageMode"], .string("durable"))),
      ("deviceEvidenceCreatedTrue", with(base, ["deviceEvidenceCreated"], .bool(true))),
      ("deviceEvidenceCreatedString", with(base, ["deviceEvidenceCreated"], .string("false"))),
      ("sourceExtraMember", with(base, ["source", "extra"], .string("x"))),
      ("sourceMissingPrivacy", with(base, ["source", "privacy"], nil)),
      ("artifactIdEmpty", with(base, ["source", "artifactId"], .string(""))),
      ("artifactIdColon", with(base, ["source", "artifactId"], .string("ART:1"))),
      ("artifactIdLeadingDot", with(base, ["source", "artifactId"], .string(".ART"))),
      (
        "artifactId128",
        with(base, ["source", "artifactId"], .string(String(repeating: "A", count: 128)))
      ),
      (
        "artifactId129",
        with(base, ["source", "artifactId"], .string(String(repeating: "A", count: 129)))
      ),
      ("artifactIdOther", with(base, ["source", "artifactId"], .string("ART-other"))),
      (
        "artifactDigestUppercase",
        with(base, ["source", "artifactDigest"], .string(String(repeating: "A", count: 64)))
      ),
      (
        "artifactDigestShort",
        with(base, ["source", "artifactDigest"], .string(String(repeating: "a", count: 63)))
      ),
      ("byteCountZero", with(base, ["source", "byteCount"], .string("0"))),
      ("byteCountLeadingZero", with(base, ["source", "byteCount"], .string("013"))),
      ("byteCountPlus", with(base, ["source", "byteCount"], .string("+13"))),
      ("byteCountNegative", with(base, ["source", "byteCount"], .string("-1"))),
      ("byteCountInteger", with(base, ["source", "byteCount"], .integer(13))),
      (
        "byteCountInt64Max",
        with(base, ["source", "byteCount"], .string("9223372036854775807"))
      ),
      (
        "byteCountOverflow",
        with(base, ["source", "byteCount"], .string("9223372036854775808"))
      ),
      (
        "sourceOperationOther",
        with(base, ["source", "sourceOperation"], .string("capture.diagnostics@2"))
      ),
      ("nameOther", with(base, ["source", "name"], .string("trace.bin"))),
      ("mediaTypeOther", with(base, ["source", "mediaType"], .string("application/json"))),
      ("privacyInternal", with(base, ["source", "privacy"], .string("internal"))),
      ("engineNameOther", with(base, ["engine", "name"], .string("Perfetto"))),
      ("engineExtraMember", with(base, ["engine", "extra"], .string("x"))),
      ("engineBuildEmpty", with(base, ["engine", "build"], .string(""))),
      (
        "engineSourceRevision39",
        with(base, ["engine", "sourceRevision"], .string(String(repeating: "a", count: 39)))
      ),
      (
        "engineSourceRevisionUppercase",
        with(base, ["engine", "sourceRevision"], .string(String(repeating: "A", count: 40)))
      ),
      (
        "engineSourceRevisionNonHex",
        with(base, ["engine", "sourceRevision"], .string(String(repeating: "g", count: 40)))
      ),
      ("parserExtraMember", with(base, ["parser", "extra"], .string("x"))),
      ("parserNameEmpty", with(base, ["parser", "name"], .string(""))),
      ("parserVersionSlash", with(base, ["parser", "version"], .string("a/b"))),
      (
        "parserUpstreamRevision41",
        with(base, ["parser", "upstreamRevision"], .string(hex40 + "a"))
      ),
      (
        "parserBinarySha256Uppercase",
        with(base, ["parser", "binarySha256"], .string(String(repeating: "D", count: 64)))
      ),
      ("parserAdapterVersionControl", with(base, ["parser", "adapterVersion"], .string("\u{1}"))),
      (
        "parserBuildRecipeVersion129",
        with(
          base, ["parser", "buildRecipeVersion"], .string(String(repeating: "r", count: 129)))
      ),
      ("schemaExtraMember", with(base, ["schema", "extra"], .string("x"))),
      (
        "schemaFingerprintShort",
        with(base, ["schema", "fingerprint"], .string(String(repeating: "b", count: 63)))
      ),
      ("provenanceExtraMember", with(base, ["schema", "provenance", "extra"], .string("x"))),
      (
        "provenanceAdapterVersionEmpty",
        with(base, ["schema", "provenance", "adapterVersion"], .string(""))
      ),
      (
        "provenanceIndexVersionNegative",
        with(base, ["schema", "provenance", "indexVersion"], .integer(-1))
      ),
      (
        "provenanceIndexVersionZero",
        with(base, ["schema", "provenance", "indexVersion"], .integer(0))
      ),
      (
        "provenanceIndexVersionString",
        with(base, ["schema", "provenance", "indexVersion"], .string("1"))
      ),
      (
        "provenanceIndexVersionFraction",
        with(base, ["schema", "provenance", "indexVersion"], .number(1.5))
      ),
      (
        "provenanceIndexVersionInt64Max",
        with(base, ["schema", "provenance", "indexVersion"], .integer(Int64.max))
      ),
      (
        "provenanceDatabaseShaUppercase",
        with(
          base, ["schema", "provenance", "upstreamDatabaseSha256"],
          .string(String(repeating: "E", count: 64)))
      ),
      (
        "provenanceDatabaseByteCountNegative",
        with(base, ["schema", "provenance", "upstreamDatabaseByteCount"], .string("-1"))
      ),
      (
        "provenanceDatabaseByteCountZero",
        with(base, ["schema", "provenance", "upstreamDatabaseByteCount"], .string("0"))
      ),
      (
        "provenanceDatabaseByteCountLeadingZero",
        with(base, ["schema", "provenance", "upstreamDatabaseByteCount"], .string("00"))
      ),
      (
        "provenanceDatabaseByteCountInteger",
        with(base, ["schema", "provenance", "upstreamDatabaseByteCount"], .integer(13))
      ),
      ("traceExtraMember", with(base, ["trace", "extra"], .string("x"))),
      ("durationNegative", with(base, ["trace", "durationNs"], .string("-1"))),
      ("durationZero", with(base, ["trace", "durationNs"], .string("0"))),
      ("durationMinusZero", with(base, ["trace", "durationNs"], .string("-0"))),
      ("durationInteger", with(base, ["trace", "durationNs"], .integer(42))),
      (
        "durationInt64Max",
        with(base, ["trace", "durationNs"], .string("9223372036854775807"))
      ),
      (
        "capabilitiesExtraMember",
        with(base, ["trace", "capabilities", "extra"], .bool(true))
      ),
      (
        "capabilitiesMissingMember",
        with(base, ["trace", "capabilities", "processCounters"], nil)
      ),
      (
        "capabilityString",
        with(base, ["trace", "capabilities", "cpuScheduling"], .string("true"))
      ),
      ("qualityExtraMember", with(base, ["dataQuality", "extra"], .string("x"))),
      ("qualityWarningsWithoutIssues", with(base, ["dataQuality"], quality("warnings", []))),
      ("qualityStatusOther", with(base, ["dataQuality"], quality("unknown", []))),
      (
        "qualityOneIssue",
        with(
          base, ["dataQuality"],
          quality("warnings", [issue("probeTruncated", .null, .null)]))
      ),
      (
        "qualityIssueWithScope",
        with(
          base, ["dataQuality"],
          quality("warnings", [issue("invalidValue", .string("thread.name"), .integer(3))]))
      ),
      (
        "qualityOkWithIssue",
        with(base, ["dataQuality"], quality("ok", [issue("probeTruncated", .null, .null)]))
      ),
      (
        "qualityIssueUnknownCategory",
        with(base, ["dataQuality"], quality("warnings", [issue("lostValue", .null, .null)]))
      ),
      (
        "qualityIssueUnknownScope",
        with(
          base, ["dataQuality"],
          quality("warnings", [issue("invalidValue", .string("thread.color"), .null)]))
      ),
      (
        "qualityIssueNegativeCount",
        with(
          base, ["dataQuality"],
          quality("warnings", [issue("invalidValue", .null, .integer(-1))]))
      ),
      (
        "qualityIssueCountString",
        with(
          base, ["dataQuality"],
          quality("warnings", [issue("invalidValue", .null, .string("3"))]))
      ),
      (
        "qualityIssueCountFraction",
        with(
          base, ["dataQuality"],
          quality("warnings", [issue("invalidValue", .null, .number(3.5))]))
      ),
      (
        "qualityIssueScopeNumber",
        with(
          base, ["dataQuality"],
          quality("warnings", [issue("invalidValue", .integer(1), .null)]))
      ),
      (
        "qualityIssueMissingCount",
        with(
          base, ["dataQuality"],
          quality(
            "warnings",
            [.object(["category": .string("invalidValue"), "scope": .null])]))
      ),
      (
        "qualityIssueExtraMember",
        with(
          base, ["dataQuality"],
          quality(
            "warnings",
            [
              .object([
                "category": .string("invalidValue"), "scope": .null, "count": .null,
                "extra": .null,
              ])
            ]))
      ),
    ]
    let ordered = [
      issue("droppedValue", .null, .integer(2)),
      issue("invalidValue", .null, .null),
      issue("invalidValue", .null, .integer(0)),
      issue("invalidValue", .string("process.end_ts"), .integer(1)),
      issue("invalidValue", .string("process.start_ts"), .integer(1)),
    ]
    cases += [
      ("qualityIssuesOrdered", with(base, ["dataQuality"], quality("warnings", ordered))),
      (
        "qualityIssuesUnordered",
        with(base, ["dataQuality"], quality("warnings", ordered.reversed()))
      ),
      (
        "qualityIssuesDuplicate",
        with(base, ["dataQuality"], quality("warnings", [ordered[0], ordered[0]]))
      ),
      (
        "qualityIssuesScopesReversed",
        with(base, ["dataQuality"], quality("warnings", [ordered[4], ordered[3]]))
      ),
      (
        "qualityIssuesCountsReversed",
        with(base, ["dataQuality"], quality("warnings", [ordered[2], ordered[1]]))
      ),
    ]
    // The engine version is the probe for Swift's safe text: bounded in UTF-8
    // bytes, no solidus or backslash, and no scalar of Foundation's
    // `controlCharacters` (Cc and Cf).
    let versions: [(String, String)] = [
      ("Empty", ""), ("Slash", "4.3/7"), ("Backslash", "4.3\\7"),
      ("Bytes128", String(repeating: "v", count: 128)),
      ("Bytes129", String(repeating: "v", count: 129)),
      ("Multibyte126", String(repeating: "版本", count: 21)),
      ("Multibyte130", String(repeating: "é", count: 65)),
      ("Nul", "4.3\u{0}"), ("Bell", "\u{7}"), ("Tab", "4\t3"), ("Del", "\u{7F}"),
      ("NextLine", "\u{85}"), ("SoftHyphen", "\u{AD}"), ("ArabicNumberSign", "\u{600}"),
      ("ZeroWidthSpace", "\u{200B}"), ("LeftToRightMark", "\u{200E}"),
      ("LineSeparator", "\u{2028}"), ("WordJoiner", "\u{2060}"),
      ("ByteOrderMark", "\u{FEFF}"), ("InterlinearAnchor", "\u{FFF9}"),
      ("LanguageTag", "\u{E0001}"), ("TagLatinA", "\u{E0041}"),
      ("PrivateUse", "\u{E000}"), ("Space", " "), ("NoBreakSpace", "\u{A0}"),
      ("CombiningAcute", "e\u{301}"), ("Emoji", "🙂"),
    ]
    cases += versions.map { name, version in
      ("engineVersion\(name)", with(base, ["engine", "version"], .string(version)))
    }
    return cases
  }

  func testSwiftTraceInspectDecisionsTheRustCLIReplays() throws {
    let base = try Self.recorded()
    let projections: [JSONValue] = Self.projections(base).map { name, value in
      var fields: [String: JSONValue] = ["name": .string(name), "value": value]
      do {
        let projection = try RuntimeTraceInspectionProjection(value)
        fields["accepted"] = .bool(true)
        fields["owner"] = projection.owner.value
        fields["artifactId"] = .string(projection.artifactID)
      } catch {
        fields["accepted"] = .bool(false)
        fields["reason"] = .string(String(describing: error))
      }
      return .object(fields)
    }

    let proof: [String: JSONValue] = [
      "phase": .string("traceInspectionOwner"), "newDispatchCount": .integer(0),
      "deviceEvidenceCreated": .bool(false),
    ]
    let evidence: [(String, [String: JSONValue])] = [
      ("proof", proof),
      ("otherPhase", ["phase": .string("artifactOwner"), "newDispatchCount": .integer(0)]),
      (
        "dispatched",
        ["phase": .string("traceInspectionOwner"), "newDispatchCount": .integer(1)]
      ),
      ("preAdmission", ["phase": .string("preAdmission"), "newDispatchCount": .integer(0)]),
      ("none", [:]),
    ]
    let wireCodes = [
      "invalidInput", "operationUnavailable", "resourceNotFound", "artifactIntegrityFailed",
      "recordUnreadable", "operationFailed", "resourceConflict", "internalError", "notFound",
      "invalidParams", "sensitiveAccessDenied", "unknownMethod", "malformedFrame", "rejected",
      "inputTooLarge", "timedOut",
    ]
    var failures: [JSONValue] = []
    for wireCode in wireCodes {
      for (name, details) in evidence {
        let error = CLIRuntimeSession.mapped(
          .structuredDaemonError(
            code: wireCode, message: "the Runtime refused \(wireCode)", details: details),
          method: "trace.inspect", command: "trace.inspect")
        failures.append(
          .object([
            "wireCode": .string(wireCode), "evidence": .string(name),
            "details": .object(details), "code": .string(error.code.rawValue),
            "message": .string(error.message), "mappedDetails": .object(error.details),
          ]))
      }
    }

    let job = "job-trace-inspect"
    let artifact = "ART-9c914630ca801dc5e25b24667d40e4fe"
    let argv: [(String, [String])] = [
      ("valid", ["--job", job, "--artifact", artifact, "--allow-sensitive"]),
      ("withoutAllowSensitive", ["--job", job, "--artifact", artifact]),
      ("jobColon", ["--job", "bad:id", "--artifact", artifact, "--allow-sensitive"]),
      ("jobEmpty", ["--job", "", "--artifact", artifact, "--allow-sensitive"]),
      ("jobLeadingDot", ["--job", ".job", "--artifact", artifact, "--allow-sensitive"]),
      (
        "job129",
        [
          "--job", String(repeating: "j", count: 129), "--artifact", artifact,
          "--allow-sensitive",
        ]
      ),
      ("artifactColon", ["--job", job, "--artifact", "ART:1", "--allow-sensitive"]),
      ("jobImportIdentity", ["--job", "imp-123", "--artifact", artifact, "--allow-sensitive"]),
    ]
    let timeouts = [
      "1ms", "10m", "600000ms", "600001ms", "11m", "0ms", "2h", "soon", "1s", "05s",
    ]
    var argvCases = argv
    for timeout in timeouts {
      argvCases.append(
        (
          "timeout-\(timeout)",
          ["--job", job, "--artifact", artifact, "--allow-sensitive", "--timeout", timeout]
        ))
    }
    argvCases += [
      (
        "jobColonAndTimeout11m",
        [
          "--job", "bad:id", "--artifact", artifact, "--allow-sensitive", "--timeout", "11m",
        ]
      ),
      (
        "jobImportIdentityAndTimeout11m",
        [
          "--job", "imp-123", "--artifact", artifact, "--allow-sensitive", "--timeout", "11m",
        ]
      ),
    ]
    let decisions: [JSONValue] = argvCases.map { name, options in
      var fields: [String: JSONValue] = [
        "name": .string(name), "argv": .array(options.map(JSONValue.string)),
      ]
      do {
        try RuntimeCLI.runTrace(
          ["inspect"] + options + ["--output", "json", "--socket", Self.absentSocket])
        fields["outcome"] = .string("emitted")
      } catch let error as CLIRegistryError {
        if error.details["method"] == .string("trace.inspect") {
          // The request left for the Runtime; no Runtime was there.
          fields["outcome"] = .string("requested")
        } else {
          fields["outcome"] = .string("refused")
          fields["code"] = .string(error.code.rawValue)
          fields["message"] = .string(error.message)
          fields["details"] = .object(error.details)
        }
      } catch {
        fields["outcome"] = .string("thrown")
        fields["error"] = .string(String(describing: error))
      }
      return .object(fields)
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [:]
    files["projections.json"] = try encoder.encode(JSONValue.array(projections)) + Data("\n".utf8)
    files["scopes.json"] =
      try encoder.encode(
        JSONValue.array(
          ArkTraceSummaryEnvelopeValidator.machineQualityScopes.sorted().map(JSONValue.string)))
      + Data("\n".utf8)
    files["failures.json"] = try encoder.encode(JSONValue.array(failures)) + Data("\n".utf8)
    files["argv.json"] = try encoder.encode(JSONValue.array(decisions)) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("CLITraceInspectOracleContractTests"),
          "owners": .array([
            .string("RuntimeTraceInspectionProjection"),
            .string("ArkTraceSummaryEnvelopeValidator.machineQualityScopes"),
            .string("CLIRuntimeSession.mapped"),
            .string("RuntimeCLI.runTrace"),
          ]),
          "base": .string("ControlFrames/trace.inspect.jsonl"),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}
