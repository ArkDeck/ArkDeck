import Foundation
import Observation

/// An explicitly started, bounded sequence of the published screenshot operation.
/// Stopping prevents further requests and publication of an in-flight result;
/// it does not claim to cancel a Job the Runtime already accepted.
@MainActor @Observable
public final class DevicePreviewSession {
  public enum StopReason: Sendable, Equatable {
    case user, limit, contextChanged, hidden
    case failed(String)
  }

  public private(set) var isRunning = false
  public private(set) var isBusy = false
  public private(set) var frameCount = 0
  public private(set) var stopReason: StopReason?
  public static let maximumFrames = 30
  public static let maximumSeconds = 60

  private let capture: @MainActor (DeviceTargetPresentation) async -> DeviceScreenshotResult
  private let now: @MainActor () -> Duration
  private let pause: @MainActor () async throws -> Void

  public convenience init(provider: any DeviceControlProviding) {
    let clock = ContinuousClock()
    let origin = clock.now
    self.init(
      capture: { await provider.captureScreen(target: $0) },
      now: { origin.duration(to: clock.now) },
      pause: { try await Task.sleep(for: .seconds(2)) })
  }

  init(
    capture: @escaping @MainActor (DeviceTargetPresentation) async -> DeviceScreenshotResult,
    now: @escaping @MainActor () -> Duration,
    pause: @escaping @MainActor () async throws -> Void
  ) {
    self.capture = capture
    self.now = now
    self.pause = pause
  }

  public func run(
    target: DeviceTargetPresentation,
    receive: @MainActor (DeviceScreenFrame) -> Void
  ) async {
    guard !isBusy, !Task.isCancelled else { return }
    isBusy = true
    isRunning = true
    frameCount = 0
    stopReason = nil
    let started = now()
    defer { isRunning = false; isBusy = false }
    while isRunning, !Task.isCancelled {
      guard frameCount < Self.maximumFrames,
        now() - started < .seconds(Self.maximumSeconds)
      else { stop(.limit); break }
      let result = await capture(target)
      guard isRunning, !Task.isCancelled else { break }
      switch result {
      case .captured(let frame):
        frameCount += 1
        receive(frame)
      case .failed(let reason):
        stop(.failed(reason))
      }
      guard isRunning else { break }
      if frameCount == Self.maximumFrames { stop(.limit); break }
      do { try await pause() } catch { stop(.user) }
    }
  }

  public func stop(_ reason: StopReason = .user) {
    guard isRunning else { return }
    isRunning = false
    stopReason = reason
  }
}
