import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class CLIRuntimeUpdateContractTests: XCTestCase {
  func testEveryLeafUsesTheSameDurableOwnerAndOnlyHandoffCarriesConsent() async throws {
    let owner = RecordingRuntimeUpdateOwner()
    let identity = UpdateProductIdentity(
      appVersion: "1.2.3", osVersion: "26.0.0", architecture: "arm64")
    let revealer = NoOpRuntimeUpdateRevealer()
    let fixedNow = Date(timeIntervalSince1970: 1_788_225_600)

    for verb in ["check", "download", "status", "cancel"] {
      _ = try await RuntimeCLI.runtimeUpdateResult(
        subcommand: verb,
        options: try CLIOptions([]),
        owner: owner,
        identity: identity,
        revealer: revealer,
        now: fixedNow)
    }
    _ = try await RuntimeCLI.runtimeUpdateResult(
      subcommand: "handoff",
      options: try CLIOptions(["--consent", "reveal-in-finder"]),
      owner: owner,
      identity: identity,
      revealer: revealer,
      now: fixedNow)
    _ = try await RuntimeCLI.runtimeUpdateResult(
      subcommand: "cleanup",
      options: try CLIOptions([]),
      owner: owner,
      identity: identity,
      revealer: revealer,
      now: fixedNow)

    let calls = await owner.recordedCalls()
    let recordedIdentity = await owner.recordedIdentity()
    let recordedDate = await owner.recordedCheckDate()
    let explicitConsent = await owner.handoffHadExplicitConsent()
    XCTAssertEqual(
      calls,
      [
        "recover", "check", "status",
        "recover", "download", "status",
        "recover", "status",
        "recover", "cancel",
        "recover", "handoff", "status",
        "cleanup",
      ])
    XCTAssertEqual(recordedIdentity, identity)
    XCTAssertEqual(recordedDate, fixedNow)
    XCTAssertTrue(explicitConsent)
  }

  func testHandoffRefusesMissingConsentBeforeCallingTheOwner() async throws {
    let owner = RecordingRuntimeUpdateOwner()
    do {
      _ = try await RuntimeCLI.runtimeUpdateResult(
        subcommand: "handoff",
        options: try CLIOptions([]),
        owner: owner,
        identity: UpdateProductIdentity(
          appVersion: "1.0.0", osVersion: "26.0.0", architecture: "arm64"),
        revealer: NoOpRuntimeUpdateRevealer())
      XCTFail("handoff without the exact consent token must fail")
    } catch {
      XCTAssertEqual(error as? AutoUpdateServiceError, .explicitConsentRequired)
    }
    let calls = await owner.recordedCalls()
    XCTAssertEqual(calls, [])
  }

  func testStatusProjectionContainsNoPrivateArtifactPath() throws {
    let artifact = DownloadedUpdateArtifact(
      url: URL(filePath: "/Users/private/Library/Caches/ArkDeck-Updates/update.dmg"),
      byteLength: 64,
      sha256: String(repeating: "a", count: 64),
      identity: UpdateFileIdentity(
        device: 1, inode: 2, byteLength: 64, mode: 0o100400,
        modifiedSeconds: 3, modifiedNanoseconds: 4,
        changedSeconds: 5, changedNanoseconds: 6))
    let value = RuntimeCLI.runtimeUpdateStatusJSON(
      RuntimeUpdateStatusProjection(
        snapshot: RuntimeUpdateSnapshot(
          generation: 8,
          state: .verifying(artifact),
          activeOperationID: UUID())))
    let encoded = try JSONEncoder().encode(value)
    let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

    XCTAssertTrue(text.contains(String(repeating: "a", count: 64)))
    XCTAssertTrue(text.contains("\"artifactByteLength\":64"))
    XCTAssertFalse(text.contains("/Users/private"))
    XCTAssertFalse(text.contains("update.dmg"))
  }

  func testUpdateFailuresMapToStableCodesWithoutEmbeddingPrivateDetails() {
    let cases: [(any Error, CLIErrorCode)] = [
      (RuntimeUpdateStateStoreError.operationInProgress, .resourceConflict),
      (RuntimeUpdateStateStoreError.recordUnreadable, .recordUnreadable),
      (RuntimeUpdateStateStoreError.writeFailed, .ioFailure),
      (AutoUpdateServiceError.explicitConsentRequired, .admissionDenied),
      (UpdateFeedError.invalidSignature, .artifactIntegrityFailed),
      (UpdateArtifactSecurityError.differentTeam, .artifactIntegrityFailed),
      (UpdateDownloadError.cancelled, .clientInterrupted),
      (UpdateDownloadError.fileOperationFailed(errno: 13), .ioFailure),
      (UpdateNetworkError.invalidResponse, .operationFailed),
    ]
    for (error, expected) in cases {
      let mapped = RuntimeCLI.runtimeUpdateError(error, command: "runtime.update.download")
      XCTAssertEqual(mapped.code, expected)
      XCTAssertFalse(mapped.message.contains("/Users/"))
      XCTAssertEqual(mapped.command, "runtime.update.download")
    }
  }
}

private actor RecordingRuntimeUpdateOwner: RuntimeUpdateCommandOperating {
  private var calls: [String] = []
  private var identity: UpdateProductIdentity?
  private var checkDate: Date?
  private var explicitConsent = false

  func recoverOrphanPartials() async throws { calls.append("recover") }

  func checkManually(identity: UpdateProductIdentity, now: Date) async throws -> AutoUpdateState {
    calls.append("check")
    self.identity = identity
    checkDate = now
    return .idle
  }

  func downloadAvailableUpdate() async throws -> AutoUpdateState {
    calls.append("download")
    return .idle
  }

  func handoff(
    explicitConsent: Bool,
    revealer: any UpdateArtifactRevealing
  ) async throws -> AutoUpdateState {
    calls.append("handoff")
    self.explicitConsent = explicitConsent
    return .idle
  }

  func status() async throws -> RuntimeUpdateStatusProjection {
    calls.append("status")
    return RuntimeUpdateStatusProjection(
      snapshot: RuntimeUpdateSnapshot(generation: UInt64(calls.count), state: .idle))
  }

  func cancel() async throws -> RuntimeUpdateStatusProjection {
    calls.append("cancel")
    return RuntimeUpdateStatusProjection(
      snapshot: RuntimeUpdateSnapshot(generation: UInt64(calls.count), state: .cancelled))
  }

  func cleanup() async throws -> RuntimeUpdateCleanupReceipt {
    calls.append("cleanup")
    return RuntimeUpdateCleanupReceipt(
      status: RuntimeUpdateStatusProjection(
        snapshot: RuntimeUpdateSnapshot(generation: UInt64(calls.count), state: .idle)),
      removedVerifiedArtifacts: 0)
  }

  func recordedCalls() -> [String] { calls }
  func recordedIdentity() -> UpdateProductIdentity? { identity }
  func recordedCheckDate() -> Date? { checkDate }
  func handoffHadExplicitConsent() -> Bool { explicitConsent }
}

private struct NoOpRuntimeUpdateRevealer: UpdateArtifactRevealing, Sendable {
  @MainActor func revealInFinder(_ url: URL) throws {}
}
