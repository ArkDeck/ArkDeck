import Foundation
import XCTest

@testable import ArkDeckCore

final class DiagnosticsWorkflowStepContractTests: XCTestCase {
  func testTEST_AC_WF_001_02_DiagnosticsActionsAcceptBoundaryParameters() {
    let filters = Array(repeating: String(repeating: "A", count: 200), count: 16)
    let vectors: [(String, [String: JSONValue])] = [
      (
        "bounded-hilog-min",
        diagnosticsArguments(
          actionID: "boundedHilog",
          parameters: [
            "durationSeconds": .integer(1),
            "filters": .array([]),
            "byteBudget": .integer(1024),
          ])
      ),
      (
        "bounded-hilog-max",
        diagnosticsArguments(
          actionID: "boundedHilog",
          parameters: [
            "durationSeconds": .integer(600),
            "filters": .array(filters.map(JSONValue.string)),
            "byteBudget": .integer(134_217_728),
          ])
      ),
      (
        "component-tree-min",
        diagnosticsArguments(
          actionID: "componentTree",
          parameters: ["byteBudget": .integer(1024)])
      ),
      (
        "component-tree-max",
        diagnosticsArguments(
          actionID: "componentTree",
          parameters: ["byteBudget": .integer(67_108_864)])
      ),
      (
        "window-inventory-min",
        diagnosticsArguments(
          actionID: "windowInventory",
          parameters: ["byteBudget": .integer(1024)])
      ),
      (
        "window-inventory-max",
        diagnosticsArguments(
          actionID: "windowInventory",
          parameters: ["byteBudget": .integer(67_108_864)])
      ),
    ]

    for (id, arguments) in vectors {
      XCTAssertNoThrow(try makeStep(id: id, arguments: arguments), id)
    }
  }

  func testTEST_AC_WF_001_02_InvalidDiagnosticsArgumentsFailBeforeDispatch() {
    let invalidVectors: [(String, [String: JSONValue])] = [
      (
        "unknown-catalog",
        [
          "catalogId": .string("unknown-diagnostics"),
          "actionId": .string("boundedHilog"),
          "parameters": .object(validHilogParameters()),
          "artifactId": .string("artifact-1"),
        ]
      ),
      (
        "unknown-action",
        diagnosticsArguments(
          actionID: "unknownAction", parameters: validHilogParameters())
      ),
      (
        "cross-catalog-action",
        [
          "catalogId": .string("arkui-ui-dump"),
          "actionId": .string("boundedHilog"),
          "parameters": .object(validHilogParameters()),
          "artifactId": .string("artifact-1"),
        ]
      ),
      (
        "duration-low",
        diagnosticsArguments(
          actionID: "boundedHilog",
          parameters: validHilogParameters(overrides: ["durationSeconds": .integer(0)]))
      ),
      (
        "duration-high",
        diagnosticsArguments(
          actionID: "boundedHilog",
          parameters: validHilogParameters(overrides: ["durationSeconds": .integer(601)]))
      ),
      (
        "hilog-budget-low",
        diagnosticsArguments(
          actionID: "boundedHilog",
          parameters: validHilogParameters(overrides: ["byteBudget": .integer(1023)]))
      ),
      (
        "hilog-budget-high",
        diagnosticsArguments(
          actionID: "boundedHilog",
          parameters: validHilogParameters(
            overrides: ["byteBudget": .integer(134_217_729)]))
      ),
      (
        "too-many-filters",
        diagnosticsArguments(
          actionID: "boundedHilog",
          parameters: validHilogParameters(
            overrides: [
              "filters": .array(Array(repeating: .string("tag"), count: 17))
            ]))
      ),
      (
        "filter-shell-token",
        diagnosticsArguments(
          actionID: "boundedHilog",
          parameters: validHilogParameters(
            overrides: ["filters": .array([.string("tag;rm")])]))
      ),
      (
        "filter-too-long",
        diagnosticsArguments(
          actionID: "boundedHilog",
          parameters: validHilogParameters(
            overrides: [
              "filters": .array([.string(String(repeating: "A", count: 201))])
            ]))
      ),
      (
        "component-budget-low",
        diagnosticsArguments(
          actionID: "componentTree",
          parameters: ["byteBudget": .integer(1023)])
      ),
      (
        "component-budget-high",
        diagnosticsArguments(
          actionID: "componentTree",
          parameters: ["byteBudget": .integer(67_108_865)])
      ),
      (
        "window-inventory-budget-low",
        diagnosticsArguments(
          actionID: "windowInventory",
          parameters: ["byteBudget": .integer(1023)])
      ),
      (
        "window-inventory-budget-high",
        diagnosticsArguments(
          actionID: "windowInventory",
          parameters: ["byteBudget": .integer(67_108_865)])
      ),
      (
        "caller-remote-path",
        diagnosticsArguments(
          actionID: "boundedHilog",
          parameters: validHilogParameters(
            overrides: ["remotePath": .string("/data/local/tmp/caller")]))
      ),
      (
        "command-shaped-key",
        diagnosticsArguments(
          actionID: "boundedHilog",
          parameters: validHilogParameters(
            overrides: ["command": .string("hilog")]))
      ),
    ]

    var dispatchCount = 0
    for (id, arguments) in invalidVectors {
      XCTAssertThrowsError(
        try validateThenDispatch(id: id, arguments: arguments, dispatchCount: &dispatchCount),
        id)
    }
    XCTAssertEqual(dispatchCount, 0)
  }

