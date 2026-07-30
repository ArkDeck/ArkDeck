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
  case captureTrace(HDCTraceCaptureRequest, into: HDCOwnedRemotePath)
  case receiveOwnedArtifact(HDCOwnedRemoteArtifact)
  case cleanupOwnedRemotePath(HDCOwnedRemotePath)
  // E1 mutation family (T13). Success for the mutating members is decided
  // by their paired readback, never by the mutation's own exit code.
  case sendArtifactToStaging(HDCStagedArtifact)
  case installPackage(HDCStagedArtifact, bundle: HDCBundleReference)
  case queryPackageReadback(HDCBundleReference)
  case startAbility(HDCAbilityReference)
  case verifyProcessState(HDCBundleReference)
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
/// deliberately absent: the Runtime consumes the E2 capability immediately
/// before the first mutation and the Provider cannot request a second,
/// legacy authorization token.
public enum RockchipProviderAction: Sendable, Equatable {
  case enterLoader(connectKey: String)
  case waitForHDCDisconnect(connectKey: String)
  case waitForLoader(stableIdentitySHA256: String)
  case rebindLoader(stableIdentitySHA256: String)
  case flashPartitions(RockchipRuntimeFlashBundle)
  case verifyFlashReadback(RockchipRuntimeFlashBundle)
  case rebootToNormal(stableIdentitySHA256: String)
  case waitForHDCReconnect(connectKey: String)
  case verifyBuild(connectKey: String)
  case capturePostFlashDiagnostics(connectKey: String, request: HDCHilogCaptureRequest)
}

public enum TypedProviderAction: Sendable, Equatable {
  case hdc(HDCProviderAction)
  case rockchip(RockchipProviderAction)

