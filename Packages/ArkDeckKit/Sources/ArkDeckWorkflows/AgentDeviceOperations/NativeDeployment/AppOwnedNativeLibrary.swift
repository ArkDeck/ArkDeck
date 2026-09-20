import ArkDeckClientKit
import ArkDeckCore
import CryptoKit
import Foundation

package enum HDCNativeRestartProfile: String, Sendable, Equatable, Codable {
  case restartAbility
  case restartProcess
  case none
}

package enum HDCNativeVerificationProfile: String, Sendable, Equatable, Codable {
  case hashOnly
  case hashAndProcess
  case hashProcessAndMaps
}

package enum HDCNativeRollbackPolicy: String, Sendable, Equatable, Codable {
  case autoRollback
  case retainBackup
}

public enum HDCNativeLibraryInspection: String, Sendable, Equatable, Codable {
  case stagingMatchesArtifact
  case backupMatchesTarget
  case targetMatchesArtifact
  case targetStopped
  case targetStarted
  case targetLoaded
  case cleanupComplete
  case rollbackRestored
}

/// Exact provider-owned paths persisted with a native action. Recovery
/// validates these paths against the closed job/bundle/ABI namespace and
/// then reuses them verbatim; it must not silently rebuild an old intent
/// with the current version's preferred layout.
package struct HDCAppOwnedNativeLibraryExactPaths: Sendable, Equatable {
  package let directoryPath: String
  package let targetPath: String
  package let loaderVisiblePath: String
  package let stagingDirectoryPath: String?
  package let stagingPath: String
  package let backupPath: String
  package let rollbackStagingPath: String
  package let codeSignHelperRemotePath: String?

  package init(
    directoryPath: String,
    targetPath: String,
    loaderVisiblePath: String,
    stagingDirectoryPath: String?,
    stagingPath: String,
    backupPath: String,
    rollbackStagingPath: String,
    codeSignHelperRemotePath: String? = nil
  ) {
    self.directoryPath = directoryPath
    self.targetPath = targetPath
    self.loaderVisiblePath = loaderVisiblePath
    self.stagingDirectoryPath = stagingDirectoryPath
    self.stagingPath = stagingPath
    self.backupPath = backupPath
    self.rollbackStagingPath = rollbackStagingPath
    self.codeSignHelperRemotePath = codeSignHelperRemotePath
  }
}

package struct HDCNativeCodeSignHelperFacts: Sendable, Equatable {
  package let abi: HDCNativeLibraryABI
  package let buildID: String
  public let sha256: String
  public let byteCount: Int

  public init(
    abi: HDCNativeLibraryABI,
    buildID: String,
    sha256: String,
    byteCount: Int
  ) {
    self.abi = abi
    self.buildID = buildID
    self.sha256 = sha256
    self.byteCount = byteCount
  }
}

/// Fully provider-owned app profile. Inputs select only a bundle and logical
/// library name; the canonical remote namespace is derived here and can never
/// be supplied by a runtime caller.
public struct HDCAppOwnedNativeLibraryDeployment: Sendable, Equatable {
  package static let entryAbility = "EntryAbility"
  package static let userID = 100
  package static let moduleName = "entry"

  public let jobID: String
  package let artifactLeaseID: String
  package let artifactID: String
  public let bundle: HDCBundleReference
  package let libraryLogicalName: String
  package let artifactFacts: HDCNativeLibraryArtifactFacts
  package let restartProfile: HDCNativeRestartProfile
  package let verificationProfile: HDCNativeVerificationProfile
  package let rollbackPolicy: HDCNativeRollbackPolicy
  package let directoryPath: String
  package let targetPath: String
  package let loaderVisiblePath: String
  package let stagingDirectoryPath: String
  package let stagingDirectoryIsJobOwned: Bool
  package let stagingPath: String
  package let backupPath: String
  package let rollbackStagingPath: String
  package let codeSignHelperFacts: HDCNativeCodeSignHelperFacts?
  package let codeSignHelperRemotePath: String?

