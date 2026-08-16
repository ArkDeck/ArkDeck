// The deterministic analyzer provider (CHG-2026-055, TASK-HFA-007).
//
// TASK-HFA-001 taught the loop to judge crashes from the device's own fault
// ledger, and it did that by parsing bytes inside the harness process. That
// answer is right and its provenance is invisible: nothing records which
// parser produced it, at what version, from which artifact, so a later
// reader cannot tell a good verdict from a lucky one.
//
// This provider moves that work onto the same path every other external
// effect already takes. An analysis is a runtime job: it declares its input
// artifact, runs a pinned executable through the descriptor-bound
// dispatcher, and publishes a derived artifact whose provenance names the
// source artifact, its hash, and the analyzer reference and version.
//
// Three properties are the point:
//
//   * the analyzer is named, not supplied. `analyzerRef` is a closed
//     vocabulary checked in the step contract, so no input selects a program;
//   * the input is an artifact lease the engine resolved, and the provider
//     re-checks its byte count and digest before reading it. An artifact that
//     does not match its lease is a refusal, not a best effort;
//   * an analysis writes nothing outside its own derived artifact, so
//     recovery confirms "not executed" and a repeat cannot double anything.
//
// What stays out: the engine-internal exception in the architecture's §17.5
// is for pure, in-memory, no-subprocess transforms only. Anything that spawns
// a tool comes here.

import ArkDeckCore
import ArkDeckRuntime
import CryptoKit
import Foundation

package struct AnalyzerProfile: Sendable, Equatable {
  /// Closed reference the step contract also enforces.
  package let analyzerRef: String
  /// The analyzer's own version, recorded on every derived artifact so a
  /// conclusion can be traced to the code that produced it.
  package let analyzerVersion: String
  package let executablePath: String
  public let executableSHA256: String
  package let canonicalNamespaceRoot: String?
  package let fixedArguments: [String]
  package let timeoutSeconds: Int
  package let outputByteBudget: Int
  package let pinnedFiles: [AnalyzerPinnedFile]
  package let pinnedTrees: [AnalyzerPinnedTree]
  package let preflightAvailability: ProviderOperationAvailability
  package let arkTraceSummaryContract: ArkTraceSummaryInvocationContract?
  package let arkTraceAnalysisContract: ArkTraceSummaryInvocationContract?

  public init(
    analyzerRef: String,
    analyzerVersion: String,
    executablePath: String,
    executableSHA256: String,
    canonicalNamespaceRoot: String? = nil,
    fixedArguments: [String] = [],
    timeoutSeconds: Int = 60,
    outputByteBudget: Int = 8 * 1024 * 1024,
    pinnedFiles: [AnalyzerPinnedFile] = [],
    pinnedTrees: [AnalyzerPinnedTree] = [],
    preflightAvailability: ProviderOperationAvailability = .available,
    arkTraceSummaryContract: ArkTraceSummaryInvocationContract? = nil,
    arkTraceAnalysisContract: ArkTraceSummaryInvocationContract? = nil
  ) {
    self.analyzerRef = analyzerRef
    self.analyzerVersion = analyzerVersion
    self.executablePath = executablePath
    self.executableSHA256 = executableSHA256
    self.canonicalNamespaceRoot = canonicalNamespaceRoot
    self.fixedArguments = fixedArguments
    self.timeoutSeconds = timeoutSeconds
    self.outputByteBudget = outputByteBudget
    self.pinnedFiles = pinnedFiles
    self.pinnedTrees = pinnedTrees
    self.preflightAvailability = preflightAvailability
    self.arkTraceSummaryContract = arkTraceSummaryContract
    self.arkTraceAnalysisContract = arkTraceAnalysisContract
  }
}

package struct AnalyzerPinnedTree: Sendable, Equatable {
  package let path: String
  package let sha256: String
}

package struct AnalyzerPinnedFile: Sendable, Equatable {
  package let path: String
  package let sha256: String
  package let byteCount: Int
  package let requireExecutable: Bool

  package init(
    path: String,
    sha256: String,
    byteCount: Int,
    requireExecutable: Bool = false
  ) {
    self.path = path
    self.sha256 = sha256
    self.byteCount = byteCount
    self.requireExecutable = requireExecutable
  }
}

