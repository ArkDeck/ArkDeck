import Foundation
import XCTest

/// The lane runner's usage text and the lanes it implements must be one set,
/// and a lane that claims to be a wider tier must actually be one.
///
/// `medium` ran eighty-four tests where `fast` ran ninety-four: moving up a
/// tier narrowed coverage, and nothing said so. A lane name is the only thing
/// most readers see, so it has to be true — an over-claiming lane is the same
/// wrong-signal failure as an over-claiming availability reason, one layer out.
///
/// Source-level because the alternative is invoking every lane and asserting
/// on counts, which tests today's suite size rather than the agreement.
final class TestLaneContractTests: XCTestCase {

  private func runner() throws -> String {
    // …/Tests/ArkDeckContractTests/<file> -> Packages/ArkDeckKit
    let packageRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: packageRoot.appending(path: "Scripts/run-test-lane.sh"), encoding: .utf8)
  }

  /// Lane names from the `case "$lane" in` arms, and the filter each one sets.
  private func lanes(in script: String) throws -> (names: Set<String>, filters: [String: String]) {
    var names: Set<String> = []
    var filters: [String: String] = [:]
    var current: String?
    for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      // A lane arm is `name)` at the start of a line, never `*)`.
      if trimmed.hasSuffix(")"), !trimmed.hasPrefix("*"), !trimmed.contains(" "),
        !trimmed.contains("$"), trimmed.count > 1
      {
        let name = String(trimmed.dropLast())
        if name.allSatisfy({ $0.isLetter || $0 == "-" }), !name.isEmpty {
          names.insert(name)
          current = name
        }
        continue
      }
      if let current, trimmed.hasPrefix("lane_filter=") {
        filters[current] = trimmed
          .dropFirst("lane_filter=".count)
          .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
      }
    }
    return (names, filters)
  }

  func testEveryImplementedLaneIsNamedInUsageAndViceVersa() throws {
    let script = try runner()
    let (implemented, _) = try lanes(in: script)
    XCTAssertFalse(implemented.isEmpty, "no lanes were parsed; this tests nothing")

    guard let usageRange = script.range(of: "run-test-lane.sh {"),
      let closing = script.range(
        of: "}", range: usageRange.upperBound..<script.endIndex)
    else {
      return XCTFail("the usage line has been reshaped; this guard no longer applies")
    }
    let documented = Set(
      script[usageRange.upperBound..<closing.lowerBound]
        .split(separator: "|")
        .map { $0.split(separator: " ").first.map(String.init) ?? "" }
        .filter { !$0.isEmpty })

    XCTAssertEqual(
      implemented, documented,
      """
      the lane runner implements \(implemented.subtracting(documented).sorted()) without \
      naming them in usage, and names \(documented.subtracting(implemented).sorted()) without \
      implementing them
      """)
  }

  /// The tier that has to hold: `medium` is `fast` plus more, not a different
  /// slice of the same size. Checked on the filter rather than on a test count
  /// so it says what it means and does not move with the suite.
  func testMediumIsAWiderTierThanFastRatherThanADifferentOne() throws {
    let (_, filters) = try lanes(in: try runner())
    let fast = try XCTUnwrap(filters["fast"], "fast declares no filter")
    let medium = try XCTUnwrap(filters["medium"], "medium declares no filter")
    for term in fast.split(separator: "|") {
      XCTAssertTrue(
        medium.split(separator: "|").contains(term),
        "medium omits \(term), which fast runs — a wider tier cannot cover less")
    }
    XCTAssertGreaterThan(
      medium.split(separator: "|").count, fast.split(separator: "|").count,
      "medium must add something to fast, or it is fast under another name")
  }

  /// The merge gate stays whole. Narrowing what `plan.py` runs would turn a
  /// developer convenience into a hole in the gate, so the classifier must go
  /// on asking for the full suite.
  func testTheClassifierStillRunsTheWholeSuiteAsTheGate() throws {
    let repositoryRoot = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let plan = try String(
      contentsOf: repositoryRoot.appending(path: "scripts/ci/plan.py"), encoding: .utf8)
    let invocations = plan.components(separatedBy: "run-test-lane.sh").dropFirst()
    XCTAssertEqual(invocations.count, 1, "the gate must invoke the lane runner exactly once")
    for invocation in invocations {
      XCTAssertTrue(
        invocation.prefix(40).contains("\"full\""),
        "the gate must ask for the full suite, not a lane")
    }
  }
}
