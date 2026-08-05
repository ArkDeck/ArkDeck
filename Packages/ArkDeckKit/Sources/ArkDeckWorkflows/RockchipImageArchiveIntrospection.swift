// What a DAYU200 images archive says about itself (CHG-2026-056 r4, TASK-E2B-001).
//
// A device profile describes a board. Everything that varies between firmware
// builds is read from the archive under authorization instead of being
// compiled into the product, because OpenHarmony publishes a daily and a
// profile constant per build costs a `deviceProfile` enum value, a catalog
// digest, and therefore every Golden Journey's `REAL_DEVICE_PASS`.
//
// Three facts, three sources, none of them a guess:
//
//   * member digests   - a hash of bytes already being read
//   * partition table  - `parameter.txt`, whose CMDLINE carries the mtdparts
//                        list with every partition's name, size and offset
//   * runtime version  - the bytes of the system image the plan will write
//
// The last one is the subtle one, and the reason it is not read from the
// archive's name or its build log: both state the daily's label, which is not
// what the flashed device answers. The 2026-07-28 daily is named `7.0.0.35`
// and its `daily_build.log` says `OpenHarmony_7.0.0.35`, while the value baked
// into its `system.img` is `OpenHarmony-7.0.0.36` - which is what the device
// reported after it was flashed on 2026-08-04, and what post-flash
// verification has to compare against.
//
// Nothing here executes anything from inside the archive. Reading bytes is the
// whole capability: no mount, no loop device, no interpreter.

import ArkDeckCore
import CryptoKit
import Foundation

public enum RockchipArchiveIntrospectionFailure: Error, Equatable, Sendable {
  case memberUnreadable(String)
  case partitionTableMissing
  case partitionTableUnparsable(String)
  case systemImageMissing(String)
  case runtimeBuildVersionUnreadable
  case oversizedMember(name: String, sizeBytes: Int64)
}

/// One partition as the archive's own table declares it.
public struct RockchipDeclaredPartition: Equatable, Sendable {
  public let name: String
  public let sizeSectors: Int64
  public let offsetSectors: Int64

  public init(name: String, sizeSectors: Int64, offsetSectors: Int64) {
    self.name = name
    self.sizeSectors = sizeSectors
    self.offsetSectors = offsetSectors
  }
}

/// Everything the archive states about the build it carries. Derived at import
/// and recorded on the Artifact lease; never carried by a device profile.
public struct RockchipImageBuildDescriptor: Equatable, Sendable {
  public let archiveSizeBytes: Int64
  public let archiveSHA256: String
  public let members: [RockchipImagesArchiveMember]
  public let declaredPartitions: [RockchipDeclaredPartition]
  /// The value the flashed device will report for `const.ohos.fullname`.
  public let runtimeBuildVersion: String

  public init(
    archiveSizeBytes: Int64,
    archiveSHA256: String,
    members: [RockchipImagesArchiveMember],
    declaredPartitions: [RockchipDeclaredPartition],
    runtimeBuildVersion: String
  ) {
    self.archiveSizeBytes = archiveSizeBytes
    self.archiveSHA256 = archiveSHA256.lowercased()
    self.members = members
    self.declaredPartitions = declaredPartitions
    self.runtimeBuildVersion = runtimeBuildVersion
  }

  public func observation() -> RockchipImagesArchiveObservation {
    RockchipImagesArchiveObservation(
      archiveSizeBytes: archiveSizeBytes,
      archiveSHA256: archiveSHA256,
      members: members.map {
        RockchipArchiveMemberObservation(
          name: $0.name, sizeBytes: $0.sizeBytes, sha256: $0.sha256)
      })
  }
}

public enum RockchipImageArchiveIntrospection {
  /// A single member may not exceed this. The largest real member is a 2 GiB
  /// `system.img`; the bound exists so a malformed archive cannot make the
  /// host read without end, not because 4 GiB is meaningful.
  static let maximumMemberBytes: Int64 = 4 * 1024 * 1024 * 1024

