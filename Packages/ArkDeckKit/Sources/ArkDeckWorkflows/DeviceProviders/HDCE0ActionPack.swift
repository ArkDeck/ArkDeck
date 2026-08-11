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
  package static let remotePath = "/data/local/tmp"
  package static let maximumRequiredBytes = 8 * 1024 * 1024 * 1024

  package let requiredBytes: Int

  public init(requiredBytes: Int) throws {
    guard (1...Self.maximumRequiredBytes).contains(requiredBytes) else {
      throw HDCE0RequestError.outOfBounds(
        field: "requiredBytes", detail: "1...\(Self.maximumRequiredBytes)")
    }
    self.requiredBytes = requiredBytes
  }
}

public struct HDCHilogCaptureRequest: Sendable, Equatable {
  package static let maximumDurationSeconds = 600
  package static let maximumFilters = 16
  package static let maximumByteBudget = 128 * 1024 * 1024
  /// `hilog -x` exits after draining the device's current rolling buffers,
  /// but that drain is not instantaneous. On the production DAYU200 an
  /// a roughly 600 KiB capture has completed in 30 seconds; the old
  /// `durationSeconds + 15` timeout gave the common five-second request only
  /// 20 seconds and intermittently turned a healthy drain into an unknown
  /// outcome. This floor remains a real process timeout (not a success
  /// classification) and only gives the typed command enough time to exit
  /// naturally.
  package static let minimumCommandTimeoutSeconds = 45
  package static let commandStartupAndDrainGraceSeconds = 15

  public let durationSeconds: Int
  public let filters: [String]
  package let byteBudget: Int

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

  package var commandTimeoutSeconds: Int {
    max(
      Self.minimumCommandTimeoutSeconds,
      durationSeconds + Self.commandStartupAndDrainGraceSeconds)
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
  package let byteBudget: Int

  public init(scope: Scope = .windowList, byteBudget: Int = 8 * 1024 * 1024) throws {
    guard (1024...(64 * 1024 * 1024)).contains(byteBudget) else {
      throw HDCE0RequestError.outOfBounds(field: "byteBudget", detail: "1024...64MiB")
    }
    self.scope = scope
    self.byteBudget = byteBudget
  }
}

public struct HDCTraceCaptureRequest: Sendable, Equatable {
  package static let maximumCategories = 24
  package static let maximumDurationSeconds = 120

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
  package let nonce: String
  /// Full remote path under the provider's fixed staging root.
  package let remotePath: String

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
    case "capture-screenshot":
      // Not cosmetic: `snapshot_display` rejects a name whose suffix does
      // not match the requested type (measured on OH 3.2, CHG-2026-049 r5).
      suffix = ".png"
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
  package let expectedSHA256: String?
  package let maximumBytes: Int
  /// What the product's first bytes must be, when the format has a magic
  /// worth checking. A screenshot that is not a PNG is a failure, not an
  /// artifact — and the check is cheap enough to be unconditional.
  package let expectedLeadingBytes: Data?

  package init(
    path: HDCOwnedRemotePath,
    expectedSHA256: String?,
    maximumBytes: Int,
    expectedLeadingBytes: Data? = nil
  ) {
    self.path = path
    self.expectedSHA256 = expectedSHA256
    self.maximumBytes = maximumBytes
    self.expectedLeadingBytes = expectedLeadingBytes
  }
}

/// One Faultlogger entry name. The device's index prints these; a caller
/// may pass one back to fetch that entry.
///
/// The constraint is the *shape*, not a type vocabulary: a lowercase
/// prefix, then bounded name characters, and **no separator**, so the
/// value can never become a path or a shell fragment. r6 proposed
/// `^[a-z]+crash-…`, which would have rejected `appfreeze-…` — Faultlogger
/// holds more than crashes, and only `jscrash` has been measured on a
/// device. Enumerating types nobody has seen is the mistake this ledger
/// exists to prevent, so the prefix stays open: a name the device does not
/// have simply answers `invalid parameters.`
public struct HDCFaultLogName: Sendable, Equatable {
  public let value: String

