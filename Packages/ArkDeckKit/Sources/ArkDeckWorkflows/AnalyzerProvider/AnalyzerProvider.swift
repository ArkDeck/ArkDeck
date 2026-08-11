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

public struct AnalyzerProfile: Sendable, Equatable {
  /// Closed reference the step contract also enforces.
  public let analyzerRef: String
  /// The analyzer's own version, recorded on every derived artifact so a
  /// conclusion can be traced to the code that produced it.
  public let analyzerVersion: String
  public let executablePath: String
  public let executableSHA256: String
  public let fixedArguments: [String]
  public let timeoutSeconds: Int

  public init(
    analyzerRef: String,
    analyzerVersion: String,
    executablePath: String,
    executableSHA256: String,
    fixedArguments: [String] = [],
    timeoutSeconds: Int = 60
  ) {
    self.analyzerRef = analyzerRef
    self.analyzerVersion = analyzerVersion
    self.executablePath = executablePath
    self.executableSHA256 = executableSHA256
    self.fixedArguments = fixedArguments
    self.timeoutSeconds = timeoutSeconds
  }
}

package struct AnalyzerInvocation: Sendable, Equatable, Codable {
  public let analyzerRef: String
  public let analyzerVersion: String
  public let executableSHA256: String
  public let arguments: [String]
  public let timeoutSeconds: Int
  public let sourceArtifactID: String
  public let sourceSHA256: String
  public let sourceByteCount: Int
}

package enum AnalyzerProviderAction: Sendable, Equatable, Codable {
  case analyze(AnalyzerInvocation)
}

public struct AnalyzerProvider: DeviceProvider {
  public static let crashSignature = "analyzer.extract-crash-signature@1"
  public static let hilogSummary = "analyzer.summarize-hilog@1"
  public static let traceSummary = "analyzer.summarize-trace@1"

  /// Which analyzer each published operation is allowed to name. The mapping
  /// lives here rather than in the request: an operation cannot be pointed at
  /// a different analyzer by its caller.
  public static let analyzerForOperation: [String: String] = [
    crashSignature: "crash-signature@1",
    hilogSummary: "hilog-summary@1",
    traceSummary: "trace-summary@1",
  ]

  /// The artifact each analyzer publishes. One table, used by both the
  /// descriptors and the engine's step materialization, so a rename cannot
  /// leave the two disagreeing about where the result landed.
  public static func derivedArtifactName(_ analyzerRef: String) -> String {
    switch analyzerRef {
    case "crash-signature@1": return "crash-signature.json"
    case "hilog-summary@1": return "hilog-summary.json"
    case "trace-summary@1": return "trace-summary.json"
    default: return "analysis.json"
    }
  }

  private let profiles: [String: AnalyzerProfile]

  public init(profiles: [AnalyzerProfile] = []) {
    self.profiles = Dictionary(
      profiles.map { ($0.analyzerRef, $0) }, uniquingKeysWith: { first, _ in first })
  }

  public var providerID: String { CatalogProvider.analyzer.rawValue }

