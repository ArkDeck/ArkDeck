import ArkDeckCore
import Foundation

/// Closed validator for the only ArkTrace wire result accepted by the
/// existing `analyzer.summarize-trace@1` operation. It intentionally does not
/// expose decoded fields to callers: success authorizes publication of the
/// exact input bytes, never a re-encoded approximation.
package enum ArkTraceSummaryEnvelopeValidator {
  package static func validate(
    _ data: Data,
    invocation: AnalyzerInvocation
  ) -> Bool {
    do {
      try validateThrowing(data, invocation: invocation)
      return true
    } catch {
      return false
    }
  }

  private enum ValidationError: Error { case invalid }

  private static func validateThrowing(
    _ data: Data,
    invocation: AnalyzerInvocation
  ) throws {
    guard let contract = invocation.arkTraceSummaryContract,
      invocation.analyzerRef == "trace-summary@1",
      invocation.sourceByteCount > 0,
      isSHA256(invocation.sourceSHA256),
      isSHA256(invocation.executableSHA256),
      let outputBudget = invocation.outputByteBudget,
      data.count <= outputBudget,
      let sourcePath = invocation.arguments.last,
      !sourcePath.isEmpty,
      data.range(of: Data(sourcePath.utf8)) == nil,
      invocation.arguments == [
        "summary", "--json", "--no-cache", "--timeout-ms",
        String(invocation.timeoutSeconds * 1_000), "--max-rows", "1000",
        "--max-events", "10000", "--max-output-bytes", String(outputBudget), sourcePath,
      ]
    else { throw ValidationError.invalid }

    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    try duplicateValidator.validate()
    var integerValidator = StrictJSONIntegerTokenValidator(data: data)
    try integerValidator.validate()
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      !containsPrivatePathInMachineValue(root, sourcePath: sourcePath),
      exactKeys(root, [
        "schemaVersion", "tool", "request", "trace", "provenance", "limits",
        "dataQuality", "truncation", "result",
      ]),
      string(root["schemaVersion"]) == "1.0",
      try validateTool(root["tool"], invocation: invocation, contract: contract),
      try validateRequest(root["request"]),
      try validateLimits(root["limits"], invocation: invocation),
      try validateTrace(root["trace"], invocation: invocation, contract: contract),
      try validateProvenance(root["provenance"], contract: contract),
      try validateDataQuality(root["dataQuality"]),
      try validateTruncation(root["truncation"]),
      try validateResult(
        root["result"], trace: root["trace"], truncation: root["truncation"])
    else { throw ValidationError.invalid }
  }

  private static func validateTool(
    _ value: Any?,
    invocation: AnalyzerInvocation,
    contract: ArkTraceSummaryInvocationContract
  ) throws -> Bool {
    guard let object = value as? [String: Any],
      exactKeys(object, ["name", "version", "buildRevision"])
    else { throw ValidationError.invalid }
    return string(object["name"]) == "arktrace"
      && string(object["version"]) == contract.toolVersion
      && string(object["buildRevision"]) == invocation.executableSHA256
  }

  private static func validateRequest(_ value: Any?) throws -> Bool {
    guard let object = value as? [String: Any],
      exactKeys(object, ["command", "parameters"]),
      string(object["command"]) == "summary",
      let parameters = object["parameters"] as? [String: Any],
      exactKeys(parameters, ["startNs", "endNs"])
    else { throw ValidationError.invalid }
    return parameters["startNs"] is NSNull && parameters["endNs"] is NSNull
  }

  private static func validateLimits(
    _ value: Any?, invocation: AnalyzerInvocation
  ) throws -> Bool {
    guard let object = value as? [String: Any],
      exactKeys(object, ["timeoutMs", "maxRows", "maxEvents", "maxOutputBytes"]),
      let outputBudget = invocation.outputByteBudget
    else { throw ValidationError.invalid }
    return integer(object["timeoutMs"]) == Int64(invocation.timeoutSeconds * 1_000)
      && integer(object["maxRows"]) == 1_000
      && integer(object["maxEvents"]) == 10_000
      && integer(object["maxOutputBytes"]) == Int64(outputBudget)
  }

  private static func validateTrace(
    _ value: Any?,
    invocation: AnalyzerInvocation,
    contract: ArkTraceSummaryInvocationContract
  ) throws -> Bool {
    guard let object = value as? [String: Any],
      exactKeys(object, ["sha256", "byteCount", "durationNs", "parser", "schemaFingerprint"]),
      string(object["sha256"]) == invocation.sourceSHA256,
      integer(object["byteCount"]) == Int64(invocation.sourceByteCount),
      let duration = integer(object["durationNs"]), duration >= 0,
      let schema = string(object["schemaFingerprint"]), isSHA256(schema),
      let parser = object["parser"] as? [String: Any],
      exactKeys(parser, ["name", "version", "upstreamRevision", "binarySha256"])
    else { throw ValidationError.invalid }
    return string(parser["name"]) == "trace_streamer"
      && string(parser["version"]) == contract.parserVersion
      && string(parser["upstreamRevision"]) == contract.parserUpstreamRevision
      && string(parser["binarySha256"]) == contract.parserSHA256
  }

  private static func validateProvenance(
    _ value: Any?, contract: ArkTraceSummaryInvocationContract
  ) throws -> Bool {
    guard let object = value as? [String: Any],
      exactKeys(object, [
        "parserAdapterVersion", "parserBuildRecipeVersion", "schemaAdapterVersion",
        "indexSchemaVersion", "upstreamDatabaseSha256", "upstreamDatabaseByteCount",
      ]),
      let databaseSHA = string(object["upstreamDatabaseSha256"]), isSHA256(databaseSHA),
      let databaseBytes = integer(object["upstreamDatabaseByteCount"]), databaseBytes >= 0
    else { throw ValidationError.invalid }
    return string(object["parserAdapterVersion"]) == contract.parserAdapterVersion
      && string(object["parserBuildRecipeVersion"]) == contract.parserBuildRecipeVersion
      && string(object["schemaAdapterVersion"]) == contract.schemaAdapterVersion
      && integer(object["indexSchemaVersion"]) == Int64(contract.indexSchemaVersion)
  }

  private static func validateDataQuality(_ value: Any?) throws -> Bool {
    guard let object = value as? [String: Any],
      exactKeys(object, ["status", "warnings"]),
      let status = string(object["status"]),
      let warnings = object["warnings"] as? [Any], warnings.count <= 4_096
    else { throw ValidationError.invalid }
    var previous: (String, String, Int64)?
    var identities = Set<String>()
    let categories = Set([
      "probeTruncated", "invalidValue", "clampedValue", "droppedValue",
      "referentialIntegrity", "unavailableValue",
    ])
    for raw in warnings {
      guard let warning = raw as? [String: Any],
        exactKeys(warning, ["category", "scope", "count", "message"]),
        let category = string(warning["category"]), categories.contains(category),
        warning["message"] is NSNull
      else { throw ValidationError.invalid }
      let scope: String
      if warning["scope"] is NSNull {
        scope = ""
      } else {
        guard let value = string(warning["scope"]), machineQualityScopes.contains(value) else {
          throw ValidationError.invalid
        }
        scope = value
      }
      let count: Int64
      if warning["count"] is NSNull {
        count = Int64.min
      } else {
        guard let value = integer(warning["count"]), value >= 0 else {
          throw ValidationError.invalid
        }
        count = value
      }
      let key = (category, scope, count)
      if let previous, previous > key { throw ValidationError.invalid }
      let identity = "\(category)\u{0}\(scope)\u{0}\(count)"
      guard identities.insert(identity).inserted else { throw ValidationError.invalid }
      previous = key
    }
    return status == (warnings.isEmpty ? "ok" : "warnings")
  }

  private static func validateTruncation(_ value: Any?) throws -> Bool {
    guard let object = value as? [String: Any],
      exactKeys(object, ["truncated", "sections"]),
      let truncated = boolean(object["truncated"]),
      let rawSections = object["sections"] as? [Any], rawSections.count <= 256
    else { throw ValidationError.invalid }
    let sections = try rawSections.map { raw -> String in
      guard let section = string(raw), safe(section, maximumBytes: 128) else {
        throw ValidationError.invalid
      }
      return section
    }
    let allowed = Set([
      "cpuCount", "processCount", "threadCount", "cpuSliceCount",
      "threadStateCount", "namedSliceCount", "counterSeriesCount", "eventCountBySource",
    ])
    return Set(sections).count == sections.count
      && sections == sections.sorted()
      && sections.allSatisfy(allowed.contains)
      && truncated == !sections.isEmpty
  }

  private static func validateResult(
    _ value: Any?, trace: Any?, truncation: Any?
  ) throws -> Bool {
    let keys = [
      "range", "durationNs", "cpuCount", "processCount", "threadCount",
      "cpuSliceCount", "threadStateCount", "namedSliceCount", "counterSeriesCount",
      "eventCountBySource", "capabilities",
    ]
    guard let object = value as? [String: Any], exactKeys(object, keys) else {
      throw ValidationError.invalid
    }
    let capabilities = try validateCapabilities(object["capabilities"])
    guard
      let traceObject = trace as? [String: Any],
      let traceDuration = integer(traceObject["durationNs"]),
      let duration = integer(object["durationNs"]), duration == traceDuration,
      let processCount = integer(object["processCount"]), processCount >= 0,
      let threadCount = integer(object["threadCount"]), threadCount >= 0,
      processCount <= 1_000, threadCount <= 1_000,
      let range = object["range"] as? [String: Any],
      exactKeys(range, ["startNs", "endNs"]),
      integer(range["startNs"]) == 0,
      integer(range["endNs"]) == duration,
      optionalBoundedCount(object["cpuCount"]),
      optionalBoundedCount(object["cpuSliceCount"]),
      optionalBoundedCount(object["threadStateCount"]),
      optionalBoundedCount(object["namedSliceCount"]),
      optionalBoundedCount(object["counterSeriesCount"]),
      try validateEventSources(object["eventCountBySource"]),
      (object["cpuCount"] is NSNull) == !capabilities.cpuScheduling,
      (object["cpuSliceCount"] is NSNull) == !capabilities.cpuScheduling,
      (object["threadStateCount"] is NSNull) == !capabilities.threadStates,
      (object["namedSliceCount"] is NSNull) == !capabilities.namedSlices,
      (object["counterSeriesCount"] is NSNull)
        == !(capabilities.cpuCounters || capabilities.processCounters),
      let truncationObject = truncation as? [String: Any],
      let sectionRows = truncationObject["sections"] as? [String]
    else { throw ValidationError.invalid }
    let sections = Set(sectionRows)
    guard (!sections.contains("cpuCount") && !sections.contains("cpuSliceCount"))
      || capabilities.cpuScheduling,
      !sections.contains("threadStateCount") || capabilities.threadStates,
      !sections.contains("namedSliceCount") || capabilities.namedSlices,
      !sections.contains("counterSeriesCount")
        || capabilities.cpuCounters || capabilities.processCounters,
      !sections.contains("eventCountBySource") || !(object["eventCountBySource"] is NSNull)
    else { throw ValidationError.invalid }
    return true
  }

  private static func validateEventSources(_ value: Any?) throws -> Bool {
    if value is NSNull { return true }
    guard let rows = value as? [Any], rows.count <= 10_000 else {
      throw ValidationError.invalid
    }
    var previous: Data?
    var identities = Set<Data>()
    for raw in rows {
      guard let row = raw as? [String: Any], exactKeys(row, ["source", "count"]),
        let source = string(row["source"]), safe(source, maximumBytes: 1_024),
        let count = integer(row["count"]), count >= 0
      else { throw ValidationError.invalid }
      let identity = Data(source.utf8)
      if let previous, identity.lexicographicallyPrecedes(previous) {
        throw ValidationError.invalid
      }
      guard identities.insert(identity).inserted else { throw ValidationError.invalid }
      previous = identity
    }
    return true
  }

  private struct Capabilities {
    let cpuScheduling: Bool
    let threadStates: Bool
    let namedSlices: Bool
    let cpuCounters: Bool
    let processCounters: Bool
  }

  private static func validateCapabilities(_ value: Any?) throws -> Capabilities {
    guard let object = value as? [String: Any],
      exactKeys(object, [
        "cpuScheduling", "threadStates", "namedSlices", "cpuCounters", "processCounters",
      ]),
      let cpuScheduling = boolean(object["cpuScheduling"]),
      let threadStates = boolean(object["threadStates"]),
      let namedSlices = boolean(object["namedSlices"]),
      let cpuCounters = boolean(object["cpuCounters"]),
      let processCounters = boolean(object["processCounters"])
    else { throw ValidationError.invalid }
    return Capabilities(
      cpuScheduling: cpuScheduling, threadStates: threadStates,
      namedSlices: namedSlices, cpuCounters: cpuCounters,
      processCounters: processCounters)
  }

  private static func exactKeys(_ object: [String: Any], _ expected: [String]) -> Bool {
    Set(object.keys) == Set(expected) && object.count == expected.count
  }

  private static func string(_ value: Any?) -> String? { value as? String }

  private static func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber,
      String(cString: number.objCType) == "c"
    else { return nil }
    return number.boolValue
  }

  private static func integer(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber,
      String(cString: number.objCType) != "c"
    else { return nil }
    let result = number.int64Value
    return number.doubleValue == Double(result) ? result : nil
  }

  private static func optionalBoundedCount(_ value: Any?) -> Bool {
    value is NSNull || integer(value).map { (0...10_000).contains($0) } == true
  }

  package static func containsPrivatePathInMachineValue(
    _ value: Any,
    sourcePath: String
  ) -> Bool {
    if let string = value as? String {
      return containsPrivatePath(string, sourcePath: sourcePath)
    }
    if let array = value as? [Any] {
      return array.contains {
        containsPrivatePathInMachineValue($0, sourcePath: sourcePath)
      }
    }
    if let object = value as? [String: Any] {
      return object.values.contains {
        containsPrivatePathInMachineValue($0, sourcePath: sourcePath)
      }
    }
    return false
  }

  /// Trace-controlled labels may contain arbitrary prose. Reject every
  /// lexical absolute-path token instead of enumerating familiar macOS roots:
  /// an owner-selected install may live under `/srv`, `/mnt`, `/Network`, or
  /// any other absolute namespace. A semantic identifier such as
  /// `sched/sched_switch` remains valid because its slash is not at a token
  /// boundary. JSON escapes are already decoded; percent escapes get one
  /// bounded decode pass so `FILE:%2F%2F...` cannot smuggle a URI.
  private static func containsPrivatePath(_ string: String, sourcePath: String) -> Bool {
    var candidates = [string]
    let decoded = decodeValidPercentEscapes(string)
    if decoded != string {
      candidates.append(decoded)
    }
    return candidates.contains { candidate in
      candidate.contains(sourcePath)
        || containsFileURIToken(candidate)
        || containsAbsolutePathToken(candidate)
    }
  }

  private static func containsFileURIToken(_ string: String) -> Bool {
    let bytes = Array(string.lowercased().utf8)
    let scheme = Array("file:".utf8)
    guard bytes.count > scheme.count else { return false }
    for index in 0...(bytes.count - scheme.count - 1)
    where Array(bytes[index..<(index + scheme.count)]) == scheme
      && bytes[index + scheme.count] == UInt8(ascii: "/") {
      if index == 0 { return true }
      let previous = bytes[index - 1]
      if !isASCIIIdentifierByte(previous) {
        return true
      }
    }
    return false
  }

  private static func containsAbsolutePathToken(_ string: String) -> Bool {
    let scalars = Array(string.unicodeScalars)
    var index = scalars.startIndex
    while index < scalars.endIndex {
      guard scalars[index].value == UInt32(UInt8(ascii: "/")) else {
        index = scalars.index(after: index)
        continue
      }
      // Trace-controlled labels legitimately carry non-file resource URIs
      // such as `resource:///icon.svg`. Their authority separator is not a
      // host filesystem path. `file:/...` remains rejected independently by
      // containsFileURIToken, while a single slash after an arbitrary label
      // (for example `HOME:/Users/...`) still reaches the path check below.
      if let separatorEnd = uriSeparatorEnd(scalars, startingAt: index) {
        index = scalars.index(after: separatorEnd)
        continue
      }
      if index == scalars.startIndex { return true }
      let previous = scalars[scalars.index(before: index)]
      if !isSemanticIdentifierScalar(previous) { return true }
      index = scalars.index(after: index)
    }
    return false
  }

  private static func uriSeparatorEnd(
    _ scalars: [Unicode.Scalar], startingAt start: Int
  ) -> Int? {
    guard start > scalars.startIndex else { return nil }
    let colon = scalars.index(before: start)
    guard scalars[colon].value == UInt32(UInt8(ascii: ":")), colon > scalars.startIndex
    else { return nil }

    var end = start
    while scalars.index(after: end) < scalars.endIndex,
      scalars[scalars.index(after: end)].value == UInt32(UInt8(ascii: "/"))
    {
      end = scalars.index(after: end)
    }
    guard scalars.distance(from: start, to: scalars.index(after: end)) >= 2,
      colon > scalars.startIndex
    else { return nil }

    var schemeStart = colon
    while schemeStart > scalars.startIndex {
      let candidate = scalars.index(before: schemeStart)
      guard isURISchemeContinuationScalar(scalars[candidate]) else { break }
      schemeStart = candidate
    }
    guard schemeStart < colon, isASCIIAlphaScalar(scalars[schemeStart]),
      scalars[schemeStart..<colon].allSatisfy(isURISchemeContinuationScalar)
    else { return nil }
    return end
  }

  private static func isASCIIAlphaScalar(_ scalar: Unicode.Scalar) -> Bool {
    (scalar.value >= UInt32(UInt8(ascii: "A"))
      && scalar.value <= UInt32(UInt8(ascii: "Z")))
      || (scalar.value >= UInt32(UInt8(ascii: "a"))
        && scalar.value <= UInt32(UInt8(ascii: "z")))
  }

  private static func isURISchemeContinuationScalar(_ scalar: Unicode.Scalar) -> Bool {
    isASCIIAlphaScalar(scalar)
      || (scalar.value >= UInt32(UInt8(ascii: "0"))
        && scalar.value <= UInt32(UInt8(ascii: "9")))
      || scalar.value == UInt32(UInt8(ascii: "+"))
      || scalar.value == UInt32(UInt8(ascii: "-"))
      || scalar.value == UInt32(UInt8(ascii: "."))
  }

  private static func isSemanticIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet.alphanumerics.contains(scalar)
      || scalar.value == UInt32(UInt8(ascii: "_"))
      || scalar.value == UInt32(UInt8(ascii: "-"))
      || scalar.value == UInt32(UInt8(ascii: "."))
  }

  private static func isASCIIIdentifierByte(_ byte: UInt8) -> Bool {
    (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
      || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
      || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
      || byte == UInt8(ascii: ".")
  }

  /// Decode each valid `%HH` independently. Foundation's all-or-nothing URL
  /// decoder returns nil for `HOME=%2Fsrv%`, which would otherwise discard the
  /// already-valid `%2F` that reveals an absolute path.
  private static func decodeValidPercentEscapes(_ string: String) -> String {
    let source = Array(string.utf8)
    var decoded: [UInt8] = []
    decoded.reserveCapacity(source.count)
    var index = 0
    while index < source.count {
      if source[index] == UInt8(ascii: "%"), index + 2 < source.count,
        let high = hexValue(source[index + 1]), let low = hexValue(source[index + 2])
      {
        decoded.append(high << 4 | low)
        index += 3
      } else {
        decoded.append(source[index])
        index += 1
      }
    }
    return String(decoding: decoded, as: UTF8.self)
  }

  private static func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
    default: return nil
    }
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
      ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
        || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
    }
  }

  private static func safe(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes
      && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }

  package static let machineQualityScopes: Set<String> = [
    "process.start_ts", "process.end_ts", "process.lifecycle", "process.name",
    "thread.start_ts", "thread.end_ts", "thread.ipid", "thread.lifecycle",
    "thread.name", "thread.processName",
    "sched_slice.ts", "sched_slice.dur", "sched_slice.cpu", "sched_slice.value",
    "sched_slice.identity", "sched_slice.overlap",
    "thread_state.ts", "thread_state.dur", "thread_state.cpu", "thread_state.value",
    "thread_state.identity", "thread_state.state",
    "callstack.ts", "callstack.dur", "callstack.depth", "callstack.parent_id",
    "callstack.cookie", "callstack.value", "callstack.identity",
    "measure.ts", "measure.filter_id", "measure.value", "measure.dur", "measure.optional",
    "cpu_measure_filter.id", "cpu_measure_filter.name", "cpu_measure_filter.cpu",
    "cpu_measure_filter.unit", "process_measure_filter.id", "process_measure_filter.name",
    "process_measure_filter.ipid", "process_measure_filter.unit",
    "stat", "stat.count", "stat.source", "stat.event_name", "stat.stat_type",
    "timeline.density.occupancy", "timeline.density.dominantThread", "timeline.counter",
    "timeline.counter.duration",
  ]
}

