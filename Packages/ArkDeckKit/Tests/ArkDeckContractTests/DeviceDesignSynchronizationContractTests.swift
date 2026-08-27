import Foundation
import XCTest

/// Keep the design's interaction surface tied to the App. The previous draft
/// exposed a live preview and timed recorder that the product did not have.
final class DeviceDesignSynchronizationContractTests: XCTestCase {
  private var root: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }

  private func source(_ path: String) throws -> String {
    try String(contentsOf: root.appending(path: path), encoding: .utf8)
  }

  func testDraftPreservesTheAppStateAndFailureSurfaces() throws {
    let draft = try source("docs/design/prototype.html")
    let view = try source("ArkDeckApp/Features/Device/DeviceWorkspaceView.swift")
    for identifier in [
      "device.capture", "device.screen.empty", "device.screen.surface", "device.stale.badge",
      "device.log.refused", "device.log.entry", "device.record.frames", "device.record.start",
      "device.record.stage", "device.record.failed", "device.record.refused", "device.record.shrink",
      "device.record.headroomUnknown", "device.record.ready", "device.record.gap",
      "device.record.location", "device.record.reveal", "device.record.saveAs", "device.record.again",
      "device.performance", "device.frame.age", "device.boundary",
    ] {
      XCTAssertTrue(view.contains("\"\(identifier)\""), "App lost \(identifier)")
      XCTAssertTrue(draft.contains("\"\(identifier)\""), "Draft lost \(identifier)")
    }
  }

  func testDraftUsesTheCurrentLocalizedBoundariesInBothLanguages() throws {
    let draft = try source("docs/design/prototype.html")
    let data = Data(try source("ArkDeckApp/Resources/DeviceLocalizable.xcstrings").utf8)
    let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try XCTUnwrap(document["strings"] as? [String: Any])
    for key in [
      "device.screen.empty.title", "device.screen.empty.ready", "device.screen.empty.noTarget",
      "device.stale.refused", "device.stale.refused.detail", "device.boundary",
      "device.record.ceiling", "device.record.timeline", "device.record.headroomUnknown",
      "device.record.preflighting",
      "device.record.noRoom", "device.record.noRoom.detail", "device.performance.detail",
    ] {
      let entry = try XCTUnwrap(strings[key] as? [String: Any])
      let locales = try XCTUnwrap(entry["localizations"] as? [String: Any])
      for locale in ["zh-Hans", "en"] {
        let value = try XCTUnwrap(locales[locale] as? [String: Any])
        let unit = try XCTUnwrap(value["stringUnit"] as? [String: Any])
        let text = try XCTUnwrap(unit["value"] as? String)
        XCTAssertTrue(draft.contains(text), "Draft drift: \(locale) \(key)")
      }
    }
  }

  func testDraftDoesNotRestoreUnimplementedDeviceControls() throws {
    let draft = try source("docs/design/prototype.html")
    for retired in [
      "toggleToolPreview", "stopToolRecording", "toolRecordTime", "handleToolCanvasKey",
      "device-workspace-rail", "device-keyboard-cursor", "device-drag-preview",
      "开启低帧率预览", "停止持续预览", "screen-recording.mp4",
    ] {
      XCTAssertFalse(draft.contains(retired), "Unimplemented Device control returned: \(retired)")
    }
    XCTAssertTrue(draft.contains("交互稿 · 演示数据，不连接设备"))
    XCTAssertTrue(draft.contains("S.deviceControl!==t"), "Old scenario callbacks must not publish")
  }
}
