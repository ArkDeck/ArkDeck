// Repository-managed workspace operation extension (CHG-2026-054, TASK-HTP-005).
//
// Runtime callers select only a project/preset and bounded typed inputs.
// Executable identities and complete argument arrays belong to the
// ProjectProfile. Patch paths come from resolved Artifact leases, are parsed
// and scope-checked before dispatch, and every successful write has an exact
// before/after readback record that can be reconciled or reverted.

import ArkDeckCore
import CryptoKit
import Foundation

public struct WorkspaceExecutableIdentity: Sendable, Equatable, Hashable, Codable {
  public let path: String
  public let sha256: String

  public init(path: String, sha256: String) throws {
    guard path.hasPrefix("/"), URL(filePath: path).standardizedFileURL.path == path else {
      throw DeviceProviderError.factsUnavailable(
        "workspace executable path must be canonical and absolute")
    }
    guard WorkspaceProviderSupport.isSHA256(sha256) else {
      throw DeviceProviderError.factsUnavailable(
        "workspace executable identity must be a lowercase SHA-256")
    }
    self.path = path
    self.sha256 = sha256
  }

  package static func hashing(path: String) throws -> WorkspaceExecutableIdentity {
    let canonical = URL(filePath: path).standardizedFileURL.path
    let bytes = try Data(contentsOf: URL(filePath: canonical))
    return try WorkspaceExecutableIdentity(
      path: canonical, sha256: WorkspaceProviderSupport.sha256(bytes))
  }
}

package struct WorkspaceCommandPreset: Sendable, Equatable {
  package let presetID: String
  public let executable: WorkspaceExecutableIdentity
  package let argumentZero: String?
  package let fixedArguments: [String]
  package let timeoutSeconds: Int

  public init(
    presetID: String,
    executable: WorkspaceExecutableIdentity,
    argumentZero: String? = nil,
    fixedArguments: [String],
    timeoutSeconds: Int
  ) throws {
    guard WorkspaceProviderSupport.isIdentifier(presetID) else {
      throw DeviceProviderError.factsUnavailable("workspace preset id is malformed")
    }
    guard (1...7_200).contains(timeoutSeconds) else {
      throw DeviceProviderError.factsUnavailable("workspace preset timeout is outside 1...7200")
    }
    guard
      argumentZero.map({
        !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 4_096
      }) ?? true,
      fixedArguments.count <= 128,
      fixedArguments.allSatisfy({
        !$0.contains("\0") && $0.utf8.count <= 4_096
      })
    else {
      throw DeviceProviderError.factsUnavailable("workspace preset arguments are not bounded")
    }
    self.presetID = presetID
    self.executable = executable
    self.argumentZero = argumentZero
    self.fixedArguments = fixedArguments
    self.timeoutSeconds = timeoutSeconds
  }
}

package enum WorkspaceProjectProfileKind: String, Sendable, Equatable {
  case primary
  case evolution
}

package struct WorkspaceProjectProfile: Sendable, Equatable {
  package let profileID: String
  package let projectRef: String
  package let projectRoot: String
  package let allowedFileGlobs: [String]
  package let inspectionPreset: WorkspaceCommandPreset
  /// Pinned source-control tool. Absent means the read-only git operations
  /// report unavailable rather than falling back to whatever `git` is on
  /// PATH (CHG-2026-055, TASK-HFA-008).
  package let sourceControlPreset: WorkspaceCommandPreset?
  /// Pinned reader for bounded source ranges. Absent means the operation is
  /// unavailable rather than falling back to reading files in-process.
  package let sourceReaderPreset: WorkspaceCommandPreset?
  /// Pinned archive writer for workspaces that are intentionally not Git
  /// checkouts. It can only seal exact, profile-scoped files into the
  /// provider-owned attempt store.
  package let archiveCheckpointPreset: WorkspaceCommandPreset?
  package let patchPreset: WorkspaceCommandPreset
  package let buildPresets: [String: WorkspaceCommandPreset]
  package let testPresets: [String: WorkspaceCommandPreset]
  package let symbolPresets: [String: WorkspaceCommandPreset]
  /// A build preset may declare one deployable product whose bytes are read
  /// back after a successful build.  The path belongs to repository-managed
  /// configuration, never to a model proposal or task input.
  package let buildProducts: [String: String]
  public let kind: WorkspaceProjectProfileKind

  public init(
    profileID: String,
    projectRef: String,
    projectRoot: String,
    allowedFileGlobs: [String],
    inspectionPreset: WorkspaceCommandPreset,
    sourceControlPreset: WorkspaceCommandPreset? = nil,
    sourceReaderPreset: WorkspaceCommandPreset? = nil,
    archiveCheckpointPreset: WorkspaceCommandPreset? = nil,
    patchPreset: WorkspaceCommandPreset,
    buildPresets: [String: WorkspaceCommandPreset],
    testPresets: [String: WorkspaceCommandPreset],
    symbolPresets: [String: WorkspaceCommandPreset],
    buildProducts: [String: String] = [:],
    kind: WorkspaceProjectProfileKind = .primary
  ) throws {
    let canonical = URL(filePath: projectRoot)
      .resolvingSymlinksInPath().standardizedFileURL.path
    var isDirectory: ObjCBool = false
    guard projectRoot.hasPrefix("/"),
      FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw DeviceProviderError.factsUnavailable(
        "workspace project root must be an existing canonical directory")
    }
    guard WorkspaceProviderSupport.isIdentifier(profileID),
      WorkspaceProviderSupport.isIdentifier(projectRef),
      !allowedFileGlobs.isEmpty,
      allowedFileGlobs.count <= 64,
      allowedFileGlobs.allSatisfy(WorkspaceProviderSupport.isSafeGlob),
      buildPresets.allSatisfy({ $0.key == $0.value.presetID }),
      testPresets.allSatisfy({ $0.key == $0.value.presetID }),
      symbolPresets.allSatisfy({ $0.key == $0.value.presetID }),
      buildProducts.keys.allSatisfy({ buildPresets[$0] != nil }),
      buildProducts.values.allSatisfy(WorkspaceProviderSupport.isSafeRelativePath)
    else {
      throw DeviceProviderError.factsUnavailable("workspace ProjectProfile is malformed")
    }
    self.profileID = profileID
    self.projectRef = projectRef
    self.projectRoot = canonical
    self.allowedFileGlobs = allowedFileGlobs
    self.inspectionPreset = inspectionPreset
    self.sourceControlPreset = sourceControlPreset
    self.sourceReaderPreset = sourceReaderPreset
    self.archiveCheckpointPreset = archiveCheckpointPreset
    self.patchPreset = patchPreset
    self.buildPresets = buildPresets
    self.testPresets = testPresets
    self.symbolPresets = symbolPresets
    self.buildProducts = buildProducts
    self.kind = kind
  }

  /// Built-in profile for this repository. An explicit root override is
  /// configuration, not authority; the closed preset vocabulary stays here.
  package static func arkDeck(rootURL: URL) throws -> WorkspaceProjectProfile {
    let root = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
    let grep = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/grep")
    let patch = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/patch")
    let sourceControl: WorkspaceCommandPreset?
    if FileManager.default.fileExists(
      atPath: URL(filePath: root).appending(path: ".git").path)
    {
      let git = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/git")
      sourceControl = try WorkspaceCommandPreset(
        presetID: "git", executable: git, fixedArguments: [], timeoutSeconds: 120)
    } else {
      sourceControl = nil
    }
    let swiftPackagePaths = [
      "/Applications/Xcode.app/Contents/Developer/Toolchains/"
        + "XcodeDefault.xctoolchain/usr/bin/swift-package",
      "/Library/Developer/CommandLineTools/usr/bin/swift-package",
    ]
    guard
      let swiftPackagePath = swiftPackagePaths.first(where: {
        FileManager.default.isExecutableFile(atPath: $0)
      })
    else {
      throw DeviceProviderError.factsUnavailable(
        "workspace.toolchainUnavailable: no fixed SwiftPM executable exists")
    }
    let swiftPackage = try WorkspaceExecutableIdentity.hashing(path: swiftPackagePath)
    let swiftBin = URL(filePath: swiftPackagePath).deletingLastPathComponent()
    let swiftBuildRole = swiftBin.appending(path: "swift-build").path
    let swiftTestRole = swiftBin.appending(path: "swift-test").path
    guard FileManager.default.fileExists(atPath: swiftBuildRole),
      FileManager.default.fileExists(atPath: swiftTestRole)
    else {
      throw DeviceProviderError.factsUnavailable(
        "workspace.toolchainUnavailable: SwiftPM role links are absent")
    }
    let inspection = try WorkspaceCommandPreset(
      presetID: "source-inspection", executable: grep,
      fixedArguments: [], timeoutSeconds: 30)
    let patching = try WorkspaceCommandPreset(
      presetID: "unified-diff", executable: patch,
      fixedArguments: [], timeoutSeconds: 120)
    let packagePath = URL(filePath: root)
      .appending(path: "Packages/ArkDeckKit").path
    guard
      FileManager.default.fileExists(
        atPath: URL(filePath: packagePath)
          .appending(path: "Package.swift").path)
    else {
      throw DeviceProviderError.factsUnavailable(
        "workspace.projectProfileUnavailable: ArkDeck Package.swift is absent")
    }
    let build = try WorkspaceCommandPreset(
      presetID: "arkdeck-debug", executable: swiftPackage,
      argumentZero: swiftBuildRole,
      fixedArguments: ["--package-path", packagePath],
      timeoutSeconds: 900)
    let tests = try WorkspaceCommandPreset(
      presetID: "arkdeck-tests", executable: swiftPackage,
      argumentZero: swiftTestRole,
      fixedArguments: [
        "--package-path", packagePath,
        // A daemon cannot safely run the contract that launches and
        // terminates another copy of its own composition-root binary. That
        // lifecycle test remains in CI/full developer runs; this preset
        // excludes only the self-termination shape.
        "--skip",
        "ArkDeckContractTests.AgentDaemonContractTests/"
          + "testDaemonBinaryStaysAliveAndServesRequests",
      ],
      timeoutSeconds: 900)
    return try WorkspaceProjectProfile(
      profileID: "workspace-host@1", projectRef: "ArkDeck",
      projectRoot: root,
      allowedFileGlobs: [
        "Packages/ArkDeckKit/**", "Catalog/**", "docs/**",
      ],
      inspectionPreset: inspection, sourceControlPreset: sourceControl,
      patchPreset: patching,
      buildPresets: [build.presetID: build],
      testPresets: [tests.presetID: tests],
      // No generic symbolizer is guessed. A profile without an exact symbol
      // preset publishes workspace.symbolize-crash as UNAVAILABLE.
      symbolPresets: [:])
  }

  /// Closed production profile for the real WaterFlow Golden Journey app.
  /// The project root is configured by the operator, but every tool, task,
  /// module, product and output path remains repository-owned vocabulary.
  package static func waterFlowDemo(
    rootURL: URL,
    projectRef: String = "demo-app",
    nodePath: String,
    hvigorScriptPath: String
  ) throws -> WorkspaceProjectProfile {
    let root = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    let protectedRoots = ["Desktop", "Documents", "Downloads"].map {
      home.appending(path: $0, directoryHint: .isDirectory).standardizedFileURL.path
    }
    guard
      !protectedRoots.contains(where: {
        root == $0 || root.hasPrefix($0 + "/")
      })
    else {
      throw DeviceProviderError.factsUnavailable(
        "workspace.projectProfileUnavailable: project root is under a "
          + "macOS privacy-managed user folder; configure a LaunchAgent-readable path")
    }
    let canonicalScript = URL(filePath: hvigorScriptPath)
      .resolvingSymlinksInPath().standardizedFileURL.path
    guard hvigorScriptPath.hasPrefix("/"),
      FileManager.default.fileExists(atPath: canonicalScript),
      FileManager.default.fileExists(
        atPath: URL(filePath: root).appending(path: "build-profile.json5").path),
      FileManager.default.fileExists(
        atPath: URL(filePath: root)
          .appending(path: "entry/src/main/module.json5").path)
    else {
      throw DeviceProviderError.factsUnavailable(
        "workspace.projectProfileUnavailable: WaterFlow project or Hvigor is absent")
    }
    let grep = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/grep")
    let sed = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/sed")
    let patch = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/patch")
    let tar = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/bsdtar")
    let node = try WorkspaceExecutableIdentity.hashing(path: nodePath)
    let inspection = try WorkspaceCommandPreset(
      presetID: "source-inspection", executable: grep,
      fixedArguments: [], timeoutSeconds: 30)
    let sourceReader = try WorkspaceCommandPreset(
      presetID: "source-range", executable: sed,
      fixedArguments: [], timeoutSeconds: 30)
    let patching = try WorkspaceCommandPreset(
      presetID: "unified-diff", executable: patch,
      fixedArguments: [], timeoutSeconds: 120)
    let checkpointing = try WorkspaceCommandPreset(
      presetID: "sealed-source-archive", executable: tar,
      fixedArguments: [], timeoutSeconds: 120)
    let commonHvigorArguments = [
      "--mode", "module",
      "-p", "module=entry@default",
      "-p", "product=default",
      "-p", "buildMode=debug",
      "--analyze=normal", "--parallel", "--incremental", "--no-daemon",
    ]
    let build = try WorkspaceCommandPreset(
      presetID: "waterflow-debug", executable: node,
      fixedArguments: [canonicalScript, "assembleHap"] + commonHvigorArguments,
      timeoutSeconds: 1_800)
    let tests = try WorkspaceCommandPreset(
      presetID: "waterflow-tests", executable: node,
      fixedArguments: [canonicalScript, "test"] + commonHvigorArguments,
      timeoutSeconds: 1_800)
    return try WorkspaceProjectProfile(
      profileID: "waterflow-openharmony@1", projectRef: projectRef,
      projectRoot: root,
      allowedFileGlobs: [
        "entry/src/main/ets/**", "entry/src/main/cpp/**",
        "entry/src/test/**", "entry/src/ohosTest/**",
      ],
      inspectionPreset: inspection, sourceReaderPreset: sourceReader,
      archiveCheckpointPreset: checkpointing,
      patchPreset: patching,
      buildPresets: [build.presetID: build],
      testPresets: [tests.presetID: tests],
      symbolPresets: [:],
      buildProducts: [
        build.presetID: "entry/build/default/outputs/default/entry-default-unsigned.hap"
      ])
  }

  fileprivate var executableIdentities: Set<WorkspaceExecutableIdentity> {
    var values: Set<WorkspaceExecutableIdentity> = [
      inspectionPreset.executable, patchPreset.executable,
    ]
    if let sourceControl = sourceControlPreset { values.insert(sourceControl.executable) }
    if let sourceReader = sourceReaderPreset { values.insert(sourceReader.executable) }
    if let archiveCheckpoint = archiveCheckpointPreset {
      values.insert(archiveCheckpoint.executable)
    }
    for preset in buildPresets.values { values.insert(preset.executable) }
    for preset in testPresets.values { values.insert(preset.executable) }
    for preset in symbolPresets.values { values.insert(preset.executable) }
    return values
  }
}

