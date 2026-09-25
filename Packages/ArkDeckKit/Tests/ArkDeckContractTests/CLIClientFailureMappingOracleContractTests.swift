import ArkDeckAgentClient
import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore

/// How Swift's CLI names a client failure (`CLIRuntimeSession.mapped`),
/// recorded for the Rust CLI to replay
/// (`rust/crates/arkdeck-cli/tests/client_failure_mapping.rs`).
///
/// `cases.json` holds 56 failures in full: no connection, a lost or malformed
/// reply, the client's own deadline, and the Runtime's refusal with and
/// without proof that nothing was dispatched, each for read-only and
/// mutation-capable methods. A case records the code, words, details and
/// command Swift answers.
///
/// `methods.json` holds Swift's code for every method Swift classifies: each
/// transport failure, and every wire code Swift's mapper knows (and one it
/// does not) with no evidence, with the pre-admission proof, and with each
/// owner's proof, each also with one dispatch instead of none. Methods that
/// answer alike share a profile, and a variant beyond the first two is
/// recorded only where it changes the answer. The words and details follow
/// one rule for every entry, which this test checks as it records.
///
/// Record a new oracle with
/// `ARKDECK_RUST_CLIENT_FAILURE_MAPPING_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class CLIClientFailureMappingOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/client-failure-mapping", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_CLIENT_FAILURE_MAPPING_RECORD"

  /// Every wire code `CLIControlFailureMapper` names, and one it does not.
  private static let wireCodes: [String] = [
    "resourceConflict", "factsDrifted", "admissionDenied", "targetTrustPending", "invalidInput",
    "operationUnavailable", "inputTooLarge", "invalidCursor", "idempotencyConflict",
    "reviewedPlanMismatch", "resourceNotFound", "humanActionExpired",
    "orchestrationBudgetExpired", "orchestrationClockUntrusted", "bindingRevisionStale",
    "unsupportedProtocolVersion", "malformedFrame", "unknownMethod", "invalidParams", "conflict",
    "notFound", "resultNotReady", "workspaceReferenceNotFound", "recordUnreadable", "rejected",
    "internalError", "artifactIntegrityFailed", "sensitiveAccessDenied", "operationFailed",
    "quotaExceeded", "fileIdentityChanged", "ioFailure", "outcomeUnknown", "unclassifiedWireCode",
  ]
  /// Every owner phase `CLIControlFailureMapper` reads.
  private static let ownerPhases: [String] = [
    "artifactOwner", "importOwner", "bootstrapRegistryOwner", "targetDisplayNameOwner",
    "candidateDisplayNameOwner", "historyFilterOwner", "runtimeStorageOwner", "sessionOwner",
    "workspaceProjectOwner", "workspacePresetOwner", "traceCacheOwner", "traceInspectionOwner",
  ]

  func testSwiftNamesTheClientFailuresTheRustCLIReplays() throws {
    let failures: [(String, AgentClientError)] = [
      ("connectFailed", .connectFailed("connection refused")),
      ("lostResponse", .transport("the peer closed the connection")),
      ("malformedResponse", .malformedResponse("the frame is not a response")),
      ("deadlineExceeded", .deadlineExceeded),
      ("daemonError", .daemonError(code: "notFound", message: "no such resource")),
      (
        "refusedBeforeAdmission",
        .structuredDaemonError(
          code: "invalidParams", message: "the parameters are invalid",
          details: ["phase": .string("preAdmission"), "newDispatchCount": .integer(0)])
      ),
      (
        "refusedWithoutProof",
        .structuredDaemonError(code: "conflict", message: "the target is busy", details: [:])
      ),
    ]
    let methods = [
      "human-action.resume", "agent.run", "agent.resume", "agent.status", "job.status",
      "job.submit", "job.run", "health",
    ]
    var cases: [JSONValue] = []
    for method in methods {
      for (name, failure) in failures {
        let error = CLIRuntimeSession.mapped(failure, method: method, command: method)
        cases.append(
          .object([
            "failure": .string(name), "method": .string(method),
            "code": .string(error.code.rawValue), "message": .string(error.message),
            "details": .object(error.details),
            "command": error.command.map(JSONValue.string) ?? .null,
          ]))
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [:]
    files["cases.json"] =
      try encoder.encode(JSONValue.object(["cases": .array(cases)])) + Data("\n".utf8)
    files["methods.json"] = try encoder.encode(Self.methodTable(encoder: encoder)) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("CLIClientFailureMappingOracleContractTests"),
          "owners": .array([
            .string("CLIRuntimeSession.mapped"), .string("CLIControlFailureMapper"),
            .string("CLIControlMethodRegistry.effect(of:)"),
          ]),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }

  /// Swift's answers for every classified method, grouped into profiles.
  private static func methodTable(encoder: JSONEncoder) throws -> JSONValue {
    var variants: [(String, [String: JSONValue])] = [
      ("preAdmission", ["phase": .string("preAdmission"), "newDispatchCount": .integer(0)]),
      ("preAdmission/1", ["phase": .string("preAdmission"), "newDispatchCount": .integer(1)]),
    ]
    for phase in ownerPhases {
      variants.append((phase, ["phase": .string(phase), "newDispatchCount": .integer(0)]))
      variants.append((phase + "/1", ["phase": .string(phase), "newDispatchCount": .integer(1)]))
    }
    let transports: [(String, AgentClientError, String)] = [
      ("connectFailed", .connectFailed("connect failed: errno 61"), "connect failed: errno 61"),
      ("lostResponse", .transport("connection closed before response"),
       "connection closed before response"),
      ("malformedResponse", .malformedResponse("response id mismatch"), "response id mismatch"),
      ("deadlineExceeded", .deadlineExceeded,
       "the client wait deadline expired; no cancellation was requested"),
    ]
    var profiles: [String: JSONValue] = [:]
    var profileNames: [Data: String] = [:]
    var methodProfiles: [String: JSONValue] = [:]
    for method in CLIControlMethodRegistry.classifiedMethods.sorted() {
      var transport: [String: JSONValue] = [:]
      for (name, failure, words) in transports {
        let error = CLIRuntimeSession.mapped(failure, method: method, command: method)
        XCTAssertEqual(error.message, words, "\(method) \(name)")
        XCTAssertEqual(error.details, ["method": .string(method)], "\(method) \(name)")
        transport[name] = .string(error.code.rawValue)
      }
      var refusals: [String: JSONValue] = [:]
      for wireCode in wireCodes {
        let unproven = refusal(wireCode, details: nil, method: method)
        var answers: [String: JSONValue] = ["none": .string(unproven)]
        for (name, details) in variants {
          let code = refusal(wireCode, details: details, method: method)
          if name == "preAdmission" || code != unproven { answers[name] = .string(code) }
        }
        refusals[wireCode] = .object(answers)
      }
      let effect: String =
        CLIControlMethodRegistry.effect(of: method) == .boundedReadOnly
        ? "boundedReadOnly" : "mutationCapable"
      let profile = JSONValue.object([
        "effect": .string(effect), "transport": .object(transport), "refusals": .object(refusals),
      ])
      let key = try encoder.encode(profile)
      let name: String
      if let known = profileNames[key] {
        name = known
      } else {
        name = String(format: "p%02ld", profileNames.count + 1)
        profileNames[key] = name
        profiles[name] = profile
      }
      methodProfiles[method] = .string(name)
    }
    return .object([
      "wireCodes": .array(wireCodes.map(JSONValue.string)),
      "ownerPhases": .array(ownerPhases.map(JSONValue.string)),
      "profiles": .object(profiles),
      "methods": .object(methodProfiles),
    ])
  }

  /// Swift's code for the Runtime's refusal `wireCode` of `method`, with
  /// `details` as its evidence; its words and details are checked here.
  private static func refusal(_ wireCode: String, details: [String: JSONValue]?, method: String)
    -> String
  {
    let failure: AgentClientError =
      if let details {
        .structuredDaemonError(code: wireCode, message: "refused", details: details)
      } else {
        .daemonError(code: wireCode, message: "refused")
      }
    let error = CLIRuntimeSession.mapped(failure, method: method, command: method)
    var expected = details ?? [:]
    expected["method"] = .string(method)
    expected["wireCode"] = .string(wireCode)
    XCTAssertEqual(error.message, "refused", "\(method) \(wireCode)")
    XCTAssertEqual(error.details, expected, "\(method) \(wireCode)")
    return error.code.rawValue
  }
}
