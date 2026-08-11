import ArkDeckCore
import ArkDeckProcess
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

package enum OpenHarmonyLocalSigning {
  public static let operationReference = "workspace.sign-openharmony-hap@1"
  package static let defaultPresetID = "openharmony-release@1"
  package static let defaultProjectRef = "demo-app"
  static let keychainService = "dev.arkdeck.openharmony-local-signing"
  /// Bumps only when ArkDeck changes how the Keychain item binds the
  /// interactive maintainer CLI and the installed LaunchAgent daemon. A
  /// missing/older value is forward-readable, but is never silently reused:
  /// the next explicit install creates one new ACL-bearing envelope.
  static let keychainAccessSchema = "trusted-applications-v3"

  /// Public password shipped with the official OpenHarmony SDK release
  /// keystore. Runtime still reads it from Keychain; maintenance may use this
  /// known value to bind a fresh envelope to a replaced daemon without asking
  /// the user to authorize an obsolete per-binary ACL.
  static func publicSDKReleasePassword() -> Data {
    Data([49, 50, 51, 52, 53, 54])
  }

  package static func defaultRootURL() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ArkDeck/Signing/OpenHarmony", isDirectory: true)
  }

  package static func defaultAgentDaemonURL() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ArkDeck/bin/arkdeck-agentd")
  }

}

public enum OpenHarmonySigningError: Error, Equatable, CustomStringConvertible, Sendable {
  case invalidConfiguration(String)
  case unsafeFile(String)
  case identityDrift(String)
  case receiptUnavailable(String)
  case secretUnavailable(String)
  case ioFailure(String)

  public var description: String {
    switch self {
    case .invalidConfiguration(let value): return "invalid signing configuration: \(value)"
    case .unsafeFile(let value): return "unsafe signing file: \(value)"
    case .identityDrift(let value): return "signing identity drift: \(value)"
    case .receiptUnavailable(let value): return "signing receipt unavailable: \(value)"
    case .secretUnavailable(let value): return "signing secret unavailable: \(value)"
    case .ioFailure(let value): return "signing I/O failure: \(value)"
    }
  }
}

package struct OpenHarmonySigningFileIdentity: Codable, Sendable, Equatable {
  public let path: String
  public let sha256: String
  public let byteCount: Int

  public init(path: String, sha256: String, byteCount: Int) {
    self.path = path
    self.sha256 = sha256
    self.byteCount = byteCount
  }
}

package struct OpenHarmonySigningPresetConfiguration: Sendable, Equatable {
  package let presetID: String
  package let projectRef: String
  package let javaExecutable: URL
  package let signerJAR: URL
  package let keystore: URL
  package let appCertificate: URL
  package let signedProfile: URL
  package let keyAlias: String
  package let signingAlgorithm: String
  package let managedMaterialDirectory: URL?

  public init(
    presetID: String = OpenHarmonyLocalSigning.defaultPresetID,
    projectRef: String = OpenHarmonyLocalSigning.defaultProjectRef,
    javaExecutable: URL,
    signerJAR: URL,
    keystore: URL,
    appCertificate: URL,
    signedProfile: URL,
    keyAlias: String,
    signingAlgorithm: String = "SHA256withECDSA",
    managedMaterialDirectory: URL? = nil
  ) {
    self.presetID = presetID
    self.projectRef = projectRef
    self.javaExecutable = javaExecutable
    self.signerJAR = signerJAR
    self.keystore = keystore
    self.appCertificate = appCertificate
    self.signedProfile = signedProfile
    self.keyAlias = keyAlias
    self.signingAlgorithm = signingAlgorithm
    self.managedMaterialDirectory = managedMaterialDirectory
  }
}

package struct OpenHarmonySigningPresetReceipt: Codable, Sendable, Equatable {
  package let schemaVersion: String
  package let installedAtUTC: String
  package let presetID: String
  package let projectRef: String
  package let javaExecutable: OpenHarmonySigningFileIdentity
  package let signerJAR: OpenHarmonySigningFileIdentity
  package let keystore: OpenHarmonySigningFileIdentity
  package let appCertificate: OpenHarmonySigningFileIdentity
  package let signedProfile: OpenHarmonySigningFileIdentity
  package let keyAlias: String
  package let signingAlgorithm: String
  package let keystorePasswordAccount: String
  package let keyPasswordAccount: String
  package let secretEnvelopeAccount: String?
  package let legacyPasswordAccounts: [String]?
  package let trustedDaemonApplicationSHA256: String?
  package let keychainAccessSchema: String?
  package let managedMaterialDirectory: String?

  public init(
    schemaVersion: String, installedAtUTC: String, presetID: String,
    projectRef: String, javaExecutable: OpenHarmonySigningFileIdentity,
    signerJAR: OpenHarmonySigningFileIdentity, keystore: OpenHarmonySigningFileIdentity,
    appCertificate: OpenHarmonySigningFileIdentity,
    signedProfile: OpenHarmonySigningFileIdentity, keyAlias: String,
    signingAlgorithm: String, keystorePasswordAccount: String,
    keyPasswordAccount: String, secretEnvelopeAccount: String? = nil,
    legacyPasswordAccounts: [String]? = nil,
    trustedDaemonApplicationSHA256: String? = nil,
    keychainAccessSchema: String? = nil,
    managedMaterialDirectory: String? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.installedAtUTC = installedAtUTC
    self.presetID = presetID
    self.projectRef = projectRef
    self.javaExecutable = javaExecutable
    self.signerJAR = signerJAR
    self.keystore = keystore
    self.appCertificate = appCertificate
    self.signedProfile = signedProfile
    self.keyAlias = keyAlias
    self.signingAlgorithm = signingAlgorithm
    self.keystorePasswordAccount = keystorePasswordAccount
    self.keyPasswordAccount = keyPasswordAccount
    self.secretEnvelopeAccount = secretEnvelopeAccount
    self.legacyPasswordAccounts = legacyPasswordAccounts
    self.trustedDaemonApplicationSHA256 = trustedDaemonApplicationSHA256
    self.keychainAccessSchema = keychainAccessSchema
    self.managedMaterialDirectory = managedMaterialDirectory
  }
}

package struct OpenHarmonySigningPresetStatus: Codable, Sendable, Equatable {
  public let installed: Bool
  public let ready: Bool
  package let receiptPath: String
  package let presetID: String?
  package let projectRef: String?
  package let javaPath: String?
  package let javaSHA256: String?
  package let signerJARPath: String?
  package let signerJARSHA256: String?
  package let keystorePath: String?
  package let keystoreSHA256: String?
  package let appCertificatePath: String?
  package let appCertificateSHA256: String?
  package let signedProfilePath: String?
  package let signedProfileSHA256: String?
  package let keystorePasswordPresent: Bool
  package let keyPasswordPresent: Bool
  public let diagnostics: [String]
}

package struct OpenHarmonySigningPresetRemoval: Codable, Sendable, Equatable {
  package let removedReceipt: Bool
  package let removedKeystorePassword: Bool
  package let removedKeyPassword: Bool
  package let removedManagedMaterial: Bool
  package let preservedSourcePaths: [String]
}

package struct OpenHarmonySigningSecretNormalization: Codable, Sendable, Equatable {
  package let presetID: String
  package let normalizedKeystorePassword: Bool
  package let normalizedKeyPassword: Bool
}

package struct OpenHarmonySigningEnvelopeMigration: Codable, Sendable, Equatable {
  package let presetID: String
  package let migrated: Bool
  package let envelopeAccount: String
  package let legacyAccountCount: Int
}

private struct OpenHarmonySigningSecretEnvelope: Codable {
  let schemaVersion: String
  var keystorePassword: Data
  var keyPassword: Data
}

package protocol OpenHarmonySigningSecretStoring: Sendable {
  func set(_ data: Data, account: String) throws
  func read(account: String) throws -> Data
  func contains(account: String) -> Bool
  func refreshTrustedApplicationAccess(account: String) throws
  func trustedDaemonApplicationSHA256() throws -> String?
  @discardableResult func remove(account: String) throws -> Bool
}

extension OpenHarmonySigningSecretStoring {
  package func trustedDaemonApplicationSHA256() throws -> String? { nil }
}

