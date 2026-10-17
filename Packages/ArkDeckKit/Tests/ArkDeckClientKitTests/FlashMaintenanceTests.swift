import ArkDeckCore
import Foundation
import Testing
@testable import ArkDeckClientKit

struct FlashMaintenanceTests {
  private func document(_ outcome: String = "verified") -> [String: Any] {
    let hash = String(repeating: "a", count: 64)
    return ["schema": "arkforge.flash-verification/v1", "source_job_id": "JOB-1",
      "source_plan_id": "PLAN-1", "source_plan_sha256": hash,
      "exit_code": outcome == "verified" ? 0 : outcome == "typedSkip" ? 9 : 7,
      "outcome": outcome == "verified" ? "verified" : outcome == "typedSkip" ? "partial" : "failed",
      "verified": outcome == "verified" ? 1 : 0, "skipped": outcome == "typedSkip" ? 1 : 0,
      "failed": outcome == "failed" ? 1 : 0,
      "targets": [["target": "userdata", "range_start": 4096, "range_length": 4096,
        "expected_sha256": hash, "observed_sha256": outcome == "verified" ? hash as Any : NSNull(),
        "verification_strength": outcome == "verified" ? "fullHash" as Any : NSNull(),
        "outcome": outcome, "reason": outcome == "verified" ? NSNull() as Any : outcome == "typedSkip" ? "mounted-writable-after-boot" : "content-mismatch"]]]
  }
  private func decode(_ value: [String: Any]) throws -> FlashMaintenanceResult {
    try JSONDecoder().decode(FlashMaintenanceResult.self, from: JSONSerialization.data(withJSONObject: value))
  }
  @Test func verificationDistinguishesMatchSkipAndFailure() throws {
    for (outcome, code) in [("verified", 0), ("typedSkip", 9), ("failed", 7)] {
      let result = try decode(document(outcome))
      #expect(result.exitCode == code)
      #expect(result.verification?.targets.first?.rangeLength == 4096)
      #expect(result.verification?.targets.first?.verificationStrength == (code == 0 ? "fullHash" : nil))
    }
  }
  @Test func fabricatedSuccessAndIncompleteRestorationAreRejected() throws {
    var forged = document("typedSkip")
    forged["exit_code"] = 0
    #expect(throws: (any Error).self) { try decode(forged) }
    let incomplete: [String: Any] = ["schema": "arkforge.boot-loop-restoration/v1", "source_job_id": "JOB-1",
      "restoration_job_id": "JOB-2", "exit_code": 0, "outcome": "verified", "outcome_unknown": false]
    #expect(throws: (any Error).self) { try decode(incomplete) }
    let stopped: [String: Any] = ["schema": "arkforge.boot-loop-restoration/v1", "source_job_id": "JOB-1",
      "exit_code": 1, "outcome": "stopped", "outcome_unknown": true, "reason": "identity changed"]
    #expect(try decode(stopped).outcomeUnknown)
  }
  @Test func restorationRequiresTheExactOriginalRamdiskFullHash() throws {
    var verification = document()
    verification["source_job_id"] = "JOB-2"
    let hash = "bdd1f4eacbe545f5a553b529980bc487723d37554148058dd551c241abf86de4"
    verification["targets"] = [["target": "ramdisk", "range_start": 121_634_816,
      "range_length": 4_194_304, "expected_sha256": hash, "observed_sha256": hash,
      "outcome": "verified", "verification_strength": "fullHash"]]
    var restoration: [String: Any] = ["schema": "arkforge.boot-loop-restoration/v1",
      "source_job_id": "JOB-1", "restoration_job_id": "JOB-2", "exit_code": 0,
      "outcome": "verified", "outcome_unknown": false, "verification": verification]
    #expect(try decode(restoration).exitCode == 0)
    verification["outcome"] = "partial"
    restoration["verification"] = verification
    #expect(throws: (any Error).self) { try decode(restoration) }
  }
  @Test func reviewedPlanPrecedesSubmissionAndLostRunIsNeverRepeated() async {
    let wire = MaintenanceWire()
    let provider = FlashProductionApplicationProvider(send: { method, params in await wire.send(method, params) })
    let target = FlashTargetPresentation(id: "target-1", bindingRevision: 1, toolVersion: "test", adoptedAtUTC: "")
    _ = await provider.maintenance(sourceJobID: "source-1", target: target, archiveURL: nil, budgetMs: 1000)
    _ = await provider.maintenance(sourceJobID: "source-1", target: target, archiveURL: nil, budgetMs: 1000)
    #expect(await wire.methods == ["job.plan", "job.submit", "job.run", "job.plan", "job.submit"])
  }
  @Test func invalidParametersNeverReachTheRuntime() async {
    let provider = FlashProductionApplicationProvider(send: { _, _ in
      Issue.record("invalid maintenance reached the transport")
      return .failure(.transport("unexpected call"))
    })
    let target = FlashTargetPresentation(id: "target-1", bindingRevision: 1, toolVersion: "test", adoptedAtUTC: "")
    let result = await provider.maintenance(sourceJobID: "source", target: target, archiveURL: nil, budgetMs: 0)
    guard case .failed(let reason) = result else { Issue.record("expected invalid input"); return }
    #expect(reason.contains("exit 2"))
  }
}

private actor MaintenanceWire {
  var methods: [String] = []
  func send(_ method: String, _ params: [String: JSONValue]?) -> Result<Data, FlashXPCReadFailure> {
    methods.append(method)
    let digest = String(repeating: "a", count: 64)
    switch method {
    case "job.plan":
      let result: [String: Any] = ["operation": "flash.verify@1", "targetId": "target-1",
        "bindingRevision": 1, "providerId": "arkforge", "effectiveEffect": "readOnly",
        "jobAdmitted": false, "dispatchDisposition": "notDispatched", "materializedPlanDigest": digest]
      return .success(try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result]))
    case "job.submit":
      guard case .string(let raw)? = params?["requestJson"],
        let request = try? JSONDecoder().decode([String: JSONValue].self, from: Data(raw.utf8)) else {
        Issue.record("missing typed request"); return .failure(.transport("invalid request"))
      }
      #expect(request["reviewedPlanDigest"] == .string(digest))
      return .success(Data(#"{"ok":true,"result":{"jobId":"JOB-1"}}"#.utf8))
    case "job.run": return .failure(.transport("response lost"))
    default: Issue.record("unexpected request"); return .failure(.transport("unexpected request"))
    }
  }
}
