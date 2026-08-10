import ArkDeckCore
import ArkDeckProcess
import CryptoKit
import Darwin
import Foundation
import Security

public enum OpenHarmonyLocalSigning {
  public static let operationReference = "workspace.sign-openharmony-hap@1"
  public static let defaultPresetID = "openharmony-release@1"
  public static let defaultProjectRef = "demo-app"
  static let keychainService = "dev.arkdeck.openharmony-local-signing"

  public static func defaultRootURL() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ArkDeck/Signing/OpenHarmony", isDirectory: true)
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

public struct OpenHarmonySigningFileIdentity: Codable, Sendable, Equatable {
  public let path: String
  public let sha256: String
  public let byteCount: Int

  public init(path: String, sha256: String, byteCount: Int) {
    self.path = path
    self.sha256 = sha256
    self.byteCount = byteCount
  }
}

public struct OpenHarmonySigningPresetConfiguration: Sendable, Equatable {
  public let presetID: String
  public let projectRef: String
  public let javaExecutable: URL
  public let signerJAR: URL
  public let keystore: URL
  public let appCertificate: URL
  public let signedProfile: URL
  public let keyAlias: String
  public let signingAlgorithm: String

  public init(
    presetID: String = OpenHarmonyLocalSigning.defaultPresetID,
    projectRef: String = OpenHarmonyLocalSigning.defaultProjectRef,
    javaExecutable: URL,
    signerJAR: URL,
    keystore: URL,
    appCertificate: URL,
    signedProfile: URL,
    keyAlias: String,
    signingAlgorithm: String = "SHA256withECDSA"
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
  }
}

public struct OpenHarmonySigningPresetReceipt: Codable, Sendable, Equatable {
  public let schemaVersion: String
  public let installedAtUTC: String
  public let presetID: String
  public let projectRef: String
  public let javaExecutable: OpenHarmonySigningFileIdentity
  public let signerJAR: OpenHarmonySigningFileIdentity
  public let keystore: OpenHarmonySigningFileIdentity
  public let appCertificate: OpenHarmonySigningFileIdentity
  public let signedProfile: OpenHarmonySigningFileIdentity
  public let keyAlias: String
  public let signingAlgorithm: String
  public let keystorePasswordAccount: String
  public let keyPasswordAccount: String
}

public struct OpenHarmonySigningPresetStatus: Codable, Sendable, Equatable {
  public let installed: Bool
  public let ready: Bool
  public let receiptPath: String
  public let presetID: String?
  public let projectRef: String?
  public let javaPath: String?
  public let javaSHA256: String?
  public let signerJARPath: String?
  public let signerJARSHA256: String?
  public let keystorePath: String?
  public let keystoreSHA256: String?
  public let appCertificatePath: String?
  public let appCertificateSHA256: String?
  public let signedProfilePath: String?
  public let signedProfileSHA256: String?
  public let keystorePasswordPresent: Bool
  public let keyPasswordPresent: Bool
  public let diagnostics: [String]
}

public struct OpenHarmonySigningPresetRemoval: Codable, Sendable, Equatable {
  public let removedReceipt: Bool
  public let removedKeystorePassword: Bool
  public let removedKeyPassword: Bool
  public let preservedSourcePaths: [String]
}

public protocol OpenHarmonySigningSecretStoring: Sendable {
  func set(_ data: Data, account: String) throws
  func read(account: String) throws -> Data
  func contains(account: String) -> Bool
  @discardableResult func remove(account: String) throws -> Bool
}

public struct LoginKeychainSigningSecretStore: OpenHarmonySigningSecretStoring {
  public init() {}

  public func set(_ data: Data, account: String) throws {
    let identity = query(account: account)
    let update = SecItemUpdate(
      identity as CFDictionary,
      [kSecValueData as String: data] as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else {
      throw OpenHarmonySigningError.secretUnavailable("Keychain update status \(update)")
    }
    var add = identity
    add[kSecValueData as String] = data
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw OpenHarmonySigningError.secretUnavailable("Keychain add status \(status)")
    }
  }

  public func read(account: String) throws -> Data {
    var request = query(account: account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
      throw OpenHarmonySigningError.secretUnavailable("Keychain read status \(status)")
    }
    return data
  }