  /// What a caller must ask the archive reader for so a build can be described
  /// in the single pass the archive is already making.
  public static func derivationRequest(board: RockchipFlashProfile) -> GzipTarDerivationRequest {
    GzipTarDerivationRequest(
      captureMembers: [RockchipFlashProfile.partitionTableMemberName],
      captureByteLimit: 1 << 20,
      scanMember: board.mappedPartitions
        .first { $0.partitionName == board.runtimeVersionPartitionName }?.imageMemberName,
      scanKey: runtimeVersionKey)
  }

  /// Describes the build an archive carries, from the summary of the one pass
  /// that already streamed it.
  ///
  /// Nothing is extracted. This file's neighbour states the rule it follows:
  /// an unvalidated archive is never handed to an external tool, and it is not
  /// written out to be read a second time either. Everything below is learned
  /// from bytes that went past once.
  public static func describe(
    summary: GzipTarArchiveSummary,
    board: RockchipFlashProfile
  ) throws -> RockchipImageBuildDescriptor {
    let members = summary.members.map {
      RockchipImagesArchiveMember(
        name: $0.name, sizeBytes: $0.sizeBytes, sha256: $0.sha256,
        classification: board.classification(ofMemberNamed: $0.name))
    }
    guard
      let tableBytes = summary.capturedMembers[RockchipFlashProfile.partitionTableMemberName]
    else {
      throw RockchipArchiveIntrospectionFailure.partitionTableMissing
    }
    let declared = try partitions(inTable: tableBytes)

    let systemImageMember = board.mappedPartitions
      .first { $0.partitionName == board.runtimeVersionPartitionName }?.imageMemberName
    guard let systemImageMember,
      members.contains(where: { $0.name == systemImageMember })
    else {
      throw RockchipArchiveIntrospectionFailure.systemImageMissing(
        board.runtimeVersionPartitionName)
    }
    guard let version = summary.scannedValue, !version.isEmpty else {
      throw RockchipArchiveIntrospectionFailure.runtimeBuildVersionUnreadable
    }

    return RockchipImageBuildDescriptor(
      archiveSizeBytes: summary.archiveSizeBytes,
      archiveSHA256: summary.archiveSHA256,
      members: members,
      declaredPartitions: declared,
      runtimeBuildVersion: version)
  }


  /// The partition table lives in the archive's `parameter.txt`, on the
  /// `CMDLINE` line, as Rockchip's `mtdparts` list:
  ///
  ///   `mtdparts=rk29xxnand:0x00002000@0x00002000(uboot),…,-@0x01308000(userdata:grow)`
  ///
  /// A size of `-` means "the rest of the device"; a name may carry a
  /// `:bootable`/`:grow` suffix that is an attribute, not part of the name.
  static func partitions(inTableAt url: URL) throws -> [RockchipDeclaredPartition] {
    guard let bytes = try? Data(contentsOf: url) else {
      throw RockchipArchiveIntrospectionFailure.partitionTableUnparsable("unreadable")
    }
    return try partitions(inTable: bytes)
  }

