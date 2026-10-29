import ArkTraceAppSupport
import ArkTraceCore
import Foundation
import Observation

package struct ArkDeckTraceRuntimeOwner: Sendable {
  let makeController: @MainActor @Sendable () -> TraceDocumentController
  let shutdown: @Sendable () async throws -> Void
}

private enum ArkDeckTraceRuntimeFactory {
  @concurrent
  static func create(bundleURL: URL, cachesDirectory: URL?) async throws -> ArkDeckTraceRuntimeOwner {
#if ARKTRACE_NATIVE_RUNTIME
    let runtime = try await ArkDeckTraceNativeRuntime.createBundled(
      bundleURL: bundleURL, cachesDirectory: cachesDirectory)
    return ArkDeckTraceRuntimeOwner(
      makeController: { runtime.makeDocumentController() },
      shutdown: { try await runtime.shutdown() })
#else
    throw ArkTraceError(
      code: .traceStreamerUnavailable, stage: .preparing,
      message: "The Trace runtime is unavailable")
#endif
  }
}

/// App-owned startup and Quit barrier for its shared Trace controller. A
/// staged native build admits its fixed bundle before publishing the Viewer;
/// startup failure cannot switch it to the Swift engine.
@MainActor
@Observable
public final class ArkDeckTraceBootstrap {
  public enum Phase: Equatable { case preparing, ready, stopping, failed, stopped }

  public private(set) var phase = Phase.preparing
  public private(set) var controller: TraceDocumentController?
  public private(set) var failure: TraceAppErrorPresentation?
  public private(set) var shutdownRequested = false
  @ObservationIgnored private let factory: @Sendable () async throws -> ArkDeckTraceRuntimeOwner
  @ObservationIgnored private var owner: ArkDeckTraceRuntimeOwner?
  @ObservationIgnored private var startupTask: Task<Void, Never>?
  @ObservationIgnored private var stopTask: Task<Void, any Error>?
  @ObservationIgnored private var pendingURL: URL?

  public init(bundleURL: URL = Bundle.main.bundleURL, cachesDirectory: URL? = nil) {
    factory = { try await ArkDeckTraceRuntimeFactory.create(bundleURL: bundleURL, cachesDirectory: cachesDirectory) }
  }

  package init(factory: @escaping @Sendable () async throws -> ArkDeckTraceRuntimeOwner) {
    self.factory = factory
  }

  public func start() async {
    if let startupTask { await startupTask.value; return }
    guard phase == .preparing, owner == nil, !shutdownRequested else { return }
    let task = Task { [self] in
      defer { startupTask = nil }
      do {
        let created = try await factory()
        owner = created
        // A racing Quit joins this task before draining the newly returned
        // owner; cancellation cannot orphan it or publish a late controller.
        guard !shutdownRequested, !Task.isCancelled else { return }
        let document = created.makeController()
        controller = document
        phase = .ready
        if let pendingURL { self.pendingURL = nil; document.open(pendingURL) }
      } catch {
        guard !shutdownRequested else { return }
        failure = Self.presentation(error)
        phase = .failed
      }
    }
    startupTask = task
    await task.value
  }

  public func retryStartup() async {
    guard phase == .failed, !shutdownRequested, owner == nil, startupTask == nil else { return }
    failure = nil
    phase = .preparing
    await start()
  }

  public func open(_ url: URL) {
    guard url.isFileURL, !shutdownRequested else { return }
    if let controller, phase == .ready { controller.open(url) }
    else {
      pendingURL = url
      Task { [self] in await start() }
    }
  }

  /// Concurrent Quit requests share the same drain. Cleanup survives the
  /// requesting task's cancellation; a failed drain retains the owner for a
  /// later explicit Quit retry.
  public func stop() async throws {
    if let stopTask { return try await stopTask.value }
    if phase == .stopped { return }
    shutdownRequested = true
    phase = .stopping
    pendingURL = nil
    startupTask?.cancel()
    let starting = startupTask
    let task = Task { [self] in
      defer { stopTask = nil }
      await starting?.value
      var failureError: (any Error)?
      do { try await controller?.closeForProductShutdown() } catch { failureError = error }
      do { try await owner?.shutdown() } catch { failureError = error }
      if let error = failureError {
        failure = Self.presentation(error)
        phase = .failed
        throw error
      }
      controller = nil
      owner = nil
      failure = nil
      phase = .stopped
    }
    stopTask = task
    try await task.value
  }

  private static func presentation(_ error: any Error) -> TraceAppErrorPresentation {
    TraceAppErrorPresentation(error: error as? ArkTraceError ?? ArkTraceError(
      code: .internalError, stage: .preparing,
      message: "Trace could not complete the operation", retryable: true))
  }
}
