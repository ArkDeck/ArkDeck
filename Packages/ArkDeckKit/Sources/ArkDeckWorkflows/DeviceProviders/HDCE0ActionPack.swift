// HDC E0 typed action pack (CHG-2026-048, T10).
//
// Every read-only capture/query surface is a validated typed request:
// bounds and defaults are enforced at construction, property queries are
// closed over an allowlist enum, and remote temporary paths can only be
// minted by the provider (package init) with session/job/step components -
// callers cannot supply device paths, and cleanup only accepts the
// provider's own path type. There is no generic read-only shell.

import ArkDeckCore
import Foundation

public enum HDCE0RequestError: Error, Equatable, Sendable {
  case outOfBounds(field: String, detail: String)
  case malformed(field: String, detail: String)
}

/// Closed device-property allowlist. Extending it is a catalog/provider
/// decision delivered by PR, never a caller-supplied key.
public enum HDCAllowlistedProperty: String, CaseIterable, Sendable, Codable {
  case productModel = "const.product.model"
  case productName = "const.product.name"
  case softwareVersion = "const.product.software.version"
  case buildCharacteristics = "ro.build.characteristics"
  case apiVersion = "const.ohos.apiversion"
  case fullBuildVersion = "const.ohos.fullname"
}

public struct HDCHilogCaptureRequest: Sendable, Equatable {
  public static let maximumDurationSeconds = 600
  public static let maximumFilters = 16
  public static let maximumByteBudget = 128 * 1024 * 1024

  public let durationSeconds: Int
  public let filters: [String]
  public let byteBudget: Int

  public init(
    durationSeconds: Int,
    filters: [String] = [],
    byteBudget: Int = 16 * 1024 * 1024
  ) throws {
    guard (1...Self.maximumDurationSeconds).contains(durationSeconds) else {
      throw HDCE0RequestError.outOfBounds(
        field: "durationSeconds", detail: "1...\(Self.maximumDurationSeconds)")
    }
    guard filters.count <= Self.maximumFilters else {
      throw HDCE0RequestError.outOfBounds(
        field: "filters", detail: "at most \(Self.maximumFilters)")
    }
    for filter in filters {
      guard !filter.isEmpty, filter.count <= 200,
        filter.allSatisfy({ character in
          character.isASCII
            && (character.isLetter || character.isNumber || ":*./_-".contains(character))
        })
      else {
        throw HDCE0RequestError.malformed(
          field: "filters", detail: "filter tokens are bounded ASCII, no shell fragments")
      }
    }
    guard (1024...Self.maximumByteBudget).contains(byteBudget) else {
      throw HDCE0RequestError.outOfBounds(
        field: "byteBudget", detail: "1024...\(Self.maximumByteBudget)")
    }
    self.durationSeconds = durationSeconds
    self.filters = filters
    self.byteBudget = byteBudget
  }
}

public struct HDCUIDumpRequest: Sendable, Equatable {
  public enum Scope: String, CaseIterable, Sendable {
    case windowList
    case componentTree
  }

  public let scope: Scope
  public let byteBudget: Int

  public init(scope: Scope = .componentTree, byteBudget: Int = 8 * 1024 * 1024) throws {
    guard (1024...(64 * 1024 * 1024)).contains(byteBudget) else {
      throw HDCE0RequestError.outOfBounds(field: "byteBudget", detail: "1024...64MiB")
    }
    self.scope = scope
    self.byteBudget = byteBudget
  }
}

public struct HDCTraceCaptureRequest: Sendable, Equatable {
  public static let maximumCategories = 24
  public static let maximumDurationSeconds = 120

  public let durationSeconds: Int
  public let categories: [String]
  public let bufferKB: Int

  public init(
    durationSeconds: Int,
    categories: [String],
    bufferKB: Int = 8192
  ) throws {
    guard (1...Self.maximumDurationSeconds).contains(durationSeconds) else {
      throw HDCE0RequestError.outOfBounds(
        field: "durationSeconds", detail: "1...\(Self.maximumDurationSeconds)")
    }
    guard !categories.isEmpty, categories.count <= Self.maximumCategories else {
      throw HDCE0RequestError.outOfBounds(
        field: "categories", detail: "1...\(Self.maximumCategories)")
    }
    for category in categories {
      guard !category.isEmpty, category.count <= 64,
        category.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
      else {
        throw HDCE0RequestError.malformed(
          field: "categories", detail: "categories are bounded identifiers")
      }
    }
    guard (1024...65536).contains(bufferKB) else {
      throw HDCE0RequestError.outOfBounds(field: "bufferKB", detail: "1024...65536")
    }
    self.durationSeconds = durationSeconds
    self.categories = categories
    self.bufferKB = bufferKB
  }
}