  public var effect: WorkflowEffect {
    switch self {
    case .hdc(.observeTool), .hdc(.observeServer):
      return .hostOnly
    case .hdc(.listDeviceCandidates), .hdc(.observeDevice), .hdc(.queryProperty),
      .hdc(.observeStorage),
      .hdc(.captureHilog), .hdc(.captureUIDump), .hdc(.receiveOwnedArtifact):
      return .readOnly
    case .hdc(.queryPackageReadback), .hdc(.verifyProcessState):
      return .readOnly
    case .hdc(.readPackagePresence), .hdc(.readProcessPresence),
      .hdc(.readOwnedPathPresence), .hdc(.readPortForwardPresence),
      .hdc(.inspectNativeLibrary):
      return .readOnly
    case .hdc(.captureTrace), .hdc(.cleanupOwnedRemotePath),
      .hdc(.sendArtifactToStaging), .hdc(.installPackage), .hdc(.startAbility),
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
    case .rockchip(.waitForHDCDisconnect), .rockchip(.waitForLoader),
      .rockchip(.rebindLoader), .rockchip(.verifyFlashReadback),
      .rockchip(.waitForHDCReconnect), .rockchip(.verifyBuild),
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

  init(_ action: TypedProviderAction) {
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
    case .hdc(.captureTrace(let request, let path)):
      var arguments = pathArguments(path)
      arguments["durationSeconds"] = .integer(Int64(request.durationSeconds))
      arguments["categories"] = .array(request.categories.map(JSONValue.string))
      arguments["bufferKB"] = .integer(Int64(request.bufferKB))
      self.init(kind: "hdc.captureTrace", arguments: arguments)
    case .hdc(.receiveOwnedArtifact(let artifact)):
      var arguments = pathArguments(artifact.path)
      arguments["maximumBytes"] = .integer(Int64(artifact.maximumBytes))
      optional(artifact.expectedSHA256, into: &arguments, key: "expectedSha256")
      self.init(kind: "hdc.receiveOwnedArtifact", arguments: arguments)
    case .hdc(.cleanupOwnedRemotePath(let path)):
      self.init(kind: "hdc.cleanupOwnedRemotePath", arguments: pathArguments(path))
    case .hdc(.sendArtifactToStaging(let artifact)):
      var arguments = pathArguments(artifact.path)
      arguments["artifactLeaseId"] = .string(artifact.artifactLeaseID)
      optional(artifact.expectedSHA256, into: &arguments, key: "expectedSha256")
      self.init(kind: "hdc.sendArtifactToStaging", arguments: arguments)
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
          "localPort": .integer(Int64(spec.localPort)),
          "remotePort": .integer(Int64(spec.remotePort)),
        ])
    case .hdc(.removePortForward(let spec)):
      self.init(
        kind: "hdc.removePortForward",
        arguments: [
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
    case .rockchip(.verifyBuild(let connectKey)):
      self.init(
        kind: "rockchip.verifyBuild",
        arguments: ["connectKey": .string(connectKey)])
    case .rockchip(.capturePostFlashDiagnostics(let connectKey, let request)):
      self.init(
        kind: "rockchip.capturePostFlashDiagnostics",
        arguments: [
          "connectKey": .string(connectKey),
          "durationSeconds": .integer(Int64(request.durationSeconds)),
          "filters": .array(request.filters.map(JSONValue.string)),
          "byteBudget": .integer(Int64(request.byteBudget)),
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
    case "hdc.captureTrace":
      return .hdc(.captureTrace(
        try HDCTraceCaptureRequest(
          durationSeconds: integer("durationSeconds"),
          categories: stringArray("categories"), bufferKB: integer("bufferKB")),
        into: try path()))
    case "hdc.receiveOwnedArtifact":
      return .hdc(.receiveOwnedArtifact(
        HDCOwnedRemoteArtifact(
          path: try path(), expectedSHA256: try optionalString("expectedSha256"),
          maximumBytes: try integer("maximumBytes"))))
    case "hdc.cleanupOwnedRemotePath":
      return .hdc(.cleanupOwnedRemotePath(try path()))
    case "hdc.sendArtifactToStaging":
      return .hdc(.sendArtifactToStaging(try staged()))
    case "hdc.installPackage":
      return .hdc(.installPackage(try staged(), bundle: try bundle()))
    case "hdc.queryPackageReadback":
      return .hdc(.queryPackageReadback(try bundle()))
    case "hdc.startAbility":
      return .hdc(.startAbility(try ability()))
    case "hdc.verifyProcessState":
      return .hdc(.verifyProcessState(try bundle()))
    case "hdc.stopAbility":
      return .hdc(.stopAbility(try ability()))
    case "hdc.uninstallPackage":
      return .hdc(.uninstallPackage(try bundle()))
    case "hdc.createPortForward":
      return .hdc(.createPortForward(try HDCPortForwardSpec(
        localPort: integer("localPort"), remotePort: integer("remotePort"))))
    case "hdc.removePortForward":
      return .hdc(.removePortForward(try HDCPortForwardSpec(
        localPort: integer("localPort"), remotePort: integer("remotePort"))))
    case "hdc.readPackagePresence":
      return .hdc(.readPackagePresence(try bundle()))
    case "hdc.readProcessPresence":
      return .hdc(.readProcessPresence(try bundle()))
    case "hdc.readOwnedPathPresence":
      return .hdc(.readOwnedPathPresence(try path()))
    case "hdc.readPortForwardPresence":
      return .hdc(.readPortForwardPresence(try HDCPortForwardSpec(
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
    case "rockchip.verifyBuild":
      return .rockchip(.verifyBuild(connectKey: try string("connectKey")))
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
public struct TypedProcessInvocation: Sendable, Equatable {
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

  package init(
    identifier: String,
    jobID: String,
    stepID: String,
    targetID: String,
    bindingRevision: Int,
    connectKey: String,
    expectedIdentitySHA256: String,
    providerExecutableSHA256: String,
    actionSHA256: String
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
  }
}

public struct TypedProcessPlan: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case process(executableSHA256: String, argumentSummary: [String], timeoutSeconds: Int?)
    case processSequence(executableSHA256: String, invocations: [TypedProcessInvocation])
    case hostManaged(HostManagedProcessDescriptor)
  }

  public let action: TypedProviderAction
  public let kind: Kind

  package init(action: TypedProviderAction, kind: Kind) {
    self.action = action
    self.kind = kind
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
    subprocesses: [ProviderSubprocessReceipt] = []
  ) {
    self.exitStatus = exitStatus
    self.stdout = stdout
    self.stderr = stderr
    self.stdoutTruncated = stdoutTruncated
    self.durationSeconds = durationSeconds
    self.hostManagedRecordID = hostManagedRecordID
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
  public let nowUTC: String
  public let resolvedInputArtifact: ProviderResolvedInputArtifact?

  public init(
    jobID: String,
    stepID: String,
    targetID: String,
    bindingRevision: Int?,
    connectKey: String? = nil,
    expectedIdentitySHA256: String? = nil,
    toolVersion: String? = nil,
    toolSHA256: String? = nil,
    nowUTC: String,
    resolvedInputArtifact: ProviderResolvedInputArtifact? = nil
  ) {
    self.jobID = jobID
    self.stepID = stepID
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.connectKey = connectKey
    self.expectedIdentitySHA256 = expectedIdentitySHA256
    self.toolVersion = toolVersion
    self.toolSHA256 = toolSHA256
    self.nowUTC = nowUTC
    self.resolvedInputArtifact = resolvedInputArtifact
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
  public let action: TypedProviderAction

  public init(jobID: String, stepID: String, intentEventID: String, action: TypedProviderAction) {
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

public protocol DeviceProvider: Sendable {
  var providerID: String { get }

  /// Catalog presence is only a description. A provider must separately
  /// publish whether its complete typed implementation is production-ready.
  func runtimeAvailability(
    for operation: CatalogOperationDescriptor
  ) -> ProviderOperationAvailability

  func resolveFacts(targetID: String) async throws -> ProviderFacts

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
}

extension DeviceProvider {
  public func runtimeAvailability(
    for operation: CatalogOperationDescriptor
  ) -> ProviderOperationAvailability {
    .unavailable(
      reason: "provider \(providerID) has not published runtime availability "
        + "for \(operation.reference)")
  }

  public func action(
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

  public init(providers: [any DeviceProvider]) {
    var table: [String: any DeviceProvider] = [:]
    for provider in providers {
      table[provider.providerID] = provider
    }
    self.providers = table
  }

  public func provider(id: String) -> (any DeviceProvider)? {
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
