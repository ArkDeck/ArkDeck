import Foundation
@testable import ArkDeckCore

/// Historical typed records for the offline host-store differential. Constructing
/// these values never obtains authority or invokes a Provider.
enum HostStoreStepShadowFixtures {
  static let hash = String(repeating: "a", count: 64)
  static let identifier: JSONValue = .string("fixture-1")
  static func arguments(_ kind: WorkflowStepKind) -> [String: JSONValue] {
    let id = identifier
    let sha = JSONValue.string(hash)
    switch kind {
    case .probeHostTool: return ["toolIdentity": id, "candidatePath": .string("/fixture/tool")]
    case .probeHDCServer: return ["endpoint": .string("fixture-endpoint"), "clientIdentity": id]
    case .mutateHDCServerLifecycle: return ["action": .string("startManaged"), "endpoint": .string("fixture-endpoint"),
      "expectedGeneration": .null, "expectedOwnership": .string("absent"), "impactSnapshotHash": sha, "confirmationId": .null]
    case .probeDevice: return ["evidencePolicy": id]
    case .captureRemoteStdout: return ["catalogId": .string("arkdeck-diagnostics"), "actionId": .string("componentTree"),
      "parameters": .object(["byteBudget": .integer(1024)]), "artifactId": id]
    case .captureRemoteFile: return ["catalogId": .string("trace-presets"), "actionId": .string("custom"),
      "parameters": .object([:]), "artifactId": id, "ownedRemotePath": .string("/fixture/owned")]
    case .stopRemoteCapture: return ["captureStepId": id, "stopPolicy": id]
    case .sendFile: return ["sourceArtifactId": id, "remotePath": .string("/fixture/remote"), "sourceSha256": sha]
    case .receiveFile: return ["remotePath": .string("/fixture/remote"), "artifactId": id, "localRelativePath": .string("payload.bin")]
    case .snapshotParameter: return ["name": .string("persist.shadow")]
    case .setParameter: return ["name": .string("persist.shadow"), "value": .string("value"), "readbackPolicy": .string("required")]
    case .restoreParameter: return ["name": .string("persist.shadow"), "snapshotStepId": id, "restorePolicy": .string("restoreKnownValue")]
    case .waitForDisconnect, .waitForReconnect: return ["deadlineMilliseconds": .integer(1), "reason": id]
    case .verifyRemoteState: return ["probeId": id, "expectedState": .string("ready")]
    case .verifyArtifact, .hashFile: return ["artifactId": id]
    case .preflightHostStorage: return ["volumeIdentity": id, "requiredBytes": .unsignedInteger(UInt64.max),
      "metadataHeadroomBytes": .integer(1), "writerClass": .string("light")]
    case .preflightDeviceStorage: return ["remotePath": .string("/fixture/remote"), "requiredBytes": .integer(0)]
    case .postprocessArtifact: return ["inputArtifactIds": .array([id]), "outputArtifactId": id, "processorId": id, "parameters": .object([:])]
    case .cleanupOwnedRemotePath: return ["remotePath": .string("/fixture/owned"), "ownershipEvidenceId": id]
    case .requestConfirmation: return ["confirmationId": id, "promptKey": id, "riskClass": .string("securityBoundary"), "scopeHash": sha]
    case .installPackage: return ["packageArtifactId": id, "packageName": .string("fixture.package"), "replacePolicy": .string("forbid")]
    case .uninstallPackage: return ["packageName": .string("fixture.package")]
    case .startApplication, .stopApplication: return ["bundleName": .string("fixture.bundle"), "abilityName": .string("FixtureAbility")]
    case .createPortForward: return ["forwardId": id, "hostEndpoint": .string("tcp:1"), "deviceEndpoint": .string("tcp:2")]
    case .removePortForward: return ["forwardId": id]
    case .injectPointerInput: return ["gesture": .string("tap"), "pointerX": .integer(0), "pointerY": .integer(0)]
    case .clearLogBuffer: return ["bufferId": id, "confirmationId": id]
    case .resizeLogBuffer: return ["bufferId": id, "sizeBytes": .integer(1), "restorePolicy": .string("restoreSnapshot")]
    case .startDeviceLogPersist: return ["profileId": id, "artifactSeriesId": id, "rotationBytes": .integer(1), "retainedSegments": .integer(1)]
    case .runApprovedRemoteRead: return ["catalogId": .string("arkdeck-remote-operations"), "actionId": .string("deviceSummary"),
      "parameters": .object([:]), "artifactId": id]
    case .runApprovedRemoteMutation: return ["catalogId": .string("arkdeck-remote-operations"), "actionId": .string("requestRootMode"),
      "parameters": .object([:]), "artifactId": id, "confirmationId": id]
    case .rebootDevice: return ["targetMode": .string("normal"), "reason": id]
    case .enterUpdater: return ["providerOperationId": .string("enterUpdater"), "expectedMode": .string("updater"), "reconnectDeadlineMilliseconds": .integer(1)]
    case .flashPartition: return ["providerOperationId": .string("flash"), "partition": .string("system"), "imageArtifactId": id,
      "imageSha256": sha, "imageSize": .integer(1), "confirmationId": id, "safeBoundaryId": id]
    case .updatePackage: return ["providerOperationId": .string("update"), "packageArtifactId": id, "packageSha256": sha,
      "packageSize": .integer(1), "confirmationId": id, "safeBoundaryId": id]
    case .erasePartition: return ["providerOperationId": .string("erase"), "partition": .string("userdata"), "confirmationId": id, "safeBoundaryId": id]
    case .formatPartition: return ["providerOperationId": .string("format"), "partition": .string("userdata"), "confirmationId": id,
      "safeBoundaryId": id, "formatType": .string("fixture")]
    case .unlockDevice: return ["providerOperationId": .string("unlock"), "confirmationId": id, "scopeHash": sha, "safeBoundaryId": id]
    case .finalizeSession: return ["sessionId": id, "publicationPolicy": .string("atomicAfterValidation")]
    case .inspectWorkspaceSource: return ["projectRef": id, "symbol": .string("Fixture"), "fileScope": .string("Sources/**"), "artifactId": id]
    case .prepareWorkspaceIsolation: return ["sourceProjectRef": id, "expectedWorkspaceRevision": sha, "allowedFileScopesDigest": sha,
      "workspaceRevision": sha, "workspaceProjectRef": id, "artifactId": id]
    case .sweepWorkspaceIsolation: return ["retainLatestCount": .integer(0), "minimumQuiescentSeconds": .integer(0), "dryRun": .string("true"), "artifactId": id]
    case .applyWorkspacePatch: return ["projectRef": id, "patchArtifactId": id, "patchSha256": sha,
      "allowedFileGlobs": .array([.string("Sources/**")]), "patchAttemptRef": id]
    case .buildWorkspaceOpenHarmony: return ["projectRef": id, "buildPresetRef": id]
    case .signWorkspaceOpenHarmonyHap: return ["projectRef": id, "signingPresetRef": .string("openharmony-release@1"), "inputArtifactId": id, "inputSha256": sha]
    case .runWorkspaceTests: return ["projectRef": id, "testPresetRef": id]
    case .symbolizeWorkspaceCrash: return ["projectRef": id, "dumpArtifactId": id, "dumpSha256": sha, "symbolPresetRef": id]
    case .revertWorkspacePatch: return ["projectRef": id, "patchAttemptRef": id]
    case .inspectWorkspaceGitStatus, .createWorkspaceCheckpoint: return ["projectRef": id, "artifactId": id]
    case .inspectWorkspaceDiff: return ["projectRef": id, "baseRevision": .string("HEAD"), "pathScope": .string("Sources"), "artifactId": id]
    case .readWorkspaceSourceRange: return ["projectRef": id, "filePath": .string("Sources/Fixture.swift"),
      "lineStart": .integer(1), "lineEnd": .integer(1), "artifactId": id]
    case .runDeterministicAnalyzer: return ["analyzerRef": .string("trace-analysis@1"), "inputArtifactId": id, "artifactId": id]
    }
  }

