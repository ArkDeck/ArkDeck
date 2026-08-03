// Runtime Artifact service boundaries.
//
// This service owns the runtime-only relationship between an executed typed
// step and the Artifact products it may publish.  Catalog declarations stay
// the public contract; these tables are deliberately private implementation
// detail, kept out of RuntimeJobEngine so admission, recovery and job-running
// code do not become the source of truth for Artifact policy.

import ArkDeckCore
import ArkDeckRuntime
import Foundation

enum RuntimeArtifactService {
  /// Declared products whose bytes come from a device file transfer rather
  /// than from a captured stream. They publish from the host file the
  /// dispatcher measured, and a missing file is a recorded absence — there
  /// is no path from "the step ran" to a published trace.
  static let fileBackedArtifacts: Set<String> = ["trace.htrace", "screenshot.png"]

  /// A confirmed process failure still owns useful bounded diagnostics.
  /// Publishing those bytes does not turn the Job into success; it prevents
  /// the failure path from discarding the only actionable build/test output.
  static let failedDiagnosticArtifactOperations: Set<String> = [
    "workspace.build-openharmony@1",
    "workspace.run-tests@1",
  ]

  static let workspaceOperationReferences: Set<String> = [
    "workspace.apply-patch@1",
    "workspace.build-openharmony@1",
    "workspace.create-checkpoint@1",
    "workspace.revert-patch@1",
    "workspace.run-tests@1",
    "workspace.symbolize-crash@1",
  ]

  /// Received text products must go through the redacting publication path.
  static let receivedRedactedArtifacts: Set<String> = ["ui-tree.json"]

  /// Which step produces which declared Artifact. This stays outside the
  /// Catalog schema because it is a runtime publication implementation detail.
  static let artifactMapping: [String: [String: [String]]] = [
    "analyzer.extract-crash-signature@1": [
      "extract-crash-signature": ["crash-signature.json"]
    ],
    "analyzer.summarize-hilog@1": [
      "summarize-hilog": ["hilog-summary.json"]
    ],
    "analyzer.summarize-trace@1": [
      "summarize-trace": ["trace-summary.json"]
    ],
    "workspace.inspect-source@1": [
      "inspect-workspace-source": ["source-inspection.txt"]
    ],
    "workspace.apply-patch@1": [
      "apply-patch": ["applied-patch.json"]
    ],
    "workspace.build-openharmony@1": [
      "build-project": ["build.log"]
    ],
    "workspace.create-checkpoint@1": [
      "create-checkpoint": ["checkpoint.txt"]
    ],
    "workspace.run-tests@1": [
      "run-tests": ["test-output.log"]
    ],
    "workspace.symbolize-crash@1": [
      "symbolize-crash": ["symbolized-crash.txt"]
    ],
    "workspace.revert-patch@1": [
      "revert-patch": ["revert-report.json"]
    ],
    "observe.device@1": [
      "probe-host-tool": ["tool-facts.json"],
      "read-evidence-firmware": ["device-facts.json", "binding-snapshot.json"],
    ],
    "capture.diagnostics@1": [
      "observe-application-liveness": ["application-liveness.json"],
      "capture-hilog": ["hilog.txt"],
      "capture-ui-dump": ["ui-dump.json"],
      "receive-trace-artifact": ["trace.htrace"],
      "receive-ui-tree": ["ui-tree.json"],
      "receive-screenshot": ["screenshot.png"],
      "capture-crash-index": ["crash-index.txt"],
      "capture-crash-log": ["crash-log.txt"],
    ],
    "debug.hap@1": [
      "package-readback": ["install-readback.json"],
      "process-readback": ["process-readback.json"],
      "capture-diagnostics": ["debug-hilog.txt"],
    ],
    "deploy.native-library.app-owned@1": [
      "atomic-publish": ["publish-report.json"],
      "verify-loaded-library": ["verification-report.json"],
    ],
    "flash.dayu200@1": [
      "rebind-and-verify-build": ["post-flash-facts.json"],
      "capture-post-flash-diagnostics": ["post-flash-hilog.txt"],
    ],
  ]

  /// Products synthesized at finalization rather than by one typed step.
  static let finalizeArtifacts: [String: [String]] = [
    "capture.diagnostics@1": ["artifact-index.json", "capture-summary.json"],
    "flash.dayu200@1": ["flash-report.json"],
  ]