/// A provider-owned remote temporary path. Only this module can mint one
/// (package init), the components make collisions structurally impossible,
/// and cleanup actions accept only this type - never a raw string.
public struct HDCOwnedRemotePath: Sendable, Equatable {
  public let jobID: String
  public let stepID: String
  public let nonce: String
  /// Full remote path under the provider's fixed staging root.
  public let remotePath: String

  package init(jobID: String, stepID: String, nonce: String) {
    self.jobID = jobID
    self.stepID = stepID
    self.nonce = nonce
    self.remotePath = "/data/local/tmp/arkdeck/\(jobID)/\(stepID)-\(nonce)"
  }
}

/// A provider-created remote artifact awaiting receive: the remote path is
/// provider-owned and the expected content hash is pinned before receive.
public struct HDCOwnedRemoteArtifact: Sendable, Equatable {
  public let path: HDCOwnedRemotePath
  public let expectedSHA256: String?
  public let maximumBytes: Int

  package init(path: HDCOwnedRemotePath, expectedSHA256: String?, maximumBytes: Int) {
    self.path = path
    self.expectedSHA256 = expectedSHA256
    self.maximumBytes = maximumBytes
  }
}

public enum HDCArtifactReceiveOutcome: Sendable, Equatable {
  case received(byteCount: Int, sha256: String, remoteCleanup: HDCRemoteCleanupState)
  case hashMismatch(expected: String, actual: String)
  case oversized(limit: Int)
}

public enum HDCRemoteCleanupState: Sendable, Equatable {
  case cleaned
  case cleanupDebt(reason: String)
}

// MARK: - E1 mutation surface (CHG-2026-049, T13)

/// A HAP staged under a provider-owned path. As with the E0 pack, the
/// remote location is minted by the provider; a caller supplies only an
/// artifact lease, never a device path.
public struct HDCStagedArtifact: Sendable, Equatable {
  public let path: HDCOwnedRemotePath
  public let artifactLeaseID: String
  public let expectedSHA256: String?

  package init(path: HDCOwnedRemotePath, artifactLeaseID: String, expectedSHA256: String?) {
    self.path = path
    self.artifactLeaseID = artifactLeaseID
    self.expectedSHA256 = expectedSHA256
  }
}

public struct HDCBundleReference: Sendable, Equatable {
  public let bundleName: String

  public init(bundleName: String) throws {
    guard !bundleName.isEmpty, bundleName.count <= 200,
      bundleName.contains("."),
      bundleName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") })
    else {
      throw HDCE0RequestError.malformed(
        field: "bundleName", detail: "reverse-DNS identifier expected")
    }
    self.bundleName = bundleName
  }
}

public struct HDCAbilityReference: Sendable, Equatable {
  public let bundle: HDCBundleReference
  public let abilityName: String

  public init(bundle: HDCBundleReference, abilityName: String) throws {
    guard !abilityName.isEmpty, abilityName.count <= 200,
      abilityName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") })
    else {
      throw HDCE0RequestError.malformed(field: "abilityName", detail: "identifier expected")
    }
    self.bundle = bundle
    self.abilityName = abilityName
  }
}

public struct HDCPortForwardSpec: Sendable, Equatable {
  public let localPort: Int
  public let remotePort: Int

  public init(localPort: Int, remotePort: Int) throws {
    for (value, field) in [(localPort, "localPort"), (remotePort, "remotePort")] {
      guard (1024...65535).contains(value) else {
        throw HDCE0RequestError.outOfBounds(field: field, detail: "1024...65535")
      }
    }
    self.localPort = localPort
    self.remotePort = remotePort
  }
}

/// What a package readback found. `installed == false` with a clean exit
/// is exactly the case that must never be reported as a successful
/// install - real hardware has shown `hdc install` exiting zero without
/// having installed anything.
public struct HDCPackageReadback: Sendable, Equatable {
  public let bundleName: String
  public let installed: Bool
}

public struct HDCProcessReadback: Sendable, Equatable {
  public let bundleName: String
  public let running: Bool
}
