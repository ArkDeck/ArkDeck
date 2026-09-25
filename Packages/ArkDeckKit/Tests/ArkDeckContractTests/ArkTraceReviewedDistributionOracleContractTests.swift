// Host acceptance oracle for the Rust ArkTrace loader over a reviewed
// distribution (CHG-2026-074, TASK-XPA-015).

import Darwin
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// Swift's production loading of a reviewed, signed and notarized ArkTrace
/// distribution — `ProductionArkTraceDistributionTrustChecker`, the doctor
/// probe run against the real CLI, a private snapshot generation — at one
/// fixed root, recorded for the Rust loader's host acceptance
/// (`rust/crates/arkdeck-hoststore/tests/arktrace_reviewed.rs`). A reviewed
/// distribution is a host's, not the repository's, so nothing is checked in:
/// this runs only when `ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR` names one and
/// `ARKDECK_REVIEWED_ARKTRACE_RECORD` names the new file to record into.
final class ArkTraceReviewedDistributionOracleContractTests: XCTestCase {
  static let root = "/private/tmp/arkdeck-arktrace-reviewed"

  func testSwiftLoadsTheReviewedDistribution() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let descriptor = environment["ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR"],
      let record = environment["ARKDECK_REVIEWED_ARKTRACE_RECORD"]
    else {
      throw XCTSkip(
        "set ARKDECK_REVIEWED_ARKTRACE_DESCRIPTOR and ARKDECK_REVIEWED_ARKTRACE_RECORD")
    }
    let lock = try ArkTraceProfileLoaderOracleContractTests.lock()
    defer { close(lock) }
    let manager = FileManager.default
    try? manager.removeItem(atPath: Self.root)
    defer { try? manager.removeItem(atPath: Self.root) }
    try ArkTraceProfileLoaderOracleContractTests.directory(Self.root, mode: 0o700)
    let outcome: JSONValue
    do {
      let profiles = try await ArkTraceSummaryAnalyzerProfileLoader(
        doctor: ProductionArkTraceDoctorProbe(homeURL: URL(filePath: "\(Self.root)/home")),
        snapshotRootURL: URL(filePath: "\(Self.root)/snapshots", directoryHint: .isDirectory))
        .loadProfiles(descriptorURL: URL(filePath: descriptor))
      outcome = .object([
        "profiles": .array(profiles.map(ArkTraceProfileLoaderOracleContractTests.projection))
      ])
    } catch let error as ArkTraceSummaryProfileError {
      outcome = .object(["error": .string(error.reason)])
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    guard !manager.fileExists(atPath: record) else { throw CocoaError(.fileWriteFileExists) }
    try (encoder.encode(outcome) + Data("\n".utf8)).write(to: URL(filePath: record))
  }
}
