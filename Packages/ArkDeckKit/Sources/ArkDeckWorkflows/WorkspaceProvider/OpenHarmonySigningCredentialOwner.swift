import ArkDeckCore
import Darwin
import Foundation

/// The path-free identity of the one installed OpenHarmony signing credential.
///
/// The existing signing store owns measured files and the Keychain envelope.
/// This owner adds the missing resource lifecycle around that store: a
/// workspace preset pins an exact content reference, and maintenance cannot
/// replace or remove it while any preset still depends on it.
package struct OpenHarmonySigningCredentialResource: Sendable, Equatable {
  package let credentialRef: String
  package let projectRef: String
  package let presetID: String
  package let installedAtUTC: String
  package let referenceCount: Int

  package var projection: JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.signing-credential/1"),
      "credentialRef": .string(credentialRef),
      "kind": .string("openharmony-signing"),
      "projectRef": .string(projectRef),
      "presetId": .string(presetID),
      "installedAtUtc": .string(installedAtUTC),
      "referenceCount": .integer(Int64(referenceCount)),
      "state": .string("available"),
    ])
  }
}

package final class OpenHarmonySigningCredentialOwner: @unchecked Sendable {
  private struct OwnerLock {
    let directoryFD: Int32
    let lockFD: Int32

    func close() {
      flock(lockFD, LOCK_UN)
      Darwin.close(lockFD)
      Darwin.close(directoryFD)
    }
  }

  private struct Ledger: Codable, Equatable {
    var schemaVersion = "arkdeck.signing-credential-owner/1"
    var state = "stable"
    var credentialRef: String?
    var presetOwners: [String] = []
  }

  private struct ReferenceIdentity: Codable {
    let schemaVersion: String
    let installedAtUTC: String
    let presetID: String
    let projectRef: String
    let javaSHA256: String
    let javaByteCount: Int
    let signerJARSHA256: String
    let signerJARByteCount: Int
    let keystoreSHA256: String
    let keystoreByteCount: Int
    let appCertificateSHA256: String
    let appCertificateByteCount: Int
    let signedProfileSHA256: String
    let signedProfileByteCount: Int
    let keyAlias: String
    let signingAlgorithm: String
  }

  private static let ledgerName = "credential-owner-v1.json"
  private static let lockName = ".credential-owner.lock"
  private static let maximumLedgerBytes = 256 * 1_024

  private let store: OpenHarmonySigningPresetStore
  private let rootURL: URL

  package init(store: OpenHarmonySigningPresetStore) {
    self.store = store
    self.rootURL = store.credentialOwnerRootURL
  }

  /// The installed receipt, or `nil` only when the preset root positively
  /// holds none.
  ///
  /// A receipt this build cannot honour is an error here, never an absence.
  /// Collapsing the two is what let an interrupted replace, or a missing
  /// ledger beside an unsupported receipt, durably publish a stable owner
  /// with no credential over material that was still on disk — after which
  /// `replace` and `remove` were free to run against it.
  private func installedReceipt() throws -> OpenHarmonySigningPresetReceipt? {
    switch store.receiptState() {
    case .absent: return nil
    case .installed(let receipt): return receipt
    case .unusable(let error): throw error
    }
  }

  package func current() throws -> OpenHarmonySigningCredentialResource {
    try withOwnerLock { rootFD in
      let (ledger, receipt) = try loadAndRecover(rootFD: rootFD)
      guard let receipt, let reference = ledger.credentialRef else {
        throw OpenHarmonySigningError.receiptUnavailable(
          "signing credential is not installed")
      }
      return resource(receipt: receipt, reference: reference, owners: ledger.presetOwners)
    }
  }

  package func resolve(
    _ reference: String, owner presetRef: String? = nil,
    requireSecrets: Bool = true
  ) throws -> OpenHarmonySigningPresetReceipt {
    try withOwnerLock { rootFD in
      let (ledger, receipt) = try loadAndRecover(rootFD: rootFD)
      guard ledger.state == "stable", ledger.credentialRef == reference,
        let receipt
      else {
        throw OpenHarmonySigningError.receiptUnavailable(
          "signing credential reference is absent or stale")
      }
      if let presetRef {
        try validateOwner(presetRef)
        guard ledger.presetOwners.contains(presetRef) else {
          throw OpenHarmonySigningError.receiptUnavailable(
            "workspace preset does not own the signing credential")
        }
      }
      let validated = try store.loadValidated(
        presetID: receipt.presetID, requireSecrets: requireSecrets)
      try revalidateOwnerDirectory(rootFD)
      guard validated == receipt else {
        throw OpenHarmonySigningError.identityDrift("signing credential receipt")
      }
      return validated
    }
  }

  package func acquire(_ reference: String, owner presetRef: String) throws {
    try validateOwner(presetRef)
    try withOwnerLock { rootFD in
      var (ledger, receipt) = try loadAndRecover(rootFD: rootFD)
      guard ledger.state == "stable", ledger.credentialRef == reference,
        let receipt
      else {
        throw OpenHarmonySigningError.receiptUnavailable(
          "signing credential reference is absent or stale")
      }
      _ = try store.loadValidated(presetID: receipt.presetID, requireSecrets: true)
      try revalidateOwnerDirectory(rootFD)
      if !ledger.presetOwners.contains(presetRef) {
        guard ledger.presetOwners.count < 4_096 else {
          throw OpenHarmonySigningError.invalidConfiguration(
            "signing credential workspace preset reference limit is reached")
        }
        ledger.presetOwners.append(presetRef)
        ledger.presetOwners.sort()
        try save(ledger, rootFD: rootFD)
      }
    }
  }

  package func release(_ reference: String, owner presetRef: String) throws {
    try validateOwner(presetRef)
    try withOwnerLock { rootFD in
      var (ledger, _) = try loadAndRecover(rootFD: rootFD)
      guard ledger.state == "stable", ledger.credentialRef == reference else {
        throw OpenHarmonySigningError.receiptUnavailable(
          "signing credential reference is absent or stale")
      }
      let previous = ledger.presetOwners
      ledger.presetOwners.removeAll { $0 == presetRef }
      if ledger.presetOwners != previous { try save(ledger, rootFD: rootFD) }
    }
  }

  /// Replaces the installed receipt only while no workspace preset owns it.
  /// The durable `replacing` marker makes a crash after the receipt write
  /// recover by adopting the exact receipt that actually landed.
  package func replace<T>(
    _ body: () throws -> T
  ) throws -> (T, OpenHarmonySigningCredentialResource) {
    try withOwnerLock { rootFD in
      var ledger = try ledgerForMutation(rootFD: rootFD)
      ledger.state = "replacing"
      try save(ledger, rootFD: rootFD)
      do {
        let value = try body()
        let receipt = try store.loadValidated(requireSecrets: true)
        let reference = try Self.reference(for: receipt)
        ledger = Ledger(
          state: "stable", credentialRef: reference, presetOwners: [])
        try save(ledger, rootFD: rootFD)
        return (value, resource(receipt: receipt, reference: reference, owners: []))
      } catch {
        _ = try? recoverMutation(rootFD: rootFD, ledger: ledger)
        throw error
      }
    }
  }

  package func replace<T: Sendable>(
    _ body: () async throws -> T
  ) async throws -> (T, OpenHarmonySigningCredentialResource) {
    let ownerLock = try lockOwner()
    defer { ownerLock.close() }
    let rootFD = ownerLock.directoryFD
    var ledger = try ledgerForMutation(rootFD: rootFD)
    ledger.state = "replacing"
    try save(ledger, rootFD: rootFD)
    do {
      let value = try await body()
      let receipt = try store.loadValidated(requireSecrets: true)
      let reference = try Self.reference(for: receipt)
      ledger = Ledger(state: "stable", credentialRef: reference, presetOwners: [])
      try save(ledger, rootFD: rootFD)
      return (value, resource(receipt: receipt, reference: reference, owners: []))
    } catch {
      _ = try? recoverMutation(rootFD: rootFD, ledger: ledger)
      throw error
    }
  }

  /// Storage/ACL maintenance may run while a preset is registered, but it
  /// must preserve the public credential identity exactly.
  package func maintain<T>(_ body: () throws -> T) throws -> T {
    try withOwnerLock { rootFD in
      let (ledger, beforeReceipt) = try loadAndRecover(rootFD: rootFD)
      let before = try beforeReceipt.map(Self.reference(for:))
      let value = try body()
      try revalidateOwnerDirectory(rootFD)
      let afterReceipt = try installedReceipt()
      try revalidateOwnerDirectory(rootFD)
      let after = try afterReceipt.map(Self.reference(for:))
      guard before == after, ledger.credentialRef == after else {
        throw OpenHarmonySigningError.identityDrift(
          "signing credential maintenance changed its public identity")
      }
      return value
    }
  }

  package func remove<T>(_ body: () throws -> T) throws -> T {
    try withOwnerLock { rootFD in
      var ledger = try ledgerForMutation(rootFD: rootFD)
      ledger.state = "removing"
      try save(ledger, rootFD: rootFD)
      do {
        let value = try body()
        ledger = Ledger()
        try save(ledger, rootFD: rootFD)
        return value
      } catch {
        _ = try? recoverMutation(rootFD: rootFD, ledger: ledger)
        throw error
      }
    }
  }

  private func loadAndRecover(
    rootFD: Int32
  ) throws -> (Ledger, OpenHarmonySigningPresetReceipt?) {
    var ledger = try readLedger(rootFD: rootFD)
    if ledger.state != "stable" {
      ledger = try recoverMutation(rootFD: rootFD, ledger: ledger)
    }
    let receipt = try installedReceipt()
    try revalidateOwnerDirectory(rootFD)
    let actualReference = try receipt.map(Self.reference(for:))
    guard ledger.schemaVersion == "arkdeck.signing-credential-owner/1",
      ledger.state == "stable", ledger.presetOwners.count <= 4_096,
      ledger.presetOwners == ledger.presetOwners.sorted(),
      Set(ledger.presetOwners).count == ledger.presetOwners.count,
      ledger.presetOwners.allSatisfy(AgentExecutionIntent.validIdentifier),
      ledger.credentialRef == actualReference
    else {
      throw OpenHarmonySigningError.receiptUnavailable(
        "signing credential owner ledger does not match the installed receipt")
    }
    return (ledger, receipt)
  }

  private func recoverMutation(rootFD: Int32, ledger: Ledger) throws -> Ledger {
    guard ["replacing", "removing"].contains(ledger.state),
      ledger.presetOwners.isEmpty
    else {
      throw OpenHarmonySigningError.receiptUnavailable(
        "signing credential mutation record is invalid")
    }
    // The interrupted mutation is settled by adopting whatever actually
    // landed — but only once this build can say what that is. An unusable
    // receipt throws instead: an installed credential that cannot be read is
    // not an uninstalled one, and writing `stable` with no reference here
    // would strand the user's material behind an owner claiming nothing is
    // installed.
    let receipt = try installedReceipt()
    let recovered = try Ledger(
      state: "stable", credentialRef: receipt.map(Self.reference(for:)),
      presetOwners: [])
    try save(recovered, rootFD: rootFD)
    return recovered
  }

  /// The ledger as it stands, for a mutation that is about to rewrite the
  /// credential outright.
  ///
  /// Deliberately does not read the receipt. An explicit reinstall is the only
  /// way out of a receipt this build cannot honour, and an interrupted
  /// `replace` is settled by completing one — so gating either on re-reading
  /// what the interruption left behind would lock the user out of the entry
  /// the refusal tells them to use. What still gates the mutation is
  /// ownership, which this ledger records by itself: a credential a workspace
  /// preset pins is never replaced or removed underneath it.
  private func ledgerForMutation(rootFD: Int32) throws -> Ledger {
    let ledger = try readLedger(rootFD: rootFD, adoptingInstalledReceipt: false)
    guard ledger.schemaVersion == "arkdeck.signing-credential-owner/1",
      ["stable", "replacing", "removing"].contains(ledger.state),
      ledger.presetOwners.count <= 4_096,
      ledger.presetOwners == ledger.presetOwners.sorted(),
      Set(ledger.presetOwners).count == ledger.presetOwners.count,
      ledger.presetOwners.allSatisfy(AgentExecutionIntent.validIdentifier)
    else {
      throw OpenHarmonySigningError.receiptUnavailable(
        "signing credential mutation record is invalid")
    }
    guard ledger.presetOwners.isEmpty else {
      throw OpenHarmonySigningError.invalidConfiguration(
        "signing credential is referenced by an active workspace preset")
    }
    return ledger
  }

  private func validateOwner(_ presetRef: String) throws {
    guard AgentExecutionIntent.validIdentifier(presetRef) else {
      throw OpenHarmonySigningError.invalidConfiguration(
        "workspace preset reference is malformed")
    }
  }

  private func resource(
    receipt: OpenHarmonySigningPresetReceipt, reference: String, owners: [String]
  ) -> OpenHarmonySigningCredentialResource {
    OpenHarmonySigningCredentialResource(
      credentialRef: reference, projectRef: receipt.projectRef,
      presetID: receipt.presetID, installedAtUTC: receipt.installedAtUTC,
      referenceCount: owners.count)
  }

  private static func reference(
    for receipt: OpenHarmonySigningPresetReceipt
  ) throws -> String {
    let identity = ReferenceIdentity(
      schemaVersion: "arkdeck.signing-credential-content/1",
      installedAtUTC: receipt.installedAtUTC, presetID: receipt.presetID,
      projectRef: receipt.projectRef,
      javaSHA256: receipt.javaExecutable.sha256,
      javaByteCount: receipt.javaExecutable.byteCount,
      signerJARSHA256: receipt.signerJAR.sha256,
      signerJARByteCount: receipt.signerJAR.byteCount,
      keystoreSHA256: receipt.keystore.sha256,
      keystoreByteCount: receipt.keystore.byteCount,
      appCertificateSHA256: receipt.appCertificate.sha256,
      appCertificateByteCount: receipt.appCertificate.byteCount,
      signedProfileSHA256: receipt.signedProfile.sha256,
      signedProfileByteCount: receipt.signedProfile.byteCount,
      keyAlias: receipt.keyAlias, signingAlgorithm: receipt.signingAlgorithm)
    let bytes = try CanonicalJSONEncoders.canonical().encode(identity)
    return "credential:sha256-" + SHA256Hex.string(of: bytes)
  }

  private func withOwnerLock<T>(_ body: (Int32) throws -> T) throws -> T {
    let ownerLock = try lockOwner()
    defer { ownerLock.close() }
    return try body(ownerLock.directoryFD)
  }

  private func lockOwner() throws -> OwnerLock {
    let rootFD: Int32
    do {
      rootFD = try ArkTraceProfileFileReader.openOrCreateOwnerPrivateDirectory(
        rootURL.path)
    } catch {
      throw OpenHarmonySigningError.ioFailure("cannot open signing credential owner")
    }
    var rootStatus = stat()
    guard fstat(rootFD, &rootStatus) == 0,
      rootStatus.st_mode & S_IFMT == S_IFDIR, rootStatus.st_uid == geteuid(),
      rootStatus.st_mode & 0o077 == 0
    else {
      close(rootFD)
      throw OpenHarmonySigningError.unsafeFile(
        "signing credential owner directory is unsafe")
    }
    let lockFD = openat(
      rootFD, Self.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lockFD >= 0 else {
      close(rootFD)
      throw OpenHarmonySigningError.ioFailure("cannot open signing credential lock")
    }
    var lockStatus = stat()
    guard fstat(lockFD, &lockStatus) == 0,
      lockStatus.st_mode & S_IFMT == S_IFREG, lockStatus.st_uid == geteuid(),
      lockStatus.st_nlink == 1, lockStatus.st_mode & 0o077 == 0
    else {
      close(lockFD); close(rootFD)
      throw OpenHarmonySigningError.unsafeFile("signing credential lock is unsafe")
    }
    while flock(lockFD, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      close(lockFD); close(rootFD)
      throw OpenHarmonySigningError.ioFailure(
        "signing credential lock cannot be acquired")
    }
    do {
      try revalidateOwnerDirectory(rootFD)
    } catch {
      flock(lockFD, LOCK_UN)
      close(lockFD)
      close(rootFD)
      throw error
    }
    return OwnerLock(directoryFD: rootFD, lockFD: lockFD)
  }

  private func revalidateOwnerDirectory(_ rootFD: Int32) throws {
    var opened = stat()
    var current = stat()
    guard fstat(rootFD, &opened) == 0,
      rootURL.path.withCString({ lstat($0, &current) }) == 0,
      opened.st_mode & S_IFMT == S_IFDIR,
      current.st_mode & S_IFMT == S_IFDIR,
      opened.st_dev == current.st_dev, opened.st_ino == current.st_ino,
      current.st_uid == geteuid(), current.st_mode & 0o077 == 0
    else {
      throw OpenHarmonySigningError.unsafeFile(
        "signing credential owner directory identity changed")
    }
  }

  private func readLedger(
    rootFD directory: Int32, adoptingInstalledReceipt: Bool = true
  ) throws -> Ledger {
    try revalidateOwnerDirectory(directory)
    let fd = openat(
      directory, Self.ledgerName, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0, errno == ENOENT {
      // A root with no ledger yet. A mutation takes the empty owner as read
      // and writes its own marker next; nothing is published here.
      guard adoptingInstalledReceipt else { return Ledger(credentialRef: nil) }
      // Otherwise the ledger is adopted, and only from a receipt this build
      // can account for: absent means a genuinely empty owner, an installed
      // receipt means adopt its exact reference, and anything else refuses
      // rather than writing an empty stable owner beside a credential it
      // could not read.
      let receipt = try installedReceipt()
      let ledger = try Ledger(
        credentialRef: receipt.map(Self.reference(for:)), presetOwners: [])
      try save(ledger, rootFD: directory)
      return ledger
    }
    guard fd >= 0 else {
      throw OpenHarmonySigningError.receiptUnavailable(
        "signing credential ledger cannot be opened")
    }
    defer { close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(), status.st_nlink == 1,
      status.st_mode & 0o077 == 0, status.st_size >= 0,
      status.st_size <= Self.maximumLedgerBytes
    else {
      throw OpenHarmonySigningError.unsafeFile("signing credential ledger is unsafe")
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    while true {
      let count = read(fd, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else {
        throw OpenHarmonySigningError.ioFailure("cannot read signing credential ledger")
      }
      if count == 0 { break }
      data.append(buffer, count: count)
      guard data.count <= Self.maximumLedgerBytes else {
        throw OpenHarmonySigningError.receiptUnavailable(
          "signing credential ledger exceeds its bound")
      }
    }
    do { return try JSONDecoder().decode(Ledger.self, from: data) }
    catch {
      throw OpenHarmonySigningError.receiptUnavailable(
        "signing credential ledger failed schema validation")
    }
  }

  private func save(_ ledger: Ledger, rootFD directory: Int32) throws {
    try revalidateOwnerDirectory(directory)
    let bytes = try CanonicalJSONEncoders.canonical().encode(ledger)
    guard bytes.count <= Self.maximumLedgerBytes else {
      throw OpenHarmonySigningError.ioFailure(
        "signing credential ledger exceeds its bound")
    }
    let temporary = ".credential-owner-" + UUID().uuidString.lowercased()
    let fd = openat(
      directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      0o600)
    guard fd >= 0 else {
      throw OpenHarmonySigningError.ioFailure(
        "cannot create signing credential transaction")
    }
    defer { close(fd); unlinkat(directory, temporary, 0) }
    var offset = 0
    try bytes.withUnsafeBytes { raw in
      while offset < bytes.count {
        let count = Darwin.write(
          fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw OpenHarmonySigningError.ioFailure(
            "cannot write signing credential transaction")
        }
        offset += count
      }
    }
    guard fsync(fd) == 0,
      renameat(directory, temporary, directory, Self.ledgerName) == 0,
      fsync(directory) == 0
    else {
      throw OpenHarmonySigningError.ioFailure(
        "signing credential transaction could not be published durably")
    }
    try revalidateOwnerDirectory(directory)
  }
}
