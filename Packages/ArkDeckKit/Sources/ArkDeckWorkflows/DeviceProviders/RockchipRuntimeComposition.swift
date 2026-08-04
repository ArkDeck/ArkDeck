// Product-owned Rockchip Runtime composition for GJ-4.
//
// The bundled component is not a PATH/user-selected executable. It is the
// exact nested binary from the reviewed 1.0.0 release tuple. Runtime binds the
// signed bytes it will actually execute into target facts, the materialized
// plan and the E2 capability query. The historical external-tool pin remains
// separate and cannot authorize this product-owned execution route.

import CryptoKit
import Darwin
import Foundation
import Security

public enum BundledRockchipComponent {
  public static let packageID = "arkdeck-rockchip-component-package@1.0.0"
  public static let reportedVersion = "rkdeveloptool ver 1.32"
  public static let bundleRelativePath = "rkdeveloptool"
  public static let signingIdentifier = "com.arkdeck.desktop.rkdeveloptool"
  public static let signingTeamIdentifier = "8AQTYW5FKR"
}

public enum BundledRockchipComponentError: Error, Equatable, Sendable,
  CustomStringConvertible
{
  case mainExecutableUnavailable
  case componentMissing
  case nonCanonicalPath
  case notRegularExecutable
  case identityMismatch(expected: String, actual: String)
  case codeSignatureInvalid(OSStatus)
  case codeSignatureMetadataInvalid(String)
  case unsupportedProvider(String)

  public var description: String {
    switch self {
    case .mainExecutableUnavailable:
      return "the product executable location is unavailable"
    case .componentMissing:
      return "rkdeveloptool is missing from all fixed ArkDeck product locations"
    case .nonCanonicalPath:
      return "the bundled rkdeveloptool path is non-canonical or symlinked"
    case .notRegularExecutable:
      return "the bundled rkdeveloptool is not a regular executable"
    case .identityMismatch(let expected, let actual):
      return "bundled rkdeveloptool identity mismatch (expected \(expected), actual \(actual))"
    case .codeSignatureInvalid(let status):
      return "bundled rkdeveloptool Developer ID signature is invalid (OSStatus \(status))"
    case .codeSignatureMetadataInvalid(let field):
      return "bundled rkdeveloptool signature metadata is invalid (\(field))"
    case .unsupportedProvider(let providerID):
      return "bundled Rockchip resolver cannot resolve provider \(providerID)"
    }
  }
}

/// Resolves only fixed ArkDeck product locations. The package-only initializers
/// are test seams; production callers cannot supply a path.
public struct BundledRockchipExecutableResolver: RuntimeExecutableResolving {
  private enum TrustPolicy: Sendable {
    case productDeveloperID
    case exactSHA256(String)
  }

  private let componentURLs: [URL]
  private let trustPolicy: TrustPolicy

  public init() {
    var candidates: [URL] = []
    if let productExecutableURL = Bundle.main.executableURL {
      candidates.append(
        productExecutableURL.deletingLastPathComponent()
          .appendingPathComponent(BundledRockchipComponent.bundleRelativePath))
    }
    candidates.append(
      URL(fileURLWithPath: "/Applications/ArkDeck.app/Contents/MacOS")
        .appendingPathComponent(BundledRockchipComponent.bundleRelativePath))
    candidates.append(
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/ArkDeck.app/Contents/MacOS")
        .appendingPathComponent(BundledRockchipComponent.bundleRelativePath))
    componentURLs = candidates.reduce(into: []) { result, candidate in
      if !result.contains(candidate) {
        result.append(candidate)
      }
    }
    trustPolicy = .productDeveloperID
  }

  package init(productExecutableURL: URL?, expectedSHA256: String) {
    componentURLs = productExecutableURL.map {
      [
        $0.deletingLastPathComponent()
          .appendingPathComponent(BundledRockchipComponent.bundleRelativePath)
      ]
    } ?? []
    trustPolicy = .exactSHA256(expectedSHA256)
  }

  package init(componentURLs: [URL], expectedSHA256: String) {
    self.componentURLs = componentURLs
    trustPolicy = .exactSHA256(expectedSHA256)
  }

