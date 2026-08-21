import XCTest

@testable import ArkDeckWorkflows

final class ArkForgeAuthoritySupportContractTests: XCTestCase {
  private var baseKey: ArkForgeAuthoritySupport.Key {
    .init(
      authorityNamespace: "arkdeck",
      authorityImplementationVersion: "1.0.0",
      authorityImplementationSHA256: String(repeating: "1", count: 64),
      managedControlMappingSHA256: String(repeating: "2", count: 64),
      managedControlToolSHA256: String(repeating: "3", count: 64),
      permitCodecSHA256: String(repeating: "4", count: 64),
      mechanicsMaturityKeySHA256: String(repeating: "5", count: 64),
      hostPlatform: "macos/arm64")
  }

  func testAuthoritySupportKeyIsDeterministicAndEveryAxisRotatesIt() throws {
    let base = baseKey
    let digest = try base.digestBytes()
    XCTAssertEqual(digest, try base.digestBytes())
    XCTAssertEqual(digest.count, 32)

    let candidates: [ArkForgeAuthoritySupport.Key] = [
      .init(
        authorityNamespace: "arkdeck.other",
        authorityImplementationVersion: base.authorityImplementationVersion,
        authorityImplementationSHA256: base.authorityImplementationSHA256,
        managedControlMappingSHA256: base.managedControlMappingSHA256,
        managedControlToolSHA256: base.managedControlToolSHA256,
        permitCodecSHA256: base.permitCodecSHA256,
        mechanicsMaturityKeySHA256: base.mechanicsMaturityKeySHA256,
        hostPlatform: base.hostPlatform),
      .init(
        authorityNamespace: base.authorityNamespace,
        authorityImplementationVersion: "1.0.1",
        authorityImplementationSHA256: base.authorityImplementationSHA256,
        managedControlMappingSHA256: base.managedControlMappingSHA256,
        managedControlToolSHA256: base.managedControlToolSHA256,
        permitCodecSHA256: base.permitCodecSHA256,
        mechanicsMaturityKeySHA256: base.mechanicsMaturityKeySHA256,
        hostPlatform: base.hostPlatform),
      replacing(base, authorityImplementationSHA256: String(repeating: "6", count: 64)),
      replacing(base, managedControlMappingSHA256: String(repeating: "6", count: 64)),
      replacing(base, managedControlToolSHA256: String(repeating: "6", count: 64)),
      replacing(base, permitCodecSHA256: String(repeating: "6", count: 64)),
      replacing(base, mechanicsMaturityKeySHA256: String(repeating: "6", count: 64)),
      .init(
        authorityNamespace: base.authorityNamespace,
        authorityImplementationVersion: base.authorityImplementationVersion,
        authorityImplementationSHA256: base.authorityImplementationSHA256,
        managedControlMappingSHA256: base.managedControlMappingSHA256,
        managedControlToolSHA256: base.managedControlToolSHA256,
        permitCodecSHA256: base.permitCodecSHA256,
        mechanicsMaturityKeySHA256: base.mechanicsMaturityKeySHA256,
        hostPlatform: "windows/x86_64"),
    ]
    for candidate in candidates {
      XCTAssertNotEqual(digest, try candidate.digestBytes())
    }
  }

  func testNoCampaignIsHardwareGatedAndCannotExecute() throws {
    let configuration = ArkForgeAuthoritySupport.Configuration(
      authorityImplementationSHA256: String(repeating: "a", count: 64),
      managedControlToolSHA256: String(repeating: "b", count: 64),
      hardwareCampaign: "")
    let seal = try configuration.seal(
      mechanicsMaturityKeySHA256: String(repeating: "c", count: 64))

    XCTAssertEqual(seal.state, "hardwareGated")
    XCTAssertFalse(seal.permitsExecution)
    XCTAssertTrue(seal.campaign.isEmpty)
    XCTAssertFalse(seal.detail.isEmpty)
  }

  func testMalformedAxisCannotBePaddedOrTruncatedIntoAKey() {
    let malformed = replacing(baseKey, managedControlToolSHA256: "abc")
    XCTAssertThrowsError(try malformed.digestBytes()) { error in
      XCTAssertEqual(
        error as? ArkForgeAuthoritySupport.SupportError,
        .invalidDigest(axis: "managedControlToolSHA256", value: "abc"))
    }
  }

  private func replacing(
    _ key: ArkForgeAuthoritySupport.Key,
    authorityImplementationSHA256: String? = nil,
    managedControlMappingSHA256: String? = nil,
    managedControlToolSHA256: String? = nil,
    permitCodecSHA256: String? = nil,
    mechanicsMaturityKeySHA256: String? = nil
  ) -> ArkForgeAuthoritySupport.Key {
    .init(
      authorityNamespace: key.authorityNamespace,
      authorityImplementationVersion: key.authorityImplementationVersion,
      authorityImplementationSHA256: authorityImplementationSHA256
        ?? key.authorityImplementationSHA256,
      managedControlMappingSHA256: managedControlMappingSHA256
        ?? key.managedControlMappingSHA256,
      managedControlToolSHA256: managedControlToolSHA256
        ?? key.managedControlToolSHA256,
      permitCodecSHA256: permitCodecSHA256 ?? key.permitCodecSHA256,
      mechanicsMaturityKeySHA256: mechanicsMaturityKeySHA256
        ?? key.mechanicsMaturityKeySHA256,
      hostPlatform: key.hostPlatform)
  }
}