  static func partitions(inTable bytes: Data) throws -> [RockchipDeclaredPartition] {
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw RockchipArchiveIntrospectionFailure.partitionTableUnparsable("not UTF-8")
    }
    guard
      let cmdline = text.split(separator: "\n").first(where: {
        $0.hasPrefix("CMDLINE")
      }),
      let partsRange = cmdline.range(of: "mtdparts=")
    else {
      throw RockchipArchiveIntrospectionFailure.partitionTableUnparsable("no mtdparts")
    }
    let list = cmdline[partsRange.upperBound...]
    // Everything after the first colon is the partition list; before it is the
    // flash device name.
    guard let colon = list.firstIndex(of: ":") else {
      throw RockchipArchiveIntrospectionFailure.partitionTableUnparsable("no device prefix")
    }
    var declared: [RockchipDeclaredPartition] = []
    for entry in list[list.index(after: colon)...].split(separator: ",") {
      let trimmed = entry.trimmingCharacters(in: .whitespaces)
      guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else {
        throw RockchipArchiveIntrospectionFailure.partitionTableUnparsable(trimmed)
      }
      let geometry = trimmed[trimmed.startIndex..<open]
      let rawName = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
      let name = String(rawName.split(separator: ":").first ?? rawName)
      guard let at = geometry.firstIndex(of: "@") else {
        throw RockchipArchiveIntrospectionFailure.partitionTableUnparsable(trimmed)
      }
      let sizeText = geometry[geometry.startIndex..<at]
      let offsetText = geometry[geometry.index(after: at)...]
      guard let offset = hexSectors(offsetText) else {
        throw RockchipArchiveIntrospectionFailure.partitionTableUnparsable(trimmed)
      }
      // `-` is the grow marker: the partition runs to the end of the device.
      let size = sizeText == "-" ? Int64(-1) : hexSectors(sizeText)
      guard let size else {
        throw RockchipArchiveIntrospectionFailure.partitionTableUnparsable(trimmed)
      }
      guard !name.isEmpty else {
        throw RockchipArchiveIntrospectionFailure.partitionTableUnparsable(trimmed)
      }
      declared.append(
        RockchipDeclaredPartition(name: name, sizeSectors: size, offsetSectors: offset))
    }
    guard !declared.isEmpty else {
      throw RockchipArchiveIntrospectionFailure.partitionTableUnparsable("empty list")
    }
    return declared
  }

  static func hexSectors(_ text: Substring) -> Int64? {
    let body = text.hasPrefix("0x") || text.hasPrefix("0X") ? text.dropFirst(2) : text
    guard !body.isEmpty, body.count <= 16 else { return nil }
    return Int64(body, radix: 16)
  }

  /// The property the booted device answers with, read from the image that
  /// will become that device's system partition.
  ///
  /// Scanned rather than parsed: the parameter file lives inside a filesystem
  /// image, and reading its bytes is a capability this host already has, while
  /// mounting the image is not one it should acquire for a version string. The
  /// scan is bounded, streams in windows, and carries the window overlap so a
  /// match that straddles a boundary is still found.
  static let runtimeVersionKey = "const.ohos.fullname="

  /// Finds `key` followed by a printable value run, across an arbitrary number
  /// of chunks.
  ///
  /// Streaming rather than window-at-a-time because the bytes arrive from a
  /// decompressor that owes nobody a chunk boundary: the property can land
  /// astride any two chunks, and a scanner that only searched inside one would
  /// silently report "no version" and leave post-flash verification with
  /// nothing to compare against.
  struct StreamingValueScanner {
    private let key: [UInt8]
    private var matched = 0
    private var value: [UInt8] = []
    private var collecting = false

    init(key: String) {
      self.key = Array(key.utf8)
    }

    /// Returns the value once the run ends, or nil while more input is needed.
    mutating func consume(_ bytes: UnsafeRawBufferPointer) -> String? {
      for byte in bytes {
        if collecting {
          if isValueByte(byte) {
            value.append(byte)
            // A value this long is not a version string; treat the run as
            // noise rather than growing without bound.
            if value.count > 256 { collecting = false; value = []; matched = 0 }
            continue
          }
          collecting = false
          if !value.isEmpty { return String(decoding: value, as: UTF8.self) }
          matched = 0
          continue
        }
        if byte == key[matched] {
          matched += 1
          if matched == key.count {
            collecting = true
            value = []
            matched = 0
          }
        } else {
          // Restart, allowing the mismatched byte to open a new match.
          matched = byte == key[0] ? 1 : 0
        }
      }
      return nil
    }
  }

  /// First `key`-prefixed run of printable value bytes in `window`.
  static func value(forKey key: [UInt8], in window: [UInt8]) -> String? {
    guard window.count >= key.count else { return nil }
    var index = 0
    let limit = window.count - key.count
    while index <= limit {
      if window[index] == key[0], Array(window[index..<index + key.count]) == key {
        var end = index + key.count
        while end < window.count, isValueByte(window[end]) { end += 1 }
        let value = String(decoding: window[(index + key.count)..<end], as: UTF8.self)
        return value.isEmpty ? nil : value
      }
      index += 1
    }
    return nil
  }

  static func isValueByte(_ byte: UInt8) -> Bool {
    // Version values are ASCII words: letters, digits, dot, dash, underscore.
    (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
      || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2E || byte == 0x2D || byte == 0x5F
  }

  static func streamedSHA256(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