/// ArkTrace summary 1.0 has no floating-point fields. Foundation's JSON
/// bridge rounds some decimal spellings through `Double` before producing an
/// `NSNumber`, so validating only the bridged value can accept a fractional
/// token as an integer. This pass preserves the wire token and requires every
/// JSON number to be one signed Int64 decimal integer.
package struct StrictJSONIntegerTokenValidator {
  private enum TokenError: Error { case invalid }
  private let bytes: [UInt8]
  private var index = 0

  package init(data: Data) { bytes = Array(data) }

  package mutating func validate() throws {
    while index < bytes.count {
      switch bytes[index] {
      case UInt8(ascii: "\""):
        try skipString()
      case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
        try consumeInteger()
      default:
        index += 1
      }
    }
  }

  private mutating func skipString() throws {
    index += 1
    while index < bytes.count {
      switch bytes[index] {
      case UInt8(ascii: "\""):
        index += 1
        return
      case UInt8(ascii: "\\"):
        index += 2
      default:
        index += 1
      }
    }
    throw TokenError.invalid
  }

  private mutating func consumeInteger() throws {
    let start = index
    while index < bytes.count, !isDelimiter(bytes[index]) { index += 1 }
    guard index > start,
      let token = String(bytes: bytes[start..<index], encoding: .utf8),
      Int64(token) != nil
    else { throw TokenError.invalid }
  }

  private func isDelimiter(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: ",") || byte == UInt8(ascii: "]")
      || byte == UInt8(ascii: "}") || byte == UInt8(ascii: " ")
      || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
      || byte == UInt8(ascii: "\n")
  }
}
