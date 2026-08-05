// First-device-adoption bootstrap (CHG-2026-048, T09).
//
// Breaks the deadlock "no observation without a binding, no binding
// without observation" with an independent, permanently read-only
// admission path. Structural E0: the machine's action vocabulary is a
// closed observation subset - there is no type-level way to express a
// mutation inside bootstrap, and the normal runtime's checks are never
// relaxed (this is a separate path, not a bypass).

import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

// MARK: - Closed observation vocabulary

public enum BootstrapObservationAction: Sendable, Equatable {
  case observeTool
  case observeServer
  case listCandidates
  case observeDevice(connectKey: String)

  var providerAction: TypedProviderAction {
    switch self {
    case .observeTool: return .hdc(.observeTool)
    case .observeServer: return .hdc(.observeServer)
    case .listCandidates: return .hdc(.listDeviceCandidates)
    case .observeDevice(let connectKey): return .hdc(.observeDevice(connectKey: connectKey))
    }
  }
}

public enum BootstrapPhase: String, Sendable, Equatable, Codable {
  case discoverHostTools
  case observeHDCServer
  case enumerateDeviceCandidates
  case waitForPhysicalTrust
  case observeSelectedDevice
  case createDurableTarget
  case persistInitialBinding
  case handedOff
}

public struct BootstrapCandidate: Sendable, Equatable, Codable {
  public let connectKey: String
  public let state: String

  public init(connectKey: String, state: String) {
    self.connectKey = connectKey
    self.state = state
  }

  public var isAuthorized: Bool { state == "Connected" }
  public var needsPhysicalTrust: Bool {
    state == "Unauthorized" || state == "Offline"
  }
}

public enum BootstrapHumanActionKind: String, Sendable, Equatable {
  case trustDevice
  case physicalReconnect
}

public enum BootstrapProgress: Sendable, Equatable {
  case adopted(RuntimeTargetRecord)
  case needsSelection([BootstrapCandidate])
  case waitingForHuman(kind: BootstrapHumanActionKind, prompt: String)
  case failed(reason: String)
}

public enum BootstrapError: Error, Equatable, Sendable {
  case noCandidates
  case unknownCandidate(String)
  case observationFailed(String)
  case storeFailure(String)
}

// MARK: - Durable target store

public struct RuntimeTargetRecord: Sendable, Equatable, Codable {
  public let targetID: String
  public let stablePhysicalIdentitySHA256: String
  public let bindingRevision: Int
  public let connectKey: String
  public let toolVersion: String
  public let adoptedAtUTC: String

  public init(
    targetID: String,
    stablePhysicalIdentitySHA256: String,
    bindingRevision: Int,
    connectKey: String,
    toolVersion: String,
    adoptedAtUTC: String
  ) {
    self.targetID = targetID
    self.stablePhysicalIdentitySHA256 = stablePhysicalIdentitySHA256
    self.bindingRevision = bindingRevision
    self.connectKey = connectKey
    self.toolVersion = toolVersion
    self.adoptedAtUTC = adoptedAtUTC
  }
}

/// A single, already-proven cross-mode identity transition. The Rockchip
/// binding store constructs this value from its owner-only lineage evidence;
/// the target store only applies the exact previous -> current edge. Keeping
/// the proof outside the generic store prevents a caller from advancing a
/// target with an uncorrelated identity or a skipped revision.
package struct RuntimeTargetBindingLineageAdvance: Sendable, Equatable {
  package let previousStableIdentitySHA256: String
  package let previousRevision: Int
  package let currentStableIdentitySHA256: String
  package let currentRevision: Int

  package init(
    previousStableIdentitySHA256: String,
    previousRevision: Int,
    currentStableIdentitySHA256: String,
    currentRevision: Int
  ) {
    self.previousStableIdentitySHA256 = previousStableIdentitySHA256
    self.previousRevision = previousRevision
    self.currentStableIdentitySHA256 = currentStableIdentitySHA256
    self.currentRevision = currentRevision
  }
}

private struct TargetStoreDocument: Codable, Equatable {
  var schemaVersion: String
  var targets: [RuntimeTargetRecord]
}

/// Durable, flock-guarded target registry in the daemon state directory.
public final class RuntimeTargetStore: @unchecked Sendable {
  private let url: URL
  private let lockURL: URL
  private let queue = DispatchQueue(label: "arkdeck.target-store")

