// Exact base revision binding (CHG-2026-055, TASK-HFA-009 r1).
//
// Registered acceptance: HFA-AC-18, in part — the revision half. The
// capability-subject half is not here, and deliberately so: the engine
// short-circuits authorization for `effect <= .readOnly`, and every
// workspace operation declares `hostOnly`. A workspace-scoped capability
// would therefore be unreachable code until the effect classification
// changes, which is a breaking change to published operations and a
// maintainer decision.
//
// What is reachable today is the part that stops a patch from landing on a
// tree nobody looked at: a caller states the revision it decided against,
// and the provider refuses if the tree has moved.

import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class WorkspaceRevisionBindingContractTests: XCTestCase {
  private var root: URL!
  private var state: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkdeck-workspace-revision", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    state = root.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Sources", isDirectory: true),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data("one\n".utf8).write(to: root.appendingPathComponent("Sources/App.txt"))
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  // MARK: - What the revision is made of

  func testTheRevisionIsStableForAnUnchangedTree() throws {
    let first = try revision()
    let second = try revision()
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.count, 64)
  }

  func testAWorkingTreeEditMovesTheRevision() throws {
    let before = try revision()
    try Data("two\n".utf8).write(to: root.appendingPathComponent("Sources/App.txt"))
    // A dirty worktree is exactly what a HEAD-only revision would miss, and
    // it is the case that matters: the decision was made against these bytes.
    XCTAssertNotEqual(before, try revision())
  }

  func testHeadAndIndexBothParticipate() throws {
    let git = root.appendingPathComponent(".git", isDirectory: true)
    try FileManager.default.createDirectory(
      at: git.appendingPathComponent("refs/heads", isDirectory: true),
      withIntermediateDirectories: true)
    try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
    try Data("a".utf8).write(to: git.appendingPathComponent("index"))
    let oid = String(repeating: "ab", count: 20)
    try Data((oid + "\n").utf8).write(to: git.appendingPathComponent("refs/heads/main"))
    let atFirstCommit = try revision()

    // Moving HEAD moves the revision even when no file changed.
    let moved = String(repeating: "cd", count: 20)
    try Data((moved + "\n").utf8).write(to: git.appendingPathComponent("refs/heads/main"))
    XCTAssertNotEqual(atFirstCommit, try revision())

    // Staging moves it too: the index is part of what "this tree" means.
    try Data((moved + "\n").utf8).write(to: git.appendingPathComponent("refs/heads/main"))
    let afterHeadMove = try revision()
    try Data("b".utf8).write(to: git.appendingPathComponent("index"))
    XCTAssertNotEqual(afterHeadMove, try revision())
  }

  func testAPackedRefResolvesRatherThanReadingAsAbsent() throws {
    let git = root.appendingPathComponent(".git", isDirectory: true)
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
    let withoutRef = try revision()
    let oid = String(repeating: "ef", count: 20)
    try Data("# pack-refs with: peeled\n\(oid) refs/heads/main\n".utf8)
      .write(to: git.appendingPathComponent("packed-refs"))
    // A repository whose branch is packed is not a repository with no HEAD.
    XCTAssertNotEqual(withoutRef, try revision())
  }

  func testTheIdentityIsTheTreeAndNotItsContents() throws {
    let identity = WorkspaceProviderSupport.workspaceIdentity(
      root: root.path, profileID: "test-workspace@1")
    try Data("changed\n".utf8).write(to: root.appendingPathComponent("Sources/App.txt"))
    XCTAssertEqual(
      identity,
      WorkspaceProviderSupport.workspaceIdentity(root: root.path, profileID: "test-workspace@1"))
    XCTAssertNotEqual(
      identity,
      WorkspaceProviderSupport.workspaceIdentity(root: root.path, profileID: "other@1"))
  }

  // MARK: - What the binding refuses

  func testAMutationDeclaringAMovedRevisionIsRefused() throws {
    let provider = try makeProvider()
    let stale = try revision()
    try Data("three\n".utf8).write(to: root.appendingPathComponent("Sources/App.txt"))

    XCTAssertThrowsError(
      try provider.action(
        for: buildStep(), operation: buildDescriptor(),
        inputs: [
          "projectRef": .string("TestProject"),
          "buildPresetRef": .string("build-ok"),
          "expectedWorkspaceRevision": .string(stale),
        ],
        context: context())
    ) { error in
      // Named, not generic: a reader has to be able to tell "the tree moved"
      // from "the preset is missing".
      XCTAssertTrue("\(error)".contains("workspace.revisionConflict"))
    }
  }

  func testAMutationDeclaringTheCurrentRevisionProceeds() throws {
    let provider = try makeProvider()
    let action = try provider.action(
      for: buildStep(), operation: buildDescriptor(),
      inputs: [
        "projectRef": .string("TestProject"),
        "buildPresetRef": .string("build-ok"),
        "expectedWorkspaceRevision": .string(try revision()),
      ],
      context: context())
    guard case .workspace(.buildOpenHarmony) = action else {
      return XCTFail("a matching revision must not block the build")
    }
  }

  func testAnUndeclaredRevisionIsNotSilentlyInvented() throws {
    // Omitting the field is legal and unchanged behaviour: this release adds
    // an enforceable statement, it does not require every caller to make one.
    let provider = try makeProvider()
    let action = try provider.action(
      for: buildStep(), operation: buildDescriptor(),
      inputs: ["projectRef": .string("TestProject"), "buildPresetRef": .string("build-ok")],
      context: context())
    guard case .workspace(.buildOpenHarmony) = action else {
      return XCTFail("an absent declaration must not fail the operation")
    }
  }

  func testTheMutatingOperationsAllDeclareTheField() throws {
    for reference in [
      "workspace.apply-patch@1", "workspace.build-openharmony@1",
      "workspace.revert-patch@1", "workspace.create-checkpoint@1",
    ] {
      let descriptor = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: reference))
      let field = descriptor.inputs.first { $0.name == "expectedWorkspaceRevision" }
      XCTAssertNotNil(field, "\(reference) must be able to state its base revision")
      XCTAssertEqual(field?.isRequired, false)
    }
  }

  // MARK: - Helpers

  private func revision() throws -> String {
    try WorkspaceProviderSupport.workspaceRevision(
      root: root.path, profileVersion: "test-workspace@1", globs: ["Sources/**"])
  }

  private func makeProvider() throws -> WorkspaceOperationsProvider {
    let grep = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/grep")
    let patch = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/patch")
    let printf = try WorkspaceExecutableIdentity.hashing(path: "/usr/bin/printf")
    let profile = try WorkspaceProjectProfile(
      profileID: "test-workspace@1", projectRef: "TestProject", projectRoot: root.path,
      allowedFileGlobs: ["Sources/**"],
      inspectionPreset: try WorkspaceCommandPreset(
        presetID: "inspect", executable: grep, fixedArguments: [], timeoutSeconds: 10),
      patchPreset: try WorkspaceCommandPreset(
        presetID: "patch", executable: patch, fixedArguments: [], timeoutSeconds: 10),
      buildPresets: [
        "build-ok": try WorkspaceCommandPreset(
          presetID: "build-ok", executable: printf, fixedArguments: ["BUILD_OK"],
          timeoutSeconds: 10)
      ],
      testPresets: [:], symbolPresets: [:])
    return WorkspaceOperationsProvider(
      profile: profile,
      attemptStore: try WorkspacePatchAttemptStore(
        rootURL: state.appendingPathComponent(UUID().uuidString, isDirectory: true)),
      nowUTC: { "2026-08-01T00:00:00Z" })
  }

  private func buildDescriptor() -> CatalogOperationDescriptor {
    RuntimeOperationCatalog.descriptor(reference: "workspace.build-openharmony@1")!
  }

  private func buildStep() -> CatalogStepDescriptor {
    buildDescriptor().steps[0]
  }

  private func context() -> ProviderExecutionContext {
    ProviderExecutionContext(
      jobID: "job-workspace", stepID: "build", targetID: "workspace-test",
      bindingRevision: nil, nowUTC: "2026-08-01T00:00:00Z")
  }
}
