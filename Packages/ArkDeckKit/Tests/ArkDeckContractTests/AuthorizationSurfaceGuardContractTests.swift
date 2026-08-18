import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// Source-shape guards on the caller-facing authorization surfaces.
///
/// The standing-authorization admission service this suite also covered was
/// retired with its lane and ledger (T25/W3), and its tests went with it.
/// This one stays because what it guards is still live: no caller-facing
/// surface may inject trusted facts or obtain a command, and no flash
/// subcommand may regain an in-process execution stack.
final class AuthorizationSurfaceGuardContractTests: XCTestCase {
  func testCallerFacingSurfacesCannotInjectFactsOrObtainCommands() throws {
    let packageRoot = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let workflowSource = try String(
      contentsOf: packageRoot.appending(
        path:
          "Sources/ArkDeckWorkflows/RockchipFlashAuthorization.swift"), encoding: .utf8)
    let cliSource = try String(
      contentsOf: packageRoot.appending(
        path:
          "Sources/ArkDeckCLI/ArkDeckCLIMain.swift"), encoding: .utf8)

    for forbidden in [
      "RockchipStanding" + "AuthorizationContext", "RockchipUnattended" + "ExecutionIntent",
      "authorizedForUnattended" + "AgentExecution", "runUnattended" + "Execute",
      "CLIUnattended" + "Context",
    ] {
      XCTAssertFalse(workflowSource.contains(forbidden), forbidden)
      XCTAssertFalse(cliSource.contains(forbidden), forbidden)
    }
    XCTAssertFalse(cliSource.contains("-" + "-unattended-context"))
    XCTAssertFalse(cliSource.contains("-" + "-authorization <"))
    let runFlashStart = try XCTUnwrap(
      cliSource.range(of: "static func runFlash(_ arguments: [String]) async throws"))
    let reconcileStart = try XCTUnwrap(
      cliSource.range(
        of: "// MARK: reconcile", range: runFlashStart.upperBound..<cliSource.endIndex))
    let activeFlashSurface = cliSource[runFlashStart.lowerBound..<reconcileStart.lowerBound]
    XCTAssertFalse(activeFlashSurface.contains("--authorization-id"))
    XCTAssertTrue(activeFlashSurface.contains("historical campaign preview is retired"))
    XCTAssertTrue(activeFlashSurface.contains("Runtime owns Flash admission"))
    XCTAssertTrue(activeFlashSurface.contains("historical campaign continuation is retired"))
    XCTAssertFalse(activeFlashSurface.contains("runCampaignPreview("))
    XCTAssertFalse(activeFlashSurface.contains("runExecute("))
    XCTAssertFalse(activeFlashSurface.contains("runCampaignContinue("))
    // `authorizeUnattended` was the standing lane's internal bridge; it went
    // with that lane (T25/W3). The guard that replaces it: nothing may bring
    // an unattended standing execution back into this process.
    XCTAssertFalse(workflowSource.contains("func authorizeUnattended("))
    XCTAssertFalse(cliSource.contains("RockchipFlashExecutionHost"))

    let factsSource = try String(
      contentsOf: packageRoot.appending(
        path:
          "Sources/ArkDeckWorkflows/RockchipAuthorizationFacts.swift"), encoding: .utf8)
    XCTAssertTrue(factsSource.contains("attempt.observations.count == 1"))
    XCTAssertTrue(
      factsSource.contains("plan: plan, executableIdentity: toolDevice.executableIdentity"))
    XCTAssertFalse(factsSource.contains("struct RockchipTrustedAuthorizationFacts: Codable"))
  }

  func testNRU004ProductRuntimeHasNoVendorToolReference() throws {
    let packageRoot = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let runtimeFiles = [
      "LaunchAgents/LaunchAgentService.swift",
      "Sources/ArkDeckAgentDaemonMain/main.swift",
      "Sources/ArkDeckCLI/ArkDeckCLIMain.swift",
      "Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift",
      "Sources/ArkDeckWorkflows/ArkForgeLaneComposition.swift",
      "Sources/ArkDeckWorkflows/ArkForgeControlPerformer.swift",
      "Sources/ArkDeckWorkflows/RockchipDeviceAccessApplicationFacade.swift",
      "Sources/ArkDeckWorkflows/RockchipFlashPreflight.swift",
      "Sources/ArkDeckWorkflows/DeviceProviders/RockchipLiveModeProbe.swift",
      "Sources/ArkDeckWorkflows/DeviceProviders/RockchipRuntimeComposition.swift",
    ]
    for relativePath in runtimeFiles {
      let source = try String(
        contentsOf: packageRoot.appending(path: relativePath), encoding: .utf8)
      XCTAssertFalse(
        source.lowercased().contains("rkdeveloptool"),
        "\(relativePath) reintroduced the retired vendor tool into product Runtime")
    }

    let main = try String(
      contentsOf: packageRoot.appending(
        path: "Sources/ArkDeckAgentDaemonMain/main.swift"), encoding: .utf8)
    XCTAssertTrue(main.contains("ArkForgeNativeRockUSBExecutableResolver"), main)

    let repoRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent()
    let project = try String(
      contentsOf: repoRoot.appending(path: "ArkDeck.xcodeproj/project.pbxproj"), encoding: .utf8)
    XCTAssertTrue(project.contains("rkdeveloptool in Embed Rockchip Component"))
    let retirementDoc = try String(
      contentsOf: repoRoot.appending(
        path: "docs/release/rockchip-component-packaging.md"), encoding: .utf8)
    XCTAssertTrue(retirementDoc.contains("Maskrom rescue"), retirementDoc)
    XCTAssertTrue(retirementDoc.contains("Agentd never resolves, launches"), retirementDoc)
  }
}
