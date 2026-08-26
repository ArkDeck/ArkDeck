import ArkDeckWorkflows
import Foundation
import Observation
import SwiftUI

/// Toolkit · recording.
///
/// The device has no recorder to ask, so a recording here is a bounded run of
/// stills the runtime brings back in one archive and this side composes into a
/// movie. The states below are the work that actually happens, not three words
/// for "busy": capturing is on the device, assembling writes the movie, and
/// validating reads that file back — because "the writer said it finished" is
/// exactly the claim a validating step is there to doubt.
@MainActor
@Observable
final class ToolkitRecordingViewModel {
  enum Stage: Equatable {
    case idle
    /// Refused before anything started. Distinct from `failed`: nothing was
    /// attempted, nothing reached the device, and the run can be made to fit.
    case refused(ToolkitRecordingBudget.Refusal)
    /// The store could not be asked. Not the same as "there is room" - the
    /// runtime will still refuse a recording it cannot keep, so the pane says
    /// what it does not know rather than implying a check that never ran.
    case headroomUnknown
    case capturing(frames: Int)
    case assembling
    case validating
    case ready(Ready)
    case failed(String)
  }

  struct Ready: Equatable {
    let url: URL
    let frameCount: Int
    let framesPerSecond: Double
    let durationSeconds: Double
    let byteCount: Int
    /// Asked for minus captured. Shown rather than folded away, because a
    /// recording quietly missing frames reads as a complete one.
    let framesMissing: Int
  }

  private(set) var stage = Stage.idle
  /// How long a run to ask for. There is no seconds control: the rate is the
  /// device's readback and cannot be requested, so the honest knob is frames.
  var frameCount = 40

  private let provider: any ToolkitDeviceControlProviding
  private let directory: URL

  init(
    provider: any ToolkitDeviceControlProviding,
    directory: URL = FileManager.default.temporaryDirectory
  ) {
    self.provider = provider
    self.directory = directory
  }

  var isBusy: Bool {
    switch stage {
    case .idle, .ready, .failed, .refused, .headroomUnknown: false
    case .capturing, .assembling, .validating: true
    }
  }

  var stageTitle: String {
    switch stage {
    case .idle, .refused, .headroomUnknown: toolkitText("toolkit.record.start")
    case .capturing(let frames): "\(toolkitText("toolkit.record.capturing")) · \(frames)"
    case .assembling: toolkitText("toolkit.record.assembling")
    case .validating: toolkitText("toolkit.record.validating")
    case .ready: toolkitText("toolkit.record.ready")
    case .failed: toolkitText("toolkit.record.failed")
    }
  }

  func record(target: ToolkitTargetPresentation?) async {
    guard !isBusy else { return }
    guard let target else {
      stage = .failed(toolkitText("toolkit.record.noTarget"))
      return
    }

    // Asked before anything starts, because a refusal that arrives after
    // three minutes of capturing has already cost the three minutes - and
    // the store refuses rather than evicting, so there is nothing that can
    // be quietly resolved on the way.
    guard let remaining = await provider.artifactHeadroomBytes() else {
      stage = .headroomUnknown
      return
    }
    if let refusal = ToolkitRecordingBudget.refusal(
      frameCount: frameCount, remainingBytes: remaining)
    {
      stage = .refused(refusal)
      return
    }

    stage = .capturing(frames: frameCount)
    let outcome = await provider.recordScreen(frameCount: frameCount, target: target)
    guard case .captured(let recording) = outcome else {
      if case .failed(let reason) = outcome { stage = .failed(reason) }
      return
    }

    stage = .assembling
    let url = directory.appending(
      path: "ArkDeck-recording-\(UUID().uuidString.prefix(8).lowercased()).mov")
    let composition: ToolkitRecordingComposer.Composition
    do {
      composition = try await ToolkitRecordingComposer.compose(
        frames: recording.frames,
        frameDurationsSeconds: recording.frameDurationsSeconds, into: url)
    } catch {
      stage = .failed("\(error)")
      return
    }

    stage = .validating
    do {
      let reading = try await ToolkitRecordingValidation.validate(composition)
      stage = .ready(
        Ready(
          url: composition.url, frameCount: composition.frameCount,
          framesPerSecond: composition.framesPerSecond,
          durationSeconds: reading.durationSeconds, byteCount: reading.byteCount,
          framesMissing: recording.framesMissing))
    } catch {
      // A file that does not read back is not a recording, and it is not
      // offered as one. The composed file stays on disk for a person to
      // inspect rather than being deleted under them.
      stage = .failed("\(error)")
    }
  }

  func reset() {
    guard !isBusy else { return }
    stage = .idle
  }

  /// Shrink the run to what the store can hold. Offered rather than done for
  /// the person: a shorter recording may not be the recording they wanted.
  func shrinkToFit(_ refusal: ToolkitRecordingBudget.Refusal) {
    guard !isBusy, refusal.framesThatWouldFit >= 2 else { return }
    frameCount = refusal.framesThatWouldFit
    stage = .idle
  }
}
