// Durable Runtime Capability store (CHG-2026-046, T03).
//
// install / list / inspect / revoke / consume for RuntimeCapability
// documents, with the crash-window semantics this module already proved out
// for authorization ledgers: consumption is a durable append keyed by a
// caller reservation ID; retrying the same reservation returns the original
// receipt, a drifted retry is a conflict, and nothing is ever consumed
// twice. All writes are atomic (temp + fsync + rename + directory sync)
// under an exclusive flock, so a crash between any two syscalls leaves
// either the old or the new document, never a torn one.

import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

public enum RuntimeCapabilityStoreError: Error, Equatable, Sendable {
  case ioFailure(String)
  case storeCorrupted(String)
  case capabilityNotFound(String)
  case capabilityAlreadyInstalled(String)
  case reservationConflict(String)
  case denied(RuntimeCapabilityDenial)
}

public struct RuntimeCapabilityStatus: Equatable, Sendable, Codable {
  public let capability: RuntimeCapability
  public let remainingUses: Int
  public let consumptionCount: Int
}

public struct RuntimeCapabilityConsumptionReceipt: Equatable, Sendable, Codable {
  public let capabilityID: String
  public let reservationID: String
  public let consumedAtUTC: String
  public let operationReference: String
  public let queryFingerprintSHA256: String
  public let remainingUsesAfter: Int
}

private struct StoredConsumption: Equatable, Codable {
  let reservationID: String
  let consumedAtUTC: String
  let operationReference: String
  let queryFingerprintSHA256: String
  let remainingUsesAfter: Int
}

private struct StoredRecord: Equatable, Codable {
  var capability: RuntimeCapability
  var remainingUses: Int
  var consumptions: [StoredConsumption]
}

private struct StoreDocument: Equatable, Codable {
  static let currentSchemaVersion = "1.0.0"
  var schemaVersion: String
  var records: [StoredRecord]
}

