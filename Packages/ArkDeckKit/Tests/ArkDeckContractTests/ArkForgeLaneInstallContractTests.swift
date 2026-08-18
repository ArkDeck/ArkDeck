import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckLaunchAgent
@testable import ArkDeckWorkflows

/// The install entry point for the ArkForge lane.
///
/// Every input is measured rather than trusted. That discipline already
/// applies to the HDC path and the ArkTrace descriptor; it matters more here
/// because this executable performs destructive writes, and an
/// operator who mistypes a path should learn it at install time rather than
/// when a board is half-written.
final class ArkForgeLaneInstallContractTests: XCTestCase {

  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-lane-install-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  private func write(_ name: String, _ contents: String) throws -> (URL, String) {
    let url = root.appending(path: name)
    try Data(contents.utf8).write(to: url)
    return (url, SHA256Hex.string(of: Data(contents.utf8)))
  }

  func testAMeasuredConfigurationCarriesTheNativeDaemonDigest() throws {
    let (daemon, daemonDigest) = try write("arkforged", "daemon-bytes")
    let (profile, _) = try write("dayu200.yaml", "profile")

    let status = try LaunchAgentArkForgeLaneStatus.measuring(
      daemonPath: daemon.path, declaredDaemonSHA256: daemonDigest,
      deviceProfilePath: profile.path)

    XCTAssertEqual(status.daemonSHA256, daemonDigest)
    XCTAssertEqual(
      Set(status.environment.keys), Set(ArkDeckLaunchAgent.arkForgeEnvironmentKeys))
  }

  func testWithoutACampaignTheDaemonIsStartedGated() throws {
    // The default has to stay closed. `--hardware-campaign` is what lets
    // `arkforged` back an executable DAYU200 plan at all (AD-025); a lane that
    // passed it by default would authorize a write on an unverified
    // combination for every operator who never asked.
    let (daemon, daemonDigest) = try write("arkforged", "daemon-bytes")
    let (profile, _) = try write("dayu200.yaml", "profile")

    let status = try LaunchAgentArkForgeLaneStatus.measuring(
      daemonPath: daemon.path, declaredDaemonSHA256: daemonDigest,
      deviceProfilePath: profile.path)

    XCTAssertEqual(status.campaign, "")
    XCTAssertNil(
      status.environment[ArkDeckLaunchAgent.arkForgeCampaignEnvironmentKey],
      "an empty value in the plist would read as an unnamed campaign")

    let arguments = ArkForgeLaneComposition.daemonArguments(
      inputs: .init(
        daemonPath: daemon.path, daemonSHA256: daemonDigest,
        deviceProfilePath: profile.path, campaign: ""),
      runtimeDirectory: root, pairingEpoch: 1)
    XCTAssertFalse(arguments.contains("--hardware-campaign"))
  }

  func testANamedCampaignReachesTheDaemonsArgv() throws {
    let (daemon, daemonDigest) = try write("arkforged", "daemon-bytes")
    let (profile, _) = try write("dayu200.yaml", "profile")

    let status = try LaunchAgentArkForgeLaneStatus.measuring(
      daemonPath: daemon.path, declaredDaemonSHA256: daemonDigest,
      deviceProfilePath: profile.path, campaign: "AFA-AC-6")
    XCTAssertEqual(
      status.environment[ArkDeckLaunchAgent.arkForgeCampaignEnvironmentKey], "AFA-AC-6")

    let arguments = ArkForgeLaneComposition.daemonArguments(
      inputs: .init(
        daemonPath: daemon.path, daemonSHA256: daemonDigest,
        deviceProfilePath: profile.path, campaign: "AFA-AC-6"),
      runtimeDirectory: root, pairingEpoch: 1)
    // Adjacent, because a flag whose value drifted onto another flag would
    // start a campaign nobody named.
    let index = try XCTUnwrap(arguments.firstIndex(of: "--hardware-campaign"))
    XCTAssertEqual(arguments[index + 1], "AFA-AC-6")
  }

  func testTheCampaignIsNotPartOfTheAllOrNothingSet() throws {
    // Three inputs make a lane; the campaign authorizes one. Folding it into the
    // required set would mean every ordinary install had to name a campaign,
    // which is the opposite of a gate.
    XCTAssertFalse(
      ArkDeckLaunchAgent.arkForgeEnvironmentKeys.contains(
        ArkDeckLaunchAgent.arkForgeCampaignEnvironmentKey))

    let inputs = ArkForgeLaneComposition.Inputs.read([
      "ARKDECK_ARKFORGED_PATH": "/opt/arkforged",
      "ARKDECK_ARKFORGED_SHA256": String(repeating: "a", count: 64),
      "ARKDECK_ARKFORGE_PROFILE_PATH": "/opt/dayu200.yaml",
    ])
    guard case .success(let read) = inputs else {
      return XCTFail("a lane without a campaign is a complete lane")
    }
    XCTAssertEqual(read.campaign, "")
  }

  func testADeclaredDigestThatDoesNotMatchIsRefused() throws {
    let (daemon, _) = try write("arkforged", "daemon-bytes")
    let (profile, _) = try write("dayu200.yaml", "profile")

    XCTAssertThrowsError(
      try LaunchAgentArkForgeLaneStatus.measuring(
        daemonPath: daemon.path, declaredDaemonSHA256: String(repeating: "b", count: 64),
        deviceProfilePath: profile.path)
    ) { error in
      guard case LaunchAgentArkForgeLaneStatus.Refusal.digestMismatch = error else {
        return XCTFail("expected a digest refusal, got \(error)")
      }
    }
  }

