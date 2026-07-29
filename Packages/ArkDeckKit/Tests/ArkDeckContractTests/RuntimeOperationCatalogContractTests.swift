import XCTest

@testable import ArkDeckCore

final class DiagnosticsRuntimeOperationCatalogContractTests: XCTestCase {
  func testTEST_AC_WF_001_02_EveryStdoutStepCarriesAnExactGeneratedActionReference() {
    var observed: [String: CatalogActionReference] = [:]

    for operation in RuntimeOperationCatalog.operations {
      for step in operation.steps {
        let key = "\(operation.reference)/\(step.stepID)"
        if step.kind == .captureRemoteStdout {
          guard let actionReference = step.actionReference else {
            return XCTFail("\(key) has no generated action reference")
          }
          observed[key] = actionReference
        } else {
          XCTAssertNil(
            step.actionReference,
            "\(key) must not carry a stdout action reference")
        }
      }
    }

    XCTAssertEqual(
      observed,
      [
        "capture.diagnostics@1/capture-hilog": CatalogActionReference(
          catalogID: "arkdeck-diagnostics", actionID: "boundedHilog"),
        "capture.diagnostics@1/capture-ui-dump": CatalogActionReference(
          catalogID: "arkdeck-diagnostics", actionID: "componentTree"),
        "debug.hap@1/capture-diagnostics": CatalogActionReference(
          catalogID: "arkdeck-diagnostics", actionID: "boundedHilog"),
        "flash.dayu200@1/capture-post-flash-diagnostics": CatalogActionReference(
          catalogID: "arkdeck-diagnostics", actionID: "boundedHilog"),
      ])
  }

  func testTEST_AC_WF_001_02_ActionReferenceIsIdentityOnly() {
    let mirror = Mirror(
      reflecting: CatalogActionReference(
        catalogID: "arkdeck-diagnostics", actionID: "boundedHilog"))
    XCTAssertEqual(
      Set(mirror.children.compactMap(\.label)),
      ["catalogID", "actionID"])
  }
}
