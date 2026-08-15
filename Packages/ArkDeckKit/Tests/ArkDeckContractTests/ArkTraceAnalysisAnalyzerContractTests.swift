import Darwin
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

private final class FixedArkTraceAnalysisDispatcher:
  RuntimeProcessDispatching, @unchecked Sendable
{
  private let lock = NSLock()
  private let output: Data
  private var count = 0

  init(output: Data) { self.output = output }
  var dispatchCount: Int { lock.withLock { count } }
  func unavailableReason(providerID: String) -> String? { nil }
  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    lock.withLock { count += 1 }
    return ProviderProcessReceipt(
      exitStatus: 0, stdout: output, stderr: Data(), stdoutTruncated: false,
      durationSeconds: 0.01)
  }
}

private final class CancellingArkTraceAnalysisDispatcher:
  RuntimeProcessDispatching, @unchecked Sendable
{
  private let lock = NSLock()
  private var startedContinuation: CheckedContinuation<Void, Never>?
  private var started = false
  private(set) var observedCancellation = false

  func unavailableReason(providerID: String) -> String? { nil }

  func waitUntilStarted() async {
    let isStarted = lock.withLock { started }
    if isStarted { return }
    await withCheckedContinuation { continuation in
      let resumeNow = lock.withLock {
        if started { return true }
        startedContinuation = continuation
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      started = true
      defer { startedContinuation = nil }
      return startedContinuation
    }
    continuation?.resume()
    do {
      try await Task.sleep(for: .seconds(60))
      throw RuntimeDispatchFailure.failed("analysis cancellation fixture unexpectedly completed")
    } catch is CancellationError {
      lock.withLock { observedCancellation = true }
      throw RuntimeDispatchCancellationResolution.drained
    }
  }
}

private struct UnknownArkTraceAnalysisDispatcher: RuntimeProcessDispatching {
  func unavailableReason(providerID: String) -> String? { nil }
  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    throw RuntimeDispatchFailure.outcomeUnknown("analysis child outcome is unavailable")
  }
}

final class ArkTraceAnalysisAnalyzerContractTests: XCTestCase {
  private let sourcePath = "/private/tmp/arkdeck-analysis-source.htrace"
  private let sourceSHA = String(repeating: "1", count: 64)
  private let toolSHA = String(repeating: "f", count: 64)
  private let parserSHA = String(repeating: "2", count: 64)
  private let schemaSHA = String(repeating: "4", count: 64)
  private let databaseSHA = String(repeating: "5", count: 64)
  private var temporaryRoot: URL!

