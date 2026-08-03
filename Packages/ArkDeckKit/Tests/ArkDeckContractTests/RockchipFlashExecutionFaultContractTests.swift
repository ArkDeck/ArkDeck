import ArkDeckCore
import ArkDeckProcess
import ArkDeckStorage
import Compression
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// Archive staging faults (TASK-AIN-007).
///
/// The rest of this suite drove the in-process flash executor and went with it
/// when that executor was retired (T25). Staging did not: the engine lane's
/// per-action host stages through the very same `RockchipFlashExecutionStager`,
/// so a traversal, duplicate, link or post-stage descriptor replacement must
/// still be refused.
final class RockchipFlashExecutionFaultContractTests: XCTestCase {
  func testStagingRejectsTraversalDuplicateLinkAndDescriptorReplacement() throws {
    for archiveCase in [ArchiveFault.traversal, .duplicate, .link] {
      let base = FileManager.default.temporaryDirectory.appending(
        path: "arkdeck-ain007-stage-fault-\(UUID().uuidString)")
      try FileManager.default.createDirectory(
        at: base, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: base) }
      let built = try makeFaultArchive(archiveCase)
      let archive = base.appending(path: "images.tar.gz")
      try built.data.write(to: archive)
      let root = base.appending(path: "session")
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      XCTAssertThrowsError(
        try RockchipFlashExecutionStager.stage(
          archiveURL: archive, sessionRoot: root, profile: built.profile))
    }

    let fixture = try RockchipExecutionTestFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let root = fixture.base.appending(path: "replacement-session")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let images = try RockchipFlashExecutionStager.stage(
      archiveURL: fixture.archive, sessionRoot: root, profile: fixture.profile)
    let image = try XCTUnwrap(images["image0.img"])
    let stagedPath = root.appending(path: "staging/image0.img")
    let displaced = root.appending(path: "staging/image0.displaced")
    try FileManager.default.moveItem(at: stagedPath, to: displaced)
    try Data("replacement".utf8).write(to: stagedPath)
    XCTAssertThrowsError(try image.revalidate())
  }

  private enum ArchiveFault { case traversal, duplicate, link }


  private func makeFaultArchive(_ fault: ArchiveFault) throws -> (
    data: Data, profile: RockchipFlashProfile
  ) {
    let name = fault == .traversal ? "../escape.img" : "image.img"
    let bytes = Data("payload".utf8)
    let entries: [(String, Data, UInt8)] =
      fault == .duplicate
      ? [(name, bytes, UInt8(ascii: "0")), (name, bytes, UInt8(ascii: "0"))]
      : [(name, bytes, fault == .link ? UInt8(ascii: "2") : UInt8(ascii: "0"))]
    let data = try gzipTar(entries: entries)
    let profile = try RockchipFlashProfile(
      archiveSizeBytes: Int64(data.count),
      archiveSHA256: RockchipExecutionTestFixture.sha256(data),
      members: [
        RockchipImagesArchiveMember(
          name: name, sizeBytes: Int64(bytes.count),
          sha256: RockchipExecutionTestFixture.sha256(bytes),
          classification: .mappedPartitionImage)
      ],
      mappedPartitions: [
        RockchipMappedPartition(
          writeOrder: 1, partitionName: "partition", imageMemberName: name,
          offsetSectors: 8192)
      ],
      membershiplessPartitionsWriteForbidden: [], prerequisites: [:])
    return (data, profile)
  }

  private func gzipTar(entries: [(String, Data, UInt8)]) throws -> Data {
    var tar = Data()
    for entry in entries {
      var header = [UInt8](repeating: 0, count: 512)
      RockchipExecutionTestFixture.write(entry.0, into: &header, offset: 0, length: 100)
      RockchipExecutionTestFixture.writeOctal(0o600, into: &header, offset: 100, length: 8)
      RockchipExecutionTestFixture.writeOctal(entry.1.count, into: &header, offset: 124, length: 12)
      for index in 148..<156 { header[index] = 0x20 }
      header[156] = entry.2
      RockchipExecutionTestFixture.write("ustar", into: &header, offset: 257, length: 6)
      header[263] = UInt8(ascii: "0")
      header[264] = UInt8(ascii: "0")
      let checksum = header.reduce(0) { $0 + Int($1) }
      RockchipExecutionTestFixture.write(
        String(format: "%06o", checksum), into: &header, offset: 148, length: 6)
      header[154] = 0
      header[155] = 0x20
      tar.append(contentsOf: header)
      tar.append(entry.1)
      tar.append(Data(repeating: 0, count: (512 - entry.1.count % 512) % 512))
    }
    tar.append(Data(repeating: 0, count: 1024))
    var gzip = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0, 0xff])
    gzip.append(try RockchipExecutionTestFixture.deflate(tar))
    gzip.append(Data(repeating: 0, count: 8))
    return gzip
  }
}

/// Shared archive fixture, kept for the staging test above.
struct RockchipExecutionTestFixture {
  let base: URL
  let archive: URL
  let executable: URL
  let executableSHA256: String
  let executableReceipt: ProcessExecutableIdentityReceipt
  let profile: RockchipFlashProfile
  let plan: RockchipFlashPlan
  let sessionsRoot: URL
  let coordinator: HostStorageCoordinator

