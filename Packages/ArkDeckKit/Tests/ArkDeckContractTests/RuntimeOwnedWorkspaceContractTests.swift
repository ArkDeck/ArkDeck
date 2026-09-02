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

  func testNonterminalDerivedJobKeepsItsSourceProjectRegistration() async throws {
    let sourceRoot = try temporaryDirectory("reference-source")
    let stateRoot = try temporaryDirectory("reference-state")
    try FileManager.default.createDirectory(
      at: sourceRoot.appending(path: "Sources"), withIntermediateDirectories: true)
    try Data("line one\nline two\n".utf8).write(
      to: sourceRoot.appending(path: "Sources/App.txt"))
    // XCTest's temporary directory is spelled through macOS's `/var` alias.
    // The registration contract intentionally rejects symlink ancestry, so
    // feed it the physical path just as a real CLI caller must.
    guard let physical = realpath(sourceRoot.path, nil) else { throw POSIXError(.ENOENT) }
    defer { free(physical) }
    let physicalSourceRoot = URL(
      filePath: String(cString: physical), directoryHint: .isDirectory)

    let projectStore = try RuntimeWorkspaceProjectStore(
      rootURL: stateRoot.appending(path: "workspace-projects"))
    let registration = try projectStore.register(
      requestID: "derived-reference-registration", kind: "arkdeck",
      rootPath: physicalSourceRoot.path)
    projectStore.markApplied([registration.projectRef: registration.generation])
    let profile = try workspaceProfile(
      root: physicalSourceRoot, projectRef: registration.projectRef,
      includesSourceReader: true)
    let sourceRevision = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: profile.allowedFileGlobs)
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let manager = try EvolutionWorkspaceManager(
      rootURL: stateRoot.appending(path: "evolution"), profileRegistry: registry)
    let isolation = WorkspaceIsolationIntent(
      runtimeOwnerID: "runtime-derived-reference-job",
      sourceProjectRef: registration.projectRef,
      expectedWorkspaceRevision: sourceRevision,
      isolatedWorkspaceRevision: sourceRevision,
      createdAtUTC: timestamp, allowedFileGlobs: profile.allowedFileGlobs)
    _ = try await manager.prepare(isolation)

    let provider = try workspaceProvider(
      profile: profile, registry: registry, manager: manager,
      stateRoot: stateRoot, suffix: "reference")
    let process = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: profile))
    let dispatcher = RuntimeOwnedWorkspaceDispatcher(fallback: process, manager: manager)
    let engine = try runtimeEngine(
      stateRoot: stateRoot.appending(path: "engine"), provider: provider,
      dispatcher: dispatcher,
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: stateRoot.appending(path: "capabilities")),
      artifactStore: try RuntimeArtifactStore(
        rootURL: stateRoot.appending(path: "artifacts"),
        nowUTC: { Self.fixedTimestamp }),
      workspaceProjectStore: projectStore)
    let request = try operationRequest(
      id: "workspace.read-source-range", requestID: "request-derived-reference",
      idempotencyKey: "idempotency-derived-reference",
      inputs: [
        "projectRef": .string(isolation.workspaceProjectRef),
        "filePath": .string("Sources/App.txt"),
        "lineStart": .integer(1),
        "lineEnd": .integer(1),
      ])
    let accepted = try await engine.submit(try JSONEncoder().encode(request))

    do {
      _ = try await engine.workspaceProjectRemove(
        projectRef: registration.projectRef,
        expectedGeneration: registration.generation)
      XCTFail("a nonterminal derived Job must retain its source registration")
    } catch let failure as RuntimeWorkspaceProjectFailure {
      XCTAssertEqual(failure.code, "resourceConflict")
      XCTAssertTrue(failure.message.contains("active or uncertain Job"))
    }

    let terminal = try await engine.run(jobID: accepted.jobID)
    XCTAssertEqual(terminal.state, "succeeded", terminal.timeline.joined(separator: " | "))
    let removed = try await engine.workspaceProjectRemove(
      projectRef: registration.projectRef,
      expectedGeneration: registration.generation)
    XCTAssertEqual(removed.configurationStatus, "removed")
    XCTAssertTrue(FileManager.default.fileExists(atPath: physicalSourceRoot.path))
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

  func testIsolationRefusalNamesTheOffendingEntryWithoutHostPaths() async throws {
    let sourceRoot = try temporaryDirectory("refusal-source")
    let externalRoot = try temporaryDirectory("refusal-external")
    let stateRoot = try temporaryDirectory("refusal-state")
    try FileManager.default.createDirectory(
      at: sourceRoot.appending(path: "Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: sourceRoot.appending(path: "Sources/App.txt"))
    try Data("secret\n".utf8).write(to: externalRoot.appending(path: "secret.txt"))
    try FileManager.default.createSymbolicLink(
      atPath: sourceRoot.appending(path: "Sources/external-link").path,
      withDestinationPath: externalRoot.appending(path: "secret.txt").path)

    let profile = try workspaceProfile(root: sourceRoot)
    let sourceRevision = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: profile.allowedFileGlobs)
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let manager = try EvolutionWorkspaceManager(
      rootURL: stateRoot.appending(path: "evolution"), profileRegistry: registry)
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateRoot.appending(path: "artifacts"), nowUTC: { Self.fixedTimestamp })
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateRoot.appending(path: "capabilities"))
    let provider = try workspaceProvider(
      profile: profile, registry: registry, manager: manager, stateRoot: stateRoot,
      suffix: "refusal")
    let process = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: profile))
    let dispatcher = RuntimeOwnedWorkspaceDispatcher(fallback: process, manager: manager)
    let engine = try runtimeEngine(
      stateRoot: stateRoot.appending(path: "refusal-engine"), provider: provider,
      dispatcher: dispatcher, capabilityStore: capabilityStore,
      artifactStore: artifactStore)

    let prepare = try operationRequest(
      id: "workspace.prepare-isolated-copy",
      requestID: "request-refusal",
      idempotencyKey: "idempotency-refusal",
      inputs: [
        "projectRef": .string(profile.projectRef),
        "allowedFileGlobs": .array([.string("Sources/App.txt")]),
        "expectedWorkspaceRevision": .string(sourceRevision),
      ])
    let accepted = try await engine.submit(try JSONEncoder().encode(prepare))
    let outcome = try await engine.run(jobID: accepted.jobID)
    let story = outcome.timeline.joined(separator: " | ")
    XCTAssertEqual(outcome.state, "failed", story)
    XCTAssertTrue(
      story.contains("unsafeSourceEntry(\"Sources/external-link\")"),
      "the refusal must name the offending tree-relative entry: \(story)")
    XCTAssertFalse(
      story.contains(sourceRoot.path) || story.contains(externalRoot.path),
      "the refusal must stay free of host paths: \(story)")
  }

  func testIsolatedCopyAcquiresTheRegistrationOfItsSourceProject() async throws {
    // A daemon always owns a project registration store, and every
    // per-project Job acquires its registration before admission. A
    // Runtime-owned copy is registered nowhere, so its Jobs acquire the
    // project they were copied from: that is where the pins, the generation
    // guard and the removal protection live. An unknown reference stays
    // refused, and the primary tree is still off limits to the copy's lane.
    let sourceRoot = try temporaryDirectory("registered-source")
    let stateRoot = try temporaryDirectory("registered-state")
    try FileManager.default.createDirectory(
      at: sourceRoot.appending(path: "Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: sourceRoot.appending(path: "Sources/App.txt"))
    let hap = Data([0x50, 0x4b, 0x03, 0x04, 0x41, 0x52, 0x4b])
    try hap.write(to: sourceRoot.appending(path: "Sources/Input.hap"))

    let profile = try workspaceProfile(root: sourceRoot)
    let sourceRevision = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: profile.allowedFileGlobs)
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let manager = try EvolutionWorkspaceManager(
      rootURL: stateRoot.appending(path: "evolution"), profileRegistry: registry)
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateRoot.appending(path: "artifacts"), nowUTC: { Self.fixedTimestamp })
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateRoot.appending(path: "capabilities"))
    let projectStore = try RuntimeWorkspaceProjectStore(
      rootURL: stateRoot.appending(path: "projects", directoryHint: .isDirectory),
      nowUTC: { Self.fixedTimestamp })
    // The registration owner refuses a symbolic link anywhere in the root's
    // ancestry and Foundation's canonical form keeps `/var` (a link to
    // `/private/var`), so the store gets the physical path from realpath(3).
    guard let physical = realpath(sourceRoot.path, nil) else { throw POSIXError(.ENOENT) }
    let physicalRoot = String(cString: physical)
    free(physical)
    let registered = try projectStore.register(
      requestID: "registration-source", kind: "openharmony",
      rootPath: physicalRoot, projectRef: profile.projectRef)
    XCTAssertEqual(registered.projectRef, profile.projectRef)
    projectStore.markApplied(projects: [profile.projectRef: 1], presets: [:])
    let provider = try workspaceProvider(
      profile: profile, registry: registry, manager: manager, stateRoot: stateRoot,
      suffix: "registered")
    let process = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: profile))
    let dispatcher = RuntimeOwnedWorkspaceDispatcher(fallback: process, manager: manager)
    let engine = try runtimeEngine(
      stateRoot: stateRoot.appending(path: "registered-engine"), provider: provider,
      dispatcher: dispatcher, capabilityStore: capabilityStore,
      artifactStore: artifactStore, workspaceProjectStore: projectStore)

    let prepare = try operationRequest(
      id: "workspace.prepare-isolated-copy",
      requestID: "request-registered-isolate",
      idempotencyKey: "idempotency-registered-isolate",
      inputs: [
        "projectRef": .string(profile.projectRef),
        "allowedFileGlobs": .array([.string("Sources/App.txt")]),
        "expectedWorkspaceRevision": .string(sourceRevision),
      ])
    let accepted = try await engine.submit(try JSONEncoder().encode(prepare))
    let prepared = try await engine.run(jobID: accepted.jobID)
    XCTAssertEqual(prepared.state, "succeeded", prepared.timeline.joined(separator: " | "))
    let artifacts = try await artifactStore.list(jobID: accepted.jobID)
    let isolation = try XCTUnwrap(
      artifacts.first { $0.name == "isolated-workspace.json" && $0.status.isPublished })
    let lease = try await artifactStore.leaseReference(
      jobID: accepted.jobID, artifactID: isolation.artifactID)
    let document = try JSONDecoder().decode(
      [String: JSONValue].self,
      from: Data(contentsOf: try await artifactStore.resolveLease(lease).fileURL))
    guard case .string(let isolatedProjectRef)? = document["projectRef"],
      case .string(let isolatedRevision)? = document["workspaceRevision"]
    else {
      return XCTFail("isolation artifact must carry the copy's projectRef and revision")
    }
    XCTAssertEqual(
      provider.workspaceRegistrationProjectRef(for: isolatedProjectRef), profile.projectRef)
    XCTAssertEqual(
      provider.workspaceRegistrationProjectRef(for: profile.projectRef), profile.projectRef)
    XCTAssertNil(provider.workspaceRegistrationProjectRef(for: "evolution-unknown"))

    // A mutation of the copy is admitted against the source registration and
    // authorized automatically, because the copy is a task-owned isolated
    // tree. (The durable reference scan that guards project removal still
    // keys on the literal reference a Job names, so a copy's Job does not
    // hold the source registration open; that is a known residual.)
    let patchBytes = Data(
      """
      --- a/Sources/App.txt
      +++ b/Sources/App.txt
      @@ -1 +1 @@
      -old
      +new

      """.utf8)
    let imported = try await artifactStore.publish(
      RuntimeArtifactPublicationRequest(
        jobID: "job-import-registered-patch", sessionID: "session-import-registered-patch",
        stepID: "import-patch", name: "change.patch",
        mediaType: "text/x-diff", privacy: .sensitive,
        retentionClass: .pinnedUntilVerified,
        sourceOperation: "artifact.import-workspace-patch", providerID: "host",
        bindingSnapshot: ArtifactBindingSnapshot(
          targetID: "workspace-test", bindingRevision: nil,
          stableIdentitySHA256: nil),
        contents: patchBytes))
    let patchLease = try await artifactStore.leaseReference(
      jobID: imported.jobID, artifactID: imported.artifactID)
    let patch = try operationRequest(
      id: "workspace.apply-patch",
      requestID: "request-registered-patch",
      idempotencyKey: "idempotency-registered-patch",
      inputs: [
        "projectRef": .string(isolatedProjectRef),
        "patchArtifactRef": .string(patchLease),
        "allowedFileGlobs": .array([.string("Sources/App.txt")]),
        // A copy's mutation always names the revision it decided against.
        "expectedWorkspaceRevision": .string(isolatedRevision),
      ])
    let patching = try await engine.submit(try JSONEncoder().encode(patch))
    let patched = try await engine.run(jobID: patching.jobID)
    XCTAssertEqual(patched.state, "succeeded", patched.timeline.joined(separator: " | "))
    let isolatedProfile = try XCTUnwrap(registry.profile(for: isolatedProjectRef))
    XCTAssertEqual(
      try Data(contentsOf: URL(filePath: isolatedProfile.projectRoot).appending(path: "Sources/App.txt")),
      Data("new\n".utf8), "the patch lands in the copy")
    XCTAssertEqual(
      try Data(contentsOf: sourceRoot.appending(path: "Sources/App.txt")),
      Data("old\n".utf8), "the registered source tree is untouched")

    // A reference no profile knows is refused by the registration, as before.
    let unknown = try operationRequest(
      id: "workspace.apply-patch",
      requestID: "request-registered-unknown",
      idempotencyKey: "idempotency-registered-unknown",
      inputs: [
        "projectRef": .string("evolution-00000000000000000000"),
        "patchArtifactRef": .string(patchLease),
        "allowedFileGlobs": .array([.string("Sources/App.txt")]),
        "expectedWorkspaceRevision": .string(isolatedRevision),
      ])
    do {
      _ = try await engine.submit(try JSONEncoder().encode(unknown))
      XCTFail("an unregistered reference must not acquire any registration")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(let code, let detail) = error else { return XCTFail("\(error)") }
      XCTAssertEqual(code, .invalidInput)
      XCTAssertTrue(detail.contains("not registered"), detail)
    }
  }

  func testSweepDestroysOnlyLedgerQuiescentTreesAndItsAuditSurvives() async throws {
    let sourceRoot = try temporaryDirectory("sweep-source")
    let stateRoot = try temporaryDirectory("sweep-state")
    try FileManager.default.createDirectory(
      at: sourceRoot.appending(path: "Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: sourceRoot.appending(path: "Sources/App.txt"))
    let hap = Data([0x50, 0x4b, 0x03, 0x04, 0x41, 0x52, 0x4b])
    try hap.write(to: sourceRoot.appending(path: "Sources/Input.hap"))

    let profile = try workspaceProfile(root: sourceRoot)
    let sourceRevision = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: profile.allowedFileGlobs)
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let manager = try EvolutionWorkspaceManager(
      rootURL: stateRoot.appending(path: "evolution"), profileRegistry: registry)
    let artifactStore = try RuntimeArtifactStore(
      rootURL: stateRoot.appending(path: "artifacts"), nowUTC: { Self.fixedTimestamp })
    let capabilityStore = try RuntimeCapabilityStore(
      directoryURL: stateRoot.appending(path: "capabilities"))
    let provider = try workspaceProvider(
      profile: profile, registry: registry, manager: manager, stateRoot: stateRoot,
      suffix: "sweep")
    let process = DescriptorBoundProcessDispatcher(
      resolver: WorkspaceActionExecutableResolver(profile: profile))
    let ledger = WorkspaceReferenceLedgerHandle()
    let dispatcher = RuntimeOwnedWorkspaceDispatcher(
      fallback: process, manager: manager, sweeper: manager, referenceLedger: ledger)
    let engine = try runtimeEngine(
      stateRoot: stateRoot.appending(path: "sweep-engine"), provider: provider,
      dispatcher: dispatcher, capabilityStore: capabilityStore,
      artifactStore: artifactStore)
    ledger.install(engine)

    func preparedCopy(_ suffix: String) async throws -> String {
      let request = try operationRequest(
        id: "workspace.prepare-isolated-copy",
        requestID: "request-sweep-prepare-\(suffix)",
        idempotencyKey: "idempotency-sweep-prepare-\(suffix)",
        inputs: [
          "projectRef": .string(profile.projectRef),
          "allowedFileGlobs": .array([.string("Sources/App.txt")]),
          "expectedWorkspaceRevision": .string(sourceRevision),
        ])
      let accepted = try await engine.submit(try JSONEncoder().encode(request))
      let prepared = try await engine.run(jobID: accepted.jobID)
      XCTAssertEqual(prepared.state, "succeeded", prepared.timeline.joined(separator: " | "))
      let artifacts = try await artifactStore.list(jobID: accepted.jobID)
      let isolation = try XCTUnwrap(
        artifacts.first { $0.name == "isolated-workspace.json" && $0.status.isPublished })
      let lease = try await artifactStore.leaseReference(
        jobID: accepted.jobID, artifactID: isolation.artifactID)
      let bytes = try Data(contentsOf: try await artifactStore.resolveLease(lease).fileURL)
      let document = try JSONDecoder().decode([String: JSONValue].self, from: bytes)
      guard case .string(let ref)? = document["projectRef"] else {
        throw RuntimeJobEngineError.internalFailure("isolation artifact has no projectRef")
      }
      return ref
    }

    let quiescentRef = try await preparedCopy("a")
    let activeRef = try await preparedCopy("b")
    // A submitted-but-never-run job is a live reference in the durable
    // ledger; its workspace must be untouchable however old it looks.
    let holdOpen = try operationRequest(
      id: "workspace.build-openharmony",
      requestID: "request-sweep-hold",
      idempotencyKey: "idempotency-sweep-hold",
      inputs: [
        "projectRef": .string(activeRef),
        "buildPresetRef": .string("copy-hap"),
        "expectedWorkspaceRevision": .string(
          try WorkspaceProviderSupport.workspaceRevision(
            root: try XCTUnwrap(registry.profile(for: activeRef)).projectRoot,
            profileVersion: profile.profileID,
            globs: ["Sources/App.txt"])),
      ])
    _ = try await engine.submit(try JSONEncoder().encode(holdOpen))

    let inventoryByRef = Dictionary(
      uniqueKeysWithValues: manager.runtimeWorkspaceInventory().map {
        ($0.derivedProjectRef, $0.workspaceID)
      })
    let quiescentID = try XCTUnwrap(inventoryByRef[quiescentRef])
    let activeID = try XCTUnwrap(inventoryByRef[activeRef])

    func sweep(_ suffix: String, dryRun: Bool) async throws -> (
      state: String, findings: [String: (String, Int64)], summary: [String: String],
      jobID: String
    ) {
      let request = try operationRequest(
        id: "workspace.sweep-isolated-copies",
        requestID: "request-sweep-\(suffix)",
        idempotencyKey: "idempotency-sweep-\(suffix)",
        inputs: [
          "retainLatestCount": .integer(0),
          "minimumQuiescentSeconds": .integer(0),
          "dryRun": .bool(dryRun),
        ])
      let accepted = try await engine.submit(try JSONEncoder().encode(request))
      let outcome = try await engine.run(jobID: accepted.jobID)
      let artifacts = try await artifactStore.list(jobID: accepted.jobID)
      let findingsArtifact = try XCTUnwrap(
        artifacts.first { $0.name == "sweep-findings.json" && $0.status.isPublished },
        outcome.timeline.joined(separator: " | "))
      let lease = try await artifactStore.leaseReference(
        jobID: accepted.jobID, artifactID: findingsArtifact.artifactID)
      let bytes = try Data(contentsOf: try await artifactStore.resolveLease(lease).fileURL)
      XCTAssertFalse(
        String(decoding: bytes, as: UTF8.self).contains(stateRoot.path),
        "findings must stay free of host paths")
      let document = try JSONDecoder().decode([String: JSONValue].self, from: bytes)
      var findings: [String: (String, Int64)] = [:]
      if case .array(let entries)? = document["findings"] {
        for entry in entries {
          guard case .object(let fields) = entry,
            case .string(let id)? = fields["workspaceId"],
            case .string(let disposition)? = fields["disposition"],
            case .integer(let reclaimed)? = fields["reclaimedBytes"]
          else { continue }
          findings[id] = (disposition, reclaimed)
        }
      }
      return (outcome.state, findings, [:], accepted.jobID)
    }

    let dry = try await sweep("dry", dryRun: true)
    XCTAssertEqual(dry.state, "succeeded")
    XCTAssertEqual(dry.findings[quiescentID]?.0, "wouldDestroy")
    XCTAssertEqual(dry.findings[activeID]?.0, "activeRetained")
    let quiescentTree = URL(
      filePath: try XCTUnwrap(registry.profile(for: quiescentRef)).projectRoot)
    XCTAssertTrue(FileManager.default.fileExists(atPath: quiescentTree.path))

    let wet = try await sweep("wet", dryRun: false)
    XCTAssertEqual(wet.state, "succeeded")
    XCTAssertEqual(wet.findings[quiescentID]?.0, "destroyed")
    XCTAssertEqual(wet.findings[activeID]?.0, "activeRetained")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: quiescentTree.path),
      "the quiescent tree must be gone")
    let quiescentRoot = quiescentTree.deletingLastPathComponent()
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: quiescentRoot.appending(path: "workspace.json").path),
      "the audit manifest must survive destruction")
    let activeTree = URL(
      filePath: try XCTUnwrap(registry.profile(for: activeRef)).projectRoot)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: activeTree.path),
      "a live reference must keep its tree byte-for-byte")

    // The input surface is closed: testimony cannot be supplied.
    let forged = try operationRequest(
      id: "workspace.sweep-isolated-copies",
      requestID: "request-sweep-forged",
      idempotencyKey: "idempotency-sweep-forged",
      inputs: [
        "retainLatestCount": .integer(0),
        "minimumQuiescentSeconds": .integer(0),
        "dryRun": .bool(true),
        "testimony": .array([.string(activeID)]),
      ])
    do {
      _ = try await engine.submit(try JSONEncoder().encode(forged))
      XCTFail("an undeclared testimony input must be refused at admission")
    } catch {
      // Named refusal from the closed catalog input schema.
    }
  }

  func testIsolationRevisionUsesTheCanonicalCopiedRootBehindAnAlias() async throws {
    let sourceRoot = try temporaryDirectory("canonical-source")
    try FileManager.default.createDirectory(
      at: sourceRoot.appending(path: "Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: sourceRoot.appending(path: "Sources/App.txt"))
    try Data([0x50, 0x4b, 0x03, 0x04, 0x41]).write(
      to: sourceRoot.appending(path: "Sources/Input.hap"))

    let stateContainer = try temporaryDirectory("canonical-state")
    let physicalState = stateContainer.appending(path: "physical", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: physicalState, withIntermediateDirectories: false)
    let logicalState = stateContainer.appending(path: "logical", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(
      atPath: logicalState.path, withDestinationPath: physicalState.lastPathComponent)

    let profile = try workspaceProfile(root: sourceRoot)
    let sourceRevision = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: profile.allowedFileGlobs)
    let isolatedRevision = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: ["Sources/App.txt"])
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let manager = try EvolutionWorkspaceManager(
      rootURL: logicalState.appending(path: "evolution", directoryHint: .isDirectory),
      profileRegistry: registry)
    let intent = WorkspaceIsolationIntent(
      runtimeOwnerID: "runtime-job-canonical-root",
      sourceProjectRef: profile.projectRef,
      expectedWorkspaceRevision: sourceRevision,
      isolatedWorkspaceRevision: isolatedRevision,
      createdAtUTC: timestamp,
      allowedFileGlobs: ["Sources/App.txt"])

    let prepared = try await manager.prepare(intent)
    XCTAssertEqual(prepared.workspaceID, intent.workspaceID)
    let copiedProfile = try XCTUnwrap(registry.profile(for: intent.workspaceProjectRef))
    XCTAssertEqual(copiedProfile.kind, .evolution)
    XCTAssertTrue(copiedProfile.projectRoot.hasPrefix(physicalState.path + "/"))
    XCTAssertEqual(
      try WorkspaceProviderSupport.workspaceRevision(
        root: copiedProfile.projectRoot, profileVersion: copiedProfile.profileID,
        globs: ["Sources/App.txt"]),
      isolatedRevision)
    XCTAssertEqual(try manager.inspect(intent), .prepared(prepared))
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

  private func workspaceProfile(
    root: URL,
    projectRef: String = "RuntimeIsolationProject",
    includesSourceReader: Bool = false
  ) throws -> WorkspaceProjectProfile {
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
    let sourceReader: WorkspaceCommandPreset?
    if includesSourceReader {
      sourceReader = try WorkspaceCommandPreset(
        presetID: "source-reader",
        executable: WorkspaceExecutableIdentity.hashing(path: "/usr/bin/sed"),
        fixedArguments: [], timeoutSeconds: 10)
    } else {
      sourceReader = nil
    }
    return try WorkspaceProjectProfile(
      profileID: "runtime-isolation-test@1", projectRef: projectRef,
      projectRoot: root.path, allowedFileGlobs: ["Sources/**"],
      inspectionPreset: inspection, sourceReaderPreset: sourceReader,
      patchPreset: patching,
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
    artifactStore: RuntimeArtifactStore,
    workspaceProjectStore: RuntimeWorkspaceProjectStore? = nil
  ) throws -> RuntimeJobEngine {
    try RuntimeJobEngine(
      configuration: .init(stateDirectory: stateRoot),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: RuntimeProcessDispatcherRouter(
        hdc: dispatcher, rockchip: dispatcher, workspace: dispatcher),
      capabilityStore: capabilityStore, artifactStore: artifactStore,
      workspaceProjectStore: workspaceProjectStore,
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
