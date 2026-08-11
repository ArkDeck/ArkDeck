// Unified Device Provider contract (CHG-2026-047, T05).
//
// One execution boundary for HDC and Rockchip: providers own executable
// discovery, argv lowering, remote paths and semantic parsing; the runtime
// understands only effects, intents, receipts, artifacts and reconcile.
// Actions are a closed typed vocabulary - there is no command-string,
// argv or executable parameter anywhere on this surface, and process plans
// can only be constructed inside this package (providers), never by
// clients. Verification is semantic: there is deliberately no constructor
// from "exit 0" to a verified outcome.

import ArkDeckCore
import ArkDeckStorage
import CryptoKit
import Foundation

// MARK: - Typed actions (closed)

/// The closed HDC action vocabulary. MU-2 delivered the observation
/// family; MU-3 (T10) completes the E0 pack. Every payload is a validated
/// typed request - extension is a catalog + provider decision, never a
/// caller-supplied string. Reboot deliberately stays outside E0.
public enum HDCProviderAction: Sendable, Equatable {
  case observeTool
  case observeServer
  case listDeviceCandidates
  case observeDevice(connectKey: String)
  case queryProperty(HDCAllowlistedProperty)
  case observeStorage(HDCStoragePreflightRequest)
  case captureHilog(HDCHilogCaptureRequest)
  case captureUIDump(HDCUIDumpRequest)
  /// The device's own crash ledger. Both members are reads — measured, not
  /// assumed — so this is the one collection family that stays readOnly
  /// (CHG-2026-049 r6).
  case captureCrashIndex(byteBudget: Int)
  case captureCrashLog(HDCFaultLogName, byteBudget: Int)
  case captureTrace(HDCTraceCaptureRequest, into: HDCOwnedRemotePath)
  /// The component tree, which `uitest` writes to a device file rather
  /// than to stdout. That product shape — not a missing windowId — is why
  /// it cannot ride the stdout UI dump action (CHG-2026-053 r2).
  case captureComponentTree(into: HDCOwnedRemotePath)
  /// A PNG of the display. `snapshot_display` defaults to jpeg and checks
  /// the file suffix against the requested type, so the lowering carries
  /// both `-t png` and a `.png` owned path (CHG-2026-049 r5).
  case captureScreenshot(into: HDCOwnedRemotePath)
  case receiveOwnedArtifact(HDCOwnedRemoteArtifact)
  case cleanupOwnedRemotePath(HDCOwnedRemotePath)
  // E1 mutation family (T13). Success for the mutating members is decided
  // by their paired readback, never by the mutation's own exit code.
  case sendArtifactToStaging(HDCStagedArtifact)
  case installPackage(HDCStagedArtifact, bundle: HDCBundleReference)
  // Multi-package install (CHG-2026-049 r4). Separate cases rather than an
  // optional field on the single ones: a set has a directory to create and
  // to remove, and conflating the two shapes is how a single-package plan
  // would start drifting.
  case sendPackageSetToStaging(HDCStagedPackageSet)
  case installPackageSet(HDCStagedPackageSet, bundle: HDCBundleReference)
  case cleanupStagedPackageSet(HDCStagedPackageSet)
  case queryPackageReadback(HDCBundleReference)
  case startAbility(HDCAbilityReference)
  case verifyProcessState(HDCBundleReference)
  case observeApplicationLiveness(HDCApplicationLivenessRequest)
  case stopAbility(HDCAbilityReference)
  case uninstallPackage(HDCBundleReference)
  case createPortForward(HDCPortForwardSpec)
  case removePortForward(HDCPortForwardSpec)
  // App-owned native-library deployment. The deployment value carries a
  // provider-derived namespace and host-verified ELF facts, never a caller
  // path. Every mutation has a dedicated typed inspection used both in the
  // forward path and durable reconciliation.
  case sendNativeLibraryToStaging(HDCAppOwnedNativeLibraryDeployment)
  case backupNativeLibrary(HDCAppOwnedNativeLibraryDeployment)
  case publishNativeLibrary(HDCAppOwnedNativeLibraryDeployment)
  case stopNativeTarget(HDCAppOwnedNativeLibraryDeployment)
  case startNativeTarget(HDCAppOwnedNativeLibraryDeployment)
  case cleanupNativeLibrary(HDCAppOwnedNativeLibraryDeployment)
  case rollbackNativeLibrary(HDCAppOwnedNativeLibraryDeployment)
  case inspectNativeLibrary(
    HDCAppOwnedNativeLibraryDeployment, expectation: HDCNativeLibraryInspection)
  // Recovery-only, read-only judgements. These are never substitutes for
  // the original mutation and therefore cannot resend it.
  case readPackagePresence(HDCBundleReference)
  case readProcessPresence(HDCBundleReference)
  case readOwnedPathPresence(HDCOwnedRemotePath)
  case readOwnedDirectoryPresence(HDCOwnedRemoteDirectory)
  case readPortForwardPresence(HDCPortForwardSpec)
}

/// Engine-resolved flash input. The URL is not supplied by a Runtime
/// request: it is the descriptor-backed file owned by the Artifact store
/// after the lease, target identity and binding revision have all matched.
public struct RockchipRuntimeFlashBundle: Sendable, Equatable {
  public let artifactLeaseID: String
  public let artifactID: String
  public let fileURL: URL
  public let sha256: String
  public let byteCount: Int
  public let partitionNames: [String]

  public init(
    artifactLeaseID: String,
    artifactID: String,
    fileURL: URL,
    sha256: String,
    byteCount: Int,
    partitionNames: [String]
  ) {
    self.artifactLeaseID = artifactLeaseID
    self.artifactID = artifactID
    self.fileURL = fileURL
    self.sha256 = sha256
    self.byteCount = byteCount
    self.partitionNames = partitionNames
  }
}

/// Closed actions for the published DAYU200 runtime plan. Authorization is
/// deliberately absent: the Runtime consumes its exact capability immediately
/// before the first mutation and the Provider cannot request a second,
/// legacy authorization token.
public struct RockchipHDCReconnectExpectation: Sendable, Equatable, Codable {
  public let previousConnectKey: String
  public let previousIdentitySHA256: String
  public let usbTopology: String

  public init(
    previousConnectKey: String,
    previousIdentitySHA256: String,
    usbTopology: String
  ) {
    self.previousConnectKey = previousConnectKey
    self.previousIdentitySHA256 = previousIdentitySHA256
    self.usbTopology = usbTopology
  }
}

public enum RockchipProviderAction: Sendable, Equatable {
  case enterLoader(connectKey: String)
  case observeHDCNormalUSB(connectKey: String)
  case waitForHDCDisconnect(connectKey: String)
  case waitForLoader(stableIdentitySHA256: String)
  case rebindLoader(stableIdentitySHA256: String)
  case flashPartitions(RockchipRuntimeFlashBundle)
  case verifyFlashReadback(RockchipRuntimeFlashBundle)
  case rebootToNormal(stableIdentitySHA256: String)
  case waitForHDCReconnect(connectKey: String)
  case waitForBoundHDCReconnect(expectation: RockchipHDCReconnectExpectation)
  case verifyBuild(
    connectKey: String,
    expectedProductModel: String? = nil,
    expectedBuildVersion: String? = nil)
  case verifyBoundBuild(
    expectation: RockchipHDCReconnectExpectation,
    expectedProductModel: String,
    expectedBuildVersion: String)
  case capturePostFlashDiagnostics(connectKey: String, request: HDCHilogCaptureRequest)
}

/// One host-only action family (CHG-2026-054 TASK-HTP-007). It carries a
/// resolved project root, never a caller-supplied path, and a glob that the
/// provider validated before it became part of an action.
public struct WorkspaceSourceInspection: Sendable, Equatable, Codable {
  public let projectRef: String
  public let projectRoot: String
  public let symbol: String
  public let fileScope: String

  public init(projectRef: String, projectRoot: String, symbol: String, fileScope: String) {
    self.projectRef = projectRef
    self.projectRoot = projectRoot
    self.symbol = symbol
    self.fileScope = fileScope
  }
}

extension WorkspaceProviderAction {
  /// Whether this action changes the workspace (CHG-2026-055, TASK-HFA-009 r2).
  ///
  /// A true value raises the action to `deviceMutation`, which since the
  /// architecture's §17.3 is read as the **E1 mutation risk class** rather
  /// than as a statement about devices — the name is historical and renaming
  /// the wire vocabulary would break journals for no safety gain. What it
  /// buys here is real: these five now require a capability, and the
  /// read-only workspace family still does not.
  public var mutatesWorkspace: Bool {
    switch self {
    case .applyPatch, .buildOpenHarmony, .runTests, .revertPatch,
      .createCheckpoint, .createArchiveCheckpoint:
      return true
    case .inspectSource, .signOpenHarmonyHap, .symbolizeCrash, .inspectGitStatus,
      .inspectDiff, .readSourceRange:
      return false
    }
  }
}