  package init(componentURLs: [URL]) {
    self.componentURLs = componentURLs
    trustPolicy = .productDeveloperID
  }

  public func resolveExecutable(providerID: String) throws -> ResolvedExecutable {
    guard providerID == "rockchip" else {
      throw BundledRockchipComponentError.unsupportedProvider(providerID)
    }
    guard !componentURLs.isEmpty else {
      throw BundledRockchipComponentError.mainExecutableUnavailable
    }
    guard
      let componentURL = componentURLs.first(where: {
        FileManager.default.fileExists(atPath: $0.path)
      })
    else {
      throw BundledRockchipComponentError.componentMissing
    }
    let standardized = componentURL.standardizedFileURL
    let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
    guard componentURL.path == standardized.path, standardized.path == canonical.path else {
      throw BundledRockchipComponentError.nonCanonicalPath
    }
    var metadata = stat()
    guard lstat(componentURL.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_mode & 0o111 != 0
    else {
      throw BundledRockchipComponentError.notRegularExecutable
    }
    let data = try Data(contentsOf: componentURL, options: [.mappedIfSafe])
    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    switch trustPolicy {
    case .exactSHA256(let expectedSHA256):
      guard actual == expectedSHA256 else {
        throw BundledRockchipComponentError.identityMismatch(
          expected: expectedSHA256, actual: actual)
      }
    case .productDeveloperID:
      try Self.validateProductSignature(componentURL)
    }
    return ResolvedExecutable(path: componentURL.path, sha256: actual)
  }

  private static func validateProductSignature(_ componentURL: URL) throws {
    var staticCode: SecStaticCode?
    var status = SecStaticCodeCreateWithPath(
      componentURL as CFURL, SecCSFlags(), &staticCode)
    guard status == errSecSuccess, let staticCode else {
      throw BundledRockchipComponentError.codeSignatureInvalid(status)
    }

    let requirementText =
      "identifier \"\(BundledRockchipComponent.signingIdentifier)\" "
      + "and anchor apple generic "
      + "and certificate leaf[subject.OU] = "
      + "\"\(BundledRockchipComponent.signingTeamIdentifier)\""
    var requirement: SecRequirement?
    status = SecRequirementCreateWithString(
      requirementText as CFString, SecCSFlags(), &requirement)
    guard status == errSecSuccess, let requirement else {
      throw BundledRockchipComponentError.codeSignatureInvalid(status)
    }
    status = SecStaticCodeCheckValidity(
      staticCode,
      SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
      requirement)
    guard status == errSecSuccess else {
      throw BundledRockchipComponentError.codeSignatureInvalid(status)
    }

    var rawInformation: CFDictionary?
    status = SecCodeCopySigningInformation(
      staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
      &rawInformation)
    guard status == errSecSuccess,
      let information = rawInformation as? [CFString: Any]
    else {
      throw BundledRockchipComponentError.codeSignatureInvalid(status)
    }
    guard
      information[kSecCodeInfoIdentifier] as? String
        == BundledRockchipComponent.signingIdentifier
    else {
      throw BundledRockchipComponentError.codeSignatureMetadataInvalid(
        "identifier")
    }
    guard
      information[kSecCodeInfoTeamIdentifier] as? String
        == BundledRockchipComponent.signingTeamIdentifier
    else {
      throw BundledRockchipComponentError.codeSignatureMetadataInvalid(
        "teamIdentifier")
    }
    guard let flags = information[kSecCodeInfoFlags] as? NSNumber,
      flags.uint32Value & 0x0001_0000 != 0
    else {
      throw BundledRockchipComponentError.codeSignatureMetadataInvalid(
        "hardenedRuntime")
    }
    guard information[kSecCodeInfoTimestamp] is Date else {
      throw BundledRockchipComponentError.codeSignatureMetadataInvalid(
        "secureTimestamp")
    }
    // The child entitlement dictionary is empty, matching the TASK-BRC-003
    // packaging contract. The Runtime Broker is a standalone daemon and is not
    // itself sandboxed, so a child declaring `com.apple.security.inherit`
    // aborts inside `_libsecinit_appsandbox` ("Process is not in an inherited
    // sandbox") before `main` — the shape this guard used to require could
    // never execute here. Emptiness stays fail-closed: `get-task-allow`, App
    // Sandbox inheritance, child USB/file/network capability and Hardened
    // Runtime exceptions are all rejected by having no key at all.
    let entitlements = information[kSecCodeInfoEntitlementsDict]
    guard entitlements == nil
      || (entitlements as? [String: Any])?.isEmpty == true
    else {
      throw BundledRockchipComponentError.codeSignatureMetadataInvalid(
        "entitlements")
    }
  }
}

/// Facts come from the adopted target record and the product-owned component,
/// never from request fields. This makes the target identity and binding
/// revision used for plan admission the same durable facts used by HDC.
public struct TargetStoreRockchipRuntimeFactsPort: RockchipRuntimeFactsPort {
  private let targetStore: RuntimeTargetStore
  private let resolver: any RuntimeExecutableResolving
  private let prober: (any RockchipLiveModeProbing)?
  private let nowUTC: @Sendable () -> String

