import Foundation
import XCTest

@testable import ArkDeckWorkflows
@testable import ArkDeckRuntime

final class HistoricalEvolutionCampaignArchiveContractTests: XCTestCase {
  func testHistoricalCampaignStatusIsReadOnlyAndProjectsLegacyFields() throws {
    let root = try temporaryDirectory("historical-campaign")
    defer { try? FileManager.default.removeItem(at: root) }
    let digest = String(repeating: "a", count: 64)
    let campaignID = "ECAMP-\(digest.prefix(24).uppercased())"
    let documentURL = root.appending(path: "\(campaignID).json")
    try Data(
      """
      {
        "documentType": "rockchip-evolution-campaign-ledger",
        "schemaVersion": "1.0.0",
        "campaignID": "\(campaignID)",
        "assertion": {
          "confirmationDigestSHA256": "\(digest)",
          "maxAttempts": 16,
          "baseCommitOID": "\(String(repeating: "b", count: 40))"
        },
        "events": [
          {
            "sequence": 1,
            "kind": "candidatePrepared",
            "at": "2026-08-01T00:00:00Z",
            "candidate": {
              "candidateID": "ECAND-AAAAAAAAAAAAAAAA",
              "producerID": "historical-producer"
            },
            "review": {
              "reviewID": "EREVIEW-BBBBBBBBBBBBBBBB"
            },
            "destructiveIntentEventIDs": []
          },
          {
            "sequence": 2,
            "kind": "attemptReserved",
            "at": "2026-08-01T00:01:00Z",
            "ordinal": 1,
            "jobID": "job-legacy",
            "sessionID": "session-legacy",
            "destructiveIntentEventIDs": []
          },
          {
            "sequence": 3,
            "kind": "attemptTerminal",
            "at": "2026-08-01T00:02:00Z",
            "ordinal": 1,
            "jobID": "job-legacy",
            "sessionID": "session-legacy",
            "disposition": "safeToReflash",
            "destructiveIntentEventIDs": []
          },
          {
            "sequence": 4,
            "kind": "campaignStopped",
            "at": "2026-08-01T00:03:00Z",
            "reasonCode": "retired",
            "detail": "historical record only",
            "destructiveIntentEventIDs": []
          }
        ]
      }
      """.utf8
    ).write(to: documentURL)
    XCTAssertEqual(chmod(documentURL.path, 0o600), 0)
    let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()

    let document = try HistoricalEvolutionCampaignArchive(root: root).load(campaignID)

    XCTAssertEqual(document.campaignID, campaignID)
    XCTAssertEqual(document.assertion.maxAttempts, 16)
    XCTAssertEqual(document.reservedAttemptCount, 1)
    XCTAssertTrue(document.isTerminal)
    XCTAssertEqual(document.events.first?.candidate?.candidateID, "ECAND-AAAAAAAAAAAAAAAA")
    XCTAssertEqual(document.events.first?.review?.reviewID, "EREVIEW-BBBBBBBBBBBBBBBB")
    XCTAssertEqual(document.events.last?.reasonCode, "retired")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before,
      "decode/export compatibility must not create a lock, draft or replacement document")
  }

  func testHistoricalArchiveRejectsIdentityDriftAndNeverCreatesMissingState() throws {
    let root = try temporaryDirectory("historical-campaign-refusal")
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try HistoricalEvolutionCampaignArchive(root: root)

    XCTAssertThrowsError(try archive.load("ECAMP-AAAAAAAAAAAAAAAAAAAAAAAA"))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    XCTAssertThrowsError(try archive.load("not-a-campaign-id"))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
  }

  func testRetiredCampaignWritersAndVendorOraclesCannotReturn() throws {
    let packageRoot = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for relativePath in [
      "Sources/ArkDeckCLI/EngineLaneEvolutionFlashDispatcher.swift",
      "Sources/ArkDeckWorkflows/AgentComposition/EvolutionCampaignHost.swift",
      "Sources/ArkDeckWorkflows/EvolutionCampaignAttemptAdmission.swift",
      "Sources/ArkDeckWorkflows/EvolutionCampaignAuthority.swift",
      "Sources/ArkDeckWorkflows/EvolutionCampaignLedger.swift",
      "Sources/ArkDeckWorkflows/EvolutionCandidatePipeline.swift",
      "Sources/ArkDeckWorkflows/RockchipEvolutionTargetReadback.swift",
      "Sources/ArkDeckWorkflows/RockchipFlashPreflight.swift",
    ] {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: packageRoot.appending(path: relativePath).path),
        relativePath)
    }

    let cli = try String(
      contentsOf: packageRoot.appending(path: "Sources/ArkDeckCLI/ArkDeckCLIMain.swift"),
      encoding: .utf8)
    for writer in [
      "runCampaignPreview(", "runCampaignContinue(", "engineLaneCampaignHost(",
      "engineLaneDispatcher(", "requireGreenPreflight(",
    ] {
      XCTAssertFalse(cli.contains(writer), writer)
    }

    let engine = try String(
      contentsOf: packageRoot.appending(
        path: "Sources/ArkDeckWorkflows/RuntimeJobEngine.swift"),
      encoding: .utf8)
    for retired in [
      "validateCampaignReservation(", "verifyCampaignReservationBeforeMutation(",
      "campaignExecutionTuning(",
    ] {
      XCTAssertFalse(engine.contains(retired), retired)
    }
    for retiredField in ["campaignReservation", "standingAuthorization", "chatConfirmation"] {
      let request = Data("""
        {"documentType":"runtime-operation-request","schemaVersion":"1.0.0",
         "requestId":"archive-refusal","idempotencyKey":"archive-refusal",
         "target":{"targetId":"target-1"},"operation":{"id":"observe.device","version":1},
         "\(retiredField)":null}
        """.utf8)
      XCTAssertThrowsError(try RuntimeOperationCodec.decodeRequest(request), retiredField)
    }

    let workflows = packageRoot.appending(
      path: "Sources/ArkDeckWorkflows", directoryHint: .isDirectory)
    let source = try XCTUnwrap(
      FileManager.default.enumerator(
        at: workflows, includingPropertiesForKeys: [.isRegularFileKey]))
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "swift" }
      .map { try String(contentsOf: $0, encoding: .utf8) }
      .joined(separator: "\n")
    XCTAssertFalse(source.contains("campaignExecutionTuning"))
    XCTAssertFalse(source.contains("RockchipGPTHeader"))

  }

  private func temporaryDirectory(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-\(label)-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    XCTAssertEqual(chmod(root.path, 0o700), 0)
    return root
  }
}