public actor RuntimeCapabilityStore {
  private let directoryURL: URL
  private let documentURL: URL
  private let lockURL: URL

  public init(directoryURL: URL) throws {
    self.directoryURL = directoryURL
    self.documentURL = directoryURL.appendingPathComponent("runtime-capabilities.json")
    self.lockURL = directoryURL.appendingPathComponent(".runtime-capabilities.lock")
    do {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw RuntimeCapabilityStoreError.ioFailure(
        "cannot create capability store directory: \(error)")
    }
  }

  // MARK: - Public API

  public func install(_ capability: RuntimeCapability) throws {
    try withExclusiveLock {
      var document = try loadDocument()
      if let existing = document.records.first(where: {
        $0.capability.capabilityID == capability.capabilityID
      }) {
        if existing.capability == capability {
          return  // idempotent re-install of the identical document
        }
        throw RuntimeCapabilityStoreError.capabilityAlreadyInstalled(capability.capabilityID)
      }
      document.records.append(
        StoredRecord(
          capability: capability,
          remainingUses: capability.maximumUses,
          consumptions: []))
      try persist(document)
    }
  }

  public func list() throws -> [RuntimeCapabilityStatus] {
    try withExclusiveLock {
      try loadDocument().records.map(Self.status(of:))
    }
  }

  public func inspect(capabilityID: String) throws -> RuntimeCapabilityStatus? {
    try withExclusiveLock {
      try loadDocument().records
        .first { $0.capability.capabilityID == capabilityID }
        .map(Self.status(of:))
    }
  }

  public func revoke(capabilityID: String, atUTC: String, reason: String) throws {
    try withExclusiveLock {
      var document = try loadDocument()
      guard
        let index = document.records.firstIndex(where: {
          $0.capability.capabilityID == capabilityID
        })
      else {
        throw RuntimeCapabilityStoreError.capabilityNotFound(capabilityID)
      }
      if case .revoked = document.records[index].capability.revocation {
        return  // idempotent
      }
      let existing = document.records[index].capability
      do {
        document.records[index].capability = try RuntimeCapability(
          capabilityID: existing.capabilityID,
          targetScope: existing.targetScope,
          operationScope: existing.operationScope,
          effectCeiling: existing.effectCeiling,
          inputConstraints: existing.inputConstraints,
          issuedAtUTC: existing.issuedAtUTC,
          expiresAtUTC: existing.expiresAtUTC,
          maximumUses: existing.maximumUses,
          issuer: existing.issuer,
          exactPlanDigest: existing.exactPlanDigest,
          revocation: .revoked(atUTC: atUTC, reason: reason))
      } catch {
        throw RuntimeCapabilityStoreError.storeCorrupted(
          "revocation produced an invalid capability: \(error)")
      }
      try persist(document)
    }
  }

  /// Atomically consumes one use. The first call for a reservation decides;
  /// an identical retry returns the recorded receipt; a drifted retry is a
  /// conflict; and a model-level denial consumes nothing.
  public func consume(
    capabilityID: String,
    reservationID: String,
    query: RuntimeCapabilityAuthorizationQuery,
    nowUTC: String
  ) throws -> RuntimeCapabilityConsumptionReceipt {
    guard !reservationID.isEmpty, reservationID.count <= 128 else {
      throw RuntimeCapabilityStoreError.reservationConflict("malformed reservation ID")
    }
    return try withExclusiveLock {
      var document = try loadDocument()
      guard
        let index = document.records.firstIndex(where: {
          $0.capability.capabilityID == capabilityID
        })
      else {
        throw RuntimeCapabilityStoreError.capabilityNotFound(capabilityID)
      }
      let fingerprint = Self.fingerprint(of: query, nowIndependent: true)
      if let existing = document.records[index].consumptions.first(where: {
        $0.reservationID == reservationID
      }) {
        guard existing.queryFingerprintSHA256 == fingerprint else {
          throw RuntimeCapabilityStoreError.reservationConflict(
            "reservation retry fields drifted for \(reservationID)")
        }
        return RuntimeCapabilityConsumptionReceipt(
          capabilityID: capabilityID,
          reservationID: existing.reservationID,
          consumedAtUTC: existing.consumedAtUTC,
          operationReference: existing.operationReference,
          queryFingerprintSHA256: existing.queryFingerprintSHA256,
          remainingUsesAfter: existing.remainingUsesAfter)
      }
      let record = document.records[index]
      if case .failure(let denial) = record.capability.authorizes(
        query, nowUTC: nowUTC, remainingUses: record.remainingUses)
      {
        throw RuntimeCapabilityStoreError.denied(denial)
      }
      let remainingAfter = record.remainingUses - 1
      let consumption = StoredConsumption(
        reservationID: reservationID,
        consumedAtUTC: nowUTC,
        operationReference: "\(query.operationID)@\(query.operationVersion)",
        queryFingerprintSHA256: fingerprint,
        remainingUsesAfter: remainingAfter)
      document.records[index].remainingUses = remainingAfter
      document.records[index].consumptions.append(consumption)
      try persist(document)
      return RuntimeCapabilityConsumptionReceipt(
        capabilityID: capabilityID,
        reservationID: reservationID,
        consumedAtUTC: nowUTC,
        operationReference: consumption.operationReference,
        queryFingerprintSHA256: fingerprint,
        remainingUsesAfter: remainingAfter)
    }
  }

  // MARK: - Internals

  private static func status(of record: StoredRecord) -> RuntimeCapabilityStatus {
    RuntimeCapabilityStatus(
      capability: record.capability,
      remainingUses: record.remainingUses,
      consumptionCount: record.consumptions.count)
  }

  private static func fingerprint(
    of query: RuntimeCapabilityAuthorizationQuery, nowIndependent: Bool
  ) -> String {
    // Canonical, clock-independent identity of a consumption request. Two
    // retries of the same external decision must fingerprint identically
    // even when their wall-clock differs.
    var components: [String] = [
      "operation=\(query.operationID)@\(query.operationVersion)",
      "effect=\(query.effect.rawValue)",
      "target=\(query.targetStableIdentitySHA256 ?? "-")",
      "bindingRevision=\(query.targetBindingRevision.map(String.init) ?? "-")",
      "plan=\(query.planDigest ?? "-")",
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let inputs = try? encoder.encode(query.inputs),
      let text = String(data: inputs, encoding: .utf8)
    {
      components.append("inputs=\(text)")
    } else {
      components.append("inputs=unencodable")
    }
    return SHA256Digest.hex(of: Data(components.joined(separator: "\n").utf8))
  }

  private func loadDocument() throws -> StoreDocument {
    let data: Data
    do {
      data = try Data(contentsOf: documentURL)
    } catch let error as NSError
      where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
    {
      return StoreDocument(schemaVersion: StoreDocument.currentSchemaVersion, records: [])
    } catch {
      throw RuntimeCapabilityStoreError.ioFailure("cannot read capability store: \(error)")
    }
    var validator = StrictJSONDuplicateValidator(data: data)
    do {
      try validator.validate()
    } catch {
      throw RuntimeCapabilityStoreError.storeCorrupted("duplicate or malformed JSON: \(error)")
    }
    let document: StoreDocument
    do {
      document = try JSONDecoder().decode(StoreDocument.self, from: data)
    } catch {
      throw RuntimeCapabilityStoreError.storeCorrupted("undecodable store document: \(error)")
    }
    guard document.schemaVersion == StoreDocument.currentSchemaVersion else {
      throw RuntimeCapabilityStoreError.storeCorrupted(
        "unsupported schema version \(document.schemaVersion)")
    }
    for record in document.records {
      guard record.remainingUses >= 0,
        record.remainingUses <= record.capability.maximumUses,
        record.capability.maximumUses - record.remainingUses == record.consumptions.count
      else {
        throw RuntimeCapabilityStoreError.storeCorrupted(
          "inconsistent use accounting for \(record.capability.capabilityID)")
      }
    }
    return document
  }

  private func persist(_ document: StoreDocument) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    let data: Data
    do {
      data = try encoder.encode(document)
    } catch {
      throw RuntimeCapabilityStoreError.ioFailure("cannot encode capability store: \(error)")
    }
    let temporaryURL = directoryURL.appendingPathComponent(
      ".runtime-capabilities.tmp.\(getpid())")
    let fd = open(
      temporaryURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
      throw RuntimeCapabilityStoreError.ioFailure("cannot open temp store file")
    }
    defer { close(fd) }
    let written = data.withUnsafeBytes { buffer -> Int in
      guard let base = buffer.baseAddress else { return 0 }
      var total = 0
      while total < buffer.count {
        let result = write(fd, base + total, buffer.count - total)
        if result <= 0 { return total }
        total += result
      }
      return total
    }
    guard written == data.count else {
      unlink(temporaryURL.path)
      throw RuntimeCapabilityStoreError.ioFailure("short write to temp store file")
    }
    guard fsync(fd) == 0 else {
      unlink(temporaryURL.path)
      throw RuntimeCapabilityStoreError.ioFailure("fsync of temp store file failed")
    }
    guard rename(temporaryURL.path, documentURL.path) == 0 else {
      unlink(temporaryURL.path)
      throw RuntimeCapabilityStoreError.ioFailure("atomic rename of store document failed")
    }
    let dirFD = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if dirFD >= 0 {
      _ = fsync(dirFD)
      close(dirFD)
    }
  }

  private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
    let fd = open(lockURL.path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
      throw RuntimeCapabilityStoreError.ioFailure("cannot open capability store lock")
    }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else {
      throw RuntimeCapabilityStoreError.ioFailure("cannot acquire capability store lock")
    }
    defer { flock(fd, LOCK_UN) }
    return try body()
  }
}

private enum SHA256Digest {
  static func hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
