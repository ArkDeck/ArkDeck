import Foundation
import Testing

@testable import ArkDeckClientKit

@MainActor
struct DevicePreviewSessionTests {
  private let target = DeviceTargetPresentation(id: "one", bindingRevision: 3, displayName: "One")
  private var frame: DeviceScreenFrame {
    DeviceScreenFrame(imageData: Data(), width: 720, height: 1280, capturedAtUTC: "", jobID: "fixture")
  }

  @Test func stopsAtFrameBudgetAndKeepsExactTarget() async {
    var targets: [DeviceTargetPresentation] = []
    var received = 0
    let session = DevicePreviewSession(
      capture: { targets.append($0); return .captured(frame) },
      now: { .zero }, pause: {})
    await session.run(target: target) { _ in received += 1 }
    #expect(targets == Array(repeating: target, count: 30))
    #expect(received == 30)
    #expect(session.stopReason == .limit)
    #expect(!session.isBusy)
  }

  @Test func stopsBeforeRequestAfterTimeBudget() async {
    var elapsed = Duration.zero
    var calls = 0
    let session = DevicePreviewSession(
      capture: { _ in calls += 1; return .captured(frame) },
      now: { elapsed }, pause: { elapsed = .seconds(60) })
    await session.run(target: target) { _ in }
    #expect(calls == 1)
    #expect(session.stopReason == .limit)
  }

  @Test func captureFailureIsTerminalWithoutRetry() async {
    var calls = 0
    let session = DevicePreviewSession(
      capture: { _ in calls += 1; return .failed("target offline") },
      now: { .zero }, pause: { Issue.record("Failed captures must not schedule a retry") })
    await session.run(target: target) { _ in Issue.record("Failure published a frame") }
    #expect(calls == 1)
    #expect(session.stopReason == .failed("target offline"))
  }

  @Test func stopDiscardsLateFrameAndCannotOverlapWithNewRun() async {
    let gate = CaptureGate()
    var received = 0
    let session = DevicePreviewSession(capture: { _ in await gate.capture() }, now: { .zero }, pause: {})
    let run = Task { await session.run(target: target) { _ in received += 1 } }
    await gate.waitForEntry()
    session.stop(.contextChanged)
    #expect(session.isBusy)
    await session.run(target: target) { _ in Issue.record("An overlapping run started") }
    gate.finish(.captured(frame))
    await run.value
    #expect(gate.count == 1)
    #expect(received == 0)
    #expect(session.stopReason == .contextChanged)
    #expect(!session.isBusy)
  }

  @Test func cancellationDuringCaptureCannotPublishOrDispatchAgain() async {
    let gate = CaptureGate()
    let session = DevicePreviewSession(capture: { _ in await gate.capture() }, now: { .zero }, pause: {})
    let run = Task { await session.run(target: target) { _ in Issue.record("Cancelled run published") } }
    await gate.waitForEntry()
    run.cancel()
    gate.finish(.captured(frame))
    await run.value
    #expect(gate.count == 1)
    #expect(!session.isRunning)
  }

  @Test func keyboardPointerClampsAndRequiresExplicitSwipeAnchor() throws {
    var pointer = DeviceKeyboardPointer()
    #expect(pointer.request(.swipe, frame: frame) == nil)
    pointer.move(dx: -10, dy: 10)
    let tap = try #require(pointer.request(.tap, frame: frame))
    #expect(tap.x == 0 && tap.y == 1279)
    pointer.beginSwipe()
    pointer.move(dx: 10, dy: -10)
    let swipe = try #require(pointer.request(.swipe, frame: frame))
    #expect(swipe.x == 0 && swipe.y == 1279)
    #expect(swipe.toX == 719 && swipe.toY == 0)
    #expect(swipe.durationMs == 300)
    #expect(pointer.request(.longPress, frame: frame)?.durationMs == 800)
    pointer.cancelSwipe()
    #expect(pointer.request(.swipe, frame: frame) == nil)
  }
}

@MainActor
private final class CaptureGate {
  var count = 0
  private var result: CheckedContinuation<DeviceScreenshotResult, Never>?
  private var entry: CheckedContinuation<Void, Never>?

  func capture() async -> DeviceScreenshotResult {
    count += 1
    return await withCheckedContinuation { continuation in
      result = continuation
      entry?.resume()
      entry = nil
    }
  }

  func waitForEntry() async {
    if count > 0 { return }
    await withCheckedContinuation { entry = $0 }
  }

  func finish(_ value: DeviceScreenshotResult) { result?.resume(returning: value); result = nil }
}
