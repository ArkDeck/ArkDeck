import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore

/// §8.4: how a coarse wire failure becomes a stable `error.code`.
///
/// The wire vocabulary cannot be read literally. `rejected` is returned by
/// pre-admission refusals, by read-only execution failures, by resource
/// mutations and by paths that may already have dispatched — so mapping it to
/// `admissionDenied` would tell a caller that nothing happened on requests
/// where something may well have. The rule is that only two things sharpen an
/// ambiguous failure: structured phase/effect evidence, and what the method is
/// able to do at all. Everything else stays an unknown outcome.
final class CLIControlFailureMappingContractTests: XCTestCase {

  private func daemonSource() throws -> String {
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: root.appending(path: "Sources/ArkDeckAgentDaemon/AgentDaemon.swift"),
      encoding: .utf8)
  }

  /// Every method the daemon dispatches on, scraped from its own switch.
  private func daemonMethods() throws -> Set<String> {
    var found: Set<String> = []
    for line in try daemonSource().split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("case \""), trimmed.hasSuffix("\":") else { continue }
      // `    case "job.status":` — the switch is at one fixed indentation, so
      // a `case "…"` nested deeper inside a handler is not a method name. One
      // case can list several methods (the capability-administration stubs
      // share a refusal), so the list is split rather than taken whole.
      guard line.hasPrefix("    case \"") else { continue }
      let body = trimmed.dropFirst(5).dropLast(1)
      for name in body.split(separator: ",") {
        let method = name.trimmingCharacters(in: .whitespaces)
        guard method.hasPrefix("\""), method.hasSuffix("\""), method.count > 2 else { continue }
        found.insert(String(method.dropFirst().dropLast()))
      }
    }
    return found
  }

  /// A method the daemon adds without classifying it must fail here rather
  /// than fall through to a default. The fallback direction is safe
  /// (mutation-capable), but an unreviewed classification is still a claim
  /// nobody made.
  func testEveryDaemonMethodIsClassified() throws {
    let daemon = try daemonMethods()
    XCTAssertGreaterThan(daemon.count, 40, "the method scrape found too little to be trusted")

    let unclassified = daemon.subtracting(CLIControlMethodRegistry.classifiedMethods).sorted()
    XCTAssertEqual(
      unclassified, [],
      """
      these daemon methods have no effect classification, so an ambiguous \
      failure from them cannot be mapped without guessing: \
      \(unclassified.joined(separator: ", "))
      """)

    let stale = CLIControlMethodRegistry.classifiedMethods.subtracting(daemon).sorted()
    XCTAssertEqual(
      stale, [],
      "these classified methods no longer exist in the daemon: \(stale.joined(separator: ", "))")
  }

  func testAnUnclassifiedMethodIsTreatedAsMutationCapable() {
    XCTAssertEqual(CLIControlMethodRegistry.effect(of: "some.future.method"), .mutationCapable)
    XCTAssertEqual(CLIControlMethodRegistry.effect(of: ""), .mutationCapable)
  }

  // MARK: The closed part of the map

  func testTheClosedWireCodesMapOneToOne() {
    let expected: [String: CLIErrorCode] = [
      "unsupportedProtocolVersion": .protocolVersionUnsupported,
      "malformedFrame": .protocolMalformed,
      "unknownMethod": .controlMethodUnavailable,
      "invalidParams": .invalidInput,
      "conflict": .resourceConflict,
      "notFound": .resourceNotFound,
      "recordUnreadable": .recordUnreadable,
      // §7.9's own code: a reference that is not registered on this host, as
      // distinct from a durable record that does not exist.
      "workspaceReferenceNotFound": .workspaceReferenceNotFound,
    ]
    for (wire, code) in expected {
      // The mapping must not depend on the method: these are unambiguous.
      for method in ["job.status", "job.submit", "some.future.method"] {
        XCTAssertEqual(
          CLIControlFailureMapper.code(forWireCode: wire, method: method), code,
          "\(wire) on \(method)")
      }
    }
  }

  // MARK: The ambiguous part

  func testRejectedBecomesAdmissionDeniedOnlyWithBothHalvesOfTheProof() {
    let proven = CLIControlFailureEvidence(phase: "preAdmission", newDispatchCount: 0)
    XCTAssertEqual(
      CLIControlFailureMapper.code(forWireCode: "rejected", method: "job.run", evidence: proven),
      .admissionDenied)

    for incomplete in [
      CLIControlFailureEvidence(phase: "preAdmission", newDispatchCount: nil),
      CLIControlFailureEvidence(phase: nil, newDispatchCount: 0),
      CLIControlFailureEvidence(phase: "dispatch", newDispatchCount: 0),
      CLIControlFailureEvidence(phase: "preAdmission", newDispatchCount: 1),
      CLIControlFailureEvidence(),
    ] {
      XCTAssertEqual(
        CLIControlFailureMapper.code(
          forWireCode: "rejected", method: "job.run", evidence: incomplete),
        .outcomeUnknown,
        "half a proof is not a proof: \(incomplete)")
    }
  }

  func testRejectedOnAReadOnlyMethodIsAPlainFailureRatherThanAnUnknownOutcome() {
    XCTAssertEqual(
      CLIControlFailureMapper.code(forWireCode: "rejected", method: "job.plan"), .operationFailed)
    XCTAssertEqual(
      CLIControlFailureMapper.code(forWireCode: "rejected", method: "operation.describe"),
      .operationFailed)
  }

  /// The whole point of the rule: a mutation-capable method that failed
  /// without evidence must not be reported as a refusal, because the caller
  /// would read that as "the device was not touched".
  func testRejectedOnAMutationCapableMethodWithoutEvidenceStaysUnknown() {
    for method in ["job.submit", "job.run", "target.adopt", "artifact.export"] {
      let code = CLIControlFailureMapper.code(forWireCode: "rejected", method: method)
      XCTAssertEqual(code, .outcomeUnknown, method)
      XCTAssertEqual(code.exitCode, 75, method)
    }
  }

  func testLegacyInternalErrorKeepsItsCodeOnlyWhenNothingCouldHaveHappened() {
    XCTAssertEqual(
      CLIControlFailureMapper.code(forWireCode: "internalError", method: "job.status"),
      .internalError)
    XCTAssertEqual(
      CLIControlFailureMapper.code(forWireCode: "internalError", method: "job.run"),
      .outcomeUnknown)
    XCTAssertEqual(
      CLIControlFailureMapper.code(
        forWireCode: "internalError", method: "job.run",
        evidence: CLIControlFailureEvidence(phase: "preAdmission", newDispatchCount: 0)),
      .internalError)
  }

  func testAnUnclassifiableWireErrorIsAsUncertainAsAnInternalOne() {
    XCTAssertEqual(
      CLIControlFailureMapper.code(forWireCode: "somethingNew", method: "job.status"),
      .internalError)
    XCTAssertEqual(
      CLIControlFailureMapper.code(forWireCode: "somethingNew", method: "job.submit"),
      .outcomeUnknown)
  }

  // MARK: Transport

  /// "It looked like a network problem" is not evidence that the request was
  /// never accepted.
  func testALostOrMalformedResponseFromAMutationIsAnUnknownOutcome() {
    for failure in [
      CLITransportFailure.malformedResponse, .lostResponse, .clientTimeout, .interrupted,
    ] {
      XCTAssertEqual(
        CLIControlFailureMapper.code(forTransportFailure: failure, method: "job.submit"),
        .outcomeUnknown,
        "\(failure)")
    }
  }

  func testAFailedConnectionIsRuntimeUnavailableForEveryMethod() {
    for method in ["job.status", "job.submit", "some.future.method"] {
      XCTAssertEqual(
        CLIControlFailureMapper.code(forTransportFailure: .connectFailed, method: method),
        .runtimeUnavailable,
        "nothing left the process, whatever the method could have done")
    }
  }

  func testReadOnlyMethodsKeepThePreciseTransportCode() {
    XCTAssertEqual(
      CLIControlFailureMapper.code(forTransportFailure: .clientTimeout, method: "job.status"),
      .clientTimeout)
    XCTAssertEqual(
      CLIControlFailureMapper.code(forTransportFailure: .interrupted, method: "job.status"),
      .clientInterrupted)
    XCTAssertEqual(
      CLIControlFailureMapper.code(forTransportFailure: .malformedResponse, method: "job.list"),
      .protocolMalformed)
  }

  // MARK: Evidence reading

  func testEvidenceIsReadFromTheFailurePayloadAndNeverFromAMessage() {
    let published = CLIControlFailureEvidence.read(
      from: .object(["phase": .string("preAdmission"), "newDispatchCount": .integer(0)]))
    XCTAssertTrue(published.provesZeroDispatchBeforeAdmission)

    XCTAssertFalse(CLIControlFailureEvidence.read(from: nil).provesZeroDispatchBeforeAdmission)
    XCTAssertFalse(
      CLIControlFailureEvidence.read(from: .string("phase: preAdmission, newDispatchCount: 0"))
        .provesZeroDispatchBeforeAdmission,
      "prose that happens to contain the words is not structured evidence")
  }

  // MARK: The registry itself

  func testEveryCodeHasExactlyOneExitStatusAndCategory() {
    for code in CLIErrorCode.allCases {
      XCTAssertEqual(
        code.exitCode, code.category.exitCode,
        "\(code.rawValue) must take its exit status from its category")
    }
    // §9's numbers, spelled here so a category renumbering has to be deliberate.
    XCTAssertEqual(CLIErrorCode.operationFailed.exitCode, 1)
    XCTAssertEqual(CLIErrorCode.artifactIntegrityFailed.exitCode, 2)
    XCTAssertEqual(CLIErrorCode.invalidOption.exitCode, 64)
    XCTAssertEqual(CLIErrorCode.invalidInput.exitCode, 65)
    XCTAssertEqual(CLIErrorCode.runtimeUnavailable.exitCode, 69)
    XCTAssertEqual(CLIErrorCode.protocolMalformed.exitCode, 70)
    XCTAssertEqual(CLIErrorCode.ioFailure.exitCode, 74)
    XCTAssertEqual(CLIErrorCode.outcomeUnknown.exitCode, 75)
    XCTAssertEqual(CLIErrorCode.admissionDenied.exitCode, 77)
    XCTAssertEqual(CLIErrorCode.clientInterrupted.exitCode, 130)
    XCTAssertEqual(CLIExitCategory.legacyAttention.exitCode, 4)
    XCTAssertEqual(CLIExitCategory.internalFailure.machineCategory, "internal")
  }

  /// Retryability is a promise about a request that may have dispatched, so it
  /// stays narrow on purpose.
  func testOnlyRequestsThatCannotHaveDispatchedAreMarkedRetryable() {
    let retryable = CLIErrorCode.allCases.filter(\.isControlRequestRetryable).map(\.rawValue)
    XCTAssertEqual(
      retryable.sorted(), ["clientTimeout", "resultNotReady", "runtimeUnavailable"],
      "widening this set promises a caller it may repeat something that already ran")
    XCTAssertFalse(
      CLIErrorCode.outcomeUnknown.isControlRequestRetryable,
      "an unknown outcome is settled by reading the owner, never by repeating the request")
  }

  func testAttentionTracksTheCategoriesAPersonHasToLookAt() {
    XCTAssertTrue(CLIErrorCode.humanActionRequired.requiresAttention)
    XCTAssertTrue(CLIErrorCode.outcomeUnknown.requiresAttention)
    XCTAssertTrue(CLIErrorCode.admissionDenied.requiresAttention)
    XCTAssertTrue(CLIErrorCode.artifactIntegrityFailed.requiresAttention)
    XCTAssertFalse(CLIErrorCode.invalidOption.requiresAttention)
    XCTAssertFalse(CLIErrorCode.operationFailed.requiresAttention)
  }
}
