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
}
