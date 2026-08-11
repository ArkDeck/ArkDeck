import ArkDeckCore
import Foundation

// TASK-RF-002. Typed form of the TASK-RF-001 part 1 contract
// (`evidence/runs/TASK-RF-001/images-tar-contract.md`): the pinned DAYU200 `images.tar.gz`
// member inventory, the 9 mapped partitions with their write order and FA-001 §2 sector
// offsets, the write-forbidden surface, and the REQ-FLASH-002 prerequisite declaration.
// Values are anchored to CHG-2026-003 `member-inventory.json`, PD-002
// `partition-mapping.json` (`965e3bf3…`) and FA-001 §2; they are pinned data, not policy
// this file may relax.

package enum RockchipFlashProfileError: Error, Equatable, Sendable {
  case invalidProfileDefinition(String)
}

package enum RockchipArchiveMemberClassification: String, Codable, Equatable, Sendable {
  case mappedPartitionImage
  case orphanImageWriteForbidden
  case partitionTable
  case loaderMaskromBranchOnly
  case nonPartitionMetadata
}

package struct RockchipImagesArchiveMember: Equatable, Sendable {
  public let name: String
  package let sizeBytes: Int64
  public let sha256: String
  public let classification: RockchipArchiveMemberClassification

  public init(
    name: String,
    sizeBytes: Int64,
    sha256: String,
    classification: RockchipArchiveMemberClassification
  ) {
    self.name = name
    self.sizeBytes = sizeBytes
    self.sha256 = sha256
    self.classification = classification
  }
}

package struct RockchipMappedPartition: Equatable, Sendable {
  public let writeOrder: Int
  public let partitionName: String
  public let imageMemberName: String
  /// FA-001 §2 sector offset. Doubles as the `wl <BeginSec>` fallback value so no human
  /// ever has to compute an address by hand (design §0).
  package let offsetSectors: Int64

  public init(writeOrder: Int, partitionName: String, imageMemberName: String, offsetSectors: Int64)
  {
    self.writeOrder = writeOrder
    self.partitionName = partitionName
    self.imageMemberName = imageMemberName
    self.offsetSectors = offsetSectors
  }
}

public enum RockchipPrerequisiteIdentifier: String, CaseIterable, Codable, Equatable, Sendable {
  case loader
  case recoveryPath
  case unlocked
  case stablePower
}

public enum RockchipPrerequisiteRequirement: String, Codable, Equatable, Sendable {
  case required
  case optional
  case notApplicable
}

public enum RockchipPrerequisiteStatus: String, Codable, Equatable, Sendable {
  case satisfied
  case unsatisfied
  case unknown
}