/// What a workspace-scoped capability is matched against (CHG-2026-055,
/// TASK-HFA-009 r2). The provider owns all three: the engine cannot compute
/// them and must not guess.
public struct WorkspaceAuthorizationFacts: Sendable, Equatable {
  public let identitySHA256: String
  public let revision: String
  public let fileScopesDigest: String
  /// True when this workspace is a task-owned isolated copy rather than a
  /// tree a person works in. It is the difference between "the agent edits
  /// its own scratch copy, and anything reaching the repository still goes
  /// through a pull request" and "the agent edits your checkout", which is
  /// why authorization treats the two differently.
  public let isolatedTaskCopy: Bool

  public init(
    identitySHA256: String, revision: String, fileScopesDigest: String,
    isolatedTaskCopy: Bool = false
  ) {
    self.identitySHA256 = identitySHA256
    self.revision = revision
    self.fileScopesDigest = fileScopesDigest
    self.isolatedTaskCopy = isolatedTaskCopy
  }
}

package enum WorkspaceProviderAction: Sendable, Equatable, Codable {
  case inspectSource(WorkspaceSourceInspection)
  case applyPatch(WorkspacePatchIntent)
  case buildOpenHarmony(WorkspaceResolvedInvocation)
  case signOpenHarmonyHap(WorkspaceOpenHarmonySigningAction)
  case runTests(WorkspaceResolvedInvocation)
  case symbolizeCrash(WorkspaceResolvedInvocation)
  case revertPatch(WorkspaceRevertIntent)
  /// Read-only source-control observations (CHG-2026-055, TASK-HFA-008).
  case inspectGitStatus(WorkspaceResolvedInvocation)
  case inspectDiff(WorkspaceResolvedInvocation)
  case readSourceRange(WorkspaceResolvedInvocation)
  /// The original Git-object payload stays stable for journal compatibility.
  case createCheckpoint(WorkspaceResolvedInvocation)
  case createArchiveCheckpoint(WorkspaceArchiveCheckpointIntent)
}

extension DeviceProvider {
  /// Default: this provider has no workspace to authorize. Admission then
  /// refuses rather than matching a capability against absent facts.
  public func workspaceAuthorizationFacts(
    for operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) throws -> WorkspaceAuthorizationFacts? { nil }
}

package enum TypedProviderAction: Sendable, Equatable {
  case hdc(HDCProviderAction)
  case rockchip(RockchipProviderAction)
  /// Host-only: reads declared source on this machine. It can never carry a
  /// device effect, which is what lets the host-only admission path exist.
  case workspace(WorkspaceProviderAction)
  /// Host-only: deterministic analysis of an artifact that already exists
  /// (CHG-2026-055, TASK-HFA-007).
  case analyzer(AnalyzerProviderAction)

  public var effect: WorkflowEffect {
    switch self {
    case .workspace(let workspace):
      return workspace.mutatesWorkspace ? .deviceMutation : .hostOnly
    case .analyzer:
      return .hostOnly
    case .hdc(.observeTool), .hdc(.observeServer):
      return .hostOnly
    case .hdc(.listDeviceCandidates), .hdc(.observeDevice), .hdc(.queryProperty),
      .hdc(.observeStorage),
      .hdc(.captureHilog), .hdc(.captureUIDump), .hdc(.receiveOwnedArtifact),
      .hdc(.captureCrashIndex), .hdc(.captureCrashLog):
      return .readOnly
    case .hdc(.queryPackageReadback), .hdc(.verifyProcessState),
      .hdc(.observeApplicationLiveness):
      return .readOnly
    case .hdc(.readPackagePresence), .hdc(.readProcessPresence),
      .hdc(.readOwnedPathPresence), .hdc(.readOwnedDirectoryPresence),
      .hdc(.readPortForwardPresence),
      .hdc(.inspectNativeLibrary):
      return .readOnly
    case .hdc(.captureTrace), .hdc(.captureComponentTree), .hdc(.captureScreenshot),
      .hdc(.cleanupOwnedRemotePath),
      .hdc(.sendArtifactToStaging), .hdc(.installPackage), .hdc(.startAbility),
      .hdc(.sendPackageSetToStaging), .hdc(.installPackageSet),
      .hdc(.cleanupStagedPackageSet),
      .hdc(.stopAbility), .hdc(.uninstallPackage), .hdc(.createPortForward),
      .hdc(.removePortForward), .hdc(.sendNativeLibraryToStaging),
      .hdc(.backupNativeLibrary), .hdc(.publishNativeLibrary),
      .hdc(.stopNativeTarget), .hdc(.startNativeTarget),
      .hdc(.cleanupNativeLibrary), .hdc(.rollbackNativeLibrary):
      // Writing/removing the provider-owned remote temp file is a bounded
      // deviceMutation per the step registry; the operation-level effect
      // envelope (capture.diagnostics permitted set) already models it.
      return .deviceMutation
    case .rockchip(.enterLoader), .rockchip(.rebootToNormal):
      return .deviceMutation
    case .rockchip(.observeHDCNormalUSB), .rockchip(.waitForHDCDisconnect),
      .rockchip(.waitForLoader),
      .rockchip(.rebindLoader), .rockchip(.verifyFlashReadback),
      .rockchip(.waitForHDCReconnect), .rockchip(.waitForBoundHDCReconnect),
      .rockchip(.verifyBuild), .rockchip(.verifyBoundBuild),
      .rockchip(.capturePostFlashDiagnostics):
      return .readOnly
    case .rockchip(.flashPartitions):
      return .destructive
    }
  }
}

/// Durable, closed representation of the exact typed action placed behind
/// a write-ahead intent. Recovery decodes this record; it never asks the
/// current catalog/provider mapping to invent the old intent again.
struct PersistedTypedProviderAction: Sendable, Equatable, Codable {
  let kind: String
  let arguments: [String: JSONValue]

