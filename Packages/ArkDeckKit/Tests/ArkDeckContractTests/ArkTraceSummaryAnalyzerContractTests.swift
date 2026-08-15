import Foundation
import Darwin
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckProcess
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

private final class StubArkTraceDoctorProbe: ArkTraceDoctorProbing, @unchecked Sendable {
  private let lock = NSLock()
  private let result: Bool
  private(set) var contracts: [ArkTraceDoctorContract] = []

  init(result: Bool) { self.result = result }

  func probe(_ contract: ArkTraceDoctorContract) async -> Bool {
    lock.withLock { contracts.append(contract) }
    return result
  }
}

private struct StubArkTraceDistributionTrustChecker: ArkTraceDistributionTrustChecking {
  let succeeds: Bool

  init(succeeds: Bool = true) { self.succeeds = succeeds }

  func validate(
    _ contract: ArkTraceDistributionTrustContract
  ) throws -> ArkTraceDistributionTrustEvidence {
    guard succeeds else { throw ArkTraceSummaryProfileError.contractMismatch }
    return ArkTraceDistributionTrustEvidence(
      pinnedTrees: [
        AnalyzerPinnedTree(
          path: contract.appPath,
          sha256: try ArkTraceDistributionTreeHasher.digest(rootPath: contract.appPath))
      ])
  }
}

private struct MutatingArkTraceDistributionTrustChecker: ArkTraceDistributionTrustChecking {
  let mutation: @Sendable () throws -> Void

  func validate(
    _ contract: ArkTraceDistributionTrustContract
  ) throws -> ArkTraceDistributionTrustEvidence {
    try mutation()
    return ArkTraceDistributionTrustEvidence()
  }
}

private final class FixedArkTraceSummaryDispatcher:
  RuntimeProcessDispatching, @unchecked Sendable
{
  private let lock = NSLock()
  private let output: Data

  init(output: Data) { self.output = output }

  var dispatchCount: Int { lock.withLock { dispatches } }
  private var dispatches = 0

  func unavailableReason(providerID: String) -> String? { nil }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    lock.withLock { dispatches += 1 }
    return ProviderProcessReceipt(
      exitStatus: 0, stdout: output, stderr: Data(), stdoutTruncated: false,
      durationSeconds: 0.01)
  }
}

private struct FailingArkTraceSummaryDispatcher: RuntimeProcessDispatching {
  let failure: RuntimeDispatchFailure

  func unavailableReason(providerID: String) -> String? { nil }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    throw failure
  }
}

private final class CountingArkTraceSummaryDispatcher:
  RuntimeProcessDispatching, @unchecked Sendable
{
  private let lock = NSLock()
  private var dispatches = 0

  var dispatchCount: Int { lock.withLock { dispatches } }

  func unavailableReason(providerID: String) -> String? { nil }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    lock.withLock { dispatches += 1 }
    throw RuntimeDispatchFailure.outcomeUnknown(
      "recovery attempted to redispatch the original analyzer process")
  }
}

private final class BlockingArkTraceSummaryDispatcher:
  RuntimeProcessDispatching, @unchecked Sendable
{
  private let lock = NSLock()
  private let output: Data
  private let cancellationResolution: RuntimeDispatchCancellationResolution
  private let holdCancellationResolution: Bool
  private var started = false
  private var cancelled = false
  private var cancellationResolutionReleased = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var operationContinuation: CheckedContinuation<Void, Never>?
  private var cancellationResolutionContinuation: CheckedContinuation<Void, Never>?

  init(
    output: Data,
    cancellationResolution: RuntimeDispatchCancellationResolution = .drained,
    holdCancellationResolution: Bool = false
  ) {
    self.output = output
    self.cancellationResolution = cancellationResolution
    self.holdCancellationResolution = holdCancellationResolution
  }

  var observedCancellation: Bool { lock.withLock { cancelled } }

  func unavailableReason(providerID: String) -> String? { nil }

  func waitUntilStarted() async {
    await withCheckedContinuation { continuation in
      let resumeNow = lock.withLock { () -> Bool in
        if started { return true }
        startWaiters.append(continuation)
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }

  func releaseCancellationResolution() {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      cancellationResolutionReleased = true
      defer { cancellationResolutionContinuation = nil }
      return cancellationResolutionContinuation
    }
    continuation?.resume()
  }

  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      started = true
      let captured = startWaiters
      startWaiters.removeAll()
      return captured
    }
    waiters.forEach { $0.resume() }
    do {
      try await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          let resumeNow = lock.withLock { () -> Bool in
            if cancelled { return true }
            operationContinuation = continuation
            return false
          }
          if resumeNow { continuation.resume() }
        }
        try Task.checkCancellation()
      } onCancel: {
        let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
          self.cancelled = true
          defer { self.operationContinuation = nil }
          return self.operationContinuation
        }
        continuation?.resume()
      }
    } catch is CancellationError {
      if holdCancellationResolution {
        await withCheckedContinuation { continuation in
          let resumeNow = lock.withLock { () -> Bool in
            if cancellationResolutionReleased { return true }
            cancellationResolutionContinuation = continuation
            return false
          }
          if resumeNow { continuation.resume() }
        }
      }
      throw cancellationResolution
    }
    return ProviderProcessReceipt(
      exitStatus: 0, stdout: output, stderr: Data(), stdoutTruncated: false,
      durationSeconds: 0.01)
  }
}

private actor AnalyzerDispatchInstallBarrier {
  private var reached = false
  private var released = false
  private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func waitAtBoundary() async {
    reached = true
    let waiters = reachedWaiters
    reachedWaiters.removeAll()
    waiters.forEach { $0.resume() }
    if released { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func waitUntilReached() async {
    if reached { return }
    await withCheckedContinuation { reachedWaiters.append($0) }
  }

  func release() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }
}

private final class AnalyzerLaunchCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func record() { lock.withLock { value += 1 } }
  var count: Int { lock.withLock { value } }
}

