import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// The product RockUSB identity is the measured ArkForge daemon itself.
/// Digest mismatch and provider substitution both fail before composition.
final class RockchipProductionCompositionContractTests: XCTestCase {
  func testNativeRockUSBToolchainNamesOnlyArkForge() {
    XCTAssertEqual(ArkForgeNativeRockUSBToolchain.identifier, "arkforged-native-rockusb")
    XCTAssertEqual(ArkForgeNativeRockUSBToolchain.reportedVersion, "arkforged native RockUSB")
  }

  func testNativeResolverAcceptsOnlyTheExactMeasuredDaemonDigest() throws {
    let executable = URL(filePath: "/usr/bin/true")
    let digest = SHA256.hash(data: try Data(contentsOf: executable))
      .map { String(format: "%02x", $0) }.joined()
    let resolver = ArkForgeNativeRockUSBExecutableResolver(
      daemonPath: executable.path, declaredSHA256: digest)

    let resolved = try resolver.resolveExecutable(providerID: "rockchip")

    XCTAssertEqual(resolved.path, executable.path)
    XCTAssertEqual(resolved.sha256, digest)
  }

  func testNativeResolverFailsClosedOnDigestDriftAndProviderSubstitution() {
    let resolver = ArkForgeNativeRockUSBExecutableResolver(
      daemonPath: "/usr/bin/true", declaredSHA256: String(repeating: "0", count: 64))

    XCTAssertThrowsError(try resolver.resolveExecutable(providerID: "rockchip"))
    XCTAssertThrowsError(try resolver.resolveExecutable(providerID: "hdc"))
  }
}