  public func contains(account: String) -> Bool {
    var request = query(account: account)
    request[kSecReturnAttributes as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    return SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess
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
}

public final class OpenHarmonySigningPresetStore: @unchecked Sendable {
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

  public var receiptPath: String { receiptURL.path }

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
      guard configuration.signingAlgorithm == "SHA256withECDSA",
        configuration.keyAlias.range(
          of: #"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}$"#,
          options: .regularExpression) != nil
      else {
        throw OpenHarmonySigningError.invalidConfiguration(
          "key alias or signing algorithm is outside the closed preset")
      }
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
      // There is exactly one published preset. Keep its Keychain accounts
      // independent of the selected workspace so an update cannot strand
      // secrets under an obsolete project reference.
      let accountPrefix = configuration.presetID
      let receipt = OpenHarmonySigningPresetReceipt(
        schemaVersion: "arkdeck-openharmony-signing/v1",
        installedAtUTC: nowUTC(), presetID: configuration.presetID,
        projectRef: configuration.projectRef, javaExecutable: java,
        signerJAR: jar, keystore: keystore, appCertificate: certificate,
        signedProfile: profile, keyAlias: configuration.keyAlias,
        signingAlgorithm: configuration.signingAlgorithm,
        keystorePasswordAccount: accountPrefix + "|keystore",
        keyPasswordAccount: accountPrefix + "|key")

      var previousKeystorePassword = try snapshotSecret(
        account: receipt.keystorePasswordAccount)
      defer {
        if previousKeystorePassword != nil {
          let count = previousKeystorePassword!.count
          previousKeystorePassword!.resetBytes(in: 0..<count)
        }
      }
      var previousKeyPassword = try snapshotSecret(account: receipt.keyPasswordAccount)
      defer {
        if previousKeyPassword != nil {
          let count = previousKeyPassword!.count
          previousKeyPassword!.resetBytes(in: 0..<count)
        }
      }
      try createPrivateRoot()
      do {
        try secrets.set(keystorePassword, account: receipt.keystorePasswordAccount)
        try secrets.set(keyPassword, account: receipt.keyPasswordAccount)
        try write(receipt)
      } catch {
        do {
          try restoreSecret(
            previousKeystorePassword, account: receipt.keystorePasswordAccount)
          try restoreSecret(previousKeyPassword, account: receipt.keyPasswordAccount)
        } catch {
          throw OpenHarmonySigningError.secretUnavailable(
            "signing preset update failed and Keychain rollback was incomplete")
        }
        throw error
      }
      return receipt
    }
  }

  public func loadValidated(
    presetID: String = OpenHarmonyLocalSigning.defaultPresetID,
    requireSecrets: Bool = true
  ) throws -> OpenHarmonySigningPresetReceipt {
    try lock.withLock {
      let receipt: OpenHarmonySigningPresetReceipt
      do {
        receipt = try JSONDecoder().decode(
          OpenHarmonySigningPresetReceipt.self, from: Data(contentsOf: receiptURL))
      } catch {
        throw OpenHarmonySigningError.receiptUnavailable("\(error)")
      }
      guard receipt.schemaVersion == "arkdeck-openharmony-signing/v1",
        receipt.presetID == presetID
      else {
        throw OpenHarmonySigningError.receiptUnavailable("schema or preset mismatch")
      }
      try Self.validateIdentifier(receipt.projectRef, name: "projectRef")
      let expectedAccountPrefix = receipt.presetID
      guard receipt.signingAlgorithm == "SHA256withECDSA",
        receipt.keyAlias.range(
          of: #"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}$"#,
          options: .regularExpression) != nil,
        receipt.keystorePasswordAccount == expectedAccountPrefix + "|keystore",
        receipt.keyPasswordAccount == expectedAccountPrefix + "|key",
        receipt.signerJAR.path.hasSuffix(".jar"),
        receipt.keystore.path.hasSuffix(".p12") || receipt.keystore.path.hasSuffix(".jks"),
        receipt.appCertificate.path.hasSuffix(".pem")
          || receipt.appCertificate.path.hasSuffix(".cer"),
        receipt.signedProfile.path.hasSuffix(".p7b")
      else {
        throw OpenHarmonySigningError.receiptUnavailable(
          "closed preset fields or Keychain accounts drifted")
      }
      try Self.remeasure(receipt.javaExecutable, role: "java", mustBeExecutable: true)
      try Self.remeasure(receipt.signerJAR, role: "signer JAR")
      try Self.remeasure(receipt.keystore, role: "keystore", ownerPrivate: true)
      try Self.remeasure(receipt.appCertificate, role: "app certificate")
      try Self.remeasure(receipt.signedProfile, role: "signed profile")
      if requireSecrets {
        guard secrets.contains(account: receipt.keystorePasswordAccount),
          secrets.contains(account: receipt.keyPasswordAccount)
        else {
          throw OpenHarmonySigningError.secretUnavailable("required Keychain item is absent")
        }
      }
      return receipt
    }
  }