package struct RockchipFlashProfile: Equatable, Sendable {
  package static let profileIdentity = "arkdeck.rockchip-rockusb-flash-profile.dayu200"
  package static let profileVersion = "1.0.0"
  package static let targetDeviceModel = "DAYU200 (RK3568)"
  /// Readiness pin (TASK-RF-002 readiness review): rkdeveloptool 1.32, binary SHA-256.
  package static let pinnedToolchainFingerprint =
    "rkdeveloptool-1.32@038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611"

  package let catalogReference: String
  package let firmwareVersion: String
  /// Exact value expected from `param get const.product.model` after boot.
  package let runtimeProductModel: String
  /// Exact value expected from `param get const.ohos.fullname` after boot.
  /// It is pinned separately because legacy profiles predate a versioned
  /// archive identity, while current daily profiles require the full build pin.
  public let runtimeBuildVersion: String
  public let archiveSizeBytes: Int64
  public let archiveSHA256: String
  public let members: [RockchipImagesArchiveMember]
  package let mappedPartitions: [RockchipMappedPartition]
  /// Partitions that exist on device but have no archive member; writing them is forbidden
  /// (FA-001 §2). Sector gaps are equally untouchable but have no name to list.
  package let membershiplessPartitionsWriteForbidden: [String]
  public let prerequisites: [RockchipPrerequisiteIdentifier: RockchipPrerequisiteRequirement]

  public init(
    archiveSizeBytes: Int64,
    archiveSHA256: String,
    members: [RockchipImagesArchiveMember],
    mappedPartitions: [RockchipMappedPartition],
    membershiplessPartitionsWriteForbidden: [String],
    prerequisites: [RockchipPrerequisiteIdentifier: RockchipPrerequisiteRequirement],
    catalogReference: String = "dayu200",
    firmwareVersion: String = "OpenHarmony-7.0.0.35-20260728_180253",
    runtimeProductModel: String = "DAYU200",
    runtimeBuildVersion: String = "OpenHarmony-7.0.0.36"
  ) throws {
    guard
      catalogReference == "dayu200",
      !firmwareVersion.isEmpty,
      !runtimeProductModel.isEmpty,
      !runtimeBuildVersion.isEmpty
    else {
      throw RockchipFlashProfileError.invalidProfileDefinition(
        "profile reference must be dayu200 and firmware facts must be present")
    }
    guard members.count == Set(members.map(\.name)).count else {
      throw RockchipFlashProfileError.invalidProfileDefinition("duplicate archive member name")
    }
    let memberNames = Set(members.map(\.name))
    let mappedMemberNames = Set(
      members.filter { $0.classification == .mappedPartitionImage }.map(\.name))
    guard Set(mappedPartitions.map(\.imageMemberName)) == mappedMemberNames else {
      throw RockchipFlashProfileError.invalidProfileDefinition(
        "mapped partitions and mappedPartitionImage members must agree exactly")
    }
    guard mappedPartitions.map(\.writeOrder) == Array(1...mappedPartitions.count) else {
      throw RockchipFlashProfileError.invalidProfileDefinition(
        "write order must be contiguous starting at 1")
    }
    guard mappedPartitions.map(\.offsetSectors) == mappedPartitions.map(\.offsetSectors).sorted()
    else {
      throw RockchipFlashProfileError.invalidProfileDefinition(
        "write order must be lowest offset first")
    }
    let mappedPartitionNames = Set(mappedPartitions.map(\.partitionName))
    guard mappedPartitionNames.isDisjoint(with: membershiplessPartitionsWriteForbidden) else {
      throw RockchipFlashProfileError.invalidProfileDefinition(
        "a partition cannot be both mapped and write-forbidden")
    }
    guard mappedPartitions.allSatisfy({ memberNames.contains($0.imageMemberName) }) else {
      throw RockchipFlashProfileError.invalidProfileDefinition(
        "mapped partition references an undeclared member")
    }
    self.catalogReference = catalogReference
    self.firmwareVersion = firmwareVersion
    self.runtimeProductModel = runtimeProductModel
    self.runtimeBuildVersion = runtimeBuildVersion
    self.archiveSizeBytes = archiveSizeBytes
    self.archiveSHA256 = archiveSHA256.lowercased()
    self.members = members
    self.mappedPartitions = mappedPartitions
    self.membershiplessPartitionsWriteForbidden = membershiplessPartitionsWriteForbidden
    self.prerequisites = prerequisites
  }

  public func member(named name: String) -> RockchipImagesArchiveMember? {
    members.first { $0.name == name }
  }

  public var writeForbiddenMemberNames: [String] {
    members.filter { $0.classification == .orphanImageWriteForbidden }.map(\.name)
  }

  /// The sole DAYU200 board profile. The retained seed archive is the former
  /// v2 daily image; runtime plans replace its per-build facts with those read
  /// from the exact leased archive while preserving this closed board layout.
  public static let dayu200: RockchipFlashProfile = {
    // swift-format-ignore: NeverForceUnwrap
    try! RockchipFlashProfile(
      archiveSizeBytes: 730_769_584,
      archiveSHA256: "6a023c738ac585b8a6f537c99f2ab2df95a5359fd6d4dd33150fad62e71f064e",
      members: [
        .init(
          name: "boot_linux.img", sizeBytes: 67_108_864,
          sha256: "1202a1ba694aaa3d53f104e6374a9aaffd0dba048c3122cf9f4704c4063bd757",
          classification: .mappedPartitionImage),
        .init(
          name: "chip_ckm.img", sizeBytes: 33_554_432,
          sha256: "f99c14c2520f618c721c963307ddc72ec47aefb5a71c7b29b268b1b33edcc0db",
          classification: .mappedPartitionImage),
        .init(
          name: "chip_prod.img", sizeBytes: 52_428_800,
          sha256: "44797e1616481c6211526358c11056862e04a3595dd81f59e41aec03a384ad29",
          classification: .orphanImageWriteForbidden),
        .init(
          name: "config.cfg", sizeBytes: 10_399,
          sha256: "4d06d303faff1d3e530a9d2c9bb22073427b0b498bb4bb438b5177897d86f33c",
          classification: .nonPartitionMetadata),
        .init(
          name: "daily_build.log", sizeBytes: 24_507_809,
          sha256: "8454628003ab59a4edf28c073b39ec3891cad925283244c3bed0b754ecf35503",
          classification: .nonPartitionMetadata),
        .init(
          name: "manifest_tag.xml", sizeBytes: 115_118,
          sha256: "71f9293a21d21fb1da67d27b0482b198c62ce042bb80326d62e1a0f35ee12691",
          classification: .nonPartitionMetadata),
        .init(
          name: "MiniLoaderAll.bin", sizeBytes: 455_104,
          sha256: "1cdd418032195210f191445ed96e2da5ea83d2cfe880c912ebec635839d76542",
          classification: .loaderMaskromBranchOnly),
        .init(
          name: "parameter.txt", sizeBytes: 788,
          sha256: "35464e3f0b883a8a043dd45ae7ab2342c86b7aa27f24aa1e5a0ccfb6f442d048",
          classification: .partitionTable),
        .init(
          name: "ramdisk.img", sizeBytes: 2_366_141,
          sha256: "c7e94434b4624ef70a5b9472d4848212a79c89b7a8cb5a453262e56a72e5dec9",
          classification: .mappedPartitionImage),
        .init(
          name: "resource.img", sizeBytes: 5_652_480,
          sha256: "208ceef6be9ba6d5781033bf00718b15f54d0210ae2f0e8134d4a5e40a9c13e7",
          classification: .mappedPartitionImage),
        .init(
          name: "sys_prod.img", sizeBytes: 52_428_800,
          sha256: "631845214a4ca4da44094165e30509eb2254a601350b56f90197bf78c3aa85d7",
          classification: .orphanImageWriteForbidden),
        .init(
          name: "system.img", sizeBytes: 2_147_483_648,
          sha256: "86357e57a183278e1662d55c2d560a35e8e685613bd270f62df42bdf783f0650",
          classification: .mappedPartitionImage),
        .init(
          name: "uboot.img", sizeBytes: 4_194_304,
          sha256: "c1c801e45cbb92ee63e14df3dda5d819792e02295525bd53dbf750efb645916d",
          classification: .mappedPartitionImage),
        .init(
          name: "updater_binary", sizeBytes: 3_248_972,
          sha256: "250b6ebc32f33088a328804cc918766aa6ea30f1c0acc8e2d08cf3ec7cf8f23f",
          classification: .nonPartitionMetadata),
        .init(
          name: "updater.img", sizeBytes: 20_688_145,
          sha256: "907076f10bc295a3712a911c31c7c8f83bb164cdff4d8d9c1c62d3e91c0f637a",
          classification: .mappedPartitionImage),
        .init(
          name: "userdata.img", sizeBytes: 1_468_006_400,
          sha256: "ea60e842586208b660b72ae4b507a1f4cabb397e912156f342f30f21907e1255",
          classification: .mappedPartitionImage),
        .init(
          name: "vendor.img", sizeBytes: 268_431_360,
          sha256: "b3ffda2b6dbae220361721ee6b78d25e2055ab506e5480b17eacf477ea482360",
          classification: .mappedPartitionImage),
      ],
      mappedPartitions: [
        .init(
          writeOrder: 1, partitionName: "uboot", imageMemberName: "uboot.img",
          offsetSectors: 8192),
        .init(
          writeOrder: 2, partitionName: "resource", imageMemberName: "resource.img",
          offsetSectors: 28672),
        .init(
          writeOrder: 3, partitionName: "boot_linux", imageMemberName: "boot_linux.img",
          offsetSectors: 40960),
        .init(
          writeOrder: 4, partitionName: "ramdisk", imageMemberName: "ramdisk.img",
          offsetSectors: 237_568),
        .init(
          writeOrder: 5, partitionName: "system", imageMemberName: "system.img",
          offsetSectors: 245_760),
        .init(
          writeOrder: 6, partitionName: "vendor", imageMemberName: "vendor.img",
          offsetSectors: 4_440_064),
        .init(
          writeOrder: 7, partitionName: "updater", imageMemberName: "updater.img",
          offsetSectors: 6_742_016),
        .init(
          writeOrder: 8, partitionName: "chip_ckm", imageMemberName: "chip_ckm.img",
          offsetSectors: 6_938_624),
        .init(
          writeOrder: 9, partitionName: "userdata", imageMemberName: "userdata.img",
          offsetSectors: 19_955_712),
      ],
      membershiplessPartitionsWriteForbidden: [
        "misc", "bootctrl", "sys-prod", "chip-prod", "eng_system", "eng_chipset",
      ],
      prerequisites: [
        .loader: .required,
        .recoveryPath: .required,
        .unlocked: .required,
        .stablePower: .optional,
      ],
      catalogReference: "dayu200",
      firmwareVersion: "OpenHarmony-7.0.0.35-20260728_180253",
      // The daily archive's *name* says 7.0.0.35, but the params baked into
      // its system.img — and therefore what the booted device answers — say
      // 7.0.0.36 (`const.ohos.fullname=OpenHarmony-7.0.0.36`, confirmed on
      // the flashed device on 2026-08-04). Post-flash verification compares
      // against the booted answer, so this pin must carry the embedded value,
      // never one inferred from the archive name.
      runtimeProductModel: "ohos",
      runtimeBuildVersion: "OpenHarmony-7.0.0.36"
    )
  }()

  public static func profile(reference: String) -> RockchipFlashProfile? {
    reference == dayu200.catalogReference ? dayu200 : nil
  }

  public static func profile(archiveSHA256: String, byteCount: Int) -> RockchipFlashProfile? {
    dayu200.archiveSHA256 == archiveSHA256.lowercased()
      && dayu200.archiveSizeBytes == Int64(byteCount) ? dayu200 : nil
  }

  package var planDocumentVersion: String { Self.profileVersion }
}

