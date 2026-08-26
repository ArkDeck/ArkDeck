import ArkDeckWorkflows
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class DiagnosticsWorkspaceViewModel {
  private(set) var reading: DiagnosticSessionReading?
  private(set) var selection = DiagnosticReaderSelection(cursorUTC: "")
  private(set) var deviceObservation = DeviceListPresentation.loading

  init() {}

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
    case .captureFailed: diagnosticsText("diagnostics.shot.failed")
    case .notCaptured: diagnosticsText("diagnostics.shot.none")
    case nil: nil
    }
  }

  func absenceDetail(_ mark: DiagnosticSessionReading.Mark) -> String? {
    switch mark.screenshotAbsence {
    case .takenTooFarFromTheMark(let offset):
      "\(diagnosticsText("diagnostics.shot.tooFar.detail")) (+\(offset) ms)"
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
