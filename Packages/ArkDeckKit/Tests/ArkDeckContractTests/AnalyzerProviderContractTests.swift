// Deterministic analyzer contract tests (CHG-2026-055, TASK-HFA-007).
//
// Registered acceptance: HFA-AC-15 (determinism, versioning and complete
// provenance), HFA-AC-16 (an external tool cannot take the engine-internal
// shortcut, and an unconfigured analyzer is unavailable rather than
// improvised).
//
// The reason this provider exists is that TASK-HFA-001's crash judgement is
// correct but anonymous: nothing recorded which parser produced it, at what
// version, from which bytes. Every assertion below is about making that
// answerable.

import XCTest
import Darwin

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

private struct AnalyzerResultDispatcher: RuntimeProcessDispatching {
  let output: Data

  func unavailableReason(providerID: String) -> String? { nil }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    ProviderProcessReceipt(
      exitStatus: 0, stdout: output, stderr: Data(), stdoutTruncated: false,
      durationSeconds: 0.001)
  }
}

final class AnalyzerProviderContractTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    guard let physicalTemporaryPath = realpath(
      FileManager.default.temporaryDirectory.path, nil)
    else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { free(physicalTemporaryPath) }
    root = URL(
      filePath: String(cString: physicalTemporaryPath), directoryHint: .isDirectory
    )
      .appending(path: "arkdeck-analyzer-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  // MARK: - HFA-AC-15: same bytes in, same bytes out, and it says where from

  func testTheSameArtifactProducesTheSameActionAndTheSamePlan() throws {
    let provider = try makeProvider()
    let artifact = try sourceArtifact(contents: "Reason:Signal SIGABRT\n")
    let first = try provider.action(
      for: step(), operation: descriptor(), inputs: [:], context: context(artifact))
    let second = try provider.action(
      for: step(), operation: descriptor(), inputs: [:], context: context(artifact))
    XCTAssertEqual(first, second)

    let plan = try provider.lower(action: first, context: context(artifact))
    guard case .process(let executable, let argv, _) = plan.kind else {
      return XCTFail("an analysis must lower to a pinned process plan")
    }
    // The analyzer is named by the operation, and the only variable argument
    // is the artifact the engine already resolved.
    XCTAssertEqual(executable, try toolDigest())
    XCTAssertEqual(argv, ["--emit-json", artifact.fileURL.path])
  }

  func testTheDerivedResultCarriesItsWholeProvenance() throws {
    let provider = try makeProvider()
    let artifact = try sourceArtifact(contents: "Reason:Signal SIGABRT\n")
    let action = try provider.action(
      for: step(), operation: descriptor(), inputs: [:], context: context(artifact))
    let result = try HarnessCrashLedgerDerivedAnalyzer.analyze(
      Data("Fault log list:\n******\n******\n".utf8))
    let outcome = try provider.verify(
      receipt: receipt(exitStatus: 0, stdout: result),
      action: action, context: context(artifact))
    guard case .verified(let summary) = outcome else {
      return XCTFail("a structured result is a successful analysis")
    }
    XCTAssertEqual(summary["analyzerRef"], "crash-signature@1")
    XCTAssertEqual(summary["analyzerVersion"], HarnessCrashLedgerAnalysis.analyzerVersion)
    XCTAssertEqual(summary["sourceArtifactId"], artifact.artifactID)
    XCTAssertEqual(summary["sourceSha256"], artifact.sha256)
    XCTAssertEqual(summary["derivedByteCount"], String(result.count))
    // A conclusion has to be traceable to the exact bytes it came from and
    // the exact code that produced it, or it is only an opinion.
    XCTAssertEqual(summary["derivedSha256"]?.count, 64)
  }

  func testAnArtifactThatDoesNotMatchItsLeaseIsRefused() throws {
    let provider = try makeProvider()
    let artifact = try sourceArtifact(contents: "Reason:Signal SIGABRT\n")
    let lying = ProviderResolvedInputArtifact(
      artifactID: artifact.artifactID, fileURL: artifact.fileURL,
      sha256: String(repeating: "0", count: 64), byteCount: artifact.byteCount)
    XCTAssertThrowsError(
      try provider.action(
        for: step(), operation: descriptor(), inputs: [:], context: context(lying))
    ) { error in
      // The lease is the claim; the bytes are the fact.
      XCTAssertTrue("\(error)".contains("do not match their lease"))
    }
  }

  func testArtifactMutationAndSymlinkAreRefusedImmediatelyBeforeLowering() throws {
    let provider = try makeProvider()
    let artifact = try sourceArtifact(contents: "immutable lease bytes\n")
    try Data("mutated after lease\n".utf8).write(to: artifact.fileURL)
    XCTAssertThrowsError(
      try provider.action(
        for: step(), operation: descriptor(), inputs: [:], context: context(artifact)))

    let physical = try sourceArtifact(contents: "physical bytes\n")
    let linkedURL = root.appending(path: "linked-source.txt")
    try FileManager.default.createSymbolicLink(
      at: linkedURL, withDestinationURL: physical.fileURL)
    let linked = ProviderResolvedInputArtifact(
      artifactID: physical.artifactID, fileURL: linkedURL,
      sha256: physical.sha256, byteCount: physical.byteCount)
    XCTAssertThrowsError(
      try provider.action(
        for: step(), operation: descriptor(), inputs: [:], context: context(linked)))
  }

  func testAnEmptyOrUnstructuredResultIsAFailureAndNotAConclusion() throws {
    let provider = try makeProvider()
    let artifact = try sourceArtifact(contents: "Reason:Signal SIGABRT\n")
    let action = try provider.action(
      for: step(), operation: descriptor(), inputs: [:], context: context(artifact))

    let empty = try provider.verify(
      receipt: receipt(exitStatus: 0, stdout: ""), action: action, context: context(artifact))
    guard case .failed(let emptyCode, _) = empty else {
      return XCTFail("no output is not a finding of 'nothing found'")
    }
    XCTAssertEqual(emptyCode, "analyzer.emptyResult")

    // The descriptor promises a .json artifact; text under that name would
    // break every downstream reader that believes it.
    let text = try provider.verify(
      receipt: receipt(exitStatus: 0, stdout: "SIGABRT at frame 3"),
      action: action, context: context(artifact))
    guard case .failed(let textCode, _) = text else {
      return XCTFail("unstructured output must not be published as a structured artifact")
    }
    XCTAssertEqual(textCode, "analyzer.malformedResult")

    let broken = try provider.verify(
      receipt: receipt(exitStatus: 2, stdout: ""), action: action, context: context(artifact))
    guard case .failed(let brokenCode, _) = broken else {
      return XCTFail("a non-zero exit is a failed analysis")
    }
    XCTAssertEqual(brokenCode, "analyzer.failed")
  }

  func testRecoveryOfAnAnalysisConfirmsNothingHappened() async throws {
    let provider = try makeProvider()
    let artifact = try sourceArtifact(contents: "x\n")
    let action = try provider.action(
      for: step(), operation: descriptor(), inputs: [:], context: context(artifact))
    let outcome = try await provider.reconcile(
      intent: ProviderDurableIntentReference(
        jobID: "job-analyzer", stepID: "extract-crash-signature",
        intentEventID: "evt-analyzer", action: action),
      context: context(artifact))
    XCTAssertEqual(outcome, .confirmedNotExecuted)
    XCTAssertNil(
      try provider.reconciliationReadback(
        intent: ProviderDurableIntentReference(
          jobID: "job-analyzer", stepID: "extract-crash-signature",
          intentEventID: "evt-analyzer", action: action),
        context: context(artifact)))
  }

  // MARK: - HFA-AC-16: no shortcut, no improvisation

  func testAnUnconfiguredAnalyzerIsUnavailableRatherThanImprovised() throws {
    let bare = AnalyzerProvider()
    for reference in [AnalyzerProvider.crashSignature, AnalyzerProvider.traceSummary] {
      let operation = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: reference))
      guard case .unavailable(let code, let reason) = bare.runtimeAvailability(for: operation)
      else {
        return XCTFail("\(reference) must be unavailable with no profile")
      }
      // Machine-readable, and admission stops here: no capability is spent
      // on an analyzer this host was never given (PRODUCT-LOOP §8). The code is
      // what a caller branches on; the prose is for whoever reads the log.
      XCTAssertEqual(code, .providerToolUnavailable)
      XCTAssertEqual(reason, "analyzer.profileUnavailable")
      // And it stays the operator's to fix: one is an ARKDECK_ANALYZER_PATH
      // away, the other an installed ArkTrace descriptor away.
      XCTAssertEqual(code.origin, .hostConfiguration, reference)
    }
  }

  /// `hilog-summary@1` is declared by the catalog and produced by nothing.
  /// It used to answer with the same code as an analyzer that is one setting
  /// away, which sent an operator looking for a setting that does not exist.
  func testAnAnalyzerNothingSuppliesIsNotReportedAsUnconfigured() throws {
    let bare = AnalyzerProvider()
    let operation = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: AnalyzerProvider.hilogSummary))
    guard case .unavailable(let code, let reason) = bare.runtimeAvailability(for: operation)
    else {
      return XCTFail("summarize-hilog must be unavailable")
    }
    XCTAssertEqual(code, .operationNotSupported)
    XCTAssertEqual(reason, "analyzer.notImplemented")
    XCTAssertEqual(code.origin, .productBuild)
  }

  /// Stated over the catalog rather than over today's list, so declaring a new
  /// analyzer forces a decision about whether anything can supply it instead
  /// of inheriting either answer by being forgotten.
  func testEveryDeclaredAnalyzerIsEitherSuppliableOrKnownUnimplemented() {
    let declared = Set(AnalyzerProvider.analyzerForOperation.values)
    XCTAssertTrue(
      AnalyzerProvider.hostSuppliableAnalyzers.isSubset(of: declared),
      "a suppliable analyzer that no operation names is dead vocabulary")
    XCTAssertEqual(
      declared.subtracting(AnalyzerProvider.hostSuppliableAnalyzers), ["hilog-summary@1"],
      "a newly declared analyzer must be added to hostSuppliableAnalyzers, or listed here "
        + "as one this build does not implement")
  }

  func testAToolThatDriftedFromItsPinIsUnavailable() throws {
    let provider = try AnalyzerProvider(profiles: [
      AnalyzerProfile(
        analyzerRef: "crash-signature@1",
        analyzerVersion: HarnessCrashLedgerAnalysis.analyzerVersion,
        executablePath: "/bin/cat", executableSHA256: String(repeating: "a", count: 64))
    ])
    let operation = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: AnalyzerProvider.crashSignature))
    guard case .unavailable(let code, let reason) = provider.runtimeAvailability(for: operation)
    else {
      return XCTFail("a drifted tool must not be admitted")
    }
    XCTAssertEqual(code, .toolIdentityDrift)
    XCTAssertEqual(reason, "analyzer.toolIdentityDrift")
  }

  func testActionSpecificResolverSelectsEachPinnedAnalyzerIndependentOfProfileOrder() throws {
    let cat = try executableProfile(
      analyzerRef: "crash-signature@1", path: "/bin/cat", fixedArguments: ["--emit-json"])
    let echo = try executableProfile(
      analyzerRef: "trace-summary@1", path: "/bin/echo",
      fixedArguments: ["summary", "--json", "--max-rows", "1000"])
    let artifact = try sourceArtifact(contents: "trace bytes")

    func resolved(_ profiles: [AnalyzerProfile], operationReference: String) throws
      -> ResolvedExecutable
    {
      let provider = try AnalyzerProvider(profiles: profiles)
      let operation = try XCTUnwrap(
        RuntimeOperationCatalog.descriptor(reference: operationReference))
      let action = try provider.action(
        for: operation.steps[0], operation: operation, inputs: [:], context: context(artifact))
      return try AnalyzerExecutableResolver(profiles: profiles).resolveExecutable(for: action)
    }

    XCTAssertEqual(
      try resolved([cat, echo], operationReference: AnalyzerProvider.crashSignature).path,
      "/bin/cat")
    XCTAssertEqual(
      try resolved([cat, echo], operationReference: AnalyzerProvider.traceSummary).path,
      "/bin/echo")
    XCTAssertEqual(
      try resolved([echo, cat], operationReference: AnalyzerProvider.crashSignature).path,
      "/bin/cat")
    XCTAssertEqual(
      try resolved([echo, cat], operationReference: AnalyzerProvider.traceSummary).path,
      "/bin/echo")
  }

  func testDuplicateUnknownAndActionIdentityDriftProfilesFailClosed() throws {
    let crash = try executableProfile(analyzerRef: "crash-signature@1", path: "/bin/cat")
    XCTAssertThrowsError(try AnalyzerProvider(profiles: [crash, crash])) { error in
      XCTAssertEqual(error as? AnalyzerProfileValidationError, .duplicateAnalyzerRef(crash.analyzerRef))
    }
    let unknown = try executableProfile(analyzerRef: "caller-selected@1", path: "/bin/cat")
    XCTAssertThrowsError(try AnalyzerExecutableResolver(profiles: [unknown])) { error in
      XCTAssertEqual(
        error as? AnalyzerProfileValidationError, .unknownAnalyzerRef(unknown.analyzerRef))
    }

    let resolver = try AnalyzerExecutableResolver(profiles: [crash])
    let forged = TypedProviderAction.analyzer(
      .analyze(
        AnalyzerInvocation(
          analyzerRef: crash.analyzerRef,
          analyzerVersion: crash.analyzerVersion,
          executableSHA256: String(repeating: "0", count: 64),
          arguments: ["--emit-json", "/tmp/input"],
          timeoutSeconds: 30,
          outputByteBudget: 8 * 1024 * 1024,
          sourceArtifactID: "art-source",
          sourceSHA256: String(repeating: "1", count: 64),
          sourceByteCount: 1)))
    XCTAssertThrowsError(try resolver.resolveExecutable(for: forged))
  }

  func testDurableAnalyzerInvocationWithoutAdditiveOutputBudgetStillDecodes() throws {
    let historical = Data(
      #"{"analyzerRef":"crash-signature@1","analyzerVersion":"1.0.0","executableSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","arguments":["--emit-json","/private/runtime/input"],"timeoutSeconds":30,"sourceArtifactID":"art-source","sourceSHA256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sourceByteCount":12}"#.utf8)
    let decoded = try JSONDecoder().decode(AnalyzerInvocation.self, from: historical)
    XCTAssertNil(decoded.outputByteBudget)
    XCTAssertNil(decoded.arkTraceSummaryContract)
    XCTAssertEqual(decoded.analyzerRef, "crash-signature@1")
    XCTAssertEqual(decoded.sourceByteCount, 12)
  }

  func testAnAnalysisPlanIsRefusedWhenNoAnalyzerRouteIsRegistered() async throws {
    // The workspace route owns a different executable set. Sending an
    // analysis down it would run one provider's plan under another's
    // identity check.
    let router = RuntimeProcessDispatcherRouter(
      hdc: RefusingDispatcher(), rockchip: RefusingDispatcher(),
      workspace: RefusingDispatcher())
    XCTAssertEqual(
      router.unavailableReason(providerID: "analyzer"),
      "no dispatcher route is registered for provider analyzer")

    let provider = try makeProvider()
    let artifact = try sourceArtifact(contents: "x\n")
    let plan = try provider.lower(
      action: try provider.action(
        for: step(), operation: descriptor(), inputs: [:], context: context(artifact)),
      context: context(artifact))
    do {
      _ = try await router.dispatch(plan)
      XCTFail("an analysis must not be dispatched without its own route")
    } catch {}
  }

  func testTheCatalogPublishesAnalyzersAsHostOnlyReads() throws {
    for reference in [
      AnalyzerProvider.crashSignature, AnalyzerProvider.hilogSummary,
      AnalyzerProvider.traceSummary,
    ] {
      let operation = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: reference))
      XCTAssertEqual(operation.provider, .analyzer)
      XCTAssertEqual(operation.binding, WorkflowBindingRequirement.none)
      XCTAssertEqual(operation.minimumEffect, .hostOnly)
      XCTAssertEqual(operation.steps.count, 1)
      XCTAssertEqual(operation.steps[0].kind, .runDeterministicAnalyzer)
      // The declared artifact name and the engine's materialized argument
      // come from one table, so they cannot drift apart.
      let analyzerRef = try XCTUnwrap(AnalyzerProvider.analyzerForOperation[reference])
      XCTAssertEqual(
        operation.artifacts.map(\.name), [AnalyzerProvider.derivedArtifactName(analyzerRef)])
    }
  }

  func testRuntimeAnalyzesADeviceBoundArtifactWithoutClaimingADeviceBoundJob()
    async throws
  {
    let state = root.appending(path: "runtime", directoryHint: .isDirectory)
    let artifactStore = try RuntimeArtifactStore(
      rootURL: state.appending(path: "artifacts", directoryHint: .isDirectory),
      nowUTC: { "2026-07-31T00:00:00Z" })
    let raw = Data("Fault log list:\n******\n******\n".utf8)
    let source = try await artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "JOB-CAPTURE", sessionID: "HTASK-0123456789AB",
        stepID: "capture-crash-index", name: "crash-index.txt",
        mediaType: "text/plain", privacy: .standard,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "capture.diagnostics@1", providerID: "hdc",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-1", bindingRevision: 7,
          stableIdentitySHA256: String(repeating: "c", count: 64)),
        contents: raw))
    let lease = try await artifactStore.leaseReference(
      jobID: source.jobID, artifactID: source.artifactID)
    let output = try HarnessCrashLedgerDerivedAnalyzer.analyze(raw)
    let provider = try makeProvider()
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: state.appending(path: "capabilities", directoryHint: .isDirectory))
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(path: "engine", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: AnalyzerResultDispatcher(output: output),
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-07-31T00:00:00Z" })

    func request(targetID: String) throws -> Data {
      let request = try RuntimeOperationRequest(
        requestID: "req-\(targetID.lowercased())",
        idempotencyKey: "idem-\(UUID().uuidString.lowercased())",
        target: DurableTargetReference(
          targetID: targetID, expectedBindingRevision: nil),
        operation: RuntimeOperationReference(
          id: "analyzer.extract-crash-signature", version: 1),
        inputs: ["sourceArtifactRef": .string(lease)])
      return try JSONEncoder().encode(request)
    }

    do {
      _ = try await engine.submit(try request(targetID: "TGT-OTHER"))
      XCTFail("an analyzer may not detach an Artifact from its source target")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(_, let detail) = error else { return XCTFail("\(error)") }
      XCTAssertTrue(detail.contains("not resolvable"), detail)
    }

    let acceptance = try await engine.submit(try request(targetID: "TGT-1"))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", "timeline: \(status.timeline)")
    let inventory = try await artifactStore.list(jobID: acceptance.jobID)
    let derived = try XCTUnwrap(
      inventory.first { $0.name == "crash-signature.json" && $0.status.isPublished })
    XCTAssertNil(derived.bindingSnapshot.bindingRevision)
    XCTAssertNil(derived.bindingSnapshot.stableIdentitySHA256)
    let bytes = try await artifactStore.read(
      jobID: acceptance.jobID, artifactID: derived.artifactID)
    let envelope = try JSONDecoder().decode(
      HarnessCrashLedgerDerivedArtifact.self, from: bytes)
    XCTAssertEqual(envelope.sourceArtifactID, source.artifactID)
    XCTAssertEqual(envelope.sourceSHA256, source.sha256)
    XCTAssertEqual(envelope.result.status, .answered)
  }

  // MARK: - Helpers

  private struct RefusingDispatcher: RuntimeProcessDispatching {
    func unavailableReason(providerID: String) -> String? { "not routed in this test" }
    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      throw RuntimeDispatchFailure.failed("not routed in this test")
    }
  }

  private func toolDigest() throws -> String {
    let bytes = try Data(contentsOf: URL(filePath: "/bin/cat"))
    return AnalyzerProvider.sha256(bytes)
  }

  private func makeProvider() throws -> AnalyzerProvider {
    try AnalyzerProvider(profiles: [
      AnalyzerProfile(
        analyzerRef: "crash-signature@1",
        analyzerVersion: HarnessCrashLedgerAnalysis.analyzerVersion,
        executablePath: "/bin/cat", executableSHA256: try toolDigest(),
        fixedArguments: ["--emit-json"])
    ])
  }

  private func executableProfile(
    analyzerRef: String,
    path: String,
    fixedArguments: [String] = []
  ) throws -> AnalyzerProfile {
    let bytes = try Data(contentsOf: URL(filePath: path))
    let traceContract =
      analyzerRef == "trace-summary@1"
      ? ArkTraceSummaryInvocationContract(
        toolVersion: "0.1.0", parserVersion: "4.3.7",
        parserUpstreamRevision: String(repeating: "1", count: 40),
        parserSHA256: String(repeating: "2", count: 64),
        parserBuildRecipeVersion: String(repeating: "3", count: 64),
        parserAdapterVersion: "1", schemaAdapterVersion: "2", indexSchemaVersion: 2)
      : nil
    return AnalyzerProfile(
      analyzerRef: analyzerRef,
      analyzerVersion: "1.0.0",
      executablePath: path,
      executableSHA256: AnalyzerProvider.sha256(bytes),
      fixedArguments: fixedArguments,
      timeoutSeconds: 30,
      outputByteBudget: 8 * 1024 * 1024,
      arkTraceSummaryContract: traceContract)
  }

  private func descriptor() -> CatalogOperationDescriptor {
    RuntimeOperationCatalog.descriptor(reference: AnalyzerProvider.crashSignature)!
  }

  private func step() -> CatalogStepDescriptor {
    descriptor().steps[0]
  }

  private func sourceArtifact(contents: String) throws -> ProviderResolvedInputArtifact {
    let url = root.appending(path: "crash-\(UUID().uuidString.prefix(6)).txt")
    let bytes = Data(contents.utf8)
    try bytes.write(to: url)
    return ProviderResolvedInputArtifact(
      artifactID: "art-\(AnalyzerProvider.sha256(bytes).prefix(12))",
      fileURL: url, sha256: AnalyzerProvider.sha256(bytes), byteCount: bytes.count)
  }

  private func context(_ artifact: ProviderResolvedInputArtifact) -> ProviderExecutionContext {
    ProviderExecutionContext(
      jobID: "job-analyzer", stepID: "extract-crash-signature", targetID: "analyzer-host",
      bindingRevision: nil, nowUTC: "2026-07-31T00:00:00Z", resolvedInputArtifact: artifact)
  }

  private func receipt(exitStatus: Int32, stdout: String) -> ProviderProcessReceipt {
    ProviderProcessReceipt(
      exitStatus: exitStatus, stdout: Data(stdout.utf8), stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.004)
  }

  private func receipt(exitStatus: Int32, stdout: Data) -> ProviderProcessReceipt {
    ProviderProcessReceipt(
      exitStatus: exitStatus, stdout: stdout, stderr: Data(),
      stdoutTruncated: false, durationSeconds: 0.004)
  }
}
