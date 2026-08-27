import ArkDeckWorkflows
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class DiagnosticsWorkspaceViewModel {
  /// A session is armed, or it is not, or the device would not have it. There
  /// is no state for "probably running": a person about to reproduce a bug
  /// needs to know whether anything is being kept.
  enum CaptureState: Equatable {
    case idle
    case arming
    case armed(marks: Int)
    case refusedBusy(String)
    case failed(String)
  }

  private(set) var reading: DiagnosticSessionReading?
  private(set) var selection = DiagnosticReaderSelection(cursorUTC: "")
  private(set) var deviceObservation = DeviceListPresentation.loading
  private(set) var capture = CaptureState.idle
  /// The marks a person made while the ring was holding. They are host
  /// instants and reach no device, which is why marking can be instant and
  /// why it keeps working when the device is busy doing something else.
  private(set) var pendingMarks: [String] = []

  init() {}

  // MARK: - Capture

  /// Exactly one adopted candidate, or none. A capture writes to a device, so
  /// it will not guess which one when the machine offers more than one.
  var target: DeviceTargetPresentation? {
    let adopted = deviceObservation.candidates.filter { $0.isAdopted }
    guard adopted.count == 1, let device = adopted.first,
      let targetID = device.adoptedTargetID
    else { return nil }
    let name = device.deviceInformation?.name ?? device.observedFacts?.model ?? targetID
    return DeviceTargetPresentation(
      id: targetID, bindingRevision: device.bindingRevision, displayName: name)
  }

  var canArm: Bool {
    guard target != nil else { return false }
    if case .idle = capture { return true }
    if case .failed = capture { return true }
    if case .refusedBusy = capture { return true }
    return false
  }

  var isArmed: Bool {
    if case .armed = capture { return true }
    return false
  }

  func arm() {
    guard canArm else { return }
    capture = .arming
    pendingMarks = []
    capture = .armed(marks: 0)
  }

  /// A mark is a host instant. It reaches no device, so it costs nothing and
  /// cannot fail - which is the whole reason it can be made in the moment
  /// somebody notices something.
  func mark(at instant: String) {
    guard isArmed else { return }
    pendingMarks.append(instant)
    capture = .armed(marks: pendingMarks.count)
  }

  func stop() {
    capture = .idle
  }

  /// A device somebody else's session holds. Refused rather than queued, and
  /// said so: a request that waited its turn would run later without anyone
  /// deciding that it should.
  func refuseBusy(_ detail: String) {
    capture = .refusedBusy(detail)
  }

  func fail(_ reason: String) {
    capture = .failed(reason)
  }

  var captureTitle: String {
    switch capture {
    case .idle: diagnosticsText("diagnostics.capture.arm")
    case .arming: diagnosticsText("diagnostics.capture.arming")
    case .armed: diagnosticsText("diagnostics.capture.stop")
    case .refusedBusy: diagnosticsText("diagnostics.capture.arm")
    case .failed: diagnosticsText("diagnostics.capture.arm")
    }
  }

  var captureNotice: (title: String, detail: String, isRefusal: Bool)? {
    switch capture {
    case .armed:
      (
        diagnosticsText("diagnostics.capture.armed"),
        diagnosticsText("diagnostics.capture.armed.detail"), false
      )
    case .refusedBusy(let detail):
      (
        diagnosticsText("diagnostics.busy.title"),
        "\(diagnosticsText("diagnostics.busy.detail")) \(detail)", true
      )
    case .failed(let reason):
      (diagnosticsText("diagnostics.capture.failed"), reason, true)
    case .idle, .arming:
      target == nil
        ? (diagnosticsText("diagnostics.capture.noTarget"), "", false) : nil
    }
  }

  func publish(deviceObservation: DeviceListPresentation) {
    self.deviceObservation = deviceObservation
  }

  func publish(reading: DiagnosticSessionReading) {
    self.reading = reading
    selection = DiagnosticReaderSelection(cursorUTC: reading.marks.first?.atHostUTC ?? "")
  }

  func refresh() async {}

  // MARK: - Alignment

  /// The three states, and never a fourth that means "probably fine". Which
  /// one holds decides whether anything below it can be believed, so it is
  /// stated in the toolbar rather than buried.
  var alignmentTitle: String {
    switch reading?.alignment {
    case .sameClock: diagnosticsText("diagnostics.alignment.sameClock")
    case .calibrated(let tolerance): "\(diagnosticsText("diagnostics.alignment.calibrated")) ±\(tolerance) ms"
    case .cannotAlign, nil: diagnosticsText("diagnostics.alignment.cannotAlign")
    }
  }

  var alignmentIsRefusal: Bool {
    if case .cannotAlign = reading?.alignment { return true }
    return reading == nil
  }

  var alignmentDetail: String? {
    guard case .cannotAlign(let reason) = reading?.alignment else { return nil }
    return "\(diagnosticsText("diagnostics.alignment.explain")) (\(reason))"
  }

  var isPartial: Bool { reading?.isPartial == true }

  // MARK: - Marks

  var marks: [DiagnosticSessionReading.Mark] { reading?.marks ?? [] }

  func markTitle(_ mark: DiagnosticSessionReading.Mark) -> String {
    let kind =
      mark.isAutomatic
      ? diagnosticsText("diagnostics.mark.auto") : diagnosticsText("diagnostics.mark.manual")
    if let label = mark.label { return "\(kind) \(mark.ordinal) · \(label)" }
    if let trigger = mark.trigger { return "\(kind) \(mark.ordinal) · \(trigger)" }
    return "\(kind) \(mark.ordinal)"
  }

  /// The offset is part of the reading, not a footnote: a picture taken 120 ms
  /// after a mark is a picture of 120 ms after the mark.
  func screenshotCaption(_ mark: DiagnosticSessionReading.Mark) -> String? {
    guard let shot = mark.screenshot else { return nil }
    return "+\(shot.takenAfterMarkMs) ms \(diagnosticsText("diagnostics.shot.takenAfter"))"
  }

  /// Why there is no picture here. Each reason is different and none of them
  /// is an older frame.
  func absenceTitle(_ mark: DiagnosticSessionReading.Mark) -> String? {
    switch mark.screenshotAbsence {
    case .takenTooFarFromTheMark: diagnosticsText("diagnostics.shot.tooFar")
    // Different from "not this moment": nothing here can tell either way.
    case .shutterWindowWiderThanTheRule: diagnosticsText("diagnostics.shot.undecidable")
    case .captureFailed: diagnosticsText("diagnostics.shot.failed")
    case .notCaptured: diagnosticsText("diagnostics.shot.none")
    case nil: nil
    }
  }

  func absenceDetail(_ mark: DiagnosticSessionReading.Mark) -> String? {
    switch mark.screenshotAbsence {
    case .takenTooFarFromTheMark(let offset):
      "\(diagnosticsText("diagnostics.shot.tooFar.detail")) (+\(offset) ms)"
    case .shutterWindowWiderThanTheRule(let window):
      "\(diagnosticsText("diagnostics.shot.undecidable.detail")) "
        + "(\(window) ms > \(DiagnosticSessionReading.screenshotAppliesWithinMs) ms)"
    case .captureFailed(let reason): reason
    case .notCaptured, nil: nil
    }
  }

  // MARK: - Selection

  /// Moving the cursor never clears the selected event. Crossing between an
  /// event and the log lines around it is the basic act of reading a session,
  /// and it must not cost the thing being read.
  func moveCursor(to instant: String) {
    selection.moveCursor(to: instant)
  }

  func select(event: DiagnosticReaderSelection.Event) {
    selection.select(event)
  }

  var selectionSummary: String {
    guard let event = selection.event else {
      return diagnosticsText("diagnostics.selection.timeOnly")
    }
    guard let drift = selection.cursorOffsetFromEventMs(), drift != 0 else {
      return event.name
    }
    let sign = drift > 0 ? "+" : ""
    return "\(event.name) · \(diagnosticsText("diagnostics.selection.driftedAway")) \(sign)\(drift) ms"
  }
}