  package init(
    jobID: String,
    artifactLeaseID: String,
    artifactID: String,
    bundle: HDCBundleReference,
    libraryLogicalName: String,
    artifactFacts: HDCNativeLibraryArtifactFacts,
    restartProfile: HDCNativeRestartProfile,
    verificationProfile: HDCNativeVerificationProfile,
    rollbackPolicy: HDCNativeRollbackPolicy,
    codeSignHelperFacts: HDCNativeCodeSignHelperFacts? = nil,
    exactPaths: HDCAppOwnedNativeLibraryExactPaths? = nil
  ) throws {
    guard
      jobID.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,127}$"#,
        options: .regularExpression) != nil
    else {
      throw DeviceProviderError.unsupportedAction("native deployment job identity is invalid")
    }
    guard
      libraryLogicalName.range(
        of: #"^lib[A-Za-z0-9_.-]+\.so$"#,
        options: .regularExpression) != nil,
      libraryLogicalName.count <= 128
    else {
      throw DeviceProviderError.unsupportedAction("native library logical name is invalid")
    }
    self.jobID = jobID
    self.artifactLeaseID = artifactLeaseID
    self.artifactID = artifactID
    self.bundle = bundle
    self.libraryLogicalName = libraryLogicalName
    self.artifactFacts = artifactFacts
    self.restartProfile = restartProfile
    self.verificationProfile = verificationProfile
    self.rollbackPolicy = rollbackPolicy
    self.codeSignHelperFacts = codeSignHelperFacts

    let currentABIDirectory: String
    let acceptedABIDirectories: Set<String>
    switch artifactFacts.abi {
    case .arm64:
      currentABIDirectory = "arm"
      // OpenHarmony's installed-bundle layout has used both names. Exact
      // recovery accepts the historical closed ABI directory but never an
      // arbitrary recorded path.
      acceptedABIDirectories = ["arm", "arm64"]
    case .arm32:
      currentABIDirectory = "arm"
      acceptedABIDirectories = ["arm"]
    case .x86_64:
      currentABIDirectory = "x86_64"
      acceptedABIDirectories = ["x86_64"]
    }
    let bundleInstallRoot = "/data/app/el1/bundle/public/\(bundle.bundleName)"
    let librariesRoot = "\(bundleInstallRoot)/libs"
    let stagingDirectory =
      "/data/app/el2/\(Self.userID)/base/\(bundle.bundleName)/haps/"
      + "\(Self.moduleName)/files/arkdeck-native/\(jobID)"

    if let exactPaths {
      let usesJobOwnedStagingDirectory =
        exactPaths.stagingDirectoryPath == stagingDirectory
        && exactPaths.stagingPath
          == "\(stagingDirectory)/\(libraryLogicalName).staging"
      let usesLegacySiblingStaging =
        exactPaths.stagingDirectoryPath == nil
        && exactPaths.stagingPath
          == "\(exactPaths.directoryPath)/.\(libraryLogicalName).arkdeck-\(jobID).staging"
      let expectedHelperPath =
        usesJobOwnedStagingDirectory && codeSignHelperFacts != nil
        ? "\(stagingDirectory)/arkdeck-code-sign-enable" : nil
      guard
        let abiDirectory = acceptedABIDirectories.first(where: {
          exactPaths.directoryPath == "\(librariesRoot)/\($0)"
        }),
        exactPaths.targetPath
          == "\(exactPaths.directoryPath)/\(libraryLogicalName)",
        exactPaths.loaderVisiblePath
          == "/data/storage/el1/bundle/libs/\(abiDirectory)/\(libraryLogicalName)",
        usesJobOwnedStagingDirectory || usesLegacySiblingStaging,
        exactPaths.backupPath
          == "\(exactPaths.directoryPath)/.\(libraryLogicalName).arkdeck-\(jobID).backup",
        exactPaths.rollbackStagingPath
          == "\(exactPaths.directoryPath)/.\(libraryLogicalName).arkdeck-\(jobID).rollback",
        exactPaths.codeSignHelperRemotePath == expectedHelperPath
      else {
        throw DeviceProviderError.unsupportedAction(
          "persisted native deployment paths escape the provider-owned namespace")
      }
      self.directoryPath = exactPaths.directoryPath
      self.targetPath = exactPaths.targetPath
      self.loaderVisiblePath = exactPaths.loaderVisiblePath
      self.stagingDirectoryPath =
        exactPaths.stagingDirectoryPath ?? exactPaths.directoryPath
      self.stagingDirectoryIsJobOwned = usesJobOwnedStagingDirectory
      self.stagingPath = exactPaths.stagingPath
      self.backupPath = exactPaths.backupPath
      self.rollbackStagingPath = exactPaths.rollbackStagingPath
      self.codeSignHelperRemotePath = exactPaths.codeSignHelperRemotePath
    } else {
      let directory = "\(librariesRoot)/\(currentABIDirectory)"
      self.directoryPath = directory
      self.targetPath = "\(directory)/\(libraryLogicalName)"
      self.loaderVisiblePath =
        "/data/storage/el1/bundle/libs/\(currentABIDirectory)/\(libraryLogicalName)"
      self.stagingDirectoryPath = stagingDirectory
      self.stagingDirectoryIsJobOwned = true
      self.stagingPath = "\(stagingDirectory)/\(libraryLogicalName).staging"
      self.backupPath =
        "\(directory)/.\(libraryLogicalName).arkdeck-\(jobID).backup"
      self.rollbackStagingPath =
        "\(directory)/.\(libraryLogicalName).arkdeck-\(jobID).rollback"
      self.codeSignHelperRemotePath =
        codeSignHelperFacts == nil
        ? nil : "\(stagingDirectory)/arkdeck-code-sign-enable"
    }
  }

  package var abiDirectoryName: String {
    switch artifactFacts.abi {
    case .arm64:
      return "arm"
    case .arm32:
      return "arm"
    case .x86_64:
      return "x86_64"
    }
  }

  /// HDC-visible installation directory for native libraries owned by the
  /// target application. OpenHarmony mounts this directory into the
  /// application sandbox's dynamic-linker namespace.
  package var bundleInstallRootPath: String {
    "/data/app/el1/bundle/public/\(bundle.bundleName)"
  }

  package var nativeLibrariesRootPath: String {
    "\(bundleInstallRootPath)/libs"
  }

  /// Path reported inside the application sandbox and therefore by the
  /// loader's `/proc/<pid>/maps` entry. Writable app data such as `filesDir`
  /// is deliberately not in OpenHarmony's application dynamic-linker
  /// namespace; the installed bundle-native directory is.
  /// HDC file transfer is not permitted to write directly into the installed
  /// bundle-native directory. Bytes first land in a stable, job-owned app-data
  /// directory; the typed publish action then prepares the replacement beside
  /// the target so the final rename stays atomic.
}
