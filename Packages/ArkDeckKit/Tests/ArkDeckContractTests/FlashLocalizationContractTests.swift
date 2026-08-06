import Foundation
import XCTest

final class FlashLocalizationContractTests: XCTestCase {
  private var repositoryRoot: URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
      root.deleteLastPathComponent()
    }
    return root
  }

  private var flashFeatureRoot: URL {
    repositoryRoot.appendingPathComponent("ArkDeckApp/Features/Flash")
  }

  private var flashSources: [(URL, String)] {
    get throws {
      let urls = try FileManager.default.contentsOfDirectory(
        at: flashFeatureRoot,
        includingPropertiesForKeys: nil
      )
      .filter { $0.pathExtension == "swift" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      return try urls.map { ($0, try String(contentsOf: $0, encoding: .utf8)) }
    }
  }

  func testFlashCopyUsesDedicatedNamedTable() throws {
    let localizationSource = try String(
      contentsOf: flashFeatureRoot.appendingPathComponent("FlashLocalization.swift"),
      encoding: .utf8)

    XCTAssertTrue(localizationSource.contains("table: \"FlashLocalizable\""))
    XCTAssertTrue(localizationSource.contains("Bundle.main.localizedString"))

    let forbiddenPatterns = [
      #"(?<![A-Za-z0-9_])(?:Text|Label|Button|Picker|GroupBox|LabeledContent|TextField)\(\s*\"flash\."#,
      #"String\(localized:\s*\"flash\."#,
      #"\.accessibilityLabel\(\s*\"flash\."#,
      #"LocalizedStringKey\("#,
    ]

    for (url, source) in try flashSources {
      for pattern in forbiddenPatterns {
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        XCTAssertNil(
          expression.firstMatch(in: source, range: range),
          "\(url.lastPathComponent) bypasses FlashLocalizable via \(pattern)")
      }
    }
  }

  func testEveryFlashTextKeyHasEnglishAndSimplifiedChineseValues() throws {
    let catalogURL = repositoryRoot.appendingPathComponent(
      "ArkDeckApp/Resources/FlashLocalizable.xcstrings")
    let data = try Data(contentsOf: catalogURL)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try XCTUnwrap(root["strings"] as? [String: Any])
    let expression = try NSRegularExpression(pattern: #"flashText\(\"([^\"]+)\"\)"#)

    var usedKeys = Set<String>()
    for (_, source) in try flashSources {
      let range = NSRange(source.startIndex..., in: source)
      for match in expression.matches(in: source, range: range) {
        guard
          let keyRange = Range(match.range(at: 1), in: source)
        else { continue }
        usedKeys.insert(String(source[keyRange]))
      }
    }

    XCTAssertFalse(usedKeys.isEmpty)
    for key in usedKeys.sorted() {
      let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing catalog key: \(key)")
      let localizations = try XCTUnwrap(
        entry["localizations"] as? [String: Any],
        "Missing localizations for: \(key)")
      XCTAssertNotNil(localizations["en"], "Missing English value for: \(key)")
      XCTAssertNotNil(localizations["zh-Hans"], "Missing Chinese value for: \(key)")
    }
  }

  func testFlashLocalizationFilesAreAppTargetMembers() throws {
    let project = try String(
      contentsOf: repositoryRoot.appendingPathComponent("ArkDeck.xcodeproj/project.pbxproj"),
      encoding: .utf8)

    XCTAssertTrue(project.contains("FlashLocalization.swift in Sources"))
    XCTAssertTrue(project.contains("FlashLocalizable.xcstrings in Resources"))
  }
}
