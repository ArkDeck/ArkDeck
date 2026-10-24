import Foundation

/// Explicit UI-only fixture. It never contacts Runtime or fabricates evidence.
public enum DeviceInteractionFixture {
  public static func provider(arguments: [String] = CommandLine.arguments) -> (any DeviceControlProviding)? {
    guard arguments.contains("--ui-test-device-interaction") else { return nil }
    return Provider(unknown: arguments.contains("--ui-test-device-input-unknown"))
  }

  private actor Provider: DeviceControlProviding {
    let unknown: Bool
    private var count = 0

    init(unknown: Bool) { self.unknown = unknown }

    func captureScreen(target: DeviceTargetPresentation) async -> DeviceScreenshotResult {
      count += 1
      let sample = ViewerUIFixture.capture()
      return .captured(DeviceScreenFrame(
        imageData: sample.screenshotData, width: sample.screenshotWidth,
        height: sample.screenshotHeight, capturedAtUTC: Date.now.ISO8601Format(),
        jobID: "device-ui-fixture-\(count)"))
    }

    func send(_ request: DeviceGestureRequest, to target: DeviceTargetPresentation) async -> DeviceGestureOutcome {
      unknown ? .unknown(reason: "UI fixture: outcome unknown") : .confirmed(summary: [:])
    }

    func recordScreen(frameCount: Int, target: DeviceTargetPresentation) async -> DeviceScreenRecordingResult {
      .failed("The interaction fixture does not record")
    }

    func artifactHeadroomBytes() async -> Int? { nil }
  }
}
