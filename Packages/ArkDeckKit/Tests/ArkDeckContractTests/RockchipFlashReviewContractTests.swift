import Compression
import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

// The DAYU200 profile pins and the gzip/tar reader contracts that survived
// CHG-2026-066. The provider plan model those AC-FLASH tests exercised was
// dissolved — execution semantics live in `arkforged` and the review now
// presents the engine's own catalog facts (see
// FlashApplicationFacadeContractTests for the same-source digest contract).

final class RockchipFlashReviewContractTests: XCTestCase {
  // MARK: - Single profile seed pin (drift guard)

  func testProfilePinsCurrentDAYU200SeedArchive() {
    let profile = RockchipFlashProfile.dayu200
    XCTAssertEqual(profile.archiveSizeBytes, 730_769_584)
    XCTAssertEqual(
      profile.archiveSHA256,
      "6a023c738ac585b8a6f537c99f2ab2df95a5359fd6d4dd33150fad62e71f064e")
    XCTAssertEqual(profile.members.count, 17)
    XCTAssertEqual(
      profile.member(named: "system.img")?.sha256,
      "86357e57a183278e1662d55c2d560a35e8e685613bd270f62df42bdf783f0650")
    XCTAssertEqual(profile.member(named: "system.img")?.sizeBytes, 2_147_483_648)
    XCTAssertEqual(
      profile.member(named: "uboot.img")?.sha256,
      "c1c801e45cbb92ee63e14df3dda5d819792e02295525bd53dbf750efb645916d")
    XCTAssertEqual(
      profile.member(named: "userdata.img")?.sha256,
      "ea60e842586208b660b72ae4b507a1f4cabb397e912156f342f30f21907e1255")

    XCTAssertEqual(
      profile.mappedPartitions.map(\.partitionName),
      [
        "uboot", "resource", "boot_linux", "ramdisk", "system", "vendor", "updater",
        "chip_ckm", "userdata",
      ])
    XCTAssertEqual(profile.writeForbiddenMemberNames.sorted(), ["chip_prod.img", "sys_prod.img"])
    XCTAssertEqual(
      profile.membershiplessPartitionsWriteForbidden,
      ["misc", "bootctrl", "sys-prod", "chip-prod", "eng_system", "eng_chipset"])
    XCTAssertEqual(profile.prerequisites[.loader], .required)
    XCTAssertEqual(profile.prerequisites[.recoveryPath], .required)
    XCTAssertEqual(profile.prerequisites[.unlocked], .required)
    XCTAssertEqual(profile.prerequisites[.stablePower], .optional)
  }

  // MARK: - Gzip/tar streaming inventory

  func testGzipTarArchiveReaderSummarizesMembersWithExactHashes() throws {
    let memberA = Data("uboot-image-content".utf8)
    let memberB = Data(repeating: 0x5a, count: 600)
    let memberC = Data()
    let tar = Self.tarArchive([
      ("uboot.img", memberA), ("system.img", memberB), ("empty.img", memberC),
    ])
    let gzipped = Self.gzip(tar, fileName: "images.tar")
    let url = FileManager.default.temporaryDirectory
      .appending(path: "rockusb-tar-\(UUID().uuidString).tar.gz")
    defer { try? FileManager.default.removeItem(at: url) }
    try gzipped.write(to: url)

    let summary = try GzipTarArchiveReader.summarize(fileAt: url)
    XCTAssertEqual(summary.archiveSizeBytes, Int64(gzipped.count))
    XCTAssertEqual(summary.archiveSHA256, Self.sha256Hex(gzipped))
    XCTAssertEqual(summary.members.map(\.name), ["uboot.img", "system.img", "empty.img"])
    XCTAssertEqual(summary.members.map(\.sizeBytes), [19, 600, 0])
    XCTAssertEqual(
      summary.members.map(\.sha256),
      [Self.sha256Hex(memberA), Self.sha256Hex(memberB), Self.sha256Hex(memberC)])

    let observation = summary.archiveObservation()
    XCTAssertEqual(observation.members.count, 3)
  }

  func testGzipTarArchiveReaderFailsClosedOnCorruptInput() throws {
    let tar = Self.tarArchive([("a.img", Data("payload".utf8))])
    var notGzip = Self.gzip(tar)
    notGzip[0] = 0x00
    let notGzipURL = try Self.writeTemporary(notGzip)
    defer { try? FileManager.default.removeItem(at: notGzipURL) }
    XCTAssertThrowsError(try GzipTarArchiveReader.summarize(fileAt: notGzipURL)) { error in
      XCTAssertEqual(error as? GzipTarArchiveReaderError, .notGzip)
    }

    // A valid gzip stream whose tar payload ends inside a member must not yield a summary.
    let truncatedTar = tar.prefix(tar.count - 700)
    let truncatedURL = try Self.writeTemporary(Self.gzip(Data(truncatedTar)))
    defer { try? FileManager.default.removeItem(at: truncatedURL) }
    XCTAssertThrowsError(try GzipTarArchiveReader.summarize(fileAt: truncatedURL)) { error in
      XCTAssertEqual(error as? GzipTarArchiveReaderError, .truncatedArchive)
    }

    // Truncated deflate payload fails as corrupt, never as an empty-but-valid archive.
    let truncatedDeflate = Self.gzip(tar).prefix(40)
    let truncatedDeflateURL = try Self.writeTemporary(Data(truncatedDeflate))
    defer { try? FileManager.default.removeItem(at: truncatedDeflateURL) }
    XCTAssertThrowsError(try GzipTarArchiveReader.summarize(fileAt: truncatedDeflateURL))
  }