/// Thread-safe project identity registry shared by the existing Workspace
/// provider and repair adapter. Evolution registers isolated profiles here;
/// it does not create another provider, engine or daemon.
package final class WorkspaceProjectProfileRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var profilesByRef: [String: WorkspaceProjectProfile]

  public init(profiles: [WorkspaceProjectProfile]) throws {
    guard !profiles.isEmpty else {
      throw DeviceProviderError.factsUnavailable("workspace profile registry is empty")
    }
    var indexed: [String: WorkspaceProjectProfile] = [:]
    for profile in profiles {
      guard indexed[profile.projectRef] == nil else {
        throw DeviceProviderError.factsUnavailable(
          "duplicate workspace projectRef \(profile.projectRef)")
      }
      indexed[profile.projectRef] = profile
    }
    self.profilesByRef = indexed
  }

  public convenience init(profile: WorkspaceProjectProfile) {
    try! self.init(profiles: [profile])
  }

  public func profile(for projectRef: String) -> WorkspaceProjectProfile? {
    lock.withLock { profilesByRef[projectRef] }
  }

  package func register(_ profile: WorkspaceProjectProfile) throws {
    try lock.withLock {
      if let existing = profilesByRef[profile.projectRef] {
        guard existing == profile else {
          throw DeviceProviderError.factsUnavailable(
            "workspace projectRef already resolves to another profile")
        }
        return
      }
      profilesByRef[profile.projectRef] = profile
    }
  }

  package func profiles() -> [WorkspaceProjectProfile] {
    lock.withLock { profilesByRef.values.sorted { $0.projectRef < $1.projectRef } }
  }

  /// Removes a derived evolution profile once its isolated tree is destroyed,
  /// so a stale reference fails at resolution instead of mid-operation. The
  /// primary profile is not removable through this seam.
  package func unregisterEvolutionProfile(projectRef: String) {
    lock.withLock {
      guard profilesByRef[projectRef]?.kind == .evolution else { return }
      profilesByRef.removeValue(forKey: projectRef)
    }
  }
}

