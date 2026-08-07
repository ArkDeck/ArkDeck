import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class UIDumpApplicationFacadeContractTests: XCTestCase {
  func testCatalogProjectsExactlyFourCanonicalCandidateRecipes() {
    XCTAssertEqual(
      UIDumpRecipeCatalog.definitions.map(\.id),
      [.nodeSummary, .elementTree, .fullDefaultTree, .componentDetail])
    XCTAssertEqual(
      UIDumpRecipeCatalog.definition(.nodeSummary).displayArguments(
        windowID: "42", componentID: nil),
      "-w 42 -default")
    XCTAssertEqual(
      UIDumpRecipeCatalog.definition(.elementTree).displayArguments(
        windowID: "42", componentID: nil),
      "-w 42 -element -c")
    XCTAssertEqual(
      UIDumpRecipeCatalog.definition(.fullDefaultTree).displayArguments(
        windowID: "42", componentID: nil),
      "-w 42 -default -all")
    XCTAssertEqual(
      UIDumpRecipeCatalog.definition(.componentDetail).displayArguments(
        windowID: "42", componentID: "73"),
      "-w 42 -element -lastpage 73")
    XCTAssertFalse(UIDumpRecipeCatalog.definition(.nodeSummary).requiresComponentID)
    XCTAssertTrue(UIDumpRecipeCatalog.definition(.componentDetail).requiresComponentID)
  }

  func testIdentifierValidatorAcceptsOnlyBoundedDecimalIdentifiers() {
    XCTAssertEqual(UIDumpIdentifierValidator.validate("0"), .valid("0"))
    XCTAssertEqual(UIDumpIdentifierValidator.validate("1234567890"), .valid("1234567890"))
    XCTAssertEqual(UIDumpIdentifierValidator.validate(""), .invalid(.missing))
    XCTAssertEqual(UIDumpIdentifierValidator.validate("-w"), .invalid(.notDecimal))
    XCTAssertEqual(UIDumpIdentifierValidator.validate(" 42"), .invalid(.notDecimal))
    XCTAssertEqual(UIDumpIdentifierValidator.validate("42\n"), .invalid(.notDecimal))
    XCTAssertEqual(UIDumpIdentifierValidator.validate("42;id"), .invalid(.notDecimal))
    XCTAssertEqual(
      UIDumpIdentifierValidator.validate("123456789012345678901"),
      .invalid(.tooLong))
  }

  func testPublishedOperationFactsDoNotPretendCanonicalRecipeInputsExist() {
    let operation = UIDumpApplicationFacade.operationPresentation(availability: .available)

    XCTAssertEqual(operation.reference, "capture.diagnostics@1")
    XCTAssertTrue(operation.supportsWindowInventory)
    XCTAssertTrue(operation.supportsScreenComponentTree)
    XCTAssertFalse(operation.supportsCanonicalWindowRecipes)
    XCTAssertFalse(operation.inputNames.contains("recipeId"))
    XCTAssertFalse(operation.inputNames.contains("windowId"))
    XCTAssertFalse(operation.inputNames.contains("componentId"))
  }

  func testWorkspaceDecoderPreservesCompleteRuntimeFacts() throws {
    let presentation = UIDumpWorkspaceResponseDecoding.presentation(
      operationResponse: .success(
        try response([
          [
            "reference": "capture.diagnostics@1",
            "availability": "available",
            "reasons": [],
          ]
        ])),
      targetResponse: .success(
        try response([
          [
            "targetId": "target-a",
            "bindingRevision": 7,
            "toolVersion": "3.2.0f",
            "adoptedAtUtc": "2026-08-06T08:00:00Z",
          ]
        ])),
      jobResponse: .success(
        try response([
          [
            "jobId": "job-ui-dump",
            "operation": "capture.diagnostics@1",
            "targetId": "target-a",
            "state": "waitingForHuman",
            "waitingForHuman": true,
            "outcomeUnknown": false,
            "outstandingResidueCount": 1,
          ],
          [
            "jobId": "job-other",
            "operation": "debug.logs@1",
            "targetId": "target-a",
            "state": "succeeded",
            "waitingForHuman": false,
            "outcomeUnknown": false,
            "outstandingResidueCount": 0,
          ],
        ])))

    XCTAssertEqual(presentation.operation.availability, .available)
    XCTAssertEqual(
      presentation.targets,
      [
        UIDumpTargetPresentation(
          id: "target-a", bindingRevision: 7, toolVersion: "3.2.0f",
          adoptedAtUTC: "2026-08-06T08:00:00Z")
      ])
    XCTAssertEqual(presentation.relatedJobs.count, 1)
    XCTAssertEqual(presentation.relatedJobs.first?.id, "job-ui-dump")
    XCTAssertEqual(presentation.relatedJobs.first?.needsAttention, true)
    XCTAssertNil(presentation.targetLoadFailure)
    XCTAssertNil(presentation.jobLoadFailure)
  }

  func testMalformedRuntimeFactsFailClosed() throws {
    let presentation = UIDumpWorkspaceResponseDecoding.presentation(
      operationResponse: .success(
        try response([
          [
            "reference": "capture.diagnostics@1",
            "availability": "available",
          ]
        ])),
      targetResponse: .success(
        try response([
          ["targetId": "unbound"]
        ])),
      jobResponse: .success(
        try response([
          [
            "jobId": "incomplete",
            "operation": "capture.diagnostics@1",
          ]
        ])))

    XCTAssertEqual(
      presentation.operation.availability,
      .unavailable(reasons: ["capture.diagnostics@1 is missing complete availability facts"]))
    XCTAssertTrue(presentation.targets.isEmpty)
    XCTAssertTrue(presentation.relatedJobs.isEmpty)
    XCTAssertEqual(
      presentation.targetLoadFailure,
      "Runtime returned a target without complete binding facts")
    XCTAssertEqual(
      presentation.jobLoadFailure,
      "Runtime returned an incomplete diagnostics job")
  }

  func testAppFacadeExposesOneReadAndNoMutationTransport() throws {
    let protocolSource = try source(
      "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/UIDumpApplicationFacade.swift")
    let protocolBody = try XCTUnwrap(
      protocolSource.split(separator: "public protocol UIDumpApplicationProviding", maxSplits: 1)
        .last?.split(separator: "public enum UIDumpApplicationFacade", maxSplits: 1).first)

    XCTAssertTrue(protocolBody.contains("refreshWorkspace"))
    XCTAssertFalse(protocolBody.contains("submit"))
    XCTAssertFalse(protocolBody.contains("cancel"))
    XCTAssertFalse(protocolBody.contains("export"))
    XCTAssertTrue(protocolSource.contains("method: \"operation.list\""))
    XCTAssertTrue(protocolSource.contains("method: \"target.list\""))
    XCTAssertTrue(protocolSource.contains("method: \"job.list\""))
    for forbidden in [
      "method: \"job.submit\"", "method: \"job.cancel\"",
      "method: \"artifact.import\"", "method: \"artifact.export\"",
    ] {
      XCTAssertFalse(protocolSource.contains(forbidden), forbidden)
    }
  }

  func testAppRoutesUIDumpToItsWorkspaceAndKeepsDispatchLocked() throws {
    let appSource = try source("ArkDeckApp/App/ArkDeckApp.swift")
    let viewSource = try source("ArkDeckApp/Features/UIDump/UIDumpWorkspaceView.swift")

    XCTAssertTrue(appSource.contains("case .uiDump:\n      UIDumpWorkspaceView"))
    XCTAssertTrue(
      viewSource.contains(
        "String.LocalizationValue(key), table: \"UIDumpLocalizable\""))
    XCTAssertTrue(viewSource.contains("Button(string(\"uiDump.action.run\")) {}"))
    XCTAssertTrue(viewSource.contains(".disabled(true)"))
    XCTAssertFalse(viewSource.contains("job.submit"))
    XCTAssertFalse(viewSource.contains("artifact.import"))
    XCTAssertFalse(viewSource.contains("renderTreeLegacy"))
  }

  func testNamedLocalizationCatalogCoversBothSupportedLanguagesAndScopeLabels() throws {
    let data = try Data(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Resources/UIDumpLocalizable.xcstrings"))
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try XCTUnwrap(object["strings"] as? [String: Any])
    let requiredKeys = [
      "uiDump.recipe.nodeSummary.name",
      "uiDump.recipe.elementTree.name",
      "uiDump.recipe.fullDefaultTree.name",
      "uiDump.recipe.componentDetail.name",
      "uiDump.policy.unchanged.name",
      "uiDump.policy.temporaryRestore.name",
      "uiDump.policy.persistentlyEnabled.name",
      "uiDump.scope.arkui",
      "uiDump.scope.crash",
      "uiDump.scope.system",
      "uiDump.scope.notMVP",
      "uiDump.scope.note",
    ]

    for key in requiredKeys {
      let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
      let localizations = try XCTUnwrap(
        entry["localizations"] as? [String: Any], key)
      XCTAssertNotNil(localizations["en"], key)
      XCTAssertNotNil(localizations["zh-Hans"], key)
    }
  }

  private func response(_ result: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["id": "test", "ok": true, "result": result])
  }

  private func source(_ relativePath: String) throws -> String {
    try String(contentsOf: repository.appending(path: relativePath), encoding: .utf8)
  }

  private var repository: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
