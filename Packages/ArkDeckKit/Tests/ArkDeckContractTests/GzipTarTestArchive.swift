import Compression
import CryptoKit
import Foundation

/// Minimal in-memory gzip/tar builder for archive-shaped test inputs.
///
/// Extracted from the retired `RockchipExecutionTestFixture`
/// (CHG-2026-065 removed the vendor-era staging suite that owned it);
/// the archive builder itself stays because recovery-contract tests still
/// synthesize small images.tar.gz inputs with it.
enum GzipTarTestArchive {
  enum Failure: Error { case deflateFailed }

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

  private static func deflate(_ data: Data) throws -> Data {
    let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count * 2 + 1024)
    defer { destination.deallocate() }
    let count = data.withUnsafeBytes { source in
      compression_encode_buffer(
        destination, data.count * 2 + 1024,
        source.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
        nil, COMPRESSION_ZLIB)
    }
    guard count > 0 else { throw Failure.deflateFailed }
    return Data(bytes: destination, count: count)
  }

  private static func write(
    _ string: String, into bytes: inout [UInt8], offset: Int, length: Int
  ) {
    for (index, byte) in string.utf8.prefix(length).enumerated() {
      bytes[offset + index] = byte
    }
  }

  private static func writeOctal(
    _ value: Int, into bytes: inout [UInt8], offset: Int, length: Int
  ) {
    let text = String(format: "%0*o", length - 1, value)
    write(text, into: &bytes, offset: offset, length: length - 1)
    bytes[offset + length - 1] = 0
  }
}
