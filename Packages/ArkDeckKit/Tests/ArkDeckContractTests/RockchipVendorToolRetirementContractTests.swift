import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// A source-shape tripwire for the retired selection/bookmark/trust stack.
/// Current RockUSB discovery and execution are reachable only through ArkForge.
final class RockchipVendorToolRetirementContractTests: XCTestCase {
  func testRetiredToolSelectionTypesCannotReturnToWorkflowSources() throws {
    let packageRoot = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sourceRoot = packageRoot.appending(
      path: "Sources/ArkDeckWorkflows", directoryHint: .isDirectory)
    let files = try XCTUnwrap(
      FileManager.default.enumerator(
        at: sourceRoot, includingPropertiesForKeys: [.isRegularFileKey]))
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "swift" }
    let source = try files
      .map { try String(contentsOf: $0, encoding: .utf8) }
      .joined(separator: "\n")

    for symbol in [
      "RockchipProductToolBookmarkStore",
      "RockchipProductToolInstaller",
      "RockchipProductToolTrustInspector",
      "RockchipProductToolRuntimeDirectory",
      "RockchipDeviceDiscoveryAdapter",
      "RockchipDiscoveryIntegrationProfile",
      "RockchipSelectedDiscoveryTool",
      "RockchipProductionAdmissionPort",
    ] {
      XCTAssertFalse(source.contains(symbol), symbol)
    }
  }
}
