import ArkDeckClientKit
import Foundation
import Observation
import SwiftUI

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

  let preview: DevicePreviewSession
  private(set) var keyboardPointer = DeviceKeyboardPointer()
  private var frameTarget: DeviceTargetPresentation?
  private(set) var frame: DeviceScreenFrame?
  private(set) var isCapturing = false
  private(set) var isOpeningHistoryScreen = false
  private(set) var isSendingGesture = false
  private(set) var isRecording = false
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
    preview = DevicePreviewSession(provider: provider)
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

  var canCapture: Bool {
    target != nil && !isOpeningHistoryScreen && !isCapturing && !isSendingGesture
      && !isRecording && !preview.isBusy
  }

  var canSendInput: Bool {
    target != nil && frameTarget == target && !frameIsStale && !isSendingGesture
      && !isCapturing && !isOpeningHistoryScreen && !isRecording && !preview.isBusy
  }

  var previewStatus: String {
    if preview.isRunning {
      return "\(deviceText("device.preview.running")) · \(preview.frameCount)/30"
    }
    if preview.isBusy { return deviceText("device.preview.stopping") }
    switch preview.stopReason {
    case .limit: return deviceText("device.preview.limit")
    case .failed(let reason): return "\(deviceText("device.log.captureFailed")) · \(reason)"
    case .contextChanged: return deviceText("device.preview.contextChanged")
    default: return deviceText("device.preview.detail")
    }
  }

  var emptyMessage: String {
    if let captureFailure { return captureFailure }
    return target != nil
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
    let previousTarget = target
    self.deviceObservation = deviceObservation
    guard previousTarget != target else { return }
    // An immutable historical image remains inspectable when its device leaves.
    if historyPinnedTargetID != nil, frameTarget == nil, !preview.isBusy { return }
    preview.stop(.contextChanged)
    screenGeneration &+= 1
    isOpeningHistoryScreen = false
    frame = nil
    frameTarget = nil
    liveness = DeviceFrameLiveness()
    keyboardPointer = DeviceKeyboardPointer()
    pendingMarker = nil
    lastMarker = nil
    pressStartedAt = nil
  }

  func refresh() async {}

  func recordScreen(using recording: DeviceRecordingViewModel) async {
    guard !isCapturing, !isSendingGesture, !preview.isBusy, !isRecording else { return }
    isRecording = true
    defer { isRecording = false }
    await recording.record(target: target)
  }

  func startPreview() async {
    guard canCapture, let target else { return }
    screenGeneration &+= 1
    let generation = screenGeneration
    await preview.run(target: target) { [weak self] frame in
      guard let self, self.screenGeneration == generation, self.target == target else { return }
      self.accept(frame, from: target)
    }
  }

  func deactivate() {
    preview.stop(.hidden)
    screenGeneration &+= 1
    isOpeningHistoryScreen = false
    pendingMarker = nil
    pressStartedAt = nil
    keyboardPointer.cancelSwipe()
    liveness = DeviceFrameLiveness()
  }

  private func accept(_ frame: DeviceScreenFrame, from target: DeviceTargetPresentation) {
    self.frame = frame
    frameTarget = target
    captureFailure = nil
    pendingMarker = nil
    lastMarker = nil
    keyboardPointer.cancelSwipe()
    liveness.captured()
  }

  // MARK: - Screenshot

  func captureScreen() async {
    guard canCapture, let target else { return }
    isCapturing = true
    screenGeneration &+= 1
    let generation = screenGeneration
    defer { isCapturing = false }
    let result = await provider.captureScreen(target: target)
    guard !Task.isCancelled, screenGeneration == generation, self.target == target else { return }
    switch result {
    case .captured(let frame):
      accept(frame, from: target)
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
    preview.stop(.contextChanged)
    frameTarget = nil
    keyboardPointer = DeviceKeyboardPointer()
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
    preview.stop(.contextChanged)
    frameTarget = nil
    liveness = DeviceFrameLiveness()
    keyboardPointer = DeviceKeyboardPointer()
    screenGeneration &+= 1
    isOpeningHistoryScreen = false
    historyPinnedTargetID = nil
  }

  // MARK: - Gestures

  func pointerMoved(to location: CGPoint, rendered: CGSize) {
    guard !isCapturing, !preview.isBusy, !isSendingGesture else { return }
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
    guard rendered.width > 0, rendered.height > 0, !isSendingGesture,
      !isCapturing, !preview.isBusy, self.frame?.jobID == frame.jobID
    else {
      pendingMarker = nil
      return
    }
    // Refused here rather than sent and explained afterwards: the point is
    // that this press never reaches the device, and saying why is what makes
    // the refusal act on instead of merely be complained about.
    guard canSendInput else {
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
    await send(request)
  }

  func moveKeyboardPointer(dx: Double, dy: Double) {
    guard canSendInput else { return }
    keyboardPointer.move(dx: dx, dy: dy)
  }

  func beginKeyboardSwipe() {
    guard canSendInput else { return }
    keyboardPointer.beginSwipe()
  }

  func cancelKeyboardSwipe() { keyboardPointer.cancelSwipe() }

  func sendKeyboardGesture(_ gesture: DeviceGesture) async {
    guard canSendInput, let frame,
      let request = keyboardPointer.request(gesture, frame: frame)
    else { return }
    pendingMarker = Marker(unitX: keyboardPointer.x, unitY: keyboardPointer.y)
    keyboardPointer.cancelSwipe()
    await send(request)
  }

  private func send(_ request: DeviceGestureRequest) async {
    guard canSendInput, let target else { pendingMarker = nil; return }
    let generation = screenGeneration
    isSendingGesture = true
    defer { isSendingGesture = false }
    let outcome = await provider.send(request, to: target)
    let sameContext = screenGeneration == generation && self.target == target
    if sameContext {
      lastMarker = pendingMarker
      pendingMarker = nil
      liveness.settled(outcome)
    }
    // Confirmed and unknown both change the screen as far as anyone here can
    // tell: one is known to have landed and the other may have. Only a clean
    // failure leaves the picture still true.
    // Keep the receipt visible even if the user navigated away while awaiting
    // it. A late receipt cannot change another target's frame or liveness.
    let coordinates = (sameContext ? "" : "\(target.id) · ") + Self.describe(request)
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
