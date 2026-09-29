import Foundation
import Testing

@testable import ArkDeckCore
@testable import ArkDeckClientKit

/// The Device workspace's submission surface (TASK-IDC-002 stage 3).
struct DeviceControlFacadeContractTests {
  private let target = DeviceTargetPresentation(
    id: "TGT-1a62a0dbedd6", bindingRevision: 1, displayName: "DAYU200")

  @Test func productRenamePreservesExistingIntentAndClientIdentity() throws {
    let screenshot = try DeviceControlFacade.screenshotRequest(target: target, nonce: "upgrade")
    let recording = try DeviceControlFacade.recordingRequest(
      frameCount: 2, target: target, nonce: "upgrade")
    let gesture = try DeviceControlFacade.gestureRequest(
      DeviceGestureRequest(gesture: .tap, x: 1, y: 2, frameWidth: 100, frameHeight: 200),
      target: target, nonce: "upgrade")

    for (request, prefix) in [
      (screenshot, "toolkit-screen"), (recording, "toolkit-record"),
      (gesture, "toolkit-input"),
    ] {
      #expect(request.requestID == "\(prefix)-upgrade")
      #expect(request.idempotencyKey == "\(prefix)-upgrade")
      #expect(request.clientContext?.clientName == "ArkDeckApp.Toolkit.DeviceControl")
    }
  }

  @Test func everyDeviceSubmissionNamesItsOwnClient() throws {
    let screenshot = try DeviceControlFacade.screenshotRequest(
      target: target, nonce: "n1")
    #expect(
      screenshot.clientContext?.clientName == ArkDeckAgentClientName.deviceControl,
      """
      the daemon admits a submission by client and operation together, so Device \
      cannot borrow another workspace's client name
      """)
    #expect(screenshot.target.targetID == target.id)
    #expect(screenshot.target.expectedBindingRevision == 1)

    for gesture in DeviceGesture.allCases {
      let request = try DeviceControlFacade.gestureRequest(
        DeviceGestureRequest(
          gesture: gesture, x: 10, y: 20, frameWidth: 1280, frameHeight: 2832,
          toX: 30, toY: 40, durationMs: 300),
        target: target, nonce: "n-\(gesture.rawValue)")
      #expect(
        request.clientContext?.clientName == ArkDeckAgentClientName.deviceControl)
      #expect(request.operation.id == gesture.operationID)
      #expect(request.operation.version == 1)
    }
  }

  @Test func theScreenshotLegAsksForNothingItDoesNotRead() throws {
    let request = try DeviceControlFacade.screenshotRequest(target: target, nonce: "n")
    #expect(request.inputs["uiScreenshot"] == .bool(true))
    // Draining the log buffer can dominate the interaction, and nothing in
    // this workspace reads a component tree.
    #expect(request.inputs["captureHilog"] == .bool(false))
    #expect(request.inputs["uiComponentTree"] == .bool(false))
    #expect(request.inputs["uiDump"] == .bool(false))
    #expect(request.inputs["crashLogs"] == .bool(false))
  }

  @Test func everyGestureCarriesTheFrameItWasReadFrom() throws {
    for gesture in DeviceGesture.allCases {
      let inputs = DeviceGestureRequest(
        gesture: gesture, x: 1, y: 2, frameWidth: 1280, frameHeight: 2832,
        toX: 3, toY: 4, durationMs: 500
      ).typedInputs
      #expect(
        inputs["displayWidth"] == .integer(1280),
        "the injector does not bound coordinates itself, so the frame must travel")
      #expect(inputs["displayHeight"] == .integer(2832))
    }
  }

  @Test func gestureInputsUseEachOperationsOwnFieldNames() {
    let tap = DeviceGestureRequest(
      gesture: .tap, x: 640, y: 1400, frameWidth: 1280, frameHeight: 2832
    ).typedInputs
    #expect(tap["x"] == .integer(640))
    #expect(tap["y"] == .integer(1400))
    #expect(tap["durationMs"] == nil, "a tap has no hold time")
    #expect(tap["fromX"] == nil)

    let long = DeviceGestureRequest(
      gesture: .longPress, x: 5, y: 6, frameWidth: 1280, frameHeight: 2832,
      durationMs: 900
    ).typedInputs
    #expect(long["x"] == .integer(5))
    #expect(
      long["durationMs"] == .integer(900),
      "the caller's real hold time is passed through, not replaced by a default")

    let swipe = DeviceGestureRequest(
      gesture: .swipe, x: 100, y: 200, frameWidth: 1280, frameHeight: 2832,
      toX: 100, toY: 1200, durationMs: 500
    ).typedInputs
    #expect(swipe["fromX"] == .integer(100))
    #expect(swipe["fromY"] == .integer(200))
    #expect(swipe["toX"] == .integer(100))
    #expect(swipe["toY"] == .integer(1200))
    #expect(swipe["durationMs"] == .integer(500))
    #expect(swipe["x"] == nil, "the swipe operation names its start fromX/fromY")
  }

  @Test func twoGesturesAtOneCoordinateAreTwoIntents() throws {
    let gesture = DeviceGestureRequest(
      gesture: .tap, x: 640, y: 1400, frameWidth: 1280, frameHeight: 2832)
    let first = try DeviceControlFacade.gestureRequest(
      gesture, target: target, nonce: "a")
    let second = try DeviceControlFacade.gestureRequest(
      gesture, target: target, nonce: "b")
    #expect(
      first.idempotencyKey != second.idempotencyKey,
      """
      tapping the same place twice is two intents; a shared key would let the \
      runtime deduplicate the second one away
      """)
  }

  @Test func thePictureIsMeasuredFromItselfNotFromWhatCameWithIt() {
    // A 1280x2832 PNG header, which is where the frame the workspace maps
    // against has to come from.
    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    png.append(contentsOf: [0x00, 0x00, 0x00, 0x0D])
    png.append(contentsOf: Array("IHDR".utf8))
    png.append(contentsOf: [0x00, 0x00, 0x05, 0x00])
    png.append(contentsOf: [0x00, 0x00, 0x0B, 0x10])
    let size = DeviceScreenshotIntegrity.pngPixelSize(png)
    #expect(size?.width == 1280)
    #expect(size?.height == 2832)

    #expect(
      DeviceScreenshotIntegrity.pngPixelSize(Data([0x89, 0x50])) == nil,
      "a truncated file has no dimensions to read")
    #expect(
      DeviceScreenshotIntegrity.pngPixelSize(Data(repeating: 0, count: 64)) == nil,
      "a file that is not a PNG must not be measured as one")
  }

  @Test func theGestureSummaryRepeatsWhatTheRuntimeAttested() {
    let timeline = [
      "jobCreated",
      "intent inject-pointer-input",
      "verified inject-pointer-input [\"frame\", \"gesture\", \"x\", \"y\"]",
    ]
    let summary = DeviceProductionProviderTestHook.injectionSummary(in: timeline)
    #expect(summary["verifiedFacts"] == "frame, gesture, x, y")

    #expect(
      DeviceProductionProviderTestHook.injectionSummary(in: ["jobCreated"]).isEmpty,
      """
      with no verified injection recorded there is nothing to show, and nothing \
      may be invented in its place
      """)
  }
}
