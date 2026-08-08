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
        "capture.diagnostics@1/capture-crash-index": CatalogActionReference(
          catalogID: "arkdeck-diagnostics", actionID: "crashIndex"),
        "capture.diagnostics@1/capture-crash-log": CatalogActionReference(
          catalogID: "arkdeck-diagnostics", actionID: "crashLog"),
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
        "port-forward.create@1/read-evidence-model": CatalogActionReference(
          catalogID: "arkdeck-remote-operations", actionID: "deviceModel"),
        "port-forward.create@1/read-evidence-firmware": CatalogActionReference(
          catalogID: "arkdeck-remote-operations", actionID: "firmwareBuild"),
        "port-forward.remove@1/read-evidence-model": CatalogActionReference(
          catalogID: "arkdeck-remote-operations", actionID: "deviceModel"),
        "port-forward.remove@1/read-evidence-firmware": CatalogActionReference(
          catalogID: "arkdeck-remote-operations", actionID: "firmwareBuild"),
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

final class CompleteOverwriteRecoveryCatalogContractTests: XCTestCase {
  func testDAYU200ProfilesPublishExactClosedRecoveryCoverage() throws {
    let operation = try XCTUnwrap(
      RuntimeOperationCatalog.descriptor(reference: "flash.dayu200@1"))
    let recovery = try XCTUnwrap(operation.completeOverwriteRecovery)
    XCTAssertEqual(recovery.contractVersion, "1.0.0")
    XCTAssertEqual(recovery.overwriteStepID, "flash-partitions")
    XCTAssertEqual(
      recovery.verificationStepIDs,
      [
        "verify-flash-readback", "reboot-device", "wait-for-hdc",
        "rebind-and-verify-build",
      ])
    XCTAssertEqual(
      recovery.profile(reference: "dayu200@1")?.coveredEffects,
      [
        "partition:uboot", "partition:boot_linux", "partition:system",
        "partition:vendor", "partition:userdata", "partition:resource",
        "partition:ramdisk", "partition:misc", "partition:parameter",
      ])
    XCTAssertEqual(
      recovery.profile(reference: "dayu200@2")?.coveredEffects,
      [
        "partition:uboot", "partition:resource", "partition:boot_linux",
        "partition:ramdisk", "partition:system", "partition:vendor",
        "partition:updater", "partition:chip_ckm", "partition:userdata",
      ])
    XCTAssertNil(recovery.profile(reference: "dayu200@3"))
    XCTAssertEqual(
      operation.steps.first(where: { $0.stepID == recovery.overwriteStepID })?.effect,
      .destructive)
  }
}