  static func finalArtifactContents(
    name: String,
    descriptor: CatalogOperationDescriptor,
    record: RuntimeJobRecord,
    recorded: [RuntimeArtifactMetadata],
    finalizeArtifactNames: [String],
    completedStepIDs: Set<String>
  ) throws -> Data {
    var perArtifact: [String: JSONValue] = [:]
    for declaration in descriptor.artifacts
    where !finalizeArtifactNames.contains(declaration.name) {
      let match = recorded.first { $0.name == declaration.name }
      let state: String
      var detail: String?
      switch match?.status {
      case .some(.published): state = "published"
      case .some(.missing(let reason)):
        state = "missing"
        detail = reason
      case .some(.truncated(let atBytes)):
        state = "truncated"
        detail = "at \(atBytes) bytes"
      case nil:
        state = "missing"
        detail = "never produced"
      }
      var entry: [String: JSONValue] = [
        "status": .string(state),
        "required": .bool(declaration.isRequired),
      ]
      if let detail { entry["detail"] = .string(detail) }
      if let match, match.status.isPublished {
        entry["artifactId"] = .string(match.artifactID)
        entry["byteCount"] = .integer(Int64(match.byteCount))
        entry["sha256"] = .string(match.sha256)
      }
      perArtifact[declaration.name] = .object(entry)
    }
    let missingRequired = descriptor.artifacts.filter { declaration in
      guard declaration.isRequired,
        !finalizeArtifactNames.contains(declaration.name)
      else { return false }
      return recorded.first { $0.name == declaration.name }?.status.isPublished != true
    }
    var payload: [String: JSONValue] = [
      "operation": .string(descriptor.reference),
      "jobId": .string(record.jobID),
      "artifacts": .object(perArtifact),
    ]
    if !name.contains("index") {
      payload["completeness"] = .string(
        missingRequired.isEmpty ? "complete" : "incomplete")
      payload["missingRequired"] = .array(
        missingRequired.map { .string($0.name) })
    }
    if descriptor.reference == "flash.dayu200@1" {
      appendFlashArtifactLineage(to: &payload, record: record)
      payload["verifiedSteps"] = .array(
        completedStepIDs.sorted().map { .string($0) })
      var requestFields: [String: JSONValue] = [:]
      for key in ["deviceProfile", "partitionPlan", "postFlashVerification"] {
        if let value = record.request.inputs[key] {
          requestFields[key] = value
        }
      }
      payload["request"] = .object(requestFields)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    return try encoder.encode(payload)
  }

  static func artifactContents(
    name: String,
    summary: [String: String],
    receipt: ProviderProcessReceipt,
    descriptor: CatalogOperationDescriptor,
    record: RuntimeJobRecord
  ) -> Data {
    switch name {
    case "application-liveness.json":
      var fields: [String: JSONValue] = [
        "documentType": .string("arkdeck-application-liveness"),
        "schemaVersion": .string("1.0.0"),
        "applicationRef": .string(summary["applicationRef"] ?? ""),
        "state": .string(summary["state"] ?? "UNKNOWN"),
        "reasonCode": .string(summary["reasonCode"] ?? "processReadbackUnavailable"),
        "abilityState": .string(summary["abilityState"] ?? "UNKNOWN"),
        "processState": .string(summary["processState"] ?? "UNKNOWN"),
        "pidObserved": .bool(summary["pidObserved"] == "true"),
        "sourceRuntimeJobId": .string(record.jobID),
        "sourceOperationRef": .string(descriptor.reference),
        "observedAtUtc": .string(summary["observedAtUtc"] ?? ""),
      ]
      if let revision = record.request.target.expectedBindingRevision {
        fields["targetBindingRevision"] = .integer(Int64(revision))
      }
      if let digest = summary["deployedArtifactDigest"] {
        fields["deployedArtifactDigest"] = .string(digest)
      }
      fields["observationWindow"] = .object([
        "startedAtUtc": .string(summary["observedAtUtc"] ?? ""),
        "endedAtUtc": .string(summary["observedAtUtc"] ?? ""),
      ])
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
      return (try? encoder.encode(fields)) ?? Data("{}".utf8)
    case "source-inspection.txt", "symbolized-crash.txt":
      // The inspection itself is the Artifact, not a synthetic summary.
      return receipt.stdout
    case "crash-signature.json"
    where descriptor.reference == AnalyzerProvider.crashSignature:
      guard let result = try? JSONDecoder().decode(
        HarnessCrashLedgerAnalysis.self, from: receipt.stdout),
        let analyzerRef = summary["analyzerRef"],
        let analyzerVersion = summary["analyzerVersion"],
        let sourceArtifactID = summary["sourceArtifactId"],
        let sourceSHA256 = summary["sourceSha256"],
        let sourceByteCount = summary["sourceByteCount"].flatMap(Int.init),
        let outputSHA256 = summary["derivedSha256"],
        let outputByteCount = summary["derivedByteCount"].flatMap(Int.init)
      else { return Data("{}".utf8) }
      let envelope = HarnessCrashLedgerDerivedArtifact(
        analyzerRef: analyzerRef, analyzerVersion: analyzerVersion,
        sourceArtifactID: sourceArtifactID, sourceSHA256: sourceSHA256,
        sourceByteCount: sourceByteCount, analyzerOutputSHA256: outputSHA256,
        analyzerOutputByteCount: outputByteCount, result: result)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return (try? encoder.encode(envelope)) ?? Data("{}".utf8)
    case "build.log", "test-output.log":
      var output = receipt.stdout
      output.append(receipt.stderr)
      return output
    case "hilog.txt", "ui-dump.json", "debug-hilog.txt", "post-flash-hilog.txt",
      "crash-index.txt", "crash-log.txt":
      // These products are the bounded bytes received from the provider.
      return receipt.stdout
    default:
      break
    }
    var fields: [String: JSONValue] = [
      "artifact": .string(name),
      "operation": .string(descriptor.reference),
      "jobId": .string(record.jobID),
      "catalogDigest": .string(record.catalogDigest),
    ]
    if let observation = record.evidenceObservation {
      if let model = observation.model { fields["model"] = .string(model) }
      if let firmware = observation.firmware { fields["firmware"] = .string(firmware) }
      if let transport = observation.transport { fields["transport"] = .string(transport) }
      if let identity = observation.stableIdentitySHA256 {
        fields["stableIdentitySha256"] = .string(identity)
      }
    }
    for (key, value) in summary {
      fields[key] = .string(value)
    }
    if name == "binding-snapshot.json" {
      fields["targetId"] = .string(record.request.target.targetID)
      if let revision = record.request.target.expectedBindingRevision {
        fields["expectedBindingRevision"] = .integer(Int64(revision))
      }
    }
    if descriptor.reference == "flash.dayu200@1" {
      appendFlashArtifactLineage(to: &fields, record: record)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    return (try? encoder.encode(fields)) ?? Data("{}".utf8)
  }

  static func bindingSnapshot(for record: RuntimeJobRecord) -> ArtifactBindingSnapshot {
    ArtifactBindingSnapshot(
      targetID: record.request.target.targetID,
      bindingRevision: record.request.target.expectedBindingRevision,
      stableIdentitySHA256: record.evidenceObservation?.stableIdentitySHA256
        ?? record.materializedStableTargetIdentitySHA256)
  }

  private static func appendFlashArtifactLineage(
    to fields: inout [String: JSONValue], record: RuntimeJobRecord
  ) {
    fields["catalogDigest"] = .string(record.catalogDigest)
    fields["providerId"] = .string(record.providerID)
    fields["targetId"] = .string(record.request.target.targetID)
    if let revision = record.request.target.expectedBindingRevision {
      fields["expectedBindingRevision"] = .integer(Int64(revision))
    }
    if let identity = record.evidenceObservation?.stableIdentitySHA256
      ?? record.materializedStableTargetIdentitySHA256
    {
      fields["stableIdentitySha256"] = .string(identity)
    }
    if let digest = record.materializedPlanDigest {
      fields["materializedPlanDigest"] = .string(digest)
    }
    if let evidence = record.admissionEvidence {
      var authority: [String: JSONValue] = [
        "kind": .string(evidence.kind.rawValue),
        "reference": .string(evidence.reference),
      ]
      if let fingerprint = evidence.consumptionFingerprintSHA256 {
        authority["consumptionFingerprintSha256"] = .string(fingerprint)
      }
      fields["authority"] = .object(authority)
    }
  }
}