  init(_ action: TypedProviderAction) throws {
    func pathArguments(_ path: HDCOwnedRemotePath) -> [String: JSONValue] {
      [
        "jobId": .string(path.jobID),
        "stepId": .string(path.stepID),
        "nonce": .string(path.nonce),
        "remotePath": .string(path.remotePath),
      ]
    }
    func optional(_ value: String?, into arguments: inout [String: JSONValue], key: String) {
      if let value { arguments[key] = .string(value) }
    }
    func packageSetArguments(_ set: HDCStagedPackageSet) -> [String: JSONValue] {
      [
        "jobId": .string(set.directory.jobID),
        "stepId": .string(set.directory.stepID),
        "nonce": .string(set.directory.nonce),
        "directoryPath": .string(set.directory.remotePath),
        "packages": .array(
          set.packages.map { package in
            .object([
              "remotePath": .string(package.remotePath),
              "artifactLeaseId": .string(package.artifactLeaseID),
              "sha256": package.expectedSHA256.map(JSONValue.string) ?? .null,
            ])
          }),
      ]
    }
    func nativeArguments(
      _ deployment: HDCAppOwnedNativeLibraryDeployment
    ) -> [String: JSONValue] {
      var arguments: [String: JSONValue] = [
        "jobId": .string(deployment.jobID),
        "artifactLeaseId": .string(deployment.artifactLeaseID),
        "artifactId": .string(deployment.artifactID),
        "bundleName": .string(deployment.bundle.bundleName),
        "libraryLogicalName": .string(deployment.libraryLogicalName),
        "abi": .string(deployment.artifactFacts.abi.rawValue),
        "elfClassBits": .integer(Int64(deployment.artifactFacts.elfClassBits)),
        "machine": .integer(Int64(deployment.artifactFacts.machine)),
        "buildId": .string(deployment.artifactFacts.buildID),
        "sha256": .string(deployment.artifactFacts.sha256),
        "byteCount": .integer(Int64(deployment.artifactFacts.byteCount)),
        "restartProfile": .string(deployment.restartProfile.rawValue),
        "verificationProfile": .string(deployment.verificationProfile.rawValue),
        "rollbackPolicy": .string(deployment.rollbackPolicy.rawValue),
        "directoryPath": .string(deployment.directoryPath),
        "targetPath": .string(deployment.targetPath),
        "loaderVisiblePath": .string(deployment.loaderVisiblePath),
        "stagingPath": .string(deployment.stagingPath),
        "backupPath": .string(deployment.backupPath),
        "rollbackStagingPath": .string(deployment.rollbackStagingPath),
      ]
      if deployment.stagingDirectoryIsJobOwned {
        arguments["stagingDirectoryPath"] = .string(deployment.stagingDirectoryPath)
      }
      if let codeSign = deployment.artifactFacts.codeSign {
        arguments["codeSignFormatVersion"] = .integer(Int64(codeSign.formatVersion))
        arguments["codeSignVersion"] = .integer(Int64(codeSign.codeSignVersion))
        arguments["signedDataByteCount"] = .integer(Int64(codeSign.signedDataByteCount))
        arguments["signatureByteCount"] = .integer(Int64(codeSign.signatureByteCount))
      }
      if let helper = deployment.codeSignHelperFacts,
        let helperRemotePath = deployment.codeSignHelperRemotePath
      {
        arguments["codeSignHelperABI"] = .string(helper.abi.rawValue)
        arguments["codeSignHelperBuildId"] = .string(helper.buildID)
        arguments["codeSignHelperSha256"] = .string(helper.sha256)
        arguments["codeSignHelperByteCount"] = .integer(Int64(helper.byteCount))
        arguments["codeSignHelperRemotePath"] = .string(helperRemotePath)
      }
      return arguments
    }
    switch action {
    case .workspace(.inspectSource(let inspection)):
      // The journal records what was inspected, not where: the resolved root is
      // host-private, so only the declared project reference travels.
      self.init(
        kind: "workspace.inspectSource",
        arguments: [
          "projectRef": .string(inspection.projectRef),
          "symbol": .string(inspection.symbol),
          "fileScope": .string(inspection.fileScope),
        ])
    case .workspace(let workspace):
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      self.init(
        kind: "workspace.action",
        arguments: [
          "payload": .string(
            try encoder.encode(workspace).base64EncodedString())
        ])
    case .hdc(.observeTool):
      self.init(kind: "hdc.observeTool", arguments: [:])
    case .hdc(.observeServer):
      self.init(kind: "hdc.observeServer", arguments: [:])
    case .hdc(.listDeviceCandidates):
      self.init(kind: "hdc.listDeviceCandidates", arguments: [:])
    case .hdc(.observeDevice(let connectKey)):
      self.init(
        kind: "hdc.observeDevice", arguments: ["connectKey": .string(connectKey)])
    case .hdc(.queryProperty(let property)):
      self.init(
        kind: "hdc.queryProperty", arguments: ["property": .string(property.rawValue)])
    case .hdc(.observeStorage(let request)):
      self.init(
        kind: "hdc.observeStorage",
        arguments: ["requiredBytes": .integer(Int64(request.requiredBytes))])
    case .hdc(.captureHilog(let request)):
      self.init(
        kind: "hdc.captureHilog",
        arguments: [
          "durationSeconds": .integer(Int64(request.durationSeconds)),
          "filters": .array(request.filters.map(JSONValue.string)),
          "byteBudget": .integer(Int64(request.byteBudget)),
        ])
    case .hdc(.captureUIDump(let request)):
      self.init(
        kind: "hdc.captureUIDump",
        arguments: [
          "scope": .string(request.scope.rawValue),
          "byteBudget": .integer(Int64(request.byteBudget)),
        ])
    case .hdc(.captureCrashIndex(let byteBudget)):
      self.init(
        kind: "hdc.captureCrashIndex",
        arguments: ["byteBudget": .integer(Int64(byteBudget))])
    case .hdc(.captureCrashLog(let name, let byteBudget)):
      self.init(
        kind: "hdc.captureCrashLog",
        arguments: [
          "faultLogName": .string(name.value),
          "byteBudget": .integer(Int64(byteBudget)),
        ])
    case .hdc(.captureTrace(let request, let path)):
      var arguments = pathArguments(path)
      arguments["durationSeconds"] = .integer(Int64(request.durationSeconds))
      arguments["categories"] = .array(request.categories.map(JSONValue.string))
      arguments["bufferKB"] = .integer(Int64(request.bufferKB))
      self.init(kind: "hdc.captureTrace", arguments: arguments)
    case .hdc(.captureComponentTree(let path)):
      self.init(kind: "hdc.captureComponentTree", arguments: pathArguments(path))
    case .hdc(.captureScreenshot(let path)):
      self.init(kind: "hdc.captureScreenshot", arguments: pathArguments(path))
    case .hdc(.receiveOwnedArtifact(let artifact)):
      var arguments = pathArguments(artifact.path)
      arguments["maximumBytes"] = .integer(Int64(artifact.maximumBytes))
      optional(artifact.expectedSHA256, into: &arguments, key: "expectedSha256")
      if let magic = artifact.expectedLeadingBytes {
        arguments["expectedLeadingBytes"] = .string(
          magic.map { String(format: "%02x", $0) }.joined())
      }
      self.init(kind: "hdc.receiveOwnedArtifact", arguments: arguments)
    case .hdc(.cleanupOwnedRemotePath(let path)):
      self.init(kind: "hdc.cleanupOwnedRemotePath", arguments: pathArguments(path))
    case .hdc(.sendArtifactToStaging(let artifact)):
      var arguments = pathArguments(artifact.path)
      arguments["artifactLeaseId"] = .string(artifact.artifactLeaseID)
      optional(artifact.expectedSHA256, into: &arguments, key: "expectedSha256")
      self.init(kind: "hdc.sendArtifactToStaging", arguments: arguments)
    case .hdc(.sendPackageSetToStaging(let set)):
      self.init(kind: "hdc.sendPackageSetToStaging", arguments: packageSetArguments(set))
    case .hdc(.installPackageSet(let set, let bundle)):
      var arguments = packageSetArguments(set)
      arguments["bundleName"] = .string(bundle.bundleName)
      self.init(kind: "hdc.installPackageSet", arguments: arguments)
    case .hdc(.cleanupStagedPackageSet(let set)):
      self.init(kind: "hdc.cleanupStagedPackageSet", arguments: packageSetArguments(set))
    case .hdc(.readOwnedDirectoryPresence(let directory)):
      self.init(
        kind: "hdc.readOwnedDirectoryPresence",
        arguments: [
          "jobId": .string(directory.jobID),
          "stepId": .string(directory.stepID),
          "nonce": .string(directory.nonce),
          "directoryPath": .string(directory.remotePath),
        ])
    case .hdc(.installPackage(let artifact, let bundle)):
      var arguments = pathArguments(artifact.path)
      arguments["artifactLeaseId"] = .string(artifact.artifactLeaseID)
      arguments["bundleName"] = .string(bundle.bundleName)
      optional(artifact.expectedSHA256, into: &arguments, key: "expectedSha256")
      self.init(kind: "hdc.installPackage", arguments: arguments)
    case .hdc(.queryPackageReadback(let bundle)):
      self.init(
        kind: "hdc.queryPackageReadback",
        arguments: ["bundleName": .string(bundle.bundleName)])
    case .hdc(.startAbility(let ability)):
      self.init(
        kind: "hdc.startAbility",
        arguments: [
          "bundleName": .string(ability.bundle.bundleName),
          "abilityName": .string(ability.abilityName),
        ])
    case .hdc(.verifyProcessState(let bundle)):
      self.init(
        kind: "hdc.verifyProcessState",
        arguments: ["bundleName": .string(bundle.bundleName)])
    case .hdc(.observeApplicationLiveness(let request)):
      var arguments: [String: JSONValue] = [
        "bundleName": .string(request.bundle.bundleName),
        "processName": .string(request.processName),
      ]
      optional(request.abilityName, into: &arguments, key: "abilityName")
      optional(
        request.expectedDeployedArtifactDigest, into: &arguments,
        key: "expectedDeployedArtifactDigest")
      self.init(kind: "hdc.observeApplicationLiveness", arguments: arguments)
    case .hdc(.stopAbility(let ability)):
      self.init(
        kind: "hdc.stopAbility",
        arguments: [
          "bundleName": .string(ability.bundle.bundleName),
          "abilityName": .string(ability.abilityName),
        ])
    case .hdc(.uninstallPackage(let bundle)):
      self.init(
        kind: "hdc.uninstallPackage",
        arguments: ["bundleName": .string(bundle.bundleName)])
    case .hdc(.createPortForward(let spec)):
      self.init(
        kind: "hdc.createPortForward",
        arguments: [
          "direction": .string(spec.direction.rawValue),
          "localPort": .integer(Int64(spec.localPort)),
          "remotePort": .integer(Int64(spec.remotePort)),
        ])
    case .hdc(.removePortForward(let spec)):
      self.init(
        kind: "hdc.removePortForward",
        arguments: [
          "direction": .string(spec.direction.rawValue),
          "localPort": .integer(Int64(spec.localPort)),
          "remotePort": .integer(Int64(spec.remotePort)),
        ])
    case .hdc(.readPackagePresence(let bundle)):
      self.init(
        kind: "hdc.readPackagePresence",
        arguments: ["bundleName": .string(bundle.bundleName)])
    case .hdc(.readProcessPresence(let bundle)):
      self.init(
        kind: "hdc.readProcessPresence",
        arguments: ["bundleName": .string(bundle.bundleName)])
    case .hdc(.readOwnedPathPresence(let path)):
      self.init(kind: "hdc.readOwnedPathPresence", arguments: pathArguments(path))
    case .hdc(.readPortForwardPresence(let spec)):
      self.init(
        kind: "hdc.readPortForwardPresence",
        arguments: [
          "direction": .string(spec.direction.rawValue),
          "localPort": .integer(Int64(spec.localPort)),
          "remotePort": .integer(Int64(spec.remotePort)),
        ])
    case .hdc(.sendNativeLibraryToStaging(let deployment)):
      self.init(kind: "hdc.sendNativeLibraryToStaging", arguments: nativeArguments(deployment))
    case .hdc(.backupNativeLibrary(let deployment)):
      self.init(kind: "hdc.backupNativeLibrary", arguments: nativeArguments(deployment))
    case .hdc(.publishNativeLibrary(let deployment)):
      self.init(kind: "hdc.publishNativeLibrary", arguments: nativeArguments(deployment))
    case .hdc(.stopNativeTarget(let deployment)):
      self.init(kind: "hdc.stopNativeTarget", arguments: nativeArguments(deployment))
    case .hdc(.startNativeTarget(let deployment)):
      self.init(kind: "hdc.startNativeTarget", arguments: nativeArguments(deployment))
    case .hdc(.cleanupNativeLibrary(let deployment)):
      self.init(kind: "hdc.cleanupNativeLibrary", arguments: nativeArguments(deployment))
    case .hdc(.rollbackNativeLibrary(let deployment)):
      self.init(kind: "hdc.rollbackNativeLibrary", arguments: nativeArguments(deployment))
    case .hdc(.inspectNativeLibrary(let deployment, let expectation)):
      var arguments = nativeArguments(deployment)
      arguments["expectation"] = .string(expectation.rawValue)
      self.init(kind: "hdc.inspectNativeLibrary", arguments: arguments)
    case .rockchip(.enterLoader(let connectKey)):
      self.init(
        kind: "rockchip.enterLoader",
        arguments: ["connectKey": .string(connectKey)])
    case .rockchip(.observeHDCNormalUSB(let connectKey)):
      self.init(
        kind: "rockchip.observeHDCNormalUSB",
        arguments: ["connectKey": .string(connectKey)])
    case .rockchip(.waitForHDCDisconnect(let connectKey)):
      self.init(
        kind: "rockchip.waitForHDCDisconnect",
        arguments: ["connectKey": .string(connectKey)])
    case .rockchip(.waitForLoader(let identity)):
      self.init(
        kind: "rockchip.waitForLoader",
        arguments: ["stableIdentitySha256": .string(identity)])
    case .rockchip(.rebindLoader(let identity)):
      self.init(
        kind: "rockchip.rebindLoader",
        arguments: ["stableIdentitySha256": .string(identity)])
    case .rockchip(.flashPartitions(let bundle)):
      self.init(
        kind: "rockchip.flashPartitions",
        arguments: Self.rockchipBundleArguments(bundle))
    case .rockchip(.verifyFlashReadback(let bundle)):
      self.init(
        kind: "rockchip.verifyFlashReadback",
        arguments: Self.rockchipBundleArguments(bundle))
    case .rockchip(.rebootToNormal(let identity)):
      self.init(
        kind: "rockchip.rebootToNormal",
        arguments: ["stableIdentitySha256": .string(identity)])
    case .rockchip(.waitForHDCReconnect(let connectKey)):
      self.init(
        kind: "rockchip.waitForHDCReconnect",
        arguments: ["connectKey": .string(connectKey)])
    case .rockchip(.waitForBoundHDCReconnect(let expectation)):
      self.init(
        kind: "rockchip.waitForBoundHDCReconnect",
        arguments: Self.rockchipHDCExpectationArguments(expectation))
    case .rockchip(
      .verifyBuild(let connectKey, let expectedProductModel, let expectedBuildVersion)):
      var arguments: [String: JSONValue] = ["connectKey": .string(connectKey)]
      if let expectedProductModel {
        arguments["expectedProductModel"] = .string(expectedProductModel)
      }
      if let expectedBuildVersion {
        arguments["expectedBuildVersion"] = .string(expectedBuildVersion)
      }
      self.init(kind: "rockchip.verifyBuild", arguments: arguments)
    case .rockchip(
      .verifyBoundBuild(let expectation, let expectedProductModel, let expectedBuildVersion)):
      var arguments = Self.rockchipHDCExpectationArguments(expectation)
      arguments["expectedProductModel"] = .string(expectedProductModel)
      arguments["expectedBuildVersion"] = .string(expectedBuildVersion)
      self.init(kind: "rockchip.verifyBoundBuild", arguments: arguments)
    case .rockchip(.capturePostFlashDiagnostics(let connectKey, let request)):
      self.init(
        kind: "rockchip.capturePostFlashDiagnostics",
        arguments: [
          "connectKey": .string(connectKey),
          "durationSeconds": .integer(Int64(request.durationSeconds)),
          "filters": .array(request.filters.map(JSONValue.string)),
          "byteBudget": .integer(Int64(request.byteBudget)),
        ])
    case .analyzer(.analyze(let invocation)):
      // The journal records which analyzer ran over which artifact, never
      // the host path the bytes happened to live at.
      self.init(
        kind: "analyzer.analyze",
        arguments: [
          "analyzerRef": .string(invocation.analyzerRef),
          "analyzerVersion": .string(invocation.analyzerVersion),
          "sourceArtifactId": .string(invocation.sourceArtifactID),
          "sourceSha256": .string(invocation.sourceSHA256),
          "sourceByteCount": .integer(Int64(invocation.sourceByteCount)),
        ])
    }
  }