  static func step(_ kind: WorkflowStepKind, id: String = "step-shadow") throws -> [String: JSONValue] {
    let metadata = WorkflowStepRegistry.metadata(for: kind)
    let arguments = arguments(kind)
    let step = try WorkflowStep(id: id, kind: kind, declaredEffect: metadata.minimumEffect,
      declaredCancellation: metadata.minimumCancellation, declaredBindingRequirement: metadata.minimumBindingRequirement,
      arguments: arguments)
    guard case .object(var row) = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(step)) else {
      preconditionFailure("WorkflowStep encoded as a non-object")
    }
    row["argumentsHash"] = .string(SHA256Hex.string(of: try CanonicalJSONEncoders.canonical().encode(JSONValue.object(arguments))))
    row["sourceStepId"] = .null
    row["compensationTrigger"] = .null
    row["disposition"] = .string("executed")
    row["outcomeCertainty"] = .string("confirmed")
    row["bindingRevision"] = metadata.minimumBindingRequirement == .none ? .null : .integer(1)
    row["semanticResult"] = .string("succeeded")
    return row
  }

  static func confirmations(_ step: [String: JSONValue]) -> [JSONValue] {
    guard case .object(let arguments) = step["arguments"], case .string(let id) = arguments["confirmationId"] else { return [] }
    return [.object(["confirmationId": .string(id), "kind": .string("securityBoundary"), "scopeHash": .string(hash),
      "decision": .string("accepted"), "actor": .object(["kind": .string("interactiveUser")]),
      "decidedAt": .string("2026-01-01T00:00:00Z"), "relatedStepIds": .array([step["id"]!])])]
  }
}
