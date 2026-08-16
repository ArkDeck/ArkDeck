import ArkDeckCore
import Foundation

/// Closed verifier for `analyzer.analyze-trace@1`. Successful validation
/// authorizes publication of the exact stdout bytes; callers never publish a
/// re-encoded projection of a partially checked document.
package enum ArkTraceAnalysisEnvelopeValidator {
  private enum ValidationError: Error { case invalid }
  private typealias Object = [String: JSONValue]

  package static func validate(_ data: Data, invocation: AnalyzerInvocation) -> Bool {
    do {
      try validateThrowing(data, invocation: invocation)
      return true
    } catch {
      return false
    }
  }

  private static func validateThrowing(
    _ data: Data,
    invocation: AnalyzerInvocation
  ) throws {
    guard invocation.analyzerRef == "trace-analysis@1",
      let request = invocation.arkTraceAnalysisRequest,
      let contract = invocation.arkTraceAnalysisContract,
      invocation.sourceByteCount > 0,
      isSHA256(invocation.sourceSHA256), isSHA256(invocation.executableSHA256),
      invocation.timeoutSeconds == request.processTimeoutSeconds,
      invocation.outputByteBudget == request.maxOutputBytes,
      data.count <= request.maxOutputBytes,
      let sourcePath = invocation.arguments.last, !sourcePath.isEmpty,
      invocation.arguments == request.arguments(sourcePath: sourcePath),
      data.range(of: Data(sourcePath.utf8)) == nil
    else { throw ValidationError.invalid }

    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    try duplicateValidator.validate()
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    guard let root = object(decoded), exactKeys(root, [
      "schemaVersion", "tool", "request", "trace", "provenance", "limits",
      "dataQuality", "truncation", "result",
    ]), string(root["schemaVersion"]) == "1.0",
      let bridged = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      !ArkTraceSummaryEnvelopeValidator.containsPrivatePathInMachineValue(
        bridged, sourcePath: sourcePath),
      validateTool(root["tool"], invocation: invocation, contract: contract),
      validateLimits(root["limits"], request: request),
      let trace = validateTrace(root["trace"], invocation: invocation, contract: contract),
      validateProvenance(root["provenance"], contract: contract),
      validateRequest(root["request"], request: request),
      validateDataQuality(root["dataQuality"]),
      validateTruncationRoot(root["truncation"]),
      validateResult(
        root["result"], request: request, trace: trace,
        outerQuality: root["dataQuality"], outerTruncation: root["truncation"])
    else { throw ValidationError.invalid }
  }

  private struct TraceIdentity {
    let durationNs: Int64
    let schemaFingerprint: String
  }

  private static func validateTool(
    _ value: JSONValue?,
    invocation: AnalyzerInvocation,
    contract: ArkTraceSummaryInvocationContract
  ) -> Bool {
    guard let value, let object = object(value),
      exactKeys(object, ["name", "version", "buildRevision"])
    else { return false }
    return string(object["name"]) == "arktrace"
      && string(object["version"]) == contract.toolVersion
      && string(object["buildRevision"]) == invocation.executableSHA256
  }

  private static func validateLimits(
    _ value: JSONValue?, request: ArkTraceAnalysisRequest
  ) -> Bool {
    guard let value, let object = object(value), exactKeys(object, [
      "timeoutMs", "maxRows", "maxEvents", "maxOutputBytes",
    ]) else { return false }
    return integer(object["timeoutMs"]) == Int64(request.timeoutMs)
      && integer(object["maxRows"]) == Int64(request.maxRows)
      && integer(object["maxEvents"]) == Int64(request.maxEvents)
      && integer(object["maxOutputBytes"]) == Int64(request.maxOutputBytes)
  }

  private static func validateTrace(
    _ value: JSONValue?,
    invocation: AnalyzerInvocation,
    contract: ArkTraceSummaryInvocationContract
  ) -> TraceIdentity? {
    guard let value, let object = object(value), exactKeys(object, [
      "sha256", "byteCount", "durationNs", "parser", "schemaFingerprint",
    ]), string(object["sha256"]) == invocation.sourceSHA256,
      integer(object["byteCount"]) == Int64(invocation.sourceByteCount),
      let duration = integer(object["durationNs"]), duration >= 0,
      let schema = string(object["schemaFingerprint"]), isSHA256(schema),
      let parserValue = object["parser"], let parser = self.object(parserValue),
      exactKeys(parser, ["name", "version", "upstreamRevision", "binarySha256"]),
      string(parser["name"]) == "trace_streamer",
      string(parser["version"]) == contract.parserVersion,
      string(parser["upstreamRevision"]) == contract.parserUpstreamRevision,
      string(parser["binarySha256"]) == contract.parserSHA256
    else { return nil }
    return TraceIdentity(durationNs: duration, schemaFingerprint: schema)
  }

  private static func validateProvenance(
    _ value: JSONValue?, contract: ArkTraceSummaryInvocationContract
  ) -> Bool {
    guard let value, let object = object(value), exactKeys(object, [
      "parserAdapterVersion", "parserBuildRecipeVersion", "schemaAdapterVersion",
      "indexSchemaVersion", "upstreamDatabaseSha256", "upstreamDatabaseByteCount",
    ]), let databaseSHA = string(object["upstreamDatabaseSha256"]),
      isSHA256(databaseSHA),
      let databaseBytes = integer(object["upstreamDatabaseByteCount"]), databaseBytes >= 0
    else { return false }
    return string(object["parserAdapterVersion"]) == contract.parserAdapterVersion
      && string(object["parserBuildRecipeVersion"]) == contract.parserBuildRecipeVersion
      && string(object["schemaAdapterVersion"]) == contract.schemaAdapterVersion
      && integer(object["indexSchemaVersion"]) == Int64(contract.indexSchemaVersion)
  }

  private static let filterKeys = [
    "cpu", "processKey", "pid", "threadKey", "tid", "rawState",
    "normalizedState", "name", "nameMatch", "minimumDurationNs", "depth",
    "counterFilterID",
  ]

  private static func validateRequest(
    _ value: JSONValue?, request: ArkTraceAnalysisRequest
  ) -> Bool {
    guard let value, let object = object(value),
      exactKeys(object, ["command", "parameters"]),
      let parameterValue = object["parameters"], let parameters = self.object(parameterValue)
    else { return false }
    if request.kind == .context {
      guard string(object["command"]) == "context",
        exactKeys(parameters, filterKeys + [
          "startNs", "endNs", "timestampNs", "windowBeforeNs", "windowAfterNs",
        ]), validateRequestFilters(parameters, request: request)
      else { return false }
      if let timestamp = request.timestampNs {
        return integer(parameters["timestampNs"]) == timestamp
          && integer(parameters["windowBeforeNs"]) == ArkTraceAnalysisRequest.halfWindowNs
          && integer(parameters["windowAfterNs"]) == ArkTraceAnalysisRequest.halfWindowNs
          && isNull(parameters["startNs"]) && isNull(parameters["endNs"])
      }
      return integer(parameters["startNs"]) == request.startNs
        && integer(parameters["endNs"]) == request.endNs
        && isNull(parameters["timestampNs"])
        && isNull(parameters["windowBeforeNs"])
        && isNull(parameters["windowAfterNs"])
    }
    guard string(object["command"]) == "analyze",
      exactKeys(parameters, filterKeys + [
        "kind", "startNs", "endNs", "thresholdNs", "limit",
      ]), validateRequestFilters(parameters, request: request),
      string(parameters["kind"]) == request.kind.rawValue,
      let range = request.normalizedRange,
      integer(parameters["startNs"]) == range.startNs,
      integer(parameters["endNs"]) == range.endNs,
      integer(parameters["thresholdNs"]) == request.thresholdNs,
      integer(parameters["limit"]) == Int64(request.limit)
    else { return false }
    return true
  }

  private static func validateRequestFilters(
    _ object: Object, request: ArkTraceAnalysisRequest
  ) -> Bool {
    matchesOptionalInteger(object["processKey"], expected: request.processKey)
      && matchesOptionalInteger(object["pid"], expected: request.pid)
      && matchesOptionalInteger(object["threadKey"], expected: request.threadKey)
      && matchesOptionalInteger(object["tid"], expected: request.tid)
      && string(object["nameMatch"]) == "exact"
      && ["cpu", "rawState", "normalizedState", "name", "minimumDurationNs",
          "depth", "counterFilterID"].allSatisfy { isNull(object[$0]) }
  }

  private static func validateResult(
    _ value: JSONValue?,
    request: ArkTraceAnalysisRequest,
    trace: TraceIdentity,
    outerQuality: JSONValue?,
    outerTruncation: JSONValue?
  ) -> Bool {
    if request.kind == .context {
      return validateContextResult(
        value, request: request, trace: trace,
        outerQuality: outerQuality, outerTruncation: outerTruncation)
    }
    return validateAnalysisResult(
      value, request: request, trace: trace,
      outerQuality: outerQuality, outerTruncation: outerTruncation)
  }

  private static func expectedRange(
    request: ArkTraceAnalysisRequest, traceDuration: Int64
  ) -> (Int64, Int64)? {
    if request.kind == .context, let timestamp = request.timestampNs {
      let start = max(0, timestamp - min(timestamp, ArkTraceAnalysisRequest.halfWindowNs))
      let (candidateEnd, overflow) = timestamp.addingReportingOverflow(
        ArkTraceAnalysisRequest.halfWindowNs)
      let end = min(traceDuration, overflow ? Int64.max : candidateEnd)
      return start < end ? (start, end) : nil
    }
    guard let range = request.normalizedRange, range.endNs <= traceDuration else { return nil }
    return (range.startNs, range.endNs)
  }

  private static func validateContextResult(
    _ value: JSONValue?, request: ArkTraceAnalysisRequest, trace: TraceIdentity,
    outerQuality: JSONValue?, outerTruncation: JSONValue?
  ) -> Bool {
    guard let value, let result = object(value), exactKeys(result, [
      "range", "filters", "processes", "threads", "cpuSlices", "threadStates",
      "slices", "counters", "summary", "dataQuality", "truncation",
    ]), let expected = expectedRange(request: request, traceDuration: trace.durationNs),
      validateRange(result["range"], expected: expected),
      validateResultFilters(result["filters"], request: request),
      validateDataQuality(result["dataQuality"]), result["dataQuality"] == outerQuality,
      let processes = array(result["processes"]), processes.count <= request.maxRows,
      processes.allSatisfy(validateProcess),
      let threads = array(result["threads"]),
      let directoryTotal = checkedTotal([processes.count, threads.count]),
      directoryTotal <= request.maxRows,
      threads.allSatisfy(validateThread),
      let cpuSlices = array(result["cpuSlices"]),
      cpuSlices.allSatisfy({ validateCPUSlice($0, range: expected) }),
      let threadStates = array(result["threadStates"]),
      threadStates.allSatisfy({ validateThreadState($0, range: expected) }),
      let slices = array(result["slices"]),
      slices.allSatisfy({ validateSlice($0, range: expected) }),
      let counters = array(result["counters"]),
      counters.allSatisfy({ validateCounterSeries($0, range: expected) }),
      validateContextCapabilities(
        result["summary"], cpuSlices: cpuSlices, threadStates: threadStates,
        slices: slices, counters: counters),
      validateContextReferences(
        processes: processes, threads: threads, cpuSlices: cpuSlices,
        threadStates: threadStates, slices: slices, counters: counters,
        truncation: result["truncation"]),
      let counterSamples = checkedTotal(counters.compactMap(counterSampleCount)),
      let eventTotal = checkedTotal([
        cpuSlices.count, threadStates.count, slices.count, counterSamples,
      ]), eventTotal <= request.maxEvents,
      validateContextSummary(
        result["summary"], expectedRange: expected, trace: trace, request: request,
        contextQuality: result["dataQuality"]),
      let sections = validateContextTruncation(
        result["truncation"], counts: [
          "processes": processes.count, "threads": threads.count,
          "cpuSlices": cpuSlices.count, "threadStates": threadStates.count,
          "slices": slices.count, "counters": counterSamples, "summary": 1,
        ]), validateOuterTruncation(outerTruncation, expectedSections: sections)
    else { return false }
    return true
  }

  private static func validateAnalysisResult(
    _ value: JSONValue?, request: ArkTraceAnalysisRequest, trace: TraceIdentity,
    outerQuality: JSONValue?, outerTruncation: JSONValue?
  ) -> Bool {
    guard let value, let result = object(value), exactKeys(result, ["analysis", "kind"]),
      string(result["kind"]) == request.kind.rawValue,
      let analysisValue = result["analysis"], let analysis = object(analysisValue),
      exactKeys(analysis, [
        "kind", "parameters", "range", "cpuUtilization", "topProcesses", "topThreads",
        "longSlices", "threadStateDistribution", "schedulingLatency", "hotIntervals",
        "sections", "dataQuality",
      ]), string(analysis["kind"]) == "deterministicBatch",
      let expected = expectedRange(request: request, traceDuration: trace.durationNs),
      validateRange(analysis["range"], expected: expected),
      validateAnalysisParameters(analysis["parameters"], request: request),
      validateDataQuality(analysis["dataQuality"]), analysis["dataQuality"] == outerQuality,
      let cpu = array(analysis["cpuUtilization"]),
      cpu.allSatisfy({ validateCPUUtilization($0, range: expected) }),
      let processes = array(analysis["topProcesses"]),
      processes.allSatisfy({ validateRunningProcess($0, range: expected) }),
      let threads = array(analysis["topThreads"]),
      threads.allSatisfy({ validateRunningThread($0, range: expected) }),
      let longSlices = array(analysis["longSlices"]),
      longSlices.allSatisfy({
        validateLongSlice(
          $0, minimumDurationNs: request.thresholdNs, requestedRange: expected)
      }),
      let states = array(analysis["threadStateDistribution"]),
      states.allSatisfy({ validateStateDistribution($0, range: expected) }),
      let sampleCount = validateSchedulingLatency(
        analysis["schedulingLatency"], range: expected),
      let hot = array(analysis["hotIntervals"]),
      hot.allSatisfy({ validateHotInterval($0, requestedRange: expected) }),
      let rowTotal = checkedTotal([
        cpu.count, processes.count, threads.count, longSlices.count, states.count,
        sampleCount, hot.count,
      ]), rowTotal <= request.maxRows,
      let sectionRows = validateAnalysisSections(analysis["sections"], counts: [
        "cpuUtilization": cpu.count, "topProcesses": processes.count,
        "topThreads": threads.count, "longSlices": longSlices.count,
        "threadStateDistribution": states.count,
        "schedulingLatency": sampleCount, "hotIntervals": hot.count,
      ]), validateOuterTruncation(outerTruncation, expectedSections: sectionRows)
    else { return false }
    return true
  }

  private static func validateAnalysisParameters(
    _ value: JSONValue?, request: ArkTraceAnalysisRequest
  ) -> Bool {
    guard let value, let object = object(value), exactKeys(object, [
      "filters", "maximumCPUSlices", "maximumProcessSlices", "maximumThreadSlices",
      "maximumStateIntervals", "maximumNamedSlices", "maximumSchedulingEvents",
      "maximumHotEvents", "topProcessLimit", "topThreadLimit", "longSliceLimit",
      "schedulingSampleLimit", "hotIntervalLimit", "hotBucketCount",
      "minimumLongSliceDurationNs", "timeoutSeconds", "timeoutAttoseconds",
    ]), validateResultFilters(object["filters"], request: request) else { return false }
    let eventKeys = [
      "maximumCPUSlices", "maximumProcessSlices", "maximumThreadSlices",
      "maximumStateIntervals", "maximumNamedSlices", "maximumSchedulingEvents",
      "maximumHotEvents",
    ]
    let limitKeys = [
      "topProcessLimit", "topThreadLimit", "longSliceLimit",
      "schedulingSampleLimit", "hotIntervalLimit",
    ]
    let seconds = request.timeoutMs / 1_000
    let attoseconds = Int64(request.timeoutMs % 1_000) * 1_000_000_000_000_000
    return eventKeys.allSatisfy { integer(object[$0]) == Int64(request.maxEvents) }
      && limitKeys.allSatisfy { integer(object[$0]) == Int64(request.limit) }
      && integer(object["hotBucketCount"]) == 100
      && integer(object["minimumLongSliceDurationNs"]) == request.thresholdNs
      && integer(object["timeoutSeconds"]) == Int64(seconds)
      && integer(object["timeoutAttoseconds"]) == attoseconds
  }

  private static func validateResultFilters(
    _ value: JSONValue?, request: ArkTraceAnalysisRequest
  ) -> Bool {
    guard let value, let object = object(value), exactKeys(object, filterKeys) else {
      return false
    }
    return matchesOptionalKey(
      object["processKey"], field: "ipid", expected: request.processKey)
      && matchesOptionalInteger(object["pid"], expected: request.pid)
      && matchesOptionalKey(
        object["threadKey"], field: "itid", expected: request.threadKey)
      && matchesOptionalInteger(object["tid"], expected: request.tid)
      && string(object["nameMatch"]) == "exact"
      && ["cpu", "rawState", "normalizedState", "name", "minimumDurationNs",
          "depth", "counterFilterID"].allSatisfy { isNull(object[$0]) }
  }

  private static func validateContextSummary(
    _ value: JSONValue?, expectedRange: (Int64, Int64), trace: TraceIdentity,
    request: ArkTraceAnalysisRequest,
    contextQuality: JSONValue?
  ) -> Bool {
    guard let value, let object = object(value), exactKeys(object, [
      "range", "durationNs", "cpuCount", "processCount", "threadCount",
      "cpuSliceCount", "threadStateCount", "namedSliceCount", "counterSeriesCount",
      "eventCountBySource", "capabilities", "schemaFingerprint", "dataQuality",
      "truncatedSections",
    ]), validateRange(object["range"], expected: expectedRange),
      integer(object["durationNs"]) == expectedRange.1 - expectedRange.0,
      string(object["schemaFingerprint"]) == trace.schemaFingerprint,
      let processCount = integer(object["processCount"]), processCount >= 0,
      processCount <= Int64(request.maxRows),
      let threadCount = integer(object["threadCount"]), threadCount >= 0,
      threadCount <= Int64(request.maxRows),
      validateDataQuality(object["dataQuality"]),
      qualityIsSubset(object["dataQuality"], of: contextQuality),
      validateCapabilitiesAndSummaryCounts(object, request: request),
      validateEventSources(object["eventCountBySource"], maximumRows: request.maxEvents),
      validateSummaryTruncatedSections(object["truncatedSections"], summary: object)
    else { return false }
    return true
  }

  private static func validateContextCapabilities(
    _ summaryValue: JSONValue?, cpuSlices: [JSONValue], threadStates: [JSONValue],
    slices: [JSONValue], counters: [JSONValue]
  ) -> Bool {
    guard let summaryValue, let summary = object(summaryValue),
      let capabilityValue = summary["capabilities"], let capabilities = object(capabilityValue),
      let cpuScheduling = boolean(capabilities["cpuScheduling"]),
      let states = boolean(capabilities["threadStates"]),
      let namedSlices = boolean(capabilities["namedSlices"]),
      let cpuCounters = boolean(capabilities["cpuCounters"]),
      let processCounters = boolean(capabilities["processCounters"])
    else { return false }
    guard cpuScheduling || cpuSlices.isEmpty,
      states || threadStates.isEmpty,
      namedSlices || slices.isEmpty
    else { return false }
    for value in counters {
      guard let row = object(value), let scope = string(row["scope"]),
        (scope == "cpu" && cpuCounters) || (scope == "process" && processCounters)
      else { return false }
    }
    return true
  }

  private static func validateContextReferences(
    processes: [JSONValue], threads: [JSONValue], cpuSlices: [JSONValue],
    threadStates: [JSONValue], slices: [JSONValue], counters: [JSONValue],
    truncation: JSONValue?
  ) -> Bool {
    let processKeys = processes.compactMap { row in
      object(row).flatMap { keyValue($0["key"], field: "ipid") }
    }
    let threadKeys = threads.compactMap { row in
      object(row).flatMap { keyValue($0["key"], field: "itid") }
    }
    guard processKeys.count == processes.count, Set(processKeys).count == processKeys.count,
      threadKeys.count == threads.count, Set(threadKeys).count == threadKeys.count,
      let truncation, let truncationObject = object(truncation),
      let omitted = boolean(truncationObject["referenceOmittedByBudget"])
    else { return false }
    if omitted { return true }
    let processSet = Set(processKeys)
    let threadSet = Set(threadKeys)
    func references(
      _ rows: [JSONValue], processField: String? = "processKey",
      threadField: String? = "threadKey"
    ) -> Bool {
      rows.allSatisfy { row in
        guard let object = object(row) else { return false }
        let processIsClosed = processField.flatMap { field in
          keyValue(object[field], field: "ipid").map(processSet.contains)
        } ?? true
        let threadIsClosed = threadField.flatMap { field in
          keyValue(object[field], field: "itid").map(threadSet.contains)
        } ?? true
        return processIsClosed && threadIsClosed
      }
    }
    return references(threads, threadField: nil)
      && references(cpuSlices)
      && references(threadStates)
      && references(slices)
      && references(counters, threadField: nil)
  }

  private static func validateCapabilitiesAndSummaryCounts(
    _ summary: Object, request: ArkTraceAnalysisRequest
  ) -> Bool {
    guard let value = summary["capabilities"], let capabilities = object(value),
      exactKeys(capabilities, [
        "cpuScheduling", "threadStates", "namedSlices", "cpuCounters", "processCounters",
      ]), let cpuScheduling = boolean(capabilities["cpuScheduling"]),
      let threadStates = boolean(capabilities["threadStates"]),
      let namedSlices = boolean(capabilities["namedSlices"]),
      let cpuCounters = boolean(capabilities["cpuCounters"]),
      let processCounters = boolean(capabilities["processCounters"])
    else { return false }
    func count(_ name: String, available: Bool, maximum: Int) -> Bool {
      available
        ? integer(summary[name]).map({ $0 >= 0 && $0 <= Int64(maximum) }) == true
        : isNull(summary[name])
    }
    return count("cpuCount", available: cpuScheduling, maximum: request.maxRows)
      && count("cpuSliceCount", available: cpuScheduling, maximum: request.maxEvents)
      && count("threadStateCount", available: threadStates, maximum: request.maxEvents)
      && count("namedSliceCount", available: namedSlices, maximum: request.maxEvents)
      && count(
        "counterSeriesCount", available: cpuCounters || processCounters,
        maximum: request.maxEvents)
  }

  private static func validateEventSources(
    _ value: JSONValue?, maximumRows: Int
  ) -> Bool {
    if isNull(value) { return true }
    guard let rows = array(value), rows.count <= maximumRows else { return false }
    var previous: Data?
    var identities = Set<Data>()
    for rowValue in rows {
      guard let row = object(rowValue), exactKeys(row, ["source", "count"]),
        let source = string(row["source"]), safe(source, maximumBytes: 1_024),
        let count = integer(row["count"]), count >= 0
      else { return false }
      let bytes = Data(source.utf8)
      if let previous, !previous.lexicographicallyPrecedes(bytes) { return false }
      guard identities.insert(bytes).inserted else { return false }
      previous = bytes
    }
    return true
  }

  private static func validateSummaryTruncatedSections(
    _ value: JSONValue?, summary: Object
  ) -> Bool {
    guard let sections = stringArray(value, maximumCount: 8),
      Set(sections).count == sections.count
    else { return false }
    // ArkTrace preserves the declared TraceSummarySection order. That order
    // is stable and machine-facing, but deliberately differs from lexical
    // order (for example process/thread counts precede named slices).
    let ordered = [
      "cpuCount", "processCount", "threadCount", "cpuSliceCount", "threadStateCount",
      "namedSliceCount", "counterSeriesCount", "eventCountBySource",
    ]
    let positions = sections.compactMap { ordered.firstIndex(of: $0) }
    guard positions.count == sections.count, positions == positions.sorted() else { return false }
    let unavailable = [
      "cpuCount", "cpuSliceCount", "threadStateCount", "namedSliceCount",
      "counterSeriesCount", "eventCountBySource",
    ].filter { isNull(summary[$0]) }
    return Set(sections).isDisjoint(with: Set(unavailable))
  }

  private static func validateContextTruncation(
    _ value: JSONValue?, counts: [String: Int]
  ) -> [String]? {
    guard let value, let object = object(value), exactKeys(object, [
      "processes", "threads", "cpuSlices", "threadStates", "slices", "counters",
      "summary", "referenceOmittedByBudget",
    ]), let references = boolean(object["referenceOmittedByBudget"]) else { return nil }
    var truncated: [String] = []
    for name in [
      "processes", "threads", "cpuSlices", "threadStates", "slices", "counters", "summary",
    ] {
      guard let count = counts[name], let isTruncated = validateSectionStatus(
        object[name], returnedCount: count) else { return nil }
      if isTruncated { truncated.append(name) }
    }
    if references { truncated.append("references") }
    return truncated.sorted()
  }

  private static func validateAnalysisSections(
    _ value: JSONValue?, counts: [String: Int]
  ) -> [String]? {
    let names = [
      "cpuUtilization", "topProcesses", "topThreads", "longSlices",
      "threadStateDistribution", "schedulingLatency", "hotIntervals",
    ]
    guard let value, let object = object(value), exactKeys(object, names) else { return nil }
    var truncated: [String] = []
    for name in names {
      guard let count = counts[name], let isTruncated = validateSectionStatus(
        object[name], returnedCount: count,
        permitsAggregation: name == "cpuUtilization" || name == "threadStateDistribution"
      ) else { return nil }
      if isTruncated { truncated.append(name) }
    }
    return truncated.sorted()
  }

  private static func validateSectionStatus(
    _ value: JSONValue?, returnedCount: Int, permitsAggregation: Bool = false
  ) -> Bool? {
    guard let value, let object = object(value),
      exactKeys(object, ["returnedCount", "matchedCount", "truncated"]),
      integer(object["returnedCount"]) == Int64(returnedCount),
      let truncated = boolean(object["truncated"])
    else { return nil }
    if isNull(object["matchedCount"]) {
      guard truncated else { return nil }
    } else {
      guard let matched = integer(object["matchedCount"]), matched >= Int64(returnedCount),
        matched == Int64(returnedCount) || truncated || permitsAggregation
      else { return nil }
    }
    return truncated
  }

  private static func validateOuterTruncation(
    _ value: JSONValue?, expectedSections: [String]?
  ) -> Bool {
    guard let expectedSections, let value, let object = object(value),
      exactKeys(object, ["truncated", "sections"]),
      let truncated = boolean(object["truncated"]),
      let sections = stringArray(object["sections"], maximumCount: 256)
    else { return false }
    return sections == expectedSections && truncated == !sections.isEmpty
  }

  private static func validateTruncationRoot(_ value: JSONValue?) -> Bool {
    guard let value, let object = object(value),
      exactKeys(object, ["truncated", "sections"]),
      let truncated = boolean(object["truncated"]),
      let sections = stringArray(object["sections"], maximumCount: 256)
    else { return false }
    return sections == sections.sorted() && Set(sections).count == sections.count
      && truncated == !sections.isEmpty
  }

  private static func validateDataQuality(_ value: JSONValue?) -> Bool {
    guard let value, let object = object(value), exactKeys(object, ["status", "warnings"]),
      let status = string(object["status"]), let warnings = array(object["warnings"]),
      warnings.count <= 4_096
    else { return false }
    let categories = Set([
      "probeTruncated", "invalidValue", "clampedValue", "droppedValue",
      "referentialIntegrity", "unavailableValue",
    ])
    var previous: (String, String, Int64)?
    var identities = Set<String>()
    for value in warnings {
      guard let warning = self.object(value),
        exactKeys(warning, ["category", "scope", "count", "message"]),
        let category = string(warning["category"]), categories.contains(category),
        isNull(warning["message"])
      else { return false }
      let scope: String
      if isNull(warning["scope"]) { scope = "" }
      else {
        guard let candidate = string(warning["scope"]),
          ArkTraceSummaryEnvelopeValidator.machineQualityScopes.contains(candidate)
        else { return false }
        scope = candidate
      }
      let count: Int64
      if isNull(warning["count"]) { count = .min }
      else {
        guard let candidate = integer(warning["count"]), candidate >= 0 else { return false }
        count = candidate
      }
      let identity = "\(category)\u{0}\(scope)\u{0}\(count)"
      guard identities.insert(identity).inserted else { return false }
      let current = (category, scope, count)
      if let previous, previous > current { return false }
      previous = current
    }
    return status == (warnings.isEmpty ? "ok" : "warnings")
  }

  private static func qualityIsSubset(_ lhs: JSONValue?, of rhs: JSONValue?) -> Bool {
    guard let lhs, let rhs, let left = object(lhs), let right = object(rhs),
      let leftWarnings = array(left["warnings"]), let rightWarnings = array(right["warnings"])
    else { return false }
    return leftWarnings.allSatisfy(rightWarnings.contains)
  }

  // MARK: - Context rows

  private static func validateProcess(_ value: JSONValue) -> Bool {
    guard let object = object(value), exactKeys(object, [
      "key", "pid", "name", "startNs", "endNs", "threadCount",
    ]), validKey(object["key"], field: "ipid"), integer(object["pid"]) != nil,
      optionalText(object["name"], maximumBytes: 4_096),
      optionalNonnegativeInteger(object["startNs"]),
      optionalNonnegativeInteger(object["endNs"]),
      optionalNonnegativeInteger(object["threadCount"])
    else { return false }
    return true
  }

  private static func validateThread(_ value: JSONValue) -> Bool {
    guard let object = object(value), exactKeys(object, [
      "key", "processKey", "tid", "pid", "name", "processName", "startNs", "endNs",
      "isMainThread",
    ]), validKey(object["key"], field: "itid"),
      validOptionalKey(object["processKey"], field: "ipid"), integer(object["tid"]) != nil,
      optionalInteger(object["pid"]), optionalText(object["name"], maximumBytes: 4_096),
      optionalText(object["processName"], maximumBytes: 4_096),
      optionalNonnegativeInteger(object["startNs"]),
      optionalNonnegativeInteger(object["endNs"]), optionalBoolean(object["isMainThread"])
    else { return false }
    return true
  }

  private static func validateCPUSlice(
    _ value: JSONValue, range: (Int64, Int64)
  ) -> Bool {
    guard let object = object(value), exactKeys(object, [
      "key", "range", "cpu", "threadKey", "processKey", "tid", "pid", "threadName",
      "processName", "endState", "priority", "isOpenEnded",
    ]), validateEventKey(object["key"]), validateRange(object["range"]),
      rangeIntersects(object["range"], range),
      let cpu = integer(object["cpu"]), cpu >= 0,
      validOptionalKey(object["threadKey"], field: "itid"),
      validOptionalKey(object["processKey"], field: "ipid"),
      optionalInteger(object["tid"]), optionalInteger(object["pid"]),
      optionalText(object["threadName"], maximumBytes: 4_096),
      optionalText(object["processName"], maximumBytes: 4_096),
      optionalText(object["endState"], maximumBytes: 4_096),
      optionalInteger(object["priority"]), boolean(object["isOpenEnded"]) != nil
    else { return false }
    return true
  }

  private static func validateThreadState(
    _ value: JSONValue, range: (Int64, Int64)
  ) -> Bool {
    guard let object = object(value), exactKeys(object, [
      "key", "range", "threadKey", "processKey", "state", "normalizedState", "cpu",
      "tid", "pid", "processName", "threadName", "isOpenEnded",
    ]), validateEventKey(object["key"]), validateRange(object["range"]),
      rangeIntersects(object["range"], range),
      validKey(object["threadKey"], field: "itid"),
      validOptionalKey(object["processKey"], field: "ipid"),
      let state = string(object["state"]), safe(state, maximumBytes: 4_096),
      optionalEnum(object["normalizedState"], allowed: [
        "running", "runnable", "sleeping", "blocked", "stopped",
      ]), optionalNonnegativeInteger(object["cpu"]), optionalInteger(object["tid"]),
      optionalInteger(object["pid"]),
      optionalText(object["processName"], maximumBytes: 4_096),
      optionalText(object["threadName"], maximumBytes: 4_096),
      boolean(object["isOpenEnded"]) != nil
    else { return false }
    return true
  }

  private static func validateSlice(
    _ value: JSONValue, range: (Int64, Int64)
  ) -> Bool {
    guard let object = object(value), exactKeys(object, [
      "key", "range", "threadKey", "processKey", "pid", "tid", "processName",
      "threadName", "name", "category", "depth", "parentEventKey", "isAsync",
      "isOpenEnded",
    ]), validateEventKey(object["key"]), validateRange(object["range"]),
      rangeIntersects(object["range"], range),
      validOptionalKey(object["threadKey"], field: "itid"),
      validOptionalKey(object["processKey"], field: "ipid"), optionalInteger(object["pid"]),
      optionalInteger(object["tid"]), optionalText(object["processName"], maximumBytes: 4_096),
      optionalText(object["threadName"], maximumBytes: 4_096),
      string(object["name"]).map({ safe($0, maximumBytes: 4_096) }) == true,
      optionalText(object["category"], maximumBytes: 4_096),
      optionalNonnegativeInteger(object["depth"]), validateOptionalEventKey(object["parentEventKey"]),
      boolean(object["isAsync"]) != nil, boolean(object["isOpenEnded"]) != nil
    else { return false }
    return true
  }

  private static func validateCounterSeries(
    _ value: JSONValue, range: (Int64, Int64)
  ) -> Bool {
    guard let object = object(value), exactKeys(object, [
      "filterID", "name", "scope", "cpu", "processKey", "pid", "processName", "unit",
      "samples",
    ]), integer(object["filterID"]) != nil,
      string(object["name"]).map({ safe($0, maximumBytes: 4_096) }) == true,
      let scope = string(object["scope"]), ["cpu", "process"].contains(scope),
      optionalNonnegativeInteger(object["cpu"]),
      validOptionalKey(object["processKey"], field: "ipid"), optionalInteger(object["pid"]),
      optionalText(object["processName"], maximumBytes: 4_096),
      optionalText(object["unit"], maximumBytes: 4_096),
      let samples = array(object["samples"]),
      samples.allSatisfy({ validateCounterSample($0, range: range) }),
      // A counter is a step function: its value holds until the next sample, so
      // the value in force at the window's start was written before the window.
      // One such carry-in sample is what makes the series readable at all; more
      // than one would be backfill the window cannot justify.
      samples.filter({ sampleStartsBeforeWindow($0, range: range) }).count <= 1
    else { return false }
    return scope == "cpu" ? !isNull(object["cpu"]) && isNull(object["processKey"])
      : isNull(object["cpu"]) && !isNull(object["processKey"])
  }

  private static func sampleStartsBeforeWindow(
    _ value: JSONValue, range: (Int64, Int64)
  ) -> Bool {
    guard let object = object(value), let timestamp = integer(object["timestampNs"]) else {
      return false
    }
    return timestamp < range.0
  }

  private static func validateCounterSample(
    _ value: JSONValue, range: (Int64, Int64)
  ) -> Bool {
    guard let object = object(value), exactKeys(object, [
      "key", "timestampNs", "value", "durationNs",
    ]), validateEventKey(object["key"]),
      let timestamp = integer(object["timestampNs"]),
      timestamp < range.1,
      integer(object["value"]) != nil, optionalNonnegativeInteger(object["durationNs"])
    else { return false }
    if timestamp >= range.0 { return true }
    // The sample predates the window, so it is only admissible as the value
    // still in force at the window's start: its own validity has to reach the
    // window. A bare timestamp before the window proves nothing and is refused.
    guard let duration = integer(object["durationNs"]), duration >= 0,
      let end = checkedSum(timestamp, duration), end > range.0
    else { return false }
    return true
  }

  private static func counterSampleCount(_ value: JSONValue) -> Int? {
    guard let object = object(value), let samples = array(object["samples"]) else { return nil }
    return samples.count
  }

  // MARK: - Analysis rows

  private static func validateCPUUtilization(
    _ value: JSONValue, range: (Int64, Int64)
  ) -> Bool {
    guard let object = object(value), exactKeys(object, [
      "cpu", "rawRunningNs", "occupiedNs", "sliceCount", "utilization",
    ]), let cpu = integer(object["cpu"]), cpu >= 0,
      let raw = integer(object["rawRunningNs"]), raw >= 0,
      let occupied = integer(object["occupiedNs"]), occupied >= 0,
      let count = integer(object["sliceCount"]), count >= 0,
      let utilization = finiteNumber(object["utilization"]),
      let duration = checkedDifference(range.1, range.0), duration > 0,
      occupied == min(duration, raw),
      approximatelyEqual(utilization, Double(occupied) / Double(duration))
    else { return false }
    return true
  }

  private static func validateRunningProcess(
    _ value: JSONValue, range: (Int64, Int64)
  ) -> Bool {
    guard let object = object(value), exactKeys(object, [
      "processKey", "pid", "name", "runningNs", "shareOfOneCPU", "sliceCount",
    ]), validKey(object["processKey"], field: "ipid"), optionalInteger(object["pid"]),
      optionalText(object["name"], maximumBytes: 4_096),
      let running = integer(object["runningNs"]), running >= 0,
      let share = finiteNumber(object["shareOfOneCPU"]),
      let count = integer(object["sliceCount"]), count >= 0,
      let duration = checkedDifference(range.1, range.0), duration > 0,
      approximatelyEqual(share, Double(running) / Double(duration))
    else { return false }
    return true
  }

  private static func validateRunningThread(
    _ value: JSONValue, range: (Int64, Int64)
  ) -> Bool {
    guard let object = object(value), exactKeys(object, [
      "threadKey", "processKey", "tid", "pid", "name", "processName", "runningNs",
      "shareOfOneCPU", "sliceCount",
    ]), validKey(object["threadKey"], field: "itid"),
      validOptionalKey(object["processKey"], field: "ipid"), optionalInteger(object["tid"]),
      optionalInteger(object["pid"]), optionalText(object["name"], maximumBytes: 4_096),
      optionalText(object["processName"], maximumBytes: 4_096),
      let running = integer(object["runningNs"]), running >= 0,
      let share = finiteNumber(object["shareOfOneCPU"]),
      let count = integer(object["sliceCount"]), count >= 0,
      let duration = checkedDifference(range.1, range.0), duration > 0,
      approximatelyEqual(share, Double(running) / Double(duration))
    else { return false }
    return true
  }

  private static func validateLongSlice(
    _ value: JSONValue, minimumDurationNs: Int64,
    requestedRange: (Int64, Int64)
  ) -> Bool {
    guard let object = object(value), exactKeys(object, [
      "key", "range", "name", "category", "processKey", "threadKey", "pid", "tid",
      "processName", "threadName",
    ]), validateEventKey(object["key"]), validateRange(object["range"]),
      rangeIntersects(object["range"], requestedRange),
      rangeDuration(object["range"]).map({ $0 >= minimumDurationNs }) == true,
      string(object["name"]).map({ safe($0, maximumBytes: 4_096) }) == true,
      optionalText(object["category"], maximumBytes: 4_096),
      validOptionalKey(object["processKey"], field: "ipid"),
      validOptionalKey(object["threadKey"], field: "itid"), optionalInteger(object["pid"]),
      optionalInteger(object["tid"]), optionalText(object["processName"], maximumBytes: 4_096),
      optionalText(object["threadName"], maximumBytes: 4_096)
    else { return false }
    return true
  }

  private static func validateStateDistribution(
    _ value: JSONValue, range: (Int64, Int64)
  ) -> Bool {
    guard let object = object(value), exactKeys(object, [
      "threadKey", "processKey", "tid", "pid", "rawState", "normalizedState",
      "durationNs", "percentageOfRange", "intervalCount",
    ]), validKey(object["threadKey"], field: "itid"),
      validOptionalKey(object["processKey"], field: "ipid"), optionalInteger(object["tid"]),
      optionalInteger(object["pid"]),
      string(object["rawState"]).map({ safe($0, maximumBytes: 4_096) }) == true,
      optionalEnum(object["normalizedState"], allowed: [
        "running", "runnable", "sleeping", "blocked", "stopped",
      ]), let duration = integer(object["durationNs"]), duration >= 0,
      let percentage = finiteNumber(object["percentageOfRange"]),
      let rangeDuration = checkedDifference(range.1, range.0), rangeDuration > 0,
      duration <= rangeDuration,
      approximatelyEqual(percentage, Double(duration) / Double(rangeDuration)),
      let count = integer(object["intervalCount"]), count >= 0
    else { return false }
    return true
  }

  private static func validateSchedulingLatency(
    _ value: JSONValue?, range: (Int64, Int64)
  ) -> Int? {
    guard let value, let object = object(value), exactKeys(object, [
      "supported", "unsupportedReason", "count", "percentiles", "topSamples", "truncated",
    ]), let supported = boolean(object["supported"]),
      let count = integer(object["count"]), count >= 0,
      let samples = array(object["topSamples"]),
      samples.allSatisfy({ validateSchedulingSample($0, range: range) }),
      Int64(samples.count) <= count, boolean(object["truncated"]) != nil
    else { return nil }
    if supported {
      guard isNull(object["unsupportedReason"]),
        count == 0 ? isNull(object["percentiles"]) : validatePercentiles(object["percentiles"])
      else { return nil }
    } else {
      guard let reason = string(object["unsupportedReason"]),
        ["capabilityUnavailable", "noProvableRunnableTransitions"].contains(reason),
        isNull(object["percentiles"]), count == 0, samples.isEmpty
      else { return nil }
    }
    return samples.count
  }

  private static func validatePercentiles(_ value: JSONValue?) -> Bool {
    guard let value, let object = object(value), exactKeys(object, [
      "p50Ns", "p90Ns", "p95Ns", "p99Ns", "maxNs",
    ]), let p50 = integer(object["p50Ns"]), let p90 = integer(object["p90Ns"]),
      let p95 = integer(object["p95Ns"]), let p99 = integer(object["p99Ns"]),
      let max = integer(object["maxNs"])
    else { return false }
    return 0 <= p50 && p50 <= p90 && p90 <= p95 && p95 <= p99 && p99 <= max
  }

  private static func validateSchedulingSample(
    _ value: JSONValue, range: (Int64, Int64)
  ) -> Bool {
    guard let object = object(value), exactKeys(object, [
      "threadKey", "runnableEventKey", "runningEventKey", "runnableEndNs",
      "runningStartNs", "latencyNs",
    ]), validKey(object["threadKey"], field: "itid"),
      validateEventKey(object["runnableEventKey"]), validateEventKey(object["runningEventKey"]),
      let runnableEnd = integer(object["runnableEndNs"]), runnableEnd >= 0,
      let runningStart = integer(object["runningStartNs"]), runningStart == runnableEnd,
      runnableEnd >= range.0, runningStart <= range.1,
      let latency = integer(object["latencyNs"]), latency >= 0,
      latency <= runnableEnd - range.0
    else { return false }
    return true
  }

  private static func validateHotInterval(
    _ value: JSONValue, requestedRange: (Int64, Int64)
  ) -> Bool {
    guard let object = object(value), exactKeys(object, [
      "range", "score", "cpuSliceCount", "namedSliceCount",
    ]), validateRange(object["range"]),
      rangeIsContained(object["range"], in: requestedRange),
      let cpuCount = integer(object["cpuSliceCount"]), cpuCount >= 0,
      let namedCount = integer(object["namedSliceCount"]), namedCount >= 0,
      let scoreValue = object["score"], let score = self.object(scoreValue),
      exactKeys(score, [
        "cpuBusyNs", "contextSwitchCount", "contextSwitchScoreNs", "longSliceNs", "total",
      ]), let cpuBusy = integer(score["cpuBusyNs"]), cpuBusy >= 0,
      let switches = integer(score["contextSwitchCount"]), switches >= 0,
      let switchScore = integer(score["contextSwitchScoreNs"]), switchScore >= 0,
      switches <= Int64.max / 1_000_000, switchScore == switches * 1_000_000,
      let long = integer(score["longSliceNs"]), long >= 0,
      let total = integer(score["total"]),
      let expected = checkedSum(cpuBusy, switchScore, long), total == expected
    else { return false }
    return true
  }

  // MARK: - Primitive helpers

  private static func validateRange(
    _ value: JSONValue?, expected: (Int64, Int64)? = nil
  ) -> Bool {
    guard let value, let object = object(value), exactKeys(object, ["startNs", "endNs"]),
      let start = integer(object["startNs"]), let end = integer(object["endNs"]),
      start >= 0, start <= end
    else { return false }
    return expected.map { start == $0.0 && end == $0.1 } ?? true
  }

  private static func validateEventKey(_ value: JSONValue?) -> Bool {
    guard let value, let object = object(value), exactKeys(object, ["table", "rowID"]),
      let table = string(object["table"]), safe(table, maximumBytes: 128),
      integer(object["rowID"]) != nil
    else { return false }
    return true
  }

  private static func validateOptionalEventKey(_ value: JSONValue?) -> Bool {
    isNull(value) || validateEventKey(value)
  }

  private static func validKey(_ value: JSONValue?, field: String) -> Bool {
    guard let value, let object = object(value), exactKeys(object, [field]),
      let key = integer(object[field])
    else { return false }
    return key != 0
  }

  private static func keyValue(_ value: JSONValue?, field: String) -> Int64? {
    guard let value, let object = object(value), exactKeys(object, [field]),
      let key = integer(object[field]), key != 0
    else { return nil }
    return key
  }

  private static func validOptionalKey(_ value: JSONValue?, field: String) -> Bool {
    isNull(value) || validKey(value, field: field)
  }

  private static func matchesOptionalKey(
    _ value: JSONValue?, field: String, expected: Int64?
  ) -> Bool {
    if let expected {
      guard let value, let object = object(value), exactKeys(object, [field]) else {
        return false
      }
      return integer(object[field]) == expected
    }
    return isNull(value)
  }

  private static func object(_ value: JSONValue) -> Object? {
    guard case .object(let object) = value else { return nil }
    return object
  }

  private static func array(_ value: JSONValue?) -> [JSONValue]? {
    guard case .array(let array)? = value else { return nil }
    return array
  }

  private static func string(_ value: JSONValue?) -> String? {
    guard case .string(let string)? = value else { return nil }
    return string
  }

  private static func integer(_ value: JSONValue?) -> Int64? {
    switch value {
    case .integer(let value)?: return value
    case .unsignedInteger(let value)?: return Int64(exactly: value)
    default: return nil
    }
  }

  private static func matchesOptionalInteger(
    _ value: JSONValue?, expected: Int64?
  ) -> Bool {
    if let expected { return integer(value) == expected }
    return isNull(value)
  }

  private static func finiteNumber(_ value: JSONValue?) -> Double? {
    let result: Double?
    switch value {
    case .integer(let value)?: result = Double(value)
    case .unsignedInteger(let value)?: result = Double(value)
    case .number(let value)?: result = value
    default: result = nil
    }
    guard let result, result.isFinite else { return nil }
    return result
  }

  private static func boolean(_ value: JSONValue?) -> Bool? {
    guard case .bool(let value)? = value else { return nil }
    return value
  }

  private static func isNull(_ value: JSONValue?) -> Bool {
    guard case .null? = value else { return false }
    return true
  }

  private static func optionalInteger(_ value: JSONValue?) -> Bool {
    isNull(value) || integer(value) != nil
  }

  private static func optionalNonnegativeInteger(_ value: JSONValue?) -> Bool {
    isNull(value) || integer(value).map({ $0 >= 0 }) == true
  }

  private static func optionalBoolean(_ value: JSONValue?) -> Bool {
    isNull(value) || boolean(value) != nil
  }

  private static func optionalText(_ value: JSONValue?, maximumBytes: Int) -> Bool {
    isNull(value) || string(value).map({ safe($0, maximumBytes: maximumBytes) }) == true
  }

  private static func optionalEnum(_ value: JSONValue?, allowed: Set<String>) -> Bool {
    isNull(value) || string(value).map(allowed.contains) == true
  }

  private static func exactKeys(_ object: Object, _ expected: [String]) -> Bool {
    object.count == expected.count && Set(object.keys) == Set(expected)
  }

  private static func stringArray(
    _ value: JSONValue?, maximumCount: Int
  ) -> [String]? {
    guard let rows = array(value), rows.count <= maximumCount else { return nil }
    var result: [String] = []
    result.reserveCapacity(rows.count)
    for row in rows {
      guard let value = string(row), safe(value, maximumBytes: 128) else { return nil }
      result.append(value)
    }
    return result
  }

  private static func safe(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes
      && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
      ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
        || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
    }
  }

  private static func checkedTotal(_ values: [Int]) -> Int? {
    var total = 0
    for value in values {
      let (next, overflow) = total.addingReportingOverflow(value)
      guard !overflow else { return nil }
      total = next
    }
    return total
  }

  private static func checkedSum(_ values: Int64...) -> Int64? {
    var total: Int64 = 0
    for value in values {
      let (next, overflow) = total.addingReportingOverflow(value)
      guard !overflow else { return nil }
      total = next
    }
    return total
  }

  private static func checkedDifference(_ end: Int64, _ start: Int64) -> Int64? {
    let (difference, overflow) = end.subtractingReportingOverflow(start)
    return overflow ? nil : difference
  }

  private static func rangeDuration(_ value: JSONValue?) -> Int64? {
    guard let value, let object = object(value),
      let start = integer(object["startNs"]), let end = integer(object["endNs"]),
      start <= end
    else { return nil }
    return checkedDifference(end, start)
  }

  private static func rangeIsContained(
    _ value: JSONValue?, in expected: (Int64, Int64)
  ) -> Bool {
    guard let value, let object = object(value),
      let start = integer(object["startNs"]), let end = integer(object["endNs"])
    else { return false }
    return start >= expected.0 && end <= expected.1
  }

  private static func rangeIntersects(
    _ value: JSONValue?, _ expected: (Int64, Int64)
  ) -> Bool {
    guard let value, let object = object(value),
      let start = integer(object["startNs"]), let end = integer(object["endNs"])
    else { return false }
    if start == end { return start >= expected.0 && start < expected.1 }
    return start < expected.1 && end > expected.0
  }

  private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
    guard lhs.isFinite, rhs.isFinite else { return false }
    let tolerance = max(1e-12, abs(rhs) * 1e-12)
    return abs(lhs - rhs) <= tolerance
  }
}