  private static func rockchipBundleArguments(
    _ bundle: RockchipRuntimeFlashBundle
  ) -> [String: JSONValue] {
    [
      "artifactLeaseId": .string(bundle.artifactLeaseID),
      "artifactId": .string(bundle.artifactID),
      "artifactPath": .string(bundle.fileURL.path),
      "artifactSha256": .string(bundle.sha256),
      "artifactByteCount": .integer(Int64(bundle.byteCount)),
      "partitionNames": .array(bundle.partitionNames.map(JSONValue.string)),
    ]
  }

  private static func rockchipHDCExpectationArguments(
    _ expectation: RockchipHDCReconnectExpectation
  ) -> [String: JSONValue] {
    [
      "previousConnectKey": .string(expectation.previousConnectKey),
      "previousIdentitySha256": .string(expectation.previousIdentitySHA256),
      "usbTopology": .string(expectation.usbTopology),
    ]
  }

  private init(kind: String, arguments: [String: JSONValue]) {
    self.kind = kind
    self.arguments = arguments
  }

  func materialize() throws -> TypedProviderAction {
    func string(_ key: String) throws -> String {
      guard case .string(let value)? = arguments[key] else {
        throw DeviceProviderError.unsupportedAction(
          "persisted \(kind) is missing string \(key)")
      }
      return value
    }
    func integer(_ key: String) throws -> Int {
      guard case .integer(let value)? = arguments[key], let exact = Int(exactly: value) else {
        throw DeviceProviderError.unsupportedAction(
          "persisted \(kind) is missing integer \(key)")
      }
      return exact
    }
    func stringArray(_ key: String) throws -> [String] {
      guard case .array(let values)? = arguments[key] else {
        throw DeviceProviderError.unsupportedAction(
          "persisted \(kind) is missing array \(key)")
      }
      return try values.map { value in
        guard case .string(let item) = value else {
          throw DeviceProviderError.unsupportedAction(
            "persisted \(kind).\(key) contains a non-string")
        }
        return item
      }
    }
    func optionalString(_ key: String) throws -> String? {
      guard let value = arguments[key] else { return nil }
      guard case .string(let text) = value else {
        throw DeviceProviderError.unsupportedAction(
          "persisted \(kind).\(key) is not a string")
      }
      return text
    }
    func optionalInteger(_ key: String) throws -> Int? {
      guard let value = arguments[key] else { return nil }
      guard case .integer(let number) = value, let exact = Int(exactly: number) else {
        throw DeviceProviderError.unsupportedAction(
          "persisted \(kind).\(key) is not an integer")
      }
      return exact
    }
    func portDirection() throws -> HDCPortForwardDirection {
      guard let value = try optionalString("direction") else { return .forward }
      guard let direction = HDCPortForwardDirection(rawValue: value) else {
        throw DeviceProviderError.unsupportedAction(
          "persisted \(kind).direction is not a closed port direction")
      }
      return direction
    }
    func rockchipBundle() throws -> RockchipRuntimeFlashBundle {
      let byteCount = try integer("artifactByteCount")
      guard byteCount > 0 else {
        throw DeviceProviderError.unsupportedAction(
          "persisted \(kind) carries an invalid Artifact byte count")
      }
      let pathValue = try string("artifactPath")
      let fileURL = URL(fileURLWithPath: pathValue)
      guard
        pathValue.hasPrefix("/"),
        fileURL.standardizedFileURL.path == pathValue
      else {
        throw DeviceProviderError.unsupportedAction(
          "persisted \(kind) carries a non-canonical Artifact path")
      }
      return RockchipRuntimeFlashBundle(
        artifactLeaseID: try string("artifactLeaseId"),
        artifactID: try string("artifactId"),
        fileURL: fileURL,
        sha256: try string("artifactSha256"),
        byteCount: byteCount,
        partitionNames: try stringArray("partitionNames"))
    }
    func rockchipHDCExpectation() throws -> RockchipHDCReconnectExpectation {
      let previousConnectKey = try string("previousConnectKey")
      let previousIdentity = try string("previousIdentitySha256")
      let topology = try string("usbTopology")
      let connectIdentity = SHA256Hex.string(of: Data(previousConnectKey.utf8))
      guard !previousConnectKey.isEmpty,
        previousIdentity.count == 64,
        previousIdentity.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
        connectIdentity == previousIdentity,
        !topology.isEmpty,
        topology.utf8.allSatisfy({ (48...57).contains($0) })
      else {
        throw DeviceProviderError.unsupportedAction(
          "persisted \(kind) carries an invalid HDC binding expectation")
      }
      return RockchipHDCReconnectExpectation(
        previousConnectKey: previousConnectKey,
        previousIdentitySHA256: previousIdentity,
        usbTopology: topology)
    }
    func path() throws -> HDCOwnedRemotePath {
      let reconstructed = try HDCOwnedRemotePath(
        jobID: string("jobId"), stepID: string("stepId"), nonce: string("nonce"))
      let recordedRemotePath = try string("remotePath")
      guard reconstructed.remotePath == recordedRemotePath else {
        throw DeviceProviderError.unsupportedAction(
          "persisted \(kind) remote path does not match its owned components")
      }
      return reconstructed
    }
    func bundle() throws -> HDCBundleReference {
      try HDCBundleReference(bundleName: string("bundleName"))
    }
    func ability() throws -> HDCAbilityReference {
      try HDCAbilityReference(bundle: bundle(), abilityName: string("abilityName"))
    }
    func staged() throws -> HDCStagedArtifact {
      HDCStagedArtifact(
        path: try path(), artifactLeaseID: try string("artifactLeaseId"),
        expectedSHA256: try optionalString("expectedSha256"))
    }
    func packageSet() throws -> HDCStagedPackageSet {
      let directory = try HDCOwnedRemoteDirectory(
        jobID: string("jobId"), stepID: string("stepId"), nonce: string("nonce"))
      guard case .array(let raw)? = arguments["packages"] else {
        throw DeviceProviderError.unsupportedAction(
          "persisted \(kind) carries no staged package list")
      }
      var packages: [HDCStagedPackage] = []
      for entry in raw {
        guard case .object(let fields) = entry,
          case .string(let remotePath)? = fields["remotePath"],
          case .string(let lease)? = fields["artifactLeaseId"],
          let artifactID = remotePath.split(separator: "/").last?
            .replacingOccurrences(of: ".hap", with: "")
        else {
          throw DeviceProviderError.unsupportedAction(
            "persisted \(kind) carries a malformed staged package")
        }
        var sha: String?
        if case .string(let value)? = fields["sha256"] { sha = value }
        packages.append(
          try HDCStagedPackage(
            directory: directory, artifactID: String(artifactID),
            artifactLeaseID: lease, expectedSHA256: sha))
      }
      return try HDCStagedPackageSet(directory: directory, packages: packages)
    }
    func nativeDeployment() throws -> HDCAppOwnedNativeLibraryDeployment {
      guard let abi = HDCNativeLibraryABI(rawValue: try string("abi")),
        let restart = HDCNativeRestartProfile(rawValue: try string("restartProfile")),
        let verification = HDCNativeVerificationProfile(
          rawValue: try string("verificationProfile")),
        let rollback = HDCNativeRollbackPolicy(rawValue: try string("rollbackPolicy"))
      else {
        throw DeviceProviderError.unsupportedAction(
          "persisted \(kind) carries an unknown native deployment profile")
      }
      let machineValue = try integer("machine")
      guard let machine = UInt16(exactly: machineValue) else {
        throw DeviceProviderError.unsupportedAction(
          "persisted \(kind) native ELF machine is outside UInt16")
      }
      let codeSign: HDCNativeLibraryCodeSignFacts?
      if let formatVersion = try optionalInteger("codeSignFormatVersion") {
        guard let codeSignVersion = try optionalInteger("codeSignVersion"),
          let signedDataByteCount = try optionalInteger("signedDataByteCount"),
          let signatureByteCount = try optionalInteger("signatureByteCount")
        else {
          throw DeviceProviderError.unsupportedAction(
            "persisted \(kind) carries incomplete native code-sign facts")
        }
        codeSign = HDCNativeLibraryCodeSignFacts(
          formatVersion: formatVersion,
          codeSignVersion: codeSignVersion,
          signedDataByteCount: signedDataByteCount,
          signatureByteCount: signatureByteCount)
      } else {
        codeSign = nil
      }
      let helperFacts: HDCNativeCodeSignHelperFacts?
      if let helperABIValue = try optionalString("codeSignHelperABI") {
        guard let helperABI = HDCNativeLibraryABI(rawValue: helperABIValue),
          let helperBuildID = try optionalString("codeSignHelperBuildId"),
          let helperSHA256 = try optionalString("codeSignHelperSha256"),
          let helperByteCount = try optionalInteger("codeSignHelperByteCount"),
          try optionalString("codeSignHelperRemotePath") != nil
        else {
          throw DeviceProviderError.unsupportedAction(
            "persisted \(kind) carries incomplete code-sign helper facts")
        }
        helperFacts = HDCNativeCodeSignHelperFacts(
          abi: helperABI,
          buildID: helperBuildID,
          sha256: helperSHA256,
          byteCount: helperByteCount)
      } else {
        helperFacts = nil
      }
      let deployment = try HDCAppOwnedNativeLibraryDeployment(
        jobID: string("jobId"),
        artifactLeaseID: string("artifactLeaseId"),
        artifactID: string("artifactId"),
        bundle: bundle(),
        libraryLogicalName: string("libraryLogicalName"),
        artifactFacts: HDCNativeLibraryArtifactFacts(
          abi: abi,
          elfClassBits: integer("elfClassBits"),
          machine: machine,
          buildID: string("buildId"),
          sha256: string("sha256"),
          byteCount: integer("byteCount"),
          codeSign: codeSign),
        restartProfile: restart,
        verificationProfile: verification,
        rollbackPolicy: rollback,
        codeSignHelperFacts: helperFacts,
        exactPaths: HDCAppOwnedNativeLibraryExactPaths(
          directoryPath: try string("directoryPath"),
          targetPath: try string("targetPath"),
          loaderVisiblePath: try string("loaderVisiblePath"),
          stagingDirectoryPath: try optionalString("stagingDirectoryPath"),
          stagingPath: try string("stagingPath"),
          backupPath: try string("backupPath"),
          rollbackStagingPath: try string("rollbackStagingPath"),
          codeSignHelperRemotePath: try optionalString(
            "codeSignHelperRemotePath")))
      return deployment
    }

    switch kind {
    case "workspace.inspectSource":
      return .workspace(
        .inspectSource(
          WorkspaceSourceInspection(
            projectRef: try string("projectRef"),
            projectRoot: "",
            symbol: try string("symbol"),
            fileScope: try string("fileScope"))))
    case "workspace.action":
      let payload = try string("payload")
      guard let data = Data(base64Encoded: payload) else {
        throw DeviceProviderError.unsupportedAction(
          "persisted workspace action payload is not base64")
      }
      do {
        return .workspace(
          try JSONDecoder().decode(WorkspaceProviderAction.self, from: data))
      } catch {
        throw DeviceProviderError.unsupportedAction(
          "persisted workspace action payload is invalid: \(error)")
      }
    case "hdc.observeTool": return .hdc(.observeTool)
    case "hdc.observeServer": return .hdc(.observeServer)
    case "hdc.listDeviceCandidates": return .hdc(.listDeviceCandidates)
    case "hdc.observeDevice":
      return .hdc(.observeDevice(connectKey: try string("connectKey")))
    case "hdc.queryProperty":
      guard let property = HDCAllowlistedProperty(rawValue: try string("property")) else {
        throw DeviceProviderError.unsupportedAction("persisted query property is not allowlisted")
      }
      return .hdc(.queryProperty(property))
    case "hdc.observeStorage":
      return .hdc(.observeStorage(try HDCStoragePreflightRequest(
        requiredBytes: integer("requiredBytes"))))
    case "hdc.captureHilog":
      return .hdc(.captureHilog(try HDCHilogCaptureRequest(
        durationSeconds: integer("durationSeconds"),
        filters: stringArray("filters"), byteBudget: integer("byteBudget"))))
    case "hdc.captureUIDump":
      guard let scope = HDCUIDumpRequest.Scope(rawValue: try string("scope")) else {
        throw DeviceProviderError.unsupportedAction("persisted UI dump scope is invalid")
      }
      return .hdc(.captureUIDump(try HDCUIDumpRequest(
        scope: scope, byteBudget: integer("byteBudget"))))
    case "hdc.captureCrashIndex":
      return .hdc(.captureCrashIndex(byteBudget: try integer("byteBudget")))
    case "hdc.captureCrashLog":
      return .hdc(
        .captureCrashLog(
          try HDCFaultLogName(try string("faultLogName")),
          byteBudget: try integer("byteBudget")))
    case "hdc.captureTrace":
      return .hdc(.captureTrace(
        try HDCTraceCaptureRequest(
          durationSeconds: integer("durationSeconds"),
          categories: stringArray("categories"), bufferKB: integer("bufferKB")),
        into: try path()))
    case "hdc.captureComponentTree":
      return .hdc(.captureComponentTree(into: try path()))
    case "hdc.captureScreenshot":
      return .hdc(.captureScreenshot(into: try path()))
    case "hdc.receiveOwnedArtifact":
      return .hdc(.receiveOwnedArtifact(
        HDCOwnedRemoteArtifact(
          path: try path(), expectedSHA256: try optionalString("expectedSha256"),
          maximumBytes: try integer("maximumBytes"),
          expectedLeadingBytes: try optionalString("expectedLeadingBytes").map { hex in
            var bytes = Data()
            var index = hex.startIndex
            while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
              if let byte = UInt8(hex[index..<next], radix: 16) { bytes.append(byte) }
              index = next
            }
            return bytes
          })))
    case "hdc.cleanupOwnedRemotePath":
      return .hdc(.cleanupOwnedRemotePath(try path()))
    case "hdc.sendArtifactToStaging":
      return .hdc(.sendArtifactToStaging(try staged()))
    case "hdc.installPackage":
      return .hdc(.installPackage(try staged(), bundle: try bundle()))
    case "hdc.sendPackageSetToStaging":
      return .hdc(.sendPackageSetToStaging(try packageSet()))
    case "hdc.installPackageSet":
      return .hdc(.installPackageSet(try packageSet(), bundle: try bundle()))
    case "hdc.cleanupStagedPackageSet":
      return .hdc(.cleanupStagedPackageSet(try packageSet()))
    case "hdc.readOwnedDirectoryPresence":
      return .hdc(
        .readOwnedDirectoryPresence(
          try HDCOwnedRemoteDirectory(
            jobID: string("jobId"), stepID: string("stepId"), nonce: string("nonce"))))
    case "hdc.queryPackageReadback":
      return .hdc(.queryPackageReadback(try bundle()))
    case "hdc.startAbility":
      return .hdc(.startAbility(try ability()))
    case "hdc.verifyProcessState":
      return .hdc(.verifyProcessState(try bundle()))
    case "hdc.observeApplicationLiveness":
      return .hdc(
        .observeApplicationLiveness(
          try HDCApplicationLivenessRequest(
            bundle: bundle(),
            abilityName: optionalString("abilityName"),
            processName: optionalString("processName"),
            expectedDeployedArtifactDigest: optionalString(
              "expectedDeployedArtifactDigest"))))
    case "hdc.stopAbility":
      return .hdc(.stopAbility(try ability()))
    case "hdc.uninstallPackage":
      return .hdc(.uninstallPackage(try bundle()))
    case "hdc.createPortForward":
      return .hdc(.createPortForward(try HDCPortForwardSpec(
        direction: try portDirection(),
        localPort: integer("localPort"), remotePort: integer("remotePort"))))
    case "hdc.removePortForward":
      return .hdc(.removePortForward(try HDCPortForwardSpec(
        direction: try portDirection(),
        localPort: integer("localPort"), remotePort: integer("remotePort"))))
    case "hdc.readPackagePresence":
      return .hdc(.readPackagePresence(try bundle()))
    case "hdc.readProcessPresence":
      return .hdc(.readProcessPresence(try bundle()))
    case "hdc.readOwnedPathPresence":
      return .hdc(.readOwnedPathPresence(try path()))
    case "hdc.readPortForwardPresence":
      return .hdc(.readPortForwardPresence(try HDCPortForwardSpec(
        direction: try portDirection(),
        localPort: integer("localPort"), remotePort: integer("remotePort"))))
    case "hdc.sendNativeLibraryToStaging":
      return .hdc(.sendNativeLibraryToStaging(try nativeDeployment()))
    case "hdc.backupNativeLibrary":
      return .hdc(.backupNativeLibrary(try nativeDeployment()))
    case "hdc.publishNativeLibrary":
      return .hdc(.publishNativeLibrary(try nativeDeployment()))
    case "hdc.stopNativeTarget":
      return .hdc(.stopNativeTarget(try nativeDeployment()))
    case "hdc.startNativeTarget":
      return .hdc(.startNativeTarget(try nativeDeployment()))
    case "hdc.cleanupNativeLibrary":
      return .hdc(.cleanupNativeLibrary(try nativeDeployment()))
    case "hdc.rollbackNativeLibrary":
      return .hdc(.rollbackNativeLibrary(try nativeDeployment()))
    case "hdc.inspectNativeLibrary":
      guard let expectation = HDCNativeLibraryInspection(
        rawValue: try string("expectation"))
      else {
        throw DeviceProviderError.unsupportedAction(
          "persisted native inspection expectation is unknown")
      }
      return .hdc(.inspectNativeLibrary(
        try nativeDeployment(), expectation: expectation))
    case "rockchip.enterLoader":
      return .rockchip(.enterLoader(connectKey: try string("connectKey")))
    case "rockchip.observeHDCNormalUSB":
      return .rockchip(.observeHDCNormalUSB(connectKey: try string("connectKey")))
    case "rockchip.waitForHDCDisconnect":
      return .rockchip(.waitForHDCDisconnect(connectKey: try string("connectKey")))
    case "rockchip.waitForLoader":
      return .rockchip(.waitForLoader(
        stableIdentitySHA256: try string("stableIdentitySha256")))
    case "rockchip.rebindLoader":
      return .rockchip(.rebindLoader(
        stableIdentitySHA256: try string("stableIdentitySha256")))
    case "rockchip.flashPartitions":
      return .rockchip(.flashPartitions(try rockchipBundle()))
    case "rockchip.verifyFlashReadback":
      return .rockchip(.verifyFlashReadback(try rockchipBundle()))
    case "rockchip.rebootToNormal":
      return .rockchip(.rebootToNormal(
        stableIdentitySHA256: try string("stableIdentitySha256")))
    case "rockchip.waitForHDCReconnect":
      return .rockchip(.waitForHDCReconnect(connectKey: try string("connectKey")))
    case "rockchip.waitForBoundHDCReconnect":
      return .rockchip(.waitForBoundHDCReconnect(
        expectation: try rockchipHDCExpectation()))
    case "rockchip.verifyBuild":
      return .rockchip(
        .verifyBuild(
          connectKey: try string("connectKey"),
          expectedProductModel: try optionalString("expectedProductModel"),
          expectedBuildVersion: try optionalString("expectedBuildVersion")))
    case "rockchip.verifyBoundBuild":
      return .rockchip(
        .verifyBoundBuild(
          expectation: try rockchipHDCExpectation(),
          expectedProductModel: try string("expectedProductModel"),
          expectedBuildVersion: try string("expectedBuildVersion")))
    case "rockchip.capturePostFlashDiagnostics":
      return .rockchip(.capturePostFlashDiagnostics(
        connectKey: try string("connectKey"),
        request: try HDCHilogCaptureRequest(
          durationSeconds: integer("durationSeconds"),
          filters: stringArray("filters"),
          byteBudget: integer("byteBudget"))))
    default:
      throw DeviceProviderError.unsupportedAction(
        "persisted typed provider action kind \(kind) is unknown")
    }
  }
}

