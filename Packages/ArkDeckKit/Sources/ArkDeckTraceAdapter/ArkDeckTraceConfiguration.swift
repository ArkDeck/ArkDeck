import ArkTraceAppSupport
import Foundation
import UniformTypeIdentifiers

/// ArkDeck-owned composition values for the shared ArkTrace engine.
///
/// Shared parsing, storage, runtime, analysis and rendering code lives only in
/// ArkTrace. This adapter owns the values that legitimately differ for the
/// sandboxed ArkDeck product.
public enum ArkDeckTraceConfiguration {
  public static let bundleIdentifier = "com.arkdeck.desktop"
  public static let recentDocumentsKey = "ArkDeck.Trace.RecentTraceBookmarks.v1"
  public static let signpostSubsystem = "com.arkdeck.desktop.trace"
  public static let supportedTraceExtensions = [
    "htrace", "ftrace", "systrace", "trace",
  ]

  public static var supportedTraceContentTypes: [UTType] {
    supportedTraceExtensions.compactMap { UTType(filenameExtension: $0) }
  }

  public static func make(
    bundleURL: URL = Bundle.main.bundleURL,
    cachesDirectory: URL? = nil
  ) -> TraceProductConfiguration {
    let base = cachesDirectory
      ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let productRoot = base.appending(
      path: "ArkDeck/Trace", directoryHint: .isDirectory)
    do {
      return try TraceProductConfiguration(
        bundleURL: bundleURL,
        cacheDirectory: productRoot.appending(
          path: "traces", directoryHint: .isDirectory),
        stagingDirectory: productRoot.appending(
          path: "staging", directoryHint: .isDirectory),
        recentDocumentsKey: recentDocumentsKey,
        signpostSubsystem: signpostSubsystem,
        bundledParser: TraceBundledParserLocation(
          executableRelativePath: "Contents/MacOS/trace_streamer",
          manifestRelativePath: "Contents/Resources/TraceStreamer/manifest.json"
        ),
        bundledParserExecutionPolicy: .signedBundleInPlace
      )
    } catch {
      preconditionFailure("reviewed ArkDeck Trace configuration is invalid")
    }
  }
}
