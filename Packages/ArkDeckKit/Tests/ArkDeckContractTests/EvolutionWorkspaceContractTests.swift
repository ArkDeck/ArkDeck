import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckAgentComposition
@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

final class EvolutionWorkspaceContractTests: XCTestCase {
  private var roots: [URL] = []

  override func tearDownWithError() throws {
    for root in roots { try? FileManager.default.removeItem(at: root) }
    roots = []
  }

  /// `HFA-AC-24` — the isolated workspace outlives the process that made it.
  ///
  /// Registration happens only on the creation path, so a daemon restart used
  /// to leave a task's `evolution-…` reference unresolvable while its files sat
  /// intact on disk. Everything downstream then failed for reasons that named
  /// something else: on 7.0.0.37 GJ-5 spent three rounds reporting the
  /// workspace revision had "changed to none" and stopped claiming the
  /// evidence was insufficient.
  func testAPersistedEvolutionWorkspaceIsAdoptedByANewProcess() async throws {
    let sourceRoot = try temporaryDirectory("adopt-source")
    let stateRoot = try temporaryDirectory("adopt-state")
    try FileManager.default.createDirectory(
      at: sourceRoot.appending(path: "Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: sourceRoot.appending(path: "Sources/App.txt"))
    let profile = try workspaceProfile(root: sourceRoot)
    let policy = try EvolutionWorkspacePolicy(
      baseRevision: try WorkspaceProviderSupport.workspaceRevision(
        root: profile.projectRoot, profileVersion: profile.profileID,
        globs: ["Sources/**"]),
      allowedPaths: ["Sources/**"], maxAttempts: 3, maxChangedFiles: 2,
      maxDiffLines: 20, allowedOperations: ["workspace.build-openharmony@1"])
    let evolutionRoot = stateRoot.appending(path: "evolution")

    let created = WorkspaceProjectProfileRegistry(profile: profile)
    let workspace = try await EvolutionWorkspaceManager(
      rootURL: evolutionRoot, profileRegistry: created
    ).prepareWorkspace(
      htaskID: "HTASK-ADOPT-001", sourceProjectRef: profile.projectRef,
      policy: policy, createdAtUTC: timestamp)
    let original = try XCTUnwrap(created.profile(for: workspace.projectRef))

    // A new process: the same trees on disk, a registry that has only ever
    // seen the source profile.
    let restarted = WorkspaceProjectProfileRegistry(profile: profile)
    let recovered = try EvolutionWorkspaceManager(
      rootURL: evolutionRoot, profileRegistry: restarted)
    XCTAssertNil(
      restarted.profile(for: workspace.projectRef),
      "precondition: a fresh registry cannot know a workspace it never created")

    try await recovered.adoptPersistedWorkspace(workspace, policy: policy)

    let adopted = try XCTUnwrap(
      restarted.profile(for: workspace.projectRef),
      "a workspace that survived on disk must survive in the registry")
    XCTAssertEqual(adopted, original, "adoption must reconstruct the same identity")
    XCTAssertEqual(adopted.kind, .evolution)
    XCTAssertNotEqual(
      adopted.projectRoot, profile.projectRoot,
      "adoption must never fall back to the source tree; that cancels the isolation")
  }

  /// `HFA-AC-24` — adoption refuses rather than rebuilds.
  func testAdoptionRefusesAManifestItDoesNotAgreeWith() async throws {
    let sourceRoot = try temporaryDirectory("adopt-conflict-source")
    let stateRoot = try temporaryDirectory("adopt-conflict-state")
    try FileManager.default.createDirectory(
      at: sourceRoot.appending(path: "Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: sourceRoot.appending(path: "Sources/App.txt"))
    let profile = try workspaceProfile(root: sourceRoot)
    let policy = try EvolutionWorkspacePolicy(
      baseRevision: try WorkspaceProviderSupport.workspaceRevision(
        root: profile.projectRoot, profileVersion: profile.profileID,
        globs: ["Sources/**"]),
      allowedPaths: ["Sources/**"], maxAttempts: 3, maxChangedFiles: 2,
      maxDiffLines: 20, allowedOperations: ["workspace.build-openharmony@1"])
    let evolutionRoot = stateRoot.appending(path: "evolution")
    let created = WorkspaceProjectProfileRegistry(profile: profile)
    let workspace = try await EvolutionWorkspaceManager(
      rootURL: evolutionRoot, profileRegistry: created
    ).prepareWorkspace(
      htaskID: "HTASK-ADOPT-002", sourceProjectRef: profile.projectRef,
      policy: policy, createdAtUTC: timestamp)

    let restarted = WorkspaceProjectProfileRegistry(profile: profile)
    let recovered = try EvolutionWorkspaceManager(
      rootURL: evolutionRoot, profileRegistry: restarted)
    // The same workspace identity claiming a base revision the manifest never
    // recorded. Rebuilding it silently would substitute one isolated tree for
    // another under a reference the task already holds.
    let drifted = EvolutionWorkspaceRecord(
      workspaceID: workspace.workspaceID, htaskID: workspace.htaskID,
      sourceProjectRef: workspace.sourceProjectRef, projectRef: workspace.projectRef,
      baseRevision: String(repeating: "9", count: 64),
      allowedPathsDigest: workspace.allowedPathsDigest,
      createdAtUTC: workspace.createdAtUTC)
    do {
      try await recovered.adoptPersistedWorkspace(drifted, policy: policy)
      XCTFail("adoption must refuse a workspace the manifest does not describe")
    } catch {
      XCTAssertNil(
        restarted.profile(for: workspace.projectRef),
        "a refused adoption must leave nothing registered")
    }
  }

  func testEvolutionWorkspaceIsIsolatedAndExistingRuntimeProviderResolvesIt() async throws {
    let sourceRoot = try temporaryDirectory("evolution-source")
    let stateRoot = try temporaryDirectory("evolution-state")
    try FileManager.default.createDirectory(
      at: sourceRoot.appending(path: "Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(
      to: sourceRoot.appending(path: "Sources/App.txt"))
    let profile = try workspaceProfile(root: sourceRoot)
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let revision = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: ["Sources/**"])
    let policy = try EvolutionWorkspacePolicy(
      baseRevision: revision, allowedPaths: ["Sources/**"], maxAttempts: 3,
      maxChangedFiles: 2, maxDiffLines: 20,
      allowedOperations: ["workspace.build-openharmony@1"])
    let manager = try EvolutionWorkspaceManager(
      rootURL: stateRoot.appending(path: "evolution"),
      profileRegistry: registry)

    let workspace = try await manager.prepareWorkspace(
      htaskID: "HTASK-EVOLUTION-001", sourceProjectRef: profile.projectRef,
      policy: policy, createdAtUTC: timestamp)
    try await manager.prepareAttemptDirectory(
      workspace: workspace, attemptID: "ATTEMPT-001", ordinal: 1,
      createdAtUTC: timestamp)
    let reopened = try await manager.prepareWorkspace(
      htaskID: "HTASK-EVOLUTION-001", sourceProjectRef: profile.projectRef,
      policy: policy, createdAtUTC: timestamp)
    XCTAssertEqual(reopened, workspace)

    let isolated = try XCTUnwrap(registry.profile(for: workspace.projectRef))
    XCTAssertEqual(isolated.kind, .evolution)
    XCTAssertNotEqual(isolated.projectRoot, profile.projectRoot)
    XCTAssertNil(isolated.sourceControlPreset)
    try Data("candidate\n".utf8).write(
      to: URL(filePath: isolated.projectRoot)
        .appending(path: "Sources/App.txt"))
    XCTAssertEqual(
      try String(
        contentsOf: sourceRoot.appending(path: "Sources/App.txt"), encoding: .utf8),
      "old\n")

    let provider = WorkspaceOperationsProvider(
      profile: profile, profileRegistry: registry,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: stateRoot.appending(path: "patch-attempts")),
      nowUTC: { "2026-08-02T00:00:00Z" })
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "workspace.build-openharmony@1"))
    let context = ProviderExecutionContext(
      jobID: "job-evolution-build", stepID: descriptor.steps[0].stepID,
      targetID: "workspace-test", bindingRevision: nil, nowUTC: timestamp)
    let action = try provider.action(
      for: descriptor.steps[0], operation: descriptor,
      inputs: [
        "projectRef": .string(workspace.projectRef),
        "buildPresetRef": .string("build-ok"),
      ], context: context)
    XCTAssertEqual(
      try provider.lower(action: action, context: context).workingDirectory,
      isolated.projectRoot)
  }

  func testInvalidAndStaleWorkspaceRevisionFailClosed() async throws {
    XCTAssertThrowsError(
      try EvolutionWorkspacePolicy(
        baseRevision: "not-a-revision", allowedPaths: ["Sources/**"],
        allowedOperations: ["workspace.apply-patch@1"])
    ) { error in
      XCTAssertEqual(error as? EvolutionWorkspacePolicyError, .invalidBaseRevision)
    }

    let root = try temporaryDirectory("stale-source")
    let state = try temporaryDirectory("stale-state")
    try FileManager.default.createDirectory(
      at: root.appending(path: "Sources"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: root.appending(path: "Sources/App.txt"))
    let profile = try workspaceProfile(root: root)
    let manager = try EvolutionWorkspaceManager(
      rootURL: state.appending(path: "evolution"),
      profileRegistry: WorkspaceProjectProfileRegistry(profile: profile))
    let stale = try EvolutionWorkspacePolicy(
      baseRevision: String(repeating: "f", count: 64), allowedPaths: ["Sources/**"],
      allowedOperations: ["workspace.apply-patch@1"])
    do {
      _ = try await manager.prepareWorkspace(
        htaskID: "HTASK-STALE", sourceProjectRef: profile.projectRef,
        policy: stale, createdAtUTC: timestamp)
      XCTFail("stale workspace admission must fail")
    } catch let error as EvolutionWorkspaceError {
      guard case .baseRevisionMismatch(let expected, let actual) = error else {
        return XCTFail("unexpected error \(error)")
      }
      XCTAssertEqual(expected, String(repeating: "f", count: 64))
      XCTAssertNotEqual(actual, expected)
    }
  }

  func testEvolutionWorkspaceRejectsRelativeSymlinkEscapingTheSourceTree() async throws {
    let source = try temporaryDirectory("symlink-source")
    let external = try temporaryDirectory("symlink-external")
    let state = try temporaryDirectory("symlink-state")
    try FileManager.default.createDirectory(
      at: source.appending(path: "Sources/Safe"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(
      to: source.appending(path: "Sources/Safe/App.txt"))
    try Data("secret\n".utf8).write(to: external.appending(path: "secret.txt"))
    try FileManager.default.createDirectory(
      at: source.appending(path: "Other"), withIntermediateDirectories: true)
    let relativeEscape = "../../\(external.lastPathComponent)/secret.txt"
    try FileManager.default.createSymbolicLink(
      atPath: source.appending(path: "Other/escape").path,
      withDestinationPath: relativeEscape)
    let profile = try workspaceProfile(root: source)
    let base = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: ["Sources/Safe/**"])
    let policy = try EvolutionWorkspacePolicy(
      baseRevision: base, allowedPaths: ["Sources/Safe/**"],
      allowedOperations: ["workspace.apply-patch@1"])
    let manager = try EvolutionWorkspaceManager(
      rootURL: state.appending(path: "evolution"),
      profileRegistry: WorkspaceProjectProfileRegistry(profile: profile))

    do {
      _ = try await manager.prepareWorkspace(
        htaskID: "HTASK-SYMLINK", sourceProjectRef: profile.projectRef,
        policy: policy, createdAtUTC: timestamp)
      XCTFail("an escaping relative symlink must never enter an Evolution workspace")
    } catch let error as EvolutionWorkspaceError {
      XCTAssertEqual(error, .unsafeSourceEntry("Other/escape"))
    }
  }

  func testEvolutionWorkspaceRewritesAbsoluteInSourceSymlinkToARelativeLink() async throws {
    let source = try temporaryDirectory("absolute-symlink-source")
    let state = try temporaryDirectory("absolute-symlink-state")
    try FileManager.default.createDirectory(
      at: source.appending(path: "Sources/Safe"), withIntermediateDirectories: true)
    let app = source.appending(path: "Sources/Safe/App.txt")
    try Data("old\n".utf8).write(to: app)
    try FileManager.default.createDirectory(
      at: source.appending(path: "Other"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: source.appending(path: "Other/primary-link").path,
      withDestinationPath: app.path)
    let profile = try workspaceProfile(root: source)
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let policy = try EvolutionWorkspacePolicy(
      baseRevision: try WorkspaceProviderSupport.workspaceRevision(
        root: profile.projectRoot, profileVersion: profile.profileID,
        globs: ["Sources/Safe/**"]),
      allowedPaths: ["Sources/Safe/**"],
      allowedOperations: ["workspace.apply-patch@1"])
    let manager = try EvolutionWorkspaceManager(
      rootURL: state.appending(path: "evolution"),
      profileRegistry: registry)

    let workspace = try await manager.prepareWorkspace(
      htaskID: "HTASK-ABSOLUTE-SYMLINK", sourceProjectRef: profile.projectRef,
      policy: policy, createdAtUTC: timestamp)

    // The invariant is unchanged — the copy must never retain a reference to
    // the primary tree. An absolute target that resolves inside the source is
    // admitted by rewriting it into the equivalent relative link.
    let isolated = try XCTUnwrap(registry.profile(for: workspace.projectRef))
    let copiedLink = URL(filePath: isolated.projectRoot)
      .appending(path: "Other/primary-link")
    let rewritten = try FileManager.default.destinationOfSymbolicLink(
      atPath: copiedLink.path)
    XCTAssertEqual(rewritten, "../Sources/Safe/App.txt")
    XCTAssertFalse(rewritten.hasPrefix("/"))
    XCTAssertEqual(try String(contentsOf: copiedLink, encoding: .utf8), "old\n")
    // Reading through the copy must not depend on the primary tree at all.
    try FileManager.default.removeItem(at: app)
    XCTAssertEqual(try String(contentsOf: copiedLink, encoding: .utf8), "old\n")
  }

  func testEvolutionWorkspaceRejectsAbsoluteSymlinkLeavingTheSourceTree() async throws {
    let source = try temporaryDirectory("absolute-escape-source")
    let external = try temporaryDirectory("absolute-escape-external")
    let state = try temporaryDirectory("absolute-escape-state")
    try FileManager.default.createDirectory(
      at: source.appending(path: "Sources/Safe"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: source.appending(path: "Sources/Safe/App.txt"))
    try Data("secret\n".utf8).write(to: external.appending(path: "secret.txt"))
    try FileManager.default.createDirectory(
      at: source.appending(path: "Other"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: source.appending(path: "Other/external-link").path,
      withDestinationPath: external.appending(path: "secret.txt").path)
    let profile = try workspaceProfile(root: source)
    let policy = try EvolutionWorkspacePolicy(
      baseRevision: try WorkspaceProviderSupport.workspaceRevision(
        root: profile.projectRoot, profileVersion: profile.profileID,
        globs: ["Sources/Safe/**"]),
      allowedPaths: ["Sources/Safe/**"],
      allowedOperations: ["workspace.apply-patch@1"])
    let manager = try EvolutionWorkspaceManager(
      rootURL: state.appending(path: "evolution"),
      profileRegistry: WorkspaceProjectProfileRegistry(profile: profile))

    do {
      _ = try await manager.prepareWorkspace(
        htaskID: "HTASK-ABSOLUTE-ESCAPE", sourceProjectRef: profile.projectRef,
        policy: policy, createdAtUTC: timestamp)
      XCTFail("an absolute symlink leaving the source tree must be refused")
    } catch let error as EvolutionWorkspaceError {
      XCTAssertEqual(error, .unsafeSourceEntry("Other/external-link"))
    }
  }

  func testEvolutionWorkspaceRefusesAnOversizedSourceFileBeforeCopyingIt() async throws {
    let source = try temporaryDirectory("oversized-source")
    let state = try temporaryDirectory("oversized-state")
    try FileManager.default.createDirectory(
      at: source.appending(path: "Sources/Safe"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: source.appending(path: "Sources/Safe/App.txt"))
    let oversized = source.appending(path: "oversized.bin")
    XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: UInt64(512 * 1_024 * 1_024 + 1))
    try handle.close()
    let profile = try workspaceProfile(root: source)
    let policy = try EvolutionWorkspacePolicy(
      baseRevision: try WorkspaceProviderSupport.workspaceRevision(
        root: profile.projectRoot, profileVersion: profile.profileID,
        globs: ["Sources/Safe/**"]),
      allowedPaths: ["Sources/Safe/**"],
      allowedOperations: ["workspace.apply-patch@1"])
    let manager = try EvolutionWorkspaceManager(
      rootURL: state.appending(path: "evolution"),
      profileRegistry: WorkspaceProjectProfileRegistry(profile: profile))

    do {
      _ = try await manager.prepareWorkspace(
        htaskID: "HTASK-OVERSIZED", sourceProjectRef: profile.projectRef,
        policy: policy, createdAtUTC: timestamp)
      XCTFail("an oversized source file must be rejected before an unbounded copy")
    } catch let error as EvolutionWorkspaceError {
      XCTAssertEqual(error, .unsafeSourceEntry("oversized.bin"))
    }
  }

  func testWorkspacePolicyConstructionEnforcesItsClosedBounds() throws {
    let base = String(repeating: "a", count: 64)
    XCTAssertNoThrow(
      try EvolutionWorkspacePolicy(
        baseRevision: base, allowedPaths: ["Sources/**"],
        allowedOperations: ["workspace.apply-patch@1"]))
    XCTAssertThrowsError(
      try EvolutionWorkspacePolicy(
        baseRevision: base, allowedPaths: ["Sources/**"],
        allowedOperations: ["flash.dayu200"])
    ) { error in
      XCTAssertEqual(
        error as? EvolutionWorkspacePolicyError,
        .destructiveOperationNotAllowed("flash.dayu200"))
    }
  }

  func testLineageDerivationFoldsAppliedAndRevertedAttemptsAndRefusesBrokenChains() {
    func attempt(
      _ ref: String, before: String, after: String, applied: String,
      reverted: String? = nil
    ) -> WorkspacePatchAttempt {
      WorkspacePatchAttempt(
        patchAttemptRef: ref, projectRef: "evolution-x", projectRoot: "/dev/null",
        patchArtifactID: "ART-x", patchFilePath: "/dev/null", patchSHA256: "",
        allowedFileGlobs: ["Sources/**"], before: [], after: [],
        workspaceRevisionBefore: before, workspaceRevisionAfter: after,
        appliedAtUTC: applied, revertedAtUTC: reverted)
    }
    let base = "b0"
    // No history vouches for exactly the base.
    XCTAssertEqual(
      EvolutionWorkspaceManager.lineageDerivedRevision(base: base, attempts: []), base)
    // Applied chain advances; a reverted attempt is a verified no-op.
    XCTAssertEqual(
      EvolutionWorkspaceManager.lineageDerivedRevision(
        base: base,
        attempts: [
          attempt("a", before: "b0", after: "r1", applied: "2026-01-01T00:00:00Z"),
          attempt("b", before: "r1", after: "r2", applied: "2026-01-02T00:00:00Z"),
          attempt(
            "c", before: "r2", after: "r3", applied: "2026-01-03T00:00:00Z",
            reverted: "2026-01-04T00:00:00Z"),
        ]), "r2")
    // A link whose `before` does not extend the current state cannot vouch.
    XCTAssertNil(
      EvolutionWorkspaceManager.lineageDerivedRevision(
        base: base,
        attempts: [
          attempt("a", before: "b0", after: "r1", applied: "2026-01-01T00:00:00Z"),
          attempt("b", before: "b0", after: "r2", applied: "2026-01-02T00:00:00Z"),
        ]))
    // A record without measured revisions cannot vouch for anything.
    XCTAssertNil(
      EvolutionWorkspaceManager.lineageDerivedRevision(
        base: base,
        attempts: [
          WorkspacePatchAttempt(
            patchAttemptRef: "a", projectRef: "evolution-x", projectRoot: "/dev/null",
            patchArtifactID: "ART-x", patchFilePath: "/dev/null", patchSHA256: "",
            allowedFileGlobs: [], before: [], after: [],
            workspaceRevisionBefore: nil, workspaceRevisionAfter: nil,
            appliedAtUTC: "2026-01-01T00:00:00Z", revertedAtUTC: nil)
        ]))
  }

  func testAdoptionAcceptsALineageDerivedRevisionAndStillRefusesTampering() async throws {
    let source = try temporaryDirectory("lineage-source")
    let state = try temporaryDirectory("lineage-state")
    try FileManager.default.createDirectory(
      at: source.appending(path: "Sources/Safe"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: source.appending(path: "Sources/Safe/App.txt"))
    let profile = try workspaceProfile(root: source)
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let allowedPaths = ["Sources/Safe/**"]
    let policy = try EvolutionWorkspacePolicy(
      baseRevision: try WorkspaceProviderSupport.workspaceRevision(
        root: profile.projectRoot, profileVersion: profile.profileID, globs: allowedPaths),
      allowedPaths: allowedPaths,
      allowedOperations: ["workspace.apply-patch@1"])
    let attempts = try WorkspacePatchAttemptStore(
      rootURL: state.appending(path: "patch-attempts"))
    let manager = try EvolutionWorkspaceManager(
      rootURL: state.appending(path: "evolution"),
      profileRegistry: registry, patchLineage: attempts)
    let workspace = try await manager.prepareWorkspace(
      htaskID: "runtime-job-lineage", sourceProjectRef: profile.projectRef,
      policy: policy, createdAtUTC: timestamp)
    let isolated = try XCTUnwrap(registry.profile(for: workspace.projectRef))
    let copiedFile = URL(filePath: isolated.projectRoot)
      .appending(path: "Sources/Safe/App.txt")

    // The runtime's own patch history vouches for the drifted revision.
    let before = try WorkspaceProviderSupport.workspaceRevision(
      root: isolated.projectRoot, profileVersion: profile.profileID, globs: allowedPaths)
    XCTAssertEqual(before, workspace.baseRevision)
    try Data("patched\n".utf8).write(to: copiedFile)
    let after = try WorkspaceProviderSupport.workspaceRevision(
      root: isolated.projectRoot, profileVersion: profile.profileID, globs: allowedPaths)
    try attempts.save(
      WorkspacePatchAttempt(
        patchAttemptRef: "patch-" + String(repeating: "a", count: 32),
        projectRef: workspace.projectRef, projectRoot: isolated.projectRoot,
        patchArtifactID: "ART-lineage", patchFilePath: "/dev/null", patchSHA256: "",
        allowedFileGlobs: allowedPaths, before: [], after: [],
        workspaceRevisionBefore: before, workspaceRevisionAfter: after,
        appliedAtUTC: "2026-08-19T00:00:00Z", revertedAtUTC: nil))

    let restartedRegistry = WorkspaceProjectProfileRegistry(profile: profile)
    let restarted = try EvolutionWorkspaceManager(
      rootURL: state.appending(path: "evolution"),
      profileRegistry: restartedRegistry, patchLineage: attempts)
    XCTAssertEqual(restarted.adoptRuntimeWorkspaces(), [])
    XCTAssertNotNil(restartedRegistry.profile(for: workspace.projectRef))

    // A mutation the lineage never recorded keeps the named refusal.
    try Data("tampered\n".utf8).write(to: copiedFile)
    let tamperedRegistry = WorkspaceProjectProfileRegistry(profile: profile)
    let tampered = try EvolutionWorkspaceManager(
      rootURL: state.appending(path: "evolution"),
      profileRegistry: tamperedRegistry, patchLineage: attempts)
    XCTAssertEqual(
      tampered.adoptRuntimeWorkspaces(), ["\(workspace.workspaceID):revision"])
    XCTAssertNil(tamperedRegistry.profile(for: workspace.projectRef))
  }

  func testWorkspaceGCDestroysOnlyTerminalTreesAndKeepsAuditMetadata() async throws {
    let fixture = try gcFixture("gc-basic")
    let terminal = try await fixture.prepare("HTASK-GC0000000001")
    let active = try await fixture.prepare("HTASK-GC0000000002")
    let unknown = try await fixture.prepare("HTASK-GC0000000003")
    try await fixture.manager.prepareAttemptDirectory(
      workspace: terminal, attemptID: "ATTEMPT-001", ordinal: 1, createdAtUTC: timestamp)

    let findings = try await fixture.manager.sweepTerminalWorkspaces(
      tasks: [
        EvolutionWorkspaceGCTaskReference(
          workspaceID: terminal.workspaceID, htaskID: terminal.htaskID,
          lifecycle: .init(rawValue: "succeeded", isTerminal: true), updatedAtUTC: "2026-08-01T00:00:00Z"),
        EvolutionWorkspaceGCTaskReference(
          workspaceID: active.workspaceID, htaskID: active.htaskID,
          lifecycle: .init(rawValue: "running", isTerminal: false), updatedAtUTC: "2026-08-01T00:00:00Z"),
      ],
      retention: try EvolutionWorkspaceRetention(
        minimumTerminalAgeSeconds: 0, retainLatestTerminalCount: 0),
      nowUTC: "2026-08-02T12:00:00Z")

    let byWorkspace = Dictionary(
      uniqueKeysWithValues: findings.map { ($0.workspaceID, $0) })
    XCTAssertEqual(byWorkspace[terminal.workspaceID]?.disposition, .destroyed)
    XCTAssertEqual(byWorkspace[active.workspaceID]?.disposition, .activeRetained)
    XCTAssertEqual(byWorkspace[unknown.workspaceID]?.disposition, .unknownTaskRetained)
    XCTAssertGreaterThan(
      try XCTUnwrap(byWorkspace[terminal.workspaceID]).reclaimedBytes, 0)

    // The isolated tree is gone; the audit metadata and the attempt
    // manifests survive, and a teardown record now exists.
    let terminalRoot = fixture.workspaceRoot(terminal)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: terminalRoot.appending(path: "workspace").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: terminalRoot.appending(path: "workspace.json").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: terminalRoot.appending(path: "attempts/attempt-001/attempt.json").path))
    let teardown = try XCTUnwrap(
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: terminalRoot.appending(path: "teardown.json")))
        as? [String: Any])
    XCTAssertEqual(teardown["documentType"] as? String, "evolution-workspace-teardown")
    XCTAssertEqual(teardown["htaskID"] as? String, terminal.htaskID)
    XCTAssertEqual(teardown["lifecycle"] as? String, "succeeded")

    // The derived profile of the destroyed tree fails at resolution; the
    // active and unknown ones keep resolving, and their trees are intact.
    XCTAssertNil(fixture.registry.profile(for: terminal.projectRef))
    XCTAssertNotNil(fixture.registry.profile(for: active.projectRef))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: fixture.workspaceRoot(active).appending(path: "workspace").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: fixture.workspaceRoot(unknown).appending(path: "workspace").path))

    // Recoverability: the active workspace still reopens idempotently; the
    // destroyed one refuses to impersonate a live tree.
    let reopened = try await fixture.prepare(active.htaskID)
    XCTAssertEqual(reopened, active)
    do {
      _ = try await fixture.prepare(terminal.htaskID)
      XCTFail("a swept workspace must not reopen")
    } catch let error as EvolutionWorkspaceError {
      XCTAssertEqual(error, .workspaceAlreadyDestroyed(terminal.workspaceID))
    }

    // A second sweep is idempotent: nothing new to reclaim.
    let second = try await fixture.manager.sweepTerminalWorkspaces(
      tasks: [
        EvolutionWorkspaceGCTaskReference(
          workspaceID: terminal.workspaceID, htaskID: terminal.htaskID,
          lifecycle: .init(rawValue: "succeeded", isTerminal: true), updatedAtUTC: "2026-08-01T00:00:00Z")
      ],
      retention: try EvolutionWorkspaceRetention(
        minimumTerminalAgeSeconds: 0, retainLatestTerminalCount: 0),
      nowUTC: "2026-08-02T13:00:00Z")
    XCTAssertEqual(
      second.first { $0.workspaceID == terminal.workspaceID }?.disposition,
      .alreadyDestroyed)
  }

  func testWorkspaceGCRetentionKeepsLatestAndYoungTerminalTrees() async throws {
    let fixture = try gcFixture("gc-retention")
    let oldest = try await fixture.prepare("HTASK-GCAGE0000001")
    let young = try await fixture.prepare("HTASK-GCAGE0000002")
    let newest = try await fixture.prepare("HTASK-GCAGE0000003")
    let references = [
      EvolutionWorkspaceGCTaskReference(
        workspaceID: oldest.workspaceID, htaskID: oldest.htaskID,
        lifecycle: .init(rawValue: "failed", isTerminal: true), updatedAtUTC: "2026-07-20T00:00:00Z"),
      EvolutionWorkspaceGCTaskReference(
        workspaceID: young.workspaceID, htaskID: young.htaskID,
        lifecycle: .init(rawValue: "cancelled", isTerminal: true), updatedAtUTC: "2026-07-30T00:00:00Z"),
      EvolutionWorkspaceGCTaskReference(
        workspaceID: newest.workspaceID, htaskID: newest.htaskID,
        lifecycle: .init(rawValue: "succeeded", isTerminal: true), updatedAtUTC: "2026-08-02T11:00:00Z"),
    ]
    let retention = try EvolutionWorkspaceRetention(
      minimumTerminalAgeSeconds: 7 * 86_400, retainLatestTerminalCount: 1)

    // Dry run decides identically but touches nothing.
    let preview = try await fixture.manager.sweepTerminalWorkspaces(
      tasks: references,
      retention: try EvolutionWorkspaceRetention(
        minimumTerminalAgeSeconds: retention.minimumTerminalAgeSeconds,
        retainLatestTerminalCount: retention.retainLatestTerminalCount, dryRun: true),
      nowUTC: "2026-08-02T12:00:00Z")
    let previewed = Dictionary(uniqueKeysWithValues: preview.map { ($0.workspaceID, $0) })
    XCTAssertEqual(previewed[oldest.workspaceID]?.disposition, .wouldDestroy)
    XCTAssertEqual(previewed[young.workspaceID]?.disposition, .retainedByPolicy)
    XCTAssertEqual(previewed[newest.workspaceID]?.disposition, .retainedByPolicy)
    for workspace in [oldest, young, newest] {
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: fixture.workspaceRoot(workspace).appending(path: "workspace").path))
    }

