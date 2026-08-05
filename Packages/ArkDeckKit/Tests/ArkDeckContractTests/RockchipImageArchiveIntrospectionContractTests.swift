// Archive introspection contract (CHG-2026-056 r4, TASK-E2B-001).
//
// A device profile describes a board; a firmware build describes itself. These
// tests hold the second half of that sentence to the same standard as the
// first — the classification rule has to reproduce the hand-authored table it
// replaces, member for member, on both published profiles. A rule that merely
// looks reasonable would be a guess, and a guess about which image reaches
// which partition is not something to hold about an E2 destructive operation.
//
// No device is touched: every test reads bytes from a fixture directory.

import ArkDeckCore
import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class RockchipImageArchiveIntrospectionContractTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("arkdeck-archive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  /// The rule replaces a table that a person wrote by hand, twice. If it does
  /// not reproduce both of them exactly, it is not the same knowledge.
  func testTheClassificationRuleReproducesEveryHandAuthoredMember() {
    for profile in RockchipFlashProfile.supportedDAYU200Profiles {
      for member in profile.members {
        XCTAssertEqual(
          profile.classification(ofMemberNamed: member.name), member.classification,
          "\(profile.catalogReference) member \(member.name) reclassified by the rule")
      }
    }
  }

  /// The exact CMDLINE line shipped in the 2026-07-28 daily's `parameter.txt`.
  /// Kept verbatim rather than simplified: a partition table parser that only
  /// handles a tidied-up table is not one that can read a real archive.
  private static let realCMDLINE = """
    FIRMWARE_VER:11.0
    MACHINE_MODEL:rk3568_r
    TYPE: GPT
    CMDLINE:mtdparts=rk29xxnand:0x00002000@0x00002000(uboot),\
    0x00002000@0x00004000(misc),0x00001000@0x00006000(bootctrl),\
    0x00003000@0x00007000(resource),0x00030000@0x0000A000(boot_linux:bootable),\
    0x00002000@0x0003A000(ramdisk),0x00400000@0x0003C000(system),\
    0x00200000@0x0043C000(vendor),0x00019000@0x0063C000(sys-prod),\
    0x00019000@0x00655000(chip-prod),0x00010000@0x0066E000(updater),\
    0x00008000@0x0067E000(eng_system),0x00008000@0x00686000(eng_chipset),\
    0x00020000@0x0069E000(chip_ckm),-@0x01308000(userdata:grow)
    uuid:system=614e0000-0000-4b53-8000-1d28000054a9
    """

  func testTheRealPartitionTableParsesIntoNamesSizesAndOffsets() throws {
    let url = root.appendingPathComponent("parameter.txt")
    try Data(Self.realCMDLINE.utf8).write(to: url)
    let declared = try RockchipImageArchiveIntrospection.partitions(inTableAt: url)

    XCTAssertEqual(declared.count, 15)
    let byName = Dictionary(uniqueKeysWithValues: declared.map { ($0.name, $0) })
    XCTAssertEqual(byName["uboot"]?.offsetSectors, 0x2000)
    XCTAssertEqual(byName["uboot"]?.sizeSectors, 0x2000)
    // A `:bootable` or `:grow` suffix is an attribute, not part of the name.
    XCTAssertNotNil(byName["boot_linux"])
    XCTAssertNotNil(byName["userdata"])
    XCTAssertEqual(byName["system"]?.offsetSectors, 0x3C000)
    // `-` means the partition runs to the end of the device.
    XCTAssertEqual(byName["userdata"]?.sizeSectors, -1)
    XCTAssertEqual(byName["userdata"]?.offsetSectors, 0x1308000)
    // Both hyphenated partitions the board forbids writing appear as the table
    // spells them, so the orphan-image rule can resolve `sys_prod.img` to it.
    XCTAssertNotNil(byName["sys-prod"])
    XCTAssertNotNil(byName["chip-prod"])
  }

  /// Every partition the board maps must appear in the table the real archive
  /// ships, under the name the board uses. This is the join that decides which
  /// image reaches which partition, so it is asserted against the shipped
  /// table rather than a tidied one.
  func testTheRealTableCoversEveryPartitionTheBoardMaps() throws {
    let url = root.appendingPathComponent("parameter.txt")
    try Data(Self.realCMDLINE.utf8).write(to: url)
    let declared = Set(
      try RockchipImageArchiveIntrospection.partitions(inTableAt: url).map(\.name))
    for profile in RockchipFlashProfile.supportedDAYU200Profiles {
      for mapped in profile.mappedPartitions {
        XCTAssertTrue(
          declared.contains(mapped.partitionName),
          "\(profile.catalogReference) maps \(mapped.partitionName), absent from the real table")
      }
      for forbidden in profile.membershiplessPartitionsWriteForbidden {
        XCTAssertTrue(
          declared.contains(forbidden),
          "\(profile.catalogReference) forbids \(forbidden), absent from the real table")
      }
    }
  }

  func testAnUnparsableTableFailsClosedRatherThanYieldingAPartialPlan() throws {
    let cases: [(String, String)] = [
      ("no mtdparts", "CMDLINE:console=ttyFIQ0\n"),
      ("no device prefix", "CMDLINE:mtdparts=0x1@0x2(uboot)\n"),
      ("unbracketed entry", "CMDLINE:mtdparts=rk29xxnand:0x1@0x2uboot\n"),
      ("no offset", "CMDLINE:mtdparts=rk29xxnand:0x1(uboot)\n"),
      ("empty name", "CMDLINE:mtdparts=rk29xxnand:0x1@0x2()\n"),
      ("not hex", "CMDLINE:mtdparts=rk29xxnand:0xzz@0x2(uboot)\n"),
    ]
    for (label, text) in cases {
      let url = root.appendingPathComponent("parameter-\(UUID().uuidString).txt")
      try Data(text.utf8).write(to: url)
      XCTAssertThrowsError(
        try RockchipImageArchiveIntrospection.partitions(inTableAt: url), label)
    }
  }

  /// The value is scanned out of the image because it is the only place that
  /// tells the truth: the 2026-07-28 daily is *named* 7.0.0.35 and its build
  /// log says 7.0.0.35, while the device it produces answers 7.0.0.36.
  func testTheRuntimeVersionIsReadFromTheImageBytes() {
    var scanner = RockchipImageArchiveIntrospection.StreamingValueScanner(
      key: RockchipImageArchiveIntrospection.runtimeVersionKey)
    var bytes = [UInt8](repeating: 0x00, count: 1_000)
    bytes.append(contentsOf: Array("const.ohos.fullname=OpenHarmony-7.0.0.36".utf8))
    bytes.append(0x00)
    let found = bytes.withUnsafeBytes { scanner.consume($0) }
    XCTAssertEqual(found, "OpenHarmony-7.0.0.36")
  }

  /// The decompressor owes nobody a chunk boundary, so the property can land
  /// astride any two chunks. A scanner that only searched inside one chunk
  /// would report "no version" and leave post-flash verification comparing
  /// against nothing — which reads as a passing flash.
  func testAVersionSplitAcrossEveryChunkBoundaryIsStillFound() {
    let payload = Array("const.ohos.fullname=OpenHarmony-7.0.0.37".utf8) + [0x00]
    for split in 1..<payload.count {
      var scanner = RockchipImageArchiveIntrospection.StreamingValueScanner(
        key: RockchipImageArchiveIntrospection.runtimeVersionKey)
      let head = Array(payload[..<split])
      let tail = Array(payload[split...])
      var found = head.withUnsafeBytes { scanner.consume($0) }
      if found == nil { found = tail.withUnsafeBytes { scanner.consume($0) } }
      XCTAssertEqual(found, "OpenHarmony-7.0.0.37", "split at \(split)")
    }
  }

  func testAnImageWithNoVersionYieldsNothing() {
    var scanner = RockchipImageArchiveIntrospection.StreamingValueScanner(
      key: RockchipImageArchiveIntrospection.runtimeVersionKey)
    let bytes = [UInt8](repeating: 0x41, count: 4_096)
    XCTAssertNil(bytes.withUnsafeBytes { scanner.consume($0) })
  }

  /// A near-miss must not consume the real match that follows it: the key
  /// appears in prose inside these images as well as in the property table.
  func testAPartialKeyDoesNotSwallowTheRealMatch() {
    var scanner = RockchipImageArchiveIntrospection.StreamingValueScanner(
      key: RockchipImageArchiveIntrospection.runtimeVersionKey)
    var bytes = Array("const.ohos.full".utf8)
    bytes.append(contentsOf: Array("const.ohos.fullname=OpenHarmony-7.0.0.38 ".utf8))
    XCTAssertEqual(bytes.withUnsafeBytes { scanner.consume($0) }, "OpenHarmony-7.0.0.38")
  }

  /// The whole claim, end to end, on the archive the pinned profile was
  /// written from: streaming it once must derive exactly what a person typed.
  ///
  /// Opt-in because the archive is 730 MB and not in the repository. Point
  /// `ARKDECK_DAYU200_ARCHIVE` at a `dayu200_img.tar.gz` to run it; the run
  /// that this change was merged on is recorded in the evidence file.
  func testTheRealArchiveDerivesExactlyWhatThePinnedProfileStates() throws {
    guard let path = ProcessInfo.processInfo.environment["ARKDECK_DAYU200_ARCHIVE"] else {
      throw XCTSkip("set ARKDECK_DAYU200_ARCHIVE to a dayu200_img.tar.gz to run this")
    }
    let board = RockchipFlashProfile.dayu200OpenHarmony70035
    let summary = try GzipTarArchiveReader.summarize(
      fileAt: URL(fileURLWithPath: path),
      derivation: RockchipImageArchiveIntrospection.derivationRequest(board: board))
    let build = try RockchipImageArchiveIntrospection.describe(summary: summary, board: board)

    XCTAssertEqual(build.archiveSizeBytes, board.archiveSizeBytes)
    XCTAssertEqual(build.archiveSHA256, board.archiveSHA256)
    XCTAssertEqual(build.runtimeBuildVersion, board.runtimeBuildVersion)

    let derived = Dictionary(uniqueKeysWithValues: build.members.map { ($0.name, $0) })
    XCTAssertEqual(Set(derived.keys), Set(board.members.map(\.name)))
    for pinned in board.members {
      let member = try XCTUnwrap(derived[pinned.name], pinned.name)
      XCTAssertEqual(member.sizeBytes, pinned.sizeBytes, pinned.name)
      XCTAssertEqual(member.sha256, pinned.sha256.lowercased(), pinned.name)
      XCTAssertEqual(member.classification, pinned.classification, pinned.name)
    }
    XCTAssertEqual(board.conformance(of: build), [])
  }

  /// Conformance is structural. An archive for a build nobody enumerated is
  /// accepted when it fits the board; one that is missing a mapped image, or
  /// declares a partition this board does not know, is not.
  func testConformanceJudgesStructureRatherThanRecognisingADigest() {
    let board = RockchipFlashProfile.dayu200OpenHarmony70035
    let table = board.mappedPartitions.map {
      RockchipDeclaredPartition(name: $0.partitionName, sizeSectors: 1, offsetSectors: 0)
    } + board.membershiplessPartitionsWriteForbidden.map {
      RockchipDeclaredPartition(name: $0, sizeSectors: 1, offsetSectors: 0)
    }
    func build(
      members: [String], partitions: [RockchipDeclaredPartition], version: String = "OpenHarmony-9.9.9.9"
    ) -> RockchipImageBuildDescriptor {
      RockchipImageBuildDescriptor(
        archiveSizeBytes: 1, archiveSHA256: String(repeating: "a", count: 64),
        members: members.map {
          RockchipImagesArchiveMember(
            name: $0, sizeBytes: 1, sha256: String(repeating: "b", count: 64),
            classification: board.classification(ofMemberNamed: $0))
        },
        declaredPartitions: partitions, runtimeBuildVersion: version)
    }
    let allImages = board.mappedPartitions.map(\.imageMemberName)

    // A build with a version no profile has ever named still conforms.
    XCTAssertEqual(build(members: allImages, partitions: table).conformanceViolations(on: board), [])

    XCTAssertEqual(
      build(members: Array(allImages.dropFirst()), partitions: table)
        .conformanceViolations(on: board).filter { $0.hasPrefix("mappedPartitionImageMissing") }
        .count,
      1)
    XCTAssertTrue(
      build(
        members: allImages,
        partitions: table + [
          RockchipDeclaredPartition(name: "vendor-secrets", sizeSectors: 1, offsetSectors: 0)
        ]
      ).conformanceViolations(on: board).contains("undeclaredPartitionInTable:vendor-secrets"))
    XCTAssertTrue(
      build(members: allImages, partitions: table, version: "")
        .conformanceViolations(on: board).contains("runtimeBuildVersionUnreadable"))
  }
}

extension RockchipImageBuildDescriptor {
  fileprivate func conformanceViolations(on board: RockchipFlashProfile) -> [String] {
    board.conformance(of: self)
  }
}