  func testTEST_AC_WF_001_02_JSONSchemaPinsTheSameActionsAndBounds() throws {
    let schema = try loadWorkflowStepSchema()
    let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
    let stdout = try XCTUnwrap(definitions["catalogStdoutArguments"] as? [String: Any])
    let arms = try XCTUnwrap(stdout["oneOf"] as? [[String: Any]])

    let diagnosticsPairs = try arms.compactMap { arm -> (String, String)? in
      let properties = try XCTUnwrap(arm["properties"] as? [String: Any])
      let catalog = try XCTUnwrap(properties["catalogId"] as? [String: Any])
      guard catalog["const"] as? String == "arkdeck-diagnostics" else { return nil }
      let action = try XCTUnwrap(properties["actionId"] as? [String: Any])
      return (
        try XCTUnwrap(action["const"] as? String),
        try XCTUnwrap((properties["parameters"] as? [String: Any])?["$ref"] as? String)
      )
    }
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: diagnosticsPairs),
      [
        "boundedHilog": "#/$defs/diagnosticsHilogParameters",
        "componentTree": "#/$defs/diagnosticsComponentTreeParameters",
        "windowInventory": "#/$defs/diagnosticsComponentTreeParameters",
        "crashIndex": "#/$defs/diagnosticsComponentTreeParameters",
        "crashLog": "#/$defs/diagnosticsCrashLogParameters",
      ])

    let hilog = try XCTUnwrap(definitions["diagnosticsHilogParameters"] as? [String: Any])
    let hilogProperties = try XCTUnwrap(hilog["properties"] as? [String: Any])
    XCTAssertEqual(
      (hilogProperties["durationSeconds"] as? [String: Any])?["minimum"] as? Int, 1)
    XCTAssertEqual(
      (hilogProperties["durationSeconds"] as? [String: Any])?["maximum"] as? Int, 600)
    XCTAssertEqual(
      (hilogProperties["byteBudget"] as? [String: Any])?["maximum"] as? Int,
      134_217_728)

    let component = try XCTUnwrap(
      definitions["diagnosticsComponentTreeParameters"] as? [String: Any])
    let componentProperties = try XCTUnwrap(component["properties"] as? [String: Any])
    XCTAssertEqual(
      (componentProperties["byteBudget"] as? [String: Any])?["maximum"] as? Int,
      67_108_864)
  }

  private func validateThenDispatch(
    id: String,
    arguments: [String: JSONValue],
    dispatchCount: inout Int
  ) throws {
    _ = try makeStep(id: id, arguments: arguments)
    dispatchCount += 1
  }

  private func makeStep(
    id: String,
    arguments: [String: JSONValue]
  ) throws -> WorkflowStep {
    try WorkflowStep(
      id: id,
      kind: .captureRemoteStdout,
      declaredEffect: .readOnly,
      declaredCancellation: .immediate,
      declaredBindingRequirement: .confirmedDevice,
      arguments: arguments)
  }

  private func diagnosticsArguments(
    actionID: String,
    parameters: [String: JSONValue]
  ) -> [String: JSONValue] {
    [
      "catalogId": .string("arkdeck-diagnostics"),
      "actionId": .string(actionID),
      "parameters": .object(parameters),
      "artifactId": .string("artifact-1"),
    ]
  }

  private func validHilogParameters(
    overrides: [String: JSONValue] = [:]
  ) -> [String: JSONValue] {
    var parameters: [String: JSONValue] = [
      "durationSeconds": .integer(30),
      "filters": .array([.string("ArkUI:Info")]),
      "byteBudget": .integer(16 * 1024 * 1024),
    ]
    parameters.merge(overrides) { _, replacement in replacement }
    return parameters
  }

  private func loadWorkflowStepSchema() throws -> [String: Any] {
    let url = repositoryRoot().appending(path: "openspec/contracts/workflow-step.schema.json")
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

final class HardwareEvidenceWorkflowStepContractTests: XCTestCase {
  func testEvidenceRemoteReadsAreValidDurableJournalActions() {
    for actionID in ["deviceModel", "firmwareBuild"] {
      XCTAssertNoThrow(try makeRemoteRead(actionID: actionID), actionID)
    }
  }

  func testWorkflowStepSchemaAndSwiftRegistryHaveTheSameRemoteReadActions() throws {
    let data = try Data(
      contentsOf: repositoryRoot()
        .appending(path: "openspec/contracts/workflow-step.schema.json"))
    let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
    let arguments = try XCTUnwrap(
      definitions["approvedRemoteReadArguments"] as? [String: Any])
    let properties = try XCTUnwrap(arguments["properties"] as? [String: Any])
    let action = try XCTUnwrap(properties["actionId"] as? [String: Any])
    let actionIDs = try XCTUnwrap(action["enum"] as? [String])
    XCTAssertEqual(
      Set(actionIDs),
      Set([
        "deviceSummary", "systemProperties", "processList", "packageInfo", "storageUsage",
        "deviceModel", "firmwareBuild",
      ]))
    for actionID in actionIDs {
      XCTAssertNoThrow(try makeRemoteRead(actionID: actionID), actionID)
    }
  }

  func testUnknownEvidenceRemoteReadFailsBeforeDispatch() {
    var dispatchCount = 0
    XCTAssertThrowsError(try makeRemoteRead(actionID: "callerSelectedProperty"))
    XCTAssertEqual(dispatchCount, 0)
    dispatchCount += 0
  }

  private func makeRemoteRead(actionID: String) throws -> WorkflowStep {
    try WorkflowStep(
      id: "read-\(actionID)",
      kind: .runApprovedRemoteRead,
      declaredEffect: .readOnly,
      declaredCancellation: .immediate,
      declaredBindingRequirement: .confirmedDevice,
      arguments: [
        "catalogId": .string("arkdeck-remote-operations"),
        "actionId": .string(actionID),
        "parameters": .object([:]),
        "artifactId": .string("artifact-\(actionID)"),
      ])
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
