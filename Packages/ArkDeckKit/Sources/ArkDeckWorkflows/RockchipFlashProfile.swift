import ArkDeckCore
import Foundation

// TASK-RF-002. Typed form of the TASK-RF-001 part 1 contract
// (`evidence/runs/TASK-RF-001/images-tar-contract.md`): the pinned DAYU200 `images.tar.gz`
// member inventory, the 9 mapped partitions with their write order and FA-001 §2 sector
// offsets, the write-forbidden surface, and the REQ-FLASH-002 prerequisite declaration.
// Values are anchored to CHG-2026-003 `member-inventory.json`, PD-002
// `partition-mapping.json` (`965e3bf3…`) and FA-001 §2; they are pinned data, not policy
// this file may relax.

public enum RockchipFlashProfileError: Error, Equatable, Sendable {
  case invalidProfileDefinition(String)
}

public enum RockchipArchiveMemberClassification: String, Codable, Equatable, Sendable {
  case mappedPartitionImage
  case orphanImageWriteForbidden
  case partitionTable
  case loaderMaskromBranchOnly
  case nonPartitionMetadata
}

public struct RockchipImagesArchiveMember: Equatable, Sendable {
  public let name: String
  public let sizeBytes: Int64
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

public struct RockchipMappedPartition: Equatable, Sendable {
  public let writeOrder: Int
  public let partitionName: String
  public let imageMemberName: String
  /// FA-001 §2 sector offset. Doubles as the `wl <BeginSec>` fallback value so no human
  /// ever has to compute an address by hand (design §0).
  public let offsetSectors: Int64

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

public struct RockchipFlashProfile: Sendable {
  public static let profileIdentity = "arkdeck.rockchip-rockusb-flash-profile.dayu200"
  public static let profileVersion = "1.0.0"
  public static let targetDeviceModel = "DAYU200 (RK3568)"
  /// Readiness pin (TASK-RF-002 readiness review): rkdeveloptool 1.32, binary SHA-256.
  public static let pinnedToolchainFingerprint =
    "rkdeveloptool-1.32@038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611"

  public let archiveSizeBytes: Int64
  public let archiveSHA256: String
  public let members: [RockchipImagesArchiveMember]
  public let mappedPartitions: [RockchipMappedPartition]
  /// Partitions that exist on device but have no archive member; writing them is forbidden
  /// (FA-001 §2). Sector gaps are equally untouchable but have no name to list.
  public let membershiplessPartitionsWriteForbidden: [String]
  public let prerequisites: [RockchipPrerequisiteIdentifier: RockchipPrerequisiteRequirement]

