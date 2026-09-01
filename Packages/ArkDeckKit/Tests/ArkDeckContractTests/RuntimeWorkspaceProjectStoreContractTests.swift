import Darwin
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class RuntimeWorkspaceProjectStoreContractTests: XCTestCase {
  private var stateDirectory: URL!

  override func setUpWithError() throws {
    stateDirectory = FileManager.default.temporaryDirectory.appending(
      path: "workspace-project-store-\(UUID())", directoryHint: .isDirectory)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: stateDirectory)
  }

  func testRegistrationIsDurableIdempotentAndKeepsTheRootPrivate() throws {
    let root = try makeRoot("first-project")
    let store = try RuntimeWorkspaceProjectStore(
      rootURL: stateDirectory, nowUTC: { "2026-09-01T12:00:00.000Z" })

    let registered = try store.register(
      requestID: "registration-1", kind: "arkdeck", rootPath: root.path)
    XCTAssertEqual(registered.generation, 1)
    XCTAssertEqual(registered.configurationStatus, "runtimeRestartRequired")
    let ownerDirectory = stateDirectory.appending(
      path: "workspace-projects", directoryHint: .isDirectory)
    let document = ownerDirectory.appending(path: "projects.json")
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: ownerDirectory.path)[.posixPermissions]
        as? NSNumber)?.intValue ?? -1,
      0o700)
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: document.path)[.posixPermissions]
        as? NSNumber)?.intValue ?? -1,
      0o600)
    XCTAssertEqual(
      try store.register(
        requestID: "registration-1", kind: "arkdeck", rootPath: root.path),
      registered)

    XCTAssertThrowsError(
      try store.register(
        requestID: "registration-1", kind: "openharmony", rootPath: root.path)
    ) { error in
      XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "idempotencyConflict")
    }

    let reopened = try RuntimeWorkspaceProjectStore(rootURL: stateDirectory)
    XCTAssertEqual(try reopened.list().map(\.projectRef), [registered.projectRef])
    let privateRecord = try XCTUnwrap(try reopened.compositionRecords().first)
    XCTAssertEqual(privateRecord.rootPath, root.path)

    let rendered = String(
      data: try JSONEncoder().encode(registered.projection), encoding: .utf8) ?? ""
    XCTAssertTrue(rendered.contains(registered.projectRef))
    XCTAssertFalse(rendered.contains(root.path))
    XCTAssertFalse(rendered.contains("root"))
  }

  func testGenerationCASAndUseTokenCloseUpdateAndRemoveRaces() throws {
    let firstRoot = try makeRoot("first-project")
    let secondRoot = try makeRoot("second-project")
    let store = try RuntimeWorkspaceProjectStore(rootURL: stateDirectory)
    let registered = try store.register(
      requestID: "registration-2", kind: "arkdeck", rootPath: firstRoot.path)
    store.markApplied([registered.projectRef: registered.generation])

    let use = try store.acquireUse(projectRef: registered.projectRef)
    for mutation in [
      {
        _ = try store.update(
          projectRef: registered.projectRef, expectedGeneration: 1,
          kind: "arkdeck", rootPath: secondRoot.path,
          requireNoActiveReference: { _ in })
      },
      {
        _ = try store.remove(
          projectRef: registered.projectRef, expectedGeneration: 1,
          requireNoActiveReference: { _ in })
      },
    ] {
      XCTAssertThrowsError(try mutation()) { error in
        XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "resourceConflict")
      }
    }
    store.endUse(use)

    let updated = try store.update(
      projectRef: registered.projectRef, expectedGeneration: 1,
      kind: "arkdeck", rootPath: secondRoot.path,
      requireNoActiveReference: { _ in })
    XCTAssertEqual(updated.generation, 2)
    XCTAssertEqual(updated.configurationStatus, "runtimeRestartRequired")
    XCTAssertThrowsError(
      try store.update(
        projectRef: registered.projectRef, expectedGeneration: 1,
        kind: "arkdeck", rootPath: firstRoot.path,
        requireNoActiveReference: { _ in })
    ) { error in
      XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "resourceConflict")
    }

    let removed = try store.remove(
      projectRef: registered.projectRef, expectedGeneration: 2,
      requireNoActiveReference: { _ in })
    XCTAssertEqual(removed.configurationStatus, "removed")
    XCTAssertTrue(try store.list().isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstRoot.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondRoot.path))
  }

  func testActiveDurableReferenceCheckRunsInsideTheMutationOwner() throws {
    let root = try makeRoot("first-project")
    let replacement = try makeRoot("replacement-project")
    let store = try RuntimeWorkspaceProjectStore(rootURL: stateDirectory)
    let registered = try store.register(
      requestID: "registration-3", kind: "arkdeck", rootPath: root.path)
    var checkedProjectRef: String?

    XCTAssertThrowsError(
      try store.update(
        projectRef: registered.projectRef, expectedGeneration: 1,
        kind: "arkdeck", rootPath: replacement.path,
        requireNoActiveReference: { projectRef in
          checkedProjectRef = projectRef
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "fixture active Job reference")
        })
    ) { error in
      XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "resourceConflict")
    }
    XCTAssertEqual(checkedProjectRef, registered.projectRef)
    XCTAssertEqual(try store.inspect(registered.projectRef).generation, 1)
  }

  func testSymlinkAndChangedRootIdentityFailClosed() throws {
    let root = try makeRoot("first-project")
    let symlink = stateDirectory.appending(path: "root-link")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root)
    let store = try RuntimeWorkspaceProjectStore(rootURL: stateDirectory)

    XCTAssertThrowsError(
      try store.register(
        requestID: "registration-link", kind: "arkdeck", rootPath: symlink.path)
    ) { error in
      XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "invalidInput")
    }

    let registered = try store.register(
      requestID: "registration-4", kind: "arkdeck", rootPath: root.path)
    store.markApplied([registered.projectRef: 1])
    let moved = stateDirectory.appending(path: "moved-project", directoryHint: .isDirectory)
    try FileManager.default.moveItem(at: root, to: moved)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

    let startup = try XCTUnwrap(try store.startupRecords().first)
    XCTAssertNil(startup.composition)
    XCTAssertEqual(startup.failure?.code, "factsDrifted")
    XCTAssertThrowsError(try store.acquireUse(projectRef: registered.projectRef)) { error in
      XCTAssertEqual((error as? RuntimeWorkspaceProjectFailure)?.code, "factsDrifted")
    }
  }

  private func makeRoot(_ name: String) throws -> URL {
    let root = stateDirectory.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard let canonical = realpath(root.path, nil) else { throw POSIXError(.ENOENT) }
    defer { free(canonical) }
    return URL(filePath: String(cString: canonical), directoryHint: .isDirectory)
  }
}