// MARK: - Archive validation (REQ-FLASH-003 face used by TASK-RF-002)

package struct RockchipArchiveMemberObservation: Equatable, Sendable {
  public let name: String
  package let sizeBytes: Int64
  public let sha256: String

  public init(name: String, sizeBytes: Int64, sha256: String) {
    self.name = name
    self.sizeBytes = sizeBytes
    self.sha256 = sha256.lowercased()
  }
}

package struct RockchipImagesArchiveObservation: Equatable, Sendable {
  public let archiveSizeBytes: Int64
  public let archiveSHA256: String
  public let members: [RockchipArchiveMemberObservation]

  public init(
    archiveSizeBytes: Int64, archiveSHA256: String, members: [RockchipArchiveMemberObservation]
  ) {
    self.archiveSizeBytes = archiveSizeBytes
    self.archiveSHA256 = archiveSHA256.lowercased()
    self.members = members
  }
}

package enum RockchipArchiveViolation: Equatable, Sendable, CustomStringConvertible {
  case archiveSizeMismatch(expected: Int64, observed: Int64)
  case archiveHashMismatch(expected: String, observed: String)
  case duplicateMember(name: String)
  case missingMember(name: String)
  case undeclaredMember(name: String)
  case memberSizeMismatch(name: String, expected: Int64, observed: Int64)
  case memberHashMismatch(name: String, expected: String, observed: String)

  public var description: String {
    switch self {
    case .archiveSizeMismatch(let expected, let observed):
      "archive size mismatch: expected \(expected), observed \(observed)"
    case .archiveHashMismatch(let expected, let observed):
      "archive SHA-256 mismatch: expected \(expected), observed \(observed)"
    case .duplicateMember(let name):
      "duplicate archive member: \(name)"
    case .missingMember(let name):
      "missing archive member: \(name)"
    case .undeclaredMember(let name):
      "member not declared by the Profile (unknown provenance): \(name)"
    case .memberSizeMismatch(let name, let expected, let observed):
      "member \(name) size mismatch: expected \(expected), observed \(observed)"
    case .memberHashMismatch(let name, let expected, let observed):
      "member \(name) SHA-256 mismatch: expected \(expected), observed \(observed)"
    }
  }
}