final class ArkTraceSummaryAnalyzerContractTests: XCTestCase {
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
      .appending(path: "arkdeck-arktrace-profile-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testReviewedDistributionPassesProductionTrustDoctorAndSummaryWhenProvided() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard
      let descriptorPath = environment["ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR"],
      let sourcePath = environment["ARKDECK_REVIEWED_ARKTRACE_FIXTURE"]
    else {
      throw XCTSkip(
        "set ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR and ARKDECK_REVIEWED_ARKTRACE_FIXTURE "
          + "for the reviewed signed App gate")
    }
    let home = root.appending(path: "reviewed-doctor-home", directoryHint: .isDirectory)
    let snapshots = root.appending(
      path: "reviewed-profile-snapshots", directoryHint: .isDirectory)
    let profiles = try await ArkTraceSummaryAnalyzerProfileLoader(
      doctor: ProductionArkTraceDoctorProbe(homeURL: home),
      snapshotRootURL: snapshots)
      .loadProfiles(descriptorURL: URL(filePath: descriptorPath))
    let profile = try XCTUnwrap(profiles.first { $0.analyzerRef == "trace-summary@1" })
    let analysisProfile = try XCTUnwrap(
      profiles.first { $0.analyzerRef == "trace-analysis@1" })

    XCTAssertEqual(profile.analyzerRef, "trace-summary@1")
    XCTAssertEqual(profile.analyzerVersion, "0.1.0+1")
    XCTAssertTrue(profile.executablePath.hasPrefix(snapshots.path + "/"))
    XCTAssertGreaterThan(profile.pinnedFiles.count, 20)
    XCTAssertTrue(
      profile.pinnedFiles.allSatisfy { $0.path.hasPrefix(snapshots.path + "/") })
    XCTAssertTrue(profile.pinnedFiles.contains(where: { $0.path.hasSuffix("CodeResources") }))
    XCTAssertTrue(profile.pinnedFiles.contains(where: { $0.path.hasSuffix("notarization-receipt.json") }))
    XCTAssertEqual(analysisProfile.executablePath, profile.executablePath)
    XCTAssertEqual(analysisProfile.pinnedFiles, profile.pinnedFiles)
    XCTAssertEqual(analysisProfile.pinnedTrees, profile.pinnedTrees)

    let provider = try AnalyzerProvider(profiles: profiles)
    let operation = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: AnalyzerProvider.traceSummary))
    XCTAssertEqual(provider.runtimeAvailability(for: operation), .available)
    let sourceURL = URL(filePath: sourcePath)
    let sourceBytes = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
    let artifact = ProviderResolvedInputArtifact(
      artifactID: "art-reviewed-arktrace-zlib", fileURL: sourceURL,
      sha256: AnalyzerProvider.sha256(sourceBytes), byteCount: sourceBytes.count)
    let context = ProviderExecutionContext(
      jobID: "job-reviewed-arktrace-zlib", stepID: operation.steps[0].stepID,
      targetID: "TGT-REVIEWED-ARKTRACE", bindingRevision: nil,
      nowUTC: "2026-08-14T12:43:40Z", resolvedInputArtifact: artifact)
    let action = try provider.action(
      for: operation.steps[0], operation: operation, inputs: [:], context: context)
    let receipt = try await DescriptorBoundProcessDispatcher(
      resolver: try AnalyzerExecutableResolver(profiles: [profile]))
      .dispatch(provider.lower(action: action, context: context))
    let outcome = try provider.verify(receipt: receipt, action: action, context: context)
    guard case .verified(let summary) = outcome else {
      return XCTFail("the reviewed signed distribution must produce one verified summary")
    }
    XCTAssertEqual(summary["sourceSha256"], artifact.sha256)
    XCTAssertEqual(summary["sourceByteCount"], String(artifact.byteCount))
    XCTAssertEqual(summary["toolSha256"], profile.executableSHA256)
    XCTAssertEqual(
      summary["parserSha256"], try XCTUnwrap(profile.arkTraceSummaryContract).parserSHA256)
    XCTAssertEqual(summary["derivedSha256"], AnalyzerProvider.sha256(receipt.stdout))
    XCTAssertEqual(summary["derivedByteCount"], String(receipt.stdout.count))
    XCTAssertTrue(receipt.stderr.isEmpty)
    print(
      "ARKTRACE_REVIEWED_SUMMARY bytes=\(receipt.stdout.count) "
        + "sha256=\(AnalyzerProvider.sha256(receipt.stdout))")

    let summaryJSON = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: receipt.stdout) as? [String: Any])
    let traceJSON = try XCTUnwrap(summaryJSON["trace"] as? [String: Any])
    let traceDurationNs = try XCTUnwrap((traceJSON["durationNs"] as? NSNumber)?.int64Value)
    let preferredStartNs: Int64 = 10_100_000_000
    let preferredEndNs: Int64 = 10_300_000_000
    let reviewedStartNs = traceDurationNs >= preferredEndNs ? preferredStartNs : 0
    let reviewedEndNs = traceDurationNs >= preferredEndNs
      ? preferredEndNs : min(traceDurationNs, 100_000_000)
    XCTAssertGreaterThan(reviewedEndNs, reviewedStartNs)
    let analysisOperation = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: AnalyzerProvider.traceAnalysis))
    let commonInputs: [String: JSONValue] = [
      "startNs": .integer(reviewedStartNs), "endNs": .integer(reviewedEndNs),
      "timeoutMs": .integer(30_000), "maxRows": .integer(10_000),
      "maxEvents": .integer(10_000), "maxOutputBytes": .integer(8_388_608),
    ]
    let analysisDispatcher = DescriptorBoundProcessDispatcher(
      resolver: try AnalyzerExecutableResolver(profiles: profiles))
    for kind in ["context", "range"] {
      var inputs = commonInputs
      inputs["kind"] = .string(kind)
      if kind != "context" { inputs["limit"] = .integer(10) }
      let analysisContext = ProviderExecutionContext(
        jobID: "job-reviewed-arktrace-\(kind)", stepID: analysisOperation.steps[0].stepID,
        targetID: "TGT-REVIEWED-ARKTRACE", bindingRevision: nil,
        nowUTC: "2026-08-15T00:00:00Z", resolvedInputArtifact: artifact)
      let analysisAction = try provider.action(
        for: analysisOperation.steps[0], operation: analysisOperation,
        inputs: inputs, context: analysisContext)
      let analysisReceipt = try await analysisDispatcher.dispatch(
        provider.lower(action: analysisAction, context: analysisContext))
      let analysisOutcome = try provider.verify(
        receipt: analysisReceipt, action: analysisAction, context: analysisContext)
      guard case .verified(let analysisSummary) = analysisOutcome else {
        return XCTFail("reviewed signed distribution did not verify \(kind) output")
      }
      XCTAssertEqual(analysisSummary["sourceSha256"], artifact.sha256)
      XCTAssertEqual(analysisSummary["toolSha256"], analysisProfile.executableSHA256)
      XCTAssertTrue(analysisReceipt.stderr.isEmpty)
      if reviewedStartNs == preferredStartNs {
        let envelope = try XCTUnwrap(
          try JSONSerialization.jsonObject(with: analysisReceipt.stdout) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        if kind == "context" {
          XCTAssertFalse(try XCTUnwrap(result["slices"] as? [Any]).isEmpty)
        } else {
          let analysis = try XCTUnwrap(result["analysis"] as? [String: Any])
          XCTAssertFalse(try XCTUnwrap(analysis["longSlices"] as? [Any]).isEmpty)
          XCTAssertFalse(try XCTUnwrap(analysis["hotIntervals"] as? [Any]).isEmpty)
        }
      }
      print(
        "ARKTRACE_REVIEWED_ANALYSIS kind=\(kind) bytes=\(analysisReceipt.stdout.count) "
          + "sha256=\(AnalyzerProvider.sha256(analysisReceipt.stdout))")
    }
  }

  func testDescriptorDispatcherKeepsTheExactAnalyzerSourceLeaseThroughChildOpen() async throws {
    let source = root.appending(path: "source.htrace")
    let held = root.appending(path: "held-source.htrace")
    let original = Data("immutable analyzer source A".utf8)
    let replacement = Data("replacement analyzer source B".utf8)
    try original.write(to: source)
    let resolver = try FixedExecutableResolver.hashing(
      path: "/bin/cat", providerID: "analyzer")
    let resolved = try resolver.resolveExecutable(providerID: "analyzer")
    let invocation = AnalyzerInvocation(
      analyzerRef: "source-lease-test@1", analyzerVersion: "1",
      executableSHA256: resolved.sha256, arguments: [source.path],
      timeoutSeconds: 5, outputByteBudget: 4_096,
      sourceArtifactID: "ART-SOURCE-LEASE",
      sourceSHA256: AnalyzerProvider.sha256(original),
      sourceByteCount: original.count)
    let action = TypedProviderAction.analyzer(.analyze(invocation))
    let plan = TypedProcessPlan(
      action: action,
      kind: .process(
        executableSHA256: resolved.sha256,
        argumentSummary: invocation.arguments,
        timeoutSeconds: invocation.timeoutSeconds))
    let executor = FoundationProcessExecutor(
      identityBoundPreSpawnHook: { _ in },
      launchObserver: { _ in },
      identityBoundSpawnObserver: { _, request, _ in
        // The process has been created, but `/bin/cat` has not necessarily
        // opened argv yet. Replacing the public Artifact path here therefore
        // catches any dispatcher that passed the mutable path rather than the
        // retained `/.vol/<dev>/<inode>` alias.
        XCTAssertNotEqual(request.arguments.last, source.path)
        try? FileManager.default.moveItem(at: source, to: held)
        try? replacement.write(to: source)
      })
    let receipt = try await DescriptorBoundProcessDispatcher(
      resolver: resolver, outputByteBudget: 4_096, processExecutor: executor)
      .dispatch(plan)

    XCTAssertEqual(receipt.exitStatus, 0)
    XCTAssertEqual(receipt.stdout, original)
    XCTAssertEqual(try Data(contentsOf: source), replacement)
    XCTAssertEqual(try Data(contentsOf: held), original)
  }

  func testTraceSummaryCannotAdmitOrDispatchWithoutItsRequiredArtifactStore() async throws {
    let (provider, action, _) = try await makeSummaryVerificationSubject()
    guard case .analyzer(.analyze(let invocation)) = action else {
      return XCTFail("fixture must materialize the trace-summary Analyzer invocation")
    }
    let validOutput = try summaryEnvelope(invocation)
    let dispatcher = FixedArkTraceSummaryDispatcher(output: validOutput)
    let state = root.appending(path: "missing-artifact-store", directoryHint: .isDirectory)
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(path: "engine", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: dispatcher,
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: state.appending(path: "capabilities", directoryHint: .isDirectory)),
      artifactStore: nil,
      nowUTC: { "2026-08-14T00:00:00Z" })

    let availabilities = await engine.operationAvailability()
    let availability = try XCTUnwrap(
      availabilities.first {
        $0.reference == AnalyzerProvider.traceSummary
      })
    XCTAssertEqual(availability.state, .unavailable)
    XCTAssertEqual(availability.reasons, ["runtime.artifactStoreUnavailable"])

    let request = try RuntimeOperationRequest(
      requestID: "req-trace-summary-no-artifact-store",
      idempotencyKey: "idem-trace-summary-no-artifact-store",
      target: DurableTargetReference(targetID: "TGT-TRACE", expectedBindingRevision: nil),
      operation: RuntimeOperationReference(id: "analyzer.summarize-trace", version: 1),
      inputs: ["sourceArtifactRef": .string("lease-v1:unreachable:source")])
    do {
      _ = try await engine.submit(try JSONEncoder().encode(request))
      XCTFail("a required trace-summary Artifact must not become an optional publication")
    } catch {
      XCTAssertTrue("\(error)".contains("runtime.artifactStoreUnavailable"), "\(error)")
    }
    XCTAssertEqual(dispatcher.dispatchCount, 0)
  }

  func testValidProfileIsAvailableAndLowersOneExactSourceArgument() async throws {
    let fixture = try makeDistribution()
    XCTAssertTrue(
      try ArkTraceProfileFileReader.isPhysicalDirectory(fixture.distributionRoot.path),
      "fixture distribution must be a physical directory")
    _ = try ArkTraceProfileFileReader.read(
      path: fixture.descriptorURL.path, maximumByteCount: 16 * 1024)
    let doctor = StubArkTraceDoctorProbe(result: true)
    let profiles = try await ArkTraceSummaryAnalyzerProfileLoader(
      doctor: doctor, trustChecker: StubArkTraceDistributionTrustChecker())
      .loadProfiles(descriptorURL: fixture.descriptorURL)
    let profile = try XCTUnwrap(profiles.first { $0.analyzerRef == "trace-summary@1" })
    let analysisProfile = try XCTUnwrap(
      profiles.first { $0.analyzerRef == "trace-analysis@1" })

    XCTAssertEqual(profile.analyzerRef, "trace-summary@1")
    XCTAssertEqual(profile.outputByteBudget, 8 * 1024 * 1024)
    XCTAssertEqual(
      profile.fixedArguments,
      [
        "summary", "--json", "--no-cache", "--timeout-ms", "30000",
        "--max-rows", "1000", "--max-events", "10000",
        "--max-output-bytes", "8388608",
      ])
    XCTAssertEqual(doctor.contracts.count, 1)
    XCTAssertEqual(doctor.contracts[0].executable.path, fixture.toolURL.path)
    XCTAssertEqual(
      doctor.contracts[0].executable.canonicalNamespaceRoot,
      fixture.distributionRoot.appending(path: "ArkTraceCLI.app").path)
    XCTAssertFalse(doctor.contracts[0].executable.verifiedResources.isEmpty)
    XCTAssertFalse(doctor.contracts[0].executable.verifiedTrees.isEmpty)
    XCTAssertEqual(analysisProfile.executablePath, profile.executablePath)
    XCTAssertEqual(analysisProfile.executableSHA256, profile.executableSHA256)
    XCTAssertEqual(analysisProfile.canonicalNamespaceRoot, profile.canonicalNamespaceRoot)
    XCTAssertEqual(analysisProfile.pinnedFiles, profile.pinnedFiles)
    XCTAssertEqual(analysisProfile.pinnedTrees, profile.pinnedTrees)
    XCTAssertEqual(analysisProfile.arkTraceAnalysisContract, profile.arkTraceSummaryContract)
    XCTAssertNil(analysisProfile.arkTraceSummaryContract)

    let provider = try AnalyzerProvider(profiles: profiles)
    let operation = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: AnalyzerProvider.traceSummary))
    let analysisOperation = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: AnalyzerProvider.traceAnalysis))
    XCTAssertEqual(provider.runtimeAvailability(for: operation), .available)
    XCTAssertEqual(provider.runtimeAvailability(for: analysisOperation), .available)

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: fixture.toolURL.path)
    XCTAssertEqual(
      provider.runtimeAvailability(for: operation),
      .unavailable(reason: "analyzer.toolIdentityDrift"))
    XCTAssertEqual(
      provider.runtimeAvailability(for: analysisOperation),
      .unavailable(reason: "analyzer.toolIdentityDrift"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: fixture.toolURL.path)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: fixture.parserURL.path)
    XCTAssertEqual(
      provider.runtimeAvailability(for: operation),
      .unavailable(reason: "analyzer.profileIdentityDrift"))
    XCTAssertEqual(
      provider.runtimeAvailability(for: analysisOperation),
      .unavailable(reason: "analyzer.profileIdentityDrift"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: fixture.parserURL.path)
    let receiptBytes = try Data(contentsOf: fixture.receiptURL)
    try Data("receipt drift".utf8).write(to: fixture.receiptURL)
    XCTAssertEqual(
      provider.runtimeAvailability(for: operation),
      .unavailable(reason: "analyzer.profileIdentityDrift"))
    try receiptBytes.write(to: fixture.receiptURL)
    XCTAssertEqual(provider.runtimeAvailability(for: operation), .available)
    let injectedResource = fixture.distributionRoot
      .appending(path: "ArkTraceCLI.app/Contents/Resources/unreviewed-extra.txt")
    try Data("not part of the reviewed signed tree".utf8).write(to: injectedResource)
    XCTAssertEqual(
      provider.runtimeAvailability(for: operation),
      .unavailable(reason: "analyzer.profileIdentityDrift"))
    try FileManager.default.removeItem(at: injectedResource)
    XCTAssertEqual(provider.runtimeAvailability(for: operation), .available)

    let sourceURL = root.appending(path: "--source with spaces-[quoted] ' 轨迹.htrace")
    let sourceBytes = Data("immutable trace".utf8)
    try sourceBytes.write(to: sourceURL)
    let artifact = ProviderResolvedInputArtifact(
      artifactID: "art-trace-source", fileURL: sourceURL,
      sha256: AnalyzerProvider.sha256(sourceBytes), byteCount: sourceBytes.count)
    let context = ProviderExecutionContext(
      jobID: "job-trace", stepID: operation.steps[0].stepID,
      targetID: "TGT-TRACE", bindingRevision: nil,
      nowUTC: "2026-08-14T00:00:00Z", resolvedInputArtifact: artifact)
    let action = try provider.action(
      for: operation.steps[0], operation: operation,
      inputs: ["arguments": .array([.string("--caller-selected-option")])], context: context)
    guard case .analyzer(.analyze(let invocation)) = action else {
      return XCTFail("trace summary must lower to the analyzer action")
    }
    XCTAssertEqual(invocation.arguments, profile.fixedArguments + [sourceURL.path])
    XCTAssertEqual(invocation.arguments.last, sourceURL.path)
    XCTAssertEqual(invocation.sourceSHA256, artifact.sha256)
    XCTAssertEqual(invocation.outputByteBudget, profile.outputByteBudget)
    let resolved = try AnalyzerExecutableResolver(profiles: [profile])
      .resolveExecutable(for: action)
    XCTAssertEqual(resolved.path, fixture.toolURL.path)
    XCTAssertEqual(resolved.sha256, profile.executableSHA256)
    XCTAssertEqual(resolved.verifiedResources.count, 5)

    try Data("drift".utf8).write(to: fixture.parserURL)
    XCTAssertEqual(
      provider.runtimeAvailability(for: operation),
      .unavailable(reason: "analyzer.profileIdentityDrift"))
    try fixture.parserBytes.write(to: fixture.parserURL)
    XCTAssertEqual(provider.runtimeAvailability(for: operation), .available)

    try Data("tool drift".utf8).write(to: fixture.toolURL)
    XCTAssertEqual(
      provider.runtimeAvailability(for: operation),
      .unavailable(reason: "analyzer.toolIdentityDrift"))
    try fixture.toolBytes.write(to: fixture.toolURL)
    XCTAssertEqual(provider.runtimeAvailability(for: operation), .available)

    let plan = try provider.lower(action: action, context: context)
    let resolver = try AnalyzerExecutableResolver(profiles: [profile])
    let launchBarrier = AnalyzerDispatchInstallBarrier()
    let launches = AnalyzerLaunchCounter()
    let cancelledBeforeSpawn = Task {
      try await DescriptorBoundProcessDispatcher(
        resolver: resolver,
        processExecutor: FoundationProcessExecutor(
          identityBoundPreSpawnHook: { _ in },
          identityBoundFinalLaunchHook: { _ in
            await launchBarrier.waitAtBoundary()
          },
          launchObserver: { _ in launches.record() }))
        .dispatch(plan)
    }
    await launchBarrier.waitUntilReached()
    cancelledBeforeSpawn.cancel()
    await launchBarrier.release()
    do {
      _ = try await cancelledBeforeSpawn.value
      XCTFail("a cancelled identity-bound Analyzer must not spawn")
    } catch let resolution as RuntimeDispatchCancellationResolution {
      XCTAssertEqual(resolution, .drained)
    }
    XCTAssertEqual(launches.count, 0)

    try Data("parser changed after admission".utf8).write(to: fixture.parserURL)
    do {
      _ = try await DescriptorBoundProcessDispatcher(resolver: resolver).dispatch(plan)
      XCTFail("pinned parser drift must be refused again in the final pre-spawn boundary")
    } catch let failure as RuntimeDispatchFailure {
      guard case .failed(let detail) = failure else {
        return XCTFail("resource drift is a definite pre-spawn failure: \(failure)")
      }
      XCTAssertEqual(detail, "analyzer process identity refused")
    }


    try fixture.parserBytes.write(to: fixture.parserURL)
    try FileManager.default.removeItem(at: fixture.toolURL)
    do {
      _ = try await DescriptorBoundProcessDispatcher(resolver: resolver).dispatch(plan)
      XCTFail("a tool removed after admission must fail with a stable path-free reason")
    } catch let failure as RuntimeDispatchFailure {
      guard case .failed(let detail) = failure else {
        return XCTFail("tool removal is a definite pre-spawn failure: \(failure)")
      }
      XCTAssertEqual(detail, "analyzer process identity refused")
      XCTAssertFalse(detail.contains(fixture.distributionRoot.path))
      XCTAssertFalse(detail.contains(fixture.toolURL.path))
    }
  }

  func testManifestContractParserAndDoctorFailuresHaveStableUnavailableReasons() async throws {
    do {
      let fixture = try makeDistribution()
      var bytes = try Data(contentsOf: fixture.manifestURL)
      bytes.append(0x20)
      try bytes.write(to: fixture.manifestURL)
      _ = try await ArkTraceSummaryAnalyzerProfileLoader(
        doctor: StubArkTraceDoctorProbe(result: true),
        trustChecker: StubArkTraceDistributionTrustChecker())
        .load(descriptorURL: fixture.descriptorURL)
      XCTFail("manifest drift must be rejected")
    } catch let error as ArkTraceSummaryProfileError {
      XCTAssertEqual(error, .manifestDrift)
      XCTAssertEqual(error.reason, "analyzer.arktraceManifestDrift")
    }

    do {
      let fixture = try makeDistribution(productVersion: "9.0.0")
      _ = try await ArkTraceSummaryAnalyzerProfileLoader(
        doctor: StubArkTraceDoctorProbe(result: true),
        trustChecker: StubArkTraceDistributionTrustChecker())
        .load(descriptorURL: fixture.descriptorURL)
      XCTFail("unsupported product contract must be rejected")
    } catch let error as ArkTraceSummaryProfileError {
      XCTAssertEqual(error, .contractMismatch)
    }

    do {
      let fixture = try makeDistribution()
      try Data("parser drift".utf8).write(to: fixture.parserURL)
      _ = try await ArkTraceSummaryAnalyzerProfileLoader(
        doctor: StubArkTraceDoctorProbe(result: true),
        trustChecker: StubArkTraceDistributionTrustChecker())
        .load(descriptorURL: fixture.descriptorURL)
      XCTFail("parser drift must be rejected")
    } catch let error as ArkTraceSummaryProfileError {
      XCTAssertEqual(error, .parserDrift)
    }

    do {
      let fixture = try makeDistribution()
      _ = try await ArkTraceSummaryAnalyzerProfileLoader(
        doctor: StubArkTraceDoctorProbe(result: false),
        trustChecker: StubArkTraceDistributionTrustChecker())
        .load(descriptorURL: fixture.descriptorURL)
      XCTFail("failed doctor must keep the operation unavailable")
    } catch let error as ArkTraceSummaryProfileError {
      XCTAssertEqual(error, .selfTestFailed)
      let provider = try AnalyzerProvider(
        profiles: [], unavailableReasons: ["trace-summary@1": error.reason])
      let operation = try XCTUnwrap(
        RuntimeOperationCatalog.descriptor(reference: AnalyzerProvider.traceSummary))
      XCTAssertEqual(
        provider.runtimeAvailability(for: operation),
        .unavailable(reason: "analyzer.arktraceSelfTestFailed"))
    }
  }

  func testDriftingUpgradeCandidateLeavesTheRetainedProfileAvailable() async throws {
    let retainedFixture = try makeDistribution()
    let retainedProfile = try await ArkTraceSummaryAnalyzerProfileLoader(
      doctor: StubArkTraceDoctorProbe(result: true),
      trustChecker: StubArkTraceDistributionTrustChecker())
      .load(descriptorURL: retainedFixture.descriptorURL)
    let retainedProvider = try AnalyzerProvider(profiles: [retainedProfile])
    let operation = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: AnalyzerProvider.traceSummary))
    XCTAssertEqual(retainedProvider.runtimeAvailability(for: operation), .available)

    let candidateFixture = try makeDistribution()
    try Data("candidate parser drift".utf8).write(to: candidateFixture.parserURL)
    do {
      _ = try await ArkTraceSummaryAnalyzerProfileLoader(
        doctor: StubArkTraceDoctorProbe(result: true),
        trustChecker: StubArkTraceDistributionTrustChecker())
        .load(descriptorURL: candidateFixture.descriptorURL)
      XCTFail("a drifting upgrade candidate must not replace the retained profile")
    } catch let error as ArkTraceSummaryProfileError {
      XCTAssertEqual(error, .parserDrift)
    }

    XCTAssertEqual(retainedProvider.runtimeAvailability(for: operation), .available)
    XCTAssertEqual(retainedProfile.executablePath, retainedFixture.toolURL.path)
  }

  func testProductionSnapshotOwnsTheCanonicalBundleNamespaceForItsLifetime() async throws {
    let fixture = try makeDistribution()
    let snapshots = root.appending(
      path: "daemon-state/arktrace-profile-snapshots", directoryHint: .isDirectory)
    let doctor = StubArkTraceDoctorProbe(result: true)
    let profile = try await ArkTraceSummaryAnalyzerProfileLoader(
      doctor: doctor,
      trustChecker: StubArkTraceDistributionTrustChecker(),
      snapshotRootURL: snapshots)
      .load(descriptorURL: fixture.descriptorURL)

    XCTAssertTrue(profile.executablePath.hasPrefix(snapshots.path + "/"))
    XCTAssertNotEqual(profile.executablePath, fixture.toolURL.path)
    XCTAssertEqual(doctor.contracts.count, 1)
    XCTAssertEqual(doctor.contracts[0].executable.path, profile.executablePath)
    XCTAssertTrue(
      doctor.contracts[0].executable.verifiedResources.allSatisfy {
        $0.path.hasPrefix(snapshots.path + "/")
      })

    // A selected install is only an input to snapshot materialization. An
    // upgrade/removal of that external version after load cannot rebind the
    // canonical path seen by Bundle.main in a running daemon.
    try FileManager.default.removeItem(at: fixture.distributionRoot)
    let provider = try AnalyzerProvider(profiles: [profile])
    let operation = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: AnalyzerProvider.traceSummary))
    XCTAssertEqual(provider.runtimeAvailability(for: operation), .available)
    XCTAssertTrue(FileManager.default.fileExists(atPath: profile.executablePath))
  }

  func testSnapshotRootSymlinkIsRejectedWithoutMutatingTheForeignDirectory() async throws {
    let fixture = try makeDistribution()
    let foreign = root.appending(path: "foreign-snapshot-target", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: foreign.path)
    let snapshotRoot = root.appending(path: "arktrace-profile-snapshots")
    try FileManager.default.createSymbolicLink(at: snapshotRoot, withDestinationURL: foreign)
    var before = stat()
    XCTAssertEqual(lstat(foreign.path, &before), 0)

    do {
      _ = try await ArkTraceSummaryAnalyzerProfileLoader(
        doctor: StubArkTraceDoctorProbe(result: true),
        trustChecker: StubArkTraceDistributionTrustChecker(),
        snapshotRootURL: snapshotRoot)
        .load(descriptorURL: fixture.descriptorURL)
      XCTFail("a symlinked snapshot authority must fail before any chmod or copy")
    } catch {
      // The stable public reason is less important here than proving that the
      // rejected pathname never changes the foreign inode.
    }
    var after = stat()
    XCTAssertEqual(lstat(foreign.path, &after), 0)
    XCTAssertEqual(before.st_dev, after.st_dev)
    XCTAssertEqual(before.st_ino, after.st_ino)
    XCTAssertEqual(before.st_mode, after.st_mode)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)
  }

  func testSnapshotGenerationNeverFollowsARootReplacementAfterDescriptorBinding() async throws {
    let fixture = try makeDistribution()
    let snapshotRoot = root.appending(
      path: "bound-snapshot-root", directoryHint: .isDirectory)
    let heldRoot = root.appending(
      path: "held-bound-snapshot-root", directoryHint: .isDirectory)
    let foreign = root.appending(
      path: "foreign-replacement-root", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: snapshotRoot.path)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: foreign.path)
    let sentinel = foreign.appending(path: "foreign-sentinel.txt")
    let sentinelBytes = Data("must remain the only foreign entry".utf8)
    try sentinelBytes.write(to: sentinel)
    var foreignBefore = stat()
    XCTAssertEqual(lstat(foreign.path, &foreignBefore), 0)

    do {
      _ = try await ArkTraceSummaryAnalyzerProfileLoader(
        doctor: StubArkTraceDoctorProbe(result: true),
        trustChecker: StubArkTraceDistributionTrustChecker(),
        snapshotRootURL: snapshotRoot,
        snapshotRootBoundHook: {
          try FileManager.default.moveItem(at: snapshotRoot, to: heldRoot)
          try FileManager.default.moveItem(at: foreign, to: snapshotRoot)
        })
        .load(descriptorURL: fixture.descriptorURL)
      XCTFail("a replaced public snapshot namespace must never become the profile")
    } catch {
      // The retained fd may contain a complete private generation, but the
      // public path no longer names it, so admission must fail closed.
    }

    var foreignAfter = stat()
    XCTAssertEqual(lstat(snapshotRoot.path, &foreignAfter), 0)
    XCTAssertEqual(foreignBefore.st_dev, foreignAfter.st_dev)
    XCTAssertEqual(foreignBefore.st_ino, foreignAfter.st_ino)
    XCTAssertEqual(foreignBefore.st_mode, foreignAfter.st_mode)
    XCTAssertEqual(try Data(contentsOf: snapshotRoot.appending(path: sentinel.lastPathComponent)), sentinelBytes)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: snapshotRoot.path),
      [sentinel.lastPathComponent])
  }

  func testSnapshotPublicationCollisionNeverLeaksTheCopiedPartialGeneration() async throws {
    let fixture = try makeDistribution()
    let snapshotRoot = root.appending(
      path: "collision-snapshot-root", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: snapshotRoot, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: snapshotRoot.path)
    let finalName = try ArkTraceDistributionTreeHasher.digest(
      rootPath: fixture.distributionRoot.path)
    let invalidFinal = snapshotRoot.appending(path: finalName, directoryHint: .isDirectory)
    let sentinelBytes = Data("pre-existing invalid generation".utf8)
    let loader = ArkTraceSummaryAnalyzerProfileLoader(
      doctor: StubArkTraceDoctorProbe(result: true),
      trustChecker: StubArkTraceDistributionTrustChecker(),
      snapshotRootURL: snapshotRoot,
      beforeSnapshotPublicationHook: { publishedName in
        XCTAssertEqual(publishedName, finalName)
        try FileManager.default.createDirectory(
          at: invalidFinal, withIntermediateDirectories: false)
        try sentinelBytes.write(to: invalidFinal.appending(path: "sentinel.txt"))
      })

    do {
      _ = try await loader.load(descriptorURL: fixture.descriptorURL)
      XCTFail("an invalid concurrent final generation must fail closed")
    } catch {}
    let firstEntries = try FileManager.default.contentsOfDirectory(atPath: snapshotRoot.path)
    XCTAssertEqual(firstEntries, [finalName])
    XCTAssertEqual(
      try Data(contentsOf: invalidFinal.appending(path: "sentinel.txt")), sentinelBytes)

    do {
      _ = try await loader.load(descriptorURL: fixture.descriptorURL)
      XCTFail("the same invalid generation must remain rejected")
    } catch {}
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: snapshotRoot.path), firstEntries)
    XCTAssertEqual(
      try Data(contentsOf: invalidFinal.appending(path: "sentinel.txt")), sentinelBytes)
  }

  func testSymlinkedOrMissingDescriptorFailsBeforeDoctor() async throws {
    let physical = try makeDistribution()
    let link = root.appending(path: "linked-distribution", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: physical.distributionRoot)
    let linkDescriptor = root.appending(path: "linked-descriptor.json")
    try descriptorData(root: link, manifestURL: physical.manifestURL).write(to: linkDescriptor)
    let doctor = StubArkTraceDoctorProbe(result: true)
    do {
      _ = try await ArkTraceSummaryAnalyzerProfileLoader(
        doctor: doctor, trustChecker: StubArkTraceDistributionTrustChecker())
        .load(descriptorURL: linkDescriptor)
      XCTFail("symlinked distribution root must be rejected")
    } catch let error as ArkTraceSummaryProfileError {
      XCTAssertEqual(error, .notFound)
    }
    XCTAssertTrue(doctor.contracts.isEmpty)

    do {
      _ = try await ArkTraceSummaryAnalyzerProfileLoader(
        doctor: doctor, trustChecker: StubArkTraceDistributionTrustChecker())
        .load(descriptorURL: root.appending(path: "missing.json"))
      XCTFail("missing descriptor must be rejected")
    } catch let error as ArkTraceSummaryProfileError {
      XCTAssertEqual(error, .notFound)
    }
  }

  func testWritableDescriptorOrInstallAuthorityFailsBeforeDoctor() async throws {
    let writableDescriptor = try makeDistribution()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o666], ofItemAtPath: writableDescriptor.descriptorURL.path)
    let descriptorDoctor = StubArkTraceDoctorProbe(result: true)
    do {
      _ = try await ArkTraceSummaryAnalyzerProfileLoader(
        doctor: descriptorDoctor, trustChecker: StubArkTraceDistributionTrustChecker())
        .load(descriptorURL: writableDescriptor.descriptorURL)
      XCTFail("group/world-writable descriptor authority must be rejected")
    } catch let error as ArkTraceSummaryProfileError {
      XCTAssertEqual(error, .descriptorInvalid)
    }
    XCTAssertTrue(descriptorDoctor.contracts.isEmpty)

    let writableInstall = try makeDistribution()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o777], ofItemAtPath: writableInstall.distributionRoot.path)
    let installDoctor = StubArkTraceDoctorProbe(result: true)
    do {
      _ = try await ArkTraceSummaryAnalyzerProfileLoader(
        doctor: installDoctor, trustChecker: StubArkTraceDistributionTrustChecker())
        .load(descriptorURL: writableInstall.descriptorURL)
      XCTFail("group/world-writable versioned install authority must be rejected")
    } catch let error as ArkTraceSummaryProfileError {
      XCTAssertEqual(error, .descriptorInvalid)
    }
    XCTAssertTrue(installDoctor.contracts.isEmpty)
  }

  func testProductionTrustRejectsManifestOnlyUnsignedBytesAndParentReplacement() async throws {
    let unsigned = try makeDistribution()
    do {
      _ = try await ArkTraceSummaryAnalyzerProfileLoader(
        doctor: StubArkTraceDoctorProbe(result: true))
        .load(descriptorURL: unsigned.descriptorURL)
      XCTFail("manifest claims cannot make unsigned fixture bytes production-available")
    } catch let error as ArkTraceSummaryProfileError {
      XCTAssertEqual(error, .contractMismatch)
    }

    let replaced = try makeDistribution()
    let held = root.appending(path: "held-distribution", directoryHint: .isDirectory)
    let checker = MutatingArkTraceDistributionTrustChecker {
      try FileManager.default.moveItem(at: replaced.distributionRoot, to: held)
      try FileManager.default.createSymbolicLink(
        at: replaced.distributionRoot, withDestinationURL: held)
    }
    do {
      _ = try await ArkTraceSummaryAnalyzerProfileLoader(
        doctor: StubArkTraceDoctorProbe(result: true), trustChecker: checker)
        .load(descriptorURL: replaced.descriptorURL)
      XCTFail("a distribution root replaced after admission must fail final revalidation")
    } catch let error as ArkTraceSummaryProfileError {
      XCTAssertEqual(error, .manifestDrift)
    }
  }

  func testCompleteArkTraceSummaryEnvelopeIsBoundToInvocationAndAccepted() async throws {
    let (provider, action, context) = try await makeSummaryVerificationSubject()
    guard case .analyzer(.analyze(let invocation)) = action else {
      return XCTFail("expected trace analyzer invocation")
    }
    let output = try summaryEnvelope(invocation)
    let outcome = try provider.verify(
      receipt: ProviderProcessReceipt(
        exitStatus: 0, stdout: output, stderr: Data(), stdoutTruncated: false,
        durationSeconds: 0.01),
      action: action, context: context)
    guard case .verified(let summary) = outcome else {
      return XCTFail("complete bound envelope must verify")
    }
    XCTAssertEqual(summary["sourceSha256"], invocation.sourceSHA256)
    XCTAssertEqual(summary["toolSha256"], invocation.executableSHA256)
    XCTAssertEqual(summary["parserSha256"], invocation.arkTraceSummaryContract?.parserSHA256)
    XCTAssertEqual(summary["derivedSha256"], AnalyzerProvider.sha256(output))
    XCTAssertEqual(summary["derivedByteCount"], String(output.count))

    let semanticSlash = Data(
      String(decoding: output, as: UTF8.self).replacingOccurrences(
        of: "\"source\":\"token=secretvalue\"",
        with: "\"source\":\"sched/sched_switch\"").utf8)
    let semanticSlashOutcome = try provider.verify(
      receipt: ProviderProcessReceipt(
        exitStatus: 0, stdout: semanticSlash, stderr: Data(), stdoutTruncated: false,
        durationSeconds: 0.01),
      action: action, context: context)
    guard case .verified = semanticSlashOutcome else {
      return XCTFail("a semantic source identifier containing a slash must remain valid")
    }
    let nonURIFileLabel = Data(
      String(decoding: output, as: UTF8.self).replacingOccurrences(
        of: "\"source\":\"token=secretvalue\"",
        with: "\"source\":\"file:io\"").utf8)
    let nonURIFileLabelOutcome = try provider.verify(
      receipt: ProviderProcessReceipt(
        exitStatus: 0, stdout: nonURIFileLabel, stderr: Data(), stdoutTruncated: false,
        durationSeconds: 0.01),
      action: action, context: context)
    guard case .verified = nonURIFileLabelOutcome else {
      return XCTFail("a non-URI trace label beginning with file: must remain valid")
    }
  }

  func testArkTraceEnvelopeMismatchTruncationAndBudgetFailuresAreRejected() async throws {
    let (provider, action, context) = try await makeSummaryVerificationSubject()
    guard case .analyzer(.analyze(let invocation)) = action else {
      return XCTFail("expected trace analyzer invocation")
    }
    let valid = try summaryEnvelope(invocation)
    for mutation in [
      "tool", "command", "trace", "parser", "provenance", "extra",
      "count", "capability", "truncation",
    ] {
      let invalid = try mutateEnvelope(valid, mutation: mutation)
      let outcome = try provider.verify(
        receipt: ProviderProcessReceipt(
          exitStatus: 0, stdout: invalid, stderr: Data(), stdoutTruncated: false,
          durationSeconds: 0.01),
        action: action, context: context)
      guard case .failed(let code, _) = outcome else {
        return XCTFail("\(mutation) mismatch must fail")
      }
      XCTAssertEqual(code, "analyzer.schemaMismatch")
    }

    let text = try XCTUnwrap(String(data: valid, encoding: .utf8))
    let fractional = Data(
      text.replacingOccurrences(
        of: "\"maxRows\":1000", with: "\"maxRows\":1000.00000000000001").utf8)
    let escapedPath = invocation.arguments.last!
      .replacingOccurrences(of: "/", with: "\\u002F")
    let escapedPrivatePath = Data(
      text.replacingOccurrences(
        of: "\"source\":\"token=secretvalue\"",
        with: "\"source\":\"\(escapedPath)\"").utf8)
    let embeddedPrivatePath = Data(
      text.replacingOccurrences(
        of: "\"source\":\"token=secretvalue\"",
        with: "\"source\":\"event from /Users/alice/private.trace\"").utf8)
    let assignedPrivatePath = Data(
      text.replacingOccurrences(
        of: "\"source\":\"token=secretvalue\"",
        with: "\"source\":\"HOME=/private/tmp/arktrace-input\"").utf8)
    let customRootPrivatePath = Data(
      text.replacingOccurrences(
        of: "\"source\":\"token=secretvalue\"",
        with: "\"source\":\"event from /srv/arktrace/input\"").utf8)
    let rootWithoutTrailingSlash = Data(
      text.replacingOccurrences(
        of: "\"source\":\"token=secretvalue\"",
        with: "\"source\":\"HOME=/tmp\"").utf8)
    let uppercaseFileURI = Data(
      text.replacingOccurrences(
        of: "\"source\":\"token=secretvalue\"",
        with: "\"source\":\"FILE:///srv/arktrace/input\"").utf8)
    let percentEncodedFileURI = Data(
      text.replacingOccurrences(
        of: "\"source\":\"token=secretvalue\"",
        with: "\"source\":\"file:%2F%2F%2Fsrv%2Farktrace%2Finput\"").utf8)
    let closingBracketBoundary = Data(
      text.replacingOccurrences(
        of: "\"source\":\"token=secretvalue\"",
        with: "\"source\":\"event)/srv/private.trace\"").utf8)
    let pipeBoundary = Data(
      text.replacingOccurrences(
        of: "\"source\":\"token=secretvalue\"",
        with: "\"source\":\"path|/mnt/input\"").utf8)
    let unicodeWhitespaceBoundary = Data(
      text.replacingOccurrences(
        of: "\"source\":\"token=secretvalue\"",
        with: "\"source\":\"event\u{00a0}/srv/input\"").utf8)
    let arrowBoundary = Data(
      text.replacingOccurrences(
        of: "\"source\":\"token=secretvalue\"",
        with: "\"source\":\"event→/Network/input\"").utf8)
    let validEscapeWithInvalidTail = Data(
      text.replacingOccurrences(
        of: "\"source\":\"token=secretvalue\"",
        with: "\"source\":\"HOME=%2Fsrv%\"").utf8)
    for (label, bytes) in [
      ("fractional integer", fractional),
      ("escaped exact source path", escapedPrivatePath),
      ("embedded host path", embeddedPrivatePath),
      ("assigned embedded host path", assignedPrivatePath),
      ("custom absolute root", customRootPrivatePath),
      ("root without trailing slash", rootWithoutTrailingSlash),
      ("uppercase file URI", uppercaseFileURI),
      ("percent-encoded file URI", percentEncodedFileURI),
      ("closing bracket boundary", closingBracketBoundary),
      ("pipe boundary", pipeBoundary),
      ("Unicode whitespace boundary", unicodeWhitespaceBoundary),
      ("arrow boundary", arrowBoundary),
      ("valid escape before invalid tail", validEscapeWithInvalidTail),
    ] {
      let outcome = try provider.verify(
        receipt: ProviderProcessReceipt(
          exitStatus: 0, stdout: bytes, stderr: Data(), stdoutTruncated: false,
          durationSeconds: 0.01),
        action: action, context: context)
      guard case .failed(let code, _) = outcome else {
        return XCTFail("\(label) must fail")
      }
      XCTAssertEqual(code, "analyzer.schemaMismatch")
    }

    let truncated = try provider.verify(
      receipt: ProviderProcessReceipt(
        exitStatus: 0, stdout: valid, stderr: Data(), stdoutTruncated: true,
        durationSeconds: 0.01),
      action: action, context: context)
    guard case .failed(let truncatedCode, _) = truncated else {
      return XCTFail("truncated stdout must fail")
    }
    XCTAssertEqual(truncatedCode, "analyzer.truncatedResult")

    let tinyInvocation = AnalyzerInvocation(
      analyzerRef: invocation.analyzerRef,
      analyzerVersion: invocation.analyzerVersion,
      executableSHA256: invocation.executableSHA256,
      arguments: invocation.arguments,
      timeoutSeconds: invocation.timeoutSeconds,
      outputByteBudget: valid.count - 1,
      sourceArtifactID: invocation.sourceArtifactID,
      sourceSHA256: invocation.sourceSHA256,
      sourceByteCount: invocation.sourceByteCount,
      arkTraceSummaryContract: invocation.arkTraceSummaryContract)
    let oversized = try provider.verify(
      receipt: ProviderProcessReceipt(
        exitStatus: 0, stdout: valid, stderr: Data(), stdoutTruncated: false,
        durationSeconds: 0.01),
      action: .analyzer(.analyze(tinyInvocation)), context: context)
    guard case .failed(let oversizedCode, _) = oversized else {
      return XCTFail("over-budget stdout must fail")
    }
    XCTAssertEqual(oversizedCode, "analyzer.outputLimitExceeded")
  }

  func testRuntimePublishesAndReloadsTheExactValidatedSummaryBytes() async throws {
    let state = root.appending(path: "runtime", directoryHint: .isDirectory)
    let artifactRoot = state.appending(path: "artifacts", directoryHint: .isDirectory)
    let artifactStore = try RuntimeArtifactStore(
      rootURL: artifactRoot, nowUTC: { "2026-08-14T00:00:00Z" })
    let raw = Data("runtime immutable trace".utf8)
    let source = try await artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "JOB-TRACE-CAPTURE", sessionID: "HTASK-TRACE000001",
        stepID: "receive-trace-artifact", name: "trace.htrace",
        mediaType: "application/octet-stream", privacy: .sensitive,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "capture.diagnostics@1", providerID: "hdc",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "TGT-TRACE", bindingRevision: 4,
          stableIdentitySHA256: String(repeating: "c", count: 64)),
        contents: raw))
    let lease = try await artifactStore.leaseReference(
      jobID: source.jobID, artifactID: source.artifactID)

    let toolSHA = AnalyzerProvider.sha256(try Data(contentsOf: URL(filePath: "/bin/cat")))
    let contract = ArkTraceSummaryInvocationContract(
      toolVersion: "0.1.0", parserVersion: "4.3.7",
      parserUpstreamRevision: String(repeating: "d", count: 40),
      parserSHA256: String(repeating: "e", count: 64),
      parserBuildRecipeVersion: String(repeating: "f", count: 64),
      parserAdapterVersion: "1", schemaAdapterVersion: "2", indexSchemaVersion: 2)
    let fixedArguments = [
      "summary", "--json", "--no-cache", "--timeout-ms", "30000",
      "--max-rows", "1000", "--max-events", "10000",
      "--max-output-bytes", "8388608",
    ]
    let profile = AnalyzerProfile(
      analyzerRef: "trace-summary@1", analyzerVersion: "0.1.0+1",
      executablePath: "/bin/cat", executableSHA256: toolSHA,
      fixedArguments: fixedArguments, timeoutSeconds: 30,
      outputByteBudget: 8 * 1024 * 1024,
      arkTraceSummaryContract: contract)
    let sourceResolution = try await artifactStore.resolveLease(lease)
    let sourcePath = sourceResolution.fileURL.path
    let expectedInvocation = AnalyzerInvocation(
      analyzerRef: "trace-summary@1", analyzerVersion: "0.1.0+1",
      executableSHA256: toolSHA, arguments: fixedArguments + [sourcePath],
      timeoutSeconds: 30, outputByteBudget: 8 * 1024 * 1024,
      sourceArtifactID: source.artifactID, sourceSHA256: source.sha256,
      sourceByteCount: source.byteCount, arkTraceSummaryContract: contract)
    let exactOutput = try summaryEnvelope(expectedInvocation)
    let provider = try AnalyzerProvider(profiles: [profile])
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: state.appending(path: "capabilities", directoryHint: .isDirectory))
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(path: "engine", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: FixedArkTraceSummaryDispatcher(output: exactOutput),
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-14T00:00:00Z" })
    let request = try RuntimeOperationRequest(
      requestID: "req-trace-summary", idempotencyKey: "idem-trace-summary",
      target: DurableTargetReference(targetID: "TGT-TRACE", expectedBindingRevision: nil),
      operation: RuntimeOperationReference(id: "analyzer.summarize-trace", version: 1),
      inputs: ["sourceArtifactRef": .string(lease)])

    let cancelledRequest = try RuntimeOperationRequest(
      requestID: "req-trace-summary-cancelled",
      idempotencyKey: "idem-trace-summary-cancelled",
      target: DurableTargetReference(targetID: "TGT-TRACE", expectedBindingRevision: nil),
      operation: RuntimeOperationReference(id: "analyzer.summarize-trace", version: 1),
      inputs: ["sourceArtifactRef": .string(lease)])
    let cancelledAcceptance = try await engine.submit(
      try JSONEncoder().encode(cancelledRequest))
    try await engine.requestCancel(jobID: cancelledAcceptance.jobID)
    let cancelledStatus = try await engine.status(jobID: cancelledAcceptance.jobID)
    let cancelledArtifacts = try await artifactStore.list(jobID: cancelledAcceptance.jobID)
    XCTAssertEqual(cancelledStatus.state, "cancelled")
    XCTAssertFalse(
      cancelledArtifacts.contains(where: { $0.name == "trace-summary.json" }))

    let blockingDispatcher = BlockingArkTraceSummaryDispatcher(
      output: exactOutput, holdCancellationResolution: true)
    let inFlightState = state.appending(
      path: "in-flight-cancel-engine", directoryHint: .isDirectory)
    let inFlightCancelEngine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: inFlightState),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: blockingDispatcher,
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-14T00:00:00Z" })
    let inFlightCancelRequest = try RuntimeOperationRequest(
      requestID: "req-trace-summary-in-flight-cancel",
      idempotencyKey: "idem-trace-summary-in-flight-cancel",
      target: DurableTargetReference(targetID: "TGT-TRACE", expectedBindingRevision: nil),
      operation: RuntimeOperationReference(id: "analyzer.summarize-trace", version: 1),
      inputs: ["sourceArtifactRef": .string(lease)])
    let inFlightAcceptance = try await inFlightCancelEngine.submit(
      try JSONEncoder().encode(inFlightCancelRequest))
    let inFlightRun = Task {
      try await inFlightCancelEngine.run(jobID: inFlightAcceptance.jobID)
    }
    await blockingDispatcher.waitUntilStarted()
    try await inFlightCancelEngine.requestCancel(jobID: inFlightAcceptance.jobID)
    let inFlightJobDirectory = inFlightState.appending(
      path: "jobs/\(inFlightAcceptance.jobID)", directoryHint: .isDirectory)
    let preTerminalCancellationRecord = try RuntimeJobRecord.load(
      from: inFlightJobDirectory)
    XCTAssertEqual(preTerminalCancellationRecord.state, "cancelRequested")
    XCTAssertNotNil(preTerminalCancellationRecord.recoveryStepID)
    XCTAssertNotNil(preTerminalCancellationRecord.recoveryAction)
    blockingDispatcher.releaseCancellationResolution()
    let inFlightStatus = try await inFlightRun.value
    XCTAssertEqual(inFlightStatus.state, "cancelled")
    XCTAssertFalse(inFlightStatus.outcomeUnknown)
    XCTAssertTrue(blockingDispatcher.observedCancellation)
    let inFlightArtifacts = try await artifactStore.list(jobID: inFlightAcceptance.jobID)
    XCTAssertFalse(
      inFlightArtifacts.contains(where: { $0.name == "trace-summary.json" }))

    // Recreate a daemon loss immediately after the correlated cancelled
    // outcome, before either cancellation transition could be trusted from
    // the persisted record.  Journal replay must complete cancellation and
    // must never materialize/dispatch the original Analyzer action again.
    let inFlightJournal = inFlightState.appending(
      path: "jobs/\(inFlightAcceptance.jobID)/journal.jsonl")
    let inFlightReplay = try DurableJournalRecovery.inspect(url: inFlightJournal)
    let cancelledOutcomeSequence = try XCTUnwrap(
      inFlightReplay.events.first {
        $0.kind == .stepOutcome
          && $0.payload["semanticCode"] == .string("cancelled")
      }?.sequence)
    let inFlightLines = try String(contentsOf: inFlightJournal, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: false)
    try Data(
      (inFlightLines.prefix(cancelledOutcomeSequence + 1).joined(separator: "\n") + "\n")
        .utf8
    ).write(to: inFlightJournal)
    // Restore the authoritative record to the bytes that existed in the
    // crash window, including the SQLite hot-recovery index. Keeping the later
    // terminal projection would make recoverActiveJobs skip this Job and
    // would not exercise replay.
    try preTerminalCancellationRecord.persist(into: inFlightJobDirectory)
    try RuntimeAdmissionService(stateDirectory: inFlightState).persist(
      preTerminalCancellationRecord, at: "2026-08-14T00:00:00Z")
    let cancellationRecoveryDispatcher = CountingArkTraceSummaryDispatcher()
    let cancellationRecoveryEngine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: inFlightState),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: cancellationRecoveryDispatcher,
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-14T00:00:01Z" })
    let recovered = try await cancellationRecoveryEngine.recoverActiveJobs()
    let recoveredCancellation = try XCTUnwrap(
      recovered.first(where: { $0.jobID == inFlightAcceptance.jobID }))
    XCTAssertEqual(recoveredCancellation.state, "cancelled")
    XCTAssertFalse(recoveredCancellation.outcomeUnknown)
    XCTAssertEqual(cancellationRecoveryDispatcher.dispatchCount, 0)
    var recoveredRecord = try RuntimeJobRecord.load(from: inFlightJobDirectory)
    XCTAssertEqual(recoveredRecord.operationFailure?.code, .cancelled)
    XCTAssertNil(recoveredRecord.recoveryStepID)
    XCTAssertNil(recoveredRecord.recoveryIntentEventID)
    XCTAssertNil(recoveredRecord.recoveryAction)

    // A second crash after the final cancelled transition but before the
    // record/index persist must canonicalize the same terminal bytes without
    // appending another transition or redispatching the Analyzer.
    let cancelledJournal = try DurableJournalRecovery.inspect(url: inFlightJournal)
    XCTAssertEqual(cancelledJournal.currentState, .cancelled)
    let cancelledLastSequence = cancelledJournal.lastDurableSequence
    try preTerminalCancellationRecord.persist(into: inFlightJobDirectory)
    try RuntimeAdmissionService(stateDirectory: inFlightState).persist(
      preTerminalCancellationRecord, at: "2026-08-14T00:00:01Z")
    let terminalWindowDispatcher = CountingArkTraceSummaryDispatcher()
    let terminalWindowEngine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: inFlightState),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: terminalWindowDispatcher,
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-14T00:00:02Z" })
    let terminalRecovered = try await terminalWindowEngine.recoverActiveJobs()
    XCTAssertTrue(terminalRecovered.contains(where: {
      $0.jobID == inFlightAcceptance.jobID && $0.state == "cancelled"
    }))
    XCTAssertEqual(terminalWindowDispatcher.dispatchCount, 0)
    recoveredRecord = try RuntimeJobRecord.load(from: inFlightJobDirectory)
    XCTAssertEqual(recoveredRecord.operationFailure?.code, .cancelled)
    XCTAssertNil(recoveredRecord.recoveryStepID)
    XCTAssertNil(recoveredRecord.recoveryIntentEventID)
    XCTAssertNil(recoveredRecord.recoveryAction)
    XCTAssertEqual(
      try DurableJournalRecovery.inspect(url: inFlightJournal).lastDurableSequence,
      cancelledLastSequence)

    // A process-layer cancellation without a positive no-survivors receipt
    // stays unknown and keeps its intent for explicit recovery.
    let unconfirmedDispatcher = BlockingArkTraceSummaryDispatcher(
      output: exactOutput, cancellationResolution: .unconfirmed)
    let unconfirmedEngine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(
          path: "unconfirmed-cancel-engine", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: unconfirmedDispatcher,
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-14T00:00:00Z" })
    let unconfirmedRequest = try RuntimeOperationRequest(
      requestID: "req-trace-summary-unconfirmed-cancel",
      idempotencyKey: "idem-trace-summary-unconfirmed-cancel",
      target: DurableTargetReference(targetID: "TGT-TRACE", expectedBindingRevision: nil),
      operation: RuntimeOperationReference(id: "analyzer.summarize-trace", version: 1),
      inputs: ["sourceArtifactRef": .string(lease)])
    let unconfirmedAcceptance = try await unconfirmedEngine.submit(
      try JSONEncoder().encode(unconfirmedRequest))
    let unconfirmedRun = Task {
      try await unconfirmedEngine.run(jobID: unconfirmedAcceptance.jobID)
    }
    await unconfirmedDispatcher.waitUntilStarted()
    try await unconfirmedEngine.requestCancel(jobID: unconfirmedAcceptance.jobID)
    let unconfirmedStatus = try await unconfirmedRun.value
    XCTAssertEqual(unconfirmedStatus.state, "waitingForRecovery")
    XCTAssertTrue(unconfirmedStatus.outcomeUnknown)
    XCTAssertTrue(unconfirmedDispatcher.observedCancellation)
    let unconfirmedArtifacts = try await artifactStore.list(
      jobID: unconfirmedAcceptance.jobID)
    XCTAssertFalse(
      unconfirmedArtifacts.contains(where: { $0.name == "trace-summary.json" }))

    // Cancel while the actor is suspended after step preparation but before
    // an active Task is installed.  The final synchronous recheck closes the
    // job without ever calling the dispatcher.
    let installBarrier = AnalyzerDispatchInstallBarrier()
    let installRaceDispatcher = CountingArkTraceSummaryDispatcher()
    let installRaceEngine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(
          path: "install-race-engine", directoryHint: .isDirectory),
        testHooks: .init(
          beforeDispatchInstall: { _, _ in await installBarrier.waitAtBoundary() })),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: installRaceDispatcher,
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-14T00:00:00Z" })
    let installRaceRequest = try RuntimeOperationRequest(
      requestID: "req-trace-summary-install-race",
      idempotencyKey: "idem-trace-summary-install-race",
      target: DurableTargetReference(targetID: "TGT-TRACE", expectedBindingRevision: nil),
      operation: RuntimeOperationReference(id: "analyzer.summarize-trace", version: 1),
      inputs: ["sourceArtifactRef": .string(lease)])
    let installRaceAcceptance = try await installRaceEngine.submit(
      try JSONEncoder().encode(installRaceRequest))
    let installRaceRun = Task {
      try await installRaceEngine.run(jobID: installRaceAcceptance.jobID)
    }
    await installBarrier.waitUntilReached()
    try await installRaceEngine.requestCancel(jobID: installRaceAcceptance.jobID)
    await installBarrier.release()
    let installRaceStatus = try await installRaceRun.value
    XCTAssertEqual(installRaceStatus.state, "cancelled")
    XCTAssertFalse(installRaceStatus.outcomeUnknown)
    XCTAssertEqual(installRaceDispatcher.dispatchCount, 0)

    // Once a verified Analyzer receipt crosses the Runtime-owned success
    // commit point, a later cancellation is rejected rather than producing
    // the contradictory state `cancelled` plus a published summary.
    let commitBarrier = AnalyzerDispatchInstallBarrier()
    let commitEngine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(
          path: "commit-linearization-engine", directoryHint: .isDirectory),
        testHooks: .init(
          afterAnalyzerCommitLinearization: { _, _ in
            await commitBarrier.waitAtBoundary()
          })),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: FixedArkTraceSummaryDispatcher(output: exactOutput),
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-14T00:00:00Z" })
    let commitRequest = try RuntimeOperationRequest(
      requestID: "req-trace-summary-commit-linearization",
      idempotencyKey: "idem-trace-summary-commit-linearization",
      target: DurableTargetReference(targetID: "TGT-TRACE", expectedBindingRevision: nil),
      operation: RuntimeOperationReference(id: "analyzer.summarize-trace", version: 1),
      inputs: ["sourceArtifactRef": .string(lease)])
    let commitAcceptance = try await commitEngine.submit(
      try JSONEncoder().encode(commitRequest))
    let commitRun = Task { try await commitEngine.run(jobID: commitAcceptance.jobID) }
    await commitBarrier.waitUntilReached()
    try await commitEngine.requestCancel(jobID: commitAcceptance.jobID)
    await commitBarrier.release()
    let commitStatus = try await commitRun.value
    XCTAssertEqual(commitStatus.state, "succeeded")
    XCTAssertFalse(commitStatus.outcomeUnknown)
    let committedArtifacts = try await artifactStore.list(jobID: commitAcceptance.jobID)
    XCTAssertTrue(committedArtifacts.contains(where: {
      $0.name == "trace-summary.json" && $0.status.isPublished
    }))

    // Simulate process loss after exact Artifact publication but before the
    // correlated succeeded outcome. Recovery must preserve the Artifact,
    // park the still-outstanding read-only intent, and never redispatch the
    // Analyzer whose stdout no longer exists in memory.
    let publicationBarrier = AnalyzerDispatchInstallBarrier()
    let publicationCrashState = state.appending(
      path: "publication-crash-engine", directoryHint: .isDirectory)
    let publicationEngine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: publicationCrashState,
        testHooks: .init(
          afterAnalyzerArtifactPublication: { _, _ in
            await publicationBarrier.waitAtBoundary()
          })),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: FixedArkTraceSummaryDispatcher(output: exactOutput),
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-14T00:00:00Z" })
    let publicationRequest = try RuntimeOperationRequest(
      requestID: "req-trace-summary-publication-crash",
      idempotencyKey: "idem-trace-summary-publication-crash",
      target: DurableTargetReference(targetID: "TGT-TRACE", expectedBindingRevision: nil),
      operation: RuntimeOperationReference(id: "analyzer.summarize-trace", version: 1),
      inputs: ["sourceArtifactRef": .string(lease)])
    let publicationAcceptance = try await publicationEngine.submit(
      try JSONEncoder().encode(publicationRequest))
    let publicationRun = Task {
      try await publicationEngine.run(jobID: publicationAcceptance.jobID)
    }
    await publicationBarrier.waitUntilReached()
    let publicationJobDirectory = publicationCrashState.appending(
      path: "jobs/\(publicationAcceptance.jobID)", directoryHint: .isDirectory)
    let publicationJournal = publicationJobDirectory.appending(path: "journal.jsonl")
    let crashRecord = try RuntimeJobRecord.load(from: publicationJobDirectory)
    let crashJournalBytes = try Data(contentsOf: publicationJournal)
    let crashReplay = try DurableJournalRecovery.inspect(url: publicationJournal)
    XCTAssertEqual(crashReplay.outstandingIntents.count, 1)
    XCTAssertTrue(crashReplay.events.filter { $0.kind == .stepOutcome }.isEmpty)
    let artifactAtCrash = try await artifactStore.list(jobID: publicationAcceptance.jobID)
    XCTAssertEqual(
      artifactAtCrash.first(where: { $0.name == "trace-summary.json" })?.sha256,
      AnalyzerProvider.sha256(exactOutput))
    await publicationBarrier.release()
    let publicationCompleted = try await publicationRun.value
    XCTAssertEqual(publicationCompleted.state, "succeeded")

    try crashJournalBytes.write(to: publicationJournal)
    try crashRecord.persist(into: publicationJobDirectory)
    try RuntimeAdmissionService(stateDirectory: publicationCrashState).persist(
      crashRecord, at: "2026-08-14T00:00:00Z")
    let publicationRecoveryDispatcher = CountingArkTraceSummaryDispatcher()
    let publicationRecoveryEngine = try RuntimeJobEngine(
      configuration: .init(stateDirectory: publicationCrashState),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: publicationRecoveryDispatcher,
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { "2026-08-14T00:00:01Z" })
    let publicationRecovered = try await publicationRecoveryEngine.recoverActiveJobs()
    let publicationStatus = try XCTUnwrap(
      publicationRecovered.first(where: { $0.jobID == publicationAcceptance.jobID }))
    XCTAssertEqual(publicationStatus.state, "waitingForRecovery")
    XCTAssertTrue(publicationStatus.outcomeUnknown)
    XCTAssertEqual(publicationRecoveryDispatcher.dispatchCount, 0)
    let artifactAfterRecovery = try await artifactStore.list(
      jobID: publicationAcceptance.jobID)
    XCTAssertEqual(
      artifactAfterRecovery.first(where: { $0.name == "trace-summary.json" })?.sha256,
      AnalyzerProvider.sha256(exactOutput))

    let acceptance = try await engine.submit(try JSONEncoder().encode(request))
    let status = try await engine.run(jobID: acceptance.jobID)
    XCTAssertEqual(status.state, "succeeded", "timeline: \(status.timeline)")
    XCTAssertFalse(status.timeline.joined(separator: "\n").contains(sourcePath))

    let inventory = try await artifactStore.list(jobID: acceptance.jobID)
    let derived = try XCTUnwrap(
      inventory.first { $0.name == "trace-summary.json" && $0.status.isPublished })
    XCTAssertEqual(derived.sha256, AnalyzerProvider.sha256(exactOutput))
    XCTAssertEqual(derived.byteCount, exactOutput.count)
    XCTAssertFalse(derived.redactionApplied)
    let derivation = try XCTUnwrap(derived.derivation)
    XCTAssertEqual(derivation.sourceArtifactID, source.artifactID)
    XCTAssertEqual(derivation.sourceSHA256, source.sha256)
    XCTAssertEqual(derivation.sourceByteCount, source.byteCount)
    XCTAssertEqual(derivation.toolSHA256, toolSHA)
    XCTAssertEqual(derivation.parserSHA256, contract.parserSHA256)
    XCTAssertEqual(derivation.parserVersion, contract.parserVersion)
    XCTAssertEqual(derivation.parserAdapterVersion, contract.parserAdapterVersion)
    XCTAssertEqual(derivation.schemaAdapterVersion, contract.schemaAdapterVersion)
    XCTAssertEqual(derivation.indexSchemaVersion, contract.indexSchemaVersion)
    XCTAssertEqual(derivation.timeoutMs, 30_000)
    XCTAssertEqual(derivation.maxRows, 1_000)
    XCTAssertEqual(derivation.maxEvents, 10_000)
    XCTAssertEqual(derivation.maxOutputBytes, 8 * 1024 * 1024)
    let reloadedStore = try RuntimeArtifactStore(
      rootURL: artifactRoot, nowUTC: { "2026-08-14T00:00:01Z" })
    let reloaded = try await reloadedStore.read(
      jobID: acceptance.jobID, artifactID: derived.artifactID)
    XCTAssertEqual(reloaded, exactOutput)
    let reloadedMetadata = try await reloadedStore.inspect(
      jobID: acceptance.jobID, artifactID: derived.artifactID)
    XCTAssertEqual(reloadedMetadata.derivation, derivation)
    let restarted = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(path: "engine", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: FixedArkTraceSummaryDispatcher(output: exactOutput),
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: state.appending(path: "capabilities", directoryHint: .isDirectory)),
      artifactStore: reloadedStore,
      nowUTC: { "2026-08-14T00:00:01Z" })
    let restartedStatus = try await restarted.status(jobID: acceptance.jobID)
    XCTAssertEqual(restartedStatus.state, "succeeded")

    let malformedEngine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(path: "malformed-engine", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: FixedArkTraceSummaryDispatcher(output: Data("{}".utf8)),
      capabilityStore: capabilityStore, artifactStore: reloadedStore,
      nowUTC: { "2026-08-14T00:00:02Z" })
    let malformedRequest = try RuntimeOperationRequest(
      requestID: "req-trace-summary-malformed",
      idempotencyKey: "idem-trace-summary-malformed",
      target: DurableTargetReference(targetID: "TGT-TRACE", expectedBindingRevision: nil),
      operation: RuntimeOperationReference(id: "analyzer.summarize-trace", version: 1),
      inputs: ["sourceArtifactRef": .string(lease)])
    let malformedAcceptance = try await malformedEngine.submit(
      try JSONEncoder().encode(malformedRequest))
    let malformedStatus = try await malformedEngine.run(jobID: malformedAcceptance.jobID)
    let malformedArtifacts = try await reloadedStore.list(jobID: malformedAcceptance.jobID)
    XCTAssertEqual(malformedStatus.state, "failed")
    XCTAssertFalse(
      malformedArtifacts.contains(where: { $0.name == "trace-summary.json" }))

    let timedOutEngine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(path: "timeout-engine", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: FailingArkTraceSummaryDispatcher(
        failure: .outcomeUnknown("analyzer process outcome unknown")),
      capabilityStore: capabilityStore, artifactStore: reloadedStore,
      nowUTC: { "2026-08-14T00:00:03Z" })
    let timedOutRequest = try RuntimeOperationRequest(
      requestID: "req-trace-summary-timeout",
      idempotencyKey: "idem-trace-summary-timeout",
      target: DurableTargetReference(targetID: "TGT-TRACE", expectedBindingRevision: nil),
      operation: RuntimeOperationReference(id: "analyzer.summarize-trace", version: 1),
      inputs: ["sourceArtifactRef": .string(lease)])
    let timedOutAcceptance = try await timedOutEngine.submit(
      try JSONEncoder().encode(timedOutRequest))
    let timedOutStatus = try await timedOutEngine.run(jobID: timedOutAcceptance.jobID)
    let timedOutArtifacts = try await reloadedStore.list(jobID: timedOutAcceptance.jobID)
    XCTAssertEqual(timedOutStatus.state, "waitingForRecovery")
    XCTAssertFalse(
      timedOutArtifacts.contains(where: { $0.name == "trace-summary.json" }))

    // AC-8: a fresh daemon must materialize only the path-free durable
    // Analyzer identity, ask the provider for a recovery decision, and never
    // replay the original process argv. A proven non-execution is terminal
    // and cannot publish an Artifact.
    let recoveryDispatcher = CountingArkTraceSummaryDispatcher()
    let recoveredTimedOutEngine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: state.appending(path: "timeout-engine", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: recoveryDispatcher,
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: state.appending(path: "capabilities", directoryHint: .isDirectory)),
      artifactStore: reloadedStore,
      nowUTC: { "2026-08-14T00:00:04Z" })
    let recoveredActive = try await recoveredTimedOutEngine.recoverActiveJobs()
    XCTAssertEqual(recoveredActive.map(\.jobID), [timedOutAcceptance.jobID])
    let reconciledTimeout = try await recoveredTimedOutEngine.reconcile(
      jobID: timedOutAcceptance.jobID)
    XCTAssertEqual(reconciledTimeout.state, "failed")
    XCTAssertFalse(reconciledTimeout.outcomeUnknown)
    XCTAssertEqual(recoveryDispatcher.dispatchCount, 0)
    XCTAssertFalse(reconciledTimeout.timeline.joined(separator: "\n").contains(sourcePath))
    let reconciledArtifacts = try await reloadedStore.list(jobID: timedOutAcceptance.jobID)
    XCTAssertFalse(
      reconciledArtifacts.contains(where: { $0.name == "trace-summary.json" }))
  }

  private struct DistributionFixture {
    let distributionRoot: URL
    let descriptorURL: URL
    let manifestURL: URL
    let toolURL: URL
    let parserURL: URL
    let receiptURL: URL
    let parserBytes: Data
    let toolBytes: Data
  }

  private func makeSummaryVerificationSubject() async throws -> (
    AnalyzerProvider, TypedProviderAction, ProviderExecutionContext
  ) {
    let fixture = try makeDistribution()
    let profile = try await ArkTraceSummaryAnalyzerProfileLoader(
      doctor: StubArkTraceDoctorProbe(result: true),
      trustChecker: StubArkTraceDistributionTrustChecker())
      .load(descriptorURL: fixture.descriptorURL)
    let provider = try AnalyzerProvider(profiles: [profile])
    let sourceURL = root.appending(path: "bounded-source.htrace")
    let source = Data("trace bytes for envelope".utf8)
    try source.write(to: sourceURL)
    let artifact = ProviderResolvedInputArtifact(
      artifactID: "art-trace-envelope", fileURL: sourceURL,
      sha256: AnalyzerProvider.sha256(source), byteCount: source.count)
    let operation = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: AnalyzerProvider.traceSummary))
    let context = ProviderExecutionContext(
      jobID: "job-trace-envelope", stepID: operation.steps[0].stepID,
      targetID: "TGT-TRACE", bindingRevision: nil,
      nowUTC: "2026-08-14T00:00:00Z", resolvedInputArtifact: artifact)
    let action = try provider.action(
      for: operation.steps[0], operation: operation, inputs: [:], context: context)
    return (provider, action, context)
  }

  private func summaryEnvelope(_ invocation: AnalyzerInvocation) throws -> Data {
    let contract = try XCTUnwrap(invocation.arkTraceSummaryContract)
    let root: [String: Any] = [
      "schemaVersion": "1.0",
      "tool": [
        "name": "arktrace", "version": contract.toolVersion,
        "buildRevision": invocation.executableSHA256,
      ],
      "request": [
        "command": "summary", "parameters": ["startNs": NSNull(), "endNs": NSNull()],
      ],
      "trace": [
        "sha256": invocation.sourceSHA256, "byteCount": invocation.sourceByteCount,
        "durationNs": 100,
        "parser": [
          "name": "trace_streamer", "version": contract.parserVersion,
          "upstreamRevision": contract.parserUpstreamRevision,
          "binarySha256": contract.parserSHA256,
        ],
        "schemaFingerprint": String(repeating: "e", count: 64),
      ],
      "provenance": [
        "parserAdapterVersion": contract.parserAdapterVersion,
        "parserBuildRecipeVersion": contract.parserBuildRecipeVersion,
        "schemaAdapterVersion": contract.schemaAdapterVersion,
        "indexSchemaVersion": contract.indexSchemaVersion,
        "upstreamDatabaseSha256": String(repeating: "f", count: 64),
        "upstreamDatabaseByteCount": 4_096,
      ],
      "limits": [
        "timeoutMs": invocation.timeoutSeconds * 1_000, "maxRows": 1_000,
        "maxEvents": 10_000, "maxOutputBytes": invocation.outputByteBudget!,
      ],
      "dataQuality": ["status": "ok", "warnings": []],
      "truncation": ["truncated": false, "sections": []],
      "result": [
        "range": ["startNs": 0, "endNs": 100], "durationNs": 100,
        "cpuCount": 1, "processCount": 1, "threadCount": 1,
        "cpuSliceCount": 1, "threadStateCount": NSNull(), "namedSliceCount": 1,
        "counterSeriesCount": NSNull(),
        // This is a legal closed ArkTrace value that deliberately resembles
        // a generic secret diagnostic. The exact validated machine bytes must
        // not be rewritten by the Artifact store's text redactor.
        "eventCountBySource": [["source": "token=secretvalue", "count": 2]],
        "capabilities": [
          "cpuScheduling": true, "threadStates": false, "namedSlices": true,
          "cpuCounters": false, "processCounters": false,
        ],
      ],
    ]
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  }

  private func mutateEnvelope(_ data: Data, mutation: String) throws -> Data {
    var root = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    switch mutation {
    case "tool":
      var tool = try XCTUnwrap(root["tool"] as? [String: Any])
      tool["buildRevision"] = String(repeating: "0", count: 64)
      root["tool"] = tool
    case "command":
      var request = try XCTUnwrap(root["request"] as? [String: Any])
      request["command"] = "inspect"
      root["request"] = request
    case "trace":
      var trace = try XCTUnwrap(root["trace"] as? [String: Any])
      trace["sha256"] = String(repeating: "0", count: 64)
      root["trace"] = trace
    case "parser":
      var trace = try XCTUnwrap(root["trace"] as? [String: Any])
      var parser = try XCTUnwrap(trace["parser"] as? [String: Any])
      parser["binarySha256"] = String(repeating: "0", count: 64)
      trace["parser"] = parser
      root["trace"] = trace
    case "provenance": root.removeValue(forKey: "provenance")
    case "extra": root["sourcePath"] = "/Users/reviewer/private.htrace"
    case "count":
      var result = try XCTUnwrap(root["result"] as? [String: Any])
      result["processCount"] = 1_001
      root["result"] = result
    case "capability":
      var result = try XCTUnwrap(root["result"] as? [String: Any])
      var capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
      capabilities["cpuScheduling"] = false
      result["capabilities"] = capabilities
      root["result"] = result
    case "truncation":
      root["truncation"] = ["truncated": true, "sections": ["unknown"]]
    default: XCTFail("unknown envelope mutation")
    }
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
  }

  private func makeDistribution(
    productVersion: String = "0.1.0"
  ) throws -> DistributionFixture {
    let distribution = root.appending(
      path: "distribution-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    let tool = distribution.appending(path: "ArkTraceCLI.app/Contents/MacOS/arktrace")
    let parser = distribution.appending(path: "ArkTraceCLI.app/Contents/Helpers/trace_streamer")
    let parserManifest = distribution.appending(
      path: "ArkTraceCLI.app/Contents/Resources/TraceStreamer/manifest.json")
    let signingRecord = distribution.appending(
      path: "ArkTraceCLI.app/Contents/Resources/TraceStreamer/distribution-signing.json")
    let resourceBundle = distribution.appending(
      path: "ArkTraceCLI.app/Contents/Resources/ArkTraceCLIResources",
      directoryHint: .isDirectory)
    let receipt = distribution.appending(path: "notarization-receipt.json")
    for directory in [
      tool.deletingLastPathComponent(), parser.deletingLastPathComponent(),
      parserManifest.deletingLastPathComponent(), resourceBundle,
    ] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try FileManager.default.copyItem(at: URL(filePath: "/bin/cat"), to: tool)
    try FileManager.default.copyItem(at: URL(filePath: "/bin/echo"), to: parser)
    let parserBytes = try Data(contentsOf: parser)
    let parserManifestBytes = Data("{\"binary\":\"signed\"}\n".utf8)
    let signingRecordBytes = Data("{\"signed\":true}\n".utf8)
    let receiptBytes = Data("{\"status\":\"Accepted\"}\n".utf8)
    try parserManifestBytes.write(to: parserManifest)
    try signingRecordBytes.write(to: signingRecord)
    try receiptBytes.write(to: receipt)
    let toolBytes = try Data(contentsOf: tool)

    let manifestObject: [String: Any] = [
      "formatVersion": 1,
      "source": [
        "revision": String(repeating: "1", count: 40),
        "treeSHA256": String(repeating: "2", count: 64),
      ],
      "product": [
        "name": "arktrace", "version": productVersion, "build": "1",
        "architecture": "arm64", "bundleIdentifier": "com.arktrace.ArkTrace.CLI",
        "jsonContract": ["major": 1, "minor": 0],
      ],
      "layout": [
        "bundle": "ArkTraceCLI.app",
        "executable": "ArkTraceCLI.app/Contents/MacOS/arktrace",
        "parserExecutable": "ArkTraceCLI.app/Contents/Helpers/trace_streamer",
        "parserManifest": "ArkTraceCLI.app/Contents/Resources/TraceStreamer/manifest.json",
        "parserSigningRecord":
          "ArkTraceCLI.app/Contents/Resources/TraceStreamer/distribution-signing.json",
        "resourceBundle": "ArkTraceCLI.app/Contents/Resources/ArkTraceCLIResources",
      ],
      "tool": [
        "binarySHA256": AnalyzerProvider.sha256(toolBytes), "byteCount": toolBytes.count,
        "codeDirectoryHash": String(repeating: "3", count: 40),
      ],
      "traceStreamer": [
        "unsignedBinarySHA256": String(repeating: "4", count: 64),
        "binarySHA256": AnalyzerProvider.sha256(parserBytes), "byteCount": parserBytes.count,
        "codeDirectoryHash": String(repeating: "5", count: 40),
        "manifestSHA256": AnalyzerProvider.sha256(parserManifestBytes),
        "manifestByteCount": parserManifestBytes.count,
        "signingRecordSHA256": AnalyzerProvider.sha256(signingRecordBytes),
        "signingRecordByteCount": signingRecordBytes.count,
        "reportedVersion": "4.3.7",
        "upstreamRevision": String(repeating: "6", count: 40),
        "buildRecipeVersion": String(repeating: "7", count: 64),
      ],
      "signing": [
        "teamIdentifier": "TEAM123456", "identity": "Developer ID Application: Test",
        "certificateSHA1": String(repeating: "A", count: 40),
        "policy": "developer-id-runtime-timestamp",
      ],
      "notarization": [
        "status": "Accepted", "submissionID": UUID().uuidString.lowercased(),
        "receipt": "notarization-receipt.json",
        "receiptSHA256": AnalyzerProvider.sha256(receiptBytes),
        "stapledTicketValidated": true, "gatekeeperAssessment": "accepted",
      ],
      "integrity": [
        "appTreeSHA256": String(repeating: "8", count: 64),
        "resourceTreeSHA256": String(repeating: "9", count: 64),
        "appCodeDirectoryHash": String(repeating: "a", count: 40),
      ],
      "attribution": [
        "license": "LICENSE", "licenseSHA256": String(repeating: "a", count: 64),
        "licenseByteCount": 1, "notice": "THIRD_PARTY_NOTICES.md",
        "noticeSHA256": String(repeating: "b", count: 64), "noticeByteCount": 1,
        "inventory": "ArkTraceCLI.app/Contents/Resources/ArkTraceCLIResources/license-inventory.json",
        "inventorySHA256": String(repeating: "c", count: 64), "inventoryByteCount": 1,
        "licenseFileCount": 18,
        "selfTestFixture": "ArkTraceCLI.app/Contents/Resources/ArkTraceCLIResources/zlib.htrace",
        "selfTestFixtureSHA256": String(repeating: "d", count: 64),
        "selfTestFixtureByteCount": 1,
      ],
      "upgradePolicy": [
        "identity": "distribution-manifest+tool-parser-hashes",
        "installMode": "versioned-directory",
        "pathSelection": "reviewed-absolute-descriptor-only",
        "rollback": "retain-prior-exact-directory",
      ],
    ]
    let manifestData = try JSONSerialization.data(
      withJSONObject: manifestObject, options: [.sortedKeys])
    let manifest = distribution.appending(path: "distribution-manifest.json")
    try manifestData.write(to: manifest)
    let descriptor = root.appending(path: "descriptor-\(UUID().uuidString.lowercased()).json")
    try descriptorData(root: distribution, manifestURL: manifest).write(to: descriptor)
    return DistributionFixture(
      distributionRoot: distribution, descriptorURL: descriptor, manifestURL: manifest,
      toolURL: tool, parserURL: parser, receiptURL: receipt,
      parserBytes: parserBytes, toolBytes: toolBytes)
  }

  private func descriptorData(root: URL, manifestURL: URL) throws -> Data {
    let bytes = try Data(contentsOf: manifestURL)
    return try JSONSerialization.data(
      withJSONObject: [
        "formatVersion": 1,
        "distributionRoot": root.path,
        "manifestSHA256": AnalyzerProvider.sha256(bytes),
      ],
      options: [.sortedKeys])
  }
}
