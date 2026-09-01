import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class RuntimeHistoryFilterStoreContractTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appending(
      path: "history-filter-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private var query: RuntimeHistoryFilterQuery {
    RuntimeHistoryFilterQuery(
      search: "failed flash", status: "needsAttention", mode: "execute",
      sessionID: "session-1", targetID: "target-1", timeRange: "lastWeek",
      activity: "flash")
  }

  func testSaveDeleteAndReloadKeepOneMonotonicCASResource() throws {
    let store = RuntimeHistoryFilterStore(
      rootURL: directory, nowUTC: { "2026-09-01T08:00:00.000Z" })
    XCTAssertEqual(
      try store.read(),
      RuntimeHistoryFilterResource(generation: 1, query: nil, updatedAtUTC: nil))

    let saved = try store.save(expectedGeneration: 1, query: query)
    XCTAssertEqual(saved.generation, 2)
    XCTAssertEqual(saved.query, query)
    XCTAssertEqual(saved.updatedAtUTC, "2026-09-01T08:00:00.000Z")

    let reloaded = RuntimeHistoryFilterStore(rootURL: directory)
    XCTAssertEqual(try reloaded.read(), saved)
    XCTAssertThrowsError(try reloaded.save(expectedGeneration: 1, query: query)) { error in
      XCTAssertEqual((error as? RuntimeHistoryFilterFailure)?.code, "resourceConflict")
    }

    let deleted = try reloaded.delete(expectedGeneration: 2)
    XCTAssertEqual(deleted.generation, 3)
    XCTAssertNil(deleted.query)
    XCTAssertEqual(try RuntimeHistoryFilterStore(rootURL: directory).read().generation, 3)
    XCTAssertThrowsError(try reloaded.delete(expectedGeneration: 3)) { error in
      XCTAssertEqual((error as? RuntimeHistoryFilterFailure)?.code, "resourceNotFound")
    }
  }

  func testQueryVocabularyAndBoundsAreClosedBeforePublication() throws {
    let store = RuntimeHistoryFilterStore(rootURL: directory)
    let invalid = [
      RuntimeHistoryFilterQuery(status: "success"),
      RuntimeHistoryFilterQuery(mode: "preview"),
      RuntimeHistoryFilterQuery(timeRange: "forever"),
      RuntimeHistoryFilterQuery(activity: "toolkit"),
      RuntimeHistoryFilterQuery(search: String(repeating: "a", count: 513)),
      RuntimeHistoryFilterQuery(sessionID: " leading"),
      RuntimeHistoryFilterQuery(targetID: "bad\nidentity"),
    ]
    for query in invalid {
      XCTAssertThrowsError(try store.save(expectedGeneration: 1, query: query)) { error in
        XCTAssertEqual((error as? RuntimeHistoryFilterFailure)?.code, "invalidInput")
      }
      XCTAssertEqual(try store.read().generation, 1)
    }
  }

  func testUnsafeDirectoryFailsClosedWithoutCreatingAResource() throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    let store = RuntimeHistoryFilterStore(rootURL: directory)
    XCTAssertThrowsError(try store.read()) { error in
      XCTAssertEqual((error as? RuntimeHistoryFilterFailure)?.code, "recordUnreadable")
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appending(path: "history-filter.json").path))
  }
}
