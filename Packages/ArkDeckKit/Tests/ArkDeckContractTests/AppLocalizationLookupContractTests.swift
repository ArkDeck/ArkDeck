import Foundation
import XCTest

/// Every key the App looks up must exist in the table it looks it up from.
///
/// A missing key does not crash and does not fail a build. `String(localized:)`
/// and `Bundle.main.localizedString(forKey:value:)` both fall back to the key
/// itself, so the failure is a screen showing `flash.workspace.readiness`
/// where a sentence belongs — visible only to whoever opens that screen, and
/// only if they notice. There was no gate for it.
///
/// This guards the direction that damages the product. The opposite direction
/// — a catalog entry no code looks up — is waste rather than damage, and is
/// deliberately not asserted here: the App reaches keys through table-scoped
/// helpers, through direct `String(localized:)`, and through typed
/// `String.LocalizationValue` extensions that never spell the key as a
/// literal, so "nothing references this entry" is not decidable by scanning.
/// Claiming it would produce confident deletions of strings that are still
/// rendered.
///
/// Scanning is sound in this direction for the opposite reason: a lookup form
/// this test does not recognise is simply not checked. It can miss a
/// violation; it cannot invent one.
final class AppLocalizationLookupContractTests: XCTestCase {

  /// The closed set of table-scoped lookup helpers, each paired with the table
  /// its body names. Established by reading the bodies rather than by naming
  /// convention — `DebugL10n.text` and `UIDumpWorkspaceView.string` share no
  /// spelling with the tables they read.
  private static let helperTables: [(helper: String, table: String)] = [
    ("DebugL10n.text", "DebugLocalizable"),
    ("jobsText", "JobsLocalizable"),
    ("flashText", "FlashLocalizable"),
    ("traceString", "TraceLocalizable"),
    ("traceViewerText", "TraceViewerLocalizable"),
    ("historyLocalized", "HistoryLocalizable"),
    ("settingsText", "SettingsLocalizable"),
    ("deviceString", "Localizable"),
    ("viewerText", "UIDumpLocalizable"),
    ("deviceText", "DeviceLocalizable"),
    ("diagnosticsText", "DiagnosticsLocalizable"),
  ]

  private func repositoryRoot() -> URL {
    // …/Tests/ArkDeckContractTests/<file> -> Packages/ArkDeckKit -> repo root
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func tables() throws -> [String: Set<String>] {
    let resources = repositoryRoot().appending(path: "ArkDeckApp/Resources")
    let contents = try FileManager.default.contentsOfDirectory(
      at: resources, includingPropertiesForKeys: nil)
    var loaded: [String: Set<String>] = [:]
    for url in contents where url.pathExtension == "xcstrings" {
      let document = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
      let strings = (document as? [String: Any])?["strings"] as? [String: Any] ?? [:]
      loaded[url.deletingPathExtension().lastPathComponent] = Set(strings.keys)
    }
    return loaded
  }

  private func appSources() throws -> [(name: String, text: String)] {
    let root = repositoryRoot().appending(path: "ArkDeckApp")
    guard
      let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil)
    else { return [] }
    var sources: [(String, String)] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
      sources.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
    }
    return sources
  }

  private func literals(_ pattern: String, in text: String, group: Int = 1) throws -> [String] {
    let expression = try NSRegularExpression(pattern: pattern)
    return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
      .compactMap { match in
        Range(match.range(at: group), in: text).map { String(text[$0]) }
      }
  }

  func testEveryLocalizationLookupResolvesInTheTableItReadsFrom() throws {
    let tables = try tables()
    XCTAssertFalse(tables.isEmpty, "no string catalogs were found; this tests nothing")

    var checked = 0
    var unresolved: [String] = []
    func require(_ key: String, _ table: String, _ file: String, _ form: String) {
      checked += 1
      guard tables[table]?.contains(key) != true else { return }
      unresolved.append("\(file): \(form) \"\(key)\" is absent from \(table)")
    }

    for (name, text) in try appSources() {
      for (helper, table) in Self.helperTables {
        let escaped = NSRegularExpression.escapedPattern(for: helper)
        for key in try literals(escaped + #"\(\s*"([^"\\]+)"\s*(?:\)|,\s*values:)"#, in: text) {
          require(key, table, name, helper)
        }
      }
      // No `table:` argument means the default catalog.
      for key in try literals(#"String\(localized:\s*"([^"\\]+)"\s*\)"#, in: text) {
        require(key, "Localizable", name, "String(localized:)")
      }
      // An explicit table, which is also where a key read from the wrong
      // catalog would show up.
      let expression = try NSRegularExpression(
        pattern: #"String\(localized:[^)]*?"([^"\\]+)"[^)]*?table:\s*"([A-Za-z]+)""#)
      for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let key = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
          let table = Range(match.range(at: 2), in: text).map({ String(text[$0]) })
        else { continue }
        require(key, table, name, "String(localized:table:)")
      }
    }

    XCTAssertGreaterThan(
      checked, 300, "the scan found almost no lookups; it has stopped testing anything")
    XCTAssertEqual(
      unresolved.sorted(), [],
      """
      these lookups fall back to rendering the key itself, which no build or \
      test would otherwise notice: \(unresolved.sorted().joined(separator: "; "))
      """)
  }

  func testTraceViewerCopyAndNamedArgumentsArePresentInBothLanguages() throws {
    let url = repositoryRoot().appending(path: "ArkDeckApp/Resources/TraceViewerLocalizable.xcstrings")
    let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let strings = try XCTUnwrap(document["strings"] as? [String: [String: Any]])
    for (key, entry) in strings {
      let localizations = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]], key)
      let english = try XCTUnwrap((localizations["en"]?["stringUnit"] as? [String: Any])?["value"] as? String, key)
      let chinese = try XCTUnwrap((localizations["zh-Hans"]?["stringUnit"] as? [String: Any])?["value"] as? String, key)
      XCTAssertFalse(english.isEmpty, key)
      XCTAssertFalse(chinese.isEmpty, key)
      XCTAssertEqual(
        Set(try literals(#"\{([A-Za-z]+)\}"#, in: english)),
        Set(try literals(#"\{([A-Za-z]+)\}"#, in: chinese)),
        "\(key) must not lose its named runtime values in translation")
    }
  }

  func testSidebarProductNamesStayConsistentAcrossLocales() throws {
    let catalogURL = repositoryRoot()
      .appending(path: "ArkDeckApp/Resources/Localizable.xcstrings")
    let data = try Data(contentsOf: catalogURL)
    let catalog = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

    let expectedNames = [
      "app.navigation.overview": "Overview",
      "app.navigation.flash": "Flash",
      "app.navigation.debug": "Debug",
      "app.navigation.uiDump": "Viewer",
      "app.navigation.trace": "Trace",
      "app.navigation.device": "Device",
      "app.navigation.diagnostics": "Diagnostics",
      "app.navigation.history": "History",
    ]

    for (key, expectedName) in expectedNames {
      let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing \(key)")
      let localizations = try XCTUnwrap(
        entry["localizations"] as? [String: Any], "missing localizations for \(key)")
      for locale in ["en", "zh-Hans"] {
        let localization = try XCTUnwrap(
          localizations[locale] as? [String: Any], "missing \(locale) for \(key)")
        let stringUnit = try XCTUnwrap(
          localization["stringUnit"] as? [String: Any],
          "missing string unit for \(key) in \(locale)")
        XCTAssertEqual(
          stringUnit["value"] as? String,
          expectedName,
          "\(key) must use the product name in \(locale)")
      }
    }
  }
}
