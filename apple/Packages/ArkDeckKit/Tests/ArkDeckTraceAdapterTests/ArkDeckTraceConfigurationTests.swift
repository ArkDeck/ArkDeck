import ArkDeckTraceAdapter
import ArkTraceAppSupport
import Foundation
import Testing

struct ArkDeckTraceConfigurationTests {
  @Test func arkDeckOwnsOnlyItsProductProfile() {
    let configuration = ArkDeckTraceConfiguration.make(
      bundleURL: URL(filePath: "/Applications/ArkDeck.app"),
      cachesDirectory: URL(filePath: "/tmp/arkdeck-contract-cache")
    )

    #expect(
      configuration.cacheDirectory.path
        == "/tmp/arkdeck-contract-cache/ArkDeck/Trace/traces")
    #expect(
      configuration.stagingDirectory.path
        == "/tmp/arkdeck-contract-cache/ArkDeck/Trace/staging")
    #expect(
      configuration.recentDocumentsKey
        == "ArkDeck.Trace.RecentTraceBookmarks.v1")
    #expect(configuration.signpostSubsystem == "com.arkdeck.desktop.trace")
    #expect(
      ArkDeckTraceConfiguration.supportedTraceExtensions
        == ["htrace", "ftrace", "systrace", "trace"])
    #expect(ArkDeckTraceConfiguration.supportedTraceContentTypes.count == 4)
    #expect(
      configuration.bundledParser.executableRelativePath
        == "Contents/MacOS/trace_streamer")
    #expect(
      configuration.bundledParser.manifestRelativePath
        == "Contents/Resources/TraceStreamer/manifest.json")
    #expect(
      configuration.bundledParserExecutionPolicy
        == .signedBundleInPlace)
  }

  @Test func daemonDerivesTheSandboxCacheRootFromTheReviewedBundleIdentity() {
    let root = ArkDeckTraceConfiguration.appContainerCachesDirectory(
      homeDirectory: URL(filePath: "/Users/fixture", directoryHint: .isDirectory))
    #expect(
      root.path
        == "/Users/fixture/Library/Containers/com.arkdeck.desktop/Data/Library/Caches")
  }

  @Test func maintenanceOwnsOnlyEmptyDerivedCacheSiblings() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-trace-maintenance-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let originalTrace = root.appending(path: "original.htrace")
    try Data("trace fixture".utf8).write(to: originalTrace)

    let service = try ArkDeckTraceCacheMaintenanceService(cachesDirectory: root)
    let inventory = try await service.inventory()
    #expect(
      inventory
        == ArkDeckTraceCacheInventory(entryCount: 0, totalByteCount: 0, activeEntryCount: 0))

    let report = try await service.purgeUnused()
    #expect(report.before == inventory)
    #expect(report.after == inventory)
    #expect(report.removedEntryCount == 0)
    #expect(FileManager.default.fileExists(atPath: originalTrace.path))
  }
}
