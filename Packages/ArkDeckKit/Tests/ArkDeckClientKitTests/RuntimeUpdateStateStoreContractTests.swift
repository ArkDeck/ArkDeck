import Darwin
import Foundation
import Testing

@testable import ArkDeckClientKit

struct RuntimeUpdateStateStoreContractTests {
  @Test func appAndCLIResolveTheSameSandboxContainerDirectories() throws {
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
      #expect(fromCLI == fromApp)
    }

    let project = try String(
      contentsOf: repositoryRoot.appending(path: "ArkDeck.xcodeproj/project.pbxproj"),
      encoding: .utf8)
    #expect(
      project.contains(
        "PRODUCT_BUNDLE_IDENTIFIER = \(AutoUpdateFilesystemLayout.appBundleIdentifier);"),
      "the shared-container pin must match the App's signed bundle identifier")
  }

  @Test func durableStateUsesGenerationCASAndSurvivesANewOwner() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixed = Date(timeIntervalSince1970: 1_788_225_600)
    let first = RuntimeUpdateStateStore(directory: root, now: { fixed })

    let initial = try first.load()
    #expect(initial.generation == 0)
    let laterOwner = RuntimeUpdateStateStore(
      directory: root, now: { fixed.addingTimeInterval(3_600) })
    #expect(try laterOwner.load() == initial)
    let operationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let checking = try first.replace(
      expectedGeneration: 0, state: .checking, activeOperationID: operationID)
    #expect(checking.generation == 1)
    #expect(checking.activeOperationID == operationID)

    let second = RuntimeUpdateStateStore(directory: root, now: { fixed })
    #expect(try second.load() == checking)
    #expect(throws: RuntimeUpdateStateStoreError.resourceConflict) {
      try second.replace(expectedGeneration: 0, state: .idle)
    }

    let cancelled = try second.requestCancellation()
    #expect(cancelled.generation == 2)
    #expect(cancelled.cancellationRequested)
    #expect(cancelled.activeOperationID == operationID)

    let statePath = root.appending(path: "state-v1.json").path
    var stateMetadata = stat()
    #expect(lstat(statePath, &stateMetadata) == 0)
    #expect(stateMetadata.st_mode & mode_t(0o777) == mode_t(0o400))
    var directoryMetadata = stat()
    #expect(lstat(root.path, &directoryMetadata) == 0)
    #expect(directoryMetadata.st_mode & mode_t(0o777) == mode_t(0o700))
  }

  @Test func operationLeaseProvesWhetherAnInProgressRecordCanBeRecovered() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = RuntimeUpdateStateStore(directory: root)
    let second = RuntimeUpdateStateStore(directory: root)

    var lease: RuntimeUpdateOperationLease? = try first.acquireOperationLease()
    #expect(try second.operationIsActive())
    #expect(throws: RuntimeUpdateStateStoreError.operationInProgress) {
      try second.acquireOperationLease()
    }
    lease = nil
    #expect(try !second.operationIsActive())
    #expect(lease == nil)
  }

  @Test func nonCanonicalOrWritableStateFailsClosed() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RuntimeUpdateStateStore(directory: root)
    _ = try store.replace(expectedGeneration: 0, state: .idle)
    let state = root.appending(path: "state-v1.json")

    #expect(chmod(state.path, 0o600) == 0)
    #expect(throws: RuntimeUpdateStateStoreError.recordUnreadable) {
      try store.load()
    }
  }

  @Test func statusProjectionNeverPublishesThePrivateArtifactPath() throws {
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

    #expect(projection.phase == "verifying")
    #expect(projection.artifactSHA256 == String(repeating: "a", count: 64))
    #expect(projection.artifactByteLength == 1_024)
    #expect(!String(describing: projection).contains("/Users/example/private"))
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
