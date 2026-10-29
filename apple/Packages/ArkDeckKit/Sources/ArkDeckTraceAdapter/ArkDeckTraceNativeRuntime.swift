#if ARKTRACE_NATIVE_RUNTIME
import ArkTraceAppSupport
import ArkTraceCore
import ArkTraceRustRuntime
import Foundation

/// Composition for ArkDeck's staged native SDK. The shared bundled startup
/// validates tools and prepares private roots before publishing its owner.
/// Open requests cannot replace this configuration.
public enum ArkDeckTraceNativeRuntime {
  public struct Configuration: Sendable {
    public let product: TraceProductConfiguration
    public let runtime: RustConfiguration
  }

  /// Keep native writers separate from the existing Swift cache and daemon
  /// maintenance namespace until the downstream format-4 cutover is accepted.
  public static func configuration(
    bundleURL: URL,
    cachesDirectory: URL,
    helperSHA256: String,
    parserIdentity: TraceParserIdentity,
    publisher: RustPublisher
  ) throws -> Configuration {
    let identifier = ArkDeckTraceConfiguration.bundleIdentifier
    guard publisher.helperCodeIdentifier == identifier + ".host-process",
      publisher.parserCodeIdentifier == identifier + ".trace-streamer"
    else {
      throw ArkTraceError(
        code: .invalidArgument, stage: .preparing,
        message: "Native Trace publisher does not match the ArkDeck product")
    }
    let product = try productConfiguration(bundleURL: bundleURL, cachesDirectory: cachesDirectory)
    let runtime = RustConfiguration(
      namespace: product.stagingDirectory,
      helper: product.bundleURL.appending(path: "Contents/Helpers/arktrace-host-process"),
      parser: product.bundledParser.executableURL(in: product.bundleURL),
      helperSHA256: helperSHA256,
      parserIdentity: parserIdentity,
      publisher: publisher,
      storagePolicy: .contentAddressed(cacheDirectory: product.cacheDirectory))
    return Configuration(product: product, runtime: runtime)
  }

  /// The returned owner supplies both document controllers and cache
  /// maintenance. Close controllers and drain this owner during App shutdown.
  @concurrent
  public static func create(_ configuration: Configuration) async throws -> TraceRustProductRuntime {
    try await TraceRustProductRuntime.create(
      configuration: configuration.product,
      runtimeConfiguration: configuration.runtime,
      openTimeoutMilliseconds: 300_000)
  }

  @concurrent
  public static func createBundled(
    bundleURL: URL = Bundle.main.bundleURL,
    cachesDirectory: URL? = nil
  ) async throws -> TraceRustProductRuntime {
    let caches = cachesDirectory
      ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return try await TraceRustProductRuntime.createBundled(
      configuration: productConfiguration(bundleURL: bundleURL, cachesDirectory: caches),
      publisherCodeIdentifierPrefix: ArkDeckTraceConfiguration.bundleIdentifier)
  }

  private static func productConfiguration(
    bundleURL: URL,
    cachesDirectory: URL
  ) throws -> TraceProductConfiguration {
    let directories = ArkDeckTraceConfiguration.cacheDirectories(cachesDirectory: cachesDirectory)
    let root = directories.cache.deletingLastPathComponent()
      .appending(path: "native-v1", directoryHint: .isDirectory)
    return try TraceProductConfiguration(
      bundleURL: bundleURL,
      cacheDirectory: root.appending(path: "traces", directoryHint: .isDirectory),
      stagingDirectory: root.appending(path: "staging", directoryHint: .isDirectory),
      recentDocumentsKey: ArkDeckTraceConfiguration.recentDocumentsKey,
      signpostSubsystem: ArkDeckTraceConfiguration.signpostSubsystem,
      bundledParser: TraceBundledParserLocation(
        executableRelativePath: "Contents/MacOS/trace_streamer",
        manifestRelativePath: "Contents/Resources/TraceStreamer/manifest.json"),
      bundledParserExecutionPolicy: .signedBundleInPlace)
  }
}
#endif
