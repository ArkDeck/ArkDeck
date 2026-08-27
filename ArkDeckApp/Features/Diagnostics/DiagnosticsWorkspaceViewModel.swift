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
  private(set) var session: DiagnosticSessionPresentation?
  private(set) var isLoading = false
  private(set) var loadError: String?
  private(set) var previewText: String?
  private(set) var previewName: String?
  private(set) var previewError: String?
  private(set) var isPreviewLoading = false
  private(set) var previewWasClipped = false
  private(set) var previewReplacedInvalidUTF8 = false
  private var context: RuntimeHistoryWorkspaceContext?
  private var generation = UUID()
  private var previewGeneration = UUID()
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private let provider: any RuntimeJobDetailApplicationProviding

  /// No Diagnostic Session capture provider is composed into the App. The
  /// published capture supports a bounded ring snapshot, but not interactive
  /// append-marker/stop orchestration. These controls must not imply otherwise.
  /// An adopted device or a local button press cannot prove recording began.
  let captureUnavailableReasonCode = "diagnostic_session_capture_not_connected"

  init(provider: any RuntimeJobDetailApplicationProviding) {
    self.provider = provider
  }

  func openHistoryContext(_ context: RuntimeHistoryWorkspaceContext) {
    self.context = context
    reload()
  }

  var traceContext: RuntimeHistoryWorkspaceContext? {
    guard let session, TracePublishedArtifactPolicy.selectRawTrace(from: session.artifacts) != nil else { return nil }
    return context
  }

  func reload() {
    guard let context else { return }
    loadTask?.cancel()
    let ticket = UUID()
    generation = ticket
    previewGeneration = UUID()
    reading = nil
    session = nil
    loadError = nil
    previewText = nil
    previewName = nil
    previewError = nil
    previewWasClipped = false
    previewReplacedInvalidUTF8 = false
    isPreviewLoading = false
    isLoading = true
    loadTask = Task { [weak self, provider] in
      let result = await DiagnosticSessionApplicationReader(provider: provider).load(context)
      guard let self, !Task.isCancelled, generation == ticket else { return }
      isLoading = false
      switch result {
      case .loaded(let session):
        self.session = session
        publish(reading: session.reading)
      case .unavailable(let reason): loadError = reason
      }
    }
  }

  /// Reading device text is a separate, explicit local action. No raw bytes
  /// are fetched on History navigation, exported, or sent to another service.
  func preview(_ artifact: RuntimeArtifactPresentation) {
    guard let context, session?.artifacts.contains(artifact) == true,
      artifact.mediaType == "text/plain" || artifact.mediaType == "application/json"
    else { return }
    let ticket = UUID()
    previewGeneration = ticket
    isPreviewLoading = true
    previewName = artifact.name
    previewText = nil
    previewError = nil
    previewWasClipped = false
    previewReplacedInvalidUTF8 = false
    Task { [weak self, provider] in
      let result = await provider.readArtifact(
        jobID: context.jobID, artifact: artifact, maximumBytes: 2 * 1_024 * 1_024,
        allowSensitive: artifact.privacy == "sensitive")
      guard let self, previewGeneration == ticket else { return }
      isPreviewLoading = false
      switch result {
      case .loaded(let bytes):
        guard let preview = DiagnosticArtifactTextPreview(bytes: bytes, mediaType: artifact.mediaType) else {
          previewError = diagnosticsText("diagnostics.preview.invalidStructuredText")
          return
        }
        previewWasClipped = preview.wasClipped
        previewReplacedInvalidUTF8 = preview.replacedInvalidUTF8
        previewText = preview.text
      case .failed(let reason): previewError = reason
      }
    }
  }

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

  func publish(deviceObservation: DeviceListPresentation) {
    self.deviceObservation = deviceObservation
  }

  func publish(reading: DiagnosticSessionReading) {
    self.reading = reading
    selection = DiagnosticReaderSelection(cursorUTC: reading.marks.first?.atHostUTC ?? "")
  }

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
    if reason == "capture artifacts contain no host-to-device calibration" {
      return diagnosticsText("diagnostics.alignment.explain")
    }
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