    let findings = try await fixture.manager.sweepTerminalWorkspaces(
      tasks: references, retention: retention, nowUTC: "2026-08-02T12:00:00Z")
    let byWorkspace = Dictionary(uniqueKeysWithValues: findings.map { ($0.workspaceID, $0) })
    // Only the tree both older than the age floor and outside the
    // latest-count window is reclaimed.
    XCTAssertEqual(byWorkspace[oldest.workspaceID]?.disposition, .destroyed)
    XCTAssertEqual(byWorkspace[young.workspaceID]?.disposition, .retainedByPolicy)
    XCTAssertEqual(byWorkspace[newest.workspaceID]?.disposition, .retainedByPolicy)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.workspaceRoot(oldest).appending(path: "workspace").path))
    for workspace in [young, newest] {
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: fixture.workspaceRoot(workspace).appending(path: "workspace").path))
    }
  }

  func testWorkspaceGCResumesInterruptedTeardownAndRemovesStaleTemporaries() async throws {
    let fixture = try gcFixture("gc-resume")
    let workspace = try await fixture.prepare("HTASK-GCRESUME001")
    let taskRoot = fixture.workspaceRoot(workspace)
    // Simulate a teardown that crashed between the rename and the removal,
    // with a stale copy temporary from an interrupted prepare next to it.
    try FileManager.default.moveItem(
      at: taskRoot.appending(path: "workspace"),
      to: taskRoot.appending(path: ".workspace.doomed"))
    try FileManager.default.createDirectory(
      at: taskRoot.appending(path: ".workspace.tmp"), withIntermediateDirectories: false)
    try Data("stale\n".utf8).write(
      to: taskRoot.appending(path: ".workspace.tmp/leftover.txt"))

    let findings = try await fixture.manager.sweepTerminalWorkspaces(
      tasks: [
        EvolutionWorkspaceGCTaskReference(
          workspaceID: workspace.workspaceID, htaskID: workspace.htaskID,
          lifecycle: .init(rawValue: "failed", isTerminal: true), updatedAtUTC: "2026-08-01T00:00:00Z")
      ],
      retention: try EvolutionWorkspaceRetention(
        minimumTerminalAgeSeconds: 0, retainLatestTerminalCount: 0),
      nowUTC: "2026-08-02T12:00:00Z")

    XCTAssertEqual(findings.first?.disposition, .destroyed)
    XCTAssertGreaterThan(try XCTUnwrap(findings.first).reclaimedBytes, 0)
    for doomed in ["workspace", ".workspace.doomed", ".workspace.tmp"] {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: taskRoot.appending(path: doomed).path))
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: taskRoot.appending(path: "teardown.json").path))
  }

  private struct EvolutionGCFixture {
    let manager: EvolutionWorkspaceManager
    let registry: WorkspaceProjectProfileRegistry
    let managerRoot: URL
    let sourceProjectRef: String
    let policy: EvolutionWorkspacePolicy
    let createdAtUTC: String

    func prepare(_ htaskID: String) async throws -> EvolutionWorkspaceRecord {
      try await manager.prepareWorkspace(
        htaskID: htaskID, sourceProjectRef: sourceProjectRef,
        policy: policy, createdAtUTC: createdAtUTC)
    }

    func workspaceRoot(_ workspace: EvolutionWorkspaceRecord) -> URL {
      managerRoot.appending(path: workspace.workspaceID, directoryHint: .isDirectory)
    }
  }

  private func gcFixture(_ prefix: String) throws -> EvolutionGCFixture {
    let source = try temporaryDirectory("\(prefix)-source")
    let state = try temporaryDirectory("\(prefix)-state")
    try FileManager.default.createDirectory(
      at: source.appending(path: "Sources"), withIntermediateDirectories: true)
    try Data("payload\n".utf8).write(to: source.appending(path: "Sources/App.txt"))
    let profile = try workspaceProfile(root: source)
    let registry = WorkspaceProjectProfileRegistry(profile: profile)
    let base = try WorkspaceProviderSupport.workspaceRevision(
      root: profile.projectRoot, profileVersion: profile.profileID,
      globs: ["Sources/**"])
    let managerRoot = state.appending(path: "evolution", directoryHint: .isDirectory)
    return EvolutionGCFixture(
      manager: try EvolutionWorkspaceManager(
        rootURL: managerRoot, profileRegistry: registry),
      registry: registry,
      managerRoot: managerRoot,
      sourceProjectRef: profile.projectRef,
      policy: try EvolutionWorkspacePolicy(
        baseRevision: base, allowedPaths: ["Sources/**"], maxAttempts: 3,
        maxChangedFiles: 2, maxDiffLines: 20,
        allowedOperations: evolutionOperations),
      createdAtUTC: timestamp)
  }

  private var timestamp: String { "2026-08-02T00:00:00Z" }
  private var evolutionOperations: [String] {
    [
      "workspace.apply-patch@1", "workspace.build-openharmony@1",
      "workspace.run-tests@1", "debug.hap@1", "workspace.revert-patch@1",
    ]
  }
  private func temporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path:
        "arkdeck-\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    roots.append(url)
    return url
  }

  private func workspaceProfile(root: URL) throws -> WorkspaceProjectProfile {
    let grep = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/grep")
    let patch = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/patch")
    let printf = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/printf")
    let inspection = try WorkspaceCommandPreset(
      presetID: "inspect", executable: grep, fixedArguments: [], timeoutSeconds: 10)
    let patching = try WorkspaceCommandPreset(
      presetID: "patch", executable: patch, fixedArguments: [], timeoutSeconds: 10)
    let build = try WorkspaceCommandPreset(
      presetID: "build-ok", executable: printf,
      fixedArguments: ["BUILD_OK\n"], timeoutSeconds: 10)
    let tests = try WorkspaceCommandPreset(
      presetID: "tests-ok", executable: printf,
      fixedArguments: ["TESTS_OK\n"], timeoutSeconds: 10)
    return try WorkspaceProjectProfile(
      profileID: "evolution-test@1", projectRef: "TestProject",
      projectRoot: root.path, allowedFileGlobs: ["Sources/**"],
      inspectionPreset: inspection, patchPreset: patching,
      buildPresets: [build.presetID: build], testPresets: [tests.presetID: tests],
      symbolPresets: [:])
  }
}