  /// `prober: nil` keeps the record-only behaviour: mode, build and profile
  /// are reported unknown because nothing measured them. A composed prober
  /// replaces those unknowns with read-only measurements, never with guesses.
  package init(
    targetStore: RuntimeTargetStore,
    resolver: any RuntimeExecutableResolving,
    prober: (any RockchipLiveModeProbing)? = nil,
    nowUTC: @escaping @Sendable () -> String
  ) {
    self.targetStore = targetStore
    self.resolver = resolver
    self.prober = prober
    self.nowUTC = nowUTC
  }

  public func currentFacts(targetID: String) async throws -> ProviderFacts {
    guard let target = try targetStore.find(targetID: targetID) else {
      throw DeviceProviderError.factsUnavailable("target \(targetID) has not been adopted")
    }
    let component: ResolvedExecutable
    do {
      component = try resolver.resolveExecutable(providerID: "rockchip")
    } catch {
      throw DeviceProviderError.factsUnavailable(
        "product-owned Rockchip component is unavailable: \(error)")
    }
    let live = await liveFacts(connectKey: target.connectKey)
    return ProviderFacts(
      providerID: "rockchip",
      toolVersion: BundledRockchipComponent.reportedVersion,
      toolSHA256: component.sha256,
      serverFacts: [
        "componentPackage": BundledRockchipComponent.packageID,
        "componentSigningIdentifier": BundledRockchipComponent.signingIdentifier,
        "componentSigningTeam": BundledRockchipComponent.signingTeamIdentifier,
      ],
      targetID: target.targetID,
      bindingRevision: target.bindingRevision,
      deviceIdentitySHA256: target.stablePhysicalIdentitySHA256,
      executionConnectKey: target.connectKey,
      deviceMode: live.deviceMode,
      buildFingerprint: live.buildFingerprint,
      profileID: live.profileID,
      collectedAtUTC: nowUTC())
  }

