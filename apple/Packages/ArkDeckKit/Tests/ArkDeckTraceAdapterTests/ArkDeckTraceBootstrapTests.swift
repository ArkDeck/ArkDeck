import ArkTraceAppSupport
import ArkTraceCore
import Foundation
import Testing
@testable import ArkDeckTraceAdapter

private enum BootstrapTestError: Error { case startup, shutdown }

private actor StartupGate {
  private var request: CheckedContinuation<ArkDeckTraceRuntimeOwner, any Error>?
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var cancelledWaiters: [CheckedContinuation<Void, Never>] = []
  private var cancelled = false
  private(set) var calls = 0

  func create() async throws -> ArkDeckTraceRuntimeOwner {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        calls += 1
        request = continuation
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
      }
    } onCancel: {
      Task { await self.didCancel() }
    }
  }

  func waitForRequest() async {
    if request != nil { return }
    await withCheckedContinuation { enteredWaiters.append($0) }
  }

  func waitForCancellation() async {
    if cancelled { return }
    await withCheckedContinuation { cancelledWaiters.append($0) }
  }

  private func didCancel() {
    cancelled = true
    cancelledWaiters.forEach { $0.resume() }
    cancelledWaiters.removeAll()
  }

  func returnOwner(_ owner: ArkDeckTraceRuntimeOwner) {
    request?.resume(returning: owner)
    request = nil
  }
}

private actor ShutdownProbe {
  private(set) var calls = 0
  private var failFirst: Bool

  init(failFirst: Bool = false) { self.failFirst = failFirst }

  func shutdown() throws {
    calls += 1
    if failFirst { failFirst = false; throw BootstrapTestError.shutdown }
  }
}

private actor RetryFactory {
  private(set) var calls = 0
  let owner: ArkDeckTraceRuntimeOwner

  init(owner: ArkDeckTraceRuntimeOwner) { self.owner = owner }

  func create() throws -> ArkDeckTraceRuntimeOwner {
    calls += 1
    if calls == 1 { throw BootstrapTestError.startup }
    return owner
  }
}

@MainActor
private final class ControllerProbe {
  private(set) var calls = 0

  func make() -> TraceDocumentController {
    calls += 1
    let root = URL(filePath: "/private/tmp/arkdeck-bootstrap-tests-" + UUID().uuidString)
    let configuration = try! TraceProductConfiguration(
      bundleURL: root.appending(path: "App.app"),
      cacheDirectory: root.appending(path: "native/traces"),
      stagingDirectory: root.appending(path: "native/staging"),
      recentDocumentsKey: "ArkDeck.BootstrapTests." + UUID().uuidString,
      signpostSubsystem: "com.arkdeck.bootstrap-tests",
      bundledParser: TraceBundledParserLocation(
        executableRelativePath: "Contents/MacOS/trace_streamer",
        manifestRelativePath: "Contents/Resources/TraceStreamer/manifest.json"))
    return TraceDocumentController(configuration: configuration)
  }
}

@MainActor
struct ArkDeckTraceBootstrapTests {
#if DEBUG
  @Test func emptyViewerFixtureDoesNotRequireNativeTools() async throws {
    let bootstrap = ArkDeckTraceBootstrap.emptyViewerFixture()
    await bootstrap.start()
    #expect(bootstrap.phase == .ready)
    #expect(bootstrap.controller?.sourceURL == nil)
    #expect(bootstrap.controller?.recentDocuments.isEmpty == true)
    try await bootstrap.stop()
    #expect(bootstrap.phase == .stopped)
  }
#endif
#if !ARKTRACE_NATIVE_RUNTIME
  @Test func missingNativeSDKFailsClosed() async throws {
    let bootstrap = ArkDeckTraceBootstrap(bundleURL: URL(filePath: "/private/tmp/Unavailable.app"))
    await bootstrap.start()
    #expect(bootstrap.phase == .failed)
    #expect(bootstrap.controller == nil)
    #expect(bootstrap.failure != nil)
    try await bootstrap.stop()
    #expect(bootstrap.phase == .stopped)
  }
#endif