package struct UnavailableWorkspaceOperationsProvider: DeviceProvider {
  public let providerID = "workspace"
  private let reason: String

  public init(reason: String) {
    self.reason = reason
  }

  package func runtimeAvailability(
    for operation: CatalogOperationDescriptor
  ) -> ProviderOperationAvailability {
    .unavailable(reason: reason)
  }

  package func resolveFacts(targetID: String) async throws -> ProviderFacts {
    throw DeviceProviderError.factsUnavailable(reason)
  }

  package func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) throws -> TypedProviderAction {
    throw DeviceProviderError.factsUnavailable(reason)
  }

  package func lower(
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan {
    throw DeviceProviderError.factsUnavailable(reason)
  }

  package func verify(
    receipt: ProviderProcessReceipt,
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> ProviderSemanticOutcome {
    .unsupported(reason: reason)
  }

  public func reconcile(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) async throws -> ProviderReconcileOutcome {
    .stillUnknown(reason: reason)
  }
}

public struct WorkspaceResolvedInvocation: Sendable, Equatable, Codable {
  public let operation: String
  package let projectRef: String
  package let projectRoot: String
  package let presetID: String
  public let executable: WorkspaceExecutableIdentity
  package let argumentZero: String?
  public let arguments: [String]
  package let timeoutSeconds: Int
}

public struct WorkspaceFileSnapshot: Sendable, Equatable, Codable {
  package let relativePath: String
  public let sha256: String?
}

public struct WorkspacePatchIntent: Sendable, Equatable, Codable {
  package let invocation: WorkspaceResolvedInvocation
  package let patchAttemptRef: String
  package let patchArtifactID: String
  package let patchFilePath: String
  package let patchSHA256: String
  package let allowedFileGlobs: [String]
  public let before: [WorkspaceFileSnapshot]
  /// Evolution binds the patch to the complete policy-scoped tree rather
  /// than only the files the diff happens to touch.
  package let previousWorkspaceRevision: String?

  package init(
    invocation: WorkspaceResolvedInvocation,
    patchAttemptRef: String,
    patchArtifactID: String,
    patchFilePath: String,
    patchSHA256: String,
    allowedFileGlobs: [String],
    before: [WorkspaceFileSnapshot],
    previousWorkspaceRevision: String? = nil
  ) {
    self.invocation = invocation
    self.patchAttemptRef = patchAttemptRef
    self.patchArtifactID = patchArtifactID
    self.patchFilePath = patchFilePath
    self.patchSHA256 = patchSHA256
    self.allowedFileGlobs = allowedFileGlobs
    self.before = before
    self.previousWorkspaceRevision = previousWorkspaceRevision
  }
}

public struct WorkspaceArchiveCheckpointIntent: Sendable, Equatable, Codable {
  package let invocation: WorkspaceResolvedInvocation
  /// The path is derived from the runtime
  /// Job identity inside the provider-owned 0700 attempt store.
  package let archivePath: String
  package let sourceSnapshots: [WorkspaceFileSnapshot]

  package init(
    invocation: WorkspaceResolvedInvocation,
    archivePath: String,
    sourceSnapshots: [WorkspaceFileSnapshot]
  ) {
    self.invocation = invocation
    self.archivePath = archivePath
    self.sourceSnapshots = sourceSnapshots
  }
}

package struct WorkspacePatchAttempt: Sendable, Equatable, Codable {
  package let patchAttemptRef: String
  package let projectRef: String
  package let projectRoot: String
  package let patchArtifactID: String
  package let patchFilePath: String
  package let patchSHA256: String
  package let allowedFileGlobs: [String]
  public let before: [WorkspaceFileSnapshot]
  public let after: [WorkspaceFileSnapshot]
  package let workspaceRevisionBefore: String?
  package let workspaceRevisionAfter: String?
  package let appliedAtUTC: String
  package let revertedAtUTC: String?

  fileprivate func markingReverted(atUTC: String) -> WorkspacePatchAttempt {
    WorkspacePatchAttempt(
      patchAttemptRef: patchAttemptRef, projectRef: projectRef,
      projectRoot: projectRoot, patchArtifactID: patchArtifactID,
      patchFilePath: patchFilePath, patchSHA256: patchSHA256,
      allowedFileGlobs: allowedFileGlobs, before: before, after: after,
      workspaceRevisionBefore: workspaceRevisionBefore,
      workspaceRevisionAfter: workspaceRevisionAfter,
      appliedAtUTC: appliedAtUTC, revertedAtUTC: atUTC)
  }
}

public struct WorkspaceRevertIntent: Sendable, Equatable, Codable {
  package let invocation: WorkspaceResolvedInvocation
  package let attempt: WorkspacePatchAttempt
}

extension WorkspaceProviderAction {
  var operationInvocation: WorkspaceResolvedInvocation? {
    switch self {
    case .inspectSource, .prepareIsolatedCopy:
      return nil
    case .signOpenHarmonyHap:
      return nil
    case .buildOpenHarmony(let value), .runTests(let value),
      .symbolizeCrash(let value), .inspectGitStatus(let value), .inspectDiff(let value),
      .readSourceRange(let value), .createCheckpoint(let value):
      return value
    case .createArchiveCheckpoint(let value):
      return value.invocation
    case .applyPatch(let value):
      return value.invocation
    case .revertPatch(let value):
      return value.invocation
    }
  }
}

package final class WorkspacePatchAttemptStore: @unchecked Sendable {
  private let rootURL: URL
  private let lock = NSLock()

  public init(rootURL: URL) throws {
    self.rootURL = rootURL
    try FileManager.default.createDirectory(
      at: rootURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  public func load(_ reference: String) throws -> WorkspacePatchAttempt {
    try lock.withLock {
      try JSONDecoder().decode(
        WorkspacePatchAttempt.self, from: Data(contentsOf: url(for: reference)))
    }
  }

  public func save(_ attempt: WorkspacePatchAttempt) throws {
    try lock.withLock {
      let encoder = CanonicalJSONEncoders.canonicalPretty()
      let data = try encoder.encode(attempt)
      let destination = try url(for: attempt.patchAttemptRef)
      let temporary = rootURL.appending(
        path:
          ".\(attempt.patchAttemptRef).tmp.\(getpid())")
      try data.write(to: temporary, options: [])
      let handle = try FileHandle(forWritingTo: temporary)
      try handle.synchronize()
      try handle.close()
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: destination)
      }
    }
  }

  /// Copies the leased patch bytes into the provider-owned attempt store.
  /// Artifact leases may expire after the apply Job finishes; revert must
  /// remain possible from the durable patchAttemptRef alone.
  package func persistPatch(
    reference: String, sourceURL: URL, expectedSHA256: String
  ) throws -> String {
    try lock.withLock {
      let destination = try patchURL(for: reference)
      if FileManager.default.fileExists(atPath: destination.path) {
        let existing = try Data(contentsOf: destination)
        guard WorkspaceProviderSupport.sha256(existing) == expectedSHA256 else {
          throw DeviceProviderError.factsUnavailable(
            "workspace durable patch bytes do not match the attempt digest")
        }
        return destination.path
      }
      let bytes = try Data(contentsOf: sourceURL)
      guard WorkspaceProviderSupport.sha256(bytes) == expectedSHA256 else {
        throw DeviceProviderError.factsUnavailable(
          "workspace leased patch bytes changed before durable persistence")
      }
      let temporary = rootURL.appending(
        path:
          ".\(reference).patch.tmp.\(getpid())")
      try bytes.write(to: temporary, options: [])
      let handle = try FileHandle(forWritingTo: temporary)
      try handle.synchronize()
      try handle.close()
      try FileManager.default.moveItem(at: temporary, to: destination)
      return destination.path
    }
  }

  /// Returns a provider-owned destination for one Job's pre-patch source
  /// archive. Hashing the opaque Job id keeps it from becoming a path surface.
  package func checkpointArchiveURL(jobID: String) -> URL {
    let digest = WorkspaceProviderSupport.sha256(Data(jobID.utf8))
    return rootURL.appending(path: "checkpoint-\(digest).tar")
  }

  private func url(for reference: String) throws -> URL {
    try validate(reference)
    return rootURL.appending(path: "\(reference).json")
  }

  private func patchURL(for reference: String) throws -> URL {
    try validate(reference)
    return rootURL.appending(path: "\(reference).patch")
  }

  private func validate(_ reference: String) throws {
    guard reference.hasPrefix("patch-"), reference.count == 38,
      reference.dropFirst(6).allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    else {
      throw DeviceProviderError.unsupportedAction("workspace patch attempt ref is malformed")
    }
  }
}

/// Dispatcher resolver that accepts only executable identities in the same
/// ProjectProfile as the provider. The executor performs the final identity
/// check again atomically at spawn.
package struct WorkspaceActionExecutableResolver: RuntimeExecutableResolving {
  private let allowed: Set<WorkspaceExecutableIdentity>

  public init(profile: WorkspaceProjectProfile) {
    self.allowed = profile.executableIdentities
  }

  package func resolveExecutable(providerID: String) throws -> ResolvedExecutable {
    guard providerID == "workspace" else {
      throw RuntimeDispatchFailure.failed(
        "workspace resolver cannot serve provider \(providerID)")
    }
    for identity in allowed {
      _ = try validated(identity)
    }
    guard let first = allowed.sorted(by: { $0.path < $1.path }).first else {
      throw RuntimeDispatchFailure.failed("workspace profile has no executable presets")
    }
    return try validated(first)
  }

  package func resolveExecutable(for action: TypedProviderAction) throws -> ResolvedExecutable {
    guard case .workspace(let workspace) = action,
      let invocation = workspace.operationInvocation,
      allowed.contains(invocation.executable)
    else {
      throw RuntimeDispatchFailure.failed(
        "workspace action executable is not owned by the active ProjectProfile")
    }
    return try validated(invocation.executable)
  }

  private func validated(_ identity: WorkspaceExecutableIdentity) throws -> ResolvedExecutable {
    let bytes = try Data(contentsOf: URL(filePath: identity.path))
    guard WorkspaceProviderSupport.sha256(bytes) == identity.sha256 else {
      throw RuntimeDispatchFailure.failed(
        "workspace executable identity drifted: \(identity.path)")
    }
    return ResolvedExecutable(path: identity.path, sha256: identity.sha256)
  }
}

/// One dispatcher route serves both the TASK-HTP-007 inspector and the five
/// ProjectProfile operations. Selection is made only from the exact typed
/// action; callers cannot name an executable.
package struct CombinedWorkspaceExecutableResolver: RuntimeExecutableResolving {
  private let inspector: ResolvedExecutable?
  private let operations: WorkspaceActionExecutableResolver

  public init(
    inspector: ResolvedExecutable?,
    operations: WorkspaceActionExecutableResolver
  ) {
    self.inspector = inspector
    self.operations = operations
  }

  package func resolveExecutable(providerID: String) throws -> ResolvedExecutable {
    guard providerID == "workspace" else {
      throw RuntimeDispatchFailure.failed(
        "workspace resolver cannot serve provider \(providerID)")
    }
    return try operations.resolveExecutable(providerID: providerID)
  }

  package func resolveExecutable(for action: TypedProviderAction) throws -> ResolvedExecutable {
    guard case .workspace(let workspace) = action else {
      throw RuntimeDispatchFailure.failed(
        "workspace resolver received a foreign typed action")
    }
    if case .inspectSource = workspace {
      guard let inspector else {
        throw RuntimeDispatchFailure.failed(
          "no workspace inspector executable is configured")
      }
      return inspector
    }
    return try operations.resolveExecutable(for: action)
  }
}

package struct WorkspaceOperationsProvider: DeviceProvider {
  public let providerID = "workspace"
  private let profile: WorkspaceProjectProfile
  private let profileRegistry: WorkspaceProjectProfileRegistry
  private let attempts: WorkspacePatchAttemptStore
  private let signingPresets: OpenHarmonySigningPresetStore?
  private let signingAttempts: OpenHarmonySigningAttemptStore?
  private let isolationManager: (any WorkspaceIsolationManaging)?
  private let nowUTC: @Sendable () -> String

  public init(
    profile: WorkspaceProjectProfile,
    attemptStore: WorkspacePatchAttemptStore,
    signingPresetStore: OpenHarmonySigningPresetStore? = nil,
    signingAttemptStore: OpenHarmonySigningAttemptStore? = nil,
    isolationManager: (any WorkspaceIsolationManaging)? = nil,
    nowUTC: @escaping @Sendable () -> String
  ) {
    self.profile = profile
    self.profileRegistry = WorkspaceProjectProfileRegistry(profile: profile)
    self.attempts = attemptStore
    self.signingPresets = signingPresetStore
    self.signingAttempts = signingAttemptStore
    self.isolationManager = isolationManager
    self.nowUTC = nowUTC
  }

  public init(
    profile: WorkspaceProjectProfile,
    profileRegistry: WorkspaceProjectProfileRegistry,
    attemptStore: WorkspacePatchAttemptStore,
    signingPresetStore: OpenHarmonySigningPresetStore? = nil,
    signingAttemptStore: OpenHarmonySigningAttemptStore? = nil,
    isolationManager: (any WorkspaceIsolationManaging)? = nil,
    nowUTC: @escaping @Sendable () -> String
  ) {
    self.profile = profile
    self.profileRegistry = profileRegistry
    self.attempts = attemptStore
    self.signingPresets = signingPresetStore
    self.signingAttempts = signingAttemptStore
    self.isolationManager = isolationManager
    self.nowUTC = nowUTC
  }

  package func runtimeAvailability(
    for operation: CatalogOperationDescriptor
  ) -> ProviderOperationAvailability {
    guard operation.provider == .workspace else {
      return .unavailable(reason: "workspace.unsupportedProvider")
    }
    let hasPreset: Bool
    switch operation.reference {
    case "workspace.prepare-isolated-copy@1":
      hasPreset = isolationManager != nil && profile.kind == .primary
    case "workspace.apply-patch@1", "workspace.revert-patch@1":
      hasPreset = true
    case "workspace.build-openharmony@1":
      hasPreset = !profile.buildPresets.isEmpty
    case OpenHarmonyLocalSigning.operationReference:
      guard let signingPresets else {
        return .unavailable(reason: "workspace.signingPresetUnavailable")
      }
      let status = signingPresets.status()
      hasPreset = status.ready && status.projectRef == profile.projectRef
    case "workspace.run-tests@1":
      hasPreset = !profile.testPresets.isEmpty
    case "workspace.symbolize-crash@1":
      hasPreset = !profile.symbolPresets.isEmpty
    case "workspace.inspect-git-status@1", "workspace.inspect-diff@1":
      hasPreset = profile.sourceControlPreset != nil
    case "workspace.create-checkpoint@1":
      hasPreset = profile.sourceControlPreset != nil || profile.archiveCheckpointPreset != nil
    case "workspace.read-source-range@1":
      hasPreset = profile.sourceReaderPreset != nil
    default:
      return .unavailable(reason: "workspace.unsupportedOperation")
    }
    guard hasPreset else {
      return .unavailable(reason: "workspace.presetUnavailable")
    }
    do {
      for identity in profile.executableIdentities {
        let bytes = try Data(contentsOf: URL(filePath: identity.path))
        guard WorkspaceProviderSupport.sha256(bytes) == identity.sha256 else {
          return .unavailable(reason: "workspace.toolIdentityDrift")
        }
      }
      return .available
    } catch {
      return .unavailable(reason: "workspace.toolchainUnavailable")
    }
  }

  package func resolveFacts(targetID: String) async throws -> ProviderFacts {
    throw DeviceProviderError.factsUnavailable(
      "workspace provider is host-only: it has no device facts for \(targetID)")
  }

  /// The three facts a workspace-scoped capability is matched against
  /// (CHG-2026-055, TASK-HFA-009 r2). All are computed here, from files, at
  /// admission time — the engine cannot derive them and a stale value would
  /// be exactly the drift the grant exists to prevent.
  package func workspaceAuthorizationFacts(
    for operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) throws -> WorkspaceAuthorizationFacts? {
    guard operation.provider == .workspace else { return nil }
    if case .string(let requestedRef)? = inputs["projectRef"],
      requestedRef != profile.projectRef
    {
      guard let selected = profileRegistry.profile(for: requestedRef) else {
        throw DeviceProviderError.factsUnavailable(
          "workspace.projectProfileUnavailable:\(requestedRef)")
      }
      return try WorkspaceOperationsProvider(
        profile: selected, profileRegistry: profileRegistry,
        attemptStore: attempts, signingPresetStore: signingPresets,
        signingAttemptStore: signingAttempts, isolationManager: isolationManager,
        nowUTC: nowUTC
      ).workspaceAuthorizationFacts(for: operation, inputs: inputs)
    }
    return WorkspaceAuthorizationFacts(
      identitySHA256: WorkspaceProviderSupport.workspaceIdentity(
        root: profile.projectRoot, profileID: profile.profileID),
      revision: try WorkspaceProviderSupport.workspaceRevision(
        root: profile.projectRoot, profileVersion: profile.profileID,
        globs: profile.allowedFileGlobs),
      fileScopesDigest: WorkspaceProviderSupport.sha256(
        Data(profile.allowedFileGlobs.sorted().joined(separator: "\n").utf8)),
      isolatedTaskCopy: profile.kind == .evolution)
  }

  package func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) throws -> TypedProviderAction {
    throw DeviceProviderError.factsUnavailable(
      "workspace action materialization requires a job context")
  }

  package func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue],
    context: ProviderExecutionContext
  ) throws -> TypedProviderAction {
    let projectRef = try string("projectRef", in: inputs)
    if projectRef != profile.projectRef {
      guard let selected = profileRegistry.profile(for: projectRef) else {
        throw DeviceProviderError.unsupportedAction(
          "workspace.projectProfileUnavailable:\(projectRef)")
      }
      return try WorkspaceOperationsProvider(
        profile: selected, profileRegistry: profileRegistry,
        attemptStore: attempts, signingPresetStore: signingPresets,
        signingAttemptStore: signingAttempts, isolationManager: isolationManager,
        nowUTC: nowUTC
      ).action(for: step, operation: operation, inputs: inputs, context: context)
    }
    guard projectRef == profile.projectRef else {
      throw DeviceProviderError.unsupportedAction(
        "workspace.projectProfileUnavailable:\(projectRef)")
    }
    // Exact base revision (CHG-2026-055, TASK-HFA-009). A caller that states
    // which tree it decided against gets that statement enforced: if the tree
    // moved between the decision and this materialization, the change is
    // refused rather than applied to a workspace nobody looked at.
    //
    // One workspace revision, computed one way, everywhere. `create-checkpoint`
    // used to compare against a digest of just `checkpointFilePaths`, which no
    // caller can produce: the harness states the revision it planned against,
    // and that is the profile-scoped workspace revision the authorization
    // facts, the issued capability's scope and `apply-patch` all speak. The two
    // digests could only agree by accident, so the checkpoint leg refused every
    // request that reached it and the repair route could never get past it.
    //
    // Comparing the profile-scoped revision is also the stricter of the two:
    // the checkpoint's own paths must already lie inside the profile globs, so
    // this sees every change the narrow digest saw, plus drift elsewhere in the
    // declared scope that the narrow digest was blind to.
    if case .string(let declared)? = inputs["expectedWorkspaceRevision"] {
      let actual = try WorkspaceProviderSupport.workspaceRevision(
        root: profile.projectRoot, profileVersion: profile.profileID,
        globs: profile.allowedFileGlobs)
      guard actual == declared else {
        throw DeviceProviderError.unsupportedAction(
          "workspace.revisionConflict:\(declared.prefix(12))!=\(actual.prefix(12))")
      }
    }
    switch (operation.reference, step.kind) {
    case ("workspace.prepare-isolated-copy@1", .prepareWorkspaceIsolation):
      guard profile.kind == .primary, isolationManager != nil else {
        throw DeviceProviderError.unsupportedAction(
          "workspace.isolationManagerUnavailable")
      }
      let requestGlobs = try stringArray("allowedFileGlobs", in: inputs)
      guard !requestGlobs.isEmpty,
        requestGlobs.allSatisfy({ requested in
          profile.allowedFileGlobs.contains(where: {
            WorkspaceProviderSupport.isNarrower(requested, than: $0)
          })
        })
      else {
        throw DeviceProviderError.unsupportedAction(
          "workspace.isolationScopeOutsideProjectProfile")
      }
      let revision = try string("expectedWorkspaceRevision", in: inputs)
      let isolatedRevision = try WorkspaceProviderSupport.workspaceRevision(
        root: profile.projectRoot, profileVersion: profile.profileID,
        globs: requestGlobs)
      return .workspace(
        .prepareIsolatedCopy(
          WorkspaceIsolationIntent(
            runtimeOwnerID: "runtime-\(context.jobID)",
            sourceProjectRef: projectRef,
            expectedWorkspaceRevision: revision,
            isolatedWorkspaceRevision: isolatedRevision,
            createdAtUTC: context.nowUTC,
            allowedFileGlobs: requestGlobs)))

    case ("workspace.apply-patch@1", .applyWorkspacePatch):
      guard let artifact = context.resolvedInputArtifact else {
        throw DeviceProviderError.unsupportedAction(
          "workspace patch Artifact lease was not resolved before materialization")
      }
      let requestGlobs = try stringArray("allowedFileGlobs", in: inputs)
      let patch = try Data(contentsOf: artifact.fileURL)
      guard patch.count == artifact.byteCount,
        patch.count <= 4 * 1024 * 1024,
        WorkspaceProviderSupport.sha256(patch) == artifact.sha256
      else {
        throw DeviceProviderError.unsupportedAction(
          "workspace patch Artifact bytes do not match their lease")
      }
      let paths = try WorkspaceProviderSupport.patchPaths(from: patch)
      try WorkspaceProviderSupport.validate(
        relativePaths: paths, root: profile.projectRoot,
        profileGlobs: profile.allowedFileGlobs, requestGlobs: requestGlobs)
      let before = try WorkspaceProviderSupport.snapshots(
        relativePaths: paths, root: profile.projectRoot)
      let attemptDigest = WorkspaceProviderSupport.sha256(
        Data("\(context.jobID)\n\(artifact.sha256)\n\(projectRef)".utf8))
      let reference = "patch-\(attemptDigest.prefix(32))"
      let arguments =
        profile.patchPreset.fixedArguments
        + ["-f", "-p1", "-d", profile.projectRoot, "-i", artifact.fileURL.path]
      let invocation = resolved(
        operation: operation.reference, preset: profile.patchPreset,
        arguments: arguments)
      return .workspace(
        .applyPatch(
          WorkspacePatchIntent(
            invocation: invocation, patchAttemptRef: reference,
            patchArtifactID: artifact.artifactID,
            patchFilePath: artifact.fileURL.path,
            patchSHA256: artifact.sha256, allowedFileGlobs: requestGlobs,
            before: before,
            previousWorkspaceRevision: profile.kind == .evolution
              ? try string("expectedWorkspaceRevision", in: inputs) : nil)))

    case ("workspace.build-openharmony@1", .buildWorkspaceOpenHarmony):
      let presetID = try string("buildPresetRef", in: inputs)
      guard let preset = profile.buildPresets[presetID] else {
        throw DeviceProviderError.unsupportedAction(
          "workspace.buildPresetUnavailable:\(presetID)")
      }
      return .workspace(
        .buildOpenHarmony(
          resolved(
            operation: operation.reference, preset: preset,
            arguments: preset.fixedArguments)))

    case (OpenHarmonyLocalSigning.operationReference, .signWorkspaceOpenHarmonyHap):
      guard let artifact = context.resolvedInputArtifact else {
        throw DeviceProviderError.unsupportedAction(
          "workspace unsigned HAP Artifact lease was not resolved before materialization")
      }
      let presetID = try string("signingPresetRef", in: inputs)
      guard let signingPresets, let signingAttempts else {
        throw DeviceProviderError.unsupportedAction("workspace.signingPresetUnavailable")
      }
      let preset: OpenHarmonySigningPresetReceipt
      do {
        preset = try signingPresets.loadValidated(presetID: presetID)
      } catch {
        throw DeviceProviderError.unsupportedAction(
          "workspace.signingPresetUnavailable:\(error)")
      }
      guard preset.projectRef == projectRef else {
        throw DeviceProviderError.unsupportedAction(
          "workspace.signingPresetProjectMismatch")
      }
      let handle = try FileHandle(forReadingFrom: artifact.fileURL)
      defer { try? handle.close() }
      let bytes = try handle.read(upToCount: 4)
      guard artifact.byteCount > 0, artifact.byteCount <= 64 * 1_024 * 1_024,
        bytes == Data([0x50, 0x4b, 0x03, 0x04])
      else {
        throw DeviceProviderError.unsupportedAction(
          "workspace unsigned HAP is not a bounded ZIP container")
      }
      return .workspace(
        .signOpenHarmonyHap(
          WorkspaceOpenHarmonySigningAction(
            jobID: context.jobID, projectRef: projectRef, preset: preset,
            inputArtifactID: artifact.artifactID,
            inputFilePath: artifact.fileURL.path,
            inputSHA256: artifact.sha256, inputByteCount: artifact.byteCount,
            output: signingAttempts.paths(jobID: context.jobID))))

    case ("workspace.run-tests@1", .runWorkspaceTests):
      let presetID = try string("testPresetRef", in: inputs)
      guard let preset = profile.testPresets[presetID] else {
        throw DeviceProviderError.unsupportedAction(
          "workspace.testPresetUnavailable:\(presetID)")
      }
      return .workspace(
        .runTests(
          resolved(
            operation: operation.reference, preset: preset,
            arguments: preset.fixedArguments)))

    case ("workspace.symbolize-crash@1", .symbolizeWorkspaceCrash):
      guard let artifact = context.resolvedInputArtifact else {
        throw DeviceProviderError.unsupportedAction(
          "workspace crash Artifact lease was not resolved before materialization")
      }
      let presetID = try string("symbolPresetRef", in: inputs)
      guard let preset = profile.symbolPresets[presetID] else {
        throw DeviceProviderError.unsupportedAction(
          "workspace.symbolPresetUnavailable:\(presetID)")
      }
      return .workspace(
        .symbolizeCrash(
          resolved(
            operation: operation.reference, preset: preset,
            arguments: preset.fixedArguments + [artifact.fileURL.path])))

    case ("workspace.inspect-git-status@1", .inspectWorkspaceGitStatus):
      guard let preset = profile.sourceControlPreset else {
        throw DeviceProviderError.unsupportedAction("workspace.sourceControlPresetUnavailable")
      }
      // `-C <root>` first: git runs in the root this provider resolved, so
      // no input can move it elsewhere.
      return .workspace(
        .inspectGitStatus(
          resolved(
            operation: operation.reference, preset: preset,
            arguments: preset.fixedArguments
              + ["-C", profile.projectRoot, "status", "--porcelain=v1", "--untracked-files=all"])))

    case ("workspace.inspect-diff@1", .inspectWorkspaceDiff):
      guard let preset = profile.sourceControlPreset else {
        throw DeviceProviderError.unsupportedAction("workspace.sourceControlPresetUnavailable")
      }
      let baseRevision = try string("baseRevision", in: inputs)
      let pathScope = try string("pathScope", in: inputs)
      try WorkspaceProviderSupport.validateRevisionExpression(baseRevision)
      try WorkspaceProviderSupport.validatePathScope(pathScope)
      // `--` terminates options, so neither value can become a flag, and the
      // pathspec is relative to the root git was pointed at.
      return .workspace(
        .inspectDiff(
          resolved(
            operation: operation.reference, preset: preset,
            arguments: preset.fixedArguments
              + ["-C", profile.projectRoot, "diff", "--stat", baseRevision, "--", pathScope])))

    case ("workspace.read-source-range@1", .readWorkspaceSourceRange):
      guard let preset = profile.sourceReaderPreset else {
        throw DeviceProviderError.unsupportedAction("workspace.sourceReaderPresetUnavailable")
      }
      let filePath = try string("filePath", in: inputs)
      let start = try integer("lineStart", in: inputs)
      let end = try integer("lineEnd", in: inputs)
      guard start >= 1, end >= start, end - start < 2000 else {
        // An unbounded range is how a "read" becomes "ship the repository":
        // the span is part of the contract, not a caller's discretion.
        throw DeviceProviderError.unsupportedAction("workspace.malformedLineRange")
      }
      // The path is resolved against the root this provider owns and checked
      // against the ProjectProfile globs, so a caller cannot address a file
      // the profile never declared.
      let resolvedPath = try WorkspaceProviderSupport.resolvedReadablePath(
        filePath, root: profile.projectRoot, profileGlobs: profile.allowedFileGlobs)
      return .workspace(
        .readSourceRange(
          resolved(
            operation: operation.reference, preset: preset,
            arguments: preset.fixedArguments + ["-n", "\(start),\(end)p", resolvedPath])))

    case ("workspace.create-checkpoint@1", .createWorkspaceCheckpoint):
      if let preset = profile.sourceControlPreset {
        // `stash create` writes a commit object and moves nothing - no ref,
        // index or worktree - so a Git checkpoint cannot disturb the tree.
        return .workspace(
          .createCheckpoint(
            resolved(
              operation: operation.reference, preset: preset,
              arguments: preset.fixedArguments
                + ["-C", profile.projectRoot, "stash", "create"])))
      }
      guard let preset = profile.archiveCheckpointPreset else {
        throw DeviceProviderError.unsupportedAction("workspace.checkpointPresetUnavailable")
      }
      let paths = try stringArray("checkpointFilePaths", in: inputs)
      try WorkspaceProviderSupport.validate(
        relativePaths: paths, root: profile.projectRoot,
        profileGlobs: profile.allowedFileGlobs, requestGlobs: paths)
      let snapshots = try WorkspaceProviderSupport.snapshots(
        relativePaths: paths, root: profile.projectRoot)
      guard snapshots.allSatisfy({ $0.sha256 != nil }) else {
        throw DeviceProviderError.unsupportedAction(
          "workspace checkpoint cannot seal a missing source file")
      }
      try WorkspaceProviderSupport.requireBoundedCheckpointSources(
        relativePaths: paths, root: profile.projectRoot)
      let archiveURL = attempts.checkpointArchiveURL(jobID: context.jobID)
      guard !FileManager.default.fileExists(atPath: archiveURL.path) else {
        throw DeviceProviderError.unsupportedAction(
          "workspace checkpoint destination already exists")
      }
      // bsdtar receives only provider-owned paths and exact profile-scoped
      // files. `--` ensures no relative source name can become an option.
      return .workspace(
        .createArchiveCheckpoint(
          WorkspaceArchiveCheckpointIntent(
            invocation: resolved(
              operation: operation.reference, preset: preset,
              arguments: preset.fixedArguments
                + ["-c", "-f", archiveURL.path, "-C", profile.projectRoot, "--"]
                + paths.sorted()),
            archivePath: archiveURL.path,
            sourceSnapshots: snapshots)))

    case ("workspace.revert-patch@1", .revertWorkspacePatch):
      let reference = try string("patchAttemptRef", in: inputs)
      let attempt = try attempts.load(reference)
      guard attempt.projectRef == profile.projectRef,
        attempt.projectRoot == profile.projectRoot,
        attempt.revertedAtUTC == nil
      else {
        throw DeviceProviderError.unsupportedAction(
          "workspace patch attempt is not active in this ProjectProfile")
      }
      let bytes = try Data(contentsOf: URL(filePath: attempt.patchFilePath))
      guard WorkspaceProviderSupport.sha256(bytes) == attempt.patchSHA256 else {
        throw DeviceProviderError.unsupportedAction(
          "workspace original patch bytes are unavailable or changed")
      }
      let arguments =
        profile.patchPreset.fixedArguments
        + [
          "-f", "-R", "-p1", "-d", profile.projectRoot,
          "-i", attempt.patchFilePath,
        ]
      let invocation = resolved(
        operation: operation.reference, preset: profile.patchPreset,
        arguments: arguments)
      return .workspace(
        .revertPatch(WorkspaceRevertIntent(invocation: invocation, attempt: attempt)))

    default:
      throw DeviceProviderError.unsupportedStepKind(
        "\(operation.reference)/\(step.kind.rawValue)")
    }
  }

  package func lower(
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan {
    if case .workspace(.prepareIsolatedCopy(let isolation)) = action {
      guard isolationManager != nil,
        isolation.runtimeOwnerID == "runtime-\(context.jobID)"
      else {
        throw DeviceProviderError.unsupportedAction(
          "workspace isolation action is not owned by this Job")
      }
      return TypedProcessPlan(
        action: action,
        kind: .hostWorkspace(
          HostWorkspaceProcessDescriptor(
            identifier: "workspace.prepare-isolated-copy/v1",
            jobID: context.jobID, stepID: context.stepID,
            actionSHA256: isolation.actionSHA256)))
    }
    if case .workspace(.signOpenHarmonyHap(let signing)) = action {
      guard signing.output == signingAttempts?.paths(jobID: context.jobID),
        signing.jobID == context.jobID,
        signing.projectRef == profile.projectRef
      else {
        throw DeviceProviderError.unsupportedAction(
          "workspace signing action is not owned by this Job/Profile")
      }
      try OpenHarmonySigningPresetStore.remeasureForDispatch(signing.preset)
      return TypedProcessPlan(
        action: action,
        kind: .process(
          executableSHA256: signing.preset.javaExecutable.sha256,
          argumentSummary: signing.signArguments,
          timeoutSeconds: 600),
        workingDirectory: signing.output.directory)
    }
    if case .workspace(let workspace) = action,
      let invocation = workspace.operationInvocation,
      invocation.projectRef != profile.projectRef
    {
      guard let selected = profileRegistry.profile(for: invocation.projectRef) else {
        throw DeviceProviderError.unsupportedAction(
          "workspace.projectProfileUnavailable:\(invocation.projectRef)")
      }
      return try WorkspaceOperationsProvider(
        profile: selected, profileRegistry: profileRegistry,
        attemptStore: attempts, signingPresetStore: signingPresets,
        signingAttemptStore: signingAttempts, isolationManager: isolationManager,
        nowUTC: nowUTC
      ).lower(action: action, context: context)
    }
    guard case .workspace(let workspace) = action,
      let invocation = workspace.operationInvocation,
      profile.executableIdentities.contains(invocation.executable)
    else {
      throw DeviceProviderError.unsupportedAction(
        "workspace provider received a foreign action or executable")
    }
    switch workspace {
    case .applyPatch(let intent):
      try WorkspaceProviderSupport.require(
        snapshots: intent.before, root: profile.projectRoot)
    case .createArchiveCheckpoint(let intent):
      guard intent.archivePath == attempts.checkpointArchiveURL(jobID: context.jobID).path,
        !FileManager.default.fileExists(atPath: intent.archivePath)
      else {
        throw DeviceProviderError.unsupportedAction(
          "workspace checkpoint destination is not fresh and provider-owned")
      }
      try WorkspaceProviderSupport.require(
        snapshots: intent.sourceSnapshots, root: profile.projectRoot)
    case .revertPatch(let intent):
      try WorkspaceProviderSupport.require(
        snapshots: intent.attempt.after, root: profile.projectRoot)
    default:
      break
    }
    let hostLanding: HostLandingExpectation?
    if profile.kind == .evolution,
      case .buildOpenHarmony(let build) = workspace,
      let relativeProduct = profile.buildProducts[build.presetID]
    {
      hostLanding = HostLandingExpectation(
        destination: URL(filePath: profile.projectRoot).appending(path: relativeProduct),
        maximumBytes: 64 * 1_024 * 1_024)
    } else {
      hostLanding = nil
    }
    return TypedProcessPlan(
      action: action,
      kind: .process(
        executableSHA256: invocation.executable.sha256,
        argumentSummary: invocation.arguments,
        timeoutSeconds: invocation.timeoutSeconds),
      argumentZero: invocation.argumentZero,
      workingDirectory: invocation.projectRoot,
      hostLanding: hostLanding)
  }

  package func verify(
    receipt: ProviderProcessReceipt,
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> ProviderSemanticOutcome {
    if case .workspace(.prepareIsolatedCopy(let isolation)) = action {
      guard receipt.exitStatus == 0, !receipt.stdoutTruncated,
        receipt.hostManagedRecordID == isolation.workspaceID,
        receipt.hostManagedSummary["projectRef"] == isolation.workspaceProjectRef,
        receipt.hostManagedSummary["workspaceRevision"]
          == isolation.isolatedWorkspaceRevision,
        receipt.hostManagedSummary["sourceWorkspaceRevision"]
          == isolation.expectedWorkspaceRevision
      else {
        return .failed(
          code: "workspace.isolationReceiptInvalid",
          detail: "isolated workspace receipt is absent or disagrees with the typed action")
      }
      guard let isolationManager else {
        return .failed(
          code: "workspace.isolationManagerUnavailable",
          detail: "isolated workspace lifecycle is unavailable")
      }
      switch try isolationManager.inspect(isolation) {
      case .prepared(let prepared) where prepared.summary == receipt.hostManagedSummary:
        return .verified(summary: prepared.summary)
      case .absent:
        return .failed(
          code: "workspace.isolationReadbackAbsent",
          detail: "isolated workspace was not durable after preparation")
      case .prepared, .conflicted:
        return .failed(
          code: "workspace.isolationReadbackDrifted",
          detail: "isolated workspace manifest or copied revision drifted")
      }
    }
    if case .workspace(.signOpenHarmonyHap(let signing)) = action {
      guard receipt.exitStatus == 0, !receipt.stdoutTruncated,
        receipt.hostManagedRecordID == signing.output.resultRecord,
        let landed = receipt.landedArtifact, let landedSHA = landed.sha256
      else {
        return .failed(
          code: "workspace.signingPostflightMissing",
          detail: "signing receipt has no exact verified output")
      }
      do {
        let durable = try OpenHarmonySigningWorkspaceDispatcher.readVerifiedResult(
          action: signing)
        guard durable == receipt.hostManagedSummary,
          durable["signedHapSha256"] == landedSHA,
          durable["signedHapByteCount"] == String(landed.byteCount)
        else {
          return .failed(
            code: "workspace.signingPostflightDrift",
            detail: "signing result, output and process receipt disagree")
        }
        return .verified(summary: durable)
      } catch {
        return .failed(
          code: "workspace.signingPostflightInvalid", detail: "\(error)")
      }
    }
    if case .workspace(let workspace) = action,
      let invocation = workspace.operationInvocation,
      invocation.projectRef != profile.projectRef
    {
      guard let selected = profileRegistry.profile(for: invocation.projectRef) else {
        return .unsupported(
          reason: "workspace.projectProfileUnavailable:\(invocation.projectRef)")
      }
      return try WorkspaceOperationsProvider(
        profile: selected, profileRegistry: profileRegistry,
        attemptStore: attempts, signingPresetStore: signingPresets,
        signingAttemptStore: signingAttempts, isolationManager: isolationManager,
        nowUTC: nowUTC
      ).verify(receipt: receipt, action: action, context: context)
    }
    guard case .workspace(let workspace) = action else {
      return .unsupported(reason: "workspace provider received a foreign action")
    }
    guard !receipt.stdoutTruncated else {
      return .failed(
        code: "workspace.outputTruncated",
        detail: "bounded output was truncated; semantic result is incomplete")
    }
    switch workspace {
    case .signOpenHarmonyHap:
      return .failed(
        code: "workspace.signingRoutingFailed",
        detail: "signing verification did not use the closed signing receipt")
    case .inspectSource:
      return .unsupported(reason: "inspection belongs to TASK-HTP-007 provider path")
    case .inspectGitStatus:
      guard receipt.exitStatus == 0 else {
        return failed("workspace.gitStatusFailed", receipt)
      }
      // A clean tree prints nothing. That is an observation, not a failure -
      // the evaluator has to be able to tell "no local changes" from
      // "the read broke".
      var statusSummary = outputSummary(receipt)
      statusSummary["dirty"] = receipt.stdout.isEmpty ? "false" : "true"
      return .verified(summary: statusSummary)
    case .inspectDiff:
      guard receipt.exitStatus == 0 else {
        return failed("workspace.diffFailed", receipt)
      }
      var diffSummary = outputSummary(receipt)
      diffSummary["changed"] = receipt.stdout.isEmpty ? "false" : "true"
      return .verified(summary: diffSummary)
    case .readSourceRange:
      guard receipt.exitStatus == 0 else {
        return failed("workspace.sourceRangeFailed", receipt)
      }
      var rangeSummary = outputSummary(receipt)
      rangeSummary["empty"] = receipt.stdout.isEmpty ? "true" : "false"
      return .verified(summary: rangeSummary)
    case .createCheckpoint:
      // No object id on stdout means no checkpoint exists, and calling that
      // success would let the repair leg believe it can roll back.
      guard receipt.exitStatus == 0 else {
        return failed("workspace.checkpointFailed", receipt)
      }
      let oid = String(decoding: receipt.stdout, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard oid.count == 40, oid.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
      else {
        return .failed(
          code: "workspace.checkpointEmpty",
          detail: "git produced no checkpoint object for this workspace")
      }
      var checkpointSummary = outputSummary(receipt)
      checkpointSummary["checkpointObject"] = oid
      checkpointSummary["checkpointKind"] = "gitObject"
      return .verified(summary: checkpointSummary)
    case .createArchiveCheckpoint(let intent):
      guard receipt.exitStatus == 0 else {
        return failed("workspace.checkpointFailed", receipt)
      }
      guard intent.archivePath == attempts.checkpointArchiveURL(jobID: context.jobID).path
      else {
        return .failed(
          code: "workspace.checkpointReadbackFailed",
          detail: "checkpoint archive path is not provider-owned")
      }
      let archiveURL = URL(filePath: intent.archivePath)
      let evidence: (byteCount: Int, sha256: String)
      do {
        let handle = try FileHandle(forWritingTo: archiveURL)
        try handle.synchronize()
        try handle.close()
        evidence = try WorkspaceProviderSupport.sealedArchiveEvidence(at: archiveURL)
      } catch {
        return .failed(
          code: "workspace.checkpointReadbackFailed",
          detail: "checkpoint archive is absent, unsafe, incomplete or oversized: \(error)")
      }
      do {
        try WorkspaceProviderSupport.require(
          snapshots: intent.sourceSnapshots, root: profile.projectRoot)
      } catch {
        return .failed(
          code: "workspace.checkpointSourceDrift",
          detail: "declared source changed while the checkpoint was written: \(error)")
      }
      var checkpointSummary = outputSummary(receipt)
      checkpointSummary["checkpointObject"] = evidence.sha256
      checkpointSummary["checkpointKind"] = "sealedArchive"
      checkpointSummary["checkpointByteCount"] = String(evidence.byteCount)
      return .verified(summary: checkpointSummary)
    case .prepareIsolatedCopy:
      return .failed(
        code: "workspace.isolationRoutingFailed",
        detail: "isolated workspace verification did not use its typed route")
    case .buildOpenHarmony(let invocation):
      guard receipt.exitStatus == 0 else {
        return failed("workspace.buildFailed", receipt)
      }
      var summary = outputSummary(receipt)
      if profile.kind == .evolution, profile.buildProducts[invocation.presetID] != nil {
        guard let landed = receipt.landedArtifact,
          let sha256 = landed.sha256,
          landed.byteCount > 0,
          landed.leadingBytes.starts(with: [0x50, 0x4b, 0x03, 0x04])
        else {
          return .failed(
            code: "workspace.buildProductMissing",
            detail: "build succeeded without its declared bounded HAP product")
        }
        summary["unsignedHapSha256"] = sha256
        summary["unsignedHapByteCount"] = String(landed.byteCount)
      }
      return .verified(summary: summary)
    case .runTests:
      guard receipt.exitStatus == 0 else {
        return failed("workspace.testsFailed", receipt)
      }
      return .verified(summary: outputSummary(receipt))
    case .symbolizeCrash:
      guard receipt.exitStatus == 0, !receipt.stdout.isEmpty else {
        return failed("workspace.symbolizationFailed", receipt)
      }
      return .verified(summary: outputSummary(receipt))
    case .applyPatch(let intent):
      guard receipt.exitStatus == 0 else {
        return failed("workspace.patchFailed", receipt)
      }
      let after = try WorkspaceProviderSupport.snapshots(
        relativePaths: intent.before.map(\.relativePath), root: profile.projectRoot)
      guard after != intent.before else {
        return .failed(
          code: "workspace.patchReadbackFailed",
          detail: "patch reported success but no declared file changed")
      }
      let durablePatchPath = try attempts.persistPatch(
        reference: intent.patchAttemptRef,
        sourceURL: URL(filePath: intent.patchFilePath),
        expectedSHA256: intent.patchSHA256)
      let workspaceRevisionAfter =
        profile.kind == .evolution
        ? try WorkspaceProviderSupport.workspaceRevision(
          root: profile.projectRoot, profileVersion: profile.profileID,
          globs: profile.allowedFileGlobs)
        : nil
      let attempt = WorkspacePatchAttempt(
        patchAttemptRef: intent.patchAttemptRef,
        projectRef: profile.projectRef, projectRoot: profile.projectRoot,
        patchArtifactID: intent.patchArtifactID,
        patchFilePath: durablePatchPath, patchSHA256: intent.patchSHA256,
        allowedFileGlobs: intent.allowedFileGlobs,
        before: intent.before, after: after,
        workspaceRevisionBefore: intent.previousWorkspaceRevision,
        workspaceRevisionAfter: workspaceRevisionAfter,
        appliedAtUTC: context.nowUTC, revertedAtUTC: nil)
      try attempts.save(attempt)
      var summary = outputSummary(receipt)
      summary["patchAttemptRef"] = intent.patchAttemptRef
      summary["workspaceRevision"] =
        workspaceRevisionAfter
        ?? WorkspaceProviderSupport.revision(after)
      summary["previousWorkspaceRevision"] =
        intent.previousWorkspaceRevision
        ?? WorkspaceProviderSupport.revision(intent.before)
      summary["touchedFiles"] = after.map(\.relativePath).joined(separator: ",")
      return .verified(summary: summary)
    case .revertPatch(let intent):
      guard receipt.exitStatus == 0 else {
        return failed("workspace.revertFailed", receipt)
      }
      do {
        try WorkspaceProviderSupport.require(
          snapshots: intent.attempt.before, root: profile.projectRoot)
      } catch {
        return .failed(
          code: "workspace.revertReadbackFailed",
          detail: "workspace did not return to the exact original revision: \(error)")
      }
      try attempts.save(intent.attempt.markingReverted(atUTC: context.nowUTC))
      var summary = outputSummary(receipt)
      summary["patchAttemptRef"] = intent.attempt.patchAttemptRef
      summary["workspaceRevision"] =
        intent.attempt.workspaceRevisionBefore
        ?? WorkspaceProviderSupport.revision(intent.attempt.before)
      return .verified(summary: summary)
    }
  }

  public func reconcile(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) async throws -> ProviderReconcileOutcome {
    if case .workspace(.prepareIsolatedCopy(let isolation)) = intent.action {
      guard let isolationManager else {
        return .stillUnknown(reason: "workspace isolation lifecycle is unavailable")
      }
      switch try isolationManager.inspect(isolation) {
      case .absent:
        return .confirmedNotExecuted
      case .prepared(let prepared):
        return .confirmedCompleted(summary: prepared.summary)
      case .conflicted(let reason):
        return .stillUnknown(reason: reason)
      }
    }
    if case .workspace(.signOpenHarmonyHap(let signing)) = intent.action {
      let hasOutput = FileManager.default.fileExists(atPath: signing.output.signedHAP)
      let hasResult = FileManager.default.fileExists(atPath: signing.output.resultRecord)
      if !hasOutput, !hasResult { return .confirmedNotExecuted }
      guard hasOutput else {
        return .stillUnknown(reason: "signing result exists without its exact output")
      }
      do {
        let summary: [String: String]
        if hasResult {
          summary = try OpenHarmonySigningWorkspaceDispatcher.readVerifiedResult(
            action: signing)
        } else {
          summary = try await OpenHarmonySigningWorkspaceDispatcher.verifyAndRecord(
            action: signing)
        }
        return .confirmedCompleted(summary: summary)
      } catch {
        return .stillUnknown(reason: "signing output cannot be verified: \(error)")
      }
    }
    if case .workspace(let workspace) = intent.action,
      let invocation = workspace.operationInvocation,
      invocation.projectRef != profile.projectRef
    {
      guard let selected = profileRegistry.profile(for: invocation.projectRef) else {
        return .stillUnknown(
          reason: "workspace.projectProfileUnavailable:\(invocation.projectRef)")
      }
      return try await WorkspaceOperationsProvider(
        profile: selected, profileRegistry: profileRegistry,
        attemptStore: attempts, signingPresetStore: signingPresets,
        signingAttemptStore: signingAttempts, isolationManager: isolationManager,
        nowUTC: nowUTC
      ).reconcile(intent: intent, context: context)
    }
    guard case .workspace(let workspace) = intent.action else {
      return .stillUnknown(reason: "workspace reconcile received a foreign action")
    }
    switch workspace {
    case .inspectGitStatus, .inspectDiff, .readSourceRange:
      // A read writes nothing, so there is no external effect for recovery
      // to confirm and re-running it cannot double anything.
      return .confirmedNotExecuted
    case .createCheckpoint:
      // A checkpoint object is content-addressed: re-running produces the
      // same object for the same tree and changes nothing observable. It is
      // still not "not executed", so recovery must not claim either way.
      return .stillUnknown(
        reason: "workspace checkpoint object cannot be observed without re-reading git")
    case .createArchiveCheckpoint(let checkpoint):
      guard checkpoint.archivePath == attempts.checkpointArchiveURL(jobID: intent.jobID).path
      else {
        return .stillUnknown(reason: "workspace checkpoint archive path is not provider-owned")
      }
      guard FileManager.default.fileExists(atPath: checkpoint.archivePath) else {
        return .confirmedNotExecuted
      }
      do {
        try WorkspaceProviderSupport.require(
          snapshots: checkpoint.sourceSnapshots, root: profile.projectRoot)
        let evidence = try WorkspaceProviderSupport.sealedArchiveEvidence(
          at: URL(filePath: checkpoint.archivePath))
        return .confirmedCompleted(summary: [
          "checkpointObject": evidence.sha256,
          "checkpointKind": "sealedArchive",
          "checkpointByteCount": String(evidence.byteCount),
        ])
      } catch {
        return .stillUnknown(
          reason: "workspace checkpoint archive cannot be proven against source: \(error)")
      }
    case .applyPatch(let patch):
      let current = try WorkspaceProviderSupport.snapshots(
        relativePaths: patch.before.map(\.relativePath), root: profile.projectRoot)
      if current == patch.before { return .confirmedNotExecuted }
      if let attempt = try? attempts.load(patch.patchAttemptRef), current == attempt.after {
        return .confirmedCompleted(summary: [
          "patchAttemptRef": attempt.patchAttemptRef,
          "workspaceRevision": WorkspaceProviderSupport.revision(current),
        ])
      }
      return .stillUnknown(
        reason: "workspace patch files are neither the exact preimage nor a durable postimage")
    case .revertPatch(let revert):
      let current = try WorkspaceProviderSupport.snapshots(
        relativePaths: revert.attempt.before.map(\.relativePath),
        root: profile.projectRoot)
      if current == revert.attempt.before {
        // Receipt loss after a successful revert must close the durable
        // attempt before recovery reports completion. Otherwise a later
        // request could materialize and dispatch the same mutation again.
        try attempts.save(
          revert.attempt.markingReverted(atUTC: context.nowUTC))
        return .confirmedCompleted(summary: [
          "patchAttemptRef": revert.attempt.patchAttemptRef,
          "workspaceRevision": WorkspaceProviderSupport.revision(current),
        ])
      }
      if current == revert.attempt.after { return .confirmedNotExecuted }
      return .stillUnknown(
        reason: "workspace revert files are neither the exact postimage nor original preimage")
    case .inspectSource, .prepareIsolatedCopy:
      return .confirmedNotExecuted
    case .buildOpenHarmony, .runTests, .symbolizeCrash:
      return .stillUnknown(
        reason: "read/build process completion is not inferable after receipt loss")
    case .signOpenHarmonyHap:
      return .stillUnknown(reason: "signing recovery routing failed")
    }
  }

  package func cleanupTerminalJob(jobID: String) {
    signingAttempts?.cleanup(jobID: jobID)
  }

  private func resolved(
    operation: String,
    preset: WorkspaceCommandPreset,
    arguments: [String]
  ) -> WorkspaceResolvedInvocation {
    WorkspaceResolvedInvocation(
      operation: operation, projectRef: profile.projectRef,
      projectRoot: profile.projectRoot, presetID: preset.presetID,
      executable: preset.executable, argumentZero: preset.argumentZero,
      arguments: arguments,
      timeoutSeconds: preset.timeoutSeconds)
  }

  private func string(
    _ key: String, in inputs: [String: JSONValue]
  ) throws -> String {
    guard case .string(let value)? = inputs[key] else {
      throw DeviceProviderError.unsupportedAction("workspace input \(key) is missing")
    }
    return value
  }

  private func integer(
    _ key: String, in inputs: [String: JSONValue]
  ) throws -> Int {
    guard case .integer(let value)? = inputs[key] else {
      throw DeviceProviderError.unsupportedAction("workspace input \(key) is missing")
    }
    return Int(value)
  }

  private func stringArray(
    _ key: String, in inputs: [String: JSONValue]
  ) throws -> [String] {
    guard case .array(let values)? = inputs[key] else {
      throw DeviceProviderError.unsupportedAction("workspace input \(key) is missing")
    }
    return try values.map {
      guard case .string(let value) = $0 else {
        throw DeviceProviderError.unsupportedAction(
          "workspace input \(key) contains a non-string")
      }
      return value
    }
  }

  private func outputSummary(_ receipt: ProviderProcessReceipt) -> [String: String] {
    [
      "exitStatus": receipt.exitStatus.map(String.init) ?? "missing",
      "stdoutByteCount": String(receipt.stdout.count),
      "stderrByteCount": String(receipt.stderr.count),
      "stdoutSHA256": WorkspaceProviderSupport.sha256(receipt.stdout),
      "stderrSHA256": WorkspaceProviderSupport.sha256(receipt.stderr),
    ]
  }

  private func failed(
    _ code: String, _ receipt: ProviderProcessReceipt
  ) -> ProviderSemanticOutcome {
    .failed(
      code: code,
      detail:
        "real process exit=\(receipt.exitStatus.map(String.init) ?? "missing") "
        + "stdoutBytes=\(receipt.stdout.count) stderrBytes=\(receipt.stderr.count)")
  }
}

package enum WorkspaceProviderSupport {
  package static func isNarrower(_ requested: String, than profileScope: String) -> Bool {
    if requested == profileScope { return true }
    if profileScope.hasSuffix("/**") {
      let prefix = String(profileScope.dropLast(3))
      return requested == prefix || requested.hasPrefix(prefix + "/")
    }
    if profileScope.hasSuffix("/*") {
      let prefix = String(profileScope.dropLast(2))
      guard requested.hasPrefix(prefix + "/") else { return false }
      return !requested.dropFirst(prefix.count + 1).contains("/")
    }
    return false
  }

  /// The workspace's identity: which tree this is, independent of what it
  /// currently contains (CHG-2026-055, TASK-HFA-009).
  package static func workspaceIdentity(root: String, profileID: String) -> String {
    sha256(Data("arkdeck-workspace|\(profileID)|\(root)".utf8))
  }

  /// The workspace's revision: what this tree currently *is*.
  ///
  /// The architecture's §18.2 formula is HEAD OID + index tree OID + changed
  /// path digests + submodule OIDs + profile version. Two deliberate
  /// substitutions, both named rather than hidden:
  ///
  ///   * the index contributes the digest of the index *file*, not the tree
  ///     OID it encodes. Reading the tree OID means parsing git's binary
  ///     index; the file digest moves whenever the index does, which is the
  ///     property being used;
  ///   * submodule OIDs are not included. This provider has no submodule
  ///     surface yet, and a component nothing can change is not evidence.
  ///
  /// Everything here is a file read. Computing a revision must not depend on
  /// spawning git, because admission needs the answer before any process
  /// runs.
  package static func workspaceRevision(
    root: String, profileVersion: String, globs: [String]
  ) throws -> String {
    let rootURL = URL(filePath: root, directoryHint: .isDirectory)
      .resolvingSymlinksInPath().standardizedFileURL
    let canonicalRoot = rootURL.path
    let gitURL = rootURL.appending(path: ".git", directoryHint: .isDirectory)
    var material = "profileVersion\t\(profileVersion)\n"
    material += "head\t\(headOID(gitDirectory: gitURL) ?? "absent")\n"
    let indexURL = gitURL.appending(path: "index")
    let indexDigest = (try? Data(contentsOf: indexURL)).map(sha256) ?? "absent"
    material += "index\t\(indexDigest)\n"
    let paths = try files(
      root: canonicalRoot, profileGlobs: globs, requestGlobs: globs)
    for path in paths.sorted() {
      let relative = String(
        path.dropFirst(canonicalRoot.count).drop(while: { $0 == "/" }))
      let digest = (try? Data(contentsOf: URL(filePath: path))).map(sha256) ?? "absent"
      material += "file\t\(relative)\t\(digest)\n"
    }
    return sha256(Data(material.utf8))
  }

  /// HEAD as an object id, read from files. A detached HEAD holds the id
  /// directly; a symbolic HEAD points at a ref file, and a packed ref is
  /// resolved from `packed-refs`.
  private static func headOID(gitDirectory: URL) -> String? {
    guard
      let head = try? String(
        contentsOf: gitDirectory.appending(path: "HEAD"), encoding: .utf8)
    else { return nil }
    let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("ref: ") else {
      return trimmed.isEmpty ? nil : trimmed
    }
    let ref = String(trimmed.dropFirst("ref: ".count))
    if let loose = try? String(
      contentsOf: gitDirectory.appending(path: ref), encoding: .utf8)
    {
      let value = loose.trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { return value }
    }
    guard
      let packed = try? String(
        contentsOf: gitDirectory.appending(path: "packed-refs"), encoding: .utf8)
    else { return nil }
    for line in packed.split(separator: "\n") where line.hasSuffix(" " + ref) {
      return String(line.prefix(while: { $0 != " " }))
    }
    return nil
  }

  package static func sha256(_ data: Data) -> String {
    SHA256Hex.string(of: data)
  }

  package static func isSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.allSatisfy {
        $0.isNumber || ("a"..."f").contains(String($0))
      }
  }

  package static func isIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 128
      && value.allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber || "._:@-".contains($0))
      }
  }

  static func isSafeGlob(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 512
      && !value.hasPrefix("/") && !value.contains("\\")
      && !value.split(separator: "/", omittingEmptySubsequences: false)
        .contains(where: { $0 == ".." || $0.isEmpty })
      && !value.hasPrefix(".git") && !value.contains("/.git/")
  }

  static func isSafeRelativePath(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 512 && !value.hasPrefix("/") && !value.contains("\\")
      && !value.contains(where: { "*?[]".contains($0) })
      && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      && !value.split(separator: "/", omittingEmptySubsequences: false)
        .contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
      && value != ".git" && !value.hasPrefix(".git/") && !value.contains("/.git/")
  }

  static func matches(_ path: String, glob: String) -> Bool {
    guard isSafeGlob(glob) else { return false }
    var pattern = "^"
    let characters = Array(glob)
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "*" {
        if index + 1 < characters.count, characters[index + 1] == "*" {
          pattern += ".*"
          index += 2
          continue
        }
        pattern += "[^/]*"
      } else if character == "?" {
        pattern += "[^/]"
      } else {
        pattern += NSRegularExpression.escapedPattern(for: String(character))
      }
      index += 1
    }
    pattern += "$"
    return path.range(of: pattern, options: .regularExpression) != nil
  }

  /// Whether an enumerated directory can contain a match for this glob.
  /// Only the literal prefix before the first wildcard is used, so this may
  /// deliberately keep extra directories but can never prune a possible
  /// match. Narrow task scopes such as `entry/src/main/ets/**` therefore do
  /// not walk unrelated build caches before admission.
  package static func globMayMatchDescendant(
    directory: String, glob: String
  ) -> Bool {
    guard isSafeGlob(glob), isSafeRelativePath(directory) else { return false }
    let wildcard = glob.firstIndex { "*?[".contains($0) }
    let prefix = String(glob[..<(wildcard ?? glob.endIndex)])
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !prefix.isEmpty else { return true }
    return prefix == directory
      || prefix.hasPrefix(directory + "/")
      || directory.hasPrefix(prefix)
  }

  /// The narrowest directory that can be opened before recursively matching
  /// a glob. `nil` means the project root. The returned path contains no
  /// wildcard and is already covered by `isSafeGlob`'s traversal checks.
  package static func globEnumerationAnchor(_ glob: String) -> String? {
    guard isSafeGlob(glob) else { return nil }
    guard let wildcard = glob.firstIndex(where: { "*?[".contains($0) }) else {
      let components = glob.split(separator: "/")
      guard components.count > 1 else { return nil }
      return components.dropLast().joined(separator: "/")
    }
    let literal = String(glob[..<wildcard])
    if literal.hasSuffix("/") {
      let directory = String(literal.dropLast())
      return directory.isEmpty ? nil : directory
    }
    guard let separator = literal.lastIndex(of: "/") else { return nil }
    let directory = String(literal[..<separator])
    return directory.isEmpty ? nil : directory
  }

  package static func files(
    root: String, profileGlobs: [String], requestGlobs: [String]
  ) throws -> [String] {
    guard !requestGlobs.isEmpty, requestGlobs.count <= 64,
      requestGlobs.allSatisfy(isSafeGlob)
    else {
      throw DeviceProviderError.unsupportedAction(
        "workspace file scope globs are empty or unsafe")
    }
    let rootURL = URL(filePath: root)
      .resolvingSymlinksInPath().standardizedFileURL
    let canonicalRoot = rootURL.path
    let anchors = Set(requestGlobs.map(globEnumerationAnchor))
    var result: Set<String> = []
    var visitedEntries = 0
    for anchor in anchors.sorted(by: { ($0 ?? "") < ($1 ?? "") }) {
      let anchorURL =
        anchor.map { rootURL.appending(path: $0, directoryHint: .isDirectory) }
        ?? rootURL
      let lexicalAnchor = anchorURL.standardizedFileURL.path
      guard lexicalAnchor == canonicalRoot || lexicalAnchor.hasPrefix(canonicalRoot + "/") else {
        throw DeviceProviderError.factsUnavailable(
          "workspace enumeration anchor escapes the canonical project root")
      }
      guard FileManager.default.fileExists(atPath: lexicalAnchor) else { continue }
      let anchorValues = try anchorURL.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard anchorValues.isDirectory == true, anchorValues.isSymbolicLink != true else {
        continue
      }
      var enumerationError: Error?
      guard
        let enumerator = FileManager.default.enumerator(
          at: anchorURL,
          includingPropertiesForKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
          ],
          options: [.skipsHiddenFiles, .skipsPackageDescendants],
          errorHandler: { _, error in
            enumerationError = error
            return false
          })
      else {
        throw DeviceProviderError.factsUnavailable(
          "workspace source scope cannot be enumerated")
      }
      for case let fileURL as URL in enumerator {
        visitedEntries += 1
        guard visitedEntries <= 20_000 else {
          throw DeviceProviderError.unsupportedAction(
            "workspace inspection enumeration exceeds 20000 entries")
        }
        let values = try fileURL.resourceValues(
          forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        let lexicalFile = fileURL.standardizedFileURL.path
        guard lexicalFile.hasPrefix(canonicalRoot + "/") else {
          throw DeviceProviderError.factsUnavailable(
            "workspace source path escapes the canonical project root")
        }
        let lexicalRelative = String(
          lexicalFile.dropFirst(canonicalRoot.count + 1))
        if values.isDirectory == true {
          if values.isSymbolicLink == true
            || !profileGlobs.contains(where: {
              globMayMatchDescendant(directory: lexicalRelative, glob: $0)
            })
            || !requestGlobs.contains(where: {
              globMayMatchDescendant(directory: lexicalRelative, glob: $0)
            })
          {
            enumerator.skipDescendants()
          }
          continue
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
        let canonicalFile = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard canonicalFile.hasPrefix(canonicalRoot + "/") else {
          throw DeviceProviderError.factsUnavailable(
            "workspace source path escapes the canonical project root")
        }
        let relative = String(canonicalFile.dropFirst(canonicalRoot.count + 1))
        if profileGlobs.contains(where: { matches(relative, glob: $0) }),
          requestGlobs.contains(where: { matches(relative, glob: $0) })
        {
          result.insert(canonicalFile)
          guard result.count <= 2_000 else {
            throw DeviceProviderError.unsupportedAction(
              "workspace inspection scope exceeds 2000 files")
          }
        }
      }
      if enumerationError != nil {
        throw DeviceProviderError.factsUnavailable(
          "workspace source scope enumeration failed")
      }
    }
    return result.sorted()
  }

  package static func patchPaths(from data: Data) throws -> [String] {
    guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
      throw DeviceProviderError.unsupportedAction(
        "workspace patch must be bounded UTF-8 unified diff")
    }
    var paths: Set<String> = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      if line.hasPrefix("GIT binary patch") || line.hasPrefix("Binary files ")
        || line.hasPrefix("rename from ") || line.hasPrefix("rename to ")
        || line.hasPrefix("copy from ") || line.hasPrefix("copy to ")
      {
        throw DeviceProviderError.unsupportedAction(
          "workspace binary/rename/copy patches are not supported")
      }
      if line.hasPrefix("diff --git ") {
        let fields = line.split(separator: " ")
        guard fields.count == 4,
          let old = normalizedPatchPath(String(fields[2]), prefix: "a/"),
          let new = normalizedPatchPath(String(fields[3]), prefix: "b/")
        else {
          throw DeviceProviderError.unsupportedAction(
            "workspace diff header carries an unsafe path")
        }
        paths.insert(old)
        paths.insert(new)
      } else if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
        let raw = String(line.dropFirst(4)).split(separator: "\t").first.map(String.init) ?? ""
        if raw != "/dev/null" {
          let prefix = line.hasPrefix("--- ") ? "a/" : "b/"
          guard let path = normalizedPatchPath(raw, prefix: prefix) else {
            throw DeviceProviderError.unsupportedAction(
              "workspace unified diff carries an unsafe path")
          }
          paths.insert(path)
        }
      }
    }
    guard !paths.isEmpty, paths.count <= 128 else {
      throw DeviceProviderError.unsupportedAction(
        "workspace patch must touch 1...128 declared files")
    }
    return paths.sorted()
  }

  private static func normalizedPatchPath(
    _ raw: String, prefix: String
  ) -> String? {
    guard raw.hasPrefix(prefix) else { return nil }
    let path = String(raw.dropFirst(prefix.count))
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
      !path.split(separator: "/", omittingEmptySubsequences: false)
        .contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }),
      !path.hasPrefix(".git/"), path != ".git"
    else { return nil }
    return path
  }

  /// A repository-relative path that the ProjectProfile already declares
  /// readable. Traversal, absolute paths and leading dashes are refused
  /// rather than normalised, and the returned value is the joined path the
  /// argv carries.
  static func resolvedReadablePath(
    _ relativePath: String, root: String, profileGlobs: [String]
  ) throws -> String {
    guard !relativePath.isEmpty, relativePath.count <= 240,
      !relativePath.hasPrefix("-"), !relativePath.hasPrefix("/"),
      !relativePath.contains(".."), !relativePath.contains("\u{0}")
    else {
      throw DeviceProviderError.unsupportedAction("workspace.malformedFilePath")
    }
    guard profileGlobs.contains(where: { matches(relativePath, glob: $0) }) else {
      throw DeviceProviderError.unsupportedAction("workspace.pathOutsideProfileScope")
    }
    return URL(filePath: root).appending(path: relativePath).path
  }

  /// A git revision expression, not a path and not an option. Anything that
  /// could become a flag or reach the filesystem is refused rather than
  /// escaped.
  static func validateRevisionExpression(_ value: String) throws {
    guard !value.isEmpty, value.count <= 120, !value.hasPrefix("-"),
      !value.contains(".."), !value.contains("/"),
      value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-^~@{}".contains($0)) })
    else {
      throw DeviceProviderError.unsupportedAction("workspace.malformedRevision")
    }
  }

  /// A pathspec relative to the resolved root: no parent traversal, no
  /// absolute path, no leading dash.
  static func validatePathScope(_ value: String) throws {
    guard !value.isEmpty, value.count <= 120, !value.hasPrefix("-"),
      !value.hasPrefix("/"), !value.contains(".."),
      value.allSatisfy({
        $0.isASCII && ($0.isLetter || $0.isNumber || "*?.-_[]/".contains($0))
      })
    else {
      throw DeviceProviderError.unsupportedAction("workspace.malformedPathScope")
    }
  }

  package static func validate(
    relativePaths: [String],
    root: String,
    profileGlobs: [String],
    requestGlobs: [String]
  ) throws {
    guard !requestGlobs.isEmpty, requestGlobs.count <= 64,
      requestGlobs.allSatisfy(isSafeGlob)
    else {
      throw DeviceProviderError.unsupportedAction(
        "workspace patch allowedFileGlobs are empty or unsafe")
    }
    for path in relativePaths {
      guard profileGlobs.contains(where: { matches(path, glob: $0) }),
        requestGlobs.contains(where: { matches(path, glob: $0) })
      else {
        throw DeviceProviderError.unsupportedAction(
          "workspace.patchScopeViolation:\(path)")
      }
      try validatePath(path, root: root)
    }
  }

  private static func validatePath(_ relativePath: String, root: String) throws {
    let candidate = URL(filePath: root).appending(path: relativePath)
      .standardizedFileURL.path
    guard candidate.hasPrefix(root + "/") else {
      throw DeviceProviderError.unsupportedAction(
        "workspace path escapes the ProjectProfile root")
    }
    var cursor = URL(filePath: root)
    for component in relativePath.split(separator: "/").dropLast() {
      cursor.append(path: String(component))
      if FileManager.default.fileExists(atPath: cursor.path) {
        let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
          throw DeviceProviderError.unsupportedAction(
            "workspace path traverses a symbolic link")
        }
      }
    }
    if FileManager.default.fileExists(atPath: candidate) {
      let values = try URL(filePath: candidate).resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw DeviceProviderError.unsupportedAction(
          "workspace patch target is not a regular file")
      }
    }
  }

  package static func snapshots(
    relativePaths: [String], root: String
  ) throws -> [WorkspaceFileSnapshot] {
    try relativePaths.sorted().map { path in
      try validatePath(path, root: root)
      let url = URL(filePath: root).appending(path: path)
      guard FileManager.default.fileExists(atPath: url.path) else {
        return WorkspaceFileSnapshot(relativePath: path, sha256: nil)
      }
      return WorkspaceFileSnapshot(
        relativePath: path, sha256: sha256(try Data(contentsOf: url)))
    }
  }

  static func requireBoundedCheckpointSources(
    relativePaths: [String], root: String
  ) throws {
    var totalBytes = 0
    for path in relativePaths {
      let url = URL(filePath: root).appending(path: path)
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      totalBytes += values.fileSize ?? 0
      guard totalBytes <= 60 * 1024 * 1024 else {
        throw DeviceProviderError.unsupportedAction(
          "workspace checkpoint sources exceed the 60 MiB bound")
      }
    }
  }

  /// A complete uncompressed tar ends with at least two 512-byte zero
  /// records. That footer distinguishes a completed provider dispatch from
  /// a receipt-lost partial write during recovery.
  static func sealedArchiveEvidence(at url: URL) throws -> (byteCount: Int, sha256: String) {
    let values = try url.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    let byteCount = values.fileSize ?? 0
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      byteCount >= 1_024, byteCount <= 64 * 1024 * 1024,
      byteCount.isMultiple(of: 512)
    else {
      throw DeviceProviderError.factsUnavailable(
        "workspace checkpoint archive metadata is unsafe")
    }
    let bytes = try Data(contentsOf: url)
    guard bytes.count == byteCount,
      bytes.suffix(1_024).allSatisfy({ $0 == 0 })
    else {
      throw DeviceProviderError.factsUnavailable(
        "workspace checkpoint archive footer is incomplete")
    }
    return (byteCount, sha256(bytes))
  }

  static func require(
    snapshots expected: [WorkspaceFileSnapshot], root: String
  ) throws {
    let current = try snapshots(
      relativePaths: expected.map(\.relativePath), root: root)
    guard current == expected else {
      throw DeviceProviderError.unsupportedAction(
        "workspace revision drifted before descriptor-bound dispatch")
    }
  }

  package static func revision(_ snapshots: [WorkspaceFileSnapshot]) -> String {
    let material = snapshots.sorted { $0.relativePath < $1.relativePath }
      .map { "\($0.relativePath)\t\($0.sha256 ?? "absent")" }
      .joined(separator: "\n")
    return sha256(Data(material.utf8))
  }
}