  public func secretPair(
    for receipt: OpenHarmonySigningPresetReceipt
  ) throws -> (keystore: Data, key: Data) {
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
    let keyStorePresent = receipt.map {
      secrets.contains(account: $0.keystorePasswordAccount)
    } ?? false
    let keyPresent = receipt.map { secrets.contains(account: $0.keyPasswordAccount) } ?? false
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
      let accountPrefix = OpenHarmonyLocalSigning.defaultPresetID
      let removedKeystore = try secrets.remove(account: accountPrefix + "|keystore")
      let removedKey = try secrets.remove(account: accountPrefix + "|key")
      let removedReceipt: Bool
      if fileManager.fileExists(atPath: receiptURL.path) {
        try fileManager.removeItem(at: receiptURL)
        removedReceipt = true
      } else {
        removedReceipt = false
      }
      let preserved = receipt.map {
        [$0.keystore.path, $0.appCertificate.path, $0.signedProfile.path]
      } ?? []
      return OpenHarmonySigningPresetRemoval(
        removedReceipt: removedReceipt,
        removedKeystorePassword: removedKeystore,
        removedKeyPassword: removedKey,
        preservedSourcePaths: preserved)
    }
  }

  private func createPrivateRoot() throws {
    try fileManager.createDirectory(
      at: rootURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
  }

  private func snapshotSecret(account: String) throws -> Data? {
    guard secrets.contains(account: account) else { return nil }
    return try secrets.read(account: account)
  }

  private func restoreSecret(_ previous: Data?, account: String) throws {
    if let previous {
      try secrets.set(previous, account: account)
    } else {
      _ = try secrets.remove(account: account)
    }
  }

  private func write(_ receipt: OpenHarmonySigningPresetReceipt) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
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
      sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
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

  public static func utcNow() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}

public struct OpenHarmonySigningAttemptPaths: Codable, Sendable, Equatable {
  public let directory: String
  public let signedHAP: String
  public let certificateChainReadback: String
  public let profileReadback: String
  public let resultRecord: String
}

public final class OpenHarmonySigningAttemptStore: @unchecked Sendable {
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

  public func paths(jobID: String) -> OpenHarmonySigningAttemptPaths {
    let digest = SHA256.hash(data: Data(jobID.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let directory = rootURL.appendingPathComponent(String(digest.prefix(32)), isDirectory: true)
    return OpenHarmonySigningAttemptPaths(
      directory: directory.path,
      signedHAP: directory.appendingPathComponent("signed.hap").path,
      certificateChainReadback: directory.appendingPathComponent("certificate-chain.pem").path,
      profileReadback: directory.appendingPathComponent("profile-readback.p7b").path,
      resultRecord: directory.appendingPathComponent("signing-result.json").path)
  }

  public func prepareFresh(jobID: String) throws -> OpenHarmonySigningAttemptPaths {
    let paths = paths(jobID: jobID)
    guard !fileManager.fileExists(atPath: paths.directory) else {
      throw OpenHarmonySigningError.ioFailure("signing attempt directory already exists")
    }
    try fileManager.createDirectory(
      atPath: paths.directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    return paths
  }

  public func cleanup(jobID: String) {
    try? fileManager.removeItem(atPath: paths(jobID: jobID).directory)
  }
}

package struct WorkspaceOpenHarmonySigningAction: Sendable, Equatable, Codable {
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
      "-inFile", inputFilePath,
      "-keystoreFile", preset.keystore.path,
      "-outFile", output.signedHAP,
      "-signCode", "1",
      "-pwdInputMode", "1",
    ]
  }

  var verifyArguments: [String] {
    [
      "-jar", preset.signerJAR.path, "verify-app",
      "-inFile", output.signedHAP,
      "-outCertchain", output.certificateChainReadback,
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
public struct OpenHarmonySigningWorkspaceDispatcher: RuntimeProcessDispatching {
  private let fallback: any RuntimeProcessDispatching
  private let presetStore: OpenHarmonySigningPresetStore

  public init(
    fallback: any RuntimeProcessDispatching,
    presetStore: OpenHarmonySigningPresetStore
  ) {
    self.fallback = fallback
    self.presetStore = presetStore
  }

  public func unavailableReason(providerID: String) -> String? {
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

    do {
      let input = try Self.measuredHAP(
        at: action.inputFilePath, maximumBytes: 64 * 1_024 * 1_024)
      guard input.byteCount == action.inputByteCount, input.sha256 == action.inputSHA256 else {
        throw OpenHarmonySigningError.identityDrift("input HAP")
      }
      try FileManager.default.createDirectory(
        atPath: action.output.directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw RuntimeDispatchFailure.failed("signing admission refused before spawn: \(error)")
    }

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
        ], verifiedResources: [signerJAR])
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
        "hapsigner did not exit successfully; output requires readback")
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
    for path in [action.output.certificateChainReadback, action.output.profileReadback] {
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
      at: action.output.certificateChainReadback, maximumBytes: 4 * 1_024 * 1_024)
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
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
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
      SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
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