  public func runtimeAvailability(
    for operation: CatalogOperationDescriptor
  ) -> ProviderOperationAvailability {
    guard let analyzerRef = Self.analyzerForOperation[operation.reference] else {
      return .unavailable(reason: "analyzer.unsupportedOperation")
    }
    guard let profile = profiles[analyzerRef] else {
      // Machine-readable, and nothing is admitted: no capability is spent on
      // an analyzer this host has not been given (PRODUCT-LOOP §8).
      return .unavailable(reason: "analyzer.profileUnavailable")
    }
    guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: profile.executablePath)),
      AnalyzerProvider.sha256(bytes) == profile.executableSHA256
    else {
      return .unavailable(reason: "analyzer.toolIdentityDrift")
    }
    return .available
  }

  /// Host-only: there is no device, and inventing facts for one is exactly
  /// what the host-only admission path exists to avoid.
  public func resolveFacts(targetID: String) async throws -> ProviderFacts {
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
    let bytes = try Data(contentsOf: artifact.fileURL)
    guard bytes.count == artifact.byteCount,
      AnalyzerProvider.sha256(bytes) == artifact.sha256
    else {
      // The lease is the claim; the bytes are the fact. A mismatch means the
      // analysis would describe something other than what was collected.
      throw DeviceProviderError.unsupportedAction(
        "analyzer input Artifact bytes do not match their lease")
    }
    return .analyzer(
      .analyze(
        AnalyzerInvocation(
          analyzerRef: profile.analyzerRef,
          analyzerVersion: profile.analyzerVersion,
          executableSHA256: profile.executableSHA256,
          arguments: profile.fixedArguments + [artifact.fileURL.path],
          timeoutSeconds: profile.timeoutSeconds,
          sourceArtifactID: artifact.artifactID,
          sourceSHA256: artifact.sha256,
          sourceByteCount: artifact.byteCount)))
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
        detail: "\(invocation.analyzerRef) exited \(receipt.exitStatus.map(String.init) ?? "unknown")")
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
      guard let result = try? JSONDecoder().decode(
        HarnessCrashLedgerAnalysis.self, from: receipt.stdout),
        result.schemaVersion == HarnessCrashLedgerAnalysis.schemaVersion,
        result.analyzerRef == invocation.analyzerRef,
        result.analyzerVersion == invocation.analyzerVersion
      else {
        return .failed(
          code: "analyzer.schemaMismatch",
          detail: "\(invocation.analyzerRef) produced JSON outside its versioned schema")
      }
    }
    // Provenance travels with the derived artifact: which artifact it came
    // from, that artifact's digest, which analyzer at which version, and the
    // digest of what was produced.
    return .verified(summary: [
      "analyzerRef": invocation.analyzerRef,
      "analyzerVersion": invocation.analyzerVersion,
      "sourceArtifactId": invocation.sourceArtifactID,
      "sourceSha256": invocation.sourceSHA256,
      "sourceByteCount": String(invocation.sourceByteCount),
      "derivedSha256": AnalyzerProvider.sha256(receipt.stdout),
      "derivedByteCount": String(receipt.stdout.count),
      "truncated": receipt.stdoutTruncated ? "true" : "false",
    ])
  }

  /// Analysis writes nothing outside its own derived artifact, so there is no
  /// external effect for recovery to confirm and a repeat cannot double
  /// anything.
  public func reconcile(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) async throws -> ProviderReconcileOutcome {
    guard case .analyzer = intent.action else {
      return .stillUnknown(reason: "analyzer reconcile received a foreign action")
    }
    return .confirmedNotExecuted
  }

  public func reconciliationReadback(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan? {
    nil
  }

  public func verifyReconciliationReadback(
    receipt: ProviderProcessReceipt,
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) throws -> ProviderReconcileOutcome {
    .stillUnknown(reason: "analyzer provider publishes no readback plan")
  }

  static func sha256(_ bytes: Data) -> String {
    SHA256Hex.string(of: bytes)
  }
}

/// Resolves the pinned executable for an analysis plan. Identity is checked
/// by the dispatcher against this table, so a drifted binary cannot run under
/// a registered analyzer's name (CHG-2026-055, TASK-HFA-007).
public struct AnalyzerExecutableResolver: RuntimeExecutableResolving {
  private let table: [String: ResolvedExecutable]

  /// One pinned binary per host, with each analyzer selecting its behaviour
  /// through fixed arguments. Registering two analyzers backed by different
  /// binaries is not expressible here on purpose: the dispatcher resolves by
  /// provider, so a second binary would be checked against the first one's
  /// digest and refused. A host that needs that should register one tool with
  /// subcommands, which is what `fixedArguments` is for.
  public init(profiles: [AnalyzerProfile]) {
    self.table = [
      "analyzer": profiles.first.map {
        ResolvedExecutable(path: $0.executablePath, sha256: $0.executableSHA256)
      }
    ].compactMapValues { $0 }
  }

  public func resolveExecutable(providerID: String) throws -> ResolvedExecutable {
    guard let executable = table[providerID] else {
      throw DeviceProviderError.unsupportedAction("analyzer.executableUnavailable")
    }
    return executable
  }
}
