import XCTest

@testable import ArkDeckCore

final class DiagnosticsRuntimeOperationCatalogContractTests: XCTestCase {
  func testTEST_AC_WF_001_02_EveryStdoutStepCarriesAnExactGeneratedActionReference() {
    var observed: [String: CatalogActionReference] = [:]

    for operation in RuntimeOperationCatalog.operations {
      for step in operation.steps {
        let key = "\(operation.reference)/\(step.stepID)"
        if step.kind == .captureRemoteStdout
          || (step.kind == .runApprovedRemoteRead && step.actionReference != nil)
        {
          guard let actionReference = step.actionReference else {
            return XCTFail("\(key) has no generated action reference")
          }
          observed[key] = actionReference
        } else {
          XCTAssertNil(
            step.actionReference,
            "\(key) must not carry an action reference")
        }
      }
    }

    XCTAssertEqual(
      observed,
      [
        "capture.diagnostics@1/capture-hilog": CatalogActionReference(
          catalogID: "arkdeck-diagnostics", actionID: "boundedHilog"),
        "capture.diagnostics@1/capture-ui-dump": CatalogActionReference(
          catalogID: "arkdeck-diagnostics", actionID: "windowInventory"),
        "debug.hap@1/capture-diagnostics": CatalogActionReference(
          catalogID: "arkdeck-diagnostics", actionID: "boundedHilog"),
        "observe.device@1/read-evidence-model": CatalogActionReference(
          catalogID: "arkdeck-remote-operations", actionID: "deviceModel"),
        "observe.device@1/read-evidence-firmware": CatalogActionReference(
          catalogID: "arkdeck-remote-operations", actionID: "firmwareBuild"),
        "capture.diagnostics@1/read-evidence-model": CatalogActionReference(
          catalogID: "arkdeck-remote-operations", actionID: "deviceModel"),
        "capture.diagnostics@1/read-evidence-firmware": CatalogActionReference(
          catalogID: "arkdeck-remote-operations", actionID: "firmwareBuild"),
        "debug.hap@1/read-evidence-model": CatalogActionReference(
          catalogID: "arkdeck-remote-operations", actionID: "deviceModel"),
        "debug.hap@1/read-evidence-firmware": CatalogActionReference(
          catalogID: "arkdeck-remote-operations", actionID: "firmwareBuild"),
        "debug.hap@1/package-readback": CatalogActionReference(
          catalogID: "arkdeck-remote-operations", actionID: "packageInfo"),
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
