import ArkDeckCore
import CryptoKit
import Foundation

/// ArkDeck's independent support key for the authority half of ArkForge Flash.
///
/// Mechanics maturity answers whether the provider/profile/artifact/toolchain
/// combination is ready. It cannot answer whether this exact ArkDeck authority
/// build, managed-control mapping, HDC build and permit codec are ready. This
/// key binds those independent axes before a controller materialization can
/// become executable.
package enum ArkForgeAuthoritySupport {
  package static let namespace = "arkdeck"
  package static let implementationVersion = "1.0.0"

  /// The executable control lowering ArkDeck currently implements.
  ///
  /// This string is deliberately a closed protocol description rather than a
  /// source-file digest. A refactor that preserves the mapping preserves the
  /// key; any semantic mapping change must update this description and
  /// therefore rotates the support key.
  private static let managedControlMapping = """
    arkdeck.arkforge-managed-control/v1
    enterUpdater=observeHDCNormalUSB+enterLoader+waitForHDCDisconnect+waitForLoader+rebindLoader
    rebootToNormal=waitForBoundHDCReconnect
    readProductFacts=verifyBoundBuild:const.product.model
    readBuildFacts=verifyBoundBuild:const.ohos.fullname
    acceptedReceiptEvidence=sha256(sorted-utf8-key=value-newline)
    forbiddenReceiptFacts=argv,connectKey,hdcEndpoint,hdcExecutablePath,serverLifecycleAction,shell
    """

  /// The exact permit representation and replay discipline implemented by
  /// `ArkForgeStepPermit` and `ArkForgeExecutionAuthority`.
  private static let permitCodec = """
    arkdeck.arkforge-step-permit/rfc8949-canonical-cbor-v1+hmac-sha256
    tag=HMAC-SHA256(pairing-secret,canonical-body)
    pairingEpoch=per-daemon-generation
    singleUse=true
    retransmit=exact-stored-body-and-tag
    """

  package struct Key: Sendable, Equatable {
    package let authorityNamespace: String
    package let authorityImplementationVersion: String
    package let authorityImplementationSHA256: String
    package let managedControlMappingSHA256: String
    package let managedControlToolSHA256: String
    package let permitCodecSHA256: String
    package let mechanicsMaturityKeySHA256: String
    package let hostPlatform: String

    package init(
      authorityNamespace: String, authorityImplementationVersion: String,
      authorityImplementationSHA256: String, managedControlMappingSHA256: String,
      managedControlToolSHA256: String, permitCodecSHA256: String,
      mechanicsMaturityKeySHA256: String, hostPlatform: String
    ) {
      self.authorityNamespace = authorityNamespace
      self.authorityImplementationVersion = authorityImplementationVersion
      self.authorityImplementationSHA256 = authorityImplementationSHA256
      self.managedControlMappingSHA256 = managedControlMappingSHA256
      self.managedControlToolSHA256 = managedControlToolSHA256
      self.permitCodecSHA256 = permitCodecSHA256
      self.mechanicsMaturityKeySHA256 = mechanicsMaturityKeySHA256
      self.hostPlatform = hostPlatform
    }

    /// Domain-separated SHA-256 over a canonical textual projection.
    ///
    /// Values are newline-free identifiers or exact lowercase SHA-256 text,
    /// and keys are byte-sorted. That makes the representation reviewable in
    /// either language without depending on dictionary iteration order.
    package func digestBytes() throws -> [UInt8] {
      for (name, value) in [
        ("authorityImplementationSHA256", authorityImplementationSHA256),
        ("managedControlMappingSHA256", managedControlMappingSHA256),
        ("managedControlToolSHA256", managedControlToolSHA256),
        ("permitCodecSHA256", permitCodecSHA256),
        ("mechanicsMaturityKeySHA256", mechanicsMaturityKeySHA256),
      ] {
        guard ArkForgeAuthoritySupport.isLowercaseSHA256(value) else {
          throw SupportError.invalidDigest(axis: name, value: value)
        }
      }
      for (name, value) in [
        ("authorityNamespace", authorityNamespace),
        ("authorityImplementationVersion", authorityImplementationVersion),
        ("hostPlatform", hostPlatform),
      ] where value.isEmpty || value.contains("\n") || value.contains("=") {
        throw SupportError.invalidIdentifier(axis: name, value: value)
      }

      let fields = [
        "authorityImplementationSHA256": authorityImplementationSHA256,
        "authorityImplementationVersion": authorityImplementationVersion,
        "authorityNamespace": authorityNamespace,
        "hostPlatform": hostPlatform,
        "managedControlMappingSHA256": managedControlMappingSHA256,
        "managedControlToolSHA256": managedControlToolSHA256,
        "mechanicsMaturityKeySHA256": mechanicsMaturityKeySHA256,
        "permitCodecSHA256": permitCodecSHA256,
      ]
      var body = Data("arkdeck.authority-support-key/v1\n".utf8)
      for (name, value) in fields.sorted(by: {
        Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8))
      }) {
        body.append(contentsOf: Data("\(name)=\(value)\n".utf8))
      }
      return Array(SHA256.hash(data: body))
    }
  }

  package struct Configuration: Sendable, Equatable {
    package let authorityImplementationSHA256: String
    package let managedControlToolSHA256: String
    /// Empty is the normal, non-executable state.
    package let hardwareCampaign: String

    package init(
      authorityImplementationSHA256: String, managedControlToolSHA256: String,
      hardwareCampaign: String
    ) {
      self.authorityImplementationSHA256 = authorityImplementationSHA256.lowercased()
      self.managedControlToolSHA256 = managedControlToolSHA256.lowercased()
      self.hardwareCampaign = hardwareCampaign
    }

    package func key(mechanicsMaturityKeySHA256: String) -> Key {
      Key(
        authorityNamespace: namespace,
        authorityImplementationVersion: implementationVersion,
        authorityImplementationSHA256: authorityImplementationSHA256,
        managedControlMappingSHA256: sha256Hex(managedControlMapping),
        managedControlToolSHA256: managedControlToolSHA256,
        permitCodecSHA256: sha256Hex(permitCodec),
        mechanicsMaturityKeySHA256: mechanicsMaturityKeySHA256,
        hostPlatform: currentHostPlatform)
    }

    package func seal(mechanicsMaturityKeySHA256: String) throws -> Seal {
      let key = key(mechanicsMaturityKeySHA256: mechanicsMaturityKeySHA256)
      let digest = try key.digestBytes()
      if hardwareCampaign.isEmpty {
        return Seal(
          key: key, keySHA256: digest, state: "hardwareGated",
          detail:
            "the exact ArkDeck authority build/control-map/HDC/permit-codec/mechanics/platform "
            + "combination has no reviewed production support record")
      }
      guard !hardwareCampaign.contains("\n") else {
        throw SupportError.invalidIdentifier(axis: "hardwareCampaign", value: hardwareCampaign)
      }
      return Seal(
        key: key, keySHA256: digest, state: "hardwareCampaign", detail: hardwareCampaign)
    }
  }

  package struct Seal: Sendable, Equatable {
    package let key: Key
    package let keySHA256: [UInt8]
    package let state: String
    package let detail: String

    package var keyHex: String { SHA256Hex.lowercaseHex(Data(keySHA256)) }
    package var permitsExecution: Bool {
      state == "productionVerified" || state == "hardwareCampaign"
    }
    package var campaign: String { state == "hardwareCampaign" ? detail : "" }
  }

  package enum SupportError: Error, Equatable, CustomStringConvertible {
    case invalidDigest(axis: String, value: String)
    case invalidIdentifier(axis: String, value: String)

    package var description: String {
      switch self {
      case .invalidDigest(let axis, _):
        return "\(axis) must be exactly 32 lowercase hex-encoded bytes"
      case .invalidIdentifier(let axis, _):
        return "\(axis) must be a non-empty single-line identifier without '='"
      }
    }
  }

  /// A deliberately non-executable first controller pass. It retrieves the
  /// daemon's real mechanics state while proving the controller understands
  /// and echoes the authority-support fields before any executable plan can be
  /// stored.
  package static let pendingKeySHA256: [UInt8] =
    Array(SHA256.hash(data: Data("arkdeck.authority-support-pending/v1".utf8)))
  package static let pendingDetail =
    "the exact mechanics maturity key has not yet been bound to ArkDeck authority support"

  private static var currentHostPlatform: String {
    #if os(macOS)
      let os = "macos"
    #elseif os(Windows)
      let os = "windows"
    #elseif os(Linux)
      let os = "linux"
    #else
      let os = "unknown-os"
    #endif
    #if arch(arm64)
      let arch = "arm64"
    #elseif arch(x86_64)
      let arch = "x86_64"
    #else
      let arch = "unknown-arch"
    #endif
    return "\(os)/\(arch)"
  }

  private static func sha256Hex(_ value: String) -> String {
    SHA256Hex.lowercaseHex(Data(SHA256.hash(data: Data(value.utf8))))
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 64 else { return false }
    return bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }
}