package enum AnalyzerProfileValidationError: Error, Equatable, CustomStringConvertible {
  case unknownAnalyzerRef(String)
  case duplicateAnalyzerRef(String)
  case invalidProfile(String)

  package var description: String {
    switch self {
    case .unknownAnalyzerRef(let reference):
      return "unknown analyzer reference: \(reference)"
    case .duplicateAnalyzerRef(let reference):
      return "duplicate analyzer reference: \(reference)"
    case .invalidProfile(let reason):
      return "invalid analyzer profile: \(reason)"
    }
  }
}

package struct ArkTraceSummaryInvocationContract: Sendable, Equatable, Codable {
  package let toolVersion: String
  package let parserVersion: String
  package let parserUpstreamRevision: String
  package let parserSHA256: String
  package let parserBuildRecipeVersion: String
  package let parserAdapterVersion: String
  package let schemaAdapterVersion: String
  package let indexSchemaVersion: Int
}

package enum ArkTraceAnalysisKind: String, Sendable, Equatable, Codable, CaseIterable {
  case context
  case cpu
  case scheduling
  case slices
  case range
  case hotIntervals = "hot-intervals"

  package var cliAnalysisKind: String? {
    self == .context ? nil : rawValue
  }
}

package struct ArkTraceAnalysisRequest: Sendable, Equatable, Codable {
  package static let halfWindowNs: Int64 = 50_000_000

  package let kind: ArkTraceAnalysisKind
  package let timestampNs: Int64?
  package let startNs: Int64?
  package let endNs: Int64?
  package let processKey: Int64?
  package let pid: Int64?
  package let threadKey: Int64?
  package let tid: Int64?
  package let thresholdNs: Int64
  package let limit: Int
  package let timeoutMs: Int
  package let maxRows: Int
  package let maxEvents: Int
  package let maxOutputBytes: Int

  package var processTimeoutSeconds: Int {
    max(1, min(120, (timeoutMs + 999) / 1_000))
  }

  /// Path-free canonical identity carried by the durable recovery record.
  /// Delimiters are unambiguous because every free-form value has already
  /// been reduced to a closed enum or an exact integer.
  package var recoveryDigestSHA256: String {
    var fields = ["arktrace-analysis-request@1", kind.rawValue]
    fields.append(timestampNs.map(String.init) ?? "null")
    fields.append(startNs.map(String.init) ?? "null")
    fields.append(endNs.map(String.init) ?? "null")
    fields.append(processKey.map(String.init) ?? "null")
    fields.append(pid.map(String.init) ?? "null")
    fields.append(threadKey.map(String.init) ?? "null")
    fields.append(tid.map(String.init) ?? "null")
    fields.append(contentsOf: [
      String(thresholdNs), String(limit), String(timeoutMs), String(maxRows),
      String(maxEvents), String(maxOutputBytes),
    ])
    return AnalyzerProvider.sha256(Data(fields.joined(separator: "\u{0}").utf8))
  }

  package var normalizedRange: (startNs: Int64, endNs: Int64)? {
    if let startNs, let endNs { return (startNs, endNs) }
    guard let timestampNs else { return nil }
    let start = max(0, timestampNs - min(timestampNs, Self.halfWindowNs))
    let (end, overflow) = timestampNs.addingReportingOverflow(Self.halfWindowNs)
    guard !overflow, start < end else { return nil }
    return (start, end)
  }

  package func arguments(sourcePath: String) -> [String] {
    var result = [
      kind == .context ? "context" : "analyze",
      "--json", "--no-cache", "--timeout-ms", String(timeoutMs),
      "--max-rows", String(maxRows), "--max-events", String(maxEvents),
      "--max-output-bytes", String(maxOutputBytes),
    ]
    if kind == .context, let timestampNs {
      result += ["--timestamp-ns", String(timestampNs), "--window-ms", "50"]
    } else if let normalizedRange {
      if kind != .context, let cliKind = kind.cliAnalysisKind {
        result += ["--kind", cliKind]
      }
      result += [
        "--start-ns", String(normalizedRange.startNs),
        "--end-ns", String(normalizedRange.endNs),
      ]
    }
    if let processKey { result += ["--process-key", String(processKey)] }
    if let pid { result += ["--pid", String(pid)] }
    if let threadKey { result += ["--thread-key", String(threadKey)] }
    if let tid { result += ["--tid", String(tid)] }
    if kind != .context {
      result += ["--threshold-ns", String(thresholdNs), "--limit", String(limit)]
    }
    result.append(sourcePath)
    return result
  }
}