package struct LoginKeychainSigningSecretStore: OpenHarmonySigningSecretStoring {
  private let agentDaemonURL: URL
  private let allowsUserInteraction: Bool

  public init(
    agentDaemonURL: URL = OpenHarmonyLocalSigning.defaultAgentDaemonURL(),
    allowsUserInteraction: Bool = false
  ) {
    self.agentDaemonURL = agentDaemonURL.standardizedFileURL
    self.allowsUserInteraction = allowsUserInteraction
  }

  public func set(_ data: Data, account: String) throws {
    let identity = query(account: account)
    let update = SecItemUpdate(
      identity as CFDictionary,
      Self.existingItemValueUpdate(data) as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else {
      throw OpenHarmonySigningError.secretUnavailable("Keychain update status \(update)")
    }
    var add = identity
    add[kSecValueData as String] = data
    add[kSecAttrAccess as String] = try trustedApplicationAccess()
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw OpenHarmonySigningError.secretUnavailable("Keychain add status \(status)")
    }
  }

  static func existingItemValueUpdate(_ data: Data) -> [String: Any] {
    // Updating the protected value does not change ACL ownership. Replacing
    // kSecAttrAccess here would force a macOS password prompt for every
    // normalization or reinstall, even when the daemon identity is stable.
    [kSecValueData as String: data]
  }

  public func read(account: String) throws -> Data {
    var request = query(account: account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    if !allowsUserInteraction {
      request.merge(Self.nonInteractiveReadOptions()) { _, replacement in replacement }
    }
    var value: CFTypeRef?
    let result = (
      status: SecItemCopyMatching(request as CFDictionary, &value),
      value: value)
    guard result.status == errSecSuccess, let data = result.value as? Data, !data.isEmpty else {
      throw OpenHarmonySigningError.secretUnavailable(
        "Keychain read status \(result.status)")
    }
    return data
  }

  static func nonInteractiveReadOptions() -> [String: Any] {
    // A LaunchAgent has no UI contract. `LAContext.interactionNotAllowed` is
    // the current API, while the explicit Security UI policy is also needed
    // by the legacy macOS Keychain ACL path used by `kSecAttrAccess`. Without
    // the latter, securityd can still wait for an invisible confirmation.
    let context = LAContext()
    context.interactionNotAllowed = true
    return [
      kSecUseAuthenticationContext as String: context,
      kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
    ]
  }

  public func contains(account: String) -> Bool {
    // Provider availability, health and status are read-only control-plane
    // queries. Asking Keychain for kSecValueData here made every such query a
    // secret decryption attempt; legacy ACL evaluation can wait on
    // SecurityAgent even when authentication UI is explicitly forbidden,
    // which in turn occupied the daemon actor and made the UDS look dead.
    // Query attributes only. Dispatch still validates exact daemon identity
    // and private presets still perform the non-interactive value read before
    // the signer is launched, so an unavailable secret remains fail-closed.
    var value: CFTypeRef?
    return SecItemCopyMatching(
      Self.presenceQuery(account: account) as CFDictionary, &value) == errSecSuccess
  }

  static func presenceQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: OpenHarmonyLocalSigning.keychainService,
      kSecAttrAccount as String: account,
      kSecReturnAttributes as String: true,
      kSecReturnData as String: false,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
    ]
  }

  package func refreshTrustedApplicationAccess(account: String) throws {
    let status = SecItemUpdate(
      query(account: account) as CFDictionary,
      [kSecAttrAccess as String: try trustedApplicationAccess()] as CFDictionary)
    guard status == errSecSuccess else {
      throw OpenHarmonySigningError.secretUnavailable(
        "Keychain trusted-application update status \(status)")
    }
  }

  package func trustedDaemonApplicationSHA256() throws -> String? {
    let daemonApplication = try trustedApplications().daemon
    var staticCode: SecStaticCode?
    let createStatus = SecStaticCodeCreateWithPath(
      agentDaemonURL as CFURL, SecCSFlags(), &staticCode)
    guard createStatus == errSecSuccess, let staticCode else {
      throw OpenHarmonySigningError.secretUnavailable(
        "could not inspect arkdeck-agentd signing identity (status \(createStatus))")
    }
    let validityStatus = SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil)
    guard validityStatus == errSecSuccess else {
      throw OpenHarmonySigningError.secretUnavailable(
        "arkdeck-agentd code signature is invalid (status \(validityStatus))")
    }
    var applicationIdentity: CFData?
    let identityStatus = SecTrustedApplicationCopyData(
      daemonApplication, &applicationIdentity)
    guard identityStatus == errSecSuccess, let applicationIdentity else {
      throw OpenHarmonySigningError.secretUnavailable(
        "could not read arkdeck-agentd Keychain ACL identity (status \(identityStatus))")
    }
    // `SecTrustedApplicationCopyData` is opaque and may remain stable across
    // ad-hoc rebuilds that share a code-signing identity. The ACL still has
    // to be recreated for the exact installed daemon bytes: otherwise a
    // replacement can be mistaken for the previously authorised executable
    // and the first headless read waits on SecurityAgent. Bind both facts in
    // one domain-separated receipt fingerprint.
    let executableSHA256 = try Self.streamedSHA256(agentDaemonURL)
    return Self.trustedApplicationFingerprint(
      applicationIdentity: applicationIdentity as Data,
      executableSHA256: executableSHA256)
  }

  static func trustedApplicationFingerprint(
    applicationIdentity: Data,
    executableSHA256: Data
  ) -> String {
    precondition(executableSHA256.count == SHA256.byteCount)
    var hasher = SHA256()
    hasher.update(data: Data("arkdeck-keychain-trusted-application-v1\0".utf8))
    hasher.update(data: applicationIdentity)
    hasher.update(data: executableSHA256)
    return SHA256Hex.hexString(hasher.finalize())
  }

  private static func streamedSHA256(_ url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return Data(hasher.finalize())
  }

  @discardableResult
  public func remove(account: String) throws -> Bool {
    let status = SecItemDelete(query(account: account) as CFDictionary)
    if status == errSecItemNotFound { return false }
    guard status == errSecSuccess else {
      throw OpenHarmonySigningError.secretUnavailable("Keychain delete status \(status)")
    }
    return true
  }

  private func query(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: OpenHarmonyLocalSigning.keychainService,
      kSecAttrAccount as String: account,
    ]
  }

  private func trustedApplicationAccess() throws -> SecAccess {
    let applications = try trustedApplications()
    var keychainAccess: SecAccess?
    let accessStatus = SecAccessCreate(
      "ArkDeck OpenHarmony local signing" as CFString,
      [applications.current, applications.daemon] as CFArray,
      &keychainAccess)
    guard accessStatus == errSecSuccess, let keychainAccess else {
      throw OpenHarmonySigningError.secretUnavailable(
        "could not create the signing Keychain ACL (status \(accessStatus))")
    }
    return keychainAccess
  }

  private func trustedApplications() throws -> (
    current: SecTrustedApplication, daemon: SecTrustedApplication
  ) {
    let daemonPath = agentDaemonURL.path
    var info = stat()
    guard agentDaemonURL.isFileURL, daemonPath.hasPrefix("/"),
      agentDaemonURL.path == agentDaemonURL.standardizedFileURL.path,
      agentDaemonURL.resolvingSymlinksInPath().standardizedFileURL.path == daemonPath,
      daemonPath.withCString({ lstat($0, &info) }) == 0,
      info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
      info.st_mode & 0o077 == 0, access(daemonPath, X_OK) == 0
    else {
      throw OpenHarmonySigningError.unsafeFile(
        "installed arkdeck-agentd is absent or unsafe for Keychain ACL")
    }

    var currentApplication: SecTrustedApplication?
    let currentStatus = SecTrustedApplicationCreateFromPath(nil, &currentApplication)
    guard currentStatus == errSecSuccess, let currentApplication else {
      throw OpenHarmonySigningError.secretUnavailable(
        "could not identify the ArkDeck CLI for Keychain ACL (status \(currentStatus))")
    }
    var daemonApplication: SecTrustedApplication?
    let daemonStatus = daemonPath.withCString {
      SecTrustedApplicationCreateFromPath($0, &daemonApplication)
    }
    guard daemonStatus == errSecSuccess, let daemonApplication else {
      throw OpenHarmonySigningError.secretUnavailable(
        "could not identify arkdeck-agentd for Keychain ACL (status \(daemonStatus))")
    }
    return (currentApplication, daemonApplication)
  }
}

