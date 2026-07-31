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

/// Fixed-root free-space observation for Catalog preflightDeviceStorage.
/// The request carries no caller-selected remote path.
public struct HDCStoragePreflightRequest: Sendable, Equatable {
  public static let remotePath = "/data/local/tmp"
  public static let maximumRequiredBytes = 8 * 1024 * 1024 * 1024

  public let requiredBytes: Int

  public init(requiredBytes: Int) throws {
    guard (1...Self.maximumRequiredBytes).contains(requiredBytes) else {
      throw HDCE0RequestError.outOfBounds(
        field: "requiredBytes", detail: "1...\(Self.maximumRequiredBytes)")
    }
    self.requiredBytes = requiredBytes
  }
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
  /// Kept as an enum with one case on purpose: the wire form stays stable
  /// and the type keeps saying that a UI dump has a scope. `componentTree`
  /// is gone from it because that scope is not a stdout capture at all —
  /// it is the `captureComponentTree` file action (CHG-2026-053 r2). No
  /// persisted journal can name it: its lowering refused from the day it
  /// was introduced, so nothing was ever dispatched under it.
  public enum Scope: String, CaseIterable, Sendable {
    case windowList
  }

  public let scope: Scope
  public let byteBudget: Int

  public init(scope: Scope = .windowList, byteBudget: Int = 8 * 1024 * 1024) throws {
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

  package init(jobID: String, stepID: String, nonce: String) throws {
    let componentPattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#
    for (field, value) in [("jobID", jobID), ("stepID", stepID), ("nonce", nonce)] {
      guard value.range(of: componentPattern, options: .regularExpression) != nil else {
        throw HDCE0RequestError.malformed(
          field: field, detail: "provider-owned path components must be bounded identifiers")
      }
    }
    self.jobID = jobID
    self.stepID = stepID
    self.nonce = nonce
    // A flat file under the existing /data/local/tmp directory requires no
    // undeclared mkdir mutation. The job/step/nonce tuple still provides
    // the required per-job isolation.
    let suffix: String
    switch stepID {
    case "send-hap":
      suffix = ".hap"
    case "capture-trace":
      suffix = ".htrace"
    case "capture-ui-tree":
      suffix = ".json"
    default:
      suffix = ""
    }
    let remotePath = "/data/local/tmp/arkdeck-\(jobID)-\(stepID)-\(nonce)\(suffix)"
    guard remotePath.utf8.count <= 255 else {
      throw HDCE0RequestError.outOfBounds(
        field: "remotePath", detail: "provider-owned path must be at most 255 bytes")
    }
    self.remotePath = remotePath
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