// MARK: - Facts, plans, receipts, outcomes

public struct ProviderFacts: Sendable, Equatable {
  public let providerID: String
  public let toolVersion: String
  public let toolSHA256: String
  public let serverFacts: [String: String]
  /// Correlation fields are optional for compatibility with pre-V3 fact
  /// producers. Hardware evidence treats every absent field as
  /// incomplete; the runtime never fills one from a target ID or caller
  /// input.
  public let targetID: String?
  public let bindingRevision: Int?
  public let deviceIdentitySHA256: String?
  /// Private execution routing material. This type is deliberately not
  /// Codable so a raw device key cannot leak into a job record, receipt or
  /// evidence artifact by accidental serialization.
  public let executionConnectKey: String?
  public let deviceModel: String?
  public let deviceMode: String?
  public let buildFingerprint: String?
  public let transport: String?
  public let profileID: String
  public let collectedAtUTC: String
  /// Time at which the device facts themselves were read. This is
  /// deliberately separate from `collectedAtUTC`: reopening a cached
  /// target record "now" must not make an old observation fresh.
  public let sourceObservedAtUTC: String?

  public init(
    providerID: String,
    toolVersion: String,
    toolSHA256: String,
    serverFacts: [String: String],
    targetID: String? = nil,
    bindingRevision: Int? = nil,
    deviceIdentitySHA256: String?,
    executionConnectKey: String? = nil,
    deviceModel: String? = nil,
    deviceMode: String?,
    buildFingerprint: String?,
    transport: String? = nil,
    profileID: String,
    collectedAtUTC: String,
    sourceObservedAtUTC: String? = nil
  ) {
    self.providerID = providerID
    self.toolVersion = toolVersion
    self.toolSHA256 = toolSHA256
    self.serverFacts = serverFacts
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.deviceIdentitySHA256 = deviceIdentitySHA256
    self.executionConnectKey = executionConnectKey
    self.deviceModel = deviceModel
    self.deviceMode = deviceMode
    self.buildFingerprint = buildFingerprint
    self.transport = transport
    self.profileID = profileID
    self.collectedAtUTC = collectedAtUTC
    self.sourceObservedAtUTC = sourceObservedAtUTC
  }
}

