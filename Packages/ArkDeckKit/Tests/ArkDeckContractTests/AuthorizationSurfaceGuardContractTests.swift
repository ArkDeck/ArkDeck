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
    XCTAssertFalse(cli.contains("runExecute("))
    XCTAssertFalse(cli.contains("runPostflight("))
    XCTAssertFalse(cli.contains("RockchipFlashExecutionHost"))

    // The retired Flash verbs are declared once, in the command registry, and
    // answered before dispatch. This used to read the prose out of the CLI's
    // usage literal; the literal is gone because help is generated, so the
    // tripwire follows the tombstones to the file that now owns them.
    let registry = try String(
      contentsOf: packageRoot.appending(path: "Sources/ArkDeckCLI/CLICommandRegistry.swift"),
      encoding: .utf8)
    XCTAssertTrue(registry.contains("Runtime owns Flash admission"))
    XCTAssertTrue(registry.contains("historical campaigns are decode-only"))
    for retired in ["\"plan\"", "\"preview\"", "\"execute\"", "\"continue\"", "\"postflight\""] {
      XCTAssertTrue(
        registry.contains("token: \(retired)"),
        "the retired flash verb \(retired) must stay a named tombstone")
    }
    XCTAssertTrue(
      registry.contains("agent run --operation flash.full-restore@1"),
      "the retired executor must keep naming the Runtime-owned replacement")

    let composition = try String(
      contentsOf: packageRoot.appending(
        path: "Sources/ArkDeckWorkflows/DeviceProviders/RockchipRuntimeComposition.swift"),
      encoding: .utf8)
    XCTAssertTrue(composition.contains("ArkForgeNativeRockUSBExecutableResolver"))
    XCTAssertTrue(composition.contains("arkforged-native-rockusb"))
    XCTAssertTrue(composition.contains(#""rockusbBackend": "native""#))
  }

  func testTheRescueComponentIsFullyRetiredFromTheProject() throws {
    // CHG-2026-065: the Maskrom rescue rkdeveloptool left the App bundle,
    // the build, and CI. This used to assert the opposite (the embed phase
    // had to exist); the inversion is deliberate and the source tripwire
    // above still refuses any reintroduction of the executable by name.
    let packageRoot = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let repoRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent()
    let project = try String(
      contentsOf: repoRoot.appending(path: "ArkDeck.xcodeproj/project.pbxproj"),
      encoding: .utf8)
    XCTAssertFalse(project.contains("Embed Rockchip Component"))
    XCTAssertFalse(project.contains("ROCKCHIP_COMPONENT"))
    XCTAssertFalse(project.lowercased().contains("rkdeveloptool"))
    XCTAssertFalse(project.contains("RockchipComponent.entitlements"))

    for retiredPath in [
      ".github/workflows/rockchip-component.yml",
      "scripts/rockchip_component",
      "openspec/integrations/rockchip/bundled-component",
      "ArkDeckApp/RockchipComponent.entitlements",
    ] {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: repoRoot.appending(path: retiredPath).path),
        "\(retiredPath) should be gone with the rescue component")
    }

    let retirementDoc = try String(
      contentsOf: repoRoot.appending(
        path: "docs/release/rockchip-component-packaging.md"), encoding: .utf8)
    XCTAssertTrue(retirementDoc.contains("CHG-2026-065"), retirementDoc)
    XCTAssertTrue(retirementDoc.contains("已随分发停止而卸除"), retirementDoc)
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
