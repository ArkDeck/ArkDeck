import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckWorkflows

final class FlashArtifactContractTests: XCTestCase {
  private func flashRecord() throws -> RuntimeJobRecord {
    let request = try RuntimeOperationRequest(
      requestID: "req-flash-artifacts",
      idempotencyKey: "idem-flash-artifacts",
      target: DurableTargetReference(
        targetID: "TGT-DAYU200", expectedBindingRevision: 7),
      operation: RuntimeOperationReference(id: "flash.dayu200"),
      inputs: [
        "imageBundleLease": .string(
          "lease-v1:input-flash:ART-0123456789abcdef0123456789abcdef"),
        "deviceProfile": .string("dayu200"),
        "partitionPlan": .array([.string("boot"), .string("system")]),
        "postFlashVerification": .string("full"),
      ],
      authorization: RuntimeCapabilityReference(
        capabilityID: "CAP-RT-GJ4-ARTIFACTS"))
    var record = RuntimeJobRecord(
      jobID: "job-flash-artifacts",
      request: request,
      operationReference: "flash.dayu200",
      catalogDigest: String(repeating: "c", count: 64),
      providerID: "rockchip",
      createdAtUTC: "2026-07-31T00:00:00Z",
      actualEffect: "destructive",
      admissionEvidence: RuntimeAdmissionEvidence(
        kind: .standingAuthorization,
        reference: "merged-pr:gj4-exact-plan",
        admittedAtUTC: "2026-07-31T00:00:00Z",
        validUntilUTC: "2026-08-01T00:00:00Z",
        consumptionFingerprintSHA256: String(repeating: "f", count: 64)),
      materializedPlanDigest: String(repeating: "d", count: 64),
      materializedStableTargetIdentitySHA256: String(repeating: "a", count: 64),
      materializedBindingRevision: 7)
    record.evidenceObservation = RuntimeEvidenceObservation(
      targetID: "TGT-DAYU200",
      bindingRevision: 7,
      stableIdentitySHA256: String(repeating: "a", count: 64),
      model: "pre-flash-model",
      firmware: "pre-flash-firmware",
      transport: "usb",
      providerID: "rockchip",
      toolVersion: "1.0.0",
      toolSHA256: String(repeating: "b", count: 64),
      confirmedAtUTC: "2026-07-31T00:00:00Z",
      confirmationMethod: "typed-preflight",
      preflightSteps: [])
    return record
  }