/// A lowered plan. `process` carries a concrete child-process invocation
/// (descriptor-bound); `hostManaged` marks an adapter-compat execution the
/// provider runs under its own proven host (Rockchip migration mode).
/// Construction is package-only: clients cannot mint plans.
package struct TypedProcessInvocation: Sendable, Equatable {
  public let arguments: [String]
  public let timeoutSeconds: Int?
  /// A mutating command can report non-zero after partially taking effect.
  /// Those invocations must still reach their dedicated readback.
  public let continueAfterNonZero: Bool

  package init(
    arguments: [String],
    timeoutSeconds: Int?,
    continueAfterNonZero: Bool = false
  ) {
    self.arguments = arguments
    self.timeoutSeconds = timeoutSeconds
    self.continueAfterNonZero = continueAfterNonZero
  }
}

/// Engine-derived correlation carried to a provider-owned host. Every field
/// comes from the same target facts and typed action that were materialized
/// before Runtime capability admission; callers cannot construct or mutate
/// this value outside ArkDeckWorkflows.
public struct HostManagedProcessDescriptor: Sendable, Equatable {
  public let identifier: String
  public let jobID: String
  public let stepID: String
  public let targetID: String
  public let bindingRevision: Int
  public let connectKey: String
  public let expectedIdentitySHA256: String
  public let providerExecutableSHA256: String
  public let actionSHA256: String
  /// Candidate timing controls copied only from an admitted Evolution
  /// reservation. Request inputs cannot construct this descriptor.
  public let executionTuning: AgentAuthorityCampaignExecutionTuning?

