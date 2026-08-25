import Foundation
import XCTest

/// The interactive design draft is a mirror of the shipped Viewer and Trace
/// surfaces. These identifiers and localized strings are intentionally a
/// narrow synchronization seam: when the product surface changes, the same
/// change must update the draft instead of letting an older dashboard become
/// the input for a later redesign.
final class ViewerTraceDesignSynchronizationContractTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func source(_ path: String) throws -> String {
    try String(
      contentsOf: repositoryRoot.appending(path: path),
      encoding: .utf8)
  }

  private func localizedValue(
    _ key: String,
    table: String,
    locale: String = "zh-Hans"
  ) throws -> String {
    let data = try Data(
      contentsOf: repositoryRoot.appending(
        path: "ArkDeckApp/Resources/\(table).xcstrings"))
    let document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try XCTUnwrap(document["strings"] as? [String: Any])
    let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing \(key)")
    let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
    let localization = try XCTUnwrap(localizations[locale] as? [String: Any])
    let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
    return try XCTUnwrap(unit["value"] as? String)
  }

  func testPrototypeMirrorsProductionSynchronizationIdentifiers() throws {
    let prototype = try source("docs/design/prototype.html")
    let viewerSource = try source(
      "ArkDeckApp/Features/UIDump/UIDumpWorkspaceView.swift")
    let traceSource = try [
      "ArkDeckApp/Features/Trace/TraceWorkspaceView.swift",
      "ArkDeckApp/Features/Trace/TraceConfigurationView.swift",
      "ArkDeckApp/Features/Trace/TraceProgressArtifactsView.swift",
    ].map(source).joined(separator: "\n")

    let viewerIdentifiers = [
      "viewer.target",
      "viewer.search",
      "viewer.recapture",
      "viewer.showBounds",
      "viewer.footer",
    ]
    let traceIdentifiers = [
      "trace.workspace.summary",
      "trace.capture.section",
      "trace.availability.status",
      "trace.target.picker",
      "trace.target.deviceSummary",
      "trace.profile.picker",
      "trace.duration.input",
      "trace.duration.unit",
      "trace.duration.quick",
      "trace.capture.status",
      "trace.start",
      "trace.viewer.section",
      "trace.viewer.empty",
      "trace.openViewer",
    ]

    for identifier in viewerIdentifiers {
      XCTAssertTrue(viewerSource.contains("\"\(identifier)\""), "App lost \(identifier)")
      XCTAssertTrue(
        prototype.contains("data-sync-id=\"\(identifier)\""),
        "Viewer draft is no longer synchronized at \(identifier)")
    }
    for identifier in traceIdentifiers {
      XCTAssertTrue(traceSource.contains("\"\(identifier)\""), "App lost \(identifier)")
      XCTAssertTrue(
        prototype.contains("data-sync-id=\"\(identifier)\""),
        "Trace draft is no longer synchronized at \(identifier)")
    }
  }

  func testPrototypeUsesCurrentViewerAndTraceLocalizedCopy() throws {
    let prototype = try source("docs/design/prototype.html")
    let keysByTable: [String: [String]] = [
      "UIDumpLocalizable": [
        "viewer.empty.title",
        "viewer.empty.explain",
        "viewer.toolbar.capture",
        "viewer.toolbar.recapture",
        "viewer.toolbar.search",
        "viewer.pane.screenshot",
        "viewer.pane.showBounds",
        "viewer.pane.tree",
      ],
      "TraceLocalizable": [
        "trace.workspace.summary",
        "trace.capture.title",
        "trace.capture.device",
        "trace.capture.profile",
        "trace.duration.seconds",
        "trace.duration.minutes",
        "trace.duration.quick",
        "trace.capture.localOnly",
        "trace.action.start",
        "trace.viewer.title",
        "trace.viewer.description",
        "trace.action.openViewer",
        "trace.availability.available",
        "trace.availability.unavailable",
        "trace.blocker.adapterUnsupported",
        "trace.preset.arkuiDeep",
        "trace.preset.arkuiDeep.detail",
        "trace.preset.renderAnimation",
        "trace.preset.renderAnimation.detail",
        "trace.preset.schedulingIpc",
        "trace.preset.schedulingIpc.detail",
        "trace.preset.io",
        "trace.preset.io.detail",
        "trace.preset.attachmentPanorama",
        "trace.preset.attachmentPanorama.detail",
      ],
    ]

    for (table, keys) in keysByTable {
      for key in keys {
        let value = try localizedValue(key, table: table)
        XCTAssertTrue(
          prototype.contains(value),
          "design draft does not contain current \(table) value for \(key): \(value)")
      }
    }
  }

  func testPrototypeKeepsViewerEmptyFirstAndTraceFocusedOnCaptureAndView() throws {
    let prototype = try source("docs/design/prototype.html")
    let traceStart = try XCTUnwrap(
      prototype.range(of: "/* ---------- Trace ---------- */"))
    let traceEnd = try XCTUnwrap(
      prototype.range(
        of: "/* ---------- Diagnostics ---------- */",
        range: traceStart.upperBound..<prototype.endIndex))
    let traceDraft = String(prototype[traceStart.lowerBound..<traceEnd.lowerBound])
    let viewerDesignSystem = try source(
      "docs/design/arkdeck-ds/src/components/viewer.tsx")
    let durationSource = try source(
      "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/TraceApplicationFacade.swift")

    XCTAssertTrue(
      prototype.contains(#"hasCapture:PARAMS.get("viewerState")==="captured""#))
    XCTAssertTrue(prototype.contains("showBounds:false"))
    XCTAssertTrue(viewerDesignSystem.contains("showBounds = false"))
    XCTAssertFalse(viewerDesignSystem.contains("<h1"))
    XCTAssertTrue(durationSource.contains("case .seconds: [15, 30, 45, 60]"))
    XCTAssertTrue(durationSource.contains("case .minutes: [1, 2, 3]"))
    XCTAssertTrue(prototype.contains("[15,30,45,60]"))
    XCTAssertTrue(prototype.contains("[1,2,3]"))

    for retiredTraceSurface in [
      "Preset",
      "自定义 tag",
      "TagPicker",
      "Debug 参数快照",
      "应用参数并开始抓取(",
      "arkui-deep.raw.ftrace",
      "arkui-deep.filtered.ftrace",
    ] {
      XCTAssertFalse(
        traceDraft.contains(retiredTraceSurface),
        "Trace draft restored retired surface: \(retiredTraceSurface)")
    }
  }
}