  public init(directoryURL: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: directoryURL, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw BootstrapError.storeFailure("cannot create target store directory: \(error)")
    }
    self.url = directoryURL.appendingPathComponent("targets.json")
    self.lockURL = directoryURL.appendingPathComponent(".targets.lock")
  }

  public func list() throws -> [RuntimeTargetRecord] {
    try queue.sync { try load().targets }
  }

  public func find(targetID: String) throws -> RuntimeTargetRecord? {
    try queue.sync { try load().targets.first { $0.targetID == targetID } }
  }

  /// Idempotent adoption keyed by stable physical identity: re-adopting
  /// the same device returns the existing record untouched.
  public func adopt(
    stableIdentitySHA256: String,
    connectKey: String,
    toolVersion: String,
    nowUTC: String
  ) throws -> (record: RuntimeTargetRecord, created: Bool) {
    try queue.sync {
      var document = try load()
      if let existing = document.targets.first(where: {
        $0.stablePhysicalIdentitySHA256 == stableIdentitySHA256
      }) {
        return (existing, false)
      }
      // Identity alone is not enough to recognise an already-adopted device.
      //
      // A Flash lineage advance keeps the durable target ID and the HDC
      // connect key while replacing the identity with the Loader-derived one.
      // The next time the daemon observes that device through HDC it derives
      // the *normal-mode* identity, finds no record carrying it, and used to
      // append a second record — whose derived ID collides with the first,
      // because the ID is a prefix of the identity the device was adopted
      // under. Bootstrap then refuses both with `ambiguous completed target
      // binding lineage`, and the daemon will not start until someone edits
      // the store by hand. Observed on 2026-08-05 after the 08-04 reflash.
      //
      // Same durable ID and same connect key is the same physical device seen
      // through another provider's address face, which is exactly what the
      // lineage advance documents. Return what is already adopted.
      let derivedID = "TGT-\(stableIdentitySHA256.prefix(12))"
      if let sameDevice = document.targets.first(where: { $0.targetID == derivedID }) {
        guard sameDevice.connectKey == connectKey else {
          // Same ID, different address: a genuine ambiguity a person must see,
          // not something to resolve by guessing which one was meant.
          throw BootstrapError.storeFailure(
            "adopted target \(derivedID) is bound to another connect key")
        }
        return (sameDevice, false)
      }
      let record = RuntimeTargetRecord(
        targetID: derivedID,
        stablePhysicalIdentitySHA256: stableIdentitySHA256,
        bindingRevision: 1,
        connectKey: connectKey,
        toolVersion: toolVersion,
        adoptedAtUTC: nowUTC)
      document.targets.append(record)
      try persist(document)
      return (record, true)
    }
  }

  /// Advances one adopted target across a strictly adjacent, externally
  /// proven binding lineage edge. The durable target ID and HDC connect key
  /// remain stable: after a Loader-mode Flash the same normal-mode address is
  /// needed for reconnect and full Debug Runtime verification.
  ///
  /// This is idempotent for the exact current edge. Any missing, ambiguous,
  /// colliding or skipped lineage fails closed without changing the file.
  package func advanceBindingLineage(
    _ advance: RuntimeTargetBindingLineageAdvance
  ) throws -> (record: RuntimeTargetRecord, updated: Bool) {
    try queue.sync {
      guard
        Self.isCanonicalSHA256(advance.previousStableIdentitySHA256),
        Self.isCanonicalSHA256(advance.currentStableIdentitySHA256),
        advance.previousStableIdentitySHA256 != advance.currentStableIdentitySHA256,
        advance.previousRevision > 0,
        advance.currentRevision == advance.previousRevision + 1
      else {
        throw BootstrapError.storeFailure("invalid target binding lineage advance")
      }

      var document = try load()
      let currentMatches = document.targets.filter {
        $0.stablePhysicalIdentitySHA256 == advance.currentStableIdentitySHA256
          && $0.bindingRevision == advance.currentRevision
      }
      let previousIdentityIndexes = document.targets.indices.filter {
        document.targets[$0].stablePhysicalIdentitySHA256
          == advance.previousStableIdentitySHA256
      }
      if currentMatches.count == 1 {
        guard previousIdentityIndexes.isEmpty,
          document.targets.filter({
            $0.stablePhysicalIdentitySHA256 == advance.currentStableIdentitySHA256
          }).count == 1
        else {
          throw BootstrapError.storeFailure("ambiguous completed target binding lineage")
        }
        return (currentMatches[0], false)
      }
      guard currentMatches.isEmpty else {
        throw BootstrapError.storeFailure("ambiguous current target binding lineage")
      }
      guard
        !document.targets.contains(where: {
          $0.stablePhysicalIdentitySHA256 == advance.currentStableIdentitySHA256
        })
      else {
        throw BootstrapError.storeFailure("target binding lineage collides with a durable record")
      }
      guard previousIdentityIndexes.count == 1,
        let index = previousIdentityIndexes.first,
        document.targets[index].bindingRevision == advance.previousRevision
      else {
        throw BootstrapError.storeFailure("previous target binding lineage is missing or ambiguous")
      }
      let previous = document.targets[index]
      let current = RuntimeTargetRecord(
        targetID: previous.targetID,
        stablePhysicalIdentitySHA256: advance.currentStableIdentitySHA256,
        bindingRevision: advance.currentRevision,
        connectKey: previous.connectKey,
        toolVersion: previous.toolVersion,
        adoptedAtUTC: previous.adoptedAtUTC)
      document.targets[index] = current
      try persist(document)
      return (current, true)
    }
  }

  private static func isCanonicalSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy {
      ("0"..."9").contains($0) || ("a"..."f").contains($0)
    }
  }

  private func load() throws -> TargetStoreDocument {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return TargetStoreDocument(schemaVersion: "1.0.0", targets: [])
    }
    do {
      return try JSONDecoder().decode(TargetStoreDocument.self, from: Data(contentsOf: url))
    } catch {
      throw BootstrapError.storeFailure("undecodable target store: \(error)")
    }
  }

  private func persist(_ document: TargetStoreDocument) throws {
    let lockFD = open(lockURL.path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lockFD >= 0 else { throw BootstrapError.storeFailure("cannot open target lock") }
    defer { close(lockFD) }
    guard flock(lockFD, LOCK_EX) == 0 else {
      throw BootstrapError.storeFailure("cannot lock target store")
    }
    defer { flock(lockFD, LOCK_UN) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data: Data
    do {
      data = try encoder.encode(document)
    } catch {
      throw BootstrapError.storeFailure("cannot encode target store: \(error)")
    }
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".targets.tmp.\(getpid())")
    do {
      try data.write(to: temporary, options: [])
      let handle = try FileHandle(forWritingTo: temporary)
      try handle.synchronize()
      try handle.close()
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } catch {
      throw BootstrapError.storeFailure("cannot persist target store: \(error)")
    }
  }
}

