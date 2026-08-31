import Foundation
import XCTest

/// Builds the external-consumer API baseline package as part of the ordinary
/// test gate, so `swift test` (the merge gate CI already runs) fails whenever
/// the published public API drifts below what an out-of-package consumer
/// needs. The baseline lives at Packages/ArkDeckKit/APIBaseline and is NOT a
/// target of this package on purpose: `package`-access symbols are invisible
/// to it, which is exactly the visibility a repository-external importer has
/// — the in-package compiler can never prove that surface (untyped `throws`
/// error contracts and unread result fields in particular).
final class APIBaselineGateContractTests: XCTestCase {
  private func packageRoot() -> URL {
    // …/Tests/ArkDeckContractTests/APIBaselineGateContractTests.swift -> package root
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  func testExternalConsumerBaselineBuildsAgainstThePublishedPublicAPI() throws {
    let baseline = packageRoot().appending(path: "APIBaseline")
    var isDirectory: ObjCBool = false
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: baseline.path, isDirectory: &isDirectory)
        && isDirectory.boolValue,
      "API baseline package is missing at \(baseline.path)")

    let output = Pipe()
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/xcrun")
    process.arguments = ["swift", "build", "--arch", "arm64", "--package-path", baseline.path]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let transcript = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(
      process.terminationStatus, 0,
      "external-consumer API baseline no longer compiles — the published "
        + "public API lost something a repository-external importer needs:\n"
        + String(decoding: transcript, as: UTF8.self))
  }
}
