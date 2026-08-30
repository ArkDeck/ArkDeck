import ArkDeckWorkflows
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class DeviceWorkspaceViewModel {
  /// Below this the pointer did not travel: the gesture is a press at one
  /// place, and how long it was held decides whether that is a tap or a long
  /// press.
  static var travelThreshold: CGFloat { DeviceGestureClassification.travelThresholdPoints }
  /// A press held at least this long is a long press. Anything shorter is a
  /// tap; nothing in between is silently promoted, because a long press the
  /// device receives as a tap is a different act than the one intended.
  static var longPressThreshold: TimeInterval {
    DeviceGestureClassification.longPressThresholdSeconds
  }

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

  private(set) var frame: DeviceScreenFrame?
  private(set) var isCapturing = false
  private(set) var isOpeningHistoryScreen = false
  private(set) var isSendingGesture = false
  private(set) var pendingMarker: Marker?
  private(set) var lastMarker: Marker?
  private(set) var log: [LogEntry] = []
  /// Whether the picture on screen still shows the device.
  ///
  /// Not a matter of age. The runtime's own freshness budget is a second,
  /// and a still is read at a person's own pace - they look, they think,
  /// they decide where to press. See `DeviceFrameLiveness` for why the rule
  /// is about what changed the screen rather than about how old the picture
  /// is; here it only decides whether the next press is sent or refused.
  private(set) var liveness = DeviceFrameLiveness()
  var frameIsStale: Bool { liveness.refusesInput }
  private(set) var deviceObservation = DeviceListPresentation.loading
  private(set) var captureFailure: String?

  private let provider: any DeviceControlProviding
  private var pressStartedAt: Date?
  private var screenGeneration = 0
  private var historyPinnedTargetID: String?

  init(provider: any DeviceControlProviding) {
    self.provider = provider
  }

  // MARK: - Target

  /// The exact target explicitly chosen through History, or one unambiguous
  /// adopted candidate. Device never switches a historical screen to a
  /// different device merely because that device is currently connected.
  var target: DeviceTargetPresentation? {
    let adopted = deviceObservation.candidates.filter { $0.isAdopted }
    let candidates = historyPinnedTargetID.map { targetID in
      adopted.filter { $0.adoptedTargetID == targetID }
    } ?? adopted
    guard candidates.count == 1, let device = candidates.first,
      let targetID = device.adoptedTargetID
    else { return nil }
    let name = device.deviceInformation?.name ?? device.observedFacts?.model ?? targetID
    return DeviceTargetPresentation(
      id: targetID, bindingRevision: device.bindingRevision, displayName: name)
  }

  var targetName: String { target?.displayName ?? deviceText("device.target.none") }

  var targetDetail: String {
    guard let target else { return deviceText("device.target.none.detail") }
    guard let revision = target.bindingRevision else { return target.id }
    return "\(target.id) · binding r\(revision)"
  }

  var canCapture: Bool { target != nil && !isOpeningHistoryScreen }

  var emptyMessage: String {
    if let captureFailure { return captureFailure }
    return canCapture
      ? deviceText("device.screen.empty.ready") : deviceText("device.screen.empty.noTarget")
  }

  /// The age is stated, never hidden behind a soothing word. A person acting
  /// on a still needs to know how stale it is, because nothing here refreshes
  /// it for them.
  var frameAgeSummary: String {
    guard let frame else { return deviceText("device.frame.none") }
    guard let captured = try? Date(frame.capturedAtUTC, strategy: .iso8601) else {
      return deviceText("device.frame.unknownAge")
    }
    let seconds = Int(Date.now.timeIntervalSince(captured))
    let measured = seconds < 0 ? 0 : seconds
    return "\(deviceText("device.frame.age")) \(measured)s · \(frame.width)×\(frame.height)"
  }

  func publish(deviceObservation: DeviceListPresentation) {
    self.deviceObservation = deviceObservation
  }

  func refresh() async {}

  // MARK: - Screenshot

  func captureScreen() async {
    guard let target, !isCapturing, !isOpeningHistoryScreen else { return }
    isCapturing = true
    screenGeneration &+= 1
    let generation = screenGeneration
    defer { isCapturing = false }
    let result = await provider.captureScreen(target: target)
    guard !Task.isCancelled, screenGeneration == generation else { return }
    switch result {
    case .captured(let frame):
      self.frame = frame
      captureFailure = nil
      pendingMarker = nil
      lastMarker = nil
      // A fresh picture is the only thing that clears staleness. There is no
      // way to un-change a screen.
      liveness.captured()
      append(
        title: deviceText("device.log.captured"),
        detail: "\(frame.width)×\(frame.height)", systemImage: "camera", tint: "neutral")
    case .failed(let reason):
      // The previous picture stays on screen rather than being cleared: it is
      // still the last thing the device is known to have shown, and blanking
      // it would replace a stale truth with nothing.
      captureFailure = reason
      append(
        title: deviceText("device.log.captureFailed"), detail: reason,
        systemImage: "exclamationmark.triangle.fill", tint: "failed")
    }
  }

  /// Restores a screenshot Artifact for inspection. Historical frames begin
  /// stale and therefore cannot be used as authority for a new gesture.
  func openHistoryContext(_ context: RuntimeHistoryWorkspaceContext) {
    guard context.workspaceKind == .device else { return }
    screenGeneration &+= 1
    let generation = screenGeneration
    historyPinnedTargetID = context.targetID
    isOpeningHistoryScreen = false
    frame = nil
    pendingMarker = nil
    lastMarker = nil
    pressStartedAt = nil
    liveness = DeviceFrameLiveness()
    guard context.operationReference == "capture.diagnostics@1" else { return }
    isOpeningHistoryScreen = true
    captureFailure = nil
    let provider = provider
    Task { [weak self] in
      let result = await provider.loadHistoricalScreen(
        jobID: context.jobID, targetID: context.targetID)
      guard let self, self.screenGeneration == generation else { return }
      self.isOpeningHistoryScreen = false
      guard !Task.isCancelled else { return }
      switch result {
      case .captured(let frame):
        self.frame = frame
        self.pendingMarker = nil
        self.lastMarker = nil
        // Deliberately do not call `captured()`: a historical still is not a
        // live input surface. A new explicit capture is required first.
        self.liveness = DeviceFrameLiveness()
        self.append(
          title: deviceText("device.log.captured"),
          detail: "History · \(frame.width)×\(frame.height)",
          systemImage: "clock.arrow.circlepath", tint: "neutral")
      case .failed(let reason):
        self.captureFailure = reason
      }
    }
  }

  func dismissHistoryContext() {
    screenGeneration &+= 1
    isOpeningHistoryScreen = false
    historyPinnedTargetID = nil
  }

  // MARK: - Gestures

  func pointerMoved(to location: CGPoint, rendered: CGSize) {
    if pressStartedAt == nil { pressStartedAt = .now }
    guard rendered.width > 0, rendered.height > 0 else { return }
    pendingMarker = Marker(
      unitX: min(max(location.x / rendered.width, 0), 1),
      unitY: min(max(location.y / rendered.height, 0), 1))
  }

  func pointerEnded(
    start: CGPoint, end: CGPoint, rendered: CGSize, frame: DeviceScreenFrame
  ) async {
    let heldFor = pressStartedAt.map { Date.now.timeIntervalSince($0) } ?? 0
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
        title: deviceText("device.stale.refused"),
        detail: deviceText("device.stale.refused.detail"),
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
        title: "\(deviceText(Self.title(for: request.gesture))) · "
          + deviceText("device.log.confirmed"),
        detail: summary["verifiedFacts"].map { "\(coordinates) · \($0)" } ?? coordinates,
        systemImage: "checkmark.circle.fill", tint: "confirmed")
    case .failed(let reason):
      append(
        title: "\(deviceText(Self.title(for: request.gesture))) · "
          + deviceText("device.log.failed"),
        detail: "\(coordinates) · \(reason)",
        systemImage: "xmark.circle.fill", tint: "failed")
    case .unknown(let reason):
      // Unknown is shown as unknown and offers no resend. The runtime could
      // not say whether the device received it, and a second gesture might be
      // a second gesture rather than a retry.
      append(
        title: "\(deviceText(Self.title(for: request.gesture))) · "
          + deviceText("device.log.unknown"),
        detail: "\(coordinates) · \(reason)",
        systemImage: "questionmark.circle.fill", tint: "unknown")
    }
  }

  /// Classifying lives in `DeviceGestureClassification`, where it can be
  /// exercised directly; this workspace only decides when to ask.
  static func gesture(
    start: CGPoint, end: CGPoint, travelled: CGFloat, heldFor: TimeInterval,
    rendered: CGSize, frame: DeviceScreenFrame
  ) -> DeviceGestureRequest {
    DeviceGestureClassification.classify(
      start: start, end: end, travelled: travelled, heldFor: heldFor,
      rendered: rendered, frame: frame)
  }

  static func title(for gesture: DeviceGesture) -> String {
    switch gesture {
    case .tap: return "device.gesture.tap"
    case .longPress: return "device.gesture.longPress"
    case .swipe: return "device.gesture.swipe"
    }
  }

  static func describe(_ request: DeviceGestureRequest) -> String {
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
