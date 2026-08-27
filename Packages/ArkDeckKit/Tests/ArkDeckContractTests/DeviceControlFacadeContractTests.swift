import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckWorkflows

/// The Device workspace's submission surface (TASK-IDC-002 stage 3).
final class DeviceControlFacadeContractTests: XCTestCase {
  private let target = DeviceTargetPresentation(
    id: "TGT-1a62a0dbedd6", bindingRevision: 1, displayName: "DAYU200")

  func testProductRenamePreservesExistingIntentAndClientIdentity() throws {
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
      XCTAssertEqual(request.requestID, "\(prefix)-upgrade")
      XCTAssertEqual(request.idempotencyKey, "\(prefix)-upgrade")
      XCTAssertEqual(request.clientContext?.clientName, "ArkDeckApp.Toolkit.DeviceControl")
    }
  }

  func testEveryDeviceSubmissionNamesItsOwnClient() throws {
    let screenshot = try DeviceControlFacade.screenshotRequest(
      target: target, nonce: "n1")
    XCTAssertEqual(
      screenshot.clientContext?.clientName, ArkDeckAgentClientName.deviceControl,
      "the daemon admits a submission by client and operation together, so Device "
        + "cannot borrow another workspace's client name")
    XCTAssertEqual(screenshot.target.targetID, target.id)
    XCTAssertEqual(screenshot.target.expectedBindingRevision, 1)

    for gesture in DeviceGesture.allCases {
      let request = try DeviceControlFacade.gestureRequest(
        DeviceGestureRequest(
          gesture: gesture, x: 10, y: 20, frameWidth: 1280, frameHeight: 2832,
          toX: 30, toY: 40, durationMs: 300),
        target: target, nonce: "n-\(gesture.rawValue)")
      XCTAssertEqual(
        request.clientContext?.clientName, ArkDeckAgentClientName.deviceControl)
      XCTAssertEqual(request.operation.id, gesture.operationID)
      XCTAssertEqual(request.operation.version, 1)
    }
  }

  func testTheScreenshotLegAsksForNothingItDoesNotRead() throws {
    let request = try DeviceControlFacade.screenshotRequest(target: target, nonce: "n")
    XCTAssertEqual(request.inputs["uiScreenshot"], .bool(true))
    // Draining the log buffer can dominate the interaction, and nothing in
    // this workspace reads a component tree.
    XCTAssertEqual(request.inputs["captureHilog"], .bool(false))
    XCTAssertEqual(request.inputs["uiComponentTree"], .bool(false))
    XCTAssertEqual(request.inputs["uiDump"], .bool(false))
    XCTAssertEqual(request.inputs["crashLogs"], .bool(false))
  }

  func testEveryGestureCarriesTheFrameItWasReadFrom() throws {
    for gesture in DeviceGesture.allCases {
      let inputs = DeviceGestureRequest(
        gesture: gesture, x: 1, y: 2, frameWidth: 1280, frameHeight: 2832,
        toX: 3, toY: 4, durationMs: 500
      ).typedInputs
      XCTAssertEqual(
        inputs["displayWidth"], .integer(1280),
        "the injector does not bound coordinates itself, so the frame must travel")
      XCTAssertEqual(inputs["displayHeight"], .integer(2832))
    }
  }

  func testGestureInputsUseEachOperationsOwnFieldNames() {
    let tap = DeviceGestureRequest(
      gesture: .tap, x: 640, y: 1400, frameWidth: 1280, frameHeight: 2832
    ).typedInputs
    XCTAssertEqual(tap["x"], .integer(640))
    XCTAssertEqual(tap["y"], .integer(1400))
    XCTAssertNil(tap["durationMs"], "a tap has no hold time")
    XCTAssertNil(tap["fromX"])

    let long = DeviceGestureRequest(
      gesture: .longPress, x: 5, y: 6, frameWidth: 1280, frameHeight: 2832,
      durationMs: 900
    ).typedInputs
    XCTAssertEqual(long["x"], .integer(5))
    XCTAssertEqual(
      long["durationMs"], .integer(900),
      "the caller's real hold time is passed through, not replaced by a default")

    let swipe = DeviceGestureRequest(
      gesture: .swipe, x: 100, y: 200, frameWidth: 1280, frameHeight: 2832,
      toX: 100, toY: 1200, durationMs: 500
    ).typedInputs
    XCTAssertEqual(swipe["fromX"], .integer(100))
    XCTAssertEqual(swipe["fromY"], .integer(200))
    XCTAssertEqual(swipe["toX"], .integer(100))
    XCTAssertEqual(swipe["toY"], .integer(1200))
    XCTAssertEqual(swipe["durationMs"], .integer(500))
    XCTAssertNil(swipe["x"], "the swipe operation names its start fromX/fromY")
  }

  func testTwoGesturesAtOneCoordinateAreTwoIntents() throws {
    let gesture = DeviceGestureRequest(
      gesture: .tap, x: 640, y: 1400, frameWidth: 1280, frameHeight: 2832)
    let first = try DeviceControlFacade.gestureRequest(
      gesture, target: target, nonce: "a")
    let second = try DeviceControlFacade.gestureRequest(
      gesture, target: target, nonce: "b")
    XCTAssertNotEqual(
      first.idempotencyKey, second.idempotencyKey,
      "tapping the same place twice is two intents; a shared key would let the "
        + "runtime deduplicate the second one away")
  }

  func testThePictureIsMeasuredFromItselfNotFromWhatCameWithIt() {
    // A 1280x2832 PNG header, which is where the frame the workspace maps
    // against has to come from.
    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    png.append(contentsOf: [0x00, 0x00, 0x00, 0x0D])
    png.append(contentsOf: Array("IHDR".utf8))
    png.append(contentsOf: [0x00, 0x00, 0x05, 0x00])
    png.append(contentsOf: [0x00, 0x00, 0x0B, 0x10])
    let size = DeviceScreenshotIntegrity.pngPixelSize(png)
    XCTAssertEqual(size?.width, 1280)
    XCTAssertEqual(size?.height, 2832)

    XCTAssertNil(
      DeviceScreenshotIntegrity.pngPixelSize(Data([0x89, 0x50])),
      "a truncated file has no dimensions to read")
    XCTAssertNil(
      DeviceScreenshotIntegrity.pngPixelSize(Data(repeating: 0, count: 64)),
      "a file that is not a PNG must not be measured as one")
  }

  func testTheGestureSummaryRepeatsWhatTheRuntimeAttested() {
    let timeline = [
      "jobCreated",
      "intent inject-pointer-input",
      "verified inject-pointer-input [\"frame\", \"gesture\", \"x\", \"y\"]",
    ]
    let summary = DeviceProductionProviderTestHook.injectionSummary(in: timeline)
    XCTAssertEqual(summary["verifiedFacts"], "frame, gesture, x, y")

    XCTAssertTrue(
      DeviceProductionProviderTestHook.injectionSummary(in: ["jobCreated"]).isEmpty,
      "with no verified injection recorded there is nothing to show, and nothing "
        + "may be invented in its place")
  }
}