  /// Without a prober the durable adoption record is all this port has, and
  /// it cannot support any of these three: they stay unknown rather than
  /// fabricated. The previous "hdc"/"dayu200@1" literals were adoption-era
  /// guesses that flowed into evidence as if measured, and the real firmware
  /// profile (dayu200@2) contradicted one of them.
  ///
  /// With a prober they are measured read-only. A probe failure — including a
  /// device that is simply not attached — is encoded as `absent`, not thrown:
  /// these facts are the pre-admission portrait, while the fail-closed
  /// authority gates are the engine's fresh readback and reservation at the
  /// consume point. Throwing here would take device-absent planOnly and draft
  /// with it, and those must stay possible with no device on the host.
  private func liveFacts(
    connectKey: String?
  ) async -> (deviceMode: String, buildFingerprint: String?, profileID: String) {
    guard let prober, let connectKey else {
      return ("unknown", nil, "unknown")
    }
    guard
      let observation = try? await prober.observe(connectKey: connectKey)
    else {
      return ("absent", nil, "unknown")
    }
    // The flash profile is never inferred from a device model or a mode: only
    // an exact published firmware fingerprint names one. Anything else stays
    // unknown, and the per-request `deviceProfile` input remains the pin that
    // actually authorizes a write.
    let profileID =
      observation.buildFingerprint.flatMap { fingerprint in
        RockchipFlashProfile.supportedDAYU200Profiles.first {
          $0.firmwareVersion == fingerprint
        }?.catalogReference
      } ?? "unknown"
    return (observation.deviceMode, observation.buildFingerprint, profileID)
  }
}

/// The Rockchip route is installed in production even while it is
/// unavailable. It validates the exact host-managed action shape and exposes
/// the concrete compatibility blocker through operation.list. It must not
/// fall back to PATH, a bookmark, the HDC dispatcher, or the old whole-plan
/// host (which would consume a second legacy authorization).
public struct BundledRockchipRuntimeDispatcher: RuntimeProcessDispatching {
  private let resolver: any RuntimeExecutableResolving
  private let host: any RockchipRuntimeActionHosting

  package init(resolver: any RuntimeExecutableResolving) {
    self.resolver = resolver
    host = RefusingRockchipRuntimeActionHost(
      reason:
        "the per-action RockUSB host requires descriptor-bound HDC and a product state directory")
  }

  package init(
    resolver: any RuntimeExecutableResolving,
    hdcResolver: any RuntimeExecutableResolving,
    stateDirectory: URL
  ) {
    self.resolver = resolver
    host = DurableRockchipRuntimeActionHost(
      executor: FoundationRockchipRuntimeActionExecutor(
        hdcResolver: hdcResolver),
      records: RockchipRuntimeActionRecordStore(
        rootURL: stateDirectory.appendingPathComponent(
          "rockchip-runtime", isDirectory: true)))
  }

  init(
    resolver: any RuntimeExecutableResolving,
    host: any RockchipRuntimeActionHosting
  ) {
    self.resolver = resolver
    self.host = host
  }

  public func unavailableReason(providerID: String) -> String? {
    guard providerID == "rockchip" else {
      return "bundled Rockchip dispatcher cannot serve provider \(providerID)"
    }
    do {
      _ = try resolver.resolveExecutable(providerID: providerID)
    } catch {
      return "product-owned Rockchip component is unavailable: \(error)"
    }
    return host.unavailableReason()
  }

  public func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    guard case .rockchip(let action) = plan.action else {
      throw RuntimeDispatchFailure.failed(
        "bundled Rockchip dispatcher received a non-Rockchip action")
    }
    guard case .hostManaged(let descriptor) = plan.kind else {
      throw RuntimeDispatchFailure.failed(
        "Rockchip runtime actions must use their closed host-managed descriptors")
    }
    if let reason = unavailableReason(providerID: "rockchip") {
      throw RuntimeDispatchFailure.failed(reason)
    }
    let executable: ResolvedExecutable
    do {
      executable = try resolver.resolveExecutable(providerID: "rockchip")
    } catch {
      throw RuntimeDispatchFailure.failed(
        "product-owned Rockchip component is unavailable: \(error)")
    }
    guard descriptor.providerExecutableSHA256 == executable.sha256 else {
      throw RuntimeDispatchFailure.failed(
        "bundled Rockchip executable identity changed after availability materialization")
    }
    let result = try await host.execute(
      action: action,
      descriptor: descriptor,
      rockchipExecutable: executable)
    guard let recordID = result.summary["recordID"], !recordID.isEmpty else {
      throw RuntimeDispatchFailure.outcomeUnknown(
        "Rockchip host returned no durable job/step receipt")
    }
    return ProviderProcessReceipt(
      exitStatus: 0,
      stdout: result.stdout,
      stderr: result.stderr,
      stdoutTruncated: result.stdoutTruncated,
      durationSeconds: result.subprocesses.reduce(0) {
        $0 + $1.durationSeconds
      },
      hostManagedRecordID: recordID,
      subprocesses: result.subprocesses)
  }
}