/// Any violation blocks both the execute branch and planned-success (AC-FLASH-003-01):
/// a plan built from an unvalidated archive must not exist at all.
package enum RockchipArchiveValidationVerdict: Equatable, Sendable {
  case valid
  case blocked([RockchipArchiveViolation])

  package var blocksExecuteAndPlannedSuccess: Bool {
    if case .blocked = self { return true }
    return false
  }
}

extension RockchipFlashProfile {
  public func validate(_ observation: RockchipImagesArchiveObservation)
    -> RockchipArchiveValidationVerdict
  {
    var violations: [RockchipArchiveViolation] = []
    if observation.archiveSizeBytes != archiveSizeBytes {
      violations.append(
        .archiveSizeMismatch(expected: archiveSizeBytes, observed: observation.archiveSizeBytes))
    }
    if observation.archiveSHA256 != archiveSHA256 {
      violations.append(
        .archiveHashMismatch(expected: archiveSHA256, observed: observation.archiveSHA256))
    }

    var seen: Set<String> = []
    var observedByName: [String: RockchipArchiveMemberObservation] = [:]
    for observed in observation.members {
      guard seen.insert(observed.name).inserted else {
        violations.append(.duplicateMember(name: observed.name))
        continue
      }
      observedByName[observed.name] = observed
    }

    for declared in members {
      guard let observed = observedByName[declared.name] else {
        violations.append(.missingMember(name: declared.name))
        continue
      }
      if observed.sizeBytes != declared.sizeBytes {
        violations.append(
          .memberSizeMismatch(
            name: declared.name, expected: declared.sizeBytes, observed: observed.sizeBytes))
      }
      if observed.sha256 != declared.sha256.lowercased() {
        violations.append(
          .memberHashMismatch(
            name: declared.name, expected: declared.sha256.lowercased(),
            observed: observed.sha256))
      }
    }

    let declaredNames = Set(members.map(\.name))
    for observed in observation.members where !declaredNames.contains(observed.name) {
      violations.append(.undeclaredMember(name: observed.name))
    }

    return violations.isEmpty ? .valid : .blocked(violations)
  }
}

