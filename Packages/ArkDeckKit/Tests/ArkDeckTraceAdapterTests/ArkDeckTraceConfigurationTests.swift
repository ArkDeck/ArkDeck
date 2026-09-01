import ArkDeckTraceAdapter
import ArkTraceAppSupport
import Foundation
import XCTest

final class ArkDeckTraceConfigurationTests: XCTestCase {
  func testArkDeckOwnsOnlyItsProductProfile() {
    let configuration = ArkDeckTraceConfiguration.make(
      bundleURL: URL(filePath: "/Applications/ArkDeck.app"),
      cachesDirectory: URL(filePath: "/tmp/arkdeck-contract-cache")
    )

    XCTAssertEqual(
      configuration.cacheDirectory.path,
      "/tmp/arkdeck-contract-cache/ArkDeck/Trace/traces")
    XCTAssertEqual(
      configuration.stagingDirectory.path,
      "/tmp/arkdeck-contract-cache/ArkDeck/Trace/staging")
    XCTAssertEqual(
      configuration.recentDocumentsKey,
      "ArkDeck.Trace.RecentTraceBookmarks.v1")
    XCTAssertEqual(configuration.signpostSubsystem, "com.arkdeck.desktop.trace")
    XCTAssertEqual(
      ArkDeckTraceConfiguration.supportedTraceExtensions,
      ["htrace", "ftrace", "systrace", "trace"])
    XCTAssertEqual(ArkDeckTraceConfiguration.supportedTraceContentTypes.count, 4)
    XCTAssertEqual(
      configuration.bundledParser.executableRelativePath,
      "Contents/MacOS/trace_streamer")
    XCTAssertEqual(
      configuration.bundledParser.manifestRelativePath,
      "Contents/Resources/TraceStreamer/manifest.json")
    XCTAssertEqual(
      configuration.bundledParserExecutionPolicy,
      .signedBundleInPlace)
  }

  func testDaemonDerivesTheSandboxCacheRootFromTheReviewedBundleIdentity() {
    let root = ArkDeckTraceConfiguration.appContainerCachesDirectory(
      homeDirectory: URL(filePath: "/Users/fixture", directoryHint: .isDirectory))
    XCTAssertEqual(
      root.path,
      "/Users/fixture/Library/Containers/com.arkdeck.desktop/Data/Library/Caches")
  }

  func testMaintenanceOwnsOnlyEmptyDerivedCacheSiblings() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-trace-maintenance-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let originalTrace = root.appending(path: "original.htrace")
    try Data("trace fixture".utf8).write(to: originalTrace)

    let service = try ArkDeckTraceCacheMaintenanceService(cachesDirectory: root)
    let inventory = try await service.inventory()
    XCTAssertEqual(
      inventory,
      ArkDeckTraceCacheInventory(entryCount: 0, totalByteCount: 0, activeEntryCount: 0))

    let report = try await service.purgeUnused()
    XCTAssertEqual(report.before, inventory)
    XCTAssertEqual(report.after, inventory)
    XCTAssertEqual(report.removedEntryCount, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: originalTrace.path))
  }
}
