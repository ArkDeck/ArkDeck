import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// Source-shape guards for the completed ArkForge cutover. Current product
/// surfaces must not reconstruct the retired executable, its selection/trust
/// state, its argv, or a caller-owned admission path.
final class AuthorizationSurfaceGuardContractTests: XCTestCase {
  func testCurrentProductSourcesContainNoRetiredVendorToolSurface() throws {
    let packageRoot = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let repoRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent()

    var productFiles = try sourceFiles(
      below: packageRoot.appending(path: "Sources", directoryHint: .isDirectory),
      extensions: ["swift"])
    productFiles += try sourceFiles(
      below: repoRoot.appending(path: "ArkDeckApp", directoryHint: .isDirectory),
      extensions: ["swift", "xcstrings"])

    let retiredSymbols = [
      "RockchipProductToolBookmarkStore",
      "RockchipProductToolInstaller",
      "RockchipProductToolTrustInspector",
      "RockchipProductToolRuntimeDirectory",
      "RockchipDeviceDiscoveryAdapter",
      "RockchipDiscoveryIntegrationProfile",
      "RockchipSelectedDiscoveryTool",
      "RockchipProductionAdmissionPort",
      "RockchipEvolutionCampaignAdmissionService",
      "RockchipManualFlashFallbackGate",
      "RockchipHumanHandoff",
    ]
    for file in productFiles {
      let source = try String(contentsOf: file, encoding: .utf8)
      for symbol in retiredSymbols {
        XCTAssertFalse(source.contains(symbol), "\(file.path): \(symbol)")
      }
      if file.lastPathComponent != "SessionManifest.swift" {
        XCTAssertFalse(
          source.lowercased().contains("rkdeveloptool"),
          "\(file.path) reintroduced the retired vendor executable")
      }
    }

    let manifest = try String(
      contentsOf: packageRoot.appending(
        path: "Sources/ArkDeckStorage/SessionManifest.swift"), encoding: .utf8)
    XCTAssertTrue(manifest.contains("Read-only compatibility for already durable pre-ArkForge"))
    XCTAssertTrue(manifest.contains("legacyRockchipReportedVersion"))
    XCTAssertFalse(manifest.contains("RockchipProductTool"))
  }

  func testCLIAndRuntimeExposeOnlyRuntimeOwnedArkForgeAdmission() throws {
    let packageRoot = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let cli = try String(
      contentsOf: packageRoot.appending(path: "Sources/ArkDeckCLI/ArkDeckCLIMain.swift"),
      encoding: .utf8)
    XCTAssertTrue(cli.contains("Runtime owns Flash admission"))
    XCTAssertTrue(cli.contains("historical campaign continuation is retired"))
    XCTAssertTrue(cli.contains("legacy observation-file postflight is retired"))
    XCTAssertFalse(cli.contains("runExecute("))
    XCTAssertFalse(cli.contains("runPostflight("))
    XCTAssertFalse(cli.contains("RockchipFlashExecutionHost"))

    let composition = try String(
      contentsOf: packageRoot.appending(
        path: "Sources/ArkDeckWorkflows/DeviceProviders/RockchipRuntimeComposition.swift"),
      encoding: .utf8)
    XCTAssertTrue(composition.contains("ArkForgeNativeRockUSBExecutableResolver"))
    XCTAssertTrue(composition.contains("arkforged-native-rockusb"))
    XCTAssertTrue(composition.contains(#""rockusbBackend": "native""#))
  }

  func testOnlyMaskromRescuePackagingRetainsTheStandaloneArtifact() throws {
    let packageRoot = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let repoRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent()
    let project = try String(
      contentsOf: repoRoot.appending(path: "ArkDeck.xcodeproj/project.pbxproj"),
      encoding: .utf8)
    XCTAssertTrue(project.contains("rkdeveloptool in Embed Rockchip Component"))
    XCTAssertTrue(project.contains("ROCKCHIP_COMPONENT_INPUT"))

    let retirementDoc = try String(
      contentsOf: repoRoot.appending(
        path: "docs/release/rockchip-component-packaging.md"), encoding: .utf8)
    XCTAssertTrue(retirementDoc.contains("Maskrom rescue"), retirementDoc)
    XCTAssertTrue(retirementDoc.contains("Agentd never resolves, launches"), retirementDoc)
  }

  private func sourceFiles(
    below root: URL, extensions: Set<String>
  ) throws -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey])
    else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    return enumerator.compactMap { $0 as? URL }
      .filter { extensions.contains($0.pathExtension) }
  }
}