  public init(_ value: String) throws {
    guard value.count <= 200,
      value.range(
        of: #"^[a-z]+-[A-Za-z0-9._-]{1,180}$"#, options: .regularExpression) != nil
    else {
      throw HDCE0RequestError.malformed(
        field: "faultLogName", detail: "a Faultlogger entry name, never a path")
    }
    self.value = value
  }
}

package enum HDCFileMagic {
  /// 89 50 4E 47 0D 0A 1A 0A — confirmed on a device-produced screenshot.
  package static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
}

// MARK: - E1 mutation surface (CHG-2026-049, T13)

/// A HAP staged under a provider-owned path. As with the E0 pack, the
/// remote location is minted by the provider; a caller supplies only an
/// artifact lease, never a device path.
public struct HDCStagedArtifact: Sendable, Equatable {
  public let path: HDCOwnedRemotePath
  package let artifactLeaseID: String
  package let expectedSHA256: String?

  package init(path: HDCOwnedRemotePath, artifactLeaseID: String, expectedSHA256: String?) {
    self.path = path
    self.artifactLeaseID = artifactLeaseID
    self.expectedSHA256 = expectedSHA256
  }
}

/// A provider-owned remote directory. Same discipline as
/// `HDCOwnedRemotePath`: only this module can mint one, the job/step/nonce
/// tuple makes collisions structurally impossible, and no caller can supply
/// a device location.
public struct HDCOwnedRemoteDirectory: Sendable, Equatable {
  public let jobID: String
  public let stepID: String
  package let nonce: String
  package let remotePath: String

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
    let remotePath = "/data/local/tmp/arkdeck-\(jobID)-\(stepID)-\(nonce)-packages"
    guard remotePath.utf8.count <= 255 else {
      throw HDCE0RequestError.outOfBounds(
        field: "remotePath", detail: "provider-owned path must be at most 255 bytes")
    }
    self.remotePath = remotePath
  }

  /// Where one package lands inside this directory. The file name comes from
  /// the artifact ID, never from a caller string, so a lease cannot name a
  /// path component.
  package func packagePath(artifactID: String) throws -> String {
    guard artifactID.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression)
      != nil
    else {
      throw HDCE0RequestError.malformed(
        field: "artifactID", detail: "package file names are bounded identifiers")
    }
    return "\(remotePath)/\(artifactID).hap"
  }
}

/// One package inside a staged set. Its remote path is derived from the
/// owning directory and the artifact ID — a lease cannot name a path
/// component, and the type cannot be built outside this module.
public struct HDCStagedPackage: Sendable, Equatable {
  package let remotePath: String
  package let artifactLeaseID: String
  /// Absent while the plan is only being materialized for admission, which
  /// happens before any lease is resolved. `lower` refuses to send without
  /// it, so the nil case can never reach a device.
  package let expectedSHA256: String?

  package init(
    directory: HDCOwnedRemoteDirectory,
    artifactID: String,
    artifactLeaseID: String,
    expectedSHA256: String?
  ) throws {
    self.remotePath = try directory.packagePath(artifactID: artifactID)
    self.artifactLeaseID = artifactLeaseID
    self.expectedSHA256 = expectedSHA256
  }
}

/// Several packages of one bundle staged in one provider-owned directory:
/// the shape `bm install -p <dir>` requires for a multi-module application.
/// A single-package install does not use this type at all, which is what
/// keeps its plan unchanged (CHG-2026-049 r4).
public struct HDCStagedPackageSet: Sendable, Equatable {
  public let directory: HDCOwnedRemoteDirectory
  /// Entry package first, then the caller's order. Never fewer than two.
  public let packages: [HDCStagedPackage]

