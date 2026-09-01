import Darwin
import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class RuntimeUpdateStateStoreContractTests: XCTestCase {
  func testAppAndCLIResolveTheSameSandboxContainerDirectories() throws {
    let physicalHome = URL(filePath: "/Users/example")
    let containerLibrary = physicalHome
      .appending(path: "Library/Containers", directoryHint: .isDirectory)
      .appending(
        path: AutoUpdateFilesystemLayout.appBundleIdentifier,
        directoryHint: .isDirectory)
      .appending(path: "Data/Library", directoryHint: .isDirectory)
    for kind in ["Application Support", "Caches"] {
      let appDirectory = containerLibrary.appending(path: kind, directoryHint: .isDirectory)
      let fromApp = AutoUpdateFilesystemLayout.sharedDirectory(
        kind: kind,
        processBundleIdentifier: AutoUpdateFilesystemLayout.appBundleIdentifier,
        processDirectory: appDirectory,
        processHomeDirectory: containerLibrary.deletingLastPathComponent())
      let fromCLI = AutoUpdateFilesystemLayout.sharedDirectory(
        kind: kind,
        processBundleIdentifier: "com.arkdeck.cli",
        processDirectory: physicalHome.appending(path: "Library/\(kind)"),
        processHomeDirectory: physicalHome)
      XCTAssertEqual(fromCLI, fromApp)
    }

    let project = try String(
      contentsOf: repositoryRoot.appending(path: "ArkDeck.xcodeproj/project.pbxproj"),
      encoding: .utf8)
    XCTAssertTrue(
      project.contains(
        "PRODUCT_BUNDLE_IDENTIFIER = \(AutoUpdateFilesystemLayout.appBundleIdentifier);"),
      "the shared-container pin must match the App's signed bundle identifier")
  }

  func testDurableStateUsesGenerationCASAndSurvivesANewOwner() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixed = Date(timeIntervalSince1970: 1_788_225_600)
    let first = RuntimeUpdateStateStore(directory: root, now: { fixed })

    let initial = try first.load()
    XCTAssertEqual(initial.generation, 0)
    let laterOwner = RuntimeUpdateStateStore(
      directory: root, now: { fixed.addingTimeInterval(3_600) })
    XCTAssertEqual(try laterOwner.load(), initial)
    let operationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let checking = try first.replace(
      expectedGeneration: 0, state: .checking, activeOperationID: operationID)
    XCTAssertEqual(checking.generation, 1)
    XCTAssertEqual(checking.activeOperationID, operationID)

    let second = RuntimeUpdateStateStore(directory: root, now: { fixed })
    XCTAssertEqual(try second.load(), checking)
    XCTAssertThrowsError(
      try second.replace(expectedGeneration: 0, state: .idle)
    ) { error in
      XCTAssertEqual(error as? RuntimeUpdateStateStoreError, .resourceConflict)
    }

    let cancelled = try second.requestCancellation()
    XCTAssertEqual(cancelled.generation, 2)
    XCTAssertTrue(cancelled.cancellationRequested)
    XCTAssertEqual(cancelled.activeOperationID, operationID)

    let statePath = root.appending(path: "state-v1.json").path
    var stateMetadata = stat()
    XCTAssertEqual(lstat(statePath, &stateMetadata), 0)
    XCTAssertEqual(stateMetadata.st_mode & mode_t(0o777), mode_t(0o400))
    var directoryMetadata = stat()
    XCTAssertEqual(lstat(root.path, &directoryMetadata), 0)
    XCTAssertEqual(directoryMetadata.st_mode & mode_t(0o777), mode_t(0o700))
  }

  func testOperationLeaseProvesWhetherAnInProgressRecordCanBeRecovered() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = RuntimeUpdateStateStore(directory: root)
    let second = RuntimeUpdateStateStore(directory: root)

    var lease: RuntimeUpdateOperationLease? = try first.acquireOperationLease()
    XCTAssertTrue(try second.operationIsActive())
    XCTAssertThrowsError(try second.acquireOperationLease()) { error in
      XCTAssertEqual(error as? RuntimeUpdateStateStoreError, .operationInProgress)
    }
    lease = nil
    XCTAssertFalse(try second.operationIsActive())
    XCTAssertNil(lease)
  }

  func testNonCanonicalOrWritableStateFailsClosed() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RuntimeUpdateStateStore(directory: root)
    _ = try store.replace(expectedGeneration: 0, state: .idle)
    let state = root.appending(path: "state-v1.json")

    XCTAssertEqual(chmod(state.path, 0o600), 0)
    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(error as? RuntimeUpdateStateStoreError, .recordUnreadable)
    }
  }

  func testStatusProjectionNeverPublishesThePrivateArtifactPath() throws {
    let artifact = DownloadedUpdateArtifact(
      url: URL(filePath: "/Users/example/private/ArkDeck-Updates/update.dmg"),
      byteLength: 1_024,
      sha256: String(repeating: "a", count: 64),
      identity: UpdateFileIdentity(
        device: 1, inode: 2, byteLength: 1_024, mode: 0o100400,
        modifiedSeconds: 3, modifiedNanoseconds: 4,
        changedSeconds: 5, changedNanoseconds: 6))
    let projection = RuntimeUpdateStatusProjection(
      snapshot: RuntimeUpdateSnapshot(
        generation: 7, state: .verifying(artifact), activeOperationID: UUID()))

    XCTAssertEqual(projection.phase, "verifying")
    XCTAssertEqual(projection.artifactSHA256, String(repeating: "a", count: 64))
    XCTAssertEqual(projection.artifactByteLength, 1_024)
    XCTAssertFalse(String(describing: projection).contains("/Users/example/private"))
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-runtime-update-store-\(UUID().uuidString)",
      directoryHint: .isDirectory)
  }

  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
