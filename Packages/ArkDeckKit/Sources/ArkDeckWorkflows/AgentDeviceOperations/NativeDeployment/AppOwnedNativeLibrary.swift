import ArkDeckCore
import CryptoKit
import Foundation

public enum HDCNativeLibraryABI: String, Sendable, Equatable, Codable {
  case arm64 = "arm64-v8a"
  case arm32 = "armeabi-v7a"
  case x86_64
}

package struct HDCNativeLibraryArtifactFacts: Sendable, Equatable {
  package let abi: HDCNativeLibraryABI
  package let elfClassBits: Int
  public let machine: UInt16
  package let buildID: String
  public let sha256: String
  public let byteCount: Int
  package let codeSign: HDCNativeLibraryCodeSignFacts?

  public init(
    abi: HDCNativeLibraryABI,
    elfClassBits: Int,
    machine: UInt16,
    buildID: String,
    sha256: String,
    byteCount: Int,
    codeSign: HDCNativeLibraryCodeSignFacts? = nil
  ) {
    self.abi = abi
    self.elfClassBits = elfClassBits
    self.machine = machine
    self.buildID = buildID
    self.sha256 = sha256
    self.byteCount = byteCount
    self.codeSign = codeSign
  }
}

package struct HDCNativeLibraryCodeSignFacts: Sendable, Equatable {
  package let formatVersion: Int
  package let codeSignVersion: Int
  package let signedDataByteCount: Int
  package let signatureByteCount: Int

  public init(
    formatVersion: Int,
    codeSignVersion: Int,
    signedDataByteCount: Int,
    signatureByteCount: Int
  ) {
    self.formatVersion = formatVersion
    self.codeSignVersion = codeSignVersion
    self.signedDataByteCount = signedDataByteCount
    self.signatureByteCount = signatureByteCount
  }
}

public enum NativeLibraryArtifactValidationError: Error, Equatable, CustomStringConvertible {
  case invalidELF
  case unsupportedEncoding
  case unsupportedMachine(UInt16)
  case classMachineMismatch
  case abiMismatch(expected: HDCNativeLibraryABI, actual: HDCNativeLibraryABI)
  case missingBuildID
  case missingOpenHarmonyCodeSignBlock
  case invalidOpenHarmonyCodeSignBlock

  public var description: String {
    switch self {
    case .invalidELF:
      return "native library is not a bounded, structurally valid ELF object"
    case .unsupportedEncoding:
      return "native library must use little-endian ELF encoding"
    case .unsupportedMachine(let machine):
      return "native library ELF machine \(machine) is unsupported"
    case .classMachineMismatch:
      return "native library ELF class does not match its machine"
    case .abiMismatch(let expected, let actual):
      return "native library ABI \(actual.rawValue) does not match expected \(expected.rawValue)"
    case .missingBuildID:
      return "native library has no GNU ELF build ID"
    case .missingOpenHarmonyCodeSignBlock:
      return "native library has no OpenHarmony V1 ELF code-sign block"
    case .invalidOpenHarmonyCodeSignBlock:
      return "native library has a malformed OpenHarmony V1 ELF code-sign block"
    }
  }
}