package final class OpenHarmonySigningPresetStore: @unchecked Sendable {
  private let rootURL: URL
  private let receiptURL: URL
  private let secrets: any OpenHarmonySigningSecretStoring
  private let nowUTC: @Sendable () -> String
  private let fileManager: FileManager
  private let lock = NSLock()

  public init(
    rootURL: URL = OpenHarmonyLocalSigning.defaultRootURL(),
    secrets: any OpenHarmonySigningSecretStoring = LoginKeychainSigningSecretStore(),
    fileManager: FileManager = .default,
    nowUTC: @escaping @Sendable () -> String = OpenHarmonySigningPresetStore.utcNow
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.receiptURL = self.rootURL.appendingPathComponent("preset-v1.json")
    self.secrets = secrets
    self.fileManager = fileManager
    self.nowUTC = nowUTC
  }

  package var receiptPath: String { receiptURL.path }

  public func install(
    configuration: OpenHarmonySigningPresetConfiguration,
    keystorePassword: Data,
    keyPassword: Data
  ) throws -> OpenHarmonySigningPresetReceipt {
    try lock.withLock {
      try Self.validateIdentifier(configuration.presetID, name: "presetID")
      try Self.validateIdentifier(configuration.projectRef, name: "projectRef")
      guard configuration.presetID == OpenHarmonyLocalSigning.defaultPresetID else {
        throw OpenHarmonySigningError.invalidConfiguration(
          "only \(OpenHarmonyLocalSigning.defaultPresetID) is published")
      }
      guard configuration.signingAlgorithm == "SHA256withECDSA" else {
        throw OpenHarmonySigningError.invalidConfiguration(
          "key alias or signing algorithm is outside the closed preset")
      }
      try Self.validateKeyAlias(configuration.keyAlias)
      try Self.validateSecret(keystorePassword)
      try Self.validateSecret(keyPassword)
      let java = try Self.measure(
        configuration.javaExecutable, role: "java", mustBeExecutable: true)
      let jar = try Self.measure(configuration.signerJAR, role: "signer JAR")
      let keystore = try Self.measure(
        configuration.keystore, role: "keystore", ownerPrivate: true)
      let certificate = try Self.measure(
        configuration.appCertificate, role: "app certificate")
      let profile = try Self.measure(configuration.signedProfile, role: "signed profile")
      guard jar.path.hasSuffix(".jar"),
        keystore.path.hasSuffix(".p12") || keystore.path.hasSuffix(".jks"),
        certificate.path.hasSuffix(".pem") || certificate.path.hasSuffix(".cer"),
        profile.path.hasSuffix(".p7b")
      else {
        throw OpenHarmonySigningError.invalidConfiguration(
          "expected .jar, .p12/.jks, .pem/.cer and .p7b signing files")
      }
      let managedMaterialDirectory = configuration.managedMaterialDirectory.map {
        $0.standardizedFileURL
      }
      if let managedMaterialDirectory {
        let expectedParent = rootURL.standardizedFileURL.path
        let directoryPath = managedMaterialDirectory.path
        guard configuration.managedMaterialDirectory?.isFileURL == true,
          configuration.managedMaterialDirectory?.path == directoryPath,
          managedMaterialDirectory.deletingLastPathComponent().path == expectedParent,
          [keystore.path, certificate.path, profile.path].allSatisfy({
            URL(fileURLWithPath: $0).deletingLastPathComponent().path == directoryPath
          })
        else {
          throw OpenHarmonySigningError.invalidConfiguration(
            "managed SDK material must be one exact private preset-root child")
        }
      }
      // There is exactly one published preset. Keep its Keychain account
      // independent of the selected workspace, and store both passwords in
      // one envelope so install/update has one ACL boundary rather than one
      // SecurityAgent authorization per password.
      let accountPrefix = configuration.presetID
      let envelopePrefix = accountPrefix + "|secret-envelope-"
      let previousReceipt = try? JSONDecoder().decode(
        OpenHarmonySigningPresetReceipt.self,
        from: Data(contentsOf: receiptURL))
      let daemonIdentity = try secrets.trustedDaemonApplicationSHA256()
      let reusableEnvelope = previousReceipt.flatMap { previous -> String? in
        guard previous.presetID == configuration.presetID,
          previous.trustedDaemonApplicationSHA256 == daemonIdentity,
          previous.keychainAccessSchema == OpenHarmonyLocalSigning.keychainAccessSchema,
          let account = previous.secretEnvelopeAccount,
          account.hasPrefix(envelopePrefix),
          UUID(uuidString: String(account.dropFirst(envelopePrefix.count))) != nil,
          secrets.contains(account: account)
        else { return nil }
        return account
      }
      let envelopeAccount = reusableEnvelope
        ?? envelopePrefix + UUID().uuidString.lowercased()
      var legacyAccounts: [String] = []
      if let previousReceipt, previousReceipt.presetID == configuration.presetID {
        if let previousEnvelope = previousReceipt.secretEnvelopeAccount,
          previousEnvelope != envelopeAccount
        {
          legacyAccounts.append(previousEnvelope)
        } else if previousReceipt.secretEnvelopeAccount == nil {
          legacyAccounts.append(previousReceipt.keystorePasswordAccount)
          legacyAccounts.append(previousReceipt.keyPasswordAccount)
        }
        legacyAccounts.append(contentsOf: previousReceipt.legacyPasswordAccounts ?? [])
      }
      legacyAccounts = Array(Set(legacyAccounts.filter {
        $0 == accountPrefix + "|keystore" || $0 == accountPrefix + "|key"
          || ($0.hasPrefix(envelopePrefix)
            && UUID(uuidString: String($0.dropFirst(envelopePrefix.count))) != nil)
      })).sorted()
      let receipt = OpenHarmonySigningPresetReceipt(
        schemaVersion: "arkdeck-openharmony-signing/v1",
        installedAtUTC: nowUTC(), presetID: configuration.presetID,
        projectRef: configuration.projectRef, javaExecutable: java,
        signerJAR: jar, keystore: keystore, appCertificate: certificate,
        signedProfile: profile, keyAlias: configuration.keyAlias,
        signingAlgorithm: configuration.signingAlgorithm,
        keystorePasswordAccount: accountPrefix + "|keystore",
        keyPasswordAccount: accountPrefix + "|key",
        secretEnvelopeAccount: envelopeAccount,
        legacyPasswordAccounts: legacyAccounts.isEmpty ? nil : legacyAccounts,
        trustedDaemonApplicationSHA256: daemonIdentity,
        keychainAccessSchema: OpenHarmonyLocalSigning.keychainAccessSchema,
        managedMaterialDirectory: managedMaterialDirectory?.path)

      var envelope = try Self.encodeEnvelope(
        keystorePassword: keystorePassword, keyPassword: keyPassword)
      defer { envelope.resetBytes(in: 0..<envelope.count) }
      var previousEnvelopeData = reusableEnvelope.flatMap { try? secrets.read(account: $0) }
      defer {
        let count = previousEnvelopeData?.count ?? 0
        if count > 0 { previousEnvelopeData!.resetBytes(in: 0..<count) }
      }
      try createPrivateRoot()
      do {
        try secrets.set(envelope, account: envelopeAccount)
        try write(receipt)
      } catch {
        if let previousEnvelopeData {
          try? secrets.set(previousEnvelopeData, account: envelopeAccount)
        } else {
          _ = try? secrets.remove(account: envelopeAccount)
        }
        throw error
      }
      return receipt
    }
  }

  package func loadValidated(
    presetID: String = OpenHarmonyLocalSigning.defaultPresetID,
    requireSecrets: Bool = true
  ) throws -> OpenHarmonySigningPresetReceipt {
    try lock.withLock {
      try loadValidatedUnlocked(presetID: presetID, requireSecrets: requireSecrets)
    }
  }

  /// Converts DevEco-encrypted password strings that were stored by an older
  /// ArkDeck install into the plaintext expected by hapsigner. This is an
  /// explicit local maintenance boundary: Runtime Jobs never call it and
  /// never read the mutable DevEco material directory.
  package func normalizeDevEcoSecrets(
    presetID: String = OpenHarmonyLocalSigning.defaultPresetID
  ) throws -> OpenHarmonySigningSecretNormalization {
    try lock.withLock {
      let receipt = try loadValidatedUnlocked(
        presetID: presetID, requireSecrets: true)
      if let envelopeAccount = receipt.secretEnvelopeAccount {
        var envelopeData = try secrets.read(account: envelopeAccount)
        defer { envelopeData.resetBytes(in: 0..<envelopeData.count) }
        var envelope = try Self.decodeEnvelope(envelopeData)
        defer {
          envelope.keystorePassword.resetBytes(
            in: 0..<envelope.keystorePassword.count)
          envelope.keyPassword.resetBytes(in: 0..<envelope.keyPassword.count)
        }
        let keystoreURL = URL(fileURLWithPath: receipt.keystore.path)
        var normalizedKeystore = try OpenHarmonyDevEcoPasswordDecoder.decodeIfNeeded(
          envelope.keystorePassword, keystore: keystoreURL, fileManager: fileManager)
        defer { normalizedKeystore.resetBytes(in: 0..<normalizedKeystore.count) }
        var normalizedKey = try OpenHarmonyDevEcoPasswordDecoder.decodeIfNeeded(
          envelope.keyPassword, keystore: keystoreURL, fileManager: fileManager)
        defer { normalizedKey.resetBytes(in: 0..<normalizedKey.count) }
        let changedKeystore = normalizedKeystore != envelope.keystorePassword
        let changedKey = normalizedKey != envelope.keyPassword
        if changedKeystore || changedKey {
          var updatedEnvelope = try Self.encodeEnvelope(
            keystorePassword: normalizedKeystore, keyPassword: normalizedKey)
          defer { updatedEnvelope.resetBytes(in: 0..<updatedEnvelope.count) }
          try secrets.set(updatedEnvelope, account: envelopeAccount)
        }
        return OpenHarmonySigningSecretNormalization(
          presetID: receipt.presetID,
          normalizedKeystorePassword: changedKeystore,
          normalizedKeyPassword: changedKey)
      }
      var previousKeystore = try secrets.read(account: receipt.keystorePasswordAccount)
      defer { previousKeystore.resetBytes(in: 0..<previousKeystore.count) }
      var previousKey = try secrets.read(account: receipt.keyPasswordAccount)
      defer { previousKey.resetBytes(in: 0..<previousKey.count) }
      let keystoreURL = URL(fileURLWithPath: receipt.keystore.path)
      var normalizedKeystore = try OpenHarmonyDevEcoPasswordDecoder.decodeIfNeeded(
        previousKeystore, keystore: keystoreURL, fileManager: fileManager)
      defer { normalizedKeystore.resetBytes(in: 0..<normalizedKeystore.count) }
      var normalizedKey = try OpenHarmonyDevEcoPasswordDecoder.decodeIfNeeded(
        previousKey, keystore: keystoreURL, fileManager: fileManager)
      defer { normalizedKey.resetBytes(in: 0..<normalizedKey.count) }
      try Self.validateSecret(normalizedKeystore)
      try Self.validateSecret(normalizedKey)

      let changedKeystore = normalizedKeystore != previousKeystore
      let changedKey = normalizedKey != previousKey
      do {
        if changedKeystore {
          try secrets.set(normalizedKeystore, account: receipt.keystorePasswordAccount)
        }
        if changedKey {
          try secrets.set(normalizedKey, account: receipt.keyPasswordAccount)
        }
      } catch {
        do {
          try secrets.set(previousKeystore, account: receipt.keystorePasswordAccount)
          try secrets.set(previousKey, account: receipt.keyPasswordAccount)
        } catch {
          throw OpenHarmonySigningError.secretUnavailable(
            "DevEco password normalization failed and Keychain rollback was incomplete")
        }
        throw error
      }
      return OpenHarmonySigningSecretNormalization(
        presetID: receipt.presetID,
        normalizedKeystorePassword: changedKeystore,
        normalizedKeyPassword: changedKey)
    }
  }

  package func migrateToSecretEnvelope(
    keystorePassword: Data, keyPassword: Data,
    keyAlias: String? = nil,
    presetID: String = OpenHarmonyLocalSigning.defaultPresetID
  ) throws -> OpenHarmonySigningEnvelopeMigration {
    try lock.withLock {
      let receipt = try loadValidatedUnlocked(
        presetID: presetID, requireSecrets: false)
      try Self.validateSecret(keystorePassword)
      try Self.validateSecret(keyPassword)
      if let keyAlias {
        try Self.validateKeyAlias(keyAlias)
      }
      let migratedKeyAlias = keyAlias ?? receipt.keyAlias
      let daemonIdentity = try secrets.trustedDaemonApplicationSHA256()
      if let existing = receipt.secretEnvelopeAccount,
        receipt.trustedDaemonApplicationSHA256 == daemonIdentity,
        receipt.keychainAccessSchema == OpenHarmonyLocalSigning.keychainAccessSchema
      {
        // Reuse the existing ACL-bearing item, but never treat its value as
        // immutable. A corrected DevEco source must be able to replace stale
        // credentials without creating another Keychain authorization
        // boundary. Secret-store updates are atomic and intentionally leave
        // the item's trusted-application ACL unchanged.
        var replacement = try Self.encodeEnvelope(
          keystorePassword: keystorePassword, keyPassword: keyPassword)
        defer { replacement.resetBytes(in: 0..<replacement.count) }
        if migratedKeyAlias == receipt.keyAlias {
          try secrets.set(replacement, account: existing)
        } else {
          var previous = try secrets.read(account: existing)
          defer { previous.resetBytes(in: 0..<previous.count) }
          do {
            try secrets.set(replacement, account: existing)
            try write(
              Self.copyReceipt(
                receipt, secretEnvelopeAccount: existing,
                legacyPasswordAccounts: receipt.legacyPasswordAccounts,
                trustedDaemonApplicationSHA256: daemonIdentity,
                keychainAccessSchema: OpenHarmonyLocalSigning.keychainAccessSchema,
                keyAlias: migratedKeyAlias))
          } catch {
            do {
              try secrets.set(previous, account: existing)
            } catch {
              throw OpenHarmonySigningError.secretUnavailable(
                "signing alias migration failed and Keychain rollback was incomplete")
            }
            throw error
          }
        }
        return OpenHarmonySigningEnvelopeMigration(
          presetID: receipt.presetID, migrated: false,
          envelopeAccount: existing,
          legacyAccountCount: receipt.legacyPasswordAccounts?.count ?? 0)
      }
      let token = UUID().uuidString.lowercased()
      let envelopeAccount = receipt.presetID + "|secret-envelope-" + token
      var legacy = receipt.legacyPasswordAccounts ?? []
      if let previousEnvelope = receipt.secretEnvelopeAccount {
        legacy.append(previousEnvelope)
      } else {
        legacy.append(receipt.keystorePasswordAccount)
        legacy.append(receipt.keyPasswordAccount)
      }
      legacy = Array(Set(legacy)).sorted()
      var envelope = try Self.encodeEnvelope(
        keystorePassword: keystorePassword, keyPassword: keyPassword)
      defer { envelope.resetBytes(in: 0..<envelope.count) }
      try secrets.set(envelope, account: envelopeAccount)
      do {
        let migrated = Self.copyReceipt(
            receipt, secretEnvelopeAccount: envelopeAccount,
            legacyPasswordAccounts: legacy,
            trustedDaemonApplicationSHA256: daemonIdentity,
            keychainAccessSchema: OpenHarmonyLocalSigning.keychainAccessSchema,
            keyAlias: migratedKeyAlias)
        try write(migrated)
      } catch {
        _ = try? secrets.remove(account: envelopeAccount)
        throw error
      }
      return OpenHarmonySigningEnvelopeMigration(
        presetID: receipt.presetID, migrated: true,
        envelopeAccount: envelopeAccount, legacyAccountCount: legacy.count)
    }
  }

  /// Migrates existing secret bytes into one fresh Keychain envelope bound to
  /// the currently installed daemon identity. Updating an existing legacy
  /// `SecAccess` can make macOS authorize each ACL entry separately (several
  /// password windows for one maintenance action). A new envelope has one ACL
  /// creation boundary; the old item remains a receipt-tracked legacy item so
  /// a failed receipt write is reversible and removal still cleans it up.
  package func refreshTrustedApplicationAccess(
    presetID: String = OpenHarmonyLocalSigning.defaultPresetID
  ) throws {
    try lock.withLock {
      let receipt = try loadValidatedUnlocked(
        presetID: presetID, requireSecrets: false, allowLegacyAccessSchema: true)
      let daemonIdentity = try secrets.trustedDaemonApplicationSHA256()
      if receipt.trustedDaemonApplicationSHA256 == daemonIdentity,
        receipt.keychainAccessSchema == OpenHarmonyLocalSigning.keychainAccessSchema
      {
        return
      }
      var pair: (keystore: Data, key: Data)
      if Self.isManagedSDKReleasePreset(receipt) {
        // The SDK password is public and already used by the explicit SDK
        // installer. Re-create the Keychain envelope for the new exact daemon
        // identity without reading an obsolete ACL and triggering a password
        // dialog. Private presets still take the guarded read path below.
        pair = (
          OpenHarmonyLocalSigning.publicSDKReleasePassword(),
          OpenHarmonyLocalSigning.publicSDKReleasePassword())
      } else {
        pair = try secretPair(for: receipt)
      }
      defer {
        pair.keystore.resetBytes(in: 0..<pair.keystore.count)
        pair.key.resetBytes(in: 0..<pair.key.count)
      }
      var encoded = try Self.encodeEnvelope(
        keystorePassword: pair.keystore, keyPassword: pair.key)
      defer { encoded.resetBytes(in: 0..<encoded.count) }
      let envelopeAccount = receipt.presetID + "|secret-envelope-"
        + UUID().uuidString.lowercased()
      var legacy = receipt.legacyPasswordAccounts ?? []
      if let previousEnvelope = receipt.secretEnvelopeAccount {
        legacy.append(previousEnvelope)
      } else {
        legacy.append(receipt.keystorePasswordAccount)
        legacy.append(receipt.keyPasswordAccount)
      }
      legacy = Array(Set(legacy)).sorted()
      try secrets.set(encoded, account: envelopeAccount)
      do {
        try write(
          Self.copyReceipt(
            receipt, secretEnvelopeAccount: envelopeAccount,
            legacyPasswordAccounts: legacy,
            trustedDaemonApplicationSHA256: daemonIdentity,
            keychainAccessSchema: OpenHarmonyLocalSigning.keychainAccessSchema))
      } catch {
        _ = try? secrets.remove(account: envelopeAccount)
        throw error
      }
    }
  }

  package func secretPair(
    for receipt: OpenHarmonySigningPresetReceipt
  ) throws -> (keystore: Data, key: Data) {
    if Self.isManagedSDKReleasePreset(receipt) {
      // This credential is published with the official SDK and therefore has
      // no confidentiality value. Keep the receipt-tracked Keychain envelope
      // as the reversible installation/configuration fact requested by the
      // product, but do not decrypt it on the runtime hot path. Exact daemon
      // bytes, receipt schema and item presence are still checked before any
      // signer process can start. Private presets continue below and never use
      // this public credential path.
      guard receipt.keychainAccessSchema == OpenHarmonyLocalSigning.keychainAccessSchema,
        let envelope = receipt.secretEnvelopeAccount,
        secrets.contains(account: envelope)
      else {
        throw OpenHarmonySigningError.secretUnavailable(
          "managed SDK release Keychain envelope is absent or stale")
      }
      try validateTrustedDaemonIdentity(receipt)
      return (
        OpenHarmonyLocalSigning.publicSDKReleasePassword(),
        OpenHarmonyLocalSigning.publicSDKReleasePassword())
    }
    if let envelopeAccount = receipt.secretEnvelopeAccount {
      var encoded = try secrets.read(account: envelopeAccount)
      defer { encoded.resetBytes(in: 0..<encoded.count) }
      var envelope = try Self.decodeEnvelope(encoded)
      defer {
        envelope.keystorePassword.resetBytes(
          in: 0..<envelope.keystorePassword.count)
        envelope.keyPassword.resetBytes(in: 0..<envelope.keyPassword.count)
      }
      try Self.validateSecret(envelope.keystorePassword)
      try Self.validateSecret(envelope.keyPassword)
      return (
        Data(envelope.keystorePassword.map { $0 }),
        Data(envelope.keyPassword.map { $0 }))
    }
    let keystore = try secrets.read(account: receipt.keystorePasswordAccount)
    do {
      return (keystore, try secrets.read(account: receipt.keyPasswordAccount))
    } catch {
      var mutable = keystore
      mutable.resetBytes(in: 0..<mutable.count)
      throw error
    }
  }

  public func status() -> OpenHarmonySigningPresetStatus {
    guard fileManager.fileExists(atPath: receiptURL.path) else {
      return OpenHarmonySigningPresetStatus(
        installed: false, ready: false, receiptPath: receiptURL.path,
        presetID: nil, projectRef: nil, javaPath: nil, javaSHA256: nil,
        signerJARPath: nil, signerJARSHA256: nil,
        keystorePath: nil, keystoreSHA256: nil,
        appCertificatePath: nil, appCertificateSHA256: nil,
        signedProfilePath: nil, signedProfileSHA256: nil,
        keystorePasswordPresent: false, keyPasswordPresent: false,
        diagnostics: ["signing preset is not installed"])
    }
    let receipt = try? JSONDecoder().decode(
      OpenHarmonySigningPresetReceipt.self, from: (try? Data(contentsOf: receiptURL)) ?? Data())
    let envelopePresent = receipt?.secretEnvelopeAccount.map {
      secrets.contains(account: $0)
    }
    let keyStorePresent = envelopePresent ?? receipt.map {
      secrets.contains(account: $0.keystorePasswordAccount)
    } ?? false
    let keyPresent = envelopePresent ?? receipt.map {
      secrets.contains(account: $0.keyPasswordAccount)
    } ?? false
    var diagnostics: [String] = []
    do { _ = try loadValidated() } catch { diagnostics.append("\(error)") }
    return OpenHarmonySigningPresetStatus(
      installed: true, ready: diagnostics.isEmpty, receiptPath: receiptURL.path,
      presetID: receipt?.presetID, projectRef: receipt?.projectRef,
      javaPath: receipt?.javaExecutable.path,
      javaSHA256: receipt?.javaExecutable.sha256,
      signerJARPath: receipt?.signerJAR.path,
      signerJARSHA256: receipt?.signerJAR.sha256,
      keystorePath: receipt?.keystore.path,
      keystoreSHA256: receipt?.keystore.sha256,
      appCertificatePath: receipt?.appCertificate.path,
      appCertificateSHA256: receipt?.appCertificate.sha256,
      signedProfilePath: receipt?.signedProfile.path,
      signedProfileSHA256: receipt?.signedProfile.sha256,
      keystorePasswordPresent: keyStorePresent, keyPasswordPresent: keyPresent,
      diagnostics: diagnostics)
  }

  public func remove() throws -> OpenHarmonySigningPresetRemoval {
    try lock.withLock {
      let receipt = try? JSONDecoder().decode(
        OpenHarmonySigningPresetReceipt.self,
        from: (try? Data(contentsOf: receiptURL)) ?? Data())
      let managedMaterialURL: URL?
      if let managedPath = receipt?.managedMaterialDirectory {
        let expectedParent = rootURL.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: managedPath).standardizedFileURL
        guard managedPath == candidate.path,
          candidate.deletingLastPathComponent().path == expectedParent
        else {
          throw OpenHarmonySigningError.receiptUnavailable(
            "managed signing material path drifted outside the preset root")
        }
        managedMaterialURL = candidate
      } else {
        managedMaterialURL = nil
      }
      let accountPrefix = OpenHarmonyLocalSigning.defaultPresetID
      var accounts = [accountPrefix + "|keystore", accountPrefix + "|key"]
      if let envelope = receipt?.secretEnvelopeAccount { accounts.append(envelope) }
      accounts.append(contentsOf: receipt?.legacyPasswordAccounts ?? [])
      var removedAccounts: Set<String> = []
      for account in Set(accounts) where try secrets.remove(account: account) {
        removedAccounts.insert(account)
      }
      let removedEnvelope = receipt?.secretEnvelopeAccount.map {
        removedAccounts.contains($0)
      }
      let removedKeystore = removedEnvelope
        ?? removedAccounts.contains(accountPrefix + "|keystore")
      let removedKey = removedEnvelope
        ?? removedAccounts.contains(accountPrefix + "|key")
      let removedReceipt: Bool
      if fileManager.fileExists(atPath: receiptURL.path) {
        try fileManager.removeItem(at: receiptURL)
        removedReceipt = true
      } else {
        removedReceipt = false
      }
      var removedManagedMaterial = false
      if let managedMaterialURL {
        if fileManager.fileExists(atPath: managedMaterialURL.path) {
          try fileManager.removeItem(at: managedMaterialURL)
          removedManagedMaterial = true
        }
      }
      let preserved = receipt.map {
        $0.managedMaterialDirectory == nil
          ? [$0.keystore.path, $0.appCertificate.path, $0.signedProfile.path]
          : []
      } ?? []
      return OpenHarmonySigningPresetRemoval(
        removedReceipt: removedReceipt,
        removedKeystorePassword: removedKeystore,
        removedKeyPassword: removedKey,
        removedManagedMaterial: removedManagedMaterial,
        preservedSourcePaths: preserved)
    }
  }

  private func createPrivateRoot() throws {
    try fileManager.createDirectory(
      at: rootURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
  }

  private func loadValidatedUnlocked(
    presetID: String, requireSecrets: Bool,
    allowLegacyAccessSchema: Bool = false
  ) throws -> OpenHarmonySigningPresetReceipt {
    let receipt: OpenHarmonySigningPresetReceipt
    do {
      receipt = try JSONDecoder().decode(
        OpenHarmonySigningPresetReceipt.self, from: Data(contentsOf: receiptURL))
    } catch {
      throw OpenHarmonySigningError.receiptUnavailable("\(error)")
    }
    guard receipt.schemaVersion == "arkdeck-openharmony-signing/v1",
      receipt.presetID == presetID,
      receipt.keychainAccessSchema == nil
        || receipt.keychainAccessSchema == OpenHarmonyLocalSigning.keychainAccessSchema
        || (allowLegacyAccessSchema
          && receipt.keychainAccessSchema == "trusted-applications-v2")
    else {
      throw OpenHarmonySigningError.receiptUnavailable("schema or preset mismatch")
    }
    try Self.validateIdentifier(receipt.projectRef, name: "projectRef")
    let expectedAccountPrefix = receipt.presetID
    let expectedKeystoreAccount = expectedAccountPrefix + "|keystore"
    let expectedKeyAccount = expectedAccountPrefix + "|key"
    let envelopePrefix = expectedAccountPrefix + "|secret-envelope-"
    let envelopeIsValid = receipt.secretEnvelopeAccount.map {
      $0.hasPrefix(envelopePrefix)
        && UUID(uuidString: String($0.dropFirst(envelopePrefix.count))) != nil
    } ?? true
    let legacyAccountsAreValid = (receipt.legacyPasswordAccounts ?? []).allSatisfy {
      $0 == expectedKeystoreAccount || $0 == expectedKeyAccount
        || ($0.hasPrefix(envelopePrefix)
          && UUID(uuidString: String($0.dropFirst(envelopePrefix.count))) != nil)
    }
    guard receipt.signingAlgorithm == "SHA256withECDSA",
      Self.isValidKeyAlias(receipt.keyAlias),
      receipt.keystorePasswordAccount == expectedKeystoreAccount,
      receipt.keyPasswordAccount == expectedKeyAccount,
      envelopeIsValid, legacyAccountsAreValid,
      receipt.signerJAR.path.hasSuffix(".jar"),
      receipt.keystore.path.hasSuffix(".p12") || receipt.keystore.path.hasSuffix(".jks"),
      receipt.appCertificate.path.hasSuffix(".pem")
        || receipt.appCertificate.path.hasSuffix(".cer"),
      receipt.signedProfile.path.hasSuffix(".p7b")
    else {
      throw OpenHarmonySigningError.receiptUnavailable(
        "closed preset fields or Keychain accounts drifted")
    }
    if let managedPath = receipt.managedMaterialDirectory {
      let managedURL = URL(fileURLWithPath: managedPath).standardizedFileURL
      guard managedPath == managedURL.path,
        managedURL.deletingLastPathComponent().path == rootURL.standardizedFileURL.path,
        [receipt.keystore.path, receipt.appCertificate.path, receipt.signedProfile.path]
          .allSatisfy({
            URL(fileURLWithPath: $0).deletingLastPathComponent().path == managedPath
          })
      else {
        throw OpenHarmonySigningError.receiptUnavailable(
          "managed SDK signing material escaped its private preset directory")
      }
    }
    try Self.remeasure(receipt.javaExecutable, role: "java", mustBeExecutable: true)
    try Self.remeasure(receipt.signerJAR, role: "signer JAR")
    try Self.remeasure(receipt.keystore, role: "keystore", ownerPrivate: true)
    try Self.remeasure(receipt.appCertificate, role: "app certificate")
    try Self.remeasure(receipt.signedProfile, role: "signed profile")
    if requireSecrets {
      try validateTrustedDaemonIdentity(receipt)
      let secretsPresent: Bool
      if let envelope = receipt.secretEnvelopeAccount {
        secretsPresent = secrets.contains(account: envelope)
      } else {
        secretsPresent = secrets.contains(account: receipt.keystorePasswordAccount)
          && secrets.contains(account: receipt.keyPasswordAccount)
      }
      guard secretsPresent else {
        throw OpenHarmonySigningError.secretUnavailable("required Keychain item is absent")
      }
    }
    return receipt
  }

  private func validateTrustedDaemonIdentity(
    _ receipt: OpenHarmonySigningPresetReceipt
  ) throws {
    guard let expected = receipt.trustedDaemonApplicationSHA256 else { return }
    guard receipt.keychainAccessSchema == OpenHarmonyLocalSigning.keychainAccessSchema,
      let actual = try secrets.trustedDaemonApplicationSHA256(), actual == expected
    else {
      throw OpenHarmonySigningError.identityDrift(
        "installed arkdeck-agentd no longer matches the signing receipt")
    }
  }

  private static func encodeEnvelope(
    keystorePassword: Data, keyPassword: Data
  ) throws -> Data {
    try JSONEncoder().encode(
      OpenHarmonySigningSecretEnvelope(
        schemaVersion: "arkdeck-openharmony-signing-secret/v1",
        keystorePassword: keystorePassword, keyPassword: keyPassword))
  }

  private static func decodeEnvelope(_ data: Data) throws -> OpenHarmonySigningSecretEnvelope {
    let envelope: OpenHarmonySigningSecretEnvelope
    do {
      envelope = try JSONDecoder().decode(OpenHarmonySigningSecretEnvelope.self, from: data)
    } catch {
      throw OpenHarmonySigningError.secretUnavailable(
        "signing Keychain envelope is invalid")
    }
    guard envelope.schemaVersion == "arkdeck-openharmony-signing-secret/v1" else {
      throw OpenHarmonySigningError.secretUnavailable(
        "signing Keychain envelope schema is unsupported")
    }
    return envelope
  }

  private static func copyReceipt(
    _ receipt: OpenHarmonySigningPresetReceipt,
    secretEnvelopeAccount: String?, legacyPasswordAccounts: [String]?,
    trustedDaemonApplicationSHA256: String?,
    keychainAccessSchema: String? = nil,
    keyAlias: String? = nil
  ) -> OpenHarmonySigningPresetReceipt {
    OpenHarmonySigningPresetReceipt(
      schemaVersion: receipt.schemaVersion,
      installedAtUTC: receipt.installedAtUTC, presetID: receipt.presetID,
      projectRef: receipt.projectRef, javaExecutable: receipt.javaExecutable,
      signerJAR: receipt.signerJAR, keystore: receipt.keystore,
      appCertificate: receipt.appCertificate, signedProfile: receipt.signedProfile,
      keyAlias: keyAlias ?? receipt.keyAlias,
      signingAlgorithm: receipt.signingAlgorithm,
      keystorePasswordAccount: receipt.keystorePasswordAccount,
      keyPasswordAccount: receipt.keyPasswordAccount,
      secretEnvelopeAccount: secretEnvelopeAccount,
      legacyPasswordAccounts: legacyPasswordAccounts,
      trustedDaemonApplicationSHA256: trustedDaemonApplicationSHA256,
      keychainAccessSchema: keychainAccessSchema ?? receipt.keychainAccessSchema,
      managedMaterialDirectory: receipt.managedMaterialDirectory)
  }

  private static func isManagedSDKReleasePreset(
    _ receipt: OpenHarmonySigningPresetReceipt
  ) -> Bool {
    guard let managedPath = receipt.managedMaterialDirectory else { return false }
    return receipt.keyAlias == "openharmony application release"
      && receipt.keystore.path == managedPath + "/OpenHarmony.p12"
      && receipt.appCertificate.path == managedPath + "/OpenHarmonyApplicationRelease.pem"
      && receipt.signedProfile.path == managedPath + "/release-profile.p7b"
      && receipt.signerJAR.path.hasSuffix("/toolchains/lib/hap-sign-tool.jar")
  }

  private static func isValidKeyAlias(_ keyAlias: String) -> Bool {
    keyAlias.range(
      of: #"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}$"#,
      options: .regularExpression) != nil
  }

  private static func validateKeyAlias(_ keyAlias: String) throws {
    guard isValidKeyAlias(keyAlias) else {
      throw OpenHarmonySigningError.invalidConfiguration(
        "key alias is outside the closed preset")
    }
  }

  private func write(_ receipt: OpenHarmonySigningPresetReceipt) throws {
    let encoder = CanonicalJSONEncoders.canonicalPretty()
    let bytes = try encoder.encode(receipt)
    let temporary = rootURL.appendingPathComponent(".preset-\(UUID().uuidString).tmp")
    defer { try? fileManager.removeItem(at: temporary) }
    try bytes.write(to: temporary, options: [])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    let handle = try FileHandle(forWritingTo: temporary)
    try handle.synchronize()
    try handle.close()
    let renamed = temporary.path.withCString { source in
      receiptURL.path.withCString { destination in
        Darwin.rename(source, destination)
      }
    }
    guard renamed == 0 else {
      throw OpenHarmonySigningError.ioFailure(
        "could not atomically replace signing receipt (errno \(errno))")
    }
  }

  private static func validateIdentifier(_ value: String, name: String) throws {
    guard value.range(
      of: #"^[A-Za-z0-9][A-Za-z0-9._@-]{0,127}$"#,
      options: .regularExpression) != nil
    else { throw OpenHarmonySigningError.invalidConfiguration("\(name) is malformed") }
  }

  private static func validateSecret(_ secret: Data) throws {
    guard !secret.isEmpty, secret.count <= 4_096,
      !secret.contains(0), !secret.contains(10), !secret.contains(13)
    else { throw OpenHarmonySigningError.invalidConfiguration("password is empty or unbounded") }
  }

  package static func measure(
    _ candidate: URL, role: String,
    mustBeExecutable: Bool = false,
    ownerPrivate: Bool = false
  ) throws -> OpenHarmonySigningFileIdentity {
    let path = candidate.standardizedFileURL.path
    guard candidate.isFileURL, candidate.path.hasPrefix("/"), candidate.path == path,
      candidate.resolvingSymlinksInPath().standardizedFileURL.path == path
    else { throw OpenHarmonySigningError.unsafeFile("\(role) path is not canonical absolute") }
    var info = stat()
    guard path.withCString({ lstat($0, &info) }) == 0,
      info.st_mode & S_IFMT == S_IFREG, info.st_size > 0,
      info.st_size <= 512 * 1_024 * 1_024
    else { throw OpenHarmonySigningError.unsafeFile("\(role) is not a bounded regular file") }
    guard info.st_mode & 0o022 == 0 else {
      throw OpenHarmonySigningError.unsafeFile("\(role) is group/world writable")
    }
    if ownerPrivate {
      guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
        throw OpenHarmonySigningError.unsafeFile("\(role) must be owned by this user and private")
      }
    }
    if mustBeExecutable, access(path, X_OK) != 0 {
      throw OpenHarmonySigningError.unsafeFile("\(role) is not executable")
    }
    let bytes = try Data(contentsOf: candidate, options: [.uncached])
    guard bytes.count == Int(info.st_size) else {
      throw OpenHarmonySigningError.unsafeFile("\(role) changed while hashing")
    }
    return OpenHarmonySigningFileIdentity(
      path: path,
      sha256: SHA256Hex.string(of: bytes),
      byteCount: bytes.count)
  }

  private static func remeasure(
    _ expected: OpenHarmonySigningFileIdentity, role: String,
    mustBeExecutable: Bool = false, ownerPrivate: Bool = false
  ) throws {
    let actual = try measure(
      URL(fileURLWithPath: expected.path), role: role,
      mustBeExecutable: mustBeExecutable, ownerPrivate: ownerPrivate)
    guard actual == expected else {
      throw OpenHarmonySigningError.identityDrift(role)
    }
  }

  package static func utcNow() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}

