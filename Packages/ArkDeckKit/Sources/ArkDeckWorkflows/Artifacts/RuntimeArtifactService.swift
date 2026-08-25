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
  static func traceSummaryDerivation(
    name: String,
    descriptor: CatalogOperationDescriptor,
    summary: [String: String]
  ) -> RuntimeArtifactDerivation? {
    guard name == "trace-summary.json",
      descriptor.reference == AnalyzerProvider.traceSummary,
      let analyzerRef = summary["analyzerRef"],
      let analyzerVersion = summary["analyzerVersion"],
      let sourceArtifactID = summary["sourceArtifactId"],
      let sourceSHA256 = summary["sourceSha256"],
      let sourceByteCount = summary["sourceByteCount"].flatMap(Int.init),
      let toolSHA256 = summary["toolSha256"],
      let parserSHA256 = summary["parserSha256"],
      let parserVersion = summary["parserVersion"],
      let parserUpstreamRevision = summary["parserUpstreamRevision"],
      let parserBuildRecipeVersion = summary["parserBuildRecipeVersion"],
      let parserAdapterVersion = summary["parserAdapterVersion"],
      let schemaAdapterVersion = summary["schemaAdapterVersion"],
      let indexSchemaVersion = summary["indexSchemaVersion"].flatMap(Int.init),
      let timeoutMs = summary["requestTimeoutMs"].flatMap(Int.init),
      let maxRows = summary["requestMaxRows"].flatMap(Int.init),
      let maxEvents = summary["requestMaxEvents"].flatMap(Int.init),
      let maxOutputBytes = summary["requestMaxOutputBytes"].flatMap(Int.init)
    else { return nil }
    return RuntimeArtifactDerivation(
      analyzerRef: analyzerRef, analyzerVersion: analyzerVersion,
      sourceArtifactID: sourceArtifactID, sourceSHA256: sourceSHA256,
      sourceByteCount: sourceByteCount, toolSHA256: toolSHA256,
      parserSHA256: parserSHA256, parserVersion: parserVersion,
      parserUpstreamRevision: parserUpstreamRevision,
      parserBuildRecipeVersion: parserBuildRecipeVersion,
      parserAdapterVersion: parserAdapterVersion,
      schemaAdapterVersion: schemaAdapterVersion, indexSchemaVersion: indexSchemaVersion,
      timeoutMs: timeoutMs, maxRows: maxRows, maxEvents: maxEvents,
      maxOutputBytes: maxOutputBytes)
  }

  static func traceAnalysisDerivation(
    name: String,
    descriptor: CatalogOperationDescriptor,
    summary: [String: String]
  ) -> RuntimeArtifactDerivation? {
    func optionalInt64(_ key: String) -> (present: Bool, value: Int64?) {
      guard let raw = summary[key] else { return (false, nil) }
      if raw == "null" { return (true, nil) }
      guard let value = Int64(raw) else { return (false, nil) }
      return (true, value)
    }
    let timestamp = optionalInt64("requestTimestampNs")
    let start = optionalInt64("requestStartNs")
    let end = optionalInt64("requestEndNs")
    let processKey = optionalInt64("requestProcessKey")
    let pid = optionalInt64("requestPid")
    let threadKey = optionalInt64("requestThreadKey")
    let tid = optionalInt64("requestTid")
    guard name == "trace-analysis.json",
      descriptor.reference == AnalyzerProvider.traceAnalysis,
      let analyzerRef = summary["analyzerRef"],
      let analyzerVersion = summary["analyzerVersion"],
      let sourceArtifactID = summary["sourceArtifactId"],
      let sourceSHA256 = summary["sourceSha256"],
      let sourceByteCount = summary["sourceByteCount"].flatMap(Int.init),
      let toolSHA256 = summary["toolSha256"],
      let parserSHA256 = summary["parserSha256"],
      let parserVersion = summary["parserVersion"],
      let parserUpstreamRevision = summary["parserUpstreamRevision"],
      let parserBuildRecipeVersion = summary["parserBuildRecipeVersion"],
      let parserAdapterVersion = summary["parserAdapterVersion"],
      let schemaAdapterVersion = summary["schemaAdapterVersion"],
      let indexSchemaVersion = summary["indexSchemaVersion"].flatMap(Int.init),
      let timeoutMs = summary["requestTimeoutMs"].flatMap(Int.init),
      let maxRows = summary["requestMaxRows"].flatMap(Int.init),
      let maxEvents = summary["requestMaxEvents"].flatMap(Int.init),
      let maxOutputBytes = summary["requestMaxOutputBytes"].flatMap(Int.init),
      let requestCommand = summary["requestCommand"],
      let requestKind = summary["requestKind"],
      timestamp.present, start.present, end.present, processKey.present,
      pid.present, threadKey.present, tid.present,
      let thresholdNs = summary["requestThresholdNs"].flatMap(Int64.init),
      let limit = summary["requestLimit"].flatMap(Int.init)
    else { return nil }
    return RuntimeArtifactDerivation(
      analyzerRef: analyzerRef, analyzerVersion: analyzerVersion,
      sourceArtifactID: sourceArtifactID, sourceSHA256: sourceSHA256,
      sourceByteCount: sourceByteCount, toolSHA256: toolSHA256,
      parserSHA256: parserSHA256, parserVersion: parserVersion,
      parserUpstreamRevision: parserUpstreamRevision,
      parserBuildRecipeVersion: parserBuildRecipeVersion,
      parserAdapterVersion: parserAdapterVersion,
      schemaAdapterVersion: schemaAdapterVersion, indexSchemaVersion: indexSchemaVersion,
      timeoutMs: timeoutMs, maxRows: maxRows, maxEvents: maxEvents,
      maxOutputBytes: maxOutputBytes,
      requestCommand: requestCommand, requestKind: requestKind,
      requestTimestampNs: timestamp.value, requestStartNs: start.value,
      requestEndNs: end.value, requestProcessKey: processKey.value,
      requestPID: pid.value, requestThreadKey: threadKey.value,
      requestTID: tid.value,
      requestThresholdNs: thresholdNs, requestLimit: limit)
  }

  /// Declared products whose bytes come from a device file transfer rather
  /// than from a captured stream. They publish from the host file the
  /// dispatcher measured, and a missing file is a recorded absence — there
  /// is no path from "the step ran" to a published trace.
  static let fileBackedArtifacts: Set<String> = [
    "trace.htrace", "screenshot.png", "signed.hap", "unsigned.hap",
  ]

  /// A confirmed process failure still owns useful bounded diagnostics.
  /// Publishing those bytes does not turn the Job into success; it prevents
  /// the failure path from discarding the only actionable build/test output.
  static let failedDiagnosticArtifactOperations: Set<String> = [
    "workspace.build-openharmony@1",
    "workspace.run-tests@1",
  ]

  static let workspaceOperationReferences: Set<String> = [
    "workspace.prepare-isolated-copy@1",
    "workspace.sweep-isolated-copies@1",
    "workspace.apply-patch@1",
    "workspace.build-openharmony@1",
    "workspace.create-checkpoint@1",
    "workspace.revert-patch@1",
    "workspace.run-tests@1",
    OpenHarmonyLocalSigning.operationReference,
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
    "analyzer.analyze-trace@1": [
      "analyze-trace": ["trace-analysis.json"]
    ],
    "workspace.inspect-source@1": [
      "inspect-workspace-source": ["source-inspection.txt"]
    ],
    // The three reads below declare a required Artifact in the Catalog but had
    // no entry here, so the bytes they observed were never published and the
    // required product was silently absent. Same omission as the missing
    // journal arms in `RuntimeJobEngine`: a published operation depends on two
    // hand-maintained tables, and neither is checked against the Catalog.
    "workspace.inspect-git-status@1": [
      "inspect-git-status": ["git-status.txt"]
    ],
    "workspace.inspect-diff@1": [
      "inspect-diff": ["diff-summary.txt"]
    ],
    "workspace.read-source-range@1": [
      "read-source-range": ["source-range.txt"]
    ],
    "workspace.prepare-isolated-copy@1": [
      "prepare-isolated-copy": ["isolated-workspace.json"]
    ],
    "workspace.sweep-isolated-copies@1": [
      "sweep-isolated-copies": ["sweep-findings.json"]
    ],
    "workspace.apply-patch@1": [
      "apply-patch": ["applied-patch.json"]
    ],
    "workspace.build-openharmony@1": [
      "build-project": ["build.log", "unsigned.hap"]
    ],
    OpenHarmonyLocalSigning.operationReference: [
      "sign-workspace-hap": ["signed.hap", "signing-report.json"]
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
      "capture-advanced-ui-dump": ["advanced-dump.txt"],
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
    "port-forward.create@1": [
      "verify-port-rule": ["port-rule-readback.json"]
    ],
    "port-forward.remove@1": [
      "verify-port-rule": ["port-rule-readback.json"]
    ],
    "deploy.native-library.app-owned@1": [
      "atomic-publish": ["publish-report.json"],
      "verify-loaded-library": ["verification-report.json"],
    ],
    ArkForgeFlashOperation.canonicalReference: [
      "rebind-and-verify-build": ["post-flash-facts.json"],
      "capture-post-flash-diagnostics": ["post-flash-hilog.txt"],
    ],
  ]

  /// Products synthesized at finalization rather than by one typed step.
  static let finalizeArtifacts: [String: [String]] = [
    "capture.diagnostics@1": ["capture.log", "artifact-index.json", "capture-summary.json"],
    ArkForgeFlashOperation.canonicalReference: ["flash-report.json"],
  ]

  static func artifacts(reference: String, stepID: String) -> [String]? {
    let key = ArkForgeFlashOperation.canonicalReference(for: reference) ?? reference
    return artifactMapping[key]?[stepID]
  }

  static func finalArtifacts(reference: String) -> [String]? {
    let key = ArkForgeFlashOperation.canonicalReference(for: reference) ?? reference
    return finalizeArtifacts[key]
  }

  /// A Runtime without an Artifact store cannot admit an operation whose
  /// contract consumes or produces durable Artifact bytes. Keep this derived
  /// from the same publication tables used at execution so a new mapped
  /// product cannot accidentally inherit an optional-store admission path.
  static func requiresArtifactStore(reference: String) -> Bool {
    workspaceOperationReferences.contains(reference)
      || artifactsByOperation(reference: reference) != nil
      || finalArtifacts(reference: reference) != nil
  }

  private static func artifactsByOperation(
    reference: String
  ) -> [String: [String]]? {
    let key = ArkForgeFlashOperation.canonicalReference(for: reference) ?? reference
    return artifactMapping[key]
  }

  static func finalArtifactContents(
    name: String,
    descriptor: CatalogOperationDescriptor,
    record: RuntimeJobRecord,
    recorded: [RuntimeArtifactMetadata],
    finalizeArtifactNames: [String],
    completedStepIDs: Set<String>
  ) throws -> Data {
    if descriptor.reference == "capture.diagnostics@1", name == "capture.log" {
      return Data((record.timeline.joined(separator: "\n") + "\n").utf8)
    }
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
    if ArkForgeFlashOperation.contains(descriptor.reference) {
      appendFlashArtifactLineage(to: &payload, record: record)
      payload["verifiedSteps"] = .array(
        completedStepIDs.sorted().map { .string($0) })
      var requestFields: [String: JSONValue] = [:]
      requestFields = (try? ArkForgeFlashRequest.canonicalInputs(
        submittedReference: descriptor.reference,
        inputs: record.request.inputs)) ?? [:]
      payload["request"] = .object(requestFields)
    }
    if descriptor.reference == "capture.diagnostics@1",
      case .array(let requestedTags)? = record.request.inputs["traceCategories"],
      !requestedTags.isEmpty
    {
      let beforeByName = Dictionary(
        uniqueKeysWithValues: (record.traceProbeBefore?.parameters ?? []).map { ($0.name, $0) })
      let afterByName = Dictionary(
        uniqueKeysWithValues: (record.traceProbeAfter?.parameters ?? []).map { ($0.name, $0) })
      let parameterRecords: [JSONValue] = TraceDebugParameterCatalog.definitions.map { definition in
        .object([
          "name": .string(definition.name),
          "desired": .string(definition.profileValue),
          "before": traceParameterJSON(beforeByName[definition.name]),
          "after": traceParameterJSON(afterByName[definition.name]),
          "restored": .null,
        ])
      }
      var trace: [String: JSONValue] = [
        "toolIdentity": record.traceProbeBefore?.tool.map(JSONValue.string) ?? .null,
        "adapterFamily": record.traceProbeBefore?.family.map(JSONValue.string) ?? .null,
        "tags": .array(requestedTags),
        "parameters": .array(parameterRecords),
      ]
      if case .integer(let duration)? = record.request.inputs["durationSeconds"] {
        trace["durationSeconds"] = .integer(duration)
      }
      if case .integer(let buffer)? = record.request.inputs["traceBufferKB"] {
        trace["bufferKB"] = .integer(buffer)
      }
      if let raw = recorded.first(where: { $0.name == "trace.htrace" && $0.status.isPublished }) {
        trace["rawArtifactId"] = .string(raw.artifactID)
        trace["rawSha256"] = .string(raw.sha256)
        trace["rawByteCount"] = .integer(Int64(raw.byteCount))
      }
      payload["trace"] = .object(trace)
    }
    let encoder = CanonicalJSONEncoders.canonicalPretty()
    return try encoder.encode(payload)
  }

  private static func traceParameterJSON(
    _ observation: TraceRuntimeParameterObservation?
  ) -> JSONValue {
    guard let observation else { return .object(["state": .string("unobserved")]) }
    var fields: [String: JSONValue] = ["state": .string(observation.state.rawValue)]
    if let value = observation.value { fields["value"] = .string(value) }
    if let detail = observation.detail { fields["detail"] = .string(detail) }
    return .object(fields)
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
      let encoder = CanonicalJSONEncoders.canonicalPretty()
      return (try? encoder.encode(fields)) ?? Data("{}".utf8)
    case "source-inspection.txt", "symbolized-crash.txt",
      "git-status.txt", "diff-summary.txt", "source-range.txt":
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
      let encoder = CanonicalJSONEncoders.canonical()
      return (try? encoder.encode(envelope)) ?? Data("{}".utf8)
    case "trace-summary.json"
    where descriptor.reference == AnalyzerProvider.traceSummary:
      // ArkTrace's validated machine envelope is already deterministic and
      // carries its own complete request/tool/parser/source provenance.
      // Publishing a wrapper would change those reviewed bytes.
      return receipt.stdout
    case "sweep-findings.json":
      // The dispatcher's canonical findings document is the Artifact; its
      // digest is pinned in the verified summary (`findingsSha256`).
      return receipt.stdout
    case "trace-analysis.json"
    where descriptor.reference == AnalyzerProvider.traceAnalysis:
      // Context and deterministic analysis share the same closed ArkTrace
      // machine-envelope boundary. Preserve the validator-approved bytes.
      return receipt.stdout
    case "build.log", "test-output.log":
      var output = receipt.stdout
      output.append(receipt.stderr)
      return output
    case "hilog.txt", "ui-dump.json", "advanced-dump.txt", "debug-hilog.txt", "post-flash-hilog.txt",
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
    if ArkForgeFlashOperation.contains(descriptor.reference) {
      appendFlashArtifactLineage(to: &fields, record: record)
    }
    let encoder = CanonicalJSONEncoders.canonicalPretty()
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