public struct AnalyzerInvocation: Sendable, Equatable, Codable {
  package let analyzerRef: String
  package let analyzerVersion: String
  public let executableSHA256: String
  public let arguments: [String]
  package let timeoutSeconds: Int
  package let outputByteBudget: Int?
  package let sourceArtifactID: String
  package let sourceSHA256: String
  package let sourceByteCount: Int
  package let arkTraceSummaryContract: ArkTraceSummaryInvocationContract?
  package let arkTraceAnalysisRequest: ArkTraceAnalysisRequest?
  package let arkTraceAnalysisContract: ArkTraceSummaryInvocationContract?

  package init(
    analyzerRef: String,
    analyzerVersion: String,
    executableSHA256: String,
    arguments: [String],
    timeoutSeconds: Int,
    outputByteBudget: Int?,
    sourceArtifactID: String,
    sourceSHA256: String,
    sourceByteCount: Int,
    arkTraceSummaryContract: ArkTraceSummaryInvocationContract? = nil,
    arkTraceAnalysisRequest: ArkTraceAnalysisRequest? = nil,
    arkTraceAnalysisContract: ArkTraceSummaryInvocationContract? = nil
  ) {
    self.analyzerRef = analyzerRef
    self.analyzerVersion = analyzerVersion
    self.executableSHA256 = executableSHA256
    self.arguments = arguments
    self.timeoutSeconds = timeoutSeconds
    self.outputByteBudget = outputByteBudget
    self.sourceArtifactID = sourceArtifactID
    self.sourceSHA256 = sourceSHA256
    self.sourceByteCount = sourceByteCount
    self.arkTraceSummaryContract = arkTraceSummaryContract
    self.arkTraceAnalysisRequest = arkTraceAnalysisRequest
    self.arkTraceAnalysisContract = arkTraceAnalysisContract
  }
}

/// The path-free identity retained behind an Analyzer write-ahead intent.
///
/// This value exists only so a restarted Runtime can ask the Analyzer
/// provider whether an outcome-unknown host-only action executed. It carries
/// no executable or argv and therefore cannot be lowered or dispatched as a
/// new analysis.
public struct AnalyzerRecoveryIdentity: Sendable, Equatable, Codable {
  package let analyzerRef: String
  package let analyzerVersion: String
  package let sourceArtifactID: String
  package let sourceSHA256: String
  package let sourceByteCount: Int
  package let requestDigestSHA256: String?

  package init(
    analyzerRef: String,
    analyzerVersion: String,
    sourceArtifactID: String,
    sourceSHA256: String,
    sourceByteCount: Int,
    requestDigestSHA256: String? = nil
  ) {
    self.analyzerRef = analyzerRef
    self.analyzerVersion = analyzerVersion
    self.sourceArtifactID = sourceArtifactID
    self.sourceSHA256 = sourceSHA256
    self.sourceByteCount = sourceByteCount
    self.requestDigestSHA256 = requestDigestSHA256
  }

  package init(_ invocation: AnalyzerInvocation) {
    self.init(
      analyzerRef: invocation.analyzerRef,
      analyzerVersion: invocation.analyzerVersion,
      sourceArtifactID: invocation.sourceArtifactID,
      sourceSHA256: invocation.sourceSHA256,
      sourceByteCount: invocation.sourceByteCount,
      requestDigestSHA256: invocation.arkTraceAnalysisRequest?.recoveryDigestSHA256)
  }
}

public enum AnalyzerProviderAction: Sendable, Equatable, Codable {
  case analyze(AnalyzerInvocation)
  /// Recovery-only. `AnalyzerProvider.lower` deliberately rejects this case.
  case reconcile(AnalyzerRecoveryIdentity)
}

