// Shared Swift oracle for the Rust ArkTrace summary envelope validator
// (CHG-2026-074, TASK-XPA-015).

import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// Swift `ArkTraceSummaryEnvelopeValidator.validate(_:invocation:)` over the
/// reviewed summary envelope and every way of breaking it, recorded as the
/// oracle `rust/tests/fixtures/arktrace-summary-validator` the Rust validator
/// replays: each member of each section changed, removed or joined by another;
/// each count, null and truncation section against the capabilities; the
/// warnings' categories, scopes, counts, order and duplicates; event sources'
/// order, duplicates and safety; numbers that are fractional or Boolean;
/// duplicate members, other shapes and output that is not JSON; machine
/// strings that name the source, a `file:` URI, an absolute path (or a
/// percent-encoded one), next to those that only look like one (a `scheme://`
/// resource, a `sched/sched_switch` identifier); and invocations whose
/// arguments, budget, analyzer or digests are not the reviewed ones.
///
/// Record a new oracle with
/// `ARKDECK_RUST_ARKTRACE_SUMMARY_VALIDATOR_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class ArkTraceSummaryValidatorOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/arktrace-summary-validator", directoryHint: .isDirectory)

  static let sourcePath = "/private/tmp/arkdeck-trace-source/job-trace/trace.htrace"
  static let contract = ArkTraceSummaryInvocationContract(
    toolVersion: "0.1.0", parserVersion: "4.3.7",
    parserUpstreamRevision: String(repeating: "6", count: 40),
    parserSHA256: String(repeating: "5", count: 64),
    parserBuildRecipeVersion: String(repeating: "7", count: 64),
    parserAdapterVersion: "1", schemaAdapterVersion: "2", indexSchemaVersion: 3)

  static func invocation(
    arguments: [String]? = nil, budget: Int? = 8_388_608, analyzerRef: String = "trace-summary@1",
    sourceSHA256: String = String(repeating: "a", count: 64),
    executableSHA256: String = String(repeating: "b", count: 64),
    contract: ArkTraceSummaryInvocationContract? = contract
  ) -> AnalyzerInvocation {
    AnalyzerInvocation(
      analyzerRef: analyzerRef, analyzerVersion: "0.1.0+1",
      executableSHA256: executableSHA256,
      arguments: arguments ?? [
        "summary", "--json", "--no-cache", "--timeout-ms", "30000", "--max-rows", "1000",
        "--max-events", "10000", "--max-output-bytes", String(budget ?? 0), sourcePath,
      ],
      timeoutSeconds: 30, outputByteBudget: budget, sourceArtifactID: "ART-SOURCE",
      sourceSHA256: sourceSHA256, sourceByteCount: 4_096,
      arkTraceSummaryContract: contract)
  }

  static func envelope() -> [String: Any] {
    [
      "schemaVersion": "1.0",
      "tool": [
        "name": "arktrace", "version": "0.1.0", "buildRevision": String(repeating: "b", count: 64),
      ],
      "request": ["command": "summary", "parameters": ["startNs": NSNull(), "endNs": NSNull()]],
      "trace": [
        "sha256": String(repeating: "a", count: 64), "byteCount": 4_096, "durationNs": 100,
        "parser": [
          "name": "trace_streamer", "version": "4.3.7",
          "upstreamRevision": String(repeating: "6", count: 40),
          "binarySha256": String(repeating: "5", count: 64),
        ],
        "schemaFingerprint": String(repeating: "e", count: 64),
      ],
      "provenance": [
        "parserAdapterVersion": "1", "parserBuildRecipeVersion": String(repeating: "7", count: 64),
        "schemaAdapterVersion": "2", "indexSchemaVersion": 3,
        "upstreamDatabaseSha256": String(repeating: "f", count: 64),
        "upstreamDatabaseByteCount": 4_096,
      ],
      "limits": ["timeoutMs": 30_000, "maxRows": 1_000, "maxEvents": 10_000, "maxOutputBytes": 8_388_608],
      "dataQuality": ["status": "ok", "warnings": [Any]()],
      "truncation": ["truncated": false, "sections": [Any]()],
      "result": [
        "range": ["startNs": 0, "endNs": 100], "durationNs": 100,
        "cpuCount": 1, "processCount": 1, "threadCount": 1,
        "cpuSliceCount": 1, "threadStateCount": NSNull(), "namedSliceCount": 1,
        "counterSeriesCount": NSNull(),
        "eventCountBySource": [
          ["source": "sched/sched_switch", "count": 2], ["source": "token=secretvalue", "count": 1],
        ],
        "capabilities": [
          "cpuScheduling": true, "threadStates": false, "namedSlices": true,
          "cpuCounters": false, "processCounters": false,
        ],
      ],
    ]
  }

  static func json(_ object: Any) -> String {
    String(
      decoding: try! JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
      as: UTF8.self)
  }

  /// `path` names a member by keys, then sets it (or removes it for `nil`).
  static func edited(_ path: [String], _ value: Any?) -> String {
    func set(_ object: [String: Any], _ path: ArraySlice<String>) -> [String: Any] {
      var object = object
      let key = path.first!
      if path.count == 1 {
        object[key] = value
      } else {
        object[key] = set(object[key] as! [String: Any], path.dropFirst())
      }
      return object
    }
    return json(set(envelope(), path[...]))
  }

  static func warning(
    _ category: String, _ scope: Any = NSNull(), _ count: Any = NSNull(), message: Any = NSNull()
  ) -> [String: Any] {
    ["category": category, "scope": scope, "count": count, "message": message]
  }

  static func source(_ value: String, _ count: Int = 1) -> [String: Any] {
    ["source": value, "count": count]
  }

  struct Case {
    let name: String
    let envelope: String
    var invocation = "reviewed"
  }

  static var cases: [Case] {
    var list: [Case] = [Case(name: "reviewed", envelope: json(envelope()))]
    func add(_ name: String, _ text: String, invocation: String = "reviewed") {
      list.append(Case(name: name, envelope: text, invocation: invocation))
    }
    let base = json(envelope())
    // Invocations.
    add("budgetExceeded", base, invocation: "smallBudget")
    add("argumentsReordered", base, invocation: "argumentsReordered")
    add("noBudget", base, invocation: "noBudget")
    add("otherAnalyzer", base, invocation: "otherAnalyzer")
    add("noContract", base, invocation: "noContract")
    add("uppercaseSource", base, invocation: "uppercaseSource")
    add("emptySourcePath", base, invocation: "emptySourcePath")
    // Shape.
    add("notJSON", "summary: ok\n")
    add("array", "[]")
    add("duplicateMember", "{\"schemaVersion\":\"1.0\"," + base.dropFirst())
    add("trailingNewline", base + "\n")
    add("escapedSlashes", base.replacingOccurrences(of: "/", with: "\\/"))
    add("extraRoot", edited(["extra"], 1))
    add("schemaVersion", edited(["schemaVersion"], "1.1"))
    add("missingProvenance", edited(["provenance"], nil))
    // Tool, request, limits.
    add("toolName", edited(["tool", "name"], "ArkTrace"))
    add("toolVersion", edited(["tool", "version"], "0.2.0"))
    add("buildRevision", edited(["tool", "buildRevision"], String(repeating: "c", count: 64)))
    add("toolExtra", edited(["tool", "extra"], "x"))
    add("command", edited(["request", "command"], "inspect"))
    add("startNs", edited(["request", "parameters", "startNs"], 0))
    add("timeoutMs", edited(["limits", "timeoutMs"], 30_001))
    add("maxRows", edited(["limits", "maxRows"], 10_000))
    add("maxEvents", edited(["limits", "maxEvents"], 1_000))
    add("maxOutputBytes", edited(["limits", "maxOutputBytes"], 1_024))
    add("timeoutFraction", base.replacingOccurrences(of: "\"timeoutMs\":30000", with: "\"timeoutMs\":30000.0"))
    add("timeoutExponent", base.replacingOccurrences(of: "\"timeoutMs\":30000", with: "\"timeoutMs\":3e4"))
    add("timeoutBoolean", edited(["limits", "timeoutMs"], true))
    // Trace.
    add("traceSource", edited(["trace", "sha256"], String(repeating: "0", count: 64)))
    add("traceBytes", edited(["trace", "byteCount"], 4_097))
    add("traceNegativeDuration", edited(["trace", "durationNs"], -1))
    add("traceFingerprint", edited(["trace", "schemaFingerprint"], String(repeating: "E", count: 64)))
    add("parserName", edited(["trace", "parser", "name"], "perfetto"))
    add("parserVersion", edited(["trace", "parser", "version"], "4.3.8"))
    add("parserRevision", edited(["trace", "parser", "upstreamRevision"], String(repeating: "7", count: 40)))
    add("parserBinary", edited(["trace", "parser", "binarySha256"], String(repeating: "0", count: 64)))
    // Provenance.
    add("parserAdapter", edited(["provenance", "parserAdapterVersion"], "2"))
    add("buildRecipe", edited(["provenance", "parserBuildRecipeVersion"], "x"))
    add("schemaAdapter", edited(["provenance", "schemaAdapterVersion"], "3"))
    add("indexSchema", edited(["provenance", "indexSchemaVersion"], 2))
    add("databaseDigest", edited(["provenance", "upstreamDatabaseSha256"], "f"))
    add("databaseBytes", edited(["provenance", "upstreamDatabaseByteCount"], -1))
    // Data quality.
    let sorted = [
      warning("clampedValue", "thread.name", 2), warning("invalidValue", NSNull(), NSNull()),
      warning("invalidValue", "process.name", 1),
    ]
    add("warnings", edited(["dataQuality"], ["status": "warnings", "warnings": sorted]))
    add("warningsStatusOk", edited(["dataQuality"], ["status": "ok", "warnings": sorted]))
    add("warningsUnsorted", edited(["dataQuality"], ["status": "warnings", "warnings": Array(sorted.reversed())]))
    add(
      "warningsDuplicate",
      edited(["dataQuality"], ["status": "warnings", "warnings": [sorted[0], sorted[0]]]))
    add(
      "warningCategory",
      edited(["dataQuality"], ["status": "warnings", "warnings": [warning("unknownValue")]]))
    add(
      "warningScope",
      edited(["dataQuality"], ["status": "warnings", "warnings": [warning("invalidValue", "thread.tid")]]))
    add(
      "warningCount",
      edited(["dataQuality"], ["status": "warnings", "warnings": [warning("invalidValue", NSNull(), -1)]]))
    add(
      "warningMessage",
      edited(["dataQuality"], ["status": "warnings", "warnings": [warning("invalidValue", message: "m")]]))
    add("qualityStatusWarnings", edited(["dataQuality", "status"], "warnings"))
    // Truncation.
    add("truncatedSections", edited(["truncation"], ["truncated": true, "sections": ["cpuCount", "processCount"]]))
    add("truncatedEmpty", edited(["truncation"], ["truncated": true, "sections": [Any]()]))
    add("sectionsWithoutTruncation", edited(["truncation"], ["truncated": false, "sections": ["cpuCount"]]))
    add("sectionsUnsorted", edited(["truncation"], ["truncated": true, "sections": ["processCount", "cpuCount"]]))
    add("sectionUnknown", edited(["truncation"], ["truncated": true, "sections": ["sliceCount"]]))
    add("sectionThreadStates", edited(["truncation"], ["truncated": true, "sections": ["threadStateCount"]]))
    add("sectionEvents", edited(["truncation"], ["truncated": true, "sections": ["eventCountBySource"]]))
    // Result.
    add("rangeStart", edited(["result", "range", "startNs"], 1))
    add("rangeEnd", edited(["result", "range", "endNs"], 99))
    add("resultDuration", edited(["result", "durationNs"], 101))
    add("processCountBound", edited(["result", "processCount"], 1_001))
    add("threadCountAtBound", edited(["result", "threadCount"], 1_000))
    add("cpuCountBound", edited(["result", "cpuCount"], 10_001))
    add("cpuCountNull", edited(["result", "cpuCount"], NSNull()))
    add("threadStatesCounted", edited(["result", "threadStateCount"], 0))
    add("namedSlicesNull", edited(["result", "namedSliceCount"], NSNull()))
    add("countersCounted", edited(["result", "counterSeriesCount"], 3))
    add("capabilityExtra", edited(["result", "capabilities", "gpu"], false))
    add("capabilityNumber", edited(["result", "capabilities", "cpuScheduling"], 1))
    add("eventsNull", edited(["result", "eventCountBySource"], NSNull()))
    add("eventsUnsorted", edited(["result", "eventCountBySource"], [source("b"), source("a")]))
    add("eventsDuplicate", edited(["result", "eventCountBySource"], [source("a"), source("a")]))
    add("eventsNegative", edited(["result", "eventCountBySource"], [source("a", -1)]))
    add("eventsEmptySource", edited(["result", "eventCountBySource"], [source("")]))
    add("eventsControlSource", edited(["result", "eventCountBySource"], [source("a\u{0007}b")]))
    add("eventsFormatSource", edited(["result", "eventCountBySource"], [source("a\u{200B}b")]))
    add("eventsExtra", edited(["result", "eventCountBySource"], [["source": "a", "count": 1, "x": 1]]))
    add("eventsNonASCIIOrder", edited(["result", "eventCountBySource"], [source("Z"), source("a"), source("é")]))
    // Machine strings.
    add("sourcePath", edited(["result", "eventCountBySource"], [source(sourcePath)]))
    add("absolutePath", edited(["result", "eventCountBySource"], [source("/Users/reviewer/trace")]))
    add("labelPath", edited(["result", "eventCountBySource"], [source("HOME:/Users/reviewer")]))
    add("spacePath", edited(["result", "eventCountBySource"], [source("open /srv/trace")]))
    add("fileURI", edited(["result", "eventCountBySource"], [source("FILE:/srv")]))
    add("fileURIAfterIdentifier", edited(["result", "eventCountBySource"], [source("xfile:/srv")]))
    add("percentPath", edited(["result", "eventCountBySource"], [source("HOME=%2Fsrv%")]))
    add("percentFileURI", edited(["result", "eventCountBySource"], [source("FILE:%2F%2Fsrv")]))
    add("resourceURI", edited(["result", "eventCountBySource"], [source("resource:///icon.svg")]))
    add("resourceSingleSlash", edited(["result", "eventCountBySource"], [source("resource:/icon.svg")]))
    add("identifierSlash", edited(["result", "eventCountBySource"], [source("sched/sched_switch")]))
    add("unicodeIdentifierSlash", edited(["result", "eventCountBySource"], [source("é/b")]))
    add("dotSlash", edited(["result", "eventCountBySource"], [source("./b")]))
    add("pathInKey", edited(["result", "eventCountBySource"], [source("a")]).replacingOccurrences(of: "\"source\":\"a\"", with: "\"source\":\"a\",\"/Users/x\":1"))
    add("pathInToolVersion", edited(["tool", "version"], "/0.1.0"))
    return list
  }

  static func invocation(named name: String) -> AnalyzerInvocation {
    switch name {
    case "smallBudget":
      return invocation(budget: 1_024)
    case "argumentsReordered":
      return invocation(arguments: [
        "summary", "--no-cache", "--json", "--timeout-ms", "30000", "--max-rows", "1000",
        "--max-events", "10000", "--max-output-bytes", "8388608", sourcePath,
      ])
    case "noBudget": return invocation(budget: nil)
    case "otherAnalyzer": return invocation(analyzerRef: "trace-analysis@1")
    case "noContract": return invocation(contract: nil)
    case "uppercaseSource": return invocation(sourceSHA256: String(repeating: "A", count: 64))
    case "emptySourcePath":
      return invocation(arguments: [
        "summary", "--json", "--no-cache", "--timeout-ms", "30000", "--max-rows", "1000",
        "--max-events", "10000", "--max-output-bytes", "8388608", "",
      ])
    default: return invocation()
    }
  }

  static func projection(_ invocation: AnalyzerInvocation) -> JSONValue {
    .object([
      "analyzerRef": .string(invocation.analyzerRef),
      "executableSHA256": .string(invocation.executableSHA256),
      "arguments": .array(invocation.arguments.map(JSONValue.string)),
      "timeoutSeconds": .integer(Int64(invocation.timeoutSeconds)),
      "outputByteBudget": invocation.outputByteBudget.map { .integer(Int64($0)) } ?? .null,
      "sourceSHA256": .string(invocation.sourceSHA256),
      "sourceByteCount": .integer(Int64(invocation.sourceByteCount)),
      "contract": invocation.arkTraceSummaryContract == nil ? .null : .bool(true),
    ])
  }

  func testSwiftValidatesTheSharedSummaryEnvelopes() throws {
    var recorded: [JSONValue] = []
    for item in Self.cases {
      let invocation = Self.invocation(named: item.invocation)
      recorded.append(
        .object([
          "name": .string(item.name),
          "invocation": Self.projection(invocation),
          "envelope": .string(item.envelope),
          "valid": .bool(
            ArkTraceSummaryEnvelopeValidator.validate(Data(item.envelope.utf8), invocation: invocation)),
        ]))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    let files: [String: Data] = [
      "cases.json": try encoder.encode(
        JSONValue.object([
          "contract": .object([
            "toolVersion": .string(Self.contract.toolVersion),
            "parserVersion": .string(Self.contract.parserVersion),
            "parserUpstreamRevision": .string(Self.contract.parserUpstreamRevision),
            "parserSHA256": .string(Self.contract.parserSHA256),
            "parserBuildRecipeVersion": .string(Self.contract.parserBuildRecipeVersion),
            "parserAdapterVersion": .string(Self.contract.parserAdapterVersion),
            "schemaAdapterVersion": .string(Self.contract.schemaAdapterVersion),
            "indexSchemaVersion": .integer(Int64(Self.contract.indexSchemaVersion)),
          ]),
          "cases": .array(recorded),
        ])) + Data("\n".utf8)
    ]
    try HDCOracleHarness.recordOrCompare(
      files, variable: "ARKDECK_RUST_ARKTRACE_SUMMARY_VALIDATOR_RECORD", oracle: Self.oracle)
  }
}
