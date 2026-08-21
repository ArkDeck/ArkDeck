import Foundation
import XCTest

@testable import ArkDeckLaunchAgent
@testable import ArkDeckWorkflows
@testable import ArkForgeClient

/// The one-release-unit install boundary for the ArkForge lane.
final class ArkForgeLaneInstallContractTests: XCTestCase {
  private var root: URL!
  private var fixture: ArkForgeBundleFixture!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-lane-install-\(UUID().uuidString)", directoryHint: .isDirectory)
    fixture = try makeArkForgeBundle(at: root.appending(path: "ArkForge.bundle"))
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testOneBundlePathCarriesTheMeasuredReleaseIdentity() throws {
    let status = try LaunchAgentArkForgeLaneStatus.measuring(bundlePath: fixture.root.path)

    XCTAssertEqual(status.bundlePath, fixture.root.path)
    XCTAssertEqual(status.manifestSHA256, fixture.manifestSHA256)
    XCTAssertEqual(status.daemonPath, fixture.daemon.path)
    XCTAssertEqual(status.daemonSHA256, fixture.daemonSHA256)
    XCTAssertEqual(status.deviceProfilePath, fixture.profile.path)
    XCTAssertEqual(
      status.environment,
      [ArkDeckLaunchAgent.arkForgeBundleEnvironmentKey: fixture.root.path])
  }

  func testWithoutACampaignTheDaemonIsStartedGated() throws {
    let status = try LaunchAgentArkForgeLaneStatus.measuring(bundlePath: fixture.root.path)
    guard case .success(let inputs) = ArkForgeLaneComposition.Inputs.read(status.environment)
    else { return XCTFail("a measured bundle must compose") }

    XCTAssertEqual(status.campaign, "")
    XCTAssertFalse(
      ArkForgeLaneComposition.daemonArguments(
        inputs: inputs, runtimeDirectory: root, pairingEpoch: 1
      ).contains("--hardware-campaign"))
  }

  func testANamedCampaignRemainsASeparateAuthorizationInput() throws {
    let status = try LaunchAgentArkForgeLaneStatus.measuring(
      bundlePath: fixture.root.path, campaign: " AFA-AC-7 ")
    guard case .success(let inputs) = ArkForgeLaneComposition.Inputs.read(status.environment)
    else { return XCTFail("a measured bundle must compose") }

    XCTAssertEqual(status.campaign, "AFA-AC-7")
    let arguments = ArkForgeLaneComposition.daemonArguments(
      inputs: inputs, runtimeDirectory: root, pairingEpoch: 1)
    let index = try XCTUnwrap(arguments.firstIndex(of: "--hardware-campaign"))
    XCTAssertEqual(arguments[index + 1], "AFA-AC-7")
  }

  func testMemberDriftIsRefusedBeforeThePlistCanBeWritten() throws {
    try Data("different daemon".utf8).write(to: fixture.daemon)
    XCTAssertThrowsError(
      try LaunchAgentArkForgeLaneStatus.measuring(bundlePath: fixture.root.path)
    ) { error in
      XCTAssertTrue("\(error)".contains("ArkForge.bundle is invalid"), "\(error)")
      XCTAssertTrue("\(error)".contains("expected"), "\(error)")
    }
  }

  func testASymlinkedBundleRootIsRefused() throws {
    let alias = root.appending(path: "ArkForge-alias.bundle")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
    XCTAssertThrowsError(
      try LaunchAgentArkForgeLaneStatus.measuring(bundlePath: alias.path)
    ) { error in
      XCTAssertTrue("\(error)".contains("symbolic link"), "\(error)")
    }
  }

  func testARelativeBundlePathIsRefused() {
    XCTAssertThrowsError(
      try LaunchAgentArkForgeLaneStatus.measuring(bundlePath: "ArkForge.bundle")
    ) { error in
      XCTAssertEqual(
        error as? LaunchAgentArkForgeLaneStatus.Refusal,
        .notAbsolute("ArkForge.bundle"))
    }
  }

  func testTheInstallerAndLaneShareExactlyOneCurrentKey() throws {
    let installed = try LaunchAgentArkForgeLaneStatus.measuring(bundlePath: fixture.root.path)
    XCTAssertEqual(
      ArkDeckLaunchAgent.arkForgeEnvironmentKeys,
      [ArkForgeLaneComposition.EnvironmentKey.bundlePath])
    XCTAssertEqual(Set(installed.environment.keys), Set(ArkDeckLaunchAgent.arkForgeEnvironmentKeys))
    guard case .success(let inputs) = ArkForgeLaneComposition.Inputs.read(installed.environment)
    else { return XCTFail("what the installer writes must be what the lane accepts") }
    XCTAssertEqual(inputs.daemonPath, fixture.daemon.path)
    XCTAssertEqual(inputs.expectedToolchain.sha256, fixture.daemonSHA256)
  }

  func testTheDaemonRefusesLegacyOrMixedConfiguration() {
    let legacy = [
      "ARKDECK_ARKFORGED_PATH": fixture.daemon.path,
      "ARKDECK_ARKFORGED_SHA256": fixture.daemonSHA256,
      "ARKDECK_ARKFORGE_PROFILE_PATH": fixture.profile.path,
    ]
    XCTAssertEqual(
      ArkForgeLaneComposition.Inputs.read(legacy), .failure(.legacyConfiguration))
    XCTAssertEqual(
      ArkForgeLaneComposition.Inputs.read(legacy.merging(fixture.environment) { _, new in new }),
      .failure(.mixedConfiguration))
  }

  func testAnUndeclaredFileIsRefusedAsCrossReleaseAssembly() throws {
    try Data("shadow".utf8).write(
      to: fixture.root.appending(path: "Contents/MacOS/arkforged-shadow"))
    XCTAssertThrowsError(
      try LaunchAgentArkForgeLaneStatus.measuring(bundlePath: fixture.root.path)
    ) { error in
      XCTAssertTrue("\(error)".contains("undeclared member"), "\(error)")
    }
  }
}