package struct AnalyzerProvider: DeviceProvider {
  package static let crashSignature = "analyzer.extract-crash-signature@1"
  package static let hilogSummary = "analyzer.summarize-hilog@1"
  package static let traceSummary = "analyzer.summarize-trace@1"
  package static let traceAnalysis = "analyzer.analyze-trace@1"

  /// Which analyzer each published operation is allowed to name. The mapping
  /// lives here rather than in the request: an operation cannot be pointed at
  /// a different analyzer by its caller.
  package static let analyzerForOperation: [String: String] = [
    crashSignature: "crash-signature@1",
    hilogSummary: "hilog-summary@1",
    traceSummary: "trace-summary@1",
    traceAnalysis: "trace-analysis@1",
  ]

  /// The artifact each analyzer publishes. One table, used by both the
  /// descriptors and the engine's step materialization, so a rename cannot
  /// leave the two disagreeing about where the result landed.
  package static func derivedArtifactName(_ analyzerRef: String) -> String {
    switch analyzerRef {
    case "crash-signature@1": return "crash-signature.json"
    case "hilog-summary@1": return "hilog-summary.json"
    case "trace-summary@1": return "trace-summary.json"
    case "trace-analysis@1": return "trace-analysis.json"
    default: return "analysis.json"
    }
  }

  private let profiles: [String: AnalyzerProfile]
  private let unavailableReasons: [String: String]

  public init() {
    self.profiles = [:]
    self.unavailableReasons = [:]
  }

  public init(
    profiles: [AnalyzerProfile],
    unavailableReasons: [String: String] = [:]
  ) throws {
    self.profiles = try Self.validatedProfiles(profiles)
    self.unavailableReasons = unavailableReasons
  }

  public var providerID: String { CatalogProvider.analyzer.rawValue }

  package func runtimeAvailability(
    for operation: CatalogOperationDescriptor
  ) -> ProviderOperationAvailability {
    guard let analyzerRef = Self.analyzerForOperation[operation.reference] else {
      return .unavailable(
        code: .operationNotSupported, reason: "analyzer.unsupportedOperation")
    }
    guard let profile = profiles[analyzerRef] else {
      // Machine-readable, and nothing is admitted: no capability is spent on
      // an analyzer this host has not been given (PRODUCT-LOOP §8).
      return .unavailable(
        code: .providerToolUnavailable,
        reason: unavailableReasons[analyzerRef] ?? "analyzer.profileUnavailable")
    }
    guard profile.preflightAvailability == .available else {
      return profile.preflightAvailability
    }
    guard ArkTraceProfileFileReader.matches(
      path: profile.executablePath,
      sha256: profile.executableSHA256,
      byteCount: nil,
      maximumByteCount: 128 * 1024 * 1024,
      requireExecutable: true)
    else {
      return .unavailable(
        code: .toolIdentityDrift, reason: "analyzer.toolIdentityDrift")
    }
    for pinned in profile.pinnedFiles {
      guard ArkTraceProfileFileReader.matches(
        path: pinned.path,
        sha256: pinned.sha256,
        byteCount: pinned.byteCount,
        maximumByteCount: 128 * 1024 * 1024,
        requireExecutable: pinned.requireExecutable)
      else {
        return .unavailable(
          code: .toolIdentityDrift, reason: "analyzer.profileIdentityDrift")
      }
    }
    for pinned in profile.pinnedTrees {
      guard ArkTraceDistributionTreeHasher.matches(
        rootPath: pinned.path, expectedSHA256: pinned.sha256)
      else {
        return .unavailable(
          code: .toolIdentityDrift, reason: "analyzer.profileIdentityDrift")
      }
    }
    return .available
  }

  /// Host-only: there is no device, and inventing facts for one is exactly
  /// what the host-only admission path exists to avoid.
  package func resolveFacts(targetID: String) async throws -> ProviderFacts {
    throw DeviceProviderError.factsUnavailable(
      "analyzer provider is host-only: it has no device facts for \(targetID)")
  }

  package func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) throws -> TypedProviderAction {
    throw DeviceProviderError.factsUnavailable(
      "analyzer action materialization requires a resolved input artifact")
  }

  package func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue],
    context: ProviderExecutionContext
  ) throws -> TypedProviderAction {
    guard step.kind == .runDeterministicAnalyzer,
      let analyzerRef = Self.analyzerForOperation[operation.reference]
    else {
      throw DeviceProviderError.unsupportedAction(
        "analyzer provider does not implement \(operation.reference)/\(step.stepID)")
    }
    guard let profile = profiles[analyzerRef] else {
      throw DeviceProviderError.unsupportedAction("analyzer.profileUnavailable:\(analyzerRef)")
    }
    guard let artifact = context.resolvedInputArtifact else {
      throw DeviceProviderError.unsupportedAction(
        "analyzer input Artifact lease was not resolved before materialization")
    }
    guard artifact.byteCount > 0,
      artifact.byteCount <= 512 * 1024 * 1024,
      let snapshot = try? ArkTraceProfileFileReader.read(
        path: artifact.fileURL.path, maximumByteCount: artifact.byteCount),
      snapshot.data.count == artifact.byteCount,
      AnalyzerProvider.sha256(snapshot.data) == artifact.sha256
    else {
      // The lease is the claim; the bytes are the fact. A mismatch means the
      // analysis would describe something other than what was collected.
      throw DeviceProviderError.unsupportedAction(
        "analyzer input Artifact bytes do not match their lease")
    }
    let analysisRequest: ArkTraceAnalysisRequest?
    let arguments: [String]
    let timeoutSeconds: Int
    let outputByteBudget: Int
    if analyzerRef == "trace-analysis@1" {
      analysisRequest = try Self.analysisRequest(inputs)
      arguments = analysisRequest!.arguments(sourcePath: artifact.fileURL.path)
      timeoutSeconds = analysisRequest!.processTimeoutSeconds
      outputByteBudget = analysisRequest!.maxOutputBytes
    } else {
      analysisRequest = nil
      arguments = profile.fixedArguments + [artifact.fileURL.path]
      timeoutSeconds = profile.timeoutSeconds
      outputByteBudget = profile.outputByteBudget
    }
    return .analyzer(
      .analyze(
        AnalyzerInvocation(
          analyzerRef: profile.analyzerRef,
          analyzerVersion: profile.analyzerVersion,
          executableSHA256: profile.executableSHA256,
          arguments: arguments,
          timeoutSeconds: timeoutSeconds,
          outputByteBudget: outputByteBudget,
          sourceArtifactID: artifact.artifactID,
          sourceSHA256: artifact.sha256,
          sourceByteCount: artifact.byteCount,
          arkTraceSummaryContract: profile.arkTraceSummaryContract,
          arkTraceAnalysisRequest: analysisRequest,
          arkTraceAnalysisContract: profile.arkTraceAnalysisContract)))
  }

  package func lower(
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan {
    guard case .analyzer(.analyze(let invocation)) = action else {
      throw DeviceProviderError.unsupportedAction("non-analyzer action given to analyzer provider")
    }
    return TypedProcessPlan(
      action: action,
      kind: .process(
        executableSHA256: invocation.executableSHA256,
        argumentSummary: invocation.arguments,
        timeoutSeconds: invocation.timeoutSeconds))
  }

  package func verify(
    receipt: ProviderProcessReceipt,
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> ProviderSemanticOutcome {
    guard case .analyzer(.analyze(let invocation)) = action else {
      throw DeviceProviderError.unsupportedAction("non-analyzer action given to analyzer provider")
    }
    guard receipt.exitStatus == 0 else {
      return .failed(
        code: "analyzer.failed",
        detail:
          "\(invocation.analyzerRef) exited \(receipt.exitStatus.map(String.init) ?? "unknown")")
    }
    guard !receipt.stdoutTruncated else {
      return .failed(
        code: "analyzer.truncatedResult",
        detail: "\(invocation.analyzerRef) output was truncated")
    }
    if let budget = invocation.outputByteBudget, receipt.stdout.count > budget {
      return .failed(
        code: "analyzer.outputLimitExceeded",
        detail: "\(invocation.analyzerRef) output exceeded its byte budget")
    }
    guard !receipt.stdout.isEmpty else {
      // An empty derived artifact is not a conclusion. Publishing one would
      // let a later reader treat "the analyzer produced nothing" as
      // "the analyzer found nothing".
      return .failed(
        code: "analyzer.emptyResult",
        detail: "\(invocation.analyzerRef) produced no output for \(invocation.sourceArtifactID)")
    }
    guard (try? JSONSerialization.jsonObject(with: receipt.stdout)) != nil else {
      // The descriptor declares a structured artifact. If the analyzer did
      // not produce one, saying so beats publishing text under a .json name
      // that every downstream reader will try to parse.
      return .failed(
        code: "analyzer.malformedResult",
        detail: "\(invocation.analyzerRef) did not produce a structured result")
    }
    if invocation.analyzerRef == HarnessCrashLedgerAnalysis.analyzerRef {
      guard
        let result = try? JSONDecoder().decode(
          HarnessCrashLedgerAnalysis.self, from: receipt.stdout),
        result.schemaVersion == HarnessCrashLedgerAnalysis.schemaVersion,
        result.analyzerRef == invocation.analyzerRef,
        result.analyzerVersion == invocation.analyzerVersion
      else {
        return .failed(
          code: "analyzer.schemaMismatch",
          detail: "\(invocation.analyzerRef) produced JSON outside its versioned schema")
      }
    } else if invocation.analyzerRef == "trace-summary@1" {
      guard receipt.stderr.isEmpty,
        ArkTraceSummaryEnvelopeValidator.validate(
          receipt.stdout, invocation: invocation)
      else {
        return .failed(
          code: "analyzer.schemaMismatch",
          detail: "\(invocation.analyzerRef) produced JSON outside ArkTrace contract 1.0")
      }
    } else if invocation.analyzerRef == "trace-analysis@1" {
      guard receipt.stderr.isEmpty,
        ArkTraceAnalysisEnvelopeValidator.validate(
          receipt.stdout, invocation: invocation)
      else {
        return .failed(
          code: "analyzer.schemaMismatch",
          detail: "\(invocation.analyzerRef) produced JSON outside ArkTrace analysis contract 1.0")
      }
    }
    // Provenance travels with the derived artifact: which artifact it came
    // from, that artifact's digest, which analyzer at which version, and the
    // digest of what was produced.
    var summary = [
      "analyzerRef": invocation.analyzerRef,
      "analyzerVersion": invocation.analyzerVersion,
      "sourceArtifactId": invocation.sourceArtifactID,
      "sourceSha256": invocation.sourceSHA256,
      "sourceByteCount": String(invocation.sourceByteCount),
      "derivedSha256": AnalyzerProvider.sha256(receipt.stdout),
      "derivedByteCount": String(receipt.stdout.count),
      "truncated": receipt.stdoutTruncated ? "true" : "false",
    ]
    if let contract = invocation.arkTraceSummaryContract {
      summary["toolSha256"] = invocation.executableSHA256
      summary["parserSha256"] = contract.parserSHA256
      summary["parserVersion"] = contract.parserVersion
      summary["parserUpstreamRevision"] = contract.parserUpstreamRevision
      summary["parserBuildRecipeVersion"] = contract.parserBuildRecipeVersion
      summary["parserAdapterVersion"] = contract.parserAdapterVersion
      summary["schemaAdapterVersion"] = contract.schemaAdapterVersion
      summary["indexSchemaVersion"] = String(contract.indexSchemaVersion)
      summary["requestTimeoutMs"] = String(invocation.timeoutSeconds * 1_000)
      summary["requestMaxRows"] = "1000"
      summary["requestMaxEvents"] = "10000"
      summary["requestMaxOutputBytes"] = String(invocation.outputByteBudget ?? 0)
    }
    if let contract = invocation.arkTraceAnalysisContract,
      let request = invocation.arkTraceAnalysisRequest
    {
      summary["toolSha256"] = invocation.executableSHA256
      summary["parserSha256"] = contract.parserSHA256
      summary["parserVersion"] = contract.parserVersion
      summary["parserUpstreamRevision"] = contract.parserUpstreamRevision
      summary["parserBuildRecipeVersion"] = contract.parserBuildRecipeVersion
      summary["parserAdapterVersion"] = contract.parserAdapterVersion
      summary["schemaAdapterVersion"] = contract.schemaAdapterVersion
      summary["indexSchemaVersion"] = String(contract.indexSchemaVersion)
      summary["requestCommand"] = request.kind == .context ? "context" : "analyze"
      summary["requestKind"] = request.kind.rawValue
      summary["requestTimestampNs"] = request.timestampNs.map(String.init) ?? "null"
      summary["requestStartNs"] = request.startNs.map(String.init) ?? "null"
      summary["requestEndNs"] = request.endNs.map(String.init) ?? "null"
      summary["requestProcessKey"] = request.processKey.map(String.init) ?? "null"
      summary["requestPid"] = request.pid.map(String.init) ?? "null"
      summary["requestThreadKey"] = request.threadKey.map(String.init) ?? "null"
      summary["requestTid"] = request.tid.map(String.init) ?? "null"
      summary["requestThresholdNs"] = String(request.thresholdNs)
      summary["requestLimit"] = String(request.limit)
      summary["requestTimeoutMs"] = String(request.timeoutMs)
      summary["requestMaxRows"] = String(request.maxRows)
      summary["requestMaxEvents"] = String(request.maxEvents)
      summary["requestMaxOutputBytes"] = String(request.maxOutputBytes)
    }
    return .verified(summary: summary)
  }

  /// Analysis writes nothing outside its own derived artifact, so there is no
  /// external effect for recovery to confirm and a repeat cannot double
  /// anything.
  public func reconcile(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) async throws -> ProviderReconcileOutcome {
    let recoveryIdentity: AnalyzerRecoveryIdentity
    switch intent.action {
    case .analyzer(.analyze(let invocation)):
      recoveryIdentity = AnalyzerRecoveryIdentity(invocation)
    case .analyzer(.reconcile(let identity)):
      recoveryIdentity = identity
    default:
      return .stillUnknown(reason: "analyzer reconcile received a foreign action")
    }
    if recoveryIdentity.analyzerRef == "trace-analysis@1" {
      guard let digest = recoveryIdentity.requestDigestSHA256,
        digest.count == 64,
        digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
      else {
        return .stillUnknown(reason: "analyzer reconcile request identity is incomplete")
      }
    }
    guard let artifact = context.resolvedInputArtifact,
      artifact.artifactID == recoveryIdentity.sourceArtifactID,
      artifact.sha256 == recoveryIdentity.sourceSHA256,
      artifact.byteCount == recoveryIdentity.sourceByteCount
    else {
      return .stillUnknown(reason: "analyzer reconcile source identity does not match")
    }
    return .confirmedNotExecuted
  }

  package func reconciliationReadback(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan? {
    nil
  }

  package func verifyReconciliationReadback(
    receipt: ProviderProcessReceipt,
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) throws -> ProviderReconcileOutcome {
    .stillUnknown(reason: "analyzer provider publishes no readback plan")
  }

  static func sha256(_ bytes: Data) -> String {
    SHA256Hex.string(of: bytes)
  }

  package static func analysisRequest(
    _ inputs: [String: JSONValue]
  ) throws -> ArkTraceAnalysisRequest {
    func integer(_ key: String) -> Int64? {
      switch inputs[key] {
      case .integer(let value): return value
      case .unsignedInteger(let value): return Int64(exactly: value)
      default: return nil
      }
    }
    let optionalIntegerKeys = [
      "timestampNs", "startNs", "endNs", "processKey", "pid", "threadKey", "tid",
      "thresholdNs", "limit",
    ]
    let allowedKeys = Set(optionalIntegerKeys + [
      "sourceArtifactRef", "kind", "timeoutMs", "maxRows", "maxEvents", "maxOutputBytes",
    ])
    guard inputs.keys.allSatisfy(allowedKeys.contains),
      optionalIntegerKeys.allSatisfy({ inputs[$0] == nil || integer($0) != nil })
    else {
      throw DeviceProviderError.unsupportedAction(
        "analyzer analysis inputs violate the closed request contract")
    }
    guard case .string(let rawKind)? = inputs["kind"],
      let kind = ArkTraceAnalysisKind(rawValue: rawKind),
      let timeout = integer("timeoutMs").flatMap({ Int(exactly: $0) }),
      let maxRows = integer("maxRows").flatMap({ Int(exactly: $0) }),
      let maxEvents = integer("maxEvents").flatMap({ Int(exactly: $0) }),
      let maxOutput = integer("maxOutputBytes").flatMap({ Int(exactly: $0) })
    else {
      throw DeviceProviderError.unsupportedAction("analyzer analysis inputs are incomplete")
    }
    let timestamp = integer("timestampNs")
    let start = integer("startNs")
    let end = integer("endNs")
    let threshold = integer("thresholdNs") ?? 0
    let defaultLimit = min(1_000, min(maxRows, maxEvents))
    let limit = integer("limit").flatMap({ Int(exactly: $0) }) ?? defaultLimit
    let hasTimestamp = inputs["timestampNs"] != nil
    let hasStart = inputs["startNs"] != nil
    let hasEnd = inputs["endNs"] != nil
    guard (hasTimestamp && !hasStart && !hasEnd)
      || (!hasTimestamp && hasStart && hasEnd),
      (start == nil && end == nil) || (start != nil && end != nil && start! < end!),
      timeout >= 100, timeout <= 120_000,
      maxRows >= 1, maxRows <= 100_000,
      maxEvents >= 1, maxEvents <= 100_000,
      maxOutput >= 1_024, maxOutput <= 64 * 1_024 * 1_024,
      threshold >= 0, limit >= 1,
      limit <= min(1_000, min(maxRows, maxEvents)),
      timestamp.map({ $0 >= 0 }) ?? true,
      start.map({ $0 >= 0 }) ?? true,
      end.map({ $0 >= 1 }) ?? true,
      integer("pid").map({ $0 >= 0 }) ?? true,
      integer("tid").map({ $0 >= 0 }) ?? true,
      integer("processKey") != 0,
      integer("threadKey") != 0,
      !(inputs["processKey"] != nil && inputs["pid"] != nil),
      !(inputs["threadKey"] != nil && inputs["tid"] != nil),
      kind != .context || (inputs["thresholdNs"] == nil && inputs["limit"] == nil)
    else {
      throw DeviceProviderError.unsupportedAction(
        "analyzer analysis inputs violate the closed request contract")
    }
    let request = ArkTraceAnalysisRequest(
      kind: kind, timestampNs: timestamp, startNs: start, endNs: end,
      processKey: integer("processKey"), pid: integer("pid"),
      threadKey: integer("threadKey"), tid: integer("tid"),
      thresholdNs: threshold, limit: limit, timeoutMs: timeout,
      maxRows: maxRows, maxEvents: maxEvents, maxOutputBytes: maxOutput)
    guard request.normalizedRange != nil else {
      throw DeviceProviderError.unsupportedAction("analyzer analysis time selection is invalid")
    }
    return request
  }

  package static func validatedProfiles(
    _ profiles: [AnalyzerProfile]
  ) throws -> [String: AnalyzerProfile] {
    let known = Set(analyzerForOperation.values)
    var result: [String: AnalyzerProfile] = [:]
    for profile in profiles {
      guard known.contains(profile.analyzerRef) else {
        throw AnalyzerProfileValidationError.unknownAnalyzerRef(profile.analyzerRef)
      }
      guard result[profile.analyzerRef] == nil else {
        throw AnalyzerProfileValidationError.duplicateAnalyzerRef(profile.analyzerRef)
      }
      guard profile.executablePath.hasPrefix("/"),
        profile.executableSHA256.count == 64,
        profile.executableSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
        !profile.analyzerVersion.isEmpty,
        profile.timeoutSeconds > 0,
        profile.timeoutSeconds <= 120,
        profile.outputByteBudget >= 1_024,
        profile.outputByteBudget <= 64 * 1024 * 1024,
        Set(profile.pinnedFiles.map(\.path)).count == profile.pinnedFiles.count,
        profile.pinnedFiles.allSatisfy({
          $0.path.hasPrefix("/") && $0.byteCount > 0
            && $0.sha256.count == 64
            && $0.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        }),
        Set(profile.pinnedTrees.map(\.path)).count == profile.pinnedTrees.count,
        profile.pinnedTrees.allSatisfy({
          $0.path.hasPrefix("/") && $0.sha256.count == 64
            && $0.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        }),
        (profile.analyzerRef == "trace-summary@1") == (profile.arkTraceSummaryContract != nil),
        (profile.analyzerRef == "trace-analysis@1") == (profile.arkTraceAnalysisContract != nil)
      else {
        throw AnalyzerProfileValidationError.invalidProfile(profile.analyzerRef)
      }
      result[profile.analyzerRef] = profile
    }
    return result
  }
}

/// Resolves the pinned executable for an analysis plan. Identity is checked
/// by the dispatcher against this table, so a drifted binary cannot run under
/// a registered analyzer's name (CHG-2026-055, TASK-HFA-007).
package struct AnalyzerExecutableResolver: RuntimeExecutableResolving {
  private let table: [String: ResolvedExecutable]

  /// Resolver selection is made from the closed typed action. Profile order,
  /// provider ID, caller input and PATH never choose analyzer bytes.
  public init(profiles: [AnalyzerProfile]) throws {
    let validated = try AnalyzerProvider.validatedProfiles(profiles)
    self.table = validated.mapValues {
      ResolvedExecutable(
        path: $0.executablePath,
        sha256: $0.executableSHA256,
        verifiedResources: $0.pinnedFiles.map {
          ResolvedExecutableResource(
            path: $0.path, sha256: $0.sha256,
            byteCount: max(1, $0.byteCount),
            requireExecutable: $0.requireExecutable)
        },
        verifiedTrees: $0.pinnedTrees.map {
          ResolvedExecutableTreeResource(path: $0.path, sha256: $0.sha256)
        },
        canonicalNamespaceRoot: $0.canonicalNamespaceRoot)
    }
  }

  package func resolveExecutable(providerID: String) throws -> ResolvedExecutable {
    guard providerID == "analyzer",
      let executable = table.sorted(by: { $0.key < $1.key }).first?.value
    else {
      throw DeviceProviderError.unsupportedAction("analyzer.executableUnavailable")
    }
    return executable
  }

  package func resolveExecutable(for action: TypedProviderAction) throws -> ResolvedExecutable {
    guard case .analyzer(.analyze(let invocation)) = action,
      let executable = table[invocation.analyzerRef],
      executable.sha256 == invocation.executableSHA256
    else {
      throw DeviceProviderError.unsupportedAction("analyzer.actionIdentityUnavailable")
    }
    return executable
  }
}
