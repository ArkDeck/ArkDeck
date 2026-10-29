#if ARKTRACE_NATIVE_RUNTIME
import ArkDeckTraceAdapter
import ArkTraceAppSupport
import ArkTraceCore
import ArkTraceRustRuntime
import Foundation
import Testing

struct ArkDeckTraceNativeRuntimeTests {
  private let parser = TraceParserIdentity(
    name: "TraceStreamer", reportedVersion: "4.3.7",
    binarySHA256: String(repeating: "a", count: 64),
    upstreamRepository: "https://gitee.com/openharmony/developtools_smartperf_host.git",
    upstreamRevision: String(repeating: "b", count: 40),
    architecture: "arm64", adapterVersion: "1", buildRecipeVersion: "1")

  @Test func nativeProductPreservesArkDeckIdentityAndSeparatesWriters() throws {
    let configuration = try make()
    let product = configuration.product
    #expect(product.cacheDirectory.path == "/private/tmp/arkdeck-native-test/ArkDeck/Trace/native-v1/traces")
    #expect(product.stagingDirectory.path == "/private/tmp/arkdeck-native-test/ArkDeck/Trace/native-v1/staging")
    let legacy = ArkDeckTraceConfiguration.make(
      bundleURL: product.bundleURL,
      cachesDirectory: URL(filePath: "/private/tmp/arkdeck-native-test"))
    #expect(product.cacheDirectory != legacy.cacheDirectory)
    #expect(product.stagingDirectory != legacy.stagingDirectory)
    #expect(product.recentDocumentsKey == legacy.recentDocumentsKey)
    #expect(product.signpostSubsystem == legacy.signpostSubsystem)
    #expect(product.bundledParser == legacy.bundledParser)
    #expect(product.bundledParserExecutionPolicy == .signedBundleInPlace)
    let encoded = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration.runtime)) as? [String: Any])
    #expect(encoded["namespace"] as? String == product.stagingDirectory.path)
    #expect(encoded["cacheDirectory"] as? String == product.cacheDirectory.path)
    #expect(encoded["cachePolicy"] as? String == "contentAddressed")
    #expect(encoded["helper"] as? String == "/Applications/ArkDeck.app/Contents/Helpers/arktrace-host-process")
    #expect(encoded["parser"] as? String == "/Applications/ArkDeck.app/Contents/MacOS/trace_streamer")
  }

  @Test func standalonePublisherCannotSelectArkDeckTools() {
    #expect(throws: ArkTraceError.self) {
      try make(identifier: "com.arktrace.ArkTrace")
    }
  }

  private func make(identifier: String = "com.arkdeck.desktop") throws -> ArkDeckTraceNativeRuntime.Configuration {
    try ArkDeckTraceNativeRuntime.configuration(
      bundleURL: URL(filePath: "/Applications/ArkDeck.app"),
      cachesDirectory: URL(filePath: "/private/tmp/arkdeck-native-test"),
      helperSHA256: String(repeating: "c", count: 64),
      parserIdentity: parser,
      publisher: RustPublisher(
        teamIdentifier: "ABCDEFGHIJ", helperCodeIdentifier: identifier + ".host-process",
        parserCodeIdentifier: identifier + ".trace-streamer"))
  }
}
#endif