package struct OpenHarmonySigningAttemptPaths: Codable, Sendable, Equatable {
  public let directory: String
  package let signedHAP: String
  package let certificateChainReadback: String
  package let profileReadback: String
  package let resultRecord: String

  /// Provider-owned typed staging path. Runtime Artifact payloads are named
  /// only by Artifact ID, but hap-sign-tool uses the `.hap` suffix while
  /// selecting its package/code-signing path. Keep this derived so durable
  /// actions written before this fix retain the same Codable shape.
  package var stagedUnsignedHAP: String {
    URL(fileURLWithPath: directory).appendingPathComponent("unsigned.hap").path
  }

  /// `verify-app` requires a `.cer` certificate-chain output. Early durable
  /// signing intents used the exact sibling name `certificate-chain.pem`.
  /// Preserve their Codable payload while mechanically recovering into the
  /// one supported sibling; no caller-controlled path is broadened.
  package var supportedCertificateChainReadback: String {
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    let legacy = root.appendingPathComponent("certificate-chain.pem").path
    guard certificateChainReadback == legacy else { return certificateChainReadback }
    return root.appendingPathComponent("certificate-chain.cer").path
  }
}

package final class OpenHarmonySigningAttemptStore: @unchecked Sendable {
  private let rootURL: URL
  private let fileManager: FileManager

  public init(rootURL: URL, fileManager: FileManager = .default) throws {
    self.rootURL = rootURL.standardizedFileURL
    self.fileManager = fileManager
    try fileManager.createDirectory(
      at: self.rootURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.rootURL.path)
  }

  package func paths(jobID: String) -> OpenHarmonySigningAttemptPaths {
    let digest = SHA256Hex.string(of: Data(jobID.utf8))
    let directory = rootURL.appendingPathComponent(String(digest.prefix(32)), isDirectory: true)
    return OpenHarmonySigningAttemptPaths(
      directory: directory.path,
      signedHAP: directory.appendingPathComponent("signed.hap").path,
      certificateChainReadback: directory.appendingPathComponent("certificate-chain.cer").path,
      profileReadback: directory.appendingPathComponent("profile-readback.p7b").path,
      resultRecord: directory.appendingPathComponent("signing-result.json").path)
  }

  public func cleanup(jobID: String) {
    try? fileManager.removeItem(atPath: paths(jobID: jobID).directory)
  }
}

