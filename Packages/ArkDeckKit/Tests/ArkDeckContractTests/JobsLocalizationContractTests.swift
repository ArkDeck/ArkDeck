import Foundation
import XCTest

final class JobsLocalizationContractTests: XCTestCase {
  private var repositoryRoot: URL {
    var root = URL(filePath: #filePath)
    for _ in 0..<5 {
      root.deleteLastPathComponent()
    }
    return root
  }

  private var sourceURL: URL {
    repositoryRoot.appending(
      path:
        "ArkDeckApp/Features/Jobs/GlobalJobInspectorView.swift")
  }

  func testJobsCopyUsesDedicatedNamedTable() throws {
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("table: \"JobsLocalizable\""))
    XCTAssertTrue(source.contains("Bundle.main.localizedString"))

    let forbiddenPatterns = [
      #"(?<![A-Za-z0-9_])(?:Text|Label|Button|ContentUnavailableView)\(\s*\"job"#,
      #"String\(localized:\s*\"job"#,
      #"\.accessibilityLabel\(\s*\"job"#,
      #"LocalizedStringKey\("#,
    ]

    for pattern in forbiddenPatterns {
      let expression = try NSRegularExpression(pattern: pattern)
      let range = NSRange(source.startIndex..., in: source)
      XCTAssertNil(
        expression.firstMatch(in: source, range: range),
        "GlobalJobInspectorView.swift bypasses JobsLocalizable via \(pattern)")
    }
  }

  func testEveryStaticJobsKeyHasEnglishAndSimplifiedChineseValues() throws {
    let catalogURL = repositoryRoot.appending(
      path:
        "ArkDeckApp/Resources/JobsLocalizable.xcstrings")
    let data = try Data(contentsOf: catalogURL)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try XCTUnwrap(root["strings"] as? [String: Any])
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let localizationSource = source.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.contains("accessibilityIdentifier") }
      .joined(separator: "\n")
    let expression = try NSRegularExpression(
      pattern: #"\"((?:jobInspector|jobRecovery|job\.state)\.[^\"]+)\""#)
    let range = NSRange(localizationSource.startIndex..., in: localizationSource)

    let usedKeys: Set<String> = Set(
      expression.matches(in: localizationSource, range: range).compactMap { match in
        guard
          let keyRange = Range(match.range(at: 1), in: localizationSource),
          !localizationSource[keyRange].contains(#"\("#)
        else { return nil }
        return String(localizationSource[keyRange])
      })

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

  func testJobsLocalizationCatalogIsAnAppResource() throws {
    let project = try String(
      contentsOf: repositoryRoot.appending(path: "ArkDeck.xcodeproj/project.pbxproj"),
      encoding: .utf8)

    XCTAssertTrue(project.contains("JobsLocalizable.xcstrings in Resources"))
  }

  func testDAYU200OperationIsDisplayedWithoutHistoricalVersionSuffixes() throws {
    let inspector = try String(contentsOf: sourceURL, encoding: .utf8)
    let history = try String(
      contentsOf: repositoryRoot.appending(
        path:
          "ArkDeckApp/Features/History/RuntimeHistoryView.swift"),
      encoding: .utf8)

    XCTAssertTrue(inspector.contains("displayedOperationReference(job.operationReference)"))
    XCTAssertTrue(history.contains("displayedOperationReference(job.operationReference)"))
    XCTAssertTrue(history.contains(#"reference.hasPrefix("flash.dayu200@")"#))
    XCTAssertFalse(inspector.contains("flash.dayu200@1"))
    XCTAssertFalse(history.contains("flash.dayu200@1"))
  }

  func testGlobalRecoveryBannerUsesTheFacadeCurrentGuidanceProjection() throws {
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains(".filter(\\.requiresRecoveryGuidance)"))
    XCTAssertFalse(
      source.contains(
        ".filter { $0.outcomeUnknown || $0.waitingForHuman || requiresRecoveryGuidance($0) }"))
  }

  func testInspectorDistinguishesEstablishedCurrentEpochFromHistoricalUnknownState() throws {
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("if job.hasEstablishedCurrentEpoch"))
    XCTAssertTrue(source.contains("recordedStateFactRow(job.state)"))
    XCTAssertTrue(source.contains("job.supersededByRecoveryEpochID"))
    XCTAssertTrue(source.contains("job.resolvedByTargetAliasResolutionID"))
    XCTAssertTrue(
      source.contains(#"accessibilityIdentifier("jobInspector.establishedCurrentEpoch")"#))
    XCTAssertTrue(source.contains(#"systemImage: "checkmark.shield.fill""#))
    XCTAssertFalse(
      source.contains("job.outcomeUnknown = false"),
      "the inspector must project the relation without rewriting the historical outcome")
  }
}
