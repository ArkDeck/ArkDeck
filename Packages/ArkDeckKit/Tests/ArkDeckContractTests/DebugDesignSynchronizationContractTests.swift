import Foundation
import XCTest

/// The interactive design draft is a mirror of the shipped Debug workbench.
///
/// The draft fell two designs behind the product once already: it still drew
/// the v0.9 multi-connector source browser with batch selection and a
/// standalone device restart while the App had shipped a single signed
/// app-owned `.so` per request. These identifiers and localized strings are a
/// narrow synchronization seam, the same one `ViewerTraceDesignSynchronization`
/// holds for Viewer and Trace: when the product surface changes, the same
/// change must update the draft instead of letting an older dashboard become
/// the input for a later redesign.
final class DebugDesignSynchronizationContractTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func source(_ path: String) throws -> String {
    try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
  }

  private func debugDraft(_ prototype: String) throws -> String {
    let start = try XCTUnwrap(prototype.range(of: "/* ---------- Debug ---------- */"))
    let end = try XCTUnwrap(
      prototype.range(
        of: "/* ---------- Flash ---------- */",
        range: start.upperBound..<prototype.endIndex))
    return String(prototype[start.lowerBound..<end.lowerBound])
  }

  private func localizedValue(
    _ key: String,
    table: String = "DebugLocalizable",
    locale: String = "zh-Hans"
  ) throws -> String {
    let data = try Data(
      contentsOf: repositoryRoot.appending(path: "ArkDeckApp/Resources/\(table).xcstrings"))
    let document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try XCTUnwrap(document["strings"] as? [String: Any])
    let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing \(key)")
    let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
    let localization = try XCTUnwrap(localizations[locale] as? [String: Any])
    let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
    return try XCTUnwrap(unit["value"] as? String)
  }

  func testPrototypeMirrorsShippedDebugIdentifiers() throws {
    let prototype = try source("docs/design/prototype.html")
    let debugSource = try source("ArkDeckApp/Features/Debug/DebugWorkspaceView.swift")

    let identifiers = [
      "debug.scope",
      "debug.target",
      "debug.tabs",
      "debug.availability.status",
      "debug.artifacts.preview",
      "debug.artifacts.submit",
      "debug.artifacts.openLogs",
      "debug.artifacts.productionBoundary",
      "debug.logs.start",
      "debug.logs.pauseViewport",
      "debug.logs.request",
      "debug.network.add",
      "debug.commands.run",
      "debug.commands.footer",
    ]

    for identifier in identifiers {
      XCTAssertTrue(debugSource.contains("\"\(identifier)\""), "App lost \(identifier)")
      XCTAssertTrue(
        prototype.contains("data-sync-id=\"\(identifier)\""),
        "Debug draft is no longer synchronized at \(identifier)")
    }
    for unpublishedPolicy in ["installFresh", "restorePrevious"] {
      XCTAssertFalse(
        debugSource.contains(".tag(\"\(unpublishedPolicy)\")"),
        "the App must not offer a lifecycle policy the Catalog refuses")
    }
  }

  func testPrototypeUsesCurrentDebugLocalizedCopy() throws {
    let prototype = try source("docs/design/prototype.html")
    let keys = [
      "debug.scope",
      "debug.artifacts.source.title",
      "debug.artifacts.destination.title",
      "debug.artifacts.review.title",
      "debug.artifacts.preview",
      "debug.artifacts.sheet.run",
      "debug.artifacts.openLogs",
      "debug.artifacts.productionBoundary",
      "debug.artifacts.sourceBoundary",
      "debug.logs.capture.title",
      "debug.logs.live.title",
      "debug.logs.shards.title",
      "debug.apps.package.title",
      "debug.apps.plan.title",
      "debug.network.rules.title",
      "debug.commands.argv.title",
      "debug.commands.select",
      "debug.jobs.title",
      "debug.availability.available",
      "debug.blocked.bufferOperation",
      "debug.blocked.packageLifecycle",
    ]

    for key in keys {
      let value = try localizedValue(key)
      XCTAssertTrue(
        prototype.contains(value),
        "design draft does not contain the current DebugLocalizable value for \(key)")
    }
  }

  func testDebugDraftKeepsTheShippedFlowAndNotTheRetiredOne() throws {
    let prototype = try source("docs/design/prototype.html")
    let draft = try debugDraft(prototype)

    // Five tabs with Artifacts first, and the roving-focus model the App ships.
    for shipped in [
      "\"artifacts\"", "\"logs\"", "\"apps\"", "\"net\"", "\"cmd\"",
      "debugTabKey", "ArrowRight", "Home", "End",
      "debugValidatePlan", "startDebugDeployment", "debugBrowseRemote", "debugServerManager",
    ] {
      XCTAssertTrue(draft.contains(shipped), "Debug draft lost the shipped surface: \(shipped)")
    }

    // The draft must not restore the v0.9 surfaces the product never published.
    for retired in [
      "debugSelectVisible",
      "debugArtifactRows",
      "搜索编译产物",
      "重启设备…",
      "管理来源与根目录…",
      "SMB 共享地址",
      "WSL 发行版名称",
    ] {
      XCTAssertFalse(draft.contains(retired), "Debug draft restored retired surface: \(retired)")
    }
  }
}
