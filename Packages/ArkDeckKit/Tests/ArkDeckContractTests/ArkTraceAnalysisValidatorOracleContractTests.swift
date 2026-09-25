// Shared Swift oracle for the Rust ArkTrace analysis request and envelope
// validator (CHG-2026-074, TASK-XPA-015).

import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// Swift `AnalyzerProvider.analysisRequest(_:)` over the inputs an
/// `analyzer.analyze-trace@1` Job may carry, and
/// `ArkTraceAnalysisEnvelopeValidator` over the envelopes its reviewed CLI
/// answers, the oracle `rust/crates/arkdeck-hoststore/src/arktrace_analysis.rs`
/// replays. The validator's bases are the reviewed ArkTrace CLI's own answers
/// for the repository's `zlib.htrace` and `trace_small_10.systrace`
/// (`reviewed/`, inputs recorded with their requests in `requests.json`);
/// each case edits a base's exact bytes (each edit replacing the first
/// occurrence of its text) and judges it for an invocation made from the
/// base's request, or from one changed the way its name says. Each request
/// case records the request or Swift's refusal, and for a request its CLI
/// arguments, process deadline, recovery digest and time range.
///
/// Record a new oracle with
/// `ARKDECK_RUST_ARKTRACE_ANALYSIS_VALIDATOR_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class ArkTraceAnalysisValidatorOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/arktrace-analysis-validator", directoryHint: .isDirectory)

  static let sourcePath = "/private/tmp/arkdeck-trace-source/job-trace/trace.htrace"
  /// The reviewed distribution's contract and CLI the bases were answered by.
  static let contract = ArkTraceSummaryInvocationContract(
    toolVersion: "0.1.0", parserVersion: "4.3.7",
    parserUpstreamRevision: "447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6",
    parserSHA256: "7c5ed515fc4d74517476fb901e3f7812914cb33b651324f49466d709d4641b35",
    parserBuildRecipeVersion: "e4fec8cc9cbb1be13748e7149424ce664a545c2296b424b6ff520cc3e84d3f06",
    parserAdapterVersion: "1", schemaAdapterVersion: "2", indexSchemaVersion: 3)
  static let executableSHA256 =
    "cdfc91679211c7537db343693b035e1b7c9752beadd9b60dd9cfad90874829c1"

  struct Case {
    let name: String
    let base: String
    let edits: [(String, String)]
    let invocation: String

    init(_ name: String, _ base: String, _ edits: [(String, String)], _ invocation: String) {
      self.name = name
      self.base = base
      self.edits = edits
      self.invocation = invocation
    }
  }

  static let cases: [Case] = [
    Case("reviewed-systrace-context-range", "systrace-context-range", [], "reviewed"),
    Case("reviewed-systrace-context-timestamp", "systrace-context-timestamp", [], "reviewed"),
    Case("reviewed-systrace-cpu", "systrace-cpu", [], "reviewed"),
    Case("reviewed-systrace-pid", "systrace-pid", [], "reviewed"),
    Case("reviewed-systrace-scheduling", "systrace-scheduling", [], "reviewed"),
    Case("reviewed-systrace-slices", "systrace-slices", [], "reviewed"),
    Case("reviewed-zlib-context-range", "zlib-context-range", [], "reviewed"),
    Case("reviewed-zlib-context-timestamp", "zlib-context-timestamp", [], "reviewed"),
    Case("reviewed-zlib-cpu", "zlib-cpu", [], "reviewed"),
    Case("reviewed-zlib-hot-intervals", "zlib-hot-intervals", [], "reviewed"),
    Case("reviewed-zlib-range", "zlib-range", [], "reviewed"),
    Case("reviewed-zlib-slices", "zlib-slices", [], "reviewed"),
    Case("invocation-otherExecutable", "zlib-slices", [], "otherExecutable"),
    Case("invocation-noRequest", "zlib-slices", [], "noRequest"),
    Case("invocation-noContract", "zlib-slices", [], "noContract"),
    Case("invocation-summaryAnalyzer", "zlib-slices", [], "summaryAnalyzer"),
    Case("invocation-budgetMismatch", "zlib-slices", [], "budgetMismatch"),
    Case("invocation-timeoutMismatch", "zlib-slices", [], "timeoutMismatch"),
    Case("invocation-argumentsMismatch", "zlib-slices", [], "argumentsMismatch"),
    Case("invocation-zeroByteCount", "zlib-slices", [], "zeroByteCount"),
    Case("invocation-uppercaseSource", "zlib-slices", [], "uppercaseSource"),
    Case("invocation-otherSource", "zlib-slices", [], "otherSource"),
    Case("invocation-otherByteCount", "zlib-slices", [], "otherByteCount"),
    Case("invocation-smallBudget", "zlib-slices", [], "smallBudget"),
    Case("invocation-sourcePathInOutput", "zlib-slices", [], "sourcePathInOutput"),
    Case("invocation-emptySourcePath", "zlib-slices", [], "emptySourcePath"),
    Case("invocation-requestLimitMismatch", "zlib-slices", [], "requestLimitMismatch"),
    Case("extraRootMember", "zlib-slices", [("{\"dataQuality\"", "{\"aaa\":1,\"dataQuality\"")], "reviewed"),
    Case("schemaVersion", "zlib-slices", [("\"schemaVersion\":\"1.0\"", "\"schemaVersion\":\"1.1\"")], "reviewed"),
    Case("integralFloatVersion", "zlib-slices", [("\"indexSchemaVersion\":3,", "\"indexSchemaVersion\":3.0,")], "reviewed"),
    Case("exponentByteCount", "zlib-slices", [("\"upstreamDatabaseByteCount\":917504", "\"upstreamDatabaseByteCount\":9.17504e5")], "reviewed"),
    Case("fractionalWarningCount", "zlib-slices", [("\"count\":416,", "\"count\":416.5,"), ("\"count\":416,", "\"count\":416.5,")], "reviewed"),
    Case("duplicateRootMember", "zlib-slices", [("\"schemaVersion\":\"1.0\"", "\"schemaVersion\":\"1.0\",\"schemaVersion\":\"1.0\"")], "reviewed"),
    Case("toolName", "zlib-slices", [("\"name\":\"arktrace\"", "\"name\":\"arktracf\"")], "reviewed"),
    Case("toolVersion", "zlib-slices", [("\"version\":\"0.1.0\"", "\"version\":\"0.1.1\"")], "reviewed"),
    Case("limitsTimeout", "zlib-slices", [("\"timeoutMs\":30000}", "\"timeoutMs\":30001}")], "reviewed"),
    Case("traceByteCount", "zlib-slices", [("\"byteCount\":67837", "\"byteCount\":67838")], "reviewed"),
    Case("traceNegativeDuration", "zlib-slices", [("\"durationNs\":32210627000,\"parser\"", "\"durationNs\":-1,\"parser\"")], "reviewed"),
    Case("schemaFingerprintUppercase", "zlib-slices", [("\"schemaFingerprint\":\"cb34d8b6", "\"schemaFingerprint\":\"CB34d8b6")], "reviewed"),
    Case("parserName", "zlib-slices", [("\"name\":\"trace_streamer\"", "\"name\":\"trace_streames\"")], "reviewed"),
    Case("parserBinary", "zlib-slices", [("\"binarySha256\":\"7c5ed515", "\"binarySha256\":\"7c5ed516")], "reviewed"),
    Case("databaseDigestUppercase", "zlib-slices", [("\"upstreamDatabaseSha256\":\"a4816d67", "\"upstreamDatabaseSha256\":\"A4816d67")], "reviewed"),
    Case("databaseNegativeBytes", "zlib-slices", [("\"upstreamDatabaseByteCount\":917504", "\"upstreamDatabaseByteCount\":-1")], "reviewed"),
    Case("parserAdapter", "zlib-slices", [("\"parserAdapterVersion\":\"1\"", "\"parserAdapterVersion\":\"2\"")], "reviewed"),
    Case("requestCommand", "zlib-slices", [("\"command\":\"analyze\"", "\"command\":\"context\"")], "reviewed"),
    Case("requestExtraParameter", "zlib-slices", [("\"parameters\":{\"counterFilterID\"", "\"parameters\":{\"aaa\":null,\"counterFilterID\"")], "reviewed"),
    Case("requestKind", "zlib-slices", [("\"kind\":\"slices\",\"limit\"", "\"kind\":\"cpu\",\"limit\"")], "reviewed"),
    Case("requestThreshold", "zlib-slices", [("\"thresholdNs\":1000000,\"tid\"", "\"thresholdNs\":1000001,\"tid\"")], "reviewed"),
    Case("requestNameMatch", "zlib-slices", [("\"nameMatch\":\"exact\"", "\"nameMatch\":\"prefix\"")], "reviewed"),
    Case("requestCpuFilter", "zlib-slices", [("\"parameters\":{\"counterFilterID\":null,\"cpu\":null", "\"parameters\":{\"counterFilterID\":null,\"cpu\":0")], "reviewed"),
    Case("requestEndNs", "zlib-slices", [("\"endNs\":32210627000,\"kind\"", "\"endNs\":32210626999,\"kind\"")], "reviewed"),
    Case("qualityStatus", "zlib-slices", [("{\"dataQuality\":{\"status\":\"warnings\"", "{\"dataQuality\":{\"status\":\"ok\"")], "reviewed"),
    Case("qualityCategory", "zlib-slices", [("\"category\":\"droppedValue\"", "\"category\":\"droppedValues\""), ("\"category\":\"droppedValue\"", "\"category\":\"droppedValues\"")], "reviewed"),
    Case("qualityScope", "zlib-slices", [("\"scope\":\"stat.stat_type\"", "\"scope\":\"stat.other\""), ("\"scope\":\"stat.stat_type\"", "\"scope\":\"stat.other\"")], "reviewed"),
    Case("qualityMessage", "zlib-slices", [("\"message\":null", "\"message\":\"x\""), ("\"message\":null", "\"message\":\"x\"")], "reviewed"),
    Case("qualityOrder", "zlib-slices", [("{\"category\":\"droppedValue\",\"count\":416", "{\"category\":\"unavailableValue\",\"count\":416"), ("{\"category\":\"droppedValue\",\"count\":416", "{\"category\":\"unavailableValue\",\"count\":416")], "reviewed"),
    Case("qualityDuplicate", "zlib-slices", [("\"scope\":\"callstack.cookie\"},{\"category\":\"probeTruncated\",\"count\":null,\"message\":null,\"scope\":\"callstack.depth\"}", "\"scope\":\"callstack.cookie\"},{\"category\":\"probeTruncated\",\"count\":null,\"message\":null,\"scope\":\"callstack.cookie\"}"), ("\"scope\":\"callstack.cookie\"},{\"category\":\"probeTruncated\",\"count\":null,\"message\":null,\"scope\":\"callstack.depth\"}", "\"scope\":\"callstack.cookie\"},{\"category\":\"probeTruncated\",\"count\":null,\"message\":null,\"scope\":\"callstack.cookie\"}")], "reviewed"),
    Case("qualityNegativeCount", "zlib-slices", [("\"count\":416,", "\"count\":-416,"), ("\"count\":416,", "\"count\":-416,")], "reviewed"),
    Case("innerQualityDiffers", "zlib-slices", [("\"cpuUtilization\":[],\"dataQuality\":{\"status\":\"warnings\",\"warnings\":[{\"category\":\"droppedValue\",\"count\":416", "\"cpuUtilization\":[],\"dataQuality\":{\"status\":\"warnings\",\"warnings\":[{\"category\":\"droppedValue\",\"count\":417")], "reviewed"),
    Case("truncationUnsorted", "zlib-slices", [("\"truncation\":{\"sections\":[\"hotIntervals\",\"longSlices\"]", "\"truncation\":{\"sections\":[\"longSlices\",\"hotIntervals\"]")], "reviewed"),
    Case("truncationFlag", "zlib-slices", [("\"truncation\":{\"sections\":[\"hotIntervals\",\"longSlices\"],\"truncated\":true}", "\"truncation\":{\"sections\":[\"hotIntervals\",\"longSlices\"],\"truncated\":false}")], "reviewed"),
    Case("truncationExtraSection", "zlib-slices", [("\"truncation\":{\"sections\":[\"hotIntervals\",\"longSlices\"]", "\"truncation\":{\"sections\":[\"hotIntervals\",\"longSlices\",\"topThreads\"]")], "reviewed"),
    Case("resultKind", "zlib-slices", [("\"kind\":\"slices\"},\"schemaVersion\"", "\"kind\":\"cpu\"},\"schemaVersion\"")], "reviewed"),
    Case("analysisKind", "zlib-slices", [("\"kind\":\"deterministicBatch\"", "\"kind\":\"deterministicBatcH\"")], "reviewed"),
    Case("analysisRange", "zlib-slices", [("\"range\":{\"endNs\":32210627000,\"startNs\":0}", "\"range\":{\"endNs\":32210627001,\"startNs\":0}")], "reviewed"),
    Case("maximumCPUSlices", "zlib-slices", [("\"maximumCPUSlices\":10000", "\"maximumCPUSlices\":10001")], "reviewed"),
    Case("topProcessLimit", "zlib-slices", [("\"topProcessLimit\":10", "\"topProcessLimit\":11")], "reviewed"),
    Case("hotBucketCount", "zlib-slices", [("\"hotBucketCount\":100", "\"hotBucketCount\":99")], "reviewed"),
    Case("timeoutAttoseconds", "zlib-slices", [("\"timeoutAttoseconds\":0", "\"timeoutAttoseconds\":1")], "reviewed"),
    Case("timeoutSeconds", "zlib-slices", [("\"timeoutSeconds\":30", "\"timeoutSeconds\":31")], "reviewed"),
    Case("parameterFilterPid", "zlib-slices", [("\"parameters\":{\"filters\":{\"counterFilterID\":null,\"cpu\":null,\"depth\":null,\"minimumDurationNs\":null,\"name\":null,\"nameMatch\":\"exact\",\"normalizedState\":null,\"pid\":null", "\"parameters\":{\"filters\":{\"counterFilterID\":null,\"cpu\":null,\"depth\":null,\"minimumDurationNs\":null,\"name\":null,\"nameMatch\":\"exact\",\"normalizedState\":null,\"pid\":5")], "reviewed"),
    Case("longSliceTooShort", "zlib-slices", [("\"range\":{\"endNs\":32210627000,\"startNs\":5967033000}", "\"range\":{\"endNs\":32210627000,\"startNs\":32210000000}")], "reviewed"),
    Case("longSliceEmptyName", "zlib-slices", [("\"name\":\"H:ScreenLock:TracehidePsdPage\"", "\"name\":\"\"")], "reviewed"),
    Case("longSliceZeroKey", "zlib-slices", [("\"processKey\":{\"ipid\":19}", "\"processKey\":{\"ipid\":0}")], "reviewed"),
    Case("longSliceControlName", "zlib-slices", [("\"name\":\"H:ScreenLock:TracehidePsdPage\"", "\"name\":\"H:Screen\\u0007Lock\"")], "reviewed"),
    Case("longSliceFormatName", "zlib-slices", [("\"name\":\"H:ScreenLock:TracehidePsdPage\"", "\"name\":\"H:Screen\\u200bLock\"")], "reviewed"),
    Case("longSliceNamedByPath", "zlib-slices", [("\"name\":\"H:ScreenLock:TracehidePsdPage\"", "\"name\":\"H:/Users/someone/trace\"")], "reviewed"),
    Case("longSliceNamedByFileURI", "zlib-slices", [("\"name\":\"H:ScreenLock:TracehidePsdPage\"", "\"name\":\"see file:///tmp/x\"")], "reviewed"),
    Case("kelvinKey", "zlib-slices", [("\"processKey\":{\"ipid\":19}", "\"process\\u212Aey\":{\"ipid\":19}")], "reviewed"),
    Case("kelvinKeyDuplicate", "zlib-slices", [("\"processKey\":{\"ipid\":19},\"processName\"", "\"processKey\":{\"ipid\":19},\"process\\u212Aey\":{\"ipid\":19},\"processName\"")], "reviewed"),
    Case("kelvinEnum", "zlib-slices", [("\"unsupportedReason\":\"capabilityUnavailable\"", "\"unsupportedReason\":\"capabilityUnavailable\\u0301\"")], "reviewed"),
    Case("hotIntervalTotal", "zlib-slices", [("\"longSliceNs\":3245327889,\"total\":3245327889", "\"longSliceNs\":3245327889,\"total\":3245327890")], "reviewed"),
    Case("hotIntervalSwitchScore", "zlib-slices", [("\"contextSwitchCount\":0,\"contextSwitchScoreNs\":0,\"cpuBusyNs\":0,\"longSliceNs\":3245327889", "\"contextSwitchCount\":1,\"contextSwitchScoreNs\":0,\"cpuBusyNs\":0,\"longSliceNs\":3245327889")], "reviewed"),
    Case("hotIntervalSwitches", "zlib-slices", [("\"contextSwitchCount\":0,\"contextSwitchScoreNs\":0,\"cpuBusyNs\":0,\"longSliceNs\":3245327889,\"total\":3245327889", "\"contextSwitchCount\":2,\"contextSwitchScoreNs\":2000000,\"cpuBusyNs\":0,\"longSliceNs\":3245327889,\"total\":3247327889")], "reviewed"),
    Case("hotIntervalOutside", "zlib-slices", [("\"range\":{\"endNs\":14816888420,\"startNs\":14494782150}", "\"range\":{\"endNs\":32210627001,\"startNs\":14494782150}")], "reviewed"),
    Case("sectionReturnedCount", "zlib-slices", [("\"longSlices\":{\"matchedCount\":1031,\"returnedCount\":10", "\"longSlices\":{\"matchedCount\":1031,\"returnedCount\":9")], "reviewed"),
    Case("sectionMatchedNullUntruncated", "zlib-slices", [("\"cpuUtilization\":{\"matchedCount\":0,\"returnedCount\":0,\"truncated\":false}", "\"cpuUtilization\":{\"matchedCount\":null,\"returnedCount\":0,\"truncated\":false}")], "reviewed"),
    Case("cpuSectionAggregates", "zlib-slices", [("\"cpuUtilization\":{\"matchedCount\":0,\"returnedCount\":0,\"truncated\":false}", "\"cpuUtilization\":{\"matchedCount\":5,\"returnedCount\":0,\"truncated\":false}")], "reviewed"),
    Case("processSectionDoesNotAggregate", "zlib-slices", [("\"topProcesses\":{\"matchedCount\":0,\"returnedCount\":0,\"truncated\":false}", "\"topProcesses\":{\"matchedCount\":5,\"returnedCount\":0,\"truncated\":false}")], "reviewed"),
    Case("sectionMatchedBelowReturned", "zlib-slices", [("\"longSlices\":{\"matchedCount\":1031,\"returnedCount\":10", "\"longSlices\":{\"matchedCount\":9,\"returnedCount\":10")], "reviewed"),
    Case("schedulingReason", "zlib-slices", [("\"unsupportedReason\":\"capabilityUnavailable\"", "\"unsupportedReason\":\"other\"")], "reviewed"),
    Case("schedulingUnsupportedCount", "zlib-slices", [("\"schedulingLatency\":{\"count\":0,\"percentiles\":null,\"supported\":false", "\"schedulingLatency\":{\"count\":1,\"percentiles\":null,\"supported\":false")], "reviewed"),
    Case("schedulingUnsupportedPercentiles", "zlib-slices", [("\"schedulingLatency\":{\"count\":0,\"percentiles\":null,\"supported\":false", "\"schedulingLatency\":{\"count\":0,\"percentiles\":{\"maxNs\":1,\"p50Ns\":1,\"p90Ns\":1,\"p95Ns\":1,\"p99Ns\":1},\"supported\":false")], "reviewed"),
    Case("sourceStringInOutput", "zlib-slices", [], "sourcePathInOutput"),
    Case("cpuOccupied", "systrace-cpu", [("\"occupiedNs\":3948856000,\"rawRunningNs\":3948856000", "\"occupiedNs\":3948855999,\"rawRunningNs\":3948856000")], "reviewed"),
    Case("cpuUtilizationWithinTolerance", "systrace-cpu", [("\"utilization\":0.43261176887150055", "\"utilization\":0.4326117688715006")], "reviewed"),
    Case("cpuUtilizationBeyondTolerance", "systrace-cpu", [("\"utilization\":0.43261176887150055", "\"utilization\":0.4326117688716")], "reviewed"),
    Case("cpuUtilizationInteger", "systrace-cpu", [("\"utilization\":0.43261176887150055", "\"utilization\":1")], "reviewed"),
    Case("processShare", "systrace-cpu", [("\"shareOfOneCPU\":0.1723626919709411", "\"shareOfOneCPU\":0.17236269197")], "reviewed"),
    Case("processShareFarOff", "systrace-cpu", [("\"shareOfOneCPU\":0.1723626919709411", "\"shareOfOneCPU\":0.1723")], "reviewed"),
    Case("cpuUtilizationFarOff", "systrace-cpu", [("\"utilization\":0.43261176887150055", "\"utilization\":0.4326117")], "reviewed"),
    Case("processShareString", "systrace-cpu", [("\"shareOfOneCPU\":0.1723626919709411", "\"shareOfOneCPU\":\"0.1723626919709411\"")], "reviewed"),
    Case("threadShare", "systrace-cpu", [("\"shareOfOneCPU\":0.1675732234991801", "\"shareOfOneCPU\":0.16757")], "reviewed"),
    Case("stateUnknownNormalized", "systrace-cpu", [("\"normalizedState\":\"runnable\",\"percentageOfRange\"", "\"normalizedState\":\"waiting\",\"percentageOfRange\"")], "reviewed"),
    Case("statePercentage", "systrace-cpu", [("\"percentageOfRange\":2.0815202196683065e-06", "\"percentageOfRange\":2.08e-06")], "reviewed"),
    Case("stateDurationBeyondRange", "systrace-cpu", [("\"durationNs\":19000,\"intervalCount\":1,\"normalizedState\":\"runnable\",\"percentageOfRange\":2.0815202196683065e-06", "\"durationNs\":9127944001,\"intervalCount\":1,\"normalizedState\":\"runnable\",\"percentageOfRange\":1.0000000001095538")], "reviewed"),
    Case("percentilesUnordered", "systrace-cpu", [("\"p50Ns\":26000,\"p90Ns\":76000", "\"p50Ns\":86000,\"p90Ns\":76000")], "reviewed"),
    Case("percentilesExtra", "systrace-cpu", [("\"p99Ns\":221000}", "\"p99Ns\":221000,\"p999Ns\":1}")], "reviewed"),
    Case("schedulingSupportedWithReason", "systrace-cpu", [("\"truncated\":true,\"unsupportedReason\":null}", "\"truncated\":true,\"unsupportedReason\":\"capabilityUnavailable\"}")], "reviewed"),
    Case("schedulingSampleBeyondRows", "systrace-scheduling", [("\"topSamples\":[]", "\"topSamples\":[{\"latencyNs\":5000,\"runnableEndNs\":1500000000,\"runnableEventKey\":{\"rowID\":1,\"table\":\"thread_state\"},\"runningEventKey\":{\"rowID\":2,\"table\":\"sched_slice\"},\"runningStartNs\":1500000000,\"threadKey\":{\"itid\":39}}]"), ("\"schedulingLatency\":{\"matchedCount\":2558,\"returnedCount\":0", "\"schedulingLatency\":{\"matchedCount\":2558,\"returnedCount\":1")], "reviewed"),
    Case("schedulingSample", "systrace-scheduling", [(",{\"cpu\":3,\"occupiedNs\":1000000000,\"rawRunningNs\":1000000000,\"sliceCount\":1331,\"utilization\":1}]", "]"), ("\"cpuUtilization\":{\"matchedCount\":4875,\"returnedCount\":4", "\"cpuUtilization\":{\"matchedCount\":4875,\"returnedCount\":3"), ("\"topSamples\":[]", "\"topSamples\":[{\"latencyNs\":5000,\"runnableEndNs\":1500000000,\"runnableEventKey\":{\"rowID\":1,\"table\":\"thread_state\"},\"runningEventKey\":{\"rowID\":2,\"table\":\"sched_slice\"},\"runningStartNs\":1500000000,\"threadKey\":{\"itid\":39}}]"), ("\"schedulingLatency\":{\"matchedCount\":2558,\"returnedCount\":0", "\"schedulingLatency\":{\"matchedCount\":2558,\"returnedCount\":1")], "reviewed"),
    Case("schedulingSampleStartsLater", "systrace-scheduling", [(",{\"cpu\":3,\"occupiedNs\":1000000000,\"rawRunningNs\":1000000000,\"sliceCount\":1331,\"utilization\":1}]", "]"), ("\"cpuUtilization\":{\"matchedCount\":4875,\"returnedCount\":4", "\"cpuUtilization\":{\"matchedCount\":4875,\"returnedCount\":3"), ("\"topSamples\":[]", "\"topSamples\":[{\"latencyNs\":5000,\"runnableEndNs\":1500000000,\"runnableEventKey\":{\"rowID\":1,\"table\":\"thread_state\"},\"runningEventKey\":{\"rowID\":2,\"table\":\"sched_slice\"},\"runningStartNs\":1500000001,\"threadKey\":{\"itid\":39}}]"), ("\"schedulingLatency\":{\"matchedCount\":2558,\"returnedCount\":0", "\"schedulingLatency\":{\"matchedCount\":2558,\"returnedCount\":1")], "reviewed"),
    Case("schedulingSampleLatency", "systrace-scheduling", [(",{\"cpu\":3,\"occupiedNs\":1000000000,\"rawRunningNs\":1000000000,\"sliceCount\":1331,\"utilization\":1}]", "]"), ("\"cpuUtilization\":{\"matchedCount\":4875,\"returnedCount\":4", "\"cpuUtilization\":{\"matchedCount\":4875,\"returnedCount\":3"), ("\"topSamples\":[]", "\"topSamples\":[{\"latencyNs\":500000001,\"runnableEndNs\":1500000000,\"runnableEventKey\":{\"rowID\":1,\"table\":\"thread_state\"},\"runningEventKey\":{\"rowID\":2,\"table\":\"sched_slice\"},\"runningStartNs\":1500000000,\"threadKey\":{\"itid\":39}}]"), ("\"schedulingLatency\":{\"matchedCount\":2558,\"returnedCount\":0", "\"schedulingLatency\":{\"matchedCount\":2558,\"returnedCount\":1")], "reviewed"),
    Case("schedulingSampleBeforeRange", "systrace-scheduling", [(",{\"cpu\":3,\"occupiedNs\":1000000000,\"rawRunningNs\":1000000000,\"sliceCount\":1331,\"utilization\":1}]", "]"), ("\"cpuUtilization\":{\"matchedCount\":4875,\"returnedCount\":4", "\"cpuUtilization\":{\"matchedCount\":4875,\"returnedCount\":3"), ("\"topSamples\":[]", "\"topSamples\":[{\"latencyNs\":5000,\"runnableEndNs\":999999999,\"runnableEventKey\":{\"rowID\":1,\"table\":\"thread_state\"},\"runningEventKey\":{\"rowID\":2,\"table\":\"sched_slice\"},\"runningStartNs\":999999999,\"threadKey\":{\"itid\":39}}]"), ("\"schedulingLatency\":{\"matchedCount\":2558,\"returnedCount\":0", "\"schedulingLatency\":{\"matchedCount\":2558,\"returnedCount\":1")], "reviewed"),
    Case("schedulingSampleUncounted", "systrace-scheduling", [(",{\"cpu\":3,\"occupiedNs\":1000000000,\"rawRunningNs\":1000000000,\"sliceCount\":1331,\"utilization\":1}]", "]"), ("\"cpuUtilization\":{\"matchedCount\":4875,\"returnedCount\":4", "\"cpuUtilization\":{\"matchedCount\":4875,\"returnedCount\":3"), ("\"topSamples\":[]", "\"topSamples\":[{\"latencyNs\":5000,\"runnableEndNs\":1500000000,\"runnableEventKey\":{\"rowID\":1,\"table\":\"thread_state\"},\"runningEventKey\":{\"rowID\":2,\"table\":\"sched_slice\"},\"runningStartNs\":1500000000,\"threadKey\":{\"itid\":39}}]")], "reviewed"),
    Case("schedulingSampleZeroKey", "systrace-scheduling", [(",{\"cpu\":3,\"occupiedNs\":1000000000,\"rawRunningNs\":1000000000,\"sliceCount\":1331,\"utilization\":1}]", "]"), ("\"cpuUtilization\":{\"matchedCount\":4875,\"returnedCount\":4", "\"cpuUtilization\":{\"matchedCount\":4875,\"returnedCount\":3"), ("\"topSamples\":[]", "\"topSamples\":[{\"latencyNs\":5000,\"runnableEndNs\":1500000000,\"runnableEventKey\":{\"rowID\":1,\"table\":\"thread_state\"},\"runningEventKey\":{\"rowID\":2,\"table\":\"sched_slice\"},\"runningStartNs\":1500000000,\"threadKey\":{\"itid\":0}}]"), ("\"schedulingLatency\":{\"matchedCount\":2558,\"returnedCount\":0", "\"schedulingLatency\":{\"matchedCount\":2558,\"returnedCount\":1")], "reviewed"),
    Case("schedulingSampleBeyondCount", "systrace-scheduling", [(",{\"cpu\":3,\"occupiedNs\":1000000000,\"rawRunningNs\":1000000000,\"sliceCount\":1331,\"utilization\":1}]", "]"), ("\"cpuUtilization\":{\"matchedCount\":4875,\"returnedCount\":4", "\"cpuUtilization\":{\"matchedCount\":4875,\"returnedCount\":3"), ("\"topSamples\":[]", "\"topSamples\":[{\"latencyNs\":5000,\"runnableEndNs\":1500000000,\"runnableEventKey\":{\"rowID\":1,\"table\":\"thread_state\"},\"runningEventKey\":{\"rowID\":2,\"table\":\"sched_slice\"},\"runningStartNs\":1500000000,\"threadKey\":{\"itid\":39}}]"), ("\"schedulingLatency\":{\"matchedCount\":2558,\"returnedCount\":0", "\"schedulingLatency\":{\"matchedCount\":2558,\"returnedCount\":1"), ("\"schedulingLatency\":{\"count\":2558", "\"schedulingLatency\":{\"count\":0")], "reviewed"),
    Case("contextCommand", "zlib-context-timestamp", [("\"command\":\"context\"", "\"command\":\"analyze\"")], "reviewed"),
    Case("contextWindow", "zlib-context-timestamp", [("\"windowBeforeNs\":50000000", "\"windowBeforeNs\":50000001")], "reviewed"),
    Case("contextStartEcho", "zlib-context-timestamp", [("\"parameters\":{\"counterFilterID\":null,\"cpu\":null,\"depth\":null,\"endNs\":null", "\"parameters\":{\"counterFilterID\":null,\"cpu\":null,\"depth\":null,\"endNs\":0")], "reviewed"),
    Case("contextRange", "zlib-context-timestamp", [("\"range\":{\"endNs\":16050000000,\"startNs\":15950000000},\"slices\"", "\"range\":{\"endNs\":16050000001,\"startNs\":15950000000},\"slices\"")], "reviewed"),
    Case("processDuplicateKey", "zlib-context-timestamp", [("\"key\":{\"ipid\":16}", "\"key\":{\"ipid\":39}")], "reviewed"),
    Case("processZeroKey", "zlib-context-timestamp", [("\"key\":{\"ipid\":39}", "\"key\":{\"ipid\":0}")], "reviewed"),
    Case("processWithoutPid", "zlib-context-timestamp", [("\"pid\":198,\"startNs\":12041573000", "\"pid\":null,\"startNs\":12041573000")], "reviewed"),
    Case("threadUnknownProcess", "zlib-context-timestamp", [("\"key\":{\"itid\":3},\"name\":null,\"pid\":532,\"processKey\":{\"ipid\":2}", "\"key\":{\"itid\":3},\"name\":null,\"pid\":532,\"processKey\":{\"ipid\":777}")], "reviewed"),
    Case("threadUnknownProcessOmitted", "zlib-context-timestamp", [("\"key\":{\"itid\":3},\"name\":null,\"pid\":532,\"processKey\":{\"ipid\":2}", "\"key\":{\"itid\":3},\"name\":null,\"pid\":532,\"processKey\":{\"ipid\":777}"), ("\"referenceOmittedByBudget\":false", "\"referenceOmittedByBudget\":true"), ("\"truncation\":{\"sections\":[\"processes\",\"summary\",\"threads\"]", "\"truncation\":{\"sections\":[\"processes\",\"references\",\"summary\",\"threads\"]")], "reviewed"),
    Case("referencesOmittedUndeclared", "zlib-context-timestamp", [("\"referenceOmittedByBudget\":false", "\"referenceOmittedByBudget\":true")], "reviewed"),
    Case("sliceUnknownThread", "zlib-context-timestamp", [("\"range\":{\"endNs\":32210627000,\"startNs\":5967033000},\"threadKey\":{\"itid\":27}", "\"range\":{\"endNs\":32210627000,\"startNs\":5967033000},\"threadKey\":{\"itid\":777}")], "reviewed"),
    Case("sliceEmptyName", "zlib-context-timestamp", [("\"name\":\"H:ScreenLock:TracehidePsdPage\"", "\"name\":\"\"")], "reviewed"),
    Case("sliceParentKeyWithoutRow", "zlib-context-timestamp", [("\"parentEventKey\":{\"rowID\":27,\"table\":\"callstack\"}", "\"parentEventKey\":{\"table\":\"callstack\"}")], "reviewed"),
    Case("sliceNegativeDepth", "zlib-context-timestamp", [("\"depth\":0,\"isAsync\"", "\"depth\":-1,\"isAsync\"")], "reviewed"),
    Case("sliceOutsideWindow", "zlib-context-timestamp", [("\"range\":{\"endNs\":32210627000,\"startNs\":5967033000}", "\"range\":{\"endNs\":15949999999,\"startNs\":5967033000}")], "reviewed"),
    Case("sliceInstantInWindow", "zlib-context-timestamp", [("\"range\":{\"endNs\":32210627000,\"startNs\":5967033000}", "\"range\":{\"endNs\":15950000000,\"startNs\":15950000000}")], "reviewed"),
    Case("summaryDuration", "zlib-context-timestamp", [("\"durationNs\":100000000,\"eventCountBySource\"", "\"durationNs\":100000001,\"eventCountBySource\"")], "reviewed"),
    Case("summaryFingerprint", "zlib-context-timestamp", [("\"range\":{\"endNs\":16050000000,\"startNs\":15950000000},\"schemaFingerprint\":\"cb34d8b6", "\"range\":{\"endNs\":16050000000,\"startNs\":15950000000},\"schemaFingerprint\":\"db34d8b6")], "reviewed"),
    Case("summaryProcessCount", "zlib-context-timestamp", [("\"processCount\":58", "\"processCount\":101")], "reviewed"),
    Case("summaryUnavailableCount", "zlib-context-timestamp", [("\"cpuCount\":null", "\"cpuCount\":0")], "reviewed"),
    Case("summaryAvailableCountMissing", "zlib-context-timestamp", [("\"namedSliceCount\":6", "\"namedSliceCount\":null")], "reviewed"),
    Case("summaryCapabilityExtra", "zlib-context-timestamp", [("\"capabilities\":{\"cpuCounters\"", "\"capabilities\":{\"aaa\":true,\"cpuCounters\"")], "reviewed"),
    Case("summaryEventSources", "zlib-context-timestamp", [("\"eventCountBySource\":null", "\"eventCountBySource\":[{\"count\":1,\"source\":\"a\"},{\"count\":2,\"source\":\"b\"}]")], "reviewed"),
    Case("summaryEventSourcesUnsorted", "zlib-context-timestamp", [("\"eventCountBySource\":null", "\"eventCountBySource\":[{\"count\":1,\"source\":\"b\"},{\"count\":2,\"source\":\"a\"}]")], "reviewed"),
    Case("summaryEventSourcesDuplicate", "zlib-context-timestamp", [("\"eventCountBySource\":null", "\"eventCountBySource\":[{\"count\":1,\"source\":\"a\"},{\"count\":2,\"source\":\"a\"}]")], "reviewed"),
    Case("summaryEventSourcesNegative", "zlib-context-timestamp", [("\"eventCountBySource\":null", "\"eventCountBySource\":[{\"count\":-1,\"source\":\"a\"}]")], "reviewed"),
    Case("summaryEventSourcesBell", "zlib-context-timestamp", [("\"eventCountBySource\":null", "\"eventCountBySource\":[{\"count\":1,\"source\":\"a\\u0007\"}]")], "reviewed"),
    Case("summaryEventSourcesUTF8Order", "zlib-context-timestamp", [("\"eventCountBySource\":null", "\"eventCountBySource\":[{\"count\":1,\"source\":\"\\u00e9\"},{\"count\":2,\"source\":\"\\uff21\"}]")], "reviewed"),
    Case("summaryTruncatedOrder", "zlib-context-timestamp", [("\"truncatedSections\":[\"processCount\",\"threadCount\"]", "\"truncatedSections\":[\"threadCount\",\"processCount\"]")], "reviewed"),
    Case("summaryTruncatedUnavailable", "zlib-context-timestamp", [("\"truncatedSections\":[\"processCount\",\"threadCount\"]", "\"truncatedSections\":[\"cpuCount\",\"processCount\",\"threadCount\"]")], "reviewed"),
    Case("summaryQualityNotSubset", "zlib-context-timestamp", [("{\"category\":\"unavailableValue\",\"count\":99,\"message\":null,\"scope\":\"thread.start_ts\"}]},\"durationNs\"", "{\"category\":\"unavailableValue\",\"count\":98,\"message\":null,\"scope\":\"thread.start_ts\"}]},\"durationNs\"")], "reviewed"),
    Case("contextTruncationReturned", "zlib-context-timestamp", [("\"slices\":{\"matchedCount\":6,\"returnedCount\":6", "\"slices\":{\"matchedCount\":6,\"returnedCount\":5")], "reviewed"),
    Case("contextTruncationMatched", "zlib-context-timestamp", [("\"processes\":{\"matchedCount\":100,\"returnedCount\":95", "\"processes\":{\"matchedCount\":94,\"returnedCount\":95")], "reviewed"),
    Case("contextTruncationMissing", "zlib-context-timestamp", [("\"referenceOmittedByBudget\":false,", "")], "reviewed"),
    Case("contextSummaryUntruncated", "zlib-context-timestamp", [("\"summary\":{\"matchedCount\":1,\"returnedCount\":1,\"truncated\":true}", "\"summary\":{\"matchedCount\":1,\"returnedCount\":1,\"truncated\":false}")], "reviewed"),
    Case("counterSeries", "zlib-context-timestamp", [("\"counters\":[]", "\"counters\":[{\"cpu\":null,\"filterID\":7,\"name\":\"mem\",\"pid\":198,\"processKey\":{\"ipid\":39},\"processName\":null,\"samples\":[{\"durationNs\":null,\"key\":{\"rowID\":1,\"table\":\"measure\"},\"timestampNs\":15960000000,\"value\":5}],\"scope\":\"process\",\"unit\":null}]"), ("\"processCounters\":false", "\"processCounters\":true"), ("\"counterSeriesCount\":null", "\"counterSeriesCount\":1"), ("\"counters\":{\"matchedCount\":0,\"returnedCount\":0,\"truncated\":false}", "\"counters\":{\"matchedCount\":1,\"returnedCount\":1,\"truncated\":false}")], "reviewed"),
    Case("counterCarryIn", "zlib-context-timestamp", [("\"counters\":[]", "\"counters\":[{\"cpu\":null,\"filterID\":7,\"name\":\"mem\",\"pid\":198,\"processKey\":{\"ipid\":39},\"processName\":null,\"samples\":[{\"durationNs\":20000000,\"key\":{\"rowID\":2,\"table\":\"measure\"},\"timestampNs\":15940000000,\"value\":4},{\"durationNs\":null,\"key\":{\"rowID\":1,\"table\":\"measure\"},\"timestampNs\":15960000000,\"value\":5}],\"scope\":\"process\",\"unit\":null}]"), ("\"processCounters\":false", "\"processCounters\":true"), ("\"counterSeriesCount\":null", "\"counterSeriesCount\":1"), ("\"counters\":{\"matchedCount\":0,\"returnedCount\":0,\"truncated\":false}", "\"counters\":{\"matchedCount\":2,\"returnedCount\":2,\"truncated\":false}")], "reviewed"),
    Case("counterTwoCarryIns", "zlib-context-timestamp", [("\"counters\":[]", "\"counters\":[{\"cpu\":null,\"filterID\":7,\"name\":\"mem\",\"pid\":198,\"processKey\":{\"ipid\":39},\"processName\":null,\"samples\":[{\"durationNs\":20000000,\"key\":{\"rowID\":3,\"table\":\"measure\"},\"timestampNs\":15945000000,\"value\":3},{\"durationNs\":20000000,\"key\":{\"rowID\":2,\"table\":\"measure\"},\"timestampNs\":15940000000,\"value\":4},{\"durationNs\":null,\"key\":{\"rowID\":1,\"table\":\"measure\"},\"timestampNs\":15960000000,\"value\":5}],\"scope\":\"process\",\"unit\":null}]"), ("\"processCounters\":false", "\"processCounters\":true"), ("\"counterSeriesCount\":null", "\"counterSeriesCount\":1"), ("\"counters\":{\"matchedCount\":0,\"returnedCount\":0,\"truncated\":false}", "\"counters\":{\"matchedCount\":3,\"returnedCount\":3,\"truncated\":false}")], "reviewed"),
    Case("counterBareBeforeWindow", "zlib-context-timestamp", [("\"counters\":[]", "\"counters\":[{\"cpu\":null,\"filterID\":7,\"name\":\"mem\",\"pid\":198,\"processKey\":{\"ipid\":39},\"processName\":null,\"samples\":[{\"durationNs\":null,\"key\":{\"rowID\":4,\"table\":\"measure\"},\"timestampNs\":15940000000,\"value\":2},{\"durationNs\":null,\"key\":{\"rowID\":1,\"table\":\"measure\"},\"timestampNs\":15960000000,\"value\":5}],\"scope\":\"process\",\"unit\":null}]"), ("\"processCounters\":false", "\"processCounters\":true"), ("\"counterSeriesCount\":null", "\"counterSeriesCount\":1"), ("\"counters\":{\"matchedCount\":0,\"returnedCount\":0,\"truncated\":false}", "\"counters\":{\"matchedCount\":2,\"returnedCount\":2,\"truncated\":false}")], "reviewed"),
    Case("counterWithoutCapability", "zlib-context-timestamp", [("\"counters\":[]", "\"counters\":[{\"cpu\":null,\"filterID\":7,\"name\":\"mem\",\"pid\":198,\"processKey\":{\"ipid\":39},\"processName\":null,\"samples\":[{\"durationNs\":null,\"key\":{\"rowID\":1,\"table\":\"measure\"},\"timestampNs\":15960000000,\"value\":5}],\"scope\":\"process\",\"unit\":null}]"), ("\"counterSeriesCount\":null", "\"counterSeriesCount\":1"), ("\"counters\":{\"matchedCount\":0,\"returnedCount\":0,\"truncated\":false}", "\"counters\":{\"matchedCount\":1,\"returnedCount\":1,\"truncated\":false}")], "reviewed"),
    Case("counterUncounted", "zlib-context-timestamp", [("\"counters\":[]", "\"counters\":[{\"cpu\":null,\"filterID\":7,\"name\":\"mem\",\"pid\":198,\"processKey\":{\"ipid\":39},\"processName\":null,\"samples\":[{\"durationNs\":null,\"key\":{\"rowID\":1,\"table\":\"measure\"},\"timestampNs\":15960000000,\"value\":5}],\"scope\":\"process\",\"unit\":null}]"), ("\"processCounters\":false", "\"processCounters\":true"), ("\"counterSeriesCount\":null", "\"counterSeriesCount\":1"), ("\"counters\":{\"matchedCount\":0,\"returnedCount\":0,\"truncated\":false}", "\"counters\":{\"matchedCount\":0,\"returnedCount\":0,\"truncated\":false}")], "reviewed"),
    Case("counterCpuScopeWithProcess", "zlib-context-timestamp", [("\"counters\":[]", "\"counters\":[{\"cpu\":null,\"filterID\":7,\"name\":\"mem\",\"pid\":198,\"processKey\":{\"ipid\":39},\"processName\":null,\"samples\":[{\"durationNs\":null,\"key\":{\"rowID\":1,\"table\":\"measure\"},\"timestampNs\":15960000000,\"value\":5}],\"scope\":\"cpu\",\"unit\":null}]"), ("\"processCounters\":false", "\"processCounters\":true"), ("\"counterSeriesCount\":null", "\"counterSeriesCount\":1"), ("\"counters\":{\"matchedCount\":0,\"returnedCount\":0,\"truncated\":false}", "\"counters\":{\"matchedCount\":1,\"returnedCount\":1,\"truncated\":false}")], "reviewed"),
    Case("counterUnknownProcess", "zlib-context-timestamp", [("\"counters\":[]", "\"counters\":[{\"cpu\":null,\"filterID\":7,\"name\":\"mem\",\"pid\":198,\"processKey\":{\"ipid\":777},\"processName\":null,\"samples\":[{\"durationNs\":null,\"key\":{\"rowID\":1,\"table\":\"measure\"},\"timestampNs\":15960000000,\"value\":5}],\"scope\":\"process\",\"unit\":null}]"), ("\"processCounters\":false", "\"processCounters\":true"), ("\"counterSeriesCount\":null", "\"counterSeriesCount\":1"), ("\"counters\":{\"matchedCount\":0,\"returnedCount\":0,\"truncated\":false}", "\"counters\":{\"matchedCount\":1,\"returnedCount\":1,\"truncated\":false}")], "reviewed"),
    Case("counterAfterWindow", "zlib-context-timestamp", [("\"counters\":[]", "\"counters\":[{\"cpu\":null,\"filterID\":7,\"name\":\"mem\",\"pid\":198,\"processKey\":{\"ipid\":39},\"processName\":null,\"samples\":[{\"durationNs\":null,\"key\":{\"rowID\":1,\"table\":\"measure\"},\"timestampNs\":16050000000,\"value\":5}],\"scope\":\"process\",\"unit\":null}]"), ("\"processCounters\":false", "\"processCounters\":true"), ("\"counterSeriesCount\":null", "\"counterSeriesCount\":1"), ("\"counters\":{\"matchedCount\":0,\"returnedCount\":0,\"truncated\":false}", "\"counters\":{\"matchedCount\":1,\"returnedCount\":1,\"truncated\":false}")], "reviewed"),
    Case("cpuSliceOutsideWindow", "systrace-context-timestamp", [("\"range\":{\"endNs\":4499705000,\"startNs\":4455505000}", "\"range\":{\"endNs\":4449999999,\"startNs\":4400000000}")], "reviewed"),
    Case("cpuSliceNegativeCpu", "systrace-context-timestamp", [("\"cpuSlices\":[{\"cpu\":0", "\"cpuSlices\":[{\"cpu\":-1")], "reviewed"),
    Case("cpuSliceStringPriority", "systrace-context-timestamp", [("\"priority\":120", "\"priority\":\"120\"")], "reviewed"),
    Case("threadStateNormalized", "systrace-context-timestamp", [("\"normalizedState\":\"sleeping\",\"pid\":3873", "\"normalizedState\":\"dozing\",\"pid\":3873")], "reviewed"),
    Case("threadStateWithoutThread", "systrace-context-timestamp", [("\"state\":\"S\",\"threadKey\":{\"itid\":63}", "\"state\":\"S\",\"threadKey\":null")], "reviewed"),
    Case("threadStatesWithoutCapability", "systrace-context-timestamp", [("\"processCounters\":false,\"threadStates\":true", "\"processCounters\":false,\"threadStates\":false")], "reviewed"),
    Case("cpuSliceCountBeyondEvents", "systrace-context-timestamp", [("\"cpuSliceCount\":150", "\"cpuSliceCount\":151")], "reviewed"),
    Case("contextRowsBeyondMaxRows", "systrace-context-timestamp", [("\"processes\":{\"matchedCount\":51,\"returnedCount\":39", "\"processes\":{\"matchedCount\":51,\"returnedCount\":40"), ("\"processes\":[{\"endNs\":null,\"key\":{\"ipid\":42}", "\"processes\":[{\"endNs\":null,\"key\":{\"ipid\":9999},\"name\":null,\"pid\":1,\"startNs\":null,\"threadCount\":0},{\"endNs\":null,\"key\":{\"ipid\":42}")], "reviewed"),
    Case("filterProcessKey", "systrace-context-range", [("\"processKey\":{\"ipid\":1},\"rawState\"", "\"processKey\":{\"ipid\":2},\"rawState\"")], "reviewed"),
    Case("requestProcessKey", "systrace-context-range", [("\"processKey\":1,", "\"processKey\":2,")], "reviewed"),
    Case("rangeEcho", "systrace-context-range", [("\"endNs\":2010000000,\"minimumDurationNs\"", "\"endNs\":2010000001,\"minimumDurationNs\"")], "reviewed"),
    Case("filterPid", "systrace-pid", [("\"pid\":1,\"processKey\":null,\"rawState\"", "\"pid\":2,\"processKey\":null,\"rawState\"")], "reviewed"),
    Case("requestPid", "systrace-pid", [("\"pid\":1,\"processKey\":null,\"rawState\":null,\"startNs\"", "\"pid\":null,\"processKey\":null,\"rawState\":null,\"startNs\"")], "reviewed"),
    Case("unsupportedNoTransitions", "systrace-pid", [("\"unsupportedReason\":\"noProvableRunnableTransitions\"", "\"unsupportedReason\":\"capabilityUnavailable\"")], "reviewed"),
    Case("normalizedStartEcho", "systrace-slices", [("\"startNs\":2950000000,\"threadKey\"", "\"startNs\":2950000001,\"threadKey\"")], "reviewed"),
  ]

  private struct Base {
    let bytes: Data
    let inputs: [String: JSONValue]
    let sourceSHA256: String
    let sourceByteCount: Int
  }

  private static func bases() throws -> [String: Base] {
    let requests = try JSONDecoder().decode(
      [String: JSONValue].self,
      from: Data(contentsOf: oracle.appending(path: "requests.json")))
    var result: [String: Base] = [:]
    for (name, value) in requests {
      guard case .object(let fields) = value, case .object(let inputs)? = fields["inputs"],
        case .string(let sha)? = fields["sourceSHA256"],
        case .integer(let count)? = fields["sourceByteCount"]
      else { throw CocoaError(.coderInvalidValue) }
      result[name] = Base(
        bytes: try Data(contentsOf: oracle.appending(path: "reviewed/\(name).json")),
        inputs: inputs, sourceSHA256: sha, sourceByteCount: Int(count))
    }
    return result
  }

  private static func edited(_ bytes: Data, _ edits: [(String, String)]) throws -> Data {
    var text = String(decoding: bytes, as: UTF8.self)
    for (find, replace) in edits {
      guard let range = text.range(of: find) else { throw CocoaError(.coderInvalidValue) }
      text.replaceSubrange(range, with: replace)
    }
    return Data(text.utf8)
  }

  private static func invocation(_ variant: String, base: Base) throws -> AnalyzerInvocation {
    var inputs = base.inputs
    switch variant {
    case "smallBudget": inputs["maxOutputBytes"] = .integer(4_096)
    case "requestLimitMismatch":
      if case .integer(let limit)? = inputs["limit"] {
        inputs["limit"] = .integer(limit + 1)
      } else {
        inputs["limit"] = .integer(1)
      }
    default: break
    }
    let request = try AnalyzerProvider.analysisRequest(inputs)
    var sourcePath = Self.sourcePath
    if variant == "sourcePathInOutput" { sourcePath = "H:ScreenLock" }
    if variant == "emptySourcePath" { sourcePath = "" }
    var arguments = request.arguments(sourcePath: sourcePath)
    if variant == "argumentsMismatch" { arguments.insert("--verbose", at: 1) }
    var sourceSHA256 = base.sourceSHA256
    if variant == "uppercaseSource" { sourceSHA256 = sourceSHA256.uppercased() }
    if variant == "otherSource" { sourceSHA256 = String(repeating: "a", count: 64) }
    var sourceByteCount = base.sourceByteCount
    if variant == "zeroByteCount" { sourceByteCount = 0 }
    if variant == "otherByteCount" { sourceByteCount += 1 }
    return AnalyzerInvocation(
      analyzerRef: variant == "summaryAnalyzer" ? "trace-summary@1" : "trace-analysis@1",
      analyzerVersion: "0.1.0+1",
      executableSHA256: variant == "otherExecutable"
        ? String(repeating: "b", count: 64) : Self.executableSHA256,
      arguments: arguments,
      timeoutSeconds: request.processTimeoutSeconds + (variant == "timeoutMismatch" ? 1 : 0),
      outputByteBudget: request.maxOutputBytes - (variant == "budgetMismatch" ? 1 : 0),
      sourceArtifactID: "ART-SOURCE", sourceSHA256: sourceSHA256,
      sourceByteCount: sourceByteCount,
      arkTraceAnalysisRequest: variant == "noRequest" ? nil : request,
      arkTraceAnalysisContract: variant == "noContract" ? nil : Self.contract)
  }

  static func projection(_ request: ArkTraceAnalysisRequest) -> JSONValue {
    func optional(_ value: Int64?) -> JSONValue { value.map { .integer($0) } ?? .null }
    return .object([
      "kind": .string(request.kind.rawValue),
      "timestampNs": optional(request.timestampNs),
      "startNs": optional(request.startNs),
      "endNs": optional(request.endNs),
      "processKey": optional(request.processKey),
      "pid": optional(request.pid),
      "threadKey": optional(request.threadKey),
      "tid": optional(request.tid),
      "thresholdNs": .integer(request.thresholdNs),
      "limit": .integer(Int64(request.limit)),
      "timeoutMs": .integer(Int64(request.timeoutMs)),
      "maxRows": .integer(Int64(request.maxRows)),
      "maxEvents": .integer(Int64(request.maxEvents)),
      "maxOutputBytes": .integer(Int64(request.maxOutputBytes)),
    ])
  }

  private static func projection(_ invocation: AnalyzerInvocation) -> JSONValue {
    .object([
      "analyzerRef": .string(invocation.analyzerRef),
      "executableSHA256": .string(invocation.executableSHA256),
      "arguments": .array(invocation.arguments.map(JSONValue.string)),
      "timeoutSeconds": .integer(Int64(invocation.timeoutSeconds)),
      "outputByteBudget": invocation.outputByteBudget.map { .integer(Int64($0)) } ?? .null,
      "sourceSHA256": .string(invocation.sourceSHA256),
      "sourceByteCount": .integer(Int64(invocation.sourceByteCount)),
      "request": invocation.arkTraceAnalysisRequest.map(projection) ?? .null,
      "contract": invocation.arkTraceAnalysisContract == nil ? .null : .bool(true),
    ])
  }

  /// Each request case: the inputs, as a request's JSON carries them.
  static let requestCases: [(String, String)] = [
    ("contextTimestamp", #"{"sourceArtifactRef":"lease","kind":"context","timestampNs":16000000000,"timeoutMs":30000,"maxRows":100,"maxEvents":1000,"maxOutputBytes":1048576}"#),
    ("contextRange", #"{"sourceArtifactRef":"lease","kind":"context","startNs":1000000000,"endNs":1100000000,"timeoutMs":30000,"maxRows":100,"maxEvents":1000,"maxOutputBytes":1048576}"#),
    ("cpuRangeLimit", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":32210627000,"limit":10,"timeoutMs":30000,"maxRows":100,"maxEvents":10000,"maxOutputBytes":1048576}"#),
    ("cpuDefaultLimit", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":5,"timeoutMs":30000,"maxRows":7,"maxEvents":9,"maxOutputBytes":1048576}"#),
    ("defaultLimitCapped", #"{"sourceArtifactRef":"lease","kind":"range","startNs":0,"endNs":5,"timeoutMs":30000,"maxRows":5000,"maxEvents":9000,"maxOutputBytes":1048576}"#),
    ("slicesTimestampThreshold", #"{"sourceArtifactRef":"lease","kind":"slices","timestampNs":3000000000,"thresholdNs":250,"limit":5,"timeoutMs":60000,"maxRows":100,"maxEvents":20000,"maxOutputBytes":1048576}"#),
    ("hotIntervalsKeys", #"{"sourceArtifactRef":"lease","kind":"hot-intervals","startNs":10,"endNs":20,"processKey":3,"threadKey":-4,"timeoutMs":1001,"maxRows":10,"maxEvents":10,"maxOutputBytes":1024}"#),
    ("rangePidTid", #"{"sourceArtifactRef":"lease","kind":"range","startNs":10,"endNs":20,"pid":0,"tid":7,"timeoutMs":999,"maxRows":10,"maxEvents":10,"maxOutputBytes":67108864}"#),
    ("schedulingTimestampNearZero", #"{"sourceArtifactRef":"lease","kind":"scheduling","timestampNs":10,"timeoutMs":100,"maxRows":1,"maxEvents":1,"maxOutputBytes":2048}"#),
    ("contextTimestampZero", #"{"sourceArtifactRef":"lease","kind":"context","timestampNs":0,"timeoutMs":120000,"maxRows":100000,"maxEvents":100000,"maxOutputBytes":1048576}"#),
    ("integralFloats", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0.0,"endNs":1e3,"limit":2.0,"timeoutMs":3e4,"maxRows":100.0,"maxEvents":10,"maxOutputBytes":1048576}"#),
    ("negativeZeroStart", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":-0,"endNs":1,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("timestampOverflow", #"{"sourceArtifactRef":"lease","kind":"context","timestampNs":9223372036854775000,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("timestampOverflowAnalysis", #"{"sourceArtifactRef":"lease","kind":"slices","timestampNs":9223372036854775000,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("unknownKey", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024,"window":1}"#),
    ("nullLimit", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"limit":null,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("stringLimit", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"limit":"1","timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("fractionalLimit", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"limit":1.5,"timeoutMs":30000,"maxRows":2,"maxEvents":2,"maxOutputBytes":1024}"#),
    ("unsignedTimestamp", #"{"sourceArtifactRef":"lease","kind":"context","timestampNs":18446744073709551615,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("missingKind", #"{"sourceArtifactRef":"lease","startNs":0,"endNs":1,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("unknownKind", #"{"sourceArtifactRef":"lease","kind":"memory","startNs":0,"endNs":1,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("stringTimeout", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"timeoutMs":"30000","maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("missingMaxRows", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"timeoutMs":30000,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("timestampAndStart", #"{"sourceArtifactRef":"lease","kind":"cpu","timestampNs":5,"startNs":0,"endNs":10,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("startWithoutEnd", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("noTimeSelection", #"{"sourceArtifactRef":"lease","kind":"cpu","timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("emptyRange", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":5,"endNs":5,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("timeoutTooShort", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"timeoutMs":99,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("timeoutTooLong", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"timeoutMs":120001,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("zeroRows", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"timeoutMs":30000,"maxRows":0,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("tooManyEvents", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"timeoutMs":30000,"maxRows":1,"maxEvents":100001,"maxOutputBytes":1024}"#),
    ("outputTooSmall", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1023}"#),
    ("outputTooLarge", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":67108865}"#),
    ("negativeThreshold", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"thresholdNs":-1,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("zeroLimit", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"limit":0,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("limitBeyondEvents", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"limit":3,"timeoutMs":30000,"maxRows":5,"maxEvents":2,"maxOutputBytes":1024}"#),
    ("negativeTimestamp", #"{"sourceArtifactRef":"lease","kind":"context","timestampNs":-1,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("negativeStart", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":-5,"endNs":1,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("zeroEnd", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":-1,"endNs":0,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("negativePid", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"pid":-1,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("negativeTid", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"tid":-1,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("zeroProcessKey", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"processKey":0,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("zeroThreadKey", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"threadKey":0,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("processKeyAndPid", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"processKey":2,"pid":3,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("threadKeyAndTid", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"threadKey":2,"tid":3,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("contextWithLimit", #"{"sourceArtifactRef":"lease","kind":"context","timestampNs":5,"limit":1,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("contextWithThreshold", #"{"sourceArtifactRef":"lease","kind":"context","timestampNs":5,"thresholdNs":0,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("contextKeysAndFilters", #"{"sourceArtifactRef":"lease","kind":"context","startNs":1,"endNs":2,"processKey":-9,"tid":4,"timeoutMs":30000,"maxRows":1,"maxEvents":1,"maxOutputBytes":1024}"#),
    ("exponentLimit", #"{"sourceArtifactRef":"lease","kind":"cpu","startNs":0,"endNs":1,"limit":1e3,"timeoutMs":30000,"maxRows":1000,"maxEvents":1000,"maxOutputBytes":1024}"#),
  ]

  func testSwiftValidatesTheSharedAnalysisEnvelopes() throws {
    let bases = try Self.bases()
    var recorded: [JSONValue] = []
    for item in Self.cases {
      guard let base = bases[item.base] else { throw CocoaError(.coderInvalidValue) }
      let invocation = try Self.invocation(item.invocation, base: base)
      let bytes = try Self.edited(base.bytes, item.edits)
      recorded.append(
        .object([
          "name": .string(item.name),
          "base": .string(item.base),
          "edits": .array(
            item.edits.map { .object(["find": .string($0.0), "replace": .string($0.1)]) }),
          "invocation": Self.projection(invocation),
          "valid": .bool(ArkTraceAnalysisEnvelopeValidator.validate(bytes, invocation: invocation)),
        ]))
    }
    var requests: [JSONValue] = []
    for (name, text) in Self.requestCases {
      let inputs = try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))
      let outcome: JSONValue
      do {
        let request = try AnalyzerProvider.analysisRequest(inputs)
        outcome = .object([
          "request": Self.projection(request),
          "arguments": .array(request.arguments(sourcePath: Self.sourcePath).map(JSONValue.string)),
          "processTimeoutSeconds": .integer(Int64(request.processTimeoutSeconds)),
          "recoveryDigestSHA256": .string(request.recoveryDigestSHA256),
          "normalizedRange": request.normalizedRange.map {
            .array([.integer($0.startNs), .integer($0.endNs)])
          } ?? .null,
        ])
      } catch DeviceProviderError.unsupportedAction(let reason) {
        outcome = .object(["refused": .string(reason)])
      }
      requests.append(.object(["name": .string(name), "inputs": .string(text), "outcome": outcome]))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [
      "cases.json": try encoder.encode(
        JSONValue.object([
          "sourcePath": .string(Self.sourcePath),
          "executableSHA256": .string(Self.executableSHA256),
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
        ])) + Data("\n".utf8),
      "request-cases.json": try encoder.encode(JSONValue.array(requests)) + Data("\n".utf8),
      "requests.json": try Data(contentsOf: Self.oracle.appending(path: "requests.json")),
    ]
    for name in bases.keys {
      files["reviewed/\(name).json"] = bases[name]!.bytes
    }
    try Self.recordOrCompare(files)
  }

  private static func recordOrCompare(_ files: [String: Data]) throws {
    if let output = ProcessInfo.processInfo.environment[
      "ARKDECK_RUST_ARKTRACE_ANALYSIS_VALIDATOR_RECORD"]
    {
      let destination = URL(fileURLWithPath: output, isDirectory: true)
      guard destination.path.hasPrefix("/private/tmp/"),
        !FileManager.default.fileExists(atPath: destination.path)
      else { throw CocoaError(.fileWriteFileExists) }
      for (path, data) in files {
        let url = destination.appending(path: path)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try data.write(to: url)
      }
      return
    }
    let recorded = try FileManager.default.subpathsOfDirectory(atPath: oracle.path)
      .filter { path in
        var directory: ObjCBool = false
        FileManager.default.fileExists(
          atPath: oracle.appending(path: path).path, isDirectory: &directory)
        return !directory.boolValue
      }
    XCTAssertEqual(Set(recorded), Set(files.keys))
    for (path, data) in files {
      XCTAssertEqual(try Data(contentsOf: oracle.appending(path: path)), data, path)
    }
  }
}
