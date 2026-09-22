@testable import ArkDeckClientKit
import Foundation
import XCTest
@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class FlashRuntimePlanClientContractTests: XCTestCase {
  private let target = FlashTargetPresentation(
    id: "target-flash", bindingRevision: 4, toolVersion: "3.2.0f", adoptedAtUTC: "2026-09-22T00:00:00Z")

  private func plan() -> FlashExactPlanPresentation {
    FlashPlanPresentationBuilder.presentation(
      mode: .execute, profile: .dayu200, target: target, imageFileName: "images.tar.gz")
  }

  private func artifact(_ plan: FlashExactPlanPresentation) -> FlashImportedArtifact {
    FlashImportedArtifact(lease: "lease-fixture", targetID: target.id,
      bindingRevision: target.bindingRevision, archiveSHA256: plan.archiveSHA256)
  }

  private func result(_ plan: FlashExactPlanPresentation) -> [String: Any] {
    [
      "schemaVersion": "arkdeck.job-plan/1", "executionMode": "planOnly",
      "operation": "flash.full-restore@1", "targetId": target.id,
      "catalogDigest": RuntimeOperationCatalog.catalogDigest,
      "stepSetDigestSHA256": plan.stepSetDigestSHA256,
      "bindingRevision": target.bindingRevision, "providerId": "arkforge",
      "effectiveEffect": "destructive", "authorizationPolicy": "runtimeCapability",
      "jobAdmitted": false, "dispatchDisposition": "notDispatched",
      "providerAdmissionBlocker": NSNull(), "materializedPlanDigest": String(repeating: "a", count: 64),
      "inputs": ["artifactLease": "lease-fixture", "deviceProfileRef": plan.profileReference,
        "intent": "fullRestore", "verification": "full"],
      "steps": FlashCatalogReview.decode(Data(FlashReviewCatalogGenerated.json.utf8))!.steps.map {
        ["stepId": $0.stepId, "kind": $0.kind, "effect": $0.effect,
          "cancellation": $0.cancellation, "binding": $0.binding, "optional": $0.optional] as [String: Any]
      },
    ]
  }

  private actor Replies {
    let response: Result<Data, FlashXPCReadFailure>
    var calls: [(String, [String: JSONValue]?)] = []
    init(_ response: Result<Data, FlashXPCReadFailure>) { self.response = response }
    func send(_ method: String, _ params: [String: JSONValue]?) -> Result<Data, FlashXPCReadFailure> {
      calls.append((method, params))
      return response
    }
  }

  private func envelope(_ result: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
  }

  func testOfflineGeneratedReviewRejectsDriftWithoutSelectingOrHashingSteps() throws {
    let data = Data(FlashReviewCatalogGenerated.json.utf8)
    let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNotNil(FlashCatalogReview.decode(data))
    for drift: [String: Any] in [
      ["schemaVersion": "future"], ["catalogDigest": String(repeating: "b", count: 64)],
      ["operation": "other@1"], ["providerId": "other"],
      ["selectionInputs": ["verification": "basic"]], ["jobAdmitted": true],
      ["jobAdmitted": 0], ["dispatchDisposition": "dispatched"],
      ["stepSetDigestSHA256": "invalid"], ["steps": []],
    ] {
      var changed = original
      changed.merge(drift) { _, new in new }
      XCTAssertNil(FlashCatalogReview.decode(try JSONSerialization.data(withJSONObject: changed)))
    }
    let steps = try XCTUnwrap(original["steps"] as? [[String: Any]])
    var unknownOwner = steps
    unknownOwner[0]["executionOwner"] = "unknown"
    for changedSteps in [steps + [steps[0]], Array(steps.reversed()), Array(steps.dropFirst()), unknownOwner] {
      var changed = original
      changed["steps"] = changedSteps
      XCTAssertNil(FlashCatalogReview.decode(try JSONSerialization.data(withJSONObject: changed)))
    }
  }

  func testProductionPlanReadConsumesCurrentWireNamesAndNeverSubmits() async throws {
    let plan = plan()
    let replies = Replies(.success(try envelope(result(plan))))
    let provider = FlashProductionApplicationProvider(send: { await replies.send($0, $1) })
    let preview = try await provider.runtimePlanPreview(plan: plan, artifact: artifact(plan), target: target)
    XCTAssertEqual(preview.materializedPlanDigest, String(repeating: "a", count: 64))
    let calls = await replies.calls
    XCTAssertEqual(calls.map(\.0), ["job.plan"])
    guard case .string(let json)? = calls.first?.1?["requestJson"] else { return XCTFail("missing typed plan request") }
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: Data(json.utf8))
    XCTAssertEqual(request.operation.id, "flash.full-restore")
    XCTAssertEqual(request.target.targetID, target.id)
    XCTAssertEqual(request.target.expectedBindingRevision, target.bindingRevision)
    XCTAssertNil(request.authorization)
  }

  func testOlderCompletePlanMayOmitOnlyTheAdditiveStepSetDigest() async throws {
    let plan = plan()
    var old = result(plan)
    old.removeValue(forKey: "stepSetDigestSHA256")
    let replies = Replies(.success(try envelope(old)))
    let provider = FlashProductionApplicationProvider(send: { await replies.send($0, $1) })
    let preview = try await provider.runtimePlanPreview(plan: plan, artifact: artifact(plan), target: target)
    XCTAssertEqual(preview.materializedPlanDigest, String(repeating: "a", count: 64))
  }

  func testBothPlanFormatsRequireBindingAndOptionalStepFacts() async throws {
    let plan = plan()
    for includeDigest in [false, true] {
      for drift in ["missingBinding", "missingOptional", "binding", "optional", "optionalType"] {
        var changed = result(plan)
        if !includeDigest { changed.removeValue(forKey: "stepSetDigestSHA256") }
        var steps = try XCTUnwrap(changed["steps"] as? [[String: Any]])
        switch drift {
        case "missingBinding": steps[0].removeValue(forKey: "binding")
        case "missingOptional": steps[0].removeValue(forKey: "optional")
        case "binding": steps[0]["binding"] = "confirmedDevice"
        case "optional": steps[0]["optional"] = true
        default: steps[0]["optional"] = 0
        }
        changed["steps"] = steps
        let replies = Replies(.success(try envelope(changed)))
        let provider = FlashProductionApplicationProvider(send: { await replies.send($0, $1) })
        do {
          _ = try await provider.runtimePlanPreview(plan: plan, artifact: artifact(plan), target: target)
          XCTFail("accepted incomplete or changed step facts")
        } catch {}
      }
    }
  }

  func testPlanIdentityAndAdmissionDriftNeverProduceReviewedDigest() async throws {
    let plan = plan()
    for drift: [String: Any] in [
      ["schemaVersion": "future"], ["catalogDigest": String(repeating: "b", count: 64)],
      ["stepSetDigestSHA256": String(repeating: "b", count: 64)],
      ["stepSetDigestSHA256": NSNull()], ["stepSetDigestSHA256": false],
      ["stepSetDigestSHA256": "invalid"], ["operation": "other@1"], ["targetId": "foreign"],
      ["bindingRevision": 5], ["bindingRevision": true], ["jobAdmitted": 0], ["providerId": "other"], ["effectiveEffect": "readOnly"],
      ["authorizationPolicy": "none"], ["jobAdmitted": true], ["dispatchDisposition": "dispatched"],
      ["providerAdmissionBlocker": "runtimeUnavailable"], ["materializedPlanDigest": "invalid"],
      ["inputs": ["artifactLease": "foreign"]],
    ] {
      var changed = result(plan)
      changed.merge(drift) { _, new in new }
      let replies = Replies(.success(try envelope(changed)))
      let provider = FlashProductionApplicationProvider(send: { await replies.send($0, $1) })
      do {
        _ = try await provider.runtimePlanPreview(plan: plan, artifact: artifact(plan), target: target)
        XCTFail("accepted drift: \(drift)")
      } catch {}
      let calls = await replies.calls
      XCTAssertEqual(calls.map(\.0), ["job.plan"])
    }
  }

  func testMissingAdmissionBlockerFactIsNotAnApprovedPreview() async throws {
    let plan = plan()
    var changed = result(plan)
    changed.removeValue(forKey: "providerAdmissionBlocker")
    let replies = Replies(.success(try envelope(changed)))
    let provider = FlashProductionApplicationProvider(send: { await replies.send($0, $1) })
    do {
      _ = try await provider.runtimePlanPreview(plan: plan, artifact: artifact(plan), target: target)
      XCTFail("missing required blocker field is not a proven absence of blockers")
    } catch {}
  }

  func testExtraMalformedStepOrChangedCancellationCannotHideInCompactMap() async throws {
    let plan = plan()
    let original = try XCTUnwrap(result(plan)["steps"] as? [[String: Any]])
    var cancellation = original
    cancellation[0]["cancellation"] = "unknown"
    for steps in [original + [[:]], cancellation] {
      var changed = result(plan)
      changed["steps"] = steps
      let replies = Replies(.success(try envelope(changed)))
      let provider = FlashProductionApplicationProvider(send: { await replies.send($0, $1) })
      do {
        _ = try await provider.runtimePlanPreview(plan: plan, artifact: artifact(plan), target: target)
        XCTFail("unreviewed step facts supplied a plan digest")
      } catch {}
    }
  }

  func testRunDisconnectOrUnconfirmedReadCannotDispatchTheSameJobAgain() async {
    let responses: [(Result<Data, FlashXPCReadFailure>, [String])] = [
      (.failure(.transport("connection interrupted")), ["job.run"]),
      // A compact run acknowledgment is not a valid current Job resource.
      (.success(Data(#"{"ok":true,"result":{"runRequested":true}}"#.utf8)), ["job.run", "job.show"]),
    ]
    for (response, expectedCalls) in responses {
      let replies = Replies(response)
      let provider = FlashProductionApplicationProvider(send: { await replies.send($0, $1) })
      guard case .failed = await provider.run(jobID: "job-flash") else {
        return XCTFail("unconfirmed response must not claim completion")
      }
      guard case .failed = await provider.run(jobID: "job-flash") else {
        return XCTFail("an unconfirmed run cannot be repeated")
      }
      let calls = await replies.calls
      XCTAssertEqual(calls.map(\.0), expectedCalls)
    }
  }

  func testMissingOrMalformedBootloaderObservationNeverBecomesAbsence() throws {
    let responses: [Result<Data, FlashXPCReadFailure>] = [
      .failure(.transport("connection interrupted")),
      .success(try envelope(["disposition": "unknown", "observationCount": 0])),
      .success(try envelope(["disposition": "absent", "observationCount": -1])),
      .success(try envelope(["disposition": "absent", "observationCount": false])),
      .success(try envelope(["disposition": "exactBoundTarget", "observationCount": 1])),
    ]
    for response in responses {
      let presentation = FlashWorkspaceResponseDecoding.presentation(
        operationResponse: .failure(.transport("disconnected")),
        targetResponse: .failure(.transport("disconnected")), bootloaderResponse: response)
      XCTAssertNil(presentation.bootloaderStatus)
    }
    let absent = FlashWorkspaceResponseDecoding.presentation(
      operationResponse: .failure(.transport("disconnected")),
      targetResponse: .failure(.transport("disconnected")),
      bootloaderResponse: .success(try envelope(["disposition": "absent", "observationCount": 0])))
    XCTAssertEqual(absent.bootloaderStatus?.disposition, .absent)
  }

  func testPlanDisconnectDoesNotRetryOrSubmit() async {
    let plan = plan()
    let replies = Replies(.failure(.transport("connection interrupted")))
    let provider = FlashProductionApplicationProvider(send: { await replies.send($0, $1) })
    do {
      _ = try await provider.runtimePlanPreview(plan: plan, artifact: artifact(plan), target: target)
      XCTFail("missing response cannot confirm a plan")
    } catch {}
    let calls = await replies.calls
    XCTAssertEqual(calls.map(\.0), ["job.plan"])
  }
}