/// Host-side verifier for leased native libraries. It parses only the closed
/// ELF fields ArkDeck needs for admission and never invokes a build tool or
/// accepts caller-supplied metadata.
package enum NativeLibraryArtifactValidator {
  package static let maximumBytes = 64 * 1_024 * 1_024

  public static func validate(
    _ data: Data,
    expectedABI: HDCNativeLibraryABI? = nil,
    requireOpenHarmonyCodeSignature: Bool = false
  ) throws -> HDCNativeLibraryArtifactFacts {
    guard (64...maximumBytes).contains(data.count),
      data[0] == 0x7f, data[1] == 0x45, data[2] == 0x4c, data[3] == 0x46
    else {
      throw NativeLibraryArtifactValidationError.invalidELF
    }
    let elfClass = data[4]
    guard elfClass == 1 || elfClass == 2 else {
      throw NativeLibraryArtifactValidationError.invalidELF
    }
    guard data[5] == 1 else {
      throw NativeLibraryArtifactValidationError.unsupportedEncoding
    }
    guard let machine = readUInt16(data, at: 18) else {
      throw NativeLibraryArtifactValidationError.invalidELF
    }
    let abi: HDCNativeLibraryABI
    switch machine {
    case 183:
      guard elfClass == 2 else {
        throw NativeLibraryArtifactValidationError.classMachineMismatch
      }
      abi = .arm64
    case 40:
      guard elfClass == 1 else {
        throw NativeLibraryArtifactValidationError.classMachineMismatch
      }
      abi = .arm32
    case 62:
      guard elfClass == 2 else {
        throw NativeLibraryArtifactValidationError.classMachineMismatch
      }
      abi = .x86_64
    default:
      throw NativeLibraryArtifactValidationError.unsupportedMachine(machine)
    }
    if let expectedABI, expectedABI != abi {
      throw NativeLibraryArtifactValidationError.abiMismatch(
        expected: expectedABI, actual: abi)
    }
    guard let buildID = buildID(in: data, elfClass: elfClass) else {
      throw NativeLibraryArtifactValidationError.missingBuildID
    }
    let codeSign = try openHarmonyCodeSignFacts(
      in: data, required: requireOpenHarmonyCodeSignature)
    let sha256 = SHA256Hex.string(of: data)
    return HDCNativeLibraryArtifactFacts(
      abi: abi,
      elfClassBits: elfClass == 2 ? 64 : 32,
      machine: machine,
      buildID: buildID,
      sha256: sha256,
      byteCount: data.count,
      codeSign: codeSign)
  }

  private static func openHarmonyCodeSignFacts(
    in data: Data,
    required: Bool
  ) throws -> HDCNativeLibraryCodeSignFacts? {
    let headerSize = 32
    let signMagic = Data("elf sign block  ".utf8)
    let version = Data("1000".utf8)
    guard data.count >= headerSize else {
      if required {
        throw NativeLibraryArtifactValidationError.missingOpenHarmonyCodeSignBlock
      }
      return nil
    }
    let headerOffset = data.count - headerSize
    guard data.subdata(in: headerOffset..<(headerOffset + 16)) == signMagic else {
      if required {
        throw NativeLibraryArtifactValidationError.missingOpenHarmonyCodeSignBlock
      }
      return nil
    }
    guard data.subdata(in: (headerOffset + 16)..<(headerOffset + 20)) == version,
      let blockSizeValue = readUInt32(data, at: headerOffset + 20),
      let blockCountValue = readUInt32(data, at: headerOffset + 24)
    else {
      throw NativeLibraryArtifactValidationError.invalidOpenHarmonyCodeSignBlock
    }
    let blockSize = Int(blockSizeValue)
    let blockCount = Int(blockCountValue)
    guard (1...2).contains(blockCount),
      blockSize >= blockCount * 12,
      blockSize <= 16 * 1_024 * 1_024,
      blockSize <= headerOffset
    else {
      throw NativeLibraryArtifactValidationError.invalidOpenHarmonyCodeSignBlock
    }
    let blockOffset = headerOffset - blockSize
    var signInfoOffset: Int?
    for index in 0..<blockCount {
      let offset = blockOffset + index * 12
      guard let type = readUInt16(data, at: offset),
        let candidateValue = readUInt32(data, at: offset + 8)
      else {
        throw NativeLibraryArtifactValidationError.invalidOpenHarmonyCodeSignBlock
      }
      if type == 3 {
        signInfoOffset = Int(candidateValue)
        break
      }
    }
    guard let merkleRelativeOffset = signInfoOffset,
      merkleRelativeOffset > 0,
      merkleRelativeOffset <= blockSize - 8
    else {
      throw NativeLibraryArtifactValidationError.invalidOpenHarmonyCodeSignBlock
    }
    let merkleOffset = blockOffset + merkleRelativeOffset
    guard readUInt32(data, at: merkleOffset) == 2,
      let merkleLengthValue = readUInt32(data, at: merkleOffset + 4)
    else {
      throw NativeLibraryArtifactValidationError.invalidOpenHarmonyCodeSignBlock
    }
    let merkleLength = Int(merkleLengthValue)
    guard merkleLength <= blockSize - merkleRelativeOffset - 8 else {
      throw NativeLibraryArtifactValidationError.invalidOpenHarmonyCodeSignBlock
    }
    let infoRelativeOffset = merkleRelativeOffset + 8 + merkleLength
    let infoPrefixSize = 264
    guard infoRelativeOffset <= blockSize,
      blockSize - infoRelativeOffset >= infoPrefixSize
    else {
      throw NativeLibraryArtifactValidationError.invalidOpenHarmonyCodeSignBlock
    }
    let infoOffset = blockOffset + infoRelativeOffset
    guard readUInt32(data, at: infoOffset) == 1,
      let lengthValue = readUInt32(data, at: infoOffset + 4),
      data[infoOffset + 8] == 1,
      data[infoOffset + 9] == 1,
      data[infoOffset + 10] == 12,
      data[infoOffset + 11] <= 32,
      let signatureSizeValue = readUInt32(data, at: infoOffset + 12),
      let signedDataSizeValue = readUInt64(data, at: infoOffset + 16)
    else {
      throw NativeLibraryArtifactValidationError.invalidOpenHarmonyCodeSignBlock
    }
    let length = Int(lengthValue)
    let signatureSize = Int(signatureSizeValue)
    guard signatureSize > 0, signatureSize <= 4 * 1_024 * 1_024,
      length <= blockSize - infoRelativeOffset - 8,
      infoPrefixSize + signatureSize <= 8 + length,
      signedDataSizeValue == UInt64(blockOffset),
      data[infoOffset + 263] == 1
    else {
      throw NativeLibraryArtifactValidationError.invalidOpenHarmonyCodeSignBlock
    }
    return HDCNativeLibraryCodeSignFacts(
      formatVersion: 1,
      codeSignVersion: 1,
      signedDataByteCount: Int(signedDataSizeValue),
      signatureByteCount: signatureSize)
  }

  private static func buildID(in data: Data, elfClass: UInt8) -> String? {
    let sectionOffset: Int
    let sectionEntrySizeOffset: Int
    let sectionCountOffset: Int
    if elfClass == 2 {
      guard let rawOffset = readUInt64(data, at: 40), rawOffset <= UInt64(Int.max) else {
        return nil
      }
      sectionOffset = Int(rawOffset)
      sectionEntrySizeOffset = 58
      sectionCountOffset = 60
    } else {
      guard let rawOffset = readUInt32(data, at: 32) else { return nil }
      sectionOffset = Int(rawOffset)
      sectionEntrySizeOffset = 46
      sectionCountOffset = 48
    }
    guard let entrySizeValue = readUInt16(data, at: sectionEntrySizeOffset),
      let countValue = readUInt16(data, at: sectionCountOffset)
    else {
      return nil
    }
    let entrySize = Int(entrySizeValue)
    let count = Int(countValue)
    let minimumEntrySize = elfClass == 2 ? 64 : 40
    guard sectionOffset > 0, entrySize >= minimumEntrySize, count > 0,
      count <= 65_535,
      sectionOffset <= data.count,
      entrySize <= data.count,
      count <= (data.count - sectionOffset) / entrySize
    else {
      return nil
    }
    for index in 0..<count {
      let header = sectionOffset + index * entrySize
      guard readUInt32(data, at: header + 4) == 7 else { continue }  // SHT_NOTE
      let noteOffset: Int
      let noteSize: Int
      if elfClass == 2 {
        guard let rawOffset = readUInt64(data, at: header + 24),
          let rawSize = readUInt64(data, at: header + 32),
          rawOffset <= UInt64(Int.max), rawSize <= UInt64(Int.max)
        else {
          continue
        }
        noteOffset = Int(rawOffset)
        noteSize = Int(rawSize)
      } else {
        guard let rawOffset = readUInt32(data, at: header + 16),
          let rawSize = readUInt32(data, at: header + 20)
        else {
          continue
        }
        noteOffset = Int(rawOffset)
        noteSize = Int(rawSize)
      }
      guard noteOffset <= data.count, noteSize <= data.count - noteOffset else { continue }
      if let buildID = parseBuildIDNotes(data, range: noteOffset..<(noteOffset + noteSize)) {
        return buildID
      }
    }
    return nil
  }

  private static func parseBuildIDNotes(_ data: Data, range: Range<Int>) -> String? {
    var cursor = range.lowerBound
    while cursor <= range.upperBound - 12 {
      guard let nameSizeValue = readUInt32(data, at: cursor),
        let descriptionSizeValue = readUInt32(data, at: cursor + 4),
        let type = readUInt32(data, at: cursor + 8)
      else {
        return nil
      }
      let nameSize = Int(nameSizeValue)
      let descriptionSize = Int(descriptionSizeValue)
      let nameStart = cursor + 12
      guard let paddedNameSize = aligned4(nameSize),
        nameStart <= range.upperBound,
        paddedNameSize <= range.upperBound - nameStart
      else {
        return nil
      }
      let descriptionStart = nameStart + paddedNameSize
      guard let paddedDescriptionSize = aligned4(descriptionSize),
        descriptionStart <= range.upperBound,
        paddedDescriptionSize <= range.upperBound - descriptionStart
      else {
        return nil
      }
      if type == 3, nameSize >= 3,
        data.subdata(in: nameStart..<(nameStart + 3)) == Data("GNU".utf8),
        descriptionSize > 0
      {
        return data[descriptionStart..<(descriptionStart + descriptionSize)]
          .map { String(format: "%02x", $0) }.joined()
      }
      cursor = descriptionStart + paddedDescriptionSize
    }
    return nil
  }

  private static func aligned4(_ value: Int) -> Int? {
    guard value >= 0, value <= Int.max - 3 else { return nil }
    return (value + 3) & ~3
  }

  private static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
    guard offset >= 0, offset <= data.count - 2 else { return nil }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset <= data.count - 4 else { return nil }
    return UInt32(data[offset])
      | (UInt32(data[offset + 1]) << 8)
      | (UInt32(data[offset + 2]) << 16)
      | (UInt32(data[offset + 3]) << 24)
  }

  private static func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
    guard let low = readUInt32(data, at: offset),
      let high = readUInt32(data, at: offset + 4)
    else {
      return nil
    }
    return UInt64(low) | (UInt64(high) << 32)
  }
}

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
    guard jobID.range(
      of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,127}$"#,
      options: .regularExpression) != nil
    else {
      throw DeviceProviderError.unsupportedAction("native deployment job identity is invalid")
    }
    guard libraryLogicalName.range(
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