  package init(
    identifier: String,
    jobID: String,
    stepID: String,
    targetID: String,
    bindingRevision: Int,
    connectKey: String,
    expectedIdentitySHA256: String,
    providerExecutableSHA256: String,
    actionSHA256: String,
    executionTuning: AgentAuthorityCampaignExecutionTuning? = nil
  ) {
    self.identifier = identifier
    self.jobID = jobID
    self.stepID = stepID
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.connectKey = connectKey
    self.expectedIdentitySHA256 = expectedIdentitySHA256
    self.providerExecutableSHA256 = providerExecutableSHA256
    self.actionSHA256 = actionSHA256
    self.executionTuning = executionTuning
  }
}

/// What a plan must leave behind on the host, declared by the provider that
/// also put the destination into the argv. A device-to-host transfer is the
/// one case where the process receipt cannot carry the evidence: `hdc file
/// recv` prints a progress line, and the bytes that matter land on disk.
///
/// The declaration is the provider's; reading the disk is the dispatcher's.
/// Nothing here describes what *should* have landed as though it had.
public struct HostLandingExpectation: Sendable, Equatable {
  /// Absolute host path the argv names as the transfer destination.
  public let destination: URL
  /// Refuse anything larger rather than hash an unbounded file.
  public let maximumBytes: Int
  /// Pinned content hash when one is known before the transfer. Today's
  /// trace leg has none (nothing computes a device-side digest first), so
  /// this is `nil` in production and exercised by contract tests.
  public let expectedSHA256: String?

  public init(destination: URL, maximumBytes: Int, expectedSHA256: String? = nil) {
    self.destination = destination
    self.maximumBytes = maximumBytes
    self.expectedSHA256 = expectedSHA256
  }

  /// Creates the destination directory and clears any stale file at the
  /// destination. Without the removal a leftover file from an earlier
  /// attempt could be inspected as though this transfer had produced it.
  public func prepareDestination() throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
  }

  /// Reports what is actually at the destination, or `nil` when nothing
  /// usable is: no file, a symlink, a non-regular file. `nil` is not a
  /// verdict — the landing path of `hdc file recv` is not guaranteed across
  /// versions (see `DEVICE-COMMAND-FACTS.md` §4), so absence here means the
  /// outcome is unknown, never that the transfer failed.
  public func inspectLanded() -> ProviderLandedArtifact? {
    let descriptor = Darwin.open(destination.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return nil }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      return nil
    }
    let byteCount = Int(info.st_size)
    // An oversized or empty file is reported as found, with no digest: both
    // are definite outcomes the classifier must be able to name, and
    // hashing an over-budget file is exactly what the budget forbids.
    guard byteCount > 0, byteCount <= maximumBytes else {
      return ProviderLandedArtifact(
        localURL: destination, byteCount: byteCount, sha256: nil)
    }
    var leading = Data()
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 256 * 1024)
    var hashed = 0
    while true {
      let read = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, $0.count)
      }
      if read < 0 { return nil }
      if read == 0 { break }
      hashed += read
      guard hashed <= byteCount else { return nil }
      if leading.count < 8 {
        leading.append(contentsOf: buffer.prefix(min(read, 8 - leading.count)))
      }
      buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(read))) }
    }
    guard hashed == byteCount else { return nil }
    return ProviderLandedArtifact(
      localURL: destination,
      byteCount: byteCount,
      sha256: SHA256Hex.hexString(hasher.finalize()),
      leadingBytes: leading)
  }
}

/// Bytes observed on the host after a transfer. Every field is measured
/// from the file, never copied from the request that asked for it.
public struct ProviderLandedArtifact: Sendable, Equatable {
  public let localURL: URL
  public let byteCount: Int
  /// Absent when the file was empty or over budget, i.e. when it was
  /// deliberately not hashed.
  public let sha256: String?
  /// The first bytes as they are on disk, so a format check needs no
  /// second read and cannot be satisfied by anything but the real file.
  public let leadingBytes: Data

  public init(localURL: URL, byteCount: Int, sha256: String?, leadingBytes: Data = Data()) {
    self.localURL = localURL
    self.byteCount = byteCount
    self.sha256 = sha256
    self.leadingBytes = leadingBytes
  }
}

public struct TypedProcessPlan: Sendable, Equatable {
  package enum Kind: Sendable, Equatable {
    case process(executableSHA256: String, argumentSummary: [String], timeoutSeconds: Int?)
    case processSequence(executableSHA256: String, invocations: [TypedProcessInvocation])
    case hostManaged(HostManagedProcessDescriptor)
  }

  package let action: TypedProviderAction
  package let kind: Kind
  /// Optional semantic `argv[0]` for a descriptor-bound multi-call binary.
  /// It is included in the materialized plan digest and never selects the
  /// executable descriptor.
  public let argumentZero: String?
  /// Optional canonical child working directory. It is provider-owned plan
  /// data and participates in the materialized plan digest.
  public let workingDirectory: String?
  /// Set only by plans whose product is a host file. The dispatcher honours
  /// it; no other plan gains host filesystem reach by declaring one.
  public let hostLanding: HostLandingExpectation?

  package init(
    action: TypedProviderAction,
    kind: Kind,
    argumentZero: String? = nil,
    workingDirectory: String? = nil,
    hostLanding: HostLandingExpectation? = nil
  ) {
    self.action = action
    self.kind = kind
    self.argumentZero = argumentZero
    self.workingDirectory = workingDirectory
    self.hostLanding = hostLanding
  }
}

public struct ProviderSubprocessReceipt: Sendable, Equatable {
  public let exitStatus: Int32?
  public let stdout: Data
  public let stderr: Data
  public let stdoutTruncated: Bool
  public let durationSeconds: Double

  public init(
    exitStatus: Int32?,
    stdout: Data,
    stderr: Data,
    stdoutTruncated: Bool,
    durationSeconds: Double
  ) {
    self.exitStatus = exitStatus
    self.stdout = stdout
    self.stderr = stderr
    self.stdoutTruncated = stdoutTruncated
    self.durationSeconds = durationSeconds
  }
}

public struct ProviderProcessReceipt: Sendable, Equatable {
  public let exitStatus: Int32?
  public let stdout: Data
  public let stderr: Data
  public let stdoutTruncated: Bool
  public let durationSeconds: Double
  /// Present when the plan was host-managed: an opaque reference to the
  /// provider-owned durable record (e.g. Rockchip session manifest ID).
  public let hostManagedRecordID: String?
  /// Semantic fields emitted by the product-owned host only after its
  /// durable typed receipt has been written. The provider still validates
  /// these fields; operation callers never construct process receipts.
  public let hostManagedSummary: [String: String]
  /// Present when the plan declared a `hostLanding` and the dispatcher found
  /// a file there. Measured, never assumed.
  public let landedArtifact: ProviderLandedArtifact?
  /// Ordered receipts for a provider-owned command/readback sequence. Empty
  /// for the existing single-process surface.
  public let subprocesses: [ProviderSubprocessReceipt]