// MARK: - Board-scoped classification (CHG-2026-056 r4, TASK-E2B-001)

extension RockchipFlashProfile {
  /// The loader is named by the vendor's own convention, not by this board.
  package static let loaderMemberName = "MiniLoaderAll.bin"
  /// Rockchip's partition table always travels as this file.
  package static let partitionTableMemberName = "parameter.txt"
  /// The partition whose image carries the value the booted device reports as
  /// its build version.
  package var runtimeVersionPartitionName: String { "system" }

  /// What an archive member is, decided from board facts and the member's
  /// name alone.
  ///
  /// This is a *rule*, not a table, and that is the whole point: a new daily
  /// build ships the same seventeen names, so nothing about it needs to be
  /// enumerated in advance. `RockchipFlashProfileContractTests` asserts the
  /// rule reproduces the hand-authored classification of every member of both
  /// published profiles exactly, so it cannot drift into a guess.
  public func classification(ofMemberNamed name: String)
    -> RockchipArchiveMemberClassification
  {
    if name == Self.partitionTableMemberName { return .partitionTable }
    if name == Self.loaderMemberName { return .loaderMaskromBranchOnly }
    if mappedPartitions.contains(where: { $0.imageMemberName == name }) {
      return .mappedPartitionImage
    }
    // An image whose name resolves to a partition this board forbids writing
    // is an orphan: it ships in the archive and must never reach the device.
    if name.hasSuffix(".img"),
      membershiplessPartitionsWriteForbidden.contains(Self.partitionName(fromImageMember: name))
    {
      return .orphanImageWriteForbidden
    }
    return .nonPartitionMetadata
  }

