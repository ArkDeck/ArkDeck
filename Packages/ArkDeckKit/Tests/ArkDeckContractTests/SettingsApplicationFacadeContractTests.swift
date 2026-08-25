import ArkDeckWorkflows
import XCTest

final class SettingsApplicationFacadeContractTests: XCTestCase {
  func testSettingsDiagnosticsRequiresPreviewAndExplicitExport() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-settings-diagnostics-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let destination = root.appending(
      path: "ArkDeck-Diagnostics", directoryHint: .isDirectory)
    let provider = SettingsApplicationFacade.make()
    let preview = try await provider.previewDiagnosticBundle(at: destination)

    XCTAssertTrue(preview.deviceRawExcluded)
    XCTAssertEqual(
      Set(preview.includedEntries),
      Set(["bundle.json", "hdc/tool-placeholder.json", "metadata.json"]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

    let exported = try await provider.exportDiagnosticBundle(
      to: destination, approvedPreview: preview)
    XCTAssertEqual(exported.standardizedFileURL, destination.standardizedFileURL)
    let manifest = try Data(contentsOf: destination.appending(path: "bundle.json"))
    XCTAssertTrue(manifest.contains(Data("\"automaticUploadEnabled\":false".utf8)))
    XCTAssertTrue(manifest.contains(Data("\"deviceRawExcluded\":true".utf8)))
  }

  func testSettingsSceneHasNamedLocalizedPartitionsIncludingRemoteBuildSources() throws {
    let repository = repositoryRoot()
    let app = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/App/ArkDeckApp.swift"),
      encoding: .utf8)
    let view = try String(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Features/Settings/SettingsRootView.swift"),
      encoding: .utf8)
    let catalogData = try Data(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Resources/SettingsLocalizable.xcstrings"))
    let catalog = try XCTUnwrap(
      JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
    let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

    XCTAssertTrue(app.contains("SettingsRootView("))
    XCTAssertTrue(app.contains("SettingsApplicationFacade.make()"))
    XCTAssertTrue(view.contains("tableName: \"SettingsLocalizable\""))
    for key in [
      "settings.tab.general",
      "settings.tab.toolchains",
      "settings.tab.remoteSources",
      "settings.tab.storage",
      "settings.tab.updates",
      "settings.tab.diagnostics",
    ] {
      let entry = try XCTUnwrap(strings[key] as? [String: Any])
      let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
      XCTAssertNotNil(localizations["en"], key)
      XCTAssertNotNil(localizations["zh-Hans"], key)
      XCTAssertTrue(view.contains("\"\(key)\""), key)
    }
  }

  func testSettingsSourceKeepsDiagnosticRawExcludedAndUITestsOutOfModule() throws {
    let repository = repositoryRoot()
    let facade = try String(
      contentsOf: repository.appending(
        path:
          "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Settings/SettingsApplicationFacade.swift"),
      encoding: .utf8)
    let view = try String(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Features/Settings/SettingsRootView.swift"),
      encoding: .utf8)

    XCTAssertTrue(facade.contains("trigger: .userInitiated"))
    XCTAssertTrue(facade.contains("recentSessions: []"))
    XCTAssertTrue(facade.contains("path: .redacted"))
    XCTAssertTrue(facade.contains("serverEndpoint: .redacted"))
    XCTAssertTrue(view.contains("!preview.deviceRawExcluded"))
    XCTAssertFalse(view.contains("XCUIApplication"))
    XCTAssertFalse(view.contains("XCTest"))
  }

  private func repositoryRoot() -> URL {
    var root = URL(filePath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return root
  }
}
