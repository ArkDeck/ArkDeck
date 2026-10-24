import Foundation
import Testing
@testable import ArkDeckClientKit
@testable import ArkDeckCore

struct DeviceKeyboardInputTests {
  private let target = DeviceTargetPresentation(id: "TGT-keyboard", bindingRevision: 7, displayName: "Fixture")
  private let text = "键盘 fixture ' $(value)"

  private actor Runtime {
    enum Fault: Sendable { case none, lostRun, unknown, foreignTarget, badReceipt, foreignSubmission, changedRequest, dispatchedAcceptance }
    let fault: Fault
    var calls: [(String, [String: JSONValue])] = []
    var metadata: [String: JSONValue] = [:]
    var payload = Data()
    var submittedRequest: JSONValue = .null
    var hasRun = false
    let importID = "imp-11111111-1111-4111-8111-111111111111"
    init(_ fault: Fault = .none) { self.fault = fault }
    func send(_ method: String, _ params: [String: JSONValue]) throws -> Data {
      calls.append((method, params))
      func envelope(_ result: JSONValue) throws -> Data {
        try JSONEncoder().encode(JSONValue.object(["id": .string("fixture"), "ok": .bool(true), "result": result]))
      }
      if method.hasPrefix("artifact.import.") {
        if method == "artifact.import.begin" { metadata = params }
        if method == "artifact.import.append" {
          guard case .string(let base64)? = params["base64"], let bytes = Data(base64Encoded: base64) else {
            throw AgentExecutionControlFailure("invalidInput", "bad fixture chunk")
          }
          payload.append(bytes)
        }
        let intent = try ArtifactImportIntent(metadata)
        let committed = method == "artifact.import.commit"
        let receipt: JSONValue = .object([
          "schemaVersion": .string("arkdeck.import-receipt/1"), "importId": .string(importID),
          "importRequestId": .string(intent.importRequestID),
          "owner": .object(["kind": .string("import"), "id": .string(importID)]),
          "artifactId": .string("ART-private"),
          "artifactDigest": .string(fault == .badReceipt ? String(repeating: "f", count: 64) : intent.sha256),
          "byteCount": .string(String(intent.byteCount)), "name": .string("keyboard-input.json"),
          "mediaType": .string("application/vnd.arkdeck.keyboard-input+json"), "privacy": .string("sensitive"),
          "targetId": .string(intent.targetID), "bindingRevision": .string(String(intent.bindingRevision)),
          "lease": .string("lease-v1:\(importID):ART-private"), "generation": .string("2"),
          "validation": .object(["kind": .string("keyboard-input")]),
        ])
        return try envelope(.object([
          "schemaVersion": .string("arkdeck.import/1"), "importId": .string(importID),
          "importRequestId": .string(intent.importRequestID), "metadata": .object(metadata),
          "metadataFingerprint": .string(try intent.fingerprint), "generation": .string(committed ? "2" : "1"),
          "state": .string(committed ? "committed" : "inProgress"), "nextOffset": .string(String(payload.count)),
          "maximumChunkBytes": .string("2097152"), "createdAtUtc": .string("2026-10-04T00:00:00Z"),
          "updatedAtUtc": .string("2026-10-04T00:00:00Z"), "receipt": committed ? receipt : .null,
        ]))
      }
      if method == "job.submit" {
        guard case .string(let encoded)? = params["requestJson"] else { throw AgentExecutionControlFailure("fixture", "missing request") }
        submittedRequest = try JSONDecoder().decode(JSONValue.self, from: Data(encoded.utf8))
        return try envelope(.object(["jobId": .string("job-keyboard"), "schemaVersion": .string("arkdeck.job-acceptance/1"),
          "deduplicated": .bool(false), "newDispatchCount": .integer(fault == .dispatchedAcceptance ? 1 : 0)]))
      }
      if method == "job.run" {
        hasRun = true
        if fault == .lostRun { throw AgentExecutionControlFailure("transportLost", "private fixture must never be displayed") }
        return try envelope(.object(["jobId": .string("job-keyboard"), "state": .string("succeeded"), "schemaVersion": .string("arkdeck.job-status/1")]))
      }
      if method == "job.show" {
        let response = try currentJobDetailResponse([
          "jobId": "job-keyboard", "targetId": (hasRun && fault == .foreignTarget) || fault == .foreignSubmission ? "TGT-foreign" : "TGT-keyboard",
          "operation": "input.keyboard@1", "state": hasRun ? (fault == .unknown ? "interrupted" : "succeeded") : "preflight",
          "outcomeUnknown": hasRun && fault == .unknown, "waitingForHuman": false, "outstandingResidueCount": 0,
          "timeline": hasRun ? [#"verified inject-keyboard-input ["keyboardInput"]"#] : [],
        ])
        guard case .object(var envelope) = try JSONDecoder().decode(JSONValue.self, from: response),
          case .object(var detail)? = envelope["result"], case .object(var request) = submittedRequest
        else { throw AgentExecutionControlFailure("fixture", "invalid detail") }
        if fault == .changedRequest { request["idempotencyKey"] = .string("another-input") }
        detail["request"] = .object(request)
        envelope["result"] = .object(detail)
        return try JSONEncoder().encode(JSONValue.object(envelope))
      }
      throw AgentExecutionControlFailure("invalidInput", "unexpected fixture call")
    }
  }

  @Test func boundedTextRequiresClipboardConsentAndNeverEntersJobInputs() async throws {
    let runtime = Runtime()
    let provider = DeviceProductionProvider { try await runtime.send($0, $1) }
    guard case .confirmed(let summary) = await provider.sendKeyboard(.text(text, allowDeviceClipboard: true), to: target) else {
      Issue.record("exact Import and Job receipts should confirm injector acceptance"); return
    }
    #expect(summary == ["keyboardInput": "injectorAccepted"])
    let calls = await runtime.calls
    #expect(calls.map(\.0) == ["artifact.import.begin", "artifact.import.append", "artifact.import.commit", "job.submit", "job.show", "job.run", "job.show"])
    let payload = try JSONDecoder().decode([String: JSONValue].self, from: await runtime.payload)
    #expect(payload["text"] == .string(text))
    guard case .string(let encoded)? = calls[3].1["requestJson"] else { Issue.record("typed request missing"); return }
    let request = try JSONDecoder().decode(RuntimeOperationRequest.self, from: Data(encoded.utf8))
    #expect(request.operation.id == "input.keyboard")
    #expect(Set(request.inputs.keys) == ["keyboardArtifactLease", "inputEpochUtc"])
    #expect(!encoded.contains("键盘"))
    #expect(!encoded.contains("$(value)"))
  }

  @Test func unapprovedOversizedOrControlTextHasZeroCalls() async {
    let runtime = Runtime()
    let provider = DeviceProductionProvider { try await runtime.send($0, $1) }
    for command in [DeviceKeyboardCommand.text(text, allowDeviceClipboard: false),
      .text(String(repeating: "字", count: 171), allowDeviceClipboard: true),
      .text("a\nb", allowDeviceClipboard: true),
      .text("a\u{0000}b", allowDeviceClipboard: true),
      .text("a\u{007f}b", allowDeviceClipboard: true),
      .text("a\u{0085}b", allowDeviceClipboard: true),
      .text("", allowDeviceClipboard: true)] {
      guard case .failed = await provider.sendKeyboard(command, to: target) else { Issue.record("invalid input accepted"); return }
    }
    #expect(await runtime.calls.isEmpty)
  }

  @Test func unicodeJoinersSurviveThePrivateUploadWithoutEnteringJobInputs() async throws {
    for text in ["👩‍💻", "می\u{200c}روم", "a\u{2060}b"] {
      let runtime = Runtime()
      let provider = DeviceProductionProvider { try await runtime.send($0, $1) }
      guard case .confirmed = await provider.sendKeyboard(.text(text, allowDeviceClipboard: true), to: target) else {
        Issue.record("Unicode format characters are literal text, not C0/C1 controls"); return
      }
      let payload = try JSONDecoder().decode([String: JSONValue].self, from: await runtime.payload)
      #expect(payload["text"] == .string(text))
      let request = await runtime.submittedRequest
      guard case .object(let fields) = request, case .object(let inputs)? = fields["inputs"] else {
        Issue.record("typed request missing"); return
      }
      #expect(Set(inputs.keys) == ["keyboardArtifactLease", "inputEpochUtc"])
    }
  }

  @Test func lostUnknownAndForeignReceiptsNeverRetryOrEchoServiceErrors() async {
    for fault in [Runtime.Fault.lostRun, .unknown, .foreignTarget] {
      let runtime = Runtime(fault)
      let provider = DeviceProductionProvider { try await runtime.send($0, $1) }
      guard case .unknown(let message) = await provider.sendKeyboard(.key(.enter), to: target) else {
        Issue.record("unconfirmed input must remain unknown"); return
      }
      #expect(!message.contains("private fixture"))
      let calls = await runtime.calls
      #expect(calls.filter { $0.0 == "job.submit" }.count == 1)
      #expect(calls.filter { $0.0 == "job.run" }.count == 1)
    }
  }

  @Test func mismatchedAcceptedRequestNeverRunsAnyInput() async {
    for fault in [Runtime.Fault.foreignSubmission, .changedRequest, .dispatchedAcceptance] {
      let runtime = Runtime(fault)
      let provider = DeviceProductionProvider { try await runtime.send($0, $1) }
      guard case .unknown = await provider.sendKeyboard(.key(.enter), to: target) else {
        Issue.record("unproven acceptance must remain unknown"); return
      }
      let calls = await runtime.calls
      #expect(calls.filter { $0.0 == "job.submit" }.count == 1)
      #expect(!calls.contains { $0.0 == "job.run" })
    }
  }

  @Test func changedImportReceiptNeverSubmitsADeviceJob() async {
    let runtime = Runtime(.badReceipt)
    let provider = DeviceProductionProvider { try await runtime.send($0, $1) }
    guard case .failed = await provider.sendKeyboard(.key(.enter), to: target) else { Issue.record("changed receipt accepted"); return }
    #expect(await runtime.calls.allSatisfy { $0.0.hasPrefix("artifact.import.") })
  }
}
