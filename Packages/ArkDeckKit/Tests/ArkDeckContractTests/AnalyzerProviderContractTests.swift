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

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class AnalyzerProviderContractTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-analyzer-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
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
    let result = #"{"signature":"SIGABRT"}"#
    let outcome = try provider.verify(
      receipt: receipt(exitStatus: 0, stdout: result),
      action: action, context: context(artifact))
    guard case .verified(let summary) = outcome else {
      return XCTFail("a structured result is a successful analysis")
    }
    XCTAssertEqual(summary["analyzerRef"], "crash-signature@1")
    XCTAssertEqual(summary["analyzerVersion"], "1.4.2")
    XCTAssertEqual(summary["sourceArtifactId"], artifact.artifactID)
    XCTAssertEqual(summary["sourceSha256"], artifact.sha256)
    XCTAssertEqual(summary["derivedByteCount"], String(result.utf8.count))
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
    for reference in [
      AnalyzerProvider.crashSignature, AnalyzerProvider.hilogSummary,
      AnalyzerProvider.traceSummary,
    ] {
      let operation = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: reference))
      guard case .unavailable(let reason) = bare.runtimeAvailability(for: operation) else {
        return XCTFail("\(reference) must be unavailable with no profile")
      }
      // Machine-readable, and admission stops here: no capability is spent
      // on an analyzer this host was never given (PRODUCT-LOOP §8).
      XCTAssertEqual(reason, "analyzer.profileUnavailable")
    }
  }

  func testAToolThatDriftedFromItsPinIsUnavailable() throws {
    let provider = AnalyzerProvider(profiles: [
      AnalyzerProfile(
        analyzerRef: "crash-signature@1", analyzerVersion: "1.4.2",
        executablePath: "/bin/cat", executableSHA256: String(repeating: "a", count: 64))
    ])
    let operation = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: AnalyzerProvider.crashSignature))
    guard case .unavailable(let reason) = provider.runtimeAvailability(for: operation) else {
      return XCTFail("a drifted tool must not be admitted")
    }
    XCTAssertEqual(reason, "analyzer.toolIdentityDrift")
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

  // MARK: - Helpers

  private struct RefusingDispatcher: RuntimeProcessDispatching {
    func unavailableReason(providerID: String) -> String? { "not routed in this test" }
    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      throw RuntimeDispatchFailure.failed("not routed in this test")
    }
  }

  private func toolDigest() throws -> String {
    let bytes = try Data(contentsOf: URL(fileURLWithPath: "/bin/cat"))
    return AnalyzerProvider.sha256(bytes)
  }

  private func makeProvider() throws -> AnalyzerProvider {
    AnalyzerProvider(profiles: [
      AnalyzerProfile(
        analyzerRef: "crash-signature@1", analyzerVersion: "1.4.2",
        executablePath: "/bin/cat", executableSHA256: try toolDigest(),
        fixedArguments: ["--emit-json"])
    ])
  }

  private func descriptor() -> CatalogOperationDescriptor {
    RuntimeOperationCatalog.descriptor(reference: AnalyzerProvider.crashSignature)!
  }

  private func step() -> CatalogStepDescriptor {
    descriptor().steps[0]
  }

  private func sourceArtifact(contents: String) throws -> ProviderResolvedInputArtifact {
    let url = root.appendingPathComponent("crash-\(UUID().uuidString.prefix(6)).txt")
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
}