  override func setUpWithError() throws {
    guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { free(physical) }
    temporaryRoot = URL(filePath: String(cString: physical), directoryHint: .isDirectory).appending(
      path: "arkdeck-trace-analysis-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: temporaryRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
  }

  func testContextAndAnalysisEnvelopesMatchExactTypedInvocation() throws {
    let context = try request(kind: .context, timestampNs: 100_000_000)
    let contextInvocation = invocation(context)
    XCTAssertTrue(ArkTraceAnalysisEnvelopeValidator.validate(
      try encoded(root(context)), invocation: contextInvocation))
    XCTAssertEqual(contextInvocation.arguments, [
      "context", "--json", "--no-cache", "--timeout-ms", "30000",
      "--max-rows", "10000", "--max-events", "10000",
      "--max-output-bytes", "8388608", "--timestamp-ns", "100000000",
      "--window-ms", "50", sourcePath,
    ])
    let rangedContext = try request(
      kind: .context, startNs: 10_000_000, endNs: 20_000_000)
    XCTAssertEqual(invocation(rangedContext).arguments, [
      "context", "--json", "--no-cache", "--timeout-ms", "30000",
      "--max-rows", "10000", "--max-events", "10000",
      "--max-output-bytes", "8388608", "--start-ns", "10000000",
      "--end-ns", "20000000", sourcePath,
    ])

    let analysis = try request(kind: .range, startNs: 0, endNs: 100_000_000)
    let analysisInvocation = invocation(analysis)
    XCTAssertTrue(ArkTraceAnalysisEnvelopeValidator.validate(
      try encoded(root(analysis)), invocation: analysisInvocation))
    XCTAssertEqual(analysisInvocation.arguments, [
      "analyze", "--json", "--no-cache", "--timeout-ms", "30000",
      "--max-rows", "10000", "--max-events", "10000",
      "--max-output-bytes", "8388608", "--kind", "range",
      "--start-ns", "0", "--end-ns", "100000000", "--threshold-ns", "0",
      "--limit", "10", sourcePath,
    ])
    let persisted = try PersistedTypedProviderAction(.analyzer(.analyze(analysisInvocation)))
    XCTAssertEqual(
      persisted.arguments["requestDigestSha256"],
      .string(analysis.recoveryDigestSHA256))
    guard case .analyzer(.reconcile(let recovery)) = try persisted.materialize() else {
      return XCTFail("analysis recovery identity did not materialize")
    }
    XCTAssertEqual(recovery.requestDigestSHA256, analysis.recoveryDigestSHA256)
    for kind in ArkTraceAnalysisKind.allCases where kind != .context {
      let typed = try request(kind: kind, startNs: 0, endNs: 100_000_000)
      let arguments = invocation(typed).arguments
      let kindIndex = try XCTUnwrap(arguments.firstIndex(of: "--kind"))
      XCTAssertEqual(arguments[kindIndex + 1], kind.rawValue)
      XCTAssertEqual(arguments.last, sourcePath)
      XCTAssertEqual(arguments.filter { $0 == sourcePath }.count, 1)
    }
  }

  func testClosedEnvelopeRejectsRequestProvenanceBudgetAndPrivacyDrift() throws {
    let request = try request(kind: .range, startNs: 0, endNs: 100_000_000)
    let invocation = invocation(request)

    var extra = root(request)
    extra["unexpected"] = .bool(true)
    XCTAssertFalse(ArkTraceAnalysisEnvelopeValidator.validate(
      try encoded(extra), invocation: invocation))

    var fractional = root(request)
    fractional = replacingObject(fractional, key: "limits") { limits in
      limits["maxRows"] = .number(10_000.000_1)
    }
    XCTAssertFalse(ArkTraceAnalysisEnvelopeValidator.validate(
      try encoded(fractional), invocation: invocation))

    var wrongTrace = root(request)
    wrongTrace = replacingObject(wrongTrace, key: "trace") { trace in
      trace["sha256"] = .string(String(repeating: "9", count: 64))
    }
    XCTAssertFalse(ArkTraceAnalysisEnvelopeValidator.validate(
      try encoded(wrongTrace), invocation: invocation))

    var path = root(request)
    path = replacingNestedObject(path, first: "result", second: "analysis") { analysis in
      analysis["topProcesses"] = .array([
        .object([
          "processKey": .object(["ipid": .integer(1)]), "pid": .integer(42),
          "name": .string("event)/srv/private.trace"), "runningNs": .integer(10),
          "shareOfOneCPU": .number(0.000_000_1), "sliceCount": .integer(1),
        ])
      ])
      guard case .object(var sections)? = analysis["sections"] else { return }
      sections["topProcesses"] = status(returned: 1)
      analysis["sections"] = .object(sections)
    }
    XCTAssertFalse(ArkTraceAnalysisEnvelopeValidator.validate(
      try encoded(path), invocation: invocation))

    func longSlice(_ start: Int64, _ end: Int64) -> JSONValue {
      .object([
        "key": .object(["table": .string("callstack"), "rowID": .integer(9)]),
        "range": range(start, end), "name": .string("work"), "category": .null,
        "processKey": .object(["ipid": .integer(1)]),
        "threadKey": .object(["itid": .integer(2)]), "pid": .integer(42),
        "tid": .integer(43), "processName": .string("worker"),
        "threadName": .string("main"),
      ])
    }
    func withLongSlice(_ row: JSONValue) -> [String: JSONValue] {
      replacingNestedObject(root(request), first: "result", second: "analysis") {
        analysis in
        analysis["longSlices"] = .array([row])
        guard case .object(var sections)? = analysis["sections"] else { return }
        sections["longSlices"] = status(returned: 1)
        analysis["sections"] = .object(sections)
      }
    }
    XCTAssertTrue(ArkTraceAnalysisEnvelopeValidator.validate(
      try encoded(withLongSlice(longSlice(50_000_000, 150_000_000))),
      invocation: invocation))
    XCTAssertFalse(ArkTraceAnalysisEnvelopeValidator.validate(
      try encoded(withLongSlice(longSlice(100_000_000, 200_000_000))),
      invocation: invocation))
  }

  func testAnalysisRowsAndSectionStatusesShareOneGlobalLimit() throws {
    let request = try self.request(
      kind: .range, startNs: 0, endNs: 100_000_000,
      maxRows: 1, maxEvents: 10, limit: 1)
    let invocation = invocation(request)
    var document = root(request)
    document = replacingNestedObject(document, first: "result", second: "analysis") {
      analysis in
      analysis["cpuUtilization"] = .array([
        .object([
          "cpu": .integer(0), "rawRunningNs": .integer(10),
          "occupiedNs": .integer(10), "sliceCount": .integer(1),
          "utilization": .number(0.000_000_1),
        ])
      ])
      guard case .object(var sections)? = analysis["sections"] else { return }
      sections["cpuUtilization"] = status(returned: 1)
      analysis["sections"] = .object(sections)
    }
    XCTAssertTrue(ArkTraceAnalysisEnvelopeValidator.validate(
      try encoded(document), invocation: invocation))

    document = replacingNestedObject(document, first: "result", second: "analysis") {
      analysis in
      analysis["topProcesses"] = .array([
        .object([
          "processKey": .object(["ipid": .integer(1)]), "pid": .integer(42),
          "name": .string("worker"), "runningNs": .integer(10),
          "shareOfOneCPU": .number(0.000_000_1), "sliceCount": .integer(1),
        ])
      ])
      guard case .object(var sections)? = analysis["sections"] else { return }
      sections["topProcesses"] = status(returned: 1)
      analysis["sections"] = .object(sections)
    }
    XCTAssertFalse(ArkTraceAnalysisEnvelopeValidator.validate(
      try encoded(document), invocation: invocation))
  }

  func testContextEmbeddedSummaryUsesTheRequestBudgetsRatherThanSummaryOperationDefaults()
    throws
  {
    let request = try self.request(
      kind: .context, startNs: 0, endNs: 100_000_000,
      maxRows: 2_000, maxEvents: 20_000)
    let invocation = invocation(request)
    var document = root(request)
    document = replacingNestedObject(document, first: "result", second: "summary") {
      $0["processCount"] = .integer(1_500)
      $0["threadCount"] = .integer(1_500)
    }
    XCTAssertTrue(ArkTraceAnalysisEnvelopeValidator.validate(
      try encoded(document), invocation: invocation))
    document = replacingNestedObject(document, first: "result", second: "summary") {
      $0["processCount"] = .integer(2_001)
    }
    XCTAssertFalse(ArkTraceAnalysisEnvelopeValidator.validate(
      try encoded(document), invocation: invocation))
  }

  func testContextRowsMustIntersectTheRequestedRangeAndMatchCapabilities() throws {
    let request = try self.request(
      kind: .context, startNs: 100_000_000, endNs: 200_000_000,
      maxRows: 10, maxEvents: 10)
    let invocation = invocation(request)
    func slice(_ start: Int64, _ end: Int64, threadKey: Int64 = 2) -> JSONValue {
      .object([
        "key": .object(["table": .string("callstack"), "rowID": .integer(1)]),
        "range": range(start, end),
        "threadKey": .object(["itid": .integer(threadKey)]),
        "processKey": .object(["ipid": .integer(3)]), "pid": .integer(42),
        "tid": .integer(43), "processName": .string("worker"),
        "threadName": .string("main"), "name": .string("work"),
        "category": .null, "depth": .integer(0), "parentEventKey": .null,
        "isAsync": .bool(false), "isOpenEnded": .bool(false),
      ])
    }
    func document(
      with value: JSONValue, namedSlicesAvailable: Bool
    ) -> [String: JSONValue] {
      var document = root(request)
      document = replacingNestedObject(document, first: "result", second: "summary") {
        summary in
        guard case .object(var capabilities)? = summary["capabilities"] else { return }
        capabilities["namedSlices"] = .bool(namedSlicesAvailable)
        summary["capabilities"] = .object(capabilities)
        summary["namedSliceCount"] = namedSlicesAvailable ? .integer(1) : .null
        summary["processCount"] = .integer(1)
        summary["threadCount"] = .integer(1)
      }
      document = replacingNestedObject(
        document, first: "result", second: "truncation"
      ) {
        $0["processes"] = status(returned: 1)
        $0["threads"] = status(returned: 1)
        $0["slices"] = status(returned: 1)
      }
      return replacingObject(document, key: "result") {
        $0["processes"] = .array([.object([
          "key": .object(["ipid": .integer(3)]), "pid": .integer(42),
          "name": .string("worker"), "startNs": .null, "endNs": .null,
          "threadCount": .integer(1),
        ])])
        $0["threads"] = .array([.object([
          "key": .object(["itid": .integer(2)]),
          "processKey": .object(["ipid": .integer(3)]), "tid": .integer(43),
          "pid": .integer(42), "name": .string("main"),
          "processName": .string("worker"), "startNs": .null, "endNs": .null,
          "isMainThread": .bool(true),
        ])])
        $0["slices"] = .array([value])
      }
    }

    let overlapping = document(
      with: slice(50_000_000, 150_000_000), namedSlicesAvailable: true)
    XCTAssertTrue(ArkTraceAnalysisEnvelopeValidator.validate(
      try encoded(overlapping), invocation: invocation))
    let outside = document(
      with: slice(200_000_000, 300_000_000), namedSlicesAvailable: true)
    XCTAssertFalse(ArkTraceAnalysisEnvelopeValidator.validate(
      try encoded(outside), invocation: invocation))
    let unavailable = document(
      with: slice(50_000_000, 150_000_000), namedSlicesAvailable: false)
    XCTAssertFalse(ArkTraceAnalysisEnvelopeValidator.validate(
      try encoded(unavailable), invocation: invocation))
    let missingReference = document(
      with: slice(50_000_000, 150_000_000, threadKey: 999),
      namedSlicesAvailable: true)
    XCTAssertFalse(ArkTraceAnalysisEnvelopeValidator.validate(
      try encoded(missingReference), invocation: invocation))
  }

  func testCrossFieldParserRejectsEveryAmbiguousSelectionAndFilter() throws {
    let base: [String: JSONValue] = [
      "sourceArtifactRef": .string("lease"), "kind": .string("range"),
      "startNs": .integer(0), "endNs": .integer(100),
      "timeoutMs": .integer(30_000), "maxRows": .integer(100),
      "maxEvents": .integer(100), "maxOutputBytes": .integer(8_388_608),
    ]
    XCTAssertNoThrow(try AnalyzerProvider.analysisRequest(base))

    var mixed = base
    mixed["timestampNs"] = .integer(50)
    XCTAssertThrowsError(try AnalyzerProvider.analysisRequest(mixed))

    var missingEnd = base
    missingEnd.removeValue(forKey: "endNs")
    XCTAssertThrowsError(try AnalyzerProvider.analysisRequest(missingEnd))

    var duplicateIdentity = base
    duplicateIdentity["processKey"] = .integer(7)
    duplicateIdentity["pid"] = .integer(42)
    XCTAssertThrowsError(try AnalyzerProvider.analysisRequest(duplicateIdentity))

    var sentinel = base
    sentinel["threadKey"] = .integer(0)
    XCTAssertThrowsError(try AnalyzerProvider.analysisRequest(sentinel))

    for key in [
      "timestampNs", "startNs", "endNs", "processKey", "pid", "threadKey", "tid",
      "thresholdNs", "limit",
    ] {
      var wrongType = base
      wrongType[key] = .string("1")
      XCTAssertThrowsError(
        try AnalyzerProvider.analysisRequest(wrongType), "\(key) must not be ignored")
    }

    var overLimit = base
    overLimit["maxRows"] = .integer(1)
    overLimit["limit"] = .integer(2)
    XCTAssertThrowsError(try AnalyzerProvider.analysisRequest(overLimit))

    var contextOnly = base
    contextOnly["kind"] = .string("context")
    contextOnly["thresholdNs"] = .integer(0)
    XCTAssertThrowsError(try AnalyzerProvider.analysisRequest(contextOnly))

    var unknown = base
    unknown["rawArgument"] = .string("--unsafe")
    XCTAssertThrowsError(try AnalyzerProvider.analysisRequest(unknown))
  }

  func testRuntimePublishesAndReloadsExactAnalysisBytesWithRequestLineage() async throws {
    let artifactRoot = temporaryRoot.appending(path: "artifacts", directoryHint: .isDirectory)
    let store = try RuntimeArtifactStore(
      rootURL: artifactRoot, nowUTC: { "2026-08-15T00:00:00Z" })
    let sourceBytes = Data("immutable analysis trace".utf8)
    let source = try await store.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "JOB-TRACE-SOURCE", sessionID: "HTASK-TRACEANALYSIS",
        stepID: "receive-trace-artifact", name: "trace.htrace",
        mediaType: "application/octet-stream", privacy: .sensitive,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "capture.diagnostics@1", providerID: "hdc",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-TRACE", bindingRevision: 7,
          stableIdentitySHA256: String(repeating: "c", count: 64)),
        contents: sourceBytes))
    let lease = try await store.leaseReference(
      jobID: source.jobID, artifactID: source.artifactID)
    let resolved = try await store.resolveLease(lease)
    let runtimeToolSHA = AnalyzerProvider.sha256(
      try Data(contentsOf: URL(filePath: "/bin/cat")))
    let request = try self.request(kind: .range, startNs: 0, endNs: 100_000_000)
    let profile = AnalyzerProfile(
      analyzerRef: "trace-analysis@1", analyzerVersion: "0.1.0+1",
      executablePath: "/bin/cat", executableSHA256: runtimeToolSHA,
      fixedArguments: [], timeoutSeconds: 120, outputByteBudget: 64 * 1_024 * 1_024,
      arkTraceAnalysisContract: contract)
    let expectedInvocation = AnalyzerInvocation(
      analyzerRef: "trace-analysis@1", analyzerVersion: "0.1.0+1",
      executableSHA256: runtimeToolSHA,
      arguments: request.arguments(sourcePath: resolved.fileURL.path),
      timeoutSeconds: request.processTimeoutSeconds,
      outputByteBudget: request.maxOutputBytes,
      sourceArtifactID: source.artifactID, sourceSHA256: source.sha256,
      sourceByteCount: source.byteCount, arkTraceAnalysisRequest: request,
      arkTraceAnalysisContract: contract)
    let exactOutput = try encoded(root(
      request, traceSHA: source.sha256, traceByteCount: source.byteCount,
      toolSHA: runtimeToolSHA))
    XCTAssertTrue(ArkTraceAnalysisEnvelopeValidator.validate(
      exactOutput, invocation: expectedInvocation))
    let dispatcher = FixedArkTraceAnalysisDispatcher(output: exactOutput)
    let provider = try AnalyzerProvider(profiles: [profile])
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: AnalyzerProvider.traceAnalysis))
    let providerContext = ProviderExecutionContext(
      jobID: "job-preflight", stepID: "analyze-trace", targetID: "TGT-TRACE",
      bindingRevision: nil, nowUTC: "2026-08-15T00:00:00Z",
      resolvedInputArtifact: ProviderResolvedInputArtifact(
        artifactID: source.artifactID, fileURL: resolved.fileURL,
        sha256: source.sha256, byteCount: source.byteCount))
    let providerInputs: [String: JSONValue] = [
      "kind": .string("range"), "startNs": .integer(0),
      "endNs": .integer(100_000_000), "timeoutMs": .integer(30_000),
      "maxRows": .integer(10_000), "maxEvents": .integer(10_000),
      "maxOutputBytes": .integer(8_388_608), "limit": .integer(10),
    ]
    let providerAction = try provider.action(
      for: descriptor.steps[0], operation: descriptor, inputs: providerInputs,
      context: providerContext)
    let providerOutcome = try provider.verify(
      receipt: ProviderProcessReceipt(
        exitStatus: 0, stdout: exactOutput, stderr: Data(), stdoutTruncated: false,
        durationSeconds: 0.01),
      action: providerAction, context: providerContext)
    guard case .verified(let providerSummary) = providerOutcome else {
      return XCTFail("valid analysis envelope did not verify")
    }
    XCTAssertNotNil(
      RuntimeArtifactService.traceAnalysisDerivation(
        name: "trace-analysis.json", descriptor: descriptor, summary: providerSummary),
      "summary: \(providerSummary)")
    let state = temporaryRoot.appending(path: "runtime", directoryHint: .isDirectory)
    let engine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: state),
      providers: DeviceProviderRegistry(providers: [provider]), dispatcher: dispatcher,
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: temporaryRoot.appending(path: "capabilities", directoryHint: .isDirectory)),
      artifactStore: store, nowUTC: { "2026-08-15T00:00:00Z" })
    let operationRequest = try RuntimeOperationRequest(
      requestID: "req-trace-analysis", idempotencyKey: "idem-trace-analysis",
      target: DurableTargetReference(targetID: "TGT-TRACE", expectedBindingRevision: nil),
      operation: RuntimeOperationReference(id: "analyzer.analyze-trace", version: 1),
      inputs: [
        "sourceArtifactRef": .string(lease), "kind": .string("range"),
        "startNs": .integer(0), "endNs": .integer(100_000_000),
        "timeoutMs": .integer(30_000), "maxRows": .integer(10_000),
        "maxEvents": .integer(10_000), "maxOutputBytes": .integer(8_388_608),
        "limit": .integer(10),
      ])
    let accepted = try await engine.submit(try JSONEncoder().encode(operationRequest))
    let status: RuntimeJobStatus
    do {
      status = try await engine.run(jobID: accepted.jobID)
    } catch {
      let failedStatus = try? await engine.status(jobID: accepted.jobID)
      let failedArtifacts = try? await store.list(jobID: accepted.jobID)
      XCTFail(
        "analysis run failed: \(error); status=\(String(describing: failedStatus)); "
          + "artifacts=\(String(describing: failedArtifacts))")
      return
    }
    XCTAssertEqual(status.state, "succeeded", "timeline: \(status.timeline)")
    XCTAssertEqual(dispatcher.dispatchCount, 1)
    let inventory = try await store.list(jobID: accepted.jobID)
    let metadata = try XCTUnwrap(inventory.first(where: {
      $0.name == "trace-analysis.json" && $0.status.isPublished
    }))
    XCTAssertEqual(metadata.sha256, AnalyzerProvider.sha256(exactOutput))
    XCTAssertEqual(metadata.byteCount, exactOutput.count)
    XCTAssertFalse(metadata.redactionApplied)
    let derivation = try XCTUnwrap(metadata.derivation)
    XCTAssertEqual(derivation.sourceArtifactID, source.artifactID)
    XCTAssertEqual(derivation.requestCommand, "analyze")
    XCTAssertEqual(derivation.requestKind, "range")
    XCTAssertEqual(derivation.requestStartNs, 0)
    XCTAssertEqual(derivation.requestEndNs, 100_000_000)
    XCTAssertEqual(derivation.requestThresholdNs, 0)
    XCTAssertEqual(derivation.requestLimit, 10)
    let reloaded = try RuntimeArtifactStore(
      rootURL: artifactRoot, nowUTC: { "2026-08-15T00:00:01Z" })
    let reloadedBytes = try await reloaded.read(
      jobID: accepted.jobID, artifactID: metadata.artifactID)
    XCTAssertEqual(reloadedBytes, exactOutput)
    let reloadedMetadata = try await reloaded.inspect(
      jobID: accepted.jobID, artifactID: metadata.artifactID)
    XCTAssertEqual(reloadedMetadata.derivation, derivation)

    let cancellingDispatcher = CancellingArkTraceAnalysisDispatcher()
    let cancellingEngine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: temporaryRoot.appending(
          path: "cancel-runtime", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: cancellingDispatcher,
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: temporaryRoot.appending(
          path: "cancel-capabilities", directoryHint: .isDirectory)),
      artifactStore: store, nowUTC: { "2026-08-15T00:00:02Z" })
    let cancelRequest = try RuntimeOperationRequest(
      requestID: "req-trace-analysis-cancel",
      idempotencyKey: "idem-trace-analysis-cancel",
      target: DurableTargetReference(targetID: "TGT-TRACE", expectedBindingRevision: nil),
      operation: RuntimeOperationReference(id: "analyzer.analyze-trace", version: 1),
      inputs: operationRequest.inputs)
    let cancelAcceptance = try await cancellingEngine.submit(
      try JSONEncoder().encode(cancelRequest))
    let cancelRun = Task { try await cancellingEngine.run(jobID: cancelAcceptance.jobID) }
    await cancellingDispatcher.waitUntilStarted()
    try await cancellingEngine.requestCancel(jobID: cancelAcceptance.jobID)
    let cancelled = try await cancelRun.value
    XCTAssertEqual(cancelled.state, "cancelled")
    XCTAssertTrue(cancellingDispatcher.observedCancellation)
    let cancelledArtifacts = try await store.list(jobID: cancelAcceptance.jobID)
    XCTAssertFalse(cancelledArtifacts.contains(where: {
      $0.name == "trace-analysis.json"
    }))

    let recoveryState = temporaryRoot.appending(
      path: "recovery-runtime", directoryHint: .isDirectory)
    let unknownEngine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: recoveryState),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: UnknownArkTraceAnalysisDispatcher(),
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: temporaryRoot.appending(
          path: "recovery-capabilities", directoryHint: .isDirectory)),
      artifactStore: store, nowUTC: { "2026-08-15T00:00:03Z" })
    let unknownRequest = try RuntimeOperationRequest(
      requestID: "req-trace-analysis-unknown",
      idempotencyKey: "idem-trace-analysis-unknown",
      target: DurableTargetReference(targetID: "TGT-TRACE", expectedBindingRevision: nil),
      operation: RuntimeOperationReference(id: "analyzer.analyze-trace", version: 1),
      inputs: operationRequest.inputs)
    let unknownAcceptance = try await unknownEngine.submit(
      try JSONEncoder().encode(unknownRequest))
    let parked = try await unknownEngine.run(jobID: unknownAcceptance.jobID)
    XCTAssertEqual(parked.state, "waitingForRecovery")
    XCTAssertTrue(parked.outcomeUnknown)

    let recoveryDispatcher = FixedArkTraceAnalysisDispatcher(output: exactOutput)
    let restartedEngine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: recoveryState),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: recoveryDispatcher,
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: temporaryRoot.appending(
          path: "recovery-capabilities", directoryHint: .isDirectory)),
      artifactStore: store, nowUTC: { "2026-08-15T00:00:04Z" })
    let recovered = try await restartedEngine.recoverActiveJobs()
    XCTAssertEqual(recovered.map(\.jobID), [unknownAcceptance.jobID])
    let reconciled = try await restartedEngine.reconcile(jobID: unknownAcceptance.jobID)
    XCTAssertEqual(reconciled.state, "failed")
    XCTAssertFalse(reconciled.outcomeUnknown)
    XCTAssertEqual(recoveryDispatcher.dispatchCount, 0)
    let recoveredArtifacts = try await store.list(jobID: unknownAcceptance.jobID)
    XCTAssertFalse(recoveredArtifacts.contains(where: {
      $0.name == "trace-analysis.json"
    }))
  }

  func testSubmitRejectsCrossFieldAmbiguityBeforeDispatcherRuns() async throws {
    let profile = AnalyzerProfile(
      analyzerRef: "trace-analysis@1", analyzerVersion: "0.1.0+1",
      executablePath: "/bin/cat", executableSHA256: toolSHA,
      fixedArguments: [], timeoutSeconds: 120, outputByteBudget: 64 * 1_024 * 1_024,
      arkTraceAnalysisContract: contract)
    let dispatcher = FixedArkTraceAnalysisDispatcher(output: Data())
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: temporaryRoot.appending(path: "invalid-runtime", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: [try AnalyzerProvider(profiles: [profile])]),
      dispatcher: dispatcher,
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: temporaryRoot.appending(
          path: "invalid-capabilities", directoryHint: .isDirectory)),
      artifactStore: try RuntimeArtifactStore(
        rootURL: temporaryRoot.appending(
          path: "invalid-artifacts", directoryHint: .isDirectory),
        nowUTC: { "2026-08-15T00:00:00Z" }),
      nowUTC: { "2026-08-15T00:00:00Z" })
    let valid: [String: JSONValue] = [
      "sourceArtifactRef": .string("artifact-lease-v1.invalid"),
      "kind": .string("range"), "startNs": .integer(0), "endNs": .integer(10),
      "timeoutMs": .integer(30_000), "maxRows": .integer(100),
      "maxEvents": .integer(100), "maxOutputBytes": .integer(8_388_608),
    ]
    var cases: [(String, [String: JSONValue])] = []
    func add(_ name: String, _ mutate: (inout [String: JSONValue]) -> Void) {
      var inputs = valid
      mutate(&inputs)
      cases.append((name, inputs))
    }
    add("unknown-kind") { $0["kind"] = .string("sql") }
    add("mixed-time") { $0["timestampNs"] = .integer(5) }
    add("missing-end") { $0.removeValue(forKey: "endNs") }
    add("degenerate-range") { $0["endNs"] = .integer(0) }
    add("mixed-process") {
      $0["processKey"] = .integer(7)
      $0["pid"] = .integer(42)
    }
    add("zero-thread-key") { $0["threadKey"] = .integer(0) }
    add("short-timeout") { $0["timeoutMs"] = .integer(99) }
    add("limit-over-global") {
      $0["maxRows"] = .integer(1)
      $0["limit"] = .integer(2)
    }
    add("context-threshold") {
      $0["kind"] = .string("context")
      $0["thresholdNs"] = .integer(0)
    }
    for (index, item) in cases.enumerated() {
      let request = try RuntimeOperationRequest(
        requestID: "req-invalid-analysis-\(index)",
        idempotencyKey: "idem-invalid-analysis-\(index)",
        target: DurableTargetReference(targetID: "TGT-TRACE", expectedBindingRevision: nil),
        operation: RuntimeOperationReference(id: "analyzer.analyze-trace", version: 1),
        inputs: item.1)
      do {
        _ = try await engine.submit(try JSONEncoder().encode(request))
        XCTFail("\(item.0) must be rejected before admission")
      } catch let error as RuntimeJobEngineError {
        guard case .rejected(.invalidInput, _) = error else {
          return XCTFail("\(item.0) returned the wrong typed failure: \(error)")
        }
      }
    }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  private func request(
    kind: ArkTraceAnalysisKind,
    timestampNs: Int64? = nil,
    startNs: Int64? = nil,
    endNs: Int64? = nil,
    maxRows: Int = 10_000,
    maxEvents: Int = 10_000,
    limit: Int = 10
  ) throws -> ArkTraceAnalysisRequest {
    ArkTraceAnalysisRequest(
      kind: kind, timestampNs: timestampNs, startNs: startNs, endNs: endNs,
      processKey: nil, pid: nil, threadKey: nil, tid: nil,
      thresholdNs: 0, limit: limit, timeoutMs: 30_000,
      maxRows: maxRows, maxEvents: maxEvents, maxOutputBytes: 8_388_608)
  }

  private func invocation(_ request: ArkTraceAnalysisRequest) -> AnalyzerInvocation {
    AnalyzerInvocation(
      analyzerRef: "trace-analysis@1", analyzerVersion: "0.1.0+1",
      executableSHA256: toolSHA, arguments: request.arguments(sourcePath: sourcePath),
      timeoutSeconds: request.processTimeoutSeconds,
      outputByteBudget: request.maxOutputBytes,
      sourceArtifactID: "artifact-source", sourceSHA256: sourceSHA,
      sourceByteCount: 2_048, arkTraceAnalysisRequest: request,
      arkTraceAnalysisContract: contract)
  }

  private var contract: ArkTraceSummaryInvocationContract {
    ArkTraceSummaryInvocationContract(
      toolVersion: "0.1.0", parserVersion: "4.3.7",
      parserUpstreamRevision: String(repeating: "3", count: 40),
      parserSHA256: parserSHA, parserBuildRecipeVersion: "1",
      parserAdapterVersion: "1", schemaAdapterVersion: "2", indexSchemaVersion: 2)
  }

  private func root(
    _ request: ArkTraceAnalysisRequest,
    traceSHA: String? = nil,
    traceByteCount: Int = 2_048,
    toolSHA runtimeToolSHA: String? = nil
  ) -> [String: JSONValue] {
    let quality = quality()
    let traceDuration: Int64 = 1_000_000_000
    let result: JSONValue = request.kind == .context
      ? contextResult(request, quality: quality, traceDuration: traceDuration)
      : analysisResult(request, quality: quality)
    return [
      "schemaVersion": .string("1.0"),
      "tool": .object([
        "name": .string("arktrace"), "version": .string("0.1.0"),
        "buildRevision": .string(runtimeToolSHA ?? toolSHA),
      ]),
      "request": requestEcho(request),
      "trace": .object([
        "sha256": .string(traceSHA ?? sourceSHA),
        "byteCount": .integer(Int64(traceByteCount)),
        "durationNs": .integer(traceDuration),
        "parser": .object([
          "name": .string("trace_streamer"), "version": .string("4.3.7"),
          "upstreamRevision": .string(String(repeating: "3", count: 40)),
          "binarySha256": .string(parserSHA),
        ]),
        "schemaFingerprint": .string(schemaSHA),
      ]),
      "provenance": .object([
        "parserAdapterVersion": .string("1"),
        "parserBuildRecipeVersion": .string("1"),
        "schemaAdapterVersion": .string("2"), "indexSchemaVersion": .integer(2),
        "upstreamDatabaseSha256": .string(databaseSHA),
        "upstreamDatabaseByteCount": .integer(4_096),
      ]),
      "limits": .object([
        "timeoutMs": .integer(Int64(request.timeoutMs)),
        "maxRows": .integer(Int64(request.maxRows)),
        "maxEvents": .integer(Int64(request.maxEvents)),
        "maxOutputBytes": .integer(Int64(request.maxOutputBytes)),
      ]),
      "dataQuality": quality,
      "truncation": .object(["truncated": .bool(false), "sections": .array([])]),
      "result": result,
    ]
  }

  private func requestEcho(_ request: ArkTraceAnalysisRequest) -> JSONValue {
    var parameters = requestFilterParameters(request, keys: false)
    if request.kind == .context {
      if let timestamp = request.timestampNs {
        parameters["timestampNs"] = .integer(timestamp)
        parameters["windowBeforeNs"] = .integer(50_000_000)
        parameters["windowAfterNs"] = .integer(50_000_000)
        parameters["startNs"] = .null
        parameters["endNs"] = .null
      } else {
        parameters["timestampNs"] = .null
        parameters["windowBeforeNs"] = .null
        parameters["windowAfterNs"] = .null
        parameters["startNs"] = request.startNs.map(JSONValue.integer) ?? .null
        parameters["endNs"] = request.endNs.map(JSONValue.integer) ?? .null
      }
      return .object(["command": .string("context"), "parameters": .object(parameters)])
    }
    let range = request.normalizedRange!
    parameters["kind"] = .string(request.kind.rawValue)
    parameters["startNs"] = .integer(range.startNs)
    parameters["endNs"] = .integer(range.endNs)
    parameters["thresholdNs"] = .integer(request.thresholdNs)
    parameters["limit"] = .integer(Int64(request.limit))
    return .object(["command": .string("analyze"), "parameters": .object(parameters)])
  }

  private func requestFilterParameters(
    _ request: ArkTraceAnalysisRequest, keys: Bool
  ) -> [String: JSONValue] {
    [
      "cpu": .null,
      "processKey": request.processKey.map {
        keys ? .object(["ipid": .integer($0)]) : .integer($0)
      } ?? .null,
      "pid": request.pid.map(JSONValue.integer) ?? .null,
      "threadKey": request.threadKey.map {
        keys ? .object(["itid": .integer($0)]) : .integer($0)
      } ?? .null,
      "tid": request.tid.map(JSONValue.integer) ?? .null,
      "rawState": .null, "normalizedState": .null, "name": .null,
      "nameMatch": .string("exact"), "minimumDurationNs": .null,
      "depth": .null, "counterFilterID": .null,
    ]
  }

  private func contextResult(
    _ request: ArkTraceAnalysisRequest, quality: JSONValue, traceDuration: Int64
  ) -> JSONValue {
    let start: Int64
    let end: Int64
    if let timestamp = request.timestampNs {
      start = max(0, timestamp - 50_000_000)
      end = min(traceDuration, timestamp + 50_000_000)
    } else {
      start = request.startNs!
      end = request.endNs!
    }
    let section = status(returned: 0)
    let summaryStatus = status(returned: 1)
    return .object([
      "range": range(start, end), "filters": .object(requestFilterParameters(request, keys: true)),
      "processes": .array([]), "threads": .array([]), "cpuSlices": .array([]),
      "threadStates": .array([]), "slices": .array([]), "counters": .array([]),
      "summary": .object([
        "range": range(start, end), "durationNs": .integer(end - start),
        "cpuCount": .null, "processCount": .integer(0), "threadCount": .integer(0),
        "cpuSliceCount": .null, "threadStateCount": .null, "namedSliceCount": .null,
        "counterSeriesCount": .null, "eventCountBySource": .array([]),
        "capabilities": .object([
          "cpuScheduling": .bool(false), "threadStates": .bool(false),
          "namedSlices": .bool(false), "cpuCounters": .bool(false),
          "processCounters": .bool(false),
        ]),
        "schemaFingerprint": .string(schemaSHA), "dataQuality": quality,
        "truncatedSections": .array([]),
      ]),
      "dataQuality": quality,
      "truncation": .object([
        "processes": section, "threads": section, "cpuSlices": section,
        "threadStates": section, "slices": section, "counters": section,
        "summary": summaryStatus, "referenceOmittedByBudget": .bool(false),
      ]),
    ])
  }

  private func analysisResult(
    _ request: ArkTraceAnalysisRequest, quality: JSONValue
  ) -> JSONValue {
    let rangeValue = request.normalizedRange!
    let section = status(returned: 0)
    let seconds = request.timeoutMs / 1_000
    let attoseconds = Int64(request.timeoutMs % 1_000) * 1_000_000_000_000_000
    return .object([
      "kind": .string(request.kind.rawValue),
      "analysis": .object([
        "kind": .string("deterministicBatch"),
        "parameters": .object([
          "filters": .object(requestFilterParameters(request, keys: true)),
          "maximumCPUSlices": .integer(Int64(request.maxEvents)),
          "maximumProcessSlices": .integer(Int64(request.maxEvents)),
          "maximumThreadSlices": .integer(Int64(request.maxEvents)),
          "maximumStateIntervals": .integer(Int64(request.maxEvents)),
          "maximumNamedSlices": .integer(Int64(request.maxEvents)),
          "maximumSchedulingEvents": .integer(Int64(request.maxEvents)),
          "maximumHotEvents": .integer(Int64(request.maxEvents)),
          "topProcessLimit": .integer(Int64(request.limit)),
          "topThreadLimit": .integer(Int64(request.limit)),
          "longSliceLimit": .integer(Int64(request.limit)),
          "schedulingSampleLimit": .integer(Int64(request.limit)),
          "hotIntervalLimit": .integer(Int64(request.limit)),
          "hotBucketCount": .integer(100),
          "minimumLongSliceDurationNs": .integer(request.thresholdNs),
          "timeoutSeconds": .integer(Int64(seconds)),
          "timeoutAttoseconds": .integer(attoseconds),
        ]),
        "range": range(rangeValue.startNs, rangeValue.endNs),
        "cpuUtilization": .array([]), "topProcesses": .array([]),
        "topThreads": .array([]), "longSlices": .array([]),
        "threadStateDistribution": .array([]),
        "schedulingLatency": .object([
          "supported": .bool(false),
          "unsupportedReason": .string("noProvableRunnableTransitions"),
          "count": .integer(0), "percentiles": .null,
          "topSamples": .array([]), "truncated": .bool(false),
        ]),
        "hotIntervals": .array([]),
        "sections": .object([
          "cpuUtilization": section, "topProcesses": section, "topThreads": section,
          "longSlices": section, "threadStateDistribution": section,
          "schedulingLatency": section, "hotIntervals": section,
        ]),
        "dataQuality": quality,
      ]),
    ])
  }

  private func quality() -> JSONValue {
    .object(["status": .string("ok"), "warnings": .array([])])
  }

  private func status(returned: Int) -> JSONValue {
    .object([
      "returnedCount": .integer(Int64(returned)),
      "matchedCount": .integer(Int64(returned)), "truncated": .bool(false),
    ])
  }

  private func range(_ start: Int64, _ end: Int64) -> JSONValue {
    .object(["startNs": .integer(start), "endNs": .integer(end)])
  }

  private func encoded(_ root: [String: JSONValue]) throws -> Data {
    try JSONEncoder().encode(JSONValue.object(root))
  }

  private func replacingObject(
    _ root: [String: JSONValue], key: String,
    mutate: (inout [String: JSONValue]) -> Void
  ) -> [String: JSONValue] {
    var root = root
    guard case .object(var object)? = root[key] else { return root }
    mutate(&object)
    root[key] = .object(object)
    return root
  }

  private func replacingNestedObject(
    _ root: [String: JSONValue], first: String, second: String,
    mutate: (inout [String: JSONValue]) -> Void
  ) -> [String: JSONValue] {
    replacingObject(root, key: first) { firstObject in
      guard case .object(var secondObject)? = firstObject[second] else { return }
      mutate(&secondObject)
      firstObject[second] = .object(secondObject)
    }
  }
}
