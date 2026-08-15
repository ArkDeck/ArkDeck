import Foundation
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class RuntimeOwnedWorkspaceContractTests: XCTestCase {
  private var roots: [URL] = []

  override func tearDownWithError() throws {
    for root in roots { try? FileManager.default.removeItem(at: root) }
    roots = []
  }

  func testRuntimePreparesAdoptsAndBuildsOnlyInsideTheIsolatedCopy() async throws {
    let sourceRoot = try temporaryDirectory("source")
    let stateRoot = try temporaryDirectory("state")
    try FileManager.default.createDirectory(
      at: sourceRoot.appending(path: "Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: sourceRoot.appending(path: "Sources/App.txt"))
    try Data("outside the narrowed writable scope\n".utf8).write(
      to: sourceRoot.appending(path: "Sources/Other.txt"))
    let hap = Data([0x50, 0x4b, 0x03, 0x04, 0x41, 0x52, 0x4b, 0x44, 0x45, 0x43, 0x4b])
    try hap.write(to: sourceRoot.appending(path: "Sources/Input.hap"))

    let profile = try workspaceProfile(root: sourceRoot)
    let sourceRevision = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: profile.allowedFileGlobs)
    let isolatedRevision = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: ["Sources/App.txt"])
    XCTAssertNotEqual(sourceRevision, isolatedRevision)

    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let evolutionRoot = stateRoot.appending(path: "evolution")
    let manager = try EvolutionWorkspaceManager(
      rootURL: evolutionRoot, profileRegistry: registry)
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateRoot.appending(path: "artifacts"), nowUTC: { Self.fixedTimestamp })
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateRoot.appending(path: "capabilities"))
    let provider = try workspaceProvider(
      profile: profile, registry: registry, manager: manager, stateRoot: stateRoot,
      suffix: "prepare")
    let process = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: profile))
    let dispatcher = RuntimeOwnedWorkspaceDispatcher(fallback: process, manager: manager)
    let engine = try runtimeEngine(
      stateRoot: stateRoot.appending(path: "prepare-engine"), provider: provider,
      dispatcher: dispatcher, capabilityStore: capabilityStore,
      artifactStore: artifactStore)

    let prepare = try operationRequest(
      id: "workspace.prepare-isolated-copy",
      requestID: "request-isolate",
      idempotencyKey: "idempotency-isolate",
      inputs: [
        "projectRef": .string(profile.projectRef),
        "allowedFileGlobs": .array([.string("Sources/App.txt")]),
        "expectedWorkspaceRevision": .string(sourceRevision),
      ])
    let accepted = try await engine.submit(try JSONEncoder().encode(prepare))
    let prepared = try await engine.run(jobID: accepted.jobID)
    XCTAssertEqual(prepared.state, "succeeded", prepared.timeline.joined(separator: " | "))
    let capabilitiesAfterPreparation = try await capabilityStore.list()
    XCTAssertTrue(
      capabilitiesAfterPreparation.isEmpty,
      "preparing a Runtime-owned host copy must not consume a mutation capability")

    let preparationArtifacts = try await artifactStore.list(jobID: accepted.jobID)
    let isolationArtifact = try XCTUnwrap(
      preparationArtifacts.first {
        $0.name == "isolated-workspace.json" && $0.status.isPublished
      })
    let isolationLease = try await artifactStore.leaseReference(
      jobID: accepted.jobID, artifactID: isolationArtifact.artifactID)
    let isolationBytes = try Data(
      contentsOf: try await artifactStore.resolveLease(isolationLease).fileURL)
    let isolation = try JSONDecoder().decode([String: JSONValue].self, from: isolationBytes)
    guard case .string(let isolatedProjectRef)? = isolation["projectRef"],
      case .string(let publishedSourceRevision)? = isolation["sourceWorkspaceRevision"],
      case .string(let publishedWorkspaceRevision)? = isolation["workspaceRevision"]
    else {
      return XCTFail("isolated workspace Artifact must carry its path-free identity")
    }
    XCTAssertEqual(publishedSourceRevision, sourceRevision)
    XCTAssertEqual(publishedWorkspaceRevision, isolatedRevision)
    XCTAssertTrue(isolatedProjectRef.hasPrefix("evolution-"))

    let sharedBuild = try operationRequest(
      id: "workspace.build-openharmony",
      requestID: "request-build-shared",
      idempotencyKey: "idempotency-build-shared",
      inputs: [
        "projectRef": .string(profile.projectRef),
        "buildPresetRef": .string("copy-hap"),
        "expectedWorkspaceRevision": .string(sourceRevision),
      ])
    do {
      _ = try await engine.submit(try JSONEncoder().encode(sharedBuild))
      XCTFail("a Runtime-owned copy must not authorize mutation of the primary workspace")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(.authorizationRequired, _) = error else {
        return XCTFail("unexpected shared-workspace rejection: \(error)")
      }
    }

    // A new daemon process starts with only the primary profile. It must adopt
    // the persisted Runtime-owned copy rather than silently rebuilding it.
    let restartedRegistry = WorkspaceProjectProfileRegistry(profile: profile)
    let restartedManager = try EvolutionWorkspaceManager(
      rootURL: evolutionRoot, profileRegistry: restartedRegistry)
    let adoptionFailures = restartedManager.adoptRuntimeWorkspaces()
    XCTAssertEqual(adoptionFailures, [])
    let isolatedProfile = try XCTUnwrap(restartedRegistry.profile(for: isolatedProjectRef))
    XCTAssertEqual(isolatedProfile.kind, .evolution)
    XCTAssertNotEqual(isolatedProfile.projectRoot, profile.projectRoot)
    XCTAssertEqual(
      try WorkspaceProviderSupport.workspaceRevision(
        root: isolatedProfile.projectRoot, profileVersion: profile.profileID,
        globs: profile.allowedFileGlobs),
      sourceRevision,
      "the published copy must match the exact full primary revision, not only its narrow scope")

    let restartedProvider = try workspaceProvider(
      profile: profile, registry: restartedRegistry, manager: restartedManager,
      stateRoot: stateRoot, suffix: "build")
    let restartedDispatcher = RuntimeOwnedWorkspaceDispatcher(
      fallback: process, manager: restartedManager)
    let restartedEngine = try runtimeEngine(
      stateRoot: stateRoot.appending(path: "build-engine"), provider: restartedProvider,
      dispatcher: restartedDispatcher, capabilityStore: capabilityStore,
      artifactStore: artifactStore)
    let build = try operationRequest(
      id: "workspace.build-openharmony",
      requestID: "request-build-isolated",
      idempotencyKey: "idempotency-build-isolated",
      inputs: [
        "projectRef": .string(isolatedProjectRef),
        "buildPresetRef": .string("copy-hap"),
        "expectedWorkspaceRevision": .string(isolatedRevision),
      ])
    let buildAcceptance = try await restartedEngine.submit(try JSONEncoder().encode(build))
    let built = try await restartedEngine.run(jobID: buildAcceptance.jobID)
    XCTAssertEqual(built.state, "succeeded", built.timeline.joined(separator: " | "))

    let buildArtifacts = try await artifactStore.list(jobID: buildAcceptance.jobID)
    XCTAssertTrue(buildArtifacts.contains { $0.name == "build.log" && $0.status.isPublished })
    let unsigned = try XCTUnwrap(
      buildArtifacts.first { $0.name == "unsigned.hap" && $0.status.isPublished })
    let unsignedLease = try await artifactStore.leaseReference(
      jobID: buildAcceptance.jobID, artifactID: unsigned.artifactID)
    let resolvedUnsigned = try await artifactStore.resolveLease(unsignedLease)
    XCTAssertEqual(try Data(contentsOf: resolvedUnsigned.fileURL), hap)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: sourceRoot.appending(
          path: "entry/build/default/outputs/default/entry-default-unsigned.hap"
        ).path),
      "the build product must never land in the primary source tree")
    XCTAssertEqual(
      try String(contentsOf: sourceRoot.appending(path: "Sources/App.txt"), encoding: .utf8),
      "old\n")

    let finalCapabilities = try await capabilityStore.list()
    let automatic = finalCapabilities.filter {
      $0.capability.issuer.kind == .runtimeDefaultPolicy
        && $0.capability.operationScope.contains {
          $0.operationID == "workspace.build-openharmony" && $0.version == 1
        }
    }
    XCTAssertEqual(automatic.count, 1)
    XCTAssertEqual(automatic.first?.consumptionCount, 1)
  }

  func testSourceDriftIsRejectedBeforeAnIsolatedCopyIsPublished() async throws {
    let sourceRoot = try temporaryDirectory("drift-source")
    let stateRoot = try temporaryDirectory("drift-state")
    try FileManager.default.createDirectory(
      at: sourceRoot.appending(path: "Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: sourceRoot.appending(path: "Sources/App.txt"))
    try Data([0x50, 0x4b, 0x03, 0x04, 0x41]).write(
      to: sourceRoot.appending(path: "Sources/Input.hap"))
    let profile = try workspaceProfile(root: sourceRoot)
    let sourceRevision = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: profile.allowedFileGlobs)
    let isolatedRevision = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: ["Sources/App.txt"])
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let manager = try EvolutionWorkspaceManager(
      rootURL: stateRoot.appending(path: "evolution"), profileRegistry: registry)
    let intent = WorkspaceIsolationIntent(
      runtimeOwnerID: "runtime-job-drift", sourceProjectRef: profile.projectRef,
      expectedWorkspaceRevision: sourceRevision,
      isolatedWorkspaceRevision: isolatedRevision, createdAtUTC: timestamp,
      allowedFileGlobs: ["Sources/App.txt"])

    try Data("changed after admission\n".utf8).write(
      to: sourceRoot.appending(path: "Sources/Input.hap"))
    do {
      _ = try await manager.prepare(intent)
      XCTFail("source-profile drift must be refused before copying")
    } catch let error as EvolutionWorkspaceError {
      guard case .baseRevisionMismatch(let expected, let actual) = error else {
        return XCTFail("unexpected isolation error: \(error)")
      }
      XCTAssertEqual(expected, sourceRevision)
      XCTAssertNotEqual(actual, sourceRevision)
    }
    XCTAssertNil(registry.profile(for: intent.workspaceProjectRef))
    XCTAssertEqual(try manager.inspect(intent), .absent)
  }

  private static let fixedTimestamp = "2026-08-15T00:00:00Z"
  private var timestamp: String { Self.fixedTimestamp }

  private func temporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-runtime-isolation-\(prefix)-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    roots.append(url)
    return url
  }

  private func workspaceProfile(root: URL) throws -> WorkspaceProjectProfile {
    let grep = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/grep")
    let patch = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/patch")
    let copy = try WorkspaceExecutableIdentity.hashing(path: "/bin/cp")
    let inspection = try WorkspaceCommandPreset(
      presetID: "inspect", executable: grep, fixedArguments: [], timeoutSeconds: 10)
    let patching = try WorkspaceCommandPreset(
      presetID: "patch", executable: patch, fixedArguments: [], timeoutSeconds: 10)
    let build = try WorkspaceCommandPreset(
      presetID: "copy-hap", executable: copy,
      fixedArguments: [
        "Sources/Input.hap",
        "entry/build/default/outputs/default/entry-default-unsigned.hap",
      ], timeoutSeconds: 10)
    return try WorkspaceProjectProfile(
      profileID: "runtime-isolation-test@1", projectRef: "RuntimeIsolationProject",
      projectRoot: root.path, allowedFileGlobs: ["Sources/**"],
      inspectionPreset: inspection, patchPreset: patching,
      buildPresets: [build.presetID: build], testPresets: [:], symbolPresets: [:],
      buildProducts: [
        build.presetID: "entry/build/default/outputs/default/entry-default-unsigned.hap"
      ])
  }

  private func workspaceProvider(
    profile: WorkspaceProjectProfile,
    registry: WorkspaceProjectProfileRegistry,
    manager: EvolutionWorkspaceManager,
    stateRoot: URL,
    suffix: String
  ) throws -> WorkspaceOperationsProvider {
    WorkspaceOperationsProvider(
      profile: profile, profileRegistry: registry,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: stateRoot.appending(path: "attempts-\(suffix)")),
      isolationManager: manager, nowUTC: { Self.fixedTimestamp })
  }

  private func runtimeEngine(
    stateRoot: URL,
    provider: WorkspaceOperationsProvider,
    dispatcher: RuntimeOwnedWorkspaceDispatcher,
    capabilityStore: RuntimeCapabilityStore,
    artifactStore: RuntimeArtifactStore
  ) throws -> RuntimeJobEngine {
    try RuntimeJobEngine(
      configuration: .init(stateDirectory: stateRoot),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: dispatcher, rockchip: dispatcher, workspace: dispatcher),
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      nowUTC: { Self.fixedTimestamp })
  }

  private func operationRequest(
    id: String,
    requestID: String,
    idempotencyKey: String,
    inputs: [String: JSONValue]
  ) throws -> RuntimeOperationRequest {
    try RuntimeOperationRequest(
      requestID: requestID, idempotencyKey: idempotencyKey,
      target: DurableTargetReference(targetID: "workspace-test"),
      operation: RuntimeOperationReference(id: id, version: 1),
      inputs: inputs)
  }
}