public struct WorkspaceOpenHarmonySigningAction: Sendable, Equatable, Codable {
  let jobID: String
  let projectRef: String
  let preset: OpenHarmonySigningPresetReceipt
  let inputArtifactID: String
  let inputFilePath: String
  let inputSHA256: String
  let inputByteCount: Int
  let output: OpenHarmonySigningAttemptPaths

  var signArguments: [String] {
    [
      "-jar", preset.signerJAR.path, "sign-app",
      "-keyAlias", preset.keyAlias,
      "-signAlg", preset.signingAlgorithm,
      "-mode", "localSign",
      "-appCertFile", preset.appCertificate.path,
      "-profileFile", preset.signedProfile.path,
      "-inFile", output.stagedUnsignedHAP,
      "-keystoreFile", preset.keystore.path,
      "-outFile", output.signedHAP,
      "-pwdInputMode", "1",
    ]
  }

  var verifyArguments: [String] {
    [
      "-jar", preset.signerJAR.path, "verify-app",
      "-inFile", output.signedHAP,
      "-outCertChain", output.supportedCertificateChainReadback,
      "-outProfile", output.profileReadback,
    ]
  }
}

private struct OpenHarmonySigningResultRecord: Codable, Sendable, Equatable {
  let schemaVersion: String
  let summary: [String: String]
}

