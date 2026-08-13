import ArkDeckProcess
import Darwin
import Foundation

/// Explicit inputs for ArkDeck's offline OpenHarmony SDK release preset.
/// Nothing is searched through PATH or inferred from a mutable workspace.
package struct OpenHarmonySDKReleasePresetConfiguration: Sendable, Equatable {
  package let projectRef: String
  public let bundleName: String
  package let javaExecutable: URL
  package let sdkRoot: URL

  public init(
    projectRef: String = OpenHarmonyLocalSigning.defaultProjectRef,
    bundleName: String,
    javaExecutable: URL,
    sdkRoot: URL
  ) {
    self.projectRef = projectRef
    self.bundleName = bundleName
    self.javaExecutable = javaExecutable
    self.sdkRoot = sdkRoot
  }
}

/// Builds a current, bundle-bound release profile from the official SDK
/// signing bundle and installs it as the same published ArkDeck preset. The
/// OpenHarmony SDK release profile has no device-UDID allowlist, so a generic
/// OpenHarmony board does not need DevEco Studio or cloud-side registration.
/// Runtime Jobs never call this maintenance boundary.
package final class OpenHarmonySDKReleasePresetInstaller: @unchecked Sendable {
  private static let appKeyAlias = "openharmony application release"
  private static let profileKeyAlias = "openharmony application profile release"
  private static let signingAlgorithm = "SHA256withECDSA"

  private let store: OpenHarmonySigningPresetStore
  private let materialParentURL: URL
  private let fileManager: FileManager
  private let now: @Sendable () -> Date

  public init(
    store: OpenHarmonySigningPresetStore,
    materialParentURL: URL = OpenHarmonyLocalSigning.defaultRootURL(),
    fileManager: FileManager = .default,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.store = store
    self.materialParentURL = materialParentURL.standardizedFileURL
    self.fileManager = fileManager
    self.now = now
  }

  public func install(
    configuration: OpenHarmonySDKReleasePresetConfiguration
  ) async throws -> OpenHarmonySigningPresetReceipt {
    try Self.validateIdentifier(configuration.projectRef, name: "projectRef")
    try Self.validateBundleName(configuration.bundleName)
    let sdkRoot = try validatedSDKRoot(configuration.sdkRoot)
    let library = sdkRoot.appending(path: "toolchains/lib", directoryHint: .isDirectory)
    let signerJAR = library.appending(path: "hap-sign-tool.jar")
    let sourceKeystore = library.appending(path: "OpenHarmony.p12")
    let profileCertificate = library.appending(path: "OpenHarmonyProfileRelease.pem")
    let profileTemplate = library.appending(path: "UnsgnedReleasedProfileTemplate.json")

    _ = try OpenHarmonySigningPresetStore.measure(
      configuration.javaExecutable, role: "java", mustBeExecutable: true)
    let jarIdentity = try OpenHarmonySigningPresetStore.measure(
      signerJAR, role: "SDK hapsigner JAR")
    let sourceKeystoreIdentity = try OpenHarmonySigningPresetStore.measure(
      sourceKeystore, role: "SDK release keystore")
    let profileCertificateIdentity = try OpenHarmonySigningPresetStore.measure(
      profileCertificate, role: "SDK release profile certificate")
    let profileTemplateIdentity = try OpenHarmonySigningPresetStore.measure(
      profileTemplate, role: "SDK release profile template")

    try fileManager.createDirectory(
      at: materialParentURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try fileManager.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: materialParentURL.path)
    let material = materialParentURL.appending(
      path:
        "sdk-release-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    try fileManager.createDirectory(
      at: material, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    var committed = false
    defer {
      if !committed { try? fileManager.removeItem(at: material) }
    }

    let keystore = material.appending(path: "OpenHarmony.p12")
    let appCertificate = material.appending(path: "OpenHarmonyApplicationRelease.pem")
    let unsignedProfile = material.appending(path: "release-profile.json")
    let signedProfile = material.appending(path: "release-profile.p7b")
    let profileVerification = material.appending(path: "profile-verification.json")

    try copyPrivate(
      source: sourceKeystore, expected: sourceKeystoreIdentity, destination: keystore)
    try copyPrivate(
      source: profileCertificate, expected: profileCertificateIdentity,
      destination: material.appending(path: "OpenHarmonyProfileRelease.pem"))
    let generated = try generateProfile(
      template: profileTemplate, expected: profileTemplateIdentity,
      bundleName: configuration.bundleName)
    try writePrivate(generated.bytes, to: unsignedProfile)
    try writePrivate(
      try applicationCertificateChain(
        profileCertificate: profileCertificate,
        expected: profileCertificateIdentity,
        applicationLeaf: generated.appCertificate),
      to: appCertificate)

    try await signProfile(
      java: configuration.javaExecutable, signerJAR: signerJAR,
      signerJARIdentity: jarIdentity, keystore: keystore,
      profileCertificate: material.appending(path: "OpenHarmonyProfileRelease.pem"),
      unsignedProfile: unsignedProfile, signedProfile: signedProfile)
    try await verifyProfile(
      java: configuration.javaExecutable, signerJAR: signerJAR,
      signerJARIdentity: jarIdentity, signedProfile: signedProfile,
      verification: profileVerification, expectedBundleName: configuration.bundleName,
      expectedNotBefore: generated.notBefore, expectedNotAfter: generated.notAfter)

    let previous = try? store.loadValidated(requireSecrets: false)
    var password = OpenHarmonyLocalSigning.publicSDKReleasePassword()
    defer { password.resetBytes(in: 0..<password.count) }
    let receipt = try store.install(
      configuration: OpenHarmonySigningPresetConfiguration(
        projectRef: configuration.projectRef,
        javaExecutable: configuration.javaExecutable,
        signerJAR: signerJAR,
        keystore: keystore,
        appCertificate: appCertificate,
        signedProfile: signedProfile,
        keyAlias: Self.appKeyAlias,
        managedMaterialDirectory: material),
      keystorePassword: password, keyPassword: password)
    committed = true

    if let oldPath = previous?.managedMaterialDirectory,
      oldPath != material.path
    {
      let old = URL(filePath: oldPath).standardizedFileURL
      if old.path == oldPath,
        old.deletingLastPathComponent().path == materialParentURL.path
      {
        try? fileManager.removeItem(at: old)
      }
    }
    return receipt
  }

  private struct GeneratedProfile {
    let bytes: Data
    let appCertificate: String
    let notBefore: Int64
    let notAfter: Int64
  }

  /// The SDK release template embeds only the application leaf certificate,
  /// while hap-sign-tool requires `-appCertFile` to contain a complete chain.
  /// The SDK's profile certificate bundle is the canonical root/intermediate/
  /// profile-leaf chain. Reuse only its measured root and intermediate and
  /// replace the unrelated profile leaf with the template's application leaf.
  private func applicationCertificateChain(
    profileCertificate: URL,
    expected: OpenHarmonySigningFileIdentity,
    applicationLeaf: String
  ) throws -> Data {
    let current = try OpenHarmonySigningPresetStore.measure(
      profileCertificate, role: "SDK release profile certificate")
    guard current == expected else {
      throw OpenHarmonySigningError.identityDrift("SDK release profile certificate")
    }
    let profileBytes = try Data(contentsOf: profileCertificate, options: [.uncached])
    guard let profileText = String(data: profileBytes, encoding: .utf8) else {
      throw OpenHarmonySigningError.invalidConfiguration(
        "SDK release profile certificate is not UTF-8 PEM")
    }
    let profileChain = try Self.pemCertificateBlocks(
      profileText, role: "SDK release profile certificate")
    let application = try Self.pemCertificateBlocks(
      applicationLeaf, role: "SDK release application certificate")
    guard profileChain.count == 3, application.count == 1 else {
      throw OpenHarmonySigningError.invalidConfiguration(
        "SDK release certificates are outside the closed three-certificate chain shape")
    }
    // Official SDK bundles are ordered root -> application CA -> profile leaf.
    // Keeping that accepted order and substituting the application leaf yields
    // the exact root -> application CA -> application leaf chain required by
    // the bundled signer. Never guess certificates from PATH or the host store.
    return Data((profileChain.prefix(2) + application).joined().utf8)
  }

  private static func pemCertificateBlocks(
    _ text: String, role: String
  ) throws -> [String] {
    let begin = "-----BEGIN CERTIFICATE-----"
    let end = "-----END CERTIFICATE-----"
    var remainder = text[...]
    var blocks: [String] = []
    while let start = remainder.range(of: begin) {
      guard remainder[..<start.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let finish = remainder.range(of: end, range: start.upperBound..<remainder.endIndex)
      else {
        throw OpenHarmonySigningError.invalidConfiguration("\(role) has invalid PEM framing")
      }
      let blockEnd = finish.upperBound
      blocks.append(String(remainder[start.lowerBound..<blockEnd]) + "\n")
      remainder = remainder[blockEnd...]
    }
    guard !blocks.isEmpty,
      remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw OpenHarmonySigningError.invalidConfiguration("\(role) has invalid PEM framing")
    }
    return blocks
  }

  private func generateProfile(
    template: URL, expected: OpenHarmonySigningFileIdentity, bundleName: String
  ) throws -> GeneratedProfile {
    let current = try OpenHarmonySigningPresetStore.measure(
      template, role: "SDK release profile template")
    guard current == expected else {
      throw OpenHarmonySigningError.identityDrift("SDK release profile template")
    }
    let data = try Data(contentsOf: template, options: [.uncached])
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["type"] as? String == "release",
      object["app-distribution-type"] as? String == "os_integration",
      object["issuer"] as? String == "pki_internal",
      object["debug-info"] == nil,
      var bundle = object["bundle-info"] as? [String: Any],
      bundle["apl"] as? String == "normal",
      bundle["app-feature"] as? String == "hos_normal_app",
      let certificate = bundle["distribution-certificate"] as? String,
      certificate.hasPrefix("-----BEGIN CERTIFICATE-----\n"),
      certificate.hasSuffix("-----END CERTIFICATE-----\n")
        || certificate.hasSuffix("-----END CERTIFICATE-----")
    else {
      throw OpenHarmonySigningError.invalidConfiguration(
        "SDK release profile template is outside the closed OpenHarmony shape")
    }
    let timestamp = Int64(now().timeIntervalSince1970)
    let notBefore = timestamp - 300
    let notAfter = timestamp + 365 * 24 * 60 * 60
    bundle["bundle-name"] = bundleName
    object["bundle-info"] = bundle
    object["uuid"] = UUID().uuidString.lowercased()
    object["validity"] = ["not-before": notBefore, "not-after": notAfter]
    let encoded = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return GeneratedProfile(
      bytes: encoded, appCertificate: certificate,
      notBefore: notBefore, notAfter: notAfter)
  }

  private func signProfile(
    java: URL, signerJAR: URL, signerJARIdentity: OpenHarmonySigningFileIdentity,
    keystore: URL, profileCertificate: URL, unsignedProfile: URL, signedProfile: URL
  ) async throws {
    let jar = try VerifiedRegularFileDescriptor.open(
      path: signerJAR, expectedSHA256: signerJARIdentity.sha256)
    let input = try VerifiedRegularFileDescriptor.open(
      path: unsignedProfile,
      expectedSHA256: OpenHarmonySigningPresetStore.measure(
        unsignedProfile, role: "generated release profile"
      ).sha256)
    let keyStore = try VerifiedRegularFileDescriptor.open(
      path: keystore,
      expectedSHA256: OpenHarmonySigningPresetStore.measure(
        keystore, role: "managed SDK release keystore", ownerPrivate: true
      ).sha256)
    let certificate = try VerifiedRegularFileDescriptor.open(
      path: profileCertificate,
      expectedSHA256: OpenHarmonySigningPresetStore.measure(
        profileCertificate, role: "managed SDK profile certificate"
      ).sha256)
    defer {
      jar.close()
      input.close()
      keyStore.close()
      certificate.close()
    }
    var password = OpenHarmonyLocalSigning.publicSDKReleasePassword()
    defer { password.resetBytes(in: 0..<password.count) }
    let result = try await IdentityBoundPTYExecutor().execute(
      ProcessIdentityBoundRequest(
        process: ProcessRequest(
          executable: java,
          arguments: [
            "-jar", jar.inodePath, "sign-profile",
            "-mode", "localSign",
            "-keyAlias", Self.profileKeyAlias,
            "-signAlg", Self.signingAlgorithm,
            "-profileCertFile", profileCertificate.path,
            "-inFile", unsignedProfile.path,
            "-keystoreFile", keystore.path,
            "-outFile", signedProfile.path,
            "-pwdInputMode", "1",
          ],
          workingDirectory: unsignedProfile.deletingLastPathComponent(), timeout: 120),
        expectedSHA256: try OpenHarmonySigningPresetStore.measure(
          java, role: "java", mustBeExecutable: true
        ).sha256),
      interactions: [
        IdentityBoundPTYInteraction(
          expectedPrompt: Data("please input KeystorePwd (timeout 30 seconds):".utf8),
          secret: password),
        IdentityBoundPTYInteraction(
          expectedPrompt: Data("please input KeyPwd (timeout 30 seconds):".utf8),
          secret: password),
      ],
      verifiedResources: [jar, input, keyStore, certificate])
    guard case .exited(0) = result.termination, result.completedInteractions == 2 else {
      throw OpenHarmonySigningError.ioFailure(
        "SDK release profile signer failed with closed diagnostic \(result.failureCategory.rawValue)"
      )
    }
    try fileManager.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: signedProfile.path)
    _ = try OpenHarmonySigningPresetStore.measure(
      signedProfile, role: "signed SDK release profile")
  }

  private func verifyProfile(
    java: URL, signerJAR: URL, signerJARIdentity: OpenHarmonySigningFileIdentity,
    signedProfile: URL, verification: URL, expectedBundleName: String,
    expectedNotBefore: Int64, expectedNotAfter: Int64
  ) async throws {
    let jar = try VerifiedRegularFileDescriptor.open(
      path: signerJAR, expectedSHA256: signerJARIdentity.sha256)
    let profile = try VerifiedRegularFileDescriptor.open(
      path: signedProfile,
      expectedSHA256: OpenHarmonySigningPresetStore.measure(
        signedProfile, role: "signed SDK release profile"
      ).sha256)
    defer {
      jar.close()
      profile.close()
    }
    let result = try await FoundationProcessExecutor().executeIdentityBound(
      ProcessIdentityBoundRequest(
        process: ProcessRequest(
          executable: java,
          arguments: [
            "-jar", jar.inodePath, "verify-profile",
            "-inFile", signedProfile.path,
            "-outFile", verification.path,
          ],
          workingDirectory: signedProfile.deletingLastPathComponent(), timeout: 120),
        expectedSHA256: try OpenHarmonySigningPresetStore.measure(
          java, role: "java", mustBeExecutable: true
        ).sha256),
      verifiedResources: [jar, profile], captureLimit: 256 * 1_024)
    guard case .exited(0) = result.execution.termination,
      !result.execution.stdout.wasTruncated, !result.execution.stderr.wasTruncated,
      let document = try JSONSerialization.jsonObject(
        with: Data(contentsOf: verification)) as? [String: Any],
      (document["verifiedPassed"] as? NSNumber)?.boolValue == true,
      let content = document["content"] as? [String: Any],
      content["type"] as? String == "release", content["debug-info"] == nil,
      let bundle = content["bundle-info"] as? [String: Any],
      bundle["bundle-name"] as? String == expectedBundleName,
      let validity = content["validity"] as? [String: Any],
      (validity["not-before"] as? NSNumber)?.int64Value == expectedNotBefore,
      (validity["not-after"] as? NSNumber)?.int64Value == expectedNotAfter
    else {
      throw OpenHarmonySigningError.ioFailure(
        "SDK release profile did not pass exact verify-profile readback")
    }
    try? fileManager.removeItem(at: verification)
  }

  private func validatedSDKRoot(_ candidate: URL) throws -> URL {
    let root = candidate.standardizedFileURL
    guard candidate.isFileURL, candidate.path.hasPrefix("/"), candidate.path == root.path,
      candidate.resolvingSymlinksInPath().standardizedFileURL.path == root.path
    else {
      throw OpenHarmonySigningError.invalidConfiguration(
        "OpenHarmony SDK root must be an explicit canonical absolute path")
    }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw OpenHarmonySigningError.invalidConfiguration("OpenHarmony SDK root is absent") }
    return root
  }

  private func copyPrivate(
    source: URL, expected: OpenHarmonySigningFileIdentity, destination: URL
  ) throws {
    guard
      try OpenHarmonySigningPresetStore.measure(source, role: "SDK signing material")
        == expected
    else { throw OpenHarmonySigningError.identityDrift("SDK signing material") }
    let bytes = try Data(contentsOf: source, options: [.uncached])
    try writePrivate(bytes, to: destination)
    guard
      try OpenHarmonySigningPresetStore.measure(source, role: "SDK signing material")
        == expected
    else { throw OpenHarmonySigningError.identityDrift("SDK signing material") }
  }

  private func writePrivate(_ bytes: Data, to destination: URL) throws {
    try bytes.write(to: destination, options: [.withoutOverwriting])
    try fileManager.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: destination.path)
  }

  private static func validateIdentifier(_ value: String, name: String) throws {
    guard
      value.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._@-]{0,127}$"#,
        options: .regularExpression) != nil
    else { throw OpenHarmonySigningError.invalidConfiguration("\(name) is malformed") }
  }

  private static func validateBundleName(_ value: String) throws {
    guard value.count <= 255,
      value.range(
        of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#,
        options: .regularExpression) != nil
    else { throw OpenHarmonySigningError.invalidConfiguration("bundleName is malformed") }
  }

}
