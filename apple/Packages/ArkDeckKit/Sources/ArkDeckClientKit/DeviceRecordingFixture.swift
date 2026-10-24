import Foundation

/// Replays a real frame archive so the recording pane can be driven without a
/// device.
///
/// Following `ViewerUIFixture`: nothing here is reached without an explicit
/// launch argument, and it supplies a *domain* object - the frames and their
/// observed spacing - never a presentation, so a test still exercises the
/// App's real assemble-and-validate path rather than a second copy of it.
///
/// What it deliberately does not stand in for is the device leg. The archive
/// it replays has to be one a device produced, so the composing and validating
/// are exercised against bytes that came off hardware; the submit, receive and
/// cleanup legs are covered by the runtime's own contract tests and by the
/// real-hardware runs recorded with them.
public enum DeviceRecordingFixture {
  private static let prefix = "--ui-test-device-recording="

  public static func isSelected(arguments: [String] = CommandLine.arguments) -> Bool {
    arguments.contains { $0.hasPrefix(prefix) }
  }

  /// The provider to install, or `nil` for every ordinary launch.
  public static func provider(
    arguments: [String] = CommandLine.arguments
  ) -> (any DeviceControlProviding)? {
    guard let flag = arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
    return Provider(
      archivePath: String(flag.dropFirst(prefix.count)),
      headroomBytes: requestedHeadroom(in: arguments) ?? (1 << 30),
      headroomDelayMilliseconds: requestedHeadroomDelay(in: arguments))
  }

  /// `--ui-test-device-recording-headroom=<bytes>` so the refusal path can be
  /// driven without filling a real store.
  static func requestedHeadroom(in arguments: [String]) -> Int? {
    guard let flag = arguments.first(where: { $0.hasPrefix(headroomPrefix) }) else { return nil }
    return Int(flag.dropFirst(headroomPrefix.count))
  }

  private static let headroomPrefix = "--ui-test-device-recording-headroom="

  /// Make the asynchronous quota query observable without a device or a full
  /// store. Only the explicitly selected fixture can delay, for at most 10 s.
  private static func requestedHeadroomDelay(in arguments: [String]) -> Int {
    let prefix = "--ui-test-device-recording-headroom-delay-ms="
    guard let flag = arguments.first(where: { $0.hasPrefix(prefix) }),
      let milliseconds = Int(flag.dropFirst(prefix.count))
    else { return 0 }
    return min(10_000, max(0, milliseconds))
  }

  private struct Provider: DeviceControlProviding {
    let archivePath: String
    let headroomBytes: Int
    let headroomDelayMilliseconds: Int

    func captureScreen(target: DeviceTargetPresentation) async -> DeviceScreenshotResult {
      .failed("the recording fixture supplies no screenshot")
    }

    func send(
      _ request: DeviceGestureRequest, to target: DeviceTargetPresentation
    ) async -> DeviceGestureOutcome {
      .failed(reason: "the recording fixture injects nothing")
    }

    /// The fixture replays an archive it already holds, so by construction
    /// there is room for it.
    ///
    /// Reporting nothing here was wrong and shipped that way: the pane treats
    /// "cannot tell" as a reason not to start, so a fixture that could not
    /// answer made the pane unable to record at all. A stand-in that blocks
    /// the flow it stands in for is not standing in for anything.
    /// `--ui-test-device-recording-headroom=<bytes>` drives the refusal path.
    /// A negative figure stands in for a store that cannot be asked at all -
    /// what a daemon predating `artifact.quota` does, answering
    /// `unknownMethod`. It is a distinct case from "no room", and the pane
    /// treats it differently, so it needs its own way in.
    func artifactHeadroomBytes() async -> Int? {
      if headroomDelayMilliseconds > 0 {
        try? await Task.sleep(for: .milliseconds(headroomDelayMilliseconds))
      }
      return headroomBytes < 0 ? nil : headroomBytes
    }

    func recordScreen(
      frameCount: Int, target: DeviceTargetPresentation
    ) async -> DeviceScreenRecordingResult {
      guard let archive = try? Data(contentsOf: URL(filePath: archivePath)) else {
        return .failed("the fixture archive at \(archivePath) could not be read")
      }
      guard let all = try? DeviceFrameArchive.frames(in: archive) else {
        return .failed("the fixture archive at \(archivePath) is not a frame archive")
      }
      // A run asks for a bounded number of frames; replaying more than the
      // archive holds would be inventing them.
      let frames = Array(all.prefix(frameCount))
      guard !frames.isEmpty else { return .failed("the fixture archive holds no frames") }
      // The spacing a device actually produced, so the composed timeline is
      // the one hardware gives rather than a round number.
      return .captured(
        DeviceScreenRecording(
          frames: frames,
          frameDurationsSeconds: Array(repeating: 0.543, count: frames.count),
          framesMissing: max(0, frameCount - all.count)))
    }
  }
}
