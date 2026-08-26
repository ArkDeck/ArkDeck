import ArkDeckWorkflows
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ToolkitWorkspaceViewModel {
  /// Below this the pointer did not travel: the gesture is a press at one
  /// place, and how long it was held decides whether that is a tap or a long
  /// press.
  static let travelThreshold: CGFloat = 6
  /// A press held at least this long is a long press. Anything shorter is a
  /// tap; nothing in between is silently promoted, because a long press the
  /// device receives as a tap is a different act than the one intended.
  static let longPressThreshold: TimeInterval = 0.5

  struct Marker: Equatable {
    let unitX: CGFloat
    let unitY: CGFloat
  }

  struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let systemImage: String
    let tintName: String
    /// A refusal is a different kind of row from a result: nothing was sent,
    /// so nothing has an outcome. Naming it separately is what lets anyone -
    /// a reader, a test - tell the two apart without reading the prose.
    let isRefusal: Bool

    var tint: Color {
      switch tintName {
      case "confirmed": return .green
      case "failed": return .red
      case "unknown": return .orange
      default: return .secondary
      }
    }
  }

  private(set) var frame: ToolkitScreenFrame?
  private(set) var isCapturing = false
  private(set) var isSendingGesture = false
  private(set) var pendingMarker: Marker?
  private(set) var lastMarker: Marker?
  private(set) var log: [LogEntry] = []
  /// Whether the picture on screen still shows the device.
  ///
  /// Not a matter of age. The runtime's own freshness budget is a second,
  /// and a still is read at a person's own pace - they look, they think,
  /// they decide where to press. See `ToolkitFrameLiveness` for why the rule
  /// is about what changed the screen rather than about how old the picture
  /// is; here it only decides whether the next press is sent or refused.
  private(set) var liveness = ToolkitFrameLiveness()
  var frameIsStale: Bool { liveness.refusesInput }
  private(set) var deviceObservation = DeviceListPresentation.loading
  private(set) var captureFailure: String?

  private let provider: any ToolkitDeviceControlProviding
  private var pressStartedAt: Date?

  init(provider: any ToolkitDeviceControlProviding) {
    self.provider = provider
  }

  // MARK: - Target

  /// Exactly one adopted candidate, or none. Toolkit sends device mutations,
  /// so it will not guess which device the person meant when the machine
  /// offers more than one.
  var target: ToolkitTargetPresentation? {
    let adopted = deviceObservation.candidates.filter { $0.isAdopted }
    guard adopted.count == 1, let device = adopted.first,
      let targetID = device.adoptedTargetID
    else { return nil }
    let name = device.deviceInformation?.name ?? device.observedFacts?.model ?? targetID
    return ToolkitTargetPresentation(
      id: targetID, bindingRevision: device.bindingRevision, displayName: name)
  }

  var targetName: String { target?.displayName ?? toolkitText("toolkit.target.none") }

  var targetDetail: String {
    guard let target else { return toolkitText("toolkit.target.none.detail") }
    guard let revision = target.bindingRevision else { return target.id }
    return "\(target.id) · binding r\(revision)"
  }

  var canCapture: Bool { target != nil }

  var emptyMessage: String {
    if let captureFailure { return captureFailure }
    return canCapture
      ? toolkitText("toolkit.screen.empty.ready") : toolkitText("toolkit.screen.empty.noTarget")
  }

  /// The age is stated, never hidden behind a soothing word. A person acting
  /// on a still needs to know how stale it is, because nothing here refreshes
  /// it for them.
  var frameAgeSummary: String {
    guard let frame else { return toolkitText("toolkit.frame.none") }
    guard let captured = ISO8601DateFormatter().date(from: frame.capturedAtUTC) else {
      return toolkitText("toolkit.frame.unknownAge")
    }
    let seconds = Int(Date().timeIntervalSince(captured))
    let measured = seconds < 0 ? 0 : seconds
    return "\(toolkitText("toolkit.frame.age")) \(measured)s · \(frame.width)×\(frame.height)"
  }

  func publish(deviceObservation: DeviceListPresentation) {
    self.deviceObservation = deviceObservation
  }

  func refresh() async {}

  // MARK: - Screenshot

  func captureScreen() async {
    guard let target, !isCapturing else { return }
    isCapturing = true
    defer { isCapturing = false }
    switch await provider.captureScreen(target: target) {
    case .captured(let frame):
      self.frame = frame
      captureFailure = nil
      pendingMarker = nil
      lastMarker = nil
      // A fresh picture is the only thing that clears staleness. There is no
      // way to un-change a screen.
      liveness.captured()
      append(
        title: toolkitText("toolkit.log.captured"),
        detail: "\(frame.width)×\(frame.height)", systemImage: "camera", tint: "neutral")
    case .failed(let reason):
      // The previous picture stays on screen rather than being cleared: it is
      // still the last thing the device is known to have shown, and blanking
      // it would replace a stale truth with nothing.
      captureFailure = reason
      append(
        title: toolkitText("toolkit.log.captureFailed"), detail: reason,
        systemImage: "exclamationmark.triangle.fill", tint: "failed")
    }
  }

  // MARK: - Gestures

  func pointerMoved(to location: CGPoint, rendered: CGSize) {
    if pressStartedAt == nil { pressStartedAt = Date() }
    guard rendered.width > 0, rendered.height > 0 else { return }
    pendingMarker = Marker(
      unitX: min(max(location.x / rendered.width, 0), 1),
      unitY: min(max(location.y / rendered.height, 0), 1))
  }

  func pointerEnded(
    start: CGPoint, end: CGPoint, rendered: CGSize, frame: ToolkitScreenFrame
  ) async {
    let heldFor = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    pressStartedAt = nil
    guard rendered.width > 0, rendered.height > 0, !isSendingGesture else {
      pendingMarker = nil
      return
    }
    // Refused here rather than sent and explained afterwards: the point is
    // that this press never reaches the device, and saying why is what makes
    // the refusal act on instead of merely be complained about.
    guard !frameIsStale else {
      pendingMarker = nil
      append(
        title: toolkitText("toolkit.stale.refused"),
        detail: toolkitText("toolkit.stale.refused.detail"),
        systemImage: "exclamationmark.triangle.fill", tint: "failed", isRefusal: true)
      return
    }
    let travelled = hypot(end.x - start.x, end.y - start.y)
    let request = Self.gesture(
      start: start, end: end, travelled: travelled, heldFor: heldFor,
      rendered: rendered, frame: frame)

    // The marker is anchored where the press began, not where it was
    // released: a few points of drift while clicking must not move the point
    // the person aimed at.
    pendingMarker = Marker(
      unitX: min(max(start.x / rendered.width, 0), 1),
      unitY: min(max(start.y / rendered.height, 0), 1))
    guard let target else {
      pendingMarker = nil
      return
    }

    isSendingGesture = true
    defer { isSendingGesture = false }
    let outcome = await provider.send(request, to: target)
    lastMarker = pendingMarker
    pendingMarker = nil
    // Confirmed and unknown both change the screen as far as anyone here can
    // tell: one is known to have landed and the other may have. Only a clean
    // failure leaves the picture still true.
    liveness.settled(outcome)

    let coordinates = Self.describe(request)
    switch outcome {
    case .confirmed(let summary):
      append(
        title: "\(toolkitText(Self.title(for: request.gesture))) · "
          + toolkitText("toolkit.log.confirmed"),
        detail: summary["verifiedFacts"].map { "\(coordinates) · \($0)" } ?? coordinates,
        systemImage: "checkmark.circle.fill", tint: "confirmed")
    case .failed(let reason):
      append(
        title: "\(toolkitText(Self.title(for: request.gesture))) · "
          + toolkitText("toolkit.log.failed"),
        detail: "\(coordinates) · \(reason)",
        systemImage: "xmark.circle.fill", tint: "failed")
    case .unknown(let reason):
      // Unknown is shown as unknown and offers no resend. The runtime could
      // not say whether the device received it, and a second gesture might be
      // a second gesture rather than a retry.
      append(
        title: "\(toolkitText(Self.title(for: request.gesture))) · "
          + toolkitText("toolkit.log.unknown"),
        detail: "\(coordinates) · \(reason)",
        systemImage: "questionmark.circle.fill", tint: "unknown")
    }
  }

  /// Classifies one completed pointer sequence and maps it into device
  /// pixels. Travel decides between a swipe and a press; for a press, the
  /// hold decides between tap and long press.
  static func gesture(
    start: CGPoint, end: CGPoint, travelled: CGFloat, heldFor: TimeInterval,
    rendered: CGSize, frame: ToolkitScreenFrame
  ) -> ToolkitGestureRequest {
    func devicePoint(_ point: CGPoint) -> (x: Int, y: Int) {
      let x = Int((point.x / rendered.width) * CGFloat(frame.width))
      let y = Int((point.y / rendered.height) * CGFloat(frame.height))
      return (min(max(x, 0), frame.width - 1), min(max(y, 0), frame.height - 1))
    }
    let from = devicePoint(start)
    if travelled >= travelThreshold {
      let to = devicePoint(end)
      // The swipe carries the real press-to-release time, clamped into the
      // operation's published range rather than invented.
      let duration = min(max(Int(heldFor * 1000), 80), 2000)
      return ToolkitGestureRequest(
        gesture: .swipe, x: from.x, y: from.y,
        frameWidth: frame.width, frameHeight: frame.height,
        toX: to.x, toY: to.y, durationMs: duration)
    }
    if heldFor >= longPressThreshold {
      return ToolkitGestureRequest(
        gesture: .longPress, x: from.x, y: from.y,
        frameWidth: frame.width, frameHeight: frame.height,
        durationMs: min(max(Int(heldFor * 1000), 500), 2000))
    }
    return ToolkitGestureRequest(
      gesture: .tap, x: from.x, y: from.y,
      frameWidth: frame.width, frameHeight: frame.height)
  }

  static func title(for gesture: ToolkitGesture) -> String {
    switch gesture {
    case .tap: return "toolkit.gesture.tap"
    case .longPress: return "toolkit.gesture.longPress"
    case .swipe: return "toolkit.gesture.swipe"
    }
  }

  static func describe(_ request: ToolkitGestureRequest) -> String {
    switch request.gesture {
    case .tap:
      return "(\(request.x), \(request.y))"
    case .longPress:
      return "(\(request.x), \(request.y)) · \(request.durationMs ?? 0)ms"
    case .swipe:
      return "(\(request.x), \(request.y)) → (\(request.toX ?? 0), \(request.toY ?? 0))"
        + " · \(request.durationMs ?? 0)ms"
    }
  }

  private func append(
    title: String, detail: String, systemImage: String, tint: String,
    isRefusal: Bool = false
  ) {
    log.insert(
      LogEntry(
        title: title, detail: detail, systemImage: systemImage, tintName: tint,
        isRefusal: isRefusal),
      at: 0)
    if log.count > 40 { log.removeLast(log.count - 40) }
  }
}