  public init(
    archiveSizeBytes: Int64,
    archiveSHA256: String,
    members: [RockchipImagesArchiveMember],
    mappedPartitions: [RockchipMappedPartition],
    membershiplessPartitionsWriteForbidden: [String],
    prerequisites: [RockchipPrerequisiteIdentifier: RockchipPrerequisiteRequirement]
  ) throws {
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

  // MARK: - Pinned DAYU200 profile (images-tar-contract.md §1)

  public static let dayu200: RockchipFlashProfile = {
    // Force-try is deliberate: this literal profile is validated by the same invariants as
    // any runtime profile, and a definition error must be unbuildable, not recoverable.
    // swift-format-ignore: NeverForceUnwrap
    try! RockchipFlashProfile(
      archiveSizeBytes: 732_948_803,
      archiveSHA256: "fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280",
      members: [
        .init(
          name: "boot_linux.img", sizeBytes: 67_108_864,
          sha256: "390c2cf2bf59f8bedc99a9622a1263410c6132341aece6a1b9c30ed5567a9523",
          classification: .mappedPartitionImage),
        .init(
          name: "chip_ckm.img", sizeBytes: 33_554_432,
          sha256: "b60b62747679659c337eef737ea5064bbcea68b9fc219f62a076c06d05a6c81a",
          classification: .mappedPartitionImage),
        .init(
          name: "chip_prod.img", sizeBytes: 52_428_800,
          sha256: "6d009c6b685f65f91bd77ceb201916f07dde8668fde4432ee534bb04e0b6cbad",
          classification: .orphanImageWriteForbidden),
        .init(
          name: "config.cfg", sizeBytes: 10_399,
          sha256: "4d06d303faff1d3e530a9d2c9bb22073427b0b498bb4bb438b5177897d86f33c",
          classification: .nonPartitionMetadata),
        .init(
          name: "daily_build.log", sizeBytes: 24_496_219,
          sha256: "5823dd263cab3168dbd3ee098c5b5045b82b8393548b9da9f095de2883a2a0e9",
          classification: .nonPartitionMetadata),
        .init(
          name: "manifest_tag.xml", sizeBytes: 114_913,
          sha256: "fd458507b4bb63f372049a0bb9a2cd779af426e2d27de43134ace05e5884ff74",
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
          name: "ramdisk.img", sizeBytes: 2_385_465,
          sha256: "cc6f7c3d9568cbb3f810edd67ebe0015a04734605ca4f21c065ce94f88ec3b07",
          classification: .mappedPartitionImage),
        .init(
          name: "resource.img", sizeBytes: 5_652_480,
          sha256: "161cf158f6f256e7794568b1307581e4656da1a8d8d3d2612da73195d3eda06e",
          classification: .mappedPartitionImage),
        .init(
          name: "sys_prod.img", sizeBytes: 52_428_800,
          sha256: "8dfb72cfa61dc748f62f3d766214ab579c857f3b8a62e6890a8abc7ae0ac1062",
          classification: .orphanImageWriteForbidden),
        .init(
          name: "system.img", sizeBytes: 2_147_483_648,
          sha256: "aef65124a814fcce8345dbfbdf049aaa862bd76786d099095c6951b4561ba1bb",
          classification: .mappedPartitionImage),
        .init(
          name: "uboot.img", sizeBytes: 4_194_304,
          sha256: "c1c801e45cbb92ee63e14df3dda5d819792e02295525bd53dbf750efb645916d",
          classification: .mappedPartitionImage),
        .init(
          name: "updater_binary", sizeBytes: 3_248_612,
          sha256: "84659f9fd5a13b8293904f9ad7531ee9637523efffb90e74a49443f9f8ef5cd5",
          classification: .nonPartitionMetadata),
        .init(
          name: "updater.img", sizeBytes: 20_692_486,
          sha256: "5f70d2f79cbcda267a20aff98c187ffdaac2ce1f693ae6f7dbdc2bec7b1c5494",
          classification: .mappedPartitionImage),
        .init(
          name: "userdata.img", sizeBytes: 1_468_006_400,
          sha256: "715e7998ebd47653a0ec2e062964224684762ab8686330c6b69b8d5f1f55886c",
          classification: .mappedPartitionImage),
        .init(
          name: "vendor.img", sizeBytes: 268_431_360,
          sha256: "61e0c9adda4420417d88bcc1f4d725558b75e41046f528100a584c8dc466cd41",
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
        // The 9-partition write sequence overwrites `userdata`, so the unlocked/strong-confirm
        // prerequisite is always required for this profile, not only for explicit erase.
        .unlocked: .required,
        .stablePower: .optional,
      ]
    )
  }()
}

// MARK: - Archive validation (REQ-FLASH-003 face used by TASK-RF-002)

public struct RockchipArchiveMemberObservation: Equatable, Sendable {
  public let name: String
  public let sizeBytes: Int64
  public let sha256: String

  public init(name: String, sizeBytes: Int64, sha256: String) {
    self.name = name
    self.sizeBytes = sizeBytes
    self.sha256 = sha256.lowercased()
  }
}

public struct RockchipImagesArchiveObservation: Equatable, Sendable {
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

public enum RockchipArchiveViolation: Equatable, Sendable, CustomStringConvertible {
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
public enum RockchipArchiveValidationVerdict: Equatable, Sendable {
  case valid
  case blocked([RockchipArchiveViolation])

  public var blocksExecuteAndPlannedSuccess: Bool {
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
