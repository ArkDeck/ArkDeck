#if DEBUG
import ArkTraceAppSupport
import Foundation

extension ArkDeckTraceBootstrap {
  /// Explicit empty-view presentation fixture. It never admits a native
  /// runtime and is unavailable in Release builds or production startup.
  public static func emptyViewerFixture() -> ArkDeckTraceBootstrap {
    let identifier = UUID().uuidString
    let root = FileManager.default.temporaryDirectory.appending(path: identifier)
    let configuration: TraceProductConfiguration
    do {
      configuration = try TraceProductConfiguration(
        bundleURL: root.appending(path: "Fixture.app"),
        cacheDirectory: root.appending(path: "traces"),
        stagingDirectory: root.appending(path: "staging"),
        recentDocumentsKey: "ArkDeck.Trace.UIFixture." + identifier,
        signpostSubsystem: "com.arkdeck.desktop.trace.fixture",
        bundledParser: TraceBundledParserLocation(
          executableRelativePath: "Contents/MacOS/trace_streamer",
          manifestRelativePath: "Contents/Resources/TraceStreamer/manifest.json"))
    } catch {
      preconditionFailure("invalid empty Trace fixture configuration")
    }
    let controller = TraceDocumentController(configuration: configuration)
    return ArkDeckTraceBootstrap(factory: {
      ArkDeckTraceRuntimeOwner(makeController: { controller }, shutdown: {})
    })
  }
}
#endif