  static let deterministicID: @Sendable (String) -> String = { prefix in
    switch prefix {
    case "rockchip-session": "rockchip-session-fixed"
    case "rockchip-job": "rockchip-job-fixed"
    default: "rockchip-target-fixed"
    }
  }

  static func make(partitionNames: [String]? = nil) throws -> RockchipExecutionTestFixture {
    let base = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-ain007-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let members = (0..<9).map { index in
      (name: "image\(index).img", bytes: Data("image-\(index)-payload".utf8))
    }
    let archive = base.appending(path: "images.tar.gz")
    try makeGzipTar(members: members).write(to: archive)
    let archiveBytes = try Data(contentsOf: archive)
    let profileMembers = members.map {
      RockchipImagesArchiveMember(
        name: $0.name, sizeBytes: Int64($0.bytes.count), sha256: sha256($0.bytes),
        classification: .mappedPartitionImage)
    }
    let profile = try RockchipFlashProfile(
      archiveSizeBytes: Int64(archiveBytes.count), archiveSHA256: sha256(archiveBytes),
      members: profileMembers,
      mappedPartitions: members.enumerated().map { index, member in
        RockchipMappedPartition(
          writeOrder: index + 1,
          partitionName: partitionNames?[index] ?? "partition\(index)",
          imageMemberName: member.name, offsetSectors: Int64((index + 1) * 8192))
      },
      membershiplessPartitionsWriteForbidden: [],
      prerequisites: [
        .loader: .required, .recoveryPath: .required, .unlocked: .required,
        .stablePower: .optional,
      ])
    let plan = try RockchipRockUSBFlashProvider(profile: profile).makePlan(
      mode: .execute, archiveValidation: .valid)
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let executable = packageRoot.appending(path: ".build/debug/ArkDeckFakeRockchipFixture")
    let executableSHA256 = sha256(try Data(contentsOf: executable))
    let executor = FoundationProcessExecutor()
    let prepared = try executor.prepareIdentityBoundLaunch(
      ProcessIdentityBoundRequest(
        process: ProcessRequest(executable: executable, arguments: ["ld"]),
        expectedSHA256: executableSHA256))
    let receipt = prepared.executableIdentity
    prepared.close()
    let sessionsRoot = base.appending(path: "Sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sessionsRoot, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    return RockchipExecutionTestFixture(
      base: base, archive: archive, executable: executable,
      executableSHA256: executableSHA256, executableReceipt: receipt,
      profile: profile, plan: plan, sessionsRoot: sessionsRoot,
      coordinator: HostStorageCoordinator())
  }


  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func makeGzipTar(members: [(name: String, bytes: Data)]) throws -> Data {
    var tar = Data()
    for member in members {
      var header = [UInt8](repeating: 0, count: 512)
      write(member.name, into: &header, offset: 0, length: 100)
      writeOctal(0o600, into: &header, offset: 100, length: 8)
      writeOctal(0, into: &header, offset: 108, length: 8)
      writeOctal(0, into: &header, offset: 116, length: 8)
      writeOctal(member.bytes.count, into: &header, offset: 124, length: 12)
      writeOctal(0, into: &header, offset: 136, length: 12)
      for index in 148..<156 { header[index] = 0x20 }
      header[156] = UInt8(ascii: "0")
      write("ustar", into: &header, offset: 257, length: 6)
      header[262] = 0
      header[263] = UInt8(ascii: "0")
      header[264] = UInt8(ascii: "0")
      let checksum = header.reduce(0) { $0 + Int($1) }
      let checksumText = String(format: "%06o", checksum)
      write(checksumText, into: &header, offset: 148, length: 6)
      header[154] = 0
      header[155] = 0x20
      tar.append(contentsOf: header)
      tar.append(member.bytes)
      tar.append(Data(repeating: 0, count: (512 - member.bytes.count % 512) % 512))
    }
    tar.append(Data(repeating: 0, count: 1024))
    let compressed = try deflate(tar)
    var gzip = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0, 0xff])
    gzip.append(compressed)
    gzip.append(Data(repeating: 0, count: 8))
    return gzip
  }

  static func deflate(_ data: Data) throws -> Data {
    let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count * 2 + 1024)
    defer { destination.deallocate() }
    let count = data.withUnsafeBytes { source in
      compression_encode_buffer(
        destination, data.count * 2 + 1024,
        source.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
        nil, COMPRESSION_ZLIB)
    }
    guard count > 0 else { throw RockchipFlashStagingError.decompressionFailed }
    return Data(bytes: destination, count: count)
  }

  static func write(
    _ string: String, into bytes: inout [UInt8], offset: Int, length: Int
  ) {
    for (index, byte) in string.utf8.prefix(length).enumerated() {
      bytes[offset + index] = byte
    }
  }

  static func writeOctal(
    _ value: Int, into bytes: inout [UInt8], offset: Int, length: Int
  ) {
    let text = String(format: "%0*o", length - 1, value)
    write(text, into: &bytes, offset: offset, length: length - 1)
    bytes[offset + length - 1] = 0
  }
}