// MARK: - Observation port

/// What bootstrap may do, and nothing else. The production implementation
/// composes the HDC provider + dispatcher; fixtures fake it in tests.
public protocol BootstrapObservationPort: Sendable {
  func observeToolVersion() async throws -> String
  func listCandidates() async throws -> [BootstrapCandidate]
  /// Returns the device's stable-identity source attributes (serial et al).
  func observeDeviceIdentity(connectKey: String) async throws -> [String: String]
}

// MARK: - The machine

public actor DeviceBootstrapMachine {
  public private(set) var phase: BootstrapPhase = .discoverHostTools
  private let observation: any BootstrapObservationPort
  private let targetStore: RuntimeTargetStore
  private let nowUTC: @Sendable () -> String

  public init(
    observation: any BootstrapObservationPort,
    targetStore: RuntimeTargetStore,
    nowUTC: @escaping @Sendable () -> String
  ) {
    self.observation = observation
    self.targetStore = targetStore
    self.nowUTC = nowUTC
  }

  /// Runs the bootstrap to its next decision point. `selectedConnectKey`
  /// resolves a prior needsSelection; re-running after physical trust
  /// resumes automatically. Every path is observation-only.
  public func advance(selectedConnectKey: String? = nil) async -> BootstrapProgress {
    do {
      phase = .discoverHostTools
      let toolVersion = try await observation.observeToolVersion()
      phase = .observeHDCServer
      phase = .enumerateDeviceCandidates
      let candidates = try await observation.listCandidates()
      guard !candidates.isEmpty else {
        return .failed(reason: "no device candidates observed; connect a device and retry")
      }
      let selected: BootstrapCandidate
      if let selectedConnectKey {
        guard let match = candidates.first(where: { $0.connectKey == selectedConnectKey })
        else {
          return .failed(reason: "selected candidate is no longer present")
        }
        selected = match
      } else if candidates.count == 1 {
        selected = candidates[0]
      } else {
        return .needsSelection(candidates)
      }
      if selected.needsPhysicalTrust {
        phase = .waitForPhysicalTrust
        if selected.state == "Unauthorized" {
          return .waitingForHuman(
            kind: .trustDevice,
            prompt:
              "Confirm the debugging trust prompt on the device screen "
              + "(state: \(selected.state)); bootstrap resumes automatically.")
        }
        return .waitingForHuman(
          kind: .physicalReconnect,
          prompt:
            "Reconnect the device until it reports Connected "
            + "(state: \(selected.state)); bootstrap resumes automatically.")
      }
      phase = .observeSelectedDevice
      let identity = try await observation.observeDeviceIdentity(
        connectKey: selected.connectKey)
      guard let serial = identity["serial"], !serial.isEmpty else {
        return .failed(reason: "device identity has no stable serial; cannot bind safely")
      }
      phase = .createDurableTarget
      let stableIdentity = Self.stableIdentitySHA256(serial: serial)
      phase = .persistInitialBinding
      let (record, _) = try targetStore.adopt(
        stableIdentitySHA256: stableIdentity,
        connectKey: selected.connectKey,
        toolVersion: toolVersion,
        nowUTC: nowUTC())
      phase = .handedOff
      return .adopted(record)
    } catch let error as BootstrapError {
      return .failed(reason: "\(error)")
    } catch {
      return .failed(reason: "observation failed: \(error)")
    }
  }

  /// Mirrors DeviceIdentitySnapshot.stablePhysicalIdentitySha256: the
  /// stable identity hashes only the normalized serial.
  static func stableIdentitySHA256(serial: String) -> String {
    let normalized = serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return SHA256.hash(data: Data(normalized.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}
