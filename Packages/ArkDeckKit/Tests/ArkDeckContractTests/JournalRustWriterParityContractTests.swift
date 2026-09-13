import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage

/// TASK-XPA-014: the Rust Job journal writer and this Swift journal share one
/// committed oracle in `rust/tests/fixtures/journal-writer`: each scenario's
/// bytes as `FileDurableJournal` writes them and the facts
/// `DurableJournalRecovery` derives from them. `job_journal_writer.rs` must
/// reproduce the same bytes and facts from the same records, and each side
/// must repair and continue the shared bytes. To re-record the oracle from
/// Swift, set ARKDECK_RUST_JOURNAL_WRITER_RECORD to a new /private/tmp path.
final class JournalRustWriterParityContractTests: XCTestCase {
  private static let fixtures: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url.appending(path: "rust/tests/fixtures/journal-writer")
  }()

  private enum Scenario: String, CaseIterable {
    case succeeded
    case unknown
    case compensation
    case planOnly = "plan-only"
  }

  private let session = "session-rust-writer"
  private let job = "job-rust-writer"
  private let host = JournalTarget(
    scope: "host", targetID: "host-1", connectKey: nil, identitySnapshotHash: nil)
  private let device = JournalTarget(
    scope: "device", targetID: "TGT-fixture", connectKey: "fixture-only",
    identitySnapshotHash: String(repeating: "b", count: 64))

  func testSwiftJournalWritesTheSharedOracleBytesAndFacts() throws {
    let record = ProcessInfo.processInfo.environment["ARKDECK_RUST_JOURNAL_WRITER_RECORD"]
    if let record {
      guard record.hasPrefix("/private/tmp/") else { throw NSError(domain: "fixture", code: 1) }
      try FileManager.default.createDirectory(
        at: URL(filePath: record), withIntermediateDirectories: true)
    }
    for scenario in Scenario.allCases {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let url = directory.appending(path: "journal.jsonl")
      let journal = try FileDurableJournal(url: url)
      for event in try events(scenario) { try journal.appendAndSynchronize(event) }
      let bytes = try Data(contentsOf: url)
      let facts = Self.facts(try DurableJournalRecovery.inspect(url: url))
      if let record {
        let root = URL(filePath: record)
        try bytes.write(to: root.appending(path: "\(scenario.rawValue).jsonl"))
        var encoded = try CanonicalJSONEncoders.canonicalPretty().encode(facts)
        encoded.append(0x0A)
        try encoded.write(to: root.appending(path: "\(scenario.rawValue).replay.json"))
        continue
      }
      XCTAssertEqual(
        String(decoding: bytes, as: UTF8.self),
        String(decoding: try oracle(scenario, "jsonl"), as: UTF8.self), scenario.rawValue)
      XCTAssertEqual(
        facts, try JSONDecoder().decode(JSONValue.self, from: oracle(scenario, "replay.json")),
        scenario.rawValue)
    }
  }

  func testSwiftRepairsAndContinuesTheSharedOracle() throws {
    guard ProcessInfo.processInfo.environment["ARKDECK_RUST_JOURNAL_WRITER_RECORD"] == nil else {
      throw XCTSkip("recording the oracle")
    }
    for scenario in Scenario.allCases {
      let golden = try oracle(scenario, "jsonl")
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let url = directory.appending(path: "journal.jsonl")
      try (golden + Data("{\"schemaVersion\":\"1.0.0\",\"eventId\":\"evt-".utf8)).write(to: url)
      let journal = try FileDurableJournal(url: url)
      XCTAssertEqual(try Data(contentsOf: url), golden, scenario.rawValue)
      let count = try DurableJournalRecovery.inspect(url: url).events.count
      try journal.appendAndSynchronize(try continuation(scenario))
      let replay = try DurableJournalRecovery.inspect(url: url)
      XCTAssertEqual(replay.events.count, count + 1, scenario.rawValue)
      XCTAssertFalse(replay.hasTornTail, scenario.rawValue)
    }
  }

  // MARK: - Scenarios (mirrored in job_journal_writer.rs)

  private func id(_ sequence: Int) -> String { String(format: "evt-%02d", sequence) }
  private func time(_ sequence: Int) -> String {
    String(format: "2026-09-13T00:00:%02dZ", sequence)
  }

  private func created(_ sequence: Int, mode: String) throws -> JournalEvent {
    try .jobCreated(
      eventID: id(sequence), sequence: sequence, sessionID: session, jobID: job,
      timestamp: time(sequence), executionMode: mode, executionAuthority: "standardAgent",
      coreBaseline: "CORE-3.0.0")
  }

  private func transition(
    _ sequence: Int, _ from: JobState, _ to: JobState, _ reason: String, trigger: Int? = nil
  ) throws -> JournalEvent {
    try .stateTransition(
      eventID: id(sequence), sequence: sequence, sessionID: session, jobID: job,
      timestamp: time(sequence), from: from, to: to, reason: reason,
      triggerEventID: trigger.map(id))
  }

  private func intent(
    _ sequence: Int, _ step: WorkflowStep, _ target: JournalTarget, binding: Int?
  ) throws -> JournalEvent {
    try .stepIntent(
      eventID: id(sequence), sequence: sequence, sessionID: session, jobID: job,
      timestamp: time(sequence), step: step, target: target, attempt: 1,
      bindingRevision: binding)
  }

  private func outcome(
    _ sequence: Int, step: String, intent: Int, result: String = "succeeded",
    certainty: JournalOutcomeCertainty = .confirmed, code: String? = nil,
    summary: String? = nil
  ) throws -> JournalEvent {
    try .stepOutcome(
      eventID: id(sequence), sequence: sequence, sessionID: session, jobID: job,
      timestamp: time(sequence), stepID: step, attempt: 1,
      correlatesToIntentEventID: id(intent), result: result, outcomeCertainty: certainty,
      semanticCode: code, summary: summary)
  }

  private func finalized(_ sequence: Int, status: String) throws -> JournalEvent {
    try JournalEvent(
      eventID: id(sequence), sequence: sequence, sessionID: session, jobID: job,
      timestamp: time(sequence), kind: .finalized,
      payload: [
        "terminalStatus": .string(status),
        "manifestSha256": .string(String(repeating: "c", count: 64)),
        "outcomeCertainty": .string("confirmed"),
      ])
  }

  private func probeStep() throws -> WorkflowStep {
    try WorkflowStep(
      id: "probe-host-tool", kind: .probeHostTool, declaredEffect: .hostOnly,
      declaredCancellation: .immediate, declaredBindingRequirement: .none,
      arguments: ["toolIdentity": .string("hdc"), "candidatePath": .string("/usr/bin/true")])
  }

  private func captureStep(
    _ id: String, artifact: String, compensations: [CompensationDescriptor] = []
  ) throws -> WorkflowStep {
    try WorkflowStep(
      id: id, kind: .captureRemoteStdout, declaredEffect: .readOnly,
      declaredCancellation: .immediate, declaredBindingRequirement: .confirmedDevice,
      arguments: [
        "catalogId": .string("arkui-ui-dump"), "actionId": .string("nodeSummary"),
        "parameters": .object([:]), "artifactId": .string(artifact),
      ], compensationDescriptors: compensations)
  }

  private func finalizeStep() throws -> WorkflowStep {
    try WorkflowStep(
      id: "finalize-session", kind: .finalizeSession, declaredEffect: .hostOnly,
      declaredCancellation: .atSafeBoundary, declaredBindingRequirement: .none,
      arguments: [
        "sessionId": .string(session), "publicationPolicy": .string("atomicAfterValidation"),
      ])
  }

  private func rebootStep() throws -> WorkflowStep {
    try WorkflowStep(
      id: "reboot-device", kind: .rebootDevice, declaredEffect: .deviceMutation,
      declaredCancellation: .atSafeBoundary, declaredBindingRequirement: .confirmedDevice,
      arguments: ["targetMode": .string("normal"), "reason": .string("fixture")])
  }

  private func stopDescriptor() throws -> CompensationDescriptor {
    let arguments: [String: JSONValue] = [
      "captureStepId": .string("capture-trace"), "stopPolicy": .string("safe"),
    ]
    return try CompensationDescriptor(
      id: "stop-capture", kind: .stopRemoteCapture, declaredEffect: .deviceMutation,
      declaredCancellation: .atSafeBoundary, declaredBindingRequirement: .confirmedDevice,
      trigger: .onFailure, arguments: arguments,
      argumentsHash: try JournalCanonicalJSON.argumentsHash(arguments))
  }

  private func events(_ scenario: Scenario) throws -> [JournalEvent] {
    switch scenario {
    case .succeeded:
      return [
        try created(0, mode: "execute"),
        try transition(1, .queued, .preflight, "admitted"),
        try intent(2, probeStep(), host, binding: nil),
        try outcome(3, step: "probe-host-tool", intent: 2),
        try transition(4, .preflight, .running, "preflightComplete"),
        try intent(5, captureStep("capture-ui-dump", artifact: "ui-dump"), device, binding: 1),
        try outcome(
          6, step: "capture-ui-dump", intent: 5, code: "captured", summary: "UI dump captured"),
        try transition(7, .running, .finalizing, "stepsComplete"),
        try intent(8, finalizeStep(), host, binding: nil),
        try outcome(9, step: "finalize-session", intent: 8),
        try transition(10, .finalizing, .succeeded, "completed"),
      ]
    case .unknown:
      return [
        try created(0, mode: "execute"),
        try transition(1, .queued, .preflight, "admitted"),
        try transition(2, .preflight, .running, "preflightComplete"),
        try intent(3, rebootStep(), device, binding: 1),
        try outcome(
          4, step: "reboot-device", intent: 3, result: "failed", certainty: .outcomeUnknown,
          code: "transportLost", summary: "reply lost after dispatch"),
        try transition(5, .running, .waitingForRecovery, "outcomeUnknown", trigger: 4),
        try transition(6, .waitingForRecovery, .reconciling, "startupReconcile"),
        try .reconcileStarted(
          eventID: id(7), sequence: 7, sessionID: session, jobID: job, timestamp: time(7),
          recoveryAttemptID: "recovery-1", sourceState: .waitingForRecovery,
          lastDurableSequence: 6, trigger: "startup"),
        try .reconcileOutcome(
          eventID: id(8), sequence: 8, sessionID: session, jobID: job, timestamp: time(8),
          bindingRevision: nil, recoveryAttemptID: "recovery-1", result: "waitingForRecovery",
          nextState: .waitingForRecovery, outcomeCertainty: .outcomeUnknown,
          safeBoundaryConfirmed: false, evidence: ["readbackUnavailable"]),
        try transition(9, .reconciling, .waitingForRecovery, "reconcileUnproven", trigger: 8),
      ]
    case .compensation:
      return [
        try created(0, mode: "execute"),
        try transition(1, .queued, .preflight, "admitted"),
        try transition(2, .preflight, .running, "preflightComplete"),
        try intent(
          3, captureStep("capture-trace", artifact: "trace-dump", compensations: [stopDescriptor()]),
          device, binding: 1),
        try outcome(4, step: "capture-trace", intent: 3),
        try transition(5, .running, .finalizing, "laterStepFailed"),
        try .compensationIntent(
          eventID: id(6), sequence: 6, sessionID: session, jobID: job, timestamp: time(6),
          compensationOfStepID: "capture-trace", descriptor: stopDescriptor(), target: device,
          attempt: 1, bindingRevision: 1),
        try .compensationOutcome(
          eventID: id(7), sequence: 7, sessionID: session, jobID: job, timestamp: time(7),
          compensationOfStepID: "capture-trace", descriptorID: "stop-capture", attempt: 1,
          correlatesToIntentEventID: id(6), result: "succeeded", outcomeCertainty: .confirmed),
        try transition(8, .finalizing, .failed, "compensated"),
      ]
    case .planOnly:
      return [
        try created(0, mode: "planOnly"),
        try transition(1, .queued, .preflight, "admitted"),
        try transition(2, .preflight, .planning, "planOnly"),
        try transition(3, .planning, .finalizing, "planMaterialized"),
        try transition(4, .finalizing, .planned, "planned"),
      ]
    }
  }

  private func continuation(_ scenario: Scenario) throws -> JournalEvent {
    switch scenario {
    case .succeeded: try finalized(11, status: "succeeded")
    case .unknown: try transition(10, .waitingForRecovery, .reconciling, "manualReconcile")
    case .compensation: try finalized(9, status: "failed")
    case .planOnly: try finalized(5, status: "planned")
    }
  }

  // MARK: - Oracle

  private func oracle(_ scenario: Scenario, _ suffix: String) throws -> Data {
    try Data(contentsOf: Self.fixtures.appending(path: "\(scenario.rawValue).\(suffix)"))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "rust-journal-writer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// The replay facts in the shape `ReplayFacts` (Rust) decodes.
  private static func facts(_ replay: JournalReplay) -> JSONValue {
    func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    func number(_ value: Int?) -> JSONValue { value.map { .integer(Int64($0)) } ?? .null }
    let abandonment: JSONValue =
      replay.pendingAbandonment.map { pending in
        .object([
          "intentEventId": .string(pending.intentEventID),
          "phase": .string(pending.phase.rawValue),
          "outcomeEventId": text(pending.outcomeEventID),
          "releaseAuthorized": pending.releaseAuthorized.map(JSONValue.bool) ?? .null,
          "deviceHazards": .array(pending.deviceHazards.map(JSONValue.string)),
          "outcomeCertainty": .string(pending.outcomeCertainty.rawValue),
        ])
      } ?? .null
    return .object([
      "hasTornTail": .bool(replay.hasTornTail),
      "eventCount": .integer(Int64(replay.events.count)),
      "schemaVersion": text(replay.schemaVersion),
      "executionMode": text(replay.executionMode),
      "executionAuthority": text(replay.executionAuthority),
      "currentState": text(replay.currentState?.rawValue),
      "lastDurableSequence": number(replay.lastDurableSequence),
      "outstandingIntents": .array(
        replay.outstandingIntents.map { intent in
          .object([
            "eventId": .string(intent.eventID), "stepId": .string(intent.stepID),
            "attempt": .integer(Int64(intent.attempt)),
            "effect": .string(intent.effect.rawValue),
            "bindingRevision": number(intent.bindingRevision),
          ])
        }),
      "unknownOutcomes": .array(
        replay.unknownOutcomes.map { unknown in
          .object([
            "eventId": .string(unknown.eventID),
            "correlatedIntentEventId": .string(unknown.correlatedIntentEventID),
            "stepId": .string(unknown.stepID), "attempt": .integer(Int64(unknown.attempt)),
            "effect": .string(unknown.effect.rawValue),
            "isCompensation": .bool(unknown.isCompensation),
          ])
        }),
      "requiredAbandonmentHazards": .array(
        replay.requiredAbandonmentHazards.map(JSONValue.string)),
      "latestBindingRevision": number(replay.latestBindingRevision),
      "lastConfirmedStepId": text(replay.lastConfirmedStepID),
      "lastReconcileOutcomeCertainty": text(replay.lastReconcileOutcomeCertainty?.rawValue),
      "resourceReleaseAuthorized": .bool(replay.resourceReleaseAuthorized),
      "requiresUnknownFinalizedOutcome": .bool(replay.requiresUnknownFinalizedOutcome),
      "pendingAbandonment": abandonment,
      "finalized": .bool(replay.finalized),
      "requiresRecovery": .bool(replay.requiresRecovery),
    ])
  }
}