  public init(
    exitStatus: Int32?,
    stdout: Data,
    stderr: Data,
    stdoutTruncated: Bool,
    durationSeconds: Double,
    hostManagedRecordID: String? = nil,
    hostManagedSummary: [String: String] = [:],
    landedArtifact: ProviderLandedArtifact? = nil,
    subprocesses: [ProviderSubprocessReceipt] = []
  ) {
    self.exitStatus = exitStatus
    self.stdout = stdout
    self.stderr = stderr
    self.stdoutTruncated = stdoutTruncated
    self.durationSeconds = durationSeconds
    self.hostManagedRecordID = hostManagedRecordID
    self.hostManagedSummary = hostManagedSummary
    self.landedArtifact = landedArtifact
    self.subprocesses = subprocesses
  }
}

/// Closed semantic verdicts. `verified` requires a parsed summary - the
/// type system offers no path from a bare exit code to success.
public enum ProviderSemanticOutcome: Sendable, Equatable {
  case verified(summary: [String: String])
  case failed(code: String, detail: String)
  case unknown(reason: String)
  case unsupported(reason: String)
}

public enum ProviderReconcileOutcome: Sendable, Equatable {
  case confirmedCompleted(summary: [String: String])
  case confirmedNotExecuted
  case stillUnknown(reason: String)
}

public struct ProviderExecutionContext: Sendable, Equatable {
  public let jobID: String
  public let stepID: String
  public let targetID: String
  public let bindingRevision: Int?
  /// Provider-private routing and correlation facts resolved from the
  /// adopted target. They never originate in request inputs.
  public let connectKey: String?
  public let expectedIdentitySHA256: String?
  public let toolVersion: String?
  public let toolSHA256: String?
  /// Provider-owned facts resolved alongside the target. Request inputs have
  /// no route to this dictionary; closed provider adapters may consume only
  /// their registered keys when materializing an action.
  public let serverFacts: [String: String]
  public let nowUTC: String
  public let resolvedInputArtifact: ProviderResolvedInputArtifact?
  /// Further packages of a multi-package install, in the caller's order.
  /// Empty for every single-package request, which is what keeps those
  /// plans byte-identical (CHG-2026-049 r4).
  public let additionalInputArtifacts: [ProviderResolvedInputArtifact]
  /// Present only when the Runtime re-read an admitted campaign reservation
  /// and found its broker-recorded bounded tuning controls.
  public let campaignExecutionTuning: AgentAuthorityCampaignExecutionTuning?
  /// The build version declared by the image bundle this job will write, read
  /// from the bundle's system image when the Runtime resolved it.
  ///
  /// It travels on the context because deciding what a device must report
  /// after a flash is a fact about bytes, and reading bytes is the Runtime's
  /// job. A step materializer that opened a 730 MB archive to answer this
  /// would make materialization depend on I/O, which is what it stopped doing
  /// when the per-build pins were removed (CHG-2026-056 r4).
  public let expectedRuntimeBuildVersion: String?

  public init(
    jobID: String,
    stepID: String,
    targetID: String,
    bindingRevision: Int?,
    connectKey: String? = nil,
    expectedIdentitySHA256: String? = nil,
    toolVersion: String? = nil,
    toolSHA256: String? = nil,
    serverFacts: [String: String] = [:],
    nowUTC: String,
    resolvedInputArtifact: ProviderResolvedInputArtifact? = nil,
    additionalInputArtifacts: [ProviderResolvedInputArtifact] = [],
    campaignExecutionTuning: AgentAuthorityCampaignExecutionTuning? = nil,
    expectedRuntimeBuildVersion: String? = nil
  ) {
    self.jobID = jobID
    self.stepID = stepID
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.connectKey = connectKey
    self.expectedIdentitySHA256 = expectedIdentitySHA256
    self.toolVersion = toolVersion
    self.toolSHA256 = toolSHA256
    self.serverFacts = serverFacts
    self.nowUTC = nowUTC
    self.resolvedInputArtifact = resolvedInputArtifact
    self.additionalInputArtifacts = additionalInputArtifacts
    self.campaignExecutionTuning = campaignExecutionTuning
    self.expectedRuntimeBuildVersion = expectedRuntimeBuildVersion
  }
}

/// Host-side bytes resolved from an Artifact lease by the engine. Providers
/// can consume this typed value, but operation input can never supply a
/// local path directly.
public struct ProviderResolvedInputArtifact: Sendable, Equatable {
  public let artifactID: String
  public let fileURL: URL
  public let sha256: String
  public let byteCount: Int

  public init(artifactID: String, fileURL: URL, sha256: String, byteCount: Int) {
    self.artifactID = artifactID
    self.fileURL = fileURL
    self.sha256 = sha256
    self.byteCount = byteCount
  }
}

public struct ProviderDurableIntentReference: Sendable, Equatable {
  public let jobID: String
  public let stepID: String
  public let intentEventID: String
  package let action: TypedProviderAction

  package init(jobID: String, stepID: String, intentEventID: String, action: TypedProviderAction) {
    self.jobID = jobID
    self.stepID = stepID
    self.intentEventID = intentEventID
    self.action = action
  }
}

public enum DeviceProviderError: Error, Equatable, Sendable {
  case unsupportedAction(String)
  case unsupportedStepKind(String)
  case factsUnavailable(String)
}

// MARK: - The provider protocol

public enum ProviderOperationAvailability: Sendable, Equatable {
  case available
  case unavailable(reason: String)
}

package protocol DeviceProvider: Sendable {
  var providerID: String { get }

  /// Catalog presence is only a description. A provider must separately
  /// publish whether its complete typed implementation is production-ready.
  func runtimeAvailability(
    for operation: CatalogOperationDescriptor
  ) -> ProviderOperationAvailability

  func resolveFacts(targetID: String) async throws -> ProviderFacts

  /// Provider-owned execution readiness derived only from resolved Runtime
  /// facts. Plan-only may still materialize with a blocker so a person can
  /// inspect the exact plan; mutation admission and consume-time revalidation
  /// call this hook and fail closed before the first external effect.
  func executionAdmissionBlocker(
    for operation: CatalogOperationDescriptor,
    facts: ProviderFacts
  ) -> String?

  /// Maps a catalog step (closed kind vocabulary) to this provider's typed
  /// action. Unknown/unsupported kinds must throw, never guess.
  func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) throws -> TypedProviderAction

  /// Context-aware mapping used by the runtime. The default preserves
  /// adapters that do not mint job-bound resources; HDC overrides it so
  /// capture/staging paths are bound to the real durable job.
  func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue],
    context: ProviderExecutionContext
  ) throws -> TypedProviderAction

  func lower(
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan

  func verify(
    receipt: ProviderProcessReceipt,
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> ProviderSemanticOutcome

  func reconcile(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) async throws -> ProviderReconcileOutcome

  /// Returns a dedicated read-only judgement plan for an unknown mutation.
  /// `nil` means no safe readback exists; callers must leave the outcome
  /// unknown and must never redispatch the original action.
  func reconciliationReadback(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan?

  func verifyReconciliationReadback(
    receipt: ProviderProcessReceipt,
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) throws -> ProviderReconcileOutcome

  /// Facts a workspace-scoped capability is checked against; `nil` when this
  /// provider has no workspace (CHG-2026-055, TASK-HFA-009 r2).
  func workspaceAuthorizationFacts(
    for operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) throws -> WorkspaceAuthorizationFacts?

  /// Removes provider-owned temporary state only after Runtime has durably
  /// closed a known terminal. Unknown outcomes deliberately retain readback
  /// material and never pass through this hook.
  func cleanupTerminalJob(jobID: String)

}

extension DeviceProvider {
  package func cleanupTerminalJob(jobID _: String) {}
  public func runtimeAvailability(
    for operation: CatalogOperationDescriptor
  ) -> ProviderOperationAvailability {
    .unavailable(
      reason: "provider \(providerID) has not published runtime availability "
        + "for \(operation.reference)")
  }

  package func executionAdmissionBlocker(
    for operation: CatalogOperationDescriptor,
    facts: ProviderFacts
  ) -> String? {
    nil
  }

  package func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue],
    context: ProviderExecutionContext
  ) throws -> TypedProviderAction {
    try action(for: step, operation: operation, inputs: inputs)
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
    .stillUnknown(reason: "provider has no dedicated reconciliation readback")
  }
}

/// Closed provider registry keyed by providerID ("hdc", "rockchip").
public struct DeviceProviderRegistry: Sendable {
  private let providers: [String: any DeviceProvider]

  package init(providers: [any DeviceProvider]) {
    var table: [String: any DeviceProvider] = [:]
    for provider in providers {
      table[provider.providerID] = provider
    }
    self.providers = table
  }

  package func provider(id: String) -> (any DeviceProvider)? {
    providers[id]
  }

  public func resolveFacts(
    providerID: String, targetID: String
  ) async throws -> ProviderFacts {
    guard let provider = providers[providerID] else {
      throw DeviceProviderError.factsUnavailable("provider \(providerID) is not registered")
    }
    return try await provider.resolveFacts(targetID: targetID)
  }

  public var registeredProviderIDs: [String] {
    providers.keys.sorted()
  }
}