  func testASymlinkIsRefusedRatherThanFollowed() throws {
    // A name can be repointed after it was verified. The file is what was
    // reviewed, so the file is what gets installed.
    let (daemon, daemonDigest) = try write("arkforged", "daemon-bytes")
    let (profile, _) = try write("dayu200.yaml", "profile")
    let alias = root.appending(path: "arkforged-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: daemon)

    XCTAssertThrowsError(
      try LaunchAgentArkForgeLaneStatus.measuring(
        daemonPath: alias.path, declaredDaemonSHA256: daemonDigest,
        deviceProfilePath: profile.path)
    ) { error in
      XCTAssertEqual(
        error as? LaunchAgentArkForgeLaneStatus.Refusal, .symlink(alias.path))
    }
  }

  func testARelativePathIsRefused() throws {
    let (profile, _) = try write("dayu200.yaml", "profile")
    XCTAssertThrowsError(
      try LaunchAgentArkForgeLaneStatus.measuring(
        daemonPath: "arkforged", declaredDaemonSHA256: String(repeating: "a", count: 64),
        deviceProfilePath: profile.path)
    ) { error in
      XCTAssertEqual(
        error as? LaunchAgentArkForgeLaneStatus.Refusal, .notAbsolute("arkforged"))
    }
  }

  func testAMissingProfileIsRefusedEvenWhenTheDaemonIsFine() throws {
    // The profile is what tells arkforged which device it is looking at. A
    // lane installed without one would start and then fail at the first job.
    let (daemon, daemonDigest) = try write("arkforged", "daemon-bytes")
    XCTAssertThrowsError(
      try LaunchAgentArkForgeLaneStatus.measuring(
        daemonPath: daemon.path, declaredDaemonSHA256: daemonDigest,
        deviceProfilePath: root.appending(path: "absent.yaml").path))
  }

  func testTheEnvironmentIsExactlyTheKeysTheLaneReads() throws {
    // Set some and forget others is the failure mode this guards: the lane
    // refuses a partial set, so a writer that emitted two keys would produce
    // a daemon that silently has no lane.
    let (daemon, daemonDigest) = try write("arkforged", "daemon-bytes")
    let (profile, _) = try write("dayu200.yaml", "profile")
    let status = try LaunchAgentArkForgeLaneStatus.measuring(
      daemonPath: daemon.path, declaredDaemonSHA256: daemonDigest,
      deviceProfilePath: profile.path)

    XCTAssertEqual(status.environment.count, 3)
    for value in status.environment.values {
      XCTAssertFalse(value.isEmpty, "an empty value counts as missing to the lane")
    }
  }

  func testTheInstallerAndTheLaneNameTheSameKeys() {
    // Two definitions of the same three strings: the installer writes them into
    // the plist, the lane reads them at startup. Nothing but this makes them
    // agree, and a mismatch is silent — the daemon would start with a plist
    // full of keys the lane never looks at, and simply have no lane.
    XCTAssertEqual(
      Set(ArkDeckLaunchAgent.arkForgeEnvironmentKeys),
      Set([
        ArkForgeLaneComposition.EnvironmentKey.daemonPath,
        ArkForgeLaneComposition.EnvironmentKey.daemonSHA256,
        ArkForgeLaneComposition.EnvironmentKey.deviceProfilePath,
      ]))
  }

  func testWhatTheInstallerWritesIsExactlyWhatTheLaneAccepts() throws {
    // End to end across the two halves: measure a configuration, hand its
    // environment to the lane's reader, and require a composed lane out. This
    // is the assertion that would have caught a renamed key.
    let (daemon, daemonDigest) = try write("arkforged", "daemon-bytes")
    let (profile, _) = try write("dayu200.yaml", "profile")
    let installed = try LaunchAgentArkForgeLaneStatus.measuring(
      daemonPath: daemon.path, declaredDaemonSHA256: daemonDigest,
      deviceProfilePath: profile.path)

    guard case .success(let inputs) =
      ArkForgeLaneComposition.Inputs.read(installed.environment)
    else {
      return XCTFail("what the installer wrote must be what the lane accepts")
    }
    XCTAssertEqual(inputs.daemonPath, daemon.path)
    XCTAssertEqual(inputs.expectedToolchain.id, "arkforged-native-rockusb")
    XCTAssertEqual(inputs.expectedToolchain.sha256, daemonDigest)
  }

  func testALegacyFourKeyPlistIsAcceptedAndTheVendorKeyIsIgnored() {
    // Older installs carried a fourth vendor path. Property-list upgrades must
    // not mistake that extra legacy key for a partial native lane, and the
    // value must never enter the daemon argv or native toolchain identity.
    let environment = [
      "ARKDECK_ARKFORGED_PATH": "/opt/arkforged",
      "ARKDECK_ARKFORGED_SHA256": String(repeating: "a", count: 64),
      "ARKDECK_ARKFORGE_PROFILE_PATH": "/opt/dayu200.yaml",
      "ARKDECK_RKDEVELOPTOOL_PATH": "/legacy/rkdeveloptool",
    ]
    guard case .success(let inputs) = ArkForgeLaneComposition.Inputs.read(environment) else {
      return XCTFail("a complete three-key lane must ignore a legacy fourth key")
    }
    let arguments = ArkForgeLaneComposition.daemonArguments(
      inputs: inputs, runtimeDirectory: root, pairingEpoch: 1)
    XCTAssertFalse(arguments.joined(separator: " ").contains("rkdeveloptool"))
    XCTAssertEqual(inputs.expectedToolchain.id, "arkforged-native-rockusb")
  }
}