  /// A flash bundle is parsed before any authorization runs, so a crafted
  /// header must not be able to terminate the host process. The GNU base-256
  /// size field can carry `Int64.max` without tripping the parser's own
  /// per-shift overflow guard; adding the 512-byte alignment to it then traps.
  /// Only a non-regular-file type flag reaches that addition.
  func testAMemberSizeThatCannotHoldItsAlignmentIsRefusedRatherThanTrapping() throws {
    // 0x80 marks base-256; the remaining bytes are chosen so the parser's
    // `value <= Int64.max >> 8` guard passes at every shift and lands on
    // exactly `Int64.max`.
    var sizeField = [UInt8](repeating: 0xFF, count: 12)
    sizeField[0] = 0x80
    sizeField[1] = 0x00
    sizeField[2] = 0x00
    sizeField[3] = 0x00
    sizeField[4] = 0x7F

    var header = [UInt8](repeating: 0, count: 512)
    header.replaceSubrange(0..<9, with: Array("giant.img".utf8))
    header.replaceSubrange(124..<136, with: sizeField)
    header[156] = 0x35  // directory: not 0x30/0x00, so it takes the padding branch
    header.replaceSubrange(257..<263, with: Array("ustar\0".utf8))
    header.replaceSubrange(263..<265, with: Array("00".utf8))
    header.replaceSubrange(148..<156, with: Array(repeating: 0x20, count: 8))
    let checksum = header.reduce(0) { $0 + Int($1) }
    header.replaceSubrange(148..<154, with: Array(String(format: "%06o", checksum).utf8))
    header[154] = 0
    header[155] = 0x20

    var archive = Data(header)
    archive.append(contentsOf: [UInt8](repeating: 0, count: 1024))
    let url = try Self.writeTemporary(Self.gzip(archive))
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertThrowsError(try GzipTarArchiveReader.summarize(fileAt: url)) { error in
      guard case .corruptTarHeader(let detail) = error as? GzipTarArchiveReaderError else {
        return XCTFail("expected a corrupt-header refusal, got \(error)")
      }
      XCTAssertTrue(
        detail.contains("alignment"),
        "the refusal must name the unrepresentable size, got: \(detail)")
    }
  }

  // MARK: - helpers

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func writeTemporary(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "rockusb-fixture-\(UUID().uuidString)")
    try data.write(to: url)
    return url
  }

  // Minimal ustar writer for fixtures.
  private static func tarArchive(_ members: [(name: String, content: Data)]) -> Data {
    var archive = Data()
    for member in members {
      var header = [UInt8](repeating: 0, count: 512)
      let nameBytes = Array(member.name.utf8)
      header.replaceSubrange(0..<nameBytes.count, with: nameBytes)
      func writeOctal(_ value: Int, at range: Range<Int>) {
        let text = String(format: "%0\(range.count - 1)o", value)
        header.replaceSubrange(
          range.lowerBound..<range.lowerBound + text.utf8.count, with: Array(text.utf8))
      }
      writeOctal(0o644, at: 100..<108)
      writeOctal(0, at: 108..<116)
      writeOctal(0, at: 116..<124)
      writeOctal(member.content.count, at: 124..<136)
      writeOctal(0, at: 136..<148)
      header[156] = 0x30
      header.replaceSubrange(257..<263, with: Array("ustar\0".utf8))
      header.replaceSubrange(263..<265, with: Array("00".utf8))
      header.replaceSubrange(148..<156, with: Array(repeating: 0x20, count: 8))
      let checksum = header.reduce(0) { $0 + Int($1) }
      let checksumText = String(format: "%06o", checksum)
      header.replaceSubrange(148..<154, with: Array(checksumText.utf8))
      header[154] = 0
      header[155] = 0x20
      archive.append(contentsOf: header)
      archive.append(member.content)
      let padding = (512 - member.content.count % 512) % 512
      archive.append(contentsOf: [UInt8](repeating: 0, count: padding))
    }
    archive.append(contentsOf: [UInt8](repeating: 0, count: 1024))
    return archive
  }

  private static func gzip(_ payload: Data, fileName: String? = nil) -> Data {
    var output = Data([0x1f, 0x8b, 0x08, fileName == nil ? 0x00 : 0x08, 0, 0, 0, 0, 0x00, 0x03])
    if let fileName {
      output.append(contentsOf: Array(fileName.utf8))
      output.append(0)
    }
    let deflated = payload.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Data in
      let capacity = payload.count + 4096
      let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
      defer { destination.deallocate() }
      let written = compression_encode_buffer(
        destination, capacity,
        input.baseAddress!.assumingMemoryBound(to: UInt8.self), payload.count,
        nil, COMPRESSION_ZLIB)
      return Data(bytes: destination, count: written)
    }
    output.append(deflated)
    var crc = Self.crc32(payload).littleEndian
    withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
    var size = UInt32(truncatingIfNeeded: payload.count).littleEndian
    withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
    return output
  }

  private static func crc32(_ data: Data) -> UInt32 {
    var table = [UInt32](repeating: 0, count: 256)
    for index in 0..<256 {
      var value = UInt32(index)
      for _ in 0..<8 {
        value = value & 1 == 1 ? 0xedb8_8320 ^ (value >> 1) : value >> 1
      }
      table[index] = value
    }
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
      crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
    }
    return crc ^ 0xffff_ffff
  }
}