  @Test func concurrentStartupPublishesOneControllerAndDrainsOnce() async throws {
    let gate = StartupGate(), controller = ControllerProbe(), shutdown = ShutdownProbe()
    let owner = ArkDeckTraceRuntimeOwner(makeController: { controller.make() }, shutdown: { try await shutdown.shutdown() })
    let bootstrap = ArkDeckTraceBootstrap(factory: { try await gate.create() })
    let first = Task { await bootstrap.start() }
    await gate.waitForRequest()
    let second = Task { await bootstrap.start() }
    await gate.returnOwner(owner)
    await first.value
    await second.value
    #expect(await gate.calls == 1)
    #expect(controller.calls == 1)
    #expect(bootstrap.phase == .ready)
    #expect(bootstrap.controller != nil)
    try await bootstrap.stop()
    try await bootstrap.stop()
    #expect(await shutdown.calls == 1)
    #expect(bootstrap.phase == .stopped)
    #expect(bootstrap.controller == nil)
  }

  @Test func quitDuringStartupJoinsLateOwnerDespiteCallerCancellation() async throws {
    let gate = StartupGate(), controller = ControllerProbe(), shutdown = ShutdownProbe()
    let owner = ArkDeckTraceRuntimeOwner(makeController: { controller.make() }, shutdown: { try await shutdown.shutdown() })
    let bootstrap = ArkDeckTraceBootstrap(factory: { try await gate.create() })
    let starting = Task { await bootstrap.start() }
    await gate.waitForRequest()
    let quitting = Task { try await bootstrap.stop() }
    await gate.waitForCancellation()
    #expect(bootstrap.phase == .stopping)
    quitting.cancel()
    let concurrentQuit = Task { try await bootstrap.stop() }
    await gate.returnOwner(owner)
    try await quitting.value
    try await concurrentQuit.value
    await starting.value
    #expect(controller.calls == 0)
    #expect(await shutdown.calls == 1)
    #expect(bootstrap.phase == .stopped)
    #expect(bootstrap.controller == nil)
  }

  @Test func failedStartupWaitsForExplicitRetry() async throws {
    let controller = ControllerProbe(), shutdown = ShutdownProbe()
    let owner = ArkDeckTraceRuntimeOwner(makeController: { controller.make() }, shutdown: { try await shutdown.shutdown() })
    let factory = RetryFactory(owner: owner)
    let bootstrap = ArkDeckTraceBootstrap(factory: { try await factory.create() })
    await bootstrap.start()
    #expect(bootstrap.phase == .failed)
    #expect(bootstrap.failure != nil)
    #expect(bootstrap.controller == nil)
    await bootstrap.start()
    #expect(await factory.calls == 1)
    await bootstrap.retryStartup()
    #expect(await factory.calls == 2)
    #expect(controller.calls == 1)
    #expect(bootstrap.phase == .ready)
    #expect(bootstrap.failure == nil)
    try await bootstrap.stop()
  }

  @Test func failedShutdownRetainsOwnerForQuitRetry() async throws {
    let controller = ControllerProbe(), shutdown = ShutdownProbe(failFirst: true)
    let owner = ArkDeckTraceRuntimeOwner(makeController: { controller.make() }, shutdown: { try await shutdown.shutdown() })
    let bootstrap = ArkDeckTraceBootstrap(factory: { owner })
    await bootstrap.start()
    let document = try #require(bootstrap.controller)
    await #expect(throws: BootstrapTestError.self) { try await bootstrap.stop() }
    #expect(bootstrap.phase == .failed)
    #expect(bootstrap.shutdownRequested)
    #expect(bootstrap.controller === document)
    #expect(bootstrap.failure != nil)
    await bootstrap.retryStartup()
    #expect(controller.calls == 1)
    bootstrap.open(URL(filePath: "/private/tmp/unused-bootstrap-test.htrace"))
    #expect(document.sourceURL == nil)
    try await bootstrap.stop()
    #expect(await shutdown.calls == 2)
    #expect(bootstrap.phase == .stopped)
    #expect(bootstrap.controller == nil)
  }
}