  func testFlashStepsOwnEveryDeclaredRuntimeProduct() throws {
    XCTAssertEqual(
      RuntimeArtifactService.artifactMapping["flash.dayu200"]?["rebind-and-verify-build"],
      ["post-flash-facts.json"])
    XCTAssertEqual(
      RuntimeArtifactService.artifactMapping["flash.dayu200"]?[
        "capture-post-flash-diagnostics"],
      ["post-flash-hilog.txt"])
    XCTAssertEqual(
      RuntimeArtifactService.finalizeArtifacts["flash.dayu200"],
      ["flash-report.json"])

    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "flash.dayu200"))
    let mapped =
      Set(
        RuntimeArtifactService.artifactMapping["flash.dayu200", default: [:]]
          .values.flatMap { $0 }
      )
      .union(RuntimeArtifactService.finalizeArtifacts["flash.dayu200", default: []])
    XCTAssertEqual(mapped, Set(descriptor.artifacts.map(\.name)))
  }

  func testBasicFlashIntentionallyOmitsOnlyOptionalHilog() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "flash.dayu200"))
    let diagnostics = try XCTUnwrap(
      descriptor.steps.first { $0.stepID == "capture-post-flash-diagnostics" })

    XCTAssertFalse(
      RuntimeJobEngine.stepIsRequested(
        diagnostics, descriptor: descriptor,
        inputs: ["postFlashVerification": .string("basic")]))
    XCTAssertTrue(
      RuntimeJobEngine.stepIsRequested(
        diagnostics, descriptor: descriptor,
        inputs: ["postFlashVerification": .string("full")]))
    XCTAssertTrue(
      descriptor.artifacts.first { $0.name == "flash-report.json" }?.isRequired == true)
    XCTAssertTrue(
      descriptor.artifacts.first { $0.name == "post-flash-facts.json" }?.isRequired == true)
    XCTAssertTrue(
      descriptor.artifacts.first { $0.name == "post-flash-hilog.txt" }?.isRequired == false)
  }

  func testPostFlashFactsUseVerifiedReadbackAndHilogUsesReceiptBytes() throws {
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "flash.dayu200"))
    let record = try flashRecord()
    let receipt = ProviderProcessReceipt(
      exitStatus: 0,
      stdout: Data("bounded post-flash hilog\n".utf8),
      stderr: Data(),
      stdoutTruncated: false,
      durationSeconds: 1)

    let facts = RuntimeArtifactService.artifactContents(
      name: "post-flash-facts.json",
      summary: ["model": "DAYU200", "firmware": "OpenHarmony-3.2-post-flash"],
      receipt: receipt,
      descriptor: descriptor,
      record: record)
    let document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: facts) as? [String: Any])
    XCTAssertEqual(document["model"] as? String, "DAYU200")
    XCTAssertEqual(document["firmware"] as? String, "OpenHarmony-3.2-post-flash")
    XCTAssertEqual(document["targetId"] as? String, "TGT-DAYU200")
    XCTAssertEqual(document["expectedBindingRevision"] as? Int, 7)
    XCTAssertEqual(document["catalogDigest"] as? String, String(repeating: "c", count: 64))
    XCTAssertEqual(
      document["materializedPlanDigest"] as? String,
      String(repeating: "d", count: 64))
    let authority = try XCTUnwrap(document["authority"] as? [String: Any])
    XCTAssertEqual(authority["kind"] as? String, "standingAuthorization")
    XCTAssertEqual(authority["reference"] as? String, "merged-pr:gj4-exact-plan")

    XCTAssertEqual(
      RuntimeArtifactService.artifactContents(
        name: "post-flash-hilog.txt",
        summary: ["byteCount": "\(receipt.stdout.count)"],
        receipt: receipt,
        descriptor: descriptor,
        record: record),
      receipt.stdout)
  }

  func testFlashArtifactBytesHashesAndBindingSurviveStoreReopen() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-flash-artifacts-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let descriptor = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "flash.dayu200"))
    let record = try flashRecord()
    let receipt = ProviderProcessReceipt(
      exitStatus: 0,
      stdout: Data("bounded post-flash hilog\n".utf8),
      stderr: Data(),
      stdoutTruncated: false,
      durationSeconds: 1)
    let facts = RuntimeArtifactService.artifactContents(
      name: "post-flash-facts.json",
      summary: ["model": "DAYU200", "firmware": "OpenHarmony-3.2-post-flash"],
      receipt: receipt,
      descriptor: descriptor,
      record: record)
    let binding = ArtifactBindingSnapshot(
      targetID: record.request.target.targetID,
      bindingRevision: record.request.target.expectedBindingRevision,
      stableIdentitySHA256: record.materializedStableTargetIdentitySHA256)
    let metadata: RuntimeArtifactMetadata
    do {
      let store = try RuntimeArtifactStore(
        rootURL: root, nowUTC: { "2026-07-31T00:00:00Z" })
      metadata = try await store.publish(
        RuntimeArtifactPublicationRequest(
          jobID: record.jobID,
          sessionID: record.sessionID,
          stepID: "rebind-and-verify-build",
          name: "post-flash-facts.json",
          mediaType: "application/json",
          privacy: .sensitive,
          retentionClass: .default,
          sourceOperation: descriptor.reference,
          providerID: record.providerID,
          bindingSnapshot: binding,
          contents: facts))
    }

    let reopened = try RuntimeArtifactStore(
      rootURL: root, nowUTC: { "2026-07-31T00:00:00Z" })
    let listed = try await reopened.list(jobID: record.jobID)
    XCTAssertEqual(listed, [metadata])
    XCTAssertEqual(metadata.bindingSnapshot, binding)
    let bytes = try await reopened.read(
      jobID: record.jobID, artifactID: metadata.artifactID,
      allowSensitive: true)
    XCTAssertEqual(bytes, facts)
    XCTAssertEqual(
      metadata.sha256,
      SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())

    let report = try RuntimeArtifactService.finalArtifactContents(
      name: "flash-report.json",
      descriptor: descriptor,
      record: record,
      recorded: listed,
      finalizeArtifactNames: ["flash-report.json"],
      completedStepIDs: [
        "flash-partitions",
        "verify-flash-readback",
        "rebind-and-verify-build",
      ])
    let reportDocument = try XCTUnwrap(
      JSONSerialization.jsonObject(with: report) as? [String: Any])
    XCTAssertEqual(reportDocument["completeness"] as? String, "complete")
    XCTAssertEqual(reportDocument["targetId"] as? String, "TGT-DAYU200")
    XCTAssertEqual(reportDocument["expectedBindingRevision"] as? Int, 7)
    XCTAssertTrue(
      (reportDocument["verifiedSteps"] as? [String])?.contains(
        "verify-flash-readback") == true)
    let flashRequest = try XCTUnwrap(
      reportDocument["request"] as? [String: Any])
    XCTAssertEqual(flashRequest["deviceProfile"] as? String, "dayu200")
    XCTAssertEqual(
      flashRequest["partitionPlan"] as? [String],
      ["boot", "system"])
    XCTAssertEqual(flashRequest["postFlashVerification"] as? String, "full")
    let products = try XCTUnwrap(
      reportDocument["artifacts"] as? [String: [String: Any]])
    XCTAssertEqual(
      products["post-flash-facts.json"]?["sha256"] as? String,
      metadata.sha256)
    XCTAssertEqual(
      products["post-flash-hilog.txt"]?["status"] as? String,
      "missing")

    let reportMetadata = try await reopened.publish(
      RuntimeArtifactPublicationRequest(
        jobID: record.jobID,
        sessionID: record.sessionID,
        stepID: "finalize-session",
        name: "flash-report.json",
        mediaType: "application/json",
        privacy: .standard,
        retentionClass: .default,
        sourceOperation: descriptor.reference,
        providerID: record.providerID,
        bindingSnapshot: binding,
        contents: report))
    let reopenedAgain = try RuntimeArtifactStore(
      rootURL: root, nowUTC: { "2026-07-31T00:00:00Z" })
    let finalList = try await reopenedAgain.list(jobID: record.jobID)
    XCTAssertEqual(Set(finalList.map(\.name)), ["post-flash-facts.json", "flash-report.json"])
    let reopenedReport = try await reopenedAgain.read(
      jobID: record.jobID, artifactID: reportMetadata.artifactID)
    XCTAssertEqual(reopenedReport, report)
  }
}