  /// `chip_prod.img` names the `chip-prod` partition. The archive spells the
  /// separator with an underscore and the partition table with a hyphen.
  static func partitionName(fromImageMember name: String) -> String {
    String(name.dropLast(4)).replacingOccurrences(of: "_", with: "-")
  }

  /// Does an archive the product has never seen fit this board?
  ///
  /// Structural, not by digest: every partition this board maps must have an
  /// image, and every partition the archive's own table declares must be one
  /// this board knows. Byte integrity is the Artifact lease's and the
  /// exact-plan authority's (REQ-FLASH-017), not this function's.
  package func conformance(of build: RockchipImageBuildDescriptor) -> [String] {
    var violations: [String] = []
    let memberNames = Set(build.members.map(\.name))
    for mapped in mappedPartitions where !memberNames.contains(mapped.imageMemberName) {
      violations.append("mappedPartitionImageMissing:\(mapped.partitionName)")
    }
    let declaredNames = Set(build.declaredPartitions.map(\.name))
    let knownNames = Set(mappedPartitions.map(\.partitionName))
      .union(membershiplessPartitionsWriteForbidden)
    for declared in declaredNames.subtracting(knownNames).sorted() {
      violations.append("undeclaredPartitionInTable:\(declared)")
    }
    for mapped in mappedPartitions where !declaredNames.contains(mapped.partitionName) {
      violations.append("mappedPartitionAbsentFromTable:\(mapped.partitionName)")
    }
    if build.runtimeBuildVersion.isEmpty {
      violations.append("runtimeBuildVersionUnreadable")
    }
    return violations
  }
}

// MARK: - Instantiating a board profile for the build in hand (CHG-2026-056 r4)

extension RockchipFlashProfile {
  /// This board, carrying the facts of one particular archive.
  ///
  /// The per-build fields stay where they were — every downstream site that
  /// records a plan digest, stages an archive or verifies a flashed device
  /// reads them exactly as before. What changed is where they come from: the
  /// archive that was actually imported and confirmed, rather than a constant
  /// somebody typed in when that week's daily came out.
  ///
  /// This is the whole cutover in one function. The comparisons downstream are
  /// unchanged and still fail closed; they now mean "these are the bytes this
  /// plan was built for" instead of "this is a build we shipped knowledge of".
  package func forBuild(_ build: RockchipImageBuildDescriptor) throws -> RockchipFlashProfile {
    let violations = conformance(of: build)
    guard violations.isEmpty else {
      throw DeviceProviderError.unsupportedAction(
        "flash bundle does not fit \(catalogReference): "
          + violations.joined(separator: "; "))
    }
    return try RockchipFlashProfile(
      archiveSizeBytes: build.archiveSizeBytes,
      archiveSHA256: build.archiveSHA256,
      members: build.members,
      mappedPartitions: mappedPartitions,
      membershiplessPartitionsWriteForbidden: membershiplessPartitionsWriteForbidden,
      prerequisites: prerequisites,
      catalogReference: catalogReference,
      firmwareVersion: build.runtimeBuildVersion,
      runtimeProductModel: runtimeProductModel,
      runtimeBuildVersion: build.runtimeBuildVersion)
  }

  /// Reads an images archive and returns this board carrying its facts.
  ///
  /// One pass: decompress, hash, capture the partition table, scan the system
  /// image for the version. Nothing is extracted and nothing is compared
  /// against a list of builds.
  package func forArchive(at url: URL) throws -> RockchipFlashProfile {
    let summary = try GzipTarArchiveReader.summarize(
      fileAt: url,
      derivation: RockchipImageArchiveIntrospection.derivationRequest(board: self))
    return try forBuild(
      RockchipImageArchiveIntrospection.describe(summary: summary, board: self))
  }

  /// The one published DAYU200 reference resolves to the sole board profile.
  package static func board(reference: String) -> RockchipFlashProfile? {
    reference == dayu200.catalogReference ? dayu200 : nil
  }
}
