import Foundation
import XCTest

@testable import ArkDeckCore

final class JobToolchainIntentContractTests: XCTestCase {
  func testJobToolchainIntentRoundTripsExplicitKnownUnknownAndUnverifiedEvidence() throws {
    let intent = try makeIntent()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(intent)
    let reopened = try JSONDecoder().decode(JobToolchainIntent.self, from: bytes)

    XCTAssertEqual(reopened, intent)
    XCTAssertEqual(reopened.schemaVersion, "1.0.0")
    XCTAssertEqual(reopened.platformTrust, .unverified(value: "ad-hoc", reason: "not assessed"))
    XCTAssertEqual(reopened.serverVersion, .unknown(reason: "server version probe unavailable"))
    XCTAssertEqual(reopened.daemonVersion, .unknown(reason: "daemon version probe unavailable"))
    XCTAssertEqual(reopened.serverGeneration, .known(7))
  }

  func testSettingsAndPATHChangesDoNotRewriteTheDurablyReopenedBinding() throws {
    var selectedPath = "/opt/openharmony/hdc"
    var selectedHash = String(repeating: "a", count: 64)
    let intent = try makeIntent(executablePath: selectedPath, sha256: selectedHash)
    let binding = try JobToolchainIntentBinding(
      jobID: intent.jobID, intent: intent, step: makeProbeStep(path: selectedPath))

    let directory = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-core-toolchain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let durableBytes = directory.appending(path: "job-toolchain-intent.json")
    try JSONEncoder().encode(binding).write(to: durableBytes, options: .atomic)

    selectedPath = "/tmp/PATH-replacement/hdc"
    selectedHash = String(repeating: "b", count: 64)
    let reopened = try JSONDecoder().decode(
      JobToolchainIntentBinding.self, from: Data(contentsOf: durableBytes))

    XCTAssertEqual(reopened, binding)
    XCTAssertEqual(reopened.intent.executablePath, "/opt/openharmony/hdc")
    XCTAssertEqual(reopened.intent.executableSHA256, String(repeating: "a", count: 64))
    XCTAssertNotEqual(reopened.intent.executablePath, selectedPath)
    XCTAssertNotEqual(reopened.intent.executableSHA256, selectedHash)
  }

  func testBindingRejectsAnotherJobAndNonHDCStepKinds() throws {
    let intent = try makeIntent()
    XCTAssertThrowsError(
      try JobToolchainIntentBinding(
        jobID: "another-job", intent: intent, step: makeProbeStep(path: intent.executablePath))
    ) { error in
      XCTAssertEqual(
        error as? JobToolchainIntentValidationError,
        .jobMismatch(expected: "job-hdc-1", actual: "another-job"))
    }

    let unrelated = try WorkflowStep(
      id: "finalize-1",
      kind: .finalizeSession,
      declaredEffect: .hostOnly,
      declaredCancellation: .atSafeBoundary,
      declaredBindingRequirement: .none,
      arguments: [
        "sessionId": .string("session-1"),
        "publicationPolicy": .string("atomicAfterValidation"),
      ]
    )
    XCTAssertThrowsError(
      try JobToolchainIntentBinding(jobID: intent.jobID, intent: intent, step: unrelated)
    ) { error in
      XCTAssertEqual(
        error as? JobToolchainIntentValidationError, .unsupportedStepKind(.finalizeSession))
    }
  }

  func testInvalidPathHashAndEvidenceFailBeforeAnIntentCanBeCreated() throws {
    XCTAssertThrowsError(try makeIntent(executablePath: "relative/hdc")) { error in
      XCTAssertEqual(
        error as? JobToolchainIntentValidationError, .executablePathMustBeAbsolute)
    }
    XCTAssertThrowsError(try makeIntent(sha256: "not-a-sha256")) { error in
      XCTAssertEqual(error as? JobToolchainIntentValidationError, .invalidSHA256)
    }

    XCTAssertThrowsError(
      try JobToolchainIntent(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        jobID: "job-hdc-1",
        executablePath: "/opt/openharmony/hdc",
        source: .userConfigured,
        executableSHA256: String(repeating: "a", count: 64),
        platformTrust: .unknown(reason: ""),
        clientVersion: .known("3.2.0d"),
        serverVersion: .unknown(reason: "not probed"),
        daemonVersion: .unknown(reason: "not probed"),
        endpoint: "127.0.0.1:8710",
        serverGeneration: .unknown(reason: "identity probe unavailable")
      )
    ) { error in
      XCTAssertEqual(
        error as? JobToolchainIntentValidationError,
        .invalidDiagnosticEvidence(field: "platformTrust"))
    }
  }

  private func makeIntent(
    executablePath: String = "/opt/openharmony/hdc",
    sha256: String = String(repeating: "a", count: 64)
  ) throws -> JobToolchainIntent {
    try JobToolchainIntent(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      jobID: "job-hdc-1",
      executablePath: executablePath,
      source: .userConfigured,
      executableSHA256: sha256,
      platformTrust: .unverified(value: "ad-hoc", reason: "not assessed"),
      clientVersion: .known("3.2.0d"),
      serverVersion: .unknown(reason: "server version probe unavailable"),
      daemonVersion: .unknown(reason: "daemon version probe unavailable"),
      endpoint: "127.0.0.1:8710",
      serverGeneration: .known(7)
    )
  }

  private func makeProbeStep(path: String) throws -> WorkflowStep {
    try WorkflowStep(
      id: "probe-hdc-1",
      kind: .probeHostTool,
      declaredEffect: .readOnly,
      declaredCancellation: .immediate,
      declaredBindingRequirement: .none,
      arguments: [
        "toolIdentity": .string("hdc-client"),
        "candidatePath": .string(path),
        "expectedSha256": .string(String(repeating: "a", count: 64)),
      ]
    )
  }
}