  package init(directory: HDCOwnedRemoteDirectory, packages: [HDCStagedPackage]) throws {
    guard packages.count >= 2, packages.count <= 17 else {
      throw HDCE0RequestError.outOfBounds(
        field: "packages", detail: "a staged package set holds 2...17 packages")
    }
    var seen = Set<String>()
    for package in packages {
      guard seen.insert(package.remotePath).inserted else {
        throw HDCE0RequestError.malformed(
          field: "packages", detail: "two packages cannot stage to one path")
      }
      guard package.remotePath.hasPrefix(directory.remotePath + "/") else {
        throw HDCE0RequestError.malformed(
          field: "packages", detail: "every package must stage inside the owned directory")
      }
    }
    self.directory = directory
    self.packages = packages
  }
}

public struct HDCBundleReference: Sendable, Equatable {
  public let bundleName: String

  public init(bundleName: String) throws {
    let components = bundleName.split(separator: ".", omittingEmptySubsequences: false)
    guard !bundleName.isEmpty, bundleName.count <= 200, components.count >= 2,
      components.allSatisfy({ component in
        component.first?.isASCII == true && component.first?.isLetter == true
          && component.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")
          })
      })
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
      abilityName.first?.isASCII == true,
      abilityName.first?.isLetter == true,
      abilityName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") })
    else {
      throw HDCE0RequestError.malformed(field: "abilityName", detail: "identifier expected")
    }
    self.bundle = bundle
    self.abilityName = abilityName
  }
}

/// Typed identity for an application-specific liveness observation.
///
/// The caller supplies identifiers, never a PID or argv. The provider owns
/// the `pidof` lowering and derives the pseudonymous application reference
/// that is published in the result Artifact.
public struct HDCApplicationLivenessRequest: Sendable, Equatable {
  public let bundle: HDCBundleReference
  public let abilityName: String?
  package let processName: String
  package let expectedDeployedArtifactDigest: String?

  public init(
    bundle: HDCBundleReference,
    abilityName: String? = nil,
    processName: String? = nil,
    expectedDeployedArtifactDigest: String? = nil
  ) throws {
    if let abilityName {
      _ = try HDCAbilityReference(bundle: bundle, abilityName: abilityName)
    }
    let resolvedProcessName = processName ?? bundle.bundleName
    guard !resolvedProcessName.isEmpty, resolvedProcessName.count <= 200,
      resolvedProcessName.first?.isASCII == true,
      resolvedProcessName.first?.isLetter == true,
      resolvedProcessName.allSatisfy({
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == ":")
      })
    else {
      throw HDCE0RequestError.malformed(
        field: "processName", detail: "application process identifier expected")
    }
    if let digest = expectedDeployedArtifactDigest {
      guard digest.utf8.count == 64,
        digest.utf8.allSatisfy({
          (48...57).contains($0) || (97...102).contains($0)
        })
      else {
        throw HDCE0RequestError.malformed(
          field: "expectedDeployedArtifactDigest", detail: "lowercase SHA-256 expected")
      }
    }
    self.bundle = bundle
    self.abilityName = abilityName
    self.processName = resolvedProcessName
    self.expectedDeployedArtifactDigest = expectedDeployedArtifactDigest
  }
}

public enum HDCPortForwardDirection: String, Sendable, Equatable {
  case forward
  case reverse
}

public struct HDCPortForwardSpec: Sendable, Equatable {
  public let direction: HDCPortForwardDirection
  public let localPort: Int
  public let remotePort: Int

  public init(
    direction: HDCPortForwardDirection = .forward,
    localPort: Int,
    remotePort: Int
  ) throws {
    for (value, field) in [(localPort, "localPort"), (remotePort, "remotePort")] {
      guard (1024...65535).contains(value) else {
        throw HDCE0RequestError.outOfBounds(field: field, detail: "1024...65535")
      }
    }
    self.direction = direction
    self.localPort = localPort
    self.remotePort = remotePort
  }
}