/// Keeps ordinary workspace commands on the existing descriptor-bound route
/// while giving only the closed signing action its PTY/Keychain protocol.
package struct OpenHarmonySigningWorkspaceDispatcher: RuntimeProcessDispatching {
  private let fallback: any RuntimeProcessDispatching
  private let presetStore: OpenHarmonySigningPresetStore

  public init(
    fallback: any RuntimeProcessDispatching,
    presetStore: OpenHarmonySigningPresetStore
  ) {
    self.fallback = fallback
    self.presetStore = presetStore
  }

  package func unavailableReason(providerID: String) -> String? {
    fallback.unavailableReason(providerID: providerID)
  }

  public func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    guard case .workspace(.signOpenHarmonyHap(let action)) = plan.action else {
      return try await fallback.dispatch(plan)
    }
    guard case .process(let executableSHA256, let arguments, let timeout) = plan.kind,
      executableSHA256 == action.preset.javaExecutable.sha256,
      arguments == action.signArguments, timeout == 600,
      plan.workingDirectory == action.output.directory
    else {
      throw RuntimeDispatchFailure.failed("signing plan drifted from its typed action")
    }
    let current: OpenHarmonySigningPresetReceipt
    do {
      current = try presetStore.loadValidated(presetID: action.preset.presetID)
      guard current == action.preset else {
        throw OpenHarmonySigningError.identityDrift("preset receipt")
      }
    } catch {
      throw RuntimeDispatchFailure.failed("signing preset unavailable before dispatch: \(error)")
    }
    let signerJAR: VerifiedRegularFileDescriptor
    do {
      signerJAR = try VerifiedRegularFileDescriptor.open(
        path: URL(fileURLWithPath: current.signerJAR.path),
        expectedSHA256: current.signerJAR.sha256)
    } catch {
      throw RuntimeDispatchFailure.failed(
        "signing JAR identity unavailable before dispatch")
    }
    defer { signerJAR.close() }

    var keystoreSecret = Data()
    var keySecret = Data()
    do {
      let pair = try presetStore.secretPair(for: current)
      keystoreSecret = pair.keystore
      keySecret = pair.key
    } catch {
      throw RuntimeDispatchFailure.failed("signing Keychain secret unavailable before dispatch")
    }
    defer {
      keystoreSecret.resetBytes(in: 0..<keystoreSecret.count)
      keySecret.resetBytes(in: 0..<keySecret.count)
    }

    var createdAttemptDirectory = false
    do {
      let input = try Self.measuredHAP(
        at: action.inputFilePath, maximumBytes: 64 * 1_024 * 1_024)
      guard input.byteCount == action.inputByteCount, input.sha256 == action.inputSHA256 else {
        throw OpenHarmonySigningError.identityDrift("input HAP")
      }
      try FileManager.default.createDirectory(
        atPath: action.output.directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      createdAttemptDirectory = true
      try Self.stageUnsignedHAP(action: action)
    } catch {
      if createdAttemptDirectory {
        try? FileManager.default.removeItem(atPath: action.output.directory)
      }
      throw RuntimeDispatchFailure.failed("signing admission refused before spawn: \(error)")
    }

    let stagedInput: VerifiedRegularFileDescriptor
    do {
      stagedInput = try VerifiedRegularFileDescriptor.open(
        path: URL(fileURLWithPath: action.output.stagedUnsignedHAP),
        expectedSHA256: action.inputSHA256)
    } catch {
      try? FileManager.default.removeItem(atPath: action.output.directory)
      throw RuntimeDispatchFailure.failed(
        "staged signing input identity unavailable before dispatch")
    }
    defer { stagedInput.close() }

    let started = Date()
    let ptyResult: IdentityBoundPTYExecutionResult
    do {
      ptyResult = try await IdentityBoundPTYExecutor().execute(
        ProcessIdentityBoundRequest(
          process: ProcessRequest(
            executable: URL(fileURLWithPath: action.preset.javaExecutable.path),
            arguments: try Self.identityBoundJARArguments(
              action.signArguments, action: action, descriptor: signerJAR),
            workingDirectory: URL(fileURLWithPath: action.output.directory, isDirectory: true),
            timeout: 600),
          expectedSHA256: action.preset.javaExecutable.sha256),
        interactions: [
          IdentityBoundPTYInteraction(
            expectedPrompt: Data("please input KeystorePwd (timeout 30 seconds):".utf8),
            secret: keystoreSecret),
          IdentityBoundPTYInteraction(
            expectedPrompt: Data("please input KeyPwd (timeout 30 seconds):".utf8),
            secret: keySecret),
        ], verifiedResources: [signerJAR, stagedInput])
    } catch {
      if case IdentityBoundPTYError.secretEchoDetected = error {
        throw RuntimeDispatchFailure.outcomeUnknown(
          "signing PTY privacyFailure requires readback")
      }
      throw RuntimeDispatchFailure.outcomeUnknown(
        "signing PTY outcome requires readback: \(Self.safePTYError(error))")
    }
    guard case .exited(0) = ptyResult.termination else {
      throw RuntimeDispatchFailure.outcomeUnknown(
        "hapsigner did not exit successfully (termination="
          + Self.safeTermination(ptyResult.termination)
          + "; completedPrompts=\(ptyResult.completedInteractions)"
          + "; observedOutputBytes=\(ptyResult.observedOutputByteCount)"
          + "; diagnosticCode=\(ptyResult.failureCategory.rawValue)); output requires readback")
    }

    do {
      let summary = try await Self.verifyAndRecord(action: action)
      let landed = try Self.measuredHAP(
        at: action.output.signedHAP, maximumBytes: 64 * 1_024 * 1_024)
      return ProviderProcessReceipt(
        exitStatus: 0, stdout: Data(), stderr: Data(), stdoutTruncated: false,
        durationSeconds: Date().timeIntervalSince(started),
        hostManagedRecordID: action.output.resultRecord,
        hostManagedSummary: summary,
        landedArtifact: ProviderLandedArtifact(
          localURL: URL(fileURLWithPath: action.output.signedHAP),
          byteCount: landed.byteCount, sha256: landed.sha256,
          leadingBytes: Data([0x50, 0x4b, 0x03, 0x04])))
    } catch {
      throw RuntimeDispatchFailure.outcomeUnknown(
        "signed output postflight requires recovery: \(error)")
    }
  }

  package static func verifyAndRecord(
    action: WorkspaceOpenHarmonySigningAction
  ) async throws -> [String: String] {
    try OpenHarmonySigningPresetStore.remeasureForDispatch(action.preset)
    let signerJAR = try VerifiedRegularFileDescriptor.open(
      path: URL(fileURLWithPath: action.preset.signerJAR.path),
      expectedSHA256: action.preset.signerJAR.sha256)
    defer { signerJAR.close() }
    for path in [
      action.output.supportedCertificateChainReadback, action.output.profileReadback,
    ] {
      if FileManager.default.fileExists(atPath: path) {
        try FileManager.default.removeItem(atPath: path)
      }
    }
    let result = try await FoundationProcessExecutor().executeIdentityBound(
      ProcessIdentityBoundRequest(
        process: ProcessRequest(
          executable: URL(fileURLWithPath: action.preset.javaExecutable.path),
          arguments: try identityBoundJARArguments(
            action.verifyArguments, action: action, descriptor: signerJAR),
          workingDirectory: URL(fileURLWithPath: action.output.directory, isDirectory: true),
          timeout: 120),
        expectedSHA256: action.preset.javaExecutable.sha256),
      verifiedResources: [signerJAR],
      captureLimit: 256 * 1_024)
    guard case .exited(0) = result.execution.termination,
      !result.execution.stdout.wasTruncated, !result.execution.stderr.wasTruncated
    else { throw OpenHarmonySigningError.ioFailure("verify-app did not complete exactly") }
    let signed = try measuredHAP(at: action.output.signedHAP, maximumBytes: 64 * 1_024 * 1_024)
    let chain = try measuredRegularFile(
      at: action.output.supportedCertificateChainReadback, maximumBytes: 4 * 1_024 * 1_024)
    let profile = try measuredRegularFile(
      at: action.output.profileReadback, maximumBytes: 16 * 1_024 * 1_024)
    let summary: [String: String] = [
      "verification": "verified",
      "projectRef": action.projectRef,
      "signingPresetRef": action.preset.presetID,
      "sourceArtifactId": action.inputArtifactID,
      "sourceSha256": action.inputSHA256,
      "sourceByteCount": String(action.inputByteCount),
      "javaSha256": action.preset.javaExecutable.sha256,
      "signerJarSha256": action.preset.signerJAR.sha256,
      "keystoreSha256": action.preset.keystore.sha256,
      "appCertificateSha256": action.preset.appCertificate.sha256,
      "signedProfileSha256": action.preset.signedProfile.sha256,
      "signedHapSha256": signed.sha256,
      "signedHapByteCount": String(signed.byteCount),
      "certificateChainReadbackSha256": chain.sha256,
      "profileReadbackSha256": profile.sha256,
    ]
    let record = OpenHarmonySigningResultRecord(
      schemaVersion: "arkdeck-openharmony-signing-result/v1", summary: summary)
    let encoder = CanonicalJSONEncoders.canonicalPretty()
    let bytes = try encoder.encode(record)
    let temporary = URL(fileURLWithPath: action.output.directory)
      .appendingPathComponent(".signing-result-\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try bytes.write(to: temporary, options: [])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    let handle = try FileHandle(forWritingTo: temporary)
    try handle.synchronize()
    try handle.close()
    try FileManager.default.moveItem(
      at: temporary, to: URL(fileURLWithPath: action.output.resultRecord))
    return summary
  }

  package static func readVerifiedResult(
    action: WorkspaceOpenHarmonySigningAction
  ) throws -> [String: String] {
    let record = try JSONDecoder().decode(
      OpenHarmonySigningResultRecord.self,
      from: Data(contentsOf: URL(fileURLWithPath: action.output.resultRecord)))
    guard record.schemaVersion == "arkdeck-openharmony-signing-result/v1",
      record.summary["sourceArtifactId"] == action.inputArtifactID,
      record.summary["sourceSha256"] == action.inputSHA256,
      record.summary["signingPresetRef"] == action.preset.presetID,
      let expected = record.summary["signedHapSha256"]
    else { throw OpenHarmonySigningError.ioFailure("signing result record is malformed") }
    let signed = try measuredHAP(at: action.output.signedHAP, maximumBytes: 64 * 1_024 * 1_024)
    guard signed.sha256 == expected,
      record.summary["signedHapByteCount"] == String(signed.byteCount)
    else { throw OpenHarmonySigningError.identityDrift("signed HAP recovery output") }
    return record.summary
  }

  package static func recoveredReceipt(
    action: WorkspaceOpenHarmonySigningAction
  ) async throws -> (summary: [String: String], receipt: ProviderProcessReceipt) {
    let summary: [String: String]
    if FileManager.default.fileExists(atPath: action.output.resultRecord) {
      summary = try readVerifiedResult(action: action)
    } else {
      summary = try await verifyAndRecord(action: action)
    }
    let signed = try measuredHAP(
      at: action.output.signedHAP, maximumBytes: 64 * 1_024 * 1_024)
    return (
      summary,
      ProviderProcessReceipt(
        exitStatus: 0, stdout: Data(), stderr: Data(), stdoutTruncated: false,
        durationSeconds: 0,
        hostManagedRecordID: action.output.resultRecord,
        hostManagedSummary: summary,
        landedArtifact: ProviderLandedArtifact(
          localURL: URL(fileURLWithPath: action.output.signedHAP),
          byteCount: signed.byteCount, sha256: signed.sha256,
          leadingBytes: Data([0x50, 0x4b, 0x03, 0x04]))))
  }

  private static func measuredHAP(
    at path: String, maximumBytes: Int
  ) throws -> (byteCount: Int, sha256: String) {
    let measured = try measuredRegularFile(at: path, maximumBytes: maximumBytes)
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    guard try handle.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
      throw OpenHarmonySigningError.unsafeFile("HAP is not a ZIP container")
    }
    return measured
  }

  private static func stageUnsignedHAP(
    action: WorkspaceOpenHarmonySigningAction
  ) throws {
    let source = URL(fileURLWithPath: action.inputFilePath)
    let destination = URL(fileURLWithPath: action.output.stagedUnsignedHAP)
    try FileManager.default.copyItem(at: source, to: destination)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: destination.path)
    let staged = try measuredHAP(
      at: destination.path, maximumBytes: 64 * 1_024 * 1_024)
    guard staged.byteCount == action.inputByteCount,
      staged.sha256 == action.inputSHA256
    else { throw OpenHarmonySigningError.identityDrift("staged input HAP") }
  }

  private static func measuredRegularFile(
    at path: String, maximumBytes: Int
  ) throws -> (byteCount: Int, sha256: String) {
    var info = stat()
    guard path.hasPrefix("/"), path.withCString({ lstat($0, &info) }) == 0,
      info.st_mode & S_IFMT == S_IFREG, info.st_size > 0,
      info.st_size <= maximumBytes
    else { throw OpenHarmonySigningError.unsafeFile("postflight file is absent or invalid") }
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: [.uncached])
    guard bytes.count == Int(info.st_size) else {
      throw OpenHarmonySigningError.identityDrift("postflight file changed while hashing")
    }
    return (
      bytes.count,
      SHA256Hex.string(of: bytes))
  }

  private static func safePTYError(_ error: any Error) -> String {
    switch error {
    case IdentityBoundPTYError.invalidInteraction: "invalidInteraction"
    case IdentityBoundPTYError.ptyAllocationFailed: "ptyAllocationFailed"
    case IdentityBoundPTYError.launchFailed: "launchFailed"
    case IdentityBoundPTYError.promptProtocolViolation: "promptProtocolViolation"
    case IdentityBoundPTYError.secretEchoDetected: "secretEchoDetected"
    case IdentityBoundPTYError.outputBudgetExceeded: "outputBudgetExceeded"
    case IdentityBoundPTYError.timedOut: "timedOut"
    case IdentityBoundPTYError.cancelled: "cancelled"
    case IdentityBoundPTYError.waitFailed: "waitFailed"
    default: "unclassifiedPTYFailure"
    }
  }

  private static func safeTermination(_ termination: ProcessTermination) -> String {
    switch termination {
    case .exited(let status): "exit:\(status)"
    case .signalled(let signal): "signal:\(signal)"
    case .timedOut: "timedOut"
    case .cancelled: "cancelled"
    case .waitFailed: "waitFailed"
    case .unrecognizedWaitStatus: "unrecognizedWaitStatus"
    }
  }

  private static func identityBoundJARArguments(
    _ arguments: [String],
    action: WorkspaceOpenHarmonySigningAction,
    descriptor: VerifiedRegularFileDescriptor
  ) throws -> [String] {
    guard arguments.count >= 2, arguments[0] == "-jar",
      arguments[1] == action.preset.signerJAR.path,
      descriptor.authorizedPath == action.preset.signerJAR.path,
      descriptor.sha256 == action.preset.signerJAR.sha256,
      descriptor.byteCount == action.preset.signerJAR.byteCount
    else { throw OpenHarmonySigningError.identityDrift("signer JAR arguments") }
    var bound = arguments
    bound[1] = descriptor.inodePath
    return bound
  }
}

extension OpenHarmonySigningPresetStore {
  package static func remeasureForDispatch(
    _ receipt: OpenHarmonySigningPresetReceipt
  ) throws {
    try remeasure(receipt.javaExecutable, role: "java", mustBeExecutable: true)
    try remeasure(receipt.signerJAR, role: "signer JAR")
    try remeasure(receipt.keystore, role: "keystore", ownerPrivate: true)
    try remeasure(receipt.appCertificate, role: "app certificate")
    try remeasure(receipt.signedProfile, role: "signed profile")
  }
}
